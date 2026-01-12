#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
; Alt+Tab Interceptor - MICRO process for maximum speed
; ============================================================
; This runs as a separate process to ensure Alt+Tab interception
; is never delayed by other script processing.
;
; Communication: PostMessage broadcast (non-blocking)
; Events sent:
;   TAB_STEP (1) - Tab pressed during Alt session
;   ALT_UP (2)   - Alt released, session complete
; ============================================================

#UseHook true                    ; Beat Windows for Alt+Tab
InstallKeybdHook(true)           ; Hook keyboard immediately
A_MenuMaskKey := "vkE8"          ; Suppress Alt menu side-effects

#Include %A_ScriptDir%\interceptor_ipc.ahk

; ============================================================
; CONFIGURATION
; ============================================================
global UseAltGrace := true       ; Allow Tab shortly after Alt press
global AltGraceMs := 80          ; Grace period in ms
global DisableInProcesses := []  ; Process names to bypass (e.g., "valorant.exe")
global DisableInFullscreen := true  ; Bypass in fullscreen apps

; ============================================================
; STATE
; ============================================================
global sessionActive := false
global tabHeld := false
global pressCount := 0
global lastAltDown := -999999

; Alt leak control
global altArmed := false
global altConsumed := false
global altPassed := false

; ============================================================
; QUIT
; ============================================================
Quit(*) {
    ExitApp()
}
Hotkey("$*!F12", Quit)           ; Alt+F12 emergency exit
A_TrayMenu.Add("Exit", Quit)

; ============================================================
; ALT TRACKING
; ============================================================
Alt_Down(*) {
    global lastAltDown, altArmed, altConsumed, altPassed
    lastAltDown := A_TickCount
    altArmed := true
    altConsumed := false
    altPassed := false
    if (UseAltGrace)
        SetTimer(Alt_PassthroughMaybe, -AltGraceMs)
}

Alt_PassthroughMaybe() {
    global altArmed, altConsumed, altPassed
    if (!altArmed || altConsumed || altPassed)
        return
    ; Alt held without Tab -> allow OS menus
    if GetKeyState("Alt", "P") {
        Send("{Alt Down}")
        altPassed := true
    }
}

Alt_Up(*) {
    global sessionActive, pressCount, altArmed, altConsumed, altPassed, tabHeld
    altArmed := false

    ; Handle OS Alt state
    if (altPassed) {
        Send("{Alt Up}")
    } else if (!altConsumed) {
        ; Bare Alt tap - reproduce default
        Send("{Alt}")
    }

    ; Notify switcher if session occurred
    if (sessionActive && pressCount >= 1) {
        TABBY_IPC_Post(TABBY_EV_ALT_UP, 0, 0)
    }

    ; Reset state
    sessionActive := false
    pressCount := 0
    tabHeld := false
    altConsumed := false
    altPassed := false
}

; ============================================================
; HOOKS
; ============================================================
Hotkey("$*Alt", Alt_Down)
Hotkey("$*Alt Up", Alt_Up)
Hotkey("$*Tab", Tab_Down)
Hotkey("$*Tab Up", Tab_Up)

; ============================================================
; HELPERS
; ============================================================
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
    return GetKeyState("Alt", "P") || (UseAltGrace && ((A_TickCount - lastAltDown) <= AltGraceMs))
}

IsFullscreenApprox(win := "A") {
    local x := 0, y := 0, w := 0, h := 0
    try WinGetPos(&x, &y, &w, &h, win)
    return (w >= A_ScreenWidth * 0.99 && h >= A_ScreenHeight * 0.99 && x <= 5 && y <= 5)
}

; ============================================================
; TAB HANDLING
; ============================================================
Tab_Down(*) {
    global sessionActive, tabHeld, altConsumed, pressCount

    ; Bypass for games/fullscreen
    if ShouldBypassForGame() {
        Send(GetKeyState("Shift", "P") ? "+{Tab}" : "{Tab}")
        return
    }

    ; Not in Alt combo - pass through
    if !IsAltComboNowOrJustPressed() {
        Send(GetKeyState("Shift", "P") ? "+{Tab}" : "{Tab}")
        return
    }

    ; Already held - ignore repeat
    if (tabHeld)
        return
    tabHeld := true

    ; We're in Alt+Tab - consume Alt, don't leak
    altConsumed := true
    try Send("{Blind}{vkE8}")

    ; Start or continue session
    if (!sessionActive) {
        sessionActive := true
        pressCount := 0
    }

    pressCount += 1

    ; Notify switcher immediately
    shiftFlag := GetKeyState("Shift", "P") ? TABBY_FLAG_SHIFT : 0
    TABBY_IPC_Post(TABBY_EV_TAB_STEP, shiftFlag, 0)
}

Tab_Up(*) {
    global tabHeld
    tabHeld := false
}
