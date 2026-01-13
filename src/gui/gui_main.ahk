#Requires AutoHotkey v2.0
#SingleInstance Force

; Alt-Tabby GUI - Integrated with WindowStore and Interceptor

#Include %A_ScriptDir%\..\shared\config.ahk
#Include %A_ScriptDir%\..\shared\json.ahk
#Include %A_ScriptDir%\..\shared\ipc_pipe.ahk
#Include %A_ScriptDir%\..\interceptor\interceptor_ipc.ahk
#Include %A_ScriptDir%\gui_config.ahk
#Include %A_ScriptDir%\gui_gdip.ahk
#Include %A_ScriptDir%\gui_win.ahk

; ========================= GLOBAL STATE =========================

global gGUI_Revealed := false
global gGUI_HoverRow := 0
global gGUI_HoverBtn := ""
global gGUI_FooterText := "All Windows"

global gGUI_StoreClient := 0
global gGUI_StoreConnected := false
global gGUI_StoreRev := -1

global gGUI_OverlayVisible := false
global gGUI_Base := 0
global gGUI_Overlay := 0
global gGUI_BaseH := 0
global gGUI_OverlayH := 0
global gGUI_Items := []
global gGUI_Sel := 1
global gGUI_ScrollTop := 0
global gGUI_LastRowsDesired := -1

; ========================= INITIALIZATION =========================

GUI_Main_Init() {
    global gGUI_StoreClient, StorePipeName

    Win_InitDpiAwareness()
    Gdip_Startup()

    ; Listen for interceptor events
    TABBY_IPC_Listen(GUI_OnInterceptorEvent)

    ; Connect to WindowStore
    gGUI_StoreClient := IPC_PipeClient_Connect(StorePipeName, GUI_OnStoreMessage)
    if (gGUI_StoreClient.hPipe) {
        hello := { type: IPC_MSG_HELLO, projectionOpts: { sort: "MRU", columns: "items" } }
        IPC_PipeClient_Send(gGUI_StoreClient, JXON_Dump(hello))
    }
}

; ========================= IPC HANDLERS =========================

GUI_OnInterceptorEvent(evCode, flags, lParam) {
    global gGUI_OverlayVisible, gGUI_Items, gGUI_Sel

    if (evCode = TABBY_EV_TAB_STEP) {
        shiftHeld := (flags & TABBY_FLAG_SHIFT) != 0

        if (!gGUI_OverlayVisible) {
            GUI_RequestSnapshot()
            GUI_ShowOverlay()
        }

        delta := shiftHeld ? -1 : 1
        GUI_MoveSelection(delta)
    } else if (evCode = TABBY_EV_ALT_UP) {
        if (gGUI_OverlayVisible) {
            GUI_ActivateSelected()
            GUI_HideOverlay()
        }
    }
}

GUI_OnStoreMessage(line, hPipe := 0) {
    global gGUI_StoreConnected, gGUI_StoreRev, gGUI_Items, gGUI_Sel
    global gGUI_OverlayVisible, gGUI_OverlayH, gGUI_FooterText

    obj := ""
    try {
        obj := JXON_Load(line)
    } catch {
        return
    }

    if (!IsObject(obj) || !obj.Has("type")) {
        return
    }

    type := obj["type"]

    if (type = IPC_MSG_HELLO_ACK) {
        gGUI_StoreConnected := true
        if (obj.Has("rev")) {
            gGUI_StoreRev := obj["rev"]
        }
        return
    }

    if (type = IPC_MSG_SNAPSHOT || type = IPC_MSG_PROJECTION) {
        if (obj.Has("payload") && obj["payload"].Has("items")) {
            gGUI_Items := GUI_ConvertStoreItems(obj["payload"]["items"])
            if (gGUI_Sel > gGUI_Items.Length && gGUI_Items.Length > 0) {
                gGUI_Sel := gGUI_Items.Length
            }
            if (gGUI_Sel < 1 && gGUI_Items.Length > 0) {
                gGUI_Sel := 1
            }

            if (obj["payload"].Has("meta") && obj["payload"]["meta"].Has("currentWSName")) {
                wsName := obj["payload"]["meta"]["currentWSName"]
                if (wsName != "") {
                    gGUI_FooterText := wsName
                }
            }

            if (gGUI_OverlayVisible && gGUI_OverlayH) {
                GUI_Repaint()
            }
        }
        if (obj.Has("rev")) {
            gGUI_StoreRev := obj["rev"]
        }
        return
    }
}

