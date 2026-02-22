; Unit Tests - FileWatch_Start wrapper
; Tests file-level watching with debounce using DirectoryWatcher.ahk
; Included by test_unit.ahk
#Include test_utils.ahk

RunUnitTests_FileWatcher() {
    global TestPassed, TestErrors

    Log("`n--- FileWatch Unit Tests ---")

    ; Create isolated temp directory for each test
    testDir := A_Temp "\alttabby_fw_test_" A_TickCount
    DirCreate(testDir)

    try {
        ; ============================================================
        ; Test 1: Callback triggers on target file write
        ; ============================================================
        callbackFired := false
        targetFile := testDir "\target.txt"
        FileAppend("initial", targetFile, "UTF-8")
        Sleep(50)  ; Let filesystem settle before starting watcher

        w := FileWatch_Start(targetFile, (*) => (callbackFired := true), 100)

        ; Modify the file
        FileDelete(targetFile)
        FileAppend("modified " A_TickCount, targetFile, "UTF-8")

        ; Wait for debounce to settle + callback to fire
        waitStart := A_TickCount
        while (!callbackFired && (A_TickCount - waitStart) < 3000)
            Sleep(50)

        if (callbackFired) {
            Log("PASS: FileWatch callback fired on target file write (" (A_TickCount - waitStart) "ms)")
            TestPassed++
        } else {
            Log("FAIL: FileWatch callback did not fire within 3s")
            TestErrors++
        }

        w.Stop()

        ; ============================================================
        ; Test 2: Non-target file does not trigger callback
        ; ============================================================
        callbackFired2 := false
        targetFile2 := testDir "\watched.txt"
        otherFile := testDir "\other.txt"
        FileAppend("initial", targetFile2, "UTF-8")
        Sleep(50)

        w2 := FileWatch_Start(targetFile2, (*) => (callbackFired2 := true), 100)

        ; Write to a DIFFERENT file in the same directory
        FileAppend("noise " A_TickCount, otherFile, "UTF-8")

        ; Wait longer than debounce — callback should NOT fire
        Sleep(500)

        if (!callbackFired2) {
            Log("PASS: FileWatch callback correctly ignored non-target file")
            TestPassed++
        } else {
            Log("FAIL: FileWatch callback fired for non-target file")
            TestErrors++
        }

        w2.Stop()

        ; ============================================================
        ; Test 3: Debounce coalesces rapid writes
        ; ============================================================
        callbackCount3 := 0
        targetFile3 := testDir "\rapid.txt"
        FileAppend("initial", targetFile3, "UTF-8")
        Sleep(50)

        w3 := FileWatch_Start(targetFile3, (*) => (callbackCount3++), 200)

        ; Rapid writes — 5 modifications in quick succession
        loop 5 {
            FileDelete(targetFile3)
            FileAppend("write " A_Index " " A_TickCount, targetFile3, "UTF-8")
            Sleep(20)
        }

        ; Wait for debounce to fully settle (200ms after last write + margin)
        Sleep(600)

        if (callbackCount3 = 1) {
            Log("PASS: FileWatch debounce coalesced 5 rapid writes into 1 callback")
            TestPassed++
        } else {
            Log("FAIL: FileWatch debounce produced " callbackCount3 " callbacks (expected 1)")
            TestErrors++
        }

        w3.Stop()

        ; ============================================================
        ; Test 4: Stop prevents further callbacks
        ; ============================================================
        callbackFired4 := false
        targetFile4 := testDir "\stopped.txt"
        FileAppend("initial", targetFile4, "UTF-8")
        Sleep(50)

        w4 := FileWatch_Start(targetFile4, (*) => (callbackFired4 := true), 100)
        w4.Stop()

        ; Write after Stop — callback should NOT fire
        FileDelete(targetFile4)
        FileAppend("after stop " A_TickCount, targetFile4, "UTF-8")
        Sleep(500)

        if (!callbackFired4) {
            Log("PASS: FileWatch Stop() prevented callback")
            TestPassed++
        } else {
            Log("FAIL: FileWatch callback fired after Stop()")
            TestErrors++
        }

    } finally {
        ; Cleanup temp directory
        try DirDelete(testDir, true)
    }
}
