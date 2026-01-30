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
global LOG_PATH_PAINT_TIMING := A_Temp "\tabby_paint_timing.log"
_Paint_Log(msg) {
    global cfg, LOG_PATH_PAINT_TIMING
    if (!cfg.DiagPaintTimingLog)
        return
    try {
        timestamp := FormatTime(, "yyyy-MM-dd HH:mm:ss")
        FileAppend(timestamp " | " msg "`n", LOG_PATH_PAINT_TIMING)
    }
}

; Trim log file if it exceeds max size, keeping the tail
_Paint_LogTrim() {
    global cfg, LOG_PATH_PAINT_TIMING
    if (!cfg.DiagPaintTimingLog)
        return
    LogTrim(LOG_PATH_PAINT_TIMING)
}

_Paint_LogStartSession() {
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
    global gGUI_BaseH, gGUI_OverlayH, gGUI_Items, gGUI_FrozenItems, gGUI_Sel, gGUI_ScrollTop, gGUI_LastRowsDesired, gGUI_Revealed
    global gGUI_State, cfg
    global gPaint_LastPaintTick, gPaint_SessionPaintCount
    global gGdip_IconCache, gGdip_Res, gGdip_ResScale, gGdip_BackW, gGdip_BackH, gGdip_BackHdc

    ; ===== TIMING: Start =====
    tTotal := A_TickCount
    idleDuration := (gPaint_LastPaintTick > 0) ? (A_TickCount - gPaint_LastPaintTick) : -1
    gPaint_SessionPaintCount += 1
    paintNum := gPaint_SessionPaintCount

    ; Log context for first paint or paint after long idle (>60s)
    if (paintNum = 1 || idleDuration > 60000) {
        iconCacheSize := 0
        for _ in gGdip_IconCache
            iconCacheSize += 1
        resCount := gGdip_Res.Count
        _Paint_Log("===== PAINT #" paintNum " (idle=" (idleDuration > 0 ? Round(idleDuration/1000, 1) "s" : "first") ") =====")
        _Paint_Log("  Context: items=" gGUI_Items.Length " frozen=" gGUI_FrozenItems.Length " iconCache=" iconCacheSize " resCount=" resCount " resScale=" gGdip_ResScale " backbuf=" gGdip_BackW "x" gGdip_BackH)
    }

    ; Use frozen items when in ACTIVE state, live items otherwise
    items := (gGUI_State = "ACTIVE") ? gGUI_FrozenItems : gGUI_Items

    ; ENFORCE: When in ACTIVE state with ScrollKeepHighlightOnTop, ensure selection is at top
    if (gGUI_State = "ACTIVE" && cfg.GUI_ScrollKeepHighlightOnTop && items.Length > 0) {
        gGUI_ScrollTop := gGUI_Sel - 1
    }

    count := items.Length
    rowsDesired := GUI_ComputeRowsToShow(count)
    if (rowsDesired != gGUI_LastRowsDesired) {
        GUI_ResizeToRows(rowsDesired)
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
    GUI_PaintOverlay(items, gGUI_Sel, phW, phH, scale)
    tPaintOverlay := A_TickCount - t1

    ; ===== TIMING: Buffer setup =====
    t1 := A_TickCount

    ; static: marshal buffers reused per frame
    static bf := Buffer(4, 0)
    static sz := Buffer(8, 0)
    static ptDst := Buffer(8, 0)
    static ptSrc := Buffer(8, 0)

    ; BLENDFUNCTION
    NumPut("UChar", 0x00, bf, 0)
    NumPut("UChar", 0x00, bf, 1)
    NumPut("UChar", 255, bf, 2)
    NumPut("UChar", 0x01, bf, 3)
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
    GUI_RevealBoth()
    tReveal := A_TickCount - t1

    ; ===== TIMING: Total =====
    tTotalMs := A_TickCount - tTotal
    gPaint_LastPaintTick := A_TickCount

    ; Log timing for first paint, paint after long idle, or slow paints (>100ms)
    if (paintNum = 1 || idleDuration > 60000 || tTotalMs > 100) {
        _Paint_Log("  Timing: total=" tTotalMs "ms | getRect=" tGetRect " getScale=" tGetScale " backbuf=" tBackbuf " paintOverlay=" tPaintOverlay " buffers=" tBuffers " updateLayer=" tUpdateLayer " reveal=" tReveal)
    }
}

GUI_RevealBoth() {
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

GUI_PaintOverlay(items, selIndex, wPhys, hPhys, scale) {
    global gGUI_ScrollTop, gGUI_HoverRow, gGUI_FooterText, cfg, gGdip_Res, gGdip_IconCache
    global gPaint_SessionPaintCount, gPaint_LastPaintTick
    global PAINT_HDR_Y_DIP, PAINT_TITLE_Y_DIP, PAINT_TITLE_H_DIP
    global PAINT_SUB_Y_DIP, PAINT_SUB_H_DIP, PAINT_COL_Y_DIP, PAINT_COL_H_DIP
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

    RowH := Round(cfg.GUI_RowHeight * scale)
    if (RowH < 1) {
        RowH := 1
    }
    Mx := Round(cfg.GUI_MarginX * scale)
    My := Round(cfg.GUI_MarginY * scale)
    ISize := Round(cfg.GUI_IconSize * scale)
    Rad := Round(cfg.GUI_RowRadius * scale)
    gapText := Round(cfg.GUI_IconTextGapPx * scale)
    gapCols := Round(cfg.GUI_ColumnGapPx * scale)
    hdrY4 := Round(PAINT_HDR_Y_DIP * scale)
    hdrH28 := Round(cfg.GUI_HeaderHeightPx * scale)
    iconLeftDip := Round(cfg.GUI_IconLeftMargin * scale)

    y := My
    leftX := Mx + iconLeftDip
    textX := leftX + ISize + gapText

    ; Right columns (data-driven: widthProp, nameProp, dataKey)
    ; static: allocated once per process, not per-paint (hot-path rule)
    static colDefs := [
        ["GUI_ColFixed6", "GUI_Col6Name", "Col6"],
        ["GUI_ColFixed5", "GUI_Col5Name", "Col5"],
        ["GUI_ColFixed4", "GUI_Col4Name", "WS"],
        ["GUI_ColFixed3", "GUI_Col3Name", "PID"],
        ["GUI_ColFixed2", "GUI_Col2Name", "hwndHex"]
    ]
    cols := []
    rightX := wPhys - Mx
    for _, def in colDefs {
        colW := Round(cfg.%def[1]% * scale)
        if (colW > 0) {
            cx := rightX - colW
            cols.Push({name: cfg.%def[2]%, w: colW, key: def[3], x: cx})
            rightX := cx - gapCols
        }
    }

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

        ; Pre-compute scaled values (avoids ~90 Round() calls per frame)
        titleY := Round(PAINT_TITLE_Y_DIP * scale)
        titleH := Round(PAINT_TITLE_H_DIP * scale)
        subY := Round(PAINT_SUB_Y_DIP * scale)
        subH := Round(PAINT_SUB_H_DIP * scale)
        colY := Round(PAINT_COL_Y_DIP * scale)
        colH := Round(PAINT_COL_H_DIP * scale)

        while (i < rowsToDraw && (yRow + RowH <= contentTopY + availH)) {
            idx0 := Win_Wrap0(start0 + i, count)
            idx1 := idx0 + 1
            cur := items[idx1]
            isSel := (idx1 = selIndex)

            if (isSel) {
                Gdip_FillRoundRect(g, Gdip_GetCachedBrush(cfg.GUI_SelARGB), Mx - Round(4 * scale), yRow - Round(2 * scale), wPhys - 2 * Mx + Round(8 * scale), RowH, Rad)
            }

            ix := leftX
            iy := yRow + (RowH - ISize) // 2

            ; ===== TIMING: Icon draw =====
            tIcon := A_TickCount
            iconDrawn := false
            iconWasCacheHit := false
            if (cur.HasOwnProp("iconHicon") && cur.iconHicon) {
                ; Check if this will be a cache hit BEFORE drawing (for logging)
                if (gGdip_IconCache.Has(cur.hwnd)) {
                    cached := gGdip_IconCache[cur.hwnd]
                    if (cached.hicon = cur.iconHicon && cached.pBmp)
                        iconWasCacheHit := true
                }
                iconDrawn := Gdip_DrawCachedIcon(g, cur.hwnd, cur.iconHicon, ix, iy, ISize)
                if (iconWasCacheHit)
                    iconCacheHits += 1
                else
                    iconCacheMisses += 1
            }
            if (!iconDrawn) {
                Gdip_FillEllipse(g, Gdip_GetCachedBrush(Gdip_ARGBFromIndex(idx1)), ix, iy, ISize, ISize)
            }
            tPO_IconsTotal += A_TickCount - tIcon

            fMainUse := isSel ? gGdip_Res["fMainHi"] : gGdip_Res["fMain"]
            fSubUse := isSel ? gGdip_Res["fSubHi"] : gGdip_Res["fSub"]
            fColUse := isSel ? gGdip_Res["fColHi"] : gGdip_Res["fCol"]
            brMainUse := isSel ? gGdip_Res["brMainHi"] : gGdip_Res["brMain"]
            brSubUse := isSel ? gGdip_Res["brSubHi"] : gGdip_Res["brSub"]
            brColUse := isSel ? gGdip_Res["brColHi"] : gGdip_Res["brCol"]

            title := cur.HasOwnProp("Title") ? cur.Title : ""
            Gdip_DrawText(g, title, textX, yRow + titleY, textW, titleH, brMainUse, fMainUse, fmtLeft)

            sub := ""
            if (cur.HasOwnProp("processName") && cur.processName != "") {
                sub := cur.processName
            } else if (cur.HasOwnProp("Class")) {
                sub := "Class: " cur.Class
            }
            Gdip_DrawText(g, sub, textX, yRow + subY, textW, subH, brSubUse, fSubUse, fmtLeft)

            for _, col in cols {
                val := ""
                if (cur.HasOwnProp(col.key)) {
                    val := cur.%col.key%
                }
                Gdip_DrawText(g, val, col.x, yRow + colY, col.w, colH, brColUse, fColUse, gGdip_Res["fmt"])
            }

            if (idx1 = gGUI_HoverRow) {
                GUI_DrawActionButtons(g, wPhys, yRow, RowH, scale)
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
        GUI_DrawScrollbar(g, wPhys, contentTopY, rowsToDraw, RowH, scrollTop, count, scale)
    }
    tPO_Scrollbar := A_TickCount - t1

    ; Footer
    t1 := A_TickCount
    if (cfg.GUI_ShowFooter) {
        GUI_DrawFooter(g, wPhys, hPhys, scale)
    }
    tPO_Footer := A_TickCount - t1

    ; ===== TIMING: Log PaintOverlay details for first paint or paint after long idle =====
    tPO_Total := A_TickCount - tPO_Start
    idleDuration := (gPaint_LastPaintTick > 0) ? (A_TickCount - gPaint_LastPaintTick) : -1
    if (gPaint_SessionPaintCount <= 1 || idleDuration > 60000 || tPO_Total > 50) {
        _Paint_Log("  PaintOverlay: total=" tPO_Total "ms | resources=" tPO_Resources " graphicsClear=" tPO_GraphicsClear " rows=" (IsSet(tPO_RowsTotal) ? tPO_RowsTotal : 0) " scrollbar=" tPO_Scrollbar " footer=" tPO_Footer)
        if (IsSet(tPO_IconsTotal)) {
            _Paint_Log("    Icons: totalTime=" tPO_IconsTotal "ms | hits=" iconCacheHits " misses=" iconCacheMisses " rowsDrawn=" rowsToDraw)
        }
    }
}

; ========================= RESOURCE MANAGEMENT =========================

GUI_EnsureResources(scale) {
    global gGdip_Res, gGdip_ResScale, cfg
    global gPaint_SessionPaintCount, gPaint_LastPaintTick
    global GDIP_UNIT_PIXEL, GDIP_STRING_ALIGN_NEAR, GDIP_STRING_ALIGN_CENTER, GDIP_STRING_ALIGN_FAR
    global GDIP_STRING_FORMAT_NO_WRAP, GDIP_STRING_FORMAT_LINE_LIMIT, GDIP_STRING_TRIMMING_ELLIPSIS

    if (Abs(gGdip_ResScale - scale) < 0.001 && gGdip_Res.Count) {
        ; Resources exist and scale unchanged - skip recreation
        return
    }

    ; Log resource recreation (this is potentially slow)
    idleDuration := (gPaint_LastPaintTick > 0) ? (A_TickCount - gPaint_LastPaintTick) : -1
    _Paint_Log("  ** RECREATING RESOURCES (oldScale=" gGdip_ResScale " newScale=" scale " resCount=" gGdip_Res.Count " idle=" (idleDuration > 0 ? Round(idleDuration/1000, 1) "s" : "first") ")")

    tRes_Start := A_TickCount

    t1 := A_TickCount
    Gdip_DisposeResources()
    tRes_Dispose := A_TickCount - t1

    t1 := A_TickCount
    Gdip_Startup()
    tRes_Startup := A_TickCount - t1

    ; Brushes
    t1 := A_TickCount
    brushes := [
        ["brMain", cfg.GUI_MainARGB],
        ["brMainHi", cfg.GUI_MainARGBHi],
        ["brSub", cfg.GUI_SubARGB],
        ["brSubHi", cfg.GUI_SubARGBHi],
        ["brCol", cfg.GUI_ColARGB],
        ["brColHi", cfg.GUI_ColARGBHi],
        ["brHdr", cfg.GUI_HdrARGB],
        ["brHit", 0x01000000],
        ["brFooterText", cfg.GUI_FooterTextARGB]
    ]
    for _, b in brushes {
        br := 0
        DllCall("gdiplus\GdipCreateSolidFill", "int", b[2], "ptr*", &br)
        gGdip_Res[b[1]] := br
    }
    tRes_Brushes := A_TickCount - t1

    ; Fonts
    t1 := A_TickCount

    fonts := [
        [cfg.GUI_MainFontName, cfg.GUI_MainFontSize, cfg.GUI_MainFontWeight, "ffMain", "fMain"],
        [cfg.GUI_MainFontNameHi, cfg.GUI_MainFontSizeHi, cfg.GUI_MainFontWeightHi, "ffMainHi", "fMainHi"],
        [cfg.GUI_SubFontName, cfg.GUI_SubFontSize, cfg.GUI_SubFontWeight, "ffSub", "fSub"],
        [cfg.GUI_SubFontNameHi, cfg.GUI_SubFontSizeHi, cfg.GUI_SubFontWeightHi, "ffSubHi", "fSubHi"],
        [cfg.GUI_ColFontName, cfg.GUI_ColFontSize, cfg.GUI_ColFontWeight, "ffCol", "fCol"],
        [cfg.GUI_ColFontNameHi, cfg.GUI_ColFontSizeHi, cfg.GUI_ColFontWeightHi, "ffColHi", "fColHi"],
        [cfg.GUI_HdrFontName, cfg.GUI_HdrFontSize, cfg.GUI_HdrFontWeight, "ffHdr", "fHdr"],
        [cfg.GUI_ActionFontName, cfg.GUI_ActionFontSize, cfg.GUI_ActionFontWeight, "ffAction", "fAction"],
        [cfg.GUI_FooterFontName, cfg.GUI_FooterFontSize, cfg.GUI_FooterFontWeight, "ffFooter", "fFooter"]
    ]
    for _, f in fonts {
        fam := 0
        font := 0
        style := Gdip_FontStyleFromWeight(f[3])
        DllCall("gdiplus\GdipCreateFontFamilyFromName", "wstr", f[1], "ptr", 0, "ptr*", &fam)
        DllCall("gdiplus\GdipCreateFont", "ptr", fam, "float", f[2] * scale, "int", style, "int", GDIP_UNIT_PIXEL, "ptr*", &font)
        gGdip_Res[f[4]] := fam
        gGdip_Res[f[5]] := font
    }
    tRes_Fonts := A_TickCount - t1

    ; String formats
    t1 := A_TickCount
    fmtFlags := GDIP_STRING_FORMAT_NO_WRAP | GDIP_STRING_FORMAT_LINE_LIMIT

    formats := [
        ["fmt", GDIP_STRING_ALIGN_NEAR, GDIP_STRING_ALIGN_NEAR],
        ["fmtCenter", GDIP_STRING_ALIGN_CENTER, GDIP_STRING_ALIGN_NEAR],
        ["fmtRight", GDIP_STRING_ALIGN_FAR, GDIP_STRING_ALIGN_NEAR],
        ["fmtLeft", GDIP_STRING_ALIGN_NEAR, GDIP_STRING_ALIGN_NEAR],
        ["fmtLeftCol", GDIP_STRING_ALIGN_NEAR, GDIP_STRING_ALIGN_NEAR],
        ["fmtFooterLeft", GDIP_STRING_ALIGN_NEAR, GDIP_STRING_ALIGN_CENTER],
        ["fmtFooterCenter", GDIP_STRING_ALIGN_CENTER, GDIP_STRING_ALIGN_CENTER],
        ["fmtFooterRight", GDIP_STRING_ALIGN_FAR, GDIP_STRING_ALIGN_CENTER]
    ]
    for _, fm in formats {
        fmt := 0
        DllCall("gdiplus\GdipCreateStringFormat", "int", 0, "ushort", 0, "ptr*", &fmt)
        DllCall("gdiplus\GdipSetStringFormatFlags", "ptr", fmt, "int", fmtFlags)
        DllCall("gdiplus\GdipSetStringFormatTrimming", "ptr", fmt, "int", GDIP_STRING_TRIMMING_ELLIPSIS)
        DllCall("gdiplus\GdipSetStringFormatAlign", "ptr", fmt, "int", fm[2])
        DllCall("gdiplus\GdipSetStringFormatLineAlign", "ptr", fmt, "int", fm[3])
        gGdip_Res[fm[1]] := fmt
    }
    tRes_Formats := A_TickCount - t1

    gGdip_ResScale := scale

    ; Log resource recreation timing
    tRes_Total := A_TickCount - tRes_Start
    _Paint_Log("    Resources: total=" tRes_Total "ms | dispose=" tRes_Dispose " startup=" tRes_Startup " brushes=" tRes_Brushes " fonts=" tRes_Fonts " formats=" tRes_Formats)
}

; ========================= ACTION BUTTONS =========================

; Get scaled action button metrics with minimums enforced
; Returns: {size, gap, rad}
_GUI_GetActionBtnMetrics(scale) {
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

    Gdip_FillRoundRect(g, Gdip_GetCachedBrush(bgCol), btnX, btnY, size, size, rad)
    if (borderPx > 0) {
        Gdip_StrokeRoundRect(g, Gdip_GetCachedPen(cfg.%bgProp "BorderARGB"%, Round(borderPx * scale)), btnX + 0.5, btnY + 0.5, size - 1, size - 1, rad)
    }
    Gdip_DrawCenteredText(g, glyph, btnX, btnY, size, size, Gdip_GetCachedBrush(txCol), gGdip_Res["fAction"], gGdip_Res["fmtCenter"])
    btnX := btnX - (size + gap)
}

GUI_DrawActionButtons(g, wPhys, yRow, rowHPhys, scale) {
    global gGUI_HoverBtn, cfg

    metrics := _GUI_GetActionBtnMetrics(scale)
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

GUI_DrawScrollbar(g, wPhys, contentTopY, rowsDrawn, rowHPhys, scrollTop, count, scale) {
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
        Gdip_FillRoundRect(g, Gdip_GetCachedBrush(cfg.GUI_ScrollBarGutterARGB), x, y, trackW, trackH, r)
    }

    thumbBr := Gdip_GetCachedBrush(cfg.GUI_ScrollBarThumbARGB)
    if (y2 <= yEnd) {
        Gdip_FillRoundRect(g, thumbBr, x, y1, trackW, thumbH, r)
    } else {
        h1 := yEnd - y1
        if (h1 > 0) {
            Gdip_FillRoundRect(g, thumbBr, x, y1, trackW, h1, r)
        }
        h2 := y2 - yEnd
        if (h2 > 0) {
            Gdip_FillRoundRect(g, thumbBr, x, y, trackW, h2, r)
        }
    }
}

; ========================= FOOTER =========================

GUI_DrawFooter(g, wPhys, hPhys, scale) {
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
    Gdip_FillRoundRect(g, Gdip_GetCachedBrush(cfg.GUI_FooterBGARGB), fx, fy, fw, fh, fr)
    if (cfg.GUI_FooterBorderPx > 0) {
        Gdip_StrokeRoundRect(g, Gdip_GetCachedPen(cfg.GUI_FooterBorderARGB, Round(cfg.GUI_FooterBorderPx * scale)), fx + 0.5, fy + 0.5, fw - 1, fh - 1, fr)
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
    static rfLeft := Buffer(16, 0)
    NumPut("Float", leftArrowX, rfLeft, 0)
    NumPut("Float", leftArrowY, rfLeft, 4)
    NumPut("Float", leftArrowW, rfLeft, 8)
    NumPut("Float", leftArrowH, rfLeft, 12)
    DllCall("gdiplus\GdipDrawString", "ptr", g, "wstr", Chr(0x2190), "int", -1, "ptr", gGdip_Res["fFooter"], "ptr", rfLeft.Ptr, "ptr", gGdip_Res["fmtFooterCenter"], "ptr", gGdip_Res["brFooterText"])

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
    static rfRight := Buffer(16, 0)
    NumPut("Float", rightArrowX, rfRight, 0)
    NumPut("Float", rightArrowY, rfRight, 4)
    NumPut("Float", rightArrowW, rfRight, 8)
    NumPut("Float", rightArrowH, rfRight, 12)
    DllCall("gdiplus\GdipDrawString", "ptr", g, "wstr", Chr(0x2192), "int", -1, "ptr", gGdip_Res["fFooter"], "ptr", rfRight.Ptr, "ptr", gGdip_Res["fmtFooterCenter"], "ptr", gGdip_Res["brFooterText"])

    ; Center text (between arrows)
    textX := leftArrowX + leftArrowW + arrowPad
    textW := rightArrowX - textX - arrowPad
    if (textW < 0) {
        textW := 0
    }

    static rfCenter := Buffer(16, 0)
    NumPut("Float", textX, rfCenter, 0)
    NumPut("Float", fy, rfCenter, 4)
    NumPut("Float", textW, rfCenter, 8)
    NumPut("Float", fh, rfCenter, 12)
    DllCall("gdiplus\GdipDrawString", "ptr", g, "wstr", gGUI_FooterText, "int", -1, "ptr", gGdip_Res["fFooter"], "ptr", rfCenter.Ptr, "ptr", gGdip_Res["fmtFooterCenter"], "ptr", gGdip_Res["brFooterText"])
}
