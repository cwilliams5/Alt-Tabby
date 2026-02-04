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
    global GUI_TestPassed, GUI_TestFailed, gMockIPCMessages, cfg
    global gGUI_State, gGUI_Items, gGUI_FrozenItems, gGUI_AllItems
    global gGUI_Sel, gGUI_ScrollTop, gGUI_OverlayVisible, gGUI_TabCount
    global gGUI_WorkspaceMode, gGUI_AwaitingToggleProjection, gGUI_CurrentWSName, gGUI_WSContextSwitch
    global gGUI_EventBuffer, gGUI_PendingPhase, gGUI_FlushStartTick
    global gGUI_StoreRev, gGUI_ItemsMap, gGUI_LastLocalMRUTick, gGUI_LastMsgTick, gMock_VisibleRows
    global gMock_BypassResult, gINT_BypassMode, gMock_PruneCalledWith
    global IPC_MSG_SNAPSHOT, IPC_MSG_SNAPSHOT_REQUEST, IPC_MSG_DELTA
    global IPC_MSG_PROJECTION, IPC_MSG_PROJECTION_REQUEST
    global gGUI_Base, gGUI_Overlay

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
    gGUI_Items := CreateTestItems(5)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)

    GUI_AssertEq(gGUI_State, "ACTIVE", "Tab -> ACTIVE")
    GUI_AssertEq(gGUI_FrozenItems.Length, 5, "Frozen items captured")
    GUI_AssertEq(gGUI_AllItems.Length, 5, "All items captured")
    GUI_AssertEq(gGUI_Sel, 2, "Selection starts at 2 (previous window)")

    ; ----- Test 3: Selection wrapping -----
    GUI_Log("Test: Selection wrapping")
    ResetGUIState()
    gGUI_Items := CreateTestItems(3)

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
    gGUI_Items := CreateTestItems(5)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    gGUI_OverlayVisible := true  ; Simulate grace timer fired

    GUI_OnInterceptorEvent(TABBY_EV_ESCAPE, 0, 0)
    GUI_AssertEq(gGUI_State, "IDLE", "Escape -> IDLE")
    GUI_AssertEq(gGUI_OverlayVisible, false, "Escape hides overlay")

    ; ----- Test 5: Prewarm on Alt (config=true) -----
    GUI_Log("Test: Prewarm on Alt")
    ResetGUIState()
    cfg.AltTabPrewarmOnAlt := true

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)

    GUI_AssertEq(gMockIPCMessages.Length, 1, "Prewarm request sent")
    if (gMockIPCMessages.Length > 0) {
        try {
            msg := JSON.Load(gMockIPCMessages[1])
            GUI_AssertEq(msg["type"], IPC_MSG_SNAPSHOT_REQUEST, "Prewarm is snapshot request")
        } catch as e {
            GUI_Log("FAIL: JSON parse error in prewarm test: " e.Message)
            GUI_TestFailed++
        }
    }

    ; ----- Test 6: No prewarm when disabled -----
    GUI_Log("Test: No prewarm when disabled")
    ResetGUIState()
    cfg.AltTabPrewarmOnAlt := false

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_AssertEq(gMockIPCMessages.Length, 0, "No prewarm when disabled")

    cfg.AltTabPrewarmOnAlt := true  ; Restore default

    ; ----- Test 7: FreezeWindowList=true blocks deltas -----
    GUI_Log("Test: FreezeWindowList=true blocks deltas")
    ResetGUIState()
    cfg.FreezeWindowList := true
    gGUI_Items := CreateTestItems(5)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    gGUI_OverlayVisible := true

    ; Send delta with new items
    deltaMsg := JSON.Dump({ type: IPC_MSG_DELTA, rev: 10, payload: { upserts: CreateTestItems(10) } })
    GUI_OnStoreMessage(deltaMsg)

    GUI_AssertEq(gGUI_FrozenItems.Length, 5, "Frozen list unchanged (delta blocked)")

    ; ----- Test 8: FreezeWindowList=false allows deltas -----
    GUI_Log("Test: FreezeWindowList=false allows deltas")
    ResetGUIState()
    cfg.FreezeWindowList := false
    ; Simulate realistic flow: items arrive via snapshot before Alt+Tab
    snapshotMsg := JSON.Dump({ type: IPC_MSG_SNAPSHOT, rev: 5, payload: { items: CreateTestItems(5) } })
    GUI_OnStoreMessage(snapshotMsg)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    gGUI_OverlayVisible := true

    ; Send delta with new items (items 1-5 update, 6-8 add)
    deltaMsg := JSON.Dump({ type: IPC_MSG_DELTA, rev: 10, payload: { upserts: CreateTestItems(8) } })
    GUI_OnStoreMessage(deltaMsg)

    GUI_AssertEq(gGUI_FrozenItems.Length, 8, "Frozen list updated (live mode)")

    cfg.FreezeWindowList := true  ; Restore default

    ; ----- Test 9: Workspace filter (client-side) -----
    GUI_Log("Test: Workspace filter (client-side)")
    ResetGUIState()
    cfg.FreezeWindowList := true
    cfg.UseCurrentWSProjection := false
    gGUI_WorkspaceMode := "current"
    gGUI_Items := CreateTestItems(10, 4)  ; 10 items, 4 on current WS

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)

    GUI_AssertEq(gGUI_AllItems.Length, 10, "All items preserved")
    GUI_AssertEq(gGUI_FrozenItems.Length, 4, "Frozen filtered to current WS")

    ; ----- Test 10: Toggle workspace mode (client-side) -----
    GUI_Log("Test: Toggle workspace mode (client-side)")
    ResetGUIState()
    cfg.FreezeWindowList := true
    cfg.UseCurrentWSProjection := false
    gGUI_WorkspaceMode := "all"
    gGUI_Items := CreateTestItems(10, 4)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    gGUI_OverlayVisible := true

    GUI_AssertEq(gGUI_FrozenItems.Length, 10, "Initially shows all")

    GUI_ToggleWorkspaceMode()
    GUI_AssertEq(gGUI_WorkspaceMode, "current", "Mode toggled to current")
    GUI_AssertEq(gGUI_FrozenItems.Length, 4, "After toggle: filtered to current WS")

    GUI_ToggleWorkspaceMode()
    GUI_AssertEq(gGUI_WorkspaceMode, "all", "Mode toggled back to all")
    GUI_AssertEq(gGUI_FrozenItems.Length, 10, "After toggle: shows all again")

    ; ----- Test 11: UseCurrentWSProjection sends request -----
    GUI_Log("Test: UseCurrentWSProjection sends request")
    ResetGUIState()
    cfg.FreezeWindowList := true
    cfg.UseCurrentWSProjection := true
    gGUI_WorkspaceMode := "all"
    gGUI_Items := CreateTestItems(10, 4)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    gGUI_OverlayVisible := true

    msgCountBefore := gMockIPCMessages.Length

    GUI_ToggleWorkspaceMode()
    GUI_AssertEq(gGUI_WorkspaceMode, "current", "Mode toggled")
    GUI_AssertTrue(gGUI_AwaitingToggleProjection, "Toggle projection flag set")
    GUI_AssertTrue(gMockIPCMessages.Length > msgCountBefore, "Projection request sent")

    ; Verify request has currentWorkspaceOnly
    if (gMockIPCMessages.Length > msgCountBefore) {
        try {
            lastMsg := JSON.Load(gMockIPCMessages[gMockIPCMessages.Length])
            GUI_AssertEq(lastMsg["type"], IPC_MSG_PROJECTION_REQUEST, "Request type is projection_request")
            opts := lastMsg["projectionOpts"]
            hasWSFlag := (opts is Map) ? opts.Has("currentWorkspaceOnly") : opts.HasOwnProp("currentWorkspaceOnly")
            GUI_AssertTrue(hasWSFlag, "Request has currentWorkspaceOnly")
        } catch as e {
            GUI_Log("FAIL: JSON parse error in workspace toggle test: " e.Message)
            GUI_TestFailed++
        }
    }

    cfg.UseCurrentWSProjection := false  ; Restore default

    ; ----- Test 12: Toggle projection response accepted during ACTIVE -----
    GUI_Log("Test: Toggle projection response accepted during ACTIVE")
    ResetGUIState()
    cfg.FreezeWindowList := true
    cfg.UseCurrentWSProjection := true
    gGUI_WorkspaceMode := "all"
    gGUI_Items := CreateTestItems(10, 4)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    gGUI_OverlayVisible := true

    GUI_ToggleWorkspaceMode()  ; Sets gGUI_AwaitingToggleProjection := true

    ; Simulate projection response with filtered items
    filteredItems := CreateTestItems(4, 4)  ; 4 items, all on current WS
    SimulateServerResponse(filteredItems)

    GUI_AssertEq(gGUI_AwaitingToggleProjection, false, "Toggle flag cleared")
    GUI_AssertEq(gGUI_FrozenItems.Length, 4, "Frozen items updated from projection")

    cfg.UseCurrentWSProjection := false  ; Restore default

    ; ----- Test 12b: Toggle from current->all shows ALL items (Bug 2 regression test) -----
    GUI_Log("Test: Toggle current->all shows all items (Bug 2 regression)")
    ResetGUIState()
    cfg.FreezeWindowList := true
    cfg.UseCurrentWSProjection := true
    gGUI_WorkspaceMode := "current"  ; Start in current mode
    gGUI_Items := CreateTestItems(4, 4)  ; Start with 4 current-WS items

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    gGUI_OverlayVisible := true

    GUI_AssertEq(gGUI_FrozenItems.Length, 4, "Initially shows 4 current WS items")

    ; Toggle to "all" mode
    GUI_ToggleWorkspaceMode()
    GUI_AssertEq(gGUI_WorkspaceMode, "all", "Mode toggled to all")
    GUI_AssertTrue(gGUI_AwaitingToggleProjection, "Toggle projection flag set")

    ; Simulate projection response with ALL items (10 total, 4 on current WS)
    allItems := CreateTestItems(10, 4)
    SimulateServerResponse(allItems)

    ; CRITICAL: Verify ALL 10 items are now visible (Bug 2 fix verification)
    GUI_AssertEq(gGUI_FrozenItems.Length, 10, "After toggle to all: shows ALL 10 items")
    GUI_AssertEq(gGUI_AllItems.Length, 10, "gGUI_AllItems preserved ALL 10 items")

    cfg.UseCurrentWSProjection := false  ; Restore default

    ; ----- Test 12c: Toggle all->current filters correctly (Bug 1 regression test) -----
    GUI_Log("Test: Toggle all->current filters correctly (Bug 1 regression)")
    ResetGUIState()
    cfg.FreezeWindowList := true
    cfg.UseCurrentWSProjection := false  ; Client-side filtering
    gGUI_WorkspaceMode := "all"
    ; Create items where some have empty workspaceName (unmanaged windows)
    ; and some are explicitly NOT on current workspace
    items := []
    items.Push({ hwnd: 1000, Title: "Win1", isOnCurrentWorkspace: true, workspaceName: "Main", lastActivatedTick: A_TickCount - 100 })
    items.Push({ hwnd: 2000, Title: "Win2", isOnCurrentWorkspace: true, workspaceName: "Main", lastActivatedTick: A_TickCount - 200 })
    items.Push({ hwnd: 3000, Title: "Win3", isOnCurrentWorkspace: false, workspaceName: "Other", lastActivatedTick: A_TickCount - 300 })
    items.Push({ hwnd: 4000, Title: "Win4", isOnCurrentWorkspace: true, workspaceName: "", lastActivatedTick: A_TickCount - 400 })  ; Unmanaged
    items.Push({ hwnd: 5000, Title: "Win5", isOnCurrentWorkspace: false, workspaceName: "Other", lastActivatedTick: A_TickCount - 500 })
    gGUI_Items := items

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    gGUI_OverlayVisible := true

    GUI_AssertEq(gGUI_FrozenItems.Length, 5, "Initially shows all 5 items")
    GUI_AssertEq(gGUI_AllItems.Length, 5, "AllItems has 5 items")

    ; Toggle to "current" mode
    GUI_ToggleWorkspaceMode()
    GUI_AssertEq(gGUI_WorkspaceMode, "current", "Mode toggled to current")

    ; CRITICAL: Should show 3 items (2 on Main + 1 unmanaged)
    GUI_AssertEq(gGUI_FrozenItems.Length, 3, "After toggle to current: 3 items (2 Main + 1 unmanaged)")

    ; Toggle back to "all"
    GUI_ToggleWorkspaceMode()
    GUI_AssertEq(gGUI_FrozenItems.Length, 5, "After toggle back to all: shows all 5 items")

    ; ----- Test 13: Normal projection blocked during ACTIVE+frozen -----
    GUI_Log("Test: Normal projection blocked during ACTIVE+frozen")
    ResetGUIState()
    cfg.FreezeWindowList := true
    gGUI_Items := CreateTestItems(5)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    gGUI_OverlayVisible := true

    GUI_AssertEq(gGUI_AwaitingToggleProjection, false, "No toggle pending")

    ; Send projection (should be blocked)
    projMsg := JSON.Dump({ type: IPC_MSG_PROJECTION, rev: 30, payload: { items: CreateTestItems(20) } })
    GUI_OnStoreMessage(projMsg)

    GUI_AssertEq(gGUI_FrozenItems.Length, 5, "Frozen items unchanged (projection blocked)")
    GUI_AssertEq(gGUI_StoreRev, 30, "Rev still updated for tracking")

    ; ----- Test 14: Config combination matrix -----
    GUI_Log("Test: Config combination matrix (8 combinations)")

    ; Test all 8 combinations of FreezeWindowList, UseCurrentWSProjection, AltTabPrewarmOnAlt
    configCombos := [
        { freeze: true,  wsProj: false, prewarm: true,  desc: "F=T,WS=F,PW=T (default)" },
        { freeze: true,  wsProj: false, prewarm: false, desc: "F=T,WS=F,PW=F" },
        { freeze: true,  wsProj: true,  prewarm: true,  desc: "F=T,WS=T,PW=T" },
        { freeze: true,  wsProj: true,  prewarm: false, desc: "F=T,WS=T,PW=F" },
        { freeze: false, wsProj: false, prewarm: true,  desc: "F=F,WS=F,PW=T (live mode)" },
        { freeze: false, wsProj: false, prewarm: false, desc: "F=F,WS=F,PW=F" },
        { freeze: false, wsProj: true,  prewarm: true,  desc: "F=F,WS=T,PW=T" },
        { freeze: false, wsProj: true,  prewarm: false, desc: "F=F,WS=T,PW=F" },
    ]

    for _, combo in configCombos {
        ResetGUIState()
        cfg.FreezeWindowList := combo.freeze
        cfg.UseCurrentWSProjection := combo.wsProj
        cfg.AltTabPrewarmOnAlt := combo.prewarm
        ; Simulate realistic flow: items arrive via snapshot before Alt+Tab
        snapshotMsg := JSON.Dump({ type: IPC_MSG_SNAPSHOT, rev: 1, payload: { items: CreateTestItems(8, 3) } })
        GUI_OnStoreMessage(snapshotMsg)
        gGUI_WorkspaceMode := "all"

        ; Simulate Alt+Tab
        GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)

        ; Check prewarm behavior
        prewarmSent := false
        for _, msg in gMockIPCMessages {
            if (InStr(msg, "snapshot_request"))
                prewarmSent := true
        }
        GUI_AssertEq(prewarmSent, combo.prewarm, combo.desc ": Prewarm matches config")

        ; First Tab
        GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
        gGUI_OverlayVisible := true

        GUI_AssertEq(gGUI_State, "ACTIVE", combo.desc ": State is ACTIVE")
        GUI_AssertEq(gGUI_AllItems.Length, 8, combo.desc ": AllItems has 8")
        GUI_AssertEq(gGUI_FrozenItems.Length, 8, combo.desc ": FrozenItems has 8 (mode=all)")

        ; Send delta during ACTIVE state
        deltaItems := CreateTestItems(12, 5)  ; Now 12 items
        deltaMsg := JSON.Dump({ type: IPC_MSG_DELTA, rev: 50, payload: { upserts: deltaItems } })
        GUI_OnStoreMessage(deltaMsg)

        if (combo.freeze) {
            ; Delta should be blocked
            GUI_AssertEq(gGUI_FrozenItems.Length, 8, combo.desc ": Delta blocked (frozen)")
        } else {
            ; Delta should be applied
            GUI_AssertEq(gGUI_FrozenItems.Length, 12, combo.desc ": Delta applied (live)")
        }

        ; Toggle workspace mode
        msgCountBefore := gMockIPCMessages.Length
        GUI_ToggleWorkspaceMode()

        if (combo.wsProj) {
            ; Should send projection request
            GUI_AssertTrue(gMockIPCMessages.Length > msgCountBefore, combo.desc ": WS toggle sends request")
        } else {
            ; Should filter locally
            expectedCount := combo.freeze ? 3 : 5  ; 3 from original, 5 from delta
            GUI_AssertEq(gGUI_FrozenItems.Length, expectedCount, combo.desc ": WS toggle filters locally")
        }
    }

    ; Restore defaults
    cfg.FreezeWindowList := true
    cfg.UseCurrentWSProjection := false
    cfg.AltTabPrewarmOnAlt := true

    ; ============================================================
    ; BUG-SPECIFIC REGRESSION TESTS
    ; These verify the actual production code fixes the bugs
    ; ============================================================

    ; ----- Bug 1: Input uses wrong array (via _GUI_GetDisplayItems) -----
    GUI_Log("Test: Bug1 - _GUI_GetDisplayItems returns correct array during ACTIVE")
    ResetGUIState()
    cfg.FreezeWindowList := true
    cfg.UseCurrentWSProjection := false
    gGUI_Items := CreateTestItems(10, 4)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    gGUI_OverlayVisible := true

    GUI_ToggleWorkspaceMode()  ; Toggle to "current", should have 4 items

    ; CRITICAL: _GUI_GetDisplayItems() must return gGUI_FrozenItems during ACTIVE
    displayItems := _GUI_GetDisplayItems()
    GUI_AssertEq(displayItems.Length, 4, "Bug1: _GUI_GetDisplayItems returns filtered 4 items")
    GUI_AssertEq(gGUI_FrozenItems.Length, 4, "Bug1: gGUI_FrozenItems has 4 items")
    ; They should be the SAME array reference
    GUI_AssertTrue(displayItems == gGUI_FrozenItems, "Bug1: DisplayItems IS FrozenItems during ACTIVE")

    ; ----- Bug 2: Double-filtering with UseCurrentWSProjection=true -----
    GUI_Log("Test: Bug2 - No double-filtering with server-side projection")
    ResetGUIState()
    cfg.FreezeWindowList := true
    cfg.UseCurrentWSProjection := true
    gGUI_Items := CreateTestItems(10, 4)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    gGUI_OverlayVisible := true

    ; Toggle to "current" - this sends request to server
    GUI_ToggleWorkspaceMode()
    GUI_AssertTrue(gGUI_AwaitingToggleProjection, "Bug2: Toggle flag set")

    ; Simulate server response with PRE-FILTERED items (4 items, all on current WS)
    ; If double-filtering occurred, this might become 0 items
    serverFiltered := CreateTestItems(4, 4)
    SimulateServerResponse(serverFiltered)

    ; BUG FIX VERIFICATION: Should have 4 items, NOT 0
    GUI_AssertEq(gGUI_FrozenItems.Length, 4, "Bug2: Server-filtered items NOT double-filtered (have 4)")
    GUI_AssertEq(_GUI_GetDisplayItems().Length, 4, "Bug2: _GUI_GetDisplayItems shows all 4")

    cfg.UseCurrentWSProjection := false  ; Restore

    ; ----- Bug 3: Cross-session toggle persistence -----
    GUI_Log("Test: Bug3 - Cross-session toggle to all shows all windows")
    ResetGUIState()
    cfg.FreezeWindowList := true
    cfg.UseCurrentWSProjection := false

    ; Session 1: Start with "all", toggle to "current"
    gGUI_Items := CreateTestItems(10, 4)
    gGUI_WorkspaceMode := "all"

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    gGUI_OverlayVisible := true
    GUI_ToggleWorkspaceMode()  ; Now "current"
    GUI_AssertEq(_GUI_GetDisplayItems().Length, 4, "Bug3: Session 1 current mode shows 4")
    GUI_OnInterceptorEvent(TABBY_EV_ALT_UP, 0, 0)

    ; Session 2: New data arrives
    gGUI_Items := CreateTestItems(12, 5)  ; 12 total, 5 current
    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    gGUI_OverlayVisible := true

    ; Workspace mode persisted as "current"
    GUI_AssertEq(_GUI_GetDisplayItems().Length, 5, "Bug3: Session 2 starts with current mode (5 items)")

    ; Toggle to "all" - should show ALL 12
    GUI_ToggleWorkspaceMode()
    GUI_AssertEq(_GUI_GetDisplayItems().Length, 12, "Bug3: Toggle to all shows ALL 12 items")

    ; ============================================================
    ; RACE CONDITION PREVENTION TESTS
    ; ============================================================

    ; ----- Test: Selection survives delta that removes items -----
    GUI_Log("Test: Selection survives delta that removes items")
    ResetGUIState()
    cfg.FreezeWindowList := false  ; Live mode
    gGUI_Items := CreateTestItems(10, 5)
    gGUI_Sel := 8  ; Select item 8

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    gGUI_OverlayVisible := true

    ; Delta removes items, list shrinks to 5
    smallerItems := CreateTestItems(5, 2)
    deltaMsg := JSON.Dump({ type: IPC_MSG_SNAPSHOT, rev: 60, payload: { items: smallerItems } })
    GUI_OnStoreMessage(deltaMsg)

    ; Selection should be clamped to new list size
    GUI_AssertTrue(gGUI_Sel <= 5, "Selection clamped after list shrinks (sel=" gGUI_Sel ")")

    ; Restore
    cfg.FreezeWindowList := true

    ; ============================================================
    ; EDGE CASE TESTS - Grace timer, buffer overflow, lost Tab
    ; ============================================================

    ; ----- Test: Grace timer aborts when Alt_Up fires before timer -----
    GUI_Log("Test: Grace timer aborts when state is IDLE")
    ResetGUIState()
    gGUI_Items := CreateTestItems(5)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    GUI_AssertEq(gGUI_OverlayVisible, false, "Overlay not visible (grace period)")

    ; Alt released before grace timer fires
    GUI_OnInterceptorEvent(TABBY_EV_ALT_UP, 0, 0)
    GUI_AssertEq(gGUI_State, "IDLE", "State is IDLE after Alt_Up")

    ; Now simulate grace timer firing late (race condition)
    GUI_GraceTimerFired()

    ; Overlay should NOT have shown - grace timer should have aborted
    GUI_AssertEq(gGUI_OverlayVisible, false, "Grace timer correctly aborted (state was IDLE)")

    ; ----- Test: Grace timer race - ShowOverlay aborts cleanly when state changed to IDLE -----
    GUI_Log("Test: Grace timer race - ShowOverlay aborts with force-hide")
    ResetGUIState()
    gGUI_Items := CreateTestItems(5)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    ; State is ACTIVE, grace timer scheduled, overlay not yet visible
    GUI_OnInterceptorEvent(TABBY_EV_ALT_UP, 0, 0)
    ; State is IDLE, grace timer cancelled
    ; Simulate late grace timer firing (race condition)
    GUI_GraceTimerFired()
    ; OverlayVisible must be false after abort
    GUI_AssertEq(gGUI_OverlayVisible, false, "Race fix: overlay not visible after late grace fire")
    GUI_AssertEq(gGUI_State, "IDLE", "Race fix: state still IDLE after late grace fire")
    ; Mock GUI windows must not be visible (force-hide cleans up in-flight Show)
    GUI_AssertEq(gGUI_Base.visible, false, "Race fix: gGUI_Base not visible after abort")
    GUI_AssertEq(gGUI_Overlay.visible, false, "Race fix: gGUI_Overlay not visible after abort")

    ; ----- Test: Event buffer overflow triggers recovery -----
    GUI_Log("Test: Event buffer overflow recovery")
    ResetGUIState()
    gGUI_Items := CreateTestItems(5)
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
    gGUI_Items := CreateTestItems(1)  ; Only 1 window

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)

    GUI_AssertEq(gGUI_FrozenItems.Length, 1, "Frozen has 1 item")
    GUI_AssertEq(gGUI_Sel, 1, "Selection is 1 (clamped from default 2)")

    ; ----- Test: First Tab with empty list -----
    GUI_Log("Test: Selection handles empty list gracefully")
    ResetGUIState()
    gGUI_Items := []  ; Empty list

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)

    GUI_AssertEq(gGUI_FrozenItems.Length, 0, "Frozen is empty")

    ; ----- Test: Lost Tab detection synthesizes TAB_STEP -----
    GUI_Log("Test: Lost Tab detection synthesizes TAB_STEP")
    ResetGUIState()
    gGUI_Items := CreateTestItems(5)
    gGUI_PendingPhase := "flushing"
    gGUI_FlushStartTick := A_TickCount - 50  ; Past the GUI_EVENT_FLUSH_WAIT_MS threshold

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

    ; ============================================================
    ; ALT_PENDING DATA FLOW TESTS
    ; ============================================================

    ; ----- Test: Snapshot during ALT_PENDING updates gGUI_Items -----
    GUI_Log("Test: Snapshot during ALT_PENDING updates gGUI_Items")
    ResetGUIState()
    gGUI_Items := CreateTestItems(3)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_AssertEq(gGUI_State, "ALT_PENDING", "ALT_PENDING data: state is ALT_PENDING")

    ; Send snapshot with 8 items - should be accepted (prewarm data)
    snapshotMsg := JSON.Dump({ type: IPC_MSG_SNAPSHOT, rev: 150, payload: { items: CreateTestItems(8) } })
    GUI_OnStoreMessage(snapshotMsg)

    GUI_AssertEq(gGUI_Items.Length, 8, "ALT_PENDING data: snapshot accepted (8 items)")
    GUI_AssertEq(gGUI_State, "ALT_PENDING", "ALT_PENDING data: state unchanged after snapshot")

    ; ----- Test: Delta during ALT_PENDING updates gGUI_Items -----
    GUI_Log("Test: Delta during ALT_PENDING updates gGUI_Items")
    ResetGUIState()
    cfg.FreezeWindowList := false  ; Live mode for delta processing
    ; Load initial 5 items via snapshot
    snapshotMsg := JSON.Dump({ type: IPC_MSG_SNAPSHOT, rev: 1, payload: { items: CreateTestItems(5) } })
    GUI_OnStoreMessage(snapshotMsg)
    GUI_AssertEq(gGUI_Items.Length, 5, "ALT_PENDING delta: initial 5 items")

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_AssertEq(gGUI_State, "ALT_PENDING", "ALT_PENDING delta: state is ALT_PENDING")

    ; Send delta: remove hwnd 2000 and 4000, add hwnd 8888
    newRec := Map("hwnd", 8888, "title", "New Window", "class", "NewClass", "lastActivatedTick", A_TickCount + 99999)
    deltaMsg := JSON.Dump({ type: IPC_MSG_DELTA, rev: 2, payload: { removes: [2000, 4000], upserts: [newRec] } })
    GUI_OnStoreMessage(deltaMsg)

    GUI_AssertEq(gGUI_Items.Length, 4, "ALT_PENDING delta: 5 - 2 + 1 = 4 items")
    GUI_AssertEq(gGUI_ItemsMap.Has(8888), true, "ALT_PENDING delta: new hwnd 8888 in map")
    GUI_AssertEq(gGUI_ItemsMap.Has(2000), false, "ALT_PENDING delta: hwnd 2000 removed")
    cfg.FreezeWindowList := true  ; Restore

    ; ----- Test: Prewarm snapshot data used when Tab pressed -----
    GUI_Log("Test: Prewarm snapshot data used when Tab pressed")
    ResetGUIState()
    gGUI_Items := CreateTestItems(3)

    ; Alt down -> prewarm snapshot arrives -> Tab pressed
    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)

    ; Send snapshot with 10 items (simulating prewarm response)
    snapshotMsg := JSON.Dump({ type: IPC_MSG_SNAPSHOT, rev: 160, payload: { items: CreateTestItems(10) } })
    GUI_OnStoreMessage(snapshotMsg)
    GUI_AssertEq(gGUI_Items.Length, 10, "Prewarm: items updated to 10 during ALT_PENDING")

    ; Now press Tab - should freeze the 10 prewarm items, not the stale 3
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    GUI_AssertEq(gGUI_FrozenItems.Length, 10, "Prewarm: frozen items = 10 (prewarm data, not stale 3)")
    GUI_AssertEq(gGUI_State, "ACTIVE", "Prewarm: state is ACTIVE after Tab")

    ; ============================================================
    ; SNAPSHOT GUARD TESTS
    ; ============================================================

    ; ----- Test: Snapshot skipped during async activation -----
    GUI_Log("Test: Snapshot skipped during async activation")
    ResetGUIState()
    gGUI_Items := CreateTestItems(5)
    gGUI_PendingPhase := "polling"  ; Simulate async activation in progress

    ; Send snapshot - should be skipped (items unchanged)
    snapshotMsg := JSON.Dump({ type: IPC_MSG_SNAPSHOT, rev: 100, payload: { items: CreateTestItems(10) } })
    GUI_OnStoreMessage(snapshotMsg)

    GUI_AssertEq(gGUI_Items.Length, 5, "Snapshot skipped: items unchanged during async")
    GUI_AssertEq(gGUI_StoreRev, 100, "Snapshot skipped: rev still updated")
    gGUI_PendingPhase := ""  ; Cleanup

    ; ----- Test: Snapshot skipped when local MRU is fresh -----
    GUI_Log("Test: Snapshot skipped when local MRU is fresh")
    ResetGUIState()
    gGUI_Items := CreateTestItems(5)
    gGUI_LastLocalMRUTick := A_TickCount  ; Just updated MRU

    snapshotMsg := JSON.Dump({ type: IPC_MSG_SNAPSHOT, rev: 101, payload: { items: CreateTestItems(10) } })
    GUI_OnStoreMessage(snapshotMsg)

    GUI_AssertEq(gGUI_Items.Length, 5, "Snapshot skipped: items unchanged when MRU fresh")
    GUI_AssertEq(gGUI_StoreRev, 101, "Snapshot skipped: rev still updated when MRU fresh")

    ; ----- Test: Snapshot accepted when local MRU is stale -----
    GUI_Log("Test: Snapshot accepted when local MRU is stale")
    ResetGUIState()
    gGUI_Items := CreateTestItems(5)
    gGUI_LastLocalMRUTick := A_TickCount - 1000  ; MRU updated 1s ago

    snapshotMsg := JSON.Dump({ type: IPC_MSG_SNAPSHOT, rev: 102, payload: { items: CreateTestItems(10) } })
    GUI_OnStoreMessage(snapshotMsg)

    GUI_AssertEq(gGUI_Items.Length, 10, "Snapshot accepted: items updated when MRU stale")

    ; ----- Test: Toggle response bypasses BOTH guards -----
    GUI_Log("Test: Toggle response bypasses both guards")
    ResetGUIState()
    cfg.FreezeWindowList := true
    cfg.UseCurrentWSProjection := true
    gGUI_Items := CreateTestItems(5)

    ; Set up ACTIVE state with pending toggle
    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    gGUI_OverlayVisible := true

    ; Request toggle (sets AwaitingToggleProjection)
    GUI_ToggleWorkspaceMode()
    GUI_AssertTrue(gGUI_AwaitingToggleProjection, "Toggle guard: awaiting flag set")

    ; Set BOTH guards active
    gGUI_PendingPhase := "polling"
    gGUI_LastLocalMRUTick := A_TickCount

    ; Send projection response - should bypass both guards because isToggleResponse
    filteredItems := CreateTestItems(3, 3)
    projMsg := JSON.Dump({ type: IPC_MSG_PROJECTION, rev: 103, payload: { items: filteredItems }})
    GUI_OnStoreMessage(projMsg)

    GUI_AssertEq(gGUI_AwaitingToggleProjection, false, "Toggle guard: flag cleared")
    GUI_AssertEq(gGUI_FrozenItems.Length, 3, "Toggle guard: items updated despite both guards")
    gGUI_PendingPhase := ""  ; Cleanup

    cfg.UseCurrentWSProjection := false  ; Restore

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
