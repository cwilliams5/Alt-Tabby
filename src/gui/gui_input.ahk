#Requires AutoHotkey v2.0
; Alt-Tabby GUI - Input Handling
; Handles mouse events, selection movement, hover detection, and actions
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals/functions

; ========================= HOVER / MOUSE STATE =========================
global gGUI_HoverRow := 0
global gGUI_HoverBtn := ""
global gGUI_MouseTracking := false  ; Whether we've requested WM_MOUSELEAVE notification

; ========================= SELECTION CLAMPING =========================

; Clamp gGUI_Sel to valid range for the given items array.
; Called after item list changes (snapshots, deltas) to prevent out-of-bounds selection.
GUI_ClampSelection(items) {
    global gGUI_Sel
    if (items.Length > 0) {
        if (gGUI_Sel > items.Length)
            gGUI_Sel := items.Length
        if (gGUI_Sel < 1)
            gGUI_Sel := 1
    }
}

; ========================= DISPLAY ITEMS HELPER =========================

; Returns the correct items array based on GUI state
; Paint and input must use the same array for consistent behavior
; During ACTIVE state with workspace filtering, use gGUI_DisplayItems
; Otherwise use gGUI_LiveItems (live data from store)
_GUI_GetDisplayItems() {
    global gGUI_State, gGUI_LiveItems, gGUI_DisplayItems
    return (gGUI_State = "ACTIVE") ? gGUI_DisplayItems : gGUI_LiveItems
}

; ========================= SELECTION MOVEMENT =========================

_GUI_MoveSelection(delta) {
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

    Critical "On"
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
    Critical "Off"

    GUI_RecalcHover()
    ; When animation frame loop is running, skip synchronous repaint —
    ; the loop will paint next frame. Prevents message queue flooding
    ; during rapid mouse wheel scroll (Logitech infinite scroll).
    if (cfg.PerfAnimationType = "None")
        GUI_Repaint()
}

; ========================= HOVER DETECTION =========================

; NOTE: No Critical "Off" here — callers may hold Critical (e.g., interceptor's TAB_STEP).
; AHK v2 Critical is thread-level, so "Off" here would leak and break the caller's protection.
GUI_RecalcHover() {
    global gGUI_OverlayH, gGUI_HoverRow, gGUI_HoverBtn

    if (!gGUI_OverlayH) {
        return false
    }

    static pt := Buffer(8, 0)  ; static: reused per-call, repopulated before each DllCall
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
        Critical "On"
        if (gGUI_HoverRow != 0 || gGUI_HoverBtn != "") {
            gGUI_HoverRow := 0
            gGUI_HoverBtn := ""
            return true
        }
        return false
    }

    act := ""
    idx := 0
    _GUI_DetectActionAtPoint(x, y, &act, &idx)

    return _GUI_ApplyHoverState(idx, act)
}

; Atomically update hover state and return true if changed.
; Enters Critical but does NOT exit — callers may hold Critical (see GUI_RecalcHover note).
_GUI_ApplyHoverState(idx, act) {
    global gGUI_HoverRow, gGUI_HoverBtn
    Critical "On"
    changed := (idx != gGUI_HoverRow || act != gGUI_HoverBtn)
    gGUI_HoverRow := idx
    gGUI_HoverBtn := act
    return changed
}

_GUI_PointInRect(px, py, rx, ry, rw, rh) {
    return (px >= rx && px < rx + rw && py >= ry && py < ry + rh)
}

