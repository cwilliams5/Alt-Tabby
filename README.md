# Alt-Tabby

<p align="center">
  <img src="resources/img/logo.png" alt="Alt-Tabby Logo" width="400">
</p>

A fast, customizable Alt-Tab replacement for Windows, built with AutoHotkey v2. Designed for power users who want responsive window switching with deep integration for tiling window managers like [Komorebi](https://github.com/LGUG2Z/komorebi).

## Features

<img src="resources/img/icon.png" alt="Alt-Tabby Icon" width="64" align="right">

- **Low Latency** - Keyboard hooks and window data live in the same process for sub-5ms Alt-Tab detection
- **MRU Ordering** - Windows sorted by most-recently-used, matching native Windows behavior
- **Komorebi Integration** - Workspace-aware filtering and cross-workspace window activation
- **Workspace Toggle** - Press Ctrl during Alt-Tab to filter by current workspace
- **Quick Switch** - Alt+Tab and release before the GUI shows for instant window switching
- **Configurable** - GUI-based configuration editor (WebView2 with native AHK fallback)
- **Fullscreen Bypass** - Automatically uses native Alt-Tab in fullscreen games
- **Window & Process Blacklist** - Filter out unwanted windows by title, class, or process name
- **Flight Recorder** - In-memory event ring buffer for diagnosing missed keystrokes (near-zero overhead)
- **Auto-Update** - Checks for new releases on startup with one-click update
- **Admin Mode** - Optional Task Scheduler integration for UAC-free elevated operation

## Architecture

Alt-Tabby uses a multi-process architecture optimized for latency:

```
+------------------+     +------------------+
|    Launcher      |---->|   MainProcess    |
|  (Tray + Spawn)  |     | (Window Data +   |
+------------------+     |  Producers +     |
                          |  Overlay + Hooks)|
                          +--------+---------+
                                   |
                            Named Pipe IPC
                                   |
                          +--------+---------+
                          | EnrichmentPump   |
                          | (Icon + Process  |
                          |  Resolution)     |
                          +------------------+
```

### Launcher

Manages the tray icon, spawns MainProcess and EnrichmentPump as subprocesses, and handles lifecycle events (restart, config/blacklist editor launch). Receives control signals via WM_COPYDATA.

### MainProcess

The core of Alt-Tabby. Window data, all producers, the overlay GUI, and keyboard hooks run in a single process to eliminate IPC latency on the critical path:

| Producer | Purpose |
|----------|---------|
| WinEventHook | Window create/destroy/focus events and MRU tracking (primary) |
| WinEnum | Full window enumeration (startup, snapshot, Z-order pump) |
| MRU_Lite | Focus tracking fallback (only if WinEventHook fails) |
| KomorebiSub | Workspace tracking via komorebi named pipe subscription |
| KomorebiLite | Workspace polling fallback (if subscription fails) |
| IconPump | Async icon resolution with retry/backoff |
| ProcPump | PID to process name resolution |

The overlay intercepts Alt+Tab before Windows sees it, pre-warms the window list on Alt press, and freezes the display on first Tab press.

### EnrichmentPump

A separate subprocess that handles blocking icon extraction (WM_GETICON, UWP logo parsing) and process name resolution. Communicates with MainProcess via named pipe IPC, keeping the main thread responsive.

### Debug Viewer

An in-process diagnostic window within MainProcess that reads the live window list directly. Features Z-order and MRU sorting, workspace filtering, and producer health monitoring. Toggled via tray menu.

## Installation

### Requirements

- Windows 10/11
- [AutoHotkey v2](https://www.autohotkey.com/) (for development)
- Optional: [Komorebi](https://github.com/LGUG2Z/komorebi) for workspace features

### From Release

1. Download `AltTabby.exe` from [Releases](https://github.com/cwilliams5/Alt-Tabby/releases)
2. Run `AltTabby.exe`
3. Right-click the tray icon for options

### From Source

```bash
git clone https://github.com/cwilliams5/Alt-Tabby.git
cd Alt-Tabby

# Run in development mode
AutoHotkey64.exe src/alt_tabby.ahk

# Or compile
compile.bat
```

## Configuration

Access the configuration editor via:
- Tray icon > Config
- Command line: `AltTabby.exe --config`

Key settings:

| Setting | Default | Description |
|---------|---------|-------------|
| GraceMs | 150 | Delay before showing GUI (quick-switch window) |
| BypassFullscreen | true | Use native Alt-Tab in fullscreen apps |
| BypassProcesses | "" | Comma-separated process names to bypass |

Configuration is stored in `config.ini` next to the executable.

## Usage

| Action | Keys |
|--------|------|
| Open Alt-Tab | Alt + Tab |
| Next window | Tab (while holding Alt) |
| Previous window | Shift + Tab |
| Toggle workspace filter | Ctrl (while Alt-Tab is open) |
| Cancel | Escape |
| Switch to selected | Release Alt |

## Documentation

- [Configuration Options](docs/options.md) - All config.ini settings with defaults and ranges

## Development

### Project Structure

```
src/
  alt_tabby.ahk         # Unified entry point (launcher + all modes)
  gui/                   # MainProcess (overlay + window data + producers)
    gui_main.ahk         # Init, producers, heartbeat, cleanup
    gui_interceptor.ahk  # Keyboard hooks (Alt/Tab/Ctrl/Escape)
    gui_state.ahk        # State machine (IDLE/ALT_PENDING/ACTIVE)
    gui_data.ahk         # Snapshot + pre-cache
    gui_paint.ahk        # GDI+ overlay rendering
    gui_flight_recorder.ahk # In-memory event ring buffer
  core/                  # Producer modules
    winevent_hook.ahk    # Window events + MRU tracking
    komorebi_sub.ahk     # Komorebi subscription integration
    icon_pump.ahk        # Async icon resolution
    proc_pump.ahk        # PID -> process name resolution
  pump/                  # EnrichmentPump subprocess
  editors/               # Config and blacklist editors
  shared/                # Window data, IPC, config, blacklist, stats, theme
tests/
  run_tests.ahk          # Test orchestrator
  gui_tests.ahk          # State machine tests
  static_analysis.ps1    # Pre-gate static analysis
```

### Running Tests

```powershell
# Full test suite (static analysis + unit + integration)
.\tests\test.ps1 --live
```

### Compiling

```bash
compile.bat
# Output: release/AltTabby.exe
```

## License

MIT

## Acknowledgments

- [AutoHotkey](https://www.autohotkey.com/) - Scripting language for Windows automation
- [Komorebi](https://github.com/LGUG2Z/komorebi) - Tiling window manager for Windows
- [WebView2.ahk](https://github.com/thqby/ahk2_lib) - WebView2 control wrapper for AHK v2
- [cJson.ahk](https://github.com/G33kDude/cJson.ahk) - High-performance JSON parser
- [ShinsOverlayClass](https://github.com/Spawnova/ShinsOverlayClass) - Direct2D overlay reference
