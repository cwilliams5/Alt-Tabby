#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
; Mock: Color Swatch with ARGB Alpha Visualization
; ============================================================
; Tests whether each approach can show alpha transparency
; via checkerboard + semi-transparent color overlay.
;
; APPROACH B: WM_CTLCOLORSTATIC (solid brush only — NO alpha)
; APPROACH C: Subclass WM_PAINT + AlphaBlend (FULL alpha support)
;
; Each gets: ARGB hex edit + swatch + alpha slider + color picker
; ============================================================

; -- Dark mode setup --
global CLR_BG      := 0x1E1E1E   ; BGR
global CLR_TEXT    := 0xE0E0E0
global CLR_EDIT_BG := 0x2D2D2D
global CLR_BORDER  := 0x555555
global CLR_CHECK1  := 0xC0C0C0   ; Checkerboard light
global CLR_CHECK2  := 0x808080   ; Checkerboard dark

_GetUxOrd(ord) {
    static hMod := DllCall("GetModuleHandle", "Str", "uxtheme", "Ptr")
    return DllCall("GetProcAddress", "Ptr", hMod, "Ptr", ord, "Ptr")
}
DllCall(_GetUxOrd(135), "Int", 2, "Int")
DllCall(_GetUxOrd(136))

; -- State --
global gSwatchBrushes := Map()   ; hwnd -> hBrush (B only)
global gSwatchColors  := Map()   ; hwnd -> colorRef BGR
global gSwatchAlphas  := Map()   ; hwnd -> alpha 0-255
global gSwatchHwnds_B := Map()
global gSwatchHwnds_C := Map()
global gBgBrush := DllCall("CreateSolidBrush", "UInt", CLR_BG, "Ptr")
global gEditBgBrush := DllCall("CreateSolidBrush", "UInt", CLR_EDIT_BG, "Ptr")
global gSubclassProc := CallbackCreate(_SwatchSubclassProc, , 6)
global gCustomColors := Buffer(64, 0)

OnMessage(0x0138, _OnCtlColorStatic)
OnMessage(0x0133, _OnCtlColorEdit)

; ============================================================
; Build GUI
; ============================================================
myGui := Gui("+Resize", "ARGB Swatch Mock — B vs C")
myGui.BackColor := "1E1E1E"
DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", myGui.Hwnd, "UInt", 20, "Int*", 1, "UInt", 4)
DllCall(_GetUxOrd(133), "Ptr", myGui.Hwnd, "Int", true)

y := 20

; ============================================================
; APPROACH B — solid brush (no alpha visualization)
; ============================================================
myGui.SetFont("s10 cE0E0E0 Bold", "Segoe UI")
myGui.AddText("x20 y" y " w500", "B: Solid brush — alpha slider changes hex but NOT swatch")
myGui.SetFont("s9 cE0E0E0 Norm", "Segoe UI")
y += 26

_AddArgbRow(myGui, &y, "B", 0x80FF6600, "Orange 50% alpha")
_AddArgbRow(myGui, &y, "B", 0x400088FF, "Blue 25% alpha")
y += 10

; ============================================================
; APPROACH C — subclass WM_PAINT with AlphaBlend
; ============================================================
myGui.SetFont("s10 cE0E0E0 Bold", "Segoe UI")
myGui.AddText("x20 y" y " w500", "C: Subclass paint — checkerboard + AlphaBlend")
myGui.SetFont("s9 cE0E0E0 Norm", "Segoe UI")
y += 26

_AddArgbRow(myGui, &y, "C", 0x80FF6600, "Orange 50% alpha")
_AddArgbRow(myGui, &y, "C", 0x400088FF, "Blue 25% alpha")
y += 10

; ============================================================
; STRESS TEST — drag slider, watch swatch
; ============================================================
myGui.SetFont("s10 cE0E0E0 Bold", "Segoe UI")
myGui.AddText("x20 y" y " w500", "STRESS: Drag slider rapidly — C should stay smooth")
myGui.SetFont("s9 cE0E0E0 Norm", "Segoe UI")
y += 26

_AddArgbRow(myGui, &y, "C", 0xFFFF0000, "Red — drag slider to see alpha")
y += 10

myGui.Show("w520 h" (y + 20))