_GUI_DetectActionAtPoint(xPhys, yPhys, &action, &idx1) {
    global gGUI_ScrollTop, gGUI_OverlayH, cfg
    global gGUI_LeftArrowRect, gGUI_RightArrowRect

    action := ""
    idx1 := 0

    ; Check footer arrow hover (regardless of row position)
    if (cfg.GUI_ShowFooter) {
        r := gGUI_LeftArrowRect
        if (_GUI_PointInRect(xPhys, yPhys, r.x, r.y, r.w, r.h)) {
            action := "arrowLeft"
            return
        }
        r := gGUI_RightArrowRect
        if (_GUI_PointInRect(xPhys, yPhys, r.x, r.y, r.w, r.h)) {
            action := "arrowRight"
            return
        }
    }

    items := _GUI_GetDisplayItems()
    count := items.Length
    if (count <= 0) {
        return
    }

    scale := Win_GetScaleForWindow(gGUI_OverlayH)
    layout := GUI_GetCachedLayout(scale)
    RowH := layout.RowH
    My := layout.My
    topY := My + layout.hdrBlock

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

    metrics := GUI_GetActionBtnMetrics(scale)
    size := metrics.size
    gap := metrics.gap
    marR := layout.Mx

    ox := 0
    oy := 0
    ow := 0
    oh := 0
    Win_GetRectPhys(gGUI_OverlayH, &ox, &oy, &ow, &oh)

    btnX := ow - marR - size
    btnY := topY + (rowVis - 1) * RowH + (RowH - size) // 2

    if (cfg.GUI_ShowCloseButton) {
        if (_GUI_PointInRect(xPhys, yPhys, btnX, btnY, size, size)) {
            action := "close"
            return
        }
        btnX := btnX - (size + gap)
    }
    if (cfg.GUI_ShowKillButton) {
        if (_GUI_PointInRect(xPhys, yPhys, btnX, btnY, size, size)) {
            action := "kill"
            return
        }
        btnX := btnX - (size + gap)
    }
    if (cfg.GUI_ShowBlacklistButton) {
        if (_GUI_PointInRect(xPhys, yPhys, btnX, btnY, size, size)) {
            action := "blacklist"
            return
        }
    }
}

; ========================= ACTIONS =========================

_GUI_PerformAction(action, idx1 := 0) {
    global gGUI_Sel

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
            global WM_CLOSE
            try PostMessage(WM_CLOSE, 0, 0, , "ahk_id " hwnd)
        }
        _GUI_RemoveItemAt(idx1)
        return
    }

    if (action = "kill") {
        pid := cur.HasOwnProp("pid") ? cur.pid : ""
        ttl := cur.HasOwnProp("title") ? cur.title : "window"
        pname := cur.HasOwnProp("processName") ? cur.processName : ""

        ; Build detailed confirmation message
        msg := ""
        ; Warn about critical system processes
        static systemProcs := "explorer.exe|svchost.exe|csrss.exe|dwm.exe|winlogon.exe|lsass.exe|services.exe"
        if (pname != "" && InStr(systemProcs, StrLower(pname)))
            msg .= "WARNING: This is a Windows system process.`nKilling it may cause instability.`n`n"
        msg .= "Force quit this process?"
        msg .= "`n`nWindow: " SubStr(ttl, 1, 50) (StrLen(ttl) > 50 ? "..." : "")
        if (pname != "") {
            msg .= "`nProcess: " pname
        }
        msg .= "`nPID: " pid
        msg .= "`n`nUnsaved work in this application will be lost."

        if (Win_ConfirmTopmost(msg, "Force Quit Process")) {
            if (pid != "") {
                try {
                    ProcessClose(pid)
                }
            }
            _GUI_RemoveItemAt(idx1)
        }
        return
    }

    if (action = "blacklist") {
        ttl := cur.HasOwnProp("title") ? cur.title : ""
        cls := cur.HasOwnProp("class") ? cur.class : ""

        if (cls = "" && ttl = "") {
            return
        }

        ; Show blacklist options dialog
        choice := GUI_ShowBlacklistDialog(cls, ttl)
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

        ; Reload blacklist and purge newly-blacklisted windows from store
        Blacklist_Init()
        WL_PurgeBlacklisted()

        ; Remove item from local display
        _GUI_RemoveItemAt(idx1)
        return
    }
}

_GUI_RemoveItemAt(idx1) {
    global gGUI_LiveItems, gGUI_Sel, gGUI_ScrollTop, gGUI_OverlayH

    Critical "On"
    if (idx1 < 1 || idx1 > gGUI_LiveItems.Length) {
        Critical "Off"
        return
    }
    remaining := GUI_RemoveLiveItemAt(idx1)

    if (remaining = 0) {
        gGUI_Sel := 1
        gGUI_ScrollTop := 0
    } else if (gGUI_Sel > remaining) {
        gGUI_Sel := remaining
    }
    Critical "Off"

    GUI_RecalcHover()
    GUI_Repaint()
}

