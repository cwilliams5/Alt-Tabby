#Requires AutoHotkey v2.0

; IPC Message Type Constants
; Shared between production code and tests to avoid duplication.

; EnrichmentPump IPC message types
global IPC_MSG_ENRICH := "enrich"              ; Main → Pump: request icon/title/proc for hwnds
global IPC_MSG_ENRICHMENT := "enrichment"      ; Pump → Main: enrichment results
global IPC_MSG_PUMP_SHUTDOWN := "shutdown"      ; Main → Pump: clean exit

; IPC Timing Constants (milliseconds)
global IPC_TICK_ACTIVE := 8         ; Server/client tick when active (messages pending)
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

; Producer name constants - PRODUCER_ABBREVS is the single source of truth
global PRODUCER_ABBREVS := Map(
    "wineventHook", "WEH",
    "mruLite",      "MRU",
    "komorebiSub",  "KS",
    "komorebiLite", "KL",
    "iconPump",     "IP",
    "procPump",     "PP"
)
global PRODUCER_NAMES := []
for _name, _ in PRODUCER_ABBREVS
    PRODUCER_NAMES.Push(_name)

; Command-line argument constants
global ARG_LAUNCHER_HWND := "--launcher-hwnd="
global ARG_LAUNCHER_HWND_LEN := StrLen(ARG_LAUNCHER_HWND)
