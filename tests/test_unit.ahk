; Unit Tests - WindowStore, Config, Entry Point Initialization
; Tests that don't require external processes or --live flag
; Included by run_tests.ahk

; Core tests split into smaller files for parallel execution
#Include "test_unit_core_store.ahk"
#Include "test_unit_core_parsing.ahk"
#Include "test_unit_core_config.ahk"
#Include "test_unit_storage.ahk"
#Include "test_unit_setup.ahk"
#Include "test_unit_cleanup.ahk"
#Include "test_unit_advanced.ahk"
#Include "test_unit_stats.ahk"
#Include "test_unit_sort.ahk"

RunUnitTests() {
    ; Core tests (formerly RunUnitTests_Core)
    RunUnitTests_CoreStore()
    RunUnitTests_CoreParsing()
    RunUnitTests_CoreConfig()
    ; Other unit tests
    RunUnitTests_Storage()
    RunUnitTests_Setup()
    RunUnitTests_Cleanup()
    RunUnitTests_Advanced()
    RunUnitTests_Stats()
    RunUnitTests_Sort()
}
