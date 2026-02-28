#Requires AutoHotkey v2.0
; Alt-Tabby GUI - Interceptor (Keyboard Hooks)
; Handles Alt+Tab keyboard interception with deferred Tab decision logic
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals/functions

; Event constants (shared with state machine and tests)
#Include gui_constants.ahk

; ========================= INTERCEPTOR STATE =========================
; These variables track the keyboard hook state
; NOTE: Fullscreen thresholds now in config: cfg.AltTabBypassFullscreenThreshold, cfg.AltTabBypassFullscreenTolerancePx
; NOTE: Alt leeway now in config: cfg.AltTabAltLeewayMs
; NOTE: Tab decision window now in config: cfg.AltTabTabDecisionMs (default 24ms)
; NOTE: Bypass settings are now in config: cfg.AltTabBypassFullscreen, cfg.AltTabBypassProcesses

global gINT_SessionActive := false
global gINT_TabHeld := false
global gINT_PressCount := 0
global gINT_LastAltDown := -999999
global gINT_AltIsDown := false        ; Track Alt state via hotkey handlers

; Deferred-Tab decision state
global gINT_TabPending := false
global gINT_PendingShift := false
global gINT_PendingDecideArmed := false
global gINT_AltUpDuringPending := false  ; Track if Alt released before Tab_Decide

; Bypass mode state - when true, Tab hotkey is disabled for fullscreen games
global gINT_BypassMode := false

; Settle delay before Tab decision — allows Alt_Up hotkey to fire first.
; 1ms was insufficient; 5ms is empirically safe across tested hardware.
global INT_TAB_DECIDE_SETTLE_MS := 5

; ========================= HOTKEY SETUP =========================

