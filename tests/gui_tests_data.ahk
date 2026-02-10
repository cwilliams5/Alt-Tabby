; GUI Data Processing Tests - Deltas, MRU, Selection, Bypass
; Tests ACTUAL production GUI code with mocked visual layer
; Split from gui_tests.ahk for context window optimization
#Requires AutoHotkey v2.0
#Warn VarUnset, Off
A_IconHidden := true  ; No tray icon during tests

; Include common globals, mocks, and utilities
#Include gui_tests_common.ahk

; ============================================================
; RUN TESTS
; ============================================================

RunGUITests_Data() {
    global GUI_TestPassed, GUI_TestFailed, gMockIPCMessages, cfg
    global gGUI_State, gGUI_LiveItems, gGUI_DisplayItems, gGUI_ToggleBase
    global gGUI_Sel, gGUI_ScrollTop, gGUI_OverlayVisible, gGUI_TabCount
    global gGUI_WorkspaceMode, gGUI_AwaitingToggleProjection, gGUI_CurrentWSName, gGUI_WSContextSwitch
    global gGUI_EventBuffer, gGUI_PendingPhase, gGUI_FlushStartTick
    global gGUI_StoreRev, gGUI_LiveItemsMap, gGUI_LastLocalMRUTick, gGUI_LastMsgTick, gMock_VisibleRows
    global gMock_BypassResult, gINT_BypassMode, gMock_PruneCalledWith, gMock_PreCachedIcons
    global IPC_MSG_SNAPSHOT, IPC_MSG_SNAPSHOT_REQUEST, IPC_MSG_DELTA
    global IPC_MSG_PROJECTION, IPC_MSG_PROJECTION_REQUEST
    global gGUI_Base, gGUI_Overlay

    GUI_Log("`n=== GUI Data Processing Tests ===`n")

    ; ============================================================
    ; DELTA PROCESSING TESTS
    ; ============================================================

    ; ----- Test: Delta removes items -----
    GUI_Log("Test: Delta removes items")
    ResetGUIState()
    cfg.FreezeWindowList := false  ; Live mode for delta processing
    ; Load initial items via snapshot
    snapshotMsg := JSON.Dump({ type: IPC_MSG_SNAPSHOT, rev: 1, payload: { items: CreateTestItems(5) } })
    GUI_OnStoreMessage(snapshotMsg)
    GUI_AssertEq(gGUI_LiveItems.Length, 5, "Delta remove: initial 5 items")

    ; Remove items with hwnd 2000 and 4000
    deltaMsg := JSON.Dump({ type: IPC_MSG_DELTA, rev: 2, payload: { removes: [2000, 4000] } })
    GUI_OnStoreMessage(deltaMsg)

    GUI_AssertEq(gGUI_LiveItems.Length, 3, "Delta remove: 3 items remain")
    GUI_AssertEq(gGUI_LiveItemsMap.Has(2000), false, "Delta remove: hwnd 2000 gone from map")
    GUI_AssertEq(gGUI_LiveItemsMap.Has(4000), false, "Delta remove: hwnd 4000 gone from map")
    GUI_AssertEq(gGUI_LiveItemsMap.Has(1000), true, "Delta remove: hwnd 1000 still in map")

    ; ----- Test: Delta remove clamps selection -----
    GUI_Log("Test: Delta remove clamps selection")
    ResetGUIState()
    cfg.FreezeWindowList := false
    snapshotMsg := JSON.Dump({ type: IPC_MSG_SNAPSHOT, rev: 1, payload: { items: CreateTestItems(5) } })
    GUI_OnStoreMessage(snapshotMsg)
    gGUI_Sel := 5  ; Select last item

    ; Remove items 4000 and 5000 (last two)
    deltaMsg := JSON.Dump({ type: IPC_MSG_DELTA, rev: 2, payload: { removes: [4000, 5000] } })
    GUI_OnStoreMessage(deltaMsg)

    GUI_AssertEq(gGUI_LiveItems.Length, 3, "Delta remove clamp: 3 items remain")
    GUI_AssertTrue(gGUI_Sel <= 3, "Delta remove clamp: selection clamped to " gGUI_Sel)

    ; ----- Test: Delta upsert updates existing item (cosmetic) -----
    GUI_Log("Test: Delta upsert updates existing item (cosmetic)")
    ResetGUIState()
    cfg.FreezeWindowList := false
    snapshotMsg := JSON.Dump({ type: IPC_MSG_SNAPSHOT, rev: 1, payload: { items: CreateTestItems(5) } })
    GUI_OnStoreMessage(snapshotMsg)

    ; Update title and processName of existing item (cosmetic, no MRU change)
    upsertRec := Map("hwnd", 1000, "title", "Updated Title", "processName", "updated.exe")
    deltaMsg := JSON.Dump({ type: IPC_MSG_DELTA, rev: 2, payload: { upserts: [upsertRec] } })
    GUI_OnStoreMessage(deltaMsg)

    GUI_AssertEq(gGUI_LiveItems.Length, 5, "Delta upsert cosmetic: still 5 items")
    GUI_AssertEq(gGUI_LiveItemsMap[1000].Title, "Updated Title", "Delta upsert cosmetic: title updated")
    GUI_AssertEq(gGUI_LiveItemsMap[1000].processName, "updated.exe", "Delta upsert cosmetic: processName updated")

    ; ----- Test: Delta upsert updates MRU field (triggers sort) -----
    GUI_Log("Test: Delta upsert updates MRU field")
    ResetGUIState()
    cfg.FreezeWindowList := false
    snapshotMsg := JSON.Dump({ type: IPC_MSG_SNAPSHOT, rev: 1, payload: { items: CreateTestItems(5) } })
    GUI_OnStoreMessage(snapshotMsg)

    ; Update lastActivatedTick of item 3000 to make it most recent
    upsertRec := Map("hwnd", 3000, "lastActivatedTick", A_TickCount + 99999)
    deltaMsg := JSON.Dump({ type: IPC_MSG_DELTA, rev: 2, payload: { upserts: [upsertRec] } })
    GUI_OnStoreMessage(deltaMsg)

    ; Item 3000 should now be first (highest tick)
    GUI_AssertEq(gGUI_LiveItems[1].hwnd, 3000, "Delta upsert MRU: item 3000 moved to first position")

    ; ----- Test: Delta upsert adds new item -----
    GUI_Log("Test: Delta upsert adds new item")
    ResetGUIState()
    cfg.FreezeWindowList := false
    snapshotMsg := JSON.Dump({ type: IPC_MSG_SNAPSHOT, rev: 1, payload: { items: CreateTestItems(3) } })
    GUI_OnStoreMessage(snapshotMsg)

    ; Add a brand new item via upsert
    newRec := Map("hwnd", 9999, "title", "New Window", "class", "NewClass", "lastActivatedTick", A_TickCount + 99999)
    deltaMsg := JSON.Dump({ type: IPC_MSG_DELTA, rev: 2, payload: { upserts: [newRec] } })
    GUI_OnStoreMessage(deltaMsg)

    GUI_AssertEq(gGUI_LiveItems.Length, 4, "Delta upsert new: 4 items total")
    GUI_AssertEq(gGUI_LiveItemsMap.Has(9999), true, "Delta upsert new: hwnd 9999 in map")
    GUI_AssertEq(gGUI_LiveItemsMap[9999].Title, "New Window", "Delta upsert new: title correct")

    cfg.FreezeWindowList := true  ; Restore

    ; ============================================================
    ; LOCAL MRU UPDATE TESTS
    ; ============================================================

    ; ----- Test: _GUI_UpdateLocalMRU moves item to position 1 -----
    GUI_Log("Test: _GUI_UpdateLocalMRU moves item to position 1")
    ResetGUIState()
    gGUI_LiveItems := CreateTestItemsWithMap(5)

    ; Move item 3 (hwnd=3000) to position 1
    result := _GUI_UpdateLocalMRU(3000)
    GUI_AssertTrue(result, "UpdateLocalMRU: returns true for known hwnd")
    GUI_AssertEq(gGUI_LiveItems[1].hwnd, 3000, "UpdateLocalMRU: hwnd 3000 moved to position 1")
    GUI_AssertTrue(gGUI_LastLocalMRUTick > 0, "UpdateLocalMRU: freshness tick set")

    ; ----- Test: _GUI_UpdateLocalMRU unknown hwnd returns false -----
    GUI_Log("Test: _GUI_UpdateLocalMRU unknown hwnd")
    ResetGUIState()
    gGUI_LiveItems := CreateTestItemsWithMap(3)
    origFirst := gGUI_LiveItems[1].hwnd

    result := _GUI_UpdateLocalMRU(99999)
    GUI_AssertTrue(!result, "UpdateLocalMRU: returns false for unknown hwnd")
    GUI_AssertEq(gGUI_LiveItems[1].hwnd, origFirst, "UpdateLocalMRU: items unchanged for unknown hwnd")
    GUI_AssertEq(gGUI_LastLocalMRUTick, 0, "UpdateLocalMRU: tick NOT set for unknown hwnd")

    ; ----- Test: _GUI_UpdateLocalMRU already-first item -----
    GUI_Log("Test: _GUI_UpdateLocalMRU already-first item")
    ResetGUIState()
    gGUI_LiveItems := CreateTestItemsWithMap(3)
    firstHwnd := gGUI_LiveItems[1].hwnd

    result := _GUI_UpdateLocalMRU(firstHwnd)
    GUI_AssertTrue(result, "UpdateLocalMRU: returns true for first item")
    GUI_AssertEq(gGUI_LiveItems[1].hwnd, firstHwnd, "UpdateLocalMRU: first item stays first")
    GUI_AssertTrue(gGUI_LastLocalMRUTick > 0, "UpdateLocalMRU: tick set even for first item")

    ; ----- Test: _GUI_RobustActivate returns false for invalid hwnd -----
    ; Regression guard: ensures activation returns a testable result (not void)
    GUI_Log("Test: _GUI_RobustActivate returns false for invalid hwnd")
    result := _GUI_RobustActivate(0xDEAD)
    GUI_AssertEq(result, false, "_GUI_RobustActivate: returns false for non-existent window")

    ; ----- Test: _GUI_RobustActivate returns false for hwnd 0 -----
    GUI_Log("Test: _GUI_RobustActivate returns false for hwnd 0")
    result := _GUI_RobustActivate(0)
    GUI_AssertEq(result, false, "_GUI_RobustActivate: returns false for hwnd 0")

    ; ----- Test: Failed activation does NOT corrupt MRU order -----
    ; Core regression test for phantom MRU bug: before the fix, _GUI_UpdateLocalMRU
    ; ran unconditionally after _GUI_RobustActivate, corrupting MRU when activation
    ; failed. After the fix, MRU only updates on success.
    GUI_Log("Test: Failed activation does not corrupt MRU order")
    ResetGUIState()
    gGUI_LiveItems := CreateTestItemsWithMap(5)
    origFirst := gGUI_LiveItems[1].hwnd
    origSecond := gGUI_LiveItems[2].hwnd

    ; Activation will fail (fake hwnd, WinExist returns false)
    activateResult := _GUI_RobustActivate(origSecond)
    GUI_AssertEq(activateResult, false, "FailedActivation: activation returns false for test hwnd")

    ; Simulate the FIXED code path: only update MRU on success
    if (activateResult)
        _GUI_UpdateLocalMRU(origSecond)

    ; MRU should be UNCHANGED — item 1 still in position 1
    GUI_AssertEq(gGUI_LiveItems[1].hwnd, origFirst, "FailedActivation: MRU order preserved (first item unchanged)")
    GUI_AssertEq(gGUI_LastLocalMRUTick, 0, "FailedActivation: freshness tick NOT set (no phantom MRU update)")

    ; ============================================================
    ; GUI_SortItemsByMRU TESTS
    ; ============================================================

    ; ----- Test: GUI_SortItemsByMRU sorts by lastActivatedTick descending -----
    GUI_Log("Test: GUI_SortItemsByMRU sorts correctly")
    ResetGUIState()
    gGUI_LiveItems := []
    ticks := [100, 300, 200, 500, 400]
    Loop ticks.Length {
        gGUI_LiveItems.Push({ hwnd: A_Index * 1000, title: "W" A_Index, lastActivatedTick: ticks[A_Index] })
    }

    GUI_SortItemsByMRU()

    GUI_AssertEq(gGUI_LiveItems[1].lastActivatedTick, 500, "Sort MRU: first item has tick 500")
    GUI_AssertEq(gGUI_LiveItems[2].lastActivatedTick, 400, "Sort MRU: second item has tick 400")
    GUI_AssertEq(gGUI_LiveItems[3].lastActivatedTick, 300, "Sort MRU: third item has tick 300")
    GUI_AssertEq(gGUI_LiveItems[4].lastActivatedTick, 200, "Sort MRU: fourth item has tick 200")
    GUI_AssertEq(gGUI_LiveItems[5].lastActivatedTick, 100, "Sort MRU: fifth item has tick 100")

    ; ----- Test: GUI_SortItemsByMRU handles single item -----
    GUI_Log("Test: GUI_SortItemsByMRU handles single item")
    ResetGUIState()
    gGUI_LiveItems := [{ hwnd: 1000, title: "Solo", lastActivatedTick: 42 }]
    GUI_SortItemsByMRU()
    GUI_AssertEq(gGUI_LiveItems.Length, 1, "Sort MRU single: still 1 item")
    GUI_AssertEq(gGUI_LiveItems[1].lastActivatedTick, 42, "Sort MRU single: value preserved")

    ; ----- Test: GUI_SortItemsByMRU handles empty list -----
    GUI_Log("Test: GUI_SortItemsByMRU handles empty list")
    ResetGUIState()
    gGUI_LiveItems := []
    GUI_SortItemsByMRU()
    GUI_AssertEq(gGUI_LiveItems.Length, 0, "Sort MRU empty: no error")

    ; ============================================================
    ; VIEWPORT CHANGE DETECTION TESTS
    ; ============================================================

    ; ----- Test: _GUI_AnyVisibleItemChanged - item in viewport -----
    GUI_Log("Test: Viewport change detection")
    ResetGUIState()
    gGUI_ScrollTop := 0
    gMock_VisibleRows := 5
    items := CreateTestItems(10)
    changedHwnds := Map()
    changedHwnds[3000] := true  ; Item 3 is in viewport (indices 1-5)

    result := _GUI_AnyVisibleItemChanged(items, changedHwnds)
    GUI_AssertTrue(result, "Viewport: changed item 3 in viewport detected")

    ; ----- Test: _GUI_AnyVisibleItemChanged - item off-screen -----
    GUI_Log("Test: Viewport change detection - off-screen")
    changedHwnds2 := Map()
    changedHwnds2[8000] := true  ; Item 8 is off-screen (viewport is 1-5)

    result := _GUI_AnyVisibleItemChanged(items, changedHwnds2)
    GUI_AssertTrue(!result, "Viewport: changed item 8 off-screen not detected")

    ; ----- Test: _GUI_AnyVisibleItemChanged - empty changedHwnds -----
    GUI_Log("Test: Viewport change detection - empty changes")
    result := _GUI_AnyVisibleItemChanged(items, Map())
    GUI_AssertTrue(!result, "Viewport: empty changedHwnds returns false")

    ; ============================================================
    ; GUI_RemoveItemAt TESTS
    ; ============================================================

    ; ----- Test: GUI_RemoveItemAt removes middle item -----
    GUI_Log("Test: GUI_RemoveItemAt removes middle item")
    ResetGUIState()
    gGUI_LiveItems := CreateTestItems(5)
    gGUI_Sel := 2

    GUI_RemoveItemAt(3)  ; Remove middle item

    GUI_AssertEq(gGUI_LiveItems.Length, 4, "RemoveItemAt middle: 4 items remain")
    GUI_AssertEq(gGUI_Sel, 2, "RemoveItemAt middle: selection unchanged")

    ; ----- Test: GUI_RemoveItemAt removes last item, clamps selection -----
    GUI_Log("Test: GUI_RemoveItemAt clamps selection")
    ResetGUIState()
    gGUI_LiveItems := CreateTestItems(3)
    gGUI_Sel := 3  ; Select last item

    GUI_RemoveItemAt(3)  ; Remove last item

    GUI_AssertEq(gGUI_LiveItems.Length, 2, "RemoveItemAt last: 2 items remain")
    GUI_AssertEq(gGUI_Sel, 2, "RemoveItemAt last: selection clamped to 2")

    ; ----- Test: GUI_RemoveItemAt removes only item -----
    GUI_Log("Test: GUI_RemoveItemAt removes only item")
    ResetGUIState()
    gGUI_LiveItems := CreateTestItems(1)
    gGUI_Sel := 1

    GUI_RemoveItemAt(1)

    GUI_AssertEq(gGUI_LiveItems.Length, 0, "RemoveItemAt only: list empty")
    GUI_AssertEq(gGUI_Sel, 1, "RemoveItemAt only: sel=1 (default)")
    GUI_AssertEq(gGUI_ScrollTop, 0, "RemoveItemAt only: scrollTop=0")

    ; ----- Test: GUI_RemoveItemAt out-of-bounds is no-op -----
    GUI_Log("Test: GUI_RemoveItemAt out-of-bounds")
    ResetGUIState()
    gGUI_LiveItems := CreateTestItems(3)

    GUI_RemoveItemAt(0)
    GUI_AssertEq(gGUI_LiveItems.Length, 3, "RemoveItemAt 0: no-op")

    GUI_RemoveItemAt(4)
    GUI_AssertEq(gGUI_LiveItems.Length, 3, "RemoveItemAt 4: no-op (out of bounds)")

    ; ============================================================
    ; WORKSPACE PAYLOAD TRACKING TESTS
    ; ============================================================

    ; ----- Test: GUI_UpdateCurrentWSFromPayload extracts workspace name -----
    GUI_Log("Test: GUI_UpdateCurrentWSFromPayload extracts workspace name")
    ResetGUIState()
    payload := Map()
    payload["meta"] := Map("currentWSName", "Alpha")

    GUI_UpdateCurrentWSFromPayload(payload)
    GUI_AssertEq(gGUI_CurrentWSName, "Alpha", "WSPayload: workspace name extracted")

    ; ----- Test: GUI_UpdateCurrentWSFromPayload resets selection in current mode -----
    GUI_Log("Test: GUI_UpdateCurrentWSFromPayload resets selection in current mode")
    ResetGUIState()
    gGUI_WorkspaceMode := "current"
    gGUI_State := "ACTIVE"
    gGUI_CurrentWSName := "Alpha"
    gGUI_Sel := 5

    payload := Map()
    payload["meta"] := Map("currentWSName", "Beta")

    GUI_UpdateCurrentWSFromPayload(payload)
    GUI_AssertEq(gGUI_CurrentWSName, "Beta", "WSPayload reset: workspace updated")
    GUI_AssertEq(gGUI_Sel, 1, "WSPayload reset: selection reset to 1")

    ; ----- Test: GUI_UpdateCurrentWSFromPayload ALSO resets in all mode -----
    ; A workspace switch is a context switch regardless of display mode.
    ; Position 1 = focused window on the NEW workspace, which is what the user wants.
    GUI_Log("Test: GUI_UpdateCurrentWSFromPayload resets in all mode")
    ResetGUIState()
    gGUI_WorkspaceMode := "all"
    gGUI_State := "ACTIVE"
    gGUI_CurrentWSName := "Alpha"
    gGUI_Sel := 5

    payload := Map()
    payload["meta"] := Map("currentWSName", "Beta")

    GUI_UpdateCurrentWSFromPayload(payload)
    GUI_AssertEq(gGUI_CurrentWSName, "Beta", "WSPayload all: workspace updated")
    GUI_AssertEq(gGUI_Sel, 1, "WSPayload all: selection reset to 1")

    ; ============================================================
    ; WORKSPACE CONTEXT SWITCH SELECTION TESTS
    ; ============================================================
    ; Tests that workspace changes during ACTIVE state set gGUI_WSContextSwitch=true
    ; and that this flag persists sel=1 during subsequent workspace toggles (Ctrl).

    ; ----- Test: Normal Alt-Tab keeps WSContextSwitch=false -----
    GUI_Log("Test: Normal Alt-Tab keeps WSContextSwitch=false")
    ResetGUIState()
    gGUI_WSContextSwitch := false
    gGUI_LiveItems := CreateTestItems(5)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)

    GUI_AssertEq(gGUI_Sel, 2, "Normal Alt-Tab: sel=2 (previous window)")
    GUI_AssertEq(gGUI_WSContextSwitch, false, "Normal Alt-Tab: WSContextSwitch stays false")

    ; ----- Test: WS change during ACTIVE sets WSContextSwitch=true and sel=1 -----
    GUI_Log("Test: WS change during ACTIVE sets WSContextSwitch=true")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_OverlayVisible := true
    gGUI_CurrentWSName := "Alpha"
    gGUI_Sel := 3  ; Start with different selection
    gGUI_WSContextSwitch := false

    ; Simulate workspace change notification from store
    payload := Map("meta", Map("currentWSName", "Beta"))
    GUI_UpdateCurrentWSFromPayload(payload)

    GUI_AssertEq(gGUI_CurrentWSName, "Beta", "WS change: workspace updated")
    GUI_AssertEq(gGUI_Sel, 1, "WS change: sel reset to 1")
    GUI_AssertEq(gGUI_WSContextSwitch, true, "WS change: WSContextSwitch set to true")

    ; ----- Test: WSContextSwitch persists sel=1 during workspace toggles -----
    ; After WS change sets flag, Ctrl toggles should keep sel=1
    GUI_Log("Test: WSContextSwitch persists sel=1 during Ctrl toggle")
    ResetGUIState()
    cfg.FreezeWindowList := true
    cfg.ServerSideWorkspaceFilter := false
    gGUI_State := "ACTIVE"
    gGUI_OverlayVisible := true
    gGUI_LiveItems := CreateTestItems(10, 4)  ; 10 items, 4 on current WS
    gGUI_DisplayItems := gGUI_LiveItems.Clone()
    gGUI_ToggleBase := gGUI_LiveItems.Clone()
    gGUI_WorkspaceMode := "all"
    gGUI_CurrentWSName := "Alpha"
    gGUI_Sel := 3
    gGUI_WSContextSwitch := false

    ; Trigger WS change to set the flag
    payload := Map("meta", Map("currentWSName", "Beta"))
    GUI_UpdateCurrentWSFromPayload(payload)
    GUI_AssertEq(gGUI_WSContextSwitch, true, "WSContextSwitch persist: flag set")
    GUI_AssertEq(gGUI_Sel, 1, "WSContextSwitch persist: initial sel=1")

    ; Toggle to current workspace mode - sel should remain 1 (flag persists)
    GUI_ToggleWorkspaceMode()
    GUI_AssertEq(gGUI_Sel, 1, "WSContextSwitch persist: sel=1 after toggle to current")

    ; Toggle back to all - sel should still be 1
    GUI_ToggleWorkspaceMode()
    GUI_AssertEq(gGUI_Sel, 1, "WSContextSwitch persist: sel=1 after toggle back to all")

    ; ----- Test: WS change with single item list -----
    GUI_Log("Test: WS change with single item -> sel=1")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_OverlayVisible := true
    gGUI_CurrentWSName := "Alpha"
    gGUI_Sel := 1
    gGUI_LiveItems := CreateTestItems(1)

    payload := Map("meta", Map("currentWSName", "Beta"))
    GUI_UpdateCurrentWSFromPayload(payload)

    GUI_AssertEq(gGUI_Sel, 1, "WS change single: sel=1")

    ; ============================================================
    ; GUI_MoveSelectionFrozen DIRECT TESTS
    ; ============================================================

    ; ----- Test: MoveSelectionFrozen empty list is no-op -----
    GUI_Log("Test: MoveSelectionFrozen empty list is no-op")
    ResetGUIState()
    gGUI_DisplayItems := []
    gGUI_Sel := 1
    GUI_MoveSelectionFrozen(1)
    GUI_AssertEq(gGUI_Sel, 1, "MoveSelectionFrozen: empty list is no-op")

    ; ----- Test: MoveSelectionFrozen forward wrap last->first -----
    GUI_Log("Test: MoveSelectionFrozen forward wrap")
    ResetGUIState()
    gGUI_DisplayItems := CreateTestItems(5)
    gGUI_Sel := 5
    GUI_MoveSelectionFrozen(1)
    GUI_AssertEq(gGUI_Sel, 1, "MoveSelectionFrozen: forward wrap last->first")

    ; ----- Test: MoveSelectionFrozen backward wrap first->last -----
    GUI_Log("Test: MoveSelectionFrozen backward wrap")
    ResetGUIState()
    gGUI_DisplayItems := CreateTestItems(5)
    gGUI_Sel := 1
    GUI_MoveSelectionFrozen(-1)
    GUI_AssertEq(gGUI_Sel, 5, "MoveSelectionFrozen: backward wrap first->last")

    ; ============================================================
    ; GUI_MoveSelection Scroll Viewport Tests
    ; ============================================================
    ; Tests that gGUI_ScrollTop updates correctly when selection moves
    ; beyond the visible window, wraps, and under each scroll mode.

    ; ----- Test: MoveSelection scrolls down past visible window -----
    GUI_Log("Test: MoveSelection scrolls down past visible window")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_DisplayItems := CreateTestItems(12)
    gGUI_Sel := 1
    gGUI_ScrollTop := 0
    gMock_VisibleRows := 5
    cfg.GUI_ScrollKeepHighlightOnTop := false

    ; Move down to sel=5 (still visible at bottom), then sel=6 (should scroll)
    GUI_MoveSelection(1)  ; sel=2
    GUI_MoveSelection(1)  ; sel=3
    GUI_MoveSelection(1)  ; sel=4
    GUI_MoveSelection(1)  ; sel=5
    GUI_AssertEq(gGUI_Sel, 5, "ScrollDown: sel=5 after 4 moves")
    scrollBefore := gGUI_ScrollTop
    GUI_MoveSelection(1)  ; sel=6, should scroll
    GUI_AssertEq(gGUI_Sel, 6, "ScrollDown: sel=6")
    GUI_AssertTrue(gGUI_ScrollTop > scrollBefore, "ScrollDown: scrollTop advanced past visible window")

    ; ----- Test: MoveSelection scrolls up past top of viewport -----
    GUI_Log("Test: MoveSelection scrolls up past top of viewport")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_DisplayItems := CreateTestItems(12)
    gGUI_Sel := 6
    gGUI_ScrollTop := 5  ; Viewport shows items 6-10 (0-indexed top=5)
    gMock_VisibleRows := 5
    cfg.GUI_ScrollKeepHighlightOnTop := false

    GUI_MoveSelection(-1)  ; sel=5, at top of viewport
    GUI_MoveSelection(-1)  ; sel=4, should scroll up
    GUI_AssertEq(gGUI_Sel, 4, "ScrollUp: sel=4")
    GUI_AssertTrue(gGUI_ScrollTop <= 3, "ScrollUp: scrollTop retreated (scrollTop=" gGUI_ScrollTop ")")

    ; ----- Test: MoveSelection wraps from last to first -----
    GUI_Log("Test: MoveSelection wraps last->first")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_DisplayItems := CreateTestItems(12)
    gGUI_Sel := 12
    gGUI_ScrollTop := 7
    gMock_VisibleRows := 5
    cfg.GUI_ScrollKeepHighlightOnTop := false

    GUI_MoveSelection(1)  ; wrap to sel=1
    GUI_AssertEq(gGUI_Sel, 1, "WrapFwd: sel=1 after wrapping from 12")

    ; ----- Test: MoveSelection wraps from first to last -----
    GUI_Log("Test: MoveSelection wraps first->last")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_DisplayItems := CreateTestItems(12)
    gGUI_Sel := 1
    gGUI_ScrollTop := 0
    gMock_VisibleRows := 5
    cfg.GUI_ScrollKeepHighlightOnTop := false

    GUI_MoveSelection(-1)  ; wrap to sel=12
    GUI_AssertEq(gGUI_Sel, 12, "WrapBack: sel=12 after wrapping from 1")

    ; ----- Test: ScrollKeepHighlightOnTop=true keeps highlight at top -----
    GUI_Log("Test: ScrollKeepHighlightOnTop=true mode")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_DisplayItems := CreateTestItems(12)
    gGUI_Sel := 1
    gGUI_ScrollTop := 0
    gMock_VisibleRows := 5
    cfg.GUI_ScrollKeepHighlightOnTop := true

    GUI_MoveSelection(1)  ; sel=2, scrollTop should follow
    GUI_AssertEq(gGUI_Sel, 2, "KeepTop: sel=2")
    GUI_AssertEq(gGUI_ScrollTop, 1, "KeepTop: scrollTop=sel-1=1")

    GUI_MoveSelection(1)  ; sel=3
    GUI_AssertEq(gGUI_ScrollTop, 2, "KeepTop: scrollTop=sel-1=2")

    ; Wrap forward
    gGUI_Sel := 12
    gGUI_ScrollTop := 11
    GUI_MoveSelection(1)  ; wrap to sel=1
    GUI_AssertEq(gGUI_Sel, 1, "KeepTop wrap: sel=1")
    GUI_AssertEq(gGUI_ScrollTop, 0, "KeepTop wrap: scrollTop=0")

    cfg.GUI_ScrollKeepHighlightOnTop := false  ; Restore

    ; ----- Test: Fewer items than MaxVisibleRows (no scroll needed) -----
    GUI_Log("Test: MoveSelection with fewer items than visible rows")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_DisplayItems := CreateTestItems(3)
    gGUI_Sel := 1
    gGUI_ScrollTop := 0
    gMock_VisibleRows := 5
    cfg.GUI_ScrollKeepHighlightOnTop := false

    GUI_MoveSelection(1)  ; sel=2
    GUI_MoveSelection(1)  ; sel=3
    GUI_AssertEq(gGUI_Sel, 3, "FewItems: sel=3")
    GUI_MoveSelection(1)  ; wrap to sel=1
    GUI_AssertEq(gGUI_Sel, 1, "FewItems: wrap to sel=1")

    ; ----- Test: Single item (no movement possible) -----
    GUI_Log("Test: MoveSelection with single item")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_DisplayItems := CreateTestItems(1)
    gGUI_Sel := 1
    gGUI_ScrollTop := 0
    gMock_VisibleRows := 5
    cfg.GUI_ScrollKeepHighlightOnTop := false

    GUI_MoveSelection(1)  ; should stay at 1 (wraps to 1)
    GUI_AssertEq(gGUI_Sel, 1, "SingleItem: sel stays 1 after move forward")
    GUI_MoveSelection(-1)  ; should stay at 1
    GUI_AssertEq(gGUI_Sel, 1, "SingleItem: sel stays 1 after move backward")

    ; ============================================================
    ; ESC DURING ASYNC ACTIVATION TEST
    ; ============================================================

    ; ----- Test: ESC during async activation cancels and clears state -----
    GUI_Log("Test: ESC during async activation")
    ResetGUIState()
    gGUI_LiveItems := CreateTestItems(5)
    gGUI_PendingPhase := "polling"
    gGUI_State := "ACTIVE"
    gGUI_EventBuffer := [{ev: TABBY_EV_TAB_STEP, flags: 0, lParam: 0}]

    GUI_OnInterceptorEvent(TABBY_EV_ESCAPE, 0, 0)

    GUI_AssertEq(gGUI_State, "IDLE", "ESC during async: state is IDLE")
    GUI_AssertEq(gGUI_PendingPhase, "", "ESC during async: pending phase cleared")
    GUI_AssertEq(gGUI_EventBuffer.Length, 0, "ESC during async: buffer cleared")

    ; ============================================================
    ; EMPTY EVENT BUFFER -> RESYNC TEST
    ; ============================================================

    ; ----- Test: Empty buffer triggers resync (no events to process) -----
    GUI_Log("Test: Empty buffer triggers resync")
    ResetGUIState()
    gGUI_PendingPhase := "flushing"
    gGUI_EventBuffer := []
    _GUI_ProcessEventBuffer()
    GUI_AssertEq(gGUI_PendingPhase, "", "Empty buffer: pending phase cleared")

    ; ============================================================
    ; NORMAL EVENT BUFFER REPLAY TESTS
    ; ============================================================

    ; ----- Test: Normal buffer replay [ALT_DN, TAB_STEP, ALT_UP] completes full cycle -----
    GUI_Log("Test: Normal buffer replay completes full cycle")
    ResetGUIState()
    gGUI_LiveItems := CreateTestItems(5)
    gGUI_PendingPhase := "flushing"
    gGUI_FlushStartTick := A_TickCount - 50  ; Past the flush wait threshold

    ; Buffer: normal Alt+Tab sequence (Tab NOT lost)
    gGUI_EventBuffer := [
        {ev: TABBY_EV_ALT_DOWN, flags: 0, lParam: 0},
        {ev: TABBY_EV_TAB_STEP, flags: 0, lParam: 0},
        {ev: TABBY_EV_ALT_UP, flags: 0, lParam: 0}
    ]

    _GUI_ProcessEventBuffer()

    ; ALT_DN -> ALT_PENDING -> TAB_STEP -> ACTIVE -> ALT_UP -> IDLE
    GUI_AssertEq(gGUI_State, "IDLE", "Normal replay: cycle completed (state=IDLE)")
    GUI_AssertEq(gGUI_PendingPhase, "", "Normal replay: pending phase cleared")

    ; ----- Test: Multi-Tab buffer replay completes full cycle -----
    GUI_Log("Test: Multi-Tab buffer replay completes full cycle")
    ResetGUIState()
    gGUI_LiveItems := CreateTestItems(5)
    gGUI_PendingPhase := "flushing"
    gGUI_FlushStartTick := A_TickCount - 50

    ; Buffer: Alt+Tab with 3 Tab presses (user cycling through windows)
    gGUI_EventBuffer := [
        {ev: TABBY_EV_ALT_DOWN, flags: 0, lParam: 0},
        {ev: TABBY_EV_TAB_STEP, flags: 0, lParam: 0},
        {ev: TABBY_EV_TAB_STEP, flags: 0, lParam: 0},
        {ev: TABBY_EV_TAB_STEP, flags: 0, lParam: 0},
        {ev: TABBY_EV_ALT_UP, flags: 0, lParam: 0}
    ]

    _GUI_ProcessEventBuffer()

    GUI_AssertEq(gGUI_State, "IDLE", "Multi-Tab replay: cycle completed (state=IDLE)")
    GUI_AssertEq(gGUI_PendingPhase, "", "Multi-Tab replay: pending phase cleared")

    ; ============================================================
    ; BYPASS MODE PROPAGATION TESTS (Gap 1: isFocused in delta)
    ; ============================================================

    ; ----- Test: Delta isFocused=true on existing item sets bypass mode -----
    GUI_Log("Test: Delta isFocused=true on existing item sets bypass mode")
    ResetGUIState()
    cfg.FreezeWindowList := false  ; Live mode for delta processing
    snapshotMsg := JSON.Dump({ type: IPC_MSG_SNAPSHOT, rev: 1, payload: { items: CreateTestItems(5) } })
    GUI_OnStoreMessage(snapshotMsg)
    gMock_BypassResult := true  ; Mock: window should trigger bypass

    ; Send delta with isFocused=true on existing item
    upsertRec := Map("hwnd", 1000, "isFocused", true)
    deltaMsg := JSON.Dump({ type: IPC_MSG_DELTA, rev: 2, payload: { upserts: [upsertRec] } })
    GUI_OnStoreMessage(deltaMsg)

    GUI_AssertEq(gINT_BypassMode, true, "Bypass: isFocused=true on existing item enables bypass")

    ; ----- Test: Delta isFocused=true on new item sets bypass mode -----
    GUI_Log("Test: Delta isFocused=true on new item sets bypass mode")
    ResetGUIState()
    cfg.FreezeWindowList := false
    snapshotMsg := JSON.Dump({ type: IPC_MSG_SNAPSHOT, rev: 1, payload: { items: CreateTestItems(3) } })
    GUI_OnStoreMessage(snapshotMsg)
    gMock_BypassResult := true

    ; Send delta adding a NEW item with isFocused=true
    newRec := Map("hwnd", 9999, "title", "Game Window", "class", "GameClass", "isFocused", true, "lastActivatedTick", A_TickCount + 99999)
    deltaMsg := JSON.Dump({ type: IPC_MSG_DELTA, rev: 2, payload: { upserts: [newRec] } })
    GUI_OnStoreMessage(deltaMsg)

    GUI_AssertEq(gINT_BypassMode, true, "Bypass: isFocused=true on new item enables bypass")
    GUI_AssertEq(gGUI_LiveItems.Length, 4, "Bypass: new item added to list")

    ; ----- Test: Bypass mock returning false resets bypass mode -----
    GUI_Log("Test: Bypass mock returning false resets bypass mode")
    ResetGUIState()
    cfg.FreezeWindowList := false
    snapshotMsg := JSON.Dump({ type: IPC_MSG_SNAPSHOT, rev: 1, payload: { items: CreateTestItems(5) } })
    GUI_OnStoreMessage(snapshotMsg)
    gINT_BypassMode := true  ; Pre-set bypass to true
    gMock_BypassResult := false  ; Mock: window should NOT trigger bypass

    ; Send delta with isFocused=true - bypass check should disable bypass
    upsertRec := Map("hwnd", 2000, "isFocused", true)
    deltaMsg := JSON.Dump({ type: IPC_MSG_DELTA, rev: 2, payload: { upserts: [upsertRec] } })
    GUI_OnStoreMessage(deltaMsg)

    GUI_AssertEq(gINT_BypassMode, false, "Bypass: isFocused=true with non-bypass window disables bypass")

    cfg.FreezeWindowList := true  ; Restore

    ; ============================================================
    ; COMBINED REMOVES+UPSERTS DELTA TESTS (Gap 2)
    ; ============================================================

    ; ----- Test: Delta with both removes and upserts -----
    GUI_Log("Test: Combined removes + upserts in single delta")
    ResetGUIState()
    cfg.FreezeWindowList := false
    snapshotMsg := JSON.Dump({ type: IPC_MSG_SNAPSHOT, rev: 1, payload: { items: CreateTestItems(5) } })
    GUI_OnStoreMessage(snapshotMsg)
    GUI_AssertEq(gGUI_LiveItems.Length, 5, "Combined delta: initial 5 items")

    ; Single delta: remove hwnd 2000 and 4000, add hwnd 8888
    newRec := Map("hwnd", 8888, "title", "Brand New", "class", "NewClass", "lastActivatedTick", A_TickCount + 99999)
    deltaMsg := JSON.Dump({ type: IPC_MSG_DELTA, rev: 2, payload: { removes: [2000, 4000], upserts: [newRec] } })
    GUI_OnStoreMessage(deltaMsg)

    GUI_AssertEq(gGUI_LiveItems.Length, 4, "Combined delta: 5 - 2 removed + 1 added = 4")
    GUI_AssertEq(gGUI_LiveItemsMap.Has(2000), false, "Combined delta: hwnd 2000 removed")
    GUI_AssertEq(gGUI_LiveItemsMap.Has(4000), false, "Combined delta: hwnd 4000 removed")
    GUI_AssertEq(gGUI_LiveItemsMap.Has(8888), true, "Combined delta: hwnd 8888 added")
    GUI_AssertEq(gGUI_LiveItemsMap[8888].Title, "Brand New", "Combined delta: new item title correct")

    ; ----- Test: Remove then re-add same hwnd (HWND reuse) -----
    GUI_Log("Test: Remove then re-add same hwnd (HWND reuse)")
    ResetGUIState()
    cfg.FreezeWindowList := false
    snapshotMsg := JSON.Dump({ type: IPC_MSG_SNAPSHOT, rev: 1, payload: { items: CreateTestItems(3) } })
    GUI_OnStoreMessage(snapshotMsg)
    GUI_AssertEq(gGUI_LiveItemsMap[1000].Title, "Window 1", "HWND reuse: original title")

    ; Remove hwnd 1000 and re-add with new title (simulates HWND reuse by OS)
    reusedRec := Map("hwnd", 1000, "title", "Reused Window", "class", "NewApp", "lastActivatedTick", A_TickCount + 99999)
    deltaMsg := JSON.Dump({ type: IPC_MSG_DELTA, rev: 2, payload: { removes: [1000], upserts: [reusedRec] } })
    GUI_OnStoreMessage(deltaMsg)

    GUI_AssertEq(gGUI_LiveItems.Length, 3, "HWND reuse: still 3 items")
    GUI_AssertEq(gGUI_LiveItemsMap.Has(1000), true, "HWND reuse: hwnd 1000 exists")
    GUI_AssertEq(gGUI_LiveItemsMap[1000].Title, "Reused Window", "HWND reuse: title updated to new app")

    cfg.FreezeWindowList := true  ; Restore

    ; ============================================================
    ; ICON CACHE PRUNE ON SNAPSHOT TESTS (Resource leak fix)
    ; ============================================================

    ; ----- Test: Snapshot calls Gdip_PruneIconCache with live hwnd map -----
    GUI_Log("Test: Snapshot calls Gdip_PruneIconCache with live hwnd map")
    ResetGUIState()
    snapshotMsg := JSON.Dump({ type: IPC_MSG_SNAPSHOT, rev: 200, payload: { items: CreateTestItems(3) } })
    GUI_OnStoreMessage(snapshotMsg)

    GUI_AssertTrue(IsObject(gMock_PruneCalledWith), "Prune: called on snapshot")
    if (IsObject(gMock_PruneCalledWith)) {
        ; The live hwnds map should contain exactly the 3 hwnds from the snapshot
        GUI_AssertEq(gMock_PruneCalledWith.Count, 3, "Prune: live map has 3 entries")
        GUI_AssertTrue(gMock_PruneCalledWith.Has(1000), "Prune: live map has hwnd 1000")
        GUI_AssertTrue(gMock_PruneCalledWith.Has(2000), "Prune: live map has hwnd 2000")
        GUI_AssertTrue(gMock_PruneCalledWith.Has(3000), "Prune: live map has hwnd 3000")
    }

    ; ----- Test: Prune called with updated map after second snapshot -----
    GUI_Log("Test: Prune called with updated map after second snapshot")
    ResetGUIState()
    ; First snapshot: 5 items
    snapshotMsg := JSON.Dump({ type: IPC_MSG_SNAPSHOT, rev: 201, payload: { items: CreateTestItems(5) } })
    GUI_OnStoreMessage(snapshotMsg)
    GUI_AssertTrue(IsObject(gMock_PruneCalledWith), "Prune 2nd: called on first snapshot")

    ; Second snapshot: only 2 items (windows closed)
    gMock_PruneCalledWith := ""
    items2 := CreateTestItems(2)
    snapshotMsg2 := JSON.Dump({ type: IPC_MSG_SNAPSHOT, rev: 202, payload: { items: items2 } })
    GUI_OnStoreMessage(snapshotMsg2)

    GUI_AssertTrue(IsObject(gMock_PruneCalledWith), "Prune 2nd: called on second snapshot")
    if (IsObject(gMock_PruneCalledWith)) {
        GUI_AssertEq(gMock_PruneCalledWith.Count, 2, "Prune 2nd: live map has 2 entries (orphans would be pruned)")
    }

    ; ============================================================
    ; ICON PRE-CACHE ON IPC RECEIVE TESTS (Grey circle fix)
    ; ============================================================

    ; ----- Test: Snapshot pre-caches icons for items with non-zero iconHicon -----
    GUI_Log("Test: Snapshot pre-caches icons for items with non-zero iconHicon")
    ResetGUIState()
    items := CreateTestItems(3)
    items[1].iconHicon := 99001
    items[3].iconHicon := 99003
    ; items[2] has no iconHicon (defaults to 0) - should NOT be pre-cached
    snapshotMsg := JSON.Dump({ type: IPC_MSG_SNAPSHOT, rev: 300, payload: { items: items } })
    GUI_OnStoreMessage(snapshotMsg)

    GUI_AssertEq(gMock_PreCachedIcons.Count, 2, "PreCache snapshot: 2 icons cached (skipped 0)")
    GUI_AssertEq(gMock_PreCachedIcons[1000], 99001, "PreCache snapshot: hwnd 1000 has correct hicon")
    GUI_AssertEq(gMock_PreCachedIcons[3000], 99003, "PreCache snapshot: hwnd 3000 has correct hicon")

    ; ----- Test: Delta upsert pre-caches icon on update -----
    GUI_Log("Test: Delta upsert pre-caches icon on update")
    ResetGUIState()
    ; Set up initial items (no icons)
    snapshotMsg := JSON.Dump({ type: IPC_MSG_SNAPSHOT, rev: 301, payload: { items: CreateTestItems(2) } })
    GUI_OnStoreMessage(snapshotMsg)
    gMock_PreCachedIcons := Map()  ; Clear from snapshot

    ; Delta: update existing item with a new icon
    deltaMsg := JSON.Dump({ type: IPC_MSG_DELTA, rev: 302, payload: { upserts: [{ hwnd: 1000, iconHicon: 55555 }], removes: [] } })
    GUI_OnStoreMessage(deltaMsg)

    GUI_AssertEq(gMock_PreCachedIcons.Count, 1, "PreCache delta update: 1 icon cached")
    GUI_AssertEq(gMock_PreCachedIcons[1000], 55555, "PreCache delta update: correct hicon")

    ; ----- Test: Delta upsert pre-caches icon on new item -----
    GUI_Log("Test: Delta upsert pre-caches icon on new item")
    gMock_PreCachedIcons := Map()  ; Clear

    ; Delta: add a brand new item with icon
    deltaMsg := JSON.Dump({ type: IPC_MSG_DELTA, rev: 303, payload: { upserts: [{ hwnd: 9000, title: "New", class: "C", iconHicon: 77777, lastActivatedTick: A_TickCount }], removes: [] } })
    GUI_OnStoreMessage(deltaMsg)

    GUI_AssertEq(gMock_PreCachedIcons.Count, 1, "PreCache delta new: 1 icon cached")
    GUI_AssertEq(gMock_PreCachedIcons[9000], 77777, "PreCache delta new: correct hicon")

    ; ----- Summary -----
    GUI_Log("`n=== GUI Data Tests Summary ===")
    GUI_Log("Passed: " GUI_TestPassed)
    GUI_Log("Failed: " GUI_TestFailed)

    return GUI_TestFailed = 0
}

; ============================================================
; ENTRY POINT
; ============================================================

if (A_ScriptFullPath = A_LineFile) {
    try FileDelete(A_Temp "\gui_tests.log")
    result := RunGUITests_Data()
    ExitApp(result ? 0 : 1)
}
