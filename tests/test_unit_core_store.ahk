; Unit Tests - WindowList and Related Data Structures
; WindowList (WL_*), Sorting Comparators, Race Conditions, Dirty Tracking
; Split from test_unit_core.ahk for context window optimization
; Included by test_unit.ahk
#Include test_utils.ahk

RunUnitTests_CoreStore() {
    global TestPassed, TestErrors, cfg, gWS_DirtyHwnds, DISPLAY_FIELDS

    ; ============================================================
    ; WindowList Unit Tests
    ; ============================================================
    Log("`n--- WindowList Unit Tests ---")

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

    ; Test 5: WindowList basic operations
    WL_Init()
    WL_BeginScan()

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

    result := WL_UpsertWindow(testRecs, "test")
    AssertEq(result.added, 2, "WL_UpsertWindow adds records")

    ; Test 6: GetDisplayList with plain object opts (THE BUG FIX)
    proj := WL_GetDisplayList({ sort: "Z", columns: "items" })
    AssertEq(proj.items.Length, 2, "GetDisplayList with plain object opts")

    ; Test 7: GetDisplayList with Map opts
    projMap := WL_GetDisplayList(Map("sort", "Title"))
    AssertEq(projMap.items.Length, 2, "GetDisplayList with Map opts")

    ; Test 8: Z-order sorting
    projZ := WL_GetDisplayList({ sort: "Z" })
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
    WL_ClearZQueue()
    global gWS_ZQueue
    WL_EnqueueForZ(99999)
    WL_EnqueueForZ(99999)  ; Duplicate
    AssertEq(gWS_ZQueue.Length, 1, "Z-queue deduplication prevents duplicates")

    ; Test: Z-queue clear empties both queue and set
    WL_EnqueueForZ(88888)
    WL_ClearZQueue()
    global gWS_ZQueueDedup
    AssertEq(gWS_ZQueue.Length, 0, "Z-queue clear empties queue")
    AssertEq(gWS_ZQueueDedup.Count, 0, "Z-queue clear empties set")

    ; ============================================================
    ; WindowList Advanced Tests
    ; ============================================================
    Log("`n--- WindowList Advanced Tests ---")

    ; Test: WL_EndScan TTL marks windows missing before removal
    Log("Testing EndScan TTL grace period...")

    WL_Init()
    global gWS_Store

    ; Scan 1: Add two windows
    WL_BeginScan()
    rec1 := Map("hwnd", 11111, "title", "Persistent", "class", "Test", "pid", 1,
                "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 1)
    rec2 := Map("hwnd", 22222, "title", "Disappearing", "class", "Test", "pid", 2,
                "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 2)
    WL_UpsertWindow([rec1, rec2], "test")
    WL_EndScan(100)  ; 100ms grace

    AssertEq(gWS_Store[11111].present, true, "Window 1 present after scan 1")
    AssertEq(gWS_Store[22222].present, true, "Window 2 present after scan 1")

    ; Scan 2: Only include window 1
    WL_BeginScan()
    WL_UpsertWindow([rec1], "test")
    WL_EndScan(100)

    ; Window 2 marked missing but NOT removed yet (within grace period)
    AssertEq(gWS_Store[11111].present, true, "Window 1 still present")
    AssertEq(gWS_Store.Has(22222), true, "Window 2 still in store (grace period)")
    AssertEq(gWS_Store[22222].present, false, "Window 2 marked present=false")

    ; Wait for grace period + scan again
    Sleep(150)
    WL_BeginScan()
    WL_UpsertWindow([rec1], "test")
    WL_EndScan(100)

    ; Window 2 removed after grace expires (IsWindow returns false for fake hwnd)
    AssertEq(gWS_Store.Has(22222), false, "Window 2 removed after grace period")

    ; Cleanup
    WL_RemoveWindow([11111], true)

    ; Test: EndScan preserves komorebi-managed windows (workspaceName set)
    Log("Testing EndScan komorebi workspace preservation...")

    WL_Init()

    ; Scan 1: Add two windows - one with workspaceName, one without
    WL_BeginScan()
    wsRec1 := Map("hwnd", 33333, "title", "Komorebi Managed", "class", "Test", "pid", 10,
                  "isVisible", true, "isCloaked", true, "isMinimized", false, "z", 1,
                  "workspaceName", "MyWorkspace")
    wsRec2 := Map("hwnd", 44444, "title", "Unmanaged Window", "class", "Test", "pid", 11,
                  "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 2,
                  "workspaceName", "")
    WL_UpsertWindow([wsRec1, wsRec2], "test")
    WL_EndScan(100)

    AssertEq(gWS_Store[33333].present, true, "Komorebi window present after scan 1")
    AssertEq(gWS_Store[44444].present, true, "Unmanaged window present after scan 1")

    ; Scan 2: Only upsert the UNMANAGED window (simulating winenum not seeing komorebi-cloaked window)
    WL_BeginScan()
    WL_UpsertWindow([wsRec2], "test")
    WL_EndScan(100)

    ; Komorebi-managed window should survive (workspaceName protects it)
    AssertEq(gWS_Store.Has(33333), true, "Komorebi window still in store (workspace preservation)")
    AssertEq(gWS_Store[33333].present, true, "Komorebi window still present=true (not marked missing)")

    ; Scan 3: Only upsert neither (both not seen by winenum)
    WL_BeginScan()
    WL_EndScan(100)

    ; Komorebi window should still survive, unmanaged should be marked missing
    AssertEq(gWS_Store.Has(33333), true, "Komorebi window survives even with no upsert")
    AssertEq(gWS_Store[33333].present, true, "Komorebi window still present=true")
    AssertEq(gWS_Store[44444].present, false, "Unmanaged window marked present=false")

    ; Test: Empty workspaceName does NOT protect
    Log("Testing EndScan does not protect empty workspaceName...")
    WL_Init()
    WL_BeginScan()
    emptyWsRec := Map("hwnd", 55555, "title", "Empty WS Window", "class", "Test", "pid", 12,
                      "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 1,
                      "workspaceName", "")
    WL_UpsertWindow([emptyWsRec], "test")
    WL_EndScan(100)

    ; Scan again without upserting - empty workspaceName should NOT protect
    WL_BeginScan()
    WL_EndScan(100)

    AssertEq(gWS_Store[55555].present, false, "Empty workspaceName does NOT protect window")

    ; Cleanup
    WL_RemoveWindow([33333, 44444, 55555], true)

    ; ============================================================
    ; Two-Level Dirty Tracking Validation Tests
    ; ============================================================
    Log("`n--- Two-Level Dirty Tracking Tests ---")
    global gWS_SortOrderDirty, gWS_ContentDirty
    global gWS_SortAffectingFields, gWS_ContentOnlyFields

    ; Setup: init store with test windows
    WL_Init()
    WL_BeginScan()
    sortTestRecs := []
    sortTestRecs.Push(Map("hwnd", 5001, "title", "SortTest1", "class", "T", "pid", 1,
                          "isVisible", true, "isCloaked", false, "isMinimized", false,
                          "z", 1, "lastActivatedTick", 100))
    sortTestRecs.Push(Map("hwnd", 5002, "title", "SortTest2", "class", "T", "pid", 2,
                          "isVisible", true, "isCloaked", false, "isMinimized", false,
                          "z", 2, "lastActivatedTick", 200))
    WL_UpsertWindow(sortTestRecs, "test")
    WL_EndScan()

    ; Force a display list to reset dirty flags
    WL_GetDisplayList()
    AssertEq(gWS_SortOrderDirty, false, "SortOrderDirty: false after GetDisplayList")
    AssertEq(gWS_ContentDirty, false, "ContentDirty: false after GetDisplayList")

    ; iconHicon change should NOT set sort dirty (icon is cosmetic, doesn't affect order)
    ; but MUST set content dirty so fresh _WS_ToItem copies are created (regression 514a45f)
    WL_UpdateFields(5001, Map("iconHicon", 9999), "test")
    AssertEq(gWS_SortOrderDirty, false, "SortOrderDirty: iconHicon does NOT dirty sort order")
    AssertEq(gWS_ContentDirty, true, "ContentDirty: iconHicon dirties display list content")

    ; Reset via GetDisplayList
    WL_GetDisplayList()

    ; Title change MUST set content dirty (was previously untracked, masked by z=0 churn)
    WL_UpdateFields(5001, Map("title", "New Title"), "test")
    AssertEq(gWS_SortOrderDirty, false, "SortOrderDirty: title does not dirty sort order")
    AssertEq(gWS_ContentDirty, true, "ContentDirty: title dirties display list content")

    ; Reset via GetDisplayList
    WL_GetDisplayList()

    ; Sort-affecting field (lastActivatedTick) should set both dirty flags
    WL_UpdateFields(5001, Map("lastActivatedTick", 999), "test")
    AssertEq(gWS_SortOrderDirty, true, "SortOrderDirty: lastActivatedTick sets true")
    AssertEq(gWS_ContentDirty, true, "ContentDirty: lastActivatedTick sets true")

    ; Reset via GetDisplayList
    WL_GetDisplayList()
    AssertEq(gWS_SortOrderDirty, false, "SortOrderDirty: reset after GetDisplayList")
    AssertEq(gWS_ContentDirty, false, "ContentDirty: reset after GetDisplayList")

    ; Filter-affecting field (isCloaked) should set sort dirty
    WL_UpdateFields(5001, Map("isCloaked", true), "test")
    AssertEq(gWS_SortOrderDirty, true, "SortOrderDirty: isCloaked sets true")

    ; Reset and test z field
    WL_GetDisplayList()
    WL_UpdateFields(5001, Map("z", 99), "test")
    AssertEq(gWS_SortOrderDirty, true, "SortOrderDirty: z change sets true")

    ; isFocused is content-only (not used by any sort comparator) — should set contentDirty, not sortDirty
    WL_GetDisplayList()
    WL_UpdateFields(5001, Map("isFocused", true), "test")
    AssertEq(gWS_SortOrderDirty, false, "SortOrderDirty: isFocused is content-only, not sort-affecting")
    AssertEq(gWS_ContentDirty, true, "ContentDirty: isFocused sets true")

    ; --- Regression test: icon update MUST produce fresh data in display list (514a45f) ---
    ; Reset isCloaked so window is visible in default display list (includeCloaked=false)
    WL_UpdateFields(5001, Map("isCloaked", false), "test")
    WL_GetDisplayList()  ; Reset — creates cached items with old icon
    WL_UpdateFields(5001, Map("iconHicon", 7777), "test")
    proj := WL_GetDisplayList()  ; Should use Path 2 — fresh _WS_ToItem
    foundIcon := false
    for _, item in proj.items {
        if (item.hwnd = 5001) {
            AssertEq(item.iconHicon, 7777, "Path 2 returns fresh iconHicon (regression 514a45f)")
            foundIcon := true
            break
        }
    }
    AssertEq(foundIcon, true, "Path 2 regression: hwnd 5001 found in display list")

    ; --- Regression test: title update MUST produce fresh data in display list ---
    WL_GetDisplayList()
    WL_UpdateFields(5001, Map("title", "Updated Title"), "test")
    proj := WL_GetDisplayList()
    foundTitle := false
    for _, item in proj.items {
        if (item.hwnd = 5001) {
            AssertEq(item.title, "Updated Title", "Path 2 returns fresh title")
            foundTitle := true
            break
        }
    }
    AssertEq(foundTitle, true, "Path 2 title: hwnd 5001 found in display list")

    ; --- Coverage test: every _WS_ToItem field must be tracked ---
    ; Prevents future regressions where a new field is added to _WS_ToItem
    ; but not tracked, silently causing stale cache data
    for _, field in DISPLAY_FIELDS {
        covered := gWS_SortAffectingFields.Has(field) || gWS_ContentOnlyFields.Has(field)
        AssertEq(covered, true, "Field '" field "' must be tracked in SortAffecting or ContentOnly")
    }

    ; Cleanup
    WL_RemoveWindow([5001, 5002], true)

    ; ============================================================
    ; GetDisplayList itemsMap Validation Tests
    ; ============================================================
    ; itemsMap is a Map<hwnd, item> returned by all cache paths.
    ; Consumed by icon cache pruning, live item removal, and MRU miss detection.
    ; If corrupt/missing, icon pruning deletes all cached icons and MRU breaks.
    Log("`n--- GetDisplayList itemsMap Validation Tests ---")

    WL_Init()
    WL_BeginScan()
    imRecs := []
    imRecs.Push(Map("hwnd", 6001, "title", "IM_A", "class", "T", "pid", 1,
                     "isVisible", true, "isCloaked", false, "isMinimized", false,
                     "z", 1, "lastActivatedTick", 100))
    imRecs.Push(Map("hwnd", 6002, "title", "IM_B", "class", "T", "pid", 2,
                     "isVisible", true, "isCloaked", false, "isMinimized", false,
                     "z", 2, "lastActivatedTick", 200))
    imRecs.Push(Map("hwnd", 6003, "title", "IM_C", "class", "T", "pid", 3,
                     "isVisible", true, "isCloaked", false, "isMinimized", false,
                     "z", 3, "lastActivatedTick", 300))
    WL_UpsertWindow(imRecs, "test")
    WL_EndScan()

    ; Path 3 (full rebuild) — cold cache
    proj := WL_GetDisplayList({ sort: "MRU" })
    AssertTrue(proj.HasOwnProp("itemsMap"), "itemsMap Path3: returned by GetDisplayList")
    AssertEq(proj.itemsMap.Count, proj.items.Length, "itemsMap Path3: count matches items")
    AssertTrue(proj.itemsMap.Has(6001), "itemsMap Path3: contains hwnd 6001")
    AssertTrue(proj.itemsMap.Has(6003), "itemsMap Path3: contains hwnd 6003")

    ; Path 1 (cache hit) — no changes between calls
    proj := WL_GetDisplayList({ sort: "MRU" })
    AssertTrue(proj.HasOwnProp("itemsMap"), "itemsMap Path1: returned on cache hit")
    AssertEq(proj.itemsMap.Count, proj.items.Length, "itemsMap Path1: count matches items")
    AssertTrue(proj.itemsMap.Has(6002), "itemsMap Path1: contains hwnd 6002")

    ; Path 2 (content-only refresh) — change non-sort field
    WL_UpdateFields(6001, Map("iconHicon", 8888), "test")
    proj := WL_GetDisplayList({ sort: "MRU" })
    AssertTrue(proj.HasOwnProp("itemsMap"), "itemsMap Path2: returned on content refresh")
    AssertEq(proj.itemsMap.Count, proj.items.Length, "itemsMap Path2: count matches items")
    AssertTrue(proj.itemsMap.Has(6001), "itemsMap Path2: contains updated hwnd 6001")

    ; Path 1.5 (MRU bump) — change MRU-only field
    WL_UpdateFields(6001, Map("lastActivatedTick", 500), "test")
    proj := WL_GetDisplayList({ sort: "MRU" })
    AssertTrue(proj.HasOwnProp("itemsMap"), "itemsMap Path1.5: returned on MRU bump")
    AssertEq(proj.itemsMap.Count, proj.items.Length, "itemsMap Path1.5: count matches items")
    AssertTrue(proj.itemsMap.Has(6001), "itemsMap Path1.5: contains bumped hwnd 6001")

    ; Verify itemsMap entries reference the same objects as items array
    for _, item in proj.items {
        AssertTrue(proj.itemsMap.Has(item.hwnd), "itemsMap consistency: array item hwnd " item.hwnd " exists in map")
    }

    ; Cleanup
    WL_RemoveWindow([6001, 6002, 6003], true)

    ; ============================================================
    ; SetCurrentWorkspace Callback Notification Tests
    ; ============================================================
    ; WL_SetCurrentWorkspace fires gWS_OnWorkspaceChanged when workspace changes.
    ; This is the sole mechanism for the GUI to learn about workspace switches.
    Log("`n--- SetCurrentWorkspace Callback Notification Tests ---")

    WL_Init()

    ; Wire a test callback
    callbackFired := false
    WL_SetCallbacks(0, () => (callbackFired := true))

    ; Add windows so SetCurrentWorkspace has work to do
    WL_BeginScan()
    cbRecs := []
    cbRecs.Push(Map("hwnd", 6101, "title", "CB1", "class", "T", "pid", 1,
                     "isVisible", true, "isCloaked", false, "isMinimized", false,
                     "z", 1, "workspaceName", "Alpha"))
    cbRecs.Push(Map("hwnd", 6102, "title", "CB2", "class", "T", "pid", 2,
                     "isVisible", true, "isCloaked", false, "isMinimized", false,
                     "z", 2, "workspaceName", "Beta"))
    WL_UpsertWindow(cbRecs, "test")
    WL_EndScan()

    ; Workspace change fires callback
    WL_SetCurrentWorkspace("", "Alpha")
    AssertEq(callbackFired, true, "SetCurrentWorkspace fires workspace callback on change")

    ; Same workspace name does NOT fire callback (no-op)
    callbackFired := false
    WL_SetCurrentWorkspace("", "Alpha")
    AssertEq(callbackFired, false, "SetCurrentWorkspace does NOT fire callback on no-op")

    ; Different workspace fires callback again
    callbackFired := false
    WL_SetCurrentWorkspace("", "Beta")
    AssertEq(callbackFired, true, "SetCurrentWorkspace fires callback on second change")

    ; Cleanup
    WL_SetCallbacks(0, 0)
    WL_RemoveWindow([6101, 6102], true)

    ; Test: WL_SetCurrentWorkspace updates all windows
    Log("Testing SetCurrentWorkspace consistency...")

    WL_Init()
    global gWS_Meta

    WL_BeginScan()
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
    WL_UpsertWindow(recs, "test")
    WL_EndScan()

    startRev := _WL_GetRev()
    flipped := WL_SetCurrentWorkspace("", "Main")

    AssertEq(gWS_Store[1001].isOnCurrentWorkspace, true, "Main window on current")
    AssertEq(gWS_Store[1002].isOnCurrentWorkspace, false, "Other window NOT on current")
    AssertEq(gWS_Store[1003].isOnCurrentWorkspace, true, "Unmanaged floats to current")
    AssertEq(gWS_Meta["currentWSName"], "Main", "Meta updated")
    AssertEq(_WL_GetRev(), startRev + 1, "Rev bumped exactly once")

    ; Return value: boolean indicating whether any windows flipped
    ; Default isOnCurrentWorkspace is true (from _WS_NewRecord).
    ; After SetCurrentWorkspace("Main"): 1001 stays true, 1002 flips false, 1003 stays true
    AssertEq(flipped, true, "SetCurrentWorkspace return: some windows flipped")

    ; Switch workspace — both Main and Other flip
    flipped2 := WL_SetCurrentWorkspace("", "Other")
    AssertEq(gWS_Store[1001].isOnCurrentWorkspace, false, "Main now NOT current")
    AssertEq(gWS_Store[1002].isOnCurrentWorkspace, true, "Other now current")
    AssertEq(flipped2, true, "SetCurrentWorkspace switch: windows flipped")

    ; Same-name no-op (no rev bump, empty return)
    revBefore := _WL_GetRev()
    flipped3 := WL_SetCurrentWorkspace("", "Other")  ; Same name as currently set
    AssertEq(_WL_GetRev(), revBefore, "SetCurrentWorkspace same name: no-op")
    AssertEq(flipped3, false, "SetCurrentWorkspace same name: returns false")

    ; Cleanup
    WL_RemoveWindow([1001, 1002, 1003], true)

    ; ============================================================
    ; BatchUpdateFields Contract Tests
    ; ============================================================
    ; BatchUpdateFields applies N patches with a single rev bump.
    Log("`n--- BatchUpdateFields Contract Tests ---")

    WL_Init()
    WL_BeginScan()
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
    WL_UpsertWindow(batchRecs, "test")
    WL_EndScan()

    ; Reset dirty flags and capture rev before batch
    WL_GetDisplayList()
    batchRevBefore := _WL_GetRev()

    ; Batch: patch 2 windows with different fields (title = content-only, z = sort-affecting)
    patches := Map()
    patches[7001] := Map("title", "BatchUpdated1")     ; Content-only change
    patches[7002] := Map("z", 99)                       ; Sort-affecting change
    batchResult := WL_BatchUpdateFields(patches, "test")

    ; Assertions: return value
    AssertEq(batchResult.changed, 2, "BatchUpdateFields: changed count = 2")

    ; Assertions: rev bumped exactly once (not once per patch)
    AssertEq(_WL_GetRev(), batchRevBefore + 1, "BatchUpdateFields: rev bumped exactly once")

    ; Assertions: both windows updated
    AssertEq(gWS_Store[7001].title, "BatchUpdated1", "BatchUpdateFields: window 1 title updated")
    AssertEq(gWS_Store[7002].z, 99, "BatchUpdateFields: window 2 z updated")

    ; Assertions: third window untouched
    AssertEq(gWS_Store[7003].title, "Batch3", "BatchUpdateFields: window 3 title unchanged")

    ; Assertions: dirty flags correct (z is sort-affecting → both dirty)
    AssertEq(gWS_SortOrderDirty, true, "BatchUpdateFields: sort dirty (z changed)")
    AssertEq(gWS_ContentDirty, true, "BatchUpdateFields: content dirty")

    ; Test: content-only batch does NOT set sort dirty
    WL_GetDisplayList()  ; Reset dirty flags
    patches2 := Map()
    patches2[7001] := Map("iconHicon", 5555)
    WL_BatchUpdateFields(patches2, "test")
    AssertEq(gWS_SortOrderDirty, false, "BatchUpdateFields content-only: sort NOT dirty")
    AssertEq(gWS_ContentDirty, true, "BatchUpdateFields content-only: content dirty")

    ; Test: patching non-existent hwnd is silently skipped
    WL_GetDisplayList()
    batchRevBefore2 := _WL_GetRev()
    patches3 := Map()
    patches3[99999] := Map("title", "Ghost")
    batchResult3 := WL_BatchUpdateFields(patches3, "test")
    AssertEq(batchResult3.changed, 0, "BatchUpdateFields: non-existent hwnd skipped")
    AssertEq(_WL_GetRev(), batchRevBefore2, "BatchUpdateFields: no rev bump when nothing changed")

    ; Cleanup
    WL_RemoveWindow([7001, 7002, 7003], true)

    ; ============================================================
    ; BatchUpdateFields MRU-Only Tracking Tests
    ; ============================================================
    ; BatchUpdateFields tracks batchMruOnly across all patches.
    ; When ALL patches change ONLY MRU fields (lastActivatedTick), it sets
    ; gWS_MRUBumpOnly=true so GetDisplayList can use Path 1.5 (incremental).
    ; When ANY patch changes a non-MRU sort field, batchMruOnly must be false.
    Log("`n--- BatchUpdateFields MRU-Only Tracking Tests ---")

    WL_Init()
    WL_BeginScan()
    mruBatchRecs := []
    mruBatchRecs.Push(Map("hwnd", 8001, "title", "MRUBatch_A", "class", "T", "pid", 1,
                     "isVisible", true, "isCloaked", false, "isMinimized", false,
                     "z", 1, "lastActivatedTick", 100))
    mruBatchRecs.Push(Map("hwnd", 8002, "title", "MRUBatch_B", "class", "T", "pid", 2,
                     "isVisible", true, "isCloaked", false, "isMinimized", false,
                     "z", 2, "lastActivatedTick", 200))
    mruBatchRecs.Push(Map("hwnd", 8003, "title", "MRUBatch_C", "class", "T", "pid", 3,
                     "isVisible", true, "isCloaked", false, "isMinimized", false,
                     "z", 3, "lastActivatedTick", 300))
    WL_UpsertWindow(mruBatchRecs, "test")
    WL_EndScan()

    ; Prime cache (Path 3) — order: C(300), B(200), A(100)
    proj := WL_GetDisplayList({ sort: "MRU" })
    AssertEq(proj.items.Length, 3, "BatchMRU setup: 3 items")
    AssertEq(proj.items[1].hwnd, 8003, "BatchMRU setup: C first (tick 300)")

    ; MRU-only batch with SINGLE item: bump A tick, no other sort fields.
    ; Single-item batch avoids Path 1.5 sort invariant fallback (multi-item
    ; batches can break intermediate sort order, causing valid fallback to Path 3).
    mruPatches := Map()
    mruPatches[8001] := Map("lastActivatedTick", 500)  ; A → front
    WL_BatchUpdateFields(mruPatches, "test")
    AssertEq(gWS_MRUBumpOnly, true, "BatchMRU: MRUBumpOnly true for MRU-only batch")
    AssertEq(gWS_SortOrderDirty, true, "BatchMRU: sort dirty after MRU batch")

    ; GetDisplayList should use Path 1.5 → correct sort
    projMru := WL_GetDisplayList({ sort: "MRU" })
    AssertEq(projMru.cachePath, "mru", "BatchMRU: Path 1.5 used for single-item MRU batch")
    AssertEq(projMru.items[1].hwnd, 8001, "BatchMRU: A first (tick 500)")
    AssertEq(projMru.items[2].hwnd, 8003, "BatchMRU: C second (tick 300)")
    AssertEq(projMru.items[3].hwnd, 8002, "BatchMRU: B third (tick 200)")

    ; Multi-item MRU batch: flags are set correctly even though Path 1.5
    ; may fall through to Path 3 due to sort invariant check (correct behavior).
    mruPatches2 := Map()
    mruPatches2[8002] := Map("lastActivatedTick", 600)
    mruPatches2[8003] := Map("lastActivatedTick", 550)
    WL_BatchUpdateFields(mruPatches2, "test")
    AssertEq(gWS_MRUBumpOnly, true, "BatchMRU multi: MRUBumpOnly true for multi-item MRU batch")

    ; Verify correct sort order regardless of which path was used
    projMru2 := WL_GetDisplayList({ sort: "MRU" })
    AssertEq(projMru2.items[1].hwnd, 8002, "BatchMRU multi: B first (tick 600)")
    AssertEq(projMru2.items[2].hwnd, 8003, "BatchMRU multi: C second (tick 550)")
    AssertEq(projMru2.items[3].hwnd, 8001, "BatchMRU multi: A third (tick 500)")

    ; Mixed batch: MRU tick + z (non-MRU sort field) → MRUBumpOnly must be false
    mixedPatches := Map()
    mixedPatches[8003] := Map("lastActivatedTick", 700)  ; MRU field (highest)
    mixedPatches[8001] := Map("z", 99)                    ; Non-MRU sort field
    WL_BatchUpdateFields(mixedPatches, "test")
    AssertEq(gWS_MRUBumpOnly, false, "BatchMRU: MRUBumpOnly false for mixed batch (tick+z)")

    ; GetDisplayList should use Path 3 (full rebuild), not Path 1.5
    projMixed := WL_GetDisplayList({ sort: "MRU" })
    AssertEq(projMixed.items[1].hwnd, 8003, "BatchMRU mixed: C first (tick 700)")

    ; Cleanup
    WL_RemoveWindow([8001, 8002, 8003], true)

    ; ============================================================
    ; EndScan: Real Window Survives (IsWindow=true skips toRemove)
    ; ============================================================
    ; When a window is not re-upserted during a scan but IsWindow still returns true,
    ; it should NOT be added to toRemove in Phase 1 (line 183). This means a still-valid
    ; window stays in the store even after TTL expires — it's just not removed.
    ; The next WinEnum scan that re-upserts it will reset its presence flags.
    ;
    ; The Phase 2 recovery branch (lines 226-232) handles a narrower race: a window that
    ; failed IsWindow in Phase 1 but passes it in Phase 2 (flickered between the two checks).
    ; That race condition is untestable without DllCall mocking.
    Log("`n--- EndScan Real Window Survival Tests ---")

    WL_Init()

    ; Use the test process's own hwnd — guaranteed to pass IsWindow()
    testHwnd := A_ScriptHwnd + 0

    ; Add our hwnd to the store via upsert
    WL_BeginScan()
    reappearRec := Map("hwnd", testHwnd, "title", "TestProcess", "class", "TestClass",
                       "pid", ProcessExist(), "isVisible", true, "isCloaked", false,
                       "isMinimized", false, "z", 1, "lastActivatedTick", A_TickCount)
    WL_UpsertWindow([reappearRec], "test")
    WL_EndScan()

    ; Verify it's in the store
    AssertTrue(gWS_Store.Has(testHwnd), "RealWin setup: test hwnd in store")
    AssertEq(gWS_Store[testHwnd].present, true, "RealWin setup: present=true")

    ; Scan cycle 1: window not re-upserted → marks it as MISSING
    WL_BeginScan()
    WL_EndScan(0)  ; graceMs=0 so TTL expires immediately
    AssertTrue(gWS_Store.Has(testHwnd), "RealWin cycle1: window still in store (marked missing)")
    AssertEq(gWS_Store[testHwnd].present, false, "RealWin cycle1: present=false")

    ; Scan cycle 2: TTL expired BUT IsWindow=true → window NOT removed (stays in store)
    ; Phase 1 skips it because IsWindow returns true (line 183: !IsWindow is false → no push)
    WL_BeginScan()
    result := WL_EndScan(0)
    AssertTrue(gWS_Store.Has(testHwnd), "RealWin cycle2: real window NOT removed (IsWindow=true)")
    AssertEq(result.removed, 0, "RealWin cycle2: removed=0 (real window survives)")

    ; Re-upsert recovers the window (simulates next WinEnum scan finding it again)
    WL_BeginScan()
    WL_UpsertWindow([reappearRec], "test")
    WL_EndScan()
    AssertEq(gWS_Store[testHwnd].present, true, "RealWin re-upsert: present=true after re-discovery")

    ; Cleanup
    WL_RemoveWindow([testHwnd], true)

    ; ============================================================
    ; DisplayList Cache Stale-Ref Fallback Tests (Path 2 → Path 3)
    ; ============================================================
    ; Path 2 (content-only refresh) checks rec.present on cached sorted refs.
    ; If a stale ref is found, it falls through to Path 3 (full rebuild).
    Log("`n--- DisplayList Cache Stale-Ref Fallback Tests ---")

    global gWS_DLCache_SortedRecs
    WL_Init()
    WL_BeginScan()
    staleRecs := []
    staleRecs.Push(Map("hwnd", 8001, "title", "StaleTest1", "class", "T", "pid", 1,
                       "isVisible", true, "isCloaked", false, "isMinimized", false,
                       "z", 1, "lastActivatedTick", 100))
    staleRecs.Push(Map("hwnd", 8002, "title", "StaleTest2", "class", "T", "pid", 2,
                       "isVisible", true, "isCloaked", false, "isMinimized", false,
                       "z", 2, "lastActivatedTick", 200))
    WL_UpsertWindow(staleRecs, "test")
    WL_EndScan()

    ; Prime the cache (Path 3 runs, populates cache)
    proj1 := WL_GetDisplayList()
    AssertEq(proj1.items.Length, 2, "StaleRef setup: 2 items in initial display list")
    AssertEq(gWS_SortOrderDirty, false, "StaleRef setup: sort clean after display list")
    AssertEq(gWS_ContentDirty, false, "StaleRef setup: content clean after display list")

    ; Simulate stale ref: mark one cached record as not present
    ; In production, this shouldn't happen (removal sets SortOrderDirty), but the defensive
    ; check exists in case of edge cases
    for _, cachedRec in gWS_DLCache_SortedRecs {
        if (cachedRec.hwnd = 8002) {
            cachedRec.present := false
            break
        }
    }

    ; Force Path 2 entry: content dirty + sort clean
    gWS_ContentDirty := true
    gWS_SortOrderDirty := false

    ; Get display list — Path 2 should detect stale ref, fall through to Path 3
    proj2 := WL_GetDisplayList()

    ; Path 3 rebuilds from live store — only present window should appear
    AssertEq(proj2.items.Length, 1, "StaleRef fallback: Path 3 returns only present window")
    AssertEq(proj2.items[1].hwnd, 8001, "StaleRef fallback: correct window survived")

    ; Cleanup
    WL_RemoveWindow([8001, 8002], true)

    ; ============================================================
    ; Path 1.5: MRU Bump Optimization Tests
    ; ============================================================
    ; When only MRU fields change (lastActivatedTick/isFocused), Path 1.5 does an
    ; incremental move-to-front instead of full Path 3 rebuild.
    ; Verifies: flag tracking, correct output order, fallback on mixed changes.
    Log("`n--- Path 1.5 MRU Bump Tests ---")

    global gWS_MRUBumpOnly

    WL_Init()
    WL_BeginScan()
    mruRecs := []
    mruRecs.Push(Map("hwnd", 9001, "title", "MRU_A", "class", "T", "pid", 1,
                     "isVisible", true, "isCloaked", false, "isMinimized", false,
                     "z", 1, "lastActivatedTick", 100))
    mruRecs.Push(Map("hwnd", 9002, "title", "MRU_B", "class", "T", "pid", 2,
                     "isVisible", true, "isCloaked", false, "isMinimized", false,
                     "z", 2, "lastActivatedTick", 200))
    mruRecs.Push(Map("hwnd", 9003, "title", "MRU_C", "class", "T", "pid", 3,
                     "isVisible", true, "isCloaked", false, "isMinimized", false,
                     "z", 3, "lastActivatedTick", 300))
    WL_UpsertWindow(mruRecs, "test")
    WL_EndScan()

    ; Prime cache — MRU order should be C(300), B(200), A(100)
    proj := WL_GetDisplayList({ sort: "MRU" })
    AssertEq(proj.items.Length, 3, "Path1.5 setup: 3 items")
    AssertEq(proj.items[1].hwnd, 9003, "Path1.5 setup: C first (tick 300)")
    AssertEq(gWS_MRUBumpOnly, false, "Path1.5 setup: MRUBumpOnly reset after display list")

    ; MRU-only change: bump A to front
    WL_UpdateFields(9001, Map("lastActivatedTick", 500), "test")
    AssertEq(gWS_SortOrderDirty, true, "Path1.5: sort dirty after MRU bump")
    AssertEq(gWS_MRUBumpOnly, true, "Path1.5: MRUBumpOnly true for MRU-only change")

    ; GetDisplayList should use Path 1.5 and return A first
    proj2 := WL_GetDisplayList({ sort: "MRU" })
    AssertEq(proj2.items[1].hwnd, 9001, "Path1.5: A moved to front (tick 500)")
    AssertEq(proj2.items[2].hwnd, 9003, "Path1.5: C second (tick 300)")
    AssertEq(proj2.items[3].hwnd, 9002, "Path1.5: B third (tick 200)")

    ; Verify dirty flags cleared
    AssertEq(gWS_SortOrderDirty, false, "Path1.5: sort dirty cleared after display list")
    AssertEq(gWS_MRUBumpOnly, false, "Path1.5: MRUBumpOnly cleared after display list")

    ; Mixed change: MRU tick + non-MRU sort field → MRUBumpOnly must be false
    WL_UpdateFields(9002, Map("lastActivatedTick", 600, "z", 99), "test")
    AssertEq(gWS_MRUBumpOnly, false, "Path1.5: MRUBumpOnly false for mixed change (tick+z)")

    ; Display list still correct (falls through to Path 3)
    proj3 := WL_GetDisplayList({ sort: "MRU" })
    AssertEq(proj3.items[1].hwnd, 9002, "Path1.5 fallback: B first after mixed change (tick 600)")

    ; Path 1.5 selective refresh: dirty item gets fresh data, clean items reuse cache
    WL_GetDisplayList({ sort: "MRU" })  ; Reset
    WL_UpdateFields(9002, Map("lastActivatedTick", 700, "iconHicon", 4242), "test")
    proj4 := WL_GetDisplayList({ sort: "MRU" })
    AssertEq(proj4.items[1].hwnd, 9002, "Path1.5 refresh: B moved to front")
    found := false
    for _, item in proj4.items {
        if (item.hwnd = 9002) {
            AssertEq(item.iconHicon, 4242, "Path1.5 refresh: dirty item has fresh iconHicon")
            found := true
            break
        }
    }
    AssertEq(found, true, "Path1.5 refresh: B found in display list")

    ; Cleanup
    WL_RemoveWindow([9001, 9002, 9003], true)

    ; --- hwndsOnly through cached paths (Path 1, 1.5, 2) ---
    Log("`n--- hwndsOnly Through Cached Paths ---")

    WL_Init()
    WL_BeginScan()
    hwndsRecs := []
    hwndsRecs.Push(Map("hwnd", 9001, "title", "HO_A", "class", "T", "pid", 1,
                     "isVisible", true, "isCloaked", false, "isMinimized", false,
                     "z", 1, "lastActivatedTick", 100))
    hwndsRecs.Push(Map("hwnd", 9002, "title", "HO_B", "class", "T", "pid", 2,
                     "isVisible", true, "isCloaked", false, "isMinimized", false,
                     "z", 2, "lastActivatedTick", 200))
    hwndsRecs.Push(Map("hwnd", 9003, "title", "HO_C", "class", "T", "pid", 3,
                     "isVisible", true, "isCloaked", false, "isMinimized", false,
                     "z", 3, "lastActivatedTick", 300))
    WL_UpsertWindow(hwndsRecs, "test")
    WL_EndScan()

    ; Path 3 (cold cache) — baseline
    proj := WL_GetDisplayList({ sort: "MRU", columns: "hwndsOnly" })
    AssertEq(proj.HasOwnProp("hwnds"), true, "hwndsOnly Path3: has hwnds")
    AssertEq(proj.HasOwnProp("items"), false, "hwndsOnly Path3: no items")
    AssertEq(proj.hwnds.Length, 3, "hwndsOnly Path3: 3 hwnds")

    ; Path 1 (cache hit) — immediate re-call, no changes
    proj := WL_GetDisplayList({ sort: "MRU", columns: "hwndsOnly" })
    AssertEq(proj.HasOwnProp("hwnds"), true, "hwndsOnly Path1: has hwnds")
    AssertEq(proj.HasOwnProp("items"), false, "hwndsOnly Path1: no items")
    AssertEq(proj.hwnds.Length, 3, "hwndsOnly Path1: 3 hwnds")

    ; Path 2 (content refresh) — change non-sort field
    WL_UpdateFields(9001, Map("processName", "updated.exe"), "test")
    proj := WL_GetDisplayList({ sort: "MRU", columns: "hwndsOnly" })
    AssertEq(proj.HasOwnProp("hwnds"), true, "hwndsOnly Path2: has hwnds")
    AssertEq(proj.HasOwnProp("items"), false, "hwndsOnly Path2: no items")
    AssertEq(proj.hwnds.Length, 3, "hwndsOnly Path2: 3 hwnds")

    ; Path 1.5 (MRU bump) — change lastActivatedTick only
    WL_UpdateFields(9001, Map("lastActivatedTick", 500), "test")
    proj := WL_GetDisplayList({ sort: "MRU", columns: "hwndsOnly" })
    AssertEq(proj.HasOwnProp("hwnds"), true, "hwndsOnly Path1.5: has hwnds")
    AssertEq(proj.HasOwnProp("items"), false, "hwndsOnly Path1.5: no items")
    AssertEq(proj.hwnds.Length, 3, "hwndsOnly Path1.5: 3 hwnds")

    WL_RemoveWindow([9001, 9002, 9003], true)

    ; --- Path 1.5 multi-MRU-bump sort invariant fallback ---
    Log("`n--- Path 1.5 Multi-MRU-Bump Invariant Fallback ---")

    WL_Init()
    WL_BeginScan()
    invRecs := []
    invRecs.Push(Map("hwnd", 9001, "title", "INV_A", "class", "T", "pid", 1,
                     "isVisible", true, "isCloaked", false, "isMinimized", false,
                     "z", 1, "lastActivatedTick", 100))
    invRecs.Push(Map("hwnd", 9002, "title", "INV_B", "class", "T", "pid", 2,
                     "isVisible", true, "isCloaked", false, "isMinimized", false,
                     "z", 2, "lastActivatedTick", 200))
    invRecs.Push(Map("hwnd", 9003, "title", "INV_C", "class", "T", "pid", 3,
                     "isVisible", true, "isCloaked", false, "isMinimized", false,
                     "z", 3, "lastActivatedTick", 300))
    invRecs.Push(Map("hwnd", 9004, "title", "INV_D", "class", "T", "pid", 4,
                     "isVisible", true, "isCloaked", false, "isMinimized", false,
                     "z", 4, "lastActivatedTick", 400))
    WL_UpsertWindow(invRecs, "test")
    WL_EndScan()

    ; Prime cache — MRU order: D(400), C(300), B(200), A(100)
    proj := WL_GetDisplayList({ sort: "MRU" })
    AssertEq(proj.items[1].hwnd, 9004, "InvFallback setup: D first (tick 400)")

    ; Bump BOTH A and B past D without calling GetDisplayList between
    WL_UpdateFields(9001, Map("lastActivatedTick", 500), "test")
    WL_UpdateFields(9002, Map("lastActivatedTick", 600), "test")

    ; Path 1.5 moves highest-tick item (B=600) to front, then checks invariant:
    ; [B(600), D(400), C(300), A(500)] — D(400) > C(300) OK, but C(300) < A(500) FAILS
    ; Falls through to Path 3 for correct full sort
    proj := WL_GetDisplayList({ sort: "MRU" })
    AssertEq(proj.items[1].hwnd, 9002, "InvFallback: B first (tick 600)")
    AssertEq(proj.items[2].hwnd, 9001, "InvFallback: A second (tick 500)")
    AssertEq(proj.items[3].hwnd, 9004, "InvFallback: D third (tick 400)")
    AssertEq(proj.items[4].hwnd, 9003, "InvFallback: C fourth (tick 300)")

    WL_RemoveWindow([9001, 9002, 9003, 9004], true)

    ; ============================================================
    ; TitleSortActive Tests (Issue 5)
    ; ============================================================
    ; "title" is content-only by default (MRU sort), but promoted to sort-affecting
    ; when Title sort mode is active. Verifies the flag is set/cleared by GetDisplayList
    ; and that dirty tracking responds correctly.
    Log("`n--- TitleSortActive Tests ---")

    global gWS_TitleSortActive

    WL_Init()
    WL_BeginScan()
    titleRecs := []
    titleRecs.Push(Map("hwnd", 9101, "title", "Alpha", "class", "T", "pid", 1,
                       "isVisible", true, "isCloaked", false, "isMinimized", false,
                       "z", 1, "lastActivatedTick", 100))
    titleRecs.Push(Map("hwnd", 9102, "title", "Beta", "class", "T", "pid", 2,
                       "isVisible", true, "isCloaked", false, "isMinimized", false,
                       "z", 2, "lastActivatedTick", 200))
    WL_UpsertWindow(titleRecs, "test")
    WL_EndScan()

    ; Default (MRU sort): title is content-only
    WL_GetDisplayList({ sort: "MRU" })
    AssertEq(gWS_TitleSortActive, false, "TitleSort: inactive in MRU mode")
    WL_UpdateFields(9101, Map("title", "Alpha2"), "test")
    AssertEq(gWS_SortOrderDirty, false, "TitleSort: title change is content-only in MRU mode")
    AssertEq(gWS_ContentDirty, true, "TitleSort: title change sets content dirty in MRU mode")

    ; Switch to Title sort: title becomes sort-affecting
    WL_GetDisplayList({ sort: "Title" })
    AssertEq(gWS_TitleSortActive, true, "TitleSort: active after Title sort display list")
    WL_UpdateFields(9101, Map("title", "Zulu"), "test")
    AssertEq(gWS_SortOrderDirty, true, "TitleSort: title change sets sort dirty in Title mode")

    ; Verify display list reflects new title order (Zulu sorts after Beta)
    proj := WL_GetDisplayList({ sort: "Title" })
    AssertEq(proj.items[1].hwnd, 9102, "TitleSort: Beta first alphabetically")
    AssertEq(proj.items[2].hwnd, 9101, "TitleSort: Zulu second alphabetically")

    ; Switch back to MRU: title reverts to content-only
    WL_GetDisplayList({ sort: "MRU" })
    AssertEq(gWS_TitleSortActive, false, "TitleSort: deactivated after MRU sort display list")
    WL_UpdateFields(9101, Map("title", "Alpha3"), "test")
    AssertEq(gWS_SortOrderDirty, false, "TitleSort: title change is content-only again in MRU mode")

    ; Cleanup
    WL_RemoveWindow([9101, 9102], true)

    ; ============================================================
    ; Dirty-Tracking Contract Tests
    ; ============================================================
    ; Contract: any store mutation that modifies display-visible fields
    ; MUST mark gWS_DirtyHwnds. Pure data-layer tests — no mocking, no OS deps.
    ; Would have caught: Bugs #2 (WL_UpdateProcessName) and #3 (WL_UpsertWindow)
    Log("`n--- Dirty-Tracking Contract Tests ---")

    ; Test: WL_UpsertWindow marks DirtyHwnds on field change
    WL_Init()
    WL_BeginScan()
    dtRec := Map("hwnd", 99901, "title", "Original", "class", "C", "pid", 1,
                 "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 1)
    WL_UpsertWindow([dtRec], "test")
    WL_EndScan()
    gWS_DirtyHwnds := Map()  ; clear

    dtRec2 := Map("hwnd", 99901, "title", "Changed", "class", "C", "pid", 1,
                  "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 1)
    WL_UpsertWindow([dtRec2], "test")
    AssertEq(gWS_DirtyHwnds.Has(99901), true, "DirtyContract: UpsertWindow marks dirty on title change")

    ; Test: WL_UpsertWindow does NOT mark dirty when no fields changed
    gWS_DirtyHwnds := Map()
    WL_UpsertWindow([dtRec2], "test")  ; same data again
    AssertEq(gWS_DirtyHwnds.Has(99901), false, "DirtyContract: UpsertWindow no dirty when unchanged")

    ; Test: WL_UpdateProcessName marks DirtyHwnds
    gWS_DirtyHwnds := Map()
    WL_UpdateProcessName(1, "notepad.exe")
    hasDirty := false
    for hwnd, _ in gWS_DirtyHwnds
        hasDirty := true
    AssertEq(hasDirty, true, "DirtyContract: UpdateProcessName marks dirty hwnd")

    ; Test: WL_UpdateFields marks DirtyHwnds
    gWS_DirtyHwnds := Map()
    WL_UpdateFields(99901, Map("title", "Updated"), "test")
    AssertEq(gWS_DirtyHwnds.Has(99901), true, "DirtyContract: UpdateFields marks dirty")

    ; Test: WL_RemoveWindow sets SortOrderDirty (no per-hwnd dirty — window is deleted)
    gWS_SortOrderDirty := false
    WL_RemoveWindow([99901], true)
    AssertEq(gWS_SortOrderDirty, true, "DirtyContract: RemoveWindow marks sort dirty")

    ; ============================================================
    ; OptsKey Cache Invalidation Tests
    ; ============================================================
    ; Verifies display list cache invalidates when sort mode or filter changes.
    ; Prevents a bug where switching sort modes returns stale-sorted data.
    Log("`n--- OptsKey Cache Invalidation Tests ---")

    WL_Init()
    WL_BeginScan()
    okRecs := []
    okRecs.Push(Map("hwnd", 9201, "title", "Charlie", "class", "T", "pid", 1,
                     "isVisible", true, "isCloaked", false, "isMinimized", false,
                     "z", 1, "lastActivatedTick", 300))
    okRecs.Push(Map("hwnd", 9202, "title", "Alpha", "class", "T", "pid", 2,
                     "isVisible", true, "isCloaked", false, "isMinimized", false,
                     "z", 2, "lastActivatedTick", 100))
    okRecs.Push(Map("hwnd", 9203, "title", "Bravo", "class", "T", "pid", 3,
                     "isVisible", true, "isCloaked", false, "isMinimized", false,
                     "z", 3, "lastActivatedTick", 200))
    WL_UpsertWindow(okRecs, "test")
    WL_EndScan()

    ; Get MRU-sorted list: Charlie(300) > Bravo(200) > Alpha(100)
    projMRU := WL_GetDisplayList({ sort: "MRU" })
    AssertEq(projMRU.items[1].hwnd, 9201, "OptsKey MRU: Charlie first (tick 300)")
    AssertEq(projMRU.items[2].hwnd, 9203, "OptsKey MRU: Bravo second (tick 200)")
    AssertEq(projMRU.items[3].hwnd, 9202, "OptsKey MRU: Alpha third (tick 100)")

    ; Switch to Title sort: Alpha < Bravo < Charlie (different order!)
    projTitle := WL_GetDisplayList({ sort: "Title" })
    AssertEq(projTitle.items[1].hwnd, 9202, "OptsKey Title: Alpha first")
    AssertEq(projTitle.items[2].hwnd, 9203, "OptsKey Title: Bravo second")
    AssertEq(projTitle.items[3].hwnd, 9201, "OptsKey Title: Charlie third")

    ; Switch back to MRU: must NOT return Title-sorted cache
    projMRU2 := WL_GetDisplayList({ sort: "MRU" })
    AssertEq(projMRU2.items[1].hwnd, 9201, "OptsKey MRU->Title->MRU: Charlie first again")
    AssertEq(projMRU2.items[2].hwnd, 9203, "OptsKey MRU->Title->MRU: Bravo second again")
    AssertEq(projMRU2.items[3].hwnd, 9202, "OptsKey MRU->Title->MRU: Alpha third again")

    ; Same opts reuses cache (verify by checking dirty flags stay clean)
    projMRU3 := WL_GetDisplayList({ sort: "MRU" })
    AssertEq(projMRU3.items[1].hwnd, 9201, "OptsKey cache hit: same opts returns same result")
    AssertEq(gWS_SortOrderDirty, false, "OptsKey cache hit: sort dirty stays false")

    ; Filter change: currentWorkspaceOnly toggle invalidates cache
    ; Set workspace names FIRST, then call SetCurrentWorkspace to recalculate isOnCurrentWorkspace
    WL_UpdateFields(9201, Map("workspaceName", "WS_A"), "test")
    WL_UpdateFields(9202, Map("workspaceName", "WS_B"), "test")
    WL_UpdateFields(9203, Map("workspaceName", "WS_A"), "test")
    WL_SetCurrentWorkspace("", "WS_A")

    projAll := WL_GetDisplayList({ sort: "MRU", currentWorkspaceOnly: false })
    AssertEq(projAll.items.Length, 3, "OptsKey filter: all mode returns 3 items")

    projCurrent := WL_GetDisplayList({ sort: "MRU", currentWorkspaceOnly: true })
    AssertEq(projCurrent.items.Length, 2, "OptsKey filter: currentOnly returns 2 items (WS_A only)")

    ; Cleanup
    WL_RemoveWindow([9201, 9202, 9203], true)
}
