; Live Tests - Features
; In-process DisplayList Options, Blacklist E2E, Stats E2E
; Included by test_live.ahk
#Include test_utils.ahk

RunLiveTests_Features() {
    global TestPassed, TestErrors, cfg

    ; Ensure WindowList is populated with real windows for all tests
    global gWS_Store := Map()
    global gWS_Rev := 0
    WL_Init()
    WL_BeginScan()
    realWindows := WinEnumLite_ScanAll()
    WL_UpsertWindow(realWindows, "winenum_lite")
    WL_EndScan()

    baseProj := WL_GetDisplayList({ sort: "Z" })
    Log("  Feature tests: WindowList populated with " baseProj.items.Length " windows")

    ; ============================================================
    ; DisplayList Options E2E Test (in-process, real windows)
    ; ============================================================
    Log("`n--- DisplayList Options E2E Test ---")

    ; === Test columns: hwndsOnly ===
    hwndsProj := WL_GetDisplayList({ sort: "Z", columns: "hwndsOnly" })
    if (hwndsProj.HasOwnProp("hwnds")) {
        if (hwndsProj.hwnds.Length > 0 && IsInteger(hwndsProj.hwnds[1])) {
            Log("PASS: columns=hwndsOnly returned " hwndsProj.hwnds.Length " hwnds")
            TestPassed++
        } else if (hwndsProj.hwnds.Length = 0) {
            Log("FAIL: columns=hwndsOnly returned empty array")
            TestErrors++
        } else {
            Log("FAIL: columns=hwndsOnly returned non-integer hwnd")
            TestErrors++
        }
    } else {
        Log("FAIL: columns=hwndsOnly missing 'hwnds' property")
        TestErrors++
    }

    ; === Test includeMinimized: true vs false ===
    projWithMin := WL_GetDisplayList({ sort: "Z", includeMinimized: true })
    projWithoutMin := WL_GetDisplayList({ sort: "Z", includeMinimized: false })

    countMinimized := 0
    for _, item in projWithMin.items {
        if (item.isMinimized)
            countMinimized++
    }

    hasMinInFiltered := false
    for _, item in projWithoutMin.items {
        if (item.isMinimized) {
            hasMinInFiltered := true
            break
        }
    }

    if (!hasMinInFiltered) {
        Log("PASS: includeMinimized=false filters minimized (with=" projWithMin.items.Length ", without=" projWithoutMin.items.Length ", minimized=" countMinimized ")")
        TestPassed++
    } else {
        Log("FAIL: includeMinimized=false still has minimized windows")
        TestErrors++
    }

    ; === Test includeCloaked: true vs false ===
    projWithCloaked := WL_GetDisplayList({ sort: "Z", includeCloaked: true })
    projWithoutCloaked := WL_GetDisplayList({ sort: "Z", includeCloaked: false })

    countCloaked := 0
    for _, item in projWithCloaked.items {
        if (item.isCloaked)
            countCloaked++
    }

    hasCloakedInFiltered := false
    for _, item in projWithoutCloaked.items {
        if (item.isCloaked) {
            hasCloakedInFiltered := true
            break
        }
    }

    if (!hasCloakedInFiltered) {
        Log("PASS: includeCloaked=false filters cloaked (with=" projWithCloaked.items.Length ", without=" projWithoutCloaked.items.Length ", cloaked=" countCloaked ")")
        TestPassed++
    } else {
        Log("FAIL: includeCloaked=false still has cloaked windows")
        TestErrors++
    }

    ; === Test currentWorkspaceOnly: true ===
    projCurrentWS := WL_GetDisplayList({ sort: "Z", currentWorkspaceOnly: true })

    allOnCurrent := true
    for _, item in projCurrentWS.items {
        if (!item.isOnCurrentWorkspace) {
            allOnCurrent := false
            break
        }
    }

    if (allOnCurrent) {
        Log("PASS: currentWorkspaceOnly=true filters to current workspace (" projCurrentWS.items.Length " items)")
        TestPassed++
    } else {
        Log("FAIL: currentWorkspaceOnly=true has windows from other workspaces")
        TestErrors++
    }

    ; === Test Title sort ===
    titleProj := WL_GetDisplayList({ sort: "Title" })
    if (titleProj.items.Length >= 2) {
        first := titleProj.items[1]
        second := titleProj.items[2]
        ; Title sort should be alphabetical (case-insensitive)
        if (StrCompare(first.title, second.title, true) <= 0) {
            Log("PASS: Title sort order correct ('" SubStr(first.title, 1, 20) "' <= '" SubStr(second.title, 1, 20) "')")
            TestPassed++
        } else {
            Log("FAIL: Title sort order wrong ('" SubStr(first.title, 1, 20) "' > '" SubStr(second.title, 1, 20) "')")
            TestErrors++
        }
    } else {
        Log("SKIP: Title sort check needs >= 2 items")
    }

    ; ============================================================
    ; Blacklist E2E Test (in-process, real windows)
    ; ============================================================
    Log("`n--- Blacklist E2E Test ---")

    ; Get initial state
    initialProj := WL_GetDisplayList({ sort: "Z" })
    initialCount := initialProj.items.Length
    Log("  Initial display list has " initialCount " windows")

    ; Find a class to blacklist (pick one that exists, prefer one with few windows)
    testClass := ""
    testClassCount := 0
    for _, item in initialProj.items {
        cls := item.class
        if (cls = "")
            continue
        ; Count how many windows have this class
        classCount := 0
        for _, item2 in initialProj.items {
            if (item2.class = cls)
                classCount++
        }
        if (testClass = "" || classCount < testClassCount) {
            testClass := cls
            testClassCount := classCount
        }
    }

    if (testClass = "") {
        Log("SKIP: No suitable class found for blacklist test")
    } else {
        Log("  Testing blacklist with class '" testClass "' (" testClassCount " windows)")

        ; Save and modify blacklist
        blFilePath := A_ScriptDir "\..\src\shared\blacklist.txt"
        originalBlacklist := ""
        try originalBlacklist := FileRead(blFilePath, "UTF-8")

        ; === Test 1: Class blacklist removes windows ===
        Blacklist_AddClass(testClass)
        Blacklist_Init(blFilePath)
        WL_PurgeBlacklisted()

        afterProj := WL_GetDisplayList({ sort: "Z" })
        remainingWithClass := 0
        for _, item in afterProj.items {
            if (item.class = testClass)
                remainingWithClass++
        }

        if (remainingWithClass = 0) {
            Log("PASS: Class blacklist removed " testClassCount " window(s) with class '" testClass "'")
            TestPassed++
        } else {
            Log("FAIL: Class blacklist did not remove windows (expected 0, got " remainingWithClass ")")
            TestErrors++
        }

        ; === Test 2: Restore blacklist and re-scan brings windows back ===
        try {
            FileDelete(blFilePath)
            FileAppend(originalBlacklist, blFilePath, "UTF-8")
        }
        Blacklist_Init(blFilePath)

        ; Re-scan to add windows back
        WL_BeginScan()
        freshWindows := WinEnumLite_ScanAll()
        WL_UpsertWindow(freshWindows, "winenum_lite")
        WL_EndScan()

        restoredProj := WL_GetDisplayList({ sort: "Z" })
        Log("  After restore + rescan: " restoredProj.items.Length " windows (was " initialCount ")")

        if (restoredProj.items.Length >= afterProj.items.Length) {
            Log("PASS: Blacklist restore + rescan recovered windows")
            TestPassed++
        } else {
            Log("FAIL: Fewer windows after restore than after blacklist (" restoredProj.items.Length " < " afterProj.items.Length ")")
            TestErrors++
        }

        ; === Test 3: Title pattern file I/O ===
        Log("  [BL Test] Testing title blacklist pattern matching...")
        testTitlePattern := "TEST_BL_TITLE_" A_TickCount
        Blacklist_AddTitle(testTitlePattern)

        testContent := ""
        try testContent := FileRead(blFilePath, "UTF-8")

        if (InStr(testContent, testTitlePattern)) {
            Log("PASS: Title pattern added to blacklist file")
            TestPassed++
        } else {
            Log("FAIL: Title pattern not found in blacklist file")
            TestErrors++
        }

        ; === Test 4: Pair pattern file I/O ===
        Log("  [BL Test] Testing pair blacklist pattern matching...")
        testPairClass := "TEST_BL_PAIR_CLASS_" A_TickCount
        testPairTitle := "TEST_BL_PAIR_TITLE_" A_TickCount
        Blacklist_AddPair(testPairClass, testPairTitle)

        testContent := ""
        try testContent := FileRead(blFilePath, "UTF-8")

        expectedPair := testPairClass "|" testPairTitle
        if (InStr(testContent, expectedPair)) {
            Log("PASS: Pair pattern added to blacklist file")
            TestPassed++
        } else {
            Log("FAIL: Pair pattern not found in blacklist file")
            TestErrors++
        }

        ; Final restore
        try {
            FileDelete(blFilePath)
            FileAppend(originalBlacklist, blFilePath, "UTF-8")
        }
        Blacklist_Init(blFilePath)
        Log("  [BL Test] Blacklist file restored to original state")
    }

    ; ============================================================
    ; Stats Accumulation E2E Test (in-process)
    ; ============================================================
    Log("`n--- Stats Accumulation E2E Test ---")

    ; Initialize stats engine (set path to temp file, ensure enabled, then init)
    global STATS_INI_PATH
    origStatsPath := STATS_INI_PATH
    STATS_INI_PATH := A_Temp "\stats_test_" A_TickCount ".ini"
    origStatsEnabled := cfg.StatsTrackingEnabled
    cfg.StatsTrackingEnabled := true
    Stats_Init()

    ; Accumulate known deltas
    statsMsg := Map()
    statsMsg["TotalAltTabs"] := 7
    statsMsg["TotalQuickSwitches"] := 3
    statsMsg["TotalTabSteps"] := 15
    statsMsg["TotalCancellations"] := 2
    Stats_Accumulate(statsMsg)

    ; Get snapshot and verify
    snapshot := Stats_GetSnapshot()

    if (IsObject(snapshot) && snapshot.HasOwnProp("TotalAltTabs")) {
        altTabs := snapshot.TotalAltTabs
        quickSwitches := snapshot.HasOwnProp("TotalQuickSwitches") ? snapshot.TotalQuickSwitches : -1
        tabSteps := snapshot.HasOwnProp("TotalTabSteps") ? snapshot.TotalTabSteps : -1
        cancellations := snapshot.HasOwnProp("TotalCancellations") ? snapshot.TotalCancellations : -1

        if (altTabs >= 7 && quickSwitches >= 3 && tabSteps >= 15 && cancellations >= 2) {
            Log("PASS: Stats accumulated correctly (AT=" altTabs " QS=" quickSwitches " TS=" tabSteps " C=" cancellations ")")
            TestPassed++
        } else {
            Log("FAIL: Stats values too low (AT=" altTabs " QS=" quickSwitches " TS=" tabSteps " C=" cancellations ")")
            TestErrors++
        }

        ; Verify session fields exist
        hasSession := snapshot.HasOwnProp("SessionRunTimeSec") && snapshot.HasOwnProp("SessionPeakWindows")
            && snapshot.HasOwnProp("SessionAltTabs")
        if (hasSession) {
            Log("PASS: Stats snapshot includes session fields")
            TestPassed++
        } else {
            Log("FAIL: Missing session fields in stats snapshot")
            TestErrors++
        }

        ; Verify derived fields exist
        hasDerived := snapshot.HasOwnProp("DerivedQuickSwitchPct") && snapshot.HasOwnProp("DerivedCancelRate")
            && snapshot.HasOwnProp("DerivedAvgTabsPerSwitch")
        if (hasDerived) {
            Log("PASS: Stats snapshot includes derived fields")
            TestPassed++

            ; Verify formula: QuickSwitchPct
            totalActivations := altTabs + quickSwitches
            expectedQuickPct := (totalActivations > 0) ? Round(quickSwitches / totalActivations * 100, 1) : 0
            quickPct := snapshot.DerivedQuickSwitchPct
            if (quickPct = expectedQuickPct) {
                Log("PASS: DerivedQuickSwitchPct = " quickPct " (matches formula)")
                TestPassed++
            } else {
                Log("FAIL: DerivedQuickSwitchPct = " quickPct " (expected " expectedQuickPct ")")
                TestErrors++
            }

            ; Verify formula: CancelRate
            expectedCancelRate := (altTabs + cancellations > 0) ? Round(cancellations / (altTabs + cancellations) * 100, 1) : 0
            cancelRate := snapshot.DerivedCancelRate
            if (cancelRate = expectedCancelRate) {
                Log("PASS: DerivedCancelRate = " cancelRate " (matches formula)")
                TestPassed++
            } else {
                Log("FAIL: DerivedCancelRate = " cancelRate " (expected " expectedCancelRate ")")
                TestErrors++
            }

            ; Verify formula: AvgTabsPerSwitch
            expectedAvgTabs := (altTabs > 0) ? Round(tabSteps / altTabs, 1) : 0
            avgTabsVal := snapshot.DerivedAvgTabsPerSwitch
            if (avgTabsVal = expectedAvgTabs) {
                Log("PASS: DerivedAvgTabsPerSwitch = " avgTabsVal " (matches formula)")
                TestPassed++
            } else {
                Log("FAIL: DerivedAvgTabsPerSwitch = " avgTabsVal " (expected " expectedAvgTabs ")")
                TestErrors++
            }
        } else {
            Log("FAIL: Missing derived fields in stats snapshot")
            TestErrors++
        }
    } else {
        Log("FAIL: Stats_GetSnapshot did not return a valid snapshot object")
        TestErrors++
    }

    ; Cleanup test stats file and restore original path + setting
    try FileDelete(STATS_INI_PATH)
    try FileDelete(STATS_INI_PATH ".bak")
    STATS_INI_PATH := origStatsPath
    cfg.StatsTrackingEnabled := origStatsEnabled
}
