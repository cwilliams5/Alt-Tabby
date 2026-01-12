#Requires AutoHotkey v2.0

; Komorebi-lite: poll komorebic state and update current workspace + active window workspace.

global _KLite_StateText := ""
global _KLite_Stamp := 0
global _KLite_TTL := 500

KomorebiLite_Init() {
    SetTimer(KomorebiLite_Tick, 1000)
}

KomorebiLite_Tick() {
    if !KomorebiLite_IsAvailable()
        return
    txt := KomorebiLite_GetStateText()
    if (txt = "")
        return
    ws := KomorebiLite_FindCurrentWorkspaceName(txt)
    if (ws != "")
        WindowStore_SetCurrentWorkspace("", ws)
    hwnd := WinGetID("A")
    if (hwnd) {
        wsn := KomorebiLite_FindWorkspaceNameByHwnd(txt, hwnd)
        if (wsn != "")
            WindowStore_UpdateFields(hwnd, { workspaceName: wsn, isOnCurrentWorkspace: (wsn = ws) })
    }
}

KomorebiLite_IsAvailable() {
    global KomorebicExe
    return (IsSet(KomorebicExe) && KomorebicExe != "" && FileExist(KomorebicExe))
}

KomorebiLite_GetStateText() {
    global _KLite_StateText, _KLite_Stamp, _KLite_TTL, KomorebicExe
    now := A_TickCount
    if (_KLite_StateText != "" && (now - _KLite_Stamp) < _KLite_TTL)
        return _KLite_StateText
    tmp := A_Temp "\komorebi_state_" A_TickCount "_" Random(1000,9999) ".tmp"
    cmd := 'cmd.exe /c "' KomorebicExe '" state > "' tmp '" 2>&1'
    RunWait(cmd, , "Hide")
    txt := ""
    try txt := FileRead(tmp, "UTF-8")
    try FileDelete(tmp)
    if (txt != "") {
        _KLite_StateText := txt
        _KLite_Stamp := now
    }
    return txt
}

KomorebiLite_FindCurrentWorkspaceName(txt) {
    if RegExMatch(txt, '"focused_workspace"\s*:\s*"([^"]+)"', &m)
        return m[1]
    return ""
}

KomorebiLite_FindWorkspaceNameByHwnd(txt, hwnd) {
    if (txt = "" || !hwnd)
        return ""
    pos := RegExMatch(txt, '"hwnd"\s*:\s*' hwnd '\b', &m, 1)
    if (pos = 0)
        return ""
    back := SubStr(txt, 1, pos)
    names := []
    searchPos := 1
    mm := 0
    while (p := RegExMatch(back, '"name"\s*:\s*"([^"]+)"', &mm, searchPos)) {
        names.Push({ pos: p, name: mm[1], len: StrLen(mm[0]) })
        searchPos := p + StrLen(mm[0])
    }
    if (names.Length = 0)
        return ""
    i := names.Length
    loop {
        if (i <= 0)
            break
        cand := names[i]
        block := SubStr(txt, cand.pos, pos - cand.pos)
        if InStr(block, '"containers"')
            return cand.name
        i -= 1
    }
    return ""
}
