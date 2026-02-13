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

; Windows API Error Codes: uses IPC_ERROR_* from ipc_pipe.ahk (shared definitions)

; Komorebi event type strings (external API, centralized for maintainability)
global KSUB_EV_CLOAK := "Cloak"
global KSUB_EV_UNCLOAK := "Uncloak"
global KSUB_EV_TITLE_UPDATE := "TitleUpdate"
global KSUB_EV_FOCUS_CHANGE := "FocusChange"
global KSUB_EV_FOCUS_MONITOR_WS_NUM := "FocusMonitorWorkspaceNumber"
global KSUB_EV_FOCUS_WS_NUM := "FocusWorkspaceNumber"
global KSUB_EV_FOCUS_NAMED_WS := "FocusNamedWorkspace"
global KSUB_EV_MOVE_TO_WS_NUM := "MoveContainerToWorkspaceNumber"
global KSUB_EV_MOVE_TO_NAMED_WS := "MoveContainerToNamedWorkspace"

; Buffer size limit (1MB) - prevents OOM from incomplete JSON
global KSUB_BUFFER_MAX_BYTES := 1048576

; Pre-allocated read buffer for pipe reads (avoids per-poll allocation)
global KSUB_READ_CHUNK_SIZE := 65536
global KSUB_READ_BUF := Buffer(KSUB_READ_CHUNK_SIZE)

; Configuration (set in KomorebiSub_Init after ConfigLoader_Init)
global KSub_PollMs := 0
global KSub_IdleRecycleMs := 0
global KSub_FallbackPollMs := 0
global KSub_MruSuppressionMs := 2000

; State
global _KSub_PipeName := ""
global _KSub_hPipe := 0
global _KSub_hEvent := 0
global _KSub_Overlapped := 0             ; OVERLAPPED structure for async I/O
global _KSub_Connected := false
global _KSub_ClientPid := 0
global _KSub_LastEventTick := 0          ; Timestamp of last event (for idle detection)
global _KSub_ReadBuffer := ""      ; Accumulated bytes from pipe reads
global _KSub_ReadBufferLen := 0    ; Tracked length to avoid O(n) StrLen calls
global _KSub_LastWorkspaceName := ""
global _KSub_LastWsUpdateTick := 0         ; Tick when workspace was last set (for derivation cooldown)
global _KSub_FallbackMode := false

; Cache of window workspace assignments (persists even when windows leave komorebi)
; Each entry is { wsName: "name", tick: timestamp } for staleness detection
global _KSub_WorkspaceCache := Map()
global _KSub_CacheMaxAgeMs := 10000  ; Default, overridden from cfg in KomorebiSub_Init()

; Cache of per-workspace focused hwnds (populated from reliable state events)
; Used during workspace switch events where state snapshot is unreliable
global _KSub_FocusedHwndByWS := Map()

; MRU suppression: prevents WinEventHook from corrupting MRU during workspace switches.
; Set to A_TickCount + KSub_MruSuppressionMs on every FocusWorkspaceNumber/FocusNamedWorkspace event.
; NEVER cleared early (not even on FocusChange) — always auto-expires after configured duration.
; Clearing on FocusChange created a gap during rapid switching where stale WEH events
; triggered WS MISMATCH corrections, flip-flopping the workspace and causing visible jiggle.
; Komorebi handles MRU through the focused hwnd cache, so WEH suppression is harmless.
; Value: A_TickCount deadline (0 = not suppressed).
global gKSub_MruSuppressUntilTick := 0

; Cloak event batching state
global _KSub_CloakPushPending := false
global _KSub_CloakBatchTimerFn := 0
global _KSub_CloakBatchBuffer := Map()  ; hwnd -> isCloaked (bool)

; Initialize komorebi subscription
KomorebiSub_Init() {
    global _KSub_PipeName, _KSub_WorkspaceCache, _KSub_CacheMaxAgeMs, cfg
    global KSub_PollMs, KSub_IdleRecycleMs, KSub_FallbackPollMs
    global _KSub_FallbackMode

    ; Load config values (ConfigLoader_Init has already run)
    global KSub_MruSuppressionMs
    KSub_PollMs := cfg.KomorebiSubPollMs
    KSub_IdleRecycleMs := cfg.KomorebiSubIdleRecycleMs
    KSub_FallbackPollMs := cfg.KomorebiSubFallbackPollMs
    _KSub_CacheMaxAgeMs := cfg.KomorebiSubCacheMaxAgeMs
    KSub_MruSuppressionMs := cfg.KomorebiMruSuppressionMs

    _KSub_PipeName := "tabby_" A_TickCount "_" Random(1000, 9999)
    _KSub_WorkspaceCache := Map()

    if (!_KomorebiSub_IsAvailable()) {
        ; Fall back to polling mode
        _KSub_FallbackMode := true
        SetTimer(_KomorebiSub_PollFallback, KSub_FallbackPollMs)
        return false
    }

    return _KomorebiSub_Start()
}

; Check if komorebic is available
_KomorebiSub_IsAvailable() {
    global cfg
    return (cfg.KomorebicExe != "" && FileExist(cfg.KomorebicExe))
}

