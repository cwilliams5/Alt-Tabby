#Requires AutoHotkey v2.0
#SingleInstance Off  ; Allow parallel instances for --live-core/features/execution
#Warn VarUnset, Off  ; Suppress warnings for functions defined in includes
A_IconHidden := true  ; No tray icon during tests

; Prevent error dialogs from blocking headless test processes.
; Without this, an unhandled error in a timer callback (e.g., IPC pipe read)
; shows a dialog that blocks the process indefinitely — the harness waits
; forever for the process to exit.
OnError(_TestOnError)
_TestOnError(err, mode) {
    try Log("FATAL: Unhandled error: " err.Message " (" err.File ":" err.Line ")")
    ExitApp(1)
}

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
global g_AltTabbyMode := "test"  ; Prevent store_server.ahk auto-init when included

; --- IPC test globals (used by test_utils.ahk callbacks) ---
global testServer := 0
global gTestClient := 0
global gTestResponse := ""
global gTestResponseReceived := false
global gRealStoreResponse := ""
global gRealStoreReceived := false
global gViewerTestResponse := ""
global gViewerTestReceived := false
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
global gStatsTestResponse := ""
global gStatsTestReceived := false

; --- Stats globals (re-declared here so they exist before store_server.ahk include) ---
; store_server.ahk will re-assign these, which is fine.
global gStats_Lifetime := Map()
global gStats_Session := Map()

; --- Dashboard/Update check globals (from launcher_about.ahk, used by setup_utils.ahk) ---
global g_LastUpdateCheckTick := 0
global g_LastUpdateCheckTime := ""
global g_DashUpdateState
g_DashUpdateState := {status: "unchecked", version: "", downloadUrl: ""}

; --- Launcher subprocess PID globals (from alt_tabby.ahk, referenced by launcher_about.ahk) ---
global g_StorePID := 0
global g_GuiPID := 0
global g_ViewerPID := 0
global g_ConfigEditorPID := 0
global g_BlacklistEditorPID := 0

; --- Admin mode cache (from launcher_tray.ahk, used by IsAdminModeFullyActive in setup_utils.ahk) ---
global g_CachedAdminTaskActive := false

; --- Theme palette (from theme.ahk, used by launcher_about.ahk) ---
global gTheme_Palette := {}

; --- Check for flags (BEFORE log init to set suite-specific log paths) ---
DoLiveTests := false
DoLiveCore := false
DoLiveNetwork := false
DoLiveFeatures := false
DoLiveExecution := false
DoLiveLifecycle := false
DoUnitCoreStore := false
DoUnitCoreParsing := false
DoUnitCoreConfig := false
DoUnitStorage := false
DoUnitSetup := false
DoUnitCleanup := false
DoUnitAdvanced := false
DoUnitStats := false
global DoInvasiveTests := false  ; Tests that disrupt desktop (workspace switching, etc.)
for _, arg in A_Args {
    if (arg = "--live")
        DoLiveTests := true
    else if (arg = "--live-core")
        DoLiveCore := true
    else if (arg = "--live-network")
        DoLiveNetwork := true
    else if (arg = "--live-features")
        DoLiveFeatures := true
    else if (arg = "--live-execution")
        DoLiveExecution := true
    else if (arg = "--live-lifecycle")
        DoLiveLifecycle := true
    else if (arg = "--unit-core-store")
        DoUnitCoreStore := true
    else if (arg = "--unit-core-parsing")
        DoUnitCoreParsing := true
    else if (arg = "--unit-core-config")
        DoUnitCoreConfig := true
    else if (arg = "--unit-storage")
        DoUnitStorage := true
    else if (arg = "--unit-setup")
        DoUnitSetup := true
    else if (arg = "--unit-cleanup")
        DoUnitCleanup := true
    else if (arg = "--unit-advanced")
        DoUnitAdvanced := true
    else if (arg = "--unit-stats")
        DoUnitStats := true
    else if (arg = "--invasive")
        DoInvasiveTests := true
}

; Single-suite modes use a dedicated log file to avoid file locking
; conflicts when multiple instances run in parallel
if (DoLiveCore)
    TestLogPath := A_Temp "\alt_tabby_tests_core.log"
else if (DoLiveNetwork)
    TestLogPath := A_Temp "\alt_tabby_tests_network.log"
else if (DoLiveFeatures)
    TestLogPath := A_Temp "\alt_tabby_tests_features.log"
else if (DoLiveExecution)
    TestLogPath := A_Temp "\alt_tabby_tests_execution.log"
