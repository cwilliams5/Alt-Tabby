#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================================
; Direct2D Overlay Proof of Concept — Alt-Tabby
;
; Standalone demo: D2D + DirectWrite + DWM backdrop from AHK v2 via DllCall.
; No production dependencies. Mock data. Run directly:
;   AutoHotkey64.exe legacy\gui_mocks\mock_d2d_overlay.ahk
;
; Keys:
;   Up / Shift+Tab   — Select previous row
;   Down / Tab        — Select next row
;   B                 — Cycle backdrop (SWC Acrylic → SWC Blur → DWM Acrylic → None)
;   R                 — Cycle corner radius (0 → 6 → 12 → 18 → 24)
;   P                 — Toggle path geometry (per-corner radii) vs built-in rounded rect
;   T                 — Toggle paint timing overlay
;   Esc               — Exit
;
; Vtable indices verified against Spawnova/ShinsOverlayClass (known working).
; ============================================================================

; -- DPI awareness (before any window creation) --
try DllCall("SetProcessDpiAwarenessContext", "ptr", -4, "int")

; ======================== LAYOUT CONSTANTS (DIPs) ========================

SCREEN_WIDTH_PCT  := 0.60
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
SCROLLBAR_MARGIN  := 4
TITLE_Y           := 6
TITLE_H           := 24
SUB_Y             := 30
SUB_H             := 18

; ======================== COLORS (0xAARRGGBB) ========================

CLR_SEL           := 0x662B5CAD
CLR_TEXT_MAIN     := 0xFFF0F0F0
CLR_TEXT_MAIN_HI  := 0xFFF0F0F0
CLR_TEXT_SUB      := 0xFFB5C0CE
CLR_TEXT_SUB_HI   := 0xFFB5C0CE
CLR_TEXT_COL      := 0xFFF0F0F0
CLR_TEXT_HDR      := 0xFFD0D6DE
CLR_TEXT_FOOTER   := 0xFFFFFFFF
CLR_SCROLLBAR     := 0x88FFFFFF
CLR_ICON_BG       := 0xFF3A5F8A
CLR_ICON_TEXT     := 0xFFFFFFFF
CLR_FOOTER_BORDER := 0x33FFFFFF
CLR_TIMING_BG     := 0xCC000000
CLR_TIMING_TEXT   := 0xFF00FF88
CLR_DARK_BG       := 0xE01A1A2E

; ======================== VTABLE INDICES (verified vs ShinsOverlayClass) ========================

; ID2D1Factory (IUnknown 0-2, then factory methods 3+)
VT_F_CREATE_PATH  := 10
VT_F_CREATE_HWND  := 14

; ID2D1RenderTarget (IUnknown 0-2, ID2D1Resource 3, RT methods 4+)
; Note: FillMesh at 24 shifts DrawBitmap+ by 1 vs naive count
VT_CREATE_BRUSH   := 8
VT_FILL_RECT      := 17
VT_FILL_RRECT     := 19
VT_FILL_ELLIPSE   := 21
VT_FILL_GEOM      := 23
VT_DRAW_TEXT      := 27
VT_SET_TRANSFORM  := 30
VT_SET_AA         := 32
VT_SET_TEXT_AA    := 34
VT_CLEAR          := 47
VT_BEGIN_DRAW     := 48
VT_END_DRAW       := 49
VT_SET_DPI        := 51

; ID2D1HwndRenderTarget (extends RT, then CheckWindowState=57, Resize=58)
VT_RESIZE         := 58

; IDWriteFactory (IUnknown 0-2, then factory methods 3+)
; Note: RegisterFontFileLoader(13) + UnregisterFontFileLoader(14) shift CreateTextFormat to 15
VT_DW_TEXT_FMT    := 15

; IDWriteTextFormat (IUnknown 0-2, then format methods 3+)
VT_TF_ALIGN       := 3
VT_TF_PARA_ALIGN  := 4
VT_TF_WORD_WRAP   := 5

; ID2D1PathGeometry (IUnknown 0-2, Resource 3, Geometry 4-16, PathGeometry 17+)
VT_PATH_OPEN      := 17

; ID2D1GeometrySink (IUnknown 0-2, SimplifiedSink 3-9, Sink 10+)
VT_SINK_FILL_MODE := 3
VT_SINK_BEGIN_FIG := 5
VT_SINK_END_FIG   := 8
VT_SINK_CLOSE     := 9
VT_SINK_ADD_LINE  := 10
VT_SINK_ADD_ARC   := 14

; D2D enums
D2DERR_RECREATE   := 0x8899000C

; DWrite font weights
DW_REGULAR        := 400
DW_SEMIBOLD       := 600
DW_EXTRABOLD      := 800

; ======================== GLOBAL STATE ========================

