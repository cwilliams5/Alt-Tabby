#Requires AutoHotkey v2.0

; ============================================================
; Alt-Tabby Configuration
; ============================================================
; All timing values are in milliseconds unless noted.
; Settings are organized with most user-relevant at top.
; ============================================================

; ============================================================
; Alt-Tab Behavior (Most Likely to Edit)
; ============================================================
; These control the Alt-Tab overlay behavior - tweak these first!

; Grace period before showing GUI (ms). During this time,
; if Alt is released, we do a quick switch without showing GUI.
AltTabGraceMs := 150

; Maximum time for quick switch without showing GUI (ms)
; If Alt+Tab and release happen within this time, instant switch
AltTabQuickSwitchMs := 100

; Pre-warm snapshot on Alt down (true = request data before Tab pressed)
; Ensures fresh window data is available when Tab is pressed
AltTabPrewarmOnAlt := true

; Freeze window list on first Tab press (true = stable list, false = live updates)
; When true, the list is locked and won't change during Alt+Tab interaction
; When false, the list updates in real-time (may cause visual flicker)
FreezeWindowList := false

; Use server-side workspace projection filtering (true = request from store, false = filter client-side)
; When true, CTRL workspace toggle requests a new projection from the store
; When false, CTRL toggle filters the cached items locally (faster, but uses cached data)
UseCurrentWSProjection := true

; ============================================================
; GUI Appearance
; ============================================================
; Visual styling for the Alt-Tab overlay

; Background Window
GUI_AcrylicAlpha    := 0x33
GUI_AcrylicBaseRgb  := 0x330000
GUI_CornerRadiusPx  := 18
GUI_AlwaysOnTop     := true

; Selection scroll behavior
GUI_ScrollKeepHighlightOnTop := true

; Size config
GUI_ScreenWidthPct := 0.60
GUI_RowsVisibleMin := 1
GUI_RowsVisibleMax := 8

; Virtual list look
GUI_RowHeight   := 56
GUI_MarginX     := 18
GUI_MarginY     := 18
GUI_IconSize    := 36
GUI_IconLeftMargin := 8
GUI_RowRadius   := 12
GUI_SelARGB     := 0x662B5CAD

; Action keystrokes
GUI_AllowCloseKeystroke     := true
GUI_AllowKillKeystroke      := true
GUI_AllowBlacklistKeystroke := true

; Show row action buttons on hover
GUI_ShowCloseButton      := true
GUI_ShowKillButton       := true
GUI_ShowBlacklistButton  := true

; Action button geometry
GUI_ActionBtnSizePx   := 24
GUI_ActionBtnGapPx    := 6
GUI_ActionBtnRadiusPx := 6
GUI_ActionFontName    := "Segoe UI Symbol"
GUI_ActionFontSize    := 18
GUI_ActionFontWeight  := 700

; Close button styling
GUI_CloseButtonBorderPx      := 1
GUI_CloseButtonBorderARGB    := 0x88FFFFFF
GUI_CloseButtonBGARGB        := 0xFF000000
GUI_CloseButtonBGHoverARGB   := 0xFF888888
GUI_CloseButtonTextARGB      := 0xFFFFFFFF
GUI_CloseButtonTextHoverARGB := 0xFFFF0000
GUI_CloseButtonGlyph         := "X"

; Kill button styling
GUI_KillButtonBorderPx       := 1
GUI_KillButtonBorderARGB     := 0x88FFB4A5
GUI_KillButtonBGARGB         := 0xFF300000
GUI_KillButtonBGHoverARGB    := 0xFFD00000
GUI_KillButtonTextARGB       := 0xFFFFE8E8
GUI_KillButtonTextHoverARGB  := 0xFFFFFFFF
GUI_KillButtonGlyph          := "K"

; Blacklist button styling
GUI_BlacklistButtonBorderPx      := 1
GUI_BlacklistButtonBorderARGB    := 0x88999999
GUI_BlacklistButtonBGARGB        := 0xFF000000
GUI_BlacklistButtonBGHoverARGB   := 0xFF888888
GUI_BlacklistButtonTextARGB      := 0xFFFFFFFF
GUI_BlacklistButtonTextHoverARGB := 0xFFFF0000
GUI_BlacklistButtonGlyph         := "B"

