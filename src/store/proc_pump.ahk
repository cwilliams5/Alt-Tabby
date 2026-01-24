#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Expected: file is included after windowstore.ahk

; ============================================================
; Process Pump - Resolves PID -> process name asynchronously
; ============================================================
; Uses QueryFullProcessImageNameW (fast, limited privilege)
; Caches results and fans out to all WindowStore rows with same PID
; ============================================================

; Configuration (set in ProcPump_Start after ConfigLoader_Init)
global ProcBatchPerTick := 0
global ProcTimerIntervalMs := 0

; State
global _PP_TimerOn := false

; ========================= DEBUG LOGGING =========================
; Controlled by cfg.DiagProcPumpLog (config.ini [Diagnostics] ProcPumpLog=true)
; Log file: %TEMP%\tabby_procpump.log

_PP_Log(msg) {
    global cfg
    if (!cfg.DiagProcPumpLog)
        return
    try {
        logFile := A_Temp "\tabby_procpump.log"
        ts := FormatTime(, "HH:mm:ss") "." SubStr("000" Mod(A_TickCount, 1000), -2)
        FileAppend(ts " " msg "`n", logFile, "UTF-8")
    }
}

; Start the process pump timer
ProcPump_Start() {
    global _PP_TimerOn, ProcTimerIntervalMs, ProcBatchPerTick, cfg

    ; Load config values on first start (ConfigLoader_Init has already run)
    if (ProcTimerIntervalMs = 0) {
        ProcBatchPerTick := cfg.ProcPumpBatchSize
        ProcTimerIntervalMs := cfg.ProcPumpIntervalMs
    }

    if (_PP_TimerOn)
        return
    _PP_TimerOn := true
    SetTimer(_PP_Tick, ProcTimerIntervalMs)
}

; Stop the process pump timer
ProcPump_Stop() {
    global _PP_TimerOn
    if (!_PP_TimerOn)
        return
    _PP_TimerOn := false
    SetTimer(_PP_Tick, 0)
}

; Main pump tick
_PP_Tick() {
    global ProcBatchPerTick

    pids := WindowStore_PopPidBatch(ProcBatchPerTick)
    if (!IsObject(pids) || pids.Length = 0)
        return

    for _, pid in pids {
        pid := pid + 0
        if (pid <= 0)
            continue

        ; Check cache first
        cached := WindowStore_GetProcNameCached(pid)
        if (cached != "") {
            WindowStore_UpdateProcessName(pid, cached)
            continue
        }

        ; Resolve process path
        path := _PP_GetProcessPath(pid)
        if (path = "")
            continue

        name := _PP_Basename(path)
        if (name != "")
            WindowStore_UpdateProcessName(pid, name)
    }
}

; Get full process path from PID
_PP_GetProcessPath(pid) {
    ; PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    h := DllCall("kernel32\OpenProcess", "uint", 0x1000, "int", 0, "uint", pid, "ptr")
    if (!h) {
        gle := DllCall("kernel32\GetLastError", "uint")
        _PP_Log("OpenProcess FAILED pid=" pid " err=" gle)
        return ""
    }
    buf := Buffer(32767 * 2, 0)
    cch := 32767
    ok := DllCall("kernel32\QueryFullProcessImageNameW", "ptr", h, "uint", 0, "ptr", buf.Ptr, "uint*", &cch, "int")
    DllCall("kernel32\CloseHandle", "ptr", h)
    if (!ok) {
        gle := DllCall("kernel32\GetLastError", "uint")
        _PP_Log("QueryFullProcessImageNameW FAILED pid=" pid " err=" gle)
        return ""
    }
    return StrGet(buf.Ptr, "UTF-16")
}

; Extract filename from path
_PP_Basename(path) {
    if (path = "")
        return ""
    SplitPath(path, &fn)
    return fn
}
