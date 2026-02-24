; GUI State Machine Tests - State Transitions, Input Handling, Workspace Logic
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

RunGUITests_State() {
    global GUI_TestPassed, GUI_TestFailed, cfg
    global gGUI_State, gGUI_LiveItems, gGUI_DisplayItems, gGUI_ToggleBase
    global gGUI_Sel, gGUI_ScrollTop, gGUI_OverlayVisible, gGUI_TabCount
    global gGUI_WorkspaceMode, gGUI_CurrentWSName, gGUI_WSContextSwitch
    global gGUI_EventBuffer, gGUI_PendingPhase
    global gGUI_LiveItemsMap, gMock_VisibleRows
    global gMock_BypassResult, gINT_BypassMode
    global gGUI_Base, gGUI_Overlay
    global gMock_StoreItems, gMock_StoreItemsMap
    global gFR_DumpInProgress
    global gStats_AltTabs, gStats_QuickSwitches, gStats_TabSteps, gStats_Cancellations
    global gGUI_MonitorMode, gGUI_OverlayMonitorHandle, gStats_MonitorToggles

    GUI_Log("`n=== GUI State Machine Tests ===`n")

    ; ============================================================
    ; Win_Wrap0 / Win_Wrap1 Math Utility Tests
    ; ============================================================
    ; Direct unit tests for the wrapping math helpers used in selection
    ; and scroll logic. These are pure math - no mocks needed.
    GUI_Log("Test: Win_Wrap0 edge cases")

    ; Win_Wrap0: wraps value to 0..(count-1)
    GUI_AssertEq(Win_Wrap0(0, 5), 0, "Wrap0(0,5) = 0 (identity)")
    GUI_AssertEq(Win_Wrap0(4, 5), 4, "Wrap0(4,5) = 4 (no wrap)")
    GUI_AssertEq(Win_Wrap0(5, 5), 0, "Wrap0(5,5) = 0 (wrap forward)")
    GUI_AssertEq(Win_Wrap0(6, 5), 1, "Wrap0(6,5) = 1 (beyond wrap)")
    GUI_AssertEq(Win_Wrap0(-1, 5), 4, "Wrap0(-1,5) = 4 (wrap backward)")
    GUI_AssertEq(Win_Wrap0(-5, 5), 0, "Wrap0(-5,5) = 0 (full backward wrap)")
    GUI_AssertEq(Win_Wrap0(0, 0), 0, "Wrap0(0,0) = 0 (zero count guard)")
    GUI_AssertEq(Win_Wrap0(0, -1), 0, "Wrap0(0,-1) = 0 (negative count guard)")
    GUI_AssertEq(Win_Wrap0(0, 1), 0, "Wrap0(0,1) = 0 (single item)")
    GUI_AssertEq(Win_Wrap0(1, 1), 0, "Wrap0(1,1) = 0 (single item wrap)")
    GUI_AssertEq(Win_Wrap0(-1, 1), 0, "Wrap0(-1,1) = 0 (single item backward)")
    GUI_AssertEq(Win_Wrap0(10, 3), 1, "Wrap0(10,3) = 1 (multi-wrap)")
    GUI_AssertEq(Win_Wrap0(-7, 5), 3, "Wrap0(-7,5) = 3 (multi-backward)")

    GUI_Log("Test: Win_Wrap1 edge cases")

    ; Win_Wrap1: wraps value to 1..count
    GUI_AssertEq(Win_Wrap1(1, 5), 1, "Wrap1(1,5) = 1 (identity)")
    GUI_AssertEq(Win_Wrap1(5, 5), 5, "Wrap1(5,5) = 5 (no wrap)")
    GUI_AssertEq(Win_Wrap1(6, 5), 1, "Wrap1(6,5) = 1 (wrap forward)")
    GUI_AssertEq(Win_Wrap1(7, 5), 2, "Wrap1(7,5) = 2 (beyond wrap)")
    GUI_AssertEq(Win_Wrap1(0, 5), 5, "Wrap1(0,5) = 5 (wrap backward)")
    GUI_AssertEq(Win_Wrap1(-1, 5), 4, "Wrap1(-1,5) = 4 (further backward)")
    GUI_AssertEq(Win_Wrap1(-4, 5), 1, "Wrap1(-4,5) = 1 (full backward wrap)")
    GUI_AssertEq(Win_Wrap1(0, 0), 0, "Wrap1(0,0) = 0 (zero count guard)")
    GUI_AssertEq(Win_Wrap1(0, -1), 0, "Wrap1(0,-1) = 0 (negative count guard)")
    GUI_AssertEq(Win_Wrap1(1, 1), 1, "Wrap1(1,1) = 1 (single item)")
    GUI_AssertEq(Win_Wrap1(2, 1), 1, "Wrap1(2,1) = 1 (single item wrap)")
    GUI_AssertEq(Win_Wrap1(0, 1), 1, "Wrap1(0,1) = 1 (single item backward)")
    GUI_AssertEq(Win_Wrap1(11, 3), 2, "Wrap1(11,3) = 2 (multi-wrap)")
    GUI_AssertEq(Win_Wrap1(-6, 5), 4, "Wrap1(-6,5) = 4 (multi-backward)")

    ; ----- Test 1: Basic state transitions -----
    GUI_Log("Test: Basic state transitions")
    ResetGUIState()

    GUI_AssertEq(gGUI_State, "IDLE", "Initial state is IDLE")

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_AssertEq(gGUI_State, "ALT_PENDING", "Alt down -> ALT_PENDING")

    GUI_OnInterceptorEvent(TABBY_EV_ALT_UP, 0, 0)
    GUI_AssertEq(gGUI_State, "IDLE", "Alt up without Tab -> IDLE")

    ; ----- Test 2: Alt+Tab freezes list -----
    GUI_Log("Test: Alt+Tab freezes list")
    ResetGUIState()
    SetupTestItems(5)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)

    GUI_AssertEq(gGUI_State, "ACTIVE", "Tab -> ACTIVE")
    GUI_AssertEq(gGUI_DisplayItems.Length, 5, "Display items captured")
    GUI_AssertEq(gGUI_ToggleBase.Length, 5, "All items captured")
    GUI_AssertEq(gGUI_Sel, 2, "Selection starts at 2 (previous window)")

    ; ----- Test 3: Selection wrapping -----
    GUI_Log("Test: Selection wrapping")
    ResetGUIState()
    SetupTestItems(3)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    GUI_AssertEq(gGUI_Sel, 2, "Initial sel=2")

    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)  ; sel=3
    GUI_AssertEq(gGUI_Sel, 3, "Tab -> sel=3")

    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)  ; wrap to 1
    GUI_AssertEq(gGUI_Sel, 1, "Tab wraps to sel=1")

    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, TABBY_FLAG_SHIFT, 0)  ; back to 3
    GUI_AssertEq(gGUI_Sel, 3, "Shift+Tab wraps to sel=3")

    ; ----- Test 4: Escape cancels -----
    GUI_Log("Test: Escape cancels")
    ResetGUIState()
    SetupTestItems(5)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    gGUI_OverlayVisible := true  ; Simulate grace timer fired

    GUI_OnInterceptorEvent(TABBY_EV_ESCAPE, 0, 0)
    GUI_AssertEq(gGUI_State, "IDLE", "Escape -> IDLE")
    GUI_AssertEq(gGUI_OverlayVisible, false, "Escape hides overlay")

    ; ----- Test 5: Alt down pre-warms LiveItems -----
    GUI_Log("Test: Alt down pre-warms LiveItems")
    ResetGUIState()
    MockStore_SetItems(CreateTestItems(8))  ; Store has 8 items

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)

    ; Pre-warm calls GUI_RefreshLiveItems() which populates from mock store
    GUI_AssertEq(gGUI_LiveItems.Length, 8, "Prewarm: LiveItems populated with 8 items from store")

    ; ----- Test 6: Workspace filter -----
    GUI_Log("Test: Workspace filter")
    ResetGUIState()

    gGUI_WorkspaceMode := "current"
    SetupTestItems(10, 4)  ; 10 items, 4 on current WS

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)

    GUI_AssertEq(gGUI_ToggleBase.Length, 10, "All items preserved")
    GUI_AssertEq(gGUI_DisplayItems.Length, 4, "Frozen filtered to current WS")

    ; ----- Test 8: Toggle workspace mode -----
    GUI_Log("Test: Toggle workspace mode")
    ResetGUIState()

    gGUI_WorkspaceMode := "all"
    SetupTestItems(10, 4)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    gGUI_OverlayVisible := true

    GUI_AssertEq(gGUI_DisplayItems.Length, 10, "Initially shows all")

    GUI_ToggleWorkspaceMode()
    GUI_AssertEq(gGUI_WorkspaceMode, "current", "Mode toggled to current")
    GUI_AssertEq(gGUI_DisplayItems.Length, 4, "After toggle: filtered to current WS")

    GUI_ToggleWorkspaceMode()
    GUI_AssertEq(gGUI_WorkspaceMode, "all", "Mode toggled back to all")
    GUI_AssertEq(gGUI_DisplayItems.Length, 10, "After toggle: shows all again")

    ; ----- Test 9: Toggle all->current filters correctly (Bug 1 regression test) -----
    GUI_Log("Test: Toggle all->current filters correctly (Bug 1 regression)")
    ResetGUIState()

    gGUI_WorkspaceMode := "all"
    ; Create items where some have empty workspaceName (unmanaged windows)
    ; and some are explicitly NOT on current workspace
    items := []
    items.Push({ hwnd: 1000, title: "Win1", isOnCurrentWorkspace: true, workspaceName: "Main", lastActivatedTick: A_TickCount - 100, iconHicon: 0, monitorHandle: 0, monitorLabel: "" })
    items.Push({ hwnd: 2000, title: "Win2", isOnCurrentWorkspace: true, workspaceName: "Main", lastActivatedTick: A_TickCount - 200, iconHicon: 0, monitorHandle: 0, monitorLabel: "" })
    items.Push({ hwnd: 3000, title: "Win3", isOnCurrentWorkspace: false, workspaceName: "Other", lastActivatedTick: A_TickCount - 300, iconHicon: 0, monitorHandle: 0, monitorLabel: "" })
    items.Push({ hwnd: 4000, title: "Win4", isOnCurrentWorkspace: true, workspaceName: "", lastActivatedTick: A_TickCount - 400, iconHicon: 0, monitorHandle: 0, monitorLabel: "" })  ; Unmanaged
    items.Push({ hwnd: 5000, title: "Win5", isOnCurrentWorkspace: false, workspaceName: "Other", lastActivatedTick: A_TickCount - 500, iconHicon: 0, monitorHandle: 0, monitorLabel: "" })
    MockStore_SetItems(items)
    gGUI_LiveItems := items

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    gGUI_OverlayVisible := true

    GUI_AssertEq(gGUI_DisplayItems.Length, 5, "Initially shows all 5 items")
    GUI_AssertEq(gGUI_ToggleBase.Length, 5, "ToggleBase has 5 items")

    ; Toggle to "current" mode
    GUI_ToggleWorkspaceMode()
    GUI_AssertEq(gGUI_WorkspaceMode, "current", "Mode toggled to current")

    ; CRITICAL: Should show 3 items (2 on Main + 1 unmanaged)
    GUI_AssertEq(gGUI_DisplayItems.Length, 3, "After toggle to current: 3 items (2 Main + 1 unmanaged)")

    ; Toggle back to "all"
    GUI_ToggleWorkspaceMode()
    GUI_AssertEq(gGUI_DisplayItems.Length, 5, "After toggle back to all: shows all 5 items")

    ; ============================================================
    ; MONITOR MODE TESTS
    ; ============================================================
    ; Tests GUI_ToggleMonitorMode() and GUI_MonitorItemPasses() from
    ; gui_monitor.ahk (included as real production code, Win32 deps mocked).

    ; ----- Test: Monitor toggle cycles modes -----
    GUI_Log("Test: Monitor toggle cycles modes")
    ResetGUIState()
    GUI_AssertEq(gGUI_MonitorMode, "all", "MonToggle: initial mode is all")
    GUI_ToggleMonitorMode()
    GUI_AssertEq(gGUI_MonitorMode, "current", "MonToggle: after first toggle = current")
    GUI_ToggleMonitorMode()
    GUI_AssertEq(gGUI_MonitorMode, "all", "MonToggle: after second toggle = all")

    ; ----- Test: Monitor toggle increments stat -----
    GUI_Log("Test: Monitor toggle increments stat counter")
    ResetGUIState()
    GUI_AssertEq(gStats_MonitorToggles, 0, "MonStat: starts at 0")
    GUI_ToggleMonitorMode()
    GUI_AssertEq(gStats_MonitorToggles, 1, "MonStat: incremented to 1")
    GUI_ToggleMonitorMode()
    GUI_AssertEq(gStats_MonitorToggles, 2, "MonStat: incremented to 2")

    ; ----- Test: Monitor filter reduces display list -----
    GUI_Log("Test: Monitor filter reduces display list")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_OverlayVisible := true
    gGUI_OverlayMonitorHandle := 0xAAAA
    items := CreateTestItems(4)
    items[1].monitorHandle := 0xAAAA
    items[2].monitorHandle := 0xBBBB
    items[3].monitorHandle := 0xAAAA
    items[4].monitorHandle := 0xBBBB
    gGUI_ToggleBase := items
    gGUI_DisplayItems := items.Clone()
    gGUI_LiveItems := items.Clone()
    gGUI_LiveItemsMap := Map()
    for _, item in gGUI_LiveItems
        gGUI_LiveItemsMap[item.hwnd] := item

    GUI_ToggleMonitorMode()  ; all -> current
    GUI_AssertEq(gGUI_MonitorMode, "current", "MonFilter: mode is current")
    GUI_AssertEq(gGUI_DisplayItems.Length, 2, "MonFilter: display filtered to 2 items on overlay monitor")

    GUI_ToggleMonitorMode()  ; current -> all
    GUI_AssertEq(gGUI_DisplayItems.Length, 4, "MonFilter: back to all shows 4 items")

    ; ----- Test: Combined workspace + monitor filter -----
    GUI_Log("Test: Combined workspace + monitor filter")
    ResetGUIState()
    gGUI_State := "ACTIVE"
    gGUI_OverlayVisible := true
    gGUI_OverlayMonitorHandle := 0xAAAA
    gGUI_CurrentWSName := "Main"
    gGUI_WorkspaceMode := "current"
    ; 4 items: Main/MonA, Main/MonB, Other/MonA, Other/MonB
    items := [
        {hwnd: 1000, title: "Main-MonA", class: "X", isOnCurrentWorkspace: true, workspaceName: "Main", monitorHandle: 0xAAAA, monitorLabel: "Mon 1", lastActivatedTick: A_TickCount - 100, iconHicon: 0, processName: ""},
        {hwnd: 2000, title: "Main-MonB", class: "X", isOnCurrentWorkspace: true, workspaceName: "Main", monitorHandle: 0xBBBB, monitorLabel: "Mon 2", lastActivatedTick: A_TickCount - 200, iconHicon: 0, processName: ""},
        {hwnd: 3000, title: "Other-MonA", class: "X", isOnCurrentWorkspace: false, workspaceName: "Other", monitorHandle: 0xAAAA, monitorLabel: "Mon 1", lastActivatedTick: A_TickCount - 300, iconHicon: 0, processName: ""},
        {hwnd: 4000, title: "Other-MonB", class: "X", isOnCurrentWorkspace: false, workspaceName: "Other", monitorHandle: 0xBBBB, monitorLabel: "Mon 2", lastActivatedTick: A_TickCount - 400, iconHicon: 0, processName: ""}
    ]
    MockStore_SetItems(items)
    gGUI_LiveItems := items.Clone()
    gGUI_LiveItemsMap := Map()
    for _, item in gGUI_LiveItems
        gGUI_LiveItemsMap[item.hwnd] := item
    gGUI_ToggleBase := items.Clone()
    ; WS=current filters to Main (2 items), then toggle monitor to current
    gGUI_DisplayItems := GUI_FilterDisplayItems(gGUI_ToggleBase)
    GUI_AssertEq(gGUI_DisplayItems.Length, 2, "Combined setup: WS=current shows 2 Main items")

    GUI_ToggleMonitorMode()  ; all -> current (MonA)
    GUI_AssertEq(gGUI_DisplayItems.Length, 1, "Combined filter: 1 item (Main + MonA)")
    GUI_AssertEq(gGUI_DisplayItems[1].hwnd, 1000, "Combined filter: correct item Main-MonA")

    ; ----- Test: Monitor init from config -----
    GUI_Log("Test: Monitor init from config default")
    ResetGUIState()
    cfg.GUI_MonitorFilterDefault := "Current"
    GUI_InitMonitorMode()
    GUI_AssertEq(gGUI_MonitorMode, "current", "MonInit: config=Current -> mode=current")
    cfg.GUI_MonitorFilterDefault := "All"
    GUI_InitMonitorMode()
    GUI_AssertEq(gGUI_MonitorMode, "all", "MonInit: config=All -> mode=all")

    ; ============================================================
    ; BUG-SPECIFIC REGRESSION TESTS
    ; These verify the actual production code fixes the bugs
    ; ============================================================

    ; ----- Bug 1: Input uses wrong array (via _GUI_GetDisplayItems) -----
    GUI_Log("Test: Bug1 - _GUI_GetDisplayItems returns correct array during ACTIVE")
    ResetGUIState()

    SetupTestItems(10, 4)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    gGUI_OverlayVisible := true

    GUI_ToggleWorkspaceMode()  ; Toggle to "current", should have 4 items

    ; CRITICAL: _GUI_GetDisplayItems() must return gGUI_DisplayItems during ACTIVE
    displayItems := _GUI_GetDisplayItems()
    GUI_AssertEq(displayItems.Length, 4, "Bug1: _GUI_GetDisplayItems returns filtered 4 items")
    GUI_AssertEq(gGUI_DisplayItems.Length, 4, "Bug1: gGUI_DisplayItems has 4 items")
    ; They should be the SAME array reference
    GUI_AssertTrue(displayItems == gGUI_DisplayItems, "Bug1: _GUI_GetDisplayItems returns gGUI_DisplayItems during ACTIVE")

    ; ----- Bug 3: Cross-session toggle persistence -----
    GUI_Log("Test: Bug3 - Cross-session toggle to all shows all windows")
    ResetGUIState()


    ; Session 1: Start with "all", toggle to "current"
    SetupTestItems(10, 4)
    gGUI_WorkspaceMode := "all"

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    gGUI_OverlayVisible := true
    GUI_ToggleWorkspaceMode()  ; Now "current"
    GUI_AssertEq(_GUI_GetDisplayItems().Length, 4, "Bug3: Session 1 current mode shows 4")
    GUI_OnInterceptorEvent(TABBY_EV_ALT_UP, 0, 0)

    ; Session 2: New data arrives
    SetupTestItems(12, 5)  ; 12 total, 5 current
    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    gGUI_OverlayVisible := true

    ; Workspace mode persisted as "current"
    GUI_AssertEq(_GUI_GetDisplayItems().Length, 5, "Bug3: Session 2 starts with current mode (5 items)")

    ; Toggle to "all" - should show ALL 12
    GUI_ToggleWorkspaceMode()
    GUI_AssertEq(_GUI_GetDisplayItems().Length, 12, "Bug3: Toggle to all shows ALL 12 items")

    ; ============================================================
    ; EDGE CASE TESTS - Grace timer, buffer overflow, lost Tab
    ; ============================================================

    ; ----- Test: Grace timer aborts when Alt_Up fires before timer -----
    GUI_Log("Test: Grace timer aborts when state is IDLE")
    ResetGUIState()
    SetupTestItems(5)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    GUI_AssertEq(gGUI_OverlayVisible, false, "Overlay not visible (grace period)")

    ; Alt released before grace timer fires
    GUI_OnInterceptorEvent(TABBY_EV_ALT_UP, 0, 0)
    GUI_AssertEq(gGUI_State, "IDLE", "State is IDLE after Alt_Up")

    ; Now simulate grace timer firing late (race condition)
    _GUI_GraceTimerFired()

    ; Overlay should NOT have shown - grace timer should have aborted
    GUI_AssertEq(gGUI_OverlayVisible, false, "Grace timer correctly aborted (state was IDLE)")

    ; ----- Test: Grace timer race - ShowOverlay aborts cleanly when state changed to IDLE -----
    GUI_Log("Test: Grace timer race - ShowOverlay aborts with force-hide")
    ResetGUIState()
    SetupTestItems(5)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    ; State is ACTIVE, grace timer scheduled, overlay not yet visible
    GUI_OnInterceptorEvent(TABBY_EV_ALT_UP, 0, 0)
    ; State is IDLE, grace timer cancelled
    ; Simulate late grace timer firing (race condition)
    _GUI_GraceTimerFired()
    ; OverlayVisible must be false after abort
    GUI_AssertEq(gGUI_OverlayVisible, false, "Race fix: overlay not visible after late grace fire")
    GUI_AssertEq(gGUI_State, "IDLE", "Race fix: state still IDLE after late grace fire")
    ; Mock GUI windows must not be visible (force-hide cleans up in-flight Show)
    GUI_AssertEq(gGUI_Base.visible, false, "Race fix: gGUI_Base not visible after abort")
    GUI_AssertEq(gGUI_Overlay.visible, false, "Race fix: gGUI_Overlay not visible after abort")

    ; ----- Test: Event buffer overflow triggers recovery -----
    GUI_Log("Test: Event buffer overflow recovery")
    ResetGUIState()
    SetupTestItems(5)
    gGUI_PendingPhase := "polling"  ; Simulate async activation in progress
    gGUI_State := "ACTIVE"

    ; Fill buffer beyond max (51 events - over GUI_EVENT_BUFFER_MAX of 50)
    Loop 51 {
        gGUI_EventBuffer.Push({ev: TABBY_EV_TAB_STEP, flags: 0, lParam: 0})
    }

    ; Next event triggers overflow handler
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)

    GUI_AssertEq(gGUI_State, "IDLE", "Overflow triggered IDLE state")
    GUI_AssertEq(gGUI_PendingPhase, "", "Overflow cleared pending phase")
    gGUI_EventBuffer := []  ; Clean up

    ; ----- Test: First Tab selection with 1-item list -----
    GUI_Log("Test: Selection clamps to 1 when list has only 1 item")
    ResetGUIState()
    SetupTestItems(1)  ; Only 1 window

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)

    GUI_AssertEq(gGUI_DisplayItems.Length, 1, "Frozen has 1 item")
    GUI_AssertEq(gGUI_Sel, 1, "Selection is 1 (clamped from default 2)")

    ; ----- Test: First Tab with empty list -----
    GUI_Log("Test: Selection handles empty list gracefully")
    ResetGUIState()
    gGUI_LiveItems := []  ; Empty list

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)

    GUI_AssertEq(gGUI_DisplayItems.Length, 0, "Frozen is empty")

    ; ----- Test: Lost Tab detection synthesizes TAB_STEP -----
    GUI_Log("Test: Lost Tab detection synthesizes TAB_STEP")
    ResetGUIState()
    SetupTestItems(5)
    gGUI_PendingPhase := "flushing"

    ; Buffer: ALT_DN + ALT_UP but NO TAB (Tab was lost during komorebic's SendInput)
    gGUI_EventBuffer := [
        {ev: TABBY_EV_ALT_DOWN, flags: 0, lParam: 0},
        {ev: TABBY_EV_ALT_UP, flags: 0, lParam: 0}
    ]

    ; Process the buffer - should detect missing Tab and synthesize it
    _GUI_ProcessEventBuffer()

    ; After processing: cycle should have completed (synthesized Tab was processed)
    ; ALT_DN -> ALT_PENDING -> TAB (synthesized) -> ACTIVE -> ALT_UP -> IDLE
    GUI_AssertEq(gGUI_State, "IDLE", "Cycle completed after synthesized Tab (state=IDLE)")
    GUI_AssertEq(gGUI_PendingPhase, "", "Pending phase cleared after buffer processed")

    ; ----- Test: Quick-switch path (Alt+Tab released before overlay shown) -----
    GUI_Log("Test: Quick-switch activates without overlay")
    ResetGUIState()
    SetupTestItems(3)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    GUI_AssertEq(gGUI_State, "ACTIVE", "QS: state is ACTIVE after Tab")
    GUI_AssertEq(gGUI_OverlayVisible, false, "QS: overlay not visible (grace period)")
    ; Alt released within QuickSwitchMs (test runs in <1ms, threshold=100ms)
    GUI_OnInterceptorEvent(TABBY_EV_ALT_UP, 0, 0)
    GUI_AssertEq(gGUI_State, "IDLE", "QS: state returns to IDLE via quick-switch path")
    GUI_AssertEq(gGUI_OverlayVisible, false, "QS: overlay was never shown")
    GUI_AssertTrue(gStats_QuickSwitches >= 1, "QS: gStats_QuickSwitches incremented")

    ; ----- Test: Stats counters wired to state transitions -----
    GUI_Log("Test: Stats counters increment during state transitions")
    ResetGUIState()
    SetupTestItems(5)

    ; Tab_Down should increment AltTabs and TabSteps
    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    GUI_AssertTrue(gStats_AltTabs >= 1, "Stats: gStats_AltTabs incremented on first Tab")
    GUI_AssertTrue(gStats_TabSteps >= 1, "Stats: gStats_TabSteps incremented on first Tab")

    ; Additional Tab should increment TabSteps again
    prevSteps := gStats_TabSteps
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    GUI_AssertTrue(gStats_TabSteps > prevSteps, "Stats: gStats_TabSteps incremented on subsequent Tab")

    ; Escape should increment Cancellations
    GUI_OnInterceptorEvent(TABBY_EV_ESCAPE, 0, 0)
    GUI_AssertTrue(gStats_Cancellations >= 1, "Stats: gStats_Cancellations incremented on Escape")

    ; ============================================================
    ; ALT_PENDING PREWARM DATA FLOW TESTS
    ; ============================================================

    ; ----- Test: Prewarm populates LiveItems during ALT_PENDING -----
    GUI_Log("Test: Prewarm populates LiveItems during ALT_PENDING")
    ResetGUIState()
    MockStore_SetItems(CreateTestItems(10))  ; Store has 10 items
    gGUI_LiveItems := CreateTestItems(3)  ; Start with stale 3 items (prewarm should overwrite)

    ; Alt down -> prewarm calls GUI_RefreshLiveItems() -> populates from store
    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_AssertEq(gGUI_State, "ALT_PENDING", "Prewarm: state is ALT_PENDING")
    GUI_AssertEq(gGUI_LiveItems.Length, 10, "Prewarm: items updated to 10 from store")

    ; Now press Tab - should freeze the 10 prewarm items, not the stale 3
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    GUI_AssertEq(gGUI_DisplayItems.Length, 10, "Prewarm: display items = 10 (prewarm data, not stale 3)")
    GUI_AssertEq(gGUI_State, "ACTIVE", "Prewarm: state is ACTIVE after Tab")

    ; ----- Test: Workspace toggle during ACTIVE -----
    GUI_Log("Test: Workspace toggle during ACTIVE")
    ResetGUIState()

    ; Set up mock store with items
    MockStore_SetItems(CreateTestItems(8, 3))
    gGUI_WorkspaceMode := "all"

    ; Simulate Alt+Tab
    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_AssertEq(gGUI_LiveItems.Length, 8, "WS toggle: Prewarm populated 8 items")

    ; First Tab
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    gGUI_OverlayVisible := true

    GUI_AssertEq(gGUI_State, "ACTIVE", "WS toggle: State is ACTIVE")
    GUI_AssertEq(gGUI_ToggleBase.Length, 8, "WS toggle: ToggleBase has 8")
    GUI_AssertEq(gGUI_DisplayItems.Length, 8, "WS toggle: DisplayItems has 8 (mode=all)")

    ; Toggle workspace mode
    GUI_ToggleWorkspaceMode()
    GUI_AssertEq(gGUI_DisplayItems.Length, 3, "WS toggle: filters locally to 3")

    ; Toggle back
    GUI_ToggleWorkspaceMode()
    GUI_AssertEq(gGUI_DisplayItems.Length, 8, "WS toggle: back shows all 8")

    ; ============================================================
    ; FLIGHT RECORDER DUMP BLOCKING TEST
    ; State machine must be frozen while gFR_DumpInProgress is true
    ; ============================================================

    ; ----- Test: Events blocked during flight recorder dump (ACTIVE state) -----
    GUI_Log("Test: Events blocked during FR dump (ACTIVE)")
    ResetGUIState()
    SetupTestItems(3)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    GUI_AssertEq(gGUI_State, "ACTIVE", "FR dump setup: state is ACTIVE")

    gFR_DumpInProgress := true

    ; All events should be swallowed
    GUI_OnInterceptorEvent(TABBY_EV_ALT_UP, 0, 0)
    GUI_AssertEq(gGUI_State, "ACTIVE", "FR dump: ALT_UP blocked during dump")
    GUI_AssertEq(gGUI_DisplayItems.Length, 3, "FR dump: DisplayItems preserved during dump")

    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    GUI_AssertEq(gGUI_State, "ACTIVE", "FR dump: TAB_STEP blocked during dump")

    GUI_OnInterceptorEvent(TABBY_EV_ESCAPE, 0, 0)
    GUI_AssertEq(gGUI_State, "ACTIVE", "FR dump: ESCAPE blocked during dump")

    gFR_DumpInProgress := false

    ; After dump completes, events should work again
    GUI_OnInterceptorEvent(TABBY_EV_ALT_UP, 0, 0)
    GUI_AssertEq(gGUI_State, "IDLE", "FR dump: ALT_UP works after dump ends")

    ; ----- Test: Events blocked during flight recorder dump (IDLE state) -----
    GUI_Log("Test: Events blocked during FR dump (IDLE)")
    ResetGUIState()
    SetupTestItems(3)

    gFR_DumpInProgress := true

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_AssertEq(gGUI_State, "IDLE", "FR dump IDLE: ALT_DOWN blocked during dump")

    gFR_DumpInProgress := false

    ; ----- Summary -----
    GUI_Log("`n=== GUI State Tests Summary ===")
    GUI_Log("Passed: " GUI_TestPassed)
    GUI_Log("Failed: " GUI_TestFailed)

    return GUI_TestFailed = 0
}

; ============================================================
; ENTRY POINT
; ============================================================

if (A_ScriptFullPath = A_LineFile) {
    try FileDelete(A_Temp "\gui_tests.log")
    result := RunGUITests_State()
    ExitApp(result ? 0 : 1)
}
