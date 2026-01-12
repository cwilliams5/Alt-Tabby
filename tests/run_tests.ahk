#Requires AutoHotkey v2.0
#SingleInstance Force

; Automated test runner
; Usage: AutoHotkey64.exe tests/run_tests.ahk [--live]

global TestLogPath := A_Temp "\alt_tabby_tests.log"
global TestErrors := 0
global TestPassed := 0

try FileDelete(TestLogPath)
Log("=== Alt-Tabby Test Run " FormatTime(, "yyyy-MM-dd HH:mm:ss") " ===")
Log("Log file: " TestLogPath)

; Check for --live flag
RunLiveTests := false
for _, arg in A_Args {
    if (arg = "--live")
        RunLiveTests := true
}

; Include files needed for testing
#Include %A_ScriptDir%\..\src\store\windowstore.ahk
#Include %A_ScriptDir%\..\src\store\winenum_lite.ahk

Log("`n--- WindowStore Unit Tests ---")

; Test 1: _WS_GetOpt with Map
testMap := Map("sort", "Z", "includeMinimized", false)
AssertEq(_WS_GetOpt(testMap, "sort", "MRU"), "Z", "_WS_GetOpt with Map")

; Test 2: _WS_GetOpt with plain Object
testObj := { sort: "Title", columns: "hwndsOnly" }
AssertEq(_WS_GetOpt(testObj, "sort", "MRU"), "Title", "_WS_GetOpt with plain Object")

; Test 3: _WS_GetOpt default value
AssertEq(_WS_GetOpt(testObj, "missing", "default"), "default", "_WS_GetOpt default value")

; Test 4: _WS_GetOpt with non-object
AssertEq(_WS_GetOpt(0, "key", "fallback"), "fallback", "_WS_GetOpt with non-object")

; Test 5: WindowStore basic operations
WindowStore_Init()
WindowStore_BeginScan()

testRecs := []
rec1 := Map()
rec1["hwnd"] := 12345
rec1["title"] := "Test Window 1"
rec1["class"] := "TestClass"
rec1["pid"] := 100
rec1["state"] := "WorkspaceShowing"
rec1["z"] := 1
testRecs.Push(rec1)

rec2 := Map()
rec2["hwnd"] := 67890
rec2["title"] := "Test Window 2"
rec2["class"] := "TestClass2"
rec2["pid"] := 200
rec2["state"] := "WorkspaceShowing"
rec2["z"] := 2
testRecs.Push(rec2)

result := WindowStore_UpsertWindow(testRecs, "test")
AssertEq(result.added, 2, "WindowStore_UpsertWindow adds records")

; Test 6: GetProjection with plain object opts (THE BUG FIX)
proj := WindowStore_GetProjection({ sort: "Z", columns: "items" })
AssertEq(proj.items.Length, 2, "GetProjection with plain object opts")

; Test 7: GetProjection with Map opts
projMap := WindowStore_GetProjection(Map("sort", "Title"))
AssertEq(projMap.items.Length, 2, "GetProjection with Map opts")

; Test 8: Z-order sorting
projZ := WindowStore_GetProjection({ sort: "Z" })
AssertEq(projZ.items[1].z, 1, "Z-order sorting (first item z=1)")

; Live tests
if (RunLiveTests) {
    Log("`n--- Live Integration Tests ---")

    realWindows := WinEnumLite_ScanAll()
    AssertTrue(realWindows.Length > 0, "WinEnumLite finds windows (" realWindows.Length " found)")

    if (realWindows.Length > 0) {
        Log("  Sample windows:")
        count := 0
        for _, rec in realWindows {
            if (count >= 3)
                break
            Log("    hwnd=" rec["hwnd"] " title=" SubStr(rec["title"], 1, 40))
            count++
        }
    }

    ; Reset and test full pipeline
    global gWS_Store := Map()
    global gWS_Rev := 0
    WindowStore_Init()
    WindowStore_BeginScan()
    WindowStore_UpsertWindow(realWindows, "winenum_lite")
    WindowStore_EndScan()

    proj := WindowStore_GetProjection({ sort: "Z" })
    AssertTrue(proj.items.Length > 0, "Full pipeline produces projection (" proj.items.Length " items)")
}

; Summary
Log("`n=== Test Summary ===")
Log("Passed: " TestPassed)
Log("Failed: " TestErrors)
Log("Result: " (TestErrors = 0 ? "ALL TESTS PASSED" : "SOME TESTS FAILED"))

ExitApp(TestErrors > 0 ? 1 : 0)

; --- Test Helpers ---

Log(msg) {
    global TestLogPath
    FileAppend(msg "`n", TestLogPath, "UTF-8")
}

AssertEq(actual, expected, name) {
    global TestErrors, TestPassed
    if (actual = expected) {
        Log("PASS: " name)
        TestPassed++
    } else {
        Log("FAIL: " name " - expected '" expected "', got '" actual "'")
        TestErrors++
    }
}

AssertTrue(condition, name) {
    global TestErrors, TestPassed
    if (condition) {
        Log("PASS: " name)
        TestPassed++
    } else {
        Log("FAIL: " name)
        TestErrors++
    }
}
