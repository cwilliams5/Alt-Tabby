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

; Use an inert mask key so Alt taps don't focus menus
A_MenuMaskKey := "vkE8"

; ========================= INCLUDES (SHARED UTILITIES) =========================
; Shared utilities first (use *i for unified exe compatibility)
#Include *i %A_ScriptDir%\..\shared\config_loader.ahk
#Include *i %A_ScriptDir%\..\shared\json.ahk
#Include *i %A_ScriptDir%\..\shared\ipc_pipe.ahk
#Include *i %A_ScriptDir%\..\shared\blacklist.ahk

; GUI utilities
#Include *i %A_ScriptDir%\gui_gdip.ahk
#Include *i %A_ScriptDir%\gui_win.ahk

; ========================= GLOBAL STATE =========================
; CRITICAL: These must be declared BEFORE sub-module includes
; Sub-modules reference these globals and need them to exist at parse time

global gGUI_Revealed := false
global gGUI_HoverRow := 0
global gGUI_HoverBtn := ""
global gGUI_FooterText := "All Windows"

; Workspace mode: "all" = show all workspaces, "current" = show current workspace only
global gGUI_WorkspaceMode := "all"
global gGUI_CurrentWSName := ""  ; Cached from store meta

; Footer arrow hit regions (physical coords, updated during paint)
global gGUI_LeftArrowRect := { x: 0, y: 0, w: 0, h: 0 }
global gGUI_RightArrowRect := { x: 0, y: 0, w: 0, h: 0 }

global gGUI_StoreClient := 0
global gGUI_StoreConnected := false
global gGUI_StoreRev := -1

global gGUI_OverlayVisible := false
global gGUI_Base := 0
global gGUI_Overlay := 0
global gGUI_BaseH := 0
global gGUI_OverlayH := 0
global gGUI_Items := []
global gGUI_Sel := 1
global gGUI_ScrollTop := 0
global gGUI_LastRowsDesired := -1

; State machine: IDLE -> ALT_PENDING -> ACTIVE
; IDLE: Normal state, receiving/applying deltas, cache fresh
; ALT_PENDING: Alt held, optional pre-warm, still receiving deltas
; ACTIVE: List FROZEN on first Tab, ignores all updates, Tab cycles selection
global gGUI_State := "IDLE"
global gGUI_AltDownTick := 0
global gGUI_FirstTabTick := 0
global gGUI_TabCount := 0
global gGUI_FrozenItems := []  ; Snapshot of items when locking in
global gGUI_AllItems := []     ; Unfiltered items - preserved for workspace toggle
global gGUI_AwaitingToggleProjection := false  ; Flag for UseCurrentWSProjection mode
global gGUI_LastLocalMRUTick := 0  ; Timestamp of last local MRU update (to skip stale prewarns)

