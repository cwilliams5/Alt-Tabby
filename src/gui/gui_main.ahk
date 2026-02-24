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
#Include *i %A_ScriptDir%\..\shared\error_boundary.ahk
#Include *i %A_ScriptDir%\..\lib\cjson.ahk
#Include *i %A_ScriptDir%\..\lib\icon_alpha.ahk
#Include *i %A_ScriptDir%\..\shared\ipc_pipe.ahk
#Include *i %A_ScriptDir%\..\shared\ipc_wmcopydata.ahk
#Include *i %A_ScriptDir%\..\shared\blacklist.ahk
#Include *i %A_ScriptDir%\..\shared\process_utils.ahk
#Include *i %A_ScriptDir%\..\shared\theme.ahk
#Include *i %A_ScriptDir%\..\shared\theme_msgbox.ahk
#Include *i %A_ScriptDir%\..\shared\gui_antiflash.ahk
#Include *i %A_ScriptDir%\..\shared\timing.ahk
#Include *i %A_ScriptDir%\..\shared\profiler.ahk ; @profile
#Include *i %A_ScriptDir%\..\lib\OVERLAPPED.ahk
#Include *i %A_ScriptDir%\..\lib\DirectoryWatcher.ahk
#Include *i %A_ScriptDir%\..\shared\file_watcher.ahk

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
; gGUI_MonitorMode, gGUI_OverlayMonitorHandle declared in gui_monitor.ahk (sole writer)
; gGUI_CurrentWSName declared in gui_state.ahk (workspace state owner)

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
; gGUI_DisplayItems declared in gui_state.ahk (sole writer for display list management)
; gGUI_ToggleBase declared in gui_state.ahk (sole writer for toggle support)

; Session stats counters declared in gui_state.ahk / gui_workspace.ahk (sole writers)

; Producer state
global _gGUI_ScanInProgress := false  ; Re-entrancy guard for full WinEnum scan
global HOUSEKEEPING_INTERVAL_MS  ; Set from cfg.HousekeepingIntervalMs at init

; Staggered startup delays (primes to avoid timer alignment on first tick)
global STAGGER_ZPUMP_MS := 17
global STAGGER_VALIDATE_MS := 37
global STAGGER_HOUSEKEEPING_MS := 53
; _gGUI_LastCosmeticRepaintTick declared in gui_data.ahk (sole writer)

; gGUI_LauncherHwnd declared+defaulted before arg parsing (line 14), assigned there if --launcher-hwnd= present

; ========================= INITIALIZATION =========================
; Sub-modules (gui_overlay, gui_state, gui_pump, etc.) are included
; by alt_tabby.ahk before this file. They reference globals declared above.

