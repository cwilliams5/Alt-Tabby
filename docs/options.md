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
- [Komorebi](#komorebi)
- [KomorebiSub](#komorebisub)
- [Heartbeat](#heartbeat)
- [Viewer](#viewer)
- [Diagnostics](#diagnostics)
- [Testing](#testing)
- [Setup](#setup)

---

## AltTab

These control the Alt-Tab overlay behavior - tweak these first!

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `GraceMs` | int | `150` | `0` - `2000` | Grace period before showing GUI (ms). During this time, if Alt is released, we do a quick switch without showing GUI. |
| `QuickSwitchMs` | int | `100` | `0` - `1000` | Maximum time for quick switch without showing GUI (ms). If Alt+Tab and release happen within this time, instant switch. |
| `PrewarmOnAlt` | bool | `true` | - | Pre-warm snapshot on Alt down (true = request data before Tab pressed). Ensures fresh window data is available when Tab is pressed. |
| `FreezeWindowList` | bool | `false` | - | Freeze window list on first Tab press. When true, the list is locked and won't change during Alt+Tab interaction. When false, the list updates in real-time (may cause visual flicker). |
| `ServerSideWorkspaceFilter` | bool | `false` | - | Use server-side workspace filtering. When true, CTRL workspace toggle requests a new projection from the store. When false, CTRL toggle filters the cached items locally (faster, but uses cached data). |
| `SwitchOnClick` | bool | `true` | - | Activate window immediately when clicking a row (like Windows native). When false, clicking selects the row and activation happens when Alt is released. |
| `AsyncActivationPollMs` | int | `15` | `10` - `100` | Polling interval (ms) when switching to a window on a different workspace. Lower = more responsive but higher CPU (spawns cmd.exe each poll). |

### Bypass

When to let native Windows Alt-Tab handle the switch instead of Alt-Tabby

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `BypassFullscreen` | bool | `true` | - | Bypass Alt-Tabby when the foreground window is fullscreen (covers >=99%% of screen). Useful for games that need native Alt-Tab behavior. |
| `BypassFullscreenThreshold` | float | `0.99` | `0.90` - `1.00` | Fraction of screen dimensions a window must cover to be considered fullscreen. Lower values catch borderless windowed games that don't quite fill the screen. |
| `BypassFullscreenTolerancePx` | int | `5` | `0` - `50` | Maximum pixels from screen edge for a window to still be considered fullscreen. Increase if borderless windows are offset by more than 5px. |
| `BypassProcesses` | string | `(empty)` | - | Comma-separated list of process names to bypass (e.g., 'game.exe,vlc.exe'). When these processes are in the foreground, native Windows Alt-Tab is used instead. |

### Internal Timing

Internal timing parameters (usually no need to change)

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `AltLeewayMs` | int | `60` | `20` - `200` | Alt key timing tolerance window (ms). After Alt is released, Tab presses within this window are still treated as Alt+Tab. Increase for slower typing speeds. |
| `MRUFreshnessMs` | int | `300` | `50` - `2000` | How long local MRU data is considered fresh after activation (ms). Prewarmed snapshots are skipped within this window to prevent stale data overwriting recent activations. |
| `WSPollTimeoutMs` | int | `200` | `50` - `2000` | Timeout when polling for workspace switch completion (ms). Used during cross-workspace activation. |
| `TabDecisionMs` | int | `24` | `15` - `40` | Tab decision window (ms). When Tab is pressed, we wait this long before committing to show the overlay. Allows detecting rapid Tab releases. Lower = more responsive but may cause accidental triggers. |
| `WorkspaceSwitchSettleMs` | int | `75` | `0` - `500` | Wait time after workspace switch (ms). When activating a window on a different komorebi workspace, we wait this long for the workspace to stabilize before activating the window. Increase if windows fail to activate on slow systems. |

## Launcher

Settings for the main Alt-Tabby launcher process (splash screen, startup behavior).

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `SplashScreen` | enum | `Image` | - | Splash screen mode. Image = static PNG logo with fade. Animation = animated WebP. None = disabled. |

### Image Splash

Settings for static image splash screen

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `SplashImageDurationMs` | int | `3000` | `0` - `10000` | Image splash screen display duration in milliseconds (includes fade time). Set to 0 for minimum. |
| `SplashImageFadeMs` | int | `500` | `0` - `2000` | Image splash screen fade in/out duration in milliseconds. |

### Animation Splash

Settings for animated WebP splash screen

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `SplashAnimFadeInFixedMs` | int | `0` | `0` - `5000` | Fade in duration while frozen on first frame (ms). 0 = skip fixed fade in. |
| `SplashAnimFadeInAnimMs` | int | `500` | `0` - `5000` | Fade in duration while animation plays (ms). 0 = skip animated fade in. |
| `SplashAnimFadeOutAnimMs` | int | `500` | `0` - `5000` | Fade out duration while animation plays (ms). 0 = skip animated fade out. |
| `SplashAnimFadeOutFixedMs` | int | `0` | `0` - `5000` | Fade out duration while frozen on last frame (ms). 0 = skip fixed fade out. |
| `SplashAnimLoops` | int | `1` | `0` - `100` | Number of animation loops before auto-closing. 0 = loop forever (requires manual dismiss). |
| `SplashAnimBufferFrames` | int | `24` | `0` - `500` | Streaming decode buffer size. 0 = load all frames upfront (~500MB). >0 = buffer N frames (~4MB per frame at 1280x720). Default 24 = ~88MB, 1 second buffer at 24fps. |

## GUI

Visual styling for the Alt-Tab overlay window.

### Background Window

Window background and frame styling

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `AcrylicAlpha` | int | `0x33` | `0x0` - `0xFF` | Background transparency (0x00=transparent, 0xFF=opaque) |
| `AcrylicBaseRgb` | int | `0x330000` | `0x0` - `0xFFFFFF` | Background tint color (hex RGB) |
| `CornerRadiusPx` | int | `18` | `0` - `100` | Window corner radius in pixels |

### Size Config

Window and row sizing

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `ScreenWidthPct` | float | `0.60` | `0.10` - `1.00` | GUI width as fraction of screen |
| `RowsVisibleMin` | int | `1` | `1` - `20` | Minimum visible rows |
| `RowsVisibleMax` | int | `8` | `1` - `50` | Maximum visible rows |
| `RowHeight` | int | `56` | `20` - `200` | Height of each row in pixels |
| `MarginX` | int | `18` | `0` - `200` | Horizontal margin in pixels |
| `MarginY` | int | `18` | `0` - `200` | Vertical margin in pixels |

### Virtual List Look

Row and icon appearance

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `IconSize` | int | `36` | `8` - `256` | Icon size in pixels |
| `IconLeftMargin` | int | `8` | `0` - `100` | Left margin before icon in pixels |
| `IconTextGapPx` | int | `12` | `0` - `50` | Gap between icon and title text in pixels |
| `ColumnGapPx` | int | `10` | `0` - `50` | Gap between right-side data columns in pixels |
| `HeaderHeightPx` | int | `28` | `16` - `60` | Header row height in pixels |
| `RowRadius` | int | `12` | `0` - `50` | Row corner radius in pixels |
| `SelARGB` | int | `0x662B5CAD` | `0x0` - `0xFFFFFFFF` | Selection highlight color (ARGB) |

### Selection & Scrolling

Selection and scroll behavior

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `ScrollKeepHighlightOnTop` | bool | `true` | - | Keep selection at top when scrolling |
| `EmptyListText` | string | `No Windows` | - | Text shown when no windows available |

### Tooltips

Feedback tooltip timing for accessibility

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `TooltipDurationMs` | int | `2000` | `500` - `10000` | Tooltip display duration in milliseconds. Increase for accessibility. |
| `HoverPollIntervalMs` | int | `100` | `50` - `500` | Hover state polling interval (ms). Lower = more responsive but higher CPU. |

### Action Buttons

Row action buttons shown on hover

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `ShowCloseButton` | bool | `true` | - | Show close button on hover |
| `ShowKillButton` | bool | `true` | - | Show kill button on hover |
| `ShowBlacklistButton` | bool | `true` | - | Show blacklist button on hover |
| `ActionBtnSizePx` | int | `24` | `12` - `64` | Action button size in pixels |
| `ActionBtnGapPx` | int | `6` | `0` - `50` | Gap between action buttons in pixels |
| `ActionBtnRadiusPx` | int | `6` | `0` - `32` | Action button corner radius |
| `ActionFontName` | string | `Segoe UI Symbol` | - | Action button font name |
| `ActionFontSize` | int | `18` | `8` - `48` | Action button font size |
| `ActionFontWeight` | int | `700` | `100` - `900` | Action button font weight |

### Close Button Styling

Close button appearance

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `CloseButtonBorderPx` | int | `1` | `0` - `10` | Close button border width |
| `CloseButtonBorderARGB` | int | `0x88FFFFFF` | `0x0` - `0xFFFFFFFF` | Close button border color (ARGB) |
| `CloseButtonBGARGB` | int | `0xFF000000` | `0x0` - `0xFFFFFFFF` | Close button background color (ARGB) |
| `CloseButtonBGHoverARGB` | int | `0xFF888888` | `0x0` - `0xFFFFFFFF` | Close button background color on hover (ARGB) |
| `CloseButtonTextARGB` | int | `0xFFFFFFFF` | `0x0` - `0xFFFFFFFF` | Close button text color (ARGB) |
| `CloseButtonTextHoverARGB` | int | `0xFFFF0000` | `0x0` - `0xFFFFFFFF` | Close button text color on hover (ARGB) |
| `CloseButtonGlyph` | string | `X` | - | Close button glyph character |

### Kill Button Styling

Kill button appearance

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `KillButtonBorderPx` | int | `1` | `0` - `10` | Kill button border width |
| `KillButtonBorderARGB` | int | `0x88FFB4A5` | `0x0` - `0xFFFFFFFF` | Kill button border color (ARGB) |
| `KillButtonBGARGB` | int | `0xFF300000` | `0x0` - `0xFFFFFFFF` | Kill button background color (ARGB) |
| `KillButtonBGHoverARGB` | int | `0xFFD00000` | `0x0` - `0xFFFFFFFF` | Kill button background color on hover (ARGB) |
| `KillButtonTextARGB` | int | `0xFFFFE8E8` | `0x0` - `0xFFFFFFFF` | Kill button text color (ARGB) |
| `KillButtonTextHoverARGB` | int | `0xFFFFFFFF` | `0x0` - `0xFFFFFFFF` | Kill button text color on hover (ARGB) |
| `KillButtonGlyph` | string | `K` | - | Kill button glyph character |

### Blacklist Button Styling

Blacklist button appearance

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `BlacklistButtonBorderPx` | int | `1` | `0` - `10` | Blacklist button border width |
| `BlacklistButtonBorderARGB` | int | `0x88999999` | `0x0` - `0xFFFFFFFF` | Blacklist button border color (ARGB) |
| `BlacklistButtonBGARGB` | int | `0xFF000000` | `0x0` - `0xFFFFFFFF` | Blacklist button background color (ARGB) |
| `BlacklistButtonBGHoverARGB` | int | `0xFF888888` | `0x0` - `0xFFFFFFFF` | Blacklist button background color on hover (ARGB) |
| `BlacklistButtonTextARGB` | int | `0xFFFFFFFF` | `0x0` - `0xFFFFFFFF` | Blacklist button text color (ARGB) |
| `BlacklistButtonTextHoverARGB` | int | `0xFFFF0000` | `0x0` - `0xFFFFFFFF` | Blacklist button text color on hover (ARGB) |
| `BlacklistButtonGlyph` | string | `B` | - | Blacklist button glyph character |

### Columns

Extra data columns (0 = hidden)

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `ShowHeader` | bool | `true` | - | Show column headers |
| `ColFixed2` | int | `70` | `0` - `500` | Column 2 width (HWND) |
| `ColFixed3` | int | `50` | `0` - `500` | Column 3 width (PID) |
| `ColFixed4` | int | `60` | `0` - `500` | Column 4 width (Workspace) |
| `ColFixed5` | int | `0` | `0` - `500` | Column 5 width (0=hidden) |
| `ColFixed6` | int | `0` | `0` - `500` | Column 6 width (0=hidden) |
| `Col2Name` | string | `HWND` | - | Column 2 header name |
| `Col3Name` | string | `PID` | - | Column 3 header name |
| `Col4Name` | string | `WS` | - | Column 4 header name |
| `Col5Name` | string | `(empty)` | - | Column 5 header name |
| `Col6Name` | string | `(empty)` | - | Column 6 header name |

### Header Font

Column header text styling

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `HdrFontName` | string | `Segoe UI` | - | Header font name |
| `HdrFontSize` | int | `12` | `6` - `48` | Header font size |
| `HdrFontWeight` | int | `600` | `100` - `900` | Header font weight |
| `HdrARGB` | int | `0xFFD0D6DE` | `0x0` - `0xFFFFFFFF` | Header text color (ARGB) |

### Main Font

Window title text styling

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `MainFontName` | string | `Segoe UI` | - | Main font name |
| `MainFontSize` | int | `20` | `8` - `72` | Main font size |
| `MainFontWeight` | int | `400` | `100` - `900` | Main font weight |
| `MainFontNameHi` | string | `Segoe UI` | - | Main font name when highlighted |
| `MainFontSizeHi` | int | `20` | `8` - `72` | Main font size when highlighted |
| `MainFontWeightHi` | int | `800` | `100` - `900` | Main font weight when highlighted |
| `MainARGB` | int | `0xFFF0F0F0` | `0x0` - `0xFFFFFFFF` | Main text color (ARGB) |
| `MainARGBHi` | int | `0xFFF0F0F0` | `0x0` - `0xFFFFFFFF` | Main text color when highlighted (ARGB) |

### Sub Font

Subtitle row text styling

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `SubFontName` | string | `Segoe UI` | - | Sub font name |
| `SubFontSize` | int | `12` | `6` - `48` | Sub font size |
| `SubFontWeight` | int | `400` | `100` - `900` | Sub font weight |
| `SubFontNameHi` | string | `Segoe UI` | - | Sub font name when highlighted |
| `SubFontSizeHi` | int | `12` | `6` - `48` | Sub font size when highlighted |
| `SubFontWeightHi` | int | `600` | `100` - `900` | Sub font weight when highlighted |
| `SubARGB` | int | `0xFFB5C0CE` | `0x0` - `0xFFFFFFFF` | Sub text color (ARGB) |
| `SubARGBHi` | int | `0xFFB5C0CE` | `0x0` - `0xFFFFFFFF` | Sub text color when highlighted (ARGB) |

### Column Font

Column value text styling

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `ColFontName` | string | `Segoe UI` | - | Column font name |
| `ColFontSize` | int | `12` | `6` - `48` | Column font size |
| `ColFontWeight` | int | `400` | `100` - `900` | Column font weight |
| `ColFontNameHi` | string | `Segoe UI` | - | Column font name when highlighted |
| `ColFontSizeHi` | int | `12` | `6` - `48` | Column font size when highlighted |
| `ColFontWeightHi` | int | `600` | `100` - `900` | Column font weight when highlighted |
| `ColARGB` | int | `0xFFF0F0F0` | `0x0` - `0xFFFFFFFF` | Column text color (ARGB) |
| `ColARGBHi` | int | `0xFFF0F0F0` | `0x0` - `0xFFFFFFFF` | Column text color when highlighted (ARGB) |

### Scrollbar

Scrollbar appearance

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `ScrollBarEnabled` | bool | `true` | - | Show scrollbar when content overflows |
| `ScrollBarWidthPx` | int | `6` | `2` - `30` | Scrollbar width in pixels |
| `ScrollBarMarginRightPx` | int | `8` | `0` - `50` | Scrollbar right margin in pixels |
| `ScrollBarThumbARGB` | int | `0x88FFFFFF` | `0x0` - `0xFFFFFFFF` | Scrollbar thumb color (ARGB) |
| `ScrollBarGutterEnabled` | bool | `false` | - | Show scrollbar gutter background |
| `ScrollBarGutterARGB` | int | `0x30000000` | `0x0` - `0xFFFFFFFF` | Scrollbar gutter color (ARGB) |

### Footer

Footer bar appearance

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `ShowFooter` | bool | `true` | - | Show footer bar |
| `FooterBorderPx` | int | `0` | `0` - `10` | Footer border width in pixels |
| `FooterBorderARGB` | int | `0x33FFFFFF` | `0x0` - `0xFFFFFFFF` | Footer border color (ARGB) |
| `FooterBGRadius` | int | `0` | `0` - `50` | Footer background corner radius |
| `FooterBGARGB` | int | `0x0` | `0x0` - `0xFFFFFFFF` | Footer background color (ARGB) |
| `FooterTextARGB` | int | `0xFFFFFFFF` | `0x0` - `0xFFFFFFFF` | Footer text color (ARGB) |
| `FooterFontName` | string | `Segoe UI` | - | Footer font name |
| `FooterFontSize` | int | `14` | `6` - `48` | Footer font size |
| `FooterFontWeight` | int | `600` | `100` - `900` | Footer font weight |
| `FooterHeightPx` | int | `24` | `0` - `100` | Footer height in pixels |
| `FooterGapTopPx` | int | `8` | `0` - `50` | Gap between content and footer in pixels |
| `FooterPaddingX` | int | `12` | `0` - `100` | Footer horizontal padding in pixels |

## IPC

Named pipe for store<->client communication.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `StorePipeName` | string | `tabby_store_v1` | - | Named pipe name for store communication |
| `IdleTickMs` | int | `100` | `15` - `500` | Client poll interval when idle (ms). Lower = more responsive but more CPU. Active tick is always 15ms. |
| `FullRowEvery` | int | `10` | `0` - `1000` | Per-row healing: 0=always full rows (legacy, no sparse deltas), N>0=every Nth push sends full rows instead of changed-fields-only. |
| `WorkspaceDeltaStyle` | string | `Always` | - | Workspace meta in deltas. 'Always'=every delta (redundant). 'OnChange'=only when workspace changes (lean). |
| `FullSyncEvery` | int | `60` | `0` - `600` | Full-state healing: every Nth heartbeat, send complete snapshot to all clients. Heals missing/ghost rows that per-row healing cannot fix. 0=disabled. |
| `UseDirtyTracking` | bool | `true` | - | Use dirty tracking for delta computation. Set false for debugging (full field comparison). |

### Reliability

Connection retry and recovery settings

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `MaxReconnectAttempts` | int | `3` | `1` - `10` | Maximum pipe reconnection attempts before triggering store restart. |
| `StoreStartWaitMs` | int | `1000` | `500` - `5000` | Time to wait for store to start on launch (ms). Increase on slow systems. |

## Tools

Paths to external executables used by Alt-Tabby.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `AhkV2Path` | string | `C:\Program Files\AutoHotkey\v2\AutoHo...` | - | Path to AHK v2 executable (for spawning subprocesses) |
| `KomorebicExe` | string | `C:\Program Files\komorebi\bin\komoreb...` | - | Path to komorebic.exe (komorebi CLI) |

## Producers

WinEventHook and MRU are always enabled (core functionality). These control optional producers.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `UseKomorebiSub` | bool | `true` | - | Komorebi subscription-based integration (preferred, event-driven) |
| `UseKomorebiLite` | bool | `false` | - | Komorebi polling-based fallback (use if subscription fails) |
| `UseIconPump` | bool | `true` | - | Resolve window icons in background |
| `UseProcPump` | bool | `true` | - | Resolve process names in background |

## Filtering

Filter windows like native Alt-Tab (skip tool windows, etc.) and apply blacklist.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `UseAltTabEligibility` | bool | `true` | - | Filter windows like native Alt-Tab (skip tool windows, etc.) |
| `UseBlacklist` | bool | `true` | - | Apply blacklist from shared/blacklist.txt |

## WinEventHook

Event-driven window change detection. Events are queued then processed in batches to keep the callback fast.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `DebounceMs` | int | `50` | `10` - `1000` | Debounce rapid events (e.g., window moving fires many events) |
| `BatchMs` | int | `100` | `10` - `2000` | Batch processing interval - how often queued events are processed |
| `IdleThreshold` | int | `10` | `1` - `100` | Empty batch ticks before pausing timer. Lower = faster idle detection, higher = more responsive to bursts. |
| `CosmeticBufferMs` | int | `1000` | `100` - `10000` | Min interval between proactive pushes for cosmetic-only changes (title updates). Structural changes (focus, create, destroy) always push immediately. |

## ZPump

When WinEventHook adds a window, we don't know its Z-order. Z-pump triggers a full WinEnum scan to get accurate Z-order.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `IntervalMs` | int | `200` | `50` - `5000` | How often to check if Z-queue has pending windows |

## WinEnum

WinEnum normally runs on-demand (startup, snapshot, Z-pump). Enable safety polling as a paranoid belt-and-suspenders.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `MissingWindowTTLMs` | int | `1200` | `100` - `10000` | Grace period before removing a missing window (ms). Shorter values remove ghost windows faster (Outlook/Teams). Longer values tolerate slow-starting apps. |
| `FallbackScanIntervalMs` | int | `2000` | `500` - `10000` | Polling interval when WinEventHook fails and fallback scanning is active (ms). Lower = more responsive but higher CPU. |
| `SafetyPollMs` | int | `0` | `0` - `300000` | Safety polling interval (0=disabled, or 30000+ for safety net) |
| `ValidateExistenceMs` | int | `5000` | `0` - `60000` | Lightweight zombie detection interval (ms). Checks existing store entries via IsWindow() to remove dead windows. Much faster than full EnumWindows scan. 0=disabled. |

## MruLite

MRU_Lite only runs if WinEventHook fails to start. It polls the foreground window to track focus changes.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `PollMs` | int | `250` | `50` - `5000` | Polling interval for focus tracking fallback |

## IconPump

Resolves window icons asynchronously with retry/backoff.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `IntervalMs` | int | `80` | `20` - `1000` | How often the pump processes its queue |
| `BatchSize` | int | `16` | `1` - `100` | Max icons to process per tick (prevents lag spikes) |
| `MaxAttempts` | int | `4` | `1` - `20` | Max attempts before giving up on a window's icon |
| `AttemptBackoffMs` | int | `300` | `50` - `5000` | Base backoff after failed attempt (multiplied by attempt number) |
| `BackoffMultiplier` | float | `1.80` | `1.00` - `5.00` | Backoff multiplier for exponential backoff (1.0 = linear) |
| `GiveUpBackoffMs` | int | `5000` | `1000` - `30000` | Long cooldown (ms) after max icon resolution attempts are exhausted. Lower values retry sooner for problematic apps. |
| `RefreshThrottleMs` | int | `30000` | `1000` - `300000` | Minimum time between icon refresh checks for focused windows (ms). Windows can change icons (e.g., browser favicons), so we recheck WM_GETICON when focused after this delay. |
| `IdleThreshold` | int | `5` | `1` - `100` | Empty queue ticks before pausing timer. Lower = faster idle detection, higher = more responsive to bursts. |
| `ResolveTimeoutMs` | int | `500` | `100` - `2000` | WM_GETICON timeout in milliseconds. Increase for slow or hung applications that need more time to respond. |

## ProcPump

Resolves PID -> process name asynchronously.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `IntervalMs` | int | `100` | `20` - `1000` | How often the pump processes its queue |
| `BatchSize` | int | `16` | `1` - `100` | Max PIDs to resolve per tick |
| `IdleThreshold` | int | `5` | `1` - `100` | Empty queue ticks before pausing timer. Lower = faster idle detection, higher = more responsive to bursts. |

## Cache

Size limits for internal caches to prevent unbounded memory growth.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `ExeIconMax` | int | `100` | `10` - `1000` | Maximum number of cached exe icons. Older entries are evicted when limit is reached. |
| `UwpLogoMax` | int | `50` | `5` - `500` | Maximum number of cached UWP logo paths. Prevents repeated manifest parsing for multi-window UWP apps. |
| `ProcNameMax` | int | `200` | `10` - `2000` | Maximum number of cached process names. Older entries are evicted when limit is reached. |

## Komorebi

Settings for komorebi tiling window manager integration.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `CrossWorkspaceMethod` | enum | `MimicNative` | - | How Alt-Tabby activates windows on other workspaces. MimicNative = directly uncloaks and activates via COM (like native Alt+Tab), letting komorebi reconcile. RevealMove = uncloaks window, focuses it, then commands komorebi to move it back to its workspace (switches with window already focused). SwitchActivate = commands komorebi to switch first, waits for confirmation, then activates (may flash previously focused window). MimicNative and RevealMove require COM and fall back to SwitchActivate if COM fails. |
| `MimicNativeSettleMs` | int | `0` | `0` - `1000` | Milliseconds to wait after SwitchTo before returning (0 = no delay). Increase if cross-workspace activation is unreliable on slower systems. |
| `UseSocket` | bool | `true` | - | Send commands directly to komorebi's named pipe instead of spawning komorebic.exe. Faster. Falls back to komorebic.exe if socket unavailable. |
| `WorkspaceConfirmationMethod` | enum | `PollCloak` | - | How Alt-Tabby verifies a workspace switch completed (only used when CrossWorkspaceMethod=SwitchActivate). PollKomorebic = polls komorebic CLI (spawns cmd.exe every 15ms), works on multi-monitor but highest CPU. PollCloak = checks DWM cloaked state (recommended, sub-microsecond DllCall). AwaitDelta = waits for store delta, lowest CPU but potentially higher latency. |

## KomorebiSub

Event-driven komorebi integration via named pipe.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `PollMs` | int | `50` | `10` - `1000` | Pipe poll interval (checking for incoming data) |
| `IdleRecycleMs` | int | `120000` | `10000` - `600000` | Restart subscription if no events for this long (stale detection) |
| `FallbackPollMs` | int | `2000` | `500` - `30000` | Fallback polling interval if subscription fails |
| `CacheMaxAgeMs` | int | `10000` | `1000` - `60000` | Maximum age (ms) for cached workspace assignments before they are considered stale. Lower values track rapid workspace switching more accurately. |
| `BatchCloakEventsMs` | int | `50` | `0` - `500` | Batch cloak/uncloak events during workspace switches (ms). 0 = disabled, push immediately. |

## Heartbeat

Store broadcasts heartbeat to clients for liveness detection.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `StoreIntervalMs` | int | `5000` | `1000` - `60000` | Store sends heartbeat every N ms |
| `ViewerTimeoutMs` | int | `12000` | `2000` - `120000` | Viewer considers connection dead after N ms without any message |

## Viewer

Debug viewer GUI options.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `DebugLog` | bool | `false` | - | Enable verbose logging to error log |
| `AutoStartStore` | bool | `false` | - | Auto-start store_server if not running when viewer connects |

## Diagnostics

Debug options for troubleshooting. All disabled by default to minimize disk I/O and resource usage.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `ChurnLog` | bool | `false` | - | Log revision bump sources to %TEMP%\\tabby_store_error.log. Use when store rev is churning rapidly when idle. |
| `KomorebiLog` | bool | `false` | - | Log komorebi subscription events to %TEMP%\\tabby_ksub_diag.log. Use when workspace tracking has issues. |
| `AltTabTooltips` | bool | `false` | - | Show tooltips for Alt-Tab state machine debugging. Use when overlay behavior is incorrect. |
| `EventLog` | bool | `false` | - | Log Alt-Tab events to %TEMP%\\tabby_events.log. Use when debugging rapid Alt-Tab or event timing issues. |
| `WinEventLog` | bool | `false` | - | Log WinEventHook focus events to %TEMP%\\tabby_weh_focus.log. Use when focus tracking issues occur. |
| `StoreLog` | bool | `false` | - | Log store startup and operational info to %TEMP%\\tabby_store_error.log. Use for general store debugging. |
| `IconPumpLog` | bool | `false` | - | Log icon pump operations to %TEMP%\\tabby_iconpump.log. Use when debugging icon resolution issues (cloaked windows, UWP apps). |
| `ProcPumpLog` | bool | `false` | - | Log process pump operations to %TEMP%\\tabby_procpump.log. Use when debugging process name resolution failures. |
| `LauncherLog` | bool | `false` | - | Log launcher startup to %TEMP%\\tabby_launcher.log. Use when debugging startup issues, subprocess launch, or mutex problems. |
| `IPCLog` | bool | `false` | - | Log IPC pipe operations to %TEMP%\\tabby_ipc.log. Use when debugging store-GUI communication issues. |
| `PaintTimingLog` | bool | `false` | - | Log GUI paint timing to %TEMP%\\tabby_paint_timing.log. Use when debugging slow overlay rendering after extended idle. |
| `StatsTracking` | bool | `true` | - | Track usage statistics (Alt-Tabs, quick switches, etc.) and persist to stats.ini. Shown in the dashboard. |

### Log Size Limits

Control diagnostic log file sizes

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `LogMaxKB` | int | `100` | `50` - `1000` | Maximum diagnostic log file size in KB before trimming. |
| `LogKeepKB` | int | `50` | `25` - `500` | Size to keep after log trim in KB. Must be less than LogMaxKB. |

## Testing

Options for automated test suite.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `LiveDurationSec` | int | `30` | `5` - `300` | Default duration for test_live.ahk |

## Setup

Installation paths and first-run settings. Managed automatically by the setup wizard.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `ExePath` | string | `(empty)` | - | Full path to AltTabby.exe after installation. Empty = use current location. |
| `RunAsAdmin` | bool | `false` | - | Run with administrator privileges via Task Scheduler (no UAC prompts after setup). |
| `AutoUpdateCheck` | bool | `true` | - | Automatically check for updates on startup. |
| `FirstRunCompleted` | bool | `false` | - | Set to true after first-run wizard completes. |
| `InstallationId` | string | `(empty)` | - | Unique installation ID (8-char hex). Generated on first run. Used for mutex naming and admin task identification. |
| `SuppressAdminRepairPrompt` | bool | `false` | - | Don't prompt to repair stale admin task. Set automatically when user clicks 'Don't ask again'. |

---

*Generated on 2026-02-05 with 207 total settings.*
