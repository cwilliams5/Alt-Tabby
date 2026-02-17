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

; IPC message types (from shared constants - still needed for flight recorder constants)
#Include %A_ScriptDir%\..\src\shared\ipc_constants.ahk

; GUI state globals
global gGUI_State := "IDLE"
global gGUI_LiveItems := []
global gGUI_LiveItemsMap := Map()  ; hwnd -> item lookup for O(1) access
global gGdip_IconCache := Map()   ; Icon cache stub for prune condition in gui_data
global gGUI_DisplayItems := []
global gGUI_ToggleBase := []
global gGUI_WSContextSwitch := false
global gGUI_Sel := 1
global gGUI_ScrollTop := 0
global gGUI_OverlayVisible := false
global gGUI_OverlayH := 0  ; Window handle - production code checks this
global gGUI_TabCount := 0
global gGUI_FirstTabTick := 0
global gGUI_WorkspaceMode := "all"
global gGUI_CurrentWSName := ""
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

; Stats globals (from gui_main.ahk, used by gui_state.ahk and gui_workspace.ahk)
global gStats_AltTabs := 0
global gStats_QuickSwitches := 0
global gStats_TabSteps := 0
global gStats_Cancellations := 0
global gStats_CrossWorkspace := 0
global gStats_WorkspaceToggles := 0
global gStats_LastSent := Map()

; Store globals (from window_list.ahk - not included in GUI test chain)
global gWS_Store := Map()
global gWS_DirtyHwnds := Map()

; Cosmetic repaint debounce (from gui_main.ahk - not included in GUI test chain)
global _gGUI_LastCosmeticRepaintTick := 0

; Win32 constants (from win_utils.ahk - not included in GUI test chain)
global DWMWA_CLOAKED := 14

; Constants from config_loader.ahk
global LOG_PATH_EVENTS := A_Temp "\tabby_events.log"

; Cached config values (from config_loader.ahk _CL_CacheHotPathValues)
global gCached_UseAltTabEligibility := true
global gCached_UseBlacklist := true

global gGUI_LauncherHwnd := 0  ; Not used in GUI tests, needed for production includes

