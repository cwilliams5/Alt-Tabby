#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Expected: file is included after windowstore.ahk

; Include extracted modules
#Include komorebi_state.ahk  ; State navigation helpers (accepts parsed Map/Array objects)

; ============================================================
; Komorebi Subscription Producer
; ============================================================
; Event-driven komorebi integration using named pipe subscription
; Each subscription notification includes FULL state - we use this
; to update ALL windows' workspace assignments on every event.
;
; Based on working POC: legacy/components_legacy/komorebi_poc - WORKING.ahk
; ============================================================

; Windows API Error Codes (for readability)
global ERROR_IO_PENDING := 997
global ERROR_BROKEN_PIPE := 109
global ERROR_PIPE_CONNECTED := 535

; Buffer size limit (1MB) - prevents OOM from incomplete JSON
global KSUB_BUFFER_MAX_BYTES := 1048576

; Configuration (set in KomorebiSub_Init after ConfigLoader_Init)
global KSub_PollMs := 0
global KSub_IdleRecycleMs := 0
global KSub_FallbackPollMs := 0

; State
global _KSub_PipeName := ""
global _KSub_hPipe := 0
global _KSub_hEvent := 0
global _KSub_Overlapped := 0             ; OVERLAPPED structure for async I/O
global _KSub_Connected := false
global _KSub_ClientPid := 0
global _KSub_LastEventTick := 0          ; Timestamp of last event (for idle detection)
global _KSub_ReadBuffer := ""      ; Accumulated bytes from pipe reads
global _KSub_LastWorkspaceName := ""
global _KSub_LastWsUpdateTick := 0         ; Tick when workspace was last set (for derivation cooldown)
global _KSub_FallbackMode := false

; Cache of window workspace assignments (persists even when windows leave komorebi)
; Each entry is { wsName: "name", tick: timestamp } for staleness detection
global _KSub_WorkspaceCache := Map()
global _KSub_CacheMaxAgeMs := 10000  ; Cache entries older than 10s are considered stale

; Initialize komorebi subscription
KomorebiSub_Init() {
    global _KSub_PipeName, _KSub_WorkspaceCache, cfg
    global KSub_PollMs, KSub_IdleRecycleMs, KSub_FallbackPollMs

    ; Load config values (ConfigLoader_Init has already run)
    KSub_PollMs := cfg.KomorebiSubPollMs
    KSub_IdleRecycleMs := cfg.KomorebiSubIdleRecycleMs
    KSub_FallbackPollMs := cfg.KomorebiSubFallbackPollMs

    _KSub_PipeName := "tabby_" A_TickCount "_" Random(1000, 9999)
    _KSub_WorkspaceCache := Map()

    if (!KomorebiSub_IsAvailable()) {
        ; Fall back to polling mode
        _KSub_FallbackMode := true
        SetTimer(KomorebiSub_PollFallback, KSub_FallbackPollMs)
        return false
    }

    return KomorebiSub_Start()
}

; Check if komorebic is available
KomorebiSub_IsAvailable() {
    global cfg
    return (cfg.KomorebicExe != "" && FileExist(cfg.KomorebicExe))
}