; Start subscription
_KomorebiSub_Start() {
    global _KSub_PipeName, _KSub_hPipe, _KSub_hEvent, _KSub_Overlapped
    global _KSub_Connected, _KSub_ClientPid, _KSub_LastEventTick, _KSub_FallbackMode
    global KSub_FallbackPollMs, IPC_ERROR_IO_PENDING, IPC_ERROR_PIPE_CONNECTED, KSub_PollMs, KSUB_READ_CHUNK_SIZE
    global cfg

    KomorebiSub_Stop()

    ; Reset log for new session
    if (cfg.DiagKomorebiLog) {
        global LOG_PATH_KSUB
        LogInitSession(LOG_PATH_KSUB, "Alt-Tabby Komorebi Subscription Log")
    }

    if (!_KomorebiSub_IsAvailable())
        return false

    ; Create Named Pipe server (byte mode, non-wait for non-blocking accept)
    PIPE_ACCESS_INBOUND := 0x00000001
    FILE_FLAG_OVERLAPPED := 0x40000000
    PIPE_TYPE_BYTE := 0x00000000
    PIPE_READMODE_BYTE := 0x00000000

    ; Create security attributes with NULL DACL to allow non-elevated processes
    ; to connect when we're running as administrator
    pSA := IPC_CreateOpenSecurityAttrs()

    pipePath := "\\.\pipe\" _KSub_PipeName
    _KSub_hPipe := DllCall("CreateNamedPipeW"
        , "str", pipePath
        , "uint", PIPE_ACCESS_INBOUND | FILE_FLAG_OVERLAPPED
        , "uint", PIPE_TYPE_BYTE | PIPE_READMODE_BYTE
        , "uint", 1          ; max instances
        , "uint", 0          ; out buffer (inbound only)
        , "uint", KSUB_READ_CHUNK_SIZE  ; in buffer
        , "uint", 0          ; default timeout
        , "ptr", pSA         ; security attrs (NULL DACL = allow all)
        , "ptr")

    if (_KSub_hPipe = 0 || _KSub_hPipe = -1) {
        gle := DllCall("GetLastError", "uint")
        if (cfg.DiagKomorebiLog)
            KSub_DiagLog("KomorebiSub: CreateNamedPipeW FAILED err=" gle " path=" pipePath)
        _KSub_hPipe := 0
        _KSub_FallbackMode := true
        SetTimer(_KomorebiSub_PollFallback, KSub_FallbackPollMs)
        return false
    }

    ; Create event for overlapped operations
    _KSub_hEvent := DllCall("CreateEventW", "ptr", 0, "int", 1, "int", 0, "ptr", 0, "ptr")
    if (!_KSub_hEvent) {
        if (cfg.DiagKomorebiLog)
            KSub_DiagLog("KomorebiSub: CreateEventW FAILED")
        KomorebiSub_Stop()
        _KSub_FallbackMode := true
        SetTimer(_KomorebiSub_PollFallback, KSub_FallbackPollMs)
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
        if (gle = IPC_ERROR_IO_PENDING)        ; Async operation in progress
            _KSub_Connected := false
        else if (gle = IPC_ERROR_PIPE_CONNECTED)   ; Already connected
            _KSub_Connected := true
        else {
            if (cfg.DiagKomorebiLog)
                KSub_DiagLog("KomorebiSub: ConnectNamedPipe FAILED err=" gle)
            KomorebiSub_Stop()
            _KSub_FallbackMode := true
            SetTimer(_KomorebiSub_PollFallback, KSub_FallbackPollMs)
            return false
        }
    } else {
        _KSub_Connected := true
    }

    ; Launch komorebic subscriber
    try {
        cmd := '"' cfg.KomorebicExe '" subscribe-pipe ' _KSub_PipeName
        _KSub_ClientPid := ProcessUtils_RunHidden(cmd)
        if (cfg.DiagKomorebiLog)
            KSub_DiagLog("KomorebiSub: Launched subscriber pid=" _KSub_ClientPid " cmd=" cmd)
    } catch as e {
        if (cfg.DiagKomorebiLog)
            KSub_DiagLog("KomorebiSub: Failed to launch subscriber: " e.Message)
        ; Keep server alive, client may connect later
    }

    _KSub_LastEventTick := A_TickCount
    _KSub_FallbackMode := false
    if (cfg.DiagKomorebiLog)
        KSub_DiagLog("KomorebiSub: Setting timer with interval=" KSub_PollMs)
    SetTimer(KomorebiSub_Poll, KSub_PollMs)

    ; Do initial poll to populate all windows with workspace data immediately
    ; Runs after 1500ms to ensure first winenum scan has populated the store
    SetTimer(_KSub_InitialPoll, -1500)

    if (cfg.DiagKomorebiLog)
        KSub_DiagLog("KomorebiSub: Start complete, pipe=" _KSub_PipeName)
    return true
}

; Diagnostic logging - controlled by DiagKomorebiLog config flag
; Writes to %TEMP%\tabby_ksub_diag.log when enabled
KSub_DiagLog(msg) {
    global cfg, LOG_PATH_KSUB
    if (!cfg.DiagKomorebiLog)
        return
    try LogAppend(LOG_PATH_KSUB, msg)
}

; One-time initial poll to populate workspace data on startup
_KSub_InitialPoll() {
    global _KSub_LastWorkspaceName, cfg

    if (cfg.DiagKomorebiLog)
        KSub_DiagLog("InitialPoll: Starting")

    if (!_KomorebiSub_IsAvailable()) {
        if (cfg.DiagKomorebiLog)
            KSub_DiagLog("InitialPoll: komorebic not available")
        return
    }

    txt := _KSub_GetStateDirect()
    if (txt = "") {
        if (cfg.DiagKomorebiLog)
            KSub_DiagLog("InitialPoll: Got empty state")
        return
    }

    if (cfg.DiagKomorebiLog)
        KSub_DiagLog("InitialPoll: Got state len=" StrLen(txt))

    ; Parse JSON and update all windows from full state
    stateObj := ""
    try stateObj := JSON.Load(txt)
    if !(stateObj is Map) {
        if (cfg.DiagKomorebiLog)
            KSub_DiagLog("InitialPoll: Failed to parse state JSON")
        return
    }
    _KSub_ProcessFullState(stateObj)
    if (cfg.DiagKomorebiLog)
        KSub_DiagLog("InitialPoll: Complete")
}

