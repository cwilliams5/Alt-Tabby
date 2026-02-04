; GUI Tests Entry Point
; Runs all GUI state machine tests via split files
#Requires AutoHotkey v2.0
#Warn VarUnset, Off
A_IconHidden := true  ; No tray icon during tests

; Include common globals, mocks, utilities
#Include gui_tests_common.ahk

; Include test modules (entry points skip because A_ScriptFullPath != A_LineFile)
#Include gui_tests_state.ahk
#Include gui_tests_data.ahk

; ============================================================
; RUN ALL TESTS
; ============================================================

try FileDelete(A_Temp "\gui_tests.log")

GUI_Log("=== Alt-Tabby GUI Tests ===")
GUI_Log("Running split test modules...")

; Run state tests
stateResult := RunGUITests_State()

; Run data tests
dataResult := RunGUITests_Data()

; ============================================================
; SUMMARY
; ============================================================

GUI_Log("`n=== GUI Tests Complete ===")
GUI_Log("State tests: " (stateResult ? "PASS" : "FAIL"))
GUI_Log("Data tests: " (dataResult ? "PASS" : "FAIL"))
GUI_Log("Total Passed: " GUI_TestPassed)
GUI_Log("Total Failed: " GUI_TestFailed)
GUI_Log("Result: " (GUI_TestFailed = 0 ? "ALL TESTS PASSED" : "SOME TESTS FAILED"))

ExitApp(GUI_TestFailed > 0 ? 1 : 0)