; Store health check state
global gGUI_LastMsgTick := 0       ; Timestamp of last message from store
global gGUI_ReconnectAttempts := 0 ; Counter for failed reconnection attempts
global gGUI_StoreRestartAttempts := 0  ; Counter for store restart attempts

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
    global gGUI_StoreClient, cfg

    ; CRITICAL: Initialize config FIRST - sets all global defaults
    ConfigLoader_Init()

    ; Initialize blacklist for writing (needed for blacklist button in GUI)
    Blacklist_Init()

    ; Start debug event log (if enabled)
    _GUI_LogEventStartup()

    Win_InitDpiAwareness()
    Gdip_Startup()

    ; Initialize footer text based on workspace mode
    GUI_UpdateFooterText()

    ; Set up interceptor keyboard hooks (built-in, no IPC)
    INT_SetupHotkeys()

    ; Connect to WindowStore
    gGUI_StoreClient := IPC_PipeClient_Connect(cfg.StorePipeName, GUI_OnStoreMessage)
    if (gGUI_StoreClient.hPipe) {
        ; Request deltas so we stay up to date like the viewer
        hello := { type: IPC_MSG_HELLO, wants: { deltas: true }, projectionOpts: { sort: "MRU", columns: "items", includeCloaked: true } }
        IPC_PipeClient_Send(gGUI_StoreClient, JXON_Dump(hello))
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

    timeoutMs := cfg.ViewerHeartbeatTimeoutMs  ; Same timeout as viewer (default 12s)
    maxReconnectAttempts := 3  ; Try reconnecting 3 times before restarting store
    maxRestartAttempts := 2    ; Only try restarting store twice

    ; Case 1: Pipe handle is invalid (store disconnected or never connected)
    if (!IsObject(gGUI_StoreClient) || !gGUI_StoreClient.hPipe) {
        gGUI_StoreConnected := false
        gGUI_ReconnectAttempts++

        if (gGUI_ReconnectAttempts <= maxReconnectAttempts) {
            ; Try to reconnect
            ToolTip("Alt-Tabby: Reconnecting to store... (" gGUI_ReconnectAttempts "/" maxReconnectAttempts ")")
            SetTimer(() => ToolTip(), -2000)

            gGUI_StoreClient := IPC_PipeClient_Connect(cfg.StorePipeName, GUI_OnStoreMessage)
            if (gGUI_StoreClient.hPipe) {
                ; Reconnected successfully
                hello := { type: IPC_MSG_HELLO, wants: { deltas: true }, projectionOpts: { sort: "MRU", columns: "items", includeCloaked: true } }
                IPC_PipeClient_Send(gGUI_StoreClient, JXON_Dump(hello))
                gGUI_LastMsgTick := A_TickCount
                gGUI_ReconnectAttempts := 0
                gGUI_StoreConnected := true
                ToolTip("Alt-Tabby: Reconnected to store")
                SetTimer(() => ToolTip(), -2000)
            }
        } else if (gGUI_StoreRestartAttempts < maxRestartAttempts) {
            ; Reconnection failed repeatedly - try restarting store
            gGUI_StoreRestartAttempts++
            gGUI_ReconnectAttempts := 0  ; Reset for next cycle

            ToolTip("Alt-Tabby: Restarting store... (" gGUI_StoreRestartAttempts "/" maxRestartAttempts ")")
            SetTimer(() => ToolTip(), -3000)

            _GUI_StartStore()

            ; Wait a moment for store to start, then try connecting
            Sleep(1000)
            gGUI_StoreClient := IPC_PipeClient_Connect(cfg.StorePipeName, GUI_OnStoreMessage)
            if (gGUI_StoreClient.hPipe) {
                hello := { type: IPC_MSG_HELLO, wants: { deltas: true }, projectionOpts: { sort: "MRU", columns: "items", includeCloaked: true } }
                IPC_PipeClient_Send(gGUI_StoreClient, JXON_Dump(hello))
                gGUI_LastMsgTick := A_TickCount
                gGUI_StoreConnected := true
                ToolTip("Alt-Tabby: Store restarted and connected")
                SetTimer(() => ToolTip(), -2000)
            }
        }
        ; If all restart attempts exhausted, stop trying (avoid infinite loop)
        return
    }

    ; Case 2: Pipe handle valid but no messages received in timeout period
    if (gGUI_LastMsgTick && (A_TickCount - gGUI_LastMsgTick) > timeoutMs) {
        ; Connection may be stale - close and try reconnecting
        gGUI_StoreConnected := false
        IPC_PipeClient_Close(gGUI_StoreClient)
        gGUI_StoreClient := { hPipe: 0 }  ; Reset to trigger reconnect on next tick
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
        Run('"' A_ScriptFullPath '" --store', , "Hide")
    } else {
        ; Dev mode: run store_server.ahk directly
        storePath := A_ScriptDir "\..\store\store_server.ahk"
        runner := (cfg.HasOwnProp("AhkV2Path") && cfg.AhkV2Path != "" && FileExist(cfg.AhkV2Path))
            ? cfg.AhkV2Path : A_AhkPath
        Run('"' runner '" "' storePath '"', , "Hide")
    }
}

; Clean up resources on exit
_GUI_OnExit(reason, code) {
    ; Stop health check timer
    SetTimer(_GUI_StoreHealthCheck, 0)

    ; Clean up GDI+
    Gdip_Shutdown()

    return 0
}

; ========================= MAIN AUTO-INIT =========================

; Auto-init only if running standalone or if mode is "gui"
if (!IsSet(g_AltTabbyMode) || g_AltTabbyMode = "gui") {
    GUI_Main_Init()

    ; DPI change handler
    OnMessage(0x02E0, (wParam, lParam, msg, hwnd) => (gGdip_ResScale := 0.0, 0))

    ; Create windows
    GUI_CreateBase()
    gGUI_Sel := 1
    gGUI_ScrollTop := 0
    GUI_CreateOverlay()

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
