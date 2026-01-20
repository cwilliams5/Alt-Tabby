#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn VarUnset, Off  ; Suppress warnings for functions defined in includes

; Automated test runner - Orchestrates all test suites
; Usage: AutoHotkey64.exe tests/run_tests.ahk [--live]
;
; Test files:
;   - test_utils.ahk: Log, Assert helpers, IPC test callbacks
;   - test_unit.ahk:  Unit tests (WindowStore, Config, Entry Points)
;   - test_live.ahk:  Live integration tests (require --live flag)

; --- Global test state ---
global TestLogPath := A_Temp "\alt_tabby_tests.log"
global TestErrors := 0
global TestPassed := 0

; --- IPC test globals (used by test_utils.ahk callbacks) ---
global testServer := 0
global gTestClient := 0
global gTestResponse := ""
global gTestResponseReceived := false
global gRealStoreResponse := ""
global gRealStoreReceived := false
global gViewerTestResponse := ""
global gViewerTestReceived := false
global gViewerTestHelloAck := false
global gWsE2EResponse := ""
global gWsE2EReceived := false
global gHbTestHeartbeats := 0
global gHbTestLastRev := -1
global gHbTestReceived := false
global gProdTestProducers := ""
global gProdTestReceived := false
global gMruTestResponse := ""
global gMruTestReceived := false
global gProjTestResponse := ""
global gProjTestReceived := false
global gMultiClient1Response := ""
global gMultiClient1Received := false
global gMultiClient2Response := ""
global gMultiClient2Received := false
global gMultiClient3Response := ""
global gMultiClient3Received := false
global gBlTestResponse := ""
global gBlTestReceived := false
global gStandaloneTestReceived := false
global gCompiledStoreReceived := false

; --- Initialize log ---
try FileDelete(TestLogPath)
Log("=== Alt-Tabby Test Run " FormatTime(, "yyyy-MM-dd HH:mm:ss") " ===")
Log("Log file: " TestLogPath)

; --- Check for --live flag ---
DoLiveTests := false
for _, arg in A_Args {
    if (arg = "--live")
        DoLiveTests := true
}

; ============================================================
; Include PRODUCTION files (tests call real functions)
; ============================================================
#Include %A_ScriptDir%\..\src\shared\config_loader.ahk
#Include %A_ScriptDir%\..\src\shared\json.ahk
#Include %A_ScriptDir%\..\src\shared\ipc_pipe.ahk
#Include %A_ScriptDir%\..\src\shared\blacklist.ahk
#Include %A_ScriptDir%\..\src\store\windowstore.ahk
#Include %A_ScriptDir%\..\src\store\winenum_lite.ahk
#Include %A_ScriptDir%\..\src\store\komorebi_sub.ahk
#Include %A_ScriptDir%\..\src\store\icon_pump.ahk

; ============================================================
; Include TEST files (utilities, callbacks, test functions)
; ============================================================
#Include %A_ScriptDir%\test_utils.ahk
#Include %A_ScriptDir%\test_unit.ahk
#Include %A_ScriptDir%\test_live.ahk

; ============================================================
; Initialize and run tests
; ============================================================

; Initialize config (sets all defaults from gConfigRegistry)
ConfigLoader_Init(A_ScriptDir "\..\src")

; Initialize blacklist before tests
Blacklist_Init(A_ScriptDir "\..\src\shared\blacklist.txt")

; --- Always run unit tests ---
RunUnitTests()

; --- Run live tests if --live flag provided ---
if (DoLiveTests) {
    RunLiveTests()
}

; --- Summary ---
Log("`n=== Test Summary ===")
Log("Passed: " TestPassed)
Log("Failed: " TestErrors)
Log("Result: " (TestErrors = 0 ? "ALL TESTS PASSED" : "SOME TESTS FAILED"))

ExitApp(TestErrors > 0 ? 1 : 0)
