#Requires AutoHotkey v2.0

; Deterministic fixture test harness (no real system interaction).

TestFixtureLogPath := A_ScriptDir "\windowstore_fixture.log"

FileAppend("test_fixture start " FormatTime(, "yyyy-MM-dd HH:mm:ss") "`n", TestFixtureLogPath, "UTF-8")
; TODO: inject fake producer events and assert projection ordering.
FileAppend("test_fixture done " FormatTime(, "yyyy-MM-dd HH:mm:ss") "`n", TestFixtureLogPath, "UTF-8")
ExitApp()