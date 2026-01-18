; Alt-Tabby GUI - Painting
; Handles all rendering: overlay painting, resources, scrollbar, footer, action buttons

; ========================= MAIN REPAINT =========================

GUI_Repaint() {
    global gGUI_BaseH, gGUI_OverlayH, gGUI_Items, gGUI_FrozenItems, gGUI_Sel, gGUI_ScrollTop, gGUI_LastRowsDesired, gGUI_Revealed
    global gGUI_State, GUI_ScrollKeepHighlightOnTop

    ; Use frozen items when in ACTIVE state, live items otherwise
    items := (gGUI_State = "ACTIVE") ? gGUI_FrozenItems : gGUI_Items

    ; ENFORCE: When in ACTIVE state with ScrollKeepHighlightOnTop, ensure selection is at top
    if (gGUI_State = "ACTIVE" && GUI_ScrollKeepHighlightOnTop && items.Length > 0) {
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
    Win_GetRectPhys(gGUI_BaseH, &phX, &phY, &phW, &phH)

    scale := Win_GetScaleForWindow(gGUI_BaseH)
    gGdip_CurScale := scale

    Gdip_EnsureBackbuffer(phW, phH)
    GUI_PaintOverlay(items, gGUI_Sel, phW, phH, scale)

    ; BLENDFUNCTION
    bf := Buffer(4, 0)
    NumPut("UChar", 0x00, bf, 0)
    NumPut("UChar", 0x00, bf, 1)
    NumPut("UChar", 255, bf, 2)
    NumPut("UChar", 0x01, bf, 3)

    sz := Buffer(8, 0)
    ptDst := Buffer(8, 0)
    ptSrc := Buffer(8, 0)
    NumPut("Int", phW, sz, 0)
    NumPut("Int", phH, sz, 4)
    NumPut("Int", phX, ptDst, 0)
    NumPut("Int", phY, ptDst, 4)

    ; Ensure WS_EX_LAYERED
    ex := DllCall("user32\GetWindowLongPtrW", "ptr", gGUI_OverlayH, "int", -20, "ptr")
    if (!(ex & 0x80000)) {
        ex := ex | 0x80000
        DllCall("user32\SetWindowLongPtrW", "ptr", gGUI_OverlayH, "int", -20, "ptr", ex, "ptr")
    }

    hdcScreen := DllCall("user32\GetDC", "ptr", 0, "ptr")
    DllCall("user32\UpdateLayeredWindow", "ptr", gGUI_OverlayH, "ptr", hdcScreen, "ptr", ptDst.Ptr, "ptr", sz.Ptr, "ptr", gGdip_BackHdc, "ptr", ptSrc.Ptr, "int", 0, "ptr", bf.Ptr, "uint", 0x2, "int")
    DllCall("user32\ReleaseDC", "ptr", 0, "ptr", hdcScreen)

    GUI_RevealBoth()
}

GUI_RevealBoth() {
    global gGUI_Base, gGUI_BaseH, gGUI_Overlay, gGUI_Revealed

    if (gGUI_Revealed) {
        return
    }

    Win_ApplyRoundRegion(gGUI_BaseH, GUI_CornerRadiusPx)
    try {
        gGUI_Base.Show("NA")
    }
    try {
        gGUI_Overlay.Show("NA")
    }
    Win_DwmFlush()
    gGUI_Revealed := true
}

; ========================= OVERLAY PAINTING =========================

GUI_PaintOverlay(items, selIndex, wPhys, hPhys, scale) {
    global gGUI_ScrollTop, gGUI_HoverRow, gGUI_FooterText

    GUI_EnsureResources(scale)

    g := Gdip_EnsureGraphics()
    if (!g) {
        return
    }

    Gdip_Clear(g, 0x00000000)
    Gdip_FillRect(g, gGdip_Res["brHit"], 0, 0, wPhys, hPhys)

    scrollTop := gGUI_ScrollTop

    RowH := Round(GUI_RowHeight * scale)
    if (RowH < 1) {
        RowH := 1
    }
    Mx := Round(GUI_MarginX * scale)
    My := Round(GUI_MarginY * scale)
    ISize := Round(GUI_IconSize * scale)
    Rad := Round(GUI_RowRadius * scale)
    gapText := Round(12 * scale)
    gapCols := Round(10 * scale)
    hdrY4 := Round(4 * scale)
    hdrH28 := Round(28 * scale)
    iconLeftDip := Round(GUI_IconLeftMargin * scale)

    y := My
    leftX := Mx + iconLeftDip
    textX := leftX + ISize + gapText

    ; Right columns
    cols := []
    Col6W := Round(GUI_ColFixed6 * scale)
    Col5W := Round(GUI_ColFixed5 * scale)
    Col4W := Round(GUI_ColFixed4 * scale)
    Col3W := Round(GUI_ColFixed3 * scale)
    Col2W := Round(GUI_ColFixed2 * scale)

    rightX := wPhys - Mx
    if (Col6W > 0) {
        cx := rightX - Col6W
        cols.Push({name: GUI_Col6Name, w: Col6W, key: "Col6", x: cx})
        rightX := cx - gapCols
    }
    if (Col5W > 0) {
        cx := rightX - Col5W
        cols.Push({name: GUI_Col5Name, w: Col5W, key: "Col5", x: cx})
        rightX := cx - gapCols
    }
    if (Col4W > 0) {
        cx := rightX - Col4W
        cols.Push({name: GUI_Col4Name, w: Col4W, key: "WS", x: cx})
        rightX := cx - gapCols
    }
    if (Col3W > 0) {
        cx := rightX - Col3W
        cols.Push({name: GUI_Col3Name, w: Col3W, key: "PID", x: cx})
        rightX := cx - gapCols
    }
    if (Col2W > 0) {
        cx := rightX - Col2W
        cols.Push({name: GUI_Col2Name, w: Col2W, key: "HWND", x: cx})
        rightX := cx - gapCols
    }

    textW := (rightX - Round(16 * scale)) - textX
    if (textW < 0) {
        textW := 0
    }

    fmtLeft := gGdip_Res["fmtLeft"]

    ; Header
    if (GUI_ShowHeader) {
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
    if (GUI_ShowFooter) {
        footerH := Round(GUI_FooterHeightPx * scale)
        footerGap := Round(GUI_FooterGapTopPx * scale)
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
        Gdip_DrawCenteredText(g, GUI_EmptyListText, rectX, rectY, rectW, rectH, GUI_MainARGB, gGdip_Res["fMain"], gGdip_Res["fmtCenter"])
    } else if (rowsToDraw > 0) {
        start0 := Win_Wrap0(scrollTop, count)
        i := 0
        yRow := y

        while (i < rowsToDraw && (yRow + RowH <= contentTopY + availH)) {
            idx0 := Win_Wrap0(start0 + i, count)
            idx1 := idx0 + 1
            cur := items[idx1]
            isSel := (idx1 = selIndex)

            if (isSel) {
                Gdip_FillRoundRect(g, GUI_SelARGB, Mx - Round(4 * scale), yRow - Round(2 * scale), wPhys - 2 * Mx + Round(8 * scale), RowH, Rad)
            }

            ix := leftX
            iy := yRow + (RowH - ISize) // 2

            iconDrawn := false
            if (cur.HasOwnProp("iconHicon") && cur.iconHicon) {
                iconDrawn := Gdip_DrawIconFromHicon(g, cur.iconHicon, ix, iy, ISize)
            }
            if (!iconDrawn) {
                Gdip_FillEllipse(g, Gdip_ARGBFromIndex(idx1), ix, iy, ISize, ISize)
            }

            fMainUse := isSel ? gGdip_Res["fMainHi"] : gGdip_Res["fMain"]
            fSubUse := isSel ? gGdip_Res["fSubHi"] : gGdip_Res["fSub"]
            fColUse := isSel ? gGdip_Res["fColHi"] : gGdip_Res["fCol"]
            brMainUse := isSel ? gGdip_Res["brMainHi"] : gGdip_Res["brMain"]
            brSubUse := isSel ? gGdip_Res["brSubHi"] : gGdip_Res["brSub"]
            brColUse := isSel ? gGdip_Res["brColHi"] : gGdip_Res["brCol"]

            title := cur.HasOwnProp("Title") ? cur.Title : ""
            Gdip_DrawText(g, title, textX, yRow + Round(6 * scale), textW, Round(24 * scale), brMainUse, fMainUse, fmtLeft)

            sub := ""
            if (cur.HasOwnProp("processName") && cur.processName != "") {
                sub := cur.processName
            } else if (cur.HasOwnProp("Class")) {
                sub := "Class: " cur.Class
            }
            Gdip_DrawText(g, sub, textX, yRow + Round(28 * scale), textW, Round(18 * scale), brSubUse, fSubUse, fmtLeft)

            for _, col in cols {
                val := ""
                if (cur.HasOwnProp(col.key)) {
                    val := cur.%col.key%
                }
                Gdip_DrawText(g, val, col.x, yRow + Round(10 * scale), col.w, Round(20 * scale), brColUse, fColUse, gGdip_Res["fmt"])
            }

            if (idx1 = gGUI_HoverRow) {
                GUI_DrawActionButtons(g, wPhys, yRow, RowH, scale)
            }

            yRow := yRow + RowH
            i := i + 1
        }
    }

    ; Scrollbar
    if (count > rowsToDraw && rowsToDraw > 0) {
        GUI_DrawScrollbar(g, wPhys, contentTopY, rowsToDraw, RowH, scrollTop, count, scale)
    }

    ; Footer
    if (GUI_ShowFooter) {
        GUI_DrawFooter(g, wPhys, hPhys, scale)
    }
}

; ========================= RESOURCE MANAGEMENT =========================

GUI_EnsureResources(scale) {
    global gGdip_Res, gGdip_ResScale

    if (Abs(gGdip_ResScale - scale) < 0.001 && gGdip_Res.Count) {
        return
    }

    Gdip_DisposeResources()
    Gdip_Startup()

    ; Brushes
    brushes := [
        ["brMain", GUI_MainARGB],
        ["brMainHi", GUI_MainARGBHi],
        ["brSub", GUI_SubARGB],
        ["brSubHi", GUI_SubARGBHi],
        ["brCol", GUI_ColARGB],
        ["brColHi", GUI_ColARGBHi],
        ["brHdr", GUI_HdrARGB],
        ["brHit", 0x01000000],
        ["brFooterText", GUI_FooterTextARGB]
    ]
    for _, b in brushes {
        br := 0
        DllCall("gdiplus\GdipCreateSolidFill", "int", b[2], "ptr*", &br)
        gGdip_Res[b[1]] := br
    }

    ; Fonts
    UnitPixel := 2

    fonts := [
        [GUI_MainFontName, GUI_MainFontSize, GUI_MainFontWeight, "ffMain", "fMain"],
        [GUI_MainFontNameHi, GUI_MainFontSizeHi, GUI_MainFontWeightHi, "ffMainHi", "fMainHi"],
        [GUI_SubFontName, GUI_SubFontSize, GUI_SubFontWeight, "ffSub", "fSub"],
        [GUI_SubFontNameHi, GUI_SubFontSizeHi, GUI_SubFontWeightHi, "ffSubHi", "fSubHi"],
        [GUI_ColFontName, GUI_ColFontSize, GUI_ColFontWeight, "ffCol", "fCol"],
        [GUI_ColFontNameHi, GUI_ColFontSizeHi, GUI_ColFontWeightHi, "ffColHi", "fColHi"],
        [GUI_HdrFontName, GUI_HdrFontSize, GUI_HdrFontWeight, "ffHdr", "fHdr"],
        [GUI_ActionFontName, GUI_ActionFontSize, GUI_ActionFontWeight, "ffAction", "fAction"],
        [GUI_FooterFontName, GUI_FooterFontSize, GUI_FooterFontWeight, "ffFooter", "fFooter"]
    ]
    for _, f in fonts {
        fam := 0
        font := 0
        style := Gdip_FontStyleFromWeight(f[3])
        DllCall("gdiplus\GdipCreateFontFamilyFromName", "wstr", f[1], "ptr", 0, "ptr*", &fam)
        DllCall("gdiplus\GdipCreateFont", "ptr", fam, "float", f[2] * scale, "int", style, "int", UnitPixel, "ptr*", &font)
        gGdip_Res[f[4]] := fam
        gGdip_Res[f[5]] := font
    }

    ; String formats
    StringAlignmentNear := 0
    StringAlignmentCenter := 1
    StringAlignmentFar := 2
    flags := 0x00001000 | 0x00004000

    formats := [
        ["fmt", StringAlignmentNear, StringAlignmentNear],
        ["fmtCenter", StringAlignmentCenter, StringAlignmentNear],
        ["fmtRight", StringAlignmentFar, StringAlignmentNear],
        ["fmtLeft", StringAlignmentNear, StringAlignmentNear],
        ["fmtLeftCol", StringAlignmentNear, StringAlignmentNear],
        ["fmtFooterLeft", StringAlignmentNear, StringAlignmentCenter],
        ["fmtFooterCenter", StringAlignmentCenter, StringAlignmentCenter],
        ["fmtFooterRight", StringAlignmentFar, StringAlignmentCenter]
    ]
    for _, fm in formats {
        fmt := 0
        DllCall("gdiplus\GdipCreateStringFormat", "int", 0, "ushort", 0, "ptr*", &fmt)
        DllCall("gdiplus\GdipSetStringFormatFlags", "ptr", fmt, "int", flags)
        DllCall("gdiplus\GdipSetStringFormatTrimming", "ptr", fmt, "int", 3)
        DllCall("gdiplus\GdipSetStringFormatAlign", "ptr", fmt, "int", fm[2])
        DllCall("gdiplus\GdipSetStringFormatLineAlign", "ptr", fmt, "int", fm[3])
        gGdip_Res[fm[1]] := fmt
    }

    gGdip_ResScale := scale
}

; ========================= ACTION BUTTONS =========================

GUI_DrawActionButtons(g, wPhys, yRow, rowHPhys, scale) {
    global gGUI_HoverBtn

    size := Round(GUI_ActionBtnSizePx * scale)
    if (size < 12) {
        size := 12
    }
    gap := Round(GUI_ActionBtnGapPx * scale)
    if (gap < 2) {
        gap := 2
    }
    rad := Round(GUI_ActionBtnRadiusPx * scale)
    if (rad < 2) {
        rad := 2
    }
    marR := Round(GUI_MarginX * scale)

    btnX := wPhys - marR - size
    btnY := yRow + (rowHPhys - size) // 2

    if (GUI_ShowCloseButton) {
        hovered := (gGUI_HoverBtn = "close")
        bgCol := hovered ? GUI_CloseButtonBGHoverARGB : GUI_CloseButtonBGARGB
        txCol := hovered ? GUI_CloseButtonTextHoverARGB : GUI_CloseButtonTextARGB
        Gdip_FillRoundRect(g, bgCol, btnX, btnY, size, size, rad)
        if (GUI_CloseButtonBorderPx > 0) {
            Gdip_StrokeRoundRect(g, GUI_CloseButtonBorderARGB, btnX + 0.5, btnY + 0.5, size - 1, size - 1, rad, Round(GUI_CloseButtonBorderPx * scale))
        }
        Gdip_DrawCenteredText(g, GUI_CloseButtonGlyph, btnX, btnY, size, size, txCol, gGdip_Res["fAction"], gGdip_Res["fmtCenter"])
        btnX := btnX - (size + gap)
    }

    if (GUI_ShowKillButton) {
        hovered := (gGUI_HoverBtn = "kill")
        bgCol := hovered ? GUI_KillButtonBGHoverARGB : GUI_KillButtonBGARGB
        txCol := hovered ? GUI_KillButtonTextHoverARGB : GUI_KillButtonTextARGB
        Gdip_FillRoundRect(g, bgCol, btnX, btnY, size, size, rad)
        if (GUI_KillButtonBorderPx > 0) {
            Gdip_StrokeRoundRect(g, GUI_KillButtonBorderARGB, btnX + 0.5, btnY + 0.5, size - 1, size - 1, rad, Round(GUI_KillButtonBorderPx * scale))
        }
        Gdip_DrawCenteredText(g, GUI_KillButtonGlyph, btnX, btnY, size, size, txCol, gGdip_Res["fAction"], gGdip_Res["fmtCenter"])
        btnX := btnX - (size + gap)
    }

    if (GUI_ShowBlacklistButton) {
        hovered := (gGUI_HoverBtn = "blacklist")
        bgCol := hovered ? GUI_BlacklistButtonBGHoverARGB : GUI_BlacklistButtonBGARGB
        txCol := hovered ? GUI_BlacklistButtonTextHoverARGB : GUI_BlacklistButtonTextARGB
        Gdip_FillRoundRect(g, bgCol, btnX, btnY, size, size, rad)
        if (GUI_BlacklistButtonBorderPx > 0) {
            Gdip_StrokeRoundRect(g, GUI_BlacklistButtonBorderARGB, btnX + 0.5, btnY + 0.5, size - 1, size - 1, rad, Round(GUI_BlacklistButtonBorderPx * scale))
        }
        Gdip_DrawCenteredText(g, GUI_BlacklistButtonGlyph, btnX, btnY, size, size, txCol, gGdip_Res["fAction"], gGdip_Res["fmtCenter"])
    }
}

; ========================= SCROLLBAR =========================

GUI_DrawScrollbar(g, wPhys, contentTopY, rowsDrawn, rowHPhys, scrollTop, count, scale) {
    if (!GUI_ScrollBarEnabled || count <= 0 || rowsDrawn <= 0 || rowHPhys <= 0) {
        return
    }

    trackH := rowsDrawn * rowHPhys
    if (trackH <= 0) {
        return
    }

    trackW := Round(GUI_ScrollBarWidthPx * scale)
    if (trackW < 2) {
        trackW := 2
    }
    marR := Round(GUI_ScrollBarMarginRightPx * scale)
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

    if (GUI_ScrollBarGutterEnabled) {
        Gdip_FillRoundRect(g, GUI_ScrollBarGutterARGB, x, y, trackW, trackH, r)
    }

    if (y2 <= yEnd) {
        Gdip_FillRoundRect(g, GUI_ScrollBarThumbARGB, x, y1, trackW, thumbH, r)
    } else {
        h1 := yEnd - y1
        if (h1 > 0) {
            Gdip_FillRoundRect(g, GUI_ScrollBarThumbARGB, x, y1, trackW, h1, r)
        }
        h2 := y2 - yEnd
        if (h2 > 0) {
            Gdip_FillRoundRect(g, GUI_ScrollBarThumbARGB, x, y, trackW, h2, r)
        }
    }
}

; ========================= FOOTER =========================

GUI_DrawFooter(g, wPhys, hPhys, scale) {
    global gGUI_FooterText, gGUI_LeftArrowRect, gGUI_RightArrowRect

    if (!GUI_ShowFooter) {
        return
    }

    fh := Round(GUI_FooterHeightPx * scale)
    if (fh < 1) {
        fh := 1
    }
    mx := Round(GUI_MarginX * scale)
    my := Round(GUI_MarginY * scale)

    fx := mx
    fy := hPhys - my - fh
    fw := wPhys - 2 * mx
    fr := Round(GUI_FooterBGRadius * scale)
    if (fr < 0) {
        fr := 0
    }

    ; Draw footer background
    Gdip_FillRoundRect(g, GUI_FooterBGARGB, fx, fy, fw, fh, fr)
    if (GUI_FooterBorderPx > 0) {
        Gdip_StrokeRoundRect(g, GUI_FooterBorderARGB, fx + 0.5, fy + 0.5, fw - 1, fh - 1, fr, Round(GUI_FooterBorderPx * scale))
    }

    pad := Round(GUI_FooterPaddingX * scale)
    if (pad < 0) {
        pad := 0
    }

    ; Arrow dimensions
    arrowW := Round(24 * scale)  ; Width for arrow hit area
    arrowPad := Round(8 * scale)  ; Padding inside footer

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
    rfLeft := Buffer(16, 0)
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
    rfRight := Buffer(16, 0)
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

    rfCenter := Buffer(16, 0)
    NumPut("Float", textX, rfCenter, 0)
    NumPut("Float", fy, rfCenter, 4)
    NumPut("Float", textW, rfCenter, 8)
    NumPut("Float", fh, rfCenter, 12)
    DllCall("gdiplus\GdipDrawString", "ptr", g, "wstr", gGUI_FooterText, "int", -1, "ptr", gGdip_Res["fFooter"], "ptr", rfCenter.Ptr, "ptr", gGdip_Res["fmtFooterCenter"], "ptr", gGdip_Res["brFooterText"])
}
