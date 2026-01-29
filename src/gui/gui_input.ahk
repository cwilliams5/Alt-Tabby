; Alt-Tabby GUI - Input Handling
; Handles mouse events, selection movement, hover detection, and actions
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals/functions

; ========================= DISPLAY ITEMS HELPER =========================

; Returns the correct items array based on GUI state
; Paint and input must use the same array for consistent behavior
; During ACTIVE state with workspace filtering, use gGUI_FrozenItems
; Otherwise use gGUI_Items (live data from store)
_GUI_GetDisplayItems() {
    global gGUI_State, gGUI_Items, gGUI_FrozenItems
    return (gGUI_State = "ACTIVE") ? gGUI_FrozenItems : gGUI_Items
}

; ========================= SELECTION MOVEMENT =========================

GUI_MoveSelection(delta) {
    global gGUI_Sel, gGUI_ScrollTop, gGUI_OverlayH, cfg

    items := _GUI_GetDisplayItems()
    if (items.Length = 0 || delta = 0) {
        return
    }

    count := items.Length
    vis := GUI_GetVisibleRows()
    if (vis <= 0) {
        vis := 1
    }
    if (vis > count) {
        vis := count
    }

    if (cfg.GUI_ScrollKeepHighlightOnTop) {
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

    ; Check if mouse is inside the GUI window bounds
    ; If outside, clear hover state
    ox := 0, oy := 0, ow := 0, oh := 0
    Win_GetRectPhys(gGUI_OverlayH, &ox, &oy, &ow, &oh)
    if (x < 0 || y < 0 || x >= ow || y >= oh) {
        ; Mouse is outside the window
        if (gGUI_HoverRow != 0 || gGUI_HoverBtn != "") {
            gGUI_HoverRow := 0
            gGUI_HoverBtn := ""
            return true  ; Changed
        }
        return false
    }

    act := ""
    idx := 0
    GUI_DetectActionAtPoint(x, y, &act, &idx)

    changed := (idx != gGUI_HoverRow || act != gGUI_HoverBtn)
    gGUI_HoverRow := idx
    gGUI_HoverBtn := act
    return changed
}

GUI_DetectActionAtPoint(xPhys, yPhys, &action, &idx1) {
    global gGUI_ScrollTop, gGUI_OverlayH, cfg

    action := ""
    idx1 := 0
    items := _GUI_GetDisplayItems()
    count := items.Length
    if (count <= 0) {
        return
    }

    scale := Win_GetScaleForWindow(gGUI_OverlayH)
    RowH := Round(cfg.GUI_RowHeight * scale)
    if (RowH < 1) {
        RowH := 1
    }
    My := Round(cfg.GUI_MarginY * scale)
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

    metrics := _GUI_GetActionBtnMetrics(scale)
    size := metrics.size
    gap := metrics.gap
    marR := Round(cfg.GUI_MarginX * scale)

    ox := 0
    oy := 0
    ow := 0
    oh := 0
    Win_GetRectPhys(gGUI_OverlayH, &ox, &oy, &ow, &oh)

    btnX := ow - marR - size
    btnY := topY + (rowVis - 1) * RowH + (RowH - size) // 2

    if (cfg.GUI_ShowCloseButton && xPhys >= btnX && xPhys < btnX + size && yPhys >= btnY && yPhys < btnY + size) {
        action := "close"
        return
    }
    btnX := btnX - (size + gap)
    if (cfg.GUI_ShowKillButton && xPhys >= btnX && xPhys < btnX + size && yPhys >= btnY && yPhys < btnY + size) {
        action := "kill"
        return
    }
    btnX := btnX - (size + gap)
    if (cfg.GUI_ShowBlacklistButton && xPhys >= btnX && xPhys < btnX + size && yPhys >= btnY && yPhys < btnY + size) {
        action := "blacklist"
        return
    }
}

; ========================= ACTIONS =========================

GUI_PerformAction(action, idx1 := 0) {
    global gGUI_Sel, gGUI_StoreClient, IPC_MSG_RELOAD_BLACKLIST

    if (idx1 = 0) {
        idx1 := gGUI_Sel
    }
    items := _GUI_GetDisplayItems()
    if (idx1 < 1 || idx1 > items.Length) {
        return
    }

    cur := items[idx1]

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
        pname := cur.HasOwnProp("processName") ? cur.processName : ""

        ; Build detailed confirmation message
        msg := "Kill process?"
        msg .= "`n`nWindow: " SubStr(ttl, 1, 50) (StrLen(ttl) > 50 ? "..." : "")
        if (pname != "") {
            msg .= "`nProcess: " pname
        }
        msg .= "`nPID: " pid

        if (Win_ConfirmTopmost(msg, "Confirm Kill")) {
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
        ttl := cur.HasOwnProp("Title") ? cur.Title : ""
        cls := cur.HasOwnProp("Class") ? cur.Class : ""

        if (cls = "" && ttl = "") {
            return
        }

        ; Show blacklist options dialog
        choice := _GUI_ShowBlacklistDialog(cls, ttl)
        if (choice = "") {
            return
        }

        ; Write to blacklist file based on choice
        success := false
        if (choice = "class" && cls != "") {
            success := Blacklist_AddClass(cls)
        } else if (choice = "title" && ttl != "") {
            success := Blacklist_AddTitle(ttl)
        } else if (choice = "pair" && cls != "" && ttl != "") {
            success := Blacklist_AddPair(cls, ttl)
        }

        if (!success) {
            return
        }

        ; Send reload message to store via IPC
        if (IsObject(gGUI_StoreClient) && gGUI_StoreClient.hPipe) {
            msg := { type: IPC_MSG_RELOAD_BLACKLIST }
            IPC_PipeClient_Send(gGUI_StoreClient, JSON.Dump(msg))
        }

        ; Remove item from local display
        GUI_RemoveItemAt(idx1)
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
    global gGUI_Items, gGUI_Sel, gGUI_OverlayH, gGUI_OverlayVisible, gGUI_ScrollTop, cfg
    global gGUI_LeftArrowRect, gGUI_RightArrowRect, gGUI_State, gGUI_FrozenItems

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

    items := _GUI_GetDisplayItems()
    count := items.Length
    if (count = 0) {
        return
    }

    scale := Win_GetScaleForWindow(gGUI_OverlayH)
    yDip := Round(y / scale)

    rowsTopDip := cfg.GUI_MarginY + GUI_HeaderBlockDip()
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

    idxVisible := ((yDip - rowsTopDip) // cfg.GUI_RowHeight) + 1
    if (idxVisible < 1) {
        idxVisible := 1
    }
    if (idxVisible > rowsDrawn) {
        return
    }

    top0 := gGUI_ScrollTop
    idx0 := Win_Wrap0(top0 + (idxVisible - 1), count)
    clickedIdx := idx0 + 1

    ; Check if we should activate immediately on click (like Windows native)
    if (cfg.AltTabSwitchOnClick && gGUI_State = "ACTIVE") {
        ; Get the clicked item and activate it immediately
        item := items[clickedIdx]
        GUI_HideOverlay()
        GUI_ActivateItem(item)
        gGUI_State := "IDLE"
        gGUI_FrozenItems := []
        return
    }

    ; Default behavior: just select the row
    gGUI_Sel := clickedIdx

    if (cfg.GUI_ScrollKeepHighlightOnTop) {
        gGUI_ScrollTop := gGUI_Sel - 1
    }

    GUI_Repaint()
}

; Track whether we've requested WM_MOUSELEAVE notification
global gGUI_MouseTracking := false

GUI_OnMouseMove(wParam, lParam, msg, hwnd) {
    global gGUI_OverlayH, gGUI_OverlayVisible, gGUI_HoverRow, gGUI_HoverBtn, gGUI_Items, gGUI_Sel
    global gGUI_MouseTracking

    if (hwnd != gGUI_OverlayH) {
        return 0
    }

    ; Don't process mouse moves if overlay isn't visible
    if (!gGUI_OverlayVisible) {
        return 0
    }

    ; Request WM_MOUSELEAVE notification if not already tracking
    if (!gGUI_MouseTracking) {
        ; TRACKMOUSEEVENT structure: cbSize(4), dwFlags(4), hwndTrack(ptr), dwHoverTime(4)
        static TME_LEAVE := 0x02
        tme := Buffer(8 + A_PtrSize + 4, 0)
        NumPut("uint", 8 + A_PtrSize + 4, tme, 0)  ; cbSize
        NumPut("uint", TME_LEAVE, tme, 4)          ; dwFlags
        NumPut("ptr", hwnd, tme, 8)                ; hwndTrack
        DllCall("user32\TrackMouseEvent", "ptr", tme)
        gGUI_MouseTracking := true
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

GUI_OnMouseLeave() {
    global gGUI_HoverRow, gGUI_HoverBtn, gGUI_MouseTracking, gGUI_OverlayVisible

    ; Mouse has left the window - clear hover state
    gGUI_MouseTracking := false

    if (gGUI_HoverRow != 0 || gGUI_HoverBtn != "") {
        gGUI_HoverRow := 0
        gGUI_HoverBtn := ""
        if (gGUI_OverlayVisible) {
            GUI_Repaint()
        }
    }
    return 0
}

; ========================= HOVER POLLING =========================
; Fallback mechanism to clear hover when mouse leaves window
; WM_MOUSELEAVE doesn't always fire reliably, so we poll

GUI_StartHoverPolling() {
    GUI_StopHoverPolling()  ; Stop any existing timer first (prevents duplication)
    SetTimer(_GUI_HoverPollTick, 100)  ; Check every 100ms
}

GUI_StopHoverPolling() {
    SetTimer(_GUI_HoverPollTick, 0)
}

_GUI_HoverPollTick() {
    global gGUI_OverlayVisible, gGUI_HoverRow, gGUI_HoverBtn, gGUI_OverlayH

    ; Stop polling if overlay not visible
    if (!gGUI_OverlayVisible) {
        GUI_StopHoverPolling()
        return
    }

    ; Only poll if we have hover state to potentially clear
    if (gGUI_HoverRow = 0 && gGUI_HoverBtn = "") {
        return
    }

    ; Check if mouse is still over our window
    pt := Buffer(8, 0)
    if (!DllCall("user32\GetCursorPos", "ptr", pt)) {
        return
    }

    ; Get mouse position in screen coords
    mx := NumGet(pt, 0, "Int")
    my := NumGet(pt, 4, "Int")

    ; Get window rect in screen coords
    rect := Buffer(16, 0)
    if (!DllCall("user32\GetWindowRect", "ptr", gGUI_OverlayH, "ptr", rect)) {
        return
    }
    left := NumGet(rect, 0, "Int")
    top := NumGet(rect, 4, "Int")
    right := NumGet(rect, 8, "Int")
    bottom := NumGet(rect, 12, "Int")

    ; If mouse is outside window bounds, clear hover state
    if (mx < left || mx >= right || my < top || my >= bottom) {
        gGUI_HoverRow := 0
        gGUI_HoverBtn := ""
        GUI_Repaint()
    }
}

GUI_OnWheel(wParam, lParam) {
    global gGUI_OverlayVisible, cfg

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

    if (cfg.GUI_ScrollKeepHighlightOnTop) {
        GUI_MoveSelection(step)
    } else {
        GUI_ScrollBy(step)
    }
}

GUI_ScrollBy(step) {
    global gGUI_ScrollTop, gGUI_OverlayH, gGUI_Sel

    vis := GUI_GetVisibleRows()
    if (vis <= 0) {
        return
    }
    items := _GUI_GetDisplayItems()
    count := items.Length
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

; ========================= BLACKLIST DIALOG =========================

; Global for dialog result (needed for modal behavior)
global gGUI_BlacklistChoice := ""

; Show dialog with blacklist options (class, title, or pair)
; Returns: "class", "title", "pair", or "" (cancelled)
_GUI_ShowBlacklistDialog(class, title) {
    global gGUI_BlacklistChoice
    gGUI_BlacklistChoice := ""

    dlg := Gui("+AlwaysOnTop +Owner", "Blacklist Window")
    dlg.SetFont("s10")

    dlg.AddText("x10 y10 w380", "Add to blacklist:")
    dlg.AddText("x10 y35 w380", "Class: " class)
    dlg.AddText("x10 y55 w380", "Title: " SubStr(title, 1, 50) (StrLen(title) > 50 ? "..." : ""))

    ; Only show buttons for non-empty values
    btnX := 10
    if (class != "") {
        dlg.AddButton("x" btnX " y90 w90 h30", "Add Class").OnEvent("Click", (*) => _GUI_BlacklistChoice(dlg, "class"))
        btnX += 100
    }
    if (title != "") {
        dlg.AddButton("x" btnX " y90 w90 h30", "Add Title").OnEvent("Click", (*) => _GUI_BlacklistChoice(dlg, "title"))
        btnX += 100
    }
    if (class != "" && title != "") {
        dlg.AddButton("x" btnX " y90 w90 h30", "Add Pair").OnEvent("Click", (*) => _GUI_BlacklistChoice(dlg, "pair"))
        btnX += 100
    }
    dlg.AddButton("x" btnX " y90 w80 h30", "Cancel").OnEvent("Click", (*) => _GUI_BlacklistChoice(dlg, ""))

    dlg.OnEvent("Close", (*) => _GUI_BlacklistChoice(dlg, ""))
    dlg.OnEvent("Escape", (*) => _GUI_BlacklistChoice(dlg, ""))

    dlg.Show("w400 h130")

    ; Wait for dialog to close
    WinWaitClose(dlg)

    return gGUI_BlacklistChoice
}

_GUI_BlacklistChoice(dlg, choice) {
    global gGUI_BlacklistChoice
    gGUI_BlacklistChoice := choice
    dlg.Destroy()
}
