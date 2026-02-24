#Requires AutoHotkey v2.0

; Shared error boundary for timer callbacks.
; Logs error, increments counter, enters exponential backoff after maxErrors consecutive failures.
; Caller keeps `static _errCount := 0, _backoffUntil := 0` and passes both by-ref.
; On success path, caller resets both to 0.
;
; Backoff: 5s → 10s → 20s → ... → 5min cap. Timer keeps running at its normal interval,
; but each tick early-returns while A_TickCount < _backoffUntil (tick-based cooldown).
; This avoids timer state synchronization with Pump_HandleIdle/Pump_EnsureRunning.
;
; Returns: backoff duration in ms (>0 means backoff was triggered), or 0 if within threshold.
HandleTimerError(e, &errCount, &backoffUntil, logPath, label, maxErrors := 3) {
    Critical "Off"
    errCount++
    try LogAppend(logPath, label " err=" e.Message " file=" e.File " line=" e.Line " consecutive=" errCount)
    if (errCount >= maxErrors) {
        ; Calculate exponential backoff: 5s, 10s, 20s, 40s, 80s, 160s, 300s cap
        static EB_INITIAL_BACKOFF_MS := 5000
        static EB_MAX_BACKOFF_MS := 300000
        overshoot := errCount - maxErrors  ; 0 on first trigger
        backoffMs := EB_INITIAL_BACKOFF_MS
        loop overshoot
            backoffMs := Min(backoffMs * 2, EB_MAX_BACKOFF_MS)
        backoffUntil := A_TickCount + backoffMs
        try LogAppend(logPath, label " BACKOFF " backoffMs "ms after " errCount " consecutive errors (until tick " backoffUntil ")")
        ; Flight recorder event (safe: catch guards against FR globals not being available)
        try {
            global FR_EV_PRODUCER_BACKOFF, gFR_Enabled
            if (gFR_Enabled)
                FR_Record(FR_EV_PRODUCER_BACKOFF, errCount, backoffMs)
        } catch {
        }
        return backoffMs
    }
    return 0
}
