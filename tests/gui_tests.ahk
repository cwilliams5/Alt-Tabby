; GUI State Machine Tests
; Tests the Alt-Tab state machine, freeze behavior, and config interactions
; WITHOUT requiring actual window rendering or keyboard hooks

; ============================================================
; Mock Setup - Define globals that GUI code expects
; ============================================================

; Event codes (from gui_main.ahk)
global TABBY_EV_ALT_DOWN := 1
global TABBY_EV_ALT_UP := 2
global TABBY_EV_TAB_STEP := 3
global TABBY_EV_ESCAPE := 4
global TABBY_FLAG_SHIFT := 1

; IPC message types (from ipc_pipe.ahk)
global IPC_MSG_SNAPSHOT := "snapshot"
global IPC_MSG_PROJECTION := "projection"
global IPC_MSG_DELTA := "delta"
global IPC_MSG_PROJECTION_REQUEST := "projection_request"
global IPC_MSG_SNAPSHOT_REQUEST := "snapshot_request"

; GUI state globals (normally in gui_main.ahk)
global gGUI_State := "IDLE"
global gGUI_Items := []
global gGUI_FrozenItems := []
global gGUI_AllItems := []
global gGUI_AwaitingToggleProjection := false
global gGUI_Sel := 1
global gGUI_ScrollTop := 0
global gGUI_OverlayVisible := false
global gGUI_TabCount := 0
global gGUI_FirstTabTick := 0
global gGUI_AltDownTick := 0
global gGUI_WorkspaceMode := "all"
global gGUI_CurrentWSName := ""
global gGUI_StoreRev := 0
global gGUI_StoreConnected := true

; Mock IPC client
global gGUI_StoreClient := { hPipe: 1 }  ; Fake connected client
global gMockIPCMessages := []  ; Capture sent messages

; Config globals (defaults)
global AltTabPrewarmOnAlt := true
global AltTabGraceMs := 150
global AltTabQuickSwitchMs := 100
global FreezeWindowList := true
global UseCurrentWSProjection := false

; Test tracking
global GUI_TestPassed := 0
global GUI_TestFailed := 0

; ============================================================
; Mock Functions - Replace actual GUI/IPC operations
; ============================================================

; Mock IPC send - captures messages instead of sending
IPC_PipeClient_Send(client, msgText) {
    global gMockIPCMessages
    gMockIPCMessages.Push(msgText)
    return true
}

; Mock snapshot request - calls real logic but uses mock IPC
GUI_RequestSnapshot() {
    global gGUI_StoreClient, AltTabPrewarmOnAlt
    if (!gGUI_StoreClient || !gGUI_StoreClient.hPipe)
        return
    req := { type: IPC_MSG_SNAPSHOT_REQUEST, projectionOpts: { sort: "MRU", columns: "items", includeCloaked: true } }
    IPC_PipeClient_Send(gGUI_StoreClient, JXON_Dump(req))
}

; Mock projection request with WS filter
GUI_RequestProjectionWithWSFilter(currentWSOnly := false) {
    global gGUI_StoreClient, gGUI_AwaitingToggleProjection
    if (!gGUI_StoreClient || !gGUI_StoreClient.hPipe)
        return
    opts := { sort: "MRU", columns: "items", includeCloaked: true }
    if (currentWSOnly)
        opts.currentWorkspaceOnly := true
    req := { type: IPC_MSG_PROJECTION_REQUEST, projectionOpts: opts }
    gGUI_AwaitingToggleProjection := true
    IPC_PipeClient_Send(gGUI_StoreClient, JXON_Dump(req))
}

; No-op mocks for visual functions
GUI_Repaint() {
}
GUI_ResizeToRows(n) {
}
GUI_ShowOverlayWithFrozen() {
    global gGUI_OverlayVisible
    gGUI_OverlayVisible := true
}
GUI_HideOverlay() {
    global gGUI_OverlayVisible
    gGUI_OverlayVisible := false
}
GUI_UpdateFooterText() {
}
GUI_ComputeRowsToShow(n) {
    return Min(n, 10)
}
GUI_MoveSelectionFrozen(delta) {
    global gGUI_Sel, gGUI_FrozenItems
    if (gGUI_FrozenItems.Length = 0)
        return
    gGUI_Sel += delta
    if (gGUI_Sel > gGUI_FrozenItems.Length)
        gGUI_Sel := 1
    if (gGUI_Sel < 1)
        gGUI_Sel := gGUI_FrozenItems.Length
}
GUI_ActivateFromFrozen() {
}
GUI_GraceTimerFired() {
    global gGUI_State, gGUI_OverlayVisible
    if (gGUI_State = "ACTIVE" && !gGUI_OverlayVisible)
        GUI_ShowOverlayWithFrozen()
}

