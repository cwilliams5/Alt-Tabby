#Requires AutoHotkey v2.0
; Note: #SingleInstance removed - unified exe uses #SingleInstance Off
#UseHook true
InstallKeybdHook(true)

; CRITICAL: Use SendEvent mode to prevent keyboard hook from being uninstalled
; during Send operations. SendInput (default) temporarily removes the hook,
; causing rapid keypresses to be missed during cross-workspace activation.
; See: https://www.autohotkey.com/boards/viewtopic.php?t=127074
SendMode("Event")

; Alt-Tabby GUI - Main entry point
; This file orchestrates all GUI components by including sub-modules

; Declare before arg parsing so the default isn't clobbered by a later file-scope := 0
global gGUI_LauncherHwnd := 0  ; Launcher HWND for WM_COPYDATA control signals (0 = no launcher)

; Parse command-line arguments (only when running as GUI, not when included for other modes)
; Use try to handle standalone execution where g_AltTabbyMode may not exist
try {
    if (g_AltTabbyMode = "gui" || g_AltTabbyMode = "launch") {
        global ARG_LAUNCHER_HWND, ARG_LAUNCHER_HWND_LEN
        for _, arg in A_Args {
            if (arg = "--test")
                A_IconHidden := true
            else if (SubStr(arg, 1, ARG_LAUNCHER_HWND_LEN) = ARG_LAUNCHER_HWND)
                gGUI_LauncherHwnd := Integer(SubStr(arg, ARG_LAUNCHER_HWND_LEN + 1))
        }
    }
}

; Use an inert mask key so Alt taps don't focus menus
A_MenuMaskKey := "vkE8"

; ========================= INCLUDES (SHARED UTILITIES) =========================
; Shared utilities first (use *i for unified exe compatibility)
#Include *i %A_ScriptDir%\..\shared\config_loader.ahk
#Include *i %A_ScriptDir%\..\lib\cjson.ahk
#Include *i %A_ScriptDir%\..\lib\icon_alpha.ahk
#Include *i %A_ScriptDir%\..\shared\ipc_pipe.ahk
#Include *i %A_ScriptDir%\..\shared\blacklist.ahk
#Include *i %A_ScriptDir%\..\shared\process_utils.ahk
#Include *i %A_ScriptDir%\..\shared\theme.ahk
#Include *i %A_ScriptDir%\..\shared\theme_msgbox.ahk
#Include *i %A_ScriptDir%\..\shared\gui_antiflash.ahk

; GUI utilities
#Include *i %A_ScriptDir%\gui_gdip.ahk
#Include *i %A_ScriptDir%\gui_win.ahk
#Include *i %A_ScriptDir%\gui_constants.ahk

; ========================= GLOBAL STATE =========================
; CRITICAL: These must be declared BEFORE sub-module includes
; Sub-modules reference these globals and need them to exist at parse time

global gGUI_Revealed := false
; gGUI_HoverRow, gGUI_HoverBtn, gGUI_MouseTracking declared in gui_input.ahk (sole writer)
; gGUI_FooterText, gGUI_WorkspaceMode declared in gui_workspace.ahk (sole writer)
global gGUI_CurrentWSName := ""  ; Cached from gWS_Meta

global gGUI_OverlayVisible := false

; ========================= THREE-ARRAY DESIGN =========================
; gGUI_LiveItems:    CANONICAL source - always current, refreshed from WindowList.
;                    This is the live, unfiltered window list.
;
; gGUI_ToggleBase:   Copy used for workspace toggle (Ctrl key) support.
; gGUI_DisplayItems: DISPLAY list - what gets rendered and Tab cycles through.
;
; === Structural Freeze During ACTIVE ===
;
; On first Tab: gGUI_ToggleBase = shallow copy of gGUI_LiveItems (frozen positions).
; During ACTIVE: structural changes (add/remove/reorder) are ignored to prevent
; selection position corruption. Cosmetic changes (title, icon) are patched in-place.
; Workspace toggle: filters LOCALLY from gGUI_ToggleBase (instant).
; ======================================================================
global gGUI_LiveItems := []
global gGUI_Sel := 1
global gGUI_ScrollTop := 0

; gGUI_State declared in gui_state.ahk (sole writer for state machine)
; gGUI_FirstTabTick, gGUI_TabCount declared in gui_state.ahk (sole writer)
global gGUI_DisplayItems := []  ; Items being rendered (may be filtered by workspace mode)
; gGUI_ToggleBase declared in gui_state.ahk (sole writer for toggle support)

; Session stats counters declared in gui_state.ahk / gui_workspace.ahk (sole writers)

; Producer state
global _gGUI_ScanInProgress := false  ; Re-entrancy guard for full WinEnum scan
global HOUSEKEEPING_INTERVAL_MS := 300000  ; 5 minutes — cache pruning, log rotation, stats flush
; _gGUI_LastCosmeticRepaintTick declared in gui_data.ahk (sole writer)

; gGUI_LauncherHwnd declared+defaulted before arg parsing (line 14), assigned there if --launcher-hwnd= present

; ========================= INITIALIZATION =========================
; Sub-modules (gui_overlay, gui_state, gui_pump, etc.) are included
; by alt_tabby.ahk before this file. They reference globals declared above.

_GUI_Main_Init() {
    global cfg, FR_EV_PRODUCER_INIT, gFR_Enabled

    ; CRITICAL: Initialize config FIRST - sets all global defaults
    ConfigLoader_Init()

    ; Initialize theme (for blacklist dialog and MsgBox calls in GUI process)
    Theme_Init()

    ; Initialize event name map for logging
    GUI_InitEventNames()

    ; Initialize blacklist (filtering rules must load before producers)
    Blacklist_Init()

    ; Initialize flight recorder (if enabled) — must be before hotkey setup
    FR_Init()

    ; Start debug event log (if enabled)
    GUI_LogEventStartup()

    ; Start paint timing debug log (if enabled in config)
    Paint_LogStartSession()

    Win_InitDpiAwareness()
    Gdip_Startup()

    ; Initialize footer text based on workspace mode
    GUI_UpdateFooterText()

    ; ========================= PRODUCER INIT =========================
    ; CRITICAL INITIALIZATION ORDER (do not reorder):
    ; 1. Config + Blacklist (done above)
    ; 2. WindowList (data layer must exist before producers)
    ; 3. Stats engine (logging callbacks wired first)
    ; 4. Komorebi (workspace enrichment for initial scan)
    ; 5. Icon/Proc Pumps (data enrichers)
    ; 6. WinEnum initial scan (uses all above)
    ; 7. WinEventHook (requires initialized store + completed scan)
    ; 8. Hotkeys LAST (no hotkeys before data is populated)

    WL_Init()

    ; Wire producer callbacks so producers don't call Store_* directly
    WL_SetCallbacks(_GUI_OnProducerRevChanged, _GUI_OnWorkspaceFlips)

    ; Register stats logging callbacks and initialize stats tracking
    Stats_SetCallbacks(_GUI_StatsLogError, _GUI_StatsLogInfo)
    Stats_Init()

    ; Komorebi is optional — graceful if not installed.
    kMode := cfg.KomorebiIntegration
    if (kMode = "Always") {
        ksubOk := KomorebiSub_Init()
        if (gFR_Enabled)
            FR_Record(FR_EV_PRODUCER_INIT, 1, ksubOk ? 1 : 0)
        if (!ksubOk && cfg.DiagEventLog)
            GUI_LogEvent("INIT: KomorebiSub failed to start")
    } else if (kMode = "Polling") {
        KomorebiLite_Init()
    }

    ; Wire icon/proc pump callbacks to WindowList (inline fallback mode).
    ; When EnrichmentPump is connected, gui_pump.ahk overrides these to no-op
    ; (pump handles resolution, MainProcess receives results via IPC).
    IconPump_SetCallbacks(WL_PopIconBatch, WL_GetByHwnd, WL_UpdateFields, WL_GetExeIconCopy, WL_ExeIconCachePut)
    ProcPump_SetCallbacks(WL_PopPidBatch, WL_GetProcNameCached, WL_UpdateProcessName)

    ; Try connecting to EnrichmentPump for offloaded icon/title/proc resolution.
    ; If pump is unavailable, fall back to local inline pumps.
    pumpConnected := GUIPump_Init()
    if (gFR_Enabled)
        FR_Record(FR_EV_PRODUCER_INIT, 3, pumpConnected ? 1 : 0)
    if (!pumpConnected) {
        ; Local inline fallback — blocking calls run in MainProcess
        mode := cfg.AdditionalWindowInformation
        if (mode = "Always" || mode = "ProcessOnly") {
            IconPump_Start()
            ProcPump_Start()
        }
    }

    ; Initial full scan AFTER producers init so data includes komorebi workspace info
    _GUI_FullScan()

    ; WinEventHook is always enabled (primary source of window changes + MRU tracking)
    hookOk := WinEventHook_Start()
    if (gFR_Enabled)
        FR_Record(FR_EV_PRODUCER_INIT, 2, hookOk ? 1 : 0)
    if (!hookOk) {
        if (cfg.DiagEventLog)
            GUI_LogEvent("INIT: WinEventHook failed - enabling MRU_Lite fallback")
        ; Fallback: enable MRU_Lite for focus tracking
        MRU_Lite_Init()
        ; Fallback: enable safety polling if hook fails
        SetTimer(_GUI_FullScan, cfg.WinEnumFallbackScanIntervalMs)
    } else {
        ; Hook working - start Z-pump for on-demand scans (staggered)
        SetTimer(_GUI_StartZPump, -17)

        ; Optional safety net polling (usually disabled)
        if (cfg.WinEnumSafetyPollMs > 0)
            SetTimer(_GUI_FullScan, cfg.WinEnumSafetyPollMs)
    }

    ; Start lightweight existence validation (staggered)
    if (cfg.WinEnumValidateExistenceMs > 0)
        SetTimer(_GUI_StartValidateExistence, -37)

    ; Start housekeeping timer for cache pruning, log rotation, stats flush (staggered)
    SetTimer(_GUI_StartHousekeeping, -53)

    ; Set up interceptor keyboard hooks — MUST be LAST (no hotkeys before data is populated)
    INT_SetupHotkeys()

    ; Check initial bypass state based on current focused window
    INT_SetBypassMode(INT_ShouldBypassWindow(0))
}

; ========================= PRODUCER CALLBACKS =========================

; Called by producers (via gWS_OnStoreChanged) after modifying the store.
; Triggers GUI refresh when overlay is visible or pre-warming.
_GUI_OnProducerRevChanged(isStructural := true) {
    global gGUI_State

    ; Error boundary: producer callback errors must not crash the app.
    ; In the old store-as-process architecture, a store crash was isolated.
    ; Now that producers run in-process, an unhandled error here would propagate
    ; to _GUI_OnError → ExitApp(1). Log and skip — next cycle self-corrects.
    try {
        ; During IDLE: kick background icon→bitmap pre-cache.
        ; During ALT_PENDING: refresh live items to keep pre-warm data fresh.
        ; During ACTIVE: structural changes skip (selection stability),
        ;   cosmetic changes patch in-place and repaint.
        if (gGUI_State = "IDLE") {
            GUI_KickPreCache()
        } else if (gGUI_State = "ALT_PENDING") {
            GUI_RefreshLiveItems()
        } else if (gGUI_State = "ACTIVE") {
            ; Cosmetic changes: patch title/icon/processName in-place
            if (!isStructural)
                GUI_PatchCosmeticUpdates()
            ; Always check bypass mode on focus changes
            fgHwnd := DllCall("GetForegroundWindow", "Ptr")
            if (fgHwnd) {
                shouldBypass := INT_ShouldBypassWindow(fgHwnd)
                INT_SetBypassMode(shouldBypass)
            }
        }
    } catch as e {
        global LOG_PATH_STORE
        try LogAppend(LOG_PATH_STORE, "producer_rev_callback err=" e.Message " file=" e.File " line=" e.Line)
    }
}

; Called by KomorebiSub (via gWS_OnWorkspaceChanged) when workspace changes.
_GUI_OnWorkspaceFlips() {
    global gGUI_CurrentWSName, gWS_Meta, cfg

    ; Error boundary: same rationale as _GUI_OnProducerRevChanged above.
    try {
        ; Read workspace name directly from gWS_Meta (in-process, no IPC)
        wsName := ""
        if (IsObject(gWS_Meta)) {
            Critical "On"
            wsName := gWS_Meta.Has("currentWSName") ? gWS_Meta["currentWSName"] : ""
            Critical "Off"
        }

        if (wsName != "" && wsName != gGUI_CurrentWSName) {
            gGUI_CurrentWSName := wsName
            GUI_UpdateFooterText()

            ; Handle workspace switch during ACTIVE state
            Critical "On"
            GUI_HandleWorkspaceSwitch()
            Critical "Off"
        }
    } catch as e {
        Critical "Off"  ; Ensure Critical is released on error (AHK v2 auto-releases on return, but be explicit)
        global LOG_PATH_STORE
        try LogAppend(LOG_PATH_STORE, "workspace_flip_callback err=" e.Message " file=" e.File " line=" e.Line)
    }
}

; ========================= FULL SCAN =========================

_GUI_FullScan() {
    global _gGUI_ScanInProgress, gWS_Store, FR_EV_SCAN_COMPLETE, gFR_Enabled
    ; RACE FIX: Re-entrancy guard - if WinEnumLite_ScanAll() is interrupted by a
    ; timer that triggers another _GUI_FullScan, the nested scan would corrupt gWS_ScanId
    Critical "On"
    if (_gGUI_ScanInProgress) {
        Critical "Off"
        return
    }
    _gGUI_ScanInProgress := true
    Critical "Off"

    WL_BeginScan()
    recs := ""
    try recs := WinEnumLite_ScanAll()
    foundCount := IsObject(recs) ? recs.Length : 0
    if (IsObject(recs))
        WL_UpsertWindow(recs, "winenum_lite")
    WL_EndScan()
    if (gFR_Enabled)
        FR_Record(FR_EV_SCAN_COMPLETE, foundCount, gWS_Store.Count)
    Critical "On"
    _gGUI_ScanInProgress := false
    Critical "Off"
    _GUI_OnProducerRevChanged()
}

; ========================= PERIODIC TIMERS =========================

_GUI_StartZPump() {
    global cfg
    SetTimer(_GUI_ZPumpTick, cfg.ZPumpIntervalMs)
}

_GUI_ZPumpTick() {
    if (!WL_HasPendingZ())
        return
    _GUI_FullScan()
    WL_ClearZQueue()
}

_GUI_StartValidateExistence() {
    global cfg
    SetTimer(_GUI_ValidateExistenceTick, cfg.WinEnumValidateExistenceMs)
}

_GUI_ValidateExistenceTick() {
    result := WL_ValidateExistence()
    if (result.removed > 0)
        _GUI_OnProducerRevChanged()
}

_GUI_StartHousekeeping() {
    global HOUSEKEEPING_INTERVAL_MS
    SetTimer(_GUI_Housekeeping, HOUSEKEEPING_INTERVAL_MS)
}

_GUI_Housekeeping() {
    ; Cache pruning
    try KomorebiSub_PruneStaleCache()
    try WL_PruneProcNameCache()
    try WL_PruneExeIconCache()
    try ProcPump_PruneFailedPidCache()

    ; Flush churn diagnostics (if enabled)
    WL_FlushChurnLog()

    ; Log rotation
    _GUI_RotateDiagLogs()

    ; Flush stats to disk
    try Stats_FlushToDisk()
}

; ========================= DIAGNOSTIC LOG ROTATION =========================

_GUI_RotateDiagLogs() {
    global cfg
    global LOG_PATH_EVENTS, LOG_PATH_KSUB, LOG_PATH_WINEVENT
    global LOG_PATH_ICONPUMP, LOG_PATH_PROCPUMP
    global LOG_PATH_IPC, LOG_PATH_PUMP, LOG_PATH_COSMETIC_PATCH
    if (cfg.DiagEventLog)
        LogTrim(LOG_PATH_EVENTS)
    if (cfg.DiagKomorebiLog)
        LogTrim(LOG_PATH_KSUB)
    if (cfg.DiagWinEventLog)
        LogTrim(LOG_PATH_WINEVENT)
    if (cfg.DiagIconPumpLog)
        LogTrim(LOG_PATH_ICONPUMP)
    if (cfg.DiagProcPumpLog)
        LogTrim(LOG_PATH_PROCPUMP)
    if (cfg.DiagIPCLog)
        LogTrim(LOG_PATH_IPC)
    if (cfg.DiagPumpLog)
        LogTrim(LOG_PATH_PUMP)
    if (cfg.DiagCosmeticPatchLog)
        LogTrim(LOG_PATH_COSMETIC_PATCH)
}

; ========================= STATS LOGGING CALLBACKS =========================

_GUI_StatsLogError(msg) {
    global LOG_PATH_STORE
    try LogAppend(LOG_PATH_STORE, "stats_error " msg)
}

_GUI_StatsLogInfo(msg) {
    global cfg, LOG_PATH_EVENTS
    if (cfg.DiagEventLog)
        try LogAppend(LOG_PATH_EVENTS, "stats_info " msg)
}

; ========================= ERROR / EXIT HANDLERS =========================

; Log unhandled errors and exit
_GUI_OnError(err, *) {
    global LOG_PATH_STORE
    msg := "gui_error msg=" err.Message " file=" err.File " line=" err.Line " what=" err.What
    try LogAppend(LOG_PATH_STORE, msg)
    ExitApp(1)
}

; Clean up resources on exit
_GUI_OnExit(reason, code) { ; lint-ignore: dead-param
    ; Send any unsent stats, then flush to disk
    try Stats_AccumulateSession()
    try Stats_FlushToDisk()

    ; Stop all timers
    try SetTimer(_GUI_FullScan, 0)
    try SetTimer(_GUI_ZPumpTick, 0)
    try SetTimer(_GUI_StartZPump, 0)
    try SetTimer(_GUI_Housekeeping, 0)
    try SetTimer(_GUI_StartHousekeeping, 0)
    try SetTimer(_GUI_ValidateExistenceTick, 0)
    try SetTimer(_GUI_StartValidateExistence, 0)
    try GUI_StopPreCache()

    ; Stop WinEventHook
    try WinEventHook_Stop()

    ; Stop MRU fallback timer
    try SetTimer(MRU_Lite_Tick, 0)

    ; Stop viewer (if open)
    try Viewer_Shutdown()

    ; Stop pumps (pump client or local inline)
    try GUIPump_Stop()
    try IconPump_Stop()
    try ProcPump_Stop()

    ; Stop Komorebi producers
    try KomorebiSub_Stop()
    try KomorebiLite_Stop()

    ; Clean up icons (prevent HICON resource leaks)
    try WL_CleanupAllIcons()
    try WL_CleanupExeIconCache()
    try IconPump_CleanupUwpCache()

    ; Clean up GDI+
    Gdip_Shutdown()

    return 0
}

; ========================= MAIN AUTO-INIT =========================

