#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Expected: file is included after windowstore.ahk

; ============================================================
; Komorebi Subscription Producer
; ============================================================
; Event-driven komorebi integration using named pipe subscription
; Each subscription notification includes FULL state - we use this
; to update ALL windows' workspace assignments on every event.
;
; Based on working POC: legacy/components_legacy/komorebi_poc - WORKING.ahk
; ============================================================

; Configuration (use values from config.ahk if set, otherwise defaults)
; Note: KomorebicExe is set in config.ahk, we just reference it here
global KSub_PollMs := IsSet(KomorebiSubPollMs) ? KomorebiSubPollMs : 50
global KSub_IdleRecycleMs := IsSet(KomorebiSubIdleRecycleMs) ? KomorebiSubIdleRecycleMs : 120000
global KSub_FallbackPollMs := IsSet(KomorebiSubFallbackPollMs) ? KomorebiSubFallbackPollMs : 2000

; State
global _KSub_PipeName := ""
global _KSub_hPipe := 0
global _KSub_hEvent := 0
global _KSub_Over := 0
global _KSub_Connected := false
global _KSub_ClientPid := 0
global _KSub_LastEvent := 0
global _KSub_Buf := ""
global _KSub_LastWorkspaceName := ""
global _KSub_FallbackMode := false

; Cache of window workspace assignments (persists even when windows leave komorebi)
global _KSub_WorkspaceCache := Map()

; Initialize komorebi subscription
KomorebiSub_Init() {
    global _KSub_PipeName, _KSub_WorkspaceCache
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
    global KomorebicExe
    return (KomorebicExe != "" && FileExist(KomorebicExe))
}

; Start subscription
KomorebiSub_Start() {
    global _KSub_PipeName, _KSub_hPipe, _KSub_hEvent, _KSub_Over
    global _KSub_Connected, _KSub_ClientPid, _KSub_LastEvent, _KSub_FallbackMode

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
    _KSub_Over := Buffer(overSize, 0)
    NumPut("ptr", _KSub_hEvent, _KSub_Over, (A_PtrSize = 8) ? 24 : 16)

    ; Begin async connect (non-blocking)
    ok := DllCall("ConnectNamedPipe", "ptr", _KSub_hPipe, "ptr", _KSub_Over.Ptr, "int")
    if (!ok) {
        gle := DllCall("GetLastError", "uint")
        if (gle = 997)        ; ERROR_IO_PENDING - async in progress
            _KSub_Connected := false
        else if (gle = 535)   ; ERROR_PIPE_CONNECTED - already connected
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
        cmd := '"' KomorebicExe '" subscribe-pipe ' _KSub_PipeName
        _KSub_ClientPid := Run(cmd, , "Hide")
        _KSub_DiagLog("KomorebiSub: Launched subscriber pid=" _KSub_ClientPid " cmd=" cmd)
    } catch as e {
        _KSub_DiagLog("KomorebiSub: Failed to launch subscriber: " e.Message)
        ; Keep server alive, client may connect later
    }

    _KSub_LastEvent := A_TickCount
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
    global DiagKomorebiLog
    if (!IsSet(DiagKomorebiLog) || !DiagKomorebiLog)
        return
    static logPath := A_Temp "\tabby_ksub_diag.log"
    try FileAppend(FormatTime(, "HH:mm:ss") " " msg "`n", logPath, "UTF-8")
}

; One-time initial poll to populate workspace data on startup
_KSub_InitialPoll() {
    global _KSub_LastWorkspaceName

    _KSub_Log("InitialPoll: Starting")

    if (!KomorebiSub_IsAvailable()) {
        _KSub_Log("InitialPoll: komorebic not available")
        return
    }

    txt := _KSub_GetStateDirect()
    if (txt = "") {
        _KSub_Log("InitialPoll: Got empty state")
        return
    }

    _KSub_Log("InitialPoll: Got state len=" StrLen(txt))

    ; Update all windows from full state
    _KSub_ProcessFullState(txt)
    _KSub_Log("InitialPoll: Complete")
}

; Stop subscription
KomorebiSub_Stop() {
    global _KSub_hPipe, _KSub_hEvent, _KSub_Over, _KSub_Connected, _KSub_ClientPid

    SetTimer(KomorebiSub_Poll, 0)

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

    _KSub_Over := 0
    _KSub_Connected := false
}

