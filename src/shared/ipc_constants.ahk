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

; IPC Timing Constants (milliseconds)
global IPC_TICK_ACTIVE := 8         ; Server/client tick when active (messages pending)
global IPC_TICK_IDLE := 100         ; Client tick when no activity (overridable via cfg.IPCIdleTickMs)
global IPC_TICK_SERVER_IDLE := 250  ; Server tick when no clients connected
global IPC_WAIT_PIPE_TIMEOUT := 200 ; WaitNamedPipe timeout for client connect
global IPC_WAIT_SINGLE_OBJ := 1     ; WaitForSingleObject timeout (busy poll)

; Client cooldown thresholds (graduated idle back-off)
global IPC_COOLDOWN_PHASE1_TICKS := 10   ; Idle ticks before first step-up
global IPC_COOLDOWN_PHASE2_TICKS := 16   ; Idle ticks before second step-up
global IPC_COOLDOWN_PHASE3_TICKS := 20   ; Idle ticks before full idle
global IPC_COOLDOWN_PHASE1_MS := 30      ; First step-up interval
global IPC_COOLDOWN_PHASE2_MS := 50      ; Second step-up interval
