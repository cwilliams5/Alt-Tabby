; Unit Tests - WindowStore, Config, Entry Point Initialization
; Tests that don't require external processes or --live flag
; Included by run_tests.ahk

#Include "test_unit_core.ahk"
#Include "test_unit_storage.ahk"
#Include "test_unit_setup.ahk"
#Include "test_unit_cleanup.ahk"
#Include "test_unit_advanced.ahk"
#Include "test_unit_stats.ahk"

RunUnitTests() {
    RunUnitTests_Core()
    RunUnitTests_Storage()
    RunUnitTests_Setup()
    RunUnitTests_Cleanup()
    RunUnitTests_Advanced()
    RunUnitTests_Stats()
}
