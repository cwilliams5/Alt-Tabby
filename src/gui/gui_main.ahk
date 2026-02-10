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
global gGUI_HoverRow := 0
global gGUI_HoverBtn := ""
global gGUI_MouseTracking := false  ; Whether we've requested WM_MOUSELEAVE notification
; gGUI_FooterText, gGUI_WorkspaceMode declared in gui_workspace.ahk (sole writer)
global gGUI_CurrentWSName := ""  ; Cached from store meta

global gGUI_StoreClient := 0
global gGUI_StoreConnected := false

global gGUI_OverlayVisible := false

; ========================= THREE-ARRAY DESIGN =========================
; gGUI_LiveItems:       CANONICAL source - always current, updated by IPC deltas.
;                   This is the live, unfiltered window list from the store.
;
; gGUI_ToggleBase:    Copy used for workspace toggle (Ctrl key) support.
; gGUI_DisplayItems: DISPLAY list - what gets rendered and Tab cycles through.
;
; BEHAVIOR DEPENDS ON TWO CONFIG OPTIONS:
;
; === cfg.FreezeWindowList (controls delta handling during ACTIVE) ===
;
; When FreezeWindowList=false (default):
;   - During ACTIVE: Each delta updates gGUI_LiveItems, then BOTH arrays are
;     recreated from it (gGUI_ToggleBase := gGUI_LiveItems, then re-filter)
;   - Result: Display is "live" - windows can appear/disappear mid-overlay
;   - Note: Despite the names, arrays are NOT frozen in this mode
;
; When FreezeWindowList=true:
;   - On first Tab: Both arrays are created as point-in-time snapshots
;   - During ACTIVE: IPC deltas ignored (except workspace change tracking)
;   - Result: Display shows frozen snapshot, windows won't appear/disappear
;
; === cfg.ServerSideWorkspaceFilter (controls workspace toggle behavior) ===
;
; When ServerSideWorkspaceFilter=false (default):
;   - Ctrl toggle filters LOCALLY from gGUI_ToggleBase
;   - gGUI_ToggleBase stays unfiltered, allowing instant toggle back/forth
;   - No IPC roundtrip needed
;
; When ServerSideWorkspaceFilter=true:
;   - Ctrl toggle requests NEW projection from store with workspace filter
;   - Server returns PRE-FILTERED data
;   - gGUI_LiveItems receives filtered data, gGUI_ToggleBase := gGUI_LiveItems
;   - gGUI_ToggleBase is now ALSO filtered (loses "all" semantics)
;   - Toggling back requires another IPC request
; ======================================================================
global gGUI_LiveItems := []
global gGUI_Sel := 1
global gGUI_ScrollTop := 0

; State machine: IDLE -> ALT_PENDING -> ACTIVE
; IDLE: Normal state, receiving/applying deltas, cache fresh
; ALT_PENDING: Alt held, optional pre-warm, still receiving deltas
; ACTIVE: List FROZEN on first Tab, ignores all updates, Tab cycles selection
global gGUI_State := "IDLE"
; gGUI_FirstTabTick, gGUI_TabCount declared in gui_state.ahk (sole writer)
global gGUI_DisplayItems := []  ; Items being rendered (may be filtered by workspace mode)
global gGUI_ToggleBase := []     ; Snapshot for workspace toggle (Ctrl key support)
global gGUI_LastLocalMRUTick := 0  ; Timestamp of last local MRU update (to skip stale prewarns)

; Session stats counters declared in gui_state.ahk / gui_workspace.ahk (sole writers)

; Store health check state
global gGUI_LastMsgTick := 0       ; Timestamp of last message from store
global gGUI_ReconnectAttempts := 0 ; Counter for failed reconnection attempts
global gGUI_StoreRestartAttempts := 0  ; Counter for store restart attempts
global gGUI_LauncherHwnd := 0  ; Launcher HWND for WM_COPYDATA control signals (0 = no launcher)

; ========================= INCLUDES (SUB-MODULES) =========================
; These sub-modules reference the globals declared above
#Include *i %A_ScriptDir%\gui_overlay.ahk
#Include *i %A_ScriptDir%\gui_workspace.ahk
#Include *i %A_ScriptDir%\gui_paint.ahk
#Include *i %A_ScriptDir%\gui_input.ahk
#Include *i %A_ScriptDir%\gui_store.ahk
#Include *i %A_ScriptDir%\gui_state.ahk
#Include *i %A_ScriptDir%\gui_interceptor.ahk

