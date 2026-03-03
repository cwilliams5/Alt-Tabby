#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================================
; D2D Validation Prototype — Alt-Tabby Phase 0
;
; Validates the Direct2D.ahk library integration with:
;   1. SWCA acrylic backdrop + D2D HwndRenderTarget
;   2. Text rendering (DirectWrite), rounded rects, bitmap drawing
;   3. Transparent areas → acrylic shows through
;   4. Mouse events work (non-layered single window)
;   5. DWM thumbnail composites over D2D content
;   6. ComCall works with D2D objects on AHK v2.0 (Direct2D.ahk)
;
; Run: AutoHotkey64.exe temp\d2d_prototype.ahk
;
; Keys:
;   Tab / Down   — next row
;   Shift+Tab / Up — prev row
;   T            — toggle DWM thumbnail registration
;   B            — cycle backdrop (Acrylic → Blur → None)
;   Esc          — exit
; ============================================================================

; DPI awareness before any window creation
try DllCall("SetProcessDpiAwarenessContext", "ptr", -4, "int")

; Include the library (relative to this file's location)
#Include %A_ScriptDir%\..\src\lib\Direct2D.ahk

; ======================== LAYOUT CONSTANTS (DIPs) ========================

SCREEN_WIDTH_PCT  := 0.55
ROW_HEIGHT        := 56
MARGIN_X          := 18
MARGIN_Y          := 18
ICON_SIZE         := 36
ICON_LEFT_MARGIN  := 8
ICON_TEXT_GAP     := 12
HEADER_HEIGHT     := 28
FOOTER_HEIGHT     := 32
ROWS_VISIBLE_MAX  := 8
SCROLLBAR_WIDTH   := 6
TITLE_Y           := 6
TITLE_H           := 24
SUB_Y             := 30
SUB_H             := 18

; ======================== COLORS (0xAARRGGBB) ========================

CLR_SEL           := 0x662B5CAD
CLR_TEXT_MAIN     := 0xFFF0F0F0
CLR_TEXT_SUB      := 0xFFB5C0CE
CLR_TEXT_HDR      := 0xFFD0D6DE
CLR_TEXT_FOOTER   := 0xFFFFFFFF
CLR_SCROLLBAR     := 0x88FFFFFF
CLR_ICON_BG       := 0xFF3A5F8A
CLR_ICON_TEXT     := 0xFFFFFFFF
CLR_FOOTER_BORDER := 0x33FFFFFF
CLR_TIMING_BG     := 0xCC000000
CLR_TIMING_TEXT   := 0xFF00FF88
CLR_DARK_BG       := 0xE01A1A2E
CLR_THUMB_BORDER  := 0x44FFFFFF

; ======================== GLOBAL STATE ========================

gFactory  := ""   ; ID2D1Factory
gDWrite   := ""   ; IDWriteFactory
gRT       := ""   ; ID2D1HwndRenderTarget
gHwnd     := 0
gGui      := ""

gBrushes  := Map()  ; name → ID2D1SolidColorBrush
gFormats  := Map()  ; name → IDWriteTextFormat

gSel       := 1
gScroll    := 0
gBackdrop  := 1
gBackdropNames := ["Acrylic", "Blur", "None"]
gTimingMs  := 0.0
gFrameCount := 0
gFpsTime   := 0
gFps       := 0
gWinW      := 0
gWinH      := 0
gDpiScale  := 1.0
gItems     := []

; DWM Thumbnail state
gThumbId   := 0
gThumbSrc  := 0  ; source hwnd
gThumbVisible := false

; ======================== ENTRY POINT ========================

OnExit(Cleanup)
Main()
return

Main() {
    global

    InitMockData()
    CreateWindow()
    CreateD2DResources()
    ScaleWindow()
    SetupKeys()

    gFpsTime := A_TickCount
    SetTimer(PaintFrame, 16)
}

; ======================== MOCK DATA ========================

InitMockData() {
    global gItems
    gItems := [
        {title: "Visual Studio Code",       proc: "Code.exe",            ws: "Dev"},
        {title: "Alt-Tabby — config.ini",   proc: "AltTabby.exe",        ws: "Dev"},
        {title: "Windows Terminal",          proc: "WindowsTerminal.exe", ws: "Main"},
        {title: "Mozilla Firefox — GitHub",  proc: "firefox.exe",         ws: "Web"},
        {title: "File Explorer",            proc: "explorer.exe",        ws: "Main"},
        {title: "Spotify Premium",          proc: "Spotify.exe",         ws: "Media"},
        {title: "Discord",                  proc: "Discord.exe",         ws: "Chat"},
        {title: "Obsidian — Vault",         proc: "Obsidian.exe",        ws: "Notes"},
        {title: "Task Manager",             proc: "Taskmgr.exe",         ws: "Main"},
        {title: "Paint",                    proc: "mspaint.exe",         ws: "Main"},
    ]
}

; ======================== WINDOW CREATION ========================

CreateWindow() {
    global gGui, gHwnd, gWinW, gWinH

    gWinW := Round(A_ScreenWidth * SCREEN_WIDTH_PCT)
    gWinH := 500

    ; Single window: WS_EX_LAYERED for DWM transparency, no caption
    gGui := Gui("+AlwaysOnTop -Caption +Resize -DPIScale +E0x80000")
    gGui.BackColor := "000000"
    gGui.Show("x0 y0 w" gWinW " h" gWinH " Hide")
    gHwnd := gGui.Hwnd

    ; SetLayeredWindowAttributes — fully opaque but layered for DWM composition
    DllCall("SetLayeredWindowAttributes", "uptr", gHwnd, "uint", 0, "char", 255, "uint", 2)

    ; DWM: extend frame for transparent composition
    margins := Buffer(16, 0)
    NumPut("int", -1, "int", -1, "int", -1, "int", -1, margins)
    DllCall("dwmapi\DwmExtendFrameIntoClientArea", "ptr", gHwnd, "ptr", margins)

    ; DWM: dark mode + rounded corners
    _DWMAttr(gHwnd, 20, 1)   ; DWMWA_USE_IMMERSIVE_DARK_MODE
    _DWMAttr(gHwnd, 33, 2)   ; DWMWA_WINDOW_CORNER_PREFERENCE = Round

    ; Hollow brush so DWM backdrop shows through
    hollowBrush := DllCall("GetStockObject", "int", 5, "ptr")
    DllCall("SetClassLongPtrW", "ptr", gHwnd, "int", -10, "ptr", hollowBrush, "ptr")

    ; Apply initial backdrop
    _ApplyBackdrop()

    ; Window messages
    gGui.OnEvent("Close", (*) => ExitApp())
    gGui.OnEvent("Size", OnResize)
    OnMessage(0x0014, OnEraseBkgnd)   ; WM_ERASEBKGND
}

; ======================== D2D + DWRITE RESOURCES ========================

CreateD2DResources() {
    global gFactory, gDWrite, gRT, gHwnd, gWinW, gWinH, gDpiScale
    global gBrushes, gFormats

    ; Create factories via Direct2D.ahk (uses ComCall internally)
    gFactory := ID2D1Factory()
    gDWrite  := IDWriteFactory()

    ; Get monitor DPI
    dpi := DllCall("GetDpiForWindow", "ptr", gHwnd, "uint")
    if (!dpi)
        dpi := 96
    gDpiScale := dpi / 96.0

    ; Render target properties
    rtProps := Buffer(28, 0)
    NumPut("uint", 1, rtProps, 8)              ; alphaMode = PREMULTIPLIED
    NumPut("float", Float(dpi), rtProps, 12)   ; dpiX
    NumPut("float", Float(dpi), rtProps, 16)   ; dpiY

    ; Hwnd render target properties
    hwndProps := Buffer(A_PtrSize + 12, 0)
    NumPut("uptr", gHwnd, hwndProps, 0)
    NumPut("uint", gWinW, hwndProps, A_PtrSize)
    NumPut("uint", gWinH, hwndProps, A_PtrSize + 4)

    ; Create render target — THIS IS THE KEY TEST: ComCall via Direct2D.ahk
    gRT := gFactory.CreateHwndRenderTarget(rtProps, hwndProps)

    ; Anti-aliasing
    gRT.SetAntialiasMode(0)       ; D2D1_ANTIALIAS_MODE_PER_PRIMITIVE
    gRT.SetTextAntialiasMode(2)   ; D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE

    ; -- Brushes (via ComCall) --
    gBrushes["sel"]        := _MkBrush(CLR_SEL)
    gBrushes["textMain"]   := _MkBrush(CLR_TEXT_MAIN)
    gBrushes["textSub"]    := _MkBrush(CLR_TEXT_SUB)
    gBrushes["textHdr"]    := _MkBrush(CLR_TEXT_HDR)
    gBrushes["textFooter"] := _MkBrush(CLR_TEXT_FOOTER)
    gBrushes["scrollbar"]  := _MkBrush(CLR_SCROLLBAR)
    gBrushes["iconBg"]     := _MkBrush(CLR_ICON_BG)
    gBrushes["iconText"]   := _MkBrush(CLR_ICON_TEXT)
    gBrushes["footerBdr"]  := _MkBrush(CLR_FOOTER_BORDER)
    gBrushes["timingBg"]   := _MkBrush(CLR_TIMING_BG)
    gBrushes["timingText"] := _MkBrush(CLR_TIMING_TEXT)
    gBrushes["darkBg"]     := _MkBrush(CLR_DARK_BG)
    gBrushes["thumbBdr"]   := _MkBrush(CLR_THUMB_BORDER)

    ; -- Text Formats (via ComCall) --
    gFormats["title"]   := _MkFmt("Segoe UI", 18, 400)
    gFormats["titleHi"] := _MkFmt("Segoe UI", 18, 800)
    gFormats["sub"]     := _MkFmt("Segoe UI", 11.5, 400)
    gFormats["hdr"]     := _MkFmt("Segoe UI", 11.5, 600)
    gFormats["footer"]  := _MkFmt("Segoe UI", 12, 600)
    gFormats["timing"]  := _MkFmt("Consolas", 11, 400)
    gFormats["icon"]    := _MkFmt("Segoe UI", 15, 600)

    ; Set word wrapping + vertical centering on all formats
    for name, fmt in gFormats {
        fmt.SetWordWrapping(1)       ; NoWrap
        fmt.SetParagraphAlignment(2) ; Center vertically
    }

    ; Right-align timing
    gFormats["timing"].SetTextAlignment(1)  ; Trailing
    ; Center footer
    gFormats["footer"].SetTextAlignment(2)  ; Center
    ; Center icon letter
    gFormats["icon"].SetTextAlignment(2)    ; Center
}

_MkBrush(argb) {
    global gRT
    color := _ARGB(argb)
    return gRT.CreateSolidColorBrush(color)
}

_MkFmt(font, size, weight) {
    global gDWrite
    return gDWrite.CreateTextFormat(font, 0, weight, 0, 5, size, "en-us")
}

; ======================== SCALING ========================

ScaleWindow() {
    global gGui, gHwnd, gWinW, gWinH, gDpiScale, gItems

    visRows := Min(gItems.Length, ROWS_VISIBLE_MAX)
    dipH := MARGIN_Y + HEADER_HEIGHT + (visRows * ROW_HEIGHT) + FOOTER_HEIGHT + MARGIN_Y
    gWinW := Round(A_ScreenWidth * SCREEN_WIDTH_PCT)
    gWinH := Round(dipH * gDpiScale)

    x := (A_ScreenWidth - gWinW) // 2
    y := (A_ScreenHeight - gWinH) // 2

    gGui.Show("x" x " y" y " w" gWinW " h" gWinH)
}

; ======================== PAINT FRAME ========================

PaintFrame() {
    global gRT, gHwnd, gWinW, gWinH, gDpiScale, gItems, gSel, gScroll
    global gBrushes, gFormats, gTimingMs, gFrameCount, gFpsTime, gFps
    global gBackdrop, gBackdropNames, gThumbVisible

    if (!gRT)
        return

    t0 := _QPC()

    dipW := gWinW / gDpiScale
    dipH := gWinH / gDpiScale

    ; BeginDraw via ComCall
    gRT.BeginDraw()

    ; Clear to transparent (acrylic shows through)
    clearClr := Buffer(16, 0)
    gRT.Clear(clearClr)

    ; Dark background if no backdrop
    if (gBackdropNames[gBackdrop] = "None")
        _FillRect(0, 0, dipW, dipH, gBrushes["darkBg"])

    ; Layout
    cx := MARGIN_X
    visRows := Min(gItems.Length, ROWS_VISIBLE_MAX)
    hdrY    := MARGIN_Y
    rowsY   := hdrY + HEADER_HEIGHT
    cw := dipW - MARGIN_X * 2 - SCROLLBAR_WIDTH - 8
    footerY := rowsY + (visRows * ROW_HEIGHT)

    ; Header
    hdrText := "D2D Prototype — " gItems.Length " windows | ComCall: OK | Backdrop: " gBackdropNames[gBackdrop]
    _Text(hdrText, gFormats["hdr"], cx + ICON_LEFT_MARGIN, hdrY, cw, HEADER_HEIGHT, gBrushes["textHdr"])

    ; Rows
    loop visRows {
        idx := gScroll + A_Index
        if (idx > gItems.Length)
            break
        ry := rowsY + (A_Index - 1) * ROW_HEIGHT
        _DrawRow(gItems[idx], cx, ry, cw, ROW_HEIGHT, idx = gSel)
    }

    ; Scrollbar
    if (gItems.Length > ROWS_VISIBLE_MAX) {
        sbX := dipW - MARGIN_X - SCROLLBAR_WIDTH
        _DrawScrollbar(sbX, rowsY, SCROLLBAR_WIDTH, visRows * ROW_HEIGHT)
    }

    ; DWM Thumbnail placeholder (right side, shows where thumbnail composites)
    thumbX := dipW * 0.65
    thumbY := rowsY
    thumbW := dipW * 0.30
    thumbH := visRows * ROW_HEIGHT * 0.6
    if (gThumbVisible) {
        ; Draw a border to show where the DWM thumbnail is composited
        _FillRRect(thumbX - 1, thumbY - 1, thumbW + 2, thumbH + 2, 6, gBrushes["thumbBdr"])
        _Text("DWM Thumbnail Area", gFormats["hdr"], thumbX, thumbY + thumbH + 4, thumbW, 20, gBrushes["textHdr"])
    }

    ; Footer
    fW := dipW - MARGIN_X * 2
    _DrawFooter(cx, footerY, fW, FOOTER_HEIGHT)

    ; Timing overlay
    _DrawTiming(dipW - MARGIN_X - 280, MARGIN_Y, 280, 22)

    ; EndDraw via ComCall
    gRT.EndDraw()

    ; Timing stats
    gTimingMs := (_QPC() - t0) / _QPF() * 1000.0
    gFrameCount++
    if (A_TickCount - gFpsTime >= 1000) {
        gFps := gFrameCount
        gFrameCount := 0
        gFpsTime := A_TickCount
    }
}

; ======================== ROW RENDERING ========================

_DrawRow(item, x, y, w, h, isSel) {
    global gBrushes, gFormats

    ; Selection pill (native FillRoundedRectangle — 1 call vs 11 in GDI+)
    if (isSel) {
        pillY := y + 2
        pillH := h - 4
        _FillRRect(x, pillY, w, pillH, 8, gBrushes["sel"])
    }

    ; Icon circle
    iconCx := x + ICON_LEFT_MARGIN + ICON_SIZE / 2
    iconCy := y + h / 2
    iconR  := ICON_SIZE / 2 - 2
    ellipse := Buffer(16)
    NumPut("float", Float(iconCx), "float", Float(iconCy),
           "float", Float(iconR), "float", Float(iconR), ellipse)
    gRT.FillEllipse(ellipse, gBrushes["iconBg"])

    ; Letter inside icon
    letter := SubStr(item.proc, 1, 1)
    iconX := x + ICON_LEFT_MARGIN
    iconY := y + (h - ICON_SIZE) / 2
    _Text(letter, gFormats["icon"], iconX, iconY, ICON_SIZE, ICON_SIZE, gBrushes["iconText"])

    ; Text area
    textX := x + ICON_LEFT_MARGIN + ICON_SIZE + ICON_TEXT_GAP
    textW := w - ICON_LEFT_MARGIN - ICON_SIZE - ICON_TEXT_GAP - 80

    ; Title
    brT := gBrushes[isSel ? "textMain" : "textMain"]
    tfT := gFormats[isSel ? "titleHi" : "title"]
    _Text(item.title, tfT, textX, y + TITLE_Y, textW, TITLE_H, brT)

    ; Subtitle
    _Text(item.proc "  ·  " item.ws, gFormats["sub"], textX, y + SUB_Y, textW, SUB_H, gBrushes["textSub"])

    ; Workspace tag
    colX := x + w - 60
    _Text(item.ws, gFormats["hdr"], colX, y + 10, 60, 20, gBrushes["textHdr"])
}

_DrawScrollbar(x, y, w, h) {
    global gBrushes, gScroll, gItems

    total := gItems.Length
    vis := Min(total, ROWS_VISIBLE_MAX)
    if (total <= vis)
        return

    thumbH := Max(20, (vis / total) * h)
    maxScroll := total - vis
    thumbY := y + (maxScroll > 0 ? (gScroll / maxScroll) * (h - thumbH) : 0)
    _FillRRect(x, thumbY, w, thumbH, w / 2, gBrushes["scrollbar"])
}

_DrawFooter(x, y, w, h) {
    global gBrushes, gFormats, gThumbVisible
    _FillRect(x, y, w, 1, gBrushes["footerBdr"])
    thumbState := gThumbVisible ? "ON" : "OFF"
    text := "[Tab] Nav  [T] Thumb=" thumbState "  [B] Backdrop  [Esc] Exit"
    _Text(text, gFormats["footer"], x, y + 4, w, h - 4, gBrushes["textFooter"])
}

_DrawTiming(x, y, w, h) {
    global gBrushes, gFormats, gTimingMs, gFps
    _FillRRect(x, y, w, h, 4, gBrushes["timingBg"])
    text := Format("D2D ComCall: {:.2f}ms | {} FPS  ", gTimingMs, gFps)
    _Text(text, gFormats["timing"], x + 4, y, w - 8, h, gBrushes["timingText"])
}

; ======================== DWM THUMBNAIL ========================

ToggleThumbnail() {
    global gThumbId, gThumbSrc, gThumbVisible, gHwnd, gWinW, gWinH, gDpiScale

    if (gThumbVisible) {
        ; Unregister
        if (gThumbId) {
            DllCall("dwmapi\DwmUnregisterThumbnail", "ptr", gThumbId)
            gThumbId := 0
        }
        gThumbVisible := false
        return
    }

    ; Find a source window (first visible, non-us window)
    gThumbSrc := 0
    callback := CallbackCreate(_EnumWindowProc, "Fast", 2)
    DllCall("EnumWindows", "ptr", callback, "ptr", 0)
    CallbackFree(callback)

    if (!gThumbSrc)
        return

    ; Register thumbnail
    thumbId := 0
    hr := DllCall("dwmapi\DwmRegisterThumbnail", "ptr", gHwnd, "ptr", gThumbSrc, "ptr*", &thumbId, "int")
    if (hr != 0 || !thumbId)
        return

    gThumbId := thumbId

    ; Position: right portion of the window
    dipW := gWinW / gDpiScale
    visRows := Min(gItems.Length, ROWS_VISIBLE_MAX)
    rowsY := MARGIN_Y + HEADER_HEIGHT

    destL := Round(dipW * 0.65 * gDpiScale)
    destT := Round(rowsY * gDpiScale)
    destR := Round((dipW * 0.65 + dipW * 0.30) * gDpiScale)
    destB := Round((rowsY + visRows * ROW_HEIGHT * 0.6) * gDpiScale)

    ; Update thumbnail properties
    props := Buffer(48, 0)
    flags := 0x01 | 0x08 | 0x04 | 0x10  ; DEST | VISIBLE | OPACITY | SRCLIENT
    NumPut("uint", flags, props, 0)
    NumPut("int", destL, "int", destT, "int", destR, "int", destB, props, 4)
    NumPut("uchar", 255, props, 36)   ; opacity
    NumPut("int", 1, props, 40)       ; fVisible
    NumPut("int", 1, props, 44)       ; fSourceClientAreaOnly

    DllCall("dwmapi\DwmUpdateThumbnailProperties", "ptr", gThumbId, "ptr", props)
    gThumbVisible := true
}

_EnumWindowProc(hwnd, lParam) {
    global gThumbSrc, gHwnd
    if (gThumbSrc)
        return 0
    if (hwnd = gHwnd)
        return 1
    if (!DllCall("IsWindowVisible", "ptr", hwnd))
        return 1
    ; Skip cloaked
    cloaked := 0
    DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "int", 14, "int*", &cloaked, "int", 4)
    if (cloaked)
        return 1
    ; Skip empty titles
    titleLen := DllCall("GetWindowTextLengthW", "ptr", hwnd, "int")
    if (titleLen <= 0)
        return 1
    ; Skip tool windows
    exStyle := DllCall("GetWindowLongPtrW", "ptr", hwnd, "int", -20, "ptr")
    if (exStyle & 0x80)  ; WS_EX_TOOLWINDOW
        return 1
    gThumbSrc := hwnd
    return 0
}

