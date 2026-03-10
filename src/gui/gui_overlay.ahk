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
global gGUI_StealFocus := false      ; Effective steal-focus (cfg OR Mica)
global gGUI_FocusBeforeShow := 0     ; Hwnd of foreground window before overlay took focus

; D2D factories and device pipeline (process-global, survive render target recreation)
global gD2D_Factory := 0       ; ID2D1Factory1
global gDW_Factory := 0        ; IDWriteFactory
global gD2D_RT := 0            ; ID2D1DeviceContext (created from ID2D1Device)
global gD2D_D3DDevice := 0     ; ID3D11Device (raw ptr, released via ObjRelease)
global gD2D_D2DDevice := 0     ; ID2D1Device

; DXGI SwapChain + DirectComposition pipeline (replaces HwndRenderTarget)
global gD2D_SwapChain := 0     ; IDXGISwapChain1 (composition swap chain)
global gD2D_BackBuffer := 0    ; ID2D1Bitmap1 (current frame, per-frame acquire/release)
global gDComp_Device := 0      ; IDCompositionDevice
global gDComp_Target := 0      ; IDCompositionTarget
global gDComp_Visual := 0      ; IDCompositionVisual (content: swap chain)
global gDComp_ClipVisual := 0  ; IDCompositionVisual (parent: clip rect)

; Waitable swap chain state (latency optimization — Present(0,0) pattern)
global gD2D_SwapChain2 := 0     ; IDXGISwapChain2 (0 = fallback/non-waitable mode)
global gD2D_WaitableHandle := 0  ; HANDLE from GetFrameLatencyWaitableObject
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
        case "Mica":
            Win_SetSystemBackdrop(gGUI_BaseH, 2)   ; DWMSBT_MAINWINDOW
        case "MicaAlt":
            Win_SetSystemBackdrop(gGUI_BaseH, 4)   ; DWMSBT_TABBEDWINDOW
        case "Solid":
            ; No SWCA needed — D2D Clear uses cfg.GUI_AcrylicColor directly.
            ; SWCA gradient (accent 2) conflicts with DwmExtendFrame.
    }
}