INT_SetupHotkeys() {
    ; Alt hooks (pass-through, just observe)
    Hotkey("~*Alt", _INT_Alt_Down)
    Hotkey("~*Alt Up", _INT_Alt_Up)

    ; Tab hooks (intercept for decision)
    Hotkey("$*Tab", _INT_Tab_Down)
    Hotkey("$*Tab Up", _INT_Tab_Up)

    ; Escape hook
    Hotkey("$*Escape", _INT_Escape_Down)

    ; Ctrl hook for workspace mode toggle (only when GUI active)
    Hotkey("~*Ctrl", _INT_Ctrl_Down)

    ; Backtick hook for monitor mode toggle (only when GUI active)
    Hotkey("~*``", _INT_Backtick_Down)

    ; B key — cycle effect styles when GUI is active
    Hotkey("~*b", _INT_B_Down)

    ; F key — toggle FPS debug overlay when GUI is active
    Hotkey("~*f", _INT_F_Down)

    ; C key — cycle backdrop effects when GUI is active
    Hotkey("~*c", _INT_C_Down)

    ; Exit hotkey (Ctrl+Alt+F12 — avoid conflict with flight recorder's *F12)
    Hotkey("$*^!F12", (*) => ExitApp())
}

; ========================= CTRL HANDLER =========================

_INT_Ctrl_Down(*) {
    Critical "On"  ; Prevent other hotkeys from interrupting
    global gGUI_State, gGUI_OverlayVisible

    ; Only toggle mode when GUI is active and visible
    if (gGUI_State = "ACTIVE" && gGUI_OverlayVisible) {
        GUI_ToggleWorkspaceMode()  ; lint-ignore: critical-leak
    }
}

; ========================= BACKTICK HANDLER =========================

_INT_Backtick_Down(*) {
    Critical "On"  ; Prevent other hotkeys from interrupting
    global gGUI_State, gGUI_OverlayVisible

    ; Only toggle monitor mode when GUI is active and visible
    if (gGUI_State = "ACTIVE" && gGUI_OverlayVisible) {
        GUI_ToggleMonitorMode()  ; lint-ignore: critical-leak
    }
}

; ========================= ALT HANDLERS =========================

_INT_Alt_Down(*) {
    Critical "On"  ; Prevent other hotkeys from interrupting
    Profiler.Enter("_INT_Alt_Down") ; @profile
    global gINT_LastAltDown, gINT_AltIsDown, TABBY_EV_ALT_DOWN, gINT_SessionActive, cfg
    global FR_EV_ALT_DN, gFR_Enabled
    if (gFR_Enabled)
        FR_Record(FR_EV_ALT_DN, gINT_SessionActive)
    if (cfg.DiagEventLog)
        GUI_LogEvent("INT: Alt_Down (session=" gINT_SessionActive ")")
    gINT_AltIsDown := true
    gINT_LastAltDown := A_TickCount

    ; Mask key to prevent menu focus
    try Send("{Blind}{vkE8}")

    ; Notify GUI handler directly (no IPC)
    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    Profiler.Leave() ; @profile
}

_INT_Alt_Up(*) {
    Critical "On"  ; Prevent other hotkeys from interrupting
    Profiler.Enter("_INT_Alt_Up") ; @profile
    global gINT_SessionActive, gINT_PressCount, gINT_TabHeld, gINT_TabPending
    global gINT_AltUpDuringPending, gINT_AltIsDown, TABBY_EV_ALT_UP, cfg
    global gGUI_PendingPhase  ; Check if GUI is buffering events
    global FR_EV_ALT_UP, gFR_Enabled
    if (gFR_Enabled)
        FR_Record(FR_EV_ALT_UP, gINT_SessionActive, gINT_PressCount, gINT_TabPending, gGUI_PendingPhase != "")

    diagLog := cfg.DiagEventLog  ; PERF: cache config read
    if (diagLog)
        GUI_LogEvent("INT: Alt_Up (session=" gINT_SessionActive " tabPending=" gINT_TabPending " presses=" gINT_PressCount ")")
    gINT_AltIsDown := false

    ; If Tab decision is pending, mark that Alt was released
    if (gINT_TabPending) {
        if (diagLog)
            GUI_LogEvent("INT: Alt_Up -> marking AltUpDuringPending")
        gINT_AltUpDuringPending := true
        ; Don't send ALT_UP here - Tab_Decide will handle it
    } else if (gINT_SessionActive && gINT_PressCount >= 1) {
        ; Session was active, send ALT_UP directly
        if (diagLog)
            GUI_LogEvent("INT: Alt_Up -> sending ALT_UP event")
        GUI_OnInterceptorEvent(TABBY_EV_ALT_UP, 0, 0)
    } else if (gGUI_PendingPhase != "") {
        ; GUI is buffering events during async - pass Alt_Up anyway
        ; This handles the case where Tab was lost during workspace switch
        ; (komorebic's SendInput briefly uninstalls keyboard hooks)
        if (diagLog)
            GUI_LogEvent("INT: Alt_Up -> forwarding to buffer (async pending)")
        GUI_OnInterceptorEvent(TABBY_EV_ALT_UP, 0, 0)
    } else {
        if (diagLog)
            GUI_LogEvent("INT: Alt_Up -> ignored (no active session)")
    }

    gINT_SessionActive := false
    gINT_PressCount := 0
    gINT_TabHeld := false
    Profiler.Leave() ; @profile
}

; ========================= TAB HANDLERS =========================

_INT_Tab_Down(*) {
    Critical "On"  ; Prevent other hotkeys from interrupting
    Profiler.Enter("_INT_Tab_Down") ; @profile
    global gINT_TabPending, gINT_TabHeld, gINT_PendingShift
    global gINT_PendingDecideArmed, gINT_AltUpDuringPending, cfg
    global gINT_SessionActive, gINT_PressCount, gINT_AltIsDown
    global TABBY_EV_TAB_STEP, TABBY_FLAG_SHIFT
    global FR_EV_TAB_DN, gFR_Enabled
    if (gFR_Enabled)
        FR_Record(FR_EV_TAB_DN, gINT_SessionActive, gINT_AltIsDown, gINT_TabPending, gINT_TabHeld)

    diagLog := cfg.DiagEventLog  ; PERF: cache config read
    if (diagLog)
        GUI_LogEvent("INT: Tab_Down (session=" gINT_SessionActive " altIsDown=" gINT_AltIsDown " tabPending=" gINT_TabPending " tabHeld=" gINT_TabHeld ")")

    ; If a decision is pending, commit it immediately before processing this Tab
    if (gINT_TabPending) {
        if (diagLog)
            GUI_LogEvent("INT: Tab_Down -> committing pending decision first")
        SetTimer(_INT_Tab_Decide, 0)  ; Cancel pending timer
        gINT_PendingDecideArmed := false
        gINT_TabPending := false
        _INT_Tab_Decide_Inner()  ; Commit immediately - may set gINT_SessionActive := true
    }

    ; ACTIVE SESSION: Process ALL Tabs immediately - no TabHeld blocking!
    ; During active session we WANT rapid Tabs to work even if Tab Up is delayed.
    ; The TabHeld mechanism is for the first Tab only (to block key repeat before session starts).
    if (gINT_SessionActive && gINT_AltIsDown) {
        gINT_PressCount += 1
        shiftHeld := GetKeyState("Shift", "P")
        shiftFlag := shiftHeld ? TABBY_FLAG_SHIFT : 0
        if (diagLog)
            GUI_LogEvent("INT: Tab_Down -> active session, sending TAB_STEP (press #" gINT_PressCount ")")
        GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, shiftFlag, 0)
        ; NOTE: Don't set gINT_TabHeld here - we process ALL tabs during active session
        Profiler.Leave() ; @profile
        return
    }

    ; FIRST TAB: Check TabHeld to block key repeat (user holding Tab before Alt)
    if (gINT_TabHeld) {
        if (diagLog)
            GUI_LogEvent("INT: Tab_Down -> blocked (TabHeld)")
        Profiler.Leave() ; @profile
        return
    }

    ; Session not active yet - this is the FIRST Tab, needs decision delay
    if (diagLog)
        GUI_LogEvent("INT: Tab_Down -> FIRST TAB, starting " cfg.AltTabTabDecisionMs "ms decision timer")
    gINT_TabPending := true
    gINT_PendingShift := GetKeyState("Shift", "P")
    gINT_PendingDecideArmed := true
    gINT_AltUpDuringPending := false
    SetTimer(_INT_Tab_Decide, -cfg.AltTabTabDecisionMs)
    Profiler.Leave() ; @profile
}

_INT_Tab_Up(*) {
    Critical "On"  ; Prevent other hotkeys from interrupting
    global gINT_TabHeld, gINT_TabPending
    global FR_EV_TAB_UP, gFR_Enabled
    if (gFR_Enabled)
        FR_Record(FR_EV_TAB_UP, gINT_TabHeld)

    if (gINT_TabHeld) {
        ; Released from Alt+Tab step
        gINT_TabHeld := false
        return
    }
}

_INT_Tab_Decide() {
    Critical "On"  ; Prevent other hotkeys from interrupting
    global gINT_PendingDecideArmed, gINT_AltUpDuringPending, gINT_AltIsDown, cfg
    global FR_EV_TAB_DECIDE, gFR_Enabled
    if (!gINT_PendingDecideArmed)
        return
    gINT_PendingDecideArmed := false
    if (gFR_Enabled)
        FR_Record(FR_EV_TAB_DECIDE, gINT_AltIsDown, gINT_AltUpDuringPending)
    ; Log state at timer fire time (before delay)
    if (cfg.DiagEventLog)
        GUI_LogEvent("INT: Tab_Decide (altIsDown=" gINT_AltIsDown " altUpFlag=" gINT_AltUpDuringPending ")")
    ; Delay to let Alt_Up hotkey run first if it's pending
    global INT_TAB_DECIDE_SETTLE_MS
    SetTimer(_INT_Tab_Decide_Inner, -INT_TAB_DECIDE_SETTLE_MS)
}

_INT_Tab_Decide_Inner() {
    Critical "On"  ; Prevent other hotkeys from interrupting
    Profiler.Enter("_INT_Tab_Decide_Inner") ; @profile
    global gINT_TabPending, gINT_PendingShift, gINT_AltUpDuringPending
    global gINT_LastAltDown, gINT_AltIsDown, cfg
    global gINT_SessionActive, gINT_PressCount, gINT_TabHeld
    global TABBY_EV_TAB_STEP, TABBY_EV_ALT_UP, TABBY_FLAG_SHIFT

    ; Capture state NOW (before any potential message pumping)
    altDownNow := gINT_AltIsDown
    altUpFlag := gINT_AltUpDuringPending
    altRecent := (A_TickCount - gINT_LastAltDown) <= cfg.AltTabAltLeewayMs
    isAltTab := altDownNow || altRecent || altUpFlag

    diagLog := cfg.DiagEventLog  ; PERF: cache config read
    if (diagLog)
        GUI_LogEvent("INT: Tab_Decide_Inner (altDown=" altDownNow " altUpFlag=" altUpFlag " altRecent=" altRecent " -> isAltTab=" isAltTab ")")

    global FR_EV_TAB_DECIDE_INNER, gFR_Enabled
    if (gFR_Enabled)
        FR_Record(FR_EV_TAB_DECIDE_INNER, isAltTab, altDownNow, altUpFlag, altRecent)

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
        if (diagLog)
            GUI_LogEvent("INT: Tab_Decide -> sending TAB_STEP")
        GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, shiftFlag, 0)

        ; NOTE: We no longer set gINT_TabHeld here - during active session we process
        ; ALL Tabs without blocking, just like native Windows Alt+Tab behavior.

        ; CRITICAL: If Alt was released during decision window, send ALT_UP now
        if (!altDownNow || altUpFlag) {
            if (diagLog)
                GUI_LogEvent("INT: Tab_Decide -> Alt was released, sending ALT_UP")
            GUI_OnInterceptorEvent(TABBY_EV_ALT_UP, 0, 0)
            gINT_SessionActive := false
            gINT_PressCount := 0
            gINT_AltUpDuringPending := false
        }
    } else {
        ; Not Alt+Tab - replay normal Tab
        if (diagLog)
            GUI_LogEvent("INT: Tab_Decide -> NOT Alt+Tab, replaying Tab")
        gINT_TabPending := false
        Send(gINT_PendingShift ? "+{Tab}" : "{Tab}")
    }
    Profiler.Leave() ; @profile
}

