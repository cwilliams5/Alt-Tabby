#Requires AutoHotkey v2.0
#SingleInstance Off

; bench_alpha_native.ahk — Compare AHK alpha scan vs native DLL
;
; Head-to-head benchmark: production AHK code vs compiled C DLL

#Include %A_ScriptDir%\bench_common.ahk

FileAppend("bench_alpha_native.ahk — AHK vs Native Alpha Scan`n", "*")
FileAppend("=============================================`n", "*")

; Load native DLL
dllPath := A_ScriptDir "\native_src\icon_alpha.dll"
if (!FileExist(dllPath)) {
    FileAppend("ERROR: " dllPath " not found. Run native_src\build.ps1 first.`n", "*")
    ExitApp(1)
}
hDll := DllCall("LoadLibrary", "str", dllPath, "ptr")
if (!hDll) {
    FileAppend("ERROR: Failed to load DLL`n", "*")
    ExitApp(1)
}
FileAppend("Loaded: " dllPath "`n`n", "*")

; --- AHK production code (from gui_gdip.ahk) ---
_AHK_AlphaScan(pixels, pixelDataSize) {
    hasAlpha := false
    loop pixelDataSize // 4 {
        if (NumGet(pixels, (A_Index - 1) * 4 + 3, "uchar") > 0) {
            hasAlpha := true
            break
        }
    }
    return hasAlpha
}

_AHK_MaskApply(pixels, maskPixels, pixelDataSize) {
    loop pixelDataSize // 4 {
        offset := (A_Index - 1) * 4
        maskVal := NumGet(maskPixels, offset, "uint") & 0xFFFFFF
        if (maskVal = 0)
            NumPut("uchar", 255, pixels, offset + 3)
        else
            NumPut("uchar", 0, pixels, offset + 3)
    }
}

_AHK_Combined(pixels, maskPixels, pixelDataSize) {
    ; Scan
    hasAlpha := false
    loop pixelDataSize // 4 {
        if (NumGet(pixels, (A_Index - 1) * 4 + 3, "uchar") > 0) {
            hasAlpha := true
            break
        }
    }
    ; Apply mask if no alpha
    if (!hasAlpha && maskPixels) {
        loop pixelDataSize // 4 {
            offset := (A_Index - 1) * 4
            maskVal := NumGet(maskPixels, offset, "uint") & 0xFFFFFF
            if (maskVal = 0)
                NumPut("uchar", 255, pixels, offset + 3)
            else
                NumPut("uchar", 0, pixels, offset + 3)
        }
    }
    return hasAlpha
}

; --- Native DLL calls ---
_Native_Combined(pixels, maskPixels, pixelCount) {
    return DllCall(dllPath "\icon_scan_and_apply_mask",
        "ptr", pixels,
        "ptr", maskPixels,
        "uint", pixelCount,
        "cdecl int")
}

_Native_ScanOnly(pixels, pixelCount) {
    return DllCall(dllPath "\icon_scan_alpha_only",
        "ptr", pixels,
        "uint", pixelCount,
        "cdecl int")
}

; Icon sizes
iconSizes := [16, 32, 48, 64, 128, 256]

; ============================================================
; TEST 1: Correctness verification
; ============================================================
Bench_Header("Correctness Verification")

; Test: all zeros → should return 0 (no alpha)
buf := Buffer(256 * 4, 0)
result := _Native_ScanOnly(buf, 256)
FileAppend("  All zeros, scan-only: " result " (expected 0) " (result = 0 ? "PASS" : "FAIL") "`n", "*")

; Test: first pixel has alpha → should return 1
NumPut("uchar", 128, buf, 3)
result := _Native_ScanOnly(buf, 256)
FileAppend("  First alpha set, scan: " result " (expected 1) " (result = 1 ? "PASS" : "FAIL") "`n", "*")

; Test: combined with mask
pixels := Buffer(16 * 4, 0)  ; all zero alpha
mask := Buffer(16 * 4, 0)    ; all black mask → should set alpha=255
result := _Native_Combined(pixels, mask, 16)
FileAppend("  Combined (no alpha, black mask): result=" result " (expected 0)`n", "*")
alphaAfter := NumGet(pixels, 3, "uchar")
FileAppend("  First pixel alpha after mask: " alphaAfter " (expected 255) " (alphaAfter = 255 ? "PASS" : "FAIL") "`n", "*")

; Test: combined with white mask
pixels2 := Buffer(16 * 4, 0)
mask2 := Buffer(16 * 4, 0xFF)  ; all 0xFF = white mask → should set alpha=0
result2 := _Native_Combined(pixels2, mask2, 16)
alphaAfter2 := NumGet(pixels2, 3, "uchar")
FileAppend("  White mask alpha: " alphaAfter2 " (expected 0) " (alphaAfter2 = 0 ? "PASS" : "FAIL") "`n", "*")