; ============================================================
; Core GUI Logic - Copied/adapted from gui_main.ahk
; ============================================================

GUI_FilterByWorkspaceMode(items) {
    global gGUI_WorkspaceMode
    if (gGUI_WorkspaceMode = "all") {
        result := []
        for _, item in items
            result.Push(item)
        return result
    }
    result := []
    for _, item in items {
        ; Handle both Map (from JSON) and Object (from test data)
        if (item is Map) {
            isOnCurrent := item.Has("isOnCurrentWorkspace") ? item["isOnCurrentWorkspace"] : true
        } else {
            isOnCurrent := item.HasOwnProp("isOnCurrentWorkspace") ? item.isOnCurrentWorkspace : true
        }
        if (isOnCurrent)
            result.Push(item)
    }
    return result
}

GUI_ToggleWorkspaceMode() {
    global gGUI_WorkspaceMode, gGUI_State, gGUI_OverlayVisible, gGUI_FrozenItems, gGUI_AllItems, gGUI_Items, gGUI_Sel, gGUI_ScrollTop
    global UseCurrentWSProjection, FreezeWindowList

    gGUI_WorkspaceMode := (gGUI_WorkspaceMode = "all") ? "current" : "all"
    GUI_UpdateFooterText()

    if (gGUI_State = "ACTIVE" && gGUI_OverlayVisible) {
        useServerFilter := IsSet(UseCurrentWSProjection) && UseCurrentWSProjection

        if (useServerFilter) {
            currentWSOnly := (gGUI_WorkspaceMode = "current")
            GUI_RequestProjectionWithWSFilter(currentWSOnly)
        } else {
            isFrozen := !IsSet(FreezeWindowList) || FreezeWindowList
            sourceItems := isFrozen ? gGUI_AllItems : gGUI_Items
            gGUI_FrozenItems := GUI_FilterByWorkspaceMode(sourceItems)
            gGUI_Items := gGUI_FrozenItems

            gGUI_Sel := 2
            if (gGUI_Sel > gGUI_FrozenItems.Length)
                gGUI_Sel := (gGUI_FrozenItems.Length > 0) ? 1 : 0
            gGUI_ScrollTop := (gGUI_Sel > 0) ? gGUI_Sel - 1 : 0

            rowsDesired := GUI_ComputeRowsToShow(gGUI_FrozenItems.Length)
            GUI_ResizeToRows(rowsDesired)
            GUI_Repaint()
        }
    }
}