; ========================= MOUSE HANDLERS =========================

GUI_OnClick(x, y) {
    global gGUI_LiveItems, gGUI_Sel, gGUI_OverlayH, gGUI_OverlayVisible, gGUI_ScrollTop, cfg
    global gGUI_LeftArrowRect, gGUI_RightArrowRect, gGUI_State, gGUI_DisplayItems

    Critical "On"

    ; Don't process clicks if overlay isn't visible
    if (!gGUI_OverlayVisible) {
        Critical "Off"
        return
    }

    ; Check footer arrow clicks (only when GUI is active)
    if (gGUI_State = "ACTIVE") {
        ; Left arrow click
        if (x >= gGUI_LeftArrowRect.x && x < gGUI_LeftArrowRect.x + gGUI_LeftArrowRect.w
            && y >= gGUI_LeftArrowRect.y && y < gGUI_LeftArrowRect.y + gGUI_LeftArrowRect.h) {
            Critical "Off"
            GUI_ToggleWorkspaceMode()
            return
        }
        ; Right arrow click
        if (x >= gGUI_RightArrowRect.x && x < gGUI_RightArrowRect.x + gGUI_RightArrowRect.w
            && y >= gGUI_RightArrowRect.y && y < gGUI_RightArrowRect.y + gGUI_RightArrowRect.h) {
            Critical "Off"
            GUI_ToggleWorkspaceMode()
            return
        }
    }

    act := ""
    idx := 0
    _GUI_DetectActionAtPoint(x, y, &act, &idx)
    if (act != "") {
        Critical "Off"
        _GUI_PerformAction(act, idx)
        return
    }

    items := _GUI_GetDisplayItems()
    count := items.Length
    if (count = 0) {
        Critical "Off"
        return
    }

    scale := Win_GetScaleForWindow(gGUI_OverlayH)
    yDip := Round(y / scale)

    rowsTopDip := cfg.GUI_MarginY + GUI_HeaderBlockDip()
    if (yDip < rowsTopDip) {
        Critical "Off"
        return
    }

    vis := GUI_GetVisibleRows()
    if (vis <= 0) {
        Critical "Off"
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
        Critical "Off"
        return
    }

    top0 := gGUI_ScrollTop
    idx0 := Win_Wrap0(top0 + (idxVisible - 1), count)
    clickedIdx := idx0 + 1

    ; Check if we should activate immediately on click (like Windows native)
    if (cfg.AltTabSwitchOnClick && gGUI_State = "ACTIVE") {
        item := items[clickedIdx]
        Critical "Off"
        GUI_ClickActivate(item)
        return
    }

    ; Default behavior: just select the row
    gGUI_Sel := clickedIdx

    if (cfg.GUI_ScrollKeepHighlightOnTop) {
        gGUI_ScrollTop := gGUI_Sel - 1
    }
    Critical "Off"

    GUI_Repaint()
}

GUI_OnMouseMove(wParam, lParam, msg, hwnd) { ; lint-ignore: dead-param
    global gGUI_OverlayH, gGUI_OverlayVisible, gGUI_HoverRow, gGUI_HoverBtn, gGUI_LiveItems, gGUI_Sel
    global gGUI_MouseTracking
    global gFX_MouseX, gFX_MouseY, gFX_MouseInWindow

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
        static tme := Buffer(8 + A_PtrSize + 4, 0)
        NumPut("uint", 8 + A_PtrSize + 4, tme, 0)  ; cbSize
        NumPut("uint", TME_LEAVE, tme, 4)          ; dwFlags
        NumPut("ptr", hwnd, tme, 8)                ; hwndTrack
        DllCall("user32\TrackMouseEvent", "ptr", tme)
        gGUI_MouseTracking := true
    }

    x := lParam & 0xFFFF
    y := (lParam >> 16) & 0xFFFF

    ; Store mouse position for backdrop specular effect
    gFX_MouseX := x
    gFX_MouseY := y
    gFX_MouseInWindow := true

    act := ""
    idx := 0
    _GUI_DetectActionAtPoint(x, y, &act, &idx)

    if (_GUI_ApplyHoverState(idx, act)) {
        Critical "Off"
        GUI_Repaint()
    } else {
        Critical "Off"
    }
    return 0
}

