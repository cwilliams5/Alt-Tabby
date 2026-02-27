#Requires AutoHotkey v2.0
; Alt-Tabby GUI - Painting (D2D)
; All rendering via Direct2D HwndRenderTarget.
; Single-window architecture: D2D renders directly to the window surface.
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals/functions

; ========================= PAINT TIMING DEBUG LOG =========================
; Dedicated log for investigating slow paint after extended idle
; Log file: %TEMP%\tabby_paint_timing.log
; Auto-trimmed to keep last ~50KB when exceeding 100KB

global gPaint_LastPaintTick := 0      ; When we last painted (for idle duration calc)
global gPaint_SessionPaintCount := 0  ; How many paints this session
global gPaint_RepaintInProgress := false  ; Reentrancy guard (see #90)

; ========================= EFFECT STYLE SYSTEM =========================
; Toggled at runtime via B key (gui_interceptor.ahk).
; 0 = Clean (baseline), 1 = visual effects on.
global gGUI_EffectStyle := 0
global FX_STYLE_NAMES := [
    "Clean",
    "Effects"
]

; Layout state (written during paint, read by gui_main/gui_input)
global gGUI_LastRowsDesired := -1
global gGUI_LeftArrowRect := { x: 0, y: 0, w: 0, h: 0 }
global gGUI_RightArrowRect := { x: 0, y: 0, w: 0, h: 0 }
global LOG_PATH_PAINT_TIMING  ; Defined in config_loader.ahk
Paint_Log(msg) {
    global cfg, LOG_PATH_PAINT_TIMING
    if (!cfg.DiagPaintTimingLog)
        return
    LogAppend(LOG_PATH_PAINT_TIMING, msg)
}

; Trim log file if it exceeds max size, keeping the tail
Paint_LogTrim() {
    global cfg, LOG_PATH_PAINT_TIMING
    if (!cfg.DiagPaintTimingLog)
        return
    LogTrim(LOG_PATH_PAINT_TIMING)
}

Paint_LogStartSession() {
    global cfg, LOG_PATH_PAINT_TIMING, gPaint_SessionPaintCount
    gPaint_SessionPaintCount := 0
    if (!cfg.DiagPaintTimingLog)
        return
    try {
        ; Delete old log on fresh boot for clean slate
        if (FileExist(LOG_PATH_PAINT_TIMING))
            FileDelete(LOG_PATH_PAINT_TIMING)
        FileAppend("========== NEW SESSION " FormatTime(, "yyyy-MM-dd HH:mm:ss") " ==========`n", LOG_PATH_PAINT_TIMING, "UTF-8")
    }
}

; ========================= MAIN REPAINT =========================

GUI_Repaint() {
    ; Reentrancy guard: Win32 calls (SetWindowPos, DwmFlush) pump the
    ; message queue, which dispatches queued WinEvent callbacks mid-paint. Those
    ; callbacks update the store and trigger GUI_PatchCosmeticUpdates → GUI_Repaint,
    ; creating nested repaints that paint intermediate state immediately overwritten.
    ; Guard skips nested calls; the outer paint finishes with correct final state. (#90)
    global gPaint_RepaintInProgress
    if (gPaint_RepaintInProgress)
        return
    gPaint_RepaintInProgress := true

    Profiler.Enter("GUI_Repaint") ; @profile
    Critical "On"  ; Protect D2D render target from concurrent hotkey interruption
    global gGUI_BaseH, gGUI_OverlayH, gGUI_LiveItems, gGUI_DisplayItems, gGUI_Sel, gGUI_ScrollTop, gGUI_LastRowsDesired, gGUI_Revealed
    global gGUI_State, cfg
    global gPaint_LastPaintTick, gPaint_SessionPaintCount
    global gGdip_IconCache, gD2D_Res, gD2D_ResScale, gD2D_RT

    ; ===== TIMING: Start =====
    diagTiming := cfg.DiagPaintTimingLog
    if (diagTiming)
        tTotal := QPC()
    idleDuration := (gPaint_LastPaintTick > 0) ? (A_TickCount - gPaint_LastPaintTick) : -1
    gPaint_SessionPaintCount += 1
    paintNum := gPaint_SessionPaintCount

    ; Log context for first paint or paint after long idle (>60s)
    if (diagTiming && (paintNum = 1 || idleDuration > 60000)) {
        iconCacheSize := gGdip_IconCache.Count  ; O(1) via Map.Count property
        resCount := gD2D_Res.Count
        Paint_Log("===== PAINT #" paintNum " (idle=" (idleDuration > 0 ? Round(idleDuration/1000, 1) "s" : "first") ") =====")
        Paint_Log("  Context: items=" gGUI_LiveItems.Length " frozen=" gGUI_DisplayItems.Length " iconCache=" iconCacheSize " resCount=" resCount " resScale=" gD2D_ResScale " [D2D]")
    }

    ; Use display items when in ACTIVE state, live items otherwise
    items := (gGUI_State = "ACTIVE") ? gGUI_DisplayItems : gGUI_LiveItems

    ; ENFORCE: When in ACTIVE state with ScrollKeepHighlightOnTop, ensure selection is at top
    if (gGUI_State = "ACTIVE" && cfg.GUI_ScrollKeepHighlightOnTop && items.Length > 0) {
        gGUI_ScrollTop := gGUI_Sel - 1
    }

    count := items.Length
    rowsDesired := GUI_ComputeRowsToShow(count)
    oldRows := gGUI_LastRowsDesired
    rowsChanged := (rowsDesired != oldRows)
    if (rowsChanged)
        gGUI_LastRowsDesired := rowsDesired

    ; ===== TIMING: ComputeRect =====
    if (diagTiming)
        t1 := QPC()
    xDip := 0
    yDip := 0
    wDip := 0
    hDip := 0
    GUI_GetWindowRect(&xDip, &yDip, &wDip, &hDip, rowsDesired)
    waL := 0
    waT := 0
    waR := 0
    waB := 0
    Win_GetWorkAreaFromHwnd(gGUI_BaseH, &waL, &waT, &waR, &waB)
    scale := Win_GetMonitorScale(waL, waT, waR, waB)
    phX := Round(xDip * scale)
    phY := Round(yDip * scale)
    phW := Round(wDip * scale)
    phH := Round(hDip * scale)
    if (diagTiming)
        tComputeRect := QPC() - t1

    ; ===== TIMING: Resize =====
    ; Single window — resize window + D2D render target together.
    ; No split-resize needed (no overlay/base sync).
    if (diagTiming)
        t1 := QPC()
    needsResize := (rowsChanged && gGUI_Revealed)
    if (needsResize) {
        Win_SetPosPhys(gGUI_BaseH, phX, phY, phW, phH)
        if (gD2D_RT && phW > 0 && phH > 0)
            D2D_ResizeRenderTarget(phW, phH)
    }
    if (diagTiming)
        tResize := QPC() - t1

    ; ===== TIMING: D2D BeginDraw + PaintOverlay + EndDraw =====
    if (diagTiming)
        t1 := QPC()

    if (gD2D_RT) {
        gD2D_RT.BeginDraw()

        ; Clear the render target. Acrylic/AeroGlass: transparent so compositor
        ; backdrop shows through. Solid: paint the tint color directly via D2D
        ; (SWCA gradient conflicts with DwmExtendFrame).
        clearColor := (cfg.GUI_BackdropStyle = "Solid") ? cfg.GUI_AcrylicColor : 0x00000000
        gD2D_RT.Clear(D2D_ColorF(clearColor))

        if (diagTiming)
            tBeginDraw := QPC() - t1

        ; ===== TIMING: PaintOverlay (the big one) =====
        if (diagTiming)
            t1 := QPC()
        _GUI_PaintOverlay(items, gGUI_Sel, phW, phH, scale, diagTiming)
        if (diagTiming)
            tPaintOverlay := QPC() - t1

        ; ===== TIMING: EndDraw =====
        if (diagTiming)
            t1 := QPC()
        try {
            gD2D_RT.EndDraw()
            D2D_Present()
        } catch as e {
            ; D2DERR_RECREATE_TARGET = 0x8899000C or DXGI device loss
            ; Handle device loss: recreate full pipeline from D3D11 up
            D2D_HandleDeviceLoss()
            if (diagTiming)
                Paint_Log("  ** D2D DEVICE LOSS — full pipeline recreated")
        }
        if (diagTiming)
            tEndDraw := QPC() - t1
    } else {
        if (diagTiming) {
            tBeginDraw := 0
            tPaintOverlay := 0
            tEndDraw := 0
        }
    }

    ; ===== TIMING: Reveal =====
    if (diagTiming)
        t1 := QPC()
    _GUI_RevealBoth()
    if (diagTiming)
        tReveal := QPC() - t1

    ; ===== TIMING: Total =====
    gPaint_LastPaintTick := A_TickCount
    if (diagTiming) {
        tTotalMs := QPC() - tTotal
        if (paintNum = 1 || idleDuration > 60000 || tTotalMs > 100)
            Paint_Log("  Timing: total=" Round(tTotalMs, 2) "ms | computeRect=" Round(tComputeRect, 2) " resize=" Round(tResize, 2) " beginDraw=" Round(tBeginDraw, 2) " paintOverlay=" Round(tPaintOverlay, 2) " endDraw=" Round(tEndDraw, 2) " reveal=" Round(tReveal, 2))
    }
    Profiler.Leave() ; @profile
    gPaint_RepaintInProgress := false
}

_GUI_RevealBoth() {
    global gGUI_Base, gGUI_BaseH, gGUI_Revealed, cfg
    global gGUI_State, gGUI_OverlayVisible  ; Need access to state for race fix

    Profiler.Enter("_GUI_RevealBoth") ; @profile

    if (gGUI_Revealed) {
        Profiler.Leave() ; @profile
        return
    }

    ; Gate: only reveal if the show sequence explicitly requested it.
    ; Without this, cosmetic patches during the grace period trigger paint →
    ; _GUI_RevealBoth, showing the overlay while gGUI_OverlayVisible is still
    ; false. The quick-switch path then skips GUI_HideOverlay() (thinks overlay
    ; was never shown), leaving a non-interactive ghost overlay on screen.
    if (!gGUI_OverlayVisible) {
        Profiler.Leave() ; @profile
        return
    }

    ; RACE FIX: Abort early if state already changed
    if (gGUI_State != "ACTIVE") {
        try gGUI_Base.Hide()
        Profiler.Leave() ; @profile
        return
    }

    try {
        gGUI_Base.Show("NA")
    }

    ; RACE FIX: Check if Alt was released during Show (which pumps messages)
    if (gGUI_State != "ACTIVE") {
        try gGUI_Base.Hide()
        Profiler.Leave() ; @profile
        return
    }

    ; Single window — no separate overlay Show needed.

    Win_DwmFlush()
    gGUI_Revealed := true
    Profiler.Leave() ; @profile
}

; ========================= OVERLAY PAINTING =========================

_GUI_PaintOverlay(items, selIndex, wPhys, hPhys, scale, diagTiming := false) {
    Profiler.Enter("_GUI_PaintOverlay") ; @profile
    global gGUI_ScrollTop, gGUI_HoverRow, gGUI_FooterText, cfg, gD2D_Res, gGdip_IconCache
    global gPaint_SessionPaintCount, gPaint_LastPaintTick
    global PAINT_TEXT_RIGHT_PAD_DIP, gGUI_WorkspaceMode, WS_MODE_CURRENT
    global gGUI_MonitorMode, MON_MODE_CURRENT
    global gGUI_EffectStyle

    ; ===== TIMING: EnsureResources =====
    if (diagTiming) {
        tPO_Start := QPC()
        t1 := QPC()
    }
    GUI_EnsureResources(scale)
    if (diagTiming)
        tPO_Resources := QPC() - t1

    ; ===== TIMING: Clear =====
    if (diagTiming)
        t1 := QPC()
    ; Clear already done in GUI_Repaint (BeginDraw + Clear)
    if (diagTiming)
        tPO_GraphicsClear := QPC() - t1

    scrollTop := gGUI_ScrollTop

    cachedLayout := GUI_GetCachedLayout(scale)
    RowH := cachedLayout.RowH
    Mx := cachedLayout.Mx
    My := cachedLayout.My
    ISize := cachedLayout.ISize
    Rad := cachedLayout.Rad
    gapText := cachedLayout.gapText
    gapCols := cachedLayout.gapCols
    hdrY4 := cachedLayout.hdrY4
    hdrH28 := cachedLayout.hdrH28
    iconLeftDip := cachedLayout.iconLeftDip

    y := My
    leftX := Mx + iconLeftDip
    textX := leftX + ISize + gapText

    ; Right columns (data-driven: widthProp, nameProp, dataKey)
    ; static: allocated once per process, not per-paint (hot-path rule)
    ; dataKey matches store wire format property names directly
    static colDefs := [
        ["GUI_ColFixed6", "GUI_Col6Name", "Col6"],
        ["GUI_ColFixed5", "GUI_Col5Name", "monitorLabel"],
        ["GUI_ColFixed4", "GUI_Col4Name", "workspaceName"],
        ["GUI_ColFixed3", "GUI_Col3Name", "pid"],
        ["GUI_ColFixed2", "GUI_Col2Name", "hwndHex"]
    ]

    ; Cache column metrics - only rebuild when scale, width, margin, or gap changes
    ; (avoids rebuilding cols array + Round() calls per column per frame)
    static cachedCols := [], cachedColsKey := "", cachedColsRightX := 0
    colsKey := scale "_" wPhys "_" Mx "_" gapCols
    if (colsKey != cachedColsKey) {
        cachedCols := []
        cachedColsRightX := wPhys - Mx
        for _, def in colDefs {
            colW := Round(cfg.%def[1]% * scale)
            if (colW > 0) {
                cx := cachedColsRightX - colW
                cachedCols.Push({name: cfg.%def[2]%, w: colW, key: def[3], x: cx})
                cachedColsRightX := cx - gapCols
            }
        }
        cachedColsKey := colsKey
    }
    cols := cachedCols
    rightX := cachedColsRightX

    textW := (rightX - Round(PAINT_TEXT_RIGHT_PAD_DIP * scale)) - textX
    if (textW < 0) {
        textW := 0
    }

    ; Effect style shorthand
    fx := gGUI_EffectStyle

    ; Shadow params (computed once, used for all text draws)
    shadowP := _FX_GetShadowParams(fx, scale)
    shadowBr := shadowP.enabled ? D2D_GetCachedBrush(shadowP.argb) : 0

    ; Header
    if (cfg.GUI_ShowHeader) {
        hdrY := y + hdrY4
        hdrTextH := Round(20 * scale)
        if (shadowP.enabled) {
            _FX_DrawTextLeftShadow("Title", textX, hdrY, textW, hdrTextH, gD2D_Res["brHdr"], gD2D_Res["tfHdr"], shadowBr, shadowP.offX, shadowP.offY)
            for _, col in cols {
                _FX_DrawTextLeftShadow(col.name, col.x, hdrY, col.w, hdrTextH, gD2D_Res["brHdr"], gD2D_Res["tfHdr"], shadowBr, shadowP.offX, shadowP.offY)
            }
        } else {
            D2D_DrawTextLeft("Title", textX, hdrY, textW, hdrTextH, gD2D_Res["brHdr"], gD2D_Res["tfHdr"])
            for _, col in cols {
                D2D_DrawTextLeft(col.name, col.x, hdrY, col.w, hdrTextH, gD2D_Res["brHdr"], gD2D_Res["tfHdr"])
            }
        }
        y := y + hdrH28
    }

    contentTopY := y
    count := items.Length

    footerH := 0
    footerGap := 0
    if (cfg.GUI_ShowFooter) {
        footerH := Round(cfg.GUI_FooterHeightPx * scale)
        footerGap := Round(cfg.GUI_FooterGapTopPx * scale)
    }
    availH := hPhys - My - contentTopY - footerH - footerGap
    if (availH < 0) {
        availH := 0
    }

    rowsCap := 0
    if (availH > 0) {
        rowsCap := Floor(availH / RowH)
    }
    rowsToDraw := count
    if (rowsToDraw > rowsCap) {
        rowsToDraw := rowsCap
    }

    ; Empty list
    if (count = 0) {
        rectX := Mx
        rectW := wPhys - 2 * Mx
        rectH := RowH
        rectY := contentTopY + Floor((availH - rectH) / 2)
        if (rectY < contentTopY) {
            rectY := contentTopY
        }
        emptyText := cfg.GUI_EmptyListText
        if (gGUI_MonitorMode = MON_MODE_CURRENT && gGUI_WorkspaceMode = WS_MODE_CURRENT)
            emptyText := "No windows on this workspace and monitor"
        else if (gGUI_WorkspaceMode = WS_MODE_CURRENT)
            emptyText := "No windows on this workspace"
        else if (gGUI_MonitorMode = MON_MODE_CURRENT)
            emptyText := "No windows on this monitor"
        if (shadowP.enabled) {
            _FX_DrawTextCenteredShadow(emptyText, rectX, rectY, rectW, rectH, gD2D_Res["brMain"], gD2D_Res["tfMain"], shadowBr, shadowP.offX, shadowP.offY)
        } else {
            D2D_DrawTextCentered(emptyText, rectX, rectY, rectW, rectH, gD2D_Res["brMain"], gD2D_Res["tfMain"])
        }
    } else if (rowsToDraw > 0) {
        ; ===== TIMING: Row loop start =====
        if (diagTiming) {
            tPO_RowsStart := QPC()
            tPO_IconsTotal := 0
        }
        iconCacheHits := 0
        iconCacheMisses := 0

        start0 := Win_Wrap0(scrollTop, count)
        i := 0
        yRow := y

        ; Use cached layout metrics (computed once per scale change above)
        titleY := cachedLayout.titleY
        titleH := cachedLayout.titleH
        subY := cachedLayout.subY
        subH := cachedLayout.subH
        colY := cachedLayout.colY
        colH := cachedLayout.colH
        hoverRow := gGUI_HoverRow

        ; Hoist loop-invariant gD2D_Res lookups (12 keys × N rows → 12 lookups total)
        tfMain := gD2D_Res["tfMain"], tfMainHi := gD2D_Res["tfMainHi"]
        tfSub := gD2D_Res["tfSub"], tfSubHi := gD2D_Res["tfSubHi"]
        tfCol := gD2D_Res["tfCol"], tfColHi := gD2D_Res["tfColHi"]
        brMain := gD2D_Res["brMain"], brMainHi := gD2D_Res["brMainHi"]
        brSub := gD2D_Res["brSub"], brSubHi := gD2D_Res["brSubHi"]
        brCol := gD2D_Res["brCol"], brColHi := gD2D_Res["brColHi"]

        ; Selection rect expansion (in physical px)
        selExpandX := Round(4 * scale)
        selExpandY := Round(2 * scale)

        while (i < rowsToDraw && (yRow + RowH <= contentTopY + availH)) {
            idx0 := Win_Wrap0(start0 + i, count)
            idx1 := idx0 + 1
            cur := items[idx1]
            isSel := (idx1 = selIndex)

            ; Hover highlight (effects on, non-selected rows)
            if (fx && !isSel && idx1 = hoverRow) {
                _FX_DrawHover(Mx - selExpandX, yRow - selExpandY, wPhys - 2 * Mx + selExpandX * 2, RowH, Rad)
            }

            ; Selection highlight
            if (isSel) {
                selX := Mx - selExpandX
                selY := yRow - selExpandY
                selW := wPhys - 2 * Mx + selExpandX * 2
                selH := RowH
                if (fx) {
                    _FX_DrawSelection(selX, selY, selW, selH, Rad)
                } else {
                    D2D_FillRoundRect(selX, selY, selW, selH, Rad, D2D_GetCachedBrush(cfg.GUI_SelARGB))
                }
            }

            ix := leftX
            iy := yRow + (RowH - ISize) // 2

            ; ===== TIMING: Icon draw =====
            if (diagTiming)
                tIcon := QPC()
            iconDrawn := false
            iconWasCacheHit := false
            ; Schema guarantee: _GUI_CreateItemFromRecord always sets iconHicon (0 if absent)
            if (cur.iconHicon) {
                ; wasCacheHit is returned via ByRef parameter (avoids double cache lookup)
                iconDrawn := D2D_DrawCachedIcon(cur.hwnd, cur.iconHicon, ix, iy, ISize, &iconWasCacheHit)
                if (iconWasCacheHit)
                    iconCacheHits += 1
                else
                    iconCacheMisses += 1
            }
            if (!iconDrawn) {
                D2D_FillEllipse(ix, iy, ISize, ISize, D2D_GetCachedBrush(0x60808080))
            }
            if (diagTiming)
                tPO_IconsTotal += QPC() - tIcon

            tfMainUse := isSel ? tfMainHi : tfMain
            tfSubUse := isSel ? tfSubHi : tfSub
            tfColUse := isSel ? tfColHi : tfCol
            brMainUse := isSel ? brMainHi : brMain
            brSubUse := isSel ? brSubHi : brSub
            brColUse := isSel ? brColHi : brCol

            ; Text drawing (with optional shadow)
            title := cur.title
            sub := ""
            if (cur.processName != "") {
                sub := cur.processName
            } else {
                sub := "Class: " cur.class
            }

            if (shadowP.enabled) {
                _FX_DrawTextLeftShadow(title, textX, yRow + titleY, textW, titleH, brMainUse, tfMainUse, shadowBr, shadowP.offX, shadowP.offY)
                _FX_DrawTextLeftShadow(sub, textX, yRow + subY, textW, subH, brSubUse, tfSubUse, shadowBr, shadowP.offX, shadowP.offY)
                for _, col in cols {
                    val := ""
                    if (cur.HasOwnProp(col.key))
                        val := cur.%col.key%
                    _FX_DrawTextLeftShadow(val, col.x, yRow + colY, col.w, colH, brColUse, tfColUse, shadowBr, shadowP.offX, shadowP.offY)
                }
            } else {
                D2D_DrawTextLeft(title, textX, yRow + titleY, textW, titleH, brMainUse, tfMainUse)
                D2D_DrawTextLeft(sub, textX, yRow + subY, textW, subH, brSubUse, tfSubUse)
                for _, col in cols {
                    val := ""
                    if (cur.HasOwnProp(col.key))
                        val := cur.%col.key%
                    D2D_DrawTextLeft(val, col.x, yRow + colY, col.w, colH, brColUse, tfColUse)
                }
            }

            if (idx1 = hoverRow) {
                _GUI_DrawActionButtons(wPhys, yRow, RowH, scale)
            }

            yRow := yRow + RowH
            i := i + 1
        }
        ; ===== TIMING: Row loop end =====
        if (diagTiming)
            tPO_RowsTotal := QPC() - tPO_RowsStart
    }

    ; Scrollbar
    if (diagTiming)
        t1 := QPC()
    if (count > rowsToDraw && rowsToDraw > 0) {
        _GUI_DrawScrollbar(wPhys, contentTopY, rowsToDraw, RowH, scrollTop, count, scale)
    }
    if (diagTiming)
        tPO_Scrollbar := QPC() - t1

    ; Footer
    if (diagTiming)
        t1 := QPC()
    if (cfg.GUI_ShowFooter) {
        _GUI_DrawFooter(wPhys, hPhys, scale)
    }
    if (diagTiming)
        tPO_Footer := QPC() - t1

    ; Inner shadow — config-driven depth and opacity
    if (fx && cfg.GUI_InnerShadowAlpha > 0) {
        shadowDepth := Round(cfg.GUI_InnerShadowDepthPx * scale)
        _FX_DrawInnerShadow(wPhys, hPhys, shadowDepth, cfg.GUI_InnerShadowAlpha)
    }

    ; ===== TIMING: Log PaintOverlay details for first paint or paint after long idle =====
    if (diagTiming) {
        tPO_Total := QPC() - tPO_Start
        idleDuration := (gPaint_LastPaintTick > 0) ? (A_TickCount - gPaint_LastPaintTick) : -1
        if (gPaint_SessionPaintCount <= 1 || idleDuration > 60000 || tPO_Total > 50) {
            Paint_Log("  PaintOverlay: total=" Round(tPO_Total, 2) "ms | resources=" Round(tPO_Resources, 2) " clear=" Round(tPO_GraphicsClear, 2) " rows=" (IsSet(tPO_RowsTotal) ? Round(tPO_RowsTotal, 2) : 0) " scrollbar=" Round(tPO_Scrollbar, 2) " footer=" Round(tPO_Footer, 2))
            if (IsSet(tPO_IconsTotal)) {
                Paint_Log("    Icons: totalTime=" Round(tPO_IconsTotal, 2) "ms | hits=" iconCacheHits " misses=" iconCacheMisses " rowsDrawn=" rowsToDraw)
            }
        }
    }
    Profiler.Leave() ; @profile
}

; ========================= ACTION BUTTONS =========================

; Get scaled action button metrics with minimums enforced
; Returns: {size, gap, rad}
GUI_GetActionBtnMetrics(scale) {
    global cfg
    size := Round(cfg.GUI_ActionBtnSizePx * scale)
    if (size < 12)
        size := 12
    gap := Round(cfg.GUI_ActionBtnGapPx * scale)
    if (gap < 2)
        gap := 2
    rad := Round(cfg.GUI_ActionBtnRadiusPx * scale)
    if (rad < 2)
        rad := 2
    return {size: size, gap: gap, rad: rad}
}

; Draw a single action button and update btnX position
; Parameters:
;   &btnX     - ByRef x position (decremented after drawing)
;   btnY      - y position
;   size      - button size in pixels
;   rad       - corner radius in pixels
;   scale     - DPI scale factor
;   btnName   - button identifier ("close", "kill", "blacklist")
;   showProp  - config property name for show toggle (e.g., "GUI_ShowCloseButton")
;   bgProp    - config property prefix for colors (e.g., "GUI_CloseButton")
;   glyph     - text/glyph to draw
;   borderPx  - border thickness (from config)
;   gap       - gap between buttons in pixels
_GUI_DrawOneActionButton(&btnX, btnY, size, rad, scale, btnName, showProp, bgProp, glyph, borderPx, gap) {
    global gGUI_HoverBtn, cfg, gD2D_Res

    if (!cfg.%showProp%)
        return

    hovered := (gGUI_HoverBtn = btnName)
    bgCol := hovered ? cfg.%bgProp "BGHoverARGB"% : cfg.%bgProp "BGARGB"%
    txCol := hovered ? cfg.%bgProp "TextHoverARGB"% : cfg.%bgProp "TextARGB"%

    D2D_FillRoundRect(btnX, btnY, size, size, rad, D2D_GetCachedBrush(bgCol))
    if (borderPx > 0) {
        D2D_StrokeRoundRect(btnX + 0.5, btnY + 0.5, size - 1, size - 1, rad, D2D_GetCachedBrush(cfg.%bgProp "BorderARGB"%), Round(borderPx * scale))
    }
    D2D_DrawTextCentered(glyph, btnX, btnY, size, size, D2D_GetCachedBrush(txCol), gD2D_Res["tfAction"])
    btnX := btnX - (size + gap)
}

_GUI_DrawActionButtons(wPhys, yRow, rowHPhys, scale) {
    global gGUI_HoverBtn, cfg

    metrics := GUI_GetActionBtnMetrics(scale)
    size := metrics.size
    gap := metrics.gap
    rad := metrics.rad
    marR := Round(cfg.GUI_MarginX * scale)

    btnX := wPhys - marR - size
    btnY := yRow + (rowHPhys - size) // 2

    _GUI_DrawOneActionButton(&btnX, btnY, size, rad, scale, "close",
        "GUI_ShowCloseButton", "GUI_CloseButton", cfg.GUI_CloseButtonGlyph, cfg.GUI_CloseButtonBorderPx, gap)

    _GUI_DrawOneActionButton(&btnX, btnY, size, rad, scale, "kill",
        "GUI_ShowKillButton", "GUI_KillButton", cfg.GUI_KillButtonGlyph, cfg.GUI_KillButtonBorderPx, gap)

    _GUI_DrawOneActionButton(&btnX, btnY, size, rad, scale, "blacklist",
        "GUI_ShowBlacklistButton", "GUI_BlacklistButton", cfg.GUI_BlacklistButtonGlyph, cfg.GUI_BlacklistButtonBorderPx, gap)
}

; ========================= SCROLLBAR =========================

_GUI_DrawScrollbar(wPhys, contentTopY, rowsDrawn, rowHPhys, scrollTop, count, scale) {
    global cfg
    if (!cfg.GUI_ScrollBarEnabled || count <= 0 || rowsDrawn <= 0 || rowHPhys <= 0) {
        return
    }

    trackH := rowsDrawn * rowHPhys
    if (trackH <= 0) {
        return
    }

    trackW := Round(cfg.GUI_ScrollBarWidthPx * scale)
    if (trackW < 2) {
        trackW := 2
    }
    marR := Round(cfg.GUI_ScrollBarMarginRightPx * scale)
    if (marR < 0) {
        marR := 0
    }

    x := wPhys - marR - trackW
    y := contentTopY
    r := trackW // 2

    thumbH := Floor(trackH * rowsDrawn / count)
    if (thumbH < 3) {
        thumbH := 3
    }

    start0 := Win_Wrap0(scrollTop, count)
    startRatio := start0 / count
    y1 := y + Floor(startRatio * trackH)
    y2 := y1 + thumbH
    yEnd := y + trackH

    if (cfg.GUI_ScrollBarGutterEnabled) {
        D2D_FillRoundRect(x, y, trackW, trackH, r, D2D_GetCachedBrush(cfg.GUI_ScrollBarGutterARGB))
    }

    thumbBr := D2D_GetCachedBrush(cfg.GUI_ScrollBarThumbARGB)
    if (y2 <= yEnd) {
        D2D_FillRoundRect(x, y1, trackW, thumbH, r, thumbBr)
    } else {
        h1 := yEnd - y1
        if (h1 > 0) {
            D2D_FillRoundRect(x, y1, trackW, h1, r, thumbBr)
        }
        h2 := y2 - yEnd
        if (h2 > 0) {
            D2D_FillRoundRect(x, y, trackW, h2, r, thumbBr)
        }
    }
}

; ========================= FOOTER =========================

_GUI_DrawFooter(wPhys, hPhys, scale) {
    global gGUI_FooterText, gGUI_LeftArrowRect, gGUI_RightArrowRect, gGUI_HoverBtn, cfg, gD2D_Res
    global PAINT_ARROW_W_DIP, PAINT_ARROW_PAD_DIP
    global gGUI_EffectStyle

    if (!cfg.GUI_ShowFooter) {
        return
    }

    fh := Round(cfg.GUI_FooterHeightPx * scale)
    if (fh < 1) {
        fh := 1
    }
    mx := Round(cfg.GUI_MarginX * scale)
    my := Round(cfg.GUI_MarginY * scale)

    fx := mx
    fy := hPhys - my - fh
    fw := wPhys - 2 * mx
    fr := Round(cfg.GUI_FooterBGRadius * scale)
    if (fr < 0) {
        fr := 0
    }

    ; Draw footer background
    D2D_FillRoundRect(fx, fy, fw, fh, fr, D2D_GetCachedBrush(cfg.GUI_FooterBGARGB))
    if (cfg.GUI_FooterBorderPx > 0) {
        D2D_StrokeRoundRect(fx + 0.5, fy + 0.5, fw - 1, fh - 1, fr, D2D_GetCachedBrush(cfg.GUI_FooterBorderARGB), Round(cfg.GUI_FooterBorderPx * scale))
    }

    pad := Round(cfg.GUI_FooterPaddingX * scale)
    if (pad < 0) {
        pad := 0
    }

    ; Arrow dimensions
    arrowW := Round(PAINT_ARROW_W_DIP * scale)
    arrowPad := Round(PAINT_ARROW_PAD_DIP * scale)

    ; Hoist repeated gD2D_Res lookups
    tfFooter := gD2D_Res["tfFooter"]
    brFooterText := gD2D_Res["brFooterText"]
    static leftArrowGlyph := Chr(0x2190)
    static rightArrowGlyph := Chr(0x2192)

    ; Arrow brush: highlight on hover, normal otherwise
    brArrowL := (gGUI_HoverBtn = "arrowLeft") ? gD2D_Res["brMainHi"] : brFooterText
    brArrowR := (gGUI_HoverBtn = "arrowRight") ? gD2D_Res["brMainHi"] : brFooterText

    ; Left arrow
    leftArrowX := fx + arrowPad
    leftArrowY := fy
    leftArrowW := arrowW
    leftArrowH := fh

    ; Store hit region for click detection
    gGUI_LeftArrowRect.x := leftArrowX
    gGUI_LeftArrowRect.y := leftArrowY
    gGUI_LeftArrowRect.w := leftArrowW
    gGUI_LeftArrowRect.h := leftArrowH

    ; Footer shadow support
    fxShadow := _FX_GetShadowParams(gGUI_EffectStyle, scale)
    fxShadowBr := fxShadow.enabled ? D2D_GetCachedBrush(fxShadow.argb) : 0

    ; Draw left arrow
    if (fxShadow.enabled) {
        _FX_DrawTextCenteredShadow(leftArrowGlyph, leftArrowX, leftArrowY, leftArrowW, leftArrowH, brArrowL, tfFooter, fxShadowBr, fxShadow.offX, fxShadow.offY)
    } else {
        D2D_DrawTextCentered(leftArrowGlyph, leftArrowX, leftArrowY, leftArrowW, leftArrowH, brArrowL, tfFooter)
    }

    ; Right arrow
    rightArrowX := fx + fw - arrowPad - arrowW
    rightArrowY := fy
    rightArrowW := arrowW
    rightArrowH := fh

    ; Store hit region for click detection
    gGUI_RightArrowRect.x := rightArrowX
    gGUI_RightArrowRect.y := rightArrowY
    gGUI_RightArrowRect.w := rightArrowW
    gGUI_RightArrowRect.h := rightArrowH

    ; Draw right arrow
    if (fxShadow.enabled) {
        _FX_DrawTextCenteredShadow(rightArrowGlyph, rightArrowX, rightArrowY, rightArrowW, rightArrowH, brArrowR, tfFooter, fxShadowBr, fxShadow.offX, fxShadow.offY)
    } else {
        D2D_DrawTextCentered(rightArrowGlyph, rightArrowX, rightArrowY, rightArrowW, rightArrowH, brArrowR, tfFooter)
    }

    ; Center text (between arrows)
    textX := leftArrowX + leftArrowW + arrowPad
    textW := rightArrowX - textX - arrowPad
    if (textW < 0) {
        textW := 0
    }

    if (fxShadow.enabled) {
        _FX_DrawTextCenteredShadow(gGUI_FooterText, textX, fy, textW, fh, brFooterText, tfFooter, fxShadowBr, fxShadow.offX, fxShadow.offY)
    } else {
        D2D_DrawTextCentered(gGUI_FooterText, textX, fy, textW, fh, brFooterText, tfFooter)
    }
}

; ========================= VISUAL EFFECTS SYSTEM =========================
; _FX_* functions implement layered visual effects controlled by gGUI_EffectStyle.
; All gradient brushes are transient (created per-frame, released on scope exit).
; This is acceptable: gradient brush creation is ~2μs on modern GPUs, and the
; working set is small (1-3 gradients per frame). Caching would add complexity
; for negligible savings compared to the ~2ms D2D paint budget.

; Build a D2D gradient stop collection from an array of [position, argb] pairs.
; Returns the stop collection COM object (caller must keep a reference).
_FX_BuildStops(stops) {
    global gD2D_RT
    count := stops.Length
    ; D2D1_GRADIENT_STOP = 20 bytes: { float position, D2D1_COLOR_F {r, g, b, a} }
    buf := Buffer(count * 20, 0)
    for i, s in stops {
        off := (i - 1) * 20
        NumPut("float", Float(s[1]), buf, off)
        ; Decompose ARGB to D2D1_COLOR_F {r, g, b, a} as floats
        argb := s[2]
        a := ((argb >> 24) & 0xFF) / 255.0
        r := ((argb >> 16) & 0xFF) / 255.0
        g := ((argb >> 8) & 0xFF) / 255.0
        b := (argb & 0xFF) / 255.0
        NumPut("float", Float(r), buf, off + 4)
        NumPut("float", Float(g), buf, off + 8)
        NumPut("float", Float(b), buf, off + 12)
        NumPut("float", Float(a), buf, off + 16)
    }
    ; CreateGradientStopCollection(stops, count, gamma, extendMode)
    ; GAMMA_2_2=0, CLAMP=0
    return gD2D_RT.CreateGradientStopCollection(buf, count, 0, 0)
}

; Identity brush properties (opacity=1.0, identity transform).
_FX_BrushProps() {
    static bp := 0
    if (!bp) {
        bp := Buffer(28, 0)
        NumPut("float", 1.0, bp, 0)  ; opacity
        ; Identity matrix: [1, 0, 0, 1, 0, 0]
        NumPut("float", 1.0, bp, 4)
        NumPut("float", 0.0, bp, 8)
        NumPut("float", 0.0, bp, 12)
        NumPut("float", 1.0, bp, 16)
        NumPut("float", 0.0, bp, 20)
        NumPut("float", 0.0, bp, 24)
    }
    return bp
}

; Create a linear gradient brush. Caller keeps reference; COM __Delete releases.
_FX_LinearGradient(x1, y1, x2, y2, stops) {
    global gD2D_RT
    gsc := _FX_BuildStops(stops)
    if (!gsc)
        return 0
    ; D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES = 16 bytes: { startPoint, endPoint }
    lgbp := Buffer(16, 0)
    NumPut("float", Float(x1), lgbp, 0)
    NumPut("float", Float(y1), lgbp, 4)
    NumPut("float", Float(x2), lgbp, 8)
    NumPut("float", Float(y2), lgbp, 12)
    return gD2D_RT.CreateLinearGradientBrush(lgbp, _FX_BrushProps(), gsc)
}


; ---- Selection Effects ----

; Draw the selection highlight with effects (drop shadow, gradient, border).
; Called when effects are on (fx = 1). Gradient goes base → darker for depth.
_FX_DrawSelection(x, y, w, h, r) {
    if (w <= 0 || h <= 0)
        return
    global cfg

    baseARGB := cfg.GUI_SelARGB
    a := (baseARGB >> 24) & 0xFF

    ; Drop shadow: 3-layer offset for soft edge
    if (cfg.GUI_SelDropShadow)
        _FX_DrawSelDropShadow(x, y, w, h, r)

    ; Diagonal gradient: base color → 20% darker (depth without washing out)
    darkARGB := ((a) << 24) | _FX_BlendToBlack(baseARGB, 0.20)
    gradBr := _FX_LinearGradient(x, y, x + w, y + h, [
        [0.0, baseARGB],
        [1.0, darkARGB]
    ])
    if (gradBr) {
        D2D_FillRoundRect(x, y, w, h, r, gradBr)
    } else {
        D2D_FillRoundRect(x, y, w, h, r, D2D_GetCachedBrush(baseARGB))
    }

    ; Accent border (skip if width is 0)
    bw := cfg.GUI_SelBorderWidthPx
    if (bw > 0) {
        half := bw / 2
        D2D_StrokeRoundRect(x + half, y + half, w - bw, h - bw, r, D2D_GetCachedBrush(cfg.GUI_SelBorderARGB), bw)
    }
}

; Drop shadow behind the selection row.
; Offset down+right, progressively more transparent layers for softness.
_FX_DrawSelDropShadow(x, y, w, h, r) {
    offX := 3
    offY := 3
    ; 3 layers: inner dark → outer soft
    D2D_FillRoundRect(x + offX, y + offY, w, h, r + 1, D2D_GetCachedBrush(0x28000000))
    D2D_FillRoundRect(x + offX + 1, y + offY + 1, w + 2, h + 2, r + 2, D2D_GetCachedBrush(0x18000000))
    D2D_FillRoundRect(x + offX + 2, y + offY + 2, w + 4, h + 4, r + 3, D2D_GetCachedBrush(0x0C000000))
}

; ---- Text Shadow ----

; Draw text with a drop shadow behind it. Shadow is drawn first (offset, darker),
; then crisp text on top. Two DrawText calls per shadowed text element.
_FX_DrawTextLeftShadow(text, x, y, w, h, brush, tf, shadowBrush, offX, offY) {
    D2D_DrawTextLeft(text, x + offX, y + offY, w, h, shadowBrush, tf)
    D2D_DrawTextLeft(text, x, y, w, h, brush, tf)
}

_FX_DrawTextCenteredShadow(text, x, y, w, h, brush, tf, shadowBrush, offX, offY) {
    D2D_DrawTextCentered(text, x + offX, y + offY, w, h, shadowBrush, tf)
    D2D_DrawTextCentered(text, x, y, w, h, brush, tf)
}

; Get shadow parameters for current effect style.
; Returns {enabled, offX, offY, argb} or {enabled: false}.
; Uses config values (GUI_TextShadowAlpha, GUI_TextShadowDistancePx).
_FX_GetShadowParams(fx, scale) {
    global cfg
    if (!fx)
        return {enabled: false}
    alpha := cfg.GUI_TextShadowAlpha
    if (alpha <= 0)
        return {enabled: false}
    dist := cfg.GUI_TextShadowDistancePx
    off := Max(1, Round(dist * scale))
    argb := (alpha << 24) | 0x000000
    return {enabled: true, offX: off, offY: off, argb: argb}
}

; ---- Hover Highlight ----

; Draw a subtle background highlight behind the hovered row.
; Uses config color with a vertical gradient computed from it.
_FX_DrawHover(x, y, w, h, r) {
    global cfg
    baseARGB := cfg.GUI_HoverARGB
    baseA := (baseARGB >> 24) & 0xFF
    baseRGB := baseARGB & 0x00FFFFFF
    ; Vertical gradient: full alpha at top, fading to ~30% at bottom
    topARGB := baseARGB
    midA := Round(baseA * 0.6)
    midARGB := (midA << 24) | baseRGB
    botA := Round(baseA * 0.3)
    botARGB := (botA << 24) | baseRGB
    hoverBr := _FX_LinearGradient(x, y, x, y + h, [
        [0.0, topARGB],
        [0.6, midARGB],
        [1.0, botARGB]
    ])
    if (hoverBr)
        D2D_FillRoundRect(x, y, w, h, r, hoverBr)
    else
        D2D_FillRoundRect(x, y, w, h, r, D2D_GetCachedBrush(baseARGB))
}

; ---- Inner Shadow ----

; Draw gradient strips along window edges to create depth.
; Each edge is a linear gradient from dark at the edge to transparent inward.
; `alpha` controls edge darkness (0x15 = subtle, 0x38 = strong).
_FX_DrawInnerShadow(wPhys, hPhys, depth, alpha) {
    edgeARGB := (alpha << 24) | 0x000000
    botAlpha := Round(alpha * 0.85)
    botARGB := (botAlpha << 24) | 0x000000
    sideAlpha := Round(alpha * 0.7)
    sideARGB := (sideAlpha << 24) | 0x000000

    ; Top edge
    topBr := _FX_LinearGradient(0, 0, 0, depth, [
        [0.0, edgeARGB],
        [1.0, 0x00000000]
    ])
    if (topBr)
        D2D_FillRect(0, 0, wPhys, depth, topBr)

    ; Bottom edge
    botBr := _FX_LinearGradient(0, hPhys - depth, 0, hPhys, [
        [0.0, 0x00000000],
        [1.0, botARGB]
    ])
    if (botBr)
        D2D_FillRect(0, hPhys - depth, wPhys, depth, botBr)

    ; Left edge
    leftBr := _FX_LinearGradient(0, 0, depth, 0, [
        [0.0, sideARGB],
        [1.0, 0x00000000]
    ])
    if (leftBr)
        D2D_FillRect(0, 0, depth, hPhys, leftBr)

    ; Right edge
    rightBr := _FX_LinearGradient(wPhys - depth, 0, wPhys, 0, [
        [0.0, 0x00000000],
        [1.0, sideARGB]
    ])
    if (rightBr)
        D2D_FillRect(wPhys - depth, 0, depth, hPhys, rightBr)
}

; ---- Color Utilities ----

; Blend an ARGB color toward black by factor (0.0 = no change, 1.0 = pure black).
; Returns RGB only (caller handles alpha).
_FX_BlendToBlack(argb, factor) {
    r := (argb >> 16) & 0xFF
    g := (argb >> 8) & 0xFF
    b := argb & 0xFF
    r := Round(r * (1.0 - factor))
    g := Round(g * (1.0 - factor))
    b := Round(b * (1.0 - factor))
    return (r << 16) | (g << 8) | b
}

