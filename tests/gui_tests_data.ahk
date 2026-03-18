; GUI Data Processing Tests - MRU, Selection, Viewport, Icon Cache
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
    global GUI_TestPassed, GUI_TestFailed, cfg
    global gGUI_State, gGUI_LiveItems, gGUI_DisplayItems, gGUI_ToggleBase
    global gGUI_Sel, gGUI_ScrollTop, gGUI_OverlayVisible, gGUI_TabCount
    global gGUI_WorkspaceMode, gGUI_CurrentWSName, gGUI_WSContextSwitch
    global gGUI_EventBuffer, gGUI_Pending
    global gGUI_LiveItemsMap, gMock_VisibleRows
    global gMock_BypassResult, gINT_BypassMode, gMock_PruneCalledWith, gMock_PreCachedIcons
    global gGUI_Base, gGdip_IconCache
    global gMock_StoreItems, gMock_StoreItemsMap
    global _gGUI_LastCosmeticRepaintTick, gWS_Store, gWS_DirtyHwnds, gMock_RepaintCount
    global gMock_LastStatsMsg
    global gStats_AltTabs, gStats_QuickSwitches, gStats_TabSteps
    global gStats_Cancellations, gStats_CrossWorkspace, gStats_WorkspaceToggles
    global gStats_LastSent

    GUI_Log("`n=== GUI Data Processing Tests ===`n")

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

    ; ----- Test: _GUI_UpdateLocalMRU unknown hwnd returns false -----
    GUI_Log("Test: _GUI_UpdateLocalMRU unknown hwnd")
    ResetGUIState()
    gGUI_LiveItems := CreateTestItemsWithMap(3)
    origFirst := gGUI_LiveItems[1].hwnd

    result := _GUI_UpdateLocalMRU(99999)
    GUI_AssertTrue(!result, "UpdateLocalMRU: returns false for unknown hwnd")
    GUI_AssertEq(gGUI_LiveItems[1].hwnd, origFirst, "UpdateLocalMRU: items unchanged for unknown hwnd")

    ; ----- Test: _GUI_UpdateLocalMRU already-first item -----
    GUI_Log("Test: _GUI_UpdateLocalMRU already-first item")
    ResetGUIState()
    gGUI_LiveItems := CreateTestItemsWithMap(3)
    firstHwnd := gGUI_LiveItems[1].hwnd

    result := _GUI_UpdateLocalMRU(firstHwnd)
    GUI_AssertTrue(result, "UpdateLocalMRU: returns true for first item")
    GUI_AssertEq(gGUI_LiveItems[1].hwnd, firstHwnd, "UpdateLocalMRU: first item stays first")

    ; ----- Test: GUI_RobustActivate returns false for invalid hwnd -----
    ; Regression guard: ensures activation returns a testable result (not void)
    GUI_Log("Test: GUI_RobustActivate returns false for invalid hwnd")
    result := GUI_RobustActivate(0xDEAD)
    GUI_AssertEq(result, false, "GUI_RobustActivate: returns false for non-existent window")

    ; ----- Test: GUI_RobustActivate returns false for hwnd 0 -----
    GUI_Log("Test: GUI_RobustActivate returns false for hwnd 0")
    result := GUI_RobustActivate(0)
    GUI_AssertEq(result, false, "GUI_RobustActivate: returns false for hwnd 0")

    ; ----- Test: Failed activation does NOT corrupt MRU order -----
    ; Core regression test for phantom MRU bug: before the fix, _GUI_UpdateLocalMRU
    ; ran unconditionally after _GUI_RobustActivate, corrupting MRU when activation
    ; failed. After the fix, MRU only updates on success.
    GUI_Log("Test: Failed activation does not corrupt MRU order")
    ResetGUIState()
    gGUI_LiveItems := CreateTestItemsWithMap(5)
    origFirst := gGUI_LiveItems[1].hwnd
    origSecond := gGUI_LiveItems[2].hwnd

    ; Call the real production activation function with a fake item.
    ; GUI_RobustActivate will return false (WinExist fails for fake hwnds),
    ; so the production guard should prevent _GUI_UpdateLocalMRU from running.
    fakeItem := { hwnd: origSecond, isOnCurrentWorkspace: true, WS: "" }
    GUI_ActivateItem(fakeItem)

    ; MRU should be UNCHANGED — item 1 still in position 1
    GUI_AssertEq(gGUI_LiveItems[1].hwnd, origFirst, "FailedActivation: MRU order preserved (first item unchanged)")

    ; ============================================================
    ; _GUI_RemoveItemAt TESTS
    ; ============================================================

    ; ----- Test: _GUI_RemoveItemAt removes middle item -----
    GUI_Log("Test: _GUI_RemoveItemAt removes middle item")
    ResetGUIState()
    gGUI_LiveItems := CreateTestItems(5)
    gGUI_Sel := 2

    _GUI_RemoveItemAt(3)  ; Remove middle item

    GUI_AssertEq(gGUI_LiveItems.Length, 4, "RemoveItemAt middle: 4 items remain")
    GUI_AssertEq(gGUI_Sel, 2, "RemoveItemAt middle: selection unchanged")

    ; ----- Test: _GUI_RemoveItemAt removes last item, clamps selection -----
    GUI_Log("Test: _GUI_RemoveItemAt clamps selection")
    ResetGUIState()
    gGUI_LiveItems := CreateTestItems(3)
    gGUI_Sel := 3  ; Select last item

    _GUI_RemoveItemAt(3)  ; Remove last item

    GUI_AssertEq(gGUI_LiveItems.Length, 2, "RemoveItemAt last: 2 items remain")
    GUI_AssertEq(gGUI_Sel, 2, "RemoveItemAt last: selection clamped to 2")

    ; ----- Test: _GUI_RemoveItemAt removes only item -----
    GUI_Log("Test: _GUI_RemoveItemAt removes only item")
    ResetGUIState()
    gGUI_LiveItems := CreateTestItems(1)
    gGUI_Sel := 1

    _GUI_RemoveItemAt(1)

    GUI_AssertEq(gGUI_LiveItems.Length, 0, "RemoveItemAt only: list empty")
    GUI_AssertEq(gGUI_Sel, 1, "RemoveItemAt only: sel=1 (default)")
    GUI_AssertEq(gGUI_ScrollTop, 0, "RemoveItemAt only: scrollTop=0")

    ; ----- Test: _GUI_RemoveItemAt maintains map consistency -----
    GUI_Log("Test: _GUI_RemoveItemAt maintains map consistency")
    ResetGUIState()
    gGUI_LiveItems := CreateTestItemsWithMap(5)

    removedHwnd := gGUI_LiveItems[3].hwnd
    _GUI_RemoveItemAt(3)

    GUI_AssertEq(gGUI_LiveItems.Length, 4, "RemoveItemAt map: 4 items remain")
    GUI_AssertEq(gGUI_LiveItemsMap.Count, 4, "RemoveItemAt map: map has 4 entries")
    GUI_AssertTrue(!gGUI_LiveItemsMap.Has(removedHwnd), "RemoveItemAt map: removed hwnd absent from map")
    ; Verify remaining items are all in the map
    for _, item in gGUI_LiveItems
        GUI_AssertTrue(gGUI_LiveItemsMap.Has(item.hwnd), "RemoveItemAt map: remaining hwnd " item.hwnd " in map")

    ; ----- Test: _GUI_RemoveItemAt out-of-bounds is no-op -----
    GUI_Log("Test: _GUI_RemoveItemAt out-of-bounds")
    ResetGUIState()
    gGUI_LiveItems := CreateTestItems(3)

    _GUI_RemoveItemAt(0)
    GUI_AssertEq(gGUI_LiveItems.Length, 3, "RemoveItemAt 0: no-op")

    _GUI_RemoveItemAt(4)
    GUI_AssertEq(gGUI_LiveItems.Length, 3, "RemoveItemAt 4: no-op (out of bounds)")

    ; ============================================================
    ; WORKSPACE CONTEXT SWITCH SELECTION TESTS
    ; ============================================================
    ; Tests that workspace changes during ACTIVE state set gGUI_WSContextSwitch=true
    ; and that this flag persists sel=1 during subsequent workspace toggles (Ctrl).

    ; ----- Test: Normal Alt-Tab keeps WSContextSwitch=false -----
    GUI_Log("Test: Normal Alt-Tab keeps WSContextSwitch=false")
    ResetGUIState()
    gGUI_WSContextSwitch := false
    SetupTestItems(5)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)

    GUI_AssertEq(gGUI_Sel, 2, "Normal Alt-Tab: sel=2 (previous window)")
    GUI_AssertEq(gGUI_WSContextSwitch, false, "Normal Alt-Tab: WSContextSwitch stays false")

    ; ----- Test: WS change during ACTIVE sets WSContextSwitch=true and sel=1 -----
    GUI_Log("Test: WS change during ACTIVE sets WSContextSwitch=true")
    ResetGUIState()
    SetupTestItems(5)  ; Mock store needed for workspace switch context
    gGUI_State := "ACTIVE"
    gGUI_OverlayVisible := true
    gGUI_CurrentWSName := "Beta"
    gGUI_Sel := 3  ; Start with different selection
    gGUI_WSContextSwitch := false

    ; Simulate workspace change (direct state + production function)
    _GUI_HandleWorkspaceSwitch()

    GUI_AssertEq(gGUI_Sel, 1, "WS change: sel reset to 1")
    GUI_AssertEq(gGUI_WSContextSwitch, true, "WS change: WSContextSwitch set to true")

    ; ----- Test: WSContextSwitch persists sel=1 during workspace toggles -----
    ; After WS change sets flag, Ctrl toggles should keep sel=1
    GUI_Log("Test: WSContextSwitch persists sel=1 during Ctrl toggle")
    ResetGUIState()
    ; Structural freeze is always on during ACTIVE (no config needed)
    gGUI_State := "ACTIVE"
    gGUI_OverlayVisible := true
    items := SetupTestItems(10, 4)  ; 10 items, 4 on current WS ("Main"), 6 on "Other"
    gGUI_DisplayItems := items.Clone()
    gGUI_ToggleBase := items.Clone()
    gGUI_WorkspaceMode := "all"
    gGUI_CurrentWSName := "Main"
    gGUI_Sel := 3
    gGUI_WSContextSwitch := false

    ; Trigger WS change to set the flag (switch to "Other" which has 6 items)
    gGUI_CurrentWSName := "Other"
    _GUI_HandleWorkspaceSwitch()
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
    gGUI_CurrentWSName := "Beta"
    gGUI_Sel := 3  ; Start at non-1 to verify production code resets it
    SetupTestItems(1)

    _GUI_HandleWorkspaceSwitch()

    GUI_AssertEq(gGUI_Sel, 1, "WS change single: sel=1")

    ; ============================================================
    ; GUI_MoveSelectionFrozen DIRECT TESTS
    ; ============================================================

    ; ----- Test: MoveSelectionFrozen empty list is no-op -----
    GUI_Log("Test: MoveSelectionFrozen empty list is no-op")
    ResetGUIState()
    gGUI_DisplayItems := []
    gGUI_Sel := 1
    _GUI_MoveSelectionFrozen(1)
    GUI_AssertEq(gGUI_Sel, 1, "MoveSelectionFrozen: empty list is no-op")

    ; ----- Test: MoveSelectionFrozen forward wrap last->first -----
    GUI_Log("Test: MoveSelectionFrozen forward wrap")
    ResetGUIState()
    gGUI_DisplayItems := CreateTestItems(5)
    gGUI_Sel := 5
    _GUI_MoveSelectionFrozen(1)
    GUI_AssertEq(gGUI_Sel, 1, "MoveSelectionFrozen: forward wrap last->first")

    ; ----- Test: MoveSelectionFrozen backward wrap first->last -----
    GUI_Log("Test: MoveSelectionFrozen backward wrap")
    ResetGUIState()
    gGUI_DisplayItems := CreateTestItems(5)
    gGUI_Sel := 1
    _GUI_MoveSelectionFrozen(-1)
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
    _GUI_MoveSelection(1)  ; sel=2
    _GUI_MoveSelection(1)  ; sel=3
    _GUI_MoveSelection(1)  ; sel=4
    _GUI_MoveSelection(1)  ; sel=5
    GUI_AssertEq(gGUI_Sel, 5, "ScrollDown: sel=5 after 4 moves")
    scrollBefore := gGUI_ScrollTop
    _GUI_MoveSelection(1)  ; sel=6, should scroll
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

    _GUI_MoveSelection(-1)  ; sel=5, at top of viewport
    _GUI_MoveSelection(-1)  ; sel=4, should scroll up
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

    _GUI_MoveSelection(1)  ; wrap to sel=1
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

    _GUI_MoveSelection(-1)  ; wrap to sel=12
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

    _GUI_MoveSelection(1)  ; sel=2, scrollTop should follow
    GUI_AssertEq(gGUI_Sel, 2, "KeepTop: sel=2")
    GUI_AssertEq(gGUI_ScrollTop, 1, "KeepTop: scrollTop=sel-1=1")

    _GUI_MoveSelection(1)  ; sel=3
    GUI_AssertEq(gGUI_ScrollTop, 2, "KeepTop: scrollTop=sel-1=2")

    ; Wrap forward
    gGUI_Sel := 12
    gGUI_ScrollTop := 11
    _GUI_MoveSelection(1)  ; wrap to sel=1
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

    _GUI_MoveSelection(1)  ; sel=2
    _GUI_MoveSelection(1)  ; sel=3
    GUI_AssertEq(gGUI_Sel, 3, "FewItems: sel=3")
    _GUI_MoveSelection(1)  ; wrap to sel=1
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

    _GUI_MoveSelection(1)  ; should stay at 1 (wraps to 1)
    GUI_AssertEq(gGUI_Sel, 1, "SingleItem: sel stays 1 after move forward")
    _GUI_MoveSelection(-1)  ; should stay at 1
    GUI_AssertEq(gGUI_Sel, 1, "SingleItem: sel stays 1 after move backward")

    ; ============================================================
    ; ESC DURING ASYNC ACTIVATION TEST
    ; ============================================================

    ; ----- Test: ESC during async activation cancels and clears state -----
    GUI_Log("Test: ESC during async activation")
    ResetGUIState()
    SetupTestItems(5)
    gGUI_Pending.phase := "polling"
    gGUI_State := "ACTIVE"
    gGUI_EventBuffer := [{ev: TABBY_EV_TAB_STEP, flags: 0, lParam: 0}]

    GUI_OnInterceptorEvent(TABBY_EV_ESCAPE, 0, 0)

    GUI_AssertEq(gGUI_State, "IDLE", "ESC during async: state is IDLE")
    GUI_AssertEq(gGUI_Pending.phase, "", "ESC during async: pending phase cleared")
    GUI_AssertEq(gGUI_EventBuffer.Length, 0, "ESC during async: buffer cleared")

    ; ============================================================
    ; EMPTY EVENT BUFFER -> RESYNC TEST
    ; ============================================================

    ; ----- Test: Empty buffer triggers resync (no events to process) -----
    GUI_Log("Test: Empty buffer triggers resync")
    ResetGUIState()
    gGUI_Pending.phase := "flushing"
    gGUI_EventBuffer := []
    _GUI_ProcessEventBuffer()
    GUI_AssertEq(gGUI_Pending.phase, "", "Empty buffer: pending phase cleared")

    ; ============================================================
    ; NORMAL EVENT BUFFER REPLAY TESTS
    ; ============================================================

    ; ----- Test: Normal buffer replay [ALT_DN, TAB_STEP, ALT_UP] completes full cycle -----
    GUI_Log("Test: Normal buffer replay completes full cycle")
    ResetGUIState()
    SetupTestItems(5)
    gGUI_Pending.phase := "flushing"

    ; Buffer: normal Alt+Tab sequence (Tab NOT lost)
    gGUI_EventBuffer := [
        {ev: TABBY_EV_ALT_DOWN, flags: 0, lParam: 0},
        {ev: TABBY_EV_TAB_STEP, flags: 0, lParam: 0},
        {ev: TABBY_EV_ALT_UP, flags: 0, lParam: 0}
    ]

    _GUI_ProcessEventBuffer()

    ; ALT_DN -> ALT_PENDING -> TAB_STEP -> ACTIVE -> ALT_UP -> IDLE
    GUI_AssertEq(gGUI_State, "IDLE", "Normal replay: cycle completed (state=IDLE)")
    GUI_AssertEq(gGUI_Pending.phase, "", "Normal replay: pending phase cleared")

    ; ----- Test: Multi-Tab buffer replay completes full cycle -----
    GUI_Log("Test: Multi-Tab buffer replay completes full cycle")
    ResetGUIState()
    SetupTestItems(5)
    gGUI_Pending.phase := "flushing"

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
    GUI_AssertEq(gGUI_Pending.phase, "", "Multi-Tab replay: pending phase cleared")

    ; ============================================================
    ; ICON CACHE PRUNE ON REFRESH TESTS (Resource leak fix)
    ; ============================================================

    ; ----- Test: Refresh with no prior cache skips prune -----
    GUI_Log("Test: Refresh with no prior cache skips prune")
    ResetGUIState()
    MockStore_SetItems(CreateTestItems(3))
    GUI_RefreshLiveItems()

    GUI_AssertEq(gGUI_LiveItems.Length, 3, "Prune: 3 items loaded")
    GUI_AssertEq(gGUI_LiveItemsMap.Count, 3, "Prune: live map has 3 entries")

    ; ----- Test: Prune called when cache has orphans after refresh -----
    GUI_Log("Test: Prune called when cache has orphans after refresh")
    ResetGUIState()
    ; Pre-populate icon cache with 5 items (simulates previous state)
    Loop 5
        gGdip_IconCache[A_Index * 1000] := {hicon: 90000 + A_Index * 1000, bitmap: 0}

    ; Refresh with only 2 items (windows closed) — cache has orphans
    gMock_PruneCalledWith := ""
    MockStore_SetItems(CreateTestItems(2))
    GUI_RefreshLiveItems()

    GUI_AssertTrue(IsObject(gMock_PruneCalledWith), "Prune: called when cache has orphans (5->2)")
    if (IsObject(gMock_PruneCalledWith)) {
        GUI_AssertEq(gMock_PruneCalledWith.Count, 2, "Prune: live map has 2 entries (orphans would be pruned)")
    }

    ; ============================================================
    ; ICON PRE-CACHE ON REFRESH TESTS (Grey circle fix)
    ; ============================================================

    ; ----- Test: Refresh pre-caches visible icons synchronously (A1 path) -----
    GUI_Log("Test: Refresh pre-caches visible icons for items with non-zero iconHicon")
    ResetGUIState()
    items := CreateTestItems(3)
    items[1].iconHicon := 99001
    items[3].iconHicon := 99003
    ; items[2] has iconHicon 0 - should NOT be pre-cached
    MockStore_SetItems(items)
    ; Overlay visible → A1 path pre-caches viewport rows synchronously
    gGUI_OverlayVisible := true
    gGUI_ScrollTop := 0
    GUI_RefreshLiveItems()

    GUI_AssertEq(gMock_PreCachedIcons.Count, 2, "PreCache refresh: 2 icons cached (skipped 0)")
    GUI_AssertEq(gMock_PreCachedIcons[1000], 99001, "PreCache refresh: hwnd 1000 has correct hicon")
    GUI_AssertEq(gMock_PreCachedIcons[3000], 99003, "PreCache refresh: hwnd 3000 has correct hicon")

    ; ============================================================
    ; BACKGROUND PRE-CACHE TIMER TESTS (_GUI_PreCacheTick)
    ; ============================================================

    ; ----- Test: _GUI_PreCacheTick skips during ACTIVE state -----
    GUI_Log("Test: _GUI_PreCacheTick skips during ACTIVE state")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gWS_Store[1000] := {present: true, iconHicon: 50001}
    _GUI_PreCacheTick()
    GUI_AssertEq(gMock_PreCachedIcons.Count, 0, "PreCacheTick ACTIVE: no icons cached")

    ; ----- Test: _GUI_PreCacheTick caches uncached icons from gWS_Store -----
    GUI_Log("Test: _GUI_PreCacheTick caches uncached icons from gWS_Store")
    ResetGUIState()
    gWS_Store[1000] := {present: true, iconHicon: 50001}
    gWS_Store[2000] := {present: true, iconHicon: 50002}
    gWS_Store[3000] := {present: true, iconHicon: 50003}
    _GUI_PreCacheTick()
    GUI_AssertEq(gMock_PreCachedIcons.Count, 3, "PreCacheTick: 3 icons cached")
    GUI_AssertEq(gMock_PreCachedIcons[1000], 50001, "PreCacheTick: hwnd 1000 cached with correct hicon")
    GUI_AssertEq(gMock_PreCachedIcons[2000], 50002, "PreCacheTick: hwnd 2000 cached with correct hicon")
    GUI_AssertEq(gMock_PreCachedIcons[3000], 50003, "PreCacheTick: hwnd 3000 cached with correct hicon")

    ; ----- Test: _GUI_PreCacheTick skips non-present items -----
    GUI_Log("Test: _GUI_PreCacheTick skips non-present items")
    ResetGUIState()
    gWS_Store[1000] := {present: false, iconHicon: 50001}
    gWS_Store[2000] := {present: true, iconHicon: 50002}
    _GUI_PreCacheTick()
    GUI_AssertEq(gMock_PreCachedIcons.Count, 1, "PreCacheTick non-present: only 1 cached")
    GUI_AssertTrue(gMock_PreCachedIcons.Has(2000), "PreCacheTick non-present: hwnd 2000 cached")
    GUI_AssertTrue(!gMock_PreCachedIcons.Has(1000), "PreCacheTick non-present: hwnd 1000 skipped")

    ; ----- Test: _GUI_PreCacheTick skips items with iconHicon=0 -----
    GUI_Log("Test: _GUI_PreCacheTick skips items with no icon")
    ResetGUIState()
    gWS_Store[1000] := {present: true, iconHicon: 0}
    gWS_Store[2000] := {present: true, iconHicon: 0}
    _GUI_PreCacheTick()
    GUI_AssertEq(gMock_PreCachedIcons.Count, 0, "PreCacheTick no-icon: nothing cached")

    ; ----- Test: _GUI_PreCacheTick skips already-cached icons -----
    GUI_Log("Test: _GUI_PreCacheTick skips already-cached icons")
    ResetGUIState()
    gWS_Store[1000] := {present: true, iconHicon: 50001}
    gWS_Store[2000] := {present: true, iconHicon: 50002}
    ; Pre-populate icon cache with matching entries
    gGdip_IconCache[1000] := {hicon: 50001, bitmap: 1}
    gGdip_IconCache[2000] := {hicon: 50002, bitmap: 1}
    _GUI_PreCacheTick()
    GUI_AssertEq(gMock_PreCachedIcons.Count, 0, "PreCacheTick cached: nothing re-cached")

    ; ----- Test: _GUI_PreCacheTick replaces stale cache entry (hicon changed) -----
    GUI_Log("Test: _GUI_PreCacheTick replaces stale cache entry")
    ResetGUIState()
    gWS_Store[1000] := {present: true, iconHicon: 60001}  ; New icon
    gGdip_IconCache[1000] := {hicon: 50001, bitmap: 1}     ; Old cached icon
    _GUI_PreCacheTick()
    GUI_AssertEq(gMock_PreCachedIcons.Count, 1, "PreCacheTick stale: 1 icon re-cached")
    GUI_AssertEq(gMock_PreCachedIcons[1000], 60001, "PreCacheTick stale: new hicon cached")

    ; ----- Test: _GUI_PreCacheTick batch limit of 4 per tick -----
    GUI_Log("Test: _GUI_PreCacheTick batch limit of 4")
    ResetGUIState()
    loop 6
        gWS_Store[A_Index * 1000] := {present: true, iconHicon: 70000 + A_Index}
    _GUI_PreCacheTick()
    GUI_AssertEq(gMock_PreCachedIcons.Count, 4, "PreCacheTick batch: only 4 icons cached per tick")

    ; ----- Test: _GUI_PreCacheTick drains remaining on next tick -----
    GUI_Log("Test: _GUI_PreCacheTick drains remaining on subsequent tick")
    ; Continue from previous test (6 items, 4 already cached by mock)
    ; gGdip_IconCache was populated by mock Gdip_PreCacheIcon, so 4 entries exist
    gMock_PreCachedIcons := Map()  ; Reset tracker without full state reset
    _GUI_PreCacheTick()
    GUI_AssertEq(gMock_PreCachedIcons.Count, 2, "PreCacheTick drain: remaining 2 icons cached on next tick")

    ; ----- Test: _GUI_PreCacheTick cache entry with bitmap=0 is stale -----
    GUI_Log("Test: _GUI_PreCacheTick treats bitmap=0 as needing re-cache")
    ResetGUIState()
    gWS_Store[1000] := {present: true, iconHicon: 50001}
    gGdip_IconCache[1000] := {hicon: 50001, bitmap: 0}  ; Same hicon but failed conversion
    _GUI_PreCacheTick()
    GUI_AssertEq(gMock_PreCachedIcons.Count, 1, "PreCacheTick bitmap=0: icon re-cached")

    ; ----- Test: GUI_KickPreCache skips during ACTIVE state -----
    GUI_Log("Test: GUI_KickPreCache skips during ACTIVE state")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gWS_Store[1000] := {present: true, iconHicon: 50001}
    GUI_KickPreCache()
    ; Timer should NOT have been set; verify by calling tick manually after brief wait
    Sleep(500)  ; 10x the timer period for reliability under load
    GUI_AssertEq(gMock_PreCachedIcons.Count, 0, "KickPreCache ACTIVE: timer not set, no icons cached")

    ; ============================================================
    ; _GUI_ActivateFromFrozen GUARD TESTS
    ; ============================================================
    ; _GUI_ActivateFromFrozen validates sel range and window existence.
    ; These tests verify the guards by triggering ALT_UP with rigged state.

    ; ----- Test: sel out of range → no activation (guard catches) -----
    GUI_Log("Test: ActivateFromFrozen sel out of range is safe")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_FirstTabTick := A_TickCount - 500  ; Past quick-switch threshold
    gGUI_OverlayVisible := true
    gGUI_DisplayItems := CreateTestItems(3)
    gGUI_Sel := 5  ; Out of range (only 3 items)
    origMRUFirst := gGUI_LiveItems.Length > 0 ? gGUI_LiveItems[1].hwnd : 0

    ; Fire ALT_UP — calls _GUI_ActivateFromFrozen internally
    global TABBY_EV_ALT_UP
    GUI_OnInterceptorEvent(TABBY_EV_ALT_UP, 0, 0)

    GUI_AssertEq(gGUI_State, "IDLE", "ActivateFromFrozen guard: state returns to IDLE")
    ; No crash = guard worked. MRU should be unchanged (no activation happened).

    ; ----- Test: valid sel but dead hwnd → no activation (IsWindow guard) -----
    GUI_Log("Test: ActivateFromFrozen dead hwnd is safe")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_FirstTabTick := A_TickCount - 500
    gGUI_OverlayVisible := true
    ; Create items with a fake hwnd that will fail IsWindow
    deadItems := [{hwnd: 0xDEAD, title: "Dead Window", class: "X",
                   isOnCurrentWorkspace: true, workspaceName: "Main",
                   lastActivatedTick: A_TickCount, iconHicon: 0, processName: ""}]
    gGUI_DisplayItems := deadItems
    gGUI_Sel := 1
    gGUI_LiveItems := CreateTestItemsWithMap(3)
    origFirst := gGUI_LiveItems[1].hwnd

    GUI_OnInterceptorEvent(TABBY_EV_ALT_UP, 0, 0)

    GUI_AssertEq(gGUI_State, "IDLE", "ActivateFromFrozen dead hwnd: state returns to IDLE")
    GUI_AssertEq(gGUI_LiveItems[1].hwnd, origFirst, "ActivateFromFrozen dead hwnd: MRU unchanged (no activation)")

    ; ============================================================
    ; _GUI_NextValidSel WRAP ARITHMETIC TESTS
    ; ============================================================
    ; Pure math function — wraps index around list, returns 0 on exhaustion.

    GUI_Log("Test: _GUI_NextValidSel wrap arithmetic")
    ; Normal advance: 1→2
    GUI_AssertEq(_GUI_NextValidSel(1, 5, 1), 2, "NextValidSel(1,5,1)=2 (advance)")
    ; Advance at end: 5→1 (wrap)
    GUI_AssertEq(_GUI_NextValidSel(5, 5, 3), 1, "NextValidSel(5,5,3)=1 (wrap to start)")
    ; Advance to 4 = startSel → exhausted (returns 0)
    GUI_AssertEq(_GUI_NextValidSel(3, 5, 4), 0, "NextValidSel(3,5,4)=0 (advance hits startSel=exhausted)")
    ; Advance to 5 ≠ startSel → valid
    GUI_AssertEq(_GUI_NextValidSel(4, 5, 4), 5, "NextValidSel(4,5,4)=5 (advance past startSel)")
    ; Single item: sel=1, list=1, start=1 → wrap to 1 = startSel → 0
    GUI_AssertEq(_GUI_NextValidSel(1, 1, 1), 0, "NextValidSel(1,1,1)=0 (single item exhausted)")
    ; Two items: start at 1 → 2 → wrap to 1 = start → 0
    GUI_AssertEq(_GUI_NextValidSel(1, 2, 1), 2, "NextValidSel(1,2,1)=2 (advance)")
    GUI_AssertEq(_GUI_NextValidSel(2, 2, 1), 0, "NextValidSel(2,2,1)=0 (wrapped back to start)")

    ; ============================================================
    ; _GUI_ActivateFromFrozen RETRY LOOP TESTS
    ; ============================================================
    ; All test hwnds are fake → DllCall("IsWindow") returns false for all.
    ; This means the retry loop will walk the list and exhaust all candidates.

    ; ----- Test: Multi-item exhaustion (3 dead hwnds) -----
    GUI_Log("Test: ActivateFromFrozen retry exhausts 3 dead hwnds")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_FirstTabTick := A_TickCount - 500
    gGUI_OverlayVisible := true
    gGUI_DisplayItems := [
        {hwnd: 0xDEAD1, title: "Dead 1", class: "X", isOnCurrentWorkspace: true, workspaceName: "Main", lastActivatedTick: A_TickCount, iconHicon: 0, processName: ""},
        {hwnd: 0xDEAD2, title: "Dead 2", class: "X", isOnCurrentWorkspace: true, workspaceName: "Main", lastActivatedTick: A_TickCount, iconHicon: 0, processName: ""},
        {hwnd: 0xDEAD3, title: "Dead 3", class: "X", isOnCurrentWorkspace: true, workspaceName: "Main", lastActivatedTick: A_TickCount, iconHicon: 0, processName: ""}
    ]
    gGUI_Sel := 1
    gGUI_LiveItems := CreateTestItemsWithMap(3)
    origFirst := gGUI_LiveItems[1].hwnd

    GUI_OnInterceptorEvent(TABBY_EV_ALT_UP, 0, 0)

    GUI_AssertEq(gGUI_State, "IDLE", "Retry exhaust 3: state returns to IDLE")
    GUI_AssertEq(gGUI_LiveItems[1].hwnd, origFirst, "Retry exhaust 3: MRU unchanged (all dead)")

    ; ----- Test: Depth limit caps search -----
    GUI_Log("Test: ActivateFromFrozen depth limit caps search")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_FirstTabTick := A_TickCount - 500
    gGUI_OverlayVisible := true
    cfg.AltTabActivationRetryDepth := 2  ; Only try 2 of 5
    gGUI_DisplayItems := [
        {hwnd: 0xDD01, title: "D1", class: "X", isOnCurrentWorkspace: true, workspaceName: "Main", lastActivatedTick: A_TickCount, iconHicon: 0, processName: ""},
        {hwnd: 0xDD02, title: "D2", class: "X", isOnCurrentWorkspace: true, workspaceName: "Main", lastActivatedTick: A_TickCount, iconHicon: 0, processName: ""},
        {hwnd: 0xDD03, title: "D3", class: "X", isOnCurrentWorkspace: true, workspaceName: "Main", lastActivatedTick: A_TickCount, iconHicon: 0, processName: ""},
        {hwnd: 0xDD04, title: "D4", class: "X", isOnCurrentWorkspace: true, workspaceName: "Main", lastActivatedTick: A_TickCount, iconHicon: 0, processName: ""},
        {hwnd: 0xDD05, title: "D5", class: "X", isOnCurrentWorkspace: true, workspaceName: "Main", lastActivatedTick: A_TickCount, iconHicon: 0, processName: ""}
    ]
    gGUI_Sel := 1
    gGUI_LiveItems := CreateTestItemsWithMap(3)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_UP, 0, 0)

    ; Depth=2: should try positions 1 and 2, then stop (not check 3, 4, 5)
    ; gGUI_Sel should have advanced to 3 (tried 1→dead, 2→dead, loop exits at maxAttempts)
    GUI_AssertEq(gGUI_State, "IDLE", "Retry depth limit: state returns to IDLE")
    cfg.AltTabActivationRetryDepth := 0  ; Restore default

    ; ----- Test: Retry disabled (legacy path) -----
    GUI_Log("Test: ActivateFromFrozen retry disabled")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_FirstTabTick := A_TickCount - 500
    gGUI_OverlayVisible := true
    cfg.AltTabActivationRetry := false  ; Disable retry
    gGUI_DisplayItems := [
        {hwnd: 0xDE01, title: "Dead", class: "X", isOnCurrentWorkspace: true, workspaceName: "Main", lastActivatedTick: A_TickCount, iconHicon: 0, processName: ""},
        {hwnd: 0xDE02, title: "Dead2", class: "X", isOnCurrentWorkspace: true, workspaceName: "Main", lastActivatedTick: A_TickCount, iconHicon: 0, processName: ""}
    ]
    gGUI_Sel := 1
    gGUI_LiveItems := CreateTestItemsWithMap(3)
    origFirst := gGUI_LiveItems[1].hwnd

    GUI_OnInterceptorEvent(TABBY_EV_ALT_UP, 0, 0)

    GUI_AssertEq(gGUI_State, "IDLE", "Retry disabled: state returns to IDLE")
    GUI_AssertEq(gGUI_LiveItems[1].hwnd, origFirst, "Retry disabled: MRU unchanged (no retry attempted)")
    cfg.AltTabActivationRetry := true  ; Restore default

    ; ============================================================
    ; Stats_AccumulateSession DELTA TRACKING TESTS
    ; ============================================================

    ; ----- Test: All-zero counters → skip (no Stats_Accumulate call) -----
    GUI_Log("Test: Stats_AccumulateSession skips when all counters zero")
    ResetGUIState()
    gMock_LastStatsMsg := ""
    Stats_AccumulateSession()
    GUI_AssertEq(gMock_LastStatsMsg, "", "StatsAccum zero: no message sent (skip-on-zero)")

    ; ----- Test: Non-zero counters → correct delta Map with only non-zero keys -----
    GUI_Log("Test: Stats_AccumulateSession sends correct deltas")
    ResetGUIState()
    gStats_AltTabs := 5
    gStats_TabSteps := 3
    Stats_AccumulateSession()
    GUI_AssertTrue(IsObject(gMock_LastStatsMsg), "StatsAccum deltas: message is a Map")
    if (IsObject(gMock_LastStatsMsg)) {
        GUI_AssertEq(gMock_LastStatsMsg["TotalAltTabs"], 5, "StatsAccum deltas: TotalAltTabs=5")
        GUI_AssertEq(gMock_LastStatsMsg["TotalTabSteps"], 3, "StatsAccum deltas: TotalTabSteps=3")
        GUI_AssertTrue(!gMock_LastStatsMsg.Has("TotalQuickSwitches"), "StatsAccum deltas: zero-delta key omitted (QuickSwitches)")
        GUI_AssertTrue(!gMock_LastStatsMsg.Has("TotalCancellations"), "StatsAccum deltas: zero-delta key omitted (Cancellations)")
    }

    ; ----- Test: Second call without new increments → skip (LastSent bookkeeping) -----
    GUI_Log("Test: Stats_AccumulateSession skips on repeated call (LastSent tracks sent)")
    ; Continue from previous test — counters unchanged, LastSent recorded
    gMock_LastStatsMsg := ""
    Stats_AccumulateSession()
    GUI_AssertEq(gMock_LastStatsMsg, "", "StatsAccum repeat: no message (deltas are zero)")

    ; ----- Test: Incremental delta after previous send -----
    GUI_Log("Test: Stats_AccumulateSession sends only new increments")
    ; Continue from previous — LastSent has AltTabs=5, TabSteps=3
    gStats_Cancellations := 1
    gMock_LastStatsMsg := ""
    Stats_AccumulateSession()
    GUI_AssertTrue(IsObject(gMock_LastStatsMsg), "StatsAccum incr: message sent")
    if (IsObject(gMock_LastStatsMsg)) {
        GUI_AssertEq(gMock_LastStatsMsg["TotalCancellations"], 1, "StatsAccum incr: TotalCancellations=1")
        GUI_AssertTrue(!gMock_LastStatsMsg.Has("TotalAltTabs"), "StatsAccum incr: AltTabs omitted (no new increment)")
    }

    ; ============================================================
    ; _GUI_HandleWorkspaceSwitch WORKSPACE DATA PATCHING TESTS
    ; ============================================================

    ; ----- Test: Frozen record refs have live workspace data after switch -----
    ; #178: Frozen items ARE store records. WL_SetCurrentWorkspace already flipped
    ; isOnCurrentWorkspace on the records before HandleWorkspaceSwitch runs.
    ; Test verifies re-filter sees correct data and selection resets.
    GUI_Log("Test: HandleWorkspaceSwitch re-filters with live record data")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_OverlayVisible := true
    gGUI_CurrentWSName := "New"

    ; Build frozen items as record refs — workspace data already correct
    ; (simulates WL_SetCurrentWorkspace having already flipped the fields)
    items := CreateTestItems(3)
    items[1].workspaceName := "New"
    items[1].isOnCurrentWorkspace := true
    items[2].workspaceName := "New"
    items[2].isOnCurrentWorkspace := true
    items[3].workspaceName := "Other"
    items[3].isOnCurrentWorkspace := false
    gGUI_ToggleBase := items
    gGUI_DisplayItems := items.Clone()

    _GUI_HandleWorkspaceSwitch()

    GUI_AssertEq(items[1].workspaceName, "New", "WSPatch: item 1 workspaceName is 'New'")
    GUI_AssertEq(items[1].isOnCurrentWorkspace, true, "WSPatch: item 1 isOnCurrentWorkspace true")
    GUI_AssertEq(items[2].workspaceName, "New", "WSPatch: item 2 workspaceName is 'New'")
    GUI_AssertEq(items[2].isOnCurrentWorkspace, true, "WSPatch: item 2 isOnCurrentWorkspace true")
    GUI_AssertEq(items[3].workspaceName, "Other", "WSPatch: item 3 workspaceName unchanged")
    GUI_AssertEq(items[3].isOnCurrentWorkspace, false, "WSPatch: item 3 isOnCurrentWorkspace false (Other!=New)")

    ; ----- Test: Items already on current workspace stay unchanged -----
    GUI_Log("Test: HandleWorkspaceSwitch no-op when workspace matches")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_OverlayVisible := true
    gGUI_CurrentWSName := "Main"

    items := CreateTestItems(2)
    items[1].workspaceName := "Main"
    items[1].isOnCurrentWorkspace := true
    gGUI_ToggleBase := items
    gGUI_DisplayItems := items.Clone()

    _GUI_HandleWorkspaceSwitch()

    GUI_AssertEq(items[1].workspaceName, "Main", "WSPatch noop: workspaceName unchanged")
    GUI_AssertEq(items[1].isOnCurrentWorkspace, true, "WSPatch noop: isOnCurrentWorkspace still true")

    ; ============================================================
    ; GUI_RemoveLiveItemAt TESTS
    ; ============================================================

    ; ----- Test: Remove middle item -----
    GUI_Log("Test: RemoveLiveItemAt removes middle item")
    ResetGUIState()
    gGUI_LiveItems := CreateTestItemsWithMap(3)

    remaining := GUI_RemoveLiveItemAt(2)
    GUI_AssertEq(remaining, 2, "RemoveMiddle: 2 items remain")
    GUI_AssertEq(gGUI_LiveItems[1].hwnd, 1000, "RemoveMiddle: first item unchanged")
    GUI_AssertEq(gGUI_LiveItems[2].hwnd, 3000, "RemoveMiddle: third item shifted to idx 2")
    GUI_AssertTrue(!gGUI_LiveItemsMap.Has(2000), "RemoveMiddle: hwnd 2000 removed from map")
    GUI_AssertTrue(gGUI_LiveItemsMap.Has(1000), "RemoveMiddle: hwnd 1000 still in map")
    GUI_AssertTrue(gGUI_LiveItemsMap.Has(3000), "RemoveMiddle: hwnd 3000 still in map")

    ; ----- Test: Remove first item -----
    GUI_Log("Test: RemoveLiveItemAt removes first item")
    ResetGUIState()
    gGUI_LiveItems := CreateTestItemsWithMap(3)

    remaining := GUI_RemoveLiveItemAt(1)
    GUI_AssertEq(remaining, 2, "RemoveFirst: 2 items remain")
    GUI_AssertEq(gGUI_LiveItems[1].hwnd, 2000, "RemoveFirst: second item shifted to idx 1")
    GUI_AssertTrue(!gGUI_LiveItemsMap.Has(1000), "RemoveFirst: hwnd 1000 removed from map")

    ; ----- Test: Remove last item -----
    GUI_Log("Test: RemoveLiveItemAt removes last item")
    ResetGUIState()
    gGUI_LiveItems := CreateTestItemsWithMap(3)

    remaining := GUI_RemoveLiveItemAt(3)
    GUI_AssertEq(remaining, 2, "RemoveLast: 2 items remain")
    GUI_AssertTrue(!gGUI_LiveItemsMap.Has(3000), "RemoveLast: hwnd 3000 removed from map")
    GUI_AssertTrue(gGUI_LiveItemsMap.Has(1000), "RemoveLast: hwnd 1000 still in map")

    ; ----- Test: Remove only item → both empty -----
    GUI_Log("Test: RemoveLiveItemAt removes only item")
    ResetGUIState()
    gGUI_LiveItems := CreateTestItemsWithMap(1)

    remaining := GUI_RemoveLiveItemAt(1)
    GUI_AssertEq(remaining, 0, "RemoveOnly: 0 items remain")
    GUI_AssertEq(gGUI_LiveItemsMap.Count, 0, "RemoveOnly: map is empty")

    ; ----- Test: Out-of-bounds idx=0 → no-op -----
    GUI_Log("Test: RemoveLiveItemAt out-of-bounds idx=0")
    ResetGUIState()
    gGUI_LiveItems := CreateTestItemsWithMap(3)

    remaining := GUI_RemoveLiveItemAt(0)
    GUI_AssertEq(remaining, 3, "OOB idx=0: 3 items unchanged")
    GUI_AssertEq(gGUI_LiveItemsMap.Count, 3, "OOB idx=0: map unchanged")

    ; ----- Test: Out-of-bounds idx > length → no-op -----
    GUI_Log("Test: RemoveLiveItemAt out-of-bounds idx=99")
    ResetGUIState()
    gGUI_LiveItems := CreateTestItemsWithMap(3)

    remaining := GUI_RemoveLiveItemAt(99)
    GUI_AssertEq(remaining, 3, "OOB idx=99: 3 items unchanged")
    GUI_AssertEq(gGUI_LiveItemsMap.Count, 3, "OOB idx=99: map unchanged")

    ; ============================================================
    ; HOVER CLEARING DURING WORKSPACE SWITCH TESTS
    ; Regression guard for #180: action button hover icons flash
    ; at wrong row during workspace switch resize.
    ; ============================================================

    ; ----- Test: HandleWorkspaceSwitch clears hover state -----
    GUI_Log("Test: HandleWorkspaceSwitch clears hover state (#180)")
    ResetGUIState()
    global gGUI_HoverRow, gGUI_HoverBtn, gMock_RefreshBackdropCount
    gGUI_State := "ACTIVE"
    gGUI_OverlayVisible := true
    gGUI_CurrentWSName := "Main"
    gGUI_HoverRow := 3
    gGUI_HoverBtn := "close"
    items := CreateTestItems(5)
    gGUI_ToggleBase := items
    gGUI_DisplayItems := items.Clone()

    _GUI_HandleWorkspaceSwitch()

    GUI_AssertEq(gGUI_HoverRow, 0, "WSHover: gGUI_HoverRow cleared to 0")
    GUI_AssertEq(gGUI_HoverBtn, "", "WSHover: gGUI_HoverBtn cleared to empty")
    GUI_AssertTrue(gMock_RefreshBackdropCount > 0, "WSHover: GUI_RefreshBackdrop called (#235 regression)")

    ; ----- Test: HandleWorkspaceSwitch hover clear + sel reset + WSContextSwitch -----
    GUI_Log("Test: HandleWorkspaceSwitch full state update")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_OverlayVisible := true
    gGUI_CurrentWSName := "Beta"
    gGUI_HoverRow := 2
    gGUI_HoverBtn := "kill"
    gGUI_Sel := 4
    gGUI_ScrollTop := 3
    items := CreateTestItems(6)
    gGUI_ToggleBase := items
    gGUI_DisplayItems := items.Clone()

    _GUI_HandleWorkspaceSwitch()

    GUI_AssertEq(gGUI_HoverRow, 0, "WSHoverFull: hover row cleared")
    GUI_AssertEq(gGUI_HoverBtn, "", "WSHoverFull: hover btn cleared")
    GUI_AssertEq(gGUI_WSContextSwitch, true, "WSHoverFull: WSContextSwitch set")
    GUI_AssertEq(gGUI_Sel, 1, "WSHoverFull: sel reset to 1")
    GUI_AssertEq(gGUI_ScrollTop, 0, "WSHoverFull: scrollTop reset to 0")

    ; ============================================================
    ; GUI_OnWheel TESTS
    ; Covers wParam bit manipulation and config branching.
    ; ============================================================

    ; ----- Test: OnWheel scroll down (default config) -----
    GUI_Log("Test: OnWheel scroll down (viewport scroll)")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_OverlayVisible := true
    gGUI_DisplayItems := CreateTestItems(12)
    gGUI_Sel := 1
    gGUI_ScrollTop := 0
    gMock_VisibleRows := 5
    cfg.GUI_ScrollKeepHighlightOnTop := false

    savedScrollTop := gGUI_ScrollTop
    ; delta = -120 encoded in wParam: 0xFF880000 (0xFF88 = 65416 = 0x10000 - 120 = -120 unsigned)
    GUI_OnWheel(0xFF880000, 0)
    GUI_AssertTrue(gGUI_ScrollTop != savedScrollTop, "OnWheel down: scrollTop changed")

    ; ----- Test: OnWheel scroll up -----
    GUI_Log("Test: OnWheel scroll up")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_OverlayVisible := true
    gGUI_DisplayItems := CreateTestItems(12)
    gGUI_Sel := 1
    gGUI_ScrollTop := 3
    gMock_VisibleRows := 5
    cfg.GUI_ScrollKeepHighlightOnTop := false

    savedScrollTop := gGUI_ScrollTop
    ; delta = +120 encoded in wParam: 0x00780000 (0x0078 = 120)
    GUI_OnWheel(0x00780000, 0)
    GUI_AssertTrue(gGUI_ScrollTop != savedScrollTop, "OnWheel up: scrollTop changed")
    GUI_AssertTrue(gGUI_ScrollTop < savedScrollTop, "OnWheel up: scrollTop decreased")

    ; ----- Test: OnWheel with ScrollKeepHighlightOnTop moves selection -----
    GUI_Log("Test: OnWheel with ScrollKeepHighlightOnTop moves selection")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_OverlayVisible := true
    gGUI_DisplayItems := CreateTestItems(12)
    gGUI_Sel := 1
    gGUI_ScrollTop := 0
    gMock_VisibleRows := 5
    cfg.GUI_ScrollKeepHighlightOnTop := true

    savedSel := gGUI_Sel
    ; Scroll down → moves selection forward
    GUI_OnWheel(0xFF880000, 0)
    GUI_AssertTrue(gGUI_Sel != savedSel, "OnWheel KeepHighlight: selection changed")
    GUI_AssertEq(gGUI_Sel, 2, "OnWheel KeepHighlight: sel moved to 2")
    cfg.GUI_ScrollKeepHighlightOnTop := false  ; Restore

    ; ----- Test: OnWheel when overlay not visible → no-op -----
    GUI_Log("Test: OnWheel overlay not visible is no-op")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_OverlayVisible := false
    gGUI_DisplayItems := CreateTestItems(12)
    gGUI_Sel := 1
    gGUI_ScrollTop := 0
    gMock_VisibleRows := 5

    GUI_OnWheel(0xFF880000, 0)
    GUI_AssertEq(gGUI_ScrollTop, 0, "OnWheel hidden: scrollTop unchanged")
    GUI_AssertEq(gGUI_Sel, 1, "OnWheel hidden: sel unchanged")

    ; ============================================================
    ; GUI_OnWorkspaceFlips CALLBACK TESTS
    ; Covers the workspace change entry point that reads gWS_Meta
    ; and calls _GUI_HandleWorkspaceSwitch.
    ; ============================================================

    ; ----- Test: OnWorkspaceFlips detects workspace change -----
    GUI_Log("Test: OnWorkspaceFlips detects workspace name change")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_OverlayVisible := true
    gGUI_CurrentWSName := "Main"
    global gWS_Meta
    gWS_Meta := Map("currentWSName", "Beta")
    items := CreateTestItems(5)
    gGUI_ToggleBase := items
    gGUI_DisplayItems := items.Clone()

    GUI_OnWorkspaceFlips()

    GUI_AssertEq(gGUI_CurrentWSName, "Beta", "WSFlips: currentWSName updated to Beta")
    GUI_AssertEq(gGUI_WSContextSwitch, true, "WSFlips: WSContextSwitch set")
    GUI_AssertEq(gGUI_Sel, 1, "WSFlips: sel reset to 1")

    ; ----- Test: OnWorkspaceFlips same workspace → no-op -----
    GUI_Log("Test: OnWorkspaceFlips same workspace is no-op")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_OverlayVisible := true
    gGUI_CurrentWSName := "Main"
    gGUI_Sel := 3
    gWS_Meta := Map("currentWSName", "Main")
    items := CreateTestItems(5)
    gGUI_ToggleBase := items
    gGUI_DisplayItems := items.Clone()

    GUI_OnWorkspaceFlips()

    GUI_AssertEq(gGUI_CurrentWSName, "Main", "WSFlips noop: currentWSName unchanged")
    GUI_AssertEq(gGUI_WSContextSwitch, false, "WSFlips noop: WSContextSwitch not set")
    GUI_AssertEq(gGUI_Sel, 3, "WSFlips noop: sel preserved")

    ; ----- Test: OnWorkspaceFlips with non-object gWS_Meta → no crash -----
    GUI_Log("Test: OnWorkspaceFlips with non-object gWS_Meta is safe")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_CurrentWSName := "Main"
    gWS_Meta := 0  ; Not an object

    GUI_OnWorkspaceFlips()

    GUI_AssertEq(gGUI_CurrentWSName, "Main", "WSFlips non-object: currentWSName unchanged (no crash)")

    ; ----- Test: OnWorkspaceFlips with empty currentWSName in meta → no-op -----
    GUI_Log("Test: OnWorkspaceFlips with empty meta workspace is no-op")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_CurrentWSName := "Main"
    gWS_Meta := Map("currentWSName", "")

    GUI_OnWorkspaceFlips()

    GUI_AssertEq(gGUI_CurrentWSName, "Main", "WSFlips empty: currentWSName unchanged")

    ; Restore gWS_Meta to Map for cleanup
    gWS_Meta := Map()

    ; ============================================================
    ; DISPLAY ITEM EVICTION DURING ACTIVE (#178 followup)
    ; Tests GUI_EvictDisplayItem hwnd-tracked selection and
    ; GUI_ReconcileDestroys store-based dead window detection.
    ; ============================================================

    ; ----- Test: Evict item ABOVE selection — selection tracks same hwnd -----
    GUI_Log("Test: Evict above selection — sel tracks same hwnd")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    items := CreateTestItems(5)
    gGUI_LiveItems := items.Clone()
    gGUI_LiveItemsMap := Map()
    for _, item in gGUI_LiveItems
        gGUI_LiveItemsMap[item.hwnd] := item
    gGUI_ToggleBase := items.Clone()
    gGUI_DisplayItems := items.Clone()
    gGUI_Sel := 3  ; Selected hwnd = 3000
    gGUI_ScrollTop := 2

    remaining := GUI_EvictDisplayItem(1)  ; Remove item above sel (hwnd=1000)

    GUI_AssertEq(remaining, 4, "EvictAbove: 4 items remaining")
    GUI_AssertEq(gGUI_Sel, 2, "EvictAbove: sel adjusted from 3 to 2 (same hwnd 3000)")
    ; Verify the selected item IS hwnd 3000
    GUI_AssertEq(gGUI_DisplayItems[gGUI_Sel].hwnd, 3000, "EvictAbove: selected item hwnd=3000")

    ; ----- Test: Evict the SELECTED item — clamp to next -----
    GUI_Log("Test: Evict selected item — clamp to next")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    items := CreateTestItems(5)
    gGUI_LiveItems := items.Clone()
    gGUI_LiveItemsMap := Map()
    for _, item in gGUI_LiveItems
        gGUI_LiveItemsMap[item.hwnd] := item
    gGUI_ToggleBase := items.Clone()
    gGUI_DisplayItems := items.Clone()
    gGUI_Sel := 3  ; Selected hwnd = 3000

    remaining := GUI_EvictDisplayItem(3)  ; Remove the selected item

    GUI_AssertEq(remaining, 4, "EvictSel: 4 items remaining")
    GUI_AssertEq(gGUI_Sel, 3, "EvictSel: sel clamped to 3 (next item slides up)")
    GUI_AssertEq(gGUI_DisplayItems[gGUI_Sel].hwnd, 4000, "EvictSel: now pointing at hwnd=4000")

    ; ----- Test: Evict item BELOW selection — no change -----
    GUI_Log("Test: Evict below selection — sel unchanged")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    items := CreateTestItems(5)
    gGUI_LiveItems := items.Clone()
    gGUI_LiveItemsMap := Map()
    for _, item in gGUI_LiveItems
        gGUI_LiveItemsMap[item.hwnd] := item
    gGUI_ToggleBase := items.Clone()
    gGUI_DisplayItems := items.Clone()
    gGUI_Sel := 2  ; Selected hwnd = 2000

    remaining := GUI_EvictDisplayItem(4)  ; Remove item below sel (hwnd=4000)

    GUI_AssertEq(remaining, 4, "EvictBelow: 4 items remaining")
    GUI_AssertEq(gGUI_Sel, 2, "EvictBelow: sel unchanged at 2")
    GUI_AssertEq(gGUI_DisplayItems[gGUI_Sel].hwnd, 2000, "EvictBelow: still pointing at hwnd=2000")

    ; ----- Test: Evict last item when selected — sel decrements to new last -----
    GUI_Log("Test: Evict last item when selected — sel decrements")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    items := CreateTestItems(4)
    gGUI_LiveItems := items.Clone()
    gGUI_LiveItemsMap := Map()
    for _, item in gGUI_LiveItems
        gGUI_LiveItemsMap[item.hwnd] := item
    gGUI_ToggleBase := items.Clone()
    gGUI_DisplayItems := items.Clone()
    gGUI_Sel := 4  ; Last item selected (hwnd=4000)

    remaining := GUI_EvictDisplayItem(4)

    GUI_AssertEq(remaining, 3, "EvictLast: 3 items remaining")
    GUI_AssertEq(gGUI_Sel, 3, "EvictLast: sel clamped to new last (3)")
    GUI_AssertEq(gGUI_DisplayItems[gGUI_Sel].hwnd, 3000, "EvictLast: pointing at hwnd=3000")

    ; ----- Test: Evict all items — triggers empty state -----
    GUI_Log("Test: Evict all items — empty display list")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    items := CreateTestItems(1)
    gGUI_LiveItems := items.Clone()
    gGUI_LiveItemsMap := Map()
    gGUI_LiveItemsMap[items[1].hwnd] := items[1]
    gGUI_ToggleBase := items.Clone()
    gGUI_DisplayItems := items.Clone()
    gGUI_Sel := 1

    remaining := GUI_EvictDisplayItem(1)

    GUI_AssertEq(remaining, 0, "EvictAll: 0 items remaining")
    GUI_AssertEq(gGUI_Sel, 1, "EvictAll: sel reset to 1")
    GUI_AssertEq(gGUI_ScrollTop, 0, "EvictAll: scrollTop reset to 0")

    ; ----- Test: ToggleBase consistency — evict removes from both arrays -----
    GUI_Log("Test: ToggleBase consistency after evict")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    items := CreateTestItems(5, 3)  ; 3 on current WS, 2 on other
    gGUI_LiveItems := items.Clone()
    gGUI_LiveItemsMap := Map()
    for _, item in gGUI_LiveItems
        gGUI_LiveItemsMap[item.hwnd] := item
    gGUI_ToggleBase := items.Clone()
    ; Simulate WS filtering: display only current-WS items
    gGUI_DisplayItems := []
    for _, item in items {
        if (item.isOnCurrentWorkspace)
            gGUI_DisplayItems.Push(item)
    }
    gGUI_Sel := 1

    ; Evict from display (hwnd=1000) — should also remove from ToggleBase
    GUI_EvictDisplayItem(1)

    ; Verify ToggleBase doesn't contain hwnd=1000
    found := false
    for _, item in gGUI_ToggleBase {
        if (item.hwnd = 1000) {
            found := true
            break
        }
    }
    GUI_AssertTrue(!found, "ToggleBase: hwnd=1000 removed from ToggleBase")
    GUI_AssertEq(gGUI_ToggleBase.Length, 4, "ToggleBase: length reduced from 5 to 4")
    GUI_AssertEq(gGUI_DisplayItems.Length, 2, "ToggleBase: display length reduced from 3 to 2")

    ; ----- Test: ReconcileDestroys detects store-removed items -----
    GUI_Log("Test: ReconcileDestroys removes dead windows")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_OverlayVisible := true
    items := CreateTestItems(5)
    gGUI_LiveItems := items.Clone()
    gGUI_LiveItemsMap := Map()
    for _, item in gGUI_LiveItems
        gGUI_LiveItemsMap[item.hwnd] := item
    gGUI_ToggleBase := items.Clone()
    gGUI_DisplayItems := items.Clone()
    gGUI_Sel := 2

    ; Simulate store: only hwnds 1000, 2000, 4000 exist (3000 and 5000 destroyed)
    gWS_Store := Map()
    gWS_Store[1000] := {present: true}
    gWS_Store[2000] := {present: true}
    gWS_Store[4000] := {present: true}

    removed := GUI_ReconcileDestroys()

    GUI_AssertEq(removed, 2, "Reconcile: 2 items removed")
    GUI_AssertEq(gGUI_DisplayItems.Length, 3, "Reconcile: 3 items remaining")
    ; Verify only surviving hwnds remain
    hwnds := []
    for _, item in gGUI_DisplayItems
        hwnds.Push(item.hwnd)
    GUI_AssertTrue(hwnds[1] = 1000, "Reconcile: first item hwnd=1000")
    GUI_AssertTrue(hwnds[2] = 2000, "Reconcile: second item hwnd=2000")
    GUI_AssertTrue(hwnds[3] = 4000, "Reconcile: third item hwnd=4000")
    ; Selection should track hwnd=2000 (was sel=2, stays sel=2)
    GUI_AssertEq(gGUI_Sel, 2, "Reconcile: sel=2 tracks hwnd=2000")

    ; ----- Test: ReconcileDestroys all dead — triggers dismiss -----
    GUI_Log("Test: ReconcileDestroys all dead — dismisses overlay")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_OverlayVisible := true
    items := CreateTestItems(3)
    gGUI_LiveItems := items.Clone()
    gGUI_LiveItemsMap := Map()
    for _, item in gGUI_LiveItems
        gGUI_LiveItemsMap[item.hwnd] := item
    gGUI_ToggleBase := items.Clone()
    gGUI_DisplayItems := items.Clone()
    gGUI_Sel := 1
    ; Mock store to populate for RefreshLiveItems during dismiss
    MockStore_SetItems([])

    ; Empty store — all 3 items are dead
    gWS_Store := Map()

    removed := GUI_ReconcileDestroys()

    GUI_AssertEq(removed, 3, "ReconcileAll: 3 items removed")
    GUI_AssertEq(gGUI_State, "IDLE", "ReconcileAll: state returned to IDLE")
    GUI_AssertEq(gGUI_OverlayVisible, false, "ReconcileAll: overlay hidden")

    ; ----- Test: ReconcileDestroys skips during non-ACTIVE state -----
    GUI_Log("Test: ReconcileDestroys skips during IDLE")
    ResetGUIState()
    gGUI_State := "IDLE"
    gGUI_DisplayItems := CreateTestItems(3)
    gWS_Store := Map()  ; Empty store

    removed := GUI_ReconcileDestroys()

    GUI_AssertEq(removed, 0, "ReconcileIdle: 0 removed (skipped)")
    GUI_AssertEq(gGUI_DisplayItems.Length, 3, "ReconcileIdle: display list unchanged")

    ; ----- Test: Close button during ACTIVE evicts from display list -----
    GUI_Log("Test: _GUI_RemoveItemAt during ACTIVE uses eviction path")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_OverlayVisible := true
    items := CreateTestItems(5)
    gGUI_LiveItems := items.Clone()
    gGUI_LiveItemsMap := Map()
    for _, item in gGUI_LiveItems
        gGUI_LiveItemsMap[item.hwnd] := item
    gGUI_ToggleBase := items.Clone()
    gGUI_DisplayItems := items.Clone()
    gGUI_Sel := 3  ; hwnd=3000

    _GUI_RemoveItemAt(2)  ; Close button on item above selection

    GUI_AssertEq(gGUI_DisplayItems.Length, 4, "CloseActive: 4 items in display list")
    GUI_AssertEq(gGUI_Sel, 2, "CloseActive: sel tracked hwnd=3000 at new index 2")
    GUI_AssertEq(gGUI_DisplayItems[gGUI_Sel].hwnd, 3000, "CloseActive: selected item is hwnd=3000")
    GUI_AssertEq(gGUI_LiveItems.Length, 4, "CloseActive: live items also reduced")

    ; ============================================================
    ; REFERENCE-BASED FREEZE INVARIANTS (#178 followup tests)
    ; Verify the core invariant: store record mutations are visible
    ; through frozen display items, and structural guards work.
    ; ============================================================

    ; ----- Test: Live record refs — title change visible through frozen display -----
    GUI_Log("Test: Live ref — title mutation visible through gGUI_DisplayItems")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    items := CreateTestItems(3)
    gGUI_LiveItems := items
    gGUI_LiveItemsMap := Map()
    for _, item in items
        gGUI_LiveItemsMap[item.hwnd] := item
    gGUI_DisplayItems := items  ; Same references (no .Clone())
    gGUI_ToggleBase := items
    gGUI_Sel := 2

    ; Mutate the store record directly (simulates producer updating title)
    items[2].title := "Renamed Window"
    items[2].processName := "newproc.exe"
    items[2].iconHicon := 42

    ; Display items should see the mutation immediately (same object reference)
    GUI_AssertEq(gGUI_DisplayItems[2].title, "Renamed Window", "LiveRef: title mutation visible")
    GUI_AssertEq(gGUI_DisplayItems[2].processName, "newproc.exe", "LiveRef: processName mutation visible")
    GUI_AssertEq(gGUI_DisplayItems[2].iconHicon, 42, "LiveRef: iconHicon mutation visible")
    ; Verify other items unchanged
    GUI_AssertEq(gGUI_DisplayItems[1].title, "Window 1", "LiveRef: item 1 unchanged")
    GUI_AssertEq(gGUI_DisplayItems[3].title, "Window 3", "LiveRef: item 3 unchanged")

    ; ----- Test: Live record refs — workspace field change visible for re-filter -----
    GUI_Log("Test: Live ref — workspace field change visible for toggle re-filter")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_CurrentWSName := "Main"
    items := CreateTestItems(4, 3)  ; 3 on Main, 1 on Other
    gGUI_LiveItems := items
    gGUI_LiveItemsMap := Map()
    for _, item in items
        gGUI_LiveItemsMap[item.hwnd] := item
    gGUI_ToggleBase := items
    gGUI_DisplayItems := items
    gGUI_Sel := 1

    ; Simulate workspace switch: flip isOnCurrentWorkspace on record (like WL_SetCurrentWorkspace does)
    items[1].isOnCurrentWorkspace := false
    items[4].isOnCurrentWorkspace := true

    ; Display items should see the flipped values immediately
    GUI_AssertEq(gGUI_DisplayItems[1].isOnCurrentWorkspace, false, "LiveRef: ws flip visible on item 1")
    GUI_AssertEq(gGUI_DisplayItems[4].isOnCurrentWorkspace, true, "LiveRef: ws flip visible on item 4")

    ; ----- Test: Evict when ToggleBase IS DisplayItems (same array, no filtering) -----
    GUI_Log("Test: Evict with same-array ToggleBase (ObjPtr guard)")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    items := CreateTestItems(4)
    gGUI_LiveItems := items.Clone()
    gGUI_LiveItemsMap := Map()
    for _, item in gGUI_LiveItems
        gGUI_LiveItemsMap[item.hwnd] := item
    ; Key: ToggleBase and DisplayItems are the SAME array reference
    gGUI_ToggleBase := items
    gGUI_DisplayItems := items
    GUI_AssertEq(ObjPtr(gGUI_ToggleBase), ObjPtr(gGUI_DisplayItems), "SameArray: confirmed same ObjPtr")
    gGUI_Sel := 3  ; hwnd=3000

    remaining := GUI_EvictDisplayItem(1)  ; Evict hwnd=1000

    GUI_AssertEq(remaining, 3, "SameArray: 3 items remaining")
    GUI_AssertEq(gGUI_Sel, 2, "SameArray: sel tracked hwnd=3000 at index 2")
    GUI_AssertEq(gGUI_DisplayItems[gGUI_Sel].hwnd, 3000, "SameArray: correct hwnd selected")
    ; ToggleBase IS DisplayItems — both should have 3 items (single RemoveAt, not double)
    GUI_AssertEq(gGUI_ToggleBase.Length, 3, "SameArray: ToggleBase also has 3 (same array)")
    GUI_AssertEq(ObjPtr(gGUI_ToggleBase), ObjPtr(gGUI_DisplayItems), "SameArray: still same ObjPtr after evict")

    ; ----- Test: GUI_DismissOverlay resets all state correctly -----
    GUI_Log("Test: GUI_DismissOverlay resets state to IDLE")
    ResetGUIState()
    ; Set up ACTIVE state with visible overlay
    gGUI_State := "ACTIVE"
    gGUI_OverlayVisible := true
    items := CreateTestItems(3)
    gGUI_LiveItems := items
    gGUI_LiveItemsMap := Map()
    for _, item in items
        gGUI_LiveItemsMap[item.hwnd] := item
    gGUI_DisplayItems := items
    gGUI_ToggleBase := items
    gGUI_Sel := 2
    gGUI_ScrollTop := 1
    ; Bump a stat so Stats_AccumulateSession has something to send
    gStats_AltTabs := 1
    ; Populate mock store so RefreshLiveItems (called by DismissOverlay) has data
    MockStore_SetItems(CreateTestItems(3))

    GUI_DismissOverlay()

    GUI_AssertEq(gGUI_State, "IDLE", "Dismiss: state is IDLE")
    GUI_AssertEq(gGUI_OverlayVisible, false, "Dismiss: overlay hidden")
    GUI_AssertEq(gGUI_DisplayItems.Length, 0, "Dismiss: display items cleared")
    GUI_AssertTrue(gMock_LastStatsMsg != "", "Dismiss: Stats_AccumulateSession called")

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
    try FileDelete(GUI_TestLogPath)
    result := RunGUITests_Data()
    ExitApp(result ? 0 : 1)
}