; Force DWM to re-sample the acrylic/glass backdrop after a workspace switch.
; Komorebi cloaks/uncloaks windows asynchronously — when the workspace event
; fires, cloaking is still in flight. A delayed geometry nudge (SetWindowPos
; +1px/-1px) forces DWM to re-evaluate the backdrop area after the desktop
; has settled. The DComp clip rect masks the transient 1px, so no visual
; artifact. (#235)
GUI_RefreshBackdrop() {
    global cfg
    SetTimer(_GUI_BackdropNudge, -cfg.AltTabBackdropRefreshDelayMs)
}

_GUI_BackdropNudge() {
    global gGUI_BaseH, gGUI_Revealed, gGUI_OverlayVisible
    global SWP_NOZORDER, SWP_NOOWNERZORDER, SWP_NOACTIVATE
    if (!gGUI_BaseH || !gGUI_Revealed || !gGUI_OverlayVisible)
        return

    rect := Buffer(16, 0)
    if (!DllCall("user32\GetWindowRect", "ptr", gGUI_BaseH, "ptr", rect.Ptr))
        return
    x := NumGet(rect, 0, "int")
    y := NumGet(rect, 4, "int")
    w := NumGet(rect, 8, "int") - x
    h := NumGet(rect, 12, "int") - y

    flags := SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_NOACTIVATE
    DllCall("user32\SetWindowPos", "ptr", gGUI_BaseH, "ptr", 0,
        "int", x, "int", y, "int", w, "int", h + 1, "uint", flags, "int")
    DllCall("user32\SetWindowPos", "ptr", gGUI_BaseH, "ptr", 0,
        "int", x, "int", y, "int", w, "int", h, "uint", flags, "int")
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
    global gGUI_OverlayVisible, gGUI_Base, gGUI_BaseH, gGUI_Revealed
    global cfg, GUI_LOG_TRIM_EVERY_N_HIDES, gD2D_RT
    global gAnim_HidePending, gPaint_RepaintInProgress
    static hideCount := 0

    if (!gGUI_OverlayVisible) {
        Profiler.Leave() ; @profile
        return
    }

    ; Hide-fade already running — don't re-enter.  A second ALT_UP can arrive
    ; here when the STA message pump inside _GUI_RobustActivate (SetWindowPos /
    ; SetForegroundWindow) dispatches a keyboard hook for the physical Alt
    ; release while the synthetic click-triggered ALT_UP is still processing.
    ; Without this guard the second call falls through to the immediate-hide
    ; path, killing the running fade animation.
    if (gAnim_HidePending) {
        Profiler.Leave() ; @profile
        return
    }

    ; Animated hide-fade: start opacity tween, defer actual hide
    ; _Anim_OnHideFadeComplete() will call _Anim_DoActualHide() when done
    if (cfg.PerfAnimationType != "None" && gGUI_Revealed) {
        gAnim_HidePending := true
        ; Add WS_EX_LAYERED so SetLayeredWindowAttributes can fade the entire
        ; DWM composition (content + acrylic + shadow) as one unit.
        Anim_AddLayered()
        DllCall("SetLayeredWindowAttributes", "ptr", gGUI_BaseH, "uint", 0, "uchar", 255, "uint", 2)
        Anim_StartTween("hideFade", 1.0, 0.0, 60, Anim_EaseOutQuad)
        Profiler.Leave() ; @profile
        return
    }

    ; Immediate hide path (AnimationType=None, or already pending, or not revealed)
    ; Stop hover polling and clear hover state
    GUI_ClearHoverState()

    ; Clear D2D surface BEFORE hiding — ensures a clean swap chain buffer
    ; for the next Show().  SwapChain.Present() works for hidden windows
    ; (unlike HwndRenderTarget), so the clear actually commits.
    ; STA reentrancy guard: BeginDraw/EndDraw/Present pump the message loop,
    ; which can dispatch callbacks that reach GUI_Repaint. Save/restore
    ; handles nesting when called from within an existing paint.
    if (gD2D_RT) {
        wasInProgress := gPaint_RepaintInProgress
        gPaint_RepaintInProgress := true
        try {
            if (D2D_AcquireBackBuffer()) {
                gD2D_RT.BeginDraw()
                gD2D_RT.Clear(D2D_ColorF(0x00000000))
                gD2D_RT.EndDraw()
                D2D_ReleaseBackBuffer()
                D2D_Present(0)  ; Immediate — about to hide
            }
        } catch {
            D2D_ReleaseBackBuffer()
        } finally {
            gPaint_RepaintInProgress := wasInProgress
        }
    }

    try {
        gGUI_Base.Hide()
    }
    gGUI_OverlayVisible := false
    gGUI_Revealed := false

    ; Cancel any animation state
    Anim_CancelAll()

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

    ; Phase 2: Update DComp clip to new visible region (swap chain is already oversized)
    if (wPhys > 0 && hPhys > 0) {
        D2D_SetClipRect(wPhys, hPhys)
        D2D_Commit()
    }

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
    global gD2D_Factory, gDW_Factory, gD2D_RT, gD2D_D3DDevice, gD2D_D2DDevice
    global gD2D_SwapChain, gDComp_Device, gDComp_Target, gDComp_Visual, gDComp_ClipVisual

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

    ; Mica/MicaAlt: DWM requires a non-ToolWindow with WS_CAPTION for backdrop material.
    ; We add WS_CAPTION (for DWM) but hide the title bar via WM_NCCALCSIZE (zero non-client area).
    ; We replace WS_EX_TOOLWINDOW with a hidden owner window (owned windows skip taskbar).
    if (cfg.GUI_BackdropStyle = "Mica" || cfg.GUI_BackdropStyle = "MicaAlt") {
        ; Hidden owner window suppresses taskbar entry (replaces WS_EX_TOOLWINDOW)
        static micaOwner := 0
        micaOwner := Gui("+ToolWindow", "")
        micaOwner.Show("Hide w0 h0")
        gGUI_Base.Opt("+Owner" micaOwner.Hwnd)

        ; Remove WS_EX_TOOLWINDOW (0x80) from extended style
        exStyle := DllCall("user32\GetWindowLong" (A_PtrSize = 8 ? "Ptr" : ""), "ptr", gGUI_BaseH, "int", -20, "ptr")
        DllCall("user32\SetWindowLong" (A_PtrSize = 8 ? "Ptr" : ""), "ptr", gGUI_BaseH, "int", -20, "ptr", exStyle & ~0x80)
        ; Add WS_CAPTION (0xC00000), remove WS_SYSMENU|MINIMIZEBOX|MAXIMIZEBOX (0xB0000)
        ; WS_CAPTION triggers DWM Mica; removing button styles prevents caption buttons.
        ; WM_NCCALCSIZE handler zeroes the non-client area so caption is invisible.
        style := DllCall("user32\GetWindowLong" (A_PtrSize = 8 ? "Ptr" : ""), "ptr", gGUI_BaseH, "int", -16, "ptr")
        DllCall("user32\SetWindowLong" (A_PtrSize = 8 ? "Ptr" : ""), "ptr", gGUI_BaseH, "int", -16, "ptr", (style | 0xC00000) & ~0xB0000)
        ; Zero non-client area — hides title bar while keeping WS_CAPTION for DWM
        OnMessage(0x0083, _GUI_OnNcCalcSize)
    }

    ; Apply backdrop style from config
    _GUI_ApplyConfigBackdrop()

    ; Compute effective steal-focus: explicit config OR Mica/MicaAlt (need focus for wallpaper tint)
    global gGUI_StealFocus
    gGUI_StealFocus := cfg.GUI_StealFocus || (cfg.GUI_BackdropStyle = "Mica") || (cfg.GUI_BackdropStyle = "MicaAlt")

    ; Initialize D2D factories (process-global)
    _D2D_InitFactories()

    ; Create D2D render target + device context for this window
    _D2D_CreateRenderTarget(gGUI_BaseH, wPhys, hPhys)

    ; Initialize GPU effects pipeline (CLSIDs + effect graph)
    FX_InitCLSIDs()
    FX_GPU_Init()

    Win_DwmFlush()
}

; WM_NCCALCSIZE: zero out non-client area to hide WS_CAPTION title bar.
; DWM still applies Mica to the caption style, but we consume the space as client area.
_GUI_OnNcCalcSize(wParam, lParam, msg, hwnd) { ; lint-ignore: dead-param callback-critical — stateless WM handler, no shared state to protect
    try {
        global gGUI_BaseH
        if (hwnd = gGUI_BaseH && wParam)
            return 0
    }
    return ""
}

; Suppress WM_ERASEBKGND — return 1 to tell Windows we handled it.
; Prevents DWM from painting the default white background before D2D content.
_GUI_OnEraseBkgnd(wParam, lParam, msg, hwnd) { ; lint-ignore: dead-param callback-critical — stateless WM handler, no shared state to protect
    try {
        global gGUI_BaseH
        if (hwnd = gGUI_BaseH)
            return 1
    }
    return ""  ; Let other windows handle normally
}

; ========================= D2D INITIALIZATION =========================

_D2D_InitFactories() {
    global gD2D_Factory, gDW_Factory, gD2D_D3DDevice, gD2D_D2DDevice
    global D3D11_CREATE_DEVICE_BGRA_SUPPORT

    if (!gD2D_Factory)
        gD2D_Factory := ID2D1Factory1()
    if (!gDW_Factory)
        gDW_Factory := IDWriteFactory()

    ; Create D3D11 device (needed for ID2D1Device — future GPU effects pipeline)
    if (!gD2D_D3DDevice) {
        #DllLoad 'd3d11.dll'
        DllCall('d3d11\D3D11CreateDevice',
            'ptr', 0,                           ; pAdapter (NULL = default)
            'uint', 1,                          ; DriverType = D3D_DRIVER_TYPE_HARDWARE
            'ptr', 0,                           ; Software
            'uint', D3D11_CREATE_DEVICE_BGRA_SUPPORT, ; Flags
            'ptr', 0,                           ; pFeatureLevels (NULL = default)
            'uint', 0,                          ; FeatureLevels count
            'uint', 7,                          ; SDK version (D3D11_SDK_VERSION)
            'ptr*', &pD3DDevice := 0,           ; ppDevice
            'uint*', &featureLevel := 0,        ; pFeatureLevel
            'ptr*', &pContext := 0,             ; ppImmediateContext
            'hresult')
        gD2D_D3DDevice := pD3DDevice
        ; Release the immediate context — we don't use it (D2D has its own)
        if (pContext)
            ObjRelease(pContext)
    }

    ; Create ID2D1Device from DXGI device
    if (!gD2D_D2DDevice && gD2D_D3DDevice) {
        ; QI D3D11 device for IDXGIDevice
        dxgiDevice := ComObjQuery(gD2D_D3DDevice, IDXGIDevice.IID)
        pDxgi := ComObjValue(dxgiDevice)
        ObjAddRef(pDxgi)
        dxgiDev := IDXGIDevice(pDxgi)
        gD2D_D2DDevice := gD2D_Factory.CreateDevice(dxgiDev)
    }
}

_D2D_CreateRenderTarget(hwnd, wPhys, hPhys) {
    global gD2D_Factory, gD2D_RT, gD2D_D3DDevice, gD2D_D2DDevice
    global gD2D_SwapChain, gD2D_BackBuffer
    global gD2D_SwapChain2, gD2D_WaitableHandle
    global gDComp_Device, gDComp_Target, gDComp_Visual, gDComp_ClipVisual
    global D2D1_ANTIALIAS_MODE_PER_PRIMITIVE, D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE
    global DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SWAP_EFFECT_FLIP_DISCARD
    global DXGI_ALPHA_MODE_PREMULTIPLIED
    global DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT
    global LOG_PATH_STORE

    if (wPhys < 1)
        wPhys := 1
    if (hPhys < 1)
        hPhys := 1

    ; --- Step 1: Create SwapChain via DXGI factory chain ---
    ; QI D3D11Device → IDXGIDevice → GetAdapter → GetParent → IDXGIFactory2
    dxgiObj := ComObjQuery(gD2D_D3DDevice, IDXGIDevice.IID)
    pDxgi := ComObjValue(dxgiObj)
    ObjAddRef(pDxgi)
    dxgiDev := IDXGIDevice(pDxgi)

    adapter := dxgiDev.GetAdapter()
    factory := adapter.GetParent()

    ; Phase 2: Create swap chain at max monitor resolution (fixed-size, no ResizeBuffers)
    scW := 0
    scH := 0
    _D2D_GetMaxMonitorSize(&scW, &scH)

    ; Try waitable swap chain first (lower input-to-photon latency)
    waitableOk := false
    try {
        desc := D2D_SwapChainDesc1(scW, scH,
            DXGI_FORMAT_B8G8R8A8_UNORM, 2,
            DXGI_SWAP_EFFECT_FLIP_DISCARD,
            DXGI_ALPHA_MODE_PREMULTIPLIED,
            DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT)

        gD2D_SwapChain := factory.CreateSwapChainForComposition(dxgiDev, desc)

        ; QI for IDXGISwapChain2
        sc2Obj := ComObjQuery(gD2D_SwapChain.ptr, IDXGISwapChain2.IID)
        pSC2 := ComObjValue(sc2Obj)
        ObjAddRef(pSC2)
        gD2D_SwapChain2 := IDXGISwapChain2(pSC2)

        gD2D_SwapChain2.SetMaximumFrameLatency(1)
        gD2D_WaitableHandle := gD2D_SwapChain2.GetFrameLatencyWaitableObject()

        if (!gD2D_WaitableHandle)
            throw Error("GetFrameLatencyWaitableObject returned NULL")

        waitableOk := true
    } catch as e {
        try LogAppend(LOG_PATH_STORE, "WaitableSwapChain FALLBACK: " e.Message)
        _D2D_CleanupWaitableState()
        ; Release partial swap chain if created
        gD2D_SwapChain := 0
    }

    ; Fallback: standard swap chain without waitable flag — still oversized
    if (!waitableOk) {
        desc := D2D_SwapChainDesc1(scW, scH,
            DXGI_FORMAT_B8G8R8A8_UNORM, 2,
            DXGI_SWAP_EFFECT_FLIP_DISCARD,
            DXGI_ALPHA_MODE_PREMULTIPLIED)
        gD2D_SwapChain := factory.CreateSwapChainForComposition(dxgiDev, desc)
    }

    ; --- Step 2: Create ID2D1DeviceContext directly from ID2D1Device ---
    ; (No HwndRenderTarget intermediary — cleaner device-context-only pipeline)
    gD2D_RT := gD2D_D2DDevice.CreateDeviceContext(0)
    gD2D_RT.SetAntialiasMode(D2D1_ANTIALIAS_MODE_PER_PRIMITIVE)
    gD2D_RT.SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE)

    ; --- Step 3: Create DirectComposition visual tree ---
    ; Phase 2: Two-visual tree — clip on parent, content on child.
    ; DComp clips in pre-transform space; separating clip from content allows
    ; independent transform changes later (Chromium-validated pattern).
    #DllLoad 'dcomp.dll'
    if DllCall('ole32\CLSIDFromString', 'str', IDCompositionDevice.IID, 'ptr', iid := Buffer(16, 0))
        throw OSError()
    DllCall('dcomp\DCompositionCreateDevice',
        'ptr', dxgiDev.ptr,
        'ptr', iid,
        'ptr*', &pDComp := 0, 'hresult')
    gDComp_Device := IDCompositionDevice(pDComp)

    gDComp_Target := gDComp_Device.CreateTargetForHwnd(hwnd, true)

    ; Parent visual: clip rect controls visible region of the oversized swap chain
    gDComp_ClipVisual := gDComp_Device.CreateVisual()

    ; Child visual: swap chain content
    gDComp_Visual := gDComp_Device.CreateVisual()
    gDComp_Visual.SetContent(gD2D_SwapChain)

    ; Build tree: Target → ClipVisual → Visual
    gDComp_ClipVisual.AddVisual(gDComp_Visual, true, 0)
    gDComp_Target.SetRoot(gDComp_ClipVisual)

    ; Set initial clip to the visible region (not full swap chain size)
    clipRect := D2D_RectF(0, 0, wPhys, hPhys)
    gDComp_ClipVisual.SetClip(clipRect)

    gDComp_Device.Commit()
}

