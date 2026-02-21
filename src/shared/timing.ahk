#Requires AutoHotkey v2.0
; QPC() — sub-microsecond timestamp in milliseconds (float).
; Cost: ~100ns per call (one DllCall). Use for diagnostics only.
; Returns: ms since system boot as float, e.g. 12345678.123

QPC() {
    static f := 0
    if (f = 0) {
        DllCall("QueryPerformanceFrequency", "int64*", &freq := 0)
        f := freq / 1000  ; Convert to ms divisor once
    }
    DllCall("QueryPerformanceCounter", "int64*", &c := 0)
    return c / f
}

; HiSleep(ms) — high-precision sleep via QPC spin-loop.
; For ms > 20: uses native Sleep for bulk, QPC spin for tail.
; For ms <= 20: pure QPC spin-loop with NtYieldExecution.
; Cost: burns CPU during spin phase. Use only where precision matters.
HiSleep(ms) {
    target := QPC() + ms
    if (ms > 20)
        Sleep(ms - 20)
    while (QPC() < target)
        DllCall("ntdll\NtYieldExecution")
}
