#Requires AutoHotkey v2.0
; Alt-Tabby GUI - Overlay Management
; Handles window creation, sizing, show/hide, and layout calculations
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals/functions

; ========================= SHOW/HIDE =========================

global gGUI_HideCount := 0  ; Track hides for periodic log trim

GUI_HideOverlay() {
    global gGUI_OverlayVisible, gGUI_Base, gGUI_Overlay, gGUI_Revealed
    global gGUI_HoverRow, gGUI_HoverBtn, gGUI_MouseTracking
    global gGUI_HideCount, cfg, LOG_PATH_EVENTS

    if (!gGUI_OverlayVisible) {
        return
    }

    ; Stop hover polling
    GUI_StopHoverPolling()

    ; Clear the overlay's layered content before hiding.
    ; DWM caches the last UpdateLayeredWindow content for hidden layered windows.
    ; Without this, re-showing the overlay can briefly flash stale content from
    ; the previous session before the new paint's UpdateLayeredWindow takes effect.
    _GUI_ClearLayeredContent()

    try {
        gGUI_Overlay.Hide()
    }
    try {
        gGUI_Base.Hide()
    }
    gGUI_OverlayVisible := false
    gGUI_Revealed := false

    ; Clear hover state and mouse tracking when hiding
    gGUI_HoverRow := 0
    gGUI_HoverBtn := ""
    gGUI_MouseTracking := false

    ; Periodically trim diagnostic logs (every 10 hide cycles)
    gGUI_HideCount += 1
    if (Mod(gGUI_HideCount, 10) = 0) {
        Paint_LogTrim()
        if (cfg.DiagEventLog)
            LogTrim(LOG_PATH_EVENTS)
    }
}

; Push a fully transparent buffer to the overlay's layered window.
; This clears DWM's cached content so it has nothing stale to flash on next show.
_GUI_ClearLayeredContent() {
    global gGUI_OverlayH, gGdip_BackHdc, gGdip_BackW, gGdip_BackH

    if (!gGdip_BackHdc || !gGUI_OverlayH || gGdip_BackW < 1 || gGdip_BackH < 1)
        return

    g := Gdip_EnsureGraphics()
    if (!g)
        return
    Gdip_Clear(g, 0x00000000)

    ; Push cleared buffer to overlay via UpdateLayeredWindow (pptDst=0 keeps position)
    bf := Gdip_GetBlendFunction()
    static sz := Buffer(8, 0)
    static ptSrc := Buffer(8, 0)
    NumPut("Int", gGdip_BackW, sz, 0)
    NumPut("Int", gGdip_BackH, sz, 4)

    hdcScreen := DllCall("user32\GetDC", "ptr", 0, "ptr")
    DllCall("user32\UpdateLayeredWindow", "ptr", gGUI_OverlayH, "ptr", hdcScreen, "ptr", 0, "ptr", sz.Ptr, "ptr", gGdip_BackHdc, "ptr", ptSrc.Ptr, "int", 0, "ptr", bf.Ptr, "uint", 0x2, "int")
    DllCall("user32\ReleaseDC", "ptr", 0, "ptr", hdcScreen)
}

; ========================= LAYOUT CALCULATIONS =========================

GUI_ComputeRowsToShow(count) {
    global cfg
    if (count >= cfg.GUI_RowsVisibleMax) {
        return cfg.GUI_RowsVisibleMax
    }
    if (count > cfg.GUI_RowsVisibleMin) {
        return count
    }
    return cfg.GUI_RowsVisibleMin
}

GUI_HeaderBlockDip() {
    global cfg, PAINT_HEADER_BLOCK_DIP
    if (cfg.GUI_ShowHeader) {
        return PAINT_HEADER_BLOCK_DIP
    }
    return 0
}

GUI_FooterBlockDip() {
    global cfg
    if (cfg.GUI_ShowFooter) {
        return cfg.GUI_FooterGapTopPx + cfg.GUI_FooterHeightPx
    }
    return 0
}

GUI_GetVisibleRows() {
    global gGUI_OverlayH, cfg

    ox := 0
    oy := 0
    owPhys := 0
    ohPhys := 0
    Win_GetRectPhys(gGUI_OverlayH, &ox, &oy, &owPhys, &ohPhys)

    scale := Win_GetScaleForWindow(gGUI_OverlayH)
    ohDip := ohPhys / scale

    headerTopDip := cfg.GUI_MarginY + GUI_HeaderBlockDip()
    footerDip := GUI_FooterBlockDip()
    usableDip := ohDip - headerTopDip - cfg.GUI_MarginY - footerDip

    if (usableDip < cfg.GUI_RowHeight) {
        return 0
    }
    return Floor(usableDip / cfg.GUI_RowHeight)
}

; ========================= RESIZE =========================