_GUI_Main_Init() {
    global cfg, FR_EV_PRODUCER_INIT, gFR_Enabled, STAGGER_ZPUMP_MS, STAGGER_VALIDATE_MS, STAGGER_HOUSEKEEPING_MS, g_TestingMode
    global HOUSEKEEPING_INTERVAL_MS, gViewer_RefreshIntervalMs

    ; CRITICAL: Initialize config FIRST - sets all global defaults
    ConfigLoader_Init()

    ; Load config-driven constants (declared at file scope, set from cfg here)
    HOUSEKEEPING_INTERVAL_MS := cfg.HousekeepingIntervalMs
    gViewer_RefreshIntervalMs := cfg.DiagViewerRefreshMs

    ; Initialize theme (for blacklist dialog and MsgBox calls in GUI process)
    Theme_Init()

    ; Initialize event name map for logging
    GUI_InitEventNames()

    ; Initialize blacklist (filtering rules must load before producers)
    Blacklist_Init()

    ; Start blacklist file watcher — detects manual edits (Notepad, git checkout, scripts)
    ; and editor saves without WM_COPYDATA notification. Replaces TABBY_CMD_RELOAD_BLACKLIST.
    global gBlacklist_FilePath
    try {
        FileWatch_Start(gBlacklist_FilePath, _GUI_OnBlacklistFileChanged)
    } catch as e {
        global LOG_PATH_STORE
        try LogAppend(LOG_PATH_STORE, "FileWatch_Start(blacklist) failed: " e.Message)
    }

    ; Initialize flight recorder (if enabled) — must be before hotkey setup
    FR_Init()

    ; Initialize profiler hotkey (only present in --profile builds) ; @profile
    Profiler_Init() ; @profile

    ; Start debug event log (if enabled)
    GUI_LogEventStartup()

    ; Start paint timing debug log (if enabled in config)
    Paint_LogStartSession()

    Win_InitDpiAwareness()
    Win_InitMonitorCache()
    Gdip_Startup()

    ; Initialize monitor mode from config default
    GUI_InitMonitorMode()

    ; Initialize footer text based on workspace/monitor mode
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

    ; Wire producer callbacks (rev-changed, workspace-flips) so producers notify GUI of state changes
    WL_SetCallbacks(_GUI_OnProducerRevChanged, GUI_OnWorkspaceFlips)

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
        SetTimer(_GUI_StartZPump, -STAGGER_ZPUMP_MS)

        ; Optional safety net polling (usually disabled)
        if (cfg.WinEnumSafetyPollMs > 0)
            SetTimer(_GUI_FullScan, cfg.WinEnumSafetyPollMs)
    }

    ; Start lightweight existence validation (staggered)
    if (cfg.WinEnumValidateExistenceMs > 0)
        SetTimer(_GUI_StartValidateExistence, -STAGGER_VALIDATE_MS)

    ; Start housekeeping timer for cache pruning, log rotation, stats flush (staggered)
    SetTimer(_GUI_StartHousekeeping, -STAGGER_HOUSEKEEPING_MS)

    ; Lock working set after warm-up (5s delay lets caches populate)
    if (cfg.PerfKeepInMemory)
        SetTimer(_GUI_LockWorkingSet, -5000)

    ; Set up interceptor keyboard hooks — MUST be LAST (no hotkeys before data is populated)
    ; Skip in testing mode to avoid intercepting developer's real keystrokes during test runs
    if (!g_TestingMode) {
        INT_SetupHotkeys()

        ; Check initial bypass state based on current focused window
        INT_SetBypassMode(INT_ShouldBypassWindow(0))
    }
}

; ========================= PRODUCER CALLBACKS =========================

; Called by producers (via gWS_OnStoreChanged) after modifying the store.
; Triggers GUI refresh when overlay is visible or pre-warming.
_GUI_OnProducerRevChanged(isStructural := true) {
    global gGUI_State

    ; Error boundary: producers run in-process, so unhandled errors propagate
    ; to _GUI_OnError → ExitApp(1). Catch, log, and continue — next cycle self-corrects.
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
        }

        ; Check bypass mode on every focus change regardless of state.
        ; Previously gated to ACTIVE-only, which caused a deadlock: bypass
        ; disabled Tab hooks, and only ACTIVE state (requires Tab) could clear it.
        fgHwnd := DllCall("GetForegroundWindow", "Ptr")
        if (fgHwnd) {
            shouldBypass := INT_ShouldBypassWindow(fgHwnd)
            INT_SetBypassMode(shouldBypass)
        }

        ; Re-assert Tab hotkey is enabled when bypass is off.
        ; Recovers from silent desync where Hotkey("On") failed after bypass toggle.
        ; No-op when hooks are healthy (zero cost).
        INT_ReassertTabHotkey()
    } catch as e {
        global LOG_PATH_STORE
        try LogAppend(LOG_PATH_STORE, "producer_rev_callback err=" e.Message " file=" e.File " line=" e.Line)
    }
}

; GUI_OnWorkspaceFlips() moved to gui_state.ahk (workspace state owner)

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

    Profiler.Enter("_GUI_FullScan") ; @profile
    ; Error boundary: ensure WL_EndScan runs even on error (BeginScan/EndScan must be paired),
    ; and ensure _gGUI_ScanInProgress is always reset (otherwise re-entrancy guard blocks all future scans)
    try {
        WL_BeginScan()
        try {
            recs := ""
            try recs := WinEnumLite_ScanAll()
            foundCount := IsObject(recs) ? recs.Length : 0
            if (IsObject(recs))
                WL_UpsertWindow(recs, "winenum_lite")
        } finally {
            WL_EndScan()
        }
        if (gFR_Enabled)
            FR_Record(FR_EV_SCAN_COMPLETE, foundCount, gWS_Store.Count)
    } catch as e {
        Critical "Off"
        global LOG_PATH_STORE
        try LogAppend(LOG_PATH_STORE, "GUI_FullScan err=" e.Message " file=" e.File " line=" e.Line)
        Profiler.Leave() ; @profile
    }
    Critical "On"
    _gGUI_ScanInProgress := false
    Critical "Off"
    _GUI_OnProducerRevChanged()
    Profiler.Leave() ; @profile
}

