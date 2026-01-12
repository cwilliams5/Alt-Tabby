; ================== Alt+Tab Intercept MICRO (no GUI) — Alt pass-through, Tab deferred ==================
#Requires AutoHotkey v2.0
#SingleInstance Force
#UseHook true
InstallKeybdHook(true)

; Use an inert mask key so Alt taps don't focus menus, without blocking Alt itself.
; Official v2 docs: A_MenuMaskKey
A_MenuMaskKey := "vkE8"

#Include config.ahk
#Include ipc_targeted.ahk   ; targeted IPC

; ================== CONFIG (local defaults if not in config.ahk) ==================
if !IsSet(HoldMs)               ; (unused here; kept for compatibility with the rest of your app)
    HoldMs := 350
; New: tiny non-blocking Tab decision window + “recent Alt” leeway
if !IsSet(DecisionMs)
    DecisionMs := 24            ; try 16–24ms
if !IsSet(LastAltLeewayMs)
    LastAltLeewayMs := 60       ; accept Alt pressed within this window
if !IsSet(DisableInProcesses)
    DisableInProcesses := []
if !IsSet(DisableInFullscreen)
    DisableInFullscreen := true

; (Back-compat only; no longer used)
if !IsSet(UseAltGrace)
    UseAltGrace := true
if !IsSet(AltGraceMs)
    AltGraceMs := 80

; ================== STATE ==================
sessionActive := false
tabHeld       := false
pressCount    := 0
lastAltDown   := -999999

; Deferred-Tab decision state
tabPending          := false
tabUpSeen           := false
pendingShift        := false
pendingDecideArmed  := false

; ================== START ==================
TABBY_IPC_InitMicro()   ; discover receiver hwnd via HELLO/ACK (non-blocking)

; ================== QUIT ====================
Quit(*) => ExitApp()
Hotkey("$*!F12", Quit)
A_TrayMenu.Add("Exit", Quit)

; ================== ALT TRACKING (pass-through; just timestamp + mask nudge) =====
; We don't block Alt at all, so Alt+F at 10ms works. We only prevent the “Alt tap → menu” side-effect.
Hotkey("~*Alt",    Alt_Down)
Hotkey("~*Alt Up", Alt_Up)

Alt_Down(*) {
    global lastAltDown
    lastAltDown := A_TickCount
    ; Paranoia: nudge the mask at Alt down (A_MenuMaskKey already handles masking)
    try Send "{Blind}{vkE8}"
}

Alt_Up(*) {
    global sessionActive, pressCount, tabHeld
    ; No synthetic Alt sends—Alt was never blocked.
    if (sessionActive && pressCount >= 1) {
        TABBY_IPC_SendAltUp()   ; targeted + redundant pings, async
    }
    sessionActive := false
    pressCount    := 0
    tabHeld       := false
}

; ================== HOOKS ===================
Hotkey("$*Tab",    Tab_Down_Global)
Hotkey("$*Tab Up", Tab_Up)

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
    local x:=0,y:=0,w:=0,h:=0
    try WinGetPos &x,&y,&w,&h, win
    return (w >= A_ScreenWidth*0.99 && h >= A_ScreenHeight*0.99 && x <= 5 && y <= 5)
}

; ================== CORE: TAB (deferred decision; never delays Alt) ==================
Tab_Down_Global(*) {
    global tabPending, pendingShift, tabUpSeen, pendingDecideArmed, DecisionMs

    if ShouldBypassForGame() {
        Send(GetKeyState("Shift","P") ? "+{Tab}" : "{Tab}")
        return
    }
    ; Already pending or currently held by an Alt+Tab step?
    if (tabPending)
        return

    ; Swallow Tab briefly and decide soon whether this is Alt+Tab or a plain Tab.
    tabPending         := true
    pendingShift       := GetKeyState("Shift","P")
    tabUpSeen          := false
    pendingDecideArmed := true
    SetTimer(Tab_Decide, -DecisionMs)
}

Tab_Up(*) {
    global tabHeld, tabPending, tabUpSeen
    if (tabHeld) {
        ; We committed this keystroke as an Alt+Tab step—release “held” state.
        tabHeld := false
        return
    }
    ; If we're still deciding, remember that physical Tab already went up.
    if (tabPending)
        tabUpSeen := true
}

Tab_Decide() {
    global tabPending, tabUpSeen, pendingShift, pendingDecideArmed
    global lastAltDown, LastAltLeewayMs
    global sessionActive, pressCount, tabHeld

    if (!pendingDecideArmed)
        return
    pendingDecideArmed := false

    isAltNow  := GetKeyState("Alt","P")
    altRecent := (A_TickCount - lastAltDown) <= LastAltLeewayMs

    if (isAltNow || altRecent) {
        ; Commit as Alt+Tab step (send to your receiver via IPC)
        tabPending := false

        if (!sessionActive) {
            sessionActive := true
            pressCount    := 0
        }
        pressCount += 1

        shiftFlag := pendingShift ? 1 : 0
        TABBY_IPC_SendStep(shiftFlag)   ; targeted async send

        ; Maintain a simple “held Tab” flag until the physical key-up arrives (if it hasn't already).
        tabHeld := !tabUpSeen
    } else {
        ; Not Alt+Tab → replay a normal Tab immediately (respect Shift).
        tabPending := false
        Send(pendingShift ? "+{Tab}" : "{Tab}")
    }
}
