#Requires AutoHotkey v2.0

; ============================================================
; Pump Utilities - Shared helpers for timer-based pump modules
; ============================================================
; Provides common patterns for idle detection and timer management
; used by icon_pump.ahk, proc_pump.ahk, and winevent_hook.ahk.
; ============================================================

; Handle idle detection for pump timers
; Call this at the start of a pump tick when there's no work to do.
; Returns true if the timer should continue, false if it was paused.
;
; Parameters:
;   idleTicks (ByRef)  - Counter for consecutive empty ticks
;   threshold          - Number of empty ticks before pausing
;   timerOn (ByRef)    - Whether the timer is currently running
;   timerFn            - The timer callback function to pause
;   logFn (optional)   - Logging function to call when pausing (receives message string)
;
; Example usage:
;   if (!Pump_HandleIdle(&_IP_IdleTicks, _IP_IdleThreshold, &_IP_TimerOn, _IP_Tick, _IP_Log)) {
;       return  ; Timer paused due to idle
;   }
;   _IP_IdleTicks := 0  ; Reset on successful work
;
Pump_HandleIdle(&idleTicks, threshold, &timerOn, timerFn, logFn := "") {
    idleTicks += 1
    if (idleTicks >= threshold && timerOn) {
        SetTimer(timerFn, 0)
        timerOn := false
        if (logFn != "" && IsObject(logFn)) {
            logFn("Timer paused (idle after " idleTicks " empty ticks)")
        }
        return false  ; Timer was paused
    }
    return true  ; Timer continues
}

; Wake a pump timer from idle pause
; Call this when new work is enqueued to ensure the timer is running.
;
; Parameters:
;   timerOn (ByRef)   - Whether the timer is currently running
;   idleTicks (ByRef) - Counter for consecutive empty ticks (will be reset)
;   intervalMs        - Timer interval in milliseconds
;   timerFn           - The timer callback function to start
;
; Example usage:
;   Pump_EnsureRunning(&_IP_TimerOn, &_IP_IdleTicks, IconTimerIntervalMs, _IP_Tick)
;
Pump_EnsureRunning(&timerOn, &idleTicks, intervalMs, timerFn) {
    if (timerOn)
        return  ; Already running
    if (intervalMs <= 0)
        return  ; Not initialized or disabled
    timerOn := true
    idleTicks := 0
    SetTimer(timerFn, intervalMs)
}