gD2D  := 0       ; ID2D1Factory*
gDW   := 0       ; IDWriteFactory*
gRT   := 0       ; ID2D1HwndRenderTarget*
gHwnd := 0
gGui  := ""

gBr   := Map()   ; brushes: name → ID2D1SolidColorBrush*
gTf   := Map()   ; text formats: name → IDWriteTextFormat*

gSel       := 1
gScroll    := 0
gBackdrop  := 1         ; index into gBackdropNames
gRadius    := 12
gShowTiming := true
gUsePath   := false
gTimingMs  := 0.0
gFrameCount := 0
gFpsTime   := 0
gFps       := 0
gWinW      := 0
gWinH      := 0
gDpiScale  := 1.0
gItems     := []

gBackdropNames := ["SWC Acrylic", "SWC Blur", "DWM Acrylic", "None"]

; ======================== ENTRY POINT ========================

OnExit(_Cleanup)
Main()
return

Main() {
    global

    InitMockData()
    CreateFactories()
    CreateWindow()       ; creates GUI, gets gHwnd
    CreateRenderTarget() ; creates D2D RT, sets gDpiScale from monitor DPI
    ScaleWindow()        ; resize window to match DPI-scaled layout
    CreateResources()
    SetupKeys()

    gFpsTime := A_TickCount
    SetTimer(PaintFrame, 16)
}

; ======================== MOCK DATA ========================

InitMockData() {
    global gItems
    gItems := [
        {title: "Visual Studio Code",       proc: "Code.exe",              ws: "Dev",   cls: "Chrome_WidgetWin_1"},
        {title: "Alt-Tabby — config.ini",   proc: "AltTabby.exe",          ws: "Dev",   cls: "AutoHotkey"},
        {title: "Windows Terminal",          proc: "WindowsTerminal.exe",   ws: "Main",  cls: "CASCADIA_HOSTING"},
        {title: "Mozilla Firefox — GitHub",  proc: "firefox.exe",           ws: "Web",   cls: "MozillaWindowClass"},
        {title: "File Explorer — Documents", proc: "explorer.exe",          ws: "Main",  cls: "CabinetWClass"},
        {title: "Spotify Premium",           proc: "Spotify.exe",           ws: "Media", cls: "Chrome_WidgetWin_0"},
        {title: "Discord",                   proc: "Discord.exe",           ws: "Chat",  cls: "Chrome_WidgetWin_1"},
        {title: "Obsidian — Vault",          proc: "Obsidian.exe",          ws: "Notes", cls: "Chrome_WidgetWin_1"},
        {title: "Task Manager",              proc: "Taskmgr.exe",           ws: "Main",  cls: "TaskManagerWindow"},
        {title: "Paint",                     proc: "mspaint.exe",           ws: "Main",  cls: "MSPaintApp"},
        {title: "Notepad — scratch.txt",     proc: "notepad.exe",           ws: "Dev",   cls: "Notepad"},
        {title: "PowerShell 7",              proc: "pwsh.exe",              ws: "Dev",   cls: "CASCADIA_HOSTING"},
    ]
}

; ======================== COM FACTORIES ========================

CreateFactories() {
    global gD2D, gDW

    ; Explicit DLL loading required for reliable factory creation in AHK v2
    DllCall("LoadLibrary", "str", "d2d1.dll", "ptr")
    DllCall("LoadLibrary", "str", "dwrite.dll", "ptr")

    ; ID2D1Factory — SINGLE_THREADED (type 0) required for AHK v2's STA apartment
    iid := GUID("{06152247-6F50-465A-9245-118BFD3B6007}")
    gD2D := 0
    hr := DllCall("d2d1\D2D1CreateFactory", "uint", 0, "ptr", iid, "ptr", 0, "ptr*", &gD2D, "int")
    if (hr != 0 || !gD2D)
        throw Error("D2D1CreateFactory failed: " Format("0x{:08X}", hr))

    ; IDWriteFactory
    iid2 := GUID("{B859EE5A-D838-4B5B-A2E8-1ADC7D93DB48}")
    gDW := 0
    hr := DllCall("dwrite\DWriteCreateFactory", "uint", 0, "ptr", iid2, "ptr*", &gDW, "int")
    if (hr != 0 || !gDW)
        throw Error("DWriteCreateFactory failed: " Format("0x{:08X}", hr))
}

; ======================== WINDOW CREATION ========================

