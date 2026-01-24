; Alt-Tabby GUI - Interceptor (Keyboard Hooks)
; Handles Alt+Tab keyboard interception with deferred Tab decision logic
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals/functions

; ========================= EVENT CONSTANTS =========================
; Event codes for internal communication between interceptor and state machine
global TABBY_EV_TAB_STEP := 1  ; Tab pressed during Alt+Tab session
global TABBY_EV_ALT_UP   := 2  ; Alt released, session ended
global TABBY_EV_ALT_DOWN := 3  ; Alt pressed, session starting
global TABBY_EV_ESCAPE   := 4  ; Escape pressed, cancel session
global TABBY_FLAG_SHIFT  := 1  ; Shift modifier flag

; ========================= INTERCEPTOR STATE =========================
; These variables track the keyboard hook state

global gINT_DecisionMs := 24          ; Tab decision window
global gINT_LastAltLeewayMs := 60     ; Alt timing tolerance
; NOTE: Bypass settings are now in config: cfg.AltTabBypassFullscreen, cfg.AltTabBypassProcesses

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

; Bypass mode state - when true, Tab hotkey is disabled for fullscreen games
global gINT_BypassMode := false

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
    Critical "On"  ; Prevent other hotkeys from interrupting
    global gGUI_State, gGUI_OverlayVisible

    ; Only toggle mode when GUI is active and visible
    if (gGUI_State = "ACTIVE" && gGUI_OverlayVisible) {
        GUI_ToggleWorkspaceMode()
    }
}

; ========================= ALT HANDLERS =========================

INT_Alt_Down(*) {
    Critical "On"  ; Prevent other hotkeys from interrupting
    global gINT_LastAltDown, gINT_AltIsDown, TABBY_EV_ALT_DOWN, gINT_SessionActive
    _GUI_LogEvent("INT: Alt_Down (session=" gINT_SessionActive ")")
    gINT_AltIsDown := true
    gINT_LastAltDown := A_TickCount

    ; Mask key to prevent menu focus
    try Send("{Blind}{vkE8}")

    ; Notify GUI handler directly (no IPC)
    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
}

INT_Alt_Up(*) {
    Critical "On"  ; Prevent other hotkeys from interrupting
    global gINT_SessionActive, gINT_PressCount, gINT_TabHeld, gINT_TabPending
    global gINT_AltUpDuringPending, gINT_AltIsDown, TABBY_EV_ALT_UP
    global gGUI_PendingPhase  ; Check if GUI is buffering events

    _GUI_LogEvent("INT: Alt_Up (session=" gINT_SessionActive " tabPending=" gINT_TabPending " presses=" gINT_PressCount ")")
    gINT_AltIsDown := false

    ; If Tab decision is pending, mark that Alt was released
    if (gINT_TabPending) {
        _GUI_LogEvent("INT: Alt_Up -> marking AltUpDuringPending")
        gINT_AltUpDuringPending := true
        ; Don't send ALT_UP here - Tab_Decide will handle it
    } else if (gINT_SessionActive && gINT_PressCount >= 1) {
        ; Session was active, send ALT_UP directly
        _GUI_LogEvent("INT: Alt_Up -> sending ALT_UP event")
        GUI_OnInterceptorEvent(TABBY_EV_ALT_UP, 0, 0)
    } else if (gGUI_PendingPhase != "") {
        ; GUI is buffering events during async - pass Alt_Up anyway
        ; This handles the case where Tab was lost during workspace switch
        ; (komorebic's SendInput briefly uninstalls keyboard hooks)
        _GUI_LogEvent("INT: Alt_Up -> forwarding to buffer (async pending)")
        GUI_OnInterceptorEvent(TABBY_EV_ALT_UP, 0, 0)
    } else {
        _GUI_LogEvent("INT: Alt_Up -> ignored (no active session)")
    }

    gINT_SessionActive := false
    gINT_PressCount := 0
    gINT_TabHeld := false
}

; ========================= TAB HANDLERS =========================

INT_Tab_Down(*) {
    Critical "On"  ; Prevent other hotkeys from interrupting
    global gINT_TabPending, gINT_TabHeld, gINT_PendingShift, gINT_TabUpSeen
    global gINT_PendingDecideArmed, gINT_DecisionMs, gINT_AltUpDuringPending
    global gINT_SessionActive, gINT_PressCount, gINT_AltIsDown
    global TABBY_EV_TAB_STEP, TABBY_FLAG_SHIFT

    _GUI_LogEvent("INT: Tab_Down (session=" gINT_SessionActive " altIsDown=" gINT_AltIsDown " tabPending=" gINT_TabPending " tabHeld=" gINT_TabHeld ")")

    ; NOTE: Bypass check removed - now handled via focus-change detection in GUI_ApplyDelta
    ; When a bypass window is focused, INT_SetBypassMode disables Tab hooks entirely,
    ; so Tab never reaches here and native Windows Alt-Tab works

    ; If a decision is pending, commit it immediately before processing this Tab
    if (gINT_TabPending) {
        _GUI_LogEvent("INT: Tab_Down -> committing pending decision first")
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
        _GUI_LogEvent("INT: Tab_Down -> active session, sending TAB_STEP (press #" gINT_PressCount ")")
        GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, shiftFlag, 0)
        ; NOTE: Don't set gINT_TabHeld here - we process ALL tabs during active session
        return
    }

    ; FIRST TAB: Check TabHeld to block key repeat (user holding Tab before Alt)
    if (gINT_TabHeld) {
        _GUI_LogEvent("INT: Tab_Down -> blocked (TabHeld)")
        return
    }

    ; Session not active yet - this is the FIRST Tab, needs decision delay
    _GUI_LogEvent("INT: Tab_Down -> FIRST TAB, starting " gINT_DecisionMs "ms decision timer")
    gINT_TabPending := true
    gINT_PendingShift := GetKeyState("Shift", "P")
    gINT_TabUpSeen := false
    gINT_PendingDecideArmed := true
    gINT_AltUpDuringPending := false
    SetTimer(INT_Tab_Decide, -gINT_DecisionMs)
}