GUI_ConvertStoreItems(items) {
    result := []
    for _, item in items {
        hwnd := item.Has("hwnd") ? item["hwnd"] : 0
        result.Push({
            hwnd: hwnd,
            Title: item.Has("title") ? item["title"] : "",
            Class: item.Has("class") ? item["class"] : "",
            HWND: Format("0x{:X}", hwnd),
            PID: item.Has("pid") ? "" item["pid"] : "",
            WS: item.Has("workspaceName") ? item["workspaceName"] : "",
            processName: item.Has("processName") ? item["processName"] : "",
            iconHicon: item.Has("iconHicon") ? item["iconHicon"] : 0
        })
    }
    return result
}

GUI_RequestSnapshot() {
    global gGUI_StoreClient
    if (!gGUI_StoreClient || !gGUI_StoreClient.hPipe) {
        return
    }
    req := { type: IPC_MSG_SNAPSHOT_REQUEST, projectionOpts: { sort: "MRU", columns: "items" } }
    IPC_PipeClient_Send(gGUI_StoreClient, JXON_Dump(req))
}

GUI_ActivateSelected() {
    global gGUI_Items, gGUI_Sel
    if (gGUI_Sel < 1 || gGUI_Sel > gGUI_Items.Length) {
        return
    }
    item := gGUI_Items[gGUI_Sel]
    hwnd := item.hwnd
    if (!hwnd) {
        return
    }

    try {
        if (WinExist("ahk_id " hwnd)) {
            if (DllCall("user32\IsIconic", "ptr", hwnd, "int")) {
                DllCall("user32\ShowWindow", "ptr", hwnd, "int", 9)
            }
            DllCall("user32\SetForegroundWindow", "ptr", hwnd)
        }
    }
}

; ========================= OVERLAY MANAGEMENT =========================

GUI_ShowOverlay() {
    global gGUI_OverlayVisible, gGUI_Base, gGUI_BaseH, gGUI_Overlay, gGUI_OverlayH
    global gGUI_Items, gGUI_Sel, gGUI_ScrollTop, gGUI_Revealed

    if (gGUI_OverlayVisible) {
        return
    }

    gGUI_Sel := 1
    gGUI_ScrollTop := 0
    gGUI_Revealed := false

    try {
        gGUI_Base.Show("NA")
    }

    rowsDesired := GUI_ComputeRowsToShow(gGUI_Items.Length)
    GUI_ResizeToRows(rowsDesired)
    GUI_Repaint()

    try {
        gGUI_Overlay.Show("NA")
    }
    Win_DwmFlush()

    gGUI_OverlayVisible := true
}

GUI_HideOverlay() {
    global gGUI_OverlayVisible, gGUI_Base, gGUI_Overlay, gGUI_Revealed

    if (!gGUI_OverlayVisible) {
        return
    }

    try {
        gGUI_Overlay.Hide()
    }
    try {
        gGUI_Base.Hide()
    }
    gGUI_OverlayVisible := false
    gGUI_Revealed := false
}

GUI_ComputeRowsToShow(count) {
    if (count >= GUI_RowsVisibleMax) {
        return GUI_RowsVisibleMax
    }
    if (count > GUI_RowsVisibleMin) {
        return count
    }
    return GUI_RowsVisibleMin
}

GUI_HeaderBlockDip() {
    if (GUI_ShowHeader) {
        return 32
    }
    return 0
}

GUI_FooterBlockDip() {
    if (GUI_ShowFooter) {
        return GUI_FooterGapTopPx + GUI_FooterHeightPx
    }
    return 0
}