; Stop subscription
KomorebiSub_Stop() {
    global _KSub_hPipe, _KSub_hEvent, _KSub_Overlapped, _KSub_Connected, _KSub_ClientPid
    global _KSub_FallbackMode, _KSub_ReadBuffer, _KSub_ReadBufferLen

    ; Stop all timers
    SetTimer(KomorebiSub_Poll, 0)
    SetTimer(_KSub_InitialPoll, 0)  ; Cancel one-shot timer if pending

    ; Stop fallback timer if active
    if (_KSub_FallbackMode) {
        SetTimer(_KomorebiSub_PollFallback, 0)
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
    _KSub_ReadBuffer := ""
    _KSub_ReadBufferLen := 0
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
    global _KSub_LastEventTick, KSub_IdleRecycleMs, _KSub_ReadBuffer, _KSub_ReadBufferLen
    global IPC_ERROR_BROKEN_PIPE, KSUB_BUFFER_MAX_BYTES, KSUB_READ_CHUNK_SIZE, KSUB_READ_BUF
    global cfg
    static pollCount := 0, lastLogTick := 0

    pollCount++
    ; Log every 5 seconds to avoid spam
    if (cfg.DiagKomorebiLog && A_TickCount - lastLogTick > 5000) {
        KSub_DiagLog("Poll #" pollCount ": hPipe=" _KSub_hPipe " connected=" _KSub_Connected)
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
            if (gle = IPC_ERROR_BROKEN_PIPE)  ; Pipe disconnected, restart
                _KomorebiSub_Start()
            return
        }

        if (avail = 0)
            break

        toRead := Min(avail, KSUB_READ_CHUNK_SIZE)
        read := 0
        ok2 := DllCall("ReadFile"
            , "ptr", _KSub_hPipe
            , "ptr", KSUB_READ_BUF.Ptr
            , "uint", toRead
            , "uint*", &read
            , "ptr", 0
            , "int")

        if (!ok2 || read = 0)
            break

        _KSub_LastEventTick := A_TickCount
        chunk := StrGet(KSUB_READ_BUF.Ptr, read, "UTF-8")
        chunkLen := StrLen(chunk)

        ; Protect against unbounded buffer growth (use tracked length to avoid O(n) StrLen)
        ; This prevents OOM when komorebi sends incomplete JSON with opening brace
        if (_KSub_ReadBufferLen + chunkLen > KSUB_BUFFER_MAX_BYTES) {
            if (cfg.DiagKomorebiLog)
                KSub_DiagLog("Buffer overflow protection: reset (was " _KSub_ReadBufferLen ")")
            _KSub_ReadBuffer := ""
            _KSub_ReadBufferLen := 0
        }

        _KSub_ReadBuffer .= chunk
        _KSub_ReadBufferLen += chunkLen
        bytesRead += read

        if (bytesRead >= KSUB_READ_CHUNK_SIZE)
            break
    }

    ; Extract complete JSON objects from buffer (track length arithmetically)
    consumed := 0
    while true {
        json := _KSub_ExtractOneJson(&_KSub_ReadBuffer, &consumed)
        if (consumed > 0)
            _KSub_ReadBufferLen -= consumed
        if (json = "")
            break
        if (cfg.DiagKomorebiLog)
            KSub_DiagLog("Poll: Got JSON object, len=" StrLen(json))
        _KSub_OnNotification(json)
    }
    ; Safety clamp: if arithmetic drifted (edge cases), resync via O(n) StrLen
    if (_KSub_ReadBufferLen < 0 || (_KSub_ReadBuffer = "" && _KSub_ReadBufferLen != 0))
        _KSub_ReadBufferLen := StrLen(_KSub_ReadBuffer)

    ; Recycle if idle too long
    if ((A_TickCount - _KSub_LastEventTick) > KSub_IdleRecycleMs)
        _KomorebiSub_Start()
}

; Extract one complete JSON notification from buffer.
; Komorebi sends newline-delimited JSON (one notification per line).
; This replaces the O(n) character-by-character scanner with O(1) InStr.
_KSub_ExtractOneJson(&s, &consumed := 0) {
    if (s = "")
        return ""

    ; Komorebi uses newline-delimited JSON
    nlPos := InStr(s, "`n")
    if (!nlPos) {
        ; No complete line yet - check buffer limits
        if (StrLen(s) > 1000000)
            s := ""  ; Prevent unbounded growth
        return ""
    }

    ; Track consumed bytes for arithmetic buffer length tracking
    consumed := nlPos

    ; Extract line (handle both \r\n and \n)
    line := SubStr(s, 1, nlPos - 1)
    if (StrLen(line) > 0 && SubStr(line, -1) = "`r")
        line := SubStr(line, 1, -1)

    ; Consume from buffer
    s := SubStr(s, nlPos + 1)

    ; Trim and validate
    line := Trim(line)
    if (line = "" || SubStr(line, 1, 1) != "{")
        return ""

    return line
}