_D2D_CleanupWaitableState() {
    global gD2D_WaitableHandle, gD2D_SwapChain2
    if (gD2D_WaitableHandle) {
        DllCall("CloseHandle", "ptr", gD2D_WaitableHandle)
        gD2D_WaitableHandle := 0
    }
    gD2D_SwapChain2 := 0
}

; Recreate the D2D pipeline after device loss (DXGI_ERROR_DEVICE_REMOVED etc.).
D2D_HandleDeviceLoss() {
    global gD2D_RT, gD2D_SwapChain, gD2D_BackBuffer, gGUI_BaseH
    global gDComp_Device, gDComp_Target, gDComp_Visual, gDComp_ClipVisual

    ; Get current window size (used as initial clip rect for recreation)
    ox := 0
    oy := 0
    wPhys := 0
    hPhys := 0
    Win_GetRectPhys(gGUI_BaseH, &ox, &oy, &wPhys, &hPhys)

    ; Release GPU effects (depend on render target / device context)
    FX_GPU_Dispose()

    ; Release all dependent resources (brushes, text formats, icon cache)
    D2D_DisposeResources()

    ; Release back buffer + render target
    gD2D_BackBuffer := 0
    gD2D_RT := 0

    ; Release DComp tree (visual → clip visual → target → device)
    gDComp_Visual := 0
    gDComp_ClipVisual := 0
    gDComp_Target := 0
    gDComp_Device := 0

    ; Release waitable state before swap chain
    _D2D_CleanupWaitableState()

    ; Release swap chain
    gD2D_SwapChain := 0

    ; Recreate pipeline (factories survive device loss)
    _D2D_CreateRenderTarget(gGUI_BaseH, wPhys, hPhys)

    ; Recreate GPU effects
    FX_GPU_Init()
}