GUI_OnMouseLeave() {
    global gGUI_HoverRow, gGUI_HoverBtn, gGUI_MouseTracking, gGUI_OverlayVisible
    global gFX_MouseInWindow

    ; Mouse has left the window - clear hover state
    gGUI_MouseTracking := false
    gFX_MouseInWindow := false

    Critical "On"
    needRepaint := (gGUI_HoverRow != 0 || gGUI_HoverBtn != "")
    gGUI_HoverRow := 0
    gGUI_HoverBtn := ""
    Critical "Off"
    if (needRepaint && gGUI_OverlayVisible) {
        GUI_Repaint()
    }
    return 0
}

; ========================= HOVER POLLING =========================
; Fallback mechanism to clear hover when mouse leaves window
; WM_MOUSELEAVE doesn't always fire reliably, so we poll

GUI_StartHoverPolling() {
    global cfg
    _GUI_StopHoverPolling()  ; Stop any existing timer first (prevents duplication)
    interval := cfg.GUI_HoverPollIntervalMs
    SetTimer(_GUI_HoverPollTick, interval)
}

_GUI_StopHoverPolling() {
    SetTimer(_GUI_HoverPollTick, 0)
}

GUI_ClearHoverState() {
    global gGUI_HoverRow, gGUI_HoverBtn, gGUI_MouseTracking
    _GUI_StopHoverPolling()
    gGUI_HoverRow := 0
    gGUI_HoverBtn := ""
    gGUI_MouseTracking := false
}

_GUI_HoverPollTick() {
    global gGUI_OverlayVisible, gGUI_HoverRow, gGUI_HoverBtn, gGUI_OverlayH

    ; Stop polling if overlay not visible
    if (!gGUI_OverlayVisible) {
        _GUI_StopHoverPolling()
        return
    }

    ; Only poll if we have hover state to potentially clear
    if (gGUI_HoverRow = 0 && gGUI_HoverBtn = "") {
        return
    }

    ; Check if mouse is still over our window
    static pt := Buffer(8, 0)   ; static: reused per-call, repopulated before each DllCall
    static rect := Buffer(16, 0)
    if (!DllCall("user32\GetCursorPos", "ptr", pt)) {
        return
    }

    ; Get mouse position in screen coords
    mx := NumGet(pt, 0, "Int")
    my := NumGet(pt, 4, "Int")

    ; Get window rect in screen coords
    if (!DllCall("user32\GetWindowRect", "ptr", gGUI_OverlayH, "ptr", rect)) {
        return
    }
    left := NumGet(rect, 0, "Int")
    top := NumGet(rect, 4, "Int")
    right := NumGet(rect, 8, "Int")
    bottom := NumGet(rect, 12, "Int")

    ; If mouse is outside window bounds, clear hover state
    if (mx < left || mx >= right || my < top || my >= bottom) {
        Critical "On"
        gGUI_HoverRow := 0
        gGUI_HoverBtn := ""
        Critical "Off"
        GUI_Repaint()
    }
}

GUI_OnWheel(wParam, lParam) { ; lint-ignore: dead-param
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
        _GUI_MoveSelection(step)
    } else {
        _GUI_ScrollBy(step)
    }
}

_GUI_ScrollBy(step) {
    global gGUI_ScrollTop, gGUI_OverlayH, gGUI_Sel, cfg

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

    Critical "On"
    gGUI_ScrollTop := Win_Wrap0(gGUI_ScrollTop + step, count)
    Critical "Off"
    GUI_RecalcHover()
    if (cfg.PerfAnimationType = "None")
        GUI_Repaint()
}

