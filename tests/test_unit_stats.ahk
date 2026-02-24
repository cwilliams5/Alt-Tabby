; Unit Tests - Stats Engine
; Stats accumulation, flush/load round-trip, crash recovery, derived stats
; Included by test_unit.ahk
#Include test_utils.ahk

RunUnitTests_Stats() {
    global TestPassed, TestErrors, cfg
    global gStats_Lifetime, gStats_Session, STATS_LIFETIME_KEYS, STATS_CUMULATIVE_KEYS, STATS_INI_PATH

    ; ============================================================
    ; Stats Accumulation Tests
    ; ============================================================
    Log("`n--- Stats Accumulation Tests ---")

    ; Save original state
    origLifetime := Map()
    for k, v in gStats_Lifetime
        origLifetime[k] := v
    origSession := Map()
    for k, v in gStats_Session
        origSession[k] := v
    origPath := STATS_INI_PATH
    origEnabled := cfg.StatsTrackingEnabled

    ; Test 1: stats_update accumulates into lifetime
    Log("Testing stats_update accumulation...")
    try {
        cfg.StatsTrackingEnabled := true
        gStats_Lifetime := Map()
        for _, key in STATS_LIFETIME_KEYS
            gStats_Lifetime[key] := 0

        ; Simulate receiving a stats_update (same keys as Store_OnMessage handler)
        updateKeys := STATS_CUMULATIVE_KEYS
        for _, key in updateKeys
            gStats_Lifetime[key] := gStats_Lifetime.Get(key, 0) + 5

        allFive := true
        for _, key in updateKeys {
            if (gStats_Lifetime[key] != 5)
                allFive := false
        }
        if (allFive) {
            Log("PASS: stats_update accumulated 5 into each counter")
            TestPassed++
        } else {
            Log("FAIL: Expected all counters to be 5 after accumulation")
            TestErrors++
        }

        ; Second update should add to existing
        for _, key in updateKeys
            gStats_Lifetime[key] := gStats_Lifetime.Get(key, 0) + 3

        allEight := true
        for _, key in updateKeys {
            if (gStats_Lifetime[key] != 8)
                allEight := false
        }
        if (allEight) {
            Log("PASS: Second stats_update accumulated correctly (5+3=8)")
            TestPassed++
        } else {
            Log("FAIL: Expected 8 after two accumulations")
            TestErrors++
        }
    } catch as e {
        Log("FAIL: Stats accumulation error: " e.Message)
        TestErrors++
    }

    ; ============================================================
    ; Stats Flush/Load Round-Trip Tests
    ; ============================================================
    Log("`n--- Stats Flush/Load Round-Trip Tests ---")

    testStatsPath := A_Temp "\test_stats_roundtrip.ini"
    testStatsBak := testStatsPath ".bak"

    ; Clean up any previous test files
    try FileDelete(testStatsPath)
    try FileDelete(testStatsBak)

    ; Test 2: Write and read back
    Log("Testing Stats flush/load round-trip...")
    try {
        cfg.StatsTrackingEnabled := true
        STATS_INI_PATH := testStatsPath

        ; Set up known values
        gStats_Lifetime := Map()
        for _, key in STATS_LIFETIME_KEYS
            gStats_Lifetime[key] := 0
        gStats_Lifetime["TotalAltTabs"] := 42
        gStats_Lifetime["TotalQuickSwitches"] := 15
        gStats_Lifetime["TotalSessions"] := 7
        gStats_Lifetime["TotalRunTimeSec"] := 3600
        gStats_Lifetime["PeakWindowsInSession"] := 20
        gStats_Lifetime["LongestSessionSec"] := 1800
        gStats_Lifetime["TotalTabSteps"] := 100
        gStats_Lifetime["TotalCancellations"] := 5

        ; Set session start to now (so flush adds ~0s runtime)
        gStats_Session := Map()
        gStats_Session["startTick"] := A_TickCount
        gStats_Session["peakWindows"] := 0

        ; Mark dirty so flush proceeds (dirty flag gates no-op writes)
        global gStats_Dirty
        gStats_Dirty := true

        ; Flush to disk
        Stats_FlushToDisk()

        if (!FileExist(testStatsPath)) {
            Log("FAIL: Stats file not created after flush")
            TestErrors++
        } else {
            ; Verify sentinel exists
            flushStatus := IniRead(testStatsPath, "Lifetime", "_FlushStatus", "")
            if (flushStatus != "complete") {
                Log("FAIL: Flush sentinel not written (got '" flushStatus "')")
                TestErrors++
            } else {
                ; Now load it back
                gStats_Lifetime := Map()
                gStats_Session := Map()
                gStats_Session["startTick"] := A_TickCount
                gStats_Session["peakWindows"] := 0
                Stats_Init()

                if (gStats_Lifetime.Get("TotalAltTabs", 0) = 42
                    && gStats_Lifetime.Get("TotalQuickSwitches", 0) = 15
                    && gStats_Lifetime.Get("TotalSessions", 0) = 8  ; +1 for the load session
                    && gStats_Lifetime.Get("TotalTabSteps", 0) = 100
                    && gStats_Lifetime.Get("TotalCancellations", 0) = 5
                    && gStats_Lifetime.Get("PeakWindowsInSession", 0) = 20
                    && gStats_Lifetime.Get("LongestSessionSec", 0) = 1800) {
                    Log("PASS: Stats round-trip preserves all values (sessions incremented to 8)")
                    TestPassed++
                } else {
                    Log("FAIL: Round-trip mismatch: AltTabs=" gStats_Lifetime.Get("TotalAltTabs", 0)
                        " Quick=" gStats_Lifetime.Get("TotalQuickSwitches", 0)
                        " Sessions=" gStats_Lifetime.Get("TotalSessions", 0)
                        " Tabs=" gStats_Lifetime.Get("TotalTabSteps", 0)
                        " Cancels=" gStats_Lifetime.Get("TotalCancellations", 0))
                    TestErrors++
                }
            }
        }
    } catch as e {
        Log("FAIL: Stats flush/load error: " e.Message)
        TestErrors++
    }

    ; Clean up
    try FileDelete(testStatsPath)
    try FileDelete(testStatsBak)

    ; ============================================================
    ; Crash Recovery Tests
    ; ============================================================
    Log("`n--- Stats Crash Recovery Tests ---")

    ; Test 3a: .bak only (crash before any write) → recover from .bak
    Log("Testing crash recovery: .bak only...")
    try {
        cfg.StatsTrackingEnabled := true
        STATS_INI_PATH := testStatsPath

        ; Create a .bak file with known values (simulates crash before write)
        try FileDelete(testStatsPath)
        try FileDelete(testStatsBak)
        IniWrite(99, testStatsBak, "Lifetime", "TotalAltTabs")
        IniWrite(3, testStatsBak, "Lifetime", "TotalSessions")
        IniWrite("complete", testStatsBak, "Lifetime", "_FlushStatus")

        ; No .ini file — Stats_Init should recover from .bak
        gStats_Lifetime := Map()
        gStats_Session := Map()
        gStats_Session["startTick"] := A_TickCount
        Stats_Init()

        if (gStats_Lifetime.Get("TotalAltTabs", 0) = 99
            && gStats_Lifetime.Get("TotalSessions", 0) = 4) {  ; +1 for load
            Log("PASS: Recovered from .bak (AltTabs=99, Sessions=3+1=4)")
            TestPassed++
        } else {
            Log("FAIL: Recovery mismatch: AltTabs=" gStats_Lifetime.Get("TotalAltTabs", 0)
                " Sessions=" gStats_Lifetime.Get("TotalSessions", 0))
            TestErrors++
        }

        ; .bak should be gone (moved to .ini)
        if (!FileExist(testStatsBak)) {
            Log("PASS: .bak file cleaned up after recovery")
            TestPassed++
        } else {
            Log("FAIL: .bak file still exists after recovery")
            TestErrors++
        }
    } catch as e {
        Log("FAIL: Crash recovery (.bak only) error: " e.Message)
        TestErrors++
    }

    ; Clean up
    try FileDelete(testStatsPath)
    try FileDelete(testStatsBak)

    ; Test 3b: Both .ini and .bak exist, .ini has sentinel → discard .bak
    Log("Testing crash recovery: both files, .ini complete...")
    try {
        cfg.StatsTrackingEnabled := true
        STATS_INI_PATH := testStatsPath

        try FileDelete(testStatsPath)
        try FileDelete(testStatsBak)

        ; Create complete .ini with newer data
        IniWrite(200, testStatsPath, "Lifetime", "TotalAltTabs")
        IniWrite(10, testStatsPath, "Lifetime", "TotalSessions")
        IniWrite("complete", testStatsPath, "Lifetime", "_FlushStatus")

        ; Create older .bak
        IniWrite(150, testStatsBak, "Lifetime", "TotalAltTabs")
        IniWrite(8, testStatsBak, "Lifetime", "TotalSessions")
        IniWrite("complete", testStatsBak, "Lifetime", "_FlushStatus")

        gStats_Lifetime := Map()
        gStats_Session := Map()
        gStats_Session["startTick"] := A_TickCount
        Stats_Init()

        if (gStats_Lifetime.Get("TotalAltTabs", 0) = 200) {
            Log("PASS: Used .ini (complete), discarded .bak (AltTabs=200)")
            TestPassed++
        } else {
            Log("FAIL: Expected AltTabs=200 from .ini, got " gStats_Lifetime.Get("TotalAltTabs", 0))
            TestErrors++
        }

        if (!FileExist(testStatsBak)) {
            Log("PASS: .bak discarded when .ini is complete")
            TestPassed++
        } else {
            Log("FAIL: .bak should be discarded when .ini has sentinel")
            TestErrors++
        }
    } catch as e {
        Log("FAIL: Crash recovery (both files) error: " e.Message)
        TestErrors++
    }

    ; Clean up
    try FileDelete(testStatsPath)
    try FileDelete(testStatsBak)

    ; Test 3c: Both files, .ini partial (no sentinel) → use .bak
    Log("Testing crash recovery: both files, .ini partial...")
    try {
        cfg.StatsTrackingEnabled := true
        STATS_INI_PATH := testStatsPath

        try FileDelete(testStatsPath)
        try FileDelete(testStatsBak)

        ; Create partial .ini (no sentinel - crash mid-write)
        IniWrite(300, testStatsPath, "Lifetime", "TotalAltTabs")
        ; No _FlushStatus = crash during write

        ; Create complete .bak (last known good)
        IniWrite(250, testStatsBak, "Lifetime", "TotalAltTabs")
        IniWrite(12, testStatsBak, "Lifetime", "TotalSessions")
        IniWrite("complete", testStatsBak, "Lifetime", "_FlushStatus")

        gStats_Lifetime := Map()
        gStats_Session := Map()
        gStats_Session["startTick"] := A_TickCount
        Stats_Init()

        if (gStats_Lifetime.Get("TotalAltTabs", 0) = 250) {
            Log("PASS: Fell back to .bak when .ini is partial (AltTabs=250)")
            TestPassed++
        } else {
            Log("FAIL: Expected AltTabs=250 from .bak, got " gStats_Lifetime.Get("TotalAltTabs", 0))
            TestErrors++
        }
    } catch as e {
        Log("FAIL: Crash recovery (partial .ini) error: " e.Message)
        TestErrors++
    }

    ; Clean up
    try FileDelete(testStatsPath)
    try FileDelete(testStatsBak)

    ; ============================================================
    ; Dirty Flag & State Gate Tests
    ; ============================================================
    Log("`n--- Stats Dirty Flag & State Gate Tests ---")

    ; Test: FlushToDisk skips when dirty flag is false
    Log("Testing FlushToDisk: skips when not dirty...")
    try {
        cfg.StatsTrackingEnabled := true
        testStatsPath2 := A_Temp "\test_stats_dirty.ini"
        STATS_INI_PATH := testStatsPath2
        try FileDelete(testStatsPath2)

        gStats_Lifetime := Map()
        for _, key in STATS_LIFETIME_KEYS
            gStats_Lifetime[key] := 0
        gStats_Lifetime["TotalAltTabs"] := 99
        gStats_Session := Map()
        gStats_Session["startTick"] := A_TickCount
        gStats_Session["sessionStartTick"] := A_TickCount

        gStats_Dirty := false
        Stats_FlushToDisk()

        if (!FileExist(testStatsPath2)) {
            Log("PASS: FlushToDisk skipped when dirty=false (no file created)")
            TestPassed++
        } else {
            Log("FAIL: FlushToDisk should not write when dirty=false")
            TestErrors++
        }
        try FileDelete(testStatsPath2)
    } catch as e {
        Log("FAIL: Dirty flag skip test error: " e.Message)
        TestErrors++
    }

    ; Test: FlushToDisk defers during ACTIVE state
    Log("Testing FlushToDisk: defers during ACTIVE state...")
    try {
        global gGUI_State
        cfg.StatsTrackingEnabled := true
        STATS_INI_PATH := testStatsPath2
        try FileDelete(testStatsPath2)

        gStats_Lifetime := Map()
        for _, key in STATS_LIFETIME_KEYS
            gStats_Lifetime[key] := 0
        gStats_Lifetime["TotalAltTabs"] := 99
        gStats_Session := Map()
        gStats_Session["startTick"] := A_TickCount
        gStats_Session["sessionStartTick"] := A_TickCount

        gStats_Dirty := true
        gGUI_State := "ACTIVE"
        Stats_FlushToDisk()

        if (!FileExist(testStatsPath2)) {
            Log("PASS: FlushToDisk deferred during ACTIVE state")
            TestPassed++
        } else {
            Log("FAIL: FlushToDisk should not write during ACTIVE state")
            TestErrors++
        }
        ; Dirty flag should remain true (deferred, not skipped)
        if (gStats_Dirty) {
            Log("PASS: Dirty flag preserved after deferral")
            TestPassed++
        } else {
            Log("FAIL: Dirty flag was cleared despite deferral")
            TestErrors++
        }
        gGUI_State := "IDLE"
        try FileDelete(testStatsPath2)
    } catch as e {
        gGUI_State := "IDLE"
        Log("FAIL: State gate test error: " e.Message)
        TestErrors++
    }

    ; Test: ForceFlushToDisk bypasses dirty flag and state gate
    Log("Testing ForceFlushToDisk: bypasses dirty flag and state gate...")
    try {
        cfg.StatsTrackingEnabled := true
        STATS_INI_PATH := testStatsPath2
        try FileDelete(testStatsPath2)

        gStats_Lifetime := Map()
        for _, key in STATS_LIFETIME_KEYS
            gStats_Lifetime[key] := 0
        gStats_Lifetime["TotalAltTabs"] := 77
        gStats_Lifetime["TotalSessions"] := 3
        gStats_Session := Map()
        gStats_Session["startTick"] := A_TickCount
        gStats_Session["sessionStartTick"] := A_TickCount

        gStats_Dirty := false  ; Dirty flag off
        gGUI_State := "ACTIVE" ; Active state
        Stats_ForceFlushToDisk()
        gGUI_State := "IDLE"

        if (FileExist(testStatsPath2)) {
            ; Verify content readable by IniRead
            val := IniRead(testStatsPath2, "Lifetime", "TotalAltTabs", "0")
            sentinel := IniRead(testStatsPath2, "Lifetime", "_FlushStatus", "")
            if (Integer(val) = 77 && sentinel = "complete") {
                Log("PASS: ForceFlushToDisk wrote correctly (AltTabs=77, sentinel=complete)")
                TestPassed++
            } else {
                Log("FAIL: ForceFlushToDisk content wrong: AltTabs=" val " sentinel=" sentinel)
                TestErrors++
            }
        } else {
            Log("FAIL: ForceFlushToDisk did not create file")
            TestErrors++
        }
        try FileDelete(testStatsPath2)
    } catch as e {
        gGUI_State := "IDLE"
        Log("FAIL: ForceFlushToDisk bypass test error: " e.Message)
        TestErrors++
    }

    ; Reset STATS_INI_PATH for remaining tests
    STATS_INI_PATH := testStatsPath

    ; ============================================================
    ; Duration Format Tests
    ; ============================================================
    Log("`n--- Duration Format Tests ---")

    ; Test seconds
    try {
        if (Stats_FormatDuration(45) = "45s") {
            Log("PASS: FormatDuration(45) = 45s")
            TestPassed++
        } else {
            Log("FAIL: FormatDuration(45) = " Stats_FormatDuration(45) " (expected 45s)")
            TestErrors++
        }
    } catch as e {
        Log("FAIL: FormatDuration seconds error: " e.Message)
        TestErrors++
    }

    ; Test minutes
    try {
        if (Stats_FormatDuration(720) = "12m") {
            Log("PASS: FormatDuration(720) = 12m")
            TestPassed++
        } else {
            Log("FAIL: FormatDuration(720) = " Stats_FormatDuration(720) " (expected 12m)")
            TestErrors++
        }
    } catch as e {
        Log("FAIL: FormatDuration minutes error: " e.Message)
        TestErrors++
    }

    ; Test hours + minutes
    try {
        if (Stats_FormatDuration(8100) = "2h 15m") {
            Log("PASS: FormatDuration(8100) = 2h 15m")
            TestPassed++
        } else {
            Log("FAIL: FormatDuration(8100) = " Stats_FormatDuration(8100) " (expected 2h 15m)")
            TestErrors++
        }
    } catch as e {
        Log("FAIL: FormatDuration hours error: " e.Message)
        TestErrors++
    }

    ; Test days + hours
    try {
        result := Stats_FormatDuration(273600)  ; 3d 4h = 3*86400 + 4*3600
        if (result = "3d 4h") {
            Log("PASS: FormatDuration(273600) = 3d 4h")
            TestPassed++
        } else {
            Log("FAIL: FormatDuration(273600) = " result " (expected 3d 4h)")
            TestErrors++
        }
    } catch as e {
        Log("FAIL: FormatDuration days error: " e.Message)
        TestErrors++
    }

    ; Test year tier: 400 days = 1y 35d
    try {
        result := Stats_FormatDuration(86400 * 400)
        if (result = "1y 35d") {
            Log("PASS: FormatDuration(400 days) = 1y 35d")
            TestPassed++
        } else {
            Log("FAIL: FormatDuration(400 days) = " result " (expected 1y 35d)")
            TestErrors++
        }
    } catch as e {
        Log("FAIL: FormatDuration years error: " e.Message)
        TestErrors++
    }

    ; Test exact year: 365 days = 1y
    try {
        result := Stats_FormatDuration(86400 * 365)
        if (result = "1y") {
            Log("PASS: FormatDuration(365 days) = 1y")
            TestPassed++
        } else {
            Log("FAIL: FormatDuration(365 days) = " result " (expected 1y)")
            TestErrors++
        }
    } catch as e {
        Log("FAIL: FormatDuration exact year error: " e.Message)
        TestErrors++
    }

    ; Test zero
    try {
        if (Stats_FormatDuration(0) = "0s") {
            Log("PASS: FormatDuration(0) = 0s")
            TestPassed++
        } else {
            Log("FAIL: FormatDuration(0) = " Stats_FormatDuration(0) " (expected 0s)")
            TestErrors++
        }
    } catch as e {
        Log("FAIL: FormatDuration zero error: " e.Message)
        TestErrors++
    }

    ; ============================================================
    ; Stats_BumpLifetimeStat Tests
    ; ============================================================
    Log("`n--- Stats_BumpLifetimeStat Tests ---")

    ; Test: BumpLifetimeStat increments existing key
    Log("Testing BumpLifetimeStat: increment existing key...")
    try {
        gStats_Lifetime := Map()
        for _, key in STATS_LIFETIME_KEYS
            gStats_Lifetime[key] := 0
        gStats_Lifetime["TotalAltTabs"] := 10

        Stats_BumpLifetimeStat("TotalAltTabs")

        if (gStats_Lifetime["TotalAltTabs"] = 11) {
            Log("PASS: BumpLifetimeStat increments TotalAltTabs from 10 to 11")
            TestPassed++
        } else {
            Log("FAIL: Expected 11, got " gStats_Lifetime["TotalAltTabs"])
            TestErrors++
        }
    } catch as e {
        Log("FAIL: BumpLifetimeStat increment error: " e.Message)
        TestErrors++
    }

    ; Test: BumpLifetimeStat with non-existent key is no-op (no crash)
    Log("Testing BumpLifetimeStat: non-existent key is no-op...")
    try {
        gStats_Lifetime := Map()
        for _, key in STATS_LIFETIME_KEYS
            gStats_Lifetime[key] := 0
        prevCount := gStats_Lifetime.Count

        Stats_BumpLifetimeStat("NonExistentKey")

        if (gStats_Lifetime.Count = prevCount && !gStats_Lifetime.Has("NonExistentKey")) {
            Log("PASS: BumpLifetimeStat no-op for non-existent key")
            TestPassed++
        } else {
            Log("FAIL: BumpLifetimeStat created unexpected key")
            TestErrors++
        }
    } catch as e {
        Log("FAIL: BumpLifetimeStat non-existent key error: " e.Message)
        TestErrors++
    }

    ; ============================================================
    ; Stats_UpdatePeakWindows Tests
    ; ============================================================
    Log("`n--- Stats_UpdatePeakWindows Tests ---")

    ; Test: UpdatePeakWindows sets new session peak
    Log("Testing UpdatePeakWindows: new session peak...")
    try {
        gStats_Session := Map()
        gStats_Session["peakWindows"] := 5
        gStats_Session["startTick"] := A_TickCount
        gStats_Lifetime := Map()
        for _, key in STATS_LIFETIME_KEYS
            gStats_Lifetime[key] := 0
        gStats_Lifetime["PeakWindowsInSession"] := 20  ; Lifetime peak higher

        Stats_UpdatePeakWindows(10)

        if (gStats_Session["peakWindows"] = 10) {
            Log("PASS: Session peak updated from 5 to 10")
            TestPassed++
        } else {
            Log("FAIL: Expected session peak 10, got " gStats_Session["peakWindows"])
            TestErrors++
        }
        ; Lifetime should NOT change (10 < 20)
        if (gStats_Lifetime["PeakWindowsInSession"] = 20) {
            Log("PASS: Lifetime peak unchanged (10 < 20)")
            TestPassed++
        } else {
            Log("FAIL: Expected lifetime peak 20, got " gStats_Lifetime["PeakWindowsInSession"])
            TestErrors++
        }
    } catch as e {
        Log("FAIL: UpdatePeakWindows session peak error: " e.Message)
        TestErrors++
    }

    ; Test: UpdatePeakWindows sets both session AND lifetime peak
    Log("Testing UpdatePeakWindows: new lifetime peak...")
    try {
        gStats_Session := Map()
        gStats_Session["peakWindows"] := 5
        gStats_Session["startTick"] := A_TickCount
        gStats_Lifetime := Map()
        for _, key in STATS_LIFETIME_KEYS
            gStats_Lifetime[key] := 0
        gStats_Lifetime["PeakWindowsInSession"] := 8

        Stats_UpdatePeakWindows(15)

        if (gStats_Session["peakWindows"] = 15 && gStats_Lifetime["PeakWindowsInSession"] = 15) {
            Log("PASS: Both session and lifetime peak updated to 15")
            TestPassed++
        } else {
            Log("FAIL: Session=" gStats_Session["peakWindows"] " Lifetime=" gStats_Lifetime["PeakWindowsInSession"] " (expected both 15)")
            TestErrors++
        }
    } catch as e {
        Log("FAIL: UpdatePeakWindows lifetime peak error: " e.Message)
        TestErrors++
    }

    ; Test: UpdatePeakWindows below current peak is no-op
    Log("Testing UpdatePeakWindows: below session peak is no-op...")
    try {
        gStats_Session := Map()
        gStats_Session["peakWindows"] := 20
        gStats_Session["startTick"] := A_TickCount
        gStats_Lifetime := Map()
        for _, key in STATS_LIFETIME_KEYS
            gStats_Lifetime[key] := 0
        gStats_Lifetime["PeakWindowsInSession"] := 25

        Stats_UpdatePeakWindows(10)

        if (gStats_Session["peakWindows"] = 20 && gStats_Lifetime["PeakWindowsInSession"] = 25) {
            Log("PASS: Peaks unchanged when count below current (session=20, lifetime=25)")
            TestPassed++
        } else {
            Log("FAIL: Session=" gStats_Session["peakWindows"] " Lifetime=" gStats_Lifetime["PeakWindowsInSession"])
            TestErrors++
        }
    } catch as e {
        Log("FAIL: UpdatePeakWindows below peak error: " e.Message)
        TestErrors++
    }

    ; ============================================================
    ; Stats_GetSnapshot Derived Calculation Tests
    ; ============================================================
    Log("`n--- Stats_GetSnapshot Derived Calculation Tests ---")

    ; Test: Session delta calculation (lifetime - baseline)
    Log("Testing GetSnapshot: session delta calculation...")
    try {
        cfg.StatsTrackingEnabled := true
        gStats_Lifetime := Map()
        for _, key in STATS_LIFETIME_KEYS
            gStats_Lifetime[key] := 0
        gStats_Lifetime["TotalAltTabs"] := 100
        gStats_Lifetime["TotalQuickSwitches"] := 30
        gStats_Lifetime["TotalTabSteps"] := 250
        gStats_Lifetime["TotalCancellations"] := 10
        gStats_Lifetime["TotalCrossWorkspace"] := 5
        gStats_Lifetime["TotalWorkspaceToggles"] := 8
        gStats_Lifetime["TotalWindowUpdates"] := 50
        gStats_Lifetime["TotalBlacklistSkips"] := 20

        gStats_Session := Map()
        gStats_Session["sessionStartTick"] := A_TickCount
        gStats_Session["startTick"] := A_TickCount
        gStats_Session["peakWindows"] := 12
        ; Baselines: simulate starting with some lifetime stats already
        gStats_Session["baselineAltTabs"] := 60
        gStats_Session["baselineQuickSwitches"] := 20
        gStats_Session["baselineTabSteps"] := 150
        gStats_Session["baselineCancellations"] := 5
        gStats_Session["baselineCrossWorkspace"] := 2
        gStats_Session["baselineWorkspaceToggles"] := 3
        gStats_Session["baselineWindowUpdates"] := 30
        gStats_Session["baselineBlacklistSkips"] := 10

        snap := Stats_GetSnapshot()

        ; Session deltas = lifetime - baseline
        deltaOk := (snap.SessionAltTabs = 40
            && snap.SessionQuickSwitches = 10
            && snap.SessionTabSteps = 100
            && snap.SessionCancellations = 5
            && snap.SessionCrossWorkspace = 3
            && snap.SessionWorkspaceToggles = 5
            && snap.SessionWindowUpdates = 20
            && snap.SessionBlacklistSkips = 10)

        if (deltaOk) {
            Log("PASS: Session deltas correct (lifetime - baseline)")
            TestPassed++
        } else {
            Log("FAIL: Session deltas: AltTabs=" snap.SessionAltTabs " Quick=" snap.SessionQuickSwitches
                " Tabs=" snap.SessionTabSteps " Cancels=" snap.SessionCancellations)
            TestErrors++
        }

        ; SessionPeakWindows should match session peak
        if (snap.SessionPeakWindows = 12) {
            Log("PASS: SessionPeakWindows = 12")
            TestPassed++
        } else {
            Log("FAIL: SessionPeakWindows = " snap.SessionPeakWindows " (expected 12)")
            TestErrors++
        }
    } catch as e {
        Log("FAIL: GetSnapshot session delta error: " e.Message)
        TestErrors++
    }

    ; Test: Derived AvgAltTabsPerHour
    Log("Testing GetSnapshot: derived AvgAltTabsPerHour...")
    try {
        gStats_Lifetime := Map()
        for _, key in STATS_LIFETIME_KEYS
            gStats_Lifetime[key] := 0
        gStats_Lifetime["TotalAltTabs"] := 360
        gStats_Lifetime["TotalRunTimeSec"] := 3600  ; 1 hour

        gStats_Session := Map()
        gStats_Session["sessionStartTick"] := A_TickCount  ; ~0 seconds session
        gStats_Session["startTick"] := A_TickCount
        gStats_Session["peakWindows"] := 0

        snap := Stats_GetSnapshot()

        ; AvgAltTabsPerHour = 360 / ((3600 + ~0) / 3600) ≈ 360.0
        ; With ~0s session time, totalRunSec ≈ 3600
        if (snap.DerivedAvgAltTabsPerHour >= 359 && snap.DerivedAvgAltTabsPerHour <= 361) {
            Log("PASS: AvgAltTabsPerHour ≈ 360 (got " snap.DerivedAvgAltTabsPerHour ")")
            TestPassed++
        } else {
            Log("FAIL: AvgAltTabsPerHour = " snap.DerivedAvgAltTabsPerHour " (expected ~360)")
            TestErrors++
        }
    } catch as e {
        Log("FAIL: GetSnapshot AvgAltTabsPerHour error: " e.Message)
        TestErrors++
    }

    ; Test: Derived QuickSwitchPct
    Log("Testing GetSnapshot: derived QuickSwitchPct...")
    try {
        gStats_Lifetime := Map()
        for _, key in STATS_LIFETIME_KEYS
            gStats_Lifetime[key] := 0
        gStats_Lifetime["TotalAltTabs"] := 80
        gStats_Lifetime["TotalQuickSwitches"] := 20

        gStats_Session := Map()
        gStats_Session["sessionStartTick"] := A_TickCount
        gStats_Session["startTick"] := A_TickCount
        gStats_Session["peakWindows"] := 0

        snap := Stats_GetSnapshot()

        ; QuickSwitchPct = 20 / (80 + 20) * 100 = 20.0
        if (snap.DerivedQuickSwitchPct = 20.0) {
            Log("PASS: QuickSwitchPct = 20.0")
            TestPassed++
        } else {
            Log("FAIL: QuickSwitchPct = " snap.DerivedQuickSwitchPct " (expected 20.0)")
            TestErrors++
        }
    } catch as e {
        Log("FAIL: GetSnapshot QuickSwitchPct error: " e.Message)
        TestErrors++
    }

    ; Test: Derived stats with zero divisors (no crash, returns 0)
    Log("Testing GetSnapshot: derived stats with zero divisors...")
    try {
        gStats_Lifetime := Map()
        for _, key in STATS_LIFETIME_KEYS
            gStats_Lifetime[key] := 0
        ; Everything is zero — all derived stats should be 0

        gStats_Session := Map()
        gStats_Session["sessionStartTick"] := A_TickCount
        gStats_Session["startTick"] := A_TickCount
        gStats_Session["peakWindows"] := 0

        snap := Stats_GetSnapshot()

        allZero := (snap.DerivedAvgAltTabsPerHour = 0
            && snap.DerivedQuickSwitchPct = 0
            && snap.DerivedCancelRate = 0
            && snap.DerivedAvgTabsPerSwitch = 0)

        if (allZero) {
            Log("PASS: All derived stats = 0 with zero divisors")
            TestPassed++
        } else {
            Log("FAIL: Derived with zeros: AvgHour=" snap.DerivedAvgAltTabsPerHour
                " QuickPct=" snap.DerivedQuickSwitchPct
                " CancelRate=" snap.DerivedCancelRate
                " AvgTabs=" snap.DerivedAvgTabsPerSwitch)
            TestErrors++
        }
    } catch as e {
        Log("FAIL: GetSnapshot zero divisors error: " e.Message)
        TestErrors++
    }

    ; ============================================================
    ; Restore original state
    ; ============================================================
    gStats_Lifetime := origLifetime
    gStats_Session := origSession
    STATS_INI_PATH := origPath
    cfg.StatsTrackingEnabled := origEnabled

    ; Final cleanup
    try FileDelete(testStatsPath)
    try FileDelete(testStatsBak)
}
