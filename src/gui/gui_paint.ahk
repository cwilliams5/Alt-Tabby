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
        FileAppend("========== NEW SESSION " FormatTime(, "yyyy-MM-dd HH:mm:ss") " ==========`n", LOG_PATH_PAINT_TIMING)
    }
}

; ========================= MAIN REPAINT =========================

GUI_Repaint() {
    Critical "On"  ; Protect GDI+ back buffer from concurrent hotkey interruption
    global gGUI_BaseH, gGUI_OverlayH, gGUI_LiveItems, gGUI_DisplayItems, gGUI_Sel, gGUI_ScrollTop, gGUI_LastRowsDesired, gGUI_Revealed
    global gGUI_State, cfg
    global gPaint_LastPaintTick, gPaint_SessionPaintCount
    global gGdip_IconCache, gGdip_Res, gGdip_ResScale, gGdip_BackW, gGdip_BackH, gGdip_BackHdc

    ; ===== TIMING: Start =====
    tTotal := A_TickCount
    idleDuration := (gPaint_LastPaintTick > 0) ? (A_TickCount - gPaint_LastPaintTick) : -1
    gPaint_SessionPaintCount += 1
    paintNum := gPaint_SessionPaintCount

    ; Log context for first paint or paint after long idle (>60s)
    if (cfg.DiagPaintTimingLog && (paintNum = 1 || idleDuration > 60000)) {
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
    if (rowsDesired != gGUI_LastRowsDesired) {
        GUI_ResizeToRows(rowsDesired, true)  ; skipFlush: DwmFlush happens later in RevealBoth
        gGUI_LastRowsDesired := rowsDesired
    }

    phX := 0
    phY := 0
    phW := 0
    phH := 0

    ; ===== TIMING: GetRect =====
    t1 := A_TickCount
    Win_GetRectPhys(gGUI_BaseH, &phX, &phY, &phW, &phH)
    tGetRect := A_TickCount - t1

    ; ===== TIMING: GetScale =====
    t1 := A_TickCount
    scale := Win_GetScaleForWindow(gGUI_BaseH)
    tGetScale := A_TickCount - t1

    ; ===== TIMING: EnsureBackbuffer =====
    t1 := A_TickCount
    Gdip_EnsureBackbuffer(phW, phH)
    tBackbuf := A_TickCount - t1

    ; ===== TIMING: PaintOverlay (the big one) =====
    t1 := A_TickCount
    _GUI_PaintOverlay(items, gGUI_Sel, phW, phH, scale)
    tPaintOverlay := A_TickCount - t1

    ; ===== TIMING: Buffer setup =====
    t1 := A_TickCount

    ; static: marshal buffers reused per frame
    bf := Gdip_GetBlendFunction()
    static sz := Buffer(8, 0)
    static ptDst := Buffer(8, 0)
    static ptSrc := Buffer(8, 0)
    NumPut("Int", phW, sz, 0)
    NumPut("Int", phH, sz, 4)
    NumPut("Int", phX, ptDst, 0)
    NumPut("Int", phY, ptDst, 4)

    tBuffers := A_TickCount - t1

    ; ===== TIMING: UpdateLayeredWindow =====
    t1 := A_TickCount

    ; Ensure WS_EX_LAYERED
    global GWL_EXSTYLE, WS_EX_LAYERED
    ex := DllCall("user32\GetWindowLongPtrW", "ptr", gGUI_OverlayH, "int", GWL_EXSTYLE, "ptr")
    if (!(ex & WS_EX_LAYERED)) {
        ex := ex | WS_EX_LAYERED
        DllCall("user32\SetWindowLongPtrW", "ptr", gGUI_OverlayH, "int", GWL_EXSTYLE, "ptr", ex, "ptr")
    }

    hdcScreen := DllCall("user32\GetDC", "ptr", 0, "ptr")
    DllCall("user32\UpdateLayeredWindow", "ptr", gGUI_OverlayH, "ptr", hdcScreen, "ptr", ptDst.Ptr, "ptr", sz.Ptr, "ptr", gGdip_BackHdc, "ptr", ptSrc.Ptr, "int", 0, "ptr", bf.Ptr, "uint", 0x2, "int")
    DllCall("user32\ReleaseDC", "ptr", 0, "ptr", hdcScreen)

    tUpdateLayer := A_TickCount - t1

    ; ===== TIMING: RevealBoth =====
    t1 := A_TickCount
    _GUI_RevealBoth()
    tReveal := A_TickCount - t1

    ; ===== TIMING: Total =====
    tTotalMs := A_TickCount - tTotal
    gPaint_LastPaintTick := A_TickCount

    ; Log timing for first paint, paint after long idle, or slow paints (>100ms)
    if (cfg.DiagPaintTimingLog && (paintNum = 1 || idleDuration > 60000 || tTotalMs > 100)) {
        Paint_Log("  Timing: total=" tTotalMs "ms | getRect=" tGetRect " getScale=" tGetScale " backbuf=" tBackbuf " paintOverlay=" tPaintOverlay " buffers=" tBuffers " updateLayer=" tUpdateLayer " reveal=" tReveal)
    }
}

_GUI_RevealBoth() {
    global gGUI_Base, gGUI_BaseH, gGUI_Overlay, gGUI_Revealed, cfg
    global gGUI_State  ; Need access to state for race fix

    if (gGUI_Revealed) {
        return
    }

    ; RACE FIX: Abort early if state already changed
    if (gGUI_State != "ACTIVE") {
        try gGUI_Overlay.Hide()
        try gGUI_Base.Hide()
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
        return
    }

    try {
        gGUI_Overlay.Show("NA")
    }

    ; RACE FIX: Check again after Overlay.Show
    if (gGUI_State != "ACTIVE") {
        try gGUI_Overlay.Hide()
        try gGUI_Base.Hide()
        return
    }

    Win_DwmFlush()
    gGUI_Revealed := true
}

; ========================= OVERLAY PAINTING =========================

_GUI_PaintOverlay(items, selIndex, wPhys, hPhys, scale) {
    global gGUI_ScrollTop, gGUI_HoverRow, gGUI_FooterText, cfg, gGdip_Res, gGdip_IconCache
    global gPaint_SessionPaintCount, gPaint_LastPaintTick
    global PAINT_TEXT_RIGHT_PAD_DIP

    ; ===== TIMING: EnsureResources =====
    tPO_Start := A_TickCount
    t1 := A_TickCount
    GUI_EnsureResources(scale)
    tPO_Resources := A_TickCount - t1

    ; ===== TIMING: EnsureGraphics + Clear =====
    t1 := A_TickCount
    g := Gdip_EnsureGraphics()
    if (!g) {
        return
    }

    Gdip_Clear(g, 0x00000000)
    Gdip_FillRect(g, gGdip_Res["brHit"], 0, 0, wPhys, hPhys)
    tPO_GraphicsClear := A_TickCount - t1

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
        ["GUI_ColFixed5", "GUI_Col5Name", "Col5"],
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
        Gdip_DrawText(g, "Title", textX, hdrY, textW, Round(20 * scale), gGdip_Res["brHdr"], gGdip_Res["fHdr"], fmtLeft)
        for _, col in cols {
            Gdip_DrawText(g, col.name, col.x, hdrY, col.w, Round(20 * scale), gGdip_Res["brHdr"], gGdip_Res["fHdr"], gGdip_Res["fmt"])
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
        Gdip_DrawCenteredText(g, cfg.GUI_EmptyListText, rectX, rectY, rectW, rectH, gGdip_Res["brMain"], gGdip_Res["fMain"], gGdip_Res["fmtCenter"])
    } else if (rowsToDraw > 0) {
        ; ===== TIMING: Row loop start =====
        tPO_RowsStart := A_TickCount
        tPO_IconsTotal := 0
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
            tIcon := A_TickCount
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
            tPO_IconsTotal += A_TickCount - tIcon

            fMainUse := isSel ? fMainHi : fMain
            fSubUse := isSel ? fSubHi : fSub
            fColUse := isSel ? fColHi : fCol
            brMainUse := isSel ? brMainHi : brMain
            brSubUse := isSel ? brSubHi : brSub
            brColUse := isSel ? brColHi : brCol

            title := cur.Title
            Gdip_DrawText(g, title, textX, yRow + titleY, textW, titleH, brMainUse, fMainUse, fmtLeft)

            sub := ""
            if (cur.processName != "") {
                sub := cur.processName
            } else {
                sub := "Class: " cur.Class
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

            if (idx1 = gGUI_HoverRow) {
                _GUI_DrawActionButtons(g, wPhys, yRow, RowH, scale)
            }

            yRow := yRow + RowH
            i := i + 1
        }
        ; ===== TIMING: Row loop end =====
        tPO_RowsTotal := A_TickCount - tPO_RowsStart
    }

    ; Scrollbar
    t1 := A_TickCount
    if (count > rowsToDraw && rowsToDraw > 0) {
        _GUI_DrawScrollbar(g, wPhys, contentTopY, rowsToDraw, RowH, scrollTop, count, scale)
    }
    tPO_Scrollbar := A_TickCount - t1

    ; Footer
    t1 := A_TickCount
    if (cfg.GUI_ShowFooter) {
        _GUI_DrawFooter(g, wPhys, hPhys, scale)
    }
    tPO_Footer := A_TickCount - t1

    ; ===== TIMING: Log PaintOverlay details for first paint or paint after long idle =====
    if (cfg.DiagPaintTimingLog) {
        tPO_Total := A_TickCount - tPO_Start
        idleDuration := (gPaint_LastPaintTick > 0) ? (A_TickCount - gPaint_LastPaintTick) : -1
        if (gPaint_SessionPaintCount <= 1 || idleDuration > 60000 || tPO_Total > 50) {
            Paint_Log("  PaintOverlay: total=" tPO_Total "ms | resources=" tPO_Resources " graphicsClear=" tPO_GraphicsClear " rows=" (IsSet(tPO_RowsTotal) ? tPO_RowsTotal : 0) " scrollbar=" tPO_Scrollbar " footer=" tPO_Footer)
            if (IsSet(tPO_IconsTotal)) {
                Paint_Log("    Icons: totalTime=" tPO_IconsTotal "ms | hits=" iconCacheHits " misses=" iconCacheMisses " rowsDrawn=" rowsToDraw)
            }
        }
    }
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
    global gGUI_FooterText, gGUI_LeftArrowRect, gGUI_RightArrowRect, cfg, gGdip_Res
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
    Gdip_DrawCenteredText(g, Chr(0x2190), leftArrowX, leftArrowY, leftArrowW, leftArrowH, gGdip_Res["brFooterText"], gGdip_Res["fFooter"], gGdip_Res["fmtFooterCenter"])

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
    Gdip_DrawCenteredText(g, Chr(0x2192), rightArrowX, rightArrowY, rightArrowW, rightArrowH, gGdip_Res["brFooterText"], gGdip_Res["fFooter"], gGdip_Res["fmtFooterCenter"])

    ; Center text (between arrows)
    textX := leftArrowX + leftArrowW + arrowPad
    textW := rightArrowX - textX - arrowPad
    if (textW < 0) {
        textW := 0
    }

    Gdip_DrawCenteredText(g, gGUI_FooterText, textX, fy, textW, fh, gGdip_Res["brFooterText"], gGdip_Res["fFooter"], gGdip_Res["fmtFooterCenter"])
}