; Interceptor globals (from gui_interceptor.ahk - mocked here since we don't include that file)
global gINT_BypassMode := false
global gINT_TabPending := false
global gMock_BypassResult := false  ; Controls INT_ShouldBypassWindow mock return value

; Config object mock (production code uses cfg.PropertyName)
global cfg := {
    AltTabSwitchOnClick: true,
    AltTabGraceMs: 150,
    AltTabQuickSwitchMs: 100,
    AltTabBypassFullscreen: true,
    AltTabBypassProcesses: "",
    GUI_ActiveRepaintDebounceMs: 250,
    GUI_ScrollKeepHighlightOnTop: false,
    DiagAltTabTooltips: false,
    DiagEventLog: false,  ; Disable event logging during tests
    DiagPaintTimingLog: false,  ; Disable paint timing log during tests
    DiagProcPumpLog: false,
    DiagPumpLog: false,
    DiagLauncherLog: false,
    DiagIPCLog: false,
    AdditionalWindowInformation: "Never",
    KomorebiIntegration: "Never",
    KomorebicExe: ""
}

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

; GDI+ icon cache invalidation mock
Gdip_InvalidateIconCache(hwnd) {
    global gGdip_IconCache
    if (gGdip_IconCache.Has(hwnd))
        gGdip_IconCache.Delete(hwnd)
}

; GDI+ icon cache prune mock (called by GUI_RefreshLiveItems)
global gMock_PruneCalledWith := ""
Gdip_PruneIconCache(liveHwnds) {
    global gMock_PruneCalledWith, gGdip_IconCache
    gMock_PruneCalledWith := liveHwnds
    ; Mirror production: remove entries not in live hwnds
    stale := []
    for hwnd, _ in gGdip_IconCache {
        if (!liveHwnds.Has(hwnd))
            stale.Push(hwnd)
    }
    for _, hwnd in stale
        gGdip_IconCache.Delete(hwnd)
}

; GDI+ icon pre-cache mock (called by GUI_RefreshLiveItems for visible items)
global gMock_PreCachedIcons := Map()
Gdip_PreCacheIcon(hwnd, hIcon) {
    global gMock_PreCachedIcons, gGdip_IconCache
    gMock_PreCachedIcons[hwnd] := hIcon
    ; Mirror production behavior: keep gGdip_IconCache in sync for prune condition
    ; pBmp: 1 simulates a valid GDI+ bitmap pointer (0 = failed conversion, would trigger retry)
    gGdip_IconCache[hwnd] := {hicon: hIcon, pBmp: 1}
}

; Visible rows mock (called by _GUI_AnyVisibleItemChanged and GUI_RefreshLiveItems)
global gMock_VisibleRows := 5
GUI_GetVisibleRows() {
    global gMock_VisibleRows
    return gMock_VisibleRows
}

; Paint timing log mocks (gui_paint.ahk not included in tests)
global gPaint_LastPaintTick := 0
global gPaint_SessionPaintCount := 0
Paint_Log(msg) {
}
Paint_LogTrim() {
}
Paint_LogStartSession() {
}

Win_DwmFlush() {
}

Win_GetScaleForWindow(hwnd) {
    return 1.0
}

; Win_Wrap0, Win_Wrap1 from production (gui_math.ahk)
#Include %A_ScriptDir%\..\src\gui\gui_math.ahk

; ============================================================
; WindowStore mocks — GUI_RefreshLiveItems calls these directly
; ============================================================

; Mock store data: tests populate this, then call GUI_RefreshLiveItems()
global gMock_StoreItems := []
global gMock_StoreItemsMap := Map()

WL_GetDisplayList(opts := "") {
    global gMock_StoreItems, gMock_StoreItemsMap
    ; Filter by currentWorkspaceOnly if requested
    items := gMock_StoreItems
    itemsMap := gMock_StoreItemsMap
    if (IsObject(opts) && opts.HasOwnProp("currentWorkspaceOnly") && opts.currentWorkspaceOnly) {
        items := []
        itemsMap := Map()
        for _, item in gMock_StoreItems {
            isOnCurrent := item.HasOwnProp("isOnCurrentWorkspace") ? item.isOnCurrentWorkspace : true
            if (isOnCurrent) {
                items.Push(item)
                itemsMap[item.hwnd] := item
            }
        }
    }
    return { items: items, itemsMap: itemsMap, rev: 1, meta: {}, cachePath: "mock" }
}

WL_UpdateFields(hwnd, fields, source := "") {
    ; No-op in tests
}

WL_PurgeBlacklisted() {
    ; No-op in tests
}

Blacklist_Init() {
    ; No-op in tests (gui_input.ahk calls this for blacklist reload)
}

; Stats mock (gui_state.ahk calls Stats_Accumulate directly)
Stats_Accumulate(msg) {
    ; No-op in tests
}

; Flight recorder mock (gui_flight_recorder.ahk not included - it registers F12 hotkey)
global gFR_Enabled := false
global gFR_DumpInProgress := false
global FR_EV_ALT_DN := 1, FR_EV_ALT_UP := 2, FR_EV_TAB_DN := 3, FR_EV_TAB_UP := 4
global FR_EV_TAB_DECIDE := 5, FR_EV_TAB_DECIDE_INNER := 6, FR_EV_ESC := 7, FR_EV_BYPASS := 8
global FR_EV_STATE := 10, FR_EV_FREEZE := 11, FR_EV_GRACE_FIRE := 12
global FR_EV_ACTIVATE_START := 13, FR_EV_ACTIVATE_RESULT := 14, FR_EV_MRU_UPDATE := 15
global FR_EV_BUFFER_PUSH := 16, FR_EV_QUICK_SWITCH := 17
global FR_EV_REFRESH := 20, FR_EV_ENRICH_REQ := 22, FR_EV_ENRICH_RESP := 23
global FR_EV_WINDOW_ADD := 24, FR_EV_WINDOW_REMOVE := 25, FR_EV_GHOST_PURGE := 26, FR_EV_BLACKLIST_PURGE := 27
global FR_EV_COSMETIC_PATCH := 28, FR_EV_SCAN_COMPLETE := 29
global FR_EV_SESSION_START := 30, FR_EV_PRODUCER_INIT := 31, FR_EV_ACTIVATE_GONE := 32
global FR_EV_WS_SWITCH := 40, FR_EV_WS_TOGGLE := 41
global FR_EV_FOCUS := 50, FR_EV_FOCUS_SUPPRESS := 51
global FR_ST_IDLE := 0, FR_ST_ALT_PENDING := 1, FR_ST_ACTIVE := 2
FR_Record(ev, d1:=0, d2:=0, d3:=0, d4:=0) {
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
#Include %A_ScriptDir%\..\src\gui\gui_data.ahk
#Include %A_ScriptDir%\..\src\gui\gui_state.ahk

; ============================================================
; 4. TEST UTILITIES
; ============================================================

; WARNING: When adding new GUI globals to this test file, you MUST add them
; to both the global declarations above AND the reset assignments below.
; Missing a reset causes test pollution (state carries between tests).
ResetGUIState() {
    global gGUI_State, gGUI_LiveItems, gGUI_DisplayItems, gGUI_ToggleBase
    global gGUI_Sel, gGUI_ScrollTop, gGUI_OverlayVisible, gGUI_TabCount
    global gGUI_FirstTabTick, gGUI_WorkspaceMode
    global gGUI_WSContextSwitch, gGUI_CurrentWSName
    global gGUI_FooterText, gGUI_Revealed, gGUI_LiveItemsMap
    global gGUI_EventBuffer, gGUI_PendingPhase
    global gMock_VisibleRows, gMock_BypassResult
    global gGUI_Base, gGUI_Overlay, gINT_BypassMode, gMock_PruneCalledWith
    global gMock_PreCachedIcons, gGdip_IconCache
    global gMock_StoreItems, gMock_StoreItemsMap

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
    gGUI_WSContextSwitch := false
    gGUI_EventBuffer := []
    gGUI_PendingPhase := ""
    gMock_VisibleRows := 5
    gMock_BypassResult := false
    gINT_BypassMode := false
    gMock_PruneCalledWith := ""
    gMock_PreCachedIcons := Map()
    gGdip_IconCache := Map()
    gMock_StoreItems := []
    gMock_StoreItemsMap := Map()
    global _gGUI_LastCosmeticRepaintTick
    global gWS_Store, gWS_DirtyHwnds
    _gGUI_LastCosmeticRepaintTick := 0
    gWS_Store := Map()
    gWS_DirtyHwnds := Map()
    gGUI_Base.visible := false
    gGUI_Overlay.visible := false
    ; Cancel any pending pre-cache timer from previous test
    try GUI_StopPreCache()
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
            title: "Window " A_Index,
            class: "TestClass",
            isOnCurrentWorkspace: (A_Index <= currentWSCount),
            workspaceName: (A_Index <= currentWSCount) ? "Main" : "Other",
            lastActivatedTick: A_TickCount - (A_Index * 100),  ; MRU order: lower index = more recent
            iconHicon: 0
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

; Setup test items for state machine tests.  Populates both direct globals
; (gGUI_LiveItems/Map) AND mock store so GUI_RefreshLiveItems() during
; ALT_DOWN prewarm returns the same data.
SetupTestItems(count, currentWSCount := -1) {
    global gGUI_LiveItems, gGUI_LiveItemsMap
    items := CreateTestItems(count, currentWSCount)
    MockStore_SetItems(items)
    gGUI_LiveItems := items
    gGUI_LiveItemsMap := Map()
    for idx, item in items
        gGUI_LiveItemsMap[item.hwnd] := item
    return items
}

; Set up mock store with items, making them available to GUI_RefreshLiveItems()
MockStore_SetItems(items) {
    global gMock_StoreItems, gMock_StoreItemsMap
    gMock_StoreItems := items
    gMock_StoreItemsMap := Map()
    for _, item in items
        gMock_StoreItemsMap[item.hwnd] := item
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
