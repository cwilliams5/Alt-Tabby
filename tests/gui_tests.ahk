; GUI State Machine Tests
; Tests ACTUAL production GUI code with mocked visual layer
; This file tests the real gui_store.ahk, gui_workspace.ahk, gui_state.ahk, gui_input.ahk
#Requires AutoHotkey v2.0
#Warn VarUnset, Off
A_IconHidden := true  ; No tray icon during tests

; ============================================================
; 1. GLOBALS (must match gui_main.ahk)
; ============================================================

; Event codes (from production gui_constants.ahk)
#Include %A_ScriptDir%\..\src\gui\gui_constants.ahk

; IPC message types (from shared constants — no hardcoded copies)
#Include %A_ScriptDir%\..\src\shared\ipc_constants.ahk

; GUI state globals
global gGUI_State := "IDLE"
global gGUI_Items := []
global gGUI_ItemsMap := Map()  ; hwnd -> item lookup for O(1) delta processing
global gGUI_FrozenItems := []
global gGUI_AllItems := []
global gGUI_AwaitingToggleProjection := false
global gGUI_Sel := 1
global gGUI_ScrollTop := 0
global gGUI_OverlayVisible := false
global gGUI_OverlayH := 0  ; Window handle - production code checks this
global gGUI_TabCount := 0
global gGUI_FirstTabTick := 0
global gGUI_WorkspaceMode := "all"
global gGUI_CurrentWSName := ""
global gGUI_StoreRev := 0
global gGUI_StoreConnected := true
global gGUI_FooterText := ""
global gGUI_Revealed := false
global gGUI_HoverRow := 0
global gGUI_HoverBtn := ""
global gGUI_LeftArrowRect := { x: 0, y: 0, w: 0, h: 0 }
global gGUI_RightArrowRect := { x: 0, y: 0, w: 0, h: 0 }
global gGUI_MouseTracking := false  ; WM_MOUSELEAVE tracking state
global gGUI_BaseH := 0              ; Window handle for overlay base

; Async activation globals (for cross-workspace support)
global gGUI_PendingPhase := ""
global gGUI_PendingHwnd := 0
global gGUI_PendingWSName := ""
global gGUI_PendingDeadline := 0
global gGUI_PendingWaitUntil := 0
global gGUI_PendingShell := ""
global gGUI_PendingTempFile := ""
global gGUI_EventBuffer := []
global gGUI_LastLocalMRUTick := 0
global gGUI_FlushStartTick := 0  ; For tick-based flushing wait (race condition fix)

; Constants from config_loader.ahk
global TIMING_IPC_FIRE_WAIT := 10
global LOG_PATH_EVENTS := A_Temp "\tabby_events.log"

; Health check timestamp (used by gui_store.ahk)
global gGUI_LastMsgTick := 0
global gGUI_LauncherHwnd := 0  ; Not used in GUI tests, needed for production includes