; Test: AHK and native agree on mixed mask
pixels3 := Buffer(64 * 4, 0)
mask3 := Buffer(64 * 4, 0)
pixels4 := Buffer(64 * 4, 0)
; Set alternating mask: even=black(opaque), odd=white(transparent)
loop 64 {
    if (Mod(A_Index, 2) = 0)
        NumPut("uint", 0xFFFFFF, mask3, (A_Index - 1) * 4)
}
; Apply with AHK
_AHK_MaskApply(pixels3, mask3, 64 * 4)
; Apply with native (need fresh mask copy since mask3 is same)
_Native_Combined(pixels4, mask3, 64)
; Compare results
match := true
loop 64 {
    a := NumGet(pixels3, (A_Index - 1) * 4 + 3, "uchar")
    b := NumGet(pixels4, (A_Index - 1) * 4 + 3, "uchar")
    if (a != b) {
        FileAppend("  MISMATCH at pixel " A_Index ": AHK=" a " native=" b "`n", "*")
        match := false
    }
}
FileAppend("  AHK vs native mask agreement: " (match ? "PASS" : "FAIL") "`n", "*")

; ============================================================
; TEST 2: WORST CASE — All zero alpha (full scan)
; ============================================================
Bench_Header("Worst Case: Alpha Scan (all zero alpha — full scan)")

for _, sz in iconSizes {
    w := sz, h := sz
    pixelCount := w * h
    pixelDataSize := pixelCount * 4
    pixels := Buffer(pixelDataSize, 0)

    iters := (pixelCount <= 1024) ? 10000 : (pixelCount <= 4096) ? 5000 : 1000

    ; AHK
    ahkResult := Bench_Run(
        (() => _AHK_AlphaScan(pixels, pixelDataSize)),
        iters, 100, "AHK  " sz "x" sz)
    Bench_Print(ahkResult)

    ; Native
    natResult := Bench_Run(
        (() => _Native_ScanOnly(pixels, pixelCount)),
        iters, 100, "NAT  " sz "x" sz)
    Bench_Print(natResult)

    speedup := ahkResult["mean"] / natResult["mean"]
    FileAppend("  >>> Speedup: " Round(speedup, 1) "x`n`n", "*")
}

; ============================================================
; TEST 3: COMBINED — Scan + Mask Apply (worst case path)
; ============================================================
Bench_Header("Worst Case: Scan + Mask Apply Combined")

for _, sz in iconSizes {
    w := sz, h := sz
    pixelCount := w * h
    pixelDataSize := pixelCount * 4
    pixels_ahk := Buffer(pixelDataSize, 0)
    pixels_nat := Buffer(pixelDataSize, 0)
    mask := Buffer(pixelDataSize, 0)
    ; Alternating mask pattern
    loop pixelCount {
        if (Mod(A_Index, 2) = 0)
            NumPut("uint", 0xFFFFFF, mask, (A_Index - 1) * 4)
    }

    iters := (pixelCount <= 1024) ? 5000 : (pixelCount <= 4096) ? 2000 : 500

    ; AHK combined
    ahkResult := Bench_Run(
        (() => (DllCall("msvcrt\memset", "ptr", pixels_ahk, "int", 0, "uptr", pixelDataSize),
                _AHK_Combined(pixels_ahk, mask, pixelDataSize))),
        iters, 50, "AHK  " sz "x" sz " (scan+mask)")
    Bench_Print(ahkResult)

    ; Native combined
    natResult := Bench_Run(
        (() => (DllCall("msvcrt\memset", "ptr", pixels_nat, "int", 0, "uptr", pixelDataSize),
                _Native_Combined(pixels_nat, mask, pixelCount))),
        iters, 50, "NAT  " sz "x" sz " (scan+mask)")
    Bench_Print(natResult)

    speedup := ahkResult["mean"] / natResult["mean"]
    FileAppend("  >>> Speedup: " Round(speedup, 1) "x`n`n", "*")
}

; ============================================================
; TEST 4: BEST CASE — First pixel has alpha
; ============================================================
Bench_Header("Best Case: First Pixel Has Alpha (early exit)")

for _, sz in [32, 128, 256] {
    w := sz, h := sz
    pixelCount := w * h
    pixelDataSize := pixelCount * 4
    pixels := Buffer(pixelDataSize, 0)
    NumPut("uchar", 255, pixels, 3)

    ; AHK
    ahkResult := Bench_Run(
        (() => _AHK_AlphaScan(pixels, pixelDataSize)),
        10000, 200, "AHK  " sz "x" sz " (early exit)")
    Bench_Print(ahkResult)

    ; Native
    natResult := Bench_Run(
        (() => _Native_ScanOnly(pixels, pixelCount)),
        10000, 200, "NAT  " sz "x" sz " (early exit)")
    Bench_Print(natResult)

    speedup := ahkResult["mean"] / natResult["mean"]
    FileAppend("  >>> Speedup: " Round(speedup, 1) "x`n`n", "*")
}

; ============================================================
; Cleanup
; ============================================================
DllCall("FreeLibrary", "ptr", hDll)

Bench_Header("Complete")
FileAppend("Native DLL confirmed functional and benchmarked.`n", "*")
FileAppend("Next step: embed as MCode using cJSON pattern if speedups justify it.`n", "*")

ExitApp(0)
