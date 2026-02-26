#Requires AutoHotkey v2.0
; Alt-Tabby GUI - Single Window + D2D Render Target
; Single-window architecture replaces the old base+overlay two-window system.
; SWCA acrylic backdrop + D2D HwndRenderTarget for content rendering.
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals/functions

; ========================= WINDOW STATE =========================

global gGUI_Base := 0          ; Gui object (the single window)
global gGUI_Overlay := 0       ; Alias → same as gGUI_Base (single-window compat)
global gGUI_BaseH := 0         ; Window handle
global gGUI_OverlayH := 0      ; Alias → same as gGUI_BaseH (single-window compat)
global GUI_LOG_TRIM_EVERY_N_HIDES := 10

; D2D factories (process-global, survive render target recreation)
global gD2D_Factory := 0       ; ID2D1Factory
global gDW_Factory := 0        ; IDWriteFactory
global gD2D_RT := 0            ; ID2D1HwndRenderTarget

; ========================= CONFIG-DRIVEN BACKDROP =========================

; Apply backdrop style from cfg.GUI_BackdropStyle.
; Acrylic and AeroGlass use SWCA (compositor-level blur).
; Solid skips SWCA — D2D paints the tint color directly each frame.
; DwmExtendFrame provides the glass-through for alpha blending.
_GUI_ApplyConfigBackdrop() {
    global gGUI_BaseH, cfg

    switch cfg.GUI_BackdropStyle {
        case "Acrylic":
            Win_ApplyAcrylic(gGUI_BaseH, cfg.GUI_AcrylicColor)
        case "AeroGlass":
            Win_ApplySWCAccent(gGUI_BaseH, 3, 0)
        case "Solid":
            ; No SWCA needed — D2D Clear uses cfg.GUI_AcrylicColor directly.
            ; SWCA gradient (accent 2) conflicts with DwmExtendFrame.
    }
}

; ========================= CORNER STYLE =========================

; Apply DWM corner preference from config.
_GUI_ApplyCornerStyle(hWnd) {
    global cfg
    switch cfg.GUI_CornerStyle {
        case "Round":      Win_SetCornerPreference(hWnd, 2)  ; DWMWCP_ROUND
        case "RoundSmall": Win_SetCornerPreference(hWnd, 3)  ; DWMWCP_ROUNDSMALL
        case "Square":     Win_SetCornerPreference(hWnd, 1)  ; DWMWCP_DONOTROUND
        default:           Win_SetCornerPreference(hWnd, 2)  ; DWMWCP_ROUND
    }
}

; ========================= SHOW/HIDE =========================

GUI_HideOverlay() {
    Profiler.Enter("GUI_HideOverlay") ; @profile
    global gGUI_OverlayVisible, gGUI_Base, gGUI_Revealed
    global cfg, GUI_LOG_TRIM_EVERY_N_HIDES, gD2D_RT
    static hideCount := 0

    if (!gGUI_OverlayVisible) {
        Profiler.Leave() ; @profile
        return
    }

    ; Stop hover polling and clear hover state
    GUI_ClearHoverState()

    ; Clear D2D surface BEFORE hiding — HwndRenderTarget::Present() is silently
    ; discarded for hidden windows (MSDN), so the last visible-frame content
    ; persists on the surface.  Without this clear, the stale frame flashes
    ; briefly on the next Show() before the new paint arrives.
    if (gD2D_RT) {
        try {
            gD2D_RT.BeginDraw()
            gD2D_RT.Clear(D2D_ColorF(0x00000000))
            gD2D_RT.EndDraw()
        }
    }

    try {
        gGUI_Base.Hide()
    }
    gGUI_OverlayVisible := false
    gGUI_Revealed := false

    ; Periodically trim paint timing log (every 10 hide cycles)
    hideCount += 1
    if (Mod(hideCount, GUI_LOG_TRIM_EVERY_N_HIDES) = 0) {
        Paint_LogTrim()
    }
    Profiler.Leave() ; @profile
}

