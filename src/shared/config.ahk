#Requires AutoHotkey v2.0

; Shared configuration (v2 only). Add sections as the system evolves.

; ---- Testing ----
; Default duration for test_live.ahk when not overridden there.
TestLiveDurationSec_Default := 30

; ---- Store ----
StorePipeName := "tabby_store_v1"
StoreScanIntervalMs := 1000

; ---- Runtime ----
AhkV2Path := "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"

; ---- Producers ----
UseMruLite := false
