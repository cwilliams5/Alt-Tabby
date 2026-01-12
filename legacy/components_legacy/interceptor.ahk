; ================== Alt+Tab Intercept MICRO (no GUI) ==================
#Requires AutoHotkey v2.0
#SingleInstance Force
#UseHook true                 ; ensure we beat Windows for Alt+Tab
InstallKeybdHook(true)         ; bring the hook up immediately
A_MenuMaskKey := "vkE8"  ; suppress Alt menu side-effects reliably


; ---- Optional: share a couple config toggles from your existing config ----
; You can comment these two includes if you prefer local settings here.
#Include config.ahk
#Include tabby_ipc.ahk

; ================== CONFIG (local defaults if not in config.ahk) ==================
if !IsSet(HoldMs)              ; not used here, but harmless if defined
    HoldMs := 350
if !IsSet(UseAltGrace)
    UseAltGrace := true
if !IsSet(AltGraceMs)
    AltGraceMs := 80
if !IsSet(DisableInProcesses)
    DisableInProcesses := []
if !IsSet(DisableInFullscreen)
    DisableInFullscreen := true

; ================== STATE ==================
sessionActive := false
tabHeld       := false
pressCount    := 0
lastAltDown   := -999999

; Alt leak control (exactly like your POC)
altArmed    := false
altConsumed := false
altPassed   := false

; ================== QUIT ====================
Quit(*) {
    ExitApp()
}
Hotkey("$*!F12", Quit)         ; Alt+F12 emergency exit
A_TrayMenu.Add("Exit", Quit)

; ================== ALT TRACKING (grace pass-through only) =====
Alt_Down(*) {
    global lastAltDown, altArmed, altConsumed, altPassed, AltGraceMs
    lastAltDown := A_TickCount
    altArmed    := true
    altConsumed := false
    altPassed   := false
    if (UseAltGrace)
        SetTimer(Alt_PassthroughMaybe, -AltGraceMs)
}

Alt_PassthroughMaybe() {
    global altArmed, altConsumed, altPassed
    if (!altArmed || altConsumed || altPassed)
        return
    if GetKeyState("Alt","P") {         ; Alt is being held without Tab → allow OS menus
        Send "{Alt Down}"
        altPassed := true
    }
}

Alt_Up(*) {
    global sessionActive, pressCount, altArmed, altConsumed, altPassed
    altArmed := false

    ; Finalize OS Alt state (no blocking, trivial)
    if (altPassed) {
        Send "{Alt Up}"
    } else if (!altConsumed) {
        ; Bare-Alt tap—reproduce default behavior (keeps OS happy)
        Send "{Alt}"
    }
    ; If a real Alt+Tab session happened, notify the switcher.
    if (sessionActive && pressCount >= 1) {
        TABBY_IPC_Post(2, 0, 0)         ; 2 = ALT_UP
    }
    sessionActive := false
    pressCount    := 0
    tabHeld       := false
    altConsumed   := false
    altPassed     := false
}

; ================== HOOKS ===================
Hotkey("$*Alt",    Alt_Down)    ; NOTE: we block Alt initially (no "~")
Hotkey("$*Alt Up", Alt_Up)

; Global Tab hook + grace → fastest & most forgiving
Hotkey("$*Tab",    Tab_Down_Global)
Hotkey("$*Tab Up", Tab_Up)

; ================== DECISION HELPERS =========
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

IsAltComboNowOrJustPressed() {
    global lastAltDown, AltGraceMs
    return GetKeyState("Alt","P") || (!UseAltGrace ? false : ((A_TickCount - lastAltDown) <= AltGraceMs))
}

IsFullscreenApprox(win := "A") {
    local x:=0,y:=0,w:=0,h:=0
    try WinGetPos &x,&y,&w,&h, win
    return (w >= A_ScreenWidth*0.99 && h >= A_ScreenHeight*0.99 && x <= 5 && y <= 5)
}

; ================== CORE: TAB ==================
Tab_Down_Global(*) {
    global sessionActive, tabHeld, altConsumed, pressCount

    if ShouldBypassForGame() {
        Send(GetKeyState("Shift","P") ? "+{Tab}" : "{Tab}")  ; let native OS handle
        return
    }
    if !IsAltComboNowOrJustPressed() {
        Send(GetKeyState("Shift","P") ? "+{Tab}" : "{Tab}")
        return
    }

    if (tabHeld)
        return
    tabHeld := true

    ; We’re in Alt+Tab now — never leak Alt
    altConsumed := true
    try Send "{Blind}{vkE8}"

    if (!sessionActive) {
        sessionActive := true
        pressCount    := 0
    }

    pressCount += 1
    ; Notify switcher about a step (+/-) immediately and asynchronously.
    shiftFlag := GetKeyState("Shift","P") ? 1 : 0
    TABBY_IPC_Post(1, shiftFlag, 0)   ; 1 = TAB_STEP (flags bit0 = shift)
}

Tab_Up(*) {
    global tabHeld
    tabHeld := false
}
