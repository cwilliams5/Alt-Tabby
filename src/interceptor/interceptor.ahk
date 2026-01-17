; ================== Alt+Tab Intercept MICRO — Alt pass-through, Tab deferred ==================
; Based on battle-tested interceptor3.ahk
; Alt is NEVER blocked - just observed. Tab is briefly deferred to decide if it's Alt+Tab.
#Requires AutoHotkey v2.0
#SingleInstance Force
#UseHook true
InstallKeybdHook(true)

; Use an inert mask key so Alt taps don't focus menus, without blocking Alt itself.
A_MenuMaskKey := "vkE8"

#Include %A_ScriptDir%\interceptor_ipc.ahk

; ================== CONFIG ==================
; Tiny non-blocking Tab decision window
global DecisionMs := 24           ; 16-24ms works well
; Accept Alt pressed within this window (handles timing edge cases)
global LastAltLeewayMs := 60
; Bypass in these processes or fullscreen
global DisableInProcesses := []
global DisableInFullscreen := true

; ================== STATE ==================
global sessionActive := false
global tabHeld := false
global pressCount := 0
global lastAltDown := -999999
global altIsDown := false  ; Track Alt state via hotkey handlers (more reliable than GetKeyState)

; Deferred-Tab decision state
global tabPending := false
global tabUpSeen := false
global pendingShift := false
global pendingDecideArmed := false
global altUpDuringPending := false  ; Track if Alt released before Tab_Decide fires

; ================== QUIT ====================
Quit(*) => ExitApp()
Hotkey("$*!F12", Quit)
A_TrayMenu.Add("Exit", Quit)

; ================== ALT TRACKING (pass-through; just timestamp + mask nudge) =====
; We don't block Alt at all, so Alt+F at 10ms works. We only prevent the "Alt tap → menu" side-effect.
Hotkey("~*Alt", Alt_Down)
Hotkey("~*Alt Up", Alt_Up)

Alt_Down(*) {
    global lastAltDown, altIsDown
    altIsDown := true
    lastAltDown := A_TickCount
    ; Paranoia: nudge the mask at Alt down (A_MenuMaskKey already handles masking)
    try Send("{Blind}{vkE8}")
    ; Notify GUI for pre-warm (request snapshot before Tab)
    TABBY_IPC_Post(TABBY_EV_ALT_DOWN, 0, 0)
}

Alt_Up(*) {
    global sessionActive, pressCount, tabHeld, tabPending, altUpDuringPending, altIsDown
    ; No synthetic Alt sends—Alt was never blocked.
    altIsDown := false  ; Track that Alt is released

    ; If Tab decision is pending, mark that Alt was released (for Tab_Decide to check)
    if (tabPending) {
        altUpDuringPending := true
        ToolTip("AU: flag set", 100, 400, 6)
        SetTimer(() => ToolTip(,,,6), -2000)
        ; Don't send ALT_UP here - Tab_Decide will do it
    } else if (sessionActive && pressCount >= 1) {
        ToolTip("AU: sent", 100, 400, 6)
        SetTimer(() => ToolTip(,,,6), -2000)
        TABBY_IPC_Post(TABBY_EV_ALT_UP, 0, 0)
    } else {
        ToolTip("AU: skip", 100, 400, 6)
        SetTimer(() => ToolTip(,,,6), -2000)
    }
    sessionActive := false
    pressCount := 0
    tabHeld := false
}

; ================== TAB HOOKS ===================
Hotkey("$*Tab", Tab_Down_Global)
Hotkey("$*Tab Up", Tab_Up)

; ================== ESCAPE HOOK ===================
Hotkey("$*Escape", Escape_Down)

; ================== HELPERS =================
ShouldBypassForGame() {
    global DisableInProcesses, DisableInFullscreen
    exename := ""
    try exename := WinGetProcessName("A")
    if (exename) {
        lex := StrLower(exename)
        for _, nm in DisableInProcesses
            if (StrLower(nm) = lex)
                return true
    }
    return DisableInFullscreen && IsFullscreenApprox("A")
}

IsFullscreenApprox(win := "A") {
    local x := 0, y := 0, w := 0, h := 0
    try WinGetPos(&x, &y, &w, &h, win)
    return (w >= A_ScreenWidth * 0.99 && h >= A_ScreenHeight * 0.99 && x <= 5 && y <= 5)
}

