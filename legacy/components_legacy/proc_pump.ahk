#Requires AutoHotkey v2.0
; =============================================================================
; proc_pump.ahk — resolves PID→processName and fans out to WindowStore rows
; Notes:
;   - Uses QueryFullProcessImageNameW (fast, limited privilege).
;   - Updates the store-wide cache via WindowStore_UpdateProcessName(pid, name).
; =============================================================================

; ---------- Tunables ----------------------------------------------------------
if !IsSet(ProcBatchPerTick)
    ProcBatchPerTick := 16
if !IsSet(ProcTimerIntervalMs)
    ProcTimerIntervalMs := 100

; ---------- Module state ------------------------------------------------------
global _PP_TimerOn := false

; ---------- Public API --------------------------------------------------------
ProcPump_Start() {
    global _PP_TimerOn, ProcTimerIntervalMs
    if (_PP_TimerOn)
        return
    _PP_TimerOn := true
    SetTimer(_PP_Tick, ProcTimerIntervalMs)
}

ProcPump_Stop() {
    global _PP_TimerOn
    if !_PP_TimerOn
        return
    _PP_TimerOn := false
    SetTimer(_PP_Tick, 0)
}

; ---------- Core --------------------------------------------------------------
_PP_Tick() {
    global ProcBatchPerTick
    pids := WindowStore_PopPidBatch(ProcBatchPerTick)
    if (!IsObject(pids) || pids.Length = 0)
        return

    for _, pid in pids {
        pid := pid + 0
        if (pid <= 0)
            continue

        cached := WindowStore_GetProcNameCached(pid)
        if (cached != "") {
            ; Ensure any rows missing a name receive it.
            WindowStore_UpdateProcessName(pid, cached)
            continue
        }

        path := _PP_GetProcessPath(pid)
        if (path = "")
            continue

        name := _PP_Basename(path)
        if (name != "")
            WindowStore_UpdateProcessName(pid, name)
        ; (Optionally we could also store exePath per row, but icon pump can fetch path on demand.)
    }
}

; ---------- Helpers -----------------------------------------------------------
_PP_GetProcessPath(pid) {
    h := DllCall("kernel32\OpenProcess", "uint", 0x1000, "int", 0, "uint", pid, "ptr") ; QUERY_LIMITED
    if (!h)
        return ""
    buf := Buffer(32767*2, 0), cch := 32767
    ok := DllCall("kernel32\QueryFullProcessImageNameW", "ptr", h, "uint", 0, "ptr", buf.Ptr, "uint*", &cch, "int")
    DllCall("kernel32\CloseHandle", "ptr", h)
    return ok ? StrGet(buf.Ptr, "UTF-16") : ""
}

_PP_Basename(path) {
    if (path = "")
        return ""
    SplitPath(path, &fn)
    return fn
}
