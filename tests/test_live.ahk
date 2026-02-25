; Live Integration Tests - All tests that require --live flag
; In-process data pipeline + compiled exe E2E tests
; Included by run_tests.ahk

#Include "test_live_core.ahk"
#Include "test_live_network.ahk"
#Include "test_live_features.ahk"
#Include "test_live_execution.ahk"
#Include "test_live_pump.ahk"
#Include "test_live_watcher.ahk"

RunLiveTests() {
    RunLiveTests_Core()
    RunLiveTests_Network()
    RunLiveTests_Features()
    RunLiveTests_Execution()
    RunLiveTests_Pump()
    RunLiveTests_Watcher()
}
