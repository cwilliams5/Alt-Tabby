#Requires AutoHotkey v2.0
#SingleInstance Force
#UseHook true                          ; force hook for all keyboard hotkeys.

; Ensure the keyboard hook is up from the start (predictable ordering/behavior)
InstallKeybdHook(true)  ; v2 function — replaces #InstallKeybdHook directive.

; Prevent Alt/Win menu side-effects with an inert mask key (vkE8).
; AHK auto-masks Alt/Win-up after suppressed hotkeys; vkE8 has no side-effects. 
A_MenuMaskKey := "vkE8"

#Include config.ahk
#Include helpers.ahk ; provides _Log, RunTry, etc.
#Include komorebi.ahk ; include after helpers.ahk  ; uses _Log, RunTry
#Include komorebi_sub.ahk ; include after helpers.ahk AND after komorebi.ahk
#Include winenum.ahk
#Include mru.ahk
#Include tabby_ipc.ahk
#Include gui.ahk
#Include altlogic.ahk 

ALTAB_Init()           ; start everything 
Komorebi_SubEnsure()
Komorebi_DebugPing()   ; optional, do a debug ping at start of debug log
; Confirm 528146
    