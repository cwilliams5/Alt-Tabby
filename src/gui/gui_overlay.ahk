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
global gD2D_RT := 0            ; ID2D1DeviceContext (QI'd from HwndRenderTarget)
global gD2D_HwndRT := 0        ; ID2D1HwndRenderTarget (raw ptr — for Resize + presentation)
global gD2D_D3DDevice := 0     ; ID3D11Device (raw ptr, released via ObjRelease)
global gD2D_D2DDevice := 0     ; ID2D1Device

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
    global gAnim_HidePending
    static hideCount := 0

    if (!gGUI_OverlayVisible) {
        Profiler.Leave() ; @profile
        return
    }

    ; Animated hide-fade: start opacity tween, defer actual hide
    ; _Anim_OnHideFadeComplete() will call _Anim_DoActualHide() when done
    if (cfg.PerfAnimationType != "None" && gGUI_Revealed && !gAnim_HidePending) {
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

    ; Clear D2D surface BEFORE hiding — HwndRenderTarget::Present() is silently
    ; discarded for hidden windows (MSDN), so the last visible-frame content
    ; persists on the surface.  Without this clear, the stale frame flashes
    ; briefly on the next Show() before the new paint arrives.
    if (gD2D_RT) {
        try {
            gD2D_RT.BeginDraw()
            gD2D_RT.Clear(D2D_ColorF(0x00000000))
            gD2D_RT.EndDraw()
            D2D_Present()
        } catch {
            ; Best-effort clear before hide — failure handled by next paint cycle
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
    global gD2D_Factory, gDW_Factory, gD2D_RT, gD2D_HwndRT, gD2D_D3DDevice, gD2D_D2DDevice

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
    FX_BuildStyleNames()

    Win_DwmFlush()
}

; WM_NCCALCSIZE: zero out non-client area to hide WS_CAPTION title bar.
; DWM still applies Mica to the caption style, but we consume the space as client area.
_GUI_OnNcCalcSize(wParam, lParam, msg, hwnd) { ; lint-ignore: dead-param
    try {
        global gGUI_BaseH
        if (hwnd = gGUI_BaseH && wParam)
            return 0
    }
    return ""
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
    global gD2D_Factory, gD2D_RT, gD2D_HwndRT
    global D2D1_ALPHA_MODE_PREMULTIPLIED, D2D1_PRESENT_OPTIONS_NONE
    global D2D1_ANTIALIAS_MODE_PER_PRIMITIVE, D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE

    if (wPhys < 1)
        wPhys := 1
    if (hPhys < 1)
        hPhys := 1

    ; Create HwndRenderTarget — supports per-pixel alpha with DwmExtendFrame.
    ; 96 DPI = 1 D2D unit = 1 physical pixel (keeps existing coordinate math).
    rtProps := D2D_RenderTargetProps(96.0, 96.0, D2D1_ALPHA_MODE_PREMULTIPLIED)
    hwndRtProps := D2D_HwndRenderTargetProps(hwnd, wPhys, hPhys, D2D1_PRESENT_OPTIONS_NONE)

    ; ID2D1Factory::CreateHwndRenderTarget (vtable index 14)
    ComCall(14, gD2D_Factory, 'ptr', rtProps, 'ptr', hwndRtProps, 'ptr*', &pRT := 0, 'hresult')
    gD2D_HwndRT := pRT  ; Raw ptr — needed for Resize(), released via ObjRelease

    ; QI for ID2D1DeviceContext — available on Win8+ when created from ID2D1Factory1.
    ; Gives us GPU effects API while HwndRenderTarget handles alpha-correct presentation.
    dcObj := ComObjQuery(pRT, ID2D1DeviceContext.IID)
    pDC := ComObjValue(dcObj)
    ObjAddRef(pDC)
    gD2D_RT := ID2D1DeviceContext(pDC)

    gD2D_RT.SetAntialiasMode(D2D1_ANTIALIAS_MODE_PER_PRIMITIVE)
    gD2D_RT.SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE)
}

D2D_ResizeRenderTarget(wPhys, hPhys) {
    global gD2D_HwndRT
    if (!gD2D_HwndRT)
        return
    if (wPhys < 1)
        wPhys := 1
    if (hPhys < 1)
        hPhys := 1
    sizeU := D2D_SizeU(wPhys, hPhys)
    try {
        ; ID2D1HwndRenderTarget::Resize (vtable index 58: RT 0-56, CheckWindowState 57, Resize 58)
        ComCall(58, gD2D_HwndRT, 'ptr', sizeU, 'hresult')
    } catch {
        ; Resize failure — next paint will trigger device loss recovery
    }
}

; Recreate the D2D render target after D2DERR_RECREATE_TARGET.
D2D_HandleDeviceLoss() {
    global gD2D_RT, gD2D_HwndRT, gGUI_BaseH

    ; Get current window size
    ox := 0
    oy := 0
    wPhys := 0
    hPhys := 0
    Win_GetRectPhys(gGUI_BaseH, &ox, &oy, &wPhys, &hPhys)

    ; Release GPU effects (depend on render target / device context)
    FX_GPU_Dispose()

    ; Release all dependent resources (brushes, text formats, icon cache)
    D2D_DisposeResources()

    ; Release render target (DeviceContext + HwndRT)
    gD2D_RT := 0  ; COM __Delete releases DeviceContext
    if (gD2D_HwndRT) {
        ObjRelease(gD2D_HwndRT)
        gD2D_HwndRT := 0
    }

    ; Recreate render target (factories survive device loss)
    _D2D_CreateRenderTarget(gGUI_BaseH, wPhys, hPhys)

    ; Recreate GPU effects
    FX_GPU_Init()
    FX_BuildStyleNames()
}

; ========================= D2D CLEANUP =========================

D2D_ShutdownAll() {
    global gD2D_RT, gD2D_HwndRT
    global gD2D_D2DDevice, gD2D_D3DDevice
    global gD2D_Factory, gDW_Factory

    ; Dispose GPU effects first
    FX_GPU_Dispose()

    ; Dispose resources (brushes, text formats, icon cache)
    D2D_DisposeResources()

    ; Release render target
    gD2D_RT := 0  ; COM __Delete releases DeviceContext
    if (gD2D_HwndRT) {
        ObjRelease(gD2D_HwndRT)
        gD2D_HwndRT := 0
    }

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

; ========================= D2D PRESENT =========================
; No-op: HwndRenderTarget auto-presents after EndDraw().
; Kept for forward-compatibility with future swap chain pipeline.

D2D_Present() {
}