; Poll timer - check connection and read data (non-blocking like POC)
KomorebiSub_Poll() {
    global _KSub_hPipe, _KSub_hEvent, _KSub_Over, _KSub_Connected
    global _KSub_LastEvent, KSub_IdleRecycleMs, _KSub_Buf
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
                , "ptr", _KSub_Over.Ptr
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
            if (gle = 109)  ; ERROR_BROKEN_PIPE
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

        _KSub_LastEvent := A_TickCount
        chunk := StrGet(buf.Ptr, read, "UTF-8")
        _KSub_Buf .= chunk
        bytesRead += read

        if (bytesRead >= 65536)
            break
    }

    ; Extract complete JSON objects from buffer
    while true {
        json := _KSub_ExtractOneJson(&_KSub_Buf)
        if (json = "")
            break
        _KSub_DiagLog("Poll: Got notification, len=" StrLen(json))
        _KSub_Log("Poll: Got JSON object, len=" StrLen(json))
        _KSub_OnNotification(json)
    }

    ; Recycle if idle too long
    if ((A_TickCount - _KSub_LastEvent) > KSub_IdleRecycleMs)
        KomorebiSub_Start()
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
            if (ch = '"' && SubStr(s, i - 1, 1) != "\")
                inString := false
        }
        i += 1
    }

    ; Incomplete, wait for more data
    return ""
}

; Debug log for komorebi subscription (disabled by default)
global _KSub_DebugLog := ""  ; Set to A_Temp "\ksub_debug.log" to enable

_KSub_Log(msg) {
    global _KSub_DebugLog
    if (_KSub_DebugLog = "")
        return
    try FileAppend(FormatTime(, "HH:mm:ss") " " msg "`n", _KSub_DebugLog, "UTF-8")
}

