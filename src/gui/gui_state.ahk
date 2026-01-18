; Alt-Tabby GUI - State Machine
; Handles state transitions: IDLE -> ALT_PENDING -> ACTIVE -> IDLE

; ========================= STATE MACHINE EVENT HANDLER =========================

GUI_OnInterceptorEvent(evCode, flags, lParam) {
    global gGUI_State, gGUI_AltDownTick, gGUI_FirstTabTick, gGUI_TabCount
    global gGUI_OverlayVisible, gGUI_Items, gGUI_Sel, gGUI_FrozenItems
    global AltTabGraceMs, AltTabPrewarmOnAlt, AltTabQuickSwitchMs
    global TABBY_EV_ALT_DOWN, TABBY_EV_TAB_STEP, TABBY_EV_ALT_UP, TABBY_EV_ESCAPE, TABBY_FLAG_SHIFT

    if (evCode = TABBY_EV_ALT_DOWN) {
        ; Alt pressed - enter ALT_PENDING state
        gGUI_State := "ALT_PENDING"
        gGUI_AltDownTick := A_TickCount
        gGUI_FirstTabTick := 0
        gGUI_TabCount := 0

        ; Pre-warm: request snapshot now so data is ready when Tab pressed
        if (AltTabPrewarmOnAlt) {
            GUI_RequestSnapshot()
        }
        return
    }

    if (evCode = TABBY_EV_TAB_STEP) {
        shiftHeld := (flags & TABBY_FLAG_SHIFT) != 0

        if (gGUI_State = "IDLE") {
            ; Tab without Alt (shouldn't happen normally, interceptor handles this)
            return
        }

        if (gGUI_State = "ALT_PENDING") {
            ; First Tab - freeze with current data and go to ACTIVE
            gGUI_FirstTabTick := A_TickCount
            gGUI_TabCount := 1
            gGUI_State := "ACTIVE"

            ; SAFETY: If gGUI_Items is empty and prewarm was requested, wait briefly for data
            ; This handles the race where Tab is pressed before prewarm response arrives
            global AltTabPrewarmOnAlt
            if (gGUI_Items.Length = 0 && IsSet(AltTabPrewarmOnAlt) && AltTabPrewarmOnAlt) {
                waitStart := A_TickCount
                while (gGUI_Items.Length = 0 && (A_TickCount - waitStart) < 50) {
                    Sleep(10)  ; Allow IPC timer to fire and process incoming messages
                }
            }

            ; Freeze: save ALL items (for workspace toggle), then filter
            gGUI_AllItems := gGUI_Items
            gGUI_FrozenItems := GUI_FilterByWorkspaceMode(gGUI_AllItems)

            ; Selection: First Alt+Tab selects the PREVIOUS window (position 2 in 1-based MRU list)
            ; Position 1 = current window (we're already on it)
            ; Position 2 = previous window (what Alt+Tab should switch to)
            gGUI_Sel := 2
            if (gGUI_Sel > gGUI_FrozenItems.Length) {
                ; Only 1 window? Select it
                gGUI_Sel := 1
            }
            ; Pin selection at top (virtual scroll)
            gGUI_ScrollTop := gGUI_Sel - 1

            ; Start grace timer - show GUI after delay
            SetTimer(GUI_GraceTimerFired, -AltTabGraceMs)
            return
        }

        if (gGUI_State = "ACTIVE") {
            gGUI_TabCount += 1
            delta := shiftHeld ? -1 : 1
            GUI_MoveSelectionFrozen(delta)

            ; If GUI not yet visible (still in grace period), show it now on 2nd Tab
            if (!gGUI_OverlayVisible && gGUI_TabCount > 1) {
                SetTimer(GUI_GraceTimerFired, 0)  ; Cancel grace timer
                GUI_ShowOverlayWithFrozen()
            } else if (gGUI_OverlayVisible) {
                GUI_Repaint()
            }
        }
        return
    }

    if (evCode = TABBY_EV_ALT_UP) {
        ; DEBUG: Show ALT_UP arrival (controlled by DebugAltTabTooltips config)
        if (IsSet(DebugAltTabTooltips) && DebugAltTabTooltips) {
            ToolTip("ALT_UP: state=" gGUI_State " visible=" gGUI_OverlayVisible, 100, 200, 3)
            SetTimer(() => ToolTip(,,,3), -2000)
        }

        if (gGUI_State = "ALT_PENDING") {
            ; Alt released without Tab - return to IDLE
            gGUI_State := "IDLE"
            return
        }

        if (gGUI_State = "ACTIVE") {
            SetTimer(GUI_GraceTimerFired, 0)  ; Cancel grace timer

            timeSinceTab := A_TickCount - gGUI_FirstTabTick

            if (!gGUI_OverlayVisible && timeSinceTab < AltTabQuickSwitchMs) {
                ; Quick switch: Alt+Tab released quickly, no GUI shown
                GUI_ActivateFromFrozen()
            } else if (gGUI_OverlayVisible) {
                ; Normal case: activate selected and hide
                GUI_ActivateFromFrozen()
                GUI_HideOverlay()
            } else {
                ; Edge case: grace period expired but GUI not shown yet
                GUI_ActivateFromFrozen()
            }

            gGUI_State := "IDLE"
            gGUI_FrozenItems := []

            ; Resync with store - we may have missed deltas during ACTIVE
            GUI_RequestSnapshot()
        }
        return
    }

    if (evCode = TABBY_EV_ESCAPE) {
        ; Cancel - hide without activating
        SetTimer(GUI_GraceTimerFired, 0)  ; Cancel grace timer
        if (gGUI_OverlayVisible) {
            GUI_HideOverlay()
        }
        gGUI_State := "IDLE"
        gGUI_FrozenItems := []

        ; Resync with store - we may have missed deltas during ACTIVE
        GUI_RequestSnapshot()
        return
    }
}

; ========================= GRACE TIMER =========================

GUI_GraceTimerFired() {
    global gGUI_State, gGUI_OverlayVisible

    if (gGUI_State = "ACTIVE" && !gGUI_OverlayVisible) {
        GUI_ShowOverlayWithFrozen()
    }
}

; ========================= FROZEN STATE HELPERS =========================

GUI_ShowOverlayWithFrozen() {
    global gGUI_OverlayVisible, gGUI_Base, gGUI_BaseH, gGUI_Overlay, gGUI_OverlayH
    global gGUI_Items, gGUI_FrozenItems, gGUI_Sel, gGUI_ScrollTop, gGUI_Revealed
    global GUI_ScrollKeepHighlightOnTop

    if (gGUI_OverlayVisible) {
        return
    }

    ; Set visible flag FIRST to prevent re-entrancy issues
    ; (Show/DwmFlush can pump messages, allowing hotkeys to fire mid-function)
    gGUI_OverlayVisible := true

    ; Use frozen items for display
    gGUI_Items := gGUI_FrozenItems

    ; ENFORCE: When ScrollKeepHighlightOnTop is true, selected item must be at top
    ; This catches any edge cases where scrollTop wasn't set correctly
    if (GUI_ScrollKeepHighlightOnTop && gGUI_FrozenItems.Length > 0) {
        gGUI_ScrollTop := gGUI_Sel - 1
    }

    gGUI_Revealed := false

    try {
        gGUI_Base.Show("NA")
    }

    rowsDesired := GUI_ComputeRowsToShow(gGUI_Items.Length)
    GUI_ResizeToRows(rowsDesired)
    GUI_Repaint()  ; Paint with correct sel/scroll from the start

    try {
        gGUI_Overlay.Show("NA")
    }
    Win_DwmFlush()
}

GUI_MoveSelectionFrozen(delta) {
    global gGUI_Sel, gGUI_FrozenItems, gGUI_ScrollTop

    if (gGUI_FrozenItems.Length = 0) {
        return
    }

    count := gGUI_FrozenItems.Length
    newSel := gGUI_Sel + delta

    ; Wrap around
    if (newSel < 1) {
        newSel := count
    } else if (newSel > count) {
        newSel := 1
    }

    gGUI_Sel := newSel
    ; Pin selection at top row (virtual scroll - list moves, selection stays at top)
    gGUI_ScrollTop := gGUI_Sel - 1
}

GUI_ActivateFromFrozen() {
    global gGUI_Sel, gGUI_FrozenItems

    if (gGUI_Sel < 1 || gGUI_Sel > gGUI_FrozenItems.Length) {
        ; DEBUG: Out of range selection (controlled by DebugAltTabTooltips config)
        if (IsSet(DebugAltTabTooltips) && DebugAltTabTooltips) {
            ToolTip("ACTIVATE: sel=" gGUI_Sel " OUT OF RANGE (len=" gGUI_FrozenItems.Length ")", 100, 150, 2)
            SetTimer(() => ToolTip(,,,2), -2000)
        }
        return
    }

    item := gGUI_FrozenItems[gGUI_Sel]
    GUI_ActivateItem(item)
}

; ========================= ACTIVATION =========================

GUI_ActivateSelected() {
    global gGUI_Items, gGUI_Sel
    if (gGUI_Sel < 1 || gGUI_Sel > gGUI_Items.Length) {
        return
    }
    item := gGUI_Items[gGUI_Sel]
    GUI_ActivateItem(item)
}

; Unified activation logic with cross-workspace support via komorebi
GUI_ActivateItem(item) {
    global KomorebicExe

    hwnd := item.hwnd
    if (!hwnd) {
        return
    }

    ; Check if window is on a different workspace
    isOnCurrent := item.HasOwnProp("isOnCurrentWorkspace") ? item.isOnCurrentWorkspace : true
    wsName := item.HasOwnProp("WS") ? item.WS : ""

    ; If window is on different workspace and we have komorebi, switch workspace first
    if (!isOnCurrent && wsName != "" && IsSet(KomorebicExe) && KomorebicExe != "" && FileExist(KomorebicExe)) {
        try {
            ; Use komorebic to switch to the target workspace
            cmd := '"' KomorebicExe '" focus-named-workspace "' wsName '"'
            Run(cmd, , "Hide")
            ; Brief delay to let workspace switch complete
            Sleep(50)
        }
    }

    ; Now activate the window
    try {
        if (WinExist("ahk_id " hwnd)) {
            if (DllCall("user32\IsIconic", "ptr", hwnd, "int")) {
                DllCall("user32\ShowWindow", "ptr", hwnd, "int", 9)  ; SW_RESTORE
            }
            DllCall("user32\SetForegroundWindow", "ptr", hwnd)
        }
    }
}