; ======================== KEYBOARD ========================

SetupKeys() {
    global gHwnd
    HotIfWinActive("ahk_id " gHwnd)
    Hotkey("Down",  (*) => _MoveSel(1))
    Hotkey("Up",    (*) => _MoveSel(-1))
    Hotkey("Tab",   (*) => _MoveSel(1))
    Hotkey("+Tab",  (*) => _MoveSel(-1))
    Hotkey("t",     (*) => ToggleThumbnail())
    Hotkey("b",     (*) => _CycleBackdrop())
    Hotkey("Escape", (*) => ExitApp())
}

_MoveSel(delta) {
    global gSel, gScroll, gItems
    gSel := Mod(gSel - 1 + delta + gItems.Length, gItems.Length) + 1

    visRows := Min(gItems.Length, ROWS_VISIBLE_MAX)
    if (gSel > gScroll + visRows)
        gScroll := gSel - visRows
    if (gSel <= gScroll)
        gScroll := gSel - 1
    gScroll := Max(0, Min(gScroll, gItems.Length - visRows))
}

_CycleBackdrop() {
    global gBackdrop, gBackdropNames
    gBackdrop := Mod(gBackdrop, gBackdropNames.Length) + 1
    _ApplyBackdrop()
}

; ======================== WINDOW MESSAGES ========================

