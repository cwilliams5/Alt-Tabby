#Requires AutoHotkey v2.0
#SingleInstance Off  ; Allow parallel instances for --live-core/features/execution
#Warn VarUnset, Off  ; Suppress warnings for functions defined in includes
A_IconHidden := true  ; No tray icon during tests

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

; --- Testing mode flag (suppresses dialogs in setup_utils.ahk) ---
global g_TestingMode := true
global gStore_TestMode := false  ; Process utils test mode (from store_server.ahk)

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

; --- Check for flags (BEFORE log init to set suite-specific log paths) ---
DoLiveTests := false
DoLiveCore := false
DoLiveFeatures := false
DoLiveExecution := false
for _, arg in A_Args {
    if (arg = "--live")
        DoLiveTests := true
    else if (arg = "--live-core")
        DoLiveCore := true
    else if (arg = "--live-features")
        DoLiveFeatures := true
    else if (arg = "--live-execution")
        DoLiveExecution := true
}

; Single-suite modes use a dedicated log file to avoid file locking
; conflicts when multiple instances run in parallel
if (DoLiveCore)
    TestLogPath := A_Temp "\alt_tabby_tests_core.log"
else if (DoLiveFeatures)
    TestLogPath := A_Temp "\alt_tabby_tests_features.log"
else if (DoLiveExecution)
    TestLogPath := A_Temp "\alt_tabby_tests_execution.log"

; --- Error handler BEFORE any I/O to catch early startup errors ---
OnError(_Test_OnError)

_Test_OnError(err, *) {
    global TestErrors
    Log("ERROR: Unhandled exception")
    Log("  Message: " err.Message)
    Log("  File: " err.File)
    Log("  Line: " err.Line)
    TestErrors++
    return true  ; Suppress default error dialog
}

; --- Initialize log (after path is finalized, error handler is active) ---
try FileDelete(TestLogPath)
Log("=== Alt-Tabby Test Run " FormatTime(, "yyyy-MM-dd HH:mm:ss") " ===")
Log("Log file: " TestLogPath)

; ============================================================
; Include PRODUCTION files (tests call real functions)
; ============================================================
#Include %A_ScriptDir%\..\src\shared\config_loader.ahk
#Include %A_ScriptDir%\..\src\shared\cjson.ahk
#Include %A_ScriptDir%\..\src\shared\ipc_pipe.ahk
#Include %A_ScriptDir%\..\src\shared\blacklist.ahk
#Include %A_ScriptDir%\..\src\shared\setup_utils.ahk
#Include %A_ScriptDir%\..\src\shared\process_utils.ahk
#Include %A_ScriptDir%\..\src\shared\win_utils.ahk
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

; --- Determine what to run ---
; Single-suite modes skip unit tests (they run in the main process)
isSingleSuite := DoLiveCore || DoLiveFeatures || DoLiveExecution

if (!isSingleSuite) {
    ; --- Always run unit tests in full/default mode ---
    RunUnitTests()
}

; --- Run live tests ---
if (DoLiveTests) {
    ; Full sequential mode (backward compat)
    RunLiveTests()
} else if (DoLiveCore) {
    RunLiveTests_Core()
} else if (DoLiveFeatures) {
    RunLiveTests_Features()
} else if (DoLiveExecution) {
    RunLiveTests_Execution()
}

; --- Summary ---
Log("`n=== Test Summary ===")
Log("Passed: " TestPassed)
Log("Failed: " TestErrors)
Log("Result: " (TestErrors = 0 ? "ALL TESTS PASSED" : "SOME TESTS FAILED"))

ExitApp(TestErrors > 0 ? 1 : 0)
