#Requires AutoHotkey v2.0
; Alt-Tabby GUI - Painting
; Handles all rendering: overlay painting, resources, scrollbar, footer, action buttons
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals/functions

; ========================= PAINT TIMING DEBUG LOG =========================
; Dedicated log for investigating slow paint after extended idle
; Log file: %TEMP%\tabby_paint_timing.log
; Auto-trimmed to keep last ~50KB when exceeding 100KB

global gPaint_LastPaintTick := 0      ; When we last painted (for idle duration calc)
global gPaint_SessionPaintCount := 0  ; How many paints this session
global gPaint_RepaintInProgress := false  ; Reentrancy guard (see #90)

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
    ; Reentrancy guard: Win32 calls (UpdateLayeredWindow, SetWindowPos) pump the
    ; message queue, which dispatches queued WinEvent callbacks mid-paint. Those
    ; callbacks update the store and trigger GUI_PatchCosmeticUpdates → GUI_Repaint,
    ; creating nested repaints that paint intermediate state immediately overwritten.
    ; Guard skips nested calls; the outer paint finishes with correct final state. (#90)
    global gPaint_RepaintInProgress
    if (gPaint_RepaintInProgress)
        return
    gPaint_RepaintInProgress := true

    Profiler.Enter("GUI_Repaint") ; @profile
    Critical "On"  ; Protect GDI+ back buffer from concurrent hotkey interruption
    global gGUI_BaseH, gGUI_OverlayH, gGUI_LiveItems, gGUI_DisplayItems, gGUI_Sel, gGUI_ScrollTop, gGUI_LastRowsDesired, gGUI_Revealed
    global gGUI_State, cfg
    global gPaint_LastPaintTick, gPaint_SessionPaintCount
    global gGdip_IconCache, gGdip_Res, gGdip_ResScale, gGdip_BackW, gGdip_BackH, gGdip_BackHdc

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
        resCount := gGdip_Res.Count
        Paint_Log("===== PAINT #" paintNum " (idle=" (idleDuration > 0 ? Round(idleDuration/1000, 1) "s" : "first") ") =====")
        Paint_Log("  Context: items=" gGUI_LiveItems.Length " frozen=" gGUI_DisplayItems.Length " iconCache=" iconCacheSize " resCount=" resCount " resScale=" gGdip_ResScale " backbuf=" gGdip_BackW "x" gGdip_BackH)
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
    ; Compute target rect from layout, not from the window.  The base window may
    ; not be resized yet — SetWindowPos is DEFERRED to right before
    ; UpdateLayeredWindow so DWM can't present a frame with mismatched
    ; base/overlay sizes (the 1-frame flash on workspace switches).
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

    ; ===== TIMING: EnsureBackbuffer =====
    if (diagTiming)
        t1 := QPC()
    Gdip_EnsureBackbuffer(phW, phH)
    if (diagTiming)
        tBackbuf := QPC() - t1

    ; ===== TIMING: PaintOverlay (the big one) =====
    if (diagTiming)
        t1 := QPC()
    _GUI_PaintOverlay(items, gGUI_Sel, phW, phH, scale, diagTiming)
    if (diagTiming)
        tPaintOverlay := QPC() - t1

    ; ===== TIMING: Buffer setup =====
    if (diagTiming)
        t1 := QPC()

    ; static: marshal buffers reused per frame
    static bf := Gdip_GetBlendFunction()
    static sz := Buffer(8, 0)
    static ptDst := Buffer(8, 0)
    static ptSrc := Buffer(8, 0)
    NumPut("Int", phW, sz, 0)
    NumPut("Int", phH, sz, 4)
    NumPut("Int", phX, ptDst, 0)
    NumPut("Int", phY, ptDst, 4)

    if (diagTiming)
        tBuffers := QPC() - t1

    ; ===== TIMING: UpdateLayeredWindow =====
    if (diagTiming)
        t1 := QPC()

    ; Ensure WS_EX_LAYERED
    global GWL_EXSTYLE, WS_EX_LAYERED
    ex := DllCall("user32\GetWindowLongPtrW", "ptr", gGUI_OverlayH, "int", GWL_EXSTYLE, "ptr")
    if (!(ex & WS_EX_LAYERED)) {
        ex := ex | WS_EX_LAYERED
        DllCall("user32\SetWindowLongPtrW", "ptr", gGUI_OverlayH, "int", GWL_EXSTYLE, "ptr", ex, "ptr")
    }

    ; SPLIT RESIZE: Ensure the base window is always >= the overlay during
    ; transition frames.  DWM can present between any two Win32 calls, so
    ; we order SetWindowPos (base) vs UpdateLayeredWindow (overlay) to
    ; guarantee the "bad" interim frame is base-too-big (extra acrylic at
    ; bottom — barely visible) rather than overlay-too-big (old content
    ; floating outside the acrylic window — very visible).
    ;
    ; GROWING  → expand base BEFORE ULW  (interim: small overlay on big base)
    ; SHRINKING → shrink base AFTER ULW  (interim: small overlay on big base)
    ;
    ; Only when overlay is already revealed — initial show is handled by
    ; _GUI_ShowOverlayWithFrozen → GUI_ResizeToRows → _GUI_RevealBoth.
    needsResize := (rowsChanged && gGUI_Revealed)
    if (needsResize && rowsDesired > oldRows) {
        Win_SetPosPhys(gGUI_BaseH, phX, phY, phW, phH)
        Win_ApplyRoundRegion(gGUI_BaseH, cfg.GUI_CornerRadiusPx, wDip, hDip)
    }

    hdcScreen := DllCall("user32\GetDC", "ptr", 0, "ptr")
    DllCall("user32\UpdateLayeredWindow", "ptr", gGUI_OverlayH, "ptr", hdcScreen, "ptr", ptDst.Ptr, "ptr", sz.Ptr, "ptr", gGdip_BackHdc, "ptr", ptSrc.Ptr, "int", 0, "ptr", bf.Ptr, "uint", 0x2, "int")
    DllCall("user32\ReleaseDC", "ptr", 0, "ptr", hdcScreen)

    if (needsResize && rowsDesired <= oldRows) {
        Win_SetPosPhys(gGUI_BaseH, phX, phY, phW, phH)
        Win_ApplyRoundRegion(gGUI_BaseH, cfg.GUI_CornerRadiusPx, wDip, hDip)
    }

    if (diagTiming)
        tUpdateLayer := QPC() - t1

    ; ===== TIMING: RevealBoth =====
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
            Paint_Log("  Timing: total=" Round(tTotalMs, 2) "ms | computeRect=" Round(tComputeRect, 2) " backbuf=" Round(tBackbuf, 2) " paintOverlay=" Round(tPaintOverlay, 2) " buffers=" Round(tBuffers, 2) " updateLayer=" Round(tUpdateLayer, 2) " reveal=" Round(tReveal, 2))
    }
    Profiler.Leave() ; @profile
    gPaint_RepaintInProgress := false
}