; Simplified event handler for testing
GUI_OnInterceptorEvent(evCode, flags, lParam) {
    global gGUI_State, gGUI_Items, gGUI_FrozenItems, gGUI_AllItems, gGUI_Sel, gGUI_ScrollTop
    global gGUI_TabCount, gGUI_FirstTabTick, gGUI_AltDownTick, gGUI_OverlayVisible
    global AltTabPrewarmOnAlt, FreezeWindowList, AltTabGraceMs

    if (evCode = TABBY_EV_ALT_DOWN) {
        gGUI_State := "ALT_PENDING"
        gGUI_AltDownTick := A_TickCount
        gGUI_FirstTabTick := 0
        gGUI_TabCount := 0

        if (IsSet(AltTabPrewarmOnAlt) && AltTabPrewarmOnAlt)
            GUI_RequestSnapshot()
        return
    }

    if (evCode = TABBY_EV_TAB_STEP) {
        shiftHeld := (flags & TABBY_FLAG_SHIFT) != 0

        if (gGUI_State = "IDLE")
            return

        if (gGUI_State = "ALT_PENDING") {
            gGUI_FirstTabTick := A_TickCount
            gGUI_TabCount := 1
            gGUI_State := "ACTIVE"

            ; Wait-for-data logic (simplified - no IPC polling in test)
            ; In real code, this waits up to 50ms for prewarm data

            ; Freeze logic
            gGUI_AllItems := gGUI_Items
            gGUI_FrozenItems := GUI_FilterByWorkspaceMode(gGUI_AllItems)

            gGUI_Sel := 2
            if (gGUI_Sel > gGUI_FrozenItems.Length)
                gGUI_Sel := (gGUI_FrozenItems.Length > 0) ? 1 : 0
            gGUI_ScrollTop := (gGUI_Sel > 0) ? gGUI_Sel - 1 : 0

            ; In real code, SetTimer for grace period
            return
        }

        if (gGUI_State = "ACTIVE") {
            gGUI_TabCount += 1
            delta := shiftHeld ? -1 : 1
            GUI_MoveSelectionFrozen(delta)

            if (!gGUI_OverlayVisible && gGUI_TabCount > 1)
                GUI_ShowOverlayWithFrozen()
            else if (gGUI_OverlayVisible)
                GUI_Repaint()
        }
        return
    }

    if (evCode = TABBY_EV_ALT_UP) {
        if (gGUI_State = "ALT_PENDING") {
            gGUI_State := "IDLE"
            return
        }

        if (gGUI_State = "ACTIVE") {
            GUI_ActivateFromFrozen()
            if (gGUI_OverlayVisible)
                GUI_HideOverlay()
            gGUI_State := "IDLE"
        }
        return
    }

    if (evCode = TABBY_EV_ESCAPE) {
        if (gGUI_OverlayVisible)
            GUI_HideOverlay()
        gGUI_State := "IDLE"
        return
    }
}

; Simplified store message handler for testing
GUI_OnStoreMessage(line) {
    global gGUI_State, gGUI_Items, gGUI_FrozenItems, gGUI_AllItems, gGUI_Sel, gGUI_StoreRev
    global gGUI_AwaitingToggleProjection, gGUI_OverlayVisible
    global FreezeWindowList

    obj := ""
    try obj := JXON_Load(line)
    if (!IsObject(obj) || !obj.Has("type"))
        return

    type := obj["type"]

    if (type = IPC_MSG_SNAPSHOT || type = IPC_MSG_PROJECTION) {
        isFrozen := !IsSet(FreezeWindowList) || FreezeWindowList
        isToggleResponse := IsSet(gGUI_AwaitingToggleProjection) && gGUI_AwaitingToggleProjection

        if (gGUI_State = "ACTIVE" && isFrozen && !isToggleResponse) {
            if (obj.Has("rev"))
                gGUI_StoreRev := obj["rev"]
            return
        }

        if (isToggleResponse)
            gGUI_AwaitingToggleProjection := false

        if (obj.Has("payload") && obj["payload"].Has("items")) {
            gGUI_Items := obj["payload"]["items"]

            if (gGUI_State = "ACTIVE" && (!isFrozen || isToggleResponse)) {
                gGUI_AllItems := gGUI_Items
                gGUI_FrozenItems := GUI_FilterByWorkspaceMode(gGUI_AllItems)
                ; CRITICAL: Keep gGUI_Items in sync with frozen list for functions that use it directly
                ; This was the bug fix - without this line, display functions would use stale data
                gGUI_Items := gGUI_FrozenItems

                if (isToggleResponse) {
                    gGUI_Sel := 2
                    if (gGUI_Sel > gGUI_FrozenItems.Length)
                        gGUI_Sel := (gGUI_FrozenItems.Length > 0) ? 1 : 0
                    gGUI_ScrollTop := (gGUI_Sel > 0) ? gGUI_Sel - 1 : 0
                }
            }

            if (gGUI_Sel > gGUI_Items.Length && gGUI_Items.Length > 0)
                gGUI_Sel := gGUI_Items.Length
            if (gGUI_Sel < 1 && gGUI_Items.Length > 0)
                gGUI_Sel := 1

            if (gGUI_OverlayVisible)
                GUI_Repaint()
        }
        if (obj.Has("rev"))
            gGUI_StoreRev := obj["rev"]
        return
    }

    if (type = IPC_MSG_DELTA) {
        isFrozen := !IsSet(FreezeWindowList) || FreezeWindowList

        if (gGUI_State = "ACTIVE" && isFrozen) {
            if (obj.Has("rev"))
                gGUI_StoreRev := obj["rev"]
            return
        }

        ; Apply delta (simplified - just update items)
        if (obj.Has("payload") && obj["payload"].Has("items")) {
            gGUI_Items := obj["payload"]["items"]

            if (gGUI_State = "ACTIVE" && !isFrozen) {
                gGUI_AllItems := gGUI_Items
                gGUI_FrozenItems := GUI_FilterByWorkspaceMode(gGUI_AllItems)
                ; Keep gGUI_Items in sync with frozen list
                gGUI_Items := gGUI_FrozenItems
                if (gGUI_OverlayVisible)
                    GUI_Repaint()
            }
        }
        if (obj.Has("rev"))
            gGUI_StoreRev := obj["rev"]
        return
    }
}

