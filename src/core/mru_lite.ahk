#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Expected: file is included after window_list.ahk

; MRU-lite: track active window and update lastActivatedTick in store.
; This is a FALLBACK - only used if WinEventHook fails to start.

; Configuration (set in MRU_Lite_Init after ConfigLoader_Init)
global MruLiteIntervalMs := 0

global _MRU_LastHwnd := 0
global _MRU_TimerOn := false
global _MRU_IdleTicks := 0
global _MRU_IdleThreshold := 5

MRU_Lite_Init() {
    global MruLiteIntervalMs, cfg, _MRU_TimerOn

    ; Fail fast if config not initialized (catches initialization order bugs)
    CL_AssertInitialized("MRU_Lite_Init")

    ; Load config values (ConfigLoader_Init has already run)
    MruLiteIntervalMs := cfg.MruLitePollMs

    _MRU_TimerOn := true
    SetTimer(MRU_Lite_Tick, MruLiteIntervalMs)  ; lint-ignore: timer-lifecycle (process-lifetime fallback poller)
}

MRU_Lite_EnsureRunning() {
    global _MRU_TimerOn, _MRU_IdleTicks, MruLiteIntervalMs
    Pump_EnsureRunning(&_MRU_TimerOn, &_MRU_IdleTicks, MruLiteIntervalMs, MRU_Lite_Tick)
}

MRU_Lite_Tick() {
    global _MRU_LastHwnd, _MRU_TimerOn, _MRU_IdleTicks, _MRU_IdleThreshold
    static _errCount := 0  ; Error boundary: consecutive error tracking (safe static — reset on success, conservative on timer restart)
    static _backoffUntil := 0  ; Tick-based cooldown for exponential backoff
    if (A_TickCount < _backoffUntil)
        return
    try {
        hwnd := 0
        try {
            hwnd := WinGetID("A")
        } catch {
            ; No active window (e.g., during workspace switch)
            return
        }
        if (!hwnd || hwnd = _MRU_LastHwnd) {
            Pump_HandleIdle(&_MRU_IdleTicks, _MRU_IdleThreshold, &_MRU_TimerOn, MRU_Lite_Tick)
            return
        }
        _MRU_IdleTicks := 0
        ; Batch both focus updates into single rev bump
        ; WL_BatchUpdateFields handles its own Critical for store atomicity
        patches := Map()
        if (_MRU_LastHwnd)
            patches[_MRU_LastHwnd] := {isFocused: false}
        patches[hwnd] := {lastActivatedTick: A_TickCount, isFocused: true}
        _MRU_LastHwnd := hwnd
        try WL_BatchUpdateFields(patches, "mru_lite")
        _errCount := 0
        _backoffUntil := 0
    } catch as e {
        global LOG_PATH_STORE
        HandleTimerError(e, &_errCount, &_backoffUntil, LOG_PATH_STORE, "MRU_Lite_Tick")
    }
}
