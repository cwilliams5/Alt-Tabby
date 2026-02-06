#Requires AutoHotkey v2.0

; IPC Message Type Constants
; Shared between production code and tests to avoid duplication.

global IPC_MSG_HELLO := "hello"
global IPC_MSG_HELLO_ACK := "hello_ack"
global IPC_MSG_SNAPSHOT_REQUEST := "snapshot_request"
global IPC_MSG_SNAPSHOT := "snapshot"
global IPC_MSG_DELTA := "delta"
global IPC_MSG_PROJECTION_REQUEST := "projection_request"
global IPC_MSG_PROJECTION := "projection"
global IPC_MSG_SET_PROJECTION_OPTS := "set_projection_opts"
global IPC_MSG_RELOAD_BLACKLIST := "reload_blacklist"
global IPC_MSG_HEARTBEAT := "heartbeat"
global IPC_MSG_PRODUCER_STATUS_REQUEST := "producer_status_request"
global IPC_MSG_PRODUCER_STATUS := "producer_status"
global IPC_MSG_STATS_UPDATE := "stats_update"
global IPC_MSG_STATS_REQUEST := "stats_request"
global IPC_MSG_STATS_RESPONSE := "stats_response"
global IPC_MSG_WORKSPACE_CHANGE := "workspace_change"

; IPC Timing Constants (milliseconds)
global IPC_TICK_ACTIVE := 8         ; Server/client tick when active (messages pending)
global IPC_TICK_IDLE := 100         ; Client tick when no activity (overridable via cfg.IPCIdleTickMs)
global IPC_TICK_SERVER_IDLE := 250  ; Server tick when no clients connected
global IPC_SERVER_IDLE_STREAK_THRESHOLD := 8  ; Ticks before server enters IDLE (at 100ms = 800ms inactivity)
global IPC_WAIT_PIPE_TIMEOUT := 200 ; WaitNamedPipe timeout for client connect
global IPC_WAIT_SINGLE_OBJ := 1     ; WaitForSingleObject timeout (busy poll)

; Client cooldown thresholds (graduated idle back-off)
global IPC_COOLDOWN_PHASE1_TICKS := 10   ; Idle ticks before first step-up
global IPC_COOLDOWN_PHASE2_TICKS := 16   ; Idle ticks before second step-up
global IPC_COOLDOWN_PHASE3_TICKS := 20   ; Idle ticks before full idle
global IPC_COOLDOWN_PHASE1_MS := 30      ; First step-up interval
global IPC_COOLDOWN_PHASE2_MS := 50      ; Second step-up interval

; Windows message constants
global WM_COPYDATA := 0x4A              ; Standard WM_COPYDATA message
global WM_TRAYICON := 0x404             ; Custom tray icon callback message
global IPC_WM_PIPE_WAKE := 0x8001       ; WM_APP+1: PostMessage signal to check pipe for data

; Command-line argument constants
global ARG_LAUNCHER_HWND := "--launcher-hwnd="
global ARG_LAUNCHER_HWND_LEN := 16      ; StrLen(ARG_LAUNCHER_HWND)