; ========================= D2D CLEANUP =========================

D2D_ShutdownAll() {
    global gD2D_RT, gD2D_SwapChain, gD2D_BackBuffer
    global gDComp_Device, gDComp_Target, gDComp_Visual, gDComp_ClipVisual
    global gD2D_D2DDevice, gD2D_D3DDevice
    global gD2D_Factory, gDW_Factory

    ; Dispose GPU effects first
    FX_GPU_Dispose()

    ; Dispose resources (brushes, text formats, icon cache)
    D2D_DisposeResources()

    ; Release back buffer + render target
    gD2D_BackBuffer := 0
    gD2D_RT := 0

    ; Release DComp tree (visual → clip visual → target → device)
    gDComp_Visual := 0
    gDComp_ClipVisual := 0
    gDComp_Target := 0
    gDComp_Device := 0

    ; Release waitable state before swap chain
    _D2D_CleanupWaitableState()

    ; Release swap chain
    gD2D_SwapChain := 0

    ; Release D2D device pipeline
    gD2D_D2DDevice := 0
    if (gD2D_D3DDevice) {
        ObjRelease(gD2D_D3DDevice)
        gD2D_D3DDevice := 0
    }

    ; Release factories
    if (gDW_Factory)
        gDW_Factory := 0
    if (gD2D_Factory)
        gD2D_Factory := 0
}

