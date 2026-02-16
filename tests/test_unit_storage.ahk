; Unit Tests - Storage
; WL_UpdateFields, Icon Pump
; Included by test_unit.ahk
#Include test_utils.ahk

RunUnitTests_Storage() {
    global TestPassed, TestErrors, cfg

    ; ============================================================
    ; WL_UpdateFields 'exists' field test
    ; ============================================================
    Log("`n--- WL_UpdateFields Tests ---")

    ; Ensure store is initialized
    WL_Init()
    WL_BeginScan()

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
    WL_UpsertWindow([testRec], "test")
    WL_EndScan()

    ; Test: UpdateFields on existing window should return exists=true
    result := WL_UpdateFields(testHwnd, { isFocused: true }, "test")
    if (result.exists = true) {
        Log("PASS: WL_UpdateFields returns exists=true for window in store")
        TestPassed++
    } else {
        Log("FAIL: WL_UpdateFields should return exists=true for window in store")
        TestErrors++
    }

    ; Test: UpdateFields on non-existent window should return exists=false
    result := WL_UpdateFields(88888, { isFocused: true }, "test")
    if (result.exists = false) {
        Log("PASS: WL_UpdateFields returns exists=false for window not in store")
        TestPassed++
    } else {
        Log("FAIL: WL_UpdateFields should return exists=false for window not in store")
        TestErrors++
    }

    ; Test: UpdateFields changed field - updating same value should be changed=false
    result := WL_UpdateFields(testHwnd, { isFocused: true }, "test")
    if (result.changed = false && result.exists = true) {
        Log("PASS: WL_UpdateFields returns changed=false when value unchanged")
        TestPassed++
    } else {
        Log("FAIL: WL_UpdateFields should return changed=false when value unchanged (got changed=" result.changed ")")
        TestErrors++
    }

    ; Clean up - remove test window
    WL_RemoveWindow([testHwnd], true)

    ; ============================================================
    ; WL_ValidateExistence Tests (Ghost Window Detection)
    ; ============================================================
    Log("`n--- WL_ValidateExistence Tests ---")

    ; Test 1: Fake HWNDs removed (IsWindow returns false for non-existent windows)
    Log("Testing ValidateExistence removes fake HWNDs...")
    WL_Init()
    global gWS_Store

    WL_BeginScan()
    fakeRec1 := Map("hwnd", 0x9999001, "title", "Fake Win 1", "class", "FakeClass", "pid", 1,
                    "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 1)
    fakeRec2 := Map("hwnd", 0x9999002, "title", "Fake Win 2", "class", "FakeClass", "pid", 2,
                    "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 2)
    WL_UpsertWindow([fakeRec1, fakeRec2], "test")
    WL_EndScan()

    ; Both should be in store before validation
    if (gWS_Store.Has(0x9999001) && gWS_Store.Has(0x9999002)) {
        Log("PASS: Both fake HWNDs present before ValidateExistence")
        TestPassed++
    } else {
        Log("FAIL: Fake HWNDs should be present before validation")
        TestErrors++
    }

    result := WL_ValidateExistence()

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
    WL_Init()
    WL_BeginScan()
    fakeRec3 := Map("hwnd", 0x9999003, "title", "Fake Win 3", "class", "FakeClass", "pid", 3,
                    "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 1)
    WL_UpsertWindow([fakeRec3], "test")
    WL_EndScan()

    global gWS_Rev
    revBefore := gWS_Rev
    WL_ValidateExistence()
    if (gWS_Rev > revBefore) {
        Log("PASS: ValidateExistence bumped rev after removal")
        TestPassed++
    } else {
        Log("FAIL: ValidateExistence should bump rev after removal (before=" revBefore " after=" gWS_Rev ")")
        TestErrors++
    }

    ; Test 3: Empty store is no-op
    Log("Testing ValidateExistence no-op on empty store...")
    WL_Init()
    ; Drain any queued icon work from previous tests
    WL_PopIconBatch(100)
    gWS_Store := Map()
    revBefore := gWS_Rev
    result := WL_ValidateExistence()
    if (result.removed = 0 && gWS_Rev = revBefore) {
        Log("PASS: ValidateExistence no-op on empty store (removed=0, rev unchanged)")
        TestPassed++
    } else {
        Log("FAIL: ValidateExistence should be no-op on empty store (removed=" result.removed " rev changed=" (gWS_Rev != revBefore) ")")
        TestErrors++
    }

    ; ============================================================
    ; WL_PurgeBlacklisted Tests
    ; ============================================================
    Log("`n--- WL_PurgeBlacklisted Tests ---")

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
        WL_Init()
        WL_BeginScan()
        badRec := Map("hwnd", 0xAA01, "title", "BadTitle Test Window", "class", "SafeClass", "pid", 10,
                      "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 1)
        goodRec := Map("hwnd", 0xAA02, "title", "GoodTitle Window", "class", "SafeClass", "pid", 11,
                       "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 2)
        WL_UpsertWindow([badRec, goodRec], "test")
        WL_EndScan()

        result := WL_PurgeBlacklisted()

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
        WL_Init()
        WL_BeginScan()
        classRec := Map("hwnd", 0xAA03, "title", "Safe Title", "class", "BadClass", "pid", 12,
                        "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 1)
        WL_UpsertWindow([classRec], "test")
        WL_EndScan()

        result := WL_PurgeBlacklisted()
        if (!gWS_Store.Has(0xAA03) && result.removed = 1) {
            Log("PASS: PurgeBlacklisted removed class-matched window (BadClass)")
            TestPassed++
        } else {
            Log("FAIL: PurgeBlacklisted should remove class-matched window (still has=" gWS_Store.Has(0xAA03) " removed=" result.removed ")")
            TestErrors++
        }

        ; Test 4: Rev bumped only when something removed
        Log("Testing PurgeBlacklisted rev behavior...")
        WL_Init()
        WL_BeginScan()
        safeRec := Map("hwnd", 0xAA04, "title", "Completely Safe", "class", "SafeClass", "pid", 13,
                       "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 1)
        WL_UpsertWindow([safeRec], "test")
        WL_EndScan()

        revBefore := gWS_Rev
        result := WL_PurgeBlacklisted()
        if (result.removed = 0 && gWS_Rev = revBefore) {
            Log("PASS: PurgeBlacklisted no rev bump when nothing removed")
            TestPassed++
        } else {
            Log("FAIL: PurgeBlacklisted should not bump rev when nothing removed (removed=" result.removed ")")
            TestErrors++
        }
        WL_RemoveWindow([0xAA04], true)

        ; Test 5: Empty store is no-op
        Log("Testing PurgeBlacklisted no-op on empty store...")
        WL_Init()
        gWS_Store := Map()
        result := WL_PurgeBlacklisted()
        if (result.removed = 0) {
            Log("PASS: PurgeBlacklisted no-op on empty store")
            TestPassed++
        } else {
            Log("FAIL: PurgeBlacklisted should return removed=0 on empty store")
            TestErrors++
        }

        ; Drain icon queue to prevent bleeding into subsequent tests
        WL_PopIconBatch(100)

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
        hIcon := IP_ExtractExeIcon(exePath)
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

    ; Test 2: Icon Resolution Chain - cloaked window should still get EXE icon
    Log("Testing icon resolution chain for cloaked windows...")
    ; Create a mock scenario: we have an exePath, test that we can get an icon from it
    ; even when the "window" would be considered cloaked
    testExe := A_WinDir "\explorer.exe"
    if (FileExist(testExe)) {
        ; Get icon via EXE fallback (simulating what happens for cloaked windows)
        hCopy := WL_GetExeIconCopy(testExe)
        if (!hCopy) {
            master := IP_ExtractExeIcon(testExe)
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

    ; Test 3: GetProcessPath helper
    Log("Testing _IP_GetProcessPath helper...")
    explorerPid := ProcessExist("explorer.exe")
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

    ; Test 4: Hidden windows MUST be enqueued for icon resolution
    ; This is the critical end-to-end test - verifies that cloaked/minimized windows
    ; actually make it into the icon queue (the bug was they were filtered out here)
    Log("Testing hidden window icon enqueue (critical E2E test)...")
    WL_Init()
    WL_BeginScan()

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
    WL_UpsertWindow([cloakedRec], "test")

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
    WL_UpsertWindow([minRec], "test")

    WL_EndScan()

    ; Pop the icon batch - both windows should be in the queue
    batch := WL_PopIconBatch(10)

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
    WL_RemoveWindow([cloakedHwnd, minHwnd], true)

    ; Test 5: WL_EnqueueIconRefresh with throttle
    Log("Testing icon refresh throttle...")
    WL_Init()
    WL_BeginScan()

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
    WL_UpsertWindow([refreshRec], "test")
    WL_EndScan()

    ; First refresh should enqueue (never refreshed before)
    WL_EnqueueIconRefresh(refreshHwnd)
    batch1 := WL_PopIconBatch(10)
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
    WL_UpdateFields(refreshHwnd, { iconLastRefreshTick: A_TickCount }, "test")

    ; Second refresh immediately should be throttled
    WL_EnqueueIconRefresh(refreshHwnd)
    batch2 := WL_PopIconBatch(10)
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
    WL_RemoveWindow([refreshHwnd], true)

    ; Test 6: Icon upgrade - visible window with EXE fallback gets re-queued
    Log("Testing icon upgrade queue (EXE fallback -> WM_GETICON upgrade)...")
    WL_Init()
    WL_BeginScan()

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
    WL_UpsertWindow([upgradeRec], "test")
    WL_EndScan()

    ; Check if upgrade gets queued
    batch3 := WL_PopIconBatch(10)
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
    WL_RemoveWindow([upgradeHwnd], true)

    ; ============================================================
    ; ExeIconCache Prune Tests (no FIFO cap — prune-based cleanup)
    ; ============================================================
    Log("`n--- ExeIconCache Prune Tests ---")

    ; Use fake HICON values (DestroyIcon silently fails for invalid handles)
    global gWS_ExeIconCache
    savedCache := gWS_ExeIconCache
    gWS_ExeIconCache := Map()

    ; Cache grows without eviction
    WL_ExeIconCachePut("a.exe", 1001)
    WL_ExeIconCachePut("b.exe", 1002)
    WL_ExeIconCachePut("c.exe", 1003)
    WL_ExeIconCachePut("d.exe", 1004)
    if (gWS_ExeIconCache.Count = 4) {
        Log("PASS: ExeIconCache: grows to 4 (no FIFO cap)")
        TestPassed++
    } else {
        Log("FAIL: ExeIconCache: expected 4, got " gWS_ExeIconCache.Count)
        TestErrors++
    }

    ; Prune removes orphaned exe paths not used by any live window
    ; Add a window using b.exe so it survives pruning
    gWS_Store := Map()
    gWS_Store[9999] := _WS_NewRecord(9999)
    gWS_Store[9999].exePath := "b.exe"
    pruned := WL_PruneExeIconCache()
    if (pruned = 3) {
        Log("PASS: ExeIconCache prune removed 3 orphaned exe paths")
        TestPassed++
    } else {
        Log("FAIL: ExeIconCache prune expected 3 removed, got " pruned)
        TestErrors++
    }
    if (gWS_ExeIconCache.Has("b.exe") && gWS_ExeIconCache.Count = 1) {
        Log("PASS: ExeIconCache prune kept live exe (b.exe)")
        TestPassed++
    } else {
        Log("FAIL: ExeIconCache prune should keep b.exe, count=" gWS_ExeIconCache.Count)
        TestErrors++
    }
    gWS_Store := Map()  ; Clean up

    ; Restore original state
    gWS_ExeIconCache := savedCache

    ; ============================================================
    ; WL_PruneProcNameCache Tests
    ; ============================================================
    Log("`n--- WL_PruneProcNameCache Tests ---")

    global gWS_ProcNameCache
    savedProcCache := gWS_ProcNameCache

    ; Test 1: Dead PID pruned, live PID kept
    Log("Testing PruneProcNameCache removes dead PIDs, keeps live PIDs...")
    gWS_ProcNameCache := Map()
    livePid := ProcessExist("explorer.exe")
    if (livePid > 0) {
        deadPid := 4000000000  ; PID that does not exist
        gWS_ProcNameCache[livePid] := { name: "explorer.exe", tick: A_TickCount }
        gWS_ProcNameCache[deadPid] := { name: "ghost.exe", tick: A_TickCount }

        pruned := WL_PruneProcNameCache()

        if (pruned = 1) {
            Log("PASS: PruneProcNameCache pruned 1 dead PID")
            TestPassed++
        } else {
            Log("FAIL: PruneProcNameCache should prune 1 dead PID, got pruned=" pruned)
            TestErrors++
        }

        if (!gWS_ProcNameCache.Has(deadPid)) {
            Log("PASS: PruneProcNameCache removed dead PID " deadPid)
            TestPassed++
        } else {
            Log("FAIL: PruneProcNameCache should remove dead PID " deadPid)
            TestErrors++
        }

        if (gWS_ProcNameCache.Has(livePid)) {
            Log("PASS: PruneProcNameCache kept live PID " livePid " (explorer.exe)")
            TestPassed++
        } else {
            Log("FAIL: PruneProcNameCache should keep live PID " livePid)
            TestErrors++
        }
    } else {
        Log("SKIP: explorer.exe not running for PruneProcNameCache test")
    }

    ; Test 2: Empty cache returns 0
    Log("Testing PruneProcNameCache on empty cache...")
    gWS_ProcNameCache := Map()
    pruned := WL_PruneProcNameCache()
    if (pruned = 0) {
        Log("PASS: PruneProcNameCache returns 0 for empty cache")
        TestPassed++
    } else {
        Log("FAIL: PruneProcNameCache should return 0 for empty cache, got " pruned)
        TestErrors++
    }

    ; Test 3: All-dead PIDs pruned
    Log("Testing PruneProcNameCache removes all dead PIDs...")
    gWS_ProcNameCache := Map()
    gWS_ProcNameCache[4000000001] := { name: "dead1.exe", tick: A_TickCount }
    gWS_ProcNameCache[4000000002] := { name: "dead2.exe", tick: A_TickCount }
    gWS_ProcNameCache[4000000003] := { name: "dead3.exe", tick: A_TickCount }

    pruned := WL_PruneProcNameCache()
    if (pruned = 3) {
        Log("PASS: PruneProcNameCache pruned all 3 dead PIDs")
        TestPassed++
    } else {
        Log("FAIL: PruneProcNameCache should prune 3, got " pruned)
        TestErrors++
    }

    if (gWS_ProcNameCache.Count = 0) {
        Log("PASS: PruneProcNameCache left cache empty after pruning all")
        TestPassed++
    } else {
        Log("FAIL: PruneProcNameCache should leave cache empty, got count=" gWS_ProcNameCache.Count)
        TestErrors++
    }

    ; Restore original cache
    gWS_ProcNameCache := savedProcCache

    ; ============================================================
    ; WL_UpdateProcessName Tests
    ; ============================================================
    Log("`n--- WL_UpdateProcessName Tests ---")

    savedProcCache2 := gWS_ProcNameCache

    ; Test 1: Guard - pid=0 and name="" both rejected
    Log("Testing UpdateProcessName guard: pid=0 and name='' rejected...")
    WL_Init()
    gWS_ProcNameCache := Map()
    WL_UpdateProcessName(0, "ghost.exe")
    WL_UpdateProcessName(999, "")
    if (gWS_ProcNameCache.Count = 0) {
        Log("PASS: UpdateProcessName guard rejected pid=0 and name=''")
        TestPassed++
    } else {
        Log("FAIL: UpdateProcessName guard should reject pid=0 and name='', cache count=" gWS_ProcNameCache.Count)
        TestErrors++
    }

    ; Test 2: Fan-out - two windows with same PID both updated
    Log("Testing UpdateProcessName fan-out: two windows same PID both updated...")
    WL_Init()
    gWS_ProcNameCache := Map()
    WL_BeginScan()
    fanRec1 := Map("hwnd", 0xBB01, "title", "Fan Win 1", "class", "Test", "pid", 500,
                   "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 1)
    fanRec2 := Map("hwnd", 0xBB02, "title", "Fan Win 2", "class", "Test", "pid", 500,
                   "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 2)
    fanRec3 := Map("hwnd", 0xBB03, "title", "Other PID", "class", "Test", "pid", 600,
                   "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 3)
    WL_UpsertWindow([fanRec1, fanRec2, fanRec3], "test")
    WL_EndScan()
    ; Drain icon queue from upserts
    WL_PopIconBatch(100)

    WL_UpdateProcessName(500, "notepad.exe")

    if (gWS_Store[0xBB01].processName = "notepad.exe" && gWS_Store[0xBB02].processName = "notepad.exe") {
        Log("PASS: Both pid=500 windows updated to notepad.exe")
        TestPassed++
    } else {
        Log("FAIL: Fan-out should update both pid=500 windows (got '"
            . gWS_Store[0xBB01].processName "', '" gWS_Store[0xBB02].processName "')")
        TestErrors++
    }

    ; Test 3: Isolation - different PID not touched
    Log("Testing UpdateProcessName isolation: different PID not touched...")
    if (gWS_Store[0xBB03].processName = "") {
        Log("PASS: pid=600 window processName still empty")
        TestPassed++
    } else {
        Log("FAIL: pid=600 window should not be touched, got '" gWS_Store[0xBB03].processName "'")
        TestErrors++
    }

    ; Test 4: Rev bumped exactly once
    Log("Testing UpdateProcessName rev bump...")
    WL_Init()
    gWS_ProcNameCache := Map()
    WL_BeginScan()
    revRec := Map("hwnd", 0xBB04, "title", "Rev Test", "class", "Test", "pid", 700,
                  "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 1)
    WL_UpsertWindow([revRec], "test")
    WL_EndScan()
    WL_PopIconBatch(100)

    revBefore := gWS_Rev
    WL_UpdateProcessName(700, "calc.exe")
    if (gWS_Rev = revBefore + 1) {
        Log("PASS: Rev bumped exactly once after UpdateProcessName")
        TestPassed++
    } else {
        Log("FAIL: Rev should bump once, before=" revBefore " after=" gWS_Rev)
        TestErrors++
    }

    ; Test 5: No rev bump when name unchanged
    Log("Testing UpdateProcessName no rev bump when name unchanged...")
    revBefore := gWS_Rev
    WL_UpdateProcessName(700, "calc.exe")  ; Same name again
    if (gWS_Rev = revBefore) {
        Log("PASS: No rev bump when name unchanged")
        TestPassed++
    } else {
        Log("FAIL: Rev should not bump when name unchanged, before=" revBefore " after=" gWS_Rev)
        TestErrors++
    }

    ; Test 6: ProcNameCache grows without cap (prune-based cleanup)
    Log("Testing ProcNameCache grows without cap...")
    WL_Init()
    gWS_ProcNameCache := Map()

    ; Cache grows to 4 without eviction (no FIFO cap)
    WL_UpdateProcessName(1001, "a.exe")
    WL_UpdateProcessName(1002, "b.exe")
    WL_UpdateProcessName(1003, "c.exe")
    WL_UpdateProcessName(1004, "d.exe")

    if (gWS_ProcNameCache.Count = 4) {
        Log("PASS: ProcNameCache grows to 4 (no FIFO cap)")
        TestPassed++
    } else {
        Log("FAIL: ProcNameCache expected 4, got " gWS_ProcNameCache.Count)
        TestErrors++
    }

    if (gWS_ProcNameCache.Has(1001) && gWS_ProcNameCache.Has(1004)) {
        Log("PASS: ProcNameCache all entries present (no eviction)")
        TestPassed++
    } else {
        Log("FAIL: ProcNameCache should have all 4 entries")
        TestErrors++
    }

    ; Verify prune removes dead PIDs (1001-1004 are fake PIDs that don't exist)
    pruned := WL_PruneProcNameCache()
    if (pruned = 4) {
        Log("PASS: ProcNameCache prune removed 4 dead PIDs")
        TestPassed++
    } else {
        Log("FAIL: ProcNameCache prune expected 4 removed, got " pruned)
        TestErrors++
    }

    ; Restore
    gWS_ProcNameCache := savedProcCache2

    ; ============================================================
    ; Blacklist Pattern Matching Stress Tests
    ; ============================================================
    ; Tests BL_CompileWildcard regex escaping and Blacklist_IsMatch
    ; with diverse patterns that stress metacharacter handling,
    ; wildcards, case sensitivity, and edge cases.
    Log("`n--- Blacklist Pattern Matching Stress Tests ---")

    global gBlacklist_FilePath, gBlacklist_Loaded
    savedBlPathPM := gBlacklist_FilePath

    ; --- Group 1: Regex metacharacters in patterns ---
    ; BL_CompileWildcard must escape . + ^ $ { } | ( ) \ [ ]
    Log("Testing pattern matching with regex metacharacters...")

    testBlDirPM := A_Temp "\tabby_blpm_test_" A_TickCount
    testBlPathPM := testBlDirPM "\blacklist.txt"

    try {
        DirCreate(testBlDirPM)

        blContentPM := "[Title]`nC++ Builder`nApp (Beta)`nfile.txt`nprice $5`n[Class]`n[Pair]`n"
        FileAppend(blContentPM, testBlPathPM, "UTF-8")
        Blacklist_Init(testBlPathPM)

        ; Exact metacharacter matches
        if (Blacklist_IsMatch("C++ Builder", "AnyClass")) {
            Log("PASS: Metachar: 'C++ Builder' matches pattern 'C++ Builder'")
            TestPassed++
        } else {
            Log("FAIL: Metachar: 'C++ Builder' should match (+ is escaped)")
            TestErrors++
        }

        if (Blacklist_IsMatch("App (Beta)", "AnyClass")) {
            Log("PASS: Metachar: 'App (Beta)' matches pattern 'App (Beta)'")
            TestPassed++
        } else {
            Log("FAIL: Metachar: 'App (Beta)' should match (parens are escaped)")
            TestErrors++
        }

        if (Blacklist_IsMatch("file.txt", "AnyClass")) {
            Log("PASS: Metachar: 'file.txt' matches pattern 'file.txt'")
            TestPassed++
        } else {
            Log("FAIL: Metachar: 'file.txt' should match (dot is escaped)")
            TestErrors++
        }

        ; Dot NOT treated as wildcard: "file.txt" should NOT match "fileXtxt"
        if (!Blacklist_IsMatch("fileXtxt", "AnyClass")) {
            Log("PASS: Metachar: 'fileXtxt' does NOT match pattern 'file.txt' (dot escaped)")
            TestPassed++
        } else {
            Log("FAIL: Metachar: 'fileXtxt' should NOT match 'file.txt' (dot must be escaped)")
            TestErrors++
        }

        if (Blacklist_IsMatch("price $5", "AnyClass")) {
            Log("PASS: Metachar: 'price $5' matches pattern 'price $5'")
            TestPassed++
        } else {
            Log("FAIL: Metachar: 'price $5' should match ($ is escaped)")
            TestErrors++
        }

        ; Cleanup group 1
        try FileDelete(testBlPathPM)
        try DirDelete(testBlDirPM)
    } catch as e {
        Log("FAIL: Metachar group error: " e.Message)
        TestErrors++
        try DirDelete(testBlDirPM, true)
    }

    ; --- Group 2a: Multi-wildcard and single-char wildcard ---
    Log("Testing multi-wildcard and single-char wildcard patterns...")

    testBlDirPM2a := A_Temp "\tabby_blpm2a_test_" A_TickCount
    testBlPathPM2a := testBlDirPM2a "\blacklist.txt"

    try {
        DirCreate(testBlDirPM2a)

        blContentPM2a := "[Title]`n*foo*bar*`nApp?`n[Class]`n[Pair]`n"
        FileAppend(blContentPM2a, testBlPathPM2a, "UTF-8")
        Blacklist_Init(testBlPathPM2a)

        ; Multiple wildcards: *foo*bar*
        if (Blacklist_IsMatch("prefix_foo_middle_bar_suffix", "AnyClass")) {
            Log("PASS: Wildcard: '*foo*bar*' matches 'prefix_foo_middle_bar_suffix'")
            TestPassed++
        } else {
            Log("FAIL: Wildcard: '*foo*bar*' should match with text between and around")
            TestErrors++
        }

        if (Blacklist_IsMatch("foobar", "AnyClass")) {
            Log("PASS: Wildcard: '*foo*bar*' matches 'foobar' (adjacent)")
            TestPassed++
        } else {
            Log("FAIL: Wildcard: '*foo*bar*' should match 'foobar'")
            TestErrors++
        }

        if (!Blacklist_IsMatch("barfoo", "AnyClass")) {
            Log("PASS: Wildcard: '*foo*bar*' does NOT match 'barfoo' (wrong order)")
            TestPassed++
        } else {
            Log("FAIL: Wildcard: '*foo*bar*' should NOT match 'barfoo'")
            TestErrors++
        }

        ; Single-char wildcard: App? matches App1 but not App12
        if (Blacklist_IsMatch("App1", "AnyClass")) {
            Log("PASS: Wildcard: 'App?' matches 'App1'")
            TestPassed++
        } else {
            Log("FAIL: Wildcard: 'App?' should match 'App1'")
            TestErrors++
        }

        if (!Blacklist_IsMatch("App12", "AnyClass")) {
            Log("PASS: Wildcard: 'App?' does NOT match 'App12' (too long)")
            TestPassed++
        } else {
            Log("FAIL: Wildcard: 'App?' should NOT match 'App12'")
            TestErrors++
        }

        ; Cleanup group 2a
        try FileDelete(testBlPathPM2a)
        try DirDelete(testBlDirPM2a)
    } catch as e {
        Log("FAIL: Multi-wildcard group error: " e.Message)
        TestErrors++
        try DirDelete(testBlDirPM2a, true)
    }

    ; --- Group 2b: Star-matches-all and case insensitivity ---
    Log("Testing star-matches-all and case insensitivity...")

    testBlDirPM2b := A_Temp "\tabby_blpm2b_test_" A_TickCount
    testBlPathPM2b := testBlDirPM2b "\blacklist.txt"

    try {
        DirCreate(testBlDirPM2b)

        blContentPM2b := "[Title]`n*`n[Class]`nNOTEPAD`n[Pair]`n"
        FileAppend(blContentPM2b, testBlPathPM2b, "UTF-8")
        Blacklist_Init(testBlPathPM2b)

        ; Star matches everything
        if (Blacklist_IsMatch("Literally Anything", "AnyClass")) {
            Log("PASS: Wildcard: '*' matches any title")
            TestPassed++
        } else {
            Log("FAIL: Wildcard: '*' should match any title")
            TestErrors++
        }

        ; Case insensitivity: NOTEPAD class pattern matches Notepad
        if (Blacklist_IsMatch("AnyTitle", "Notepad")) {
            Log("PASS: Case: class pattern 'NOTEPAD' matches 'Notepad'")
            TestPassed++
        } else {
            Log("FAIL: Case: 'NOTEPAD' should match 'Notepad' (case-insensitive)")
            TestErrors++
        }

        if (Blacklist_IsMatch("AnyTitle", "notepad")) {
            Log("PASS: Case: class pattern 'NOTEPAD' matches 'notepad'")
            TestPassed++
        } else {
            Log("FAIL: Case: 'NOTEPAD' should match 'notepad' (case-insensitive)")
            TestErrors++
        }

        ; Cleanup group 2b
        try FileDelete(testBlPathPM2b)
        try DirDelete(testBlDirPM2b)
    } catch as e {
        Log("FAIL: Star/case group error: " e.Message)
        TestErrors++
        try DirDelete(testBlDirPM2b, true)
    }

    ; --- Group 3: Not-loaded and empty list edge cases ---
    Log("Testing not-loaded and empty list edge cases...")

    ; Test: gBlacklist_Loaded=false -> always returns false
    savedLoaded := gBlacklist_Loaded
    gBlacklist_Loaded := false
    if (!Blacklist_IsMatch("BadTitleFoo", "BadClass")) {
        Log("PASS: Not-loaded: IsMatch returns false when gBlacklist_Loaded=false")
        TestPassed++
    } else {
        Log("FAIL: Not-loaded: IsMatch should return false when gBlacklist_Loaded=false")
        TestErrors++
    }
    gBlacklist_Loaded := savedLoaded

    ; Test: Loaded but empty lists -> never matches
    testBlDirPM3 := A_Temp "\tabby_blpm3_test_" A_TickCount
    testBlPathPM3 := testBlDirPM3 "\blacklist.txt"

    try {
        DirCreate(testBlDirPM3)

        blContentPM3 := "[Title]`n[Class]`n[Pair]`n"
        FileAppend(blContentPM3, testBlPathPM3, "UTF-8")
        Blacklist_Init(testBlPathPM3)

        if (!Blacklist_IsMatch("AnyTitle", "AnyClass")) {
            Log("PASS: Empty lists: IsMatch returns false when loaded but no patterns")
            TestPassed++
        } else {
            Log("FAIL: Empty lists: IsMatch should return false with empty pattern lists")
            TestErrors++
        }

        ; Cleanup group 3
        try FileDelete(testBlPathPM3)
        try DirDelete(testBlDirPM3)
    } catch as e {
        Log("FAIL: Empty list group error: " e.Message)
        TestErrors++
        try DirDelete(testBlDirPM3, true)
    }

    ; Restore original blacklist
    Blacklist_Init(savedBlPathPM)

    ; ============================================================
    ; Blacklist_IsWindowEligible Synthetic Tests
    ; ============================================================
    ; These test the centralized eligibility function used by ALL producers.
    ; UseAltTabEligibility=false bypasses DllCall-dependent checks so we can
    ; test purely with synthetic title/class parameters.
    Log("`n--- Blacklist_IsWindowEligible Synthetic Tests ---")

    global gBlacklist_FilePath
    savedBlPathElig := gBlacklist_FilePath
    savedUseAltTab := cfg.HasOwnProp("UseAltTabEligibility") ? cfg.UseAltTabEligibility : true
    savedUseBlacklist := cfg.HasOwnProp("UseBlacklist") ? cfg.UseBlacklist : true

    ; Bypass Alt-Tab DllCall eligibility for synthetic testing
    cfg.UseAltTabEligibility := false
    cfg.UseBlacklist := true
    ; Also update cached globals (production code reads these in hot paths)
    global gCached_UseAltTabEligibility, gCached_UseBlacklist
    gCached_UseAltTabEligibility := false
    gCached_UseBlacklist := true

    testBlDirElig := A_Temp "\tabby_bwelig_test_" A_TickCount
    testBlPathElig := testBlDirElig "\blacklist.txt"

    try {
        DirCreate(testBlDirElig)

        ; Write test blacklist with title, class, and pair patterns
        blContent := "[Title]`nBadTitle*`n[Class]`nBadClass`n[Pair]`nSpecialClass|SpecialTitle*`n"
        FileAppend(blContent, testBlPathElig, "UTF-8")
        Blacklist_Init(testBlPathElig)

        ; Test 1: Empty title -> false
        result := Blacklist_IsWindowEligible(0, "", "AnyClass")
        AssertEq(result, false, "IsWindowEligible: empty title -> false")

        ; Test 2: Blacklisted title -> false
        result := Blacklist_IsWindowEligible(0, "BadTitle Something", "SafeClass")
        AssertEq(result, false, "IsWindowEligible: blacklisted title -> false")

        ; Test 3: Clean window -> true
        result := Blacklist_IsWindowEligible(0, "Good Window", "SafeClass")
        AssertEq(result, true, "IsWindowEligible: clean window -> true")

        ; Test 4: UseBlacklist=false -> blacklisted title passes
        cfg.UseBlacklist := false
        gCached_UseBlacklist := false
        result := Blacklist_IsWindowEligible(0, "BadTitle Something", "SafeClass")
        AssertEq(result, true, "IsWindowEligible: UseBlacklist=false -> blacklisted passes")
        cfg.UseBlacklist := true
        gCached_UseBlacklist := true

        ; Test 5: Blacklisted class -> false
        result := Blacklist_IsWindowEligible(0, "Good Window", "BadClass")
        AssertEq(result, false, "IsWindowEligible: blacklisted class -> false")

        ; Test 6: Pair match (both class+title) -> false
        result := Blacklist_IsWindowEligible(0, "SpecialTitle App", "SpecialClass")
        AssertEq(result, false, "IsWindowEligible: pair match (class+title) -> false")

        ; Test 7: Pair partial (title only, class doesn't match) -> true
        result := Blacklist_IsWindowEligible(0, "SpecialTitle App", "OtherClass")
        AssertEq(result, true, "IsWindowEligible: pair partial (title only) -> true")

    } catch as e {
        Log("FAIL: Blacklist_IsWindowEligible test error: " e.Message)
        TestErrors++
    }

    ; Restore original state
    cfg.UseAltTabEligibility := savedUseAltTab
    cfg.UseBlacklist := savedUseBlacklist
    gCached_UseAltTabEligibility := savedUseAltTab
    gCached_UseBlacklist := savedUseBlacklist
    Blacklist_Init(savedBlPathElig)

    ; Cleanup
    try FileDelete(testBlPathElig)
    try DirDelete(testBlDirElig)

    ; ============================================================
    ; Sort Comparator Tests (_WS_CmpTitle, _WS_CmpPid, _WS_CmpProcessName)
    ; ============================================================
    Log("`n--- Sort Comparator Tests ---")

    ; _WS_CmpTitle: locale-based string comparison
    objA := {title: "Alpha", pid: 0, processName: ""}
    objB := {title: "Beta", pid: 0, processName: ""}
    objC := {title: "Alpha", pid: 0, processName: ""}

    AssertEq(_WS_CmpTitle(objA, objB) < 0, true, "CmpTitle: Alpha < Beta returns negative")
    AssertEq(_WS_CmpTitle(objB, objA) > 0, true, "CmpTitle: Beta > Alpha returns positive")
    AssertEq(_WS_CmpTitle(objA, objC), 0, "CmpTitle: Alpha = Alpha returns 0")

    ; _WS_CmpPid: numeric comparison
    pidA := {pid: 100}
    pidB := {pid: 200}
    pidC := {pid: 100}

    AssertEq(_WS_CmpPid(pidA, pidB), -1, "CmpPid: 100 < 200 returns -1")
    AssertEq(_WS_CmpPid(pidB, pidA), 1, "CmpPid: 200 > 100 returns 1")
    AssertEq(_WS_CmpPid(pidA, pidC), 0, "CmpPid: 100 = 100 returns 0")

    ; _WS_CmpProcessName: locale-based string comparison
    pnA := {processName: "chrome.exe"}
    pnB := {processName: "firefox.exe"}
    pnC := {processName: "chrome.exe"}

    AssertEq(_WS_CmpProcessName(pnA, pnB) < 0, true, "CmpProcessName: chrome < firefox returns negative")
    AssertEq(_WS_CmpProcessName(pnB, pnA) > 0, true, "CmpProcessName: firefox > chrome returns positive")
    AssertEq(_WS_CmpProcessName(pnA, pnC), 0, "CmpProcessName: chrome = chrome returns 0")

    ; ============================================================
    ; WL_GetDisplayList Filtering Tests
    ; ============================================================
    Log("`n--- WL_GetDisplayList Filtering Tests ---")

    ; Set up store with 5 synthetic windows with varied properties
    WL_Init()
    WL_SetCurrentWorkspace("ws-1", "Desktop 1")
    WL_BeginScan()

    ; Window 1: normal, visible, on current workspace, MRU=1000
    projRec1 := Map("hwnd", 0xF001, "title", "Zulu Window", "class", "Test", "pid", 10,
                     "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 3,
                     "lastActivatedTick", 1000, "isFocused", false,
                     "workspaceName", "Desktop 1", "isOnCurrentWorkspace", true, "processName", "zulu.exe")
    ; Window 2: cloaked (other workspace), MRU=3000 (most recent)
    projRec2 := Map("hwnd", 0xF002, "title", "Alpha Window", "class", "Test", "pid", 20,
                     "isVisible", true, "isCloaked", true, "isMinimized", false, "z", 1,
                     "lastActivatedTick", 3000, "isFocused", false,
                     "workspaceName", "Desktop 2", "isOnCurrentWorkspace", false, "processName", "alpha.exe")
    ; Window 3: minimized, on current workspace, MRU=2000
    projRec3 := Map("hwnd", 0xF003, "title", "Middle Window", "class", "Test", "pid", 5,
                     "isVisible", false, "isCloaked", false, "isMinimized", true, "z", 5,
                     "lastActivatedTick", 2000, "isFocused", false,
                     "workspaceName", "Desktop 1", "isOnCurrentWorkspace", true, "processName", "middle.exe")
    ; Window 4: normal, visible, on current workspace, MRU=500
    projRec4 := Map("hwnd", 0xF004, "title", "Beta Window", "class", "Test", "pid", 30,
                     "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 2,
                     "lastActivatedTick", 500, "isFocused", false,
                     "workspaceName", "Desktop 1", "isOnCurrentWorkspace", true, "processName", "beta.exe")
    ; Window 5: cloaked + minimized, other workspace, MRU=100
    projRec5 := Map("hwnd", 0xF005, "title", "Echo Window", "class", "Test", "pid", 15,
                     "isVisible", false, "isCloaked", true, "isMinimized", true, "z", 4,
                     "lastActivatedTick", 100, "isFocused", false,
                     "workspaceName", "Desktop 2", "isOnCurrentWorkspace", false, "processName", "echo.exe")

    WL_UpsertWindow([projRec1, projRec2, projRec3, projRec4, projRec5], "test")
    WL_EndScan()
    WL_PopIconBatch(100)

    ; Test 1: Default display list excludes cloaked (2 cloaked out of 5)
    proj := WL_GetDisplayList()
    AssertEq(proj.items.Length, 3, "GetDisplayList default: 3 items (excludes 2 cloaked)")

    ; Test 2: includeCloaked=true shows all 5
    proj := WL_GetDisplayList({includeCloaked: true})
    AssertEq(proj.items.Length, 5, "GetDisplayList includeCloaked=true: all 5 items")

    ; Test 3: includeMinimized=false excludes minimized (rec3 is minimized + not cloaked)
    proj := WL_GetDisplayList({includeMinimized: false})
    AssertEq(proj.items.Length, 2, "GetDisplayList includeMinimized=false: 2 items (excludes minimized+cloaked)")

    ; Test 4: currentWorkspaceOnly=true filters to Desktop 1
    proj := WL_GetDisplayList({includeCloaked: true, currentWorkspaceOnly: true})
    AssertEq(proj.items.Length, 3, "GetDisplayList currentWorkspaceOnly: 3 items on Desktop 1")

    ; Test 5: Combined strict filters (currentWorkspaceOnly + no minimized + no cloaked)
    proj := WL_GetDisplayList({currentWorkspaceOnly: true, includeMinimized: false, includeCloaked: false})
    AssertEq(proj.items.Length, 2, "GetDisplayList strict: 2 items (current WS, not min, not cloaked)")

    ; Test 6: MRU sort order (default) - highest lastActivatedTick first
    proj := WL_GetDisplayList({includeCloaked: true})
    AssertEq(proj.items[1].hwnd + 0, 0xF002, "GetDisplayList MRU sort: first item is 0xF002 (tick=3000)")
    AssertEq(proj.items[5].hwnd + 0, 0xF005, "GetDisplayList MRU sort: last item is 0xF005 (tick=100)")

    ; Test 7: hwndsOnly columns
    proj := WL_GetDisplayList({columns: "hwndsOnly", includeCloaked: true})
    AssertEq(proj.HasOwnProp("hwnds"), true, "GetDisplayList hwndsOnly: has 'hwnds' property")
    AssertEq(proj.HasOwnProp("items"), false, "GetDisplayList hwndsOnly: no 'items' property")
    AssertEq(proj.hwnds.Length, 5, "GetDisplayList hwndsOnly: 5 hwnds")

    ; Test 8: Sort="Title" produces alphabetical order
    proj := WL_GetDisplayList({sort: "Title", includeCloaked: true})
    AssertEq(proj.items[1].title, "Alpha Window", "GetDisplayList Title sort: first is Alpha")
    AssertEq(proj.items[5].title, "Zulu Window", "GetDisplayList Title sort: last is Zulu")

    ; Test 9: Sort="Pid" produces numeric order
    proj := WL_GetDisplayList({sort: "Pid", includeCloaked: true})
    AssertEq(proj.items[1].pid + 0, 5, "GetDisplayList Pid sort: first pid=5")
    AssertEq(proj.items[5].pid + 0, 30, "GetDisplayList Pid sort: last pid=30")

    ; Test 10: Sort="ProcessName" produces alphabetical order
    proj := WL_GetDisplayList({sort: "ProcessName", includeCloaked: true})
    AssertEq(proj.items[1].processName, "alpha.exe", "GetDisplayList ProcessName sort: first is alpha.exe")
    AssertEq(proj.items[5].processName, "zulu.exe", "GetDisplayList ProcessName sort: last is zulu.exe")

    ; Test 11: Empty store returns empty items
    WL_Init()
    gWS_Store := Map()
    proj := WL_GetDisplayList()
    AssertEq(proj.items.Length, 0, "GetDisplayList empty store: 0 items")

    ; Drain icon queue
    WL_PopIconBatch(100)

    ; ============================================================
    ; _Blacklist_Reload Functional Tests
    ; ============================================================
    Log("`n--- _Blacklist_Reload Tests ---")

    global gBlacklist_FilePath, gBlacklist_Loaded
    savedBlPathReload := gBlacklist_FilePath

    testBlDirReload := A_Temp "\tabby_blreload_test_" A_TickCount
    testBlPathReload := testBlDirReload "\blacklist.txt"

    try {
        DirCreate(testBlDirReload)

        ; Step 1: Init with patterns A
        blContentA := "[Title]`nPatternA*`nExactTitleA`n[Class]`nClassA`n[Pair]`nPairClassA|PairTitleA*`n"
        FileAppend(blContentA, testBlPathReload, "UTF-8")
        Blacklist_Init(testBlPathReload)

        ; Verify patterns A match
        AssertEq(Blacklist_IsMatch("PatternA_Suffix", "OtherClass"), true, "Reload: patterns A title wildcard matches")
        AssertEq(Blacklist_IsMatch("ExactTitleA", "OtherClass"), true, "Reload: patterns A exact title matches")
        AssertEq(Blacklist_IsMatch("AnyTitle", "ClassA"), true, "Reload: patterns A class matches")

        ; Step 2: Overwrite file with patterns B and call Reload()
        FileDelete(testBlPathReload)
        blContentB := "[Title]`nPatternB*`n[Class]`nClassB`n[Pair]`nPairClassB|PairTitleB*`n"
        FileAppend(blContentB, testBlPathReload, "UTF-8")

        reloadResult := _Blacklist_Reload()
        AssertEq(reloadResult, true, "Reload: returns true on successful reload")

        ; Step 3: New patterns B match
        AssertEq(Blacklist_IsMatch("PatternB_Suffix", "OtherClass"), true, "Reload: new pattern B title matches after reload")
        AssertEq(Blacklist_IsMatch("AnyTitle", "ClassB"), true, "Reload: new pattern B class matches after reload")

        ; Step 4: Old patterns A no longer match
        AssertEq(Blacklist_IsMatch("PatternA_Suffix", "OtherClass"), false, "Reload: old pattern A title no longer matches")
        AssertEq(Blacklist_IsMatch("ExactTitleA", "OtherClass"), false, "Reload: old exact title A no longer matches")
        AssertEq(Blacklist_IsMatch("AnyTitle", "ClassA"), false, "Reload: old class A no longer matches")

        ; Step 5: Pair patterns work after reload
        AssertEq(Blacklist_IsMatch("PairTitleB_Suffix", "PairClassB"), true, "Reload: pair B matches after reload")

        ; Cleanup
        try FileDelete(testBlPathReload)
        try DirDelete(testBlDirReload)
        Blacklist_Init(savedBlPathReload)
    } catch as e {
        Log("FAIL: _Blacklist_Reload test error: " e.Message)
        TestErrors++
        try DirDelete(testBlDirReload, true)
        Blacklist_Init(savedBlPathReload)
    }
}