; ================== CORE: TAB (deferred decision; never delays Alt) ==================
Tab_Down_Global(*) {
    global tabPending, tabHeld, pendingShift, tabUpSeen, pendingDecideArmed, DecisionMs, altUpDuringPending

    if ShouldBypassForGame() {
        Send(GetKeyState("Shift", "P") ? "+{Tab}" : "{Tab}")
        return
    }
    ; Already pending, OR currently held by an Alt+Tab step (blocks key repeat!)
    if (tabPending || tabHeld)
        return

    ; Swallow Tab briefly and decide soon whether this is Alt+Tab or a plain Tab.
    tabPending := true
    pendingShift := GetKeyState("Shift", "P")
    tabUpSeen := false
    pendingDecideArmed := true
    altUpDuringPending := false  ; Reset for new decision window
    SetTimer(Tab_Decide, -DecisionMs)
}

Tab_Up(*) {
    global tabHeld, tabPending, tabUpSeen
    if (tabHeld) {
        ; We committed this keystroke as an Alt+Tab step—release "held" state.
        tabHeld := false
        return
    }
    ; If we're still deciding, remember that physical Tab already went up.
    if (tabPending)
        tabUpSeen := true
}

Tab_Decide() {
    global pendingDecideArmed
    if (!pendingDecideArmed)
        return
    pendingDecideArmed := false
    ; Delay 1ms to let any pending Alt_Up hotkey run first
    SetTimer(Tab_Decide_Inner, -1)
}

Tab_Decide_Inner() {
    global tabPending, tabUpSeen, pendingShift, altUpDuringPending
    global lastAltDown, LastAltLeewayMs, altIsDown
    global sessionActive, pressCount, tabHeld

    ; Capture state BEFORE any ToolTip (which can pump messages and let Alt_Up run)
    altDownNow := altIsDown
    altUpFlag := altUpDuringPending
    altRecent := (A_TickCount - lastAltDown) <= LastAltLeewayMs
    isAltTab := altDownNow || altRecent || altUpFlag

    ; DEBUG: Show decision state
    ToolTip("TD: d=" altDownNow " f=" altUpFlag, 100, 300, 4)
    SetTimer(() => ToolTip(,,,4), -2000)

    if (isAltTab) {
        ; Commit as Alt+Tab step (send to receiver via IPC)
        tabPending := false

        if (!sessionActive) {
            sessionActive := true
            pressCount := 0
        }
        pressCount += 1

        shiftFlag := pendingShift ? TABBY_FLAG_SHIFT : 0
        TABBY_IPC_Post(TABBY_EV_TAB_STEP, shiftFlag, 0)

        ; Maintain a simple "held Tab" flag until the physical key-up arrives (if it hasn't already).
        tabHeld := !tabUpSeen

        ; CRITICAL: If Alt was released during the decision window, send ALT_UP now!
        ; Use captured altDownNow (not current altIsDown which may have changed during ToolTip)
        if (!altDownNow || altUpFlag) {
            ; Send ALT_UP IMMEDIATELY - no SetTimer delay
            TABBY_IPC_Post(TABBY_EV_ALT_UP, 0, 0)
            ToolTip("TD: +ALT_UP sent!", 100, 350, 5)
            SetTimer(() => ToolTip(,,,5), -2000)
            sessionActive := false
            pressCount := 0
            tabHeld := false
            altUpDuringPending := false
        } else {
            ToolTip("TD: wait AU", 100, 350, 5)
            SetTimer(() => ToolTip(,,,5), -2000)
        }
    } else {
        ; Not Alt+Tab → replay a normal Tab immediately (respect Shift).
        tabPending := false
        Send(pendingShift ? "+{Tab}" : "{Tab}")
    }
}

; ================== ESCAPE HANDLING ==================
Escape_Down(*) {
    global sessionActive, pressCount, tabHeld

    ; Only consume Escape if we're in an active Alt+Tab session
    if (!sessionActive || pressCount < 1) {
        Send("{Escape}")
        return
    }

    ; Notify GUI to cancel (hide without activating)
    TABBY_IPC_Post(TABBY_EV_ESCAPE, 0, 0)

    ; Reset session state
    sessionActive := false
    pressCount := 0
    tabHeld := false
}
