# Alt-Tabby Configuration Options

> **Auto-generated from `config_registry.ahk`** - Do not edit manually.
> Run `build-config-docs.ahk` to regenerate.

This document lists all configuration options available in `config.ini`.
Edit `config.ini` (next to AltTabby.exe) to customize behavior.

## Table of Contents

- [AltTab](#alttab)
- [Launcher](#launcher)
- [GUI](#gui)
- [IPC](#ipc)
- [Tools](#tools)
- [Producers](#producers)
- [Filtering](#filtering)
- [WinEventHook](#wineventhook)
- [ZPump](#zpump)
- [WinEnum](#winenum)
- [MruLite](#mrulite)
- [IconPump](#iconpump)
- [ProcPump](#procpump)
- [Cache](#cache)
- [KomorebiSub](#komorebisub)
- [Heartbeat](#heartbeat)
- [Viewer](#viewer)
- [Diagnostics](#diagnostics)
- [Testing](#testing)
- [Setup](#setup)

---

## AltTab

These control the Alt-Tab overlay behavior - tweak these first!

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `GraceMs` | int | `150` | Grace period before showing GUI (ms). During this time, if Alt is released, we do a quick switch without showing GUI. |
| `QuickSwitchMs` | int | `100` | Maximum time for quick switch without showing GUI (ms). If Alt+Tab and release happen within this time, instant switch. |
| `PrewarmOnAlt` | bool | `true` | Pre-warm snapshot on Alt down (true = request data before Tab pressed). Ensures fresh window data is available when Tab is pressed. |
| `FreezeWindowList` | bool | `false` | Freeze window list on first Tab press. When true, the list is locked and won't change during Alt+Tab interaction. When false, the list updates in real-time (may cause visual flicker). |
| `UseCurrentWSProjection` | bool | `true` | Use server-side workspace projection filtering. When true, CTRL workspace toggle requests a new projection from the store. When false, CTRL toggle filters the cached items locally (faster, but uses cached data). |
| `SwitchOnClick` | bool | `true` | Activate window immediately when clicking a row (like Windows native). When false, clicking selects the row and activation happens when Alt is released. |
| `AsyncActivationPollMs` | int | `15` | Polling interval (ms) when switching to a window on a different workspace. Lower = more responsive but higher CPU (spawns cmd.exe each poll). Default: 15. |

### Bypass

When to let native Windows Alt-Tab handle the switch instead of Alt-Tabby

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `BypassFullscreen` | bool | `true` | Bypass Alt-Tabby when the foreground window is fullscreen (covers ≥99% of screen). Useful for games that need native Alt-Tab behavior. |
| `BypassProcesses` | string | `(empty)` | Comma-separated list of process names to bypass (e.g., 'game.exe,vlc.exe'). When these processes are in the foreground, native Windows Alt-Tab is used instead. |

### Internal Timing

Internal timing parameters (usually no need to change)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `MRUFreshnessMs` | int | `300` | How long local MRU data is considered fresh after activation (ms). Prewarmed snapshots are skipped within this window to prevent stale data overwriting recent activations. |
| `WSPollTimeoutMs` | int | `200` | Timeout when polling for workspace switch completion (ms). Used during cross-workspace activation. |
| `PrewarmWaitMs` | int | `50` | Max time to wait for prewarm data on Tab (ms). If items are empty when Tab is pressed, wait up to this long for data to arrive. |
| `TabDecisionMs` | int | `24` | Tab decision window (ms). When Tab is pressed, we wait this long before committing to show the overlay. Allows detecting rapid Tab releases. Lower = more responsive but may cause accidental triggers. Range: 15-40. |
| `WorkspaceSwitchSettleMs` | int | `75` | Wait time after workspace switch (ms). When activating a window on a different komorebi workspace, we wait this long for the workspace to stabilize before activating the window. Increase if windows fail to activate on slow systems. |

## Launcher

Settings for the main Alt-Tabby launcher process (splash screen, startup behavior).

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `ShowSplash` | bool | `true` | Show splash screen on startup. Displays logo briefly while store and GUI processes start. |
| `SplashDurationMs` | int | `3000` | Splash screen display duration in milliseconds (includes fade time). Set to 0 for minimum. |
| `SplashFadeMs` | int | `500` | Splash screen fade in/out duration in milliseconds. |
| `SplashImagePath` | string | `img\logo.png` | Path to splash screen image (relative to Alt-Tabby directory, or absolute path). |

## GUI

Visual styling for the Alt-Tab overlay window.

### Background Window

Window background and frame styling

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `AcrylicAlpha` | int | `0x33` | Background transparency (0x00=transparent, 0xFF=opaque) |
| `AcrylicBaseRgb` | int | `0x330000` | Background tint color (hex RGB) |
| `CornerRadiusPx` | int | `18` | Window corner radius in pixels |

### Size Config

Window and row sizing

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `ScreenWidthPct` | float | `0.60` | GUI width as fraction of screen (0.0-1.0) |
| `RowsVisibleMin` | int | `1` | Minimum visible rows |
| `RowsVisibleMax` | int | `8` | Maximum visible rows |
| `RowHeight` | int | `56` | Height of each row in pixels |
| `MarginX` | int | `18` | Horizontal margin in pixels |
| `MarginY` | int | `18` | Vertical margin in pixels |

### Virtual List Look

Row and icon appearance

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `IconSize` | int | `36` | Icon size in pixels |
| `IconLeftMargin` | int | `8` | Left margin before icon in pixels |
| `RowRadius` | int | `12` | Row corner radius in pixels |
| `SelARGB` | int | `0x662B5CAD` | Selection highlight color (ARGB) |

### Selection & Scrolling

Selection and scroll behavior

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `ScrollKeepHighlightOnTop` | bool | `true` | Keep selection at top when scrolling |
| `EmptyListText` | string | `No Windows` | Text shown when no windows available |

### Action Buttons

Row action buttons shown on hover

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `ShowCloseButton` | bool | `true` | Show close button on hover |
| `ShowKillButton` | bool | `true` | Show kill button on hover |
| `ShowBlacklistButton` | bool | `true` | Show blacklist button on hover |
| `ActionBtnSizePx` | int | `24` | Action button size in pixels |
| `ActionBtnGapPx` | int | `6` | Gap between action buttons in pixels |
| `ActionBtnRadiusPx` | int | `6` | Action button corner radius |
| `ActionFontName` | string | `Segoe UI Symbol` | Action button font name |
| `ActionFontSize` | int | `18` | Action button font size |
| `ActionFontWeight` | int | `700` | Action button font weight |

### Close Button Styling

Close button appearance

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `CloseButtonBorderPx` | int | `1` | Close button border width |
| `CloseButtonBorderARGB` | int | `0x88FFFFFF` | Close button border color (ARGB) |
| `CloseButtonBGARGB` | int | `0xFF000000` | Close button background color (ARGB) |
| `CloseButtonBGHoverARGB` | int | `0xFF888888` | Close button background color on hover (ARGB) |
| `CloseButtonTextARGB` | int | `0xFFFFFFFF` | Close button text color (ARGB) |
| `CloseButtonTextHoverARGB` | int | `0xFFFF0000` | Close button text color on hover (ARGB) |
| `CloseButtonGlyph` | string | `X` | Close button glyph character |

### Kill Button Styling

Kill button appearance

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `KillButtonBorderPx` | int | `1` | Kill button border width |
| `KillButtonBorderARGB` | int | `0x88FFB4A5` | Kill button border color (ARGB) |
| `KillButtonBGARGB` | int | `0xFF300000` | Kill button background color (ARGB) |
| `KillButtonBGHoverARGB` | int | `0xFFD00000` | Kill button background color on hover (ARGB) |
| `KillButtonTextARGB` | int | `0xFFFFE8E8` | Kill button text color (ARGB) |
| `KillButtonTextHoverARGB` | int | `0xFFFFFFFF` | Kill button text color on hover (ARGB) |
| `KillButtonGlyph` | string | `K` | Kill button glyph character |

### Blacklist Button Styling

Blacklist button appearance

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `BlacklistButtonBorderPx` | int | `1` | Blacklist button border width |
| `BlacklistButtonBorderARGB` | int | `0x88999999` | Blacklist button border color (ARGB) |
| `BlacklistButtonBGARGB` | int | `0xFF000000` | Blacklist button background color (ARGB) |
| `BlacklistButtonBGHoverARGB` | int | `0xFF888888` | Blacklist button background color on hover (ARGB) |
| `BlacklistButtonTextARGB` | int | `0xFFFFFFFF` | Blacklist button text color (ARGB) |
| `BlacklistButtonTextHoverARGB` | int | `0xFFFF0000` | Blacklist button text color on hover (ARGB) |
| `BlacklistButtonGlyph` | string | `B` | Blacklist button glyph character |

### Columns

Extra data columns (0 = hidden)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `ShowHeader` | bool | `true` | Show column headers |
| `ColFixed2` | int | `70` | Column 2 width (HWND) |
| `ColFixed3` | int | `50` | Column 3 width (PID) |
| `ColFixed4` | int | `60` | Column 4 width (Workspace) |
| `ColFixed5` | int | `0` | Column 5 width (0=hidden) |
| `ColFixed6` | int | `0` | Column 6 width (0=hidden) |
| `Col2Name` | string | `HWND` | Column 2 header name |
| `Col3Name` | string | `PID` | Column 3 header name |
| `Col4Name` | string | `WS` | Column 4 header name |
| `Col5Name` | string | `(empty)` | Column 5 header name |
| `Col6Name` | string | `(empty)` | Column 6 header name |

### Header Font

Column header text styling

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `HdrFontName` | string | `Segoe UI` | Header font name |
| `HdrFontSize` | int | `12` | Header font size |
| `HdrFontWeight` | int | `600` | Header font weight |
| `HdrARGB` | int | `0xFFD0D6DE` | Header text color (ARGB) |

### Main Font

Window title text styling

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `MainFontName` | string | `Segoe UI` | Main font name |
| `MainFontSize` | int | `20` | Main font size |
| `MainFontWeight` | int | `400` | Main font weight |
| `MainFontNameHi` | string | `Segoe UI` | Main font name when highlighted |
| `MainFontSizeHi` | int | `20` | Main font size when highlighted |
| `MainFontWeightHi` | int | `800` | Main font weight when highlighted |
| `MainARGB` | int | `0xFFF0F0F0` | Main text color (ARGB) |
| `MainARGBHi` | int | `4293980400` | Main text color when highlighted (ARGB) |

### Sub Font

Subtitle row text styling

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `SubFontName` | string | `Segoe UI` | Sub font name |
| `SubFontSize` | int | `12` | Sub font size |
| `SubFontWeight` | int | `400` | Sub font weight |
| `SubFontNameHi` | string | `Segoe UI` | Sub font name when highlighted |
| `SubFontSizeHi` | int | `12` | Sub font size when highlighted |
| `SubFontWeightHi` | int | `600` | Sub font weight when highlighted |
| `SubARGB` | int | `0xFFB5C0CE` | Sub text color (ARGB) |
| `SubARGBHi` | int | `4290101454` | Sub text color when highlighted (ARGB) |

### Column Font

Column value text styling

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `ColFontName` | string | `Segoe UI` | Column font name |
| `ColFontSize` | int | `12` | Column font size |
| `ColFontWeight` | int | `400` | Column font weight |
| `ColFontNameHi` | string | `Segoe UI` | Column font name when highlighted |
| `ColFontSizeHi` | int | `12` | Column font size when highlighted |
| `ColFontWeightHi` | int | `600` | Column font weight when highlighted |
| `ColARGB` | int | `0xFFF0F0F0` | Column text color (ARGB) |
| `ColARGBHi` | int | `4293980400` | Column text color when highlighted (ARGB) |

### Scrollbar

Scrollbar appearance

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `ScrollBarEnabled` | bool | `true` | Show scrollbar when content overflows |
| `ScrollBarWidthPx` | int | `6` | Scrollbar width in pixels |
| `ScrollBarMarginRightPx` | int | `8` | Scrollbar right margin in pixels |
| `ScrollBarThumbARGB` | int | `0x88FFFFFF` | Scrollbar thumb color (ARGB) |
| `ScrollBarGutterEnabled` | bool | `false` | Show scrollbar gutter background |
| `ScrollBarGutterARGB` | int | `0x30000000` | Scrollbar gutter color (ARGB) |

### Footer

Footer bar appearance

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `ShowFooter` | bool | `true` | Show footer bar |
| `FooterBorderPx` | int | `0` | Footer border width in pixels |
| `FooterBorderARGB` | int | `0x33FFFFFF` | Footer border color (ARGB) |
| `FooterBGRadius` | int | `0` | Footer background corner radius |
| `FooterBGARGB` | int | `0` | Footer background color (ARGB) |
| `FooterTextARGB` | int | `0xFFFFFFFF` | Footer text color (ARGB) |
| `FooterFontName` | string | `Segoe UI` | Footer font name |
| `FooterFontSize` | int | `14` | Footer font size |
| `FooterFontWeight` | int | `600` | Footer font weight |
| `FooterHeightPx` | int | `24` | Footer height in pixels |
| `FooterGapTopPx` | int | `8` | Gap between content and footer in pixels |
| `FooterPaddingX` | int | `12` | Footer horizontal padding in pixels |

## IPC

Named pipe for store<->client communication.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `StorePipeName` | string | `tabby_store_v1` | Named pipe name for store communication |

## Tools

Paths to external executables used by Alt-Tabby.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `AhkV2Path` | string | `C:\Program Files\AutoHotkey\v2\AutoHo...` | Path to AHK v2 executable (for spawning subprocesses) |
| `KomorebicExe` | string | `C:\Program Files\komorebi\bin\komoreb...` | Path to komorebic.exe (komorebi CLI) |

## Producers

WinEventHook and MRU are always enabled (core functionality). These control optional producers.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `UseKomorebiSub` | bool | `true` | Komorebi subscription-based integration (preferred, event-driven) |
| `UseKomorebiLite` | bool | `false` | Komorebi polling-based fallback (use if subscription fails) |
| `UseIconPump` | bool | `true` | Resolve window icons in background |
| `UseProcPump` | bool | `true` | Resolve process names in background |

## Filtering

Filter windows like native Alt-Tab (skip tool windows, etc.) and apply blacklist.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `UseAltTabEligibility` | bool | `true` | Filter windows like native Alt-Tab (skip tool windows, etc.) |
| `UseBlacklist` | bool | `true` | Apply blacklist from shared/blacklist.txt |

## WinEventHook

Event-driven window change detection. Events are queued then processed in batches to keep the callback fast.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `DebounceMs` | int | `50` | Debounce rapid events (e.g., window moving fires many events) |
| `BatchMs` | int | `100` | Batch processing interval - how often queued events are processed |
| `IdleThreshold` | int | `10` | Empty batch ticks before pausing timer. Lower = faster idle detection, higher = more responsive to bursts. |

## ZPump

When WinEventHook adds a window, we don't know its Z-order. Z-pump triggers a full WinEnum scan to get accurate Z-order.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `IntervalMs` | int | `200` | How often to check if Z-queue has pending windows |

## WinEnum

WinEnum normally runs on-demand (startup, snapshot, Z-pump). Enable safety polling as a paranoid belt-and-suspenders.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `SafetyPollMs` | int | `0` | Safety polling interval (0=disabled, or 30000+ for safety net) |
| `ValidateExistenceMs` | int | `5000` | Lightweight zombie detection interval (ms). Checks existing store entries via IsWindow() to remove dead windows. Much faster than full EnumWindows scan. 0=disabled. |

## MruLite

MRU_Lite only runs if WinEventHook fails to start. It polls the foreground window to track focus changes.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `PollMs` | int | `250` | Polling interval for focus tracking fallback |

## IconPump

Resolves window icons asynchronously with retry/backoff.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `IntervalMs` | int | `80` | How often the pump processes its queue |
| `BatchSize` | int | `16` | Max icons to process per tick (prevents lag spikes) |
| `MaxAttempts` | int | `4` | Max attempts before giving up on a window's icon |
| `AttemptBackoffMs` | int | `300` | Base backoff after failed attempt (multiplied by attempt number) |
| `BackoffMultiplier` | float | `1.80` | Backoff multiplier for exponential backoff (1.0 = linear) |
| `RefreshThrottleMs` | int | `30000` | Minimum time between icon refresh checks for focused windows (ms). Windows can change icons (e.g., browser favicons), so we recheck WM_GETICON when focused after this delay. |
| `IdleThreshold` | int | `5` | Empty queue ticks before pausing timer. Lower = faster idle detection, higher = more responsive to bursts. |

## ProcPump

Resolves PID -> process name asynchronously.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `IntervalMs` | int | `100` | How often the pump processes its queue |
| `BatchSize` | int | `16` | Max PIDs to resolve per tick |
| `IdleThreshold` | int | `5` | Empty queue ticks before pausing timer. Lower = faster idle detection, higher = more responsive to bursts. |

## Cache

Size limits for internal caches to prevent unbounded memory growth.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `ExeIconMax` | int | `100` | Maximum number of cached exe icons. Older entries are evicted when limit is reached. |
| `ProcNameMax` | int | `200` | Maximum number of cached process names. Older entries are evicted when limit is reached. |

## KomorebiSub

Event-driven komorebi integration via named pipe.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `PollMs` | int | `50` | Pipe poll interval (checking for incoming data) |
| `IdleRecycleMs` | int | `120000` | Restart subscription if no events for this long (stale detection) |
| `FallbackPollMs` | int | `2000` | Fallback polling interval if subscription fails |

## Heartbeat

Store broadcasts heartbeat to clients for liveness detection.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `StoreIntervalMs` | int | `5000` | Store sends heartbeat every N ms |
| `ViewerTimeoutMs` | int | `12000` | Viewer considers connection dead after N ms without any message |

## Viewer

Debug viewer GUI options.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `DebugLog` | bool | `false` | Enable verbose logging to error log |
| `AutoStartStore` | bool | `false` | Auto-start store_server if not running when viewer connects |

## Diagnostics

Debug options for troubleshooting. All disabled by default to minimize disk I/O and resource usage.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `ChurnLog` | bool | `false` | Log revision bump sources to %TEMP%\\tabby_store_error.log. Use when store rev is churning rapidly when idle. |
| `KomorebiLog` | bool | `false` | Log komorebi subscription events to %TEMP%\\tabby_ksub_diag.log. Use when workspace tracking has issues. |
| `AltTabTooltips` | bool | `false` | Show tooltips for Alt-Tab state machine debugging. Use when overlay behavior is incorrect. |
| `EventLog` | bool | `false` | Log Alt-Tab events to %TEMP%\\tabby_events.log. Use when debugging rapid Alt-Tab or event timing issues. |
| `WinEventLog` | bool | `false` | Log WinEventHook focus events to %TEMP%\\tabby_weh_focus.log. Use when focus tracking issues occur. |
| `StoreLog` | bool | `false` | Log store startup and operational info to %TEMP%\\tabby_store_error.log. Use for general store debugging. |
| `IconPumpLog` | bool | `false` | Log icon pump operations to %TEMP%\\tabby_iconpump.log. Use when debugging icon resolution issues (cloaked windows, UWP apps). |
| `ProcPumpLog` | bool | `false` | Log process pump operations to %TEMP%\\tabby_procpump.log. Use when debugging process name resolution failures. |
| `LauncherLog` | bool | `false` | Log launcher startup to %TEMP%\\tabby_launcher.log. Use when debugging startup issues, subprocess launch, or mutex problems. |
| `IPCLog` | bool | `false` | Log IPC pipe operations to %TEMP%\\tabby_ipc.log. Use when debugging store-GUI communication issues. |
| `PaintTimingLog` | bool | `false` | Log GUI paint timing to %TEMP%\\tabby_paint_timing.log. Use when debugging slow overlay rendering after extended idle. |

## Testing

Options for automated test suite.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `LiveDurationSec` | int | `30` | Default duration for test_live.ahk |

## Setup

Installation paths and first-run settings. Managed automatically by the setup wizard.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `ExePath` | string | `(empty)` | Full path to AltTabby.exe after installation. Empty = use current location. |
| `RunAsAdmin` | bool | `false` | Run with administrator privileges via Task Scheduler (no UAC prompts after setup). |
| `AutoUpdateCheck` | bool | `true` | Automatically check for updates on startup. |
| `FirstRunCompleted` | bool | `false` | Set to true after first-run wizard completes. |
| `InstallationId` | string | `(empty)` | Unique installation ID (8-char hex). Generated on first run. Used for mutex naming and admin task identification. |

---

*Generated on 2026-01-28 with 172 total settings.*
