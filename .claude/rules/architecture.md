# Alt-Tabby Architecture

## Process Model

Single `AltTabby.exe` serves as launcher and all process modes:

**User-facing modes:**
- `AltTabby.exe` - Launcher (spawns gui + pump, manages tray)
- `--gui-only` - MainProcess only (window data + overlay + producers)
- `--config` / `--blacklist` - Editor GUIs

**Internal modes:** `--wizard-continue`, `--enable-admin-task`, `--repair-admin-task`, `--apply-update`, `--update-installed`, `--skip-mismatch`

**Editor flags:** `--force-native` (with --config): skip WebView2 detection, use native AHK editor

## Process Roles

1. **Launcher**: Tray icon, subprocess PIDs, on-demand menu updates, lifecycle manager (WM_COPYDATA: full restart from config editor). Config/blacklist editors launched as subprocesses.
2. **MainProcess (gui_main.ahk)**: Window data (WindowList), all producers, overlay, MRU selection, window activation, stats accumulation and persistence (`stats.ini`)
3. **EnrichmentPump**: Subprocess for blocking icon/process name resolution via named pipe IPC
4. **Debug Viewer (in-process)**: In-process window within MainProcess, reads WL_GetDisplayList() directly. Toggled via tray menu (WM_COPYDATA from launcher).

## Key Files

- `VERSION` - Single source for version (e.g., `0.6.0`)
- `src/alt_tabby.ahk` - Unified entry point
- `src/lib/` - Third-party libraries (cjson, WebView2). NOT `src/shared/`.
- `src/shared/window_list.ahk` - Core window data API (store, display list, dirty tracking)
- `src/shared/ipc_pipe.ahk` - Named pipe IPC (used by EnrichmentPump)
- `src/shared/config_registry.ahk` - All config definitions
- `src/shared/blacklist.ahk` - Window eligibility logic
- `src/shared/stats.ahk` - Lifetime & session usage statistics
- `src/gui/gui_main.ahk` - MainProcess init, producers, heartbeat, cleanup
- `src/gui/gui_data.ahk` - Snapshot + pre-cache functions (replaces gui_store.ahk)
- `src/editors/config_editor.ahk` - Dispatcher: detects WebView2, falls back to native AHK
- `src/editors/config_editor_native.ahk` - Native AHK editor (sidebar + viewport scroll pattern)
- `src/editors/config_editor_webview.ahk` - WebView2 editor (HTML/JS UI)
- `src/core/` - Producer modules (WinEventHook, Komorebi, IconPump, ProcPump, etc.)
- `src/pump/` - EnrichmentPump subprocess
- `resources/img/` - Image assets (icon.ico, icon.png, logo.png)
- `resources/dll/` - Native DLLs (WebView2Loader.dll)
- `resources/html/` - HTML resources for WebView2 UI
- `stats.ini` - Lifetime usage statistics (next to config.ini, crash-safe with `.bak` sentinel)

## Producer Architecture

- **WinEventHook** (always enabled) - Primary for window changes AND MRU
- **MRU_Lite** - Fallback only if WinEventHook fails
- **Komorebi** - Optional, graceful handling if not running
- **WinEnum** - On-demand (startup, snapshot, Z-pump), not polling
- **Only winenum calls BeginScan/EndScan** - others use UpsertWindow/UpdateFields

## Producer Observability

States in display list meta: `"running"`, `"failed"`, `"disabled"`
- `meta.producers`: `{ wineventHook, mruLite, komorebiSub, komorebiLite, iconPump, procPump }`
- No automatic retry - if producer fails at startup, it stays failed

## Centralized Window Eligibility

**All eligibility logic in `Blacklist_IsWindowEligible()`** - combines Alt-Tab rules AND blacklist filtering. All producers MUST use this single function.

## Window Lifecycle Handling

