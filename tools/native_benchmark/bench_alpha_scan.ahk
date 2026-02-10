#Requires AutoHotkey v2.0
#SingleInstance Off

; bench_alpha_scan.ahk — Benchmark pixel-by-pixel alpha channel scanning
;
; Measures:
; 1. Current AHK NumGet loop (worst case: all zero alpha)
; 2. Current AHK NumGet loop (best case: first pixel has alpha)
; 3. Mask application loop (NumGet + NumPut per pixel)
; 4. Native memchr-style scan via msvcrt (baseline comparison)

#Include %A_ScriptDir%\bench_common.ahk

FileAppend("bench_alpha_scan.ahk — Icon Alpha Channel Scan Benchmark`n", "*")
FileAppend("=====================================================`n", "*")

; Icon sizes to test (width = height)
iconSizes := [16, 32, 48, 64, 128, 256]

; ============================================================
; BENCHMARK 1: Alpha scan — WORST CASE (all zero alpha)
; ============================================================
Bench_Header("1. Alpha Scan — Worst Case (all alpha bytes = 0)")

; Current production loop (from gui_gdip.ahk:437-446)
_AlphaScan_Current(pixels, pixelDataSize) {
    hasAlpha := false
    loop pixelDataSize // 4 {
        if (NumGet(pixels, (A_Index - 1) * 4 + 3, "uchar") > 0) {
            hasAlpha := true
            break
        }
    }
    return hasAlpha
}

for _, sz in iconSizes {
    w := sz, h := sz
    pixelDataSize := w * h * 4
    pixels := Buffer(pixelDataSize, 0)  ; All zeros = worst case

    pixelCount := w * h
    iters := (pixelCount <= 1024) ? 5000 : (pixelCount <= 4096) ? 2000 : 500

    result := Bench_RunBatch(
        (() => _AlphaScan_Current(pixels, pixelDataSize)),
        pixelCount, iters, 50,
        "worst " w "x" h " (" pixelCount "px)"
    )
    Bench_Print(result)
}

; ============================================================
; BENCHMARK 2: Alpha scan — BEST CASE (first pixel has alpha)
; ============================================================
Bench_Header("2. Alpha Scan — Best Case (first pixel has alpha > 0)")

for _, sz in iconSizes {
    w := sz, h := sz
    pixelDataSize := w * h * 4
    pixels := Buffer(pixelDataSize, 0)
    NumPut("uchar", 255, pixels, 3)  ; First pixel has alpha

    pixelCount := w * h
    iters := 10000

    result := Bench_RunBatch(
        (() => _AlphaScan_Current(pixels, pixelDataSize)),
        pixelCount, iters, 200,
        "best " w "x" h " (" pixelCount "px)"
    )
    Bench_Print(result)
}

; ============================================================
; BENCHMARK 3: Alpha scan — HALF WAY (alpha at midpoint)
; ============================================================
Bench_Header("3. Alpha Scan — Midpoint (alpha at pixel N/2)")

for _, sz in iconSizes {
    w := sz, h := sz
    pixelDataSize := w * h * 4
    pixels := Buffer(pixelDataSize, 0)
    midPixel := (w * h) // 2
    NumPut("uchar", 200, pixels, midPixel * 4 + 3)

    pixelCount := w * h
    iters := (pixelCount <= 1024) ? 5000 : (pixelCount <= 4096) ? 2000 : 500

    result := Bench_RunBatch(
        (() => _AlphaScan_Current(pixels, pixelDataSize)),
        pixelCount, iters, 50,
        "mid " w "x" h " (" pixelCount "px)"
    )
    Bench_Print(result)
}

; ============================================================
; BENCHMARK 4: Mask application loop (NumGet + NumPut)
; ============================================================
Bench_Header("4. Mask Application Loop (NumGet mask + NumPut alpha)")

_MaskApply_Current(pixels, maskPixels, pixelDataSize) {
    loop pixelDataSize // 4 {
        offset := (A_Index - 1) * 4
        maskVal := NumGet(maskPixels, offset, "uint") & 0xFFFFFF
        if (maskVal = 0)
            NumPut("uchar", 255, pixels, offset + 3)
        else
            NumPut("uchar", 0, pixels, offset + 3)
    }
}

for _, sz in iconSizes {
    w := sz, h := sz
    pixelDataSize := w * h * 4
    pixels := Buffer(pixelDataSize, 0)
    maskPixels := Buffer(pixelDataSize, 0)
    ; Fill mask with alternating opaque/transparent
    loop pixelDataSize // 4 {
        if (Mod(A_Index, 2) = 0)
            NumPut("uint", 0xFFFFFF, maskPixels, (A_Index - 1) * 4)
    }

    pixelCount := w * h
    iters := (pixelCount <= 1024) ? 5000 : (pixelCount <= 4096) ? 2000 : 500

    result := Bench_RunBatch(
        (() => _MaskApply_Current(pixels, maskPixels, pixelDataSize)),
        pixelCount, iters, 50,
        "mask " w "x" h " (" pixelCount "px)"
    )
    Bench_Print(result)
}

; ============================================================
; BENCHMARK 5: Native memchr baseline (msvcrt)
; ============================================================
Bench_Header("5. Native Scan Baseline (RtlZeroMemory + manual byte check)")

; We can't directly call memchr on strided data, but we CAN measure
; how fast msvcrt.memcmp is on the same buffer size as a baseline.
; This shows the floor for native processing of the same data volume.

_NativeMemcmp(buf1, buf2, size) {
    return DllCall("msvcrt\memcmp", "ptr", buf1, "ptr", buf2, "uptr", size, "int")
}

for _, sz in iconSizes {
    w := sz, h := sz
    pixelDataSize := w * h * 4
    buf1 := Buffer(pixelDataSize, 0)
    buf2 := Buffer(pixelDataSize, 0)

    result := Bench_Run(
        (() => _NativeMemcmp(buf1, buf2, pixelDataSize)),
        10000, 200,
        "memcmp " w "x" h " (" pixelDataSize "B)"
    )
    Bench_Print(result)
}

; ============================================================
; BENCHMARK 6: Native memcpy baseline (for mask apply comparison)
; ============================================================
Bench_Header("6. Native memcpy Baseline (same buffer size)")

_NativeMemcpy(dst, src, size) {
    DllCall("msvcrt\memcpy", "ptr", dst, "ptr", src, "uptr", size)
}

for _, sz in iconSizes {
    w := sz, h := sz
    pixelDataSize := w * h * 4
    src := Buffer(pixelDataSize, 0xAB)
    dst := Buffer(pixelDataSize, 0)

    result := Bench_Run(
        (() => _NativeMemcpy(dst, src, pixelDataSize)),
        10000, 200,
        "memcpy " w "x" h " (" pixelDataSize "B)"
    )
    Bench_Print(result)
}

; ============================================================
Bench_Header("Summary")
FileAppend("Compare AHK NumGet loop times vs native memcmp/memcpy baselines.`n", "*")
FileAppend("The gap represents the interpreter dispatch overhead per pixel.`n", "*")
FileAppend("A native alpha scanner would approach the memcmp baseline.`n", "*")
FileAppend("`nDone.`n", "*")

ExitApp(0)