OnEraseBkgnd(wParam, lParam, msg, hwnd) {
    global gHwnd
    if (hwnd = gHwnd)
        return 1
}

OnResize(thisGui, minMax, w, h) {
    global gRT, gWinW, gWinH
    if (!gRT || minMax = -1)
        return
    gWinW := w
    gWinH := h
    sizeU := Buffer(8)
    NumPut("uint", w, "uint", h, sizeU)
    try gRT.Resize(sizeU)
}

; ======================== CLEANUP ========================

Cleanup(reason, code) {
    global gRT, gFactory, gDWrite, gBrushes, gFormats, gThumbId

    SetTimer(PaintFrame, 0)

    if (gThumbId) {
        DllCall("dwmapi\DwmUnregisterThumbnail", "ptr", gThumbId)
        gThumbId := 0
    }

    ; Release D2D resources — ID2DBase.__Delete() calls ObjRelease automatically
    gBrushes := Map()
    gFormats := Map()
    gRT := ""
    gDWrite := ""
    gFactory := ""
}

; ======================== DRAWING HELPERS ========================

_Text(str, fmt, x, y, w, h, brush) {
    global gRT
    rect := Buffer(16)
    NumPut("float", Float(x), "float", Float(y),
           "float", Float(x + w), "float", Float(y + h), rect)
    gRT.DrawText(str, fmt, rect, brush, 2)  ; D2D1_DRAW_TEXT_OPTIONS_CLIP
}

