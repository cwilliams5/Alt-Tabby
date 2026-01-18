; Alt-Tabby GUI - Interceptor (Keyboard Hooks)
; Handles Alt+Tab keyboard interception with deferred Tab decision logic

; ========================= INTERCEPTOR STATE =========================
; These variables track the keyboard hook state

global gINT_DecisionMs := 24          ; Tab decision window
global gINT_LastAltLeewayMs := 60     ; Alt timing tolerance
global gINT_DisableInProcesses := []
global gINT_DisableInFullscreen := true

global gINT_SessionActive := false
global gINT_TabHeld := false
global gINT_PressCount := 0
global gINT_LastAltDown := -999999
global gINT_AltIsDown := false        ; Track Alt state via hotkey handlers

; Deferred-Tab decision state
global gINT_TabPending := false
global gINT_TabUpSeen := false
global gINT_PendingShift := false
global gINT_PendingDecideArmed := false
global gINT_AltUpDuringPending := false  ; Track if Alt released before Tab_Decide

; ========================= HOTKEY SETUP =========================

INT_SetupHotkeys() {
    ; Alt hooks (pass-through, just observe)
    Hotkey("~*Alt", INT_Alt_Down)
    Hotkey("~*Alt Up", INT_Alt_Up)

    ; Tab hooks (intercept for decision)
    Hotkey("$*Tab", INT_Tab_Down)
    Hotkey("$*Tab Up", INT_Tab_Up)

    ; Escape hook
    Hotkey("$*Escape", INT_Escape_Down)

    ; Ctrl hook for workspace mode toggle (only when GUI active)
    Hotkey("~*Ctrl", INT_Ctrl_Down)

    ; Exit hotkey
    Hotkey("$*!F12", (*) => ExitApp())
}

; ========================= CTRL HANDLER =========================

INT_Ctrl_Down(*) {
    global gGUI_State, gGUI_OverlayVisible

    ; Only toggle mode when GUI is active and visible
    if (gGUI_State = "ACTIVE" && gGUI_OverlayVisible) {
        GUI_ToggleWorkspaceMode()
    }
}

; ========================= ALT HANDLERS =========================

INT_Alt_Down(*) {
    global gINT_LastAltDown, gINT_AltIsDown, TABBY_EV_ALT_DOWN
    gINT_AltIsDown := true
    gINT_LastAltDown := A_TickCount

    ; Mask key to prevent menu focus
    try Send("{Blind}{vkE8}")

    ; Notify GUI handler directly (no IPC)
    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
}

INT_Alt_Up(*) {
    global gINT_SessionActive, gINT_PressCount, gINT_TabHeld, gINT_TabPending
    global gINT_AltUpDuringPending, gINT_AltIsDown, TABBY_EV_ALT_UP

    gINT_AltIsDown := false

    ; If Tab decision is pending, mark that Alt was released
    if (gINT_TabPending) {
        gINT_AltUpDuringPending := true
        ; Don't send ALT_UP here - Tab_Decide will handle it
    } else if (gINT_SessionActive && gINT_PressCount >= 1) {
        ; Session was active, send ALT_UP directly
        GUI_OnInterceptorEvent(TABBY_EV_ALT_UP, 0, 0)
    }
    ; else: No active session, ignore

    gINT_SessionActive := false
    gINT_PressCount := 0
    gINT_TabHeld := false
}

; ========================= TAB HANDLERS =========================

INT_Tab_Down(*) {
    global gINT_TabPending, gINT_TabHeld, gINT_PendingShift, gINT_TabUpSeen
    global gINT_PendingDecideArmed, gINT_DecisionMs, gINT_AltUpDuringPending
    global gINT_SessionActive, gINT_PressCount, gINT_AltIsDown
    global TABBY_EV_TAB_STEP, TABBY_FLAG_SHIFT

    if (INT_ShouldBypass()) {
        Send(GetKeyState("Shift", "P") ? "+{Tab}" : "{Tab}")
        return
    }

    ; If a decision is pending, commit it immediately before processing this Tab
    if (gINT_TabPending) {
        SetTimer(INT_Tab_Decide, 0)  ; Cancel pending timer
        gINT_PendingDecideArmed := false
        gINT_TabPending := false
        INT_Tab_Decide_Inner()  ; Commit immediately - may set gINT_SessionActive := true
    }

    ; ACTIVE SESSION: Process ALL Tabs immediately - no TabHeld blocking!
    ; During active session we WANT rapid Tabs to work even if Tab Up is delayed.
    ; The TabHeld mechanism is for the first Tab only (to block key repeat before session starts).
    if (gINT_SessionActive && gINT_AltIsDown) {
        gINT_PressCount += 1
        shiftHeld := GetKeyState("Shift", "P")
        shiftFlag := shiftHeld ? TABBY_FLAG_SHIFT : 0
        GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, shiftFlag, 0)
        ; NOTE: Don't set gINT_TabHeld here - we process ALL tabs during active session
        return
    }

    ; FIRST TAB: Check TabHeld to block key repeat (user holding Tab before Alt)
    if (gINT_TabHeld)
        return

    ; Session not active yet - this is the FIRST Tab, needs decision delay
    gINT_TabPending := true
    gINT_PendingShift := GetKeyState("Shift", "P")
    gINT_TabUpSeen := false
    gINT_PendingDecideArmed := true
    gINT_AltUpDuringPending := false
    SetTimer(INT_Tab_Decide, -gINT_DecisionMs)
}

