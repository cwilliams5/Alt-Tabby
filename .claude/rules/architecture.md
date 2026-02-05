# Alt-Tabby Architecture

## Multi-Process Model

Single `AltTabby.exe` serves as launcher and all process modes:

**User-facing modes:**
- `AltTabby.exe` - Launcher (spawns store + gui, manages tray)
- `--store` - WindowStore server only
- `--gui-only` - GUI only (requires store)
- `--viewer` - Debug viewer
- `--config` / `--blacklist` - Editor GUIs

**Internal modes:** `--wizard-continue`, `--enable-admin-task`, `--repair-admin-task`, `--apply-update`, `--update-installed`, `--skip-mismatch`

**Editor flags:** `--force-native` (with --config): skip WebView2 detection, use native AHK editor

## Process Roles

1. **Launcher**: Tray icon, subprocess PIDs, on-demand menu updates, lifecycle manager (WM_COPYDATA: store restart from GUI, full restart from config editor). Config/blacklist editors launched as subprocesses.
2. **WindowStore + Producers**: Named pipe server, window data, stats accumulation and persistence (`stats.ini`)
3. **AltLogic + GUI**: Overlay, MRU selection, window activation
4. **Debug Viewer**: Z/MRU-ordered window list display

## Key Files

- `VERSION` - Single source for version (e.g., `0.6.0`)
- `src/alt_tabby.ahk` - Unified entry point
- `src/lib/` - Third-party libraries (cjson, WebView2). NOT `src/shared/`.
- `src/store/windowstore.ahk` - Core store API
- `src/shared/ipc_pipe.ahk` - Multi-subscriber named pipe IPC
- `src/shared/config_registry.ahk` - All config definitions
- `src/shared/blacklist.ahk` - Window eligibility logic
- `src/gui/gui_main.ahk` - Alt-Tab GUI overlay
- `src/editors/config_editor.ahk` - Dispatcher: detects WebView2, falls back to native AHK
- `src/editors/config_editor_native.ahk` - Native AHK editor (sidebar + viewport scroll pattern)
- `src/editors/config_editor_webview.ahk` - WebView2 editor (HTML/JS UI)
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

States in projection meta: `"running"`, `"failed"`, `"disabled"`
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

1. **Lock-in on first Tab** - Projection frozen when Tab pressed (not Alt)
2. **Pre-warm on Alt** - Request snapshot early for fresh data
3. **GUI always running** - Show/hide, don't create/destroy
4. **Keyboard hooks in GUI process** - Zero IPC latency
5. **Grace period ~150ms** - Quick Alt+Tab = instant switch

## Config System

- All values in `global cfg := {}` object
- Single source: `gConfigRegistry` in `config_registry.ahk`
- Access via `cfg.PropertyName`
- **ConfigLoader_Init() must be called before using cfg**

## Stats IPC Messages

- `stats_update` - GUI → Store: delta counters (alt-tabs, quick switches, tab steps, cancellations, cross-workspace, workspace toggles)
- `stats_request` - Launcher → Store: on-demand query for dashboard/stats dialog
- `stats_response` - Store → Launcher: lifetime + session + derived stats

## Key Metrics

- Alt+Tab detection: <5ms
- GUI show after Tab: <50ms
- Quick switch: <25ms total