; ============================================================
; Helper: Add ARGB row (edit + swatch + slider + label + picker)
; ============================================================
_AddArgbRow(gui, &y, approach, argbValue, label) {
    global gSwatchHwnds_B, gSwatchHwnds_C, gSubclassProc

    alpha := (argbValue >> 24) & 0xFF
    rgb := argbValue & 0xFFFFFF
    colorRef := _RgbToBgr(rgb)
    pct := Round(alpha / 255 * 100)

    hexStr := "0x" Format("{:08X}", argbValue)
    ed := gui.AddEdit("x20 y" y " w130 h24", hexStr)
    DllCall("uxtheme\SetWindowTheme", "Ptr", ed.Hwnd, "Str", "DarkMode_CFD", "Ptr", 0)

    sw := gui.AddText("x160 y" y " w28 h24 +0x100 +Border", "")

    if (approach = "B") {
        gSwatchHwnds_B[sw.Hwnd] := true
        _UpdateSwatchB(sw.Hwnd, colorRef)
    } else {
        gSwatchHwnds_C[sw.Hwnd] := true
        DllCall("comctl32\SetWindowSubclass", "Ptr", sw.Hwnd, "Ptr", gSubclassProc, "UPtr", sw.Hwnd, "UPtr", 0)
        _UpdateSwatchC(sw.Hwnd, colorRef, alpha)
    }

    slider := gui.AddSlider("x196 y" y " w80 h24 +0x10 Range0-100", pct)
    lbl := gui.AddText("x280 y" (y + 3) " w36 cE0E0E0", pct "%")
    gui.AddText("x320 y" (y + 3) " w180 cE0E0E0", label)

    ; Store refs for cross-sync
    info := {edit: ed, swatch: sw, slider: slider, label: lbl, approach: approach}
    ed.OnEvent("Change", _MakeEditHandler(info))
    slider.OnEvent("Change", _MakeSliderHandler(info))
    sw.OnEvent("Click", _MakePickHandler(info))

    y += 32
}

; ============================================================
; Handler factories (closures capture info)
; ============================================================
_MakeEditHandler(info) {
    return (ctrl, *) => _OnArgbEditChange(info)
}
_MakeSliderHandler(info) {
    return (ctrl, *) => _OnArgbSliderChange(info)
}
_MakePickHandler(info) {
    return (ctrl, *) => _OnArgbSwatchClick(info)
}

; ============================================================
; Edit change -> update swatch + slider
; ============================================================
_OnArgbEditChange(info) {
    txt := info.edit.Value
    if (SubStr(txt, 1, 2) != "0x")
        return
    try val := Integer(txt)
    catch
        return
    rgb := val & 0xFFFFFF
    alpha := (val >> 24) & 0xFF
    colorRef := _RgbToBgr(rgb)
    pct := Round(alpha / 255 * 100)
    try info.slider.Value := pct
    info.label.Value := pct "%"

    if (info.approach = "B")
        _UpdateSwatchB(info.swatch.Hwnd, colorRef)
    else
        _UpdateSwatchC(info.swatch.Hwnd, colorRef, alpha)
}

; ============================================================
; Slider change -> update edit + swatch
; ============================================================
_OnArgbSliderChange(info) {
    pct := info.slider.Value
    info.label.Value := pct "%"
    alpha := Round(pct / 100 * 255)

    txt := info.edit.Value
    try val := Integer(txt)
    catch
        val := 0
    rgb := val & 0xFFFFFF
    newVal := (alpha << 24) | rgb
    info.edit.Value := "0x" Format("{:08X}", newVal)

    colorRef := _RgbToBgr(rgb)
    if (info.approach = "B")
        _UpdateSwatchB(info.swatch.Hwnd, colorRef)
    else
        _UpdateSwatchC(info.swatch.Hwnd, colorRef, alpha)
}

; ============================================================
; Swatch click -> ChooseColor -> update edit + swatch
; ============================================================
_OnArgbSwatchClick(info) {
    global gCustomColors
    txt := info.edit.Value
    try val := Integer(txt)
    catch
        val := 0
    currentRGB := val & 0xFFFFFF
    alpha := (val >> 24) & 0xFF

    cc := Buffer(A_PtrSize = 8 ? 72 : 36, 0)
    NumPut("UInt", cc.Size, cc, 0)
    off := 3 * A_PtrSize
    NumPut("UInt", _RgbToBgr(currentRGB), cc, off)
    NumPut("Ptr", gCustomColors.Ptr, cc, off + A_PtrSize)
    NumPut("UInt", 3, cc, off + 2 * A_PtrSize)

    if (!DllCall("comdlg32\ChooseColorW", "Ptr", cc.Ptr, "Int"))
        return

    resultBGR := NumGet(cc, off, "UInt")
    resultRGB := _BgrToRgb(resultBGR)
    newVal := (alpha << 24) | resultRGB
    info.edit.Value := "0x" Format("{:08X}", newVal)

    if (info.approach = "B")
        _UpdateSwatchB(info.swatch.Hwnd, resultBGR)
    else
        _UpdateSwatchC(info.swatch.Hwnd, resultBGR, alpha)
}

