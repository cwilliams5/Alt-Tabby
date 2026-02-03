; Unit Tests - Stats Engine
; Stats accumulation, flush/load round-trip, crash recovery, derived stats
; Included by test_unit.ahk
#Include test_utils.ahk

RunUnitTests_Stats() {
    global TestPassed, TestErrors, cfg
    global gStats_Lifetime, gStats_Session, STATS_LIFETIME_KEYS, STATS_INI_PATH

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
        updateKeys := ["TotalAltTabs", "TotalQuickSwitches", "TotalTabSteps",
                       "TotalCancellations", "TotalCrossWorkspace", "TotalWorkspaceToggles"]
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
    ; Derived Stats Computation Tests
    ; ============================================================
    Log("`n--- Derived Stats Tests ---")

    ; Test 4a: Avg Alt-Tabs per hour
    Log("Testing derived stats computation...")
    try {
        ; 3600 seconds = 1 hour, 100 alt-tabs → 100/hr
        totalRunSec := 3600
        totalAltTabs := 100
        avgPerHour := Round(totalAltTabs / (totalRunSec / 3600), 1)
        if (avgPerHour = 100.0) {
            Log("PASS: Avg Alt-Tabs/hr = " avgPerHour " (100 in 1hr)")
            TestPassed++
        } else {
            Log("FAIL: Expected 100.0, got " avgPerHour)
            TestErrors++
        }
    } catch as e {
        Log("FAIL: Derived stats (avg/hr) error: " e.Message)
        TestErrors++
    }

    ; Test 4b: Quick switch percentage
    Log("Testing quick switch percentage...")
    try {
        totalAltTabs := 80
        totalQuick := 20
        totalActivations := totalAltTabs + totalQuick
        pct := Round(totalQuick / totalActivations * 100, 1)
        if (pct = 20.0) {
            Log("PASS: Quick switch rate = " pct "% (20 of 100)")
            TestPassed++
        } else {
            Log("FAIL: Expected 20.0%, got " pct)
            TestErrors++
        }
    } catch as e {
        Log("FAIL: Derived stats (quick%) error: " e.Message)
        TestErrors++
    }

    ; Test 4c: Division by zero returns 0
    Log("Testing derived stats with zero values...")
    try {
        ; All zero → should produce 0, not error
        totalRunSec := 0
        totalAltTabs := 0
        totalQuick := 0
        totalCancels := 0
        totalTabs := 0
        totalActivations := totalAltTabs + totalQuick

        avgPerHour := (totalRunSec > 0) ? Round(totalAltTabs / (totalRunSec / 3600), 1) : 0
        quickPct := (totalActivations > 0) ? Round(totalQuick / totalActivations * 100, 1) : 0
        cancelRate := (totalAltTabs + totalCancels > 0) ? Round(totalCancels / (totalAltTabs + totalCancels) * 100, 1) : 0
        avgTabs := (totalAltTabs > 0) ? Round(totalTabs / totalAltTabs, 1) : 0

        if (avgPerHour = 0 && quickPct = 0 && cancelRate = 0 && avgTabs = 0) {
            Log("PASS: All derived stats = 0 with zero inputs (no division by zero)")
            TestPassed++
        } else {
            Log("FAIL: Expected all 0, got avg=" avgPerHour " quick=" quickPct " cancel=" cancelRate " tabs=" avgTabs)
            TestErrors++
        }
    } catch as e {
        Log("FAIL: Derived stats (zero) error: " e.Message)
        TestErrors++
    }

    ; Test 4d: Cancel rate computation
    Log("Testing cancel rate computation...")
    try {
        totalAltTabs := 90
        totalCancels := 10
        cancelRate := Round(totalCancels / (totalAltTabs + totalCancels) * 100, 1)
        if (cancelRate = 10.0) {
            Log("PASS: Cancel rate = " cancelRate "% (10 of 100)")
            TestPassed++
        } else {
            Log("FAIL: Expected 10.0%, got " cancelRate)
            TestErrors++
        }
    } catch as e {
        Log("FAIL: Derived stats (cancel%) error: " e.Message)
        TestErrors++
    }

    ; Test 4e: Session baseline delta computation
    Log("Testing session baseline deltas...")
    try {
        ; Simulate: baseline was 100, current is 125 → session = 25
        gStats_Lifetime := Map()
        gStats_Lifetime["TotalAltTabs"] := 125
        gStats_Session := Map()
        gStats_Session["baselineAltTabs"] := 100

        sessionDelta := gStats_Lifetime.Get("TotalAltTabs", 0) - gStats_Session.Get("baselineAltTabs", 0)
        if (sessionDelta = 25) {
            Log("PASS: Session delta = 25 (125 - 100)")
            TestPassed++
        } else {
            Log("FAIL: Expected session delta 25, got " sessionDelta)
            TestErrors++
        }
    } catch as e {
        Log("FAIL: Session baseline delta error: " e.Message)
        TestErrors++
    }

    ; ============================================================
    ; Duration Format Tests
    ; ============================================================
    Log("`n--- Duration Format Tests ---")

    ; Test seconds
    try {
        if (_Stats_FormatDuration(45) = "45s") {
            Log("PASS: FormatDuration(45) = 45s")
            TestPassed++
        } else {
            Log("FAIL: FormatDuration(45) = " _Stats_FormatDuration(45) " (expected 45s)")
            TestErrors++
        }
    } catch as e {
        Log("FAIL: FormatDuration seconds error: " e.Message)
        TestErrors++
    }

    ; Test minutes
    try {
        if (_Stats_FormatDuration(720) = "12m") {
            Log("PASS: FormatDuration(720) = 12m")
            TestPassed++
        } else {
            Log("FAIL: FormatDuration(720) = " _Stats_FormatDuration(720) " (expected 12m)")
            TestErrors++
        }
    } catch as e {
        Log("FAIL: FormatDuration minutes error: " e.Message)
        TestErrors++
    }

    ; Test hours + minutes
    try {
        if (_Stats_FormatDuration(8100) = "2h 15m") {
            Log("PASS: FormatDuration(8100) = 2h 15m")
            TestPassed++
        } else {
            Log("FAIL: FormatDuration(8100) = " _Stats_FormatDuration(8100) " (expected 2h 15m)")
            TestErrors++
        }
    } catch as e {
        Log("FAIL: FormatDuration hours error: " e.Message)
        TestErrors++
    }

    ; Test days + hours
    try {
        result := _Stats_FormatDuration(273600)  ; 3d 4h = 3*86400 + 4*3600
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
        result := _Stats_FormatDuration(86400 * 400)
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
        result := _Stats_FormatDuration(86400 * 365)
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
        if (_Stats_FormatDuration(0) = "0s") {
            Log("PASS: FormatDuration(0) = 0s")
            TestPassed++
        } else {
            Log("FAIL: FormatDuration(0) = " _Stats_FormatDuration(0) " (expected 0s)")
            TestErrors++
        }
    } catch as e {
        Log("FAIL: FormatDuration zero error: " e.Message)
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