; Auto-init only if running standalone or if mode is "gui"
if (!IsSet(g_AltTabbyMode) || g_AltTabbyMode = "gui") {
    _GUI_Main_Init()

    ; DPI change handler
    global WM_DPICHANGED
    OnMessage(WM_DPICHANGED, (wParam, lParam, msg, hwnd) => (gGdip_ResScale := 0.0, 0))

    ; Create windows
    GUI_CreateBase()
    gGUI_Sel := 1
    gGUI_ScrollTop := 0
    GUI_CreateOverlay()

    ; Pre-create GDI+ resources (fonts, brushes, string formats)
    ; GdipCreateFontFamilyFromName takes ~1.5s on first call (GDI+ font enumeration).
    ; Do it now at startup rather than deferring to first paint.
    scale := Win_GetScaleForWindow(gGUI_BaseH)
    GUI_EnsureResources(scale)

    ; Start hidden
    gGUI_OverlayVisible := false
    gGUI_Revealed := false

    ; Mouse handlers
    global WM_LBUTTONDOWN, WM_MOUSEMOVE, WM_MOUSELEAVE
    OnMessage(WM_LBUTTONDOWN, (wParam, lParam, msg, hwnd) => (hwnd = gGUI_OverlayH ? (GUI_OnClick(lParam & 0xFFFF, (lParam >> 16) & 0xFFFF), 0) : 0))
    OnMessage(0x020A, (wParam, lParam, msg, hwnd) => (hwnd = gGUI_OverlayH ? (GUI_OnWheel(wParam, lParam), 0) : 0))  ; lint-ignore: onmessage-collision
    OnMessage(WM_MOUSEMOVE, (wParam, lParam, msg, hwnd) => (hwnd = gGUI_OverlayH ? GUI_OnMouseMove(wParam, lParam, msg, hwnd) : 0))
    OnMessage(WM_MOUSELEAVE, (wParam, lParam, msg, hwnd) => (hwnd = gGUI_OverlayH ? GUI_OnMouseLeave() : 0))

    ; WM_COPYDATA handler for launcher commands (e.g., toggle viewer)
    global WM_COPYDATA, IPC_WM_STATS_REQUEST
    OnMessage(WM_COPYDATA, _GUI_OnCopyData)  ; lint-ignore: onmessage-collision (launcher_main.ahk registers in separate process)
    OnMessage(IPC_WM_STATS_REQUEST, _GUI_OnStatsRequest)

    ; Register error and exit handlers
    OnError(_GUI_OnError)
    OnExit(_GUI_OnExit)

    Persistent()
}

_GUI_OnCopyData(wParam, lParam, msg, hwnd) { ; lint-ignore: dead-param
    Critical "On"
    global TABBY_CMD_TOGGLE_VIEWER, TABBY_CMD_RELOAD_BLACKLIST, TABBY_CMD_PUMP_RESTARTED
    dwData := NumGet(lParam, 0, "uptr")
    if (dwData = TABBY_CMD_TOGGLE_VIEWER) {
        Viewer_Toggle()
        Critical "Off"
        return true
    }
    if (dwData = TABBY_CMD_RELOAD_BLACKLIST) {
        Blacklist_Init()
        WL_PurgeBlacklisted()
        Critical "Off"
        return true
    }
    if (dwData = TABBY_CMD_PUMP_RESTARTED) {
        GUIPump_Reconnect()
        Critical "Off"
        return true
    }
    Critical "Off"
    return 0
}

; Stats request handler — receives PostMessage(IPC_WM_STATS_REQUEST) from launcher.
; Responds with WM_COPYDATA containing JSON stats snapshot.
; Separate from WM_COPYDATA to avoid nested SendMessage deadlock in AHK v2.
_GUI_OnStatsRequest(wParam, lParam, msg, hwnd) { ; lint-ignore: dead-param
    Critical "On"
    global TABBY_CMD_STATS_RESPONSE, WM_COPYDATA
    senderHwnd := wParam
    if (!senderHwnd) {
        Critical "Off"
        return 0
    }
    snap := Stats_GetSnapshot()
    snapMap := Map()
    for prop in snap.OwnProps()
        snapMap[prop] := snap.%prop%
    jsonStr := JSON.Dump(snapMap)
    cbData := StrPut(jsonStr, "UTF-8")
    payload := Buffer(cbData, 0)
    StrPut(jsonStr, payload, "UTF-8")
    cds := Buffer(A_PtrSize * 3, 0)
    NumPut("uptr", TABBY_CMD_STATS_RESPONSE, cds, 0)
    NumPut("uptr", cbData, cds, A_PtrSize)
    NumPut("uptr", payload.Ptr, cds, A_PtrSize * 2)
    DetectHiddenWindows(true)
    try SendMessage(WM_COPYDATA, A_ScriptHwnd, cds.Ptr, , "ahk_id " senderHwnd)
    DetectHiddenWindows(false)
    Critical "Off"
    return 1
}