; ========================= PERIODIC TIMERS =========================

_GUI_StartZPump() {
    global cfg
    SetTimer(_GUI_ZPumpTick, cfg.ZPumpIntervalMs)
}

_GUI_ZPumpTick() {
    static _errCount := 0  ; Error boundary: consecutive error tracking
    static _backoffUntil := 0  ; Tick-based cooldown for exponential backoff
    if (A_TickCount < _backoffUntil)
        return
    try {
        if (!WL_HasPendingZ())
            return
        _GUI_FullScan()
        WL_ClearZQueue()
        _errCount := 0
        _backoffUntil := 0
    } catch as e {
        global LOG_PATH_STORE
        HandleTimerError(e, &_errCount, &_backoffUntil, LOG_PATH_STORE, "GUI_ZPumpTick")
    }
}

_GUI_StartValidateExistence() {
    global cfg
    SetTimer(_GUI_ValidateExistenceTick, cfg.WinEnumValidateExistenceMs)
}

_GUI_ValidateExistenceTick() {
    Profiler.Enter("_GUI_ValidateExistenceTick") ; @profile
    static _errCount := 0  ; Error boundary: consecutive error tracking
    static _backoffUntil := 0  ; Tick-based cooldown for exponential backoff
    if (A_TickCount < _backoffUntil) {
        Profiler.Leave() ; @profile
        return
    }
    try {
        result := WL_ValidateExistence()
        if (result.removed > 0)
            _GUI_OnProducerRevChanged()
        _errCount := 0
        _backoffUntil := 0
    } catch as e {
        global LOG_PATH_STORE
        HandleTimerError(e, &_errCount, &_backoffUntil, LOG_PATH_STORE, "GUI_ValidateExistenceTick")
    }
    Profiler.Leave() ; @profile
}

_GUI_StartHousekeeping() {
    global HOUSEKEEPING_INTERVAL_MS
    SetTimer(_GUI_Housekeeping, HOUSEKEEPING_INTERVAL_MS)
}

_GUI_Housekeeping() {
    global cfg, LOG_PATH_STORE
    try {
    ; Cache pruning
    _GUI_TryHousekeep(KomorebiSub_PruneStaleCache, "KomorebiSub_PruneStaleCache", LOG_PATH_STORE)
    _GUI_TryHousekeep(WL_PruneProcNameCache, "WL_PruneProcNameCache", LOG_PATH_STORE)
    _GUI_TryHousekeep(WL_PruneExeIconCache, "WL_PruneExeIconCache", LOG_PATH_STORE)
    _GUI_TryHousekeep(ProcPump_PruneFailedPidCache, "ProcPump_PruneFailedPidCache", LOG_PATH_STORE)

    ; Flush churn diagnostics (if enabled)
    _GUI_TryHousekeep(WL_FlushChurnLog, "WL_FlushChurnLog", LOG_PATH_STORE)

    ; Log rotation
    _GUI_TryHousekeep(_GUI_RotateDiagLogs, "_GUI_RotateDiagLogs", LOG_PATH_STORE)

    ; Flush stats to disk
    _GUI_TryHousekeep(Stats_FlushToDisk, "Stats_FlushToDisk", LOG_PATH_STORE)

    ; Touch key data structures to keep memory pages resident
    if (cfg.PerfForceTouchMemory)
        _GUI_TryHousekeep(_GUI_TouchMemoryPages, "_GUI_TouchMemoryPages", LOG_PATH_STORE)

    ; Re-assert Tab hotkey (covers idle scenarios where no focus change fires)
    _GUI_TryHousekeep(INT_ReassertTabHotkey, "INT_ReassertTabHotkey", LOG_PATH_STORE)
    } catch as e {
        try LogAppend(LOG_PATH_STORE, "Housekeeping err=" e.Message " file=" e.File " line=" e.Line)
    }
}

