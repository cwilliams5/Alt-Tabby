#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Expected: file is included after windowstore.ahk

; ============================================================
; Komorebi Subscription Producer
; ============================================================
; Event-driven komorebi integration using named pipe subscription
; Falls back to polling if subscription fails
;
; Features:
;   - Named pipe server for komorebic subscribe-pipe
;   - Non-blocking reads with overlapped I/O
;   - Auto-reconnect on disconnect
;   - Workspace tracking and WindowStore updates
; ============================================================

; Configuration (can be overridden before Init)
global KomorebicExe := "C:\Program Files\komorebi\bin\komorebic.exe"
global KSub_PollMs := 50           ; Timer interval for pipe polling
global KSub_IdleRecycleMs := 120000  ; Restart if no events this long

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

; Initialize komorebi subscription
KomorebiSub_Init() {
    global _KSub_PipeName
    _KSub_PipeName := "tabby_" A_TickCount "_" Random(1000, 9999)

    if (!KomorebiSub_IsAvailable()) {
        ; Fall back to polling mode
        _KSub_FallbackMode := true
        SetTimer(KomorebiSub_PollFallback, 2000)
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

    ; Create overlapped Named Pipe server
    PIPE_ACCESS_INBOUND := 0x00000001
    FILE_FLAG_OVERLAPPED := 0x40000000
    PIPE_TYPE_MESSAGE := 0x00000004
    PIPE_READMODE_MESSAGE := 0x00000002
    PIPE_WAIT := 0x00000000

    pipePath := "\\.\pipe\" _KSub_PipeName
    _KSub_hPipe := DllCall("CreateNamedPipeW"
        , "str", pipePath
        , "uint", PIPE_ACCESS_INBOUND | FILE_FLAG_OVERLAPPED
        , "uint", PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT
        , "uint", 1          ; max instances
        , "uint", 65536      ; out buffer
        , "uint", 65536      ; in buffer
        , "uint", 0          ; default timeout
        , "ptr", 0           ; security attrs
        , "ptr")

    if (_KSub_hPipe = 0 || _KSub_hPipe = -1) {
        _KSub_hPipe := 0
        _KSub_FallbackMode := true
        SetTimer(KomorebiSub_PollFallback, 2000)
        return false
    }

    ; Create event for overlapped connect
    _KSub_hEvent := DllCall("CreateEventW", "ptr", 0, "int", 1, "int", 0, "ptr", 0, "ptr")
    if (!_KSub_hEvent) {
        KomorebiSub_Stop()
        _KSub_FallbackMode := true
        SetTimer(KomorebiSub_PollFallback, 2000)
        return false
    }

    ; Allocate OVERLAPPED structure
    overSize := (A_PtrSize = 8) ? 32 : 20
    _KSub_Over := Buffer(overSize, 0)
    NumPut("ptr", _KSub_hEvent, _KSub_Over, (A_PtrSize = 8) ? 24 : 16)

    ; Begin async connect
    ok := DllCall("ConnectNamedPipe", "ptr", _KSub_hPipe, "ptr", _KSub_Over.Ptr, "int")
    if (!ok) {
        gle := DllCall("GetLastError", "uint")
        if (gle = 997)        ; ERROR_IO_PENDING
            _KSub_Connected := false
        else if (gle = 535)   ; ERROR_PIPE_CONNECTED
            _KSub_Connected := true
        else {
            KomorebiSub_Stop()
            _KSub_FallbackMode := true
            SetTimer(KomorebiSub_PollFallback, 2000)
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
    return true
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

; Poll timer - check connection and read data
KomorebiSub_Poll() {
    global _KSub_hPipe, _KSub_hEvent, _KSub_Over, _KSub_Connected
    global _KSub_LastEvent, KSub_IdleRecycleMs

    if (!_KSub_hPipe) {
        KomorebiSub_Start()
        return
    }

    ; Check connection status
    if (!_KSub_Connected) {
        res := DllCall("kernel32\WaitForSingleObject", "ptr", _KSub_hEvent, "uint", 0, "uint")
        if (res = 0)  ; WAIT_OBJECT_0
            _KSub_Connected := true
        return
    }

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

        buf := Buffer(Min(avail, 65536))
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
        _KSub_ProcessChunk(chunk)
        bytesRead += read

        if (bytesRead >= 65536)
            break
    }

    ; Recycle if idle too long
    if ((A_TickCount - _KSub_LastEvent) > KSub_IdleRecycleMs)
        KomorebiSub_Start()
}

; Process incoming data chunk
_KSub_ProcessChunk(chunk) {
    global _KSub_Buf
    _KSub_Buf .= chunk

    while true {
        pos := InStr(_KSub_Buf, "`n")
        if (!pos)
            break
        line := RTrim(SubStr(_KSub_Buf, 1, pos - 1), "`r")
        _KSub_Buf := SubStr(_KSub_Buf, pos + 1)
        if (line != "")
            _KSub_OnLine(line)
    }
}

; Parse JSON event line
_KSub_OnLine(line) {
    global _KSub_LastWorkspaceName

    hwnd := 0
    ws := ""

    ; Extract hwnd
    if RegExMatch(line, '"hwnd"\s*:\s*(\d+)', &m)
        hwnd := Integer(m[1])

    ; Extract workspace name (various formats)
    if RegExMatch(line, '"workspace_name"\s*:\s*"([^"]+)"', &n)
        ws := n[1]
    else if RegExMatch(line, '"focused_workspace"\s*:\s*"([^"]+)"', &n)
        ws := n[1]

    ; Update WindowStore if we have workspace info
    if (ws != "") {
        ; Track current workspace
        if (_KSub_LastWorkspaceName != ws) {
            _KSub_LastWorkspaceName := ws
            try WindowStore_SetCurrentWorkspace("", ws)
        }

        ; Update specific window if hwnd present
        if (hwnd) {
            isCurrent := (ws = _KSub_LastWorkspaceName)
            try WindowStore_UpdateFields(hwnd, {
                workspaceName: ws,
                isOnCurrentWorkspace: isCurrent
            })
        }
    }
}

; Fallback polling mode (when subscription fails)
KomorebiSub_PollFallback() {
    global _KSub_LastWorkspaceName

    if (!KomorebiSub_IsAvailable())
        return

    ; Get state via command
    txt := _KSub_GetStateFallback()
    if (txt = "")
        return

    ; Extract current workspace name
    ws := _KSub_GetCurrentWorkspaceName(txt)

    if (ws != "" && ws != _KSub_LastWorkspaceName) {
        _KSub_LastWorkspaceName := ws
        try WindowStore_SetCurrentWorkspace("", ws)
    }

    ; Map ALL windows to their workspaces
    _KSub_UpdateAllWindowWorkspaces(txt, _KSub_LastWorkspaceName)
}

; Extract current workspace name from komorebi state
_KSub_GetCurrentWorkspaceName(txt) {
    if (txt = "")
        return ""

    ; Try explicit focused_workspace_name first
    m := 0
    if RegExMatch(txt, '"focused_workspace_name"\s*:\s*"([^"]+)"', &m)
        return m[1]

    ; Try last_focused_workspace (index) - need to find name by index
    if RegExMatch(txt, '"last_focused_workspace"\s*:\s*(\d+)', &m) {
        idx := Integer(m[1])
        ; Find workspace name at this index within the same monitor's workspaces
        ; Look for "workspaces" block, then find the nth "name" entry
        pos := m.Pos(0)
        ; Search backwards for "workspaces" to find the workspace array
        backText := SubStr(txt, 1, pos)
        wsPos := 0
        searchPos := 1
        while (p := InStr(backText, '"workspaces"', , searchPos)) {
            wsPos := p
            searchPos := p + 1
        }
        if (wsPos > 0) {
            ; From wsPos, find workspace names in order
            wsBlock := SubStr(txt, wsPos, pos - wsPos + 500)
            names := []
            posN := 1
            mn := 0
            while (q := RegExMatch(wsBlock, '"name"\s*:\s*"([^"]+)"', &mn, posN)) {
                names.Push(mn[1])
                posN := mn.Pos(0) + mn.Len(0)
            }
            if (idx >= 0 && idx < names.Length)
                return names[idx + 1]  ; AHK arrays are 1-based
        }
    }

    ; Fallback: get active window's workspace
    hwnd := 0
    try hwnd := WinGetID("A")
    if (hwnd) {
        return _KSub_FindWorkspaceByHwnd(txt, hwnd)
    }

    return ""
}

_KSub_GetStateFallback() {
    global KomorebicExe
    tmp := A_Temp "\komorebi_state_" A_TickCount ".tmp"
    cmd := 'cmd.exe /c "' KomorebicExe '" state > "' tmp '" 2>&1'
    try RunWait(cmd, , "Hide")
    txt := ""
    try txt := FileRead(tmp, "UTF-8")
    try FileDelete(tmp)
    return txt
}

_KSub_FindWorkspaceByHwnd(txt, hwnd) {
    if (txt = "" || !hwnd)
        return ""
    pos := RegExMatch(txt, '"hwnd"\s*:\s*' hwnd '\b')
    if (pos = 0)
        return ""
    ; Search backwards for workspace name
    back := SubStr(txt, 1, pos)
    names := []
    searchPos := 1
    while (p := RegExMatch(back, '"name"\s*:\s*"([^"]+)"', &m, searchPos)) {
        names.Push({ pos: p, name: m[1] })
        searchPos := p + StrLen(m[0])
    }
    if (names.Length = 0)
        return ""
    ; Return most recent name before hwnd that's in a containers block
    i := names.Length
    while (i >= 1) {
        cand := names[i]
        block := SubStr(txt, cand.pos, pos - cand.pos)
        if InStr(block, '"containers"')
            return cand.name
        i -= 1
    }
    return ""
}

; Update ALL windows with their workspace info from komorebi state
_KSub_UpdateAllWindowWorkspaces(txt, currentWS) {
    global gWS_Store
    if (txt = "")
        return

    ; Get list of all hwnds in WindowStore
    hwnds := []
    for hwnd, _ in gWS_Store {
        hwnds.Push(hwnd)
    }

    ; For each hwnd, look up its workspace in komorebi state
    for _, hwnd in hwnds {
        wsName := _KSub_FindWorkspaceByHwnd(txt, hwnd)
        if (wsName != "") {
            isCurrent := (wsName = currentWS)
            try WindowStore_UpdateFields(hwnd, {
                workspaceName: wsName,
                isOnCurrentWorkspace: isCurrent
            })
        }
    }
}
