#Requires AutoHotkey v2.0

; ============================================================
; Alt-Tabby Configuration
; ============================================================
; All timing values are in milliseconds unless noted.
; Lower values = more responsive but higher CPU usage.
; ============================================================

; ============================================================
; IPC & Pipes
; ============================================================
; Named pipe for store<->client communication
StorePipeName := "tabby_store_v1"

; ============================================================
; External Tools
; ============================================================
; Path to AHK v2 executable (for spawning subprocesses)
AhkV2Path := "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"

; Path to komorebic.exe (komorebi CLI)
KomorebicExe := "C:\Program Files\komorebi\bin\komorebic.exe"

; ============================================================
; Producer Toggles
; ============================================================
; WinEventHook and MRU are always enabled (core functionality)
; These control optional producers:

; Komorebi integration - adds workspace names to windows
UseKomorebiSub := true          ; Subscription-based (preferred, event-driven)
UseKomorebiLite := false        ; Polling-based (fallback if sub fails)

; Enrichment pumps - add icons and process names asynchronously
UseIconPump := true             ; Resolve window icons in background
UseProcPump := true             ; Resolve process names in background

; ============================================================
; Window Filtering
; ============================================================
; Filter windows like native Alt-Tab (skip tool windows, etc.)
UseAltTabEligibility := true

; Apply blacklist from shared/blacklist.txt
UseBlacklist := true

; ============================================================
; WinEventHook Timing
; ============================================================
; Event-driven window change detection. Events are queued then
; processed in batches to keep the callback fast.

; Debounce rapid events (e.g., window moving fires many events)
WinEventHookDebounceMs := 50

; Batch processing interval - how often queued events are processed
WinEventHookBatchMs := 100

; ============================================================
; Z-Pump Timing
; ============================================================
; When WinEventHook adds a window, we don't know its Z-order.
; Z-pump triggers a full WinEnum scan to get accurate Z-order.

; How often to check if Z-queue has pending windows
ZPumpIntervalMs := 200

; ============================================================
; WinEnum (Full Scan) Safety Polling
; ============================================================
; WinEnum normally runs on-demand (startup, snapshot, Z-pump).
; Enable safety polling as a paranoid belt-and-suspenders.

; 0 = disabled (recommended), or 30000+ for safety net
WinEnumSafetyPollMs := 0

; ============================================================
; MRU Lite Timing (Fallback Only)
; ============================================================
; MRU_Lite only runs if WinEventHook fails to start.
; It polls the foreground window to track focus changes.

; Polling interval for focus tracking fallback
MruLitePollMs := 250

; ============================================================
; Icon Pump Timing
; ============================================================
; Resolves window icons asynchronously with retry/backoff.

; How often the pump processes its queue
IconPumpIntervalMs := 80

; Max icons to process per tick (prevents lag spikes)
IconPumpBatchSize := 16

; Max attempts before giving up on a window's icon
IconPumpMaxAttempts := 4

; Skip hidden windows (unlikely to yield icon anyway)
IconPumpSkipHidden := true

; Cooldown when skipping hidden windows
IconPumpIdleBackoffMs := 1500

; Base backoff after failed attempt (multiplied by attempt number)
IconPumpAttemptBackoffMs := 300

; Backoff multiplier for exponential backoff (1.0 = linear)
IconPumpBackoffMultiplier := 1.8

; ============================================================
; Process Pump Timing
; ============================================================
; Resolves PID -> process name asynchronously.

; How often the pump processes its queue
ProcPumpIntervalMs := 100

; Max PIDs to resolve per tick
ProcPumpBatchSize := 16

; ============================================================
; Komorebi Subscription Timing
; ============================================================
; Event-driven komorebi integration via named pipe.

; Pipe poll interval (checking for incoming data)
KomorebiSubPollMs := 50

; Restart subscription if no events for this long (stale detection)
KomorebiSubIdleRecycleMs := 120000

; Fallback polling interval if subscription fails
KomorebiSubFallbackPollMs := 2000

; ============================================================
; Heartbeat & Connection Health
; ============================================================
; Store broadcasts heartbeat to clients for liveness detection.

; Store sends heartbeat every N ms
StoreHeartbeatIntervalMs := 5000

; Viewer considers connection dead after N ms without any message
ViewerHeartbeatTimeoutMs := 12000

; ============================================================
; Viewer Settings
; ============================================================
; Debug viewer GUI options

; Enable verbose logging to error log
DebugViewerLog := false

; Auto-start store_server if not running when viewer connects
ViewerAutoStartStore := false

; ============================================================
; Diagnostics
; ============================================================
; Debug options for troubleshooting

; Log revision bump sources to error log (for debugging churn)
DiagChurnLog := false

; ============================================================
; Alt-Tab GUI Settings
; ============================================================
; Controls the Alt-Tab overlay behavior

; Grace period before showing GUI (ms). During this time,
; if Alt is released, we do a quick switch without showing GUI.
AltTabGraceMs := 150

; Pre-warm snapshot on Alt down (true = request data before Tab pressed)
; DISABLED FOR DEBUGGING - set to true once Alt+Tab logic is stable
AltTabPrewarmOnAlt := false

; Maximum time for quick switch without showing GUI (ms)
; If Alt+Tab and release happen within this time, instant switch
AltTabQuickSwitchMs := 100

; ============================================================
; Testing
; ============================================================
; Options for automated test suite

; Default duration for test_live.ahk
TestLiveDurationSec_Default := 30