CreateWindow() {
    global gGui, gHwnd, gWinW, gWinH

    ; Initial size (will be corrected by ScaleWindow after DPI is known)
    gWinW := Round(A_ScreenWidth * SCREEN_WIDTH_PCT)
    gWinH := 500

    ; WS_EX_LAYERED (0x80000) required for D2D transparency
    ; +Resize (WS_THICKFRAME) needed for DWMWA_SYSTEMBACKDROP_TYPE on Win11
    gGui := Gui("+AlwaysOnTop -Caption +Resize -DPIScale +E0x80000")
    gGui.BackColor := "000000"
    gGui.Show("x0 y0 w" gWinW " h" gWinH " Hide")
    gHwnd := gGui.Hwnd

    ; Match Shins: SetLayeredWindowAttributes — opaque but layered
    DllCall("SetLayeredWindowAttributes", "uptr", gHwnd, "uint", 0, "char", 255, "uint", 2)

    ; DWM: extend frame for transparency, then backdrop
    margins := Buffer(16, 0)
    NumPut("int", -1, "int", -1, "int", -1, "int", -1, margins)
    DllCall("dwmapi\DwmExtendFrameIntoClientArea", "ptr", gHwnd, "ptr", margins)

    ; DWM: dark mode + rounded corners
    DWMAttr(gHwnd, 20, 1)   ; DWMWA_USE_IMMERSIVE_DARK_MODE
    DWMAttr(gHwnd, 19, 1)   ; Fallback for older Win10
    DWMAttr(gHwnd, 33, 2)   ; DWMWA_WINDOW_CORNER_PREFERENCE = Round

    ; Hollow brush so DWM material shows through
    hollowBrush := DllCall("GetStockObject", "int", 5, "ptr")
    DllCall("SetClassLongPtrW", "ptr", gHwnd, "int", -10, "ptr", hollowBrush, "ptr")

    ; Apply initial backdrop
    ApplyBackdrop()

    ; Window messages
    gGui.OnEvent("Close", (*) => ExitApp())
    gGui.OnEvent("Size", OnResize)
    OnMessage(0x0014, OnEraseBkgnd)   ; WM_ERASEBKGND
    OnMessage(0x0084, OnHitTest)      ; WM_NCHITTEST

}

ScaleWindow() {
    global gGui, gHwnd, gWinW, gWinH, gDpiScale, gItems

    ; Layout constants are in DIPs. Physical pixels = DIPs * scale.
    visRows := Min(gItems.Length, ROWS_VISIBLE_MAX)
    dipH := MARGIN_Y + HEADER_HEIGHT + (visRows * ROW_HEIGHT) + FOOTER_HEIGHT + MARGIN_Y
    gWinW := Round(A_ScreenWidth * SCREEN_WIDTH_PCT)
    gWinH := Round(dipH * gDpiScale)

    x := (A_ScreenWidth - gWinW) // 2
    y := (A_ScreenHeight - gWinH) // 2

    gGui.Show("x" x " y" y " w" gWinW " h" gWinH)
}

ApplyBackdrop() {
    global gHwnd, gBackdrop, gBackdropNames
    mode := gBackdropNames[gBackdrop]

    ; Clear previous SWC accent
    _ApplySWC(gHwnd, 0, 0)
    ; Clear previous DWM backdrop type
    DWMAttr(gHwnd, 38, 0)

    switch mode {
        case "SWC Acrylic":
            _ApplySWC(gHwnd, 4, 0x88002244)       ; ACCENT_ENABLE_ACRYLICBLURBEHIND
        case "SWC Blur":
            _ApplySWC(gHwnd, 3, 0)                 ; ACCENT_ENABLE_BLURBEHIND
        case "DWM Acrylic":
            _ApplySWC(gHwnd, 5, 0)                 ; ACCENT_ENABLE_HOSTBACKDROP
            DWMAttr(gHwnd, 38, 3)                   ; DWMSBT_TRANSIENTWINDOW
        case "None":
            ; No backdrop — D2D draws a dark background
    }
}

; ======================== RENDER TARGET ========================