; Start subscription
KomorebiSub_Start() {
    global _KSub_PipeName, _KSub_hPipe, _KSub_hEvent, _KSub_Overlapped
    global _KSub_Connected, _KSub_ClientPid, _KSub_LastEventTick, _KSub_FallbackMode

    KomorebiSub_Stop()

    if (!KomorebiSub_IsAvailable())
        return false

    ; Create Named Pipe server (byte mode, non-wait for non-blocking accept)
    PIPE_ACCESS_INBOUND := 0x00000001
    FILE_FLAG_OVERLAPPED := 0x40000000
    PIPE_TYPE_BYTE := 0x00000000
    PIPE_READMODE_BYTE := 0x00000000

    ; Create security attributes with NULL DACL to allow non-elevated processes
    ; to connect when we're running as administrator
    pSA := _KSub_CreateOpenSecurityAttrs()

    pipePath := "\\.\pipe\" _KSub_PipeName
    _KSub_hPipe := DllCall("CreateNamedPipeW"
        , "str", pipePath
        , "uint", PIPE_ACCESS_INBOUND | FILE_FLAG_OVERLAPPED
        , "uint", PIPE_TYPE_BYTE | PIPE_READMODE_BYTE
        , "uint", 1          ; max instances
        , "uint", 0          ; out buffer (inbound only)
        , "uint", 65536      ; in buffer
        , "uint", 0          ; default timeout
        , "ptr", pSA         ; security attrs (NULL DACL = allow all)
        , "ptr")

    if (_KSub_hPipe = 0 || _KSub_hPipe = -1) {
        gle := DllCall("GetLastError", "uint")
        _KSub_DiagLog("KomorebiSub: CreateNamedPipeW FAILED err=" gle " path=" pipePath)
        _KSub_hPipe := 0
        _KSub_FallbackMode := true
        SetTimer(KomorebiSub_PollFallback, KSub_FallbackPollMs)
        return false
    }

    ; Create event for overlapped operations
    _KSub_hEvent := DllCall("CreateEventW", "ptr", 0, "int", 1, "int", 0, "ptr", 0, "ptr")
    if (!_KSub_hEvent) {
        KomorebiSub_Stop()
        _KSub_FallbackMode := true
        SetTimer(KomorebiSub_PollFallback, KSub_FallbackPollMs)
        return false
    }

    ; Allocate OVERLAPPED structure
    overSize := (A_PtrSize = 8) ? 32 : 20
    _KSub_Overlapped := Buffer(overSize, 0)
    NumPut("ptr", _KSub_hEvent, _KSub_Overlapped, (A_PtrSize = 8) ? 24 : 16)

    ; Begin async connect (non-blocking)
    ok := DllCall("ConnectNamedPipe", "ptr", _KSub_hPipe, "ptr", _KSub_Overlapped.Ptr, "int")
    if (!ok) {
        gle := DllCall("GetLastError", "uint")
        if (gle = ERROR_IO_PENDING)        ; Async operation in progress
            _KSub_Connected := false
        else if (gle = ERROR_PIPE_CONNECTED)   ; Already connected
            _KSub_Connected := true
        else {
            KomorebiSub_Stop()
            _KSub_FallbackMode := true
            SetTimer(KomorebiSub_PollFallback, KSub_FallbackPollMs)
            return false
        }
    } else {
        _KSub_Connected := true
    }

    ; Launch komorebic subscriber
    try {
        cmd := '"' cfg.KomorebicExe '" subscribe-pipe ' _KSub_PipeName
        _KSub_ClientPid := Run(cmd, , "Hide")
        _KSub_DiagLog("KomorebiSub: Launched subscriber pid=" _KSub_ClientPid " cmd=" cmd)
    } catch as e {
        _KSub_DiagLog("KomorebiSub: Failed to launch subscriber: " e.Message)
        ; Keep server alive, client may connect later
    }

    _KSub_LastEventTick := A_TickCount
    _KSub_FallbackMode := false
    _KSub_DiagLog("KomorebiSub: Setting timer with interval=" KSub_PollMs)
    SetTimer(KomorebiSub_Poll, KSub_PollMs)

    ; Do initial poll to populate all windows with workspace data immediately
    ; Runs after 1500ms to ensure first winenum scan has populated the store
    SetTimer(_KSub_InitialPoll, -1500)

    _KSub_DiagLog("KomorebiSub: Start complete, pipe=" _KSub_PipeName)
    return true
}

; Diagnostic logging - controlled by DiagKomorebiLog config flag
; Writes to %TEMP%\tabby_ksub_diag.log when enabled
_KSub_DiagLog(msg) {
    global cfg, LOG_PATH_KSUB
    if (!cfg.DiagKomorebiLog)
        return
    try LogAppend(LOG_PATH_KSUB, msg)
}

; One-time initial poll to populate workspace data on startup
_KSub_InitialPoll() {
    global _KSub_LastWorkspaceName

    _KSub_DiagLog("InitialPoll: Starting")

    if (!KomorebiSub_IsAvailable()) {
        _KSub_DiagLog("InitialPoll: komorebic not available")
        return
    }

    txt := _KSub_GetStateDirect()
    if (txt = "") {
        _KSub_DiagLog("InitialPoll: Got empty state")
        return
    }

    _KSub_DiagLog("InitialPoll: Got state len=" StrLen(txt))

    ; Parse JSON and update all windows from full state
    stateObj := ""
    try stateObj := JSON.Load(txt)
    if !(stateObj is Map) {
        _KSub_DiagLog("InitialPoll: Failed to parse state JSON")
        return
    }
    _KSub_ProcessFullState(stateObj)
    _KSub_DiagLog("InitialPoll: Complete")
}

; Stop subscription
KomorebiSub_Stop() {
    global _KSub_hPipe, _KSub_hEvent, _KSub_Overlapped, _KSub_Connected, _KSub_ClientPid
    global _KSub_FallbackMode

    ; Stop all timers
    SetTimer(KomorebiSub_Poll, 0)
    SetTimer(_KSub_InitialPoll, 0)  ; Cancel one-shot timer if pending

    ; Stop fallback timer if active
    if (_KSub_FallbackMode) {
        SetTimer(KomorebiSub_PollFallback, 0)
        _KSub_FallbackMode := false
    }

    if (_KSub_ClientPid) {
        try ProcessClose(_KSub_ClientPid)
        _KSub_ClientPid := 0
    }

    if (_KSub_hPipe) {
        try DllCall("DisconnectNamedPipe", "ptr", _KSub_hPipe)
        try DllCall("CloseHandle", "ptr", _KSub_hPipe)
        _KSub_hPipe := 0
    }

    if (_KSub_hEvent) {
        try DllCall("CloseHandle", "ptr", _KSub_hEvent)
        _KSub_hEvent := 0
    }

    _KSub_Overlapped := 0
    _KSub_Connected := false
}