; Quick extract event type from JSON string without full parse.
; Searches for "type":" pattern near start of the notification.
; Returns empty string if not found or malformed.
; Used by Layer 2 early-exit optimization.
_KSub_QuickExtractEventType(jsonLine) {
    ; Event type is always near the start (within first ~100 chars)
    ; Format: {"event":{"type":"EventName",...
    pos := InStr(jsonLine, '"type":"')
    if (!pos || pos > 100)
        return ""

    ; Skip past the pattern (8 chars for '"type":"')
    pos += 8

    ; Find closing quote
    endPos := InStr(jsonLine, '"', , pos)
    if (!endPos || endPos - pos > 50)  ; Event types are short
        return ""

    return SubStr(jsonLine, pos, endPos - pos)
}

; Quick extract hwnd from Cloak/Uncloak event without full JSON parse.
; Searches for "hwnd": followed by a number in the event portion.
; Returns 0 if not found.
_KSub_QuickExtractHwnd(jsonLine) {
    ; hwnd appears in event.content[{...,"hwnd":N,...}]
    ; Search within first 500 chars (event object is small)
    searchLimit := Min(500, StrLen(jsonLine))
    searchPortion := SubStr(jsonLine, 1, searchLimit)

    pos := InStr(searchPortion, '"hwnd":')
    if (!pos)
        return 0

    ; Skip past '"hwnd":' (7 chars)
    pos += 7

    ; Skip whitespace
    while (pos <= searchLimit && SubStr(searchPortion, pos, 1) = " ")
        pos++

    ; Extract digits (use InStr instead of comparison operators - AHK v2 string comparison quirk)
    numStr := ""
    while (pos <= searchLimit) {
        ch := SubStr(searchPortion, pos, 1)
        if (ch = "" || !InStr("0123456789", ch))
            break
        numStr .= ch
        pos++
    }

    if (numStr = "")
        return 0

    return Integer(numStr)
}

; Process a complete notification JSON
; Uses three-layer early-exit optimization:
;   Layer 1: Newline-delimited framing (handled by _KSub_ExtractOneJson)
;   Layer 2: Quick event type extraction to skip full parse for Cloak/Uncloak/TitleUpdate
;   Layer 3: Full parse only for structural events (FocusChange, workspace moves, etc.)
_KSub_OnNotification(jsonLine) {
    global _KSub_LastWorkspaceName, _KSub_WorkspaceCache, gKSub_MruSuppressUntilTick, _KSub_CloakBatchBuffer
    global KSUB_EV_CLOAK, KSUB_EV_UNCLOAK, KSUB_EV_TITLE_UPDATE, KSUB_EV_FOCUS_CHANGE
    global KSUB_EV_FOCUS_MONITOR_WS_NUM, KSUB_EV_FOCUS_WS_NUM, KSUB_EV_FOCUS_NAMED_WS
    global KSUB_EV_MOVE_TO_WS_NUM, KSUB_EV_MOVE_TO_NAMED_WS, KSub_MruSuppressionMs
    global cfg

    ; ========== Layer 2: Quick event type extraction (no full JSON parse) ==========
    eventType := _KSub_QuickExtractEventType(jsonLine)
    if (cfg.DiagKomorebiLog) {
        KSub_DiagLog("OnNotification called, len=" StrLen(jsonLine))
        KSub_DiagLog("  Quick event type: '" eventType "'")
    }

    ; Fast path for Cloak/Uncloak: extract hwnd directly, skip 200KB state parse
    ; These fire 10+ times per workspace switch, so avoiding full parse saves ~400KB-1.6MB
    ; Buffer changes instead of immediate update - batch applies when timer fires (single rev bump)
    if (eventType = KSUB_EV_CLOAK || eventType = KSUB_EV_UNCLOAK) {
        hwnd := _KSub_QuickExtractHwnd(jsonLine)
        if (hwnd) {
            isCloaked := (eventType = KSUB_EV_CLOAK)
            Critical "On"
            _KSub_CloakBatchBuffer[hwnd] := isCloaked
            Critical "Off"
            if (cfg.DiagKomorebiLog)
                KSub_DiagLog("  Cloak buffered: hwnd=" hwnd " cloaked=" isCloaked)
        }
        _KSub_ScheduleCloakPush()
        return
    }

    ; Fast path for TitleUpdate: skip entirely (WinEventHook handles NAMECHANGE faster)
    if (eventType = KSUB_EV_TITLE_UPDATE) {
        if (cfg.DiagKomorebiLog)
            KSub_DiagLog("  TitleUpdate: skipped (WinEventHook handles)")
        return
    }

    ; ========== Layer 3: Full parse for structural events ==========
    parsed := ""
    try parsed := JSON.Load(jsonLine)
    if !(parsed is Map) {
        if (cfg.DiagKomorebiLog)
            KSub_DiagLog("  Failed to parse notification JSON")
        return
    }

    ; Each notification has: { "event": {...}, "state": {...} }
    if (!parsed.Has("state")) {
        if (cfg.DiagKomorebiLog)
            KSub_DiagLog("  No state object found")
        return
    }
    stateObj := parsed["state"]
    if !(stateObj is Map) {
        if (cfg.DiagKomorebiLog)
            KSub_DiagLog("  State is not a Map")
        return
    }

    ; Extract the event object for workspace/cloak tracking
    eventObj := ""
    if (parsed.Has("event")) {
        eventObj := parsed["event"]
        ; eventType already extracted above via quick method
    }

    if (cfg.DiagKomorebiLog)
        KSub_DiagLog("Event: " eventType)

    ; Track if we explicitly handled workspace change
    handledWorkspaceEvent := false

    ; Handle workspace focus/move events - update current workspace from event
    ; MoveContainerToWorkspaceNumber: user moved focused window to another workspace (and followed it)
    if (eventType = KSUB_EV_FOCUS_MONITOR_WS_NUM || eventType = KSUB_EV_FOCUS_WS_NUM
        || eventType = KSUB_EV_FOCUS_NAMED_WS || eventType = KSUB_EV_MOVE_TO_WS_NUM
        || eventType = KSUB_EV_MOVE_TO_NAMED_WS) {
        ; Suppress WinEventHook MRU IMMEDIATELY — before any content extraction.
        ; Without Critical, WEH's SetTimer(-1) can interrupt between lines here.
        ; The suppression must be active before any interruptible work happens.
        Critical "On"
        gKSub_MruSuppressUntilTick := A_TickCount + KSub_MruSuppressionMs
        Critical "Off"

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

        if (cfg.DiagKomorebiLog)
            KSub_DiagLog("  FocusWorkspace content type: " Type(content))

        wsName := ""

        if (eventType = KSUB_EV_FOCUS_NAMED_WS || eventType = KSUB_EV_MOVE_TO_NAMED_WS) {
            ; Content is the workspace name directly (string)
            if (content is String)
                wsName := content
            else
                wsName := String(content)
        } else if (eventType = KSUB_EV_MOVE_TO_WS_NUM) {
            ; Content is the workspace index (integer or possibly in an array)
            wsIdx := -1
            if (content is Integer) {
                wsIdx := content
            } else if (content is Array && content.Length > 0) {
                try wsIdx := Integer(content[1])
            } else if (content != "") {
                try wsIdx := Integer(content)
            }
            if (cfg.DiagKomorebiLog)
                KSub_DiagLog("  MoveContainer wsIdx=" wsIdx)

            if (wsIdx >= 0) {
                ; Use focused monitor (we're moving on current monitor)
                focusedMonIdx := KSub_GetFocusedMonitorIndex(stateObj)
                monitorsArr := KSub_GetMonitorsArray(stateObj)
                if (focusedMonIdx >= 0 && monitorsArr.Length > focusedMonIdx) {
                    monObj := monitorsArr[focusedMonIdx + 1]
                    wsName := KSub_GetWorkspaceNameByIndex(monObj, wsIdx)
                    if (cfg.DiagKomorebiLog)
                        KSub_DiagLog("  lookup wsName from focusMon[" focusedMonIdx "] ws[" wsIdx "] = '" wsName "'")
                }
            }
        } else {
            ; FocusMonitorWorkspaceNumber: [monitorIdx, workspaceIdx]
            ; FocusWorkspaceNumber: [workspaceIdx]
            ; Content is already an Array from cJson
            wsIdx := -1
            monIdx := 0
            if (content is Array) {
                if (cfg.DiagKomorebiLog)
                    KSub_DiagLog("  content array length: " content.Length)
                if (content.Length >= 2) {
                    monIdx := Integer(content[1])
                    wsIdx := Integer(content[2])
                } else if (content.Length = 1) {
                    wsIdx := Integer(content[1])
                }
            } else if (content is Integer) {
                wsIdx := content
            }

            if (cfg.DiagKomorebiLog)
                KSub_DiagLog("  monIdx=" monIdx " wsIdx=" wsIdx)

            if (wsIdx >= 0) {
                monitorsArr := KSub_GetMonitorsArray(stateObj)
                if (cfg.DiagKomorebiLog)
                    KSub_DiagLog("  monitors count: " monitorsArr.Length)
                if (monitorsArr.Length > monIdx) {
                    ; Use the correct monitor from the event
                    monObj := monitorsArr[monIdx + 1]  ; AHK is 1-based
                    wsName := KSub_GetWorkspaceNameByIndex(monObj, wsIdx)
                    if (cfg.DiagKomorebiLog)
                        KSub_DiagLog("  lookup wsName from mon[" monIdx "] ws[" wsIdx "] = '" wsName "'")
                }
            }
        }

        if (cfg.DiagKomorebiLog) {
            KSub_DiagLog("  Focus event resolved wsName='" wsName "'")
            KSub_DiagLog("  WS event: " eventType " -> '" wsName "'")
        }
        if (wsName != "") {
            global _KSub_LastWorkspaceName, _KSub_LastWsUpdateTick
            ; Capture old workspace BEFORE updating (needed for move events)
            previousWsName := _KSub_LastWorkspaceName
            anyFlipped := false  ; Initialize before conditional (used by broadcast below)

            if (wsName != _KSub_LastWorkspaceName) {
                if (cfg.DiagKomorebiLog) {
                    KSub_DiagLog("  Updating current workspace to '" wsName "' from focus event")
                    KSub_DiagLog("  CurWS: '" _KSub_LastWorkspaceName "' -> '" wsName "'")
                }
                _KSub_LastWorkspaceName := wsName
                _KSub_LastWsUpdateTick := A_TickCount
                try anyFlipped := WindowStore_SetCurrentWorkspace("", wsName)
            }

            ; For MOVE events: DON'T try to explicitly update the moved window here.
            ; The state at this point is inconsistent - Signal has already moved to the TARGET
            ; workspace in the state data, but focus indices on the SOURCE workspace point to
            ; a DIFFERENT window. Any attempt to find "the moved window" will fail.
            ;
            ; Instead, rely on ProcessFullState from subsequent Cloak/Uncloak events which
            ; will have consistent state and correctly update all windows including Signal.
            if (eventType = KSUB_EV_MOVE_TO_WS_NUM || eventType = KSUB_EV_MOVE_TO_NAMED_WS) {
                if (cfg.DiagKomorebiLog)
                    KSub_DiagLog("  Move event: previousWS='" previousWsName "' targetWS='" wsName "' (letting ProcessFullState handle window update)")
                ; For MOVE events, the state is reliable for the TARGET workspace
                ; (the window has already been moved there in komorebi's state).
                ; Update the focused hwnd cache for JUST the target workspace so
                ; ProcessFullState gives the MRU tick to the moved window, not the
                ; previously-focused window from a stale cache.
                ; NOTE: Source workspace focus indices are unreliable ("point to OTHER
                ; windows") so we don't refresh the whole cache — just the target.
                global _KSub_FocusedHwndByWS
                targetFocused := KSub_GetFocusedHwndByWsName(stateObj, wsName)
                if (targetFocused) {
                    _KSub_FocusedHwndByWS[wsName] := targetFocused
                    if (cfg.DiagKomorebiLog)
                        KSub_DiagLog("  Move: updated cache for '" wsName "' -> focused hwnd=" targetFocused)
                }
            }

            ; Immediately broadcast workspace meta to clients (~0.5ms vs ~5ms full push).
            ; The subsequent Store_PushToClients at the end handles any remaining changes.
            if (anyFlipped)
                try Store_BroadcastWorkspaceFlips()
            handledWorkspaceEvent := true
        }
    }

    ; Process full state for structural events.
    ; (Cloak/Uncloak/TitleUpdate already returned early above via Layer 2 fast path)
    ; Structural events that reach here may change workspace structure:
    ; - FocusChange: can signal external workspace switches (notification clicks)
    ; - Workspace/Move events: change window→workspace mapping
    ; - Manage/Unmanage: add/remove windows from komorebi tracking
    isLightMode := (eventType = KSUB_EV_FOCUS_CHANGE)
    _KSub_ProcessFullState(stateObj, handledWorkspaceEvent, isLightMode)

    ; Push changes to clients (flush any pending cloak batch first)
    _KSub_CancelCloakTimer()
    try Store_PushToClients()
}

; Schedule a deferred push for batched Cloak/Uncloak events.
; If a timer is already pending, the new cloak change will be included
; when it fires (no action needed — buffer accumulates all changes).
_KSub_ScheduleCloakPush() {
    global _KSub_CloakPushPending, _KSub_CloakBatchTimerFn, _KSub_CloakBatchBuffer, cfg

    ; If batching disabled, flush buffer and push immediately
    if (!cfg.KomorebiSubBatchCloakEventsMs) {
        Critical "On"
        patches := Map()
        for hwnd, isCloaked in _KSub_CloakBatchBuffer
            patches[hwnd] := { isCloaked: isCloaked }
        _KSub_CloakBatchBuffer := Map()
        Critical "Off"
        if (patches.Count > 0)
            try WindowStore_BatchUpdateFields(patches, "cloak_immediate")
        try Store_PushToClients()
        return
    }

    ; RACE FIX: Wrap check-then-set in Critical to prevent a timer interrupt
    ; between the guard check and the flag assignment (which would orphan a Bind()
    ; reference and schedule a duplicate push timer)
    Critical "On"

    ; Already scheduled — nothing to do, new cloaks batch into same push
    if (_KSub_CloakPushPending)
        return  ; lint-ignore: critical-section (AHK v2 auto-releases Critical on return)

    _KSub_CloakPushPending := true
    _KSub_CloakBatchTimerFn := _KSub_FlushCloakBatch.Bind()
    SetTimer(_KSub_CloakBatchTimerFn, -cfg.KomorebiSubBatchCloakEventsMs)
}

; Timer callback: push all accumulated cloak changes in one delta
_KSub_FlushCloakBatch() {
    global _KSub_CloakPushPending, _KSub_CloakBatchTimerFn, _KSub_CloakBatchBuffer
    ; RACE FIX: Reset flags and extract buffer atomically so _KSub_ScheduleCloakPush()
    ; sees consistent state if it interrupts between assignments
    Critical "On"
    _KSub_CloakPushPending := false
    _KSub_CloakBatchTimerFn := 0
    patches := Map()
    for hwnd, isCloaked in _KSub_CloakBatchBuffer
        patches[hwnd] := { isCloaked: isCloaked }
    _KSub_CloakBatchBuffer := Map()
    Critical "Off"

    if (patches.Count > 0)
        try WindowStore_BatchUpdateFields(patches, "cloak_batch")
    try Store_PushToClients()
}

; Cancel any pending cloak batch timer (called when a structural event pushes immediately)
; Flushes buffered cloak changes before the structural event push to ensure consistent state
_KSub_CancelCloakTimer() {
    global _KSub_CloakPushPending, _KSub_CloakBatchTimerFn, _KSub_CloakBatchBuffer
    Critical "On"
    if (_KSub_CloakPushPending) {
        SetTimer(_KSub_CloakBatchTimerFn, 0)
        _KSub_CloakPushPending := false
        _KSub_CloakBatchTimerFn := 0
        patches := Map()
        for hwnd, isCloaked in _KSub_CloakBatchBuffer
            patches[hwnd] := { isCloaked: isCloaked }
        _KSub_CloakBatchBuffer := Map()
        Critical "Off"
        if (patches.Count > 0)
            try WindowStore_BatchUpdateFields(patches, "cloak_cancel_flush")
        return
    }
    Critical "Off"
}

; Process full komorebi state and update all windows
; stateObj: parsed Map from cJson (NOT raw text)
; skipWorkspaceUpdate: set to true when called after a focus event (notification already handled workspace)
_KSub_ProcessFullState(stateObj, skipWorkspaceUpdate := false, lightMode := false) {
    global gWS_Store, _KSub_LastWorkspaceName, _KSub_WorkspaceCache, _KSub_LastWsUpdateTick
    global _KSub_CacheMaxAgeMs, _KSub_FocusedHwndByWS, gKSub_MruSuppressUntilTick
    global cfg

    if !(stateObj is Map)
        return

    monitorsArr := KSub_GetMonitorsArray(stateObj)

    if (monitorsArr.Length = 0)
        return

    ; ALWAYS extract focused workspace from state (cheap: ~9 Map lookups).
    ; This provides self-healing when FocusWorkspaceNumber events lie — e.g.,
    ; during rapid workspace switching where komorebi sends an event for a
    ; switch that never physically completes.
    ;
    ; NOTE: A previous 2-second cooldown skipped state derivation after workspace events,
    ; claiming it saved processing during Cloak/Uncloak bursts. But Cloak/Uncloak events
    ; already skip ProcessFullState entirely (line 649), so the cooldown was blocking
    ; self-correction for no benefit.
    ;
    ; When skipWorkspaceUpdate=true (same notification as a FocusWorkspaceNumber event),
    ; we trust the event content per architecture.md ("state's ring.focused may be stale").
    ; For ALL other events, we derive workspace from state and correct if it disagrees.
    currentWsName := ""
    focusedWsIdx := "N/A"
    focusedMonIdx := -1
    if (skipWorkspaceUpdate) {
        ; Trust the value already set by focus event handler for this notification
        currentWsName := _KSub_LastWorkspaceName
    } else {
        focusedMonIdx := KSub_GetFocusedMonitorIndex(stateObj)
        if (focusedMonIdx >= 0 && focusedMonIdx < monitorsArr.Length) {
            monObj := monitorsArr[focusedMonIdx + 1]  ; AHK 1-based
            focusedWsIdx := KSub_GetFocusedWorkspaceIndex(monObj)
            currentWsName := KSub_GetWorkspaceNameByIndex(monObj, focusedWsIdx)
        }
    }

    if (cfg.DiagKomorebiLog)
        KSub_DiagLog("ProcessState: mon=" focusedMonIdx " wsIdx=" focusedWsIdx " curWS='" currentWsName "' lastWS='" _KSub_LastWorkspaceName "' skip=" skipWorkspaceUpdate)

    ; Update current workspace if state disagrees with cached value
    if (!skipWorkspaceUpdate && currentWsName != "" && currentWsName != _KSub_LastWorkspaceName) {
        if (cfg.DiagKomorebiLog)
            KSub_DiagLog("  WS change via state: '" _KSub_LastWorkspaceName "' -> '" currentWsName "'")
        _KSub_LastWorkspaceName := currentWsName
        _KSub_LastWsUpdateTick := A_TickCount
        try WindowStore_SetCurrentWorkspace("", currentWsName)
    }

    ; Light mode: only workspace self-healing (above) + focused hwnd cache + MRU.
    ; Skips the expensive wsMap build + batch patching (saves ~5-10ms).
    ; Used for FocusChange events which don't add/remove windows or change mappings.
    if (lightMode) {
        if (!skipWorkspaceUpdate) {
            KSub_CacheFocusedHwnds(stateObj, _KSub_FocusedHwndByWS, monitorsArr)
            if (cfg.DiagKomorebiLog)
                KSub_DiagLog("ProcessFullState[light]: refreshed focused hwnd cache (" _KSub_FocusedHwndByWS.Count " workspaces)")
        }
        if (currentWsName != "") {
            focusedHwnd := _KSub_FocusedHwndByWS.Has(currentWsName) ? _KSub_FocusedHwndByWS[currentWsName] : 0
            if (focusedHwnd) {
                ; Skip MRU update if WEH already confirmed focus for this exact hwnd.
                ; Prevents redundant push cycle (BuildDelta + JSON.Dump + IPC + GUI parse + repaint).
                ; When WEH is disabled/failed, gWEH_LastFocusHwnd stays 0 → never matches → update proceeds.
                global gWEH_LastFocusHwnd
                if (focusedHwnd != gWEH_LastFocusHwnd) {
                    try WindowStore_UpdateFields(focusedHwnd, { lastActivatedTick: A_TickCount }, "ksub_focus_light")
                    if (cfg.DiagKomorebiLog)
                        KSub_DiagLog("ProcessFullState[light]: MRU for focused hwnd=" focusedHwnd " on '" currentWsName "'")
                } else if (cfg.DiagKomorebiLog) {
                    KSub_DiagLog("ProcessFullState[light]: MRU skip (WEH match) hwnd=" focusedHwnd)
                }
            }
        }
        return
    }

    ; Build map of ALL windows to their workspaces from komorebi state
    ; Only stores wsName/isCurrent/winObj — title/class/exe extracted lazily
    ; in the "add to store" branch (uncommon path) to avoid wasted work
    wsMap := Map()  ; hwnd -> { wsName, isCurrent, winObj }
    now := A_TickCount

    for mi, monObj in monitorsArr {
        wsArr := KSub_GetWorkspacesArray(monObj)
        for wi, wsObj in wsArr {
            if !(wsObj is Map)
                continue
            wsName := KSafe_Str(wsObj, "name")
            if (wsName = "")
                continue

            ; Determine if this is the current workspace
            isCurrentWs := (wsName = currentWsName)

            ; Get all containers in this workspace
            if (!wsObj.Has("containers"))
                continue
            containersRing := wsObj["containers"]
            contArr := KSafe_Elements(containersRing)

            ; Iterate containers -> windows to find all hwnds
            for _, cont in contArr {
                if !(cont is Map)
                    continue

                ; Check windows ring in this container
                if (cont.Has("windows")) {
                    for _, win in KSafe_Elements(cont["windows"]) {
                        if !(win is Map) || !win.Has("hwnd")
                            continue
                        hwnd := KSafe_Int(win, "hwnd")
                        if (!hwnd)
                            continue

                        wsMap[hwnd] := { wsName: wsName, isCurrent: isCurrentWs, winObj: win }
                    }
                }

                ; Single window container ("window" key directly)
                if (cont.Has("window")) {
                    winObj := cont["window"]
                    if (winObj is Map && winObj.Has("hwnd")) {
                        hwnd := KSafe_Int(winObj, "hwnd")
                        if (hwnd && !wsMap.Has(hwnd)) {
                            wsMap[hwnd] := { wsName: wsName, isCurrent: isCurrentWs, winObj: winObj }
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
                        for _, win in KSafe_Elements(mono["windows"]) {
                            if !(win is Map) || !win.Has("hwnd")
                                continue
                            hwnd := KSafe_Int(win, "hwnd")
                            if (hwnd && !wsMap.Has(hwnd)) {
                                wsMap[hwnd] := { wsName: wsName, isCurrent: isCurrentWs, winObj: win }
                            }
                        }
                    }
                    ; Monocle may have single "window"
                    if (mono.Has("window")) {
                        winObj := mono["window"]
                        if (winObj is Map && winObj.Has("hwnd")) {
                            hwnd := KSafe_Int(winObj, "hwnd")
                            if (hwnd && !wsMap.Has(hwnd)) {
                                wsMap[hwnd] := { wsName: wsName, isCurrent: isCurrentWs, winObj: winObj }
                            }
                        }
                    }
                }
            }
        }
    }

    ; Batch update workspace cache for all windows in wsMap (single Critical section
    ; instead of per-window Critical enter/exit)
    Critical "On"
    for hwnd, info in wsMap {
        if (_KSub_WorkspaceCache.Has(hwnd) && _KSub_WorkspaceCache[hwnd].wsName = info.wsName)
            _KSub_WorkspaceCache[hwnd].tick := now
        else
            _KSub_WorkspaceCache[hwnd] := { wsName: info.wsName, tick: now }
    }
    Critical "Off"

    ; Update/insert ALL windows from komorebi state
    if (!IsSet(gWS_Store)) {  ; lint-ignore: isset-with-default
        if (cfg.DiagKomorebiLog)
            KSub_DiagLog("ProcessFullState: gWS_Store not set, returning")
        return
    }

    if (cfg.DiagKomorebiLog)
        KSub_DiagLog("ProcessFullState: wsMap has " wsMap.Count " windows, gWS_Store has " gWS_Store.Count " windows")

    ; Capture MRU tick early to preserve timing (before batch collection)
    mruTick := A_TickCount

    ; Collect all patches into a Map for batch update (one rev bump instead of N)
    batchPatches := Map()

    addedCount := 0
    updatedCount := 0
    skippedIneligible := 0
    for hwnd, info in wsMap {
        ; Check if window exists in store
        if (!gWS_Store.Has(hwnd)) {
            ; Window not in store - add it!
            ; This happens for windows on other workspaces that winenum didn't see
            ; Extract title/class/exe lazily — only needed for new windows
            kTitle := KSafe_Str(info.winObj, "title")
            kClass := KSafe_Str(info.winObj, "class")
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
            rec["isCloaked"] := !info.isCurrent  ; Not on current workspace = cloaked
            rec["isMinimized"] := false
            rec["isVisible"] := info.isCurrent
            rec["workspaceName"] := info.wsName
            rec["isOnCurrentWorkspace"] := info.isCurrent

            try WindowStore_UpsertWindow([rec])
            addedCount++
        } else {
            ; Window exists - only patch if workspace data actually changed
            row := gWS_Store[hwnd]
            if (!row.HasOwnProp("workspaceName") || row.workspaceName != info.wsName
                || !row.HasOwnProp("isOnCurrentWorkspace") || row.isOnCurrentWorkspace != info.isCurrent
                || !row.HasOwnProp("isCloaked") || row.isCloaked != !info.isCurrent) {
                batchPatches[hwnd] := {
                    workspaceName: info.wsName,
                    isOnCurrentWorkspace: info.isCurrent,
                    isCloaked: !info.isCurrent
                }
                updatedCount++
            }
        }
    }
    if (cfg.DiagKomorebiLog)
        KSub_DiagLog("ProcessFullState: added " addedCount " updated " updatedCount " skipped(ineligible) " skippedIneligible)

    ; Update MRU for the focused window on the current workspace.
    ; This ensures correct MRU ordering when clients request projections during
    ; workspace switches. WinEventHook also tracks focus via EVENT_SYSTEM_FOREGROUND
    ; but its batch timer (-1) yields to the komorebi sub timer that's running now,
    ; so it hasn't fired yet.
    ;
    ; CACHING: During workspace switch events (skipWorkspaceUpdate=true), the komorebi
    ; state snapshot is unreliable — not just ring.focused indices, but per-workspace
    ; container/window focus data too (e.g., Spotify reported as Main's focused window
    ; during a Media→Main switch). We cache focused hwnds from RELIABLE events
    ; (FocusChange, Show, etc. where skipWorkspaceUpdate=false) and use the cache
    ; during unreliable workspace switch events.
    if (!skipWorkspaceUpdate) {
        ; State is reliable — cache focused hwnds for ALL workspaces
        KSub_CacheFocusedHwnds(stateObj, _KSub_FocusedHwndByWS, monitorsArr)
        if (cfg.DiagKomorebiLog)
            KSub_DiagLog("ProcessFullState: refreshed focused hwnd cache (" _KSub_FocusedHwndByWS.Count " workspaces)")

        ; DON'T clear suppression here. During rapid workspace switches, clearing
        ; on FocusChange creates a gap where stale WEH events sneak through before
        ; the next FocusWorkspaceNumber sets suppression again. Those events trigger
        ; WS MISMATCH corrections that flip-flop the workspace, causing visible jiggle.
        ; Let suppression auto-expire after 2s instead. Komorebi handles MRU correctly
        ; through the cache above, so WEH suppression during this window is harmless.
    }
    ; Add MRU update to batch (using tick captured at start for timing consistency)
    if (currentWsName != "") {
        focusedHwnd := _KSub_FocusedHwndByWS.Has(currentWsName) ? _KSub_FocusedHwndByWS[currentWsName] : 0
        if (focusedHwnd) {
            ; Merge MRU tick into existing patch or create new one
            if (batchPatches.Has(focusedHwnd))
                batchPatches[focusedHwnd].lastActivatedTick := mruTick
            else
                batchPatches[focusedHwnd] := { lastActivatedTick: mruTick }
            if (cfg.DiagKomorebiLog)
                KSub_DiagLog("ProcessFullState: batched MRU for focused hwnd=" focusedHwnd " on '" currentWsName "' (cache " (!skipWorkspaceUpdate ? "refreshed" : "used") ")")
        }
    }

    ; Also update windows in store that aren't in komorebi state
    ; (they might have cached workspace data)
    ; Uses timestamped cache entries to avoid using stale data
    if (IsObject(gWS_Store)) {
        now := A_TickCount

        ; Snapshot hwnds to prevent iteration-during-modification race
        hwnds := WS_SnapshotMapKeys(gWS_Store)

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
                ; Add to batch (don't overwrite if already in batch from wsMap)
                if (!batchPatches.Has(hwnd)) {
                    batchPatches[hwnd] := {
                        workspaceName: wsName,
                        isOnCurrentWorkspace: isCurrent
                    }
                }
            }
        }
    }

    ; Apply all updates in a single batch (one Critical section, one rev bump)
    if (batchPatches.Count > 0) {
        result := WindowStore_BatchUpdateFields(batchPatches, "komorebi_fullstate")
        if (cfg.DiagKomorebiLog)
            KSub_DiagLog("ProcessFullState: batch updated " result.changed " windows (patches=" batchPatches.Count ")")
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
_KomorebiSub_PollFallback() {
    global cfg
    if (!_KomorebiSub_IsAvailable())
        return

    txt := _KSub_GetStateDirect()
    if (txt = "") {
        if (cfg.DiagKomorebiLog)
            KSub_DiagLog("PollFallback: GetStateDirect returned empty")
        return
    }

    ; Parse JSON before passing to ProcessFullState (expects parsed Map)
    stateObj := ""
    try stateObj := JSON.Load(txt)
    if !(stateObj is Map) {
        if (cfg.DiagKomorebiLog)
            KSub_DiagLog("PollFallback: JSON.Load failed or result not Map (len=" StrLen(txt) ")")
        return
    }
    _KSub_ProcessFullState(stateObj)
}

; Get komorebi state directly via command
_KSub_GetStateDirect() {
    global cfg, TIMING_FILE_WRITE_WAIT
    tmp := A_Temp "\komorebi_state_" A_TickCount ".tmp"
    ; Use double-quote escaping for cmd.exe with paths containing spaces
    cmd := 'cmd.exe /c ""' cfg.KomorebicExe '" state > "' tmp '"" 2>&1'
    try ProcessUtils_RunWaitHidden(cmd)
    Sleep(TIMING_FILE_WRITE_WAIT)  ; Give file time to write
    txt := ""
    try txt := FileRead(tmp, "UTF-8")
    try FileDelete(tmp)
    return txt
}