CreateRenderTarget() {
    global gD2D, gRT, gHwnd, gWinW, gWinH, gDpiScale

    ; Get monitor DPI for this window
    dpi := DllCall("GetDpiForWindow", "ptr", gHwnd, "uint")
    if (!dpi)
        dpi := 96
    gDpiScale := dpi / 96.0

    ; D2D1_RENDER_TARGET_PROPERTIES — DXGI_FORMAT_UNKNOWN, PREMULTIPLIED, monitor DPI
    rtProps := Buffer(64, 0)
    NumPut("uint", 1, rtProps, 8)              ; alphaMode = D2D1_ALPHA_MODE_PREMULTIPLIED
    NumPut("float", Float(dpi), rtProps, 12)   ; dpiX — match monitor DPI
    NumPut("float", Float(dpi), rtProps, 16)   ; dpiY

    ; D2D1_HWND_RENDER_TARGET_PROPERTIES
    hwndProps := Buffer(64, 0)
    NumPut("uptr", gHwnd, hwndProps, 0)
    NumPut("uint", gWinW, hwndProps, A_PtrSize)
    NumPut("uint", gWinH, hwndProps, A_PtrSize + 4)
    NumPut("uint", 0, hwndProps, A_PtrSize + 8)    ; D2D1_PRESENT_OPTIONS_NONE

    ; Use DllCall with manual vtable lookup (matching Shins exactly)
    ; ComCall was crashing — use DllCall to match proven Shins pattern
    pFunc := _VT(gD2D, VT_F_CREATE_HWND)
    hr := DllCall(pFunc, "ptr", gD2D, "ptr", rtProps, "ptr", hwndProps, "ptr*", &gRT := 0, "int")
    if (hr != 0 || !gRT)
        throw Error("CreateHwndRenderTarget failed: " Format("0x{:08X}", hr) " gD2D=" gD2D " hwnd=" gHwnd " w=" gWinW " h=" gWinH)

    ; Anti-aliasing: per-primitive for geometry, grayscale for text
    DllCall(_VT(gRT, VT_SET_AA), "ptr", gRT, "uint", 0)
    DllCall(_VT(gRT, VT_SET_TEXT_AA), "ptr", gRT, "uint", 2)
}

; ======================== RESOURCES ========================

CreateResources() {
    global gRT, gDW, gBr, gTf

    ; -- Brushes --
    gBr["sel"]        := _MkBrush(CLR_SEL)
    gBr["textMain"]   := _MkBrush(CLR_TEXT_MAIN)
    gBr["textMainHi"] := _MkBrush(CLR_TEXT_MAIN_HI)
    gBr["textSub"]    := _MkBrush(CLR_TEXT_SUB)
    gBr["textSubHi"]  := _MkBrush(CLR_TEXT_SUB_HI)
    gBr["textCol"]    := _MkBrush(CLR_TEXT_COL)
    gBr["textHdr"]    := _MkBrush(CLR_TEXT_HDR)
    gBr["textFooter"] := _MkBrush(CLR_TEXT_FOOTER)
    gBr["scrollbar"]  := _MkBrush(CLR_SCROLLBAR)
    gBr["iconBg"]     := _MkBrush(CLR_ICON_BG)
    gBr["iconText"]   := _MkBrush(CLR_ICON_TEXT)
    gBr["footerBdr"]  := _MkBrush(CLR_FOOTER_BORDER)
    gBr["timingBg"]   := _MkBrush(CLR_TIMING_BG)
    gBr["timingText"] := _MkBrush(CLR_TIMING_TEXT)
    gBr["darkBg"]     := _MkBrush(CLR_DARK_BG)

    ; -- Text Formats --
    gTf["title"]   := _MkFmt("Segoe UI", 18, DW_REGULAR)
    gTf["titleHi"] := _MkFmt("Segoe UI", 18, DW_EXTRABOLD)
    gTf["sub"]     := _MkFmt("Segoe UI", 11.5, DW_REGULAR)
    gTf["subHi"]   := _MkFmt("Segoe UI", 11.5, DW_SEMIBOLD)
    gTf["col"]     := _MkFmt("Segoe UI", 11.5, DW_REGULAR)
    gTf["hdr"]     := _MkFmt("Segoe UI", 11.5, DW_SEMIBOLD)
    gTf["footer"]  := _MkFmt("Segoe UI", 12, DW_SEMIBOLD)
    gTf["timing"]  := _MkFmt("Consolas", 11, DW_REGULAR)
    gTf["icon"]    := _MkFmt("Segoe UI", 15, DW_SEMIBOLD)

    ; Default: no-wrap, vertically centered
    for name, tf in gTf {
        DllCall(_VT(tf, VT_TF_WORD_WRAP), "ptr", tf, "uint", 1, "int")     ; NoWrap
        DllCall(_VT(tf, VT_TF_PARA_ALIGN), "ptr", tf, "uint", 2, "int")    ; Center vertically
    }

    ; Horizontal alignment overrides
    DllCall(_VT(gTf["col"], VT_TF_ALIGN), "ptr", gTf["col"], "uint", 1, "int")     ; Right-align columns
    DllCall(_VT(gTf["footer"], VT_TF_ALIGN), "ptr", gTf["footer"], "uint", 2, "int")  ; Center footer
    DllCall(_VT(gTf["timing"], VT_TF_ALIGN), "ptr", gTf["timing"], "uint", 1, "int")  ; Right-align timing
    DllCall(_VT(gTf["icon"], VT_TF_ALIGN), "ptr", gTf["icon"], "uint", 2, "int")    ; Center icon letter
}

_MkBrush(argb) {
    global gRT
    color := _ARGB(argb)
    pBrush := 0
    DllCall(_VT(gRT, VT_CREATE_BRUSH), "ptr", gRT, "ptr", color, "ptr", 0, "ptr*", &pBrush)
    return pBrush
}