else if (DoLiveLifecycle)
    TestLogPath := A_Temp "\alt_tabby_tests_lifecycle.log"
else if (DoUnitCoreStore)
    TestLogPath := A_Temp "\alt_tabby_tests_unit_core_store.log"
else if (DoUnitCoreParsing)
    TestLogPath := A_Temp "\alt_tabby_tests_unit_core_parsing.log"
else if (DoUnitCoreConfig)
    TestLogPath := A_Temp "\alt_tabby_tests_unit_core_config.log"
else if (DoUnitStorage)
    TestLogPath := A_Temp "\alt_tabby_tests_unit_storage.log"
else if (DoUnitSetup)
    TestLogPath := A_Temp "\alt_tabby_tests_unit_setup.log"
else if (DoUnitCleanup)
    TestLogPath := A_Temp "\alt_tabby_tests_unit_cleanup.log"
else if (DoUnitAdvanced)
    TestLogPath := A_Temp "\alt_tabby_tests_unit_advanced.log"
else if (DoUnitStats)
    TestLogPath := A_Temp "\alt_tabby_tests_unit_stats.log"

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
#Include %A_ScriptDir%\..\src\lib\cjson.ahk
#Include %A_ScriptDir%\..\src\shared\ipc_pipe.ahk
#Include %A_ScriptDir%\..\src\shared\blacklist.ahk
#Include %A_ScriptDir%\..\src\shared\setup_utils.ahk
#Include %A_ScriptDir%\..\src\shared\process_utils.ahk
#Include %A_ScriptDir%\..\src\shared\win_utils.ahk
#Include %A_ScriptDir%\..\src\store\windowstore.ahk
#Include %A_ScriptDir%\..\src\store\winenum_lite.ahk
#Include %A_ScriptDir%\..\src\store\komorebi_sub.ahk
#Include %A_ScriptDir%\..\src\store\icon_pump.ahk
#Include %A_ScriptDir%\..\src\store\store_server.ahk
#Include %A_ScriptDir%\..\src\launcher\launcher_about.ahk

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
; Use readOnly=true to avoid file contention when multiple test suites run in parallel
ConfigLoader_Init(A_ScriptDir "\..\src", true)

; Initialize blacklist before tests
Blacklist_Init(A_ScriptDir "\..\src\shared\blacklist.txt")

; --- Determine what to run ---
; Single-suite modes skip unit tests (they run in the main process)
isUnitSingle := DoUnitCoreStore || DoUnitCoreParsing || DoUnitCoreConfig || DoUnitStorage || DoUnitSetup || DoUnitCleanup || DoUnitAdvanced || DoUnitStats
isSingleSuite := DoLiveCore || DoLiveNetwork || DoLiveFeatures || DoLiveExecution || DoLiveLifecycle || isUnitSingle

if (isUnitSingle) {
    ; --- Run a single unit subset ---
    if (DoUnitCoreStore)
        RunUnitTests_CoreStore()
    else if (DoUnitCoreParsing)
        RunUnitTests_CoreParsing()
    else if (DoUnitCoreConfig)
        RunUnitTests_CoreConfig()
    else if (DoUnitStorage)
        RunUnitTests_Storage()
    else if (DoUnitSetup)
        RunUnitTests_Setup()
    else if (DoUnitCleanup)
        RunUnitTests_Cleanup()
    else if (DoUnitAdvanced)
        RunUnitTests_Advanced()
    else if (DoUnitStats)
        RunUnitTests_Stats()
} else if (!isSingleSuite) {
    ; --- Full mode: run all unit tests ---
    RunUnitTests()
}

; --- Run live tests ---
if (DoLiveTests) {
    ; Full sequential mode (backward compat)
    RunLiveTests()
} else if (DoLiveCore) {
    RunLiveTests_Core()
} else if (DoLiveNetwork) {
    RunLiveTests_Network()
} else if (DoLiveFeatures) {
    RunLiveTests_Features()
} else if (DoLiveExecution) {
    RunLiveTests_Execution()
} else if (DoLiveLifecycle) {
    RunLiveTests_Lifecycle()
}

; --- Summary ---
Log("`n=== Test Summary ===")
Log("Passed: " TestPassed)
Log("Failed: " TestErrors)
Log("Result: " (TestErrors = 0 ? "ALL TESTS PASSED" : "SOME TESTS FAILED"))

ExitApp(TestErrors > 0 ? 1 : 0)
