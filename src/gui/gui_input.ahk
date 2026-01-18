; Alt-Tabby GUI - Input Handling
; Handles mouse events, selection movement, hover detection, and actions
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals/functions

; ========================= SELECTION MOVEMENT =========================

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

; ========================= HOVER DETECTION =========================

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
    global gGUI_Items, gGUI_Sel, gGUI_OverlayH, gGUI_OverlayVisible, gGUI_ScrollTop
    global gGUI_LeftArrowRect, gGUI_RightArrowRect, gGUI_State

    ; Don't process clicks if overlay isn't visible
    if (!gGUI_OverlayVisible) {
        return
    }

    ; Check footer arrow clicks (only when GUI is active)
    if (gGUI_State = "ACTIVE") {
        ; Left arrow click
        if (x >= gGUI_LeftArrowRect.x && x < gGUI_LeftArrowRect.x + gGUI_LeftArrowRect.w
            && y >= gGUI_LeftArrowRect.y && y < gGUI_LeftArrowRect.y + gGUI_LeftArrowRect.h) {
            GUI_ToggleWorkspaceMode()
            return
        }
        ; Right arrow click
        if (x >= gGUI_RightArrowRect.x && x < gGUI_RightArrowRect.x + gGUI_RightArrowRect.w
            && y >= gGUI_RightArrowRect.y && y < gGUI_RightArrowRect.y + gGUI_RightArrowRect.h) {
            GUI_ToggleWorkspaceMode()
            return
        }
    }

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
    global gGUI_OverlayH, gGUI_OverlayVisible, gGUI_HoverRow, gGUI_HoverBtn, gGUI_Items, gGUI_Sel

    if (hwnd != gGUI_OverlayH) {
        return 0
    }

    ; Don't process mouse moves if overlay isn't visible
    if (!gGUI_OverlayVisible) {
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
    global gGUI_OverlayVisible

    ; Don't process wheel if overlay isn't visible
    if (!gGUI_OverlayVisible) {
        return
    }

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