_FillRect(x, y, w, h, brush) {
    global gRT
    rect := Buffer(16)
    NumPut("float", Float(x), "float", Float(y),
           "float", Float(x + w), "float", Float(y + h), rect)
    gRT.FillRectangle(rect, brush)
}

_FillRRect(x, y, w, h, r, brush) {
    global gRT
    rr := Buffer(24)
    NumPut("float", Float(x), "float", Float(y),
           "float", Float(x + w), "float", Float(y + h), rr, 0)
    NumPut("float", Float(r), "float", Float(r), rr, 16)
    gRT.FillRoundedRectangle(rr, brush)
}

; ======================== HELPER UTILITIES ========================

_ARGB(argb) {
    buf := Buffer(16)
    NumPut("float", ((argb >> 16) & 0xFF) / 255.0,
           "float", ((argb >> 8) & 0xFF) / 255.0,
           "float", (argb & 0xFF) / 255.0,
           "float", ((argb >> 24) & 0xFF) / 255.0,
           buf)
    return buf
}

_QPC() {
    DllCall("QueryPerformanceCounter", "int64*", &c := 0)
    return c
}

_QPF() {
    static f := 0
    if (!f)
        DllCall("QueryPerformanceFrequency", "int64*", &f)
    return f
}

_DWMAttr(hwnd, attr, val) {
    buf := Buffer(4, 0)
    NumPut("int", val, buf)
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "int", attr, "ptr", buf, "int", 4, "int")
}

