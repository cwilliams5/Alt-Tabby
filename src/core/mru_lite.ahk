#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Expected: file is included after window_list.ahk

; MRU-lite: track active window and update lastActivatedTick in store.
; This is a FALLBACK - only used if WinEventHook fails to start.

; Configuration (set in MRU_Lite_Init after ConfigLoader_Init)
global MruLiteIntervalMs := 0

global _MRU_LastHwnd := 0

MRU_Lite_Init() {
    global MruLiteIntervalMs, cfg

    ; Fail fast if config not initialized (catches initialization order bugs)
    CL_AssertInitialized("MRU_Lite_Init")

    ; Load config values (ConfigLoader_Init has already run)
    MruLiteIntervalMs := cfg.MruLitePollMs

    SetTimer(MRU_Lite_Tick, MruLiteIntervalMs)  ; lint-ignore: timer-lifecycle (process-lifetime fallback poller)
}

MRU_Lite_Tick() {
    global _MRU_LastHwnd
    static _errCount := 0  ; Error boundary: consecutive error tracking (safe static — reset on success, conservative on timer restart)
    try {
        hwnd := 0
        try {
            hwnd := WinGetID("A")
        } catch {
            ; No active window (e.g., during workspace switch)
            return
        }
        if (!hwnd || hwnd = _MRU_LastHwnd) {
            return
        }
        ; Atomic focus update - prevent race conditions with other timers/hotkeys
        Critical "On"
        ; Clear focus on previous window
        if (_MRU_LastHwnd) {
            try {
                WL_UpdateFields(_MRU_LastHwnd, { isFocused: false })
            }
        }
        _MRU_LastHwnd := hwnd
        try {
            WL_UpdateFields(hwnd, { lastActivatedTick: A_TickCount, isFocused: true })
        }
        Critical "Off"
        _errCount := 0
    } catch as e {
        global LOG_PATH_STORE
        HandleTimerError(e, &_errCount, MRU_Lite_Tick, LOG_PATH_STORE, "MRU_Lite_Tick")
    }
}