### Focus Event Race Condition (CRITICAL)
When a new window opens and gets focus:
1. `EVENT_SYSTEM_FOREGROUND` fires BEFORE WinEnum discovers the window
2. WinEventHook's `WindowStore_UpdateFields()` returns `exists: false`
3. **FIX:** When focus event comes for unknown window, check eligibility and ADD it immediately with MRU data
4. Without this fix, new windows appear at BOTTOM of Alt+Tab list

### Ghost Window Detection (CRITICAL)
Some apps (Outlook, etc.) REUSE HWNDs for temporary windows:
1. Window is added when eligible
2. App "closes" window but HWND still exists (just hidden/cloaked)
3. `IsWindow()` returns true, so standard validation doesn't remove it
4. **FIX:** `WindowStore_ValidateExistence()` also checks `Blacklist_IsWindowEligible()`
5. Ghost windows are removed when they become ineligible

## State Machine

```
IDLE ──Alt down──> ALT_PENDING ──Tab──> ACTIVE ──Alt up──> IDLE
                        │                  │
                        │ Alt up (quick)   │ Escape
                        v                  v
                   (quick switch)       (cancel)
```

States: `IDLE`, `ALT_PENDING`, `ACTIVE`

## Critical Design Decisions

1. **Lock-in on first Tab** - Display list frozen when Tab pressed (not Alt)
2. **Pre-warm on Alt** - Refresh live items early for fresh data
3. **GUI always running** - Show/hide, don't create/destroy
4. **Single-process data** - Producers + window data + GUI all in MainProcess (no IPC latency for window list)
5. **Grace period ~150ms** - Quick Alt+Tab = instant switch
6. **PostMessage pipe wake** - After pipe writes, PostMessage(IPC_WM_PIPE_WAKE) wakes the receiver immediately instead of waiting for next timer tick. Timer polling is the fallback. wakeHwnd param on Send functions is optional (default 0 = no wake, graceful degradation).

## Config System

- All values in `global cfg := {}` object
- Single source: `gConfigRegistry` in `config_registry.ahk`
- Registry entry fields: `s` (section), `k` (key), `g` (group), `t` (type), `default`, `d` (description) + optional `min`, `max`, `fmt`
- `min/max` present on all numeric settings; `fmt: "hex"` on ARGB/RGB color values
- Validation is registry-driven (`_CL_ValidateSettings()` loops the registry, not hardcoded clamps)
- Access via `cfg.PropertyName`
- **ConfigLoader_Init() must be called before using cfg**

## Theme System

- `src/shared/theme.ahk` + `theme_msgbox.ahk` — centralized dark/light mode for all native AHK GUIs
- Main overlay is excluded (has its own ARGB colors); debug viewer uses the theme system
- `Theme_Init()` must be called **before any `Gui()` constructor** (sets SetPreferredAppMode)
- `Theme_ApplyToGui(gui)` after constructor, `Theme_ApplyToControl(ctrl, type)` after each control
- `ThemeMsgBox()` is a drop-in MsgBox replacement — use it for all new message boxes
- WebView2 editors: `Theme_GetWebViewJS()` generates CSS custom properties
- Reacts to system theme changes via WM_SETTINGCHANGE automatically

## Flight Recorder

In-memory ring buffer (`gui_flight_recorder.ahk`) in MainProcess. `FR_Record(ev, d1..d4)` is the hot path (~1μs, zero allocation — writes into pre-allocated array slots). F12 (configurable) dumps state snapshot + WindowList state + live items + event trace to `recorder/` folder. Events cover keyboard hooks, state machine, activation, focus tracking, workspace switches, scans, and producer init. See `USING_RECORDER.md` for analysis guide.

## Stats

Stats engine (`stats.ahk`) runs in-process within MainProcess. `Stats_Accumulate()` for GUI delta counters, `Stats_FlushToDisk()` on heartbeat timer, `Stats_GetSnapshot()` for dashboard queries. Crash-safe with `.bak` sentinel pattern.

## Key Metrics

- Alt+Tab detection: <5ms
- GUI show after Tab: <50ms
- Quick switch: <25ms total