; ============================================================
; Test Utilities
; ============================================================

ResetGUIState() {
    global gGUI_State, gGUI_Items, gGUI_FrozenItems, gGUI_AllItems
    global gGUI_Sel, gGUI_ScrollTop, gGUI_OverlayVisible, gGUI_TabCount
    global gGUI_FirstTabTick, gGUI_AltDownTick, gGUI_WorkspaceMode
    global gGUI_AwaitingToggleProjection, gMockIPCMessages

    gGUI_State := "IDLE"
    gGUI_Items := []
    gGUI_FrozenItems := []
    gGUI_AllItems := []
    gGUI_Sel := 1
    gGUI_ScrollTop := 0
    gGUI_OverlayVisible := false
    gGUI_TabCount := 0
    gGUI_FirstTabTick := 0
    gGUI_AltDownTick := 0
    gGUI_WorkspaceMode := "all"
    gGUI_AwaitingToggleProjection := false
    gMockIPCMessages := []
}

CreateTestItems(count, currentWSCount := -1) {
    ; Create test items with workspace info
    ; If currentWSCount is -1, all items are on current workspace
    items := []
    if (currentWSCount < 0)
        currentWSCount := count

    Loop count {
        items.Push({
            hwnd: A_Index * 1000,
            Title: "Window " A_Index,
            Class: "TestClass",
            isOnCurrentWorkspace: (A_Index <= currentWSCount),
            workspaceName: (A_Index <= currentWSCount) ? "Main" : "Other"
        })
    }
    return items
}

GUI_AssertEq(actual, expected, testName) {
    global GUI_TestPassed, GUI_TestFailed
    if (actual = expected) {
        GUI_TestPassed++
        return true
    }
    GUI_TestFailed++
    GUI_Log("FAIL: " testName " - Expected: " expected ", Got: " actual)
    return false
}

GUI_AssertTrue(condition, testName) {
    global GUI_TestPassed, GUI_TestFailed
    if (condition) {
        GUI_TestPassed++
        return true
    }
    GUI_TestFailed++
    GUI_Log("FAIL: " testName)
    return false
}

; ============================================================
; TESTS
; ============================================================

