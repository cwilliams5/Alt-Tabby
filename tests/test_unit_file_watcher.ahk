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

        ; ============================================================
        ; Test 5: Atomic rename triggers callback (VS Code save pattern)
        ; ============================================================
        callbackFired5 := false
        targetFile5 := testDir "\config.ini"
        tmpFile5 := testDir "\config.ini.tmp"
        FileAppend("original", targetFile5, "UTF-8")
        Sleep(50)

        w5 := FileWatch_Start(targetFile5, (*) => (callbackFired5 := true), 100)

        ; Write to temp file, then rename to target (atomic save pattern)
        FileAppend("new content " A_TickCount, tmpFile5, "UTF-8")
        FileDelete(targetFile5)
        FileMove(tmpFile5, targetFile5)

        waitStart5 := A_TickCount
        while (!callbackFired5 && (A_TickCount - waitStart5) < 3000)
            Sleep(50)

        if (callbackFired5) {
            Log("PASS: FileWatch callback fired on atomic rename (" (A_TickCount - waitStart5) "ms)")
            TestPassed++
        } else {
            Log("FAIL: FileWatch callback did not fire on atomic rename within 3s")
            TestErrors++
        }

        w5.Stop()

        ; ============================================================
        ; Test 6: Stop() during active debounce cancels pending callback
        ; ============================================================
        callbackFired6 := false
        targetFile6 := testDir "\debounce_stop.txt"
        FileAppend("initial", targetFile6, "UTF-8")
        Sleep(50)

        w6 := FileWatch_Start(targetFile6, (*) => (callbackFired6 := true), 300)

        ; Trigger a change (starts 300ms debounce timer)
        FileDelete(targetFile6)
        FileAppend("changed " A_TickCount, targetFile6, "UTF-8")
        Sleep(50)  ; Let filesystem event arrive, debounce timer is now pending

        ; Stop BEFORE debounce fires
        w6.Stop()

        ; Wait past the debounce window
        Sleep(500)

        if (!callbackFired6) {
            Log("PASS: FileWatch Stop() during active debounce prevented callback")
            TestPassed++
        } else {
            Log("FAIL: FileWatch callback fired after Stop() during debounce")
            TestErrors++
        }

        ; ============================================================
        ; Test 7: Missing parent directory — no crash, Stop() is safe
        ; ============================================================
        nocrash7 := true
        try {
            w7 := FileWatch_Start(testDir "\nonexistent_dir\phantom.txt", (*) => 0, 100)
            ; Stop() may not exist if constructor failed — use try
            try w7.Stop()
        } catch as e {
            Log("FAIL: FileWatch_Start crashed on missing dir: " e.Message)
            nocrash7 := false
            TestErrors++
        }
        if (nocrash7) {
            Log("PASS: FileWatch_Start on missing parent dir is safe (no crash)")
            TestPassed++
        }

    } finally {
        ; Cleanup temp directory
        try DirDelete(testDir, true)
    }
}