INT_Tab_Up(*) {
    global gINT_TabHeld, gINT_TabPending, gINT_TabUpSeen

    if (gINT_TabHeld) {
        ; Released from Alt+Tab step
        gINT_TabHeld := false
        return
    }
    ; If still deciding, remember Tab went up
    if (gINT_TabPending)
        gINT_TabUpSeen := true
}

INT_Tab_Decide() {
    global gINT_PendingDecideArmed
    if (!gINT_PendingDecideArmed)
        return
    gINT_PendingDecideArmed := false
    ; Small delay to let Alt_Up run first if it's pending
    SetTimer(INT_Tab_Decide_Inner, -1)
}

INT_Tab_Decide_Inner() {
    global gINT_TabPending, gINT_TabUpSeen, gINT_PendingShift, gINT_AltUpDuringPending
    global gINT_LastAltDown, gINT_LastAltLeewayMs, gINT_AltIsDown
    global gINT_SessionActive, gINT_PressCount, gINT_TabHeld
    global TABBY_EV_TAB_STEP, TABBY_EV_ALT_UP, TABBY_FLAG_SHIFT

    ; Capture state NOW (before any potential message pumping)
    altDownNow := gINT_AltIsDown
    altUpFlag := gINT_AltUpDuringPending
    altRecent := (A_TickCount - gINT_LastAltDown) <= gINT_LastAltLeewayMs
    isAltTab := altDownNow || altRecent || altUpFlag

    if (isAltTab) {
        ; This is an Alt+Tab press
        gINT_TabPending := false

        if (!gINT_SessionActive) {
            gINT_SessionActive := true
            gINT_PressCount := 0
        }
        gINT_PressCount += 1

        ; Send TAB_STEP directly to GUI handler
        shiftFlag := gINT_PendingShift ? TABBY_FLAG_SHIFT : 0
        GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, shiftFlag, 0)

        ; NOTE: We no longer set gINT_TabHeld here - during active session we process
        ; ALL Tabs without blocking, just like native Windows Alt+Tab behavior.

        ; CRITICAL: If Alt was released during decision window, send ALT_UP now
        if (!altDownNow || altUpFlag) {
            GUI_OnInterceptorEvent(TABBY_EV_ALT_UP, 0, 0)
            gINT_SessionActive := false
            gINT_PressCount := 0
            gINT_AltUpDuringPending := false
        }
    } else {
        ; Not Alt+Tab - replay normal Tab
        gINT_TabPending := false
        Send(gINT_PendingShift ? "+{Tab}" : "{Tab}")
    }
}

; ========================= ESCAPE HANDLER =========================

INT_Escape_Down(*) {
    global gINT_SessionActive, gINT_PressCount, gINT_TabHeld, TABBY_EV_ESCAPE

    ; Only consume Escape if in active Alt+Tab session
    if (!gINT_SessionActive || gINT_PressCount < 1) {
        Send("{Escape}")
        return
    }

    ; Notify GUI to cancel
    GUI_OnInterceptorEvent(TABBY_EV_ESCAPE, 0, 0)

    ; Reset session state
    gINT_SessionActive := false
    gINT_PressCount := 0
    gINT_TabHeld := false
}

; ========================= BYPASS DETECTION =========================

INT_ShouldBypass() {
    global gINT_DisableInProcesses, gINT_DisableInFullscreen

    exename := ""
    try exename := WinGetProcessName("A")
    if (exename) {
        lex := StrLower(exename)
        for _, nm in gINT_DisableInProcesses {
            if (StrLower(nm) = lex)
                return true
        }
    }
    return gINT_DisableInFullscreen && INT_IsFullscreen("A")
}

INT_IsFullscreen(win := "A") {
    local x, y, w, h
    try {
        WinGetPos(&x, &y, &w, &h, win)
    } catch {
        return false
    }
    if (!IsSet(w) || !IsSet(h))
        return false
    return (w >= A_ScreenWidth * 0.99 && h >= A_ScreenHeight * 0.99 && x <= 5 && y <= 5)
}