; Prune stale workspace cache entries (called from Store_HeartbeatTick)
; Removes entries older than _KSub_CacheMaxAgeMs to prevent unbounded growth
; RACE FIX: Wrap in Critical - _KSub_ProcessFullState writes to cache on komorebi notifications
KomorebiSub_PruneStaleCache() {
    global _KSub_WorkspaceCache, _KSub_CacheMaxAgeMs
    if (!IsObject(_KSub_WorkspaceCache) || _KSub_WorkspaceCache.Count = 0)
        return

    Critical "On"
    now := A_TickCount
    toDelete := []
    for hwnd, cached in _KSub_WorkspaceCache {
        if ((now - cached.tick) > _KSub_CacheMaxAgeMs)
            toDelete.Push(hwnd)
    }
    for _, hwnd in toDelete
        _KSub_WorkspaceCache.Delete(hwnd)
    Critical "Off"
}

; Poll timer - check connection and read data (non-blocking like POC)
KomorebiSub_Poll() {
    global _KSub_hPipe, _KSub_hEvent, _KSub_Overlapped, _KSub_Connected
    global _KSub_LastEventTick, KSub_IdleRecycleMs, _KSub_ReadBuffer
    static pollCount := 0, lastLogTick := 0

    pollCount++
    ; Log every 5 seconds to avoid spam
    if (A_TickCount - lastLogTick > 5000) {
        _KSub_DiagLog("Poll #" pollCount ": hPipe=" _KSub_hPipe " connected=" _KSub_Connected)
        lastLogTick := A_TickCount
    }

    if (!_KSub_hPipe)
        return

    ; Check if async connect has completed
    if (!_KSub_Connected && _KSub_hEvent) {
        ; Check event with 0 timeout (non-blocking)
        WAIT_OBJECT_0 := 0
        waitRes := DllCall("WaitForSingleObject", "ptr", _KSub_hEvent, "uint", 0, "uint")
        if (waitRes = WAIT_OBJECT_0) {
            ; Event signaled - check overlapped result
            bytes := 0
            ok := DllCall("GetOverlappedResult"
                , "ptr", _KSub_hPipe
                , "ptr", _KSub_Overlapped.Ptr
                , "uint*", &bytes
                , "int", 0  ; don't wait
                , "int")
            if (ok) {
                _KSub_Connected := true
                ; Reset event for future use
                DllCall("ResetEvent", "ptr", _KSub_hEvent)
            }
        }
    }

    if (!_KSub_Connected)
        return

    ; Read available data (non-blocking)
    bytesRead := 0
    loop {
        avail := 0
        ok := DllCall("PeekNamedPipe"
            , "ptr", _KSub_hPipe
            , "ptr", 0, "uint", 0
            , "uint*", 0
            , "uint*", &avail
            , "uint*", 0
            , "int")

        if (!ok) {
            gle := DllCall("GetLastError", "uint")
            if (gle = ERROR_BROKEN_PIPE)  ; Pipe disconnected, restart
                KomorebiSub_Start()
            return
        }

        if (avail = 0)
            break

        toRead := Min(avail, 65536)
        buf := Buffer(toRead, 0)
        read := 0
        ok2 := DllCall("ReadFile"
            , "ptr", _KSub_hPipe
            , "ptr", buf.Ptr
            , "uint", buf.Size
            , "uint*", &read
            , "ptr", 0
            , "int")

        if (!ok2 || read = 0)
            break

        _KSub_LastEventTick := A_TickCount
        chunk := StrGet(buf.Ptr, read, "UTF-8")

        ; Protect against unbounded buffer growth
        ; This prevents OOM when komorebi sends incomplete JSON with opening brace
        if (StrLen(_KSub_ReadBuffer) + StrLen(chunk) > KSUB_BUFFER_MAX_BYTES) {
            _KSub_DiagLog("Buffer overflow protection: reset (was " StrLen(_KSub_ReadBuffer) ")")
            _KSub_ReadBuffer := ""
        }

        _KSub_ReadBuffer .= chunk
        bytesRead += read

        if (bytesRead >= 65536)
            break
    }

    ; Extract complete JSON objects from buffer
    while true {
        json := _KSub_ExtractOneJson(&_KSub_ReadBuffer)
        if (json = "")
            break
        _KSub_DiagLog("Poll: Got notification, len=" StrLen(json))
        _KSub_DiagLog("Poll: Got JSON object, len=" StrLen(json))
        _KSub_OnNotification(json)
    }

    ; Recycle if idle too long
    if ((A_TickCount - _KSub_LastEventTick) > KSub_IdleRecycleMs)
        KomorebiSub_Start()
}