_MkFmt(font, size, weight) {
    global gDW
    pFmt := 0
    DllCall(_VT(gDW, VT_DW_TEXT_FMT), "ptr", gDW,
        "wstr", font,
        "ptr", 0,                ; system font collection
        "uint", weight,
        "uint", 0,               ; DWRITE_FONT_STYLE_NORMAL
        "uint", 5,               ; DWRITE_FONT_STRETCH_NORMAL
        "float", Float(size),
        "wstr", "en-us",
        "ptr*", &pFmt)
    return pFmt
}

; ======================== PAINT FRAME ========================

PaintFrame() {
    global gRT, gHwnd, gWinW, gWinH, gDpiScale, gItems, gSel, gScroll, gRadius
    global gBr, gTf, gShowTiming, gTimingMs, gFrameCount, gFpsTime, gFps
    global gBackdrop, gBackdropNames, gUsePath

    if (!gRT)
        return

    t0 := QPC()

    ; All coordinates below are in DIPs — the render target scales to physical pixels
    dipW := gWinW / gDpiScale
    dipH := gWinH / gDpiScale

    ; -- Begin --
    DllCall(_VT(gRT, VT_BEGIN_DRAW), "ptr", gRT)

    ; Clear to transparent (lets DWM backdrop show through)
    clearClr := Buffer(16, 0)
    DllCall(_VT(gRT, VT_CLEAR), "ptr", gRT, "ptr", clearClr)

    ; If no backdrop, draw a dark solid background
    if (gBackdropNames[gBackdrop] = "None")
        _FillRect(0, 0, dipW, dipH, gBr["darkBg"])

    ; -- Layout (all in DIPs) --
    cx := MARGIN_X
    cy := MARGIN_Y
    cw := dipW - MARGIN_X * 2 - SCROLLBAR_WIDTH - SCROLLBAR_MARGIN * 2
    visRows := Min(gItems.Length, ROWS_VISIBLE_MAX)
    hdrY    := cy
    rowsY   := hdrY + HEADER_HEIGHT
    footerY := rowsY + (visRows * ROW_HEIGHT)

    ; -- Header --
    hdrText := "Alt-Tabby D2D POC — " gItems.Length " windows"
    _Text(hdrText, gTf["hdr"], cx + ICON_LEFT_MARGIN, hdrY, cw, HEADER_HEIGHT, gBr["textHdr"])

    ; -- Rows --
    loop visRows {
        idx := gScroll + A_Index
        if (idx > gItems.Length)
            break
        ry := rowsY + (A_Index - 1) * ROW_HEIGHT
        _DrawRow(gItems[idx], cx, ry, cw, ROW_HEIGHT, idx = gSel)
    }

    ; -- Scrollbar --
    if (gItems.Length > ROWS_VISIBLE_MAX) {
        sbX := dipW - MARGIN_X - SCROLLBAR_WIDTH
        _DrawScrollbar(sbX, rowsY, SCROLLBAR_WIDTH, visRows * ROW_HEIGHT)
    }

    ; -- Footer --
    fW := dipW - MARGIN_X * 2
    _DrawFooter(cx, footerY, fW, FOOTER_HEIGHT)

    ; -- Timing overlay --
    if (gShowTiming)
        _DrawTiming(dipW - MARGIN_X - 220, MARGIN_Y, 220, 22)

    ; -- End --
    hr := DllCall(_VT(gRT, VT_END_DRAW), "ptr", gRT, "int64*", &tag1 := 0, "int64*", &tag2 := 0, "int")
    if (hr = D2DERR_RECREATE) {
        _RecreateResources()
        return
    }

    ; -- Timing stats --
    gTimingMs := (QPC() - t0) / QPF() * 1000.0
    gFrameCount++
    if (A_TickCount - gFpsTime >= 1000) {
        gFps := gFrameCount
        gFrameCount := 0
        gFpsTime := A_TickCount
    }
}

; ======================== ROW RENDERING ========================