; ========================= MONITOR TARGETING =========================

GUI_GetTargetMonitorHwnd() {
    global gGUI_BaseH, cfg
    if (cfg.GUI_OverlayMonitor = "Primary")
        return gGUI_BaseH
    try fgHwnd := WinExist("A")
    catch
        fgHwnd := 0
    if (fgHwnd && fgHwnd != gGUI_BaseH)
        return fgHwnd
    return gGUI_BaseH
}

; ========================= LAYOUT CALCULATIONS =========================

GUI_ComputeRowsToShow(count) {
    global cfg
    if (count >= cfg.GUI_RowsVisibleMax)
        return cfg.GUI_RowsVisibleMax
    if (count > cfg.GUI_RowsVisibleMin)
        return count
    return cfg.GUI_RowsVisibleMin
}

GUI_HeaderBlockDip() {
    global cfg, PAINT_HEADER_BLOCK_DIP
    if (cfg.GUI_ShowHeader)
        return PAINT_HEADER_BLOCK_DIP
    return 0
}

_GUI_FooterBlockDip() {
    global cfg
    if (cfg.GUI_ShowFooter)
        return cfg.GUI_FooterGapTopPx + cfg.GUI_FooterHeightPx
    return 0
}

GUI_GetVisibleRows() {
    global gGUI_BaseH, cfg

    ox := 0
    oy := 0
    owPhys := 0
    ohPhys := 0
    Win_GetRectPhys(gGUI_BaseH, &ox, &oy, &owPhys, &ohPhys)

    scale := Win_GetScaleForWindow(gGUI_BaseH)
    ohDip := ohPhys / scale

    headerTopDip := cfg.GUI_MarginY + GUI_HeaderBlockDip()
    footerDip := _GUI_FooterBlockDip()
    usableDip := ohDip - headerTopDip - cfg.GUI_MarginY - footerDip

    if (usableDip < cfg.GUI_RowHeight)
        return 0
    return Floor(usableDip / cfg.GUI_RowHeight)
}

; ========================= RESIZE =========================

GUI_ResizeToRows(rowsToShow, skipFlush := false) {
    Profiler.Enter("GUI_ResizeToRows") ; @profile
    global gGUI_Base, gGUI_BaseH, gD2D_RT, cfg

    xDip := 0
    yDip := 0
    wDip := 0
    hDip := 0
    GUI_GetWindowRect(&xDip, &yDip, &wDip, &hDip, rowsToShow)

    waL := 0
    waT := 0
    waR := 0
    waB := 0
    targetHwnd := GUI_GetTargetMonitorHwnd()
    Win_GetWorkAreaFromHwnd(targetHwnd, &waL, &waT, &waR, &waB)
    monScale := Win_GetMonitorScale(waL, waT, waR, waB)

    xPhys := Round(xDip * monScale)
    yPhys := Round(yDip * monScale)
    wPhys := Round(wDip * monScale)
    hPhys := Round(hDip * monScale)

    Win_SetPosPhys(gGUI_BaseH, xPhys, yPhys, wPhys, hPhys)
    ; Single window — no anti-jiggle split resize needed.
    ; D2D renders directly to the window surface; no overlay/base sync.
    ; DWM corner preference is set once in GUI_CreateWindow; no per-resize update needed.

    ; Resize D2D render target to match new window size
    if (gD2D_RT && wPhys > 0 && hPhys > 0)
        D2D_ResizeRenderTarget(wPhys, hPhys)

    if (!skipFlush)
        Win_DwmFlush()
    Profiler.Leave() ; @profile
}

