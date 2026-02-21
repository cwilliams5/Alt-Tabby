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