; ========================= INITIALIZATION =========================

GUI_Main_Init() {
    global gGUI_StoreClient, cfg, IPC_MSG_HELLO, gGUI_LastMsgTick

    ; CRITICAL: Initialize config FIRST - sets all global defaults
    ConfigLoader_Init()

    ; Initialize theme (for blacklist dialog and MsgBox calls in GUI process)
    Theme_Init()

    ; Initialize event name map for logging
    GUI_InitEventNames()

    ; Initialize blacklist for writing (needed for blacklist button in GUI)
    Blacklist_Init()

    ; Start debug event log (if enabled)
    GUI_LogEventStartup()

    ; Start paint timing debug log (if enabled in config)
    Paint_LogStartSession()

    Win_InitDpiAwareness()
    Gdip_Startup()

    ; Initialize footer text based on workspace mode
    GUI_UpdateFooterText()

    ; Set up interceptor keyboard hooks (built-in, no IPC)
    INT_SetupHotkeys()

    ; Register PostMessage wake handler: store signals us after writing to the pipe
    ; so we read data immediately instead of waiting for next timer tick
    global IPC_WM_PIPE_WAKE
    OnMessage(IPC_WM_PIPE_WAKE, _GUI_OnPipeWake)

    ; Connect to WindowStore
    gGUI_StoreClient := IPC_PipeClient_Connect(cfg.StorePipeName, GUI_OnStoreMessage)
    if (gGUI_StoreClient.hPipe) {
        ; Request deltas so we stay up to date like the viewer
        ; Include our hwnd so store can PostMessage us after pipe writes
        hello := { type: IPC_MSG_HELLO, hwnd: A_ScriptHwnd, wants: { deltas: true }, projectionOpts: { sort: "MRU", columns: "items", includeCloaked: true } }
        IPC_PipeClient_Send(gGUI_StoreClient, JSON.Dump(hello))
        gGUI_LastMsgTick := A_TickCount  ; Initialize last message time
    }

    ; Start store health check timer (uses heartbeat interval from config)
    ; Timer fires every heartbeat interval to check if we've received messages recently
    healthCheckMs := cfg.StoreHeartbeatIntervalMs
    SetTimer(_GUI_StoreHealthCheck, healthCheckMs)

    ; Check initial bypass state based on current focused window
    ; If a fullscreen game is already focused when Alt-Tabby starts, enable bypass immediately
    INT_SetBypassMode(INT_ShouldBypassWindow(0))
}

; ========================= STORE HEALTH CHECK =========================

_GUI_StoreHealthCheck() {
    global gGUI_StoreClient, gGUI_StoreConnected, gGUI_LastMsgTick
    global gGUI_ReconnectAttempts, gGUI_StoreRestartAttempts, cfg
    global IPC_MSG_HELLO

    global MAX_RECONNECT_ATTEMPTS, MAX_RESTART_ATTEMPTS, TOOLTIP_DURATION_DEFAULT, TOOLTIP_DURATION_LONG
    timeoutMs := cfg.ViewerHeartbeatTimeoutMs  ; Same timeout as viewer (default 12s)
    maxReconnectAttempts := MAX_RECONNECT_ATTEMPTS
    maxRestartAttempts := MAX_RESTART_ATTEMPTS

    ; Case 1: Pipe handle is invalid (store disconnected or never connected)
    if (!IsObject(gGUI_StoreClient) || !gGUI_StoreClient.hPipe) {
        gGUI_StoreConnected := false
        gGUI_ReconnectAttempts++

        if (gGUI_ReconnectAttempts <= maxReconnectAttempts) {
            ; Try to reconnect - NON-BLOCKING (timeoutMs=0 = single attempt, no loop)
            ; This prevents the busy-wait loop in _IPC_ClientConnect from freezing
            ; keyboard/mouse input via blocked low-level hook callbacks.
            if (cfg.DiagEventLog)
                GUI_LogEvent("HEALTH: Store disconnected, reconnect attempt " gGUI_ReconnectAttempts "/" maxReconnectAttempts)
            ToolTip("Alt-Tabby: Reconnecting to window tracker... (" gGUI_ReconnectAttempts "/" maxReconnectAttempts ")")
            HideTooltipAfter(TOOLTIP_DURATION_DEFAULT)

            ; RACE FIX: Wrap close + reconnect in Critical to prevent hotkey
            ; from writing to closed handle between close and reassign
            Critical "On"
            ; Defensive close before reconnect (in case of stale handle)
            if (IsObject(gGUI_StoreClient) && gGUI_StoreClient.hPipe)
                IPC_PipeClient_Close(gGUI_StoreClient)

            gGUI_StoreClient := IPC_PipeClient_Connect(cfg.StorePipeName, GUI_OnStoreMessage, 0)
            Critical "Off"
            if (gGUI_StoreClient.hPipe) {
                ; Reconnected successfully - include hwnd for PostMessage wake
                hello := { type: IPC_MSG_HELLO, hwnd: A_ScriptHwnd, wants: { deltas: true }, projectionOpts: { sort: "MRU", columns: "items", includeCloaked: true } }
                IPC_PipeClient_Send(gGUI_StoreClient, JSON.Dump(hello))
                gGUI_LastMsgTick := A_TickCount
                gGUI_ReconnectAttempts := 0
                gGUI_StoreConnected := true
                if (cfg.DiagEventLog)
                    GUI_LogEvent("HEALTH: Reconnect succeeded")
                ToolTip("Alt-Tabby: Reconnected")
                HideTooltipAfter(TOOLTIP_DURATION_DEFAULT)
            }
            ; If failed, next health check tick will retry (no blocking)
        } else if (gGUI_StoreRestartAttempts < maxRestartAttempts) {
            ; Reconnection failed repeatedly - restart store
            gGUI_StoreRestartAttempts++
            gGUI_ReconnectAttempts := 0  ; Reset for next cycle

            if (cfg.DiagEventLog)
                GUI_LogEvent("HEALTH: Reconnect exhausted, restarting store attempt " gGUI_StoreRestartAttempts "/" maxRestartAttempts)
            ToolTip("Alt-Tabby: Restarting window tracker... (" gGUI_StoreRestartAttempts "/" maxRestartAttempts ")")
            HideTooltipAfter(TOOLTIP_DURATION_LONG)

            _GUI_RequestStoreRestart()
            ; Don't Sleep or block here - the next health check tick (5s) will
            ; attempt connection after the store has had time to start up.
        } else {
            if (cfg.DiagEventLog)
                GUI_LogEvent("HEALTH: All restart attempts exhausted (" maxRestartAttempts " restarts, " maxReconnectAttempts " reconnects each)")
            ; Notify user that Alt+Tab functionality is lost
            ToolTip("Alt-Tabby: Connection lost. Restart from tray menu or relaunch.")
            TrayTip("Alt-Tabby", "Window tracker connection failed.`nRight-click tray icon to restart.", "Icon!")
        }
        ; If all restart attempts exhausted, stop trying (avoid infinite loop)
        return
    }

    ; Case 2: Pipe handle valid but no messages received in timeout period
    if (gGUI_LastMsgTick && (A_TickCount - gGUI_LastMsgTick) > timeoutMs) {
        ; RACE FIX: Wrap close + reassign in Critical to prevent hotkey
        ; from writing to closed handle between close and reassign
        Critical "On"
        ; Connection may be stale - close and try reconnecting
        gGUI_StoreConnected := false
        IPC_PipeClient_Close(gGUI_StoreClient)
        gGUI_StoreClient := { hPipe: 0 }  ; Reset to trigger reconnect on next tick
        Critical "Off"
        return
    }

    ; Case 3: All good - reset counters
    if (gGUI_StoreClient.hPipe && gGUI_StoreConnected) {
        gGUI_ReconnectAttempts := 0
        gGUI_StoreRestartAttempts := 0
    }
}