GUI_ResizeToRows(rowsToShow, skipFlush := false) {
    global gGUI_Base, gGUI_BaseH, gGUI_Overlay, gGUI_OverlayH, cfg

    xDip := 0
    yDip := 0
    wDip := 0
    hDip := 0
    GUI_GetWindowRect(&xDip, &yDip, &wDip, &hDip, rowsToShow, gGUI_BaseH)

    waL := 0
    waT := 0
    waR := 0
    waB := 0
    Win_GetWorkAreaFromHwnd(gGUI_BaseH, &waL, &waT, &waR, &waB)
    monScale := Win_GetMonitorScale(waL, waT, waR, waB)

    xPhys := Round(xDip * monScale)
    yPhys := Round(yDip * monScale)
    wPhys := Round(wDip * monScale)
    hPhys := Round(hDip * monScale)

    Win_SetPosPhys(gGUI_BaseH, xPhys, yPhys, wPhys, hPhys)
    ; ANTI-JIGGLE (Part 2 of 2 — see also store_server.ahk BroadcastWorkspaceFlips):
    ; The overlay is a layered window whose content is managed exclusively by
    ; UpdateLayeredWindow (ULW) in GUI_Repaint.  ULW accepts pptDst (position)
    ; and psize (size) parameters, atomically setting position + size + bitmap
    ; content in a single DWM composition.  DO NOT resize the overlay here via
    ; SetWindowPos — that triggers a DWM frame with the new window size but the
    ; OLD bitmap content (stale items from previous workspace), then ULW triggers
    ; a SECOND frame with the correct bitmap = visible flash/jiggle on slot #1.
    Win_ApplyRoundRegion(gGUI_BaseH, cfg.GUI_CornerRadiusPx, wDip, hDip)
    if (!skipFlush)
        Win_DwmFlush()
}

GUI_GetWindowRect(&x, &y, &w, &h, rowsToShow, hWnd) {
    global cfg
    waL := 0
    waT := 0
    waR := 0
    waB := 0
    Win_GetWorkAreaFromHwnd(hWnd, &waL, &waT, &waR, &waB)

    monScale := Win_GetMonitorScale(waL, waT, waR, waB)

    waW_dip := (waR - waL) / monScale
    waH_dip := (waB - waT) / monScale
    left_dip := waL / monScale
    top_dip := waT / monScale

    pct := cfg.GUI_ScreenWidthPct
    if (pct <= 0) {
        pct := 0.10
    }
    if (pct > 1.0) {
        pct := pct / 100.0
    }

    w := Round(waW_dip * pct)
    h := cfg.GUI_MarginY + GUI_HeaderBlockDip() + rowsToShow * cfg.GUI_RowHeight + GUI_FooterBlockDip() + cfg.GUI_MarginY

    x := Round(left_dip + (waW_dip - w) / 2)
    y := Round(top_dip + (waH_dip - h) / 2)
}

; ========================= WINDOW CREATION =========================

GUI_CreateBase() {
    global gGUI_Base, gGUI_BaseH, gGUI_LiveItems, cfg

    opts := "+AlwaysOnTop -Caption"

    rowsDesired := GUI_ComputeRowsToShow(gGUI_LiveItems.Length)

    global APP_NAME
    gGUI_Base := Gui(opts, APP_NAME)
    gGUI_Base.Show("Hide w1 h1")  ; Dummy size — repositioned below
    gGUI_BaseH := gGUI_Base.Hwnd

    ; Use GUI_GetWindowRect for layout (single source of truth for sizing/centering)
    xDip := 0
    yDip := 0
    wDip := 0
    hDip := 0
    GUI_GetWindowRect(&xDip, &yDip, &wDip, &hDip, rowsDesired, gGUI_BaseH)

    waL := 0
    waT := 0
    waR := 0
    waB := 0
    Win_GetWorkAreaFromHwnd(gGUI_BaseH, &waL, &waT, &waR, &waB)
    monScale := Win_GetMonitorScale(waL, waT, waR, waB)

    xPhys := Round(xDip * monScale)
    yPhys := Round(yDip * monScale)
    wPhys := Round(wDip * monScale)
    hPhys := Round(hDip * monScale)
    Win_SetPosPhys(gGUI_BaseH, xPhys, yPhys, wPhys, hPhys)

    Win_EnableDarkTitleBar(gGUI_BaseH)
    Win_SetCornerPreference(gGUI_BaseH, 2)
    Win_ForceNoLayered(gGUI_BaseH)
    Win_ApplyRoundRegion(gGUI_BaseH, cfg.GUI_CornerRadiusPx, wDip, hDip)
    Win_ApplyAcrylic(gGUI_BaseH, cfg.GUI_AcrylicColor)
    Win_DwmFlush()
}

GUI_CreateOverlay() {
    global gGUI_Base, gGUI_BaseH, gGUI_Overlay, gGUI_OverlayH

    gGUI_Overlay := Gui("+AlwaysOnTop -Caption +ToolWindow +Owner" gGUI_BaseH)
    gGUI_Overlay.Show("Hide")
    gGUI_OverlayH := gGUI_Overlay.Hwnd

    ox := 0
    oy := 0
    ow := 0
    oh := 0
    Win_GetRectPhys(gGUI_BaseH, &ox, &oy, &ow, &oh)
    Win_SetPosPhys(gGUI_OverlayH, ox, oy, ow, oh)
}