_GUI_TryHousekeep(fn, name, logPath) {
    try {
        fn()
    } catch as e {
        try LogAppend(logPath, "Housekeeping " name " failed: " e.Message)
    }
}

; ========================= MEMORY MANAGEMENT =========================

_GUI_LockWorkingSet() {
    global cfg, LOG_PATH_STORE
    try {
        ; Query current working set via K32GetProcessMemoryInfo
        ; PROCESS_MEMORY_COUNTERS: 72 bytes on x64, WorkingSetSize at offset 16 (UPtr = SIZE_T)
        hProcess := DllCall("GetCurrentProcess", "Ptr")
        pmc := Buffer(72, 0)
        if (!DllCall("K32GetProcessMemoryInfo", "Ptr", hProcess, "Ptr", pmc, "UInt", 72, "Int"))
            return

        wsSize := NumGet(pmc, 16, "UPtr")

        ; Sanity check: skip if < 4MB or > 512MB (measurement anomaly)
        if (wsSize < 4 * 1024 * 1024 || wsSize > 512 * 1024 * 1024)
            return

        ; Set hard working set floor
        ; Flags: QUOTA_LIMITS_HARDWS_MIN_ENABLE (0x1) | QUOTA_LIMITS_HARDWS_MAX_DISABLE (0x8) = 0x9
        wsMax := wsSize * 3 // 2  ; 1.5x measured
        result := DllCall("SetProcessWorkingSetSizeEx", "Ptr", hProcess,
            "UPtr", wsSize, "UPtr", wsMax, "UInt", 0x9, "Int")

        if (cfg.DiagStoreLog) {
            wsMB := Round(wsSize / (1024 * 1024), 1)
            try LogAppend(LOG_PATH_STORE, "LockWorkingSet: set hard min=" wsMB "mb result=" result)
        }
    } catch as e {
        try LogAppend(LOG_PATH_STORE, "LockWorkingSet err=" e.Message)
    }
}

_GUI_TouchMemoryPages() {
    global gGdip_IconCache, gGUI_LiveItems, gGdip_Res, gWS_Store, gGdip_BrushCache

    ; Read one entry from each key data structure to keep pages resident.
    ; Single iteration pages in the Map's internal hash table.
    ; Read-only, discard results — no Critical section needed.

    if (gGdip_IconCache.Count)
        for _, v in gGdip_IconCache
            break

    if (gGdip_Res.Count)
        for _, v in gGdip_Res
            break

    if (gGdip_BrushCache.Count)
        for _, v in gGdip_BrushCache
            break

    if (gWS_Store.Count)
        for _, v in gWS_Store
            break

    ; Touch first and last element (different memory pages)
    if (gGUI_LiveItems.Length) {
        _ := gGUI_LiveItems[1]
        _ := gGUI_LiveItems[gGUI_LiveItems.Length]
    }
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
    try Stats_ForceFlushToDisk()

    ; Stop all timers
    try SetTimer(_GUI_FullScan, 0)
    try SetTimer(_GUI_ZPumpTick, 0)
    try SetTimer(_GUI_StartZPump, 0)
    try SetTimer(_GUI_Housekeeping, 0)
    try SetTimer(_GUI_StartHousekeeping, 0)
    try SetTimer(_GUI_ValidateExistenceTick, 0)
    try SetTimer(_GUI_StartValidateExistence, 0)
    try SetTimer(_GUI_LockWorkingSet, 0)
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

    ; Release COM objects (OS would clean up, but explicit is good hygiene)
    global gGUI_PendingShell, gGUI_ImmersiveShell, gGUI_AppViewCollection
    try gGUI_PendingShell := ""
    try gGUI_ImmersiveShell := ""
    try gGUI_AppViewCollection := ""

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
    ; IMPORTANT: Non-overlay branch must return "" (empty string), NOT 0.
    ; Returning any integer from OnMessage suppresses the message — AHK won't
    ; dispatch it to child controls.  Returning "" means "not handled, continue
    ; normal processing."  Returning 0 here previously ate WM_LBUTTONDOWN for
    ; every window in MainProcess, breaking buttons/edits in themed dialogs.
    OnMessage(WM_LBUTTONDOWN, (wParam, lParam, msg, hwnd) => (hwnd = gGUI_OverlayH ? (GUI_OnClick(lParam & 0xFFFF, (lParam >> 16) & 0xFFFF), 0) : ""))
    OnMessage(WM_MOUSEWHEEL, (wParam, lParam, msg, hwnd) => (hwnd = gGUI_OverlayH ? (GUI_OnWheel(wParam, lParam), 0) : ""))  ; lint-ignore: onmessage-collision
    OnMessage(WM_MOUSEMOVE, (wParam, lParam, msg, hwnd) => (hwnd = gGUI_OverlayH ? GUI_OnMouseMove(wParam, lParam, msg, hwnd) : ""))
    OnMessage(WM_MOUSELEAVE, (wParam, lParam, msg, hwnd) => (hwnd = gGUI_OverlayH ? GUI_OnMouseLeave() : ""))

    ; WM_COPYDATA handler for launcher commands (e.g., toggle viewer)
    global WM_COPYDATA, IPC_WM_STATS_REQUEST
    OnMessage(WM_COPYDATA, _GUI_OnCopyData, 2)  ; lint-ignore: onmessage-collision (launcher_main.ahk registers in separate process)
    OnMessage(IPC_WM_STATS_REQUEST, _GUI_OnStatsRequest)

    ; Register error and exit handlers
    OnError(_GUI_OnError)
    OnExit(_GUI_OnExit)

    Persistent()
}