; ========================= HDR DETECTION =========================

; Detect whether any active display has HDR enabled.
; Uses DisplayConfigGetDeviceInfo with DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO.
; Returns true if at least one monitor has HDR active.
D2D_IsHDRActive() {
    try {
        ; GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS=2)
        pathCount := 0
        modeCount := 0
        hr := DllCall("user32\GetDisplayConfigBufferSizes",
            "uint", 2, "uint*", &pathCount, "uint*", &modeCount, "uint")
        if (hr != 0 || pathCount = 0)
            return false

        ; QueryDisplayConfig — fill path + mode buffers
        ; DISPLAYCONFIG_PATH_INFO = 72 bytes, DISPLAYCONFIG_MODE_INFO = 64 bytes
        pathBuf := Buffer(pathCount * 72, 0)
        modeBuf := Buffer(modeCount * 64, 0)
        hr := DllCall("user32\QueryDisplayConfig",
            "uint", 2, "uint*", &pathCount, "ptr", pathBuf,
            "uint*", &modeCount, "ptr", modeBuf, "ptr", 0, "uint")
        if (hr != 0)
            return false

        ; Iterate paths, check advanced color info for each target
        loop pathCount {
            pathOffset := (A_Index - 1) * 72

            ; DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO struct (32 bytes)
            ; type=9 (DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO), size=32
            info := Buffer(32, 0)
            NumPut("uint", 9, info, 0)   ; type
            NumPut("uint", 32, info, 4)  ; size

            ; Copy adapterId (LUID, 8 bytes) from targetInfo at path offset 20
            NumPut("int64", NumGet(pathBuf, pathOffset + 20, "int64"), info, 8)
            ; Copy target id (4 bytes) from targetInfo at path offset 28
            NumPut("uint", NumGet(pathBuf, pathOffset + 28, "uint"), info, 16)

            hr := DllCall("user32\DisplayConfigGetDeviceInfo", "ptr", info, "uint")
            if (hr != 0)
                continue

            ; Bitfield at offset 20: bit 0 = advancedColorSupported, bit 1 = advancedColorEnabled
            bits := NumGet(info, 20, "uint")
            if ((bits & 0x1) && (bits & 0x2))
                return true
        }
    } catch {
        ; Detection failed — assume SDR (safe default)
    }
    return false
}

