#Requires AutoHotkey v2.0

; Shared configuration (v2 only). Add sections as the system evolves.

; ---- Testing ----
; Default duration for test_live.ahk when not overridden there.
TestLiveDurationSec_Default := 30

; ---- Store ----
StorePipeName := "tabby_store_v1"

; ---- Runtime ----
AhkV2Path := "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"

; ---- Producers ----
UseMruLite := true
UseKomorebiSub := true         ; Subscription-based komorebi (preferred)
UseKomorebiLite := false       ; Polling-based komorebi (fallback)
KomorebicExe := "C:\Program Files\komorebi\bin\komorebic.exe"

; ---- Window Enumeration ----
UseWinEventHook := true        ; Event-driven updates (responsive, low CPU)
StoreScanIntervalMs := 2000    ; Polling interval (safety net, can be slower with hook enabled)
UseAltTabEligibility := true   ; Filter windows like native Alt-Tab
UseBlacklist := true           ; Apply title/class blacklists

; ---- Blacklists (AHK wildcard patterns, case-insensitive) ----
global BlacklistTitle := [
    "komoborder*",
    "YasbBar",
    "NVIDIA GeForce Overlay",
    "DWM Notification Window",
    "MSCTFIME UI",
    "Default IME",
    "Task Switching",
    "Command Palette",
    "GDI+ Window*",
    "Windows Input Experience",
    "Program Manager"
]
global BlacklistClass := [
    "komoborder*",
    "CEF-OSC-WIDGET",
    "Dwm",
    "MSCTFIME UI",
    "IME",
    "MSTaskSwWClass",
    "MSTaskListWClass",
    "Shell_TrayWnd",
    "Shell_SecondaryTrayWnd",
    "GDI+ Hook Window Class",
    "XamlExplorerHostIslandWindow",
    "WinUIDesktopWin32WindowClass",
    "Windows.UI.Core.CoreWindow",
    "Qt*QWindow*",
    "AutoHotkeyGUI"
]
; Class+Title pairs (both must match)
global BlacklistPair := [
    { Class: "GDI+ Hook Window Class", Title: "GDI+ Window*" }
]

; ---- Pumps ----
UseIconPump := true
UseProcPump := true

; ---- Viewer ----
DebugViewerLog := false
ViewerAutoStartStore := false
