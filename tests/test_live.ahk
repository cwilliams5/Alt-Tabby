#Requires AutoHotkey v2.0
#Include ..\src\shared\config.ahk

; Live integration test harness (observes real system state).

TestLiveDurationSec_Override := ""  ; set to a number to override config

if (TestLiveDurationSec_Override != "")
    TestLiveDurationSec := TestLiveDurationSec_Override
else if IsSet(TestLiveDurationSec_Default)
    TestLiveDurationSec := TestLiveDurationSec_Default
else
    TestLiveDurationSec := 30

TestLiveLogPath := A_ScriptDir "\windowstore_live.log"

FileAppend("test_live start " FormatTime(, "yyyy-MM-dd HH:mm:ss") "`n", TestLiveLogPath, "UTF-8")

SetTimer(TestLive_Tick, 250)
SetTimer(TestLive_Stop, -TestLiveDurationSec * 1000)

return

TestLive_Tick() {
    ; TODO: start store + producers, subscribe, and log snapshots/deltas.
}

TestLive_Stop() {
    global TestLiveLogPath
    FileAppend("test_live done " FormatTime(, "yyyy-MM-dd HH:mm:ss") "`n", TestLiveLogPath, "UTF-8")
    ExitApp()
}