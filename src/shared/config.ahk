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
; MRU and WinEventHook are always enabled (no config needed)
; Komorebi is optional - gracefully handles missing/broken komorebi
UseKomorebiSub := true         ; Subscription-based komorebi (preferred)
UseKomorebiLite := false       ; Polling-based komorebi (fallback)
KomorebicExe := "C:\Program Files\komorebi\bin\komorebic.exe"

; ---- Window Enumeration ----
; WinEnum runs on-demand: startup, snapshot requests, and as Z-pump
; Optional safety polling if you want belt-and-suspenders
WinEnumSafetyPollMs := 0       ; 0 = disabled (recommended), or 30000+ for paranoid safety net
UseAltTabEligibility := true   ; Filter windows like native Alt-Tab
UseBlacklist := true           ; Apply blacklist from shared/blacklist.txt

; ---- Pumps ----
UseIconPump := true
UseProcPump := true

; ---- Heartbeat ----
StoreHeartbeatIntervalMs := 5000   ; Store sends heartbeat every N ms
ViewerHeartbeatTimeoutMs := 12000  ; Viewer considers connection dead after N ms without message

; ---- Viewer ----
DebugViewerLog := false
ViewerAutoStartStore := false

; ---- Diagnostics ----
DiagChurnLog := true          ; Log rev bump sources to error log (for debugging churn)