_GUI_StartStore() {
    global cfg

    ; Determine how to start the store based on compiled vs dev mode
    if (A_IsCompiled) {
        ; Compiled: run same exe with --store flag
        ProcessUtils_RunHidden('"' A_ScriptFullPath '" --store')
    } else {
        ; Dev mode: run store_server.ahk directly
        storePath := A_ScriptDir "\..\store\store_server.ahk"
        runner := (cfg.HasOwnProp("AhkV2Path") && cfg.AhkV2Path != "" && FileExist(cfg.AhkV2Path))
            ? cfg.AhkV2Path : A_AhkPath
        ProcessUtils_RunHidden('"' runner '" "' storePath '"')
    }
}

; Request store restart: signal launcher (preferred) or start store directly (fallback)
_GUI_RequestStoreRestart() {
    global gGUI_LauncherHwnd, TABBY_CMD_RESTART_STORE, cfg

    ; Try launcher first: it tracks the store PID and kills the old process
    if (gGUI_LauncherHwnd && DllCall("user32\IsWindow", "ptr", gGUI_LauncherHwnd)) {
        cds := Buffer(3 * A_PtrSize, 0)
        NumPut("uptr", TABBY_CMD_RESTART_STORE, cds, 0)
        NumPut("uint", 0, cds, A_PtrSize)
        NumPut("ptr", 0, cds, 2 * A_PtrSize)

        global WM_COPYDATA
        result := DllCall("user32\SendMessageTimeoutW"
            , "ptr", gGUI_LauncherHwnd
            , "uint", WM_COPYDATA
            , "ptr", A_ScriptHwnd
            , "ptr", cds.Ptr
            , "uint", 0x0002  ; SMTO_ABORTIFHUNG
            , "uint", 3000
            , "ptr*", &response := 0
            , "ptr")

        if (result && response = 1) {
            if (cfg.DiagEventLog)
                GUI_LogEvent("HEALTH: Signaled launcher to restart store")
            return
        }
        if (cfg.DiagEventLog)
            GUI_LogEvent("HEALTH: Launcher signal failed (result=" result "), falling back to direct restart")
        gGUI_LauncherHwnd := 0  ; Invalidate — don't retry a dead launcher
    }

    ; Fallback: no launcher or signal failed
    _GUI_StartStore()
}

; PostMessage wake handler: store wrote to our pipe and signaled us.
; Read immediately instead of waiting for next timer tick.
_GUI_OnPipeWake(wParam, lParam, msg, hwnd) {
    global gGUI_StoreClient
    if (IsObject(gGUI_StoreClient) && gGUI_StoreClient.hPipe)
        IPC__ClientTick(gGUI_StoreClient)
    return 0
}

; Clean up resources on exit
_GUI_OnExit(reason, code) {
    ; Send any unsent stats to store before cleanup
    try Stats_SendToStore()

    ; Stop health check timer
    SetTimer(_GUI_StoreHealthCheck, 0)

    ; Clean up GDI+
    Gdip_Shutdown()

    return 0
}

; ========================= MAIN AUTO-INIT =========================

; Auto-init only if running standalone or if mode is "gui"
if (!IsSet(g_AltTabbyMode) || g_AltTabbyMode = "gui") {  ; lint-ignore: isset-with-default
    GUI_Main_Init()

    ; DPI change handler
    OnMessage(0x02E0, (wParam, lParam, msg, hwnd) => (gGdip_ResScale := 0.0, 0))

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
    OnMessage(0x0201, (wParam, lParam, msg, hwnd) => (hwnd = gGUI_OverlayH ? (GUI_OnClick(lParam & 0xFFFF, (lParam >> 16) & 0xFFFF), 0) : 0))
    OnMessage(0x020A, (wParam, lParam, msg, hwnd) => (hwnd = gGUI_OverlayH ? (GUI_OnWheel(wParam, lParam), 0) : 0))
    OnMessage(0x0200, (wParam, lParam, msg, hwnd) => (hwnd = gGUI_OverlayH ? GUI_OnMouseMove(wParam, lParam, msg, hwnd) : 0))
    OnMessage(0x02A3, (wParam, lParam, msg, hwnd) => (hwnd = gGUI_OverlayH ? GUI_OnMouseLeave() : 0))  ; WM_MOUSELEAVE

    ; Register exit handler for cleanup
    OnExit(_GUI_OnExit)

    Persistent()
}
