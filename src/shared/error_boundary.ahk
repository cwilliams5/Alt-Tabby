#Requires AutoHotkey v2.0

; Shared error boundary for timer callbacks.
; Logs error, increments counter, disables timer after maxErrors consecutive failures.
; Caller keeps `static _errCount := 0` (correct ownership) and passes it by-ref.
HandleTimerError(e, &errCount, timerFn, logPath, label, maxErrors := 3) {
    Critical "Off"
    errCount++
    try LogAppend(logPath, label " err=" e.Message " file=" e.File " line=" e.Line " consecutive=" errCount)
    if (errCount >= maxErrors) {
        try LogAppend(logPath, label " DISABLED after " errCount " consecutive errors")
        SetTimer(timerFn, 0)
    }
}