RunGUITests() {
    global GUI_TestPassed, GUI_TestFailed, gMockIPCMessages
    global FreezeWindowList, UseCurrentWSProjection, AltTabPrewarmOnAlt
    ; CRITICAL: Declare all GUI state globals we'll modify in tests
    global gGUI_State, gGUI_Items, gGUI_FrozenItems, gGUI_AllItems
    global gGUI_Sel, gGUI_ScrollTop, gGUI_OverlayVisible, gGUI_TabCount
    global gGUI_WorkspaceMode, gGUI_AwaitingToggleProjection

    GUI_Log("`n=== GUI State Machine Tests ===`n")

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
    AltTabPrewarmOnAlt := true

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)

    GUI_AssertEq(gMockIPCMessages.Length, 1, "Prewarm request sent")
    if (gMockIPCMessages.Length > 0) {
        msg := JXON_Load(gMockIPCMessages[1])
        GUI_AssertEq(msg["type"], IPC_MSG_SNAPSHOT_REQUEST, "Prewarm is snapshot request")
    }

    ; ----- Test 6: No prewarm when disabled -----
    GUI_Log("Test: No prewarm when disabled")
    ResetGUIState()
    AltTabPrewarmOnAlt := false

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_AssertEq(gMockIPCMessages.Length, 0, "No prewarm when disabled")

    AltTabPrewarmOnAlt := true  ; Restore default

    ; ----- Test 7: FreezeWindowList=true blocks deltas -----
    GUI_Log("Test: FreezeWindowList=true blocks deltas")
    ResetGUIState()
    FreezeWindowList := true
    gGUI_Items := CreateTestItems(5)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    gGUI_OverlayVisible := true

    ; Send delta with new items
    deltaMsg := JXON_Dump({ type: IPC_MSG_DELTA, rev: 10, payload: { items: CreateTestItems(10) } })
    GUI_OnStoreMessage(deltaMsg)

    GUI_AssertEq(gGUI_FrozenItems.Length, 5, "Frozen list unchanged (delta blocked)")
    GUI_AssertEq(gGUI_Items.Length, 5, "gGUI_Items unchanged during ACTIVE+frozen")

    ; ----- Test 8: FreezeWindowList=false allows deltas -----
    GUI_Log("Test: FreezeWindowList=false allows deltas")
    ResetGUIState()
    FreezeWindowList := false
    gGUI_Items := CreateTestItems(5)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    gGUI_OverlayVisible := true

    ; Send delta with new items
    deltaMsg := JXON_Dump({ type: IPC_MSG_DELTA, rev: 10, payload: { items: CreateTestItems(8) } })
    GUI_OnStoreMessage(deltaMsg)

    GUI_AssertEq(gGUI_Items.Length, 8, "gGUI_Items updated (delta allowed)")
    GUI_AssertEq(gGUI_FrozenItems.Length, 8, "Frozen list updated (live mode)")

    FreezeWindowList := true  ; Restore default

    ; ----- Test 9: Workspace filter (client-side) -----
    GUI_Log("Test: Workspace filter (client-side)")
    ResetGUIState()
    FreezeWindowList := true
    UseCurrentWSProjection := false
    gGUI_WorkspaceMode := "current"
    gGUI_Items := CreateTestItems(10, 4)  ; 10 items, 4 on current WS

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)

    GUI_AssertEq(gGUI_AllItems.Length, 10, "All items preserved")
    GUI_AssertEq(gGUI_FrozenItems.Length, 4, "Frozen filtered to current WS")

    ; ----- Test 10: Toggle workspace mode (client-side) -----
    GUI_Log("Test: Toggle workspace mode (client-side)")
    ResetGUIState()
    FreezeWindowList := true
    UseCurrentWSProjection := false
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
    FreezeWindowList := true
    UseCurrentWSProjection := true
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
        lastMsg := JXON_Load(gMockIPCMessages[gMockIPCMessages.Length])
        GUI_AssertEq(lastMsg["type"], IPC_MSG_PROJECTION_REQUEST, "Request type is projection_request")
        opts := lastMsg["projectionOpts"]
        hasWSFlag := (opts is Map) ? opts.Has("currentWorkspaceOnly") : opts.HasOwnProp("currentWorkspaceOnly")
        GUI_AssertTrue(hasWSFlag, "Request has currentWorkspaceOnly")
    }

    UseCurrentWSProjection := false  ; Restore default

    ; ----- Test 12: Toggle projection response accepted during ACTIVE -----
    GUI_Log("Test: Toggle projection response accepted during ACTIVE")
    ResetGUIState()
    FreezeWindowList := true
    UseCurrentWSProjection := true
    gGUI_WorkspaceMode := "all"
    gGUI_Items := CreateTestItems(10, 4)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    gGUI_OverlayVisible := true

    GUI_ToggleWorkspaceMode()  ; Sets gGUI_AwaitingToggleProjection := true

    ; Simulate projection response with filtered items
    filteredItems := CreateTestItems(4, 4)  ; 4 items, all on current WS
    projMsg := JXON_Dump({ type: IPC_MSG_PROJECTION, rev: 20, payload: { items: filteredItems } })
    GUI_OnStoreMessage(projMsg)

    GUI_AssertEq(gGUI_AwaitingToggleProjection, false, "Toggle flag cleared")
    GUI_AssertEq(gGUI_FrozenItems.Length, 4, "Frozen items updated from projection")
    ; CRITICAL: Verify gGUI_Items stays in sync - this was Bug 2
    GUI_AssertEq(gGUI_Items.Length, gGUI_FrozenItems.Length, "gGUI_Items synced with gGUI_FrozenItems after toggle")

    UseCurrentWSProjection := false  ; Restore default

    ; ----- Test 12b: Toggle from current→all shows ALL items (Bug 2 regression test) -----
    GUI_Log("Test: Toggle current→all shows all items (Bug 2 regression)")
    ResetGUIState()
    FreezeWindowList := true
    UseCurrentWSProjection := true
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
    projMsg := JXON_Dump({ type: IPC_MSG_PROJECTION, rev: 25, payload: { items: allItems } })
    GUI_OnStoreMessage(projMsg)

    ; CRITICAL: Verify ALL 10 items are now visible (Bug 2 fix verification)
    GUI_AssertEq(gGUI_FrozenItems.Length, 10, "After toggle to all: shows ALL 10 items")
    GUI_AssertEq(gGUI_Items.Length, 10, "gGUI_Items also has ALL 10 items")
    GUI_AssertEq(gGUI_AllItems.Length, 10, "gGUI_AllItems preserved ALL 10 items")

    UseCurrentWSProjection := false  ; Restore default

    ; ----- Test 12c: Toggle all→current filters correctly (Bug 1 regression test) -----
    GUI_Log("Test: Toggle all→current filters correctly (Bug 1 regression)")
    ResetGUIState()
    FreezeWindowList := true
    UseCurrentWSProjection := false  ; Client-side filtering
    gGUI_WorkspaceMode := "all"
    ; Create items where some have empty workspaceName (unmanaged windows)
    ; and some are explicitly NOT on current workspace
    items := []
    items.Push({ hwnd: 1000, Title: "Win1", isOnCurrentWorkspace: true, workspaceName: "Main" })
    items.Push({ hwnd: 2000, Title: "Win2", isOnCurrentWorkspace: true, workspaceName: "Main" })
    items.Push({ hwnd: 3000, Title: "Win3", isOnCurrentWorkspace: false, workspaceName: "Other" })
    items.Push({ hwnd: 4000, Title: "Win4", isOnCurrentWorkspace: true, workspaceName: "" })  ; Unmanaged
    items.Push({ hwnd: 5000, Title: "Win5", isOnCurrentWorkspace: false, workspaceName: "Other" })
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
    ; Bug 1 was: unmanaged windows had isOnCurrentWorkspace=false and got filtered out
    GUI_AssertEq(gGUI_FrozenItems.Length, 3, "After toggle to current: 3 items (2 Main + 1 unmanaged)")
    GUI_AssertEq(gGUI_Items.Length, 3, "gGUI_Items also has 3 items")

    ; Toggle back to "all"
    GUI_ToggleWorkspaceMode()
    GUI_AssertEq(gGUI_FrozenItems.Length, 5, "After toggle back to all: shows all 5 items")

    ; ----- Test 13: Normal projection blocked during ACTIVE+frozen -----
    GUI_Log("Test: Normal projection blocked during ACTIVE+frozen")
    ResetGUIState()
    FreezeWindowList := true
    gGUI_Items := CreateTestItems(5)

    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, 0, 0)
    gGUI_OverlayVisible := true

    GUI_AssertEq(gGUI_AwaitingToggleProjection, false, "No toggle pending")

    ; Send projection (should be blocked)
    projMsg := JXON_Dump({ type: IPC_MSG_PROJECTION, rev: 30, payload: { items: CreateTestItems(20) } })
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
        FreezeWindowList := combo.freeze
        UseCurrentWSProjection := combo.wsProj
        AltTabPrewarmOnAlt := combo.prewarm
        gGUI_Items := CreateTestItems(8, 3)  ; 8 items, 3 on current WS
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
        deltaMsg := JXON_Dump({ type: IPC_MSG_DELTA, rev: 50, payload: { items: deltaItems } })
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
    FreezeWindowList := true
    UseCurrentWSProjection := false
    AltTabPrewarmOnAlt := true

    ; ----- Summary -----
    GUI_Log("`n=== GUI Test Summary ===")
    GUI_Log("Passed: " GUI_TestPassed)
    GUI_Log("Failed: " GUI_TestFailed)

    return GUI_TestFailed = 0
}

; Include JSON parser
#Include %A_ScriptDir%\..\src\shared\json.ahk

; Log function for test output
GUI_Log(msg) {
    FileAppend(msg "`n", A_Temp "\gui_tests.log", "UTF-8")
}

; Run tests if executed directly
if (A_ScriptFullPath = A_LineFile) {
    try FileDelete(A_Temp "\gui_tests.log")
    result := RunGUITests()
    ExitApp(result ? 0 : 1)
}