; Check if a quote character at position `pos` is escaped by counting
; consecutive backslashes before it. Even count = not escaped, odd = escaped.
; Used by stream framing (_KSub_ExtractOneJson) only.
_KSub_IsQuoteEscaped(text, pos) {
    if (pos <= 1)
        return false
    backslashCount := 0
    checkPos := pos - 1
    while (checkPos >= 1 && SubStr(text, checkPos, 1) = "\") {
        backslashCount += 1
        checkPos -= 1
    }
    return (Mod(backslashCount, 2) = 1)
}

; Extract one complete JSON object from buffer (balanced braces)
_KSub_ExtractOneJson(&s) {
    if (s = "")
        return ""

    ; Find first '{'
    start := InStr(s, "{")
    if (!start) {
        ; No object start; keep buffer bounded
        if (StrLen(s) > 1000000)
            s := ""
        return ""
    }

    ; Scan for matching closing '}' at depth 0, skipping strings
    i := start
    depth := 0
    inString := false
    len := StrLen(s)

    while (i <= len) {
        ch := SubStr(s, i, 1)
        if (!inString) {
            if (ch = '"') {
                inString := true
            } else if (ch = "{") {
                depth += 1
            } else if (ch = "}") {
                depth -= 1
                if (depth = 0) {
                    obj := SubStr(s, start, i - start + 1)
                    s := SubStr(s, i + 1)
                    return obj
                }
            }
        } else {
            if (ch = '"' && !_KSub_IsQuoteEscaped(s, i))
                inString := false
        }
        i += 1
    }

    ; Incomplete, wait for more data
    return ""
}

