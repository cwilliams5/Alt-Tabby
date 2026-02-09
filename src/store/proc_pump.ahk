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
global _PP_IdleTicks := 0               ; Counter for consecutive empty ticks
global _PP_IdleThreshold := 5           ; Default, overridden from config in ProcPump_Start()

; Failed PID cache: PIDs that failed lookup are not retried for 60s
; Prevents continuous retries for system processes (csrss, wininit, etc.)
global _PP_FailedPidCache := Map()       ; pid -> tick when failure recorded
global _PP_FailedPidCacheTTL := 60000    ; 60s before retry
; No hard cap — ProcPump_PruneFailedPidCache() on heartbeat removes expired + dead PIDs.

; ========================= DEBUG LOGGING =========================
; Controlled by cfg.DiagProcPumpLog (config.ini [Diagnostics] ProcPumpLog=true)
; Log file: %TEMP%\tabby_procpump.log

_PP_Log(msg) {
    global cfg, LOG_PATH_PROCPUMP
    if (!cfg.DiagProcPumpLog)
        return
    try {
        LogAppend(LOG_PATH_PROCPUMP, msg)
    }
}

; Start the process pump timer
ProcPump_Start() {
    global _PP_TimerOn, ProcTimerIntervalMs, ProcBatchPerTick, cfg

    ; Fail fast if config not initialized (catches initialization order bugs)
    _CL_AssertInitialized("ProcPump_Start")

    ; Load config values on first start (ConfigLoader_Init has already run)
    if (ProcTimerIntervalMs = 0) {
        global _PP_IdleThreshold, _PP_FailedPidCacheTTL
        ProcBatchPerTick := cfg.ProcPumpBatchSize
        ProcTimerIntervalMs := cfg.ProcPumpIntervalMs
        _PP_IdleThreshold := cfg.HasOwnProp("ProcPumpIdleThreshold") ? cfg.ProcPumpIdleThreshold : 5
        _PP_FailedPidCacheTTL := cfg.ProcPumpFailedPidRetryMs
    }

    ; Reset log for new session
    if (cfg.DiagProcPumpLog) {
        global LOG_PATH_PROCPUMP
        LogInitSession(LOG_PATH_PROCPUMP, "Alt-Tabby Process Pump Log")
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

; Ensure the process pump timer is running (wake from idle pause)
; Call this when new work is enqueued to the process queue
ProcPump_EnsureRunning() {
    global _PP_TimerOn, _PP_IdleTicks, ProcTimerIntervalMs
    Pump_EnsureRunning(&_PP_TimerOn, &_PP_IdleTicks, ProcTimerIntervalMs, _PP_Tick)
}

; Main pump tick
_PP_Tick() {
    global ProcBatchPerTick, _PP_IdleTicks, _PP_IdleThreshold, _PP_TimerOn

    pids := WindowStore_PopPidBatch(ProcBatchPerTick)
    if (!IsObject(pids) || pids.Length = 0) {
        ; Idle detection: pause timer after threshold empty ticks to reduce CPU churn
        Pump_HandleIdle(&_PP_IdleTicks, _PP_IdleThreshold, &_PP_TimerOn, _PP_Tick, _PP_Log)
        return
    }
    _PP_IdleTicks := 0  ; Reset idle counter when we have work

    for _, pid in pids {
        pid := pid + 0
        if (pid <= 0)
            continue

        ; Check failed PID cache first - skip recently failed PIDs
        global _PP_FailedPidCache, _PP_FailedPidCacheTTL
        ; RACE FIX: Protect cache read - ProcPump_PruneFailedPidCache runs from heartbeat timer
        Critical "On"
        if (_PP_FailedPidCache.Has(pid) && (A_TickCount - _PP_FailedPidCache[pid]) < _PP_FailedPidCacheTTL) {
            Critical "Off"
            continue
        }
        Critical "Off"

        ; Check positive cache
        cached := WindowStore_GetProcNameCached(pid)
        if (cached != "") {
            WindowStore_UpdateProcessName(pid, cached)
            continue
        }

        ; Resolve process path
        path := _PP_GetProcessPath(pid)
        if (path = "") {
            ; No FIFO cap — ProcPump_PruneFailedPidCache() on heartbeat drains expired/dead PIDs.
            Critical "On"
            _PP_FailedPidCache[pid] := A_TickCount
            Critical "Off"
            continue
        }

        name := _PP_Basename(path)
        if (name != "")
            WindowStore_UpdateProcessName(pid, name)
    }
}

; Get full process path from PID (uses shared utility with logging)
_PP_GetProcessPath(pid) {
    return ProcessUtils_GetPath(pid, _PP_Log)
}

; Extract filename from path (uses shared utility)
_PP_Basename(path) {
    return ProcessUtils_Basename(path)
}

; Prune expired entries from failed PID cache (called from Store_HeartbeatTick)
; Removes PIDs where TTL has expired AND process no longer exists
; RACE FIX: Wrap in Critical - _PP_Tick reads cache on every tick
ProcPump_PruneFailedPidCache() {
    global _PP_FailedPidCache, _PP_FailedPidCacheTTL
    if (!IsObject(_PP_FailedPidCache) || _PP_FailedPidCache.Count = 0)
        return 0

    Critical "On"
    now := A_TickCount
    toDelete := []
    for pid, tick in _PP_FailedPidCache {
        ; Only prune if TTL expired AND process no longer exists
        ; (if process restarted with same PID, we want to retry)
        if ((now - tick) >= _PP_FailedPidCacheTTL && !ProcessExist(pid))
            toDelete.Push(pid)
    }
    for _, pid in toDelete
        _PP_FailedPidCache.Delete(pid)
    Critical "Off"
    return toDelete.Length
}