_GUI_RevealBoth() {
    global gGUI_Base, gGUI_BaseH, gGUI_Overlay, gGUI_Revealed, cfg
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
        try gGUI_Overlay.Hide()
        try gGUI_Base.Hide()
        Profiler.Leave() ; @profile
        return
    }

    Win_ApplyRoundRegion(gGUI_BaseH, cfg.GUI_CornerRadiusPx)

    try {
        gGUI_Base.Show("NA")
    }

    ; RACE FIX: Check if Alt was released during Show (which pumps messages)
    if (gGUI_State != "ACTIVE") {
        try gGUI_Overlay.Hide()
        try gGUI_Base.Hide()
        Profiler.Leave() ; @profile
        return
    }

    try {
        gGUI_Overlay.Show("NA")
    }

    ; RACE FIX: Check again after Overlay.Show
    if (gGUI_State != "ACTIVE") {
        try gGUI_Overlay.Hide()
        try gGUI_Base.Hide()
        Profiler.Leave() ; @profile
        return
    }

    Win_DwmFlush()
    gGUI_Revealed := true
    Profiler.Leave() ; @profile
}

; ========================= OVERLAY PAINTING =========================

_GUI_PaintOverlay(items, selIndex, wPhys, hPhys, scale, diagTiming := false) {
    Profiler.Enter("_GUI_PaintOverlay") ; @profile
    global gGUI_ScrollTop, gGUI_HoverRow, gGUI_FooterText, cfg, gGdip_Res, gGdip_IconCache
    global gPaint_SessionPaintCount, gPaint_LastPaintTick
    global PAINT_TEXT_RIGHT_PAD_DIP, gGUI_WorkspaceMode, WS_MODE_CURRENT
    global gGUI_MonitorMode, MON_MODE_CURRENT

    ; ===== TIMING: EnsureResources =====
    if (diagTiming) {
        tPO_Start := QPC()
        t1 := QPC()
    }
    GUI_EnsureResources(scale)
    if (diagTiming)
        tPO_Resources := QPC() - t1

    ; ===== TIMING: EnsureGraphics + Clear =====
    if (diagTiming)
        t1 := QPC()
    g := Gdip_EnsureGraphics()
    if (!g) {
        Profiler.Leave() ; @profile
        return
    }

    Gdip_Clear(g, 0x00000000)
    Gdip_FillRect(g, gGdip_Res["brHit"], 0, 0, wPhys, hPhys)
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

    fmtLeft := gGdip_Res["fmtLeft"]

    ; Header
    if (cfg.GUI_ShowHeader) {
        hdrY := y + hdrY4
        hdrTextH := Round(20 * scale)
        Gdip_DrawText(g, "Title", textX, hdrY, textW, hdrTextH, gGdip_Res["brHdr"], gGdip_Res["fHdr"], fmtLeft)
        for _, col in cols {
            Gdip_DrawText(g, col.name, col.x, hdrY, col.w, hdrTextH, gGdip_Res["brHdr"], gGdip_Res["fHdr"], gGdip_Res["fmt"])
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
        Gdip_DrawCenteredText(g, emptyText, rectX, rectY, rectW, rectH, gGdip_Res["brMain"], gGdip_Res["fMain"], gGdip_Res["fmtCenter"])
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

        ; Hoist loop-invariant gGdip_Res lookups (14 keys × N rows → 14 lookups total)
        fMain := gGdip_Res["fMain"], fMainHi := gGdip_Res["fMainHi"]
        fSub := gGdip_Res["fSub"], fSubHi := gGdip_Res["fSubHi"]
        fCol := gGdip_Res["fCol"], fColHi := gGdip_Res["fColHi"]
        brMain := gGdip_Res["brMain"], brMainHi := gGdip_Res["brMainHi"]
        brSub := gGdip_Res["brSub"], brSubHi := gGdip_Res["brSubHi"]
        brCol := gGdip_Res["brCol"], brColHi := gGdip_Res["brColHi"]
        fmtCol := gGdip_Res["fmt"]

        while (i < rowsToDraw && (yRow + RowH <= contentTopY + availH)) {
            idx0 := Win_Wrap0(start0 + i, count)
            idx1 := idx0 + 1
            cur := items[idx1]
            isSel := (idx1 = selIndex)

            if (isSel) {
                Gdip_FillRoundRectCached(g, Gdip_GetCachedBrush(cfg.GUI_SelARGB), Mx - Round(4 * scale), yRow - Round(2 * scale), wPhys - 2 * Mx + Round(8 * scale), RowH, Rad)
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
                iconDrawn := Gdip_DrawCachedIcon(g, cur.hwnd, cur.iconHicon, ix, iy, ISize, &iconWasCacheHit)
                if (iconWasCacheHit)
                    iconCacheHits += 1
                else
                    iconCacheMisses += 1
            }
            if (!iconDrawn) {
                Gdip_FillEllipse(g, Gdip_GetCachedBrush(0x60808080), ix, iy, ISize, ISize)
            }
            if (diagTiming)
                tPO_IconsTotal += QPC() - tIcon

            fMainUse := isSel ? fMainHi : fMain
            fSubUse := isSel ? fSubHi : fSub
            fColUse := isSel ? fColHi : fCol
            brMainUse := isSel ? brMainHi : brMain
            brSubUse := isSel ? brSubHi : brSub
            brColUse := isSel ? brColHi : brCol

            title := cur.title
            Gdip_DrawText(g, title, textX, yRow + titleY, textW, titleH, brMainUse, fMainUse, fmtLeft)

            sub := ""
            if (cur.processName != "") {
                sub := cur.processName
            } else {
                sub := "Class: " cur.class
            }
            Gdip_DrawText(g, sub, textX, yRow + subY, textW, subH, brSubUse, fSubUse, fmtLeft)

            for _, col in cols {
                val := ""
                if (col.key = "hwndHex")
                    val := Format("0x{:X}", cur.hwnd)
                else if (cur.HasOwnProp(col.key))
                    val := cur.%col.key%
                Gdip_DrawText(g, val, col.x, yRow + colY, col.w, colH, brColUse, fColUse, fmtCol)
            }

            if (idx1 = hoverRow) {
                _GUI_DrawActionButtons(g, wPhys, yRow, RowH, scale)
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
        _GUI_DrawScrollbar(g, wPhys, contentTopY, rowsToDraw, RowH, scrollTop, count, scale)
    }
    if (diagTiming)
        tPO_Scrollbar := QPC() - t1

    ; Footer
    if (diagTiming)
        t1 := QPC()
    if (cfg.GUI_ShowFooter) {
        _GUI_DrawFooter(g, wPhys, hPhys, scale)
    }
    if (diagTiming)
        tPO_Footer := QPC() - t1

    ; ===== TIMING: Log PaintOverlay details for first paint or paint after long idle =====
    if (diagTiming) {
        tPO_Total := QPC() - tPO_Start
        idleDuration := (gPaint_LastPaintTick > 0) ? (A_TickCount - gPaint_LastPaintTick) : -1
        if (gPaint_SessionPaintCount <= 1 || idleDuration > 60000 || tPO_Total > 50) {
            Paint_Log("  PaintOverlay: total=" Round(tPO_Total, 2) "ms | resources=" Round(tPO_Resources, 2) " graphicsClear=" Round(tPO_GraphicsClear, 2) " rows=" (IsSet(tPO_RowsTotal) ? Round(tPO_RowsTotal, 2) : 0) " scrollbar=" Round(tPO_Scrollbar, 2) " footer=" Round(tPO_Footer, 2))
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
;   g         - GDI+ graphics object
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
_GUI_DrawOneActionButton(g, &btnX, btnY, size, rad, scale, btnName, showProp, bgProp, glyph, borderPx, gap) {
    global gGUI_HoverBtn, cfg, gGdip_Res

    if (!cfg.%showProp%)
        return

    hovered := (gGUI_HoverBtn = btnName)
    bgCol := hovered ? cfg.%bgProp "BGHoverARGB"% : cfg.%bgProp "BGARGB"%
    txCol := hovered ? cfg.%bgProp "TextHoverARGB"% : cfg.%bgProp "TextARGB"%

    Gdip_FillRoundRectCached(g, Gdip_GetCachedBrush(bgCol), btnX, btnY, size, size, rad)
    if (borderPx > 0) {
        Gdip_StrokeRoundRectCached(g, Gdip_GetCachedPen(cfg.%bgProp "BorderARGB"%, Round(borderPx * scale)), btnX + 0.5, btnY + 0.5, size - 1, size - 1, rad)
    }
    Gdip_DrawCenteredText(g, glyph, btnX, btnY, size, size, Gdip_GetCachedBrush(txCol), gGdip_Res["fAction"], gGdip_Res["fmtCenter"])
    btnX := btnX - (size + gap)
}

_GUI_DrawActionButtons(g, wPhys, yRow, rowHPhys, scale) {
    global gGUI_HoverBtn, cfg

    metrics := GUI_GetActionBtnMetrics(scale)
    size := metrics.size
    gap := metrics.gap
    rad := metrics.rad
    marR := Round(cfg.GUI_MarginX * scale)

    btnX := wPhys - marR - size
    btnY := yRow + (rowHPhys - size) // 2

    _GUI_DrawOneActionButton(g, &btnX, btnY, size, rad, scale, "close",
        "GUI_ShowCloseButton", "GUI_CloseButton", cfg.GUI_CloseButtonGlyph, cfg.GUI_CloseButtonBorderPx, gap)

    _GUI_DrawOneActionButton(g, &btnX, btnY, size, rad, scale, "kill",
        "GUI_ShowKillButton", "GUI_KillButton", cfg.GUI_KillButtonGlyph, cfg.GUI_KillButtonBorderPx, gap)

    _GUI_DrawOneActionButton(g, &btnX, btnY, size, rad, scale, "blacklist",
        "GUI_ShowBlacklistButton", "GUI_BlacklistButton", cfg.GUI_BlacklistButtonGlyph, cfg.GUI_BlacklistButtonBorderPx, gap)
}

; ========================= SCROLLBAR =========================

_GUI_DrawScrollbar(g, wPhys, contentTopY, rowsDrawn, rowHPhys, scrollTop, count, scale) {
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
        Gdip_FillRoundRectCached(g, Gdip_GetCachedBrush(cfg.GUI_ScrollBarGutterARGB), x, y, trackW, trackH, r)
    }

    thumbBr := Gdip_GetCachedBrush(cfg.GUI_ScrollBarThumbARGB)
    if (y2 <= yEnd) {
        Gdip_FillRoundRectCached(g, thumbBr, x, y1, trackW, thumbH, r)
    } else {
        h1 := yEnd - y1
        if (h1 > 0) {
            Gdip_FillRoundRectCached(g, thumbBr, x, y1, trackW, h1, r)
        }
        h2 := y2 - yEnd
        if (h2 > 0) {
            Gdip_FillRoundRectCached(g, thumbBr, x, y, trackW, h2, r)
        }
    }
}

; ========================= FOOTER =========================

_GUI_DrawFooter(g, wPhys, hPhys, scale) {
    global gGUI_FooterText, gGUI_LeftArrowRect, gGUI_RightArrowRect, gGUI_HoverBtn, cfg, gGdip_Res
    global PAINT_ARROW_W_DIP, PAINT_ARROW_PAD_DIP

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
    Gdip_FillRoundRectCached(g, Gdip_GetCachedBrush(cfg.GUI_FooterBGARGB), fx, fy, fw, fh, fr)
    if (cfg.GUI_FooterBorderPx > 0) {
        Gdip_StrokeRoundRectCached(g, Gdip_GetCachedPen(cfg.GUI_FooterBorderARGB, Round(cfg.GUI_FooterBorderPx * scale)), fx + 0.5, fy + 0.5, fw - 1, fh - 1, fr)
    }

    pad := Round(cfg.GUI_FooterPaddingX * scale)
    if (pad < 0) {
        pad := 0
    }

    ; Arrow dimensions
    arrowW := Round(PAINT_ARROW_W_DIP * scale)
    arrowPad := Round(PAINT_ARROW_PAD_DIP * scale)

    ; Hoist repeated gGdip_Res lookups
    fFooter := gGdip_Res["fFooter"]
    fmtFooterCenter := gGdip_Res["fmtFooterCenter"]
    brFooterText := gGdip_Res["brFooterText"]
    static leftArrowGlyph := Chr(0x2190)
    static rightArrowGlyph := Chr(0x2192)

    ; Arrow brush: highlight on hover, normal otherwise
    brArrowL := (gGUI_HoverBtn = "arrowLeft") ? gGdip_Res["brMainHi"] : brFooterText
    brArrowR := (gGUI_HoverBtn = "arrowRight") ? gGdip_Res["brMainHi"] : brFooterText

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

    ; Draw left arrow
    Gdip_DrawCenteredText(g, leftArrowGlyph, leftArrowX, leftArrowY, leftArrowW, leftArrowH, brArrowL, fFooter, fmtFooterCenter)

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
    Gdip_DrawCenteredText(g, rightArrowGlyph, rightArrowX, rightArrowY, rightArrowW, rightArrowH, brArrowR, fFooter, fmtFooterCenter)

    ; Center text (between arrows)
    textX := leftArrowX + leftArrowW + arrowPad
    textW := rightArrowX - textX - arrowPad
    if (textW < 0) {
        textW := 0
    }

    Gdip_DrawCenteredText(g, gGUI_FooterText, textX, fy, textW, fh, brFooterText, fFooter, fmtFooterCenter)
}