GUI_GetVisibleRows() {
    global gGUI_OverlayH

    ox := 0
    oy := 0
    owPhys := 0
    ohPhys := 0
    Win_GetRectPhys(gGUI_OverlayH, &ox, &oy, &owPhys, &ohPhys)

    scale := Win_GetScaleForWindow(gGUI_OverlayH)
    ohDip := ohPhys / scale

    headerTopDip := GUI_MarginY + GUI_HeaderBlockDip()
    footerDip := GUI_FooterBlockDip()
    usableDip := ohDip - headerTopDip - GUI_MarginY - footerDip

    if (usableDip < GUI_RowHeight) {
        return 0
    }
    return Floor(usableDip / GUI_RowHeight)
}

; ========================= SELECTION =========================

GUI_MoveSelection(delta) {
    global gGUI_Sel, gGUI_Items, gGUI_ScrollTop, gGUI_OverlayH

    if (gGUI_Items.Length = 0 || delta = 0) {
        return
    }

    count := gGUI_Items.Length
    vis := GUI_GetVisibleRows()
    if (vis <= 0) {
        vis := 1
    }
    if (vis > count) {
        vis := count
    }

    if (GUI_ScrollKeepHighlightOnTop) {
        if (delta > 0) {
            gGUI_Sel := Win_Wrap1(gGUI_Sel + 1, count)
        } else {
            gGUI_Sel := Win_Wrap1(gGUI_Sel - 1, count)
        }
        gGUI_ScrollTop := gGUI_Sel - 1
    } else {
        top0 := gGUI_ScrollTop
        if (delta > 0) {
            gGUI_Sel := Win_Wrap1(gGUI_Sel + 1, count)
            sel0 := gGUI_Sel - 1
            pos := Win_Wrap0(sel0 - top0, count)
            if (pos >= vis || pos = vis - 1) {
                gGUI_ScrollTop := sel0 - (vis - 1)
            }
        } else {
            gGUI_Sel := Win_Wrap1(gGUI_Sel - 1, count)
            sel0 := gGUI_Sel - 1
            pos := Win_Wrap0(sel0 - top0, count)
            if (pos >= vis || pos = 0) {
                gGUI_ScrollTop := sel0
            }
        }
    }

    GUI_RecalcHover()
    GUI_Repaint()
}

GUI_RecalcHover() {
    global gGUI_OverlayH, gGUI_HoverRow, gGUI_HoverBtn

    if (!gGUI_OverlayH) {
        return false
    }

    pt := Buffer(8, 0)
    if (!DllCall("user32\GetCursorPos", "ptr", pt)) {
        return false
    }
    if (!DllCall("user32\ScreenToClient", "ptr", gGUI_OverlayH, "ptr", pt.Ptr)) {
        return false
    }

    x := NumGet(pt, 0, "Int")
    y := NumGet(pt, 4, "Int")

    act := ""
    idx := 0
    GUI_DetectActionAtPoint(x, y, &act, &idx)

    changed := (idx != gGUI_HoverRow || act != gGUI_HoverBtn)
    gGUI_HoverRow := idx
    gGUI_HoverBtn := act
    return changed
}

GUI_DetectActionAtPoint(xPhys, yPhys, &action, &idx1) {
    global gGUI_Items, gGUI_ScrollTop, gGUI_OverlayH

    action := ""
    idx1 := 0
    count := gGUI_Items.Length
    if (count <= 0) {
        return
    }

    scale := Win_GetScaleForWindow(gGUI_OverlayH)
    RowH := Round(GUI_RowHeight * scale)
    if (RowH < 1) {
        RowH := 1
    }
    My := Round(GUI_MarginY * scale)
    hdr := Round(GUI_HeaderBlockDip() * scale)
    topY := My + hdr

    if (yPhys < topY) {
        return
    }

    vis := GUI_GetVisibleRows()
    if (vis <= 0) {
        return
    }

    rel := yPhys - topY
    rowVis := Floor(rel / RowH) + 1
    if (rowVis < 1 || rowVis > vis) {
        return
    }

    idx0 := Win_Wrap0(gGUI_ScrollTop + (rowVis - 1), count)
    idx1 := idx0 + 1

    size := Round(GUI_ActionBtnSizePx * scale)
    if (size < 12) {
        size := 12
    }
    gap := Round(GUI_ActionBtnGapPx * scale)
    if (gap < 2) {
        gap := 2
    }
    marR := Round(GUI_MarginX * scale)

    ox := 0
    oy := 0
    ow := 0
    oh := 0
    Win_GetRectPhys(gGUI_OverlayH, &ox, &oy, &ow, &oh)

    btnX := ow - marR - size
    btnY := topY + (rowVis - 1) * RowH + (RowH - size) // 2

    if (GUI_ShowCloseButton && xPhys >= btnX && xPhys < btnX + size && yPhys >= btnY && yPhys < btnY + size) {
        action := "close"
        return
    }
    btnX := btnX - (size + gap)
    if (GUI_ShowKillButton && xPhys >= btnX && xPhys < btnX + size && yPhys >= btnY && yPhys < btnY + size) {
        action := "kill"
        return
    }
    btnX := btnX - (size + gap)
    if (GUI_ShowBlacklistButton && xPhys >= btnX && xPhys < btnX + size && yPhys >= btnY && yPhys < btnY + size) {
        action := "blacklist"
        return
    }
}

