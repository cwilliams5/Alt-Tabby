#Requires AutoHotkey v2.0

; Live integration test harness (observes real system state).
; Edit TestLiveDurationSec to control runtime.

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