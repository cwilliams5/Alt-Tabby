; GUI Tests Common - Shared globals, mocks, utilities
; This file is included by gui_tests_state.ahk and gui_tests_data.ahk
; Contains all setup required for GUI state machine testing
#Requires AutoHotkey v2.0
#Warn VarUnset, Off
A_IconHidden := true  ; No tray icon during tests

; Worktree-scoped log path (prevents cross-worktree log clobbering)
SplitPath(A_ScriptDir, , &_guiWorktreeParent)
SplitPath(_guiWorktreeParent, &_guiWorktreeId)
global GUI_TestLogPath := A_Temp "\gui_tests_" _guiWorktreeId ".log"

; ============================================================
; 1. GLOBALS (must match gui_main.ahk)
; ============================================================

; Event codes (from production gui_constants.ahk)
#Include %A_ScriptDir%\..\src\gui\gui_constants.ahk

; IPC message types (from shared constants - still needed for flight recorder constants)
#Include %A_ScriptDir%\..\src\shared\ipc_constants.ahk

; QPC timing (used by diagnostic instrumentation in gui_state, gui_paint, etc.)
#Include %A_ScriptDir%\..\src\shared\timing.ahk
; Profiler class (referenced by ; @profile lines in production code)
#Include %A_ScriptDir%\..\src\shared\profiler.ahk

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
global gGUI_StealFocus := false
global gGUI_FocusBeforeShow := 0
global gGUI_OverlayH := 0  ; Window handle - production code checks this
global gGUI_TabCount := 0
global gGUI_FirstTabTick := 0
global gGUI_WorkspaceMode := "all"
global gGUI_MonitorMode := "all"
global MON_MODE_ALL := "all"
global MON_MODE_CURRENT := "current"
global gGUI_OverlayMonitorHandle := 0
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
global gStats_MonitorToggles := 0
global gStats_LastSent := Map()

; Store globals (mocked for GUI tests — production uses embedded store in gui_main.ahk)
global gWS_Store := Map()
global gWS_Meta := Map()
global gWS_DirtyHwnds := Map()

; Cosmetic repaint debounce (from gui_main.ahk - not included in GUI test chain)
global _gGUI_LastCosmeticRepaintTick := 0

; Animation globals (from gui_animation.ahk - not included in GUI test chain)
global gAnim_OverlayOpacity := 1.0
global gAnim_HidePending := false
global gFX_AmbientTime := 0.0

; GPU effects globals (from gui_effects.ahk / gui_paint.ahk - not included in GUI test chain)
global gGUI_EffectStyle := 0
global gFX_GPUReady := false
global gFX_BackdropStyle := 0
global gFX_BackdropSeedX := 0.0
global gFX_BackdropSeedY := 0.0
global gFX_BackdropSeedPhase := 0.0
global gFX_BackdropDirSign := 1
global FX_BG_STYLE_NAMES := ["None", "Gradient", "Caustic", "Aurora", "Grain", "Vignette", "Layered"]
global gFX_ShaderIndex := 0
global gFX_ShaderTime := Map()
global gShader_Ready := false
global SHADER_NAMES := ["None"]
global gFX_MouseX := 0.0
global gFX_MouseY := 0.0
global gFX_MouseInWindow := false

; Win32 constants (from win_utils.ahk - not included in GUI test chain)
global DWMWA_CLOAKED := 14

; Constants from config_loader.ahk
global LOG_PATH_EVENTS := A_Temp "\tabby_events.log"
global LOG_PATH_STORE := A_Temp "\tabby_store_error.log"
global LOG_PATH_COSMETIC_PATCH := A_Temp "\tabby_cosmetic_patch.log"

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
    AltTabAsyncActivationPollMs: 15,
    AltTabWSPollTimeoutMs: 200,
    AltTabWorkspaceSwitchSettleMs: 75,
    AltTabBypassFullscreen: true,
    AltTabBypassProcesses: "",
    AltTabActivationRetry: true,
    AltTabActivationRetryDepth: 0,
    GUI_ActiveRepaintDebounceMs: 250,
    GUI_ScrollKeepHighlightOnTop: false,
    GUI_RowHeight: 56,
    GUI_MarginX: 18,
    GUI_MarginY: 18,
    GUI_IconSize: 36,
    GUI_IconLeftMargin: 8,
    GUI_IconTextGapPx: 12,
    GUI_ColumnGapPx: 10,
    GUI_HeaderHeightPx: 28,
    GUI_RowRadius: 12,
    GUI_ShowCloseButton: true,
    GUI_ShowKillButton: false,
    GUI_ShowBlacklistButton: true,
    GUI_ShowFooter: true,
    GUI_HoverPollIntervalMs: 100,
    DiagAltTabTooltips: false,
    DiagEventLog: false,  ; Disable event logging during tests
    DiagPaintTimingLog: false,  ; Disable paint timing log during tests
    DiagProcPumpLog: false,
    DiagCosmeticPatchLog: false,
    DiagPumpLog: false,
    DiagLauncherLog: false,
    DiagIPCLog: false,
    DiagProfilerHotkey: "*F11",
    DiagProfilerBufferSize: 50000,
    AdditionalWindowInformation: "Never",
    KomorebiIntegration: "Never",
    KomorebicExe: "",
    KomorebiCrossWorkspaceMethod: "MimicNative",
    KomorebiMimicNativeSettleMs: 0,
    KomorebiUseSocket: true,
    KomorebiWorkspaceConfirmMethod: "PollCloak",
    GUI_MonitorFilterDefault: "All",
    GUI_AcrylicColor: 0xCC000000,
    PerfAnimationType: "None",
    PerfAnimationSpeed: 1.0
}

; Test tracking
global GUI_TestPassed := 0
global GUI_TestFailed := 0

; ============================================================
; 2. VISUAL LAYER MOCKS (defined BEFORE includes)
; These replace gui_paint.ahk, gui_overlay.ahk functions
; ============================================================

; Visual operations - tracked via mock counter for cosmetic patch tests
global gMock_RepaintCount := 0
GUI_Repaint() {
    global gMock_RepaintCount
    gMock_RepaintCount++
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

; DWM acrylic mock (called by gui_state.ahk after Show)
Win_ApplyAcrylic(hWnd, argbColor) {
}

; GDI+ icon cache invalidation mock
Gdip_InvalidateIconCache(hwnd) {
    global gGdip_IconCache
    if (gGdip_IconCache.Has(hwnd))
        gGdip_IconCache.Delete(hwnd)
}

; Stats accumulate capture mock (called by gui_state.ahk Stats_AccumulateSession)
global gMock_LastStatsMsg := ""

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
    ; bitmap: 1 simulates a valid D2D bitmap (0 = failed conversion, would trigger retry)
    gGdip_IconCache[hwnd] := {hicon: hIcon, bitmap: 1}
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

; Animation mocks (gui_animation.ahk not included in tests)
Anim_StartTween(name, from, to, durationMs, easingFunc) {
}
Anim_StartSelectionSlide(prevSel, newSel, count) {
}
Anim_ForceCompleteHide() {
}
Anim_AddLayered() {
}
Anim_EaseOutQuad(t) {
    return t
}

; GPU effects mocks (gui_effects.ahk not included in tests)
FX_OnSelectionChange(gpuStyleIndex) {
}
FX_DrawBackdrop(wPhys, hPhys, scale) {
}
FX_PreRenderShaderLayer(w, h) {
}
FX_DrawShaderLayer(wPhys, hPhys) {
}
FX_SaveShaderTime() {
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

WL_IsOnCurrentWorkspace(workspaceName, currentWSName) {
    return (workspaceName = currentWSName) || (workspaceName = "")
}

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

WL_UpsertWindow(records, source := "") {
    ; No-op in tests (foreground guard calls this)
}

WinUtils_ProbeWindow(hwnd, z := 0, includeCloaked := false, checkEligible := false) {
    ; Return 0 (ineligible) in tests — foreground guard skips when probe fails
    return 0
}

WL_PurgeBlacklisted() {
    ; No-op in tests
}

Blacklist_Init() {
    ; No-op in tests (gui_input.ahk calls this for blacklist reload)
}

; Stats mock (gui_state.ahk calls Stats_Accumulate directly)
global gMock_LastStatsMsg := ""
Stats_Accumulate(msg) {
    global gMock_LastStatsMsg
    gMock_LastStatsMsg := msg
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
global FR_EV_SESSION_START := 30, FR_EV_PRODUCER_INIT := 31, FR_EV_ACTIVATE_GONE := 32, FR_EV_ACTIVATE_RETRY := 33
global FR_EV_WS_SWITCH := 40, FR_EV_WS_TOGGLE := 41, FR_EV_MON_TOGGLE := 42
global FR_EV_FOCUS := 50, FR_EV_FOCUS_SUPPRESS := 51, FR_EV_FG_GUARD := 53
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

; Monitor Win32 dependency mocks (gui_monitor.ahk is included for real logic)
; These replace the Win32 functions that gui_monitor.ahk calls internally.
GUI_GetTargetMonitorHwnd() {
    return 0  ; No real window in tests
}
Win_GetMonitorHandle(hwnd) {
    return 0  ; Tests set gGUI_OverlayMonitorHandle directly
}
Win_GetMonitorLabel(hMon) {
    return "Mon 1"
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

; Logging mocks (gui_data.ahk, gui_state.ahk call these)
LogAppend(params*) {
}
LogInitSession(params*) {
}
GetLogTimestamp() {
    return "00:00:00.000"
}

; Process utility mock (gui_state.ahk calls this)
ProcessUtils_RunHidden(params*) {
}

; Blacklist editor mocks (gui_input.ahk calls these)
Blacklist_AddClass(params*) {
}
Blacklist_AddPair(params*) {
}
Blacklist_AddTitle(params*) {
}

; Anti-flash mocks (gui_input.ahk calls these)
GUI_AntiFlashPrepare(params*) {
}
GUI_AntiFlashReveal(params*) {
}

; Layout mocks (gui_input.ahk, gui_math.ahk call these)
GUI_GetActionBtnMetrics(params*) {
    return {x: 0, y: 0, w: 0, h: 0, gap: 0}
}
GUI_HeaderBlockDip(params*) {
    return 0
}

; Theme mocks (gui_input.ahk calls these)
Theme_ApplyToControl(params*) {
}
Theme_ApplyToGui(params*) {
}
Theme_GetAccentColor(params*) {
    return "FFFFFF"
}
Theme_GetMutedColor(params*) {
    return "888888"
}
Theme_MarkAccent(params*) {
}
Theme_MarkMuted(params*) {
}
Theme_UntrackGui(params*) {
}

; Window utility mocks (gui_input.ahk calls these)
Win_ConfirmTopmost(params*) {
}
Win_GetRectPhys(params*) {
    return {x: 0, y: 0, w: 0, h: 0}
}

; ============================================================
; 3. INCLUDE ACTUAL PRODUCTION FILES
; These contain the REAL logic we want to test
; ============================================================

#Include %A_ScriptDir%\..\src\lib\cjson.ahk
#Include %A_ScriptDir%\..\src\gui\gui_input.ahk
#Include %A_ScriptDir%\..\src\gui\gui_workspace.ahk
#Include %A_ScriptDir%\..\src\gui\gui_monitor.ahk
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
    global gMock_RepaintCount
    global gGUI_MonitorMode, gGUI_OverlayMonitorHandle, gStats_MonitorToggles

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
    gMock_RepaintCount := 0
    global _gGUI_LastCosmeticRepaintTick
    global gWS_Store, gWS_DirtyHwnds
    global gMock_LastStatsMsg
    global gStats_AltTabs, gStats_QuickSwitches, gStats_TabSteps
    global gStats_Cancellations, gStats_CrossWorkspace, gStats_WorkspaceToggles
    global gStats_LastSent
    _gGUI_LastCosmeticRepaintTick := 0
    gWS_Store := Map()
    gWS_DirtyHwnds := Map()
    gMock_LastStatsMsg := ""
    gStats_AltTabs := 0
    gStats_QuickSwitches := 0
    gStats_TabSteps := 0
    gStats_Cancellations := 0
    gStats_CrossWorkspace := 0
    gStats_WorkspaceToggles := 0
    gStats_LastSent := Map()
    gGUI_MonitorMode := "all"
    gGUI_OverlayMonitorHandle := 0
    gStats_MonitorToggles := 0
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
            iconHicon: 0,
            processName: "",
            monitorHandle: 0,
            monitorLabel: ""
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
    global GUI_TestLogPath
    FileAppend(msg "`n", GUI_TestLogPath, "UTF-8")
}