; Extra columns (0 = hidden)
GUI_ColFixed2   := 70   ; HWND
GUI_ColFixed3   := 50   ; PID
GUI_ColFixed4   := 60   ; Workspace
GUI_ColFixed5   := 0
GUI_ColFixed6   := 0

GUI_ShowHeader := true
GUI_Col2Name := "HWND"
GUI_Col3Name := "PID"
GUI_Col4Name := "WS"
GUI_Col5Name := ""
GUI_Col6Name := ""

; Header font
GUI_HdrFontName   := "Segoe UI"
GUI_HdrFontSize   := 12
GUI_HdrFontWeight := 600
GUI_HdrARGB       := 0xFFD0D6DE

; Main Font (title row)
GUI_MainFontName := "Segoe UI"
GUI_MainFontSize := 20
GUI_MainFontWeight := 400
GUI_MainFontNameHi := "Segoe UI"
GUI_MainFontSizeHi := 20
GUI_MainFontWeightHi := 800
GUI_MainARGB := 0xFFF0F0F0
GUI_MainARGBHi := 0xFFF0F0F0

; Sub Font (subtitle row)
GUI_SubFontName := "Segoe UI"
GUI_SubFontSize := 12
GUI_SubFontWeight := 400
GUI_SubFontNameHi := "Segoe UI"
GUI_SubFontSizeHi := 12
GUI_SubFontWeightHi := 600
GUI_SubARGB     := 0xFFB5C0CE
GUI_SubARGBHi   := 0xFFB5C0CE

; Column Font
GUI_ColFontName := "Segoe UI"
GUI_ColFontSize := 12
GUI_ColFontWeight := 400
GUI_ColFontNameHi := "Segoe UI"
GUI_ColFontSizeHi := 12
GUI_ColFontWeightHi := 600
GUI_ColARGB := 0xFFF0F0F0
GUI_ColARGBHi := 0xFFF0F0F0

; Scrollbar
GUI_ScrollBarEnabled         := true
GUI_ScrollBarWidthPx         := 6
GUI_ScrollBarMarginRightPx   := 8
GUI_ScrollBarThumbARGB       := 0x88FFFFFF
GUI_ScrollBarGutterEnabled   := false
GUI_ScrollBarGutterARGB      := 0x30000000

GUI_EmptyListText := "No Windows"

; Footer
GUI_ShowFooter          := true
GUI_FooterTextAlign     := "center"
GUI_FooterBorderPx      := 0
GUI_FooterBorderARGB    := 0x33FFFFFF
GUI_FooterBGRadius      := 0
GUI_FooterBGARGB        := 0x00000000
GUI_FooterTextARGB      := 0xFFFFFFFF
GUI_FooterFontName      := "Segoe UI"
GUI_FooterFontSize      := 14
GUI_FooterFontWeight    := 600
GUI_FooterHeightPx      := 24
GUI_FooterGapTopPx      := 8
GUI_FooterPaddingX      := 12

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
; Debug options for troubleshooting. All disabled by default
; to minimize disk I/O and resource usage. Enable as needed.

; Log revision bump sources to %TEMP%\tabby_store_error.log
; Use when: Store rev is churning (incrementing rapidly when idle)
; Shows which code paths are bumping rev unnecessarily
DiagChurnLog := false

; Log komorebi subscription events to %TEMP%\tabby_ksub_diag.log
; Use when: Workspace tracking issues, windows not updating WS column,
; move/focus events not being processed correctly
DiagKomorebiLog := false

; Show tooltips for Alt-Tab state machine debugging
; Use when: Alt-Tab overlay behavior is incorrect (not showing,
; wrong state transitions, quick-switch not working)
DebugAltTabTooltips := false

; ============================================================
; Testing
; ============================================================
; Options for automated test suite

; Default duration for test_live.ahk
TestLiveDurationSec_Default := 30
