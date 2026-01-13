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

    pipePath := "\\.\pipe\" _KSub_PipeName
    _KSub_hPipe := DllCall("CreateNamedPipeW"
        , "str", pipePath
        , "uint", PIPE_ACCESS_INBOUND | FILE_FLAG_OVERLAPPED
        , "uint", PIPE_TYPE_BYTE | PIPE_READMODE_BYTE
        , "uint", 1          ; max instances
        , "uint", 0          ; out buffer (inbound only)
        , "uint", 65536      ; in buffer
        , "uint", 0          ; default timeout
        , "ptr", 0           ; security attrs
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
        _KSub_ClientPid := Run('"' KomorebicExe '" subscribe-pipe ' _KSub_PipeName, , "Hide")
    } catch {
        ; Keep server alive, client may connect later
    }

    _KSub_LastEvent := A_TickCount
    _KSub_FallbackMode := false
    SetTimer(KomorebiSub_Poll, KSub_PollMs)

    ; Do initial poll to populate all windows with workspace data immediately
    ; Runs after 1500ms to ensure first winenum scan has populated the store
    SetTimer(_KSub_InitialPoll, -1500)

    return true
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

    ; Handle workspace focus events - update current workspace from event
    if (eventType = "FocusMonitorWorkspaceNumber" || eventType = "FocusWorkspaceNumber" || eventType = "FocusNamedWorkspace") {
        ; content varies by event type:
        ; - FocusMonitorWorkspaceNumber: [monitorIdx, workspaceIdx]
        ; - FocusWorkspaceNumber: [workspaceIdx]
        ; - FocusNamedWorkspace: "WorkspaceName"
        contentRaw := _KSub_ExtractArrayByKey(eventObj, "content")
        if (contentRaw = "") {
            ; Maybe it's a string value
            m := 0
            if RegExMatch(eventObj, '"content"\s*:\s*"([^"]+)"', &m)
                contentRaw := m[1]
        }

        _KSub_Log("  FocusWorkspace content: " contentRaw)

        wsName := ""

        if (eventType = "FocusNamedWorkspace") {
            ; Content is the workspace name directly
            wsName := Trim(contentRaw, '" ')
        } else {
            ; Content is array with index
            parts := _KSub_ArrayTopLevelSplit(contentRaw)
            wsIdx := -1
            if (parts.Length >= 2)
                wsIdx := Integer(Trim(parts[2]))
            else if (parts.Length = 1)
                wsIdx := Integer(Trim(parts[1]))

            if (wsIdx >= 0) {
                monitorsArr := _KSub_GetMonitorsArray(stateObj)
                if (monitorsArr.Length > 0) {
                    monObj := monitorsArr[1]  ; Assume single monitor
                    wsName := _KSub_GetWorkspaceNameByIndex(monObj, wsIdx)
                }
            }
        }

        _KSub_Log("  Focus event resolved wsName='" wsName "'")
        if (wsName != "") {
            global _KSub_LastWorkspaceName
            if (wsName != _KSub_LastWorkspaceName) {
                _KSub_Log("  Updating current workspace to '" wsName "' from focus event")
                _KSub_LastWorkspaceName := wsName
                try WindowStore_SetCurrentWorkspace("", wsName)
            }
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
    ; Skip workspace update from state since focus events handle workspace changes
    _KSub_ProcessFullState(stateObj, true)
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

    _KSub_Log("ProcessFullState: focusedMon=" focusedMonIdx " focusedWs=" (IsSet(focusedWsIdx) ? focusedWsIdx : "N/A") " currentWsName='" currentWsName "' lastWsName='" _KSub_LastWorkspaceName "' skipWsUpdate=" skipWorkspaceUpdate)

    ; Only update current workspace if not skipping (initial poll or direct state query)
    ; Skip if called from notification handler since focus events already update workspace
    if (!skipWorkspaceUpdate && currentWsName != "" && currentWsName != _KSub_LastWorkspaceName) {
        _KSub_Log("  Updating workspace from '" _KSub_LastWorkspaceName "' to '" currentWsName "'")
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