; Process a complete notification JSON
_KSub_OnNotification(jsonLine) {
    global _KSub_LastWorkspaceName, _KSub_WorkspaceCache

    _KSub_DiagLog("OnNotification called, len=" StrLen(jsonLine))

    ; Parse the notification JSON once
    parsed := ""
    try parsed := JSON.Load(jsonLine)
    if !(parsed is Map) {
        _KSub_DiagLog("  Failed to parse notification JSON")
        return
    }

    ; Each notification has: { "event": {...}, "state": {...} }
    if (!parsed.Has("state")) {
        _KSub_DiagLog("  No state object found")
        return
    }
    stateObj := parsed["state"]
    if !(stateObj is Map) {
        _KSub_DiagLog("  State is not a Map")
        return
    }

    ; Extract the event object for workspace/cloak tracking
    eventObj := ""
    eventType := ""
    if (parsed.Has("event")) {
        eventObj := parsed["event"]
        if (eventObj is Map)
            eventType := _KSafe_Str(eventObj, "type")
    }

    _KSub_DiagLog("  Event type: '" eventType "'")
    _KSub_DiagLog("Event: " eventType)

    ; Track if we explicitly handled workspace change
    handledWorkspaceEvent := false

    ; Handle workspace focus/move events - update current workspace from event
    ; MoveContainerToWorkspaceNumber: user moved focused window to another workspace (and followed it)
    if (eventType = "FocusMonitorWorkspaceNumber" || eventType = "FocusWorkspaceNumber"
        || eventType = "FocusNamedWorkspace" || eventType = "MoveContainerToWorkspaceNumber"
        || eventType = "MoveContainerToNamedWorkspace") {
        ; content varies by event type:
        ; - FocusMonitorWorkspaceNumber: [monitorIdx, workspaceIdx]
        ; - FocusWorkspaceNumber: [workspaceIdx]
        ; - FocusNamedWorkspace: "WorkspaceName"
        ; - MoveContainerToWorkspaceNumber: workspaceIdx (single number)
        ; - MoveContainerToNamedWorkspace: "WorkspaceName"

        ; With cJson, content is already the correct type (String, Integer, Array, or Map)
        content := ""
        if (eventObj is Map && eventObj.Has("content"))
            content := eventObj["content"]

        _KSub_DiagLog("  FocusWorkspace content type: " Type(content))

        wsName := ""

        if (eventType = "FocusNamedWorkspace" || eventType = "MoveContainerToNamedWorkspace") {
            ; Content is the workspace name directly (string)
            if (content is String)
                wsName := content
            else
                wsName := String(content)
        } else if (eventType = "MoveContainerToWorkspaceNumber") {
            ; Content is the workspace index (integer or possibly in an array)
            wsIdx := -1
            if (content is Integer) {
                wsIdx := content
            } else if (content is Array && content.Length > 0) {
                try wsIdx := Integer(content[1])
            } else if (content != "") {
                try wsIdx := Integer(content)
            }
            _KSub_DiagLog("  MoveContainer wsIdx=" wsIdx)

            if (wsIdx >= 0) {
                ; Use focused monitor (we're moving on current monitor)
                focusedMonIdx := _KSub_GetFocusedMonitorIndex(stateObj)
                monitorsArr := _KSub_GetMonitorsArray(stateObj)
                if (focusedMonIdx >= 0 && monitorsArr.Length > focusedMonIdx) {
                    monObj := monitorsArr[focusedMonIdx + 1]
                    wsName := _KSub_GetWorkspaceNameByIndex(monObj, wsIdx)
                    _KSub_DiagLog("  lookup wsName from focusMon[" focusedMonIdx "] ws[" wsIdx "] = '" wsName "'")
                }
            }
        } else {
            ; FocusMonitorWorkspaceNumber: [monitorIdx, workspaceIdx]
            ; FocusWorkspaceNumber: [workspaceIdx]
            ; Content is already an Array from cJson
            wsIdx := -1
            monIdx := 0
            if (content is Array) {
                _KSub_DiagLog("  content array length: " content.Length)
                if (content.Length >= 2) {
                    monIdx := Integer(content[1])
                    wsIdx := Integer(content[2])
                } else if (content.Length = 1) {
                    wsIdx := Integer(content[1])
                }
            } else if (content is Integer) {
                wsIdx := content
            }

            _KSub_DiagLog("  monIdx=" monIdx " wsIdx=" wsIdx)

            if (wsIdx >= 0) {
                monitorsArr := _KSub_GetMonitorsArray(stateObj)
                _KSub_DiagLog("  monitors count: " monitorsArr.Length)
                if (monitorsArr.Length > monIdx) {
                    ; Use the correct monitor from the event
                    monObj := monitorsArr[monIdx + 1]  ; AHK is 1-based
                    wsName := _KSub_GetWorkspaceNameByIndex(monObj, wsIdx)
                    _KSub_DiagLog("  lookup wsName from mon[" monIdx "] ws[" wsIdx "] = '" wsName "'")
                }
            }
        }

        _KSub_DiagLog("  Focus event resolved wsName='" wsName "'")
        _KSub_DiagLog("  WS event: " eventType " -> '" wsName "'")
        if (wsName != "") {
            global _KSub_LastWorkspaceName, _KSub_LastWsUpdateTick
            ; Capture old workspace BEFORE updating (needed for move events)
            previousWsName := _KSub_LastWorkspaceName

            if (wsName != _KSub_LastWorkspaceName) {
                _KSub_DiagLog("  Updating current workspace to '" wsName "' from focus event")
                _KSub_DiagLog("  CurWS: '" _KSub_LastWorkspaceName "' -> '" wsName "'")
                _KSub_LastWorkspaceName := wsName
                _KSub_LastWsUpdateTick := A_TickCount
                try WindowStore_SetCurrentWorkspace("", wsName)
            }

            ; For MOVE events: DON'T try to explicitly update the moved window here.
            ; The state at this point is inconsistent - Signal has already moved to the TARGET
            ; workspace in the state data, but focus indices on the SOURCE workspace point to
            ; a DIFFERENT window. Any attempt to find "the moved window" will fail.
            ;
            ; Instead, rely on ProcessFullState from subsequent Cloak/Uncloak events which
            ; will have consistent state and correctly update all windows including Signal.
            if (eventType = "MoveContainerToWorkspaceNumber" || eventType = "MoveContainerToNamedWorkspace") {
                _KSub_DiagLog("  Move event: previousWS='" previousWsName "' targetWS='" wsName "' (letting ProcessFullState handle window update)")
            }

            ; Immediately push to clients so they see the workspace change
            try Store_PushToClients()
            handledWorkspaceEvent := true
        }
    }

    ; Handle Cloak/Uncloak events for isCloaked tracking
    if (eventType = "Cloak" || eventType = "Uncloak") {
        if (eventObj is Map && eventObj.Has("content")) {
            contentArr := eventObj["content"]
            ; content = ["ObjectCloaked", { "hwnd": N, ... }]
            ; Iterate the array to find the object with hwnd
            if (contentArr is Array) {
                for _, item in contentArr {
                    if (item is Map && item.Has("hwnd")) {
                        hwnd := _KSafe_Int(item, "hwnd")
                        if (hwnd) {
                            isCloaked := (eventType = "Cloak")
                            try WindowStore_UpdateFields(hwnd, { isCloaked: isCloaked })
                        }
                        break
                    }
                }
            }
        }
    }

    ; Process full state to update ALL windows' workspace info
    ; Skip workspace derivation only for events that already handled it explicitly
    ; (e.g., FocusNamedWorkspace sets CurWS from event content).
    ; Non-workspace events (FocusChange, Cloak, Uncloak) derive workspace from
    ; state's ring.focused, which catches external workspace switches like
    ; notification clicks that don't fire explicit workspace events.
    _KSub_ProcessFullState(stateObj, handledWorkspaceEvent)

    ; Push changes to clients after ProcessFullState updates windows
    ; This ensures clients see workspace assignments from the komorebi state
    try Store_PushToClients()
}

; Process full komorebi state and update all windows
; stateObj: parsed Map from cJson (NOT raw text)
; skipWorkspaceUpdate: set to true when called after a focus event (notification already handled workspace)
_KSub_ProcessFullState(stateObj, skipWorkspaceUpdate := false) {
    global gWS_Store, _KSub_LastWorkspaceName, _KSub_WorkspaceCache, _KSub_LastWsUpdateTick

    if !(stateObj is Map)
        return

    ; Cooldown: after any workspace update (explicit or state-derived), skip re-derivation
    ; for 2 seconds. Workspace switches produce bursts of 6-8 Cloak/Uncloak events that
    ; each run expensive state parsing to arrive at the same workspace — pure waste.
    ; The first event in a burst detects the change; subsequent events reuse the cached value.
    if (!skipWorkspaceUpdate && _KSub_LastWsUpdateTick > 0
        && A_TickCount - _KSub_LastWsUpdateTick < 2000) {
        skipWorkspaceUpdate := true
        _KSub_DiagLog("ProcessFullState: skip=cooldown (ws updated " (A_TickCount - _KSub_LastWsUpdateTick) "ms ago)")
    }

    monitorsArr := _KSub_GetMonitorsArray(stateObj)

    if (monitorsArr.Length = 0)
        return

    ; Get current workspace name for window tagging
    ; When skipWorkspaceUpdate=true, use _KSub_LastWorkspaceName (already set by focus event)
    ; Otherwise calculate from state
    currentWsName := ""
    focusedWsIdx := "N/A"
    focusedMonIdx := -1
    if (skipWorkspaceUpdate) {
        ; Trust the value already set by focus event handler or cooldown cache
        currentWsName := _KSub_LastWorkspaceName
    } else {
        focusedMonIdx := _KSub_GetFocusedMonitorIndex(stateObj)
        if (focusedMonIdx >= 0 && focusedMonIdx < monitorsArr.Length) {
            monObj := monitorsArr[focusedMonIdx + 1]  ; AHK 1-based
            focusedWsIdx := _KSub_GetFocusedWorkspaceIndex(monObj)
            currentWsName := _KSub_GetWorkspaceNameByIndex(monObj, focusedWsIdx)
        }
    }

    _KSub_DiagLog("ProcessState: mon=" focusedMonIdx " wsIdx=" focusedWsIdx " curWS='" currentWsName "' lastWS='" _KSub_LastWorkspaceName "' skip=" skipWorkspaceUpdate)

    ; Only update current workspace if not skipping (initial poll or direct state query)
    ; Skip if called from notification handler since focus events already update workspace
    if (!skipWorkspaceUpdate && currentWsName != "" && currentWsName != _KSub_LastWorkspaceName) {
        _KSub_DiagLog("  WS change via state: '" _KSub_LastWorkspaceName "' -> '" currentWsName "'")
        _KSub_LastWorkspaceName := currentWsName
        _KSub_LastWsUpdateTick := A_TickCount
        try WindowStore_SetCurrentWorkspace("", currentWsName)
    }

    ; Build map of ALL windows to their workspaces from komorebi state
    ; Only stores wsName/isCurrent/winObj — title/class/exe extracted lazily
    ; in the "add to store" branch (uncommon path) to avoid wasted work
    wsMap := Map()  ; hwnd -> { wsName, isCurrent, winObj }
    now := A_TickCount

    for mi, monObj in monitorsArr {
        wsArr := _KSub_GetWorkspacesArray(monObj)
        for wi, wsObj in wsArr {
            if !(wsObj is Map)
                continue
            wsName := _KSafe_Str(wsObj, "name")
            if (wsName = "")
                continue

            ; Determine if this is the current workspace
            isCurrentWs := (wsName = currentWsName)

            ; Get all containers in this workspace
            if (!wsObj.Has("containers"))
                continue
            containersRing := wsObj["containers"]
            contArr := _KSafe_Elements(containersRing)

            ; Iterate containers -> windows to find all hwnds
            for _, cont in contArr {
                if !(cont is Map)
                    continue

                ; Check windows ring in this container
                if (cont.Has("windows")) {
                    for _, win in _KSafe_Elements(cont["windows"]) {
                        if !(win is Map) || !win.Has("hwnd")
                            continue
                        hwnd := _KSafe_Int(win, "hwnd")
                        if (!hwnd)
                            continue

                        wsMap[hwnd] := { wsName: wsName, isCurrent: isCurrentWs, winObj: win }
                        ; Update cache: refresh tick in place if wsName unchanged, else new entry
                        if (_KSub_WorkspaceCache.Has(hwnd) && _KSub_WorkspaceCache[hwnd].wsName = wsName)
                            _KSub_WorkspaceCache[hwnd].tick := now
                        else
                            _KSub_WorkspaceCache[hwnd] := { wsName: wsName, tick: now }
                    }
                }

                ; Single window container ("window" key directly)
                if (cont.Has("window")) {
                    winObj := cont["window"]
                    if (winObj is Map && winObj.Has("hwnd")) {
                        hwnd := _KSafe_Int(winObj, "hwnd")
                        if (hwnd && !wsMap.Has(hwnd)) {
                            wsMap[hwnd] := { wsName: wsName, isCurrent: isCurrentWs, winObj: winObj }
                            if (_KSub_WorkspaceCache.Has(hwnd) && _KSub_WorkspaceCache[hwnd].wsName = wsName)
                                _KSub_WorkspaceCache[hwnd].tick := now
                            else
                                _KSub_WorkspaceCache[hwnd] := { wsName: wsName, tick: now }
                        }
                    }
                }
            }

            ; Also check monocle_container
            if (wsObj.Has("monocle_container")) {
                mono := wsObj["monocle_container"]
                if (mono is Map) {
                    ; Monocle may have windows ring
                    if (mono.Has("windows")) {
                        for _, win in _KSafe_Elements(mono["windows"]) {
                            if !(win is Map) || !win.Has("hwnd")
                                continue
                            hwnd := _KSafe_Int(win, "hwnd")
                            if (hwnd && !wsMap.Has(hwnd)) {
                                wsMap[hwnd] := { wsName: wsName, isCurrent: isCurrentWs, winObj: win }
                                if (_KSub_WorkspaceCache.Has(hwnd) && _KSub_WorkspaceCache[hwnd].wsName = wsName)
                                    _KSub_WorkspaceCache[hwnd].tick := now
                                else
                                    _KSub_WorkspaceCache[hwnd] := { wsName: wsName, tick: now }
                            }
                        }
                    }
                    ; Monocle may have single "window"
                    if (mono.Has("window")) {
                        winObj := mono["window"]
                        if (winObj is Map && winObj.Has("hwnd")) {
                            hwnd := _KSafe_Int(winObj, "hwnd")
                            if (hwnd && !wsMap.Has(hwnd)) {
                                wsMap[hwnd] := { wsName: wsName, isCurrent: isCurrentWs, winObj: winObj }
                                if (_KSub_WorkspaceCache.Has(hwnd) && _KSub_WorkspaceCache[hwnd].wsName = wsName)
                                    _KSub_WorkspaceCache[hwnd].tick := now
                                else
                                    _KSub_WorkspaceCache[hwnd] := { wsName: wsName, tick: now }
                            }
                        }
                    }
                }
            }
        }
    }

    ; Update/insert ALL windows from komorebi state
    if (!IsSet(gWS_Store)) {
        _KSub_DiagLog("ProcessFullState: gWS_Store not set, returning")
        return
    }

    _KSub_DiagLog("ProcessFullState: wsMap has " wsMap.Count " windows, gWS_Store has " gWS_Store.Count " windows")

    addedCount := 0
    updatedCount := 0
    skippedIneligible := 0
    for hwnd, info in wsMap {
        ; Check if window exists in store
        if (!gWS_Store.Has(hwnd)) {
            ; Window not in store - add it!
            ; This happens for windows on other workspaces that winenum didn't see
            ; Extract title/class/exe lazily — only needed for new windows
            kTitle := _KSafe_Str(info.winObj, "title")
            kClass := _KSafe_Str(info.winObj, "class")
            title := (kTitle != "") ? kTitle : _KSub_GetWindowTitle(hwnd)
            class := (kClass != "") ? kClass : _KSub_GetWindowClass(hwnd)

            ; Use centralized eligibility check (Alt-Tab rules + blacklist)
            if (!Blacklist_IsWindowEligible(hwnd, title, class)) {
                skippedIneligible++
                continue
            }

            rec := Map()
            rec["hwnd"] := hwnd
            rec["title"] := title
            rec["class"] := class
            rec["pid"] := _KSub_GetWindowPid(hwnd)
            rec["z"] := 9999  ; Put at end of z-order
            rec["altTabEligible"] := true  ; Komorebi windows are eligible
            rec["isCloaked"] := !info.isCurrent  ; Not on current workspace = cloaked
            rec["isMinimized"] := false
            rec["isVisible"] := info.isCurrent
            rec["workspaceName"] := info.wsName
            rec["isOnCurrentWorkspace"] := info.isCurrent

            try WindowStore_UpsertWindow([rec])
            addedCount++
        } else {
            ; Window exists - update workspace info
            try WindowStore_UpdateFields(hwnd, {
                workspaceName: info.wsName,
                isOnCurrentWorkspace: info.isCurrent,
                isCloaked: !info.isCurrent
            })
            updatedCount++
        }
    }
    _KSub_DiagLog("ProcessFullState: added " addedCount " updated " updatedCount " skipped(ineligible) " skippedIneligible)

    ; Also update windows in store that aren't in komorebi state
    ; (they might have cached workspace data)
    ; Uses timestamped cache entries to avoid using stale data
    if (IsObject(gWS_Store)) {
        now := A_TickCount

        ; Snapshot hwnds to prevent iteration-during-modification race
        hwnds := _WS_SnapshotMapKeys(gWS_Store)

        for _, hwnd in hwnds {
            ; Guard: window may have been removed between snapshot and processing
            if (!gWS_Store.Has(hwnd))
                continue
            if (!wsMap.Has(hwnd) && _KSub_WorkspaceCache.Has(hwnd)) {
                cached := _KSub_WorkspaceCache[hwnd]
                ; Check cache staleness - entries older than _KSub_CacheMaxAgeMs are skipped
                if ((now - cached.tick) > _KSub_CacheMaxAgeMs) {
                    _KSub_WorkspaceCache.Delete(hwnd)  ; Clean up stale entry
                    continue
                }
                wsName := cached.wsName
                isCurrent := (wsName = _KSub_LastWorkspaceName)
                try WindowStore_UpdateFields(hwnd, {
                    workspaceName: wsName,
                    isOnCurrentWorkspace: isCurrent
                })
            }
        }
    }
}

; Get window title via Win API
_KSub_GetWindowTitle(hwnd) {
    try {
        return WinGetTitle("ahk_id " hwnd)
    }
    return ""
}

; Get window class via Win API
_KSub_GetWindowClass(hwnd) {
    try {
        return WinGetClass("ahk_id " hwnd)
    }
    return ""
}

; Get window PID via Win API (works on cloaked windows too)
_KSub_GetWindowPid(hwnd) {
    ; Use GetWindowThreadProcessId - works on any valid hwnd including cloaked
    pid := 0
    DllCall("user32\GetWindowThreadProcessId", "ptr", hwnd, "uint*", &pid)
    return pid
}

; Fallback polling mode (when subscription fails)
KomorebiSub_PollFallback() {
    if (!KomorebiSub_IsAvailable())
        return

    txt := _KSub_GetStateDirect()
    if (txt = "")
        return

    ; Parse JSON before passing to ProcessFullState (expects parsed Map)
    stateObj := ""
    try stateObj := JSON.Load(txt)
    if !(stateObj is Map)
        return
    _KSub_ProcessFullState(stateObj)
}

; Get komorebi state directly via command
_KSub_GetStateDirect() {
    global cfg
    tmp := A_Temp "\komorebi_state_" A_TickCount ".tmp"
    ; Use double-quote escaping for cmd.exe with paths containing spaces
    cmd := 'cmd.exe /c ""' cfg.KomorebicExe '" state > "' tmp '"" 2>&1'
    try RunWait(cmd, , "Hide")
    Sleep(100)  ; Give file time to write
    txt := ""
    try txt := FileRead(tmp, "UTF-8")
    try FileDelete(tmp)
    return txt
}

; ============================================================
; Security Helpers
; ============================================================

; Create SECURITY_ATTRIBUTES with NULL DACL to allow non-elevated processes to connect
; This is needed when running as administrator - otherwise komorebic (non-elevated) can't connect
_KSub_CreateOpenSecurityAttrs() {
    ; Use static buffers so they persist for the lifetime of the pipe
    static pSD := 0
    static pSA := 0

    ; SECURITY_DESCRIPTOR size: 20 bytes (32-bit) or 40 bytes (64-bit)
    ; Using 40 to be safe
    if (!pSD) {
        pSD := Buffer(40, 0)

        ; Initialize security descriptor
        ; SECURITY_DESCRIPTOR_REVISION = 1
        ok := DllCall("advapi32\InitializeSecurityDescriptor"
            , "ptr", pSD.Ptr
            , "uint", 1  ; SECURITY_DESCRIPTOR_REVISION
            , "int")

        if (!ok) {
            _KSub_DiagLog("InitializeSecurityDescriptor failed: " A_LastError)
            return 0
        }

        ; Set NULL DACL (grants full access to everyone)
        ; SetSecurityDescriptorDacl(pSD, bDaclPresent=TRUE, pDacl=NULL, bDaclDefaulted=FALSE)
        ok := DllCall("advapi32\SetSecurityDescriptorDacl"
            , "ptr", pSD.Ptr
            , "int", 1    ; bDaclPresent = TRUE (DACL is present)
            , "ptr", 0    ; pDacl = NULL (NULL DACL = allow all access)
            , "int", 0    ; bDaclDefaulted = FALSE
            , "int")

        if (!ok) {
            _KSub_DiagLog("SetSecurityDescriptorDacl failed: " A_LastError)
            return 0
        }
    }

    ; Create SECURITY_ATTRIBUTES structure
    ; struct SECURITY_ATTRIBUTES {
    ;   DWORD  nLength;              // offset 0, size 4
    ;   LPVOID lpSecurityDescriptor; // offset 4 (32-bit) or 8 (64-bit), size 4/8
    ;   BOOL   bInheritHandle;       // offset 8 (32-bit) or 16 (64-bit), size 4
    ; }
    if (!pSA) {
        saSize := (A_PtrSize = 8) ? 24 : 12
        pSA := Buffer(saSize, 0)

        ; nLength
        NumPut("uint", saSize, pSA, 0)
        ; lpSecurityDescriptor (at offset A_PtrSize due to alignment)
        NumPut("ptr", pSD.Ptr, pSA, A_PtrSize)
        ; bInheritHandle (at offset A_PtrSize + A_PtrSize)
        NumPut("int", 0, pSA, A_PtrSize * 2)
    }

    _KSub_DiagLog("Created NULL DACL security attributes")
    return pSA.Ptr
}