; ========================= D2D BACK BUFFER =========================

; Acquire the current back buffer and bind it as the D2D render target.
; Must be called BEFORE BeginDraw() each frame.
; With FLIP_DISCARD, back buffer content is undefined after Present(),
; so each frame gets a fresh buffer (~6μs per acquire).
D2D_AcquireBackBuffer() {
    Profiler.Enter("D2D_AcquireBackBuffer") ; @profile
    global gD2D_SwapChain, gD2D_RT, gD2D_BackBuffer

    if (!gD2D_SwapChain || !gD2D_RT) {
        Profiler.Leave() ; @profile
        return false
    }

    ; Static buffer: hot path (~120fps), avoid per-frame allocation
    static bp1 := 0
    if (!bp1) {
        bp1 := Buffer(32, 0)
        NumPut("uint", 87, bp1, 0)     ; DXGI_FORMAT_B8G8R8A8_UNORM
        NumPut("uint", 1, bp1, 4)      ; D2D1_ALPHA_MODE_PREMULTIPLIED
        NumPut("float", 96.0, bp1, 8)  ; dpiX
        NumPut("float", 96.0, bp1, 12) ; dpiY
        NumPut("uint", 0x3, bp1, 16)   ; TARGET | CANNOT_DRAW
    }

    surface := gD2D_SwapChain.GetBuffer(0)
    gD2D_BackBuffer := gD2D_RT.CreateBitmapFromDxgiSurface(surface, bp1)
    gD2D_RT.SetTarget(gD2D_BackBuffer)
    Profiler.Leave() ; @profile
    return true
}