_DrawRow(item, x, y, w, h, isSel) {
    global gBr, gTf, gRadius, gUsePath

    ; Selection pill
    if (isSel) {
        pillY := y + 2
        pillH := h - 4
        if (gUsePath)
            _DrawPathRRect(x, pillY, w, pillH, gRadius, gBr["sel"])
        else
            _FillRRect(x, pillY, w, pillH, gRadius, gBr["sel"])
    }

    ; Icon circle
    iconCx := x + ICON_LEFT_MARGIN + ICON_SIZE / 2
    iconCy := y + h / 2
    iconR  := ICON_SIZE / 2 - 2
    _FillEllipse(iconCx, iconCy, iconR, iconR, gBr["iconBg"])

    ; Letter inside icon
    letter := SubStr(item.proc, 1, 1)
    iconX := x + ICON_LEFT_MARGIN
    iconY := y + (h - ICON_SIZE) / 2
    _Text(letter, gTf["icon"], iconX, iconY, ICON_SIZE, ICON_SIZE, gBr["iconText"])

    ; Text area
    textX := x + ICON_LEFT_MARGIN + ICON_SIZE + ICON_TEXT_GAP
    textW := w - ICON_LEFT_MARGIN - ICON_SIZE - ICON_TEXT_GAP - 100

    ; Title
    brT := gBr[isSel ? "textMainHi" : "textMain"]
    tfT := gTf[isSel ? "titleHi" : "title"]
    _Text(item.title, tfT, textX, y + TITLE_Y, textW, TITLE_H, brT)

    ; Subtitle
    brS := gBr[isSel ? "textSubHi" : "textSub"]
    tfS := gTf[isSel ? "subHi" : "sub"]
    _Text(item.proc "  ·  " item.cls, tfS, textX, y + SUB_Y, textW, SUB_H, brS)

    ; Workspace tag (right-aligned)
    colX := x + w - 80
    _Text(item.ws, gTf["col"], colX, y + 10, 80, 20, gBr["textCol"])
}

; ======================== SCROLLBAR ========================

_DrawScrollbar(x, y, w, h) {
    global gBr, gScroll, gItems

    total := gItems.Length
    vis := Min(total, ROWS_VISIBLE_MAX)
    if (total <= vis)
        return

    thumbH := Max(20, (vis / total) * h)
    maxScroll := total - vis
    thumbY := y + (maxScroll > 0 ? (gScroll / maxScroll) * (h - thumbH) : 0)

    _FillRRect(x, thumbY, w, thumbH, w / 2, gBr["scrollbar"])
}

; ======================== HEADER / FOOTER ========================

_DrawFooter(x, y, w, h) {
    global gBr, gTf, gBackdropNames, gBackdrop, gRadius, gUsePath

    ; Top border line
    _FillRect(x, y, w, 1, gBr["footerBdr"])

    ; Status text
    mode := gBackdropNames[gBackdrop]
    text := "[B] " mode "  [R] r=" gRadius "  [P] " (gUsePath ? "PathGeom" : "BuiltIn") "  [T] Timing  [Esc] Exit"
    _Text(text, gTf["footer"], x, y + 4, w, h - 4, gBr["textFooter"])
}

; ======================== TIMING OVERLAY ========================

_DrawTiming(x, y, w, h) {
    global gBr, gTf, gTimingMs, gFps

    _FillRRect(x, y, w, h, 4, gBr["timingBg"])
    text := Format("D2D: {:.2f}ms | {} FPS  ", gTimingMs, gFps)
    _Text(text, gTf["timing"], x + 4, y, w - 8, h, gBr["timingText"])
}

; ======================== PATH GEOMETRY ROUNDED RECT ========================

_DrawPathRRect(x, y, w, h, r, pBrush) {
    ; Per-corner radii demo: TL=r, TR=r/2, BR=r, BL=r*1.5
    global gD2D, gRT

    if (r <= 0) {
        _FillRect(x, y, w, h, pBrush)
        return
    }

    rTL := r
    rTR := Max(2, r * 0.5)
    rBR := r
    rBL := Min(r * 1.5, h / 2)

    ; Create path geometry
    pPath := 0
    DllCall(_VT(gD2D, VT_F_CREATE_PATH), "ptr", gD2D, "ptr*", &pPath)
    if (!pPath)
        return

    ; Open geometry sink
    pSink := 0
    DllCall(_VT(pPath, VT_PATH_OPEN), "ptr", pPath, "ptr*", &pSink)
    if (!pSink) {
        ObjRelease(pPath)
        return
    }

    ; Fill mode = alternate
    DllCall(_VT(pSink, VT_SINK_FILL_MODE), "ptr", pSink, "uint", 0)

    ; Begin figure at top edge, after TL radius
    DllCall(_VT(pSink, VT_SINK_BEGIN_FIG), "ptr", pSink, "int64", _Pt(x + rTL, y), "uint", 0)

    ; Top edge → TR corner
    DllCall(_VT(pSink, VT_SINK_ADD_LINE), "ptr", pSink, "int64", _Pt(x + w - rTR, y))
    DllCall(_VT(pSink, VT_SINK_ADD_ARC), "ptr", pSink, "ptr", _Arc(x + w, y + rTR, rTR, rTR))

    ; Right edge → BR corner
    DllCall(_VT(pSink, VT_SINK_ADD_LINE), "ptr", pSink, "int64", _Pt(x + w, y + h - rBR))
    DllCall(_VT(pSink, VT_SINK_ADD_ARC), "ptr", pSink, "ptr", _Arc(x + w - rBR, y + h, rBR, rBR))

    ; Bottom edge → BL corner
    DllCall(_VT(pSink, VT_SINK_ADD_LINE), "ptr", pSink, "int64", _Pt(x + rBL, y + h))
    DllCall(_VT(pSink, VT_SINK_ADD_ARC), "ptr", pSink, "ptr", _Arc(x, y + h - rBL, rBL, rBL))

    ; Left edge → TL corner (back to start)
    DllCall(_VT(pSink, VT_SINK_ADD_LINE), "ptr", pSink, "int64", _Pt(x, y + rTL))
    DllCall(_VT(pSink, VT_SINK_ADD_ARC), "ptr", pSink, "ptr", _Arc(x + rTL, y, rTL, rTL))

    ; Close
    DllCall(_VT(pSink, VT_SINK_END_FIG), "ptr", pSink, "uint", 1)   ; D2D1_FIGURE_END_CLOSED
    DllCall(_VT(pSink, VT_SINK_CLOSE), "ptr", pSink)

    ; Fill the geometry
    DllCall(_VT(gRT, VT_FILL_GEOM), "ptr", gRT, "ptr", pPath, "ptr", pBrush, "ptr", 0)

    ; Release
    ObjRelease(pSink)
    ObjRelease(pPath)
}