GUI_GetWindowRect(&x, &y, &w, &h, rowsToShow) {
    global cfg
    waL := 0
    waT := 0
    waR := 0
    waB := 0
    targetHwnd := GUI_GetTargetMonitorHwnd()
    Win_GetWorkAreaFromHwnd(targetHwnd, &waL, &waT, &waR, &waB)

    monScale := Win_GetMonitorScale(waL, waT, waR, waB)

    waW_dip := (waR - waL) / monScale
    waH_dip := (waB - waT) / monScale
    left_dip := waL / monScale
    top_dip := waT / monScale

    pct := cfg.GUI_ScreenWidthPct
    if (pct <= 0)
        pct := 0.10
    if (pct > 1.0)
        pct := pct / 100.0

    w := Round(waW_dip * pct)
    h := cfg.GUI_MarginY + GUI_HeaderBlockDip() + rowsToShow * cfg.GUI_RowHeight + _GUI_FooterBlockDip() + cfg.GUI_MarginY

    x := Round(left_dip + (waW_dip - w) / 2)
    y := Round(top_dip + (waH_dip - h) / 2)
}

; ========================= WINDOW CREATION =========================

; Create the single overlay window with SWCA acrylic + D2D render target.
; Replaces the old GUI_CreateBase() + GUI_CreateOverlay() two-window system.
GUI_CreateWindow() {
    global gGUI_Base, gGUI_BaseH, gGUI_Overlay, gGUI_OverlayH
    global gGUI_LiveItems, cfg
    global gD2D_Factory, gDW_Factory, gD2D_RT

    ; Create single window
    ; -DPIScale: all coordinates are raw physical pixels (D2D render target uses 96 DPI).
    ; Without this, AHK's DPI scaling creates mismatches between SetWindowPos (physical)
    ; and WinGetClientPos/SetWindowRgn (DPI-scaled), clipping D2D content at high DPI.
    opts := "+AlwaysOnTop -Caption +ToolWindow -DPIScale"

    rowsDesired := GUI_ComputeRowsToShow(gGUI_LiveItems.Length)

    global APP_NAME
    gGUI_Base := Gui(opts, APP_NAME)
    gGUI_Base.BackColor := "000000"  ; Black background — DWM material shows through hollow brush
    gGUI_Base.Show("Hide w1 h1")  ; Dummy size — repositioned below
    gGUI_BaseH := gGUI_Base.Hwnd

    ; Set overlay aliases for backward compatibility (single-window architecture)
    gGUI_Overlay := gGUI_Base
    gGUI_OverlayH := gGUI_BaseH

    ; Compute initial layout
    xDip := 0
    yDip := 0
    wDip := 0
    hDip := 0
    GUI_GetWindowRect(&xDip, &yDip, &wDip, &hDip, rowsDesired)

    waL := 0
    waT := 0
    waR := 0
    waB := 0
    targetHwnd := GUI_GetTargetMonitorHwnd()
    Win_GetWorkAreaFromHwnd(targetHwnd, &waL, &waT, &waR, &waB)
    monScale := Win_GetMonitorScale(waL, waT, waR, waB)

    xPhys := Round(xDip * monScale)
    yPhys := Round(yDip * monScale)
    wPhys := Round(wDip * monScale)
    hPhys := Round(hDip * monScale)
    Win_SetPosPhys(gGUI_BaseH, xPhys, yPhys, wPhys, hPhys)

    ; DWM and composition setup
    Win_EnableDarkTitleBar(gGUI_BaseH)
    _GUI_ApplyCornerStyle(gGUI_BaseH)

    ; NOT WS_EX_LAYERED: D2D alpha compositing works through DwmExtendFrame +
    ; premultiplied alpha mode.  WS_EX_LAYERED causes DWM to cache the SWCA
    ; acrylic blur composition, showing stale blur from the previous desktop
    ; state on each Show().  Non-layered windows get fresh blur every frame.
    ; (Old GDI+ base window used Win_ForceNoLayered for the same reason.)

    ; Extend DWM frame into client area (required for D2D transparent rendering)
    Win_DwmExtendFrame(gGUI_BaseH)

    ; Set hollow brush so DWM material shows through (prevents white flash)
    Win_SetHollowBrush(gGUI_BaseH)

    ; Suppress WM_ERASEBKGND to prevent DWM flashing default background
    OnMessage(0x0014, _GUI_OnEraseBkgnd)

    ; Apply backdrop style from config
    _GUI_ApplyConfigBackdrop()

    ; Initialize D2D factories (process-global)
    _D2D_InitFactories()

    ; Create D2D render target for this window
    _D2D_CreateRenderTarget(gGUI_BaseH, wPhys, hPhys)

    Win_DwmFlush()
}