; ============================================================
; Approach B: solid brush update (no alpha)
; ============================================================
_UpdateSwatchB(hwnd, colorRef) {
    global gSwatchBrushes, gSwatchColors
    if (gSwatchBrushes.Has(hwnd))
        DllCall("DeleteObject", "Ptr", gSwatchBrushes[hwnd])
    gSwatchBrushes[hwnd] := DllCall("CreateSolidBrush", "UInt", colorRef, "Ptr")
    gSwatchColors[hwnd] := colorRef
    DllCall("InvalidateRect", "Ptr", hwnd, "Ptr", 0, "Int", 1)
}

; ============================================================
; Approach C: store color+alpha, invalidate (paint does the rest)
; ============================================================
_UpdateSwatchC(hwnd, colorRef, alpha) {
    global gSwatchColors, gSwatchAlphas
    gSwatchColors[hwnd] := colorRef
    gSwatchAlphas[hwnd] := alpha
    DllCall("InvalidateRect", "Ptr", hwnd, "Ptr", 0, "Int", 0)
}

; ============================================================
; WM_CTLCOLORSTATIC
; ============================================================
_OnCtlColorStatic(wParam, lParam, msg, hwnd) {
    global gSwatchHwnds_B, gSwatchHwnds_C, gSwatchBrushes, gSwatchColors, gBgBrush

    if (gSwatchHwnds_B.Has(lParam)) {
        if (!gSwatchBrushes.Has(lParam)) {
            DllCall("SetBkColor", "Ptr", wParam, "UInt", CLR_BG)
            return gBgBrush
        }
        DllCall("SetBkColor", "Ptr", wParam, "UInt", gSwatchColors[lParam])
        DllCall("SetBkMode", "Ptr", wParam, "Int", 1)
        return gSwatchBrushes[lParam]
    }

    if (gSwatchHwnds_C.Has(lParam))
        return  ; subclass handles paint

    DllCall("SetBkColor", "Ptr", wParam, "UInt", CLR_BG)
    DllCall("SetTextColor", "Ptr", wParam, "UInt", CLR_TEXT)
    return gBgBrush
}

; ============================================================
; WM_CTLCOLOREDIT
; ============================================================
_OnCtlColorEdit(wParam, lParam, msg, hwnd) {
    global gEditBgBrush
    DllCall("SetBkColor", "Ptr", wParam, "UInt", CLR_EDIT_BG)
    DllCall("SetTextColor", "Ptr", wParam, "UInt", CLR_TEXT)
    return gEditBgBrush
}