; ======================== KEYBOARD ========================

SetupKeys() {
    global gHwnd
    HotIfWinActive("ahk_id " gHwnd)
    Hotkey("Down",  (*) => _MoveSel(1))
    Hotkey("Up",    (*) => _MoveSel(-1))
    Hotkey("Tab",   (*) => _MoveSel(1))
    Hotkey("+Tab",  (*) => _MoveSel(-1))
    Hotkey("b",     (*) => _CycleBackdrop())
    Hotkey("r",     (*) => _CycleRadius())
    Hotkey("p",     (*) => _TogglePath())
    Hotkey("t",     (*) => _ToggleTiming())
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
    ApplyBackdrop()
}

_CycleRadius() {
    global gRadius
    radii := [0, 6, 12, 18, 24]
    loop radii.Length {
        if (radii[A_Index] = gRadius) {
            gRadius := radii[Mod(A_Index, radii.Length) + 1]
            return
        }
    }
    gRadius := 12
}

_TogglePath() {
    global gUsePath
    gUsePath := !gUsePath
}

_ToggleTiming() {
    global gShowTiming
    gShowTiming := !gShowTiming
}

; ======================== WINDOW MESSAGE HANDLERS ========================

OnEraseBkgnd(wParam, lParam, msg, hwnd) {
    global gHwnd
    if (hwnd = gHwnd)
        return 1
}

OnHitTest(wParam, lParam, msg, hwnd) {
    global gHwnd
    if (hwnd = gHwnd)
        return 2   ; HTCAPTION — allows dragging the window
}

OnResize(thisGui, minMax, w, h) {
    global gRT, gWinW, gWinH
    if (!gRT || minMax = -1)
        return
    gWinW := w
    gWinH := h
    sizeU := Buffer(8)
    NumPut("uint", w, "uint", h, sizeU)
    try DllCall(_VT(gRT, VT_RESIZE), "ptr", gRT, "ptr", sizeU)
}

; ======================== DEVICE LOSS RECOVERY ========================

_RecreateResources() {
    global gRT, gBr, gTf

    for _, br in gBr
        if (br)
            ObjRelease(br)
    gBr := Map()

    for _, tf in gTf
        if (tf)
            ObjRelease(tf)
    gTf := Map()

    if (gRT)
        ObjRelease(gRT)
    gRT := 0

    CreateRenderTarget()
    CreateResources()
}

; ======================== CLEANUP ========================

_Cleanup(reason, code) {
    global gRT, gD2D, gDW, gBr, gTf

    SetTimer(PaintFrame, 0)

    for _, br in gBr
        if (br)
            ObjRelease(br)

    for _, tf in gTf
        if (tf)
            ObjRelease(tf)

    if (gRT)
        ObjRelease(gRT)
    if (gDW)
        ObjRelease(gDW)
    if (gD2D)
        ObjRelease(gD2D)
}

; ======================== D2D DRAWING HELPERS ========================

_Text(str, pFmt, x, y, w, h, pBrush) {
    global gRT
    rect := Buffer(16)
    NumPut("float", Float(x), "float", Float(y), "float", Float(x + w), "float", Float(y + h), rect)
    DllCall(_VT(gRT, VT_DRAW_TEXT), "ptr", gRT,
        "wstr", str,
        "uint", StrLen(str),
        "ptr", pFmt,
        "ptr", rect,
        "ptr", pBrush,
        "uint", 2,      ; D2D1_DRAW_TEXT_OPTIONS_CLIP
        "uint", 0)       ; DWRITE_MEASURING_MODE_NATURAL
}