INT_Tab_Up(*) {
    Critical "On"  ; Prevent other hotkeys from interrupting
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
    Critical "On"  ; Prevent other hotkeys from interrupting
    global gINT_PendingDecideArmed, gINT_AltUpDuringPending, gINT_AltIsDown
    if (!gINT_PendingDecideArmed)
        return
    gINT_PendingDecideArmed := false
    ; Log state at timer fire time (before delay)
    _GUI_LogEvent("INT: Tab_Decide (altIsDown=" gINT_AltIsDown " altUpFlag=" gINT_AltUpDuringPending ")")
    ; Delay to let Alt_Up hotkey run first if it's pending
    ; 1ms wasn't enough - Alt_Up hotkey may not have fired yet
    SetTimer(INT_Tab_Decide_Inner, -5)
}

INT_Tab_Decide_Inner() {
    Critical "On"  ; Prevent other hotkeys from interrupting
    global gINT_TabPending, gINT_TabUpSeen, gINT_PendingShift, gINT_AltUpDuringPending
    global gINT_LastAltDown, gINT_LastAltLeewayMs, gINT_AltIsDown
    global gINT_SessionActive, gINT_PressCount, gINT_TabHeld
    global TABBY_EV_TAB_STEP, TABBY_EV_ALT_UP, TABBY_FLAG_SHIFT

    ; Capture state NOW (before any potential message pumping)
    altDownNow := gINT_AltIsDown
    altUpFlag := gINT_AltUpDuringPending
    altRecent := (A_TickCount - gINT_LastAltDown) <= gINT_LastAltLeewayMs
    isAltTab := altDownNow || altRecent || altUpFlag

    _GUI_LogEvent("INT: Tab_Decide_Inner (altDown=" altDownNow " altUpFlag=" altUpFlag " altRecent=" altRecent " -> isAltTab=" isAltTab ")")

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
        _GUI_LogEvent("INT: Tab_Decide -> sending TAB_STEP")
        GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, shiftFlag, 0)

        ; NOTE: We no longer set gINT_TabHeld here - during active session we process
        ; ALL Tabs without blocking, just like native Windows Alt+Tab behavior.

        ; CRITICAL: If Alt was released during decision window, send ALT_UP now
        if (!altDownNow || altUpFlag) {
            _GUI_LogEvent("INT: Tab_Decide -> Alt was released, sending ALT_UP")
            GUI_OnInterceptorEvent(TABBY_EV_ALT_UP, 0, 0)
            gINT_SessionActive := false
            gINT_PressCount := 0
            gINT_AltUpDuringPending := false
        }
    } else {
        ; Not Alt+Tab - replay normal Tab
        _GUI_LogEvent("INT: Tab_Decide -> NOT Alt+Tab, replaying Tab")
        gINT_TabPending := false
        Send(gINT_PendingShift ? "+{Tab}" : "{Tab}")
    }
}

; ========================= ESCAPE HANDLER =========================

INT_Escape_Down(*) {
    Critical "On"  ; Prevent other hotkeys from interrupting
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

; Called from GUI_ApplyDelta when focus changes to check bypass criteria
INT_SetBypassMode(shouldBypass) {
    global gINT_BypassMode

    if (shouldBypass && !gINT_BypassMode) {
        ; Entering bypass mode - disable Tab hooks
        _GUI_LogEvent("INT: Entering BYPASS MODE, disabling Tab hotkey")
        gINT_BypassMode := true
        try {
            Hotkey("$*Tab", "Off")
            Hotkey("$*Tab Up", "Off")
        }
    } else if (!shouldBypass && gINT_BypassMode) {
        ; Leaving bypass mode - re-enable Tab hooks
        _GUI_LogEvent("INT: Leaving BYPASS MODE, re-enabling Tab hotkey")
        gINT_BypassMode := false
        try {
            Hotkey("$*Tab", "On")
            Hotkey("$*Tab Up", "On")
        }
    }
}

; Check bypass criteria for a specific window (or active window if hwnd=0)
; Also logs the reason when bypass is triggered (under DiagEventLog)
INT_ShouldBypassWindow(hwnd := 0) {
    global cfg

    if (hwnd = 0)
        hwnd := WinExist("A")
    if (!hwnd)
        return false

    ; Check process blacklist
    if (cfg.AltTabBypassProcesses != "") {
        exename := ""
        try exename := WinGetProcessName(hwnd)
        if (exename) {
            lex := StrLower(exename)
            bypassList := StrSplit(cfg.AltTabBypassProcesses, ",")
            for _, nm in bypassList {
                nm := Trim(nm)
                if (nm != "" && StrLower(nm) = lex) {
                    _GUI_LogEvent("BYPASS REASON: process='" exename "' hwnd=" hwnd)
                    return true
                }
            }
        }
    }

    ; Check fullscreen detection
    if (cfg.AltTabBypassFullscreen && INT_IsFullscreenHwnd(hwnd)) {
        _GUI_LogEvent("BYPASS REASON: fullscreen hwnd=" hwnd)
        return true
    }

    return false
}

INT_IsFullscreenHwnd(hwnd) {
    local x, y, w, h
    try {
        WinGetPos(&x, &y, &w, &h, hwnd)
    } catch {
        return false
    }
    if (!IsSet(w) || !IsSet(h))
        return false
    return (w >= A_ScreenWidth * 0.99 && h >= A_ScreenHeight * 0.99 && x <= 5 && y <= 5)
}
