#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Expected: file is included after windowstore.ahk

; Komorebi-lite: poll komorebic state and update current workspace + active window workspace.
; Uses JSON.Load() and komorebi_state.ahk navigation helpers for proper structured parsing.

global _KLite_StateText := ""
global _KLite_StateObj := ""   ; Cached parsed JSON object (avoids re-parsing within TTL)
global _KLite_Stamp := 0
global _KLite_TTL := 500

KomorebiLite_Init() {
    ; Check if komorebi is available before starting timer
    if (!KomorebiLite_IsAvailable())
        return false
    SetTimer(KomorebiLite_Tick, 1000)
    return true
}

KomorebiLite_Stop() {
    SetTimer(KomorebiLite_Tick, 0)
}

KomorebiLite_Tick() {
    global _KLite_StateObj
    if !KomorebiLite_IsAvailable()
        return
    stateObj := KomorebiLite_GetState()
    if !(stateObj is Map)
        return
    ws := KomorebiLite_FindCurrentWorkspaceName(stateObj)
    if (ws != "")
        WindowStore_SetCurrentWorkspace("", ws)
    hwnd := WinGetID("A")
    if (hwnd) {
        wsn := _KSub_FindWorkspaceByHwnd(stateObj, hwnd)
        if (wsn != "")
            WindowStore_UpdateFields(hwnd, { workspaceName: wsn, isOnCurrentWorkspace: (wsn = ws) })
    }
}

KomorebiLite_IsAvailable() {
    global cfg
    return (cfg.KomorebicExe != "" && FileExist(cfg.KomorebicExe))
}

; Get parsed komorebi state object (cached within TTL)
KomorebiLite_GetState() {
    global _KLite_StateText, _KLite_StateObj, _KLite_Stamp, _KLite_TTL, cfg
    now := A_TickCount
    if (_KLite_StateObj is Map && (now - _KLite_Stamp) < _KLite_TTL)
        return _KLite_StateObj

    tmp := A_Temp "\komorebi_state_" A_TickCount "_" Random(1000,9999) ".tmp"
    cmd := 'cmd.exe /c "' cfg.KomorebicExe '" state > "' tmp '" 2>&1'

    ; Use async Run + poll instead of blocking RunWait to avoid freezing the
    ; store thread for 100-500ms every second. Poll with short sleep intervals
    ; up to a timeout so we yield control back to AHK's message loop.
    pid := ProcessUtils_RunHidden(cmd)
    if (pid) {
        timeout := 2000  ; Max wait 2s (RunWait had no timeout)
        pollInterval := 25
        waited := 0
        while (ProcessExist(pid) && waited < timeout) {
            Sleep(pollInterval)
            waited += pollInterval
        }
    }

    txt := ""
    try txt := FileRead(tmp, "UTF-8")
    try FileDelete(tmp)
    if (txt = "")
        return ""

    ; Parse JSON once (cJson parses typical komorebi state in <1ms)
    parsed := ""
    try parsed := JSON.Load(txt)
    if !(parsed is Map)
        return ""

    _KLite_StateText := txt
    _KLite_StateObj := parsed
    _KLite_Stamp := now
    return parsed
}

; Find current workspace name from parsed state using navigation helpers
KomorebiLite_FindCurrentWorkspaceName(stateObj) {
    ; Navigate: focused monitor -> focused workspace -> name
    ; Uses the same helpers as KomorebiSub for consistency
    focusedMonIdx := _KSub_GetFocusedMonitorIndex(stateObj)
    monitorsArr := _KSub_GetMonitorsArray(stateObj)
    if (focusedMonIdx < 0 || focusedMonIdx >= monitorsArr.Length)
        return ""
    monObj := monitorsArr[focusedMonIdx + 1]  ; AHK 1-based
    focusedWsIdx := _KSub_GetFocusedWorkspaceIndex(monObj)
    return _KSub_GetWorkspaceNameByIndex(monObj, focusedWsIdx)
}
