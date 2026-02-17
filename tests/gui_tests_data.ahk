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
    global gGUI_EventBuffer, gGUI_PendingPhase
    global gGUI_LiveItemsMap, gMock_VisibleRows
    global gMock_BypassResult, gINT_BypassMode, gMock_PruneCalledWith, gMock_PreCachedIcons
    global gGUI_Base, gGUI_Overlay, gGdip_IconCache
    global gMock_StoreItems, gMock_StoreItemsMap

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

    ; Call the real production activation function with a fake item.
    ; _GUI_RobustActivate will return false (WinExist fails for fake hwnds),
    ; so the production guard should prevent _GUI_UpdateLocalMRU from running.
    fakeItem := { hwnd: origSecond, isOnCurrentWorkspace: true, WS: "" }
    _GUI_ActivateItem(fakeItem)

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

    ; ----- Test: _GUI_RemoveItemAt out-of-bounds is no-op -----
    GUI_Log("Test: _GUI_RemoveItemAt out-of-bounds")
    ResetGUIState()
    gGUI_LiveItems := CreateTestItems(3)

    _GUI_RemoveItemAt(0)
    GUI_AssertEq(gGUI_LiveItems.Length, 3, "RemoveItemAt 0: no-op")

    _GUI_RemoveItemAt(4)
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
    SetupTestItems(5)  ; Mock store needed for workspace switch context
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
    SetupTestItems(5)  ; Mock store needed for workspace switch context
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
    gGUI_CurrentWSName := "Alpha"
    gGUI_Sel := 3  ; Start with different selection
    gGUI_WSContextSwitch := false

    ; Simulate workspace change notification
    payload := Map("meta", Map("currentWSName", "Beta"))
    GUI_UpdateCurrentWSFromPayload(payload)

    GUI_AssertEq(gGUI_CurrentWSName, "Beta", "WS change: workspace updated")
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
    payload := Map("meta", Map("currentWSName", "Other"))
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
    gGUI_Sel := 3  ; Start at non-1 to verify production code resets it
    SetupTestItems(1)

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
    SetupTestItems(5)
    gGUI_PendingPhase := "flushing"

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
    SetupTestItems(5)
    gGUI_PendingPhase := "flushing"

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
        gGdip_IconCache[A_Index * 1000] := {hicon: 90000 + A_Index * 1000, pBmp: 0}

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
    gGdip_IconCache[1000] := {hicon: 50001, pBmp: 1}
    gGdip_IconCache[2000] := {hicon: 50002, pBmp: 1}
    _GUI_PreCacheTick()
    GUI_AssertEq(gMock_PreCachedIcons.Count, 0, "PreCacheTick cached: nothing re-cached")

    ; ----- Test: _GUI_PreCacheTick replaces stale cache entry (hicon changed) -----
    GUI_Log("Test: _GUI_PreCacheTick replaces stale cache entry")
    ResetGUIState()
    gWS_Store[1000] := {present: true, iconHicon: 60001}  ; New icon
    gGdip_IconCache[1000] := {hicon: 50001, pBmp: 1}      ; Old cached icon
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

    ; ----- Test: _GUI_PreCacheTick cache entry with pBmp=0 is stale -----
    GUI_Log("Test: _GUI_PreCacheTick treats pBmp=0 as needing re-cache")
    ResetGUIState()
    gWS_Store[1000] := {present: true, iconHicon: 50001}
    gGdip_IconCache[1000] := {hicon: 50001, pBmp: 0}  ; Same hicon but failed conversion
    _GUI_PreCacheTick()
    GUI_AssertEq(gMock_PreCachedIcons.Count, 1, "PreCacheTick pBmp=0: icon re-cached")

    ; ----- Test: GUI_KickPreCache skips during ACTIVE state -----
    GUI_Log("Test: GUI_KickPreCache skips during ACTIVE state")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gWS_Store[1000] := {present: true, iconHicon: 50001}
    GUI_KickPreCache()
    ; Timer should NOT have been set; verify by calling tick manually after brief wait
    Sleep(60)
    GUI_AssertEq(gMock_PreCachedIcons.Count, 0, "KickPreCache ACTIVE: timer not set, no icons cached")

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
