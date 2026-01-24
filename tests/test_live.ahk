; Live Integration Tests - All tests that require --live flag
; Tests that spawn store processes and do E2E validation
; Included by run_tests.ahk

#Include "test_live_core.ahk"
#Include "test_live_features.ahk"
#Include "test_live_execution.ahk"

RunLiveTests() {
    RunLiveTests_Core()
    RunLiveTests_Features()
    RunLiveTests_Execution()
}