; Process a complete notification JSON
_KSub_OnNotification(jsonLine) {
    global _KSub_LastWorkspaceName, _KSub_WorkspaceCache

    _KSub_Log("OnNotification called, len=" StrLen(jsonLine))

    ; Each notification has: { "event": {...}, "state": {...} }
    ; The state contains the FULL komorebi state - use it!

    ; Extract the state object
    stateObj := _KSub_ExtractObjectByKey(jsonLine, "state")
    if (stateObj = "") {
        _KSub_Log("  No state object found")
        return  ; No state, skip
    }
    _KSub_Log("  State object len=" StrLen(stateObj))

    ; Extract the event object for workspace/cloak tracking
    eventObj := _KSub_ExtractObjectByKey(jsonLine, "event")
    eventType := ""
    if (eventObj != "")
        eventType := _KSub_GetStringProp(eventObj, "type")

    _KSub_Log("  Event type: '" eventType "'")
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

        ; Try multiple extraction methods like the POC does
        contentRaw := _KSub_ExtractContentRaw(eventObj)

        _KSub_Log("  FocusWorkspace content: " contentRaw)
        _KSub_DiagLog("  content raw: '" contentRaw "'")

        ; Debug: always show event structure for workspace events
        if (StrLen(eventObj) > 0) {
            ; Show full event if small, otherwise snippet
            if (StrLen(eventObj) <= 500)
                _KSub_DiagLog("  eventObj: " eventObj)
            else {
                snippet := SubStr(eventObj, 1, 400)
                _KSub_DiagLog("  eventObj snippet: " snippet)
            }
        }

        wsName := ""

        if (eventType = "FocusNamedWorkspace" || eventType = "MoveContainerToNamedWorkspace") {
            ; Content is the workspace name directly
            wsName := Trim(contentRaw, '" ')
        } else if (eventType = "MoveContainerToWorkspaceNumber") {
            ; Content is just the workspace index (single number, not array)
            ; Try to extract as plain number first
            wsIdx := -1
            if (contentRaw != "") {
                ; Remove brackets if present
                cleaned := RegExReplace(contentRaw, "[\[\]]", "")
                cleaned := Trim(cleaned)
                if (cleaned != "")
                    wsIdx := Integer(cleaned)
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
            parts := _KSub_ArrayTopLevelSplit(contentRaw)
            _KSub_DiagLog("  parts count: " parts.Length)
            for i, p in parts
                _KSub_DiagLog("    parts[" i "]: '" p "'")

            wsIdx := -1
            monIdx := 0
            if (parts.Length >= 2) {
                monIdx := Integer(Trim(parts[1]))
                wsIdx := Integer(Trim(parts[2]))
            } else if (parts.Length = 1) {
                wsIdx := Integer(Trim(parts[1]))
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

        _KSub_Log("  Focus event resolved wsName='" wsName "'")
        _KSub_DiagLog("  WS event: " eventType " -> '" wsName "'")
        if (wsName != "") {
            global _KSub_LastWorkspaceName
            ; Capture old workspace BEFORE updating (needed for move events)
            previousWsName := _KSub_LastWorkspaceName

            if (wsName != _KSub_LastWorkspaceName) {
                _KSub_Log("  Updating current workspace to '" wsName "' from focus event")
                _KSub_DiagLog("  CurWS: '" _KSub_LastWorkspaceName "' -> '" wsName "'")
                _KSub_LastWorkspaceName := wsName
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
        contentArr := _KSub_ExtractArrayByKey(eventObj, "content")
        if (contentArr != "") {
            ; content = ["ObjectCloaked", { "hwnd": N, ... }]
            ; Extract the hwnd from the object in the array
            hwndMatch := 0
            if RegExMatch(contentArr, '"hwnd"\s*:\s*(\d+)', &hwndMatch) {
                hwnd := Integer(hwndMatch[1])
                isCloaked := (eventType = "Cloak")
                try WindowStore_UpdateFields(hwnd, { isCloaked: isCloaked })
            }
        }
    }

    ; Process full state to update ALL windows' workspace info
    ; ALWAYS skip workspace update from notifications - the state's focused workspace index
    ; can be stale (not yet updated by komorebi). Trust explicit workspace events only.
    ; Workspace is derived from state only during initial poll (_KSub_InitialPoll).
    _KSub_ProcessFullState(stateObj, true)

    ; Push changes to clients after ProcessFullState updates windows
    ; This ensures clients see workspace assignments from the komorebi state
    try Store_PushToClients()
}

; Process full komorebi state and update all windows
; skipWorkspaceUpdate: set to true when called after a focus event (notification already handled workspace)
_KSub_ProcessFullState(stateText, skipWorkspaceUpdate := false) {
    global gWS_Store, _KSub_LastWorkspaceName, _KSub_WorkspaceCache

    if (stateText = "")
        return

    ; Get focused monitor and workspace
    focusedMonIdx := _KSub_GetFocusedMonitorIndex(stateText)
    monitorsArr := _KSub_GetMonitorsArray(stateText)

    if (monitorsArr.Length = 0)
        return

    ; Get current workspace name for window tagging
    ; When skipWorkspaceUpdate=true, use _KSub_LastWorkspaceName (already set by focus event)
    ; Otherwise calculate from state
    currentWsName := ""
    if (skipWorkspaceUpdate) {
        ; Trust the value already set by focus event handler
        currentWsName := _KSub_LastWorkspaceName
    } else if (focusedMonIdx >= 0 && focusedMonIdx < monitorsArr.Length) {
        monObj := monitorsArr[focusedMonIdx + 1]  ; AHK 1-based
        focusedWsIdx := _KSub_GetFocusedWorkspaceIndex(monObj)
        currentWsName := _KSub_GetWorkspaceNameByIndex(monObj, focusedWsIdx)
    }

    wsIdxLog := (IsSet(focusedWsIdx) ? focusedWsIdx : "N/A")
    _KSub_Log("ProcessFullState: focusedMon=" focusedMonIdx " focusedWs=" wsIdxLog " currentWsName='" currentWsName "' lastWsName='" _KSub_LastWorkspaceName "' skipWsUpdate=" skipWorkspaceUpdate)
    _KSub_DiagLog("ProcessState: mon=" focusedMonIdx " wsIdx=" wsIdxLog " curWS='" currentWsName "' lastWS='" _KSub_LastWorkspaceName "' skip=" skipWorkspaceUpdate)

    ; Extra debug: if not skipping, show why we derived this workspace
    if (!skipWorkspaceUpdate && focusedMonIdx >= 0 && monitorsArr.Length > 0) {
        monObj := monitorsArr[focusedMonIdx + 1]
        ring := _KSub_GetWorkspacesRing(monObj)
        ringFocused := _KSub_GetIntProp(ring, "focused")
        _KSub_DiagLog("  state ring.focused=" ringFocused)
    }

    ; Only update current workspace if not skipping (initial poll or direct state query)
    ; Skip if called from notification handler since focus events already update workspace
    if (!skipWorkspaceUpdate && currentWsName != "" && currentWsName != _KSub_LastWorkspaceName) {
        _KSub_Log("  Updating workspace from '" _KSub_LastWorkspaceName "' to '" currentWsName "'")
        _KSub_DiagLog("  WS change via state: '" _KSub_LastWorkspaceName "' -> '" currentWsName "'")
        _KSub_LastWorkspaceName := currentWsName
        try WindowStore_SetCurrentWorkspace("", currentWsName)
    }

    ; Build map of ALL windows to their workspaces from komorebi state
    ; AND collect window metadata for any windows not in store
    wsMap := Map()  ; hwnd -> { wsName, title, class, exe }

    for mi, monObj in monitorsArr {
        wsArr := _KSub_GetWorkspacesArray(monObj)
        for wi, wsObj in wsArr {
            wsName := _KSub_GetStringProp(wsObj, "name")
            if (wsName = "")
                continue

            ; Determine if this is the current workspace
            isCurrentWs := (wsName = currentWsName)

            ; Get all containers in this workspace
            containersText := _KSub_ExtractObjectByKey(wsObj, "containers")
            if (containersText = "")
                continue

            ; Find all windows in the containers
            pos := 1
            while (p := RegExMatch(containersText, '"hwnd"\s*:\s*(\d+)', &hwndMatch, pos)) {
                hwnd := Integer(hwndMatch[1])

                ; Get window metadata from komorebi state
                ; Find the container object for this hwnd
                containerStart := _KSub_FindContainerForHwnd(containersText, hwnd)
                if (containerStart > 0) {
                    containerObj := _KSub_BalancedObjectFrom(containersText, containerStart)
                    windowObj := _KSub_ExtractObjectByKey(containerObj, "window")
                    if (windowObj = "")
                        windowObj := containerObj

                    title := _KSub_GetStringProp(windowObj, "title")
                    class := _KSub_GetStringProp(windowObj, "class")
                    exe := _KSub_GetStringProp(windowObj, "exe")

                    wsMap[hwnd] := {
                        wsName: wsName,
                        title: title,
                        class: class,
                        exe: exe,
                        isCurrent: isCurrentWs
                    }
                } else {
                    wsMap[hwnd] := {
                        wsName: wsName,
                        title: "",
                        class: "",
                        exe: "",
                        isCurrent: isCurrentWs
                    }
                }

                ; Cache for persistence
                _KSub_WorkspaceCache[hwnd] := wsName

                pos := hwndMatch.Pos(0) + hwndMatch.Len(0)
            }
        }
    }

    ; Update/insert ALL windows from komorebi state
    if (!IsSet(gWS_Store)) {
        _KSub_Log("ProcessFullState: gWS_Store not set, returning")
        return
    }

    _KSub_Log("ProcessFullState: wsMap has " wsMap.Count " windows, gWS_Store has " gWS_Store.Count " windows")

    addedCount := 0
    updatedCount := 0
    skippedIneligible := 0
    for hwnd, info in wsMap {
        ; Check if window exists in store
        if (!gWS_Store.Has(hwnd)) {
            ; Window not in store - add it!
            ; This happens for windows on other workspaces that winenum didn't see
            title := (info.title != "") ? info.title : _KSub_GetWindowTitle(hwnd)
            class := (info.class != "") ? info.class : _KSub_GetWindowClass(hwnd)

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
    _KSub_Log("ProcessFullState: added " addedCount " updated " updatedCount " skipped(ineligible) " skippedIneligible)

    ; Also update windows in store that aren't in komorebi state
    ; (they might have cached workspace data)
    if (IsObject(gWS_Store)) {
        for hwnd, rec in gWS_Store {
            if (!wsMap.Has(hwnd) && _KSub_WorkspaceCache.Has(hwnd)) {
                wsName := _KSub_WorkspaceCache[hwnd]
                isCurrent := (wsName = _KSub_LastWorkspaceName)
                try WindowStore_UpdateFields(hwnd, {
                    workspaceName: wsName,
                    isOnCurrentWorkspace: isCurrent
                })
            }
        }
    }
}

; Find the start of a container object containing the given hwnd
_KSub_FindContainerForHwnd(containersText, hwnd) {
    ; Find "hwnd": <hwnd> in the text
    pat := '"hwnd"\s*:\s*' hwnd '\b'
    if !RegExMatch(containersText, pat, &m)
        return 0

    ; Scan backwards to find the enclosing '{'
    pos := m.Pos(0)
    depth := 0
    i := pos
    while (i > 1) {
        ch := SubStr(containersText, i, 1)
        if (ch = "}") {
            depth++
        } else if (ch = "{") {
            if (depth = 0)
                return i
            depth--
        }
        i--
    }
    return 0
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

    _KSub_ProcessFullState(txt)
}

; Get komorebi state directly via command
_KSub_GetStateDirect() {
    global KomorebicExe
    tmp := A_Temp "\komorebi_state_" A_TickCount ".tmp"
    ; Use double-quote escaping for cmd.exe with paths containing spaces
    cmd := 'cmd.exe /c ""' KomorebicExe '" state > "' tmp '"" 2>&1'
    try RunWait(cmd, , "Hide")
    Sleep(100)  ; Give file time to write
    txt := ""
    try txt := FileRead(tmp, "UTF-8")
    try FileDelete(tmp)
    return txt
}

; ============================================================
; JSON Extraction Helpers (from working POC)
; ============================================================

_KSub_ExtractObjectByKey(text, key) {
    ; Returns the balanced {...} value for "key": { ... }
    pat := '(?s)"' key '"\s*:\s*\{'
    m := 0
    if !RegExMatch(text, pat, &m)
        return ""
    start := m.Pos(0) + m.Len(0) - 1  ; at '{'
    return _KSub_BalancedObjectFrom(text, start)
}

; Extract "content" field from event - tries array, string, number, then object
; Based on POC's _GetEventContentRaw which handles all komorebi content formats
_KSub_ExtractContentRaw(evtText) {
    ; Try array first: "content": [...]
    arr := _KSub_ExtractArrayByKey(evtText, "content")
    if (arr != "") {
        _KSub_DiagLog("    ExtractContent: found array")
        return arr
    }

    ; Try quoted string: "content": "value"
    m := 0
    if RegExMatch(evtText, '(?s)"content"\s*:\s*"((?:\\.|[^"])*)"', &m) {
        _KSub_DiagLog("    ExtractContent: found string")
        return m[1]  ; Return unquoted for consistency
    }

    ; Try integer: "content": 123
    m := 0
    if RegExMatch(evtText, '(?s)"content"\s*:\s*(-?\d+)', &m) {
        _KSub_DiagLog("    ExtractContent: found integer=" m[1])
        return m[1]
    }

    ; Try object: "content": {...}
    ; This handles SocketMessage format where content is {EventType: value}
    obj := _KSub_ExtractObjectByKey(evtText, "content")
    if (obj != "") {
        _KSub_DiagLog("    ExtractContent: found object, extracting value")
        ; Try to extract the workspace index from within the object
        ; e.g., {"MoveContainerToWorkspaceNumber": 1} -> extract 1
        m := 0
        ; Look for any numeric value in the object
        if RegExMatch(obj, ':\s*(-?\d+)', &m)
            return m[1]
        ; Look for any string value
        if RegExMatch(obj, ':\s*"([^"]*)"', &m)
            return m[1]
        ; Return the whole object as fallback
        return obj
    }

    _KSub_DiagLog("    ExtractContent: no content found")
    return ""
}

_KSub_ExtractArrayByKey(text, key) {
    pat := '(?s)"' key '"\s*:\s*\['
    m := 0
    if !RegExMatch(text, pat, &m)
        return ""
    start := m.Pos(0) + m.Len(0) - 1  ; at '['
    return _KSub_BalancedArrayFrom(text, start)
}

_KSub_BalancedObjectFrom(text, bracePos) {
    ; bracePos points to '{'
    i := bracePos
    depth := 0
    inString := false
    len := StrLen(text)

    while (i <= len) {
        ch := SubStr(text, i, 1)
        if (!inString) {
            if (ch = '"') {
                inString := true
            } else if (ch = "{") {
                depth += 1
            } else if (ch = "}") {
                depth -= 1
                if (depth = 0)
                    return SubStr(text, bracePos, i - bracePos + 1)
            }
        } else {
            if (ch = '"' && SubStr(text, i - 1, 1) != "\")
                inString := false
        }
        i += 1
    }
    return ""
}

_KSub_BalancedArrayFrom(text, brackPos) {
    ; brackPos points to '['
    i := brackPos
    depth := 0
    inString := false
    len := StrLen(text)

    while (i <= len) {
        ch := SubStr(text, i, 1)
        if (!inString) {
            if (ch = '"') {
                inString := true
            } else if (ch = "[") {
                depth += 1
            } else if (ch = "]") {
                depth -= 1
                if (depth = 0)
                    return SubStr(text, brackPos, i - brackPos + 1)
            }
        } else {
            if (ch = '"' && SubStr(text, i - 1, 1) != "\")
                inString := false
        }
        i += 1
    }
    return ""
}

_KSub_GetStringProp(objText, key) {
    m := 0
    if RegExMatch(objText, '(?s)"' key '"\s*:\s*"((?:\\.|[^"])*)"', &m)
        return _KSub_UnescapeJson(m[1])
    return ""
}

_KSub_GetIntProp(objText, key) {
    m := 0
    if RegExMatch(objText, '(?s)"' key '"\s*:\s*(-?\d+)', &m)
        return Integer(m[1])
    return ""
}

_KSub_UnescapeJson(s) {
    s := StrReplace(s, '\"', '"')
    s := StrReplace(s, '\\', '\')
    s := StrReplace(s, '\/', '/')
    s := StrReplace(s, '\n', "`n")
    s := StrReplace(s, '\r', "`r")
    s := StrReplace(s, '\t', "`t")
    return s
}

; Split array into top-level elements
_KSub_ArrayTopLevelSplit(arrayText) {
    res := []
    if (arrayText = "")
        return res
    if (SubStr(arrayText, 1, 1) = "[")
        arrayText := SubStr(arrayText, 2)
    if (SubStr(arrayText, -1) = "]")
        arrayText := SubStr(arrayText, 1, -1)

    i := 1
    depthObj := 0
    depthArr := 0
    inString := false
    start := 1
    len := StrLen(arrayText)

    while (i <= len) {
        ch := SubStr(arrayText, i, 1)
        if (!inString) {
            if (ch = '"') {
                inString := true
            } else if (ch = "{") {
                depthObj += 1
            } else if (ch = "}") {
                depthObj -= 1
            } else if (ch = "[") {
                depthArr += 1
            } else if (ch = "]") {
                depthArr -= 1
            } else if (ch = "," && depthObj = 0 && depthArr = 0) {
                piece := Trim(SubStr(arrayText, start, i - start))
                if (piece != "")
                    res.Push(piece)
                start := i + 1
            }
        } else {
            if (ch = '"' && SubStr(arrayText, i - 1, 1) != "\")
                inString := false
        }
        i += 1
    }
    last := Trim(SubStr(arrayText, start))
    if (last != "")
        res.Push(last)
    return res
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

; ============================================================
; State Navigation Helpers
; ============================================================

_KSub_GetMonitorsRing(stateText) {
    return _KSub_ExtractObjectByKey(stateText, "monitors")
}

_KSub_GetMonitorsArray(stateText) {
    ring := _KSub_GetMonitorsRing(stateText)
    if (ring = "")
        return []
    elems := _KSub_ExtractArrayByKey(ring, "elements")
    return _KSub_ArrayTopLevelSplit(elems)
}

_KSub_GetFocusedMonitorIndex(stateText) {
    ring := _KSub_GetMonitorsRing(stateText)
    if (ring = "")
        return -1
    return _KSub_GetIntProp(ring, "focused")
}

_KSub_GetWorkspacesRing(monObjText) {
    return _KSub_ExtractObjectByKey(monObjText, "workspaces")
}

_KSub_GetWorkspacesArray(monObjText) {
    ring := _KSub_GetWorkspacesRing(monObjText)
    if (ring = "")
        return []
    elems := _KSub_ExtractArrayByKey(ring, "elements")
    return _KSub_ArrayTopLevelSplit(elems)
}

_KSub_GetFocusedWorkspaceIndex(monObjText) {
    ring := _KSub_GetWorkspacesRing(monObjText)
    if (ring = "") {
        _KSub_Log("  GetFocusedWorkspaceIndex: no ring found")
        return -1
    }
    focusedIdx := _KSub_GetIntProp(ring, "focused")
    _KSub_Log("  GetFocusedWorkspaceIndex: ring len=" StrLen(ring) " focused=" focusedIdx)
    return focusedIdx
}

_KSub_GetWorkspaceNameByIndex(monObjText, wsIdx) {
    wsArr := _KSub_GetWorkspacesArray(monObjText)
    if (wsIdx < 0 || wsIdx >= wsArr.Length)
        return ""
    wsObj := wsArr[wsIdx + 1]  ; AHK 1-based
    return _KSub_GetStringProp(wsObj, "name")
}

; Find workspace name for a given hwnd by scanning all workspaces
_KSub_FindWorkspaceByHwnd(stateText, hwnd) {
    if (!hwnd)
        return ""
    monitorsArr := _KSub_GetMonitorsArray(stateText)
    for mi, monObj in monitorsArr {
        wsArr := _KSub_GetWorkspacesArray(monObj)
        for wi, wsObj in wsArr {
            ; Quick search for "hwnd": <value> inside this workspace
            if RegExMatch(wsObj, '"hwnd"\s*:\s*' hwnd '\b') {
                return _KSub_GetStringProp(wsObj, "name")
            }
        }
    }
    return ""
}

; Get the focused window hwnd from a SPECIFIC workspace by name
; Used for move events where we need to find the window on the SOURCE workspace
_KSub_GetFocusedHwndFromWorkspace(stateText, targetWsName) {
    if (targetWsName = "")
        return _KSub_GetFocusedHwnd(stateText)  ; Fallback to general lookup

    _KSub_DiagLog("    GetFocusedHwndFromWorkspace: looking for ws='" targetWsName "'")

    ; Search all monitors for the workspace with this name
    monitorsArr := _KSub_GetMonitorsArray(stateText)
    for mi, monObj in monitorsArr {
        wsArr := _KSub_GetWorkspacesArray(monObj)
        for wi, wsObj in wsArr {
            wsName := _KSub_GetStringProp(wsObj, "name")
            if (wsName = targetWsName) {
                _KSub_DiagLog("    Found workspace '" targetWsName "' at mon=" (mi-1) " ws=" (wi-1))

                ; Get focused container in this workspace
                containersRing := _KSub_ExtractObjectByKey(wsObj, "containers")
                if (containersRing != "") {
                    focusedContIdx := _KSub_GetIntProp(containersRing, "focused")
                    containersArr := _KSub_ExtractArrayByKey(containersRing, "elements")
                    if (containersArr != "") {
                        containers := _KSub_ArrayTopLevelSplit(containersArr)
                        if (focusedContIdx >= 0 && focusedContIdx < containers.Length) {
                            contObj := containers[focusedContIdx + 1]

                            ; Get focused window in this container
                            windowsRing := _KSub_ExtractObjectByKey(contObj, "windows")
                            if (windowsRing != "") {
                                focusedWinIdx := _KSub_GetIntProp(windowsRing, "focused")
                                windowsArr := _KSub_ExtractArrayByKey(windowsRing, "elements")
                                if (windowsArr != "") {
                                    windows := _KSub_ArrayTopLevelSplit(windowsArr)
                                    if (focusedWinIdx >= 0 && focusedWinIdx < windows.Length) {
                                        winObj := windows[focusedWinIdx + 1]
                                        hwnd := _KSub_GetIntProp(winObj, "hwnd")
                                        if (hwnd) {
                                            _KSub_DiagLog("    Found hwnd=" hwnd " via containers.windows")
                                            return hwnd
                                        }
                                    }
                                }
                            }

                            ; Fallback: container might have "window" directly
                            windowObj := _KSub_ExtractObjectByKey(contObj, "window")
                            if (windowObj != "") {
                                hwnd := _KSub_GetIntProp(windowObj, "hwnd")
                                if (hwnd) {
                                    _KSub_DiagLog("    Found hwnd=" hwnd " via container.window")
                                    return hwnd
                                }
                            }
                        }
                    }
                }

                ; Fallback: try monocle_container
                monocleObj := _KSub_ExtractObjectByKey(wsObj, "monocle_container")
                if (monocleObj != "") {
                    hwnd := _KSub_GetIntProp(monocleObj, "hwnd")
                    if (!hwnd) {
                        winObj := _KSub_ExtractObjectByKey(monocleObj, "window")
                        if (winObj != "")
                            hwnd := _KSub_GetIntProp(winObj, "hwnd")
                    }
                    if (hwnd) {
                        _KSub_DiagLog("    Found hwnd=" hwnd " via monocle_container")
                        return hwnd
                    }
                }

                _KSub_DiagLog("    Workspace found but no focused window")
                return 0
            }
        }
    }

    _KSub_DiagLog("    Workspace '" targetWsName "' not found in state")
    return 0
}

; Get the focused window hwnd from komorebi state
; Must navigate: focused monitor -> focused workspace -> focused container -> focused window
_KSub_GetFocusedHwnd(stateText) {
    ; Navigate through the state hierarchy to find the truly focused window
    ; 1. Get focused monitor
    focusedMonIdx := _KSub_GetFocusedMonitorIndex(stateText)
    monitorsArr := _KSub_GetMonitorsArray(stateText)

    if (focusedMonIdx >= 0 && focusedMonIdx < monitorsArr.Length) {
        monObj := monitorsArr[focusedMonIdx + 1]  ; AHK 1-based

        ; 2. Get focused workspace on this monitor
        focusedWsIdx := _KSub_GetFocusedWorkspaceIndex(monObj)
        wsArr := _KSub_GetWorkspacesArray(monObj)

        if (focusedWsIdx >= 0 && focusedWsIdx < wsArr.Length) {
            wsObj := wsArr[focusedWsIdx + 1]  ; AHK 1-based

            ; 3. Get focused container in this workspace
            containersRing := _KSub_ExtractObjectByKey(wsObj, "containers")
            if (containersRing != "") {
                focusedContIdx := _KSub_GetIntProp(containersRing, "focused")
                containersArr := _KSub_ExtractArrayByKey(containersRing, "elements")
                if (containersArr != "") {
                    containers := _KSub_ArrayTopLevelSplit(containersArr)
                    if (focusedContIdx >= 0 && focusedContIdx < containers.Length) {
                        contObj := containers[focusedContIdx + 1]

                        ; 4. Get focused window in this container
                        windowsRing := _KSub_ExtractObjectByKey(contObj, "windows")
                        if (windowsRing != "") {
                            focusedWinIdx := _KSub_GetIntProp(windowsRing, "focused")
                            windowsArr := _KSub_ExtractArrayByKey(windowsRing, "elements")
                            if (windowsArr != "") {
                                windows := _KSub_ArrayTopLevelSplit(windowsArr)
                                if (focusedWinIdx >= 0 && focusedWinIdx < windows.Length) {
                                    winObj := windows[focusedWinIdx + 1]
                                    hwnd := _KSub_GetIntProp(winObj, "hwnd")
                                    if (hwnd) {
                                        _KSub_DiagLog("    GetFocusedHwnd: found via hierarchy hwnd=" hwnd)
                                        return hwnd
                                    }
                                }
                            }
                        }

                        ; Fallback: container might have "window" directly (single window container)
                        windowObj := _KSub_ExtractObjectByKey(contObj, "window")
                        if (windowObj != "") {
                            hwnd := _KSub_GetIntProp(windowObj, "hwnd")
                            if (hwnd) {
                                _KSub_DiagLog("    GetFocusedHwnd: found via container.window hwnd=" hwnd)
                                return hwnd
                            }
                        }
                    }
                }
            }

            ; Fallback: try workspace's monocle_container
            monocleObj := _KSub_ExtractObjectByKey(wsObj, "monocle_container")
            if (monocleObj != "") {
                hwnd := _KSub_GetIntProp(monocleObj, "hwnd")
                if (!hwnd) {
                    ; Try nested window object
                    winObj := _KSub_ExtractObjectByKey(monocleObj, "window")
                    if (winObj != "")
                        hwnd := _KSub_GetIntProp(winObj, "hwnd")
                }
                if (hwnd) {
                    _KSub_DiagLog("    GetFocusedHwnd: found via monocle_container hwnd=" hwnd)
                    return hwnd
                }
            }
        }
    }

    ; Last resort fallbacks (some komorebi builds have these at top level):
    m := 0
    if RegExMatch(stateText, '(?s)"focused_window"\s*:\s*\{[^}]*"hwnd"\s*:\s*(\d+)', &m) {
        _KSub_DiagLog("    GetFocusedHwnd: found via focused_window fallback hwnd=" m[1])
        return Integer(m[1])
    }
    if RegExMatch(stateText, '(?s)"focused_hwnd"\s*:\s*(\d+)', &m) {
        _KSub_DiagLog("    GetFocusedHwnd: found via focused_hwnd fallback hwnd=" m[1])
        return Integer(m[1])
    }
    if RegExMatch(stateText, '(?s)"last_focused_window"\s*:\s*\{[^}]*"hwnd"\s*:\s*(\d+)', &m) {
        _KSub_DiagLog("    GetFocusedHwnd: found via last_focused_window fallback hwnd=" m[1])
        return Integer(m[1])
    }

    _KSub_DiagLog("    GetFocusedHwnd: could not find focused hwnd")
    return 0
}
