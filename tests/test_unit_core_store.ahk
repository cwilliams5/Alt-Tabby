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

    ; Test: _WS_BumpRev records source in diagnostics (requires DiagChurnLog enabled)
    global gWS_DiagSource
    origChurnLog := cfg.DiagChurnLog
    cfg.DiagChurnLog := true
    prevCount := gWS_DiagSource.Has("test") ? gWS_DiagSource["test"] : 0
    _WS_BumpRev("test")
    AssertEq(gWS_DiagSource["test"], prevCount + 1, "_WS_BumpRev records diagnostic source")
    cfg.DiagChurnLog := origChurnLog

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
        isFocused: false, workspaceName: "Main", workspaceId: "",
        isCloaked: false, isMinimized: false, isOnCurrentWorkspace: true,
        processName: "test.exe", iconHicon: 0, lastActivatedTick: 100
    }

    ; Fields that SHOULD trigger delta (from BuildDelta code)
    triggerTests := [
        {field: "title", newVal: "Changed"},
        {field: "z", newVal: 2},
        {field: "isFocused", newVal: true},
        {field: "workspaceName", newVal: "Other"},
        {field: "workspaceId", newVal: "ws-123"},
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
    ; Sparse + Dirty Tracking Combined Tests
    ; ============================================================
    ; Production calls BuildDelta(prev, next, true, dirtySnapshot) — both sparse AND dirty.
    ; Individual tests cover each independently; this tests the combined interaction.
    Log("`n--- Sparse + Dirty Tracking Combined Tests ---")

    origDirtyTracking := cfg.IPCUseDirtyTracking
    cfg.IPCUseDirtyTracking := true

    ; 3 windows: A unchanged, B title changed, C new
    sdPrev := [
        {hwnd: 2001, title: "Unchanged", class: "C1", z: 1, pid: 100, isFocused: false,
         workspaceName: "ws1", workspaceId: "", isCloaked: false, isMinimized: false,
         isOnCurrentWorkspace: true, processName: "app1", iconHicon: 0, lastActivatedTick: 1000},
        {hwnd: 2002, title: "OldTitle", class: "C2", z: 2, pid: 200, isFocused: false,
         workspaceName: "ws1", workspaceId: "", isCloaked: false, isMinimized: false,
         isOnCurrentWorkspace: true, processName: "app2", iconHicon: 0, lastActivatedTick: 2000}
    ]
    sdNext := [
        {hwnd: 2001, title: "Unchanged", class: "C1", z: 1, pid: 100, isFocused: false,
         workspaceName: "ws1", workspaceId: "", isCloaked: false, isMinimized: false,
         isOnCurrentWorkspace: true, processName: "app1", iconHicon: 0, lastActivatedTick: 1000},
        {hwnd: 2002, title: "NewTitle", class: "C2", z: 2, pid: 200, isFocused: false,
         workspaceName: "ws1", workspaceId: "", isCloaked: false, isMinimized: false,
         isOnCurrentWorkspace: true, processName: "app2", iconHicon: 0, lastActivatedTick: 2000},
        {hwnd: 2003, title: "BrandNew", class: "C3", z: 3, pid: 300, isFocused: false,
         workspaceName: "ws1", workspaceId: "", isCloaked: false, isMinimized: false,
         isOnCurrentWorkspace: true, processName: "app3", iconHicon: 0, lastActivatedTick: 3000}
    ]

    ; Dirty set: only B (2002) is dirty. A (2001) is clean. C (2003) is new (not in prev).
    sdDirty := Map()
    sdDirty[2002] := true

    sdDelta := WindowStore_BuildDelta(sdPrev, sdNext, true, sdDirty)

    ; A (2001): clean + unchanged → skipped entirely
    foundA := false
    for _, u in sdDelta.upserts {
        if (u.hwnd = 2001)
            foundA := true
    }
    AssertEq(foundA, false, "Sparse+Dirty: clean unchanged window A skipped")

    ; B (2002): dirty + title changed → sparse upsert (only changed fields + hwnd)
    foundB := false
    for _, u in sdDelta.upserts {
        if (u.hwnd = 2002) {
            foundB := true
            AssertEq(u.title, "NewTitle", "Sparse+Dirty: B has changed title")
            AssertEq(u.HasOwnProp("z"), false, "Sparse+Dirty: B omits unchanged z")
            AssertEq(u.HasOwnProp("processName"), false, "Sparse+Dirty: B omits unchanged processName")
        }
    }
    AssertEq(foundB, true, "Sparse+Dirty: dirty changed window B present")

    ; C (2003): new window → full record (all fields, regardless of dirty set)
    foundC := false
    for _, u in sdDelta.upserts {
        if (u.hwnd = 2003) {
            foundC := true
            AssertEq(u.HasOwnProp("title"), true, "Sparse+Dirty: new window C has title")
            AssertEq(u.HasOwnProp("z"), true, "Sparse+Dirty: new window C has z")
            AssertEq(u.HasOwnProp("processName"), true, "Sparse+Dirty: new window C has processName")
        }
    }
    AssertEq(foundC, true, "Sparse+Dirty: new window C present with full fields")

    cfg.IPCUseDirtyTracking := origDirtyTracking

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
    ; Two-Level Dirty Tracking Validation Tests
    ; ============================================================
    Log("`n--- Two-Level Dirty Tracking Tests ---")
    global gWS_SortOrderDirty, gWS_ProjectionContentDirty
    global gWS_SortAffectingFields, gWS_ContentOnlyFields

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

    ; Force a projection to reset dirty flags
    WindowStore_GetProjection()
    AssertEq(gWS_SortOrderDirty, false, "SortOrderDirty: false after GetProjection")
    AssertEq(gWS_ProjectionContentDirty, false, "ContentDirty: false after GetProjection")

    ; iconHicon change should NOT set sort dirty (icon is cosmetic, doesn't affect order)
    ; but MUST set content dirty so fresh _WS_ToItem copies are created (regression 514a45f)
    WindowStore_UpdateFields(5001, Map("iconHicon", 9999), "test")
    AssertEq(gWS_SortOrderDirty, false, "SortOrderDirty: iconHicon does NOT dirty sort order")
    AssertEq(gWS_ProjectionContentDirty, true, "ContentDirty: iconHicon dirties projection content")

    ; Reset via GetProjection
    WindowStore_GetProjection()

    ; Title change MUST set content dirty (was previously untracked, masked by z=0 churn)
    WindowStore_UpdateFields(5001, Map("title", "New Title"), "test")
    AssertEq(gWS_SortOrderDirty, false, "SortOrderDirty: title does not dirty sort order")
    AssertEq(gWS_ProjectionContentDirty, true, "ContentDirty: title dirties projection content")

    ; Reset via GetProjection
    WindowStore_GetProjection()

    ; Sort-affecting field (lastActivatedTick) should set both dirty flags
    WindowStore_UpdateFields(5001, Map("lastActivatedTick", 999), "test")
    AssertEq(gWS_SortOrderDirty, true, "SortOrderDirty: lastActivatedTick sets true")
    AssertEq(gWS_ProjectionContentDirty, true, "ContentDirty: lastActivatedTick sets true")

    ; Reset via GetProjection
    WindowStore_GetProjection()
    AssertEq(gWS_SortOrderDirty, false, "SortOrderDirty: reset after GetProjection")
    AssertEq(gWS_ProjectionContentDirty, false, "ContentDirty: reset after GetProjection")

    ; Filter-affecting field (isCloaked) should set sort dirty
    WindowStore_UpdateFields(5001, Map("isCloaked", true), "test")
    AssertEq(gWS_SortOrderDirty, true, "SortOrderDirty: isCloaked sets true")

    ; Reset and test z field
    WindowStore_GetProjection()
    WindowStore_UpdateFields(5001, Map("z", 99), "test")
    AssertEq(gWS_SortOrderDirty, true, "SortOrderDirty: z change sets true")

    ; Reset and test isFocused field
    WindowStore_GetProjection()
    WindowStore_UpdateFields(5001, Map("isFocused", true), "test")
    AssertEq(gWS_SortOrderDirty, true, "SortOrderDirty: isFocused sets true")

    ; --- Regression test: icon update MUST produce fresh data in projection (514a45f) ---
    ; Reset isCloaked so window is visible in default projection (includeCloaked=false)
    WindowStore_UpdateFields(5001, Map("isCloaked", false), "test")
    WindowStore_GetProjection()  ; Reset — creates cached items with old icon
    WindowStore_UpdateFields(5001, Map("iconHicon", 7777), "test")
    proj := WindowStore_GetProjection()  ; Should use Path 2 — fresh _WS_ToItem
    foundIcon := false
    for _, item in proj.items {
        if (item.hwnd = 5001) {
            AssertEq(item.iconHicon, 7777, "Path 2 returns fresh iconHicon (regression 514a45f)")
            foundIcon := true
            break
        }
    }
    AssertEq(foundIcon, true, "Path 2 regression: hwnd 5001 found in projection")

    ; --- Regression test: title update MUST produce fresh data in projection ---
    WindowStore_GetProjection()
    WindowStore_UpdateFields(5001, Map("title", "Updated Title"), "test")
    proj := WindowStore_GetProjection()
    foundTitle := false
    for _, item in proj.items {
        if (item.hwnd = 5001) {
            AssertEq(item.title, "Updated Title", "Path 2 returns fresh title")
            foundTitle := true
            break
        }
    }
    AssertEq(foundTitle, true, "Path 2 title: hwnd 5001 found in projection")

    ; --- Coverage test: every _WS_ToItem field must be tracked ---
    ; Prevents future regressions where a new field is added to _WS_ToItem
    ; but not tracked, silently causing stale cache data
    coveredFields := ["title", "class", "pid", "z", "lastActivatedTick", "isFocused",
        "isCloaked", "isMinimized", "workspaceName", "workspaceId",
        "isOnCurrentWorkspace", "processName", "iconHicon"]
    for _, field in coveredFields {
        covered := gWS_SortAffectingFields.Has(field) || gWS_ContentOnlyFields.Has(field)
        AssertEq(covered, true, "Field '" field "' must be tracked in SortAffecting or ContentOnly")
    }

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
    flipped := WindowStore_SetCurrentWorkspace("", "Main")

    AssertEq(gWS_Store[1001].isOnCurrentWorkspace, true, "Main window on current")
    AssertEq(gWS_Store[1002].isOnCurrentWorkspace, false, "Other window NOT on current")
    AssertEq(gWS_Store[1003].isOnCurrentWorkspace, true, "Unmanaged floats to current")
    AssertEq(gWS_Meta["currentWSName"], "Main", "Meta updated")
    AssertEq(WindowStore_GetRev(), startRev + 1, "Rev bumped exactly once")

    ; Return value: flipped array contains _WS_ToItem records for windows that CHANGED
    ; Default isOnCurrentWorkspace is true (from _WS_NewRecord).
    ; After SetCurrentWorkspace("Main"): 1001 stays true, 1002 flips false, 1003 stays true
    AssertEq(flipped.Length, 1, "SetCurrentWorkspace return: only Other window flipped")
    AssertEq(flipped[1].hwnd, 1002, "Flipped item is hwnd 1002 (Other)")
    AssertEq(flipped[1].isOnCurrentWorkspace, false, "Flipped item: isOnCurrentWorkspace=false")
    AssertEq(flipped[1].HasOwnProp("title"), true, "Flipped item has title (_WS_ToItem format)")

    ; Switch workspace — both Main and Other flip
    flipped2 := WindowStore_SetCurrentWorkspace("", "Other")
    AssertEq(gWS_Store[1001].isOnCurrentWorkspace, false, "Main now NOT current")
    AssertEq(gWS_Store[1002].isOnCurrentWorkspace, true, "Other now current")
    AssertEq(flipped2.Length, 2, "SetCurrentWorkspace switch: 2 windows flipped (Main+Other)")

    ; Same-name no-op (no rev bump, empty return)
    revBefore := WindowStore_GetRev()
    flipped3 := WindowStore_SetCurrentWorkspace("", "Other")  ; Same name as currently set
    AssertEq(WindowStore_GetRev(), revBefore, "SetCurrentWorkspace same name: no-op")
    AssertEq(flipped3.Length, 0, "SetCurrentWorkspace same name: empty flipped array")

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

    ; ============================================================
    ; BatchUpdateFields Contract Tests
    ; ============================================================
    ; BatchUpdateFields applies N patches with a single rev bump.
    ; Production relies on this for efficient batching in store_server.ahk.
    Log("`n--- BatchUpdateFields Contract Tests ---")

    WindowStore_Init()
    WindowStore_BeginScan()
    batchRecs := []
    batchRecs.Push(Map("hwnd", 7001, "title", "Batch1", "class", "T", "pid", 1,
                       "isVisible", true, "isCloaked", false, "isMinimized", false,
                       "z", 1, "lastActivatedTick", 100))
    batchRecs.Push(Map("hwnd", 7002, "title", "Batch2", "class", "T", "pid", 2,
                       "isVisible", true, "isCloaked", false, "isMinimized", false,
                       "z", 2, "lastActivatedTick", 200))
    batchRecs.Push(Map("hwnd", 7003, "title", "Batch3", "class", "T", "pid", 3,
                       "isVisible", true, "isCloaked", false, "isMinimized", false,
                       "z", 3, "lastActivatedTick", 300))
    WindowStore_UpsertWindow(batchRecs, "test")
    WindowStore_EndScan()

    ; Reset dirty flags and capture rev before batch
    WindowStore_GetProjection()
    batchRevBefore := WindowStore_GetRev()

    ; Batch: patch 2 windows with different fields (title = content-only, z = sort-affecting)
    patches := Map()
    patches[7001] := Map("title", "BatchUpdated1")     ; Content-only change
    patches[7002] := Map("z", 99)                       ; Sort-affecting change
    batchResult := WindowStore_BatchUpdateFields(patches, "test")

    ; Assertions: return value
    AssertEq(batchResult.changed, 2, "BatchUpdateFields: changed count = 2")

    ; Assertions: rev bumped exactly once (not once per patch)
    AssertEq(WindowStore_GetRev(), batchRevBefore + 1, "BatchUpdateFields: rev bumped exactly once")

    ; Assertions: both windows updated
    AssertEq(gWS_Store[7001].title, "BatchUpdated1", "BatchUpdateFields: window 1 title updated")
    AssertEq(gWS_Store[7002].z, 99, "BatchUpdateFields: window 2 z updated")

    ; Assertions: third window untouched
    AssertEq(gWS_Store[7003].title, "Batch3", "BatchUpdateFields: window 3 title unchanged")

    ; Assertions: dirty flags correct (z is sort-affecting → both dirty)
    AssertEq(gWS_SortOrderDirty, true, "BatchUpdateFields: sort dirty (z changed)")
    AssertEq(gWS_ProjectionContentDirty, true, "BatchUpdateFields: content dirty")

    ; Test: content-only batch does NOT set sort dirty
    WindowStore_GetProjection()  ; Reset dirty flags
    patches2 := Map()
    patches2[7001] := Map("iconHicon", 5555)
    WindowStore_BatchUpdateFields(patches2, "test")
    AssertEq(gWS_SortOrderDirty, false, "BatchUpdateFields content-only: sort NOT dirty")
    AssertEq(gWS_ProjectionContentDirty, true, "BatchUpdateFields content-only: content dirty")

    ; Test: patching non-existent hwnd is silently skipped
    WindowStore_GetProjection()
    batchRevBefore2 := WindowStore_GetRev()
    patches3 := Map()
    patches3[99999] := Map("title", "Ghost")
    batchResult3 := WindowStore_BatchUpdateFields(patches3, "test")
    AssertEq(batchResult3.changed, 0, "BatchUpdateFields: non-existent hwnd skipped")
    AssertEq(WindowStore_GetRev(), batchRevBefore2, "BatchUpdateFields: no rev bump when nothing changed")

    ; Cleanup
    WindowStore_RemoveWindow([7001, 7002, 7003], true)

    ; ============================================================
    ; Projection Cache Stale-Ref Fallback Tests (Path 2 → Path 3)
    ; ============================================================
    ; Path 2 (content-only refresh) checks rec.present on cached sorted refs.
    ; If a stale ref is found, it falls through to Path 3 (full rebuild).
    Log("`n--- Projection Cache Stale-Ref Fallback Tests ---")

    global gWS_ProjectionCache_SortedRecs
    WindowStore_Init()
    WindowStore_BeginScan()
    staleRecs := []
    staleRecs.Push(Map("hwnd", 8001, "title", "StaleTest1", "class", "T", "pid", 1,
                       "isVisible", true, "isCloaked", false, "isMinimized", false,
                       "z", 1, "lastActivatedTick", 100))
    staleRecs.Push(Map("hwnd", 8002, "title", "StaleTest2", "class", "T", "pid", 2,
                       "isVisible", true, "isCloaked", false, "isMinimized", false,
                       "z", 2, "lastActivatedTick", 200))
    WindowStore_UpsertWindow(staleRecs, "test")
    WindowStore_EndScan()

    ; Prime the cache (Path 3 runs, populates cache)
    proj1 := WindowStore_GetProjection()
    AssertEq(proj1.items.Length, 2, "StaleRef setup: 2 items in initial projection")
    AssertEq(gWS_SortOrderDirty, false, "StaleRef setup: sort clean after projection")
    AssertEq(gWS_ProjectionContentDirty, false, "StaleRef setup: content clean after projection")

    ; Simulate stale ref: mark one cached record as not present
    ; In production, this shouldn't happen (removal sets SortOrderDirty), but the defensive
    ; check exists in case of edge cases
    for _, cachedRec in gWS_ProjectionCache_SortedRecs {
        if (cachedRec.hwnd = 8002) {
            cachedRec.present := false
            break
        }
    }

    ; Force Path 2 entry: content dirty + sort clean
    gWS_ProjectionContentDirty := true
    gWS_SortOrderDirty := false

    ; Get projection — Path 2 should detect stale ref, fall through to Path 3
    proj2 := WindowStore_GetProjection()

    ; Path 3 rebuilds from live store — only present window should appear
    AssertEq(proj2.items.Length, 1, "StaleRef fallback: Path 3 returns only present window")
    AssertEq(proj2.items[1].hwnd, 8001, "StaleRef fallback: correct window survived")

    ; Cleanup
    WindowStore_RemoveWindow([8001, 8002], true)
}