; ========================= PAINTING =========================

GUI_Repaint() {
    global gGUI_BaseH, gGUI_OverlayH, gGUI_Items, gGUI_Sel, gGUI_LastRowsDesired, gGUI_Revealed

    count := gGUI_Items.Length
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
    GUI_PaintOverlay(gGUI_Items, gGUI_Sel, phW, phH, scale)

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

GUI_ResizeToRows(rowsToShow) {
    global gGUI_Base, gGUI_BaseH, gGUI_Overlay, gGUI_OverlayH

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
    Win_ApplyRoundRegion(gGUI_BaseH, GUI_CornerRadiusPx, wDip, hDip)
    Win_DwmFlush()
}

GUI_GetWindowRect(&x, &y, &w, &h, rowsToShow, hWnd) {
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

    pct := GUI_ScreenWidthPct
    if (pct <= 0) {
        pct := 0.10
    }
    if (pct > 1.0) {
        pct := pct / 100.0
    }

    w := Round(waW_dip * pct)
    h := GUI_MarginY + GUI_HeaderBlockDip() + rowsToShow * GUI_RowHeight + GUI_FooterBlockDip() + GUI_MarginY

    x := Round(left_dip + (waW_dip - w) / 2)
    y := Round(top_dip + (waH_dip - h) / 2)
}

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

GUI_DrawFooter(g, wPhys, hPhys, scale) {
    global gGUI_FooterText

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

    Gdip_FillRoundRect(g, GUI_FooterBGARGB, fx, fy, fw, fh, fr)
    if (GUI_FooterBorderPx > 0) {
        Gdip_StrokeRoundRect(g, GUI_FooterBorderARGB, fx + 0.5, fy + 0.5, fw - 1, fh - 1, fr, Round(GUI_FooterBorderPx * scale))
    }

    pad := Round(GUI_FooterPaddingX * scale)
    if (pad < 0) {
        pad := 0
    }
    tx := fx + pad
    tw := fw - 2 * pad

    t := StrLower(Trim(GUI_FooterTextAlign))
    fmt := gGdip_Res["fmtFooterCenter"]
    if (t = "left") {
        fmt := gGdip_Res["fmtFooterLeft"]
    } else if (t = "right") {
        fmt := gGdip_Res["fmtFooterRight"]
    }

    rf := Buffer(16, 0)
    NumPut("Float", tx, rf, 0)
    NumPut("Float", fy, rf, 4)
    NumPut("Float", tw, rf, 8)
    NumPut("Float", fh, rf, 12)

    DllCall("gdiplus\GdipDrawString", "ptr", g, "wstr", gGUI_FooterText, "int", -1, "ptr", gGdip_Res["fFooter"], "ptr", rf.Ptr, "ptr", fmt, "ptr", gGdip_Res["brFooterText"])
}

; ========================= ACTIONS =========================

GUI_PerformAction(action, idx1 := 0) {
    global gGUI_Items, gGUI_Sel

    if (idx1 = 0) {
        idx1 := gGUI_Sel
    }
    if (idx1 < 1 || idx1 > gGUI_Items.Length) {
        return
    }

    cur := gGUI_Items[idx1]

    if (action = "close") {
        hwnd := cur.hwnd
        if (hwnd && WinExist("ahk_id " hwnd)) {
            PostMessage(0x0010, 0, 0, , "ahk_id " hwnd)
        }
        GUI_RemoveItemAt(idx1)
        return
    }

    if (action = "kill") {
        pid := cur.HasOwnProp("PID") ? cur.PID : ""
        ttl := cur.HasOwnProp("Title") ? cur.Title : "window"
        if (Win_ConfirmTopmost("Terminate process " pid " for '" ttl "'?", "Confirm")) {
            if (pid != "") {
                try {
                    ProcessClose(pid)
                }
            }
            GUI_RemoveItemAt(idx1)
        }
        return
    }

    if (action = "blacklist") {
        ttl := cur.HasOwnProp("Title") ? cur.Title : "window"
        cls := cur.HasOwnProp("Class") ? cur.Class : "?"
        if (Win_ConfirmTopmost("Blacklist '" ttl "' (class '" cls "')?", "Confirm")) {
            GUI_RemoveItemAt(idx1)
        }
        return
    }
}

GUI_RemoveItemAt(idx1) {
    global gGUI_Items, gGUI_Sel, gGUI_ScrollTop, gGUI_OverlayH

    if (idx1 < 1 || idx1 > gGUI_Items.Length) {
        return
    }
    gGUI_Items.RemoveAt(idx1)

    if (gGUI_Items.Length = 0) {
        gGUI_Sel := 1
        gGUI_ScrollTop := 0
    } else {
        if (gGUI_Sel > gGUI_Items.Length) {
            gGUI_Sel := gGUI_Items.Length
        }
    }

    GUI_RecalcHover()
    GUI_Repaint()
}

; ========================= MOUSE HANDLERS =========================

GUI_OnClick(x, y) {
    global gGUI_Items, gGUI_Sel, gGUI_OverlayH, gGUI_ScrollTop

    act := ""
    idx := 0
    GUI_DetectActionAtPoint(x, y, &act, &idx)
    if (act != "") {
        GUI_PerformAction(act, idx)
        return
    }

    count := gGUI_Items.Length
    if (count = 0) {
        return
    }

    scale := Win_GetScaleForWindow(gGUI_OverlayH)
    yDip := Round(y / scale)

    rowsTopDip := GUI_MarginY + GUI_HeaderBlockDip()
    if (yDip < rowsTopDip) {
        return
    }

    vis := GUI_GetVisibleRows()
    if (vis <= 0) {
        return
    }
    rowsDrawn := vis
    if (rowsDrawn > count) {
        rowsDrawn := count
    }

    idxVisible := ((yDip - rowsTopDip) // GUI_RowHeight) + 1
    if (idxVisible < 1) {
        idxVisible := 1
    }
    if (idxVisible > rowsDrawn) {
        return
    }

    top0 := gGUI_ScrollTop
    idx0 := Win_Wrap0(top0 + (idxVisible - 1), count)
    gGUI_Sel := idx0 + 1

    if (GUI_ScrollKeepHighlightOnTop) {
        gGUI_ScrollTop := gGUI_Sel - 1
    }

    GUI_Repaint()
}

GUI_OnMouseMove(wParam, lParam, msg, hwnd) {
    global gGUI_OverlayH, gGUI_HoverRow, gGUI_HoverBtn, gGUI_Items, gGUI_Sel

    if (hwnd != gGUI_OverlayH) {
        return 0
    }

    x := lParam & 0xFFFF
    y := (lParam >> 16) & 0xFFFF

    act := ""
    idx := 0
    GUI_DetectActionAtPoint(x, y, &act, &idx)

    prevRow := gGUI_HoverRow
    prevBtn := gGUI_HoverBtn
    gGUI_HoverRow := idx
    gGUI_HoverBtn := act

    if (gGUI_HoverRow != prevRow || gGUI_HoverBtn != prevBtn) {
        GUI_Repaint()
    }
    return 0
}

GUI_OnWheel(wParam, lParam) {
    delta := (wParam >> 16) & 0xFFFF
    if (delta >= 0x8000) {
        delta := delta - 0x10000
    }
    step := -1
    if (delta < 0) {
        step := 1
    }

    if (GUI_ScrollKeepHighlightOnTop) {
        GUI_MoveSelection(step)
    } else {
        GUI_ScrollBy(step)
    }
}

GUI_ScrollBy(step) {
    global gGUI_ScrollTop, gGUI_Items, gGUI_OverlayH, gGUI_Sel

    vis := GUI_GetVisibleRows()
    if (vis <= 0) {
        return
    }
    count := gGUI_Items.Length
    if (count <= 0) {
        return
    }

    visEff := vis
    if (visEff > count) {
        visEff := count
    }
    if (count <= visEff) {
        return
    }

    gGUI_ScrollTop := Win_Wrap0(gGUI_ScrollTop + step, count)
    GUI_RecalcHover()
    GUI_Repaint()
}

; ========================= WINDOW CREATION =========================

GUI_CreateBase() {
    global gGUI_Base, gGUI_BaseH, gGUI_Items

    opts := "+AlwaysOnTop -Caption"

    rowsDesired := GUI_ComputeRowsToShow(gGUI_Items.Length)

    left := 0
    top := 0
    right := 0
    bottom := 0
    MonitorGetWorkArea(0, &left, &top, &right, &bottom)
    waW_phys := right - left
    waH_phys := bottom - top

    monScale := Win_GetMonitorScale(left, top, right, bottom)

    pct := GUI_ScreenWidthPct
    if (pct <= 0) {
        pct := 0.10
    }
    if (pct > 1.0) {
        pct := pct / 100.0
    }

    waW_dip := waW_phys / monScale
    waH_dip := waH_phys / monScale
    left_dip := left / monScale
    top_dip := top / monScale

    winW := Round(waW_dip * pct)
    winH := GUI_MarginY + GUI_HeaderBlockDip() + rowsDesired * GUI_RowHeight + GUI_FooterBlockDip() + GUI_MarginY
    winX := Round(left_dip + (waW_dip - winW) / 2)
    winY := Round(top_dip + (waH_dip - winH) / 2)

    gGUI_Base := Gui(opts, "Alt-Tabby")
    gGUI_Base.Show("Hide w" winW " h" winH)
    gGUI_BaseH := gGUI_Base.Hwnd

    curX := 0
    curY := 0
    curW := 0
    curH := 0
    Win_GetRectPhys(gGUI_BaseH, &curX, &curY, &curW, &curH)

    waL := 0
    waT := 0
    waR := 0
    waB := 0
    Win_GetWorkAreaFromHwnd(gGUI_BaseH, &waL, &waT, &waR, &waB)
    waW := waR - waL
    waH := waB - waT

    tgtX := waL + (waW - curW) // 2
    tgtY := waT + (waH - curH) // 2
    Win_SetPosPhys(gGUI_BaseH, tgtX, tgtY, curW, curH)

    Win_EnableDarkTitleBar(gGUI_BaseH)
    Win_SetCornerPreference(gGUI_BaseH, 2)
    Win_ForceNoLayered(gGUI_BaseH)
    Win_ApplyRoundRegion(gGUI_BaseH, GUI_CornerRadiusPx, winW, winH)
    Win_ApplyAcrylic(gGUI_BaseH, GUI_AcrylicAlpha, GUI_AcrylicBaseRgb)
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

; ========================= MAIN =========================

GUI_Main_Init()

; DPI change handler
OnMessage(0x02E0, (wParam, lParam, msg, hwnd) => (gGdip_ResScale := 0.0, 0))

; Create windows
GUI_CreateBase()
gGUI_Sel := 1
gGUI_ScrollTop := 0
GUI_CreateOverlay()

; Start hidden
gGUI_OverlayVisible := false
gGUI_Revealed := false

; Mouse handlers
OnMessage(0x0201, (wParam, lParam, msg, hwnd) => (hwnd = gGUI_OverlayH ? (GUI_OnClick(lParam & 0xFFFF, (lParam >> 16) & 0xFFFF), 0) : 0))
OnMessage(0x020A, (wParam, lParam, msg, hwnd) => (hwnd = gGUI_OverlayH ? (GUI_OnWheel(wParam, lParam), 0) : 0))
OnMessage(0x0200, (wParam, lParam, msg, hwnd) => (hwnd = gGUI_OverlayH ? GUI_OnMouseMove(wParam, lParam, msg, hwnd) : 0))

Persistent()