; Interceptor globals (from gui_interceptor.ahk - mocked here since we don't include that file)
global gINT_BypassMode := false
global gINT_TabPending := false
global gMock_BypassResult := false  ; Controls INT_ShouldBypassWindow mock return value

; Config object mock (production code uses cfg.PropertyName)
global cfg := {
    FreezeWindowList: true,
    UseCurrentWSProjection: false,
    AltTabPrewarmOnAlt: true,
    AltTabGraceMs: 150,
    AltTabQuickSwitchMs: 100,
    AltTabBypassFullscreen: true,
    AltTabBypassProcesses: "",
    GUI_ScrollKeepHighlightOnTop: false,
    DebugAltTabTooltips: false,
    DiagEventLog: false,  ; Disable event logging during tests
    DiagPaintTimingLog: false,  ; Disable paint timing log during tests
    DiagProcPumpLog: false,
    DiagLauncherLog: false,
    DiagIPCLog: false,
    KomorebicExe: ""
}

; IPC client mock
global gGUI_StoreClient := { hPipe: 1, idleStreak: 0, tickMs: 100, timerFn: "" }
global gMockIPCMessages := []

; Test tracking
global GUI_TestPassed := 0
global GUI_TestFailed := 0

; ============================================================
; 2. VISUAL LAYER MOCKS (defined BEFORE includes)
; These replace gui_paint.ahk, gui_overlay.ahk functions
; ============================================================

; Visual operations - no-op in tests
GUI_Repaint() {
}

GUI_ResizeToRows(n) {
}

GUI_ComputeRowsToShow(n) {
    return Min(n, 10)
}

GUI_HideOverlay() {
    global gGUI_OverlayVisible
    gGUI_OverlayVisible := false
}

; GDI+ icon cache invalidation mock (called by GUI_ApplyDelta on removes)
Gdip_InvalidateIconCache(hwnd) {
}

; GDI+ icon cache prune mock (called by snapshot handler to dispose orphaned bitmaps)
global gMock_PruneCalledWith := ""
Gdip_PruneIconCache(liveHwnds) {
    global gMock_PruneCalledWith
    gMock_PruneCalledWith := liveHwnds
}

; Visible rows mock (called by _GUI_AnyVisibleItemChanged)
global gMock_VisibleRows := 5
GUI_GetVisibleRows() {
    global gMock_VisibleRows
    return gMock_VisibleRows
}

; Paint timing log mocks (gui_paint.ahk not included in tests)
global gPaint_LastPaintTick := 0
global gPaint_SessionPaintCount := 0
_Paint_Log(msg) {
}
_Paint_LogTrim() {
}
_Paint_LogStartSession() {
}

Win_DwmFlush() {
}

Win_GetScaleForWindow(hwnd) {
    return 1.0
}

; Win_Wrap0, Win_Wrap1 from production (gui_math.ahk)
#Include %A_ScriptDir%\..\src\gui\gui_math.ahk

; IPC mock - captures messages for assertions
IPC_PipeClient_Send(client, msgText) {
    global gMockIPCMessages
    gMockIPCMessages.Push(msgText)
    return true
}

; IPC polling mock (used by active-polling optimizations)
global IPC_TICK_ACTIVE := 15
_IPC_SetClientTick(client, ms) {
}

; Interceptor mocks (gui_interceptor.ahk functions - we don't include that file because it has hotkeys)
INT_ShouldBypassWindow(hwnd := 0) {
    global gMock_BypassResult
    return gMock_BypassResult
}

INT_SetBypassMode(shouldBypass) {
    global gINT_BypassMode
    gINT_BypassMode := shouldBypass
}

; Mock GUI objects (production code calls gGUI_Base.Show(), gGUI_Base.Hide(), etc.)
class _MockGui {
    visible := false
    Show(opts := "") {
        this.visible := true
    }
    Hide() {
        this.visible := false
    }
}
global gGUI_Base := _MockGui()
global gGUI_Overlay := _MockGui()

; ============================================================
; 3. INCLUDE ACTUAL PRODUCTION FILES
; These contain the REAL logic we want to test
; ============================================================

#Include %A_ScriptDir%\..\src\shared\cjson.ahk
#Include %A_ScriptDir%\..\src\gui\gui_input.ahk
#Include %A_ScriptDir%\..\src\gui\gui_workspace.ahk
#Include %A_ScriptDir%\..\src\gui\gui_store.ahk
#Include %A_ScriptDir%\..\src\gui\gui_state.ahk

; ============================================================
; 4. TEST UTILITIES
; ============================================================

ResetGUIState() {
    global gGUI_State, gGUI_Items, gGUI_FrozenItems, gGUI_AllItems
    global gGUI_Sel, gGUI_ScrollTop, gGUI_OverlayVisible, gGUI_TabCount
    global gGUI_FirstTabTick, gGUI_WorkspaceMode
    global gGUI_AwaitingToggleProjection, gMockIPCMessages, gGUI_CurrentWSName
    global gGUI_FooterText, gGUI_Revealed, gGUI_ItemsMap, gGUI_LastLocalMRUTick
    global gGUI_EventBuffer, gGUI_PendingPhase, gGUI_FlushStartTick
    global gMock_VisibleRows, gGUI_LastMsgTick, gMock_BypassResult
    global gGUI_Base, gGUI_Overlay, gINT_BypassMode, gMock_PruneCalledWith

    gGUI_State := "IDLE"
    gGUI_Items := []
    gGUI_ItemsMap := Map()
    gGUI_FrozenItems := []
    gGUI_AllItems := []
    gGUI_Sel := 1
    gGUI_ScrollTop := 0
    gGUI_OverlayVisible := false
    gGUI_TabCount := 0
    gGUI_FirstTabTick := 0
    gGUI_WorkspaceMode := "all"
    gGUI_CurrentWSName := ""
    gGUI_FooterText := ""
    gGUI_Revealed := false
    gGUI_AwaitingToggleProjection := false
    gGUI_LastLocalMRUTick := 0  ; Reset to avoid MRU freshness skip in snapshot handler
    gMockIPCMessages := []
    gGUI_EventBuffer := []
    gGUI_PendingPhase := ""
    gGUI_FlushStartTick := 0
    gMock_VisibleRows := 5
    gGUI_LastMsgTick := 0
    gMock_BypassResult := false
    gINT_BypassMode := false
    gMock_PruneCalledWith := ""
    gGUI_Base.visible := false
    gGUI_Overlay.visible := false
}

CreateTestItems(count, currentWSCount := -1) {
    ; Create test items with workspace info
    ; If currentWSCount is -1, all items are on current workspace
    ; NOTE: Uses lowercase keys to match JSON format from store (GUI_ConvertStoreItems expects lowercase)
    items := []
    if (currentWSCount < 0)
        currentWSCount := count

    Loop count {
        items.Push({
            hwnd: A_Index * 1000,
            title: "Window " A_Index,
            class: "TestClass",
            isOnCurrentWorkspace: (A_Index <= currentWSCount),
            workspaceName: (A_Index <= currentWSCount) ? "Main" : "Other",
            lastActivatedTick: A_TickCount - (A_Index * 100)  ; MRU order: lower index = more recent
        })
    }
    return items
}

; Simulate a server projection response (for UseCurrentWSProjection=true tests)
SimulateServerResponse(items) {
    global gGUI_AwaitingToggleProjection, IPC_MSG_PROJECTION
    projMsg := JSON.Dump({ type: IPC_MSG_PROJECTION, rev: A_TickCount, payload: { items: items }})
    GUI_OnStoreMessage(projMsg)
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

GUI_Log(msg) {
    FileAppend(msg "`n", A_Temp "\gui_tests.log", "UTF-8")
}

; ============================================================
; 5. TESTS - Now testing ACTUAL production code
; ============================================================

RunGUITests() {
    global GUI_TestPassed, GUI_TestFailed, gMockIPCMessages, cfg
    global gGUI_State, gGUI_Items, gGUI_FrozenItems, gGUI_AllItems
    global gGUI_Sel, gGUI_ScrollTop, gGUI_OverlayVisible, gGUI_TabCount
    global gGUI_WorkspaceMode, gGUI_AwaitingToggleProjection, gGUI_CurrentWSName
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

    ; ----- Test 12b: Toggle from current→all shows ALL items (Bug 2 regression test) -----
    GUI_Log("Test: Toggle current→all shows all items (Bug 2 regression)")
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

    ; ----- Test 12c: Toggle all→current filters correctly (Bug 1 regression test) -----
    GUI_Log("Test: Toggle all→current filters correctly (Bug 1 regression)")
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
    GUI_AssertEq(gGUI_Items.Length, 5, "Delta remove: initial 5 items")

    ; Remove items with hwnd 2000 and 4000
    deltaMsg := JSON.Dump({ type: IPC_MSG_DELTA, rev: 2, payload: { removes: [2000, 4000] } })
    GUI_OnStoreMessage(deltaMsg)

    GUI_AssertEq(gGUI_Items.Length, 3, "Delta remove: 3 items remain")
    GUI_AssertEq(gGUI_ItemsMap.Has(2000), false, "Delta remove: hwnd 2000 gone from map")
    GUI_AssertEq(gGUI_ItemsMap.Has(4000), false, "Delta remove: hwnd 4000 gone from map")
    GUI_AssertEq(gGUI_ItemsMap.Has(1000), true, "Delta remove: hwnd 1000 still in map")

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

    GUI_AssertEq(gGUI_Items.Length, 3, "Delta remove clamp: 3 items remain")
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

    GUI_AssertEq(gGUI_Items.Length, 5, "Delta upsert cosmetic: still 5 items")
    GUI_AssertEq(gGUI_ItemsMap[1000].Title, "Updated Title", "Delta upsert cosmetic: title updated")
    GUI_AssertEq(gGUI_ItemsMap[1000].processName, "updated.exe", "Delta upsert cosmetic: processName updated")

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
    GUI_AssertEq(gGUI_Items[1].hwnd, 3000, "Delta upsert MRU: item 3000 moved to first position")

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

    GUI_AssertEq(gGUI_Items.Length, 4, "Delta upsert new: 4 items total")
    GUI_AssertEq(gGUI_ItemsMap.Has(9999), true, "Delta upsert new: hwnd 9999 in map")
    GUI_AssertEq(gGUI_ItemsMap[9999].Title, "New Window", "Delta upsert new: title correct")

    cfg.FreezeWindowList := true  ; Restore

    ; ============================================================
    ; LOCAL MRU UPDATE TESTS
    ; ============================================================

    ; ----- Test: _GUI_UpdateLocalMRU moves item to position 1 -----
    GUI_Log("Test: _GUI_UpdateLocalMRU moves item to position 1")
    ResetGUIState()
    gGUI_Items := CreateTestItems(5)

    ; Move item 3 (hwnd=3000) to position 1
    result := _GUI_UpdateLocalMRU(3000)
    GUI_AssertTrue(result, "UpdateLocalMRU: returns true for known hwnd")
    GUI_AssertEq(gGUI_Items[1].hwnd, 3000, "UpdateLocalMRU: hwnd 3000 moved to position 1")
    GUI_AssertTrue(gGUI_LastLocalMRUTick > 0, "UpdateLocalMRU: freshness tick set")

    ; ----- Test: _GUI_UpdateLocalMRU unknown hwnd returns false -----
    GUI_Log("Test: _GUI_UpdateLocalMRU unknown hwnd")
    ResetGUIState()
    gGUI_Items := CreateTestItems(3)
    origFirst := gGUI_Items[1].hwnd

    result := _GUI_UpdateLocalMRU(99999)
    GUI_AssertTrue(!result, "UpdateLocalMRU: returns false for unknown hwnd")
    GUI_AssertEq(gGUI_Items[1].hwnd, origFirst, "UpdateLocalMRU: items unchanged for unknown hwnd")
    GUI_AssertEq(gGUI_LastLocalMRUTick, 0, "UpdateLocalMRU: tick NOT set for unknown hwnd")

    ; ----- Test: _GUI_UpdateLocalMRU already-first item -----
    GUI_Log("Test: _GUI_UpdateLocalMRU already-first item")
    ResetGUIState()
    gGUI_Items := CreateTestItems(3)
    firstHwnd := gGUI_Items[1].hwnd

    result := _GUI_UpdateLocalMRU(firstHwnd)
    GUI_AssertTrue(result, "UpdateLocalMRU: returns true for first item")
    GUI_AssertEq(gGUI_Items[1].hwnd, firstHwnd, "UpdateLocalMRU: first item stays first")
    GUI_AssertTrue(gGUI_LastLocalMRUTick > 0, "UpdateLocalMRU: tick set even for first item")

    ; ============================================================
    ; GUI_SortItemsByMRU TESTS
    ; ============================================================

    ; ----- Test: GUI_SortItemsByMRU sorts by lastActivatedTick descending -----
    GUI_Log("Test: GUI_SortItemsByMRU sorts correctly")
    ResetGUIState()
    gGUI_Items := []
    ticks := [100, 300, 200, 500, 400]
    Loop ticks.Length {
        gGUI_Items.Push({ hwnd: A_Index * 1000, title: "W" A_Index, lastActivatedTick: ticks[A_Index] })
    }

    GUI_SortItemsByMRU()

    GUI_AssertEq(gGUI_Items[1].lastActivatedTick, 500, "Sort MRU: first item has tick 500")
    GUI_AssertEq(gGUI_Items[2].lastActivatedTick, 400, "Sort MRU: second item has tick 400")
    GUI_AssertEq(gGUI_Items[3].lastActivatedTick, 300, "Sort MRU: third item has tick 300")
    GUI_AssertEq(gGUI_Items[4].lastActivatedTick, 200, "Sort MRU: fourth item has tick 200")
    GUI_AssertEq(gGUI_Items[5].lastActivatedTick, 100, "Sort MRU: fifth item has tick 100")

    ; ----- Test: GUI_SortItemsByMRU handles single item -----
    GUI_Log("Test: GUI_SortItemsByMRU handles single item")
    ResetGUIState()
    gGUI_Items := [{ hwnd: 1000, title: "Solo", lastActivatedTick: 42 }]
    GUI_SortItemsByMRU()
    GUI_AssertEq(gGUI_Items.Length, 1, "Sort MRU single: still 1 item")
    GUI_AssertEq(gGUI_Items[1].lastActivatedTick, 42, "Sort MRU single: value preserved")

    ; ----- Test: GUI_SortItemsByMRU handles empty list -----
    GUI_Log("Test: GUI_SortItemsByMRU handles empty list")
    ResetGUIState()
    gGUI_Items := []
    GUI_SortItemsByMRU()
    GUI_AssertEq(gGUI_Items.Length, 0, "Sort MRU empty: no error")

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
    gGUI_Items := CreateTestItems(5)
    gGUI_Sel := 2

    GUI_RemoveItemAt(3)  ; Remove middle item

    GUI_AssertEq(gGUI_Items.Length, 4, "RemoveItemAt middle: 4 items remain")
    GUI_AssertEq(gGUI_Sel, 2, "RemoveItemAt middle: selection unchanged")

    ; ----- Test: GUI_RemoveItemAt removes last item, clamps selection -----
    GUI_Log("Test: GUI_RemoveItemAt clamps selection")
    ResetGUIState()
    gGUI_Items := CreateTestItems(3)
    gGUI_Sel := 3  ; Select last item

    GUI_RemoveItemAt(3)  ; Remove last item

    GUI_AssertEq(gGUI_Items.Length, 2, "RemoveItemAt last: 2 items remain")
    GUI_AssertEq(gGUI_Sel, 2, "RemoveItemAt last: selection clamped to 2")

    ; ----- Test: GUI_RemoveItemAt removes only item -----
    GUI_Log("Test: GUI_RemoveItemAt removes only item")
    ResetGUIState()
    gGUI_Items := CreateTestItems(1)
    gGUI_Sel := 1

    GUI_RemoveItemAt(1)

    GUI_AssertEq(gGUI_Items.Length, 0, "RemoveItemAt only: list empty")
    GUI_AssertEq(gGUI_Sel, 1, "RemoveItemAt only: sel=1 (default)")
    GUI_AssertEq(gGUI_ScrollTop, 0, "RemoveItemAt only: scrollTop=0")

    ; ----- Test: GUI_RemoveItemAt out-of-bounds is no-op -----
    GUI_Log("Test: GUI_RemoveItemAt out-of-bounds")
    ResetGUIState()
    gGUI_Items := CreateTestItems(3)

    GUI_RemoveItemAt(0)
    GUI_AssertEq(gGUI_Items.Length, 3, "RemoveItemAt 0: no-op")

    GUI_RemoveItemAt(4)
    GUI_AssertEq(gGUI_Items.Length, 3, "RemoveItemAt 4: no-op (out of bounds)")

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

    ; ----- Test: GUI_UpdateCurrentWSFromPayload does NOT reset in all mode -----
    GUI_Log("Test: GUI_UpdateCurrentWSFromPayload no reset in all mode")
    ResetGUIState()
    gGUI_WorkspaceMode := "all"
    gGUI_State := "ACTIVE"
    gGUI_CurrentWSName := "Alpha"
    gGUI_Sel := 5

    payload := Map()
    payload["meta"] := Map("currentWSName", "Beta")

    GUI_UpdateCurrentWSFromPayload(payload)
    GUI_AssertEq(gGUI_CurrentWSName, "Beta", "WSPayload all: workspace updated")
    GUI_AssertEq(gGUI_Sel, 5, "WSPayload all: selection NOT reset")

    ; ============================================================
    ; GUI_MoveSelectionFrozen DIRECT TESTS
    ; ============================================================

    ; ----- Test: MoveSelectionFrozen empty list is no-op -----
    GUI_Log("Test: MoveSelectionFrozen empty list is no-op")
    ResetGUIState()
    gGUI_FrozenItems := []
    gGUI_Sel := 1
    GUI_MoveSelectionFrozen(1)
    GUI_AssertEq(gGUI_Sel, 1, "MoveSelectionFrozen: empty list is no-op")

    ; ----- Test: MoveSelectionFrozen forward wrap last->first -----
    GUI_Log("Test: MoveSelectionFrozen forward wrap")
    ResetGUIState()
    gGUI_FrozenItems := CreateTestItems(5)
    gGUI_Sel := 5
    GUI_MoveSelectionFrozen(1)
    GUI_AssertEq(gGUI_Sel, 1, "MoveSelectionFrozen: forward wrap last->first")

    ; ----- Test: MoveSelectionFrozen backward wrap first->last -----
    GUI_Log("Test: MoveSelectionFrozen backward wrap")
    ResetGUIState()
    gGUI_FrozenItems := CreateTestItems(5)
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
    gGUI_FrozenItems := CreateTestItems(12)
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
    gGUI_FrozenItems := CreateTestItems(12)
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
    gGUI_FrozenItems := CreateTestItems(12)
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
    gGUI_FrozenItems := CreateTestItems(12)
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
    gGUI_FrozenItems := CreateTestItems(12)
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
    gGUI_FrozenItems := CreateTestItems(3)
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
    gGUI_FrozenItems := CreateTestItems(1)
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
    gGUI_Items := CreateTestItems(5)
    gGUI_PendingPhase := "polling"
    gGUI_State := "ACTIVE"
    gGUI_EventBuffer := [{ev: TABBY_EV_TAB_STEP, flags: 0, lParam: 0}]

    GUI_OnInterceptorEvent(TABBY_EV_ESCAPE, 0, 0)

    GUI_AssertEq(gGUI_State, "IDLE", "ESC during async: state is IDLE")
    GUI_AssertEq(gGUI_PendingPhase, "", "ESC during async: pending phase cleared")
    GUI_AssertEq(gGUI_EventBuffer.Length, 0, "ESC during async: buffer cleared")

    ; ============================================================
    ; EMPTY EVENT BUFFER → RESYNC TEST
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
    gGUI_Items := CreateTestItems(5)
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
    gGUI_Items := CreateTestItems(5)
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
    GUI_AssertEq(gGUI_Items.Length, 4, "Bypass: new item added to list")

    ; ----- Test: Bypass mock returning false resets bypass mode -----
    GUI_Log("Test: Bypass mock returning false resets bypass mode")
    ResetGUIState()
    cfg.FreezeWindowList := false
    snapshotMsg := JSON.Dump({ type: IPC_MSG_SNAPSHOT, rev: 1, payload: { items: CreateTestItems(5) } })
    GUI_OnStoreMessage(snapshotMsg)
    gINT_BypassMode := true  ; Pre-set bypass to true
    gMock_BypassResult := false  ; Mock: window should NOT trigger bypass

    ; Send delta with isFocused=true — bypass check should disable bypass
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
    GUI_AssertEq(gGUI_Items.Length, 5, "Combined delta: initial 5 items")

    ; Single delta: remove hwnd 2000 and 4000, add hwnd 8888
    newRec := Map("hwnd", 8888, "title", "Brand New", "class", "NewClass", "lastActivatedTick", A_TickCount + 99999)
    deltaMsg := JSON.Dump({ type: IPC_MSG_DELTA, rev: 2, payload: { removes: [2000, 4000], upserts: [newRec] } })
    GUI_OnStoreMessage(deltaMsg)

    GUI_AssertEq(gGUI_Items.Length, 4, "Combined delta: 5 - 2 removed + 1 added = 4")
    GUI_AssertEq(gGUI_ItemsMap.Has(2000), false, "Combined delta: hwnd 2000 removed")
    GUI_AssertEq(gGUI_ItemsMap.Has(4000), false, "Combined delta: hwnd 4000 removed")
    GUI_AssertEq(gGUI_ItemsMap.Has(8888), true, "Combined delta: hwnd 8888 added")
    GUI_AssertEq(gGUI_ItemsMap[8888].Title, "Brand New", "Combined delta: new item title correct")

    ; ----- Test: Remove then re-add same hwnd (HWND reuse) -----
    GUI_Log("Test: Remove then re-add same hwnd (HWND reuse)")
    ResetGUIState()
    cfg.FreezeWindowList := false
    snapshotMsg := JSON.Dump({ type: IPC_MSG_SNAPSHOT, rev: 1, payload: { items: CreateTestItems(3) } })
    GUI_OnStoreMessage(snapshotMsg)
    GUI_AssertEq(gGUI_ItemsMap[1000].Title, "Window 1", "HWND reuse: original title")

    ; Remove hwnd 1000 and re-add with new title (simulates HWND reuse by OS)
    reusedRec := Map("hwnd", 1000, "title", "Reused Window", "class", "NewApp", "lastActivatedTick", A_TickCount + 99999)
    deltaMsg := JSON.Dump({ type: IPC_MSG_DELTA, rev: 2, payload: { removes: [1000], upserts: [reusedRec] } })
    GUI_OnStoreMessage(deltaMsg)

    GUI_AssertEq(gGUI_Items.Length, 3, "HWND reuse: still 3 items")
    GUI_AssertEq(gGUI_ItemsMap.Has(1000), true, "HWND reuse: hwnd 1000 exists")
    GUI_AssertEq(gGUI_ItemsMap[1000].Title, "Reused Window", "HWND reuse: title updated to new app")

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

    ; ----- Summary -----
    GUI_Log("`n=== GUI Test Summary ===")
    GUI_Log("Passed: " GUI_TestPassed)
    GUI_Log("Failed: " GUI_TestFailed)

    return GUI_TestFailed = 0
}

; ============================================================
; 6. RUN TESTS
; ============================================================

if (A_ScriptFullPath = A_LineFile) {
    try FileDelete(A_Temp "\gui_tests.log")
    result := RunGUITests()
    ExitApp(result ? 0 : 1)
}