; ========================= ESCAPE HANDLER =========================

_INT_Escape_Down(*) {
    Critical "On"  ; Prevent other hotkeys from interrupting
    global gINT_SessionActive, gINT_PressCount, gINT_TabHeld, TABBY_EV_ESCAPE
    global FR_EV_ESC, gFR_Enabled
    if (gFR_Enabled)
        FR_Record(FR_EV_ESC, gINT_SessionActive, gINT_PressCount)

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

; ========================= EFFECT STYLE TOGGLE =========================

_INT_B_Down(*) {
    Critical "On"
    global gGUI_State, gGUI_OverlayVisible, gGUI_EffectStyle, FX_STYLE_NAMES

    if (gGUI_State != "ACTIVE" || !gGUI_OverlayVisible)
        return

    ; Cycle through effect styles
    ; FX_STYLE_NAMES includes GPU styles when available (built by FX_BuildStyleNames)
    gGUI_EffectStyle := Mod(gGUI_EffectStyle + 1, FX_STYLE_NAMES.Length)

    ; Show tooltip with current style name and GPU indicator
    styleName := FX_STYLE_NAMES[gGUI_EffectStyle + 1]
    gpuTag := (gGUI_EffectStyle >= 2) ? " [GPU]" : ""
    ToolTip("Style: " styleName gpuTag)
    SetTimer(() => ToolTip(), -2000)

    ; Repaint immediately with new style
    GUI_Repaint()
}

; ========================= FPS DEBUG OVERLAY TOGGLE =========================

_INT_F_Down(*) {
    Critical "On"
    global gGUI_State, gGUI_OverlayVisible, gAnim_FPSEnabled

    if (gGUI_State != "ACTIVE" || !gGUI_OverlayVisible)
        return

    gAnim_FPSEnabled := !gAnim_FPSEnabled
    GUI_Repaint()
}

; ========================= BACKDROP STYLE CYCLING =========================

_INT_C_Down(*) {
    Critical "On"
    global gGUI_State, gGUI_OverlayVisible, gFX_BackdropStyle, FX_BG_STYLE_NAMES
    global gFX_GPUReady

    if (gGUI_State != "ACTIVE" || !gGUI_OverlayVisible)
        return
    if (!gFX_GPUReady)
        return

    gFX_BackdropStyle := Mod(gFX_BackdropStyle + 1, FX_BG_STYLE_NAMES.Length)

    styleName := FX_BG_STYLE_NAMES[gFX_BackdropStyle + 1]
    ToolTip("Backdrop: " styleName)
    SetTimer(() => ToolTip(), -2000)

    GUI_Repaint()
}

; ========================= BYPASS DETECTION =========================

; Called from _GUI_OnProducerRevChanged() when focus changes to check bypass criteria
; RACE FIX: Wrap in Critical - flag set + hotkey toggle must be atomic
; to prevent Tab callback from seeing inconsistent state (flag true but hotkey still on)
INT_SetBypassMode(shouldBypass) {
    Critical "On"
    global gINT_BypassMode, cfg

    global FR_EV_BYPASS, gFR_Enabled
    if (shouldBypass && !gINT_BypassMode) {
        ; Entering bypass mode - disable Tab hooks
        if (gFR_Enabled)
            FR_Record(FR_EV_BYPASS, 1)
        if (cfg.DiagEventLog)
            GUI_LogEvent("INT: Entering BYPASS MODE, disabling Tab hotkey")
        gINT_BypassMode := true
        try {
            Hotkey("$*Tab", "Off")
            Hotkey("$*Tab Up", "Off")
        } catch as e {
            if (cfg.DiagEventLog)
                GUI_LogEvent("INT: BYPASS Hotkey Off FAILED: " e.Message)
        }
    } else if (!shouldBypass && gINT_BypassMode) {
        ; Leaving bypass mode - re-enable Tab hooks
        if (gFR_Enabled)
            FR_Record(FR_EV_BYPASS, 0)
        if (cfg.DiagEventLog)
            GUI_LogEvent("INT: Leaving BYPASS MODE, re-enabling Tab hotkey")
        gINT_BypassMode := false
        try {
            Hotkey("$*Tab", "On")
            Hotkey("$*Tab Up", "On")
        } catch as e {
            if (cfg.DiagEventLog)
                GUI_LogEvent("INT: BYPASS Hotkey On FAILED: " e.Message)
        }
    }
    Critical "Off"
}

; Re-assert Tab hotkey is enabled when bypass is off.
; No-op when hooks are healthy (Hotkey("On") on an already-On hotkey just returns).
; Recovers from silent desync where Tab was left Off after a bypass toggle.
; Called from: focus-change callback (active use) and housekeeping timer (idle).
INT_ReassertTabHotkey() {
    global gINT_BypassMode
    if (gINT_BypassMode)
        return
    try {
        Hotkey("$*Tab", "On")
        Hotkey("$*Tab Up", "On")
    }
}

_INT_BuildBypassList() {
    global cfg
    list := []
    if (cfg.AltTabBypassProcesses = "")
        return list
    for _, nm in StrSplit(cfg.AltTabBypassProcesses, ",") {
        nm := Trim(nm)
        if (nm != "")
            list.Push(StrLower(nm))
    }
    return list
}

; Check bypass criteria for a specific window (or active window if hwnd=0)
; Also logs the reason when bypass is triggered (under DiagEventLog)
INT_ShouldBypassWindow(hwnd := 0) {
    global cfg

    if (hwnd = 0)
        hwnd := WinExist("A")
    if (!hwnd)
        return false

    ; Check process blacklist (list pre-computed once per process lifetime)
    static bypassList := _INT_BuildBypassList()
    if (bypassList.Length > 0) {
        exename := ""
        try exename := WinGetProcessName(hwnd)
        if (exename) {
            lex := StrLower(exename)
            for _, nm in bypassList {
                if (nm = lex) {
                    if (cfg.DiagEventLog)
                        GUI_LogEvent("BYPASS REASON: process='" exename "' hwnd=" hwnd)
                    return true
                }
            }
        }
    }

    ; Check fullscreen detection
    if (cfg.AltTabBypassFullscreen && _INT_IsFullscreenHwnd(hwnd)) {
        if (cfg.DiagEventLog)
            GUI_LogEvent("BYPASS REASON: fullscreen hwnd=" hwnd)
        return true
    }

    return false
}

_INT_IsFullscreenHwnd(hwnd) {
    global cfg
    local x, y, w, h
    try {
        WinGetPos(&x, &y, &w, &h, hwnd)
    } catch {
        return false
    }
    if (!IsSet(w) || !IsSet(h))
        return false
    ; Get the full monitor bounds for this window's monitor (not just primary)
    mL := 0, mT := 0, mR := 0, mB := 0
    Win_GetMonitorBoundsFromHwnd(hwnd, &mL, &mT, &mR, &mB)
    monW := mR - mL
    monH := mB - mT
    if (monW <= 0 || monH <= 0)
        return false
    ; Compare against THIS monitor's dimensions with origin-relative tolerance
    return (w >= monW * cfg.AltTabBypassFullscreenThreshold
        && h >= monH * cfg.AltTabBypassFullscreenThreshold
        && Abs(x - mL) <= cfg.AltTabBypassFullscreenTolerancePx
        && Abs(y - mT) <= cfg.AltTabBypassFullscreenTolerancePx)
}