; ============================================================
; Approach C: Subclass WM_PAINT — checkerboard + AlphaBlend
; ============================================================
_SwatchSubclassProc(hwnd, uMsg, wParam, lParam, uIdSubclass, dwRefData) {
    global gSubclassProc, gSwatchColors, gSwatchAlphas

    if (uMsg = 0x000F) {  ; WM_PAINT
        ps := Buffer(72, 0)
        hdc := DllCall("BeginPaint", "Ptr", hwnd, "Ptr", ps, "Ptr")
        rc := Buffer(16)
        DllCall("GetClientRect", "Ptr", hwnd, "Ptr", rc)
        w := NumGet(rc, 8, "Int")
        h := NumGet(rc, 12, "Int")

        colorRef := gSwatchColors.Has(hwnd) ? gSwatchColors[hwnd] : CLR_BG
        alpha := gSwatchAlphas.Has(hwnd) ? gSwatchAlphas[hwnd] : 255

        ; --- Step 1: Draw checkerboard ---
        checkSize := 5
        hBrush1 := DllCall("CreateSolidBrush", "UInt", CLR_CHECK1, "Ptr")
        hBrush2 := DllCall("CreateSolidBrush", "UInt", CLR_CHECK2, "Ptr")
        cellRc := Buffer(16)
        row := 0
        cy := 0
        while (cy < h) {
            col := 0
            cx := 0
            while (cx < w) {
                x2 := cx + checkSize
                y2 := cy + checkSize
                if (x2 > w) x2 := w
                if (y2 > h) y2 := h
                NumPut("Int", cx, cellRc, 0)
                NumPut("Int", cy, cellRc, 4)
                NumPut("Int", x2, cellRc, 8)
                NumPut("Int", y2, cellRc, 12)
                brush := (Mod(row + col, 2) = 0) ? hBrush1 : hBrush2
                DllCall("FillRect", "Ptr", hdc, "Ptr", cellRc, "Ptr", brush)
                cx += checkSize
                col++
            }
            cy += checkSize
            row++
        }
        DllCall("DeleteObject", "Ptr", hBrush1)
        DllCall("DeleteObject", "Ptr", hBrush2)

        ; --- Step 2: AlphaBlend the color on top ---
        if (alpha > 0) {
            memDC := DllCall("CreateCompatibleDC", "Ptr", hdc, "Ptr")

            ; 32-bit DIB section for premultiplied alpha
            bmi := Buffer(44, 0)
            NumPut("UInt", 40, bmi, 0)    ; biSize
            NumPut("Int", w, bmi, 4)       ; biWidth
            NumPut("Int", -h, bmi, 8)      ; biHeight (top-down)
            NumPut("UShort", 1, bmi, 12)   ; biPlanes
            NumPut("UShort", 32, bmi, 14)  ; biBitCount

            ppvBits := 0
            hBmp := DllCall("CreateDIBSection", "Ptr", memDC, "Ptr", bmi, "UInt", 0,
                "Ptr*", &ppvBits, "Ptr", 0, "UInt", 0, "Ptr")
            oldBmp := DllCall("SelectObject", "Ptr", memDC, "Ptr", hBmp, "Ptr")

            ; Fill DIB with premultiplied ARGB
            ; colorRef is BGR: 0x00BBGGRR
            rr := colorRef & 0xFF
            gg := (colorRef >> 8) & 0xFF
            bb := (colorRef >> 16) & 0xFF
            ; Premultiply
            prB := (bb * alpha) // 255
            prG := (gg * alpha) // 255
            prR := (rr * alpha) // 255
            ; Pixel: BGRA in memory (little-endian DWORD = 0xAARRGGBB)
            pixel := (alpha << 24) | (prR << 16) | (prG << 8) | prB

            ; Fill all pixels
            totalPixels := w * h
            offset := 0
            loop totalPixels {
                NumPut("UInt", pixel, ppvBits + offset)
                offset += 4
            }

            ; BLENDFUNCTION struct (packed as UInt): SourceConstantAlpha=255, AlphaFormat=AC_SRC_ALPHA(1)
            ; BlendOp=AC_SRC_OVER(0), BlendFlags=0, SourceConstantAlpha=255, AlphaFormat=1
            blendFunc := (1 << 24) | (255 << 16)  ; AlphaFormat | SCA | flags | op

            DllCall("msimg32\AlphaBlend", "Ptr", hdc, "Int", 0, "Int", 0, "Int", w, "Int", h,
                "Ptr", memDC, "Int", 0, "Int", 0, "Int", w, "Int", h, "UInt", blendFunc)

            DllCall("SelectObject", "Ptr", memDC, "Ptr", oldBmp)
            DllCall("DeleteObject", "Ptr", hBmp)
            DllCall("DeleteDC", "Ptr", memDC)
        }

        ; --- Step 3: Border ---
        hPen := DllCall("CreatePen", "Int", 0, "Int", 1, "UInt", CLR_BORDER, "Ptr")
        oldPen := DllCall("SelectObject", "Ptr", hdc, "Ptr", hPen, "Ptr")
        oldBr := DllCall("SelectObject", "Ptr", hdc, "Ptr", DllCall("GetStockObject", "Int", 5, "Ptr"), "Ptr")
        DllCall("Rectangle", "Ptr", hdc, "Int", 0, "Int", 0, "Int", w, "Int", h)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", oldPen)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", oldBr)
        DllCall("DeleteObject", "Ptr", hPen)

        DllCall("EndPaint", "Ptr", hwnd, "Ptr", ps)
        return 0
    }
    if (uMsg = 0x0014)  ; WM_ERASEBKGND
        return 1
    if (uMsg = 0x0082)  ; WM_NCDESTROY
        DllCall("comctl32\RemoveWindowSubclass", "Ptr", hwnd, "Ptr", gSubclassProc, "UPtr", uIdSubclass)
    return DllCall("comctl32\DefSubclassProc", "Ptr", hwnd, "UInt", uMsg, "Ptr", wParam, "Ptr", lParam, "Ptr")
}

; ============================================================
; Shared helpers
; ============================================================
_RgbToBgr(rgb) {
    r := (rgb >> 16) & 0xFF
    g := (rgb >> 8) & 0xFF
    b := rgb & 0xFF
    return (b << 16) | (g << 8) | r
}

_BgrToRgb(bgr) {
    b := (bgr >> 16) & 0xFF
    g := (bgr >> 8) & 0xFF
    r := bgr & 0xFF
    return (r << 16) | (g << 8) | b
}

; ============================================================
; Cleanup
; ============================================================
myGui.OnEvent("Close", _OnClose)
_OnClose(*) {
    global gSwatchBrushes, gBgBrush, gEditBgBrush
    for hwnd, hBrush in gSwatchBrushes
        DllCall("DeleteObject", "Ptr", hBrush)
    DllCall("DeleteObject", "Ptr", gBgBrush)
    DllCall("DeleteObject", "Ptr", gEditBgBrush)
    OnMessage(0x0138, _OnCtlColorStatic, 0)
    OnMessage(0x0133, _OnCtlColorEdit, 0)
    ExitApp()
}