; Suppress WM_ERASEBKGND — return 1 to tell Windows we handled it.
; Prevents DWM from painting the default white background before D2D content.
_GUI_OnEraseBkgnd(wParam, lParam, msg, hwnd) { ; lint-ignore: dead-param
    try {
        global gGUI_BaseH
        if (hwnd = gGUI_BaseH)
            return 1
    }
    return ""  ; Let other windows handle normally
}

; ========================= D2D INITIALIZATION =========================

_D2D_InitFactories() {
    global gD2D_Factory, gDW_Factory
    if (!gD2D_Factory)
        gD2D_Factory := ID2D1Factory()
    if (!gDW_Factory)
        gDW_Factory := IDWriteFactory()
}

_D2D_CreateRenderTarget(hwnd, wPhys, hPhys) {
    global gD2D_Factory, gD2D_RT
    global D2D1_ALPHA_MODE_PREMULTIPLIED, D2D1_PRESENT_OPTIONS_NONE
    global D2D1_ANTIALIAS_MODE_PER_PRIMITIVE, D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE

    if (wPhys < 1)
        wPhys := 1
    if (hPhys < 1)
        hPhys := 1

    ; Render target properties: 96 DPI = 1 D2D unit = 1 physical pixel
    ; (keeps existing coordinate math unchanged from GDI+ pipeline)
    rtProps := D2D_RenderTargetProps(96.0, 96.0, D2D1_ALPHA_MODE_PREMULTIPLIED)
    hwndProps := D2D_HwndRenderTargetProps(hwnd, wPhys, hPhys, D2D1_PRESENT_OPTIONS_NONE)

    gD2D_RT := gD2D_Factory.CreateHwndRenderTarget(rtProps, hwndProps)

    ; Set antialiasing modes
    if (gD2D_RT) {
        gD2D_RT.SetAntialiasMode(D2D1_ANTIALIAS_MODE_PER_PRIMITIVE)
        gD2D_RT.SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE)
    }
}

D2D_ResizeRenderTarget(wPhys, hPhys) {
    global gD2D_RT
    if (!gD2D_RT)
        return
    if (wPhys < 1)
        wPhys := 1
    if (hPhys < 1)
        hPhys := 1
    sizeU := D2D_SizeU(wPhys, hPhys)
    try {
        gD2D_RT.Resize(sizeU)
    }
}

; Recreate render target and all dependent resources after D2DERR_RECREATE_TARGET.
D2D_HandleDeviceLoss() {
    global gD2D_RT, gGUI_BaseH

    ; Get current window size
    ox := 0
    oy := 0
    wPhys := 0
    hPhys := 0
    Win_GetRectPhys(gGUI_BaseH, &ox, &oy, &wPhys, &hPhys)

    ; Release all dependent resources (brushes, text formats, icon cache)
    D2D_DisposeResources()

    ; Release old render target
    if (gD2D_RT)
        gD2D_RT := 0  ; COM wrapper __Delete releases the render target

    ; Recreate render target
    _D2D_CreateRenderTarget(gGUI_BaseH, wPhys, hPhys)
}

; ========================= D2D CLEANUP =========================

D2D_ShutdownAll() {
    global gD2D_RT, gD2D_Factory, gDW_Factory

    ; Dispose resources first (brushes, text formats, icon cache)
    D2D_DisposeResources()

    ; Release render target
    if (gD2D_RT)
        gD2D_RT := 0

    ; Release factories
    if (gDW_Factory)
        gDW_Factory := 0
    if (gD2D_Factory)
        gD2D_Factory := 0
}
