#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Expected: file is included after window_list.ahk

; Komorebi-lite: poll komorebic state and update current workspace + active window workspace.
; Uses JSON.Load() and komorebi_state.ahk navigation helpers for proper structured parsing.

global _KLite_StateObj := ""   ; Cached parsed JSON object (avoids re-parsing within TTL)
global _KLite_Stamp := 0
; 500ms TTL + 2s timeout is acceptable: komorebi_sub is the primary producer;
; komorebi_lite is a best-effort fallback for when subscription is unavailable.
global _KLite_TTL := 500

; Async state machine for non-blocking komorebic state queries
global _KLite_PendingPid := 0      ; PID of running komorebic process (0 = none)
global _KLite_PendingTmp := ""     ; Temp file path for output
global _KLite_PendingStart := 0    ; A_TickCount when query started
global _KLite_PendingTimeout := 2000  ; Max wait time (ms)

KomorebiLite_Init() {
    ; Check if komorebi is available before starting timer
    if (!_KomorebiLite_IsAvailable())
        return false
    SetTimer(_KomorebiLite_Tick, 1000)
    return true
}

KomorebiLite_Stop() {
    global _KLite_PendingPid, _KLite_PendingTmp
    SetTimer(_KomorebiLite_Tick, 0)
    if (_KLite_PendingPid) {
        try ProcessClose(_KLite_PendingPid)
        _KLite_PendingPid := 0
    }
    if (_KLite_PendingTmp != "") {
        try FileDelete(_KLite_PendingTmp)
        _KLite_PendingTmp := ""
    }
}

_KomorebiLite_Tick() {
    global _KLite_StateObj
    static _errCount := 0
    try {
        if !_KomorebiLite_IsAvailable()
            return
        stateObj := _KomorebiLite_GetState()
        if !(stateObj is Map)
            return
        ws := _KomorebiLite_FindCurrentWorkspaceName(stateObj)
        if (ws != "")
            WL_SetCurrentWorkspace("", ws)
        hwnd := WinGetID("A")
        if (hwnd) {
            wsn := KSub_FindWorkspaceByHwnd(stateObj, hwnd)
            if (wsn != "")
                WL_UpdateFields(hwnd, { workspaceName: wsn, isOnCurrentWorkspace: (wsn = ws) })
        }
        _errCount := 0
    } catch as e {
        global LOG_PATH_STORE
        HandleTimerError(e, &_errCount, _KomorebiLite_Tick, LOG_PATH_STORE, "KomorebiLite_Tick")
    }
}

_KomorebiLite_IsAvailable() {
    global cfg
    return (cfg.KomorebicExe != "" && FileExist(cfg.KomorebicExe))
}

; Get parsed komorebi state object (cached within TTL)
; Non-blocking: returns cached result immediately while async query runs in background
_KomorebiLite_GetState() {
    global _KLite_StateObj, _KLite_Stamp, _KLite_TTL, cfg
    global _KLite_PendingPid, _KLite_PendingTmp, _KLite_PendingStart, _KLite_PendingTimeout

    now := A_TickCount

    ; Phase 2: Check if pending query has completed
    if (_KLite_PendingPid) {
        if (!ProcessExist(_KLite_PendingPid)) {
            ; Process finished - read result
            txt := ""
            try txt := FileRead(_KLite_PendingTmp, "UTF-8")
            try FileDelete(_KLite_PendingTmp)
            _KLite_PendingPid := 0
            _KLite_PendingTmp := ""
            _KLite_PendingStart := 0

            if (txt != "") {
                parsed := ""
                try parsed := JSON.Load(txt)
                if (parsed is Map) {
                    _KLite_StateObj := parsed
                    _KLite_Stamp := now
                    return parsed
                }
            }
            ; Query failed - fall through to return cached or start new
        } else if ((now - _KLite_PendingStart) > _KLite_PendingTimeout) {
            ; Timeout - kill stale process and clean up
            try ProcessClose(_KLite_PendingPid)
            try FileDelete(_KLite_PendingTmp)
            _KLite_PendingPid := 0
            _KLite_PendingTmp := ""
            _KLite_PendingStart := 0
            ; Fall through to return cached or start new
        } else {
            ; Still running within timeout - return cached result
            if (_KLite_StateObj is Map)
                return _KLite_StateObj
            return ""
        }
    }

    ; Return cached if still valid
    if (_KLite_StateObj is Map && (now - _KLite_Stamp) < _KLite_TTL)
        return _KLite_StateObj

    ; Phase 1: Start new async query
    tmp := A_Temp "\komorebi_state_" A_TickCount "_" Random(1000,9999) ".tmp"
    cmd := 'cmd.exe /c "' cfg.KomorebicExe '" state > "' tmp '" 2>&1'

    pid := ProcessUtils_RunHidden(cmd)
    if (pid) {
        _KLite_PendingPid := pid
        _KLite_PendingTmp := tmp
        _KLite_PendingStart := now
    }

    ; Return cached result (may be stale) while query runs
    if (_KLite_StateObj is Map)
        return _KLite_StateObj
    return ""
}

; Find current workspace name from parsed state using navigation helpers
_KomorebiLite_FindCurrentWorkspaceName(stateObj) {
    ; Navigate: focused monitor -> focused workspace -> name
    ; Uses the same helpers as KomorebiSub for consistency
    focusedMonIdx := KSub_GetFocusedMonitorIndex(stateObj)
    monitorsArr := KSub_GetMonitorsArray(stateObj)
    if (focusedMonIdx < 0 || focusedMonIdx >= monitorsArr.Length)
        return ""
    monObj := monitorsArr[focusedMonIdx + 1]  ; AHK 1-based
    focusedWsIdx := KSub_GetFocusedWorkspaceIndex(monObj)
    return KSub_GetWorkspaceNameByIndex(monObj, focusedWsIdx)
}
