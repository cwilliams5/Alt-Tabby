; Unit Tests - WindowStore and Related Data Structures
; WindowStore, Sorting Comparators, Race Conditions, Delta/Dirty Tracking
; Split from test_unit_core.ahk for context window optimization
; Included by test_unit.ahk
#Include test_utils.ahk

RunUnitTests_CoreStore() {
    global TestPassed, TestErrors, cfg

    ; ============================================================
    ; WindowStore Unit Tests
    ; ============================================================
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
    rec1["isVisible"] := true
    rec1["isCloaked"] := false
    rec1["isMinimized"] := false
    rec1["z"] := 1
    testRecs.Push(rec1)

    rec2 := Map()
    rec2["hwnd"] := 67890
    rec2["title"] := "Test Window 2"
    rec2["class"] := "TestClass2"
    rec2["pid"] := 200
    rec2["isVisible"] := true
    rec2["isCloaked"] := false
    rec2["isMinimized"] := false
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

    ; ============================================================
    ; Sorting Comparator Tiebreaker Tests
    ; ============================================================
    Log("`n--- Sorting Comparator Tiebreaker Tests ---")

    ; Test _WS_CmpMRU: same lastActivatedTick, different z -> z wins
    cmpA := {lastActivatedTick: 1000, z: 2, hwnd: 10}
    cmpB := {lastActivatedTick: 1000, z: 1, hwnd: 20}
    AssertEq(_WS_CmpMRU(cmpA, cmpB) > 0, true, "_WS_CmpMRU: same tick, lower z wins (b before a)")

    ; Test _WS_CmpMRU: same lastActivatedTick, same z, different hwnd -> hwnd wins (stability)
    cmpC := {lastActivatedTick: 1000, z: 1, hwnd: 10}
    cmpD := {lastActivatedTick: 1000, z: 1, hwnd: 20}
    AssertEq(_WS_CmpMRU(cmpC, cmpD) < 0, true, "_WS_CmpMRU: same tick+z, lower hwnd first (stability)")

    ; Test _WS_CmpMRU: all equal -> returns 0
    cmpE := {lastActivatedTick: 1000, z: 1, hwnd: 10}
    cmpF := {lastActivatedTick: 1000, z: 1, hwnd: 10}
    AssertEq(_WS_CmpMRU(cmpE, cmpF), 0, "_WS_CmpMRU: all equal returns 0")

    ; Test _WS_CmpZ: same z, different lastActivatedTick -> MRU wins
    cmpG := {z: 1, lastActivatedTick: 500, hwnd: 10}
    cmpH := {z: 1, lastActivatedTick: 1000, hwnd: 20}
    AssertEq(_WS_CmpZ(cmpG, cmpH) > 0, true, "_WS_CmpZ: same z, higher tick wins (h before g)")

    ; Test _WS_CmpZ: same z, same tick, different hwnd -> hwnd wins (stability)
    cmpI := {z: 1, lastActivatedTick: 1000, hwnd: 10}
    cmpJ := {z: 1, lastActivatedTick: 1000, hwnd: 20}
    AssertEq(_WS_CmpZ(cmpI, cmpJ) < 0, true, "_WS_CmpZ: same z+tick, lower hwnd first (stability)")

    ; Test _WS_InsertionSort: 4-item array, verify identical result to manual sort
    sortArr := [
        {lastActivatedTick: 100, z: 3, hwnd: 1},
        {lastActivatedTick: 300, z: 1, hwnd: 2},
        {lastActivatedTick: 300, z: 1, hwnd: 3},
        {lastActivatedTick: 200, z: 2, hwnd: 4}
    ]
    _WS_InsertionSort(sortArr, _WS_CmpMRU)
    ; Expected MRU order: tick 300 (hwnd 2), tick 300 (hwnd 3), tick 200 (hwnd 4), tick 100 (hwnd 1)
    AssertEq(sortArr[1].hwnd, 2, "_WS_InsertionSort MRU: first = hwnd 2 (tick 300, lower hwnd)")
    AssertEq(sortArr[2].hwnd, 3, "_WS_InsertionSort MRU: second = hwnd 3 (tick 300, higher hwnd)")
    AssertEq(sortArr[3].hwnd, 4, "_WS_InsertionSort MRU: third = hwnd 4 (tick 200)")
    AssertEq(sortArr[4].hwnd, 1, "_WS_InsertionSort MRU: fourth = hwnd 1 (tick 100)")

    ; ============================================================
    ; Race Condition Prevention Tests
    ; ============================================================
    Log("`n--- Race Condition Prevention Tests ---")

    ; Test: _WS_BumpRev atomicity - rev should increment exactly once
    global gWS_Rev
    startRev := gWS_Rev
    _WS_BumpRev("test")
    AssertEq(gWS_Rev, startRev + 1, "_WS_BumpRev increments rev exactly once")

    ; Test: _WS_BumpRev records source in diagnostics
    global gWS_DiagSource
    prevCount := gWS_DiagSource.Has("test") ? gWS_DiagSource["test"] : 0
    _WS_BumpRev("test")
    AssertEq(gWS_DiagSource["test"], prevCount + 1, "_WS_BumpRev records diagnostic source")

    ; Test: Z-queue deduplication - same hwnd shouldn't be added twice
    WindowStore_ClearZQueue()
    global gWS_ZQueue
    WindowStore_EnqueueForZ(99999)
    WindowStore_EnqueueForZ(99999)  ; Duplicate
    AssertEq(gWS_ZQueue.Length, 1, "Z-queue deduplication prevents duplicates")

    ; Test: Z-queue clear empties both queue and set
    WindowStore_EnqueueForZ(88888)
    WindowStore_ClearZQueue()
    global gWS_ZQueueDedup
    AssertEq(gWS_ZQueue.Length, 0, "Z-queue clear empties queue")
    AssertEq(gWS_ZQueueDedup.Count, 0, "Z-queue clear empties set")

    ; ============================================================
    ; WindowStore Advanced Tests
    ; ============================================================
    Log("`n--- WindowStore Advanced Tests ---")

    ; Test: WindowStore_EndScan TTL marks windows missing before removal
    Log("Testing EndScan TTL grace period...")

    WindowStore_Init()
    global gWS_Store

    ; Scan 1: Add two windows
    WindowStore_BeginScan()
    rec1 := Map("hwnd", 11111, "title", "Persistent", "class", "Test", "pid", 1,
                "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 1)
    rec2 := Map("hwnd", 22222, "title", "Disappearing", "class", "Test", "pid", 2,
                "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 2)
    WindowStore_UpsertWindow([rec1, rec2], "test")
    WindowStore_EndScan(100)  ; 100ms grace

    AssertEq(gWS_Store[11111].present, true, "Window 1 present after scan 1")
    AssertEq(gWS_Store[22222].present, true, "Window 2 present after scan 1")

    ; Scan 2: Only include window 1
    WindowStore_BeginScan()
    WindowStore_UpsertWindow([rec1], "test")
    WindowStore_EndScan(100)

    ; Window 2 marked missing but NOT removed yet (within grace period)
    AssertEq(gWS_Store[11111].present, true, "Window 1 still present")
    AssertEq(gWS_Store.Has(22222), true, "Window 2 still in store (grace period)")
    AssertEq(gWS_Store[22222].present, false, "Window 2 marked present=false")

    ; Wait for grace period + scan again
    Sleep(150)
    WindowStore_BeginScan()
    WindowStore_UpsertWindow([rec1], "test")
    WindowStore_EndScan(100)

    ; Window 2 removed after grace expires (IsWindow returns false for fake hwnd)
    AssertEq(gWS_Store.Has(22222), false, "Window 2 removed after grace period")

    ; Cleanup
    WindowStore_RemoveWindow([11111], true)

    ; Test: EndScan preserves komorebi-managed windows (workspaceName set)
    Log("Testing EndScan komorebi workspace preservation...")

    WindowStore_Init()

    ; Scan 1: Add two windows - one with workspaceName, one without
    WindowStore_BeginScan()
    wsRec1 := Map("hwnd", 33333, "title", "Komorebi Managed", "class", "Test", "pid", 10,
                  "isVisible", true, "isCloaked", true, "isMinimized", false, "z", 1,
                  "workspaceName", "MyWorkspace")
    wsRec2 := Map("hwnd", 44444, "title", "Unmanaged Window", "class", "Test", "pid", 11,
                  "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 2,
                  "workspaceName", "")
    WindowStore_UpsertWindow([wsRec1, wsRec2], "test")
    WindowStore_EndScan(100)

    AssertEq(gWS_Store[33333].present, true, "Komorebi window present after scan 1")
    AssertEq(gWS_Store[44444].present, true, "Unmanaged window present after scan 1")

    ; Scan 2: Only upsert the UNMANAGED window (simulating winenum not seeing komorebi-cloaked window)
    WindowStore_BeginScan()
    WindowStore_UpsertWindow([wsRec2], "test")
    WindowStore_EndScan(100)

    ; Komorebi-managed window should survive (workspaceName protects it)
    AssertEq(gWS_Store.Has(33333), true, "Komorebi window still in store (workspace preservation)")
    AssertEq(gWS_Store[33333].present, true, "Komorebi window still present=true (not marked missing)")

    ; Scan 3: Only upsert neither (both not seen by winenum)
    WindowStore_BeginScan()
    WindowStore_EndScan(100)

    ; Komorebi window should still survive, unmanaged should be marked missing
    AssertEq(gWS_Store.Has(33333), true, "Komorebi window survives even with no upsert")
    AssertEq(gWS_Store[33333].present, true, "Komorebi window still present=true")
    AssertEq(gWS_Store[44444].present, false, "Unmanaged window marked present=false")

    ; Test: Empty workspaceName does NOT protect
    Log("Testing EndScan does not protect empty workspaceName...")
    WindowStore_Init()
    WindowStore_BeginScan()
    emptyWsRec := Map("hwnd", 55555, "title", "Empty WS Window", "class", "Test", "pid", 12,
                      "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 1,
                      "workspaceName", "")
    WindowStore_UpsertWindow([emptyWsRec], "test")
    WindowStore_EndScan(100)

    ; Scan again without upserting - empty workspaceName should NOT protect
    WindowStore_BeginScan()
    WindowStore_EndScan(100)

    AssertEq(gWS_Store[55555].present, false, "Empty workspaceName does NOT protect window")

    ; Cleanup
    WindowStore_RemoveWindow([33333, 44444, 55555], true)

    ; Test: WindowStore_BuildDelta field detection
    Log("Testing BuildDelta field detection...")

    baseItem := {
        hwnd: 12345, title: "Original", class: "TestClass", pid: 100, z: 1,
        isFocused: false, workspaceName: "Main", isCloaked: false,
        isMinimized: false, isOnCurrentWorkspace: true, processName: "test.exe",
        iconHicon: 0, lastActivatedTick: 100
    }

    ; Fields that SHOULD trigger delta (from BuildDelta code)
    triggerTests := [
        {field: "title", newVal: "Changed"},
        {field: "z", newVal: 2},
        {field: "isFocused", newVal: true},
        {field: "workspaceName", newVal: "Other"},
        {field: "isCloaked", newVal: true},
        {field: "isMinimized", newVal: true},
        {field: "isOnCurrentWorkspace", newVal: false},
        {field: "processName", newVal: "other.exe"},
        {field: "iconHicon", newVal: 12345},
        {field: "pid", newVal: 200},
        {field: "class", newVal: "OtherClass"},
        {field: "lastActivatedTick", newVal: A_TickCount + 99999}
    ]

    for _, test in triggerTests {
        changedItem := {}
        for k in baseItem.OwnProps()
            changedItem.%k% := baseItem.%k%
        changedItem.%test.field% := test.newVal

        delta := WindowStore_BuildDelta([baseItem], [changedItem])
        AssertEq(delta.upserts.Length, 1, "Field '" test.field "' triggers delta")
    }

    ; New window creates upsert
    delta := WindowStore_BuildDelta([], [baseItem])
    AssertEq(delta.upserts.Length, 1, "New window triggers upsert")
    AssertEq(delta.removes.Length, 0, "No removes for new window")

    ; Removed window creates remove
    delta := WindowStore_BuildDelta([baseItem], [])
    AssertEq(delta.removes.Length, 1, "Removed window triggers remove")

    ; Both arrays empty
    delta := WindowStore_BuildDelta([], [])
    AssertEq(delta.upserts.Length, 0, "Both empty: no upserts")
    AssertEq(delta.removes.Length, 0, "Both empty: no removes")

    ; ============================================================
    ; Sparse Delta Format Tests
    ; ============================================================
    Log("`n--- Sparse Delta Format Tests ---")

    ; Sparse: single field change emits only hwnd + changed field
    Log("Testing sparse delta single field change...")
    sparseChangedItem := {}
    for k in baseItem.OwnProps()
        sparseChangedItem.%k% := baseItem.%k%
    sparseChangedItem.title := "Sparse Changed Title"

    delta := WindowStore_BuildDelta([baseItem], [sparseChangedItem], true)
    AssertEq(delta.upserts.Length, 1, "Sparse: single field triggers upsert")
    sparseRec := delta.upserts[1]
    AssertEq(sparseRec.hwnd, 12345, "Sparse: hwnd present")
    AssertEq(sparseRec.title, "Sparse Changed Title", "Sparse: changed field present")
    ; Verify unchanged fields are NOT present
    hasZ := sparseRec.HasOwnProp("z")
    AssertEq(hasZ, false, "Sparse: unchanged 'z' not in record")
    hasPid := sparseRec.HasOwnProp("pid")
    AssertEq(hasPid, false, "Sparse: unchanged 'pid' not in record")
    hasProcessName := sparseRec.HasOwnProp("processName")
    AssertEq(hasProcessName, false, "Sparse: unchanged 'processName' not in record")

    ; Sparse: multiple field changes emit only those fields + hwnd
    Log("Testing sparse delta multiple field changes...")
    multiChangedItem := {}
    for k in baseItem.OwnProps()
        multiChangedItem.%k% := baseItem.%k%
    multiChangedItem.title := "Multi Changed"
    multiChangedItem.isFocused := true
    multiChangedItem.iconHicon := 99999

    delta := WindowStore_BuildDelta([baseItem], [multiChangedItem], true)
    AssertEq(delta.upserts.Length, 1, "Sparse multi: triggers upsert")
    sparseRec := delta.upserts[1]
    AssertEq(sparseRec.HasOwnProp("title"), true, "Sparse multi: title present")
    AssertEq(sparseRec.HasOwnProp("isFocused"), true, "Sparse multi: isFocused present")
    AssertEq(sparseRec.HasOwnProp("iconHicon"), true, "Sparse multi: iconHicon present")
    AssertEq(sparseRec.HasOwnProp("z"), false, "Sparse multi: unchanged z absent")
    AssertEq(sparseRec.HasOwnProp("workspaceName"), false, "Sparse multi: unchanged workspaceName absent")

    ; Full-record backward compat: sparse=false emits all fields
    Log("Testing full-record backward compat (sparse=false)...")
    delta := WindowStore_BuildDelta([baseItem], [sparseChangedItem], false)
    AssertEq(delta.upserts.Length, 1, "Full: single field triggers upsert")
    fullRec := delta.upserts[1]
    AssertEq(fullRec.HasOwnProp("z"), true, "Full: unchanged 'z' IS in record")
    AssertEq(fullRec.HasOwnProp("pid"), true, "Full: unchanged 'pid' IS in record")
    AssertEq(fullRec.HasOwnProp("processName"), true, "Full: unchanged 'processName' IS in record")

    ; New record always full in sparse mode
    Log("Testing new record always full in sparse mode...")
    delta := WindowStore_BuildDelta([], [baseItem], true)
    AssertEq(delta.upserts.Length, 1, "Sparse new: new window triggers upsert")
    newRec := delta.upserts[1]
    AssertEq(newRec.HasOwnProp("title"), true, "Sparse new: title present")
    AssertEq(newRec.HasOwnProp("z"), true, "Sparse new: z present")
    AssertEq(newRec.HasOwnProp("pid"), true, "Sparse new: pid present")
    AssertEq(newRec.HasOwnProp("processName"), true, "Sparse new: processName present")
    AssertEq(newRec.HasOwnProp("iconHicon"), true, "Sparse new: iconHicon present")

    ; Sparse: no changes = no upserts (same as full mode)
    delta := WindowStore_BuildDelta([baseItem], [baseItem], true)
    AssertEq(delta.upserts.Length, 0, "Sparse: identical items = no upserts")

    ; ============================================================
    ; Dirty Tracking Equivalence Tests
    ; ============================================================
    ; Tests that dirty tracking skips non-dirty windows; debug mode compares all
    Log("`n--- Dirty Tracking Equivalence Tests ---")

    Log("Testing dirty tracking behavior...")
    try {
        ; Setup: Both hwnds have field changes (isFocused swapped between them)
        ; This lets us verify dirty tracking skips 1002 when not marked dirty
        prev := [
            {hwnd: 1001, title: "Win1", class: "C1", z: 1, pid: 100, isFocused: false,
             workspaceName: "ws1", isCloaked: false, isMinimized: false,
             isOnCurrentWorkspace: true, processName: "app1", iconHicon: 0, lastActivatedTick: 1000},
            {hwnd: 1002, title: "Win2", class: "C2", z: 2, pid: 200, isFocused: true,
             workspaceName: "ws1", isCloaked: false, isMinimized: false,
             isOnCurrentWorkspace: true, processName: "app2", iconHicon: 0, lastActivatedTick: 2000}
        ]
        next := [
            {hwnd: 1001, title: "Win1", class: "C1", z: 1, pid: 100, isFocused: true,
             workspaceName: "ws1", isCloaked: false, isMinimized: false,
             isOnCurrentWorkspace: true, processName: "app1", iconHicon: 0, lastActivatedTick: 3000},
            {hwnd: 1002, title: "Win2", class: "C2", z: 2, pid: 200, isFocused: false,
             workspaceName: "ws1", isCloaked: false, isMinimized: false,
             isOnCurrentWorkspace: true, processName: "app2", iconHicon: 0, lastActivatedTick: 2000}
        ]

        global gWS_DeltaPendingHwnds
        originalDirtyTracking := cfg.IPCUseDirtyTracking
        gWS_DeltaPendingHwnds := Map()

        ; Create dirty snapshot marking ONLY hwnd 1001 (not 1002)
        dirtySnapshot := Map()
        dirtySnapshot[1001] := true

        ; TEST 1: Dirty tracking ON - should return ONLY hwnd 1001 (skips 1002)
        cfg.IPCUseDirtyTracking := true
        deltaDirty := WindowStore_BuildDelta(prev, next, false, dirtySnapshot)

        ; TEST 2: Dirty tracking OFF (debug mode) - should return BOTH 1001 and 1002
        cfg.IPCUseDirtyTracking := false
        deltaFull := WindowStore_BuildDelta(prev, next, false)

        passed := true

        ; Dirty tracking: only 1 upsert (hwnd 1001)
        if (deltaDirty.upserts.Length != 1) {
            Log("FAIL: Dirty tracking - expected 1 upsert (only marked hwnd), got " deltaDirty.upserts.Length)
            passed := false
        } else if (deltaDirty.upserts[1].hwnd != 1001) {
            Log("FAIL: Dirty tracking - expected hwnd 1001")
            passed := false
        }

        ; Debug mode: 2 upserts (both changed windows)
        if (deltaFull.upserts.Length != 2) {
            Log("FAIL: Debug mode - expected 2 upserts (all changes), got " deltaFull.upserts.Length)
            passed := false
        }

        if (passed) {
            Log("PASS: Dirty tracking correctly skips non-dirty; debug mode finds all")
            TestPassed++
        } else {
            TestErrors++
        }

        ; Restore original config
        cfg.IPCUseDirtyTracking := originalDirtyTracking
        gWS_DeltaPendingHwnds := Map()
    } catch as e {
        Log("FAIL: Dirty tracking test error: " e.Message)
        TestErrors++
    }

    ; ============================================================
    ; Sort Skip (gWS_SortDirty) Validation Tests
    ; ============================================================
    Log("`n--- Sort Skip Validation Tests ---")
    global gWS_SortDirty, gWS_ProjectionFields

    ; Setup: init store with test windows
    WindowStore_Init()
    WindowStore_BeginScan()
    sortTestRecs := []
    sortTestRecs.Push(Map("hwnd", 5001, "title", "SortTest1", "class", "T", "pid", 1,
                          "isVisible", true, "isCloaked", false, "isMinimized", false,
                          "z", 1, "lastActivatedTick", 100))
    sortTestRecs.Push(Map("hwnd", 5002, "title", "SortTest2", "class", "T", "pid", 2,
                          "isVisible", true, "isCloaked", false, "isMinimized", false,
                          "z", 2, "lastActivatedTick", 200))
    WindowStore_UpsertWindow(sortTestRecs, "test")
    WindowStore_EndScan()

    ; Force a projection to reset dirty flag
    WindowStore_GetProjection()
    AssertEq(gWS_SortDirty, false, "SortDirty: false after GetProjection")

    ; Cosmetic field change (iconHicon) should NOT set dirty
    WindowStore_UpdateFields(5001, Map("iconHicon", 9999), "test")
    AssertEq(gWS_SortDirty, false, "SortDirty: iconHicon change keeps false")

    ; Title change should NOT set dirty (title is not in ProjectionFields)
    WindowStore_UpdateFields(5001, Map("title", "New Title"), "test")
    AssertEq(gWS_SortDirty, false, "SortDirty: title change keeps false")

    ; Sort-affecting field (lastActivatedTick) should set dirty
    WindowStore_UpdateFields(5001, Map("lastActivatedTick", 999), "test")
    AssertEq(gWS_SortDirty, true, "SortDirty: lastActivatedTick sets true")

    ; Reset via GetProjection
    WindowStore_GetProjection()
    AssertEq(gWS_SortDirty, false, "SortDirty: reset after second GetProjection")

    ; Filter-affecting field (isCloaked) should set dirty
    WindowStore_UpdateFields(5001, Map("isCloaked", true), "test")
    AssertEq(gWS_SortDirty, true, "SortDirty: isCloaked sets true")

    ; Reset and test z field
    WindowStore_GetProjection()
    WindowStore_UpdateFields(5001, Map("z", 99), "test")
    AssertEq(gWS_SortDirty, true, "SortDirty: z change sets true")

    ; Reset and test isFocused field
    WindowStore_GetProjection()
    WindowStore_UpdateFields(5001, Map("isFocused", true), "test")
    AssertEq(gWS_SortDirty, true, "SortDirty: isFocused sets true")

    ; Cleanup
    WindowStore_RemoveWindow([5001, 5002], true)

    ; Test: WindowStore_SetCurrentWorkspace updates all windows
    Log("Testing SetCurrentWorkspace consistency...")

    WindowStore_Init()
    global gWS_Meta

    WindowStore_BeginScan()
    recs := []
    recs.Push(Map("hwnd", 1001, "title", "Win1", "class", "T", "pid", 1,
                  "isVisible", true, "isCloaked", false, "isMinimized", false,
                  "z", 1, "workspaceName", "Main"))
    recs.Push(Map("hwnd", 1002, "title", "Win2", "class", "T", "pid", 2,
                  "isVisible", true, "isCloaked", false, "isMinimized", false,
                  "z", 2, "workspaceName", "Other"))
    recs.Push(Map("hwnd", 1003, "title", "Win3", "class", "T", "pid", 3,
                  "isVisible", true, "isCloaked", false, "isMinimized", false,
                  "z", 3, "workspaceName", ""))  ; Unmanaged
    WindowStore_UpsertWindow(recs, "test")
    WindowStore_EndScan()

    startRev := WindowStore_GetRev()
    WindowStore_SetCurrentWorkspace("", "Main")

    AssertEq(gWS_Store[1001].isOnCurrentWorkspace, true, "Main window on current")
    AssertEq(gWS_Store[1002].isOnCurrentWorkspace, false, "Other window NOT on current")
    AssertEq(gWS_Store[1003].isOnCurrentWorkspace, true, "Unmanaged floats to current")
    AssertEq(gWS_Meta["currentWSName"], "Main", "Meta updated")
    AssertEq(WindowStore_GetRev(), startRev + 1, "Rev bumped exactly once")

    ; Switch workspace
    WindowStore_SetCurrentWorkspace("", "Other")
    AssertEq(gWS_Store[1001].isOnCurrentWorkspace, false, "Main now NOT current")
    AssertEq(gWS_Store[1002].isOnCurrentWorkspace, true, "Other now current")

    ; Same-name no-op (no rev bump)
    revBefore := WindowStore_GetRev()
    WindowStore_SetCurrentWorkspace("", "Other")  ; Same name as currently set
    AssertEq(WindowStore_GetRev(), revBefore, "SetCurrentWorkspace same name: no-op")

    ; Cleanup
    WindowStore_RemoveWindow([1001, 1002, 1003], true)

    ; ============================================================
    ; WorkspaceChangedFlag Tests
    ; ============================================================
    ; Tests for the gWS_WorkspaceChangedFlag used by OnChange delta style
    Log("`n--- WorkspaceChangedFlag Tests ---")

    ; Reset store and flag for clean test
    WindowStore_Init()
    global gWS_WorkspaceChangedFlag
    gWS_WorkspaceChangedFlag := false

    ; Test 1: Flag starts false
    AssertEq(gWS_WorkspaceChangedFlag, false, "WorkspaceChangedFlag: starts false")

    ; Test 2: SetCurrentWorkspace with new name sets flag true
    WindowStore_SetCurrentWorkspace("", "TestWS1")
    AssertEq(gWS_WorkspaceChangedFlag, true, "WorkspaceChangedFlag: set to true on workspace change")

    ; Test 3: ConsumeWorkspaceChangedFlag returns true and resets to false
    consumeResult := WindowStore_ConsumeWorkspaceChangedFlag()
    AssertEq(consumeResult, true, "WorkspaceChangedFlag: ConsumeWorkspaceChangedFlag returns true")
    AssertEq(gWS_WorkspaceChangedFlag, false, "WorkspaceChangedFlag: reset to false after consume")

    ; Test 4: Second consume returns false (already consumed)
    consumeResult2 := WindowStore_ConsumeWorkspaceChangedFlag()
    AssertEq(consumeResult2, false, "WorkspaceChangedFlag: second consume returns false")

    ; Test 5: SetCurrentWorkspace with same name does NOT set flag
    gWS_WorkspaceChangedFlag := false  ; Ensure clean state
    WindowStore_SetCurrentWorkspace("", "TestWS1")  ; Same name as currently set
    AssertEq(gWS_WorkspaceChangedFlag, false, "WorkspaceChangedFlag: stays false when name unchanged")

    ; Test 6: SetCurrentWorkspace with different name DOES set flag
    WindowStore_SetCurrentWorkspace("", "TestWS2")
    AssertEq(gWS_WorkspaceChangedFlag, true, "WorkspaceChangedFlag: set true when name changes")

    ; Cleanup
    gWS_WorkspaceChangedFlag := false
}
