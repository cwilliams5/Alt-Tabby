#Requires AutoHotkey v2.0
; bench_common.ahk — Shared timing and reporting utilities for benchmarks
; Usage: #Include bench_common.ahk

; High-resolution timer
class QPC {
    static freq := 0
    static __New() {
        DllCall("QueryPerformanceFrequency", "Int64*", &f := 0)
        QPC.freq := f
    }
    static Now() {
        DllCall("QueryPerformanceCounter", "Int64*", &t := 0)
        return t
    }
    static ElapsedUs(start, end) {
        return (end - start) * 1000000.0 / QPC.freq
    }
}

; Run a benchmark: warm up, then measure N iterations
; fn: callable with no args (use fat arrow closure to bind data)
; Returns: Map with min, max, mean, p50, p95, p99, count, total_us
Bench_Run(fn, iterations := 1000, warmup := 100, label := "") {
    ; Warm up
    loop warmup
        fn()

    ; Collect timings
    times := []
    times.Length := iterations
    loop iterations {
        s := QPC.Now()
        fn()
        e := QPC.Now()
        times[A_Index] := QPC.ElapsedUs(s, e)
    }

    ; Sort for percentiles
    times := _Bench_SortFloats(times)

    ; Compute stats
    total := 0.0
    for _, v in times
        total += v

    result := Map()
    result["label"] := label
    result["count"] := iterations
    result["total_us"] := total
    result["mean"] := total / iterations
    result["min"] := times[1]
    result["max"] := times[iterations]
    result["p50"] := times[_Bench_Percentile(iterations, 50)]
    result["p95"] := times[_Bench_Percentile(iterations, 95)]
    result["p99"] := times[_Bench_Percentile(iterations, 99)]
    return result
}

; Run a batch benchmark: measure N iterations of a function that processes
; a batch internally (e.g., loop over 50 windows). Reports per-call AND per-item.
Bench_RunBatch(fn, batchSize, iterations := 1000, warmup := 100, label := "") {
    result := Bench_Run(fn, iterations, warmup, label)
    result["batch_size"] := batchSize
    result["per_item_us"] := result["mean"] / batchSize
    return result
}

; Print a result map as a formatted line
Bench_Print(result) {
    label := result["label"]
    mean := result["mean"]
    p50 := result["p50"]
    p95 := result["p95"]
    p99 := result["p99"]
    min := result["min"]
    max := result["max"]

    line := Format("{:-30s}  mean={:8.1f}us  p50={:8.1f}us  p95={:8.1f}us  p99={:8.1f}us  min={:8.1f}us  max={:8.1f}us"
        , label, mean, p50, p95, p99, min, max)

    if (result.Has("per_item_us"))
        line .= Format("  per_item={:.2f}us", result["per_item_us"])

    FileAppend(line "`n", "*")  ; stdout
}

; Print section header
Bench_Header(title) {
    FileAppend("`n" title "`n" _Bench_Repeat("=", StrLen(title)) "`n", "*")
}

; --- Internal helpers ---

_Bench_Percentile(n, pct) {
    idx := Ceil(n * pct / 100)
    return (idx < 1) ? 1 : (idx > n) ? n : idx
}

_Bench_SortFloats(arr) {
    ; Simple insertion sort — fine for 1K-10K elements
    n := arr.Length
    loop n {
        i := A_Index
        if (i = 1)
            continue
        key := arr[i]
        j := i - 1
        while (j >= 1 && arr[j] > key) {
            arr[j + 1] := arr[j]
            j -= 1
        }
        arr[j + 1] := key
    }
    return arr
}

_Bench_Repeat(char, count) {
    s := ""
    loop count
        s .= char
    return s
}

; Generate a random string of given byte length (ASCII printable)
Bench_RandomString(byteLen) {
    s := ""
    loop byteLen
        s .= Chr(Random(32, 126))
    return s
}

; Generate a string of given byte length (repeated pattern, faster than random)
Bench_PatternString(byteLen, pattern := "The quick brown fox jumps over the lazy dog. ") {
    s := ""
    while (StrLen(s) < byteLen)
        s .= pattern
    return SubStr(s, 1, byteLen)
}