_GUI_OnCopyData(wParam, lParam, msg, hwnd) { ; lint-ignore: dead-param
    Critical "On"
    global TABBY_CMD_TOGGLE_VIEWER, TABBY_CMD_PUMP_RESTARTED
    try {
        dwData := NumGet(lParam, 0, "uptr")
        if (dwData = TABBY_CMD_TOGGLE_VIEWER) {
            Viewer_Toggle()
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
    } catch as e {
        Critical "Off"
        global LOG_PATH_STORE
        try LogAppend(LOG_PATH_STORE, "GUI_OnCopyData err=" e.Message " file=" e.File " line=" e.Line)
        return 0
    }
}

; Blacklist file watcher callback — fires when blacklist.txt is modified on disk.
; Replaces the WM_COPYDATA RELOAD_BLACKLIST notification chain.
_GUI_OnBlacklistFileChanged(path) { ; lint-ignore: dead-param
    Critical "On"
    Blacklist_Init()
    result := WL_PurgeBlacklisted()
    global LOG_PATH_STORE, cfg
    if (cfg.DiagStoreLog)
        try LogAppend(LOG_PATH_STORE, "WATCH: blacklist reloaded, purged=" result.removed)
    Critical "Off"
}

; Stats request handler — receives PostMessage(IPC_WM_STATS_REQUEST) from launcher.
; Responds with WM_COPYDATA containing JSON stats snapshot.
; Separate from WM_COPYDATA to avoid nested SendMessage deadlock in AHK v2.
_GUI_OnStatsRequest(wParam, lParam, msg, hwnd) { ; lint-ignore: dead-param
    Critical "On"
    global TABBY_CMD_STATS_RESPONSE
    try {
        senderHwnd := wParam
        if (!senderHwnd) {
            Critical "Off"
            return 0
        }
        snap := Stats_GetSnapshot()
        jsonStr := JSON.Dump(snap)
        cbData := StrPut(jsonStr, "UTF-8")
        payload := Buffer(cbData, 0)
        StrPut(jsonStr, payload, "UTF-8")
        DetectHiddenWindows(true)
        IPC_SendWmCopyDataWithPayload(senderHwnd, TABBY_CMD_STATS_RESPONSE, payload, cbData)
        DetectHiddenWindows(false)
        Critical "Off"
        return 1
    } catch as e {
        Critical "Off"
        global LOG_PATH_STORE
        try LogAppend(LOG_PATH_STORE, "GUI_OnStatsRequest err=" e.Message " file=" e.File " line=" e.Line)
        return 0
    }
}