_FillRect(x, y, w, h, pBrush) {
    global gRT
    rect := Buffer(16)
    NumPut("float", Float(x), "float", Float(y), "float", Float(x + w), "float", Float(y + h), rect)
    DllCall(_VT(gRT, VT_FILL_RECT), "ptr", gRT, "ptr", rect, "ptr", pBrush)
}

_FillRRect(x, y, w, h, r, pBrush) {
    global gRT
    rr := Buffer(24)
    NumPut("float", Float(x), "float", Float(y), "float", Float(x + w), "float", Float(y + h), rr, 0)
    NumPut("float", Float(r), "float", Float(r), rr, 16)
    DllCall(_VT(gRT, VT_FILL_RRECT), "ptr", gRT, "ptr", rr, "ptr", pBrush)
}

_FillEllipse(cx, cy, rx, ry, pBrush) {
    global gRT
    e := Buffer(16)
    NumPut("float", Float(cx), "float", Float(cy), "float", Float(rx), "float", Float(ry), e)
    DllCall(_VT(gRT, VT_FILL_ELLIPSE), "ptr", gRT, "ptr", e, "ptr", pBrush)
}

; ======================== STRUCT / GUID HELPERS ========================

; Pack D2D1_POINT_2F (8 bytes) into int64 for x64 by-value passing
_Pt(x, y) {
    static buf := Buffer(8)
    NumPut("float", Float(x), "float", Float(y), buf)
    return NumGet(buf, "int64")
}

; D2D1_ARC_SEGMENT (28 bytes): endPoint, size, rotation, sweepDir, arcSize
_Arc(endX, endY, rx, ry) {
    buf := Buffer(28, 0)
    NumPut("float", Float(endX), "float", Float(endY), buf, 0)
    NumPut("float", Float(rx), "float", Float(ry), buf, 8)
    NumPut("float", 0.0, buf, 16)      ; rotationAngle
    NumPut("uint", 1, buf, 20)          ; D2D1_SWEEP_DIRECTION_CLOCKWISE
    NumPut("uint", 0, buf, 24)          ; D2D1_ARC_SIZE_SMALL
    return buf
}

; Convert 0xAARRGGBB → D2D1_COLOR_F (r,g,b,a as floats)
_ARGB(argb) {
    buf := Buffer(16)
    NumPut("float", ((argb >> 16) & 0xFF) / 255.0,
           "float", ((argb >> 8) & 0xFF) / 255.0,
           "float", (argb & 0xFF) / 255.0,
           "float", ((argb >> 24) & 0xFF) / 255.0,
           buf)
    return buf
}

; GUID from string
GUID(str) {
    buf := Buffer(16)
    hr := DllCall("ole32\CLSIDFromString", "wstr", str, "ptr", buf, "int")
    if (hr != 0)
        throw Error("CLSIDFromString failed: " Format("0x{:08X}", hr))
    return buf
}

; COM vtable lookup — matches Shins pattern exactly
_VT(ptr, idx) {
    return NumGet(NumGet(ptr, 0, "ptr"), idx * A_PtrSize, "ptr")
}

; QueryPerformanceCounter
QPC() {
    DllCall("QueryPerformanceCounter", "int64*", &c := 0)
    return c
}

; QueryPerformanceFrequency (cached)
QPF() {
    static f := 0
    if (!f)
        DllCall("QueryPerformanceFrequency", "int64*", &f)
    return f
}

; DwmSetWindowAttribute helper
DWMAttr(hwnd, attr, val) {
    buf := Buffer(4, 0)
    NumPut("int", val, buf)
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "int", attr, "ptr", buf, "int", 4, "int")
}

; SetWindowCompositionAttribute (proven from mock_visual_styles.ahk)
_ApplySWC(hWnd, accentType, argbColor) {
    alpha := (argbColor >> 24) & 0xFF
    rr    := (argbColor >> 16) & 0xFF
    gg    := (argbColor >> 8) & 0xFF
    bb    := argbColor & 0xFF
    grad  := (alpha << 24) | (bb << 16) | (gg << 8) | rr

    accent := Buffer(16, 0)
    NumPut("int", accentType, accent, 0)
    NumPut("int", 0, accent, 4)
    NumPut("int", grad, accent, 8)
    NumPut("int", 0, accent, 12)

    data := Buffer(A_PtrSize * 3, 0)
    NumPut("int", 19, data, 0)
    NumPut("ptr", accent.Ptr, data, A_PtrSize)
    NumPut("int", accent.Size, data, A_PtrSize * 2)

    return DllCall("user32\SetWindowCompositionAttribute", "ptr", hWnd, "ptr", data.Ptr, "int")
}
