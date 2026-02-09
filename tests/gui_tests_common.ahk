; GUI Tests Common - Shared globals, mocks, utilities
; This file is included by gui_tests_state.ahk and gui_tests_data.ahk
; Contains all setup required for GUI state machine testing
#Requires AutoHotkey v2.0
#Warn VarUnset, Off
A_IconHidden := true  ; No tray icon during tests

; ============================================================
; 1. GLOBALS (must match gui_main.ahk)
; ============================================================

; Event codes (from production gui_constants.ahk)
#Include %A_ScriptDir%\..\src\gui\gui_constants.ahk

; IPC message types (from shared constants - no hardcoded copies)
#Include %A_ScriptDir%\..\src\shared\ipc_constants.ahk

; GUI state globals
global gGUI_State := "IDLE"
global gGUI_LiveItems := []
global gGUI_LiveItemsMap := Map()  ; hwnd -> item lookup for O(1) delta processing
global gGUI_DisplayItems := []
global gGUI_ToggleBase := []
global gGUI_AwaitingToggleProjection := false
global gGUI_WSContextSwitch := false
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
global gGUI_StoreWakeHwnd := 0
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

; Stats globals (from gui_main.ahk, used by gui_state.ahk and gui_workspace.ahk)
global gStats_AltTabs := 0
global gStats_QuickSwitches := 0
global gStats_TabSteps := 0
global gStats_Cancellations := 0
global gStats_CrossWorkspace := 0
global gStats_WorkspaceToggles := 0
global gStats_LastSent := Map()

; Constants from config_loader.ahk
global TIMING_IPC_FIRE_WAIT := 10
global LOG_PATH_EVENTS := A_Temp "\tabby_events.log"

; Cached config values (from config_loader.ahk _CL_CacheHotPathValues)
; These are used in hot paths to avoid cfg.HasOwnProp lookups
global gCached_MRUFreshnessMs := 300
global gCached_PrewarmWaitMs := 50
global gCached_UseAltTabEligibility := true
global gCached_UseBlacklist := true

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
    ServerSideWorkspaceFilter: false,
    AltTabPrewarmOnAlt: true,
    AltTabGraceMs: 150,
    AltTabQuickSwitchMs: 100,
    AltTabBypassFullscreen: true,
    AltTabBypassProcesses: "",
    GUI_ScrollKeepHighlightOnTop: false,
    DiagAltTabTooltips: false,
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

GUI_ResizeToRows(n, skipFlush := false) {
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

; GDI+ icon pre-cache mock (called on IPC receive to eagerly convert HICON → bitmap)
global gMock_PreCachedIcons := Map()
Gdip_PreCacheIcon(hwnd, hIcon) {
    global gMock_PreCachedIcons
    gMock_PreCachedIcons[hwnd] := hIcon
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
IPC_PipeClient_Send(client, msgText, wakeHwnd := 0) {
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

#Include %A_ScriptDir%\..\src\lib\cjson.ahk
#Include %A_ScriptDir%\..\src\gui\gui_input.ahk
#Include %A_ScriptDir%\..\src\gui\gui_workspace.ahk
#Include %A_ScriptDir%\..\src\gui\gui_store.ahk
#Include %A_ScriptDir%\..\src\gui\gui_state.ahk

; ============================================================
; 4. TEST UTILITIES
; ============================================================

ResetGUIState() {
    global gGUI_State, gGUI_LiveItems, gGUI_DisplayItems, gGUI_ToggleBase
    global gGUI_Sel, gGUI_ScrollTop, gGUI_OverlayVisible, gGUI_TabCount
    global gGUI_FirstTabTick, gGUI_WorkspaceMode
    global gGUI_AwaitingToggleProjection, gGUI_WSContextSwitch, gMockIPCMessages, gGUI_CurrentWSName
    global gGUI_FooterText, gGUI_Revealed, gGUI_LiveItemsMap, gGUI_LastLocalMRUTick
    global gGUI_EventBuffer, gGUI_PendingPhase, gGUI_FlushStartTick
    global gMock_VisibleRows, gGUI_LastMsgTick, gMock_BypassResult
    global gGUI_Base, gGUI_Overlay, gINT_BypassMode, gMock_PruneCalledWith
    global gMock_PreCachedIcons

    gGUI_State := "IDLE"
    gGUI_LiveItems := []
    gGUI_LiveItemsMap := Map()
    gGUI_DisplayItems := []
    gGUI_ToggleBase := []
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
    gGUI_WSContextSwitch := false
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
    gMock_PreCachedIcons := Map()
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

; Create test items AND populate gGUI_LiveItemsMap for tests that use _GUI_UpdateLocalMRU
; (which needs the Map for O(1) miss detection)
CreateTestItemsWithMap(count, currentWSCount := -1) {
    global gGUI_LiveItemsMap
    items := CreateTestItems(count, currentWSCount)
    gGUI_LiveItemsMap := Map()
    for _, item in items
        gGUI_LiveItemsMap[item.hwnd] := item
    return items
}

; Simulate a server projection response (for ServerSideWorkspaceFilter=true tests)
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