; Release the back buffer after EndDraw(). Must be called BEFORE Present().
; Unbinding the target allows the swap chain to flip the buffer.
D2D_ReleaseBackBuffer() {
    Profiler.Enter("D2D_ReleaseBackBuffer") ; @profile
    global gD2D_RT, gD2D_BackBuffer
    if (gD2D_BackBuffer) {
        gD2D_RT.SetTarget(0)
        gD2D_BackBuffer := 0  ; COM Release via __Delete
    }
    Profiler.Leave() ; @profile
}

; ========================= D2D PRESENT =========================

; Present the swap chain buffer to the compositor.
; syncInterval=0 for immediate (waitable swap chain handles pacing).
; Fallback path: frame loop spin-waits for frame boundary instead of VSync.
D2D_Present(syncInterval := 0) {
    Profiler.Enter("D2D_Present") ; @profile
    global gD2D_SwapChain
    if (!gD2D_SwapChain) {
        Profiler.Leave() ; @profile
        return
    }
    gD2D_SwapChain.Present(syncInterval, 0)
    Profiler.Leave() ; @profile
}

; ========================= DCOMP CLIP (Phase 2) =========================

; Update the DComp clip visual to show only the specified region.
; Does NOT commit — caller batches with other DComp changes then calls D2D_Commit().
D2D_SetClipRect(wPhys, hPhys) {
    global gDComp_ClipVisual
    if (!gDComp_ClipVisual)
        return
    clipRect := D2D_RectF(0, 0, wPhys, hPhys)
    gDComp_ClipVisual.SetClip(clipRect)
}

; Commit all pending DComp changes atomically.
D2D_Commit() {
    global gDComp_Device
    if (!gDComp_Device)
        return
    gDComp_Device.Commit()
}

; Query all monitors and return the largest physical pixel dimensions.
; Used to size the swap chain once at init — avoids ResizeBuffers during normal operation.
_D2D_GetMaxMonitorSize(&maxW, &maxH) {
    maxW := 0
    maxH := 0
    count := MonitorGetCount()
    loop count {
        mL := 0
        mT := 0
        mR := 0
        mB := 0
        MonitorGet(A_Index, &mL, &mT, &mR, &mB)
        w := mR - mL
        h := mB - mT
        if (w > maxW)
            maxW := w
        if (h > maxH)
            maxH := h
    }
    ; Fallback: if no monitors detected (unlikely), use primary screen
    if (maxW < 1)
        maxW := A_ScreenWidth
    if (maxH < 1)
        maxH := A_ScreenHeight
}