_ApplyBackdrop() {
    global gHwnd, gBackdrop, gBackdropNames
    mode := gBackdropNames[gBackdrop]

    ; Clear previous
    _ApplySWC(gHwnd, 0, 0)
    _DWMAttr(gHwnd, 38, 0)

    switch mode {
        case "Acrylic":
            _ApplySWC(gHwnd, 4, 0x88002244)
        case "Blur":
            _ApplySWC(gHwnd, 3, 0)
        case "None":
            ; Nothing — D2D draws dark background
    }
}

_ApplySWC(hWnd, accentType, argbColor) {
    alpha := (argbColor >> 24) & 0xFF
    rr    := (argbColor >> 16) & 0xFF
    gg    := (argbColor >> 8) & 0xFF
    bb    := argbColor & 0xFF
    grad  := (alpha << 24) | (bb << 16) | (gg << 8) | rr

    accent := Buffer(16, 0)
    NumPut("int", accentType, accent, 0)
    NumPut("int", grad, accent, 8)

    data := Buffer(A_PtrSize * 3, 0)
    NumPut("int", 19, data, 0)
    NumPut("ptr", accent.Ptr, data, A_PtrSize)
    NumPut("int", accent.Size, data, A_PtrSize * 2)

    return DllCall("user32\SetWindowCompositionAttribute", "ptr", hWnd, "ptr", data.Ptr, "int")
}
