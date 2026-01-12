; ================== CONFIG (tweak freely) ==================
; ---- Debug toggles ----
global DebugKomorebi := false        
global DebugBlacklist := false 
global DebugLogPath   := A_ScriptDir "\tabby_debug.log"
global DebugMaxLinesPerSession := 200    ; optional
global DebugMaxDurationMs := 200         ; optional

global HoldMs           := 200      ; overlay delay (ms) when holding Alt after first Tab
global UseAltGrace      := false     ; true: global Tab+grace; false: only when Alt physically down
global AltGraceMs       := 80       ; grace window for Alt pressed just before Tab
global DisableInProcesses := [      ; e.g. "valorant.exe", "eldenring.exe"
]
global DisableInFullscreen := false  ; bypass in fullscreen-looking windows
global OverlayFont       := "Segoe UI"
global OverlayTitle      := "Switch"    ; window title for overlay (we also blacklist it)
; add these near the top with other tunables:
global UseMRU            := true   ; true: build cycling list from MRU ring vs pure Z-order
global SwitchCloakedMode := "ignore"  ; "ignore" | "toast"
; "ignore": do nothing if target is in other Komorebi workspace
; "toast":  show small tooltip explaining why no switch happened
global UseAltTabEligibility := true   ; filter windows like native Alt-Tab


; alt tab fighting
BlockBareAlt := true
UseAltComboHook := true
RefreshOnOverlay := true ; rebuild list when overlay first appears
RefreshOnAltUp := true ; rebuild list just before activation

; === NEW: overlay + icons ===
global UseIcons            := true           ; show app icons in the list
global IconBatchPerTick    := 3              ; how many icons to resolve per timer tick
global IconTimerIntervalMs := 15             ; timer cadence for icon loading
global IconSizePx          := 64             ; small icon size

; === NEW: komorebi integration ===
global FocusCloakedViaKomorebi := true
global KomorebicExe := "C:\Program Files\komorebi\bin\komorebic.exe"  ; <— set to your actual path

; === Blacklists for enumeration (AHK wildcard, case-insensitive) ===
global BlacklistTitle := [
  "komoborder*",
  "YasbBar",
  "NVIDIA GeForce Overlay",
  "DWM Notification Window",
  "MSCTFIME UI",
  "Default IME",
  "Task Switching",
  "Command Palette",
  "GDI+ Window (OneDrive.exe)",
  "Windows Input Experience",
  OverlayTitle            ; avoid listing our own overlay
]
global BlacklistClass := [
  "komoborder*",
  "CEF-OSC-WIDGET",
  "Dwm",
  "MSCTFIME UI",
  "IME",
  "GDI+ Hook Window Class",
  "XamlExplorerHostIslandWindow",
  "WinUIDesktopWin32WindowClass",
  "Windows.UI.Core.CoreWindow",
  "AutoHotkeyGUI"         ; avoid listing any AHK GUI (including ours)
]
; Class+Title pair blacklist (both must match). Wildcards * and ? are OK (case-insensitive).
global BlacklistPair := []

;; Class+Title (exact):
BlacklistPair.Push({ Class: "GDI+ Hook Window Class", Title: "GDI+ Window (OneDrive.exe)" })

; ================== EXIT HOTKEY ==================
global QuitHotkey := "$*!F12"  ; Alt+F12


