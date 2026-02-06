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
        _Paint_LogTrim()
        if (cfg.DiagEventLog)
            LogTrim(LOG_PATH_EVENTS)
    }
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

GUI_ResizeToRows(rowsToShow) {
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
    Win_SetPosPhys(gGUI_OverlayH, xPhys, yPhys, wPhys, hPhys)
    Win_ApplyRoundRegion(gGUI_BaseH, cfg.GUI_CornerRadiusPx, wDip, hDip)
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
    Win_ApplyAcrylic(gGUI_BaseH, cfg.GUI_AcrylicAlpha, cfg.GUI_AcrylicBaseRgb)
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
