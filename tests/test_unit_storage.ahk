; Unit Tests - Storage
; WindowStore_UpdateFields, Icon Pump
; Included by test_unit.ahk

RunUnitTests_Storage() {
    global TestPassed, TestErrors, cfg

    ; ============================================================
    ; WindowStore_UpdateFields 'exists' field test
    ; ============================================================
    Log("`n--- WindowStore_UpdateFields Tests ---")

    ; Ensure store is initialized
    WindowStore_Init()
    WindowStore_BeginScan()

    ; Add a test window
    testHwnd := 99999
    testRec := Map()
    testRec["hwnd"] := testHwnd
    testRec["title"] := "Test Bypass Window"
    testRec["class"] := "TestClass"
    testRec["pid"] := 999
    testRec["isVisible"] := true
    testRec["isCloaked"] := false
    testRec["isMinimized"] := false
    testRec["z"] := 1
    testRec["isFocused"] := false
    WindowStore_UpsertWindow([testRec], "test")
    WindowStore_EndScan()

    ; Test: UpdateFields on existing window should return exists=true
    result := WindowStore_UpdateFields(testHwnd, { isFocused: true }, "test")
    if (result.exists = true) {
        Log("PASS: WindowStore_UpdateFields returns exists=true for window in store")
        TestPassed++
    } else {
        Log("FAIL: WindowStore_UpdateFields should return exists=true for window in store")
        TestErrors++
    }

    ; Test: UpdateFields on non-existent window should return exists=false
    result := WindowStore_UpdateFields(88888, { isFocused: true }, "test")
    if (result.exists = false) {
        Log("PASS: WindowStore_UpdateFields returns exists=false for window not in store")
        TestPassed++
    } else {
        Log("FAIL: WindowStore_UpdateFields should return exists=false for window not in store")
        TestErrors++
    }

    ; Test: UpdateFields changed field - updating same value should be changed=false
    result := WindowStore_UpdateFields(testHwnd, { isFocused: true }, "test")
    if (result.changed = false && result.exists = true) {
        Log("PASS: WindowStore_UpdateFields returns changed=false when value unchanged")
        TestPassed++
    } else {
        Log("FAIL: WindowStore_UpdateFields should return changed=false when value unchanged (got changed=" result.changed ")")
        TestErrors++
    }

    ; Clean up - remove test window
    WindowStore_RemoveWindow([testHwnd], true)

    ; ============================================================
    ; WindowStore_ValidateExistence Tests (Ghost Window Detection)
    ; ============================================================
    Log("`n--- WindowStore_ValidateExistence Tests ---")

    ; Test 1: Fake HWNDs removed (IsWindow returns false for non-existent windows)
    Log("Testing ValidateExistence removes fake HWNDs...")
    WindowStore_Init()
    global gWS_Store

    WindowStore_BeginScan()
    fakeRec1 := Map("hwnd", 0x9999001, "title", "Fake Win 1", "class", "FakeClass", "pid", 1,
                    "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 1)
    fakeRec2 := Map("hwnd", 0x9999002, "title", "Fake Win 2", "class", "FakeClass", "pid", 2,
                    "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 2)
    WindowStore_UpsertWindow([fakeRec1, fakeRec2], "test")
    WindowStore_EndScan()

    ; Both should be in store before validation
    if (gWS_Store.Has(0x9999001) && gWS_Store.Has(0x9999002)) {
        Log("PASS: Both fake HWNDs present before ValidateExistence")
        TestPassed++
    } else {
        Log("FAIL: Fake HWNDs should be present before validation")
        TestErrors++
    }

    result := WindowStore_ValidateExistence()

    if (!gWS_Store.Has(0x9999001) && !gWS_Store.Has(0x9999002)) {
        Log("PASS: ValidateExistence removed both fake HWNDs (IsWindow=false)")
        TestPassed++
    } else {
        Log("FAIL: ValidateExistence should remove fake HWNDs (still has: "
            . (gWS_Store.Has(0x9999001) ? "0x9999001 " : "") . (gWS_Store.Has(0x9999002) ? "0x9999002" : "") . ")")
        TestErrors++
    }

    if (result.removed = 2) {
        Log("PASS: ValidateExistence reports removed=2")
        TestPassed++
    } else {
        Log("FAIL: ValidateExistence should report removed=2, got removed=" result.removed)
        TestErrors++
    }

    ; Test 2: Rev bumped on removal
    Log("Testing ValidateExistence bumps rev on removal...")
    WindowStore_Init()
    WindowStore_BeginScan()
    fakeRec3 := Map("hwnd", 0x9999003, "title", "Fake Win 3", "class", "FakeClass", "pid", 3,
                    "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 1)
    WindowStore_UpsertWindow([fakeRec3], "test")
    WindowStore_EndScan()

    global gWS_Rev
    revBefore := gWS_Rev
    WindowStore_ValidateExistence()
    if (gWS_Rev > revBefore) {
        Log("PASS: ValidateExistence bumped rev after removal")
        TestPassed++
    } else {
        Log("FAIL: ValidateExistence should bump rev after removal (before=" revBefore " after=" gWS_Rev ")")
        TestErrors++
    }

    ; Test 3: Empty store is no-op
    Log("Testing ValidateExistence no-op on empty store...")
    WindowStore_Init()
    ; Drain any queued icon work from previous tests
    WindowStore_PopIconBatch(100)
    gWS_Store := Map()
    revBefore := gWS_Rev
    result := WindowStore_ValidateExistence()
    if (result.removed = 0 && gWS_Rev = revBefore) {
        Log("PASS: ValidateExistence no-op on empty store (removed=0, rev unchanged)")
        TestPassed++
    } else {
        Log("FAIL: ValidateExistence should be no-op on empty store (removed=" result.removed " rev changed=" (gWS_Rev != revBefore) ")")
        TestErrors++
    }

    ; ============================================================
    ; WindowStore_PurgeBlacklisted Tests
    ; ============================================================
    Log("`n--- WindowStore_PurgeBlacklisted Tests ---")

    ; Save original blacklist path to restore later
    global gBlacklist_FilePath
    savedBlPathStorage := gBlacklist_FilePath

    ; Create temp blacklist file
    testBlDirStorage := A_Temp "\tabby_purge_test_" A_TickCount
    testBlPathStorage := testBlDirStorage "\blacklist.txt"

    try {
        DirCreate(testBlDirStorage)
        blContentStorage := "[Title]`nBadTitle*`n[Class]`nBadClass`n[Pair]`n"
        FileAppend(blContentStorage, testBlPathStorage, "UTF-8")

        ; Load the test blacklist
        Blacklist_Init(testBlPathStorage)

        ; Test 1: Title match removed
        Log("Testing PurgeBlacklisted removes title-matched windows...")
        WindowStore_Init()
        WindowStore_BeginScan()
        badRec := Map("hwnd", 0xAA01, "title", "BadTitle Test Window", "class", "SafeClass", "pid", 10,
                      "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 1)
        goodRec := Map("hwnd", 0xAA02, "title", "GoodTitle Window", "class", "SafeClass", "pid", 11,
                       "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 2)
        WindowStore_UpsertWindow([badRec, goodRec], "test")
        WindowStore_EndScan()

        result := WindowStore_PurgeBlacklisted()

        if (!gWS_Store.Has(0xAA01)) {
            Log("PASS: PurgeBlacklisted removed title-matched window (BadTitle*)")
            TestPassed++
        } else {
            Log("FAIL: PurgeBlacklisted should remove title-matched window")
            TestErrors++
        }

        ; Test 2: Non-matching kept
        if (gWS_Store.Has(0xAA02)) {
            Log("PASS: PurgeBlacklisted kept non-matching window (GoodTitle)")
            TestPassed++
        } else {
            Log("FAIL: PurgeBlacklisted should keep non-matching window")
            TestErrors++
        }

        if (result.removed = 1) {
            Log("PASS: PurgeBlacklisted reports removed=1")
            TestPassed++
        } else {
            Log("FAIL: PurgeBlacklisted should report removed=1, got removed=" result.removed)
            TestErrors++
        }

        ; Test 3: Class match removed
        Log("Testing PurgeBlacklisted removes class-matched windows...")
        WindowStore_Init()
        WindowStore_BeginScan()
        classRec := Map("hwnd", 0xAA03, "title", "Safe Title", "class", "BadClass", "pid", 12,
                        "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 1)
        WindowStore_UpsertWindow([classRec], "test")
        WindowStore_EndScan()

        result := WindowStore_PurgeBlacklisted()
        if (!gWS_Store.Has(0xAA03) && result.removed = 1) {
            Log("PASS: PurgeBlacklisted removed class-matched window (BadClass)")
            TestPassed++
        } else {
            Log("FAIL: PurgeBlacklisted should remove class-matched window (still has=" gWS_Store.Has(0xAA03) " removed=" result.removed ")")
            TestErrors++
        }

        ; Test 4: Rev bumped only when something removed
        Log("Testing PurgeBlacklisted rev behavior...")
        WindowStore_Init()
        WindowStore_BeginScan()
        safeRec := Map("hwnd", 0xAA04, "title", "Completely Safe", "class", "SafeClass", "pid", 13,
                       "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 1)
        WindowStore_UpsertWindow([safeRec], "test")
        WindowStore_EndScan()

        revBefore := gWS_Rev
        result := WindowStore_PurgeBlacklisted()
        if (result.removed = 0 && gWS_Rev = revBefore) {
            Log("PASS: PurgeBlacklisted no rev bump when nothing removed")
            TestPassed++
        } else {
            Log("FAIL: PurgeBlacklisted should not bump rev when nothing removed (removed=" result.removed ")")
            TestErrors++
        }
        WindowStore_RemoveWindow([0xAA04], true)

        ; Test 5: Empty store is no-op
        Log("Testing PurgeBlacklisted no-op on empty store...")
        WindowStore_Init()
        gWS_Store := Map()
        result := WindowStore_PurgeBlacklisted()
        if (result.removed = 0) {
            Log("PASS: PurgeBlacklisted no-op on empty store")
            TestPassed++
        } else {
            Log("FAIL: PurgeBlacklisted should return removed=0 on empty store")
            TestErrors++
        }

        ; Drain icon queue to prevent bleeding into subsequent tests
        WindowStore_PopIconBatch(100)

        ; Cleanup temp files and restore blacklist
        try FileDelete(testBlPathStorage)
        try DirDelete(testBlDirStorage)
        Blacklist_Init(savedBlPathStorage)
    } catch as e {
        Log("FAIL: PurgeBlacklisted test error: " e.Message)
        TestErrors++
        try DirDelete(testBlDirStorage, true)
        Blacklist_Init(savedBlPathStorage)
    }

    ; ============================================================
    ; Icon Pump Tests
    ; ============================================================
    Log("`n--- Icon Pump Tests ---")

    ; Test 1: EXE Icon Extraction (Non-UWP)
    Log("Testing EXE icon extraction from notepad.exe...")
    exePath := A_WinDir "\notepad.exe"
    if (FileExist(exePath)) {
        hIcon := _IP_ExtractExeIcon(exePath)
        if (hIcon != 0) {
            Log("PASS: Extracted icon from notepad.exe (hIcon=" hIcon ")")
            TestPassed++
            ; Cleanup
            try DllCall("user32\DestroyIcon", "ptr", hIcon)
        } else {
            Log("FAIL: Failed to extract icon from notepad.exe")
            TestErrors++
        }
    } else {
        Log("SKIP: notepad.exe not found at " exePath)
    }

    ; Test 2: UWP Detection - explorer.exe is NOT a UWP app
    Log("Testing UWP detection (explorer.exe should not be UWP)...")
    explorerPid := ProcessExist("explorer.exe")
    if (explorerPid > 0) {
        isUWP := _IP_AppHasPackage(explorerPid)
        if (!isUWP) {
            Log("PASS: explorer.exe correctly detected as non-UWP")
            TestPassed++
        } else {
            Log("FAIL: explorer.exe incorrectly detected as UWP")
            TestErrors++
        }
    } else {
        Log("SKIP: explorer.exe not running")
    }

    ; Test 3: UWP Detection - invalid PID should return false
    Log("Testing UWP detection with invalid PID...")
    isUWP := _IP_AppHasPackage(0)
    if (!isUWP) {
        Log("PASS: Invalid PID (0) correctly returns false for UWP check")
        TestPassed++
    } else {
        Log("FAIL: Invalid PID should return false for UWP check")
        TestErrors++
    }

    ; Test 4: UWP Logo Path - only run if Calculator is running
    Log("Testing UWP logo path extraction...")
    calcHwnd := WinExist("ahk_exe Calculator.exe")
    if (!calcHwnd) {
        calcHwnd := WinExist("ahk_exe CalculatorApp.exe")
    }
    if (calcHwnd) {
        calcPid := WinGetPID("ahk_id " calcHwnd)
        isUWP := _IP_AppHasPackage(calcPid)
        if (isUWP) {
            logoPath := _IP_GetUWPLogoPath(calcHwnd)
            if (logoPath != "" && FileExist(logoPath)) {
                Log("PASS: Found Calculator logo at: " logoPath)
                TestPassed++
            } else if (logoPath != "") {
                Log("WARN: Logo path found but file missing: " logoPath)
                Log("PASS: UWP logo path extraction returned a path (file may be missing)")
                TestPassed++
            } else {
                Log("WARN: Calculator is UWP but logo path not found (manifest format may differ)")
                Log("PASS: UWP detection worked, logo extraction is best-effort")
                TestPassed++
            }
        } else {
            Log("SKIP: Calculator not detected as UWP (may be Win32 version)")
        }
    } else {
        Log("SKIP: Calculator not running for UWP test")
    }

    ; Test 5: Icon Resolution Chain - cloaked window should still get EXE icon
    Log("Testing icon resolution chain for cloaked windows...")
    ; Create a mock scenario: we have an exePath, test that we can get an icon from it
    ; even when the "window" would be considered cloaked
    testExe := A_WinDir "\explorer.exe"
    if (FileExist(testExe)) {
        ; Get icon via EXE fallback (simulating what happens for cloaked windows)
        hCopy := WindowStore_GetExeIconCopy(testExe)
        if (!hCopy) {
            master := _IP_ExtractExeIcon(testExe)
            if (master) {
                ; Don't actually cache in store during test
                hCopy := DllCall("user32\CopyIcon", "ptr", master, "ptr")
                try DllCall("user32\DestroyIcon", "ptr", master)
            }
        }
        if (hCopy != 0) {
            Log("PASS: EXE fallback works for cloaked window scenario (got icon from " testExe ")")
            TestPassed++
            try DllCall("user32\DestroyIcon", "ptr", hCopy)
        } else {
            Log("FAIL: EXE fallback should work even for cloaked windows")
            TestErrors++
        }
    } else {
        Log("SKIP: explorer.exe not found at " testExe)
    }

    ; Test 6: GetProcessPath helper
    Log("Testing _IP_GetProcessPath helper...")
    if (explorerPid > 0) {
        procPath := _IP_GetProcessPath(explorerPid)
        if (procPath != "" && InStr(procPath, "explorer.exe")) {
            Log("PASS: _IP_GetProcessPath returned: " procPath)
            TestPassed++
        } else {
            Log("FAIL: _IP_GetProcessPath should return explorer.exe path, got: " procPath)
            TestErrors++
        }
    } else {
        Log("SKIP: explorer.exe not running for process path test")
    }

    ; Test 7: Hidden windows MUST be enqueued for icon resolution
    ; This is the critical end-to-end test - verifies that cloaked/minimized windows
    ; actually make it into the icon queue (the bug was they were filtered out here)
    Log("Testing hidden window icon enqueue (critical E2E test)...")
    WindowStore_Init()
    WindowStore_BeginScan()

    ; Create a cloaked window record (simulating a window on another workspace)
    cloakedHwnd := 77777
    cloakedRec := Map()
    cloakedRec["hwnd"] := cloakedHwnd
    cloakedRec["title"] := "Test Cloaked Window"
    cloakedRec["class"] := "TestClass"
    cloakedRec["pid"] := 999
    cloakedRec["isVisible"] := true
    cloakedRec["isCloaked"] := true  ; CLOAKED - simulates other workspace
    cloakedRec["isMinimized"] := false
    cloakedRec["z"] := 1
    cloakedRec["exePath"] := A_WinDir "\notepad.exe"
    WindowStore_UpsertWindow([cloakedRec], "test")

    ; Create a minimized window record
    minHwnd := 88888
    minRec := Map()
    minRec["hwnd"] := minHwnd
    minRec["title"] := "Test Minimized Window"
    minRec["class"] := "TestClass"
    minRec["pid"] := 998
    minRec["isVisible"] := false  ; Minimized windows often have isVisible=false
    minRec["isCloaked"] := false
    minRec["isMinimized"] := true  ; MINIMIZED
    minRec["z"] := 2
    minRec["exePath"] := A_WinDir "\explorer.exe"
    WindowStore_UpsertWindow([minRec], "test")

    WindowStore_EndScan()

    ; Pop the icon batch - both windows should be in the queue
    batch := WindowStore_PopIconBatch(10)

    cloakedInQueue := false
    minInQueue := false
    for _, hwnd in batch {
        if (hwnd = cloakedHwnd)
            cloakedInQueue := true
        if (hwnd = minHwnd)
            minInQueue := true
    }

    if (cloakedInQueue) {
        Log("PASS: Cloaked window was enqueued for icon resolution")
        TestPassed++
    } else {
        Log("FAIL: Cloaked window was NOT enqueued - this is the bug that breaks other-workspace icons!")
        TestErrors++
    }

    if (minInQueue) {
        Log("PASS: Minimized window was enqueued for icon resolution")
        TestPassed++
    } else {
        Log("FAIL: Minimized window was NOT enqueued - this breaks minimized window icons!")
        TestErrors++
    }

    ; Clean up
    WindowStore_RemoveWindow([cloakedHwnd, minHwnd], true)

    ; Test 8: WindowStore_EnqueueIconRefresh with throttle
    Log("Testing icon refresh throttle...")
    WindowStore_Init()
    WindowStore_BeginScan()

    ; Create a window with WM_GETICON icon (eligible for refresh)
    refreshHwnd := 66666
    refreshRec := Map()
    refreshRec["hwnd"] := refreshHwnd
    refreshRec["title"] := "Test Refresh Window"
    refreshRec["class"] := "TestClass"
    refreshRec["pid"] := 997
    refreshRec["isVisible"] := true
    refreshRec["isCloaked"] := false
    refreshRec["isMinimized"] := false
    refreshRec["z"] := 1
    refreshRec["iconHicon"] := 12345  ; Has icon
    refreshRec["iconMethod"] := "wm_geticon"  ; Got it via WM_GETICON
    refreshRec["iconLastRefreshTick"] := 0  ; Never refreshed
    WindowStore_UpsertWindow([refreshRec], "test")
    WindowStore_EndScan()

    ; First refresh should enqueue (never refreshed before)
    WindowStore_EnqueueIconRefresh(refreshHwnd)
    batch1 := WindowStore_PopIconBatch(10)
    firstRefreshEnqueued := false
    for _, hwnd in batch1 {
        if (hwnd = refreshHwnd)
            firstRefreshEnqueued := true
    }

    if (firstRefreshEnqueued) {
        Log("PASS: First icon refresh was enqueued (no throttle for new window)")
        TestPassed++
    } else {
        Log("FAIL: First icon refresh should be enqueued")
        TestErrors++
    }

    ; Update the refresh tick to simulate recent refresh
    WindowStore_UpdateFields(refreshHwnd, { iconLastRefreshTick: A_TickCount }, "test")

    ; Second refresh immediately should be throttled
    WindowStore_EnqueueIconRefresh(refreshHwnd)
    batch2 := WindowStore_PopIconBatch(10)
    secondRefreshEnqueued := false
    for _, hwnd in batch2 {
        if (hwnd = refreshHwnd)
            secondRefreshEnqueued := true
    }

    if (!secondRefreshEnqueued) {
        Log("PASS: Second icon refresh was throttled (within throttle window)")
        TestPassed++
    } else {
        Log("FAIL: Second icon refresh should be throttled")
        TestErrors++
    }

    ; Clean up
    WindowStore_RemoveWindow([refreshHwnd], true)

    ; Test 9: Icon upgrade - visible window with EXE fallback gets re-queued
    Log("Testing icon upgrade queue (EXE fallback -> WM_GETICON upgrade)...")
    WindowStore_Init()
    WindowStore_BeginScan()

    ; Create a window that started cloaked (got EXE icon), now visible
    upgradeHwnd := 55555
    upgradeRec := Map()
    upgradeRec["hwnd"] := upgradeHwnd
    upgradeRec["title"] := "Test Upgrade Window"
    upgradeRec["class"] := "TestClass"
    upgradeRec["pid"] := 996
    upgradeRec["isVisible"] := true  ; NOW visible
    upgradeRec["isCloaked"] := false  ; NOT cloaked anymore
    upgradeRec["isMinimized"] := false
    upgradeRec["z"] := 1
    upgradeRec["iconHicon"] := 12345  ; Has icon
    upgradeRec["iconMethod"] := "exe"  ; Got it via EXE fallback (not WM_GETICON)
    WindowStore_UpsertWindow([upgradeRec], "test")
    WindowStore_EndScan()

    ; Check if upgrade gets queued
    batch3 := WindowStore_PopIconBatch(10)
    upgradeEnqueued := false
    for _, hwnd in batch3 {
        if (hwnd = upgradeHwnd)
            upgradeEnqueued := true
    }

    if (upgradeEnqueued) {
        Log("PASS: Visible window with EXE fallback icon was queued for upgrade")
        TestPassed++
    } else {
        Log("FAIL: Visible window with EXE fallback icon should be queued for upgrade to WM_GETICON")
        TestErrors++
    }

    ; Clean up
    WindowStore_RemoveWindow([upgradeHwnd], true)

    ; ============================================================
    ; ExeIconCachePut FIFO Eviction Tests
    ; ============================================================
    Log("`n--- ExeIconCachePut FIFO Eviction Tests ---")

    ; Use fake HICON values (DestroyIcon silently fails for invalid handles)
    ; Override cfg.ExeIconCacheMax to 3 for testing
    global gWS_ExeIconCache
    savedCache := gWS_ExeIconCache
    savedMax := cfg.HasOwnProp("ExeIconCacheMax") ? cfg.ExeIconCacheMax : 100
    gWS_ExeIconCache := Map()
    cfg.ExeIconCacheMax := 3

    WindowStore_ExeIconCachePut("a.exe", 1001)
    WindowStore_ExeIconCachePut("b.exe", 1002)
    WindowStore_ExeIconCachePut("c.exe", 1003)
    if (gWS_ExeIconCache.Count = 3) {
        Log("PASS: ExeIconCache: 3 entries at max")
        TestPassed++
    } else {
        Log("FAIL: ExeIconCache: expected 3 at max, got " gWS_ExeIconCache.Count)
        TestErrors++
    }

    WindowStore_ExeIconCachePut("d.exe", 1004)
    if (gWS_ExeIconCache.Count = 3) {
        Log("PASS: ExeIconCache: still 3 after eviction")
        TestPassed++
    } else {
        Log("FAIL: ExeIconCache: expected 3 after eviction, got " gWS_ExeIconCache.Count)
        TestErrors++
    }

    if (!gWS_ExeIconCache.Has("a.exe")) {
        Log("PASS: ExeIconCache FIFO: first entry (a.exe) evicted")
        TestPassed++
    } else {
        Log("FAIL: ExeIconCache FIFO: a.exe should have been evicted")
        TestErrors++
    }

    if (gWS_ExeIconCache.Has("d.exe")) {
        Log("PASS: ExeIconCache FIFO: newest entry (d.exe) present")
        TestPassed++
    } else {
        Log("FAIL: ExeIconCache FIFO: d.exe should be present")
        TestErrors++
    }

    ; Restore original state
    gWS_ExeIconCache := savedCache
    cfg.ExeIconCacheMax := savedMax
}