; ========================= BLACKLIST DIALOG =========================

; Global for dialog result (needed for modal behavior)
global gGUI_BlacklistChoice := ""

; Show dialog with blacklist options (class, title, or pair)
; Returns: "class", "title", "pair", or "" (cancelled)
GUI_ShowBlacklistDialog(class, title) {
    global gGUI_BlacklistChoice
    gGUI_BlacklistChoice := ""

    dlg := Gui("+AlwaysOnTop +Owner", "Blacklist Window")
    GUI_AntiFlashPrepare(dlg, Theme_GetBgColor())
    dlg.MarginX := 24
    dlg.MarginY := 16
    dlg.SetFont("s10", "Segoe UI")
    themeEntry := Theme_ApplyToGui(dlg)

    contentW := 440
    mutedColor := Theme_GetMutedColor()

    ; Header in accent
    hdr := dlg.AddText("w" contentW " c" Theme_GetAccentColor(), "Add to blacklist:")
    Theme_MarkAccent(hdr)

    ; Class label + value
    if (class != "") {
        lblC := dlg.AddText("x24 w50 h20 y+12 +0x200", "Class:")
        lblC.SetFont("s10 bold", "Segoe UI")
        valC := dlg.AddText("x78 yp w" (contentW - 54) " h20 +0x200 c" mutedColor, class)
        Theme_MarkMuted(valC)
    }

    ; Title label + value (truncated)
    if (title != "") {
        displayTitle := SubStr(title, 1, 50) (StrLen(title) > 50 ? "..." : "")
        lblT := dlg.AddText("x24 w50 h20 y+4 +0x200", "Title:")
        lblT.SetFont("s10 bold", "Segoe UI")
        valT := dlg.AddText("x78 yp w" (contentW - 54) " h20 +0x200 c" mutedColor, displayTitle)
        Theme_MarkMuted(valT)
    }

    ; Action buttons (uniform width, left) + Cancel (right, separated)
    btnW := 100
    btnGap := 8
    cancelGap := 24
    btnY := "+24"
    actionBtns := []
    btnX := 24
    if (class != "") {
        btn := dlg.AddButton("x" btnX " y" btnY " w" btnW " h30", "Add Class")
        btn.OnEvent("Click", (*) => _GUI_BlacklistChoice(dlg, "class"))
        actionBtns.Push(btn)
        btnX += btnW + btnGap
        btnY := "p"  ; same row for subsequent buttons
    }
    if (title != "") {
        btn := dlg.AddButton("x" btnX " y" btnY " w" btnW " h30", "Add Title")
        btn.OnEvent("Click", (*) => _GUI_BlacklistChoice(dlg, "title"))
        actionBtns.Push(btn)
        btnX += btnW + btnGap
        btnY := "p"
    }
    if (class != "" && title != "") {
        btn := dlg.AddButton("x" btnX " y" btnY " w" btnW " h30", "Add Pair")
        btn.OnEvent("Click", (*) => _GUI_BlacklistChoice(dlg, "pair"))
        actionBtns.Push(btn)
        btnX += btnW + cancelGap
    }
    btnCancel := dlg.AddButton("x" btnX " yp w" btnW " h30", "Cancel")
    btnCancel.OnEvent("Click", (*) => _GUI_BlacklistChoice(dlg, ""))

    for btn in actionBtns
        Theme_ApplyToControl(btn, "Button", themeEntry)
    Theme_ApplyToControl(btnCancel, "Button", themeEntry)

    dlg.OnEvent("Close", (*) => _GUI_BlacklistChoice(dlg, ""))
    dlg.OnEvent("Escape", (*) => _GUI_BlacklistChoice(dlg, ""))

    dlg.Show("w488 Center")
    GUI_AntiFlashReveal(dlg, true)

    ; Wait for dialog to close
    WinWaitClose(dlg)

    return gGUI_BlacklistChoice
}

_GUI_BlacklistChoice(dlg, choice) {
    global gGUI_BlacklistChoice
    gGUI_BlacklistChoice := choice
    try Theme_UntrackGui(dlg)
    dlg.Destroy()
}
