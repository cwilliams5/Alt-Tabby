# Alt-Tabby Assistant Context

## Project Summary
- AHK v2 Alt-Tab replacement focused on responsiveness and low latency.
- Komorebi aware; uses workspace state to filter and label windows.
- Keyboard hooks built into GUI process for minimal latency (no IPC delay).

## Architecture (Unified Launcher + Multi-Process)

### Compiled Distribution
Single executable `AltTabby.exe` serves as both launcher and all process modes:
- `AltTabby.exe` - Launcher (spawns store + gui, manages tray menu)
- `AltTabby.exe --store` - WindowStore server only
- `AltTabby.exe --gui-only` - GUI only (requires store running)
- `AltTabby.exe --viewer` - Debug viewer

### Process Roles
1. **Launcher**: Stays alive, single tray icon, tracks subprocess PIDs, on-demand menu updates
2. **WindowStore + Producers**: Store, winenum, MRU, komorebi producers. Named pipe server.
3. **AltLogic + GUI**: Consumer process with overlay, MRU selection, window activation.
4. **Debug Viewer**: Diagnostic tool showing Z/MRU-ordered window list from store.

### Development Mode
When running from `/src`, modules can run standalone:
- `store_server.ahk` - Store process
- `gui_main.ahk` - GUI process
- `viewer.ahk` - Viewer process

## Current Directory Structure
```
src/
  shared/         - IPC, JSON, config utilities
    config.ahk    - Global settings (pipe names, intervals, feature flags)
    ipc_pipe.ahk  - Named pipe server/client with adaptive polling
    json.ahk      - JSON encoder/decoder (Map and Object aware)
  store/          - WindowStore process
    store_server.ahk    - Main store process with pipe server
    windowstore.ahk     - Core store API (scans, projections, upserts)
    winenum_lite.ahk    - Basic window enumeration producer
    mru_lite.ahk        - Focus tracking producer
    komorebi_lite.ahk   - Komorebi polling producer
  gui/            - Alt-Tab GUI overlay (modular)
    gui_main.ahk        - Entry point, includes, globals, init
    gui_interceptor.ahk - Keyboard hooks, Tab decision logic
    gui_state.ahk       - State machine, event handlers, activation
    gui_store.ahk       - Store IPC, deltas, snapshots
    gui_workspace.ahk   - Workspace mode toggle/filter
    gui_paint.ahk       - Rendering code
    gui_input.ahk       - Mouse, selection, hover, actions
    gui_overlay.ahk     - Window creation, sizing, show/hide
    gui_config.ahk      - GUI configuration constants
    gui_gdip.ahk        - GDI+ graphics helpers
    gui_win.ahk         - Window/DPI utilities
  viewer/         - Debug viewer
    viewer.ahk    - GUI with Z/MRU toggle, workspace filter
tests/
  run_tests.ahk   - Automated test suite (unit + live)
  gui_tests.ahk   - GUI state machine tests
  test.ps1        - PowerShell test runner
legacy/
  components_legacy/  - Original ChatGPT work (reference only)
```

## Key Files
- `src/alt_tabby.ahk`: Unified entry point (launcher + mode router)
- `src/store/store_server.ahk`: WindowStore main entry point
- `src/store/windowstore.ahk`: Core store with GetProjection, UpsertWindow, scan APIs
- `src/shared/ipc_pipe.ahk`: Multi-subscriber named pipe IPC
- `src/viewer/viewer.ahk`: Debug viewer GUI
- `src/gui/gui_main.ahk`: Alt-Tab GUI overlay
- `tests/run_tests.ahk`: Automated tests
- `compile.bat`: Compiles to `release/AltTabby.exe`

## Legacy Components (in legacy/components_legacy/)
These are from the original ChatGPT work. Some are battle-tested:
- `interceptor.ahk`: Solid Alt+Tab hook with grace period - **PORTED to gui_interceptor.ahk**
- `winenum.ahk`: Full-featured enumeration with DWM cloaking - **port features**
- `komorebi_sub.ahk`: Subscription-based updates - **use instead of polling**
- `New GUI Working POC.ahk`: Rich GUI with icons, DWM effects - **port this**
- `mru.ahk`, `icon_pump.ahk`, `proc_pump.ahk`: Mature enrichers

## Guiding Constraints
- **AHK v2 only**: No v1 patterns. Use direct function refs, not `Func("Name")`.
- **Low CPU**: Event-driven, not busy loops. Adaptive polling when needed.
- **Named pipes for IPC**: Multi-subscriber support, no WM_COPYDATA.
- **Testing**: Run `tests/run_tests.ahk --live` to validate changes.

## Recent Lessons Learned

### AHK v2 Syntax
- `_WS_GetOpt()` helper handles both Map and plain Object options
- String sort comparisons must use `StrCompare()` not `<`/`>` operators
- AHK v2 `#Include` is compile-time, cannot be conditional at runtime
- Store expects Map records from producers; use `rec["key"]` not `rec.key`

### Global Variable Scoping (CRITICAL)
- **Global constants defined at file scope (like `IPC_MSG_SNAPSHOT := "snapshot"`) are NOT automatically accessible inside functions**
- You MUST declare them with `global` inside each function that uses them:
  ```ahk
  MyFunc() {
      global IPC_MSG_SNAPSHOT, IPC_MSG_PROJECTION  ; Required!
      if (type = IPC_MSG_SNAPSHOT) { ... }
  }
  ```
- With `#Warn VarUnset, Off`, missing globals silently become empty strings - comparisons fail without errors
- This is a common source of "code runs but doesn't work" bugs
- **Functions are different from variables** - don't add `global FunctionName` for functions defined in other files
- Functions are automatically global in AHK v2
- If you get warnings about undefined functions from included files, add `#Warn VarUnset, Off` to the calling file

### Compiled vs Development Path Handling (CRITICAL)
- **`A_ScriptDir` changes based on compiled status**:
  - Compiled: directory containing the exe (e.g., `release/`)
  - Development: directory containing the .ahk file (e.g., `src/store/`)
- **Use `A_IsCompiled` to handle path differences**:
  ```ahk
  if (A_IsCompiled) {
      configPath := A_ScriptDir "\config.ini"  ; Next to exe
  } else {
      configPath := A_ScriptDir "\..\config.ini"  ; Relative path
  }
  ```
- **Don't hardcode relative paths** that only work in development mode
- Functions like `ConfigLoader_Init()` should have built-in logic for both modes
- When creating default files, ensure the target directory exists first

### Git Bash Path Expansion (CRITICAL)
- **Git Bash converts any `/param` to `C:/Program Files/Git/param`** - this breaks all forward-slash parameters
- Affects: AutoHotkey (`/ErrorStdOut`), Ahk2Exe (`/in`, `/out`, `/base`), and any other Windows CLI tools
- **Solution: Use double slashes `//param` to prevent path expansion**
- Examples:
  ```bash
  # WRONG - Git Bash expands /ErrorStdOut to a path
  AutoHotkey64.exe /ErrorStdOut script.ahk

  # CORRECT - double slash prevents expansion
  AutoHotkey64.exe //ErrorStdOut script.ahk

  # WRONG - Ahk2Exe params get expanded
  Ahk2Exe.exe /in script.ahk /out script.exe /base AutoHotkey64.exe

  # CORRECT - all params need double slashes
  Ahk2Exe.exe //in script.ahk //out script.exe //base AutoHotkey64.exe
  ```
- Note: Windows batch files (`.bat`) run in cmd.exe, not Git Bash, so they use single slashes normally

### #SingleInstance in Multi-File Compiled Projects
- **When multiple .ahk files are compiled into one exe, all `#SingleInstance` directives are merged**
- If included files have `#SingleInstance Force`, they will kill other instances of the same exe
- **For multi-process architectures** (store + gui from same exe with different args):
  - Entry point (alt_tabby.ahk) should have `#SingleInstance Off`
  - Module files (store_server.ahk, gui_main.ahk) should NOT have `#SingleInstance`
  - This allows multiple instances of the same exe to run with different modes
- The first `#SingleInstance` directive encountered is supposed to win, but behavior can be unpredictable with includes

### Compilation
- **Use `compile.bat`** for standard compilation (runs in cmd.exe, single slashes OK)
- **From Git Bash**, use double slashes: `Ahk2Exe.exe //in ... //out ... //base ...`
- Ahk2Exe requires `/base` to specify v2 runtime: `"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"`
- Output: `release/AltTabby.exe` with `config.ini` and `blacklist.txt` alongside
- Use `@Ahk2Exe-Base` directive in script as fallback (but command-line `/base` is more reliable)

### Unified Launcher Tray Menu
- **On-demand menu updates** - no polling timer, rebuild menu on right-click
- Use `OnMessage(0x404, TrayIconClick)` to intercept WM_TRAYICON
- Check for `lParam = 0x205` (WM_RBUTTONUP) then call `UpdateTrayMenu()` and `A_TrayMenu.Show()`
- Must return 1 to prevent default handling after showing menu manually
- Track subprocess PIDs with `Run(cmd, , , &PID)` - 4th param is output variable
- Check process alive with `ProcessExist(PID)`, kill with `ProcessClose(PID)`
- Subprocesses hide tray icon: `A_IconHidden := true`

### ListView Updates
- ListView rows stay in insertion order; sorting the data array doesn't reorder displayed rows
- To re-sort a ListView: delete all rows and re-add in sorted order, OR use ListView's native Sort
- Incremental updates (modifying existing rows) preserve original row order

### Viewer Delta Handling
- Viewer processes all deltas (upserts AND removes) locally without network requests
- `_Viewer_RebuildFromCache()` re-sorts cached data without requesting new projection
- Only request projection when: toggle sort/filter, heartbeat timeout, or manual refresh
- This eliminates "poll count increasing alongside delta count" issue

### Komorebi Integration Testing
- Always verify komorebi is actually running: `komorebic state`
- Test workspace data flows end-to-end: komorebi → producer → store → viewer
- Don't assume empty columns mean "no data" - verify the data source
- Tests should START the store, not assume it's already running

### cmd.exe Quoting for Paths with Spaces
- When using `cmd.exe /c` with paths containing spaces, use double-quote escaping:
  ```ahk
  ; WRONG - fails with paths like "C:\Program Files\..."
  cmd := 'cmd.exe /c "' path '" args > "' outfile '"'

  ; CORRECT - double-quote escaping for cmd.exe
  cmd := 'cmd.exe /c ""' path '" args > "' outfile '""'
  ```
- The extra quotes at start (`""`) and end (`""`) are required for cmd.exe to parse correctly

### Subscription vs Polling for Komorebi
- Subscription mode (`komorebic subscribe-pipe`) only receives events when things change
- Need an initial poll on startup to populate existing windows with workspace data
- The subscription includes BOTH event AND full state in each notification
- Reference: `legacy/components_legacy/komorebi_poc - WORKING.ahk`

### Komorebi Notification State Consistency (CRITICAL)
- **Notification state is inconsistent** - it's a snapshot taken mid-operation
- For workspace focus events (FocusMonitorWorkspaceNumber, etc.):
  - Trust the EVENT's content for the new workspace name/index
  - DON'T trust the state's `ring.focused` - it may be stale
  - Always pass `skipWorkspaceUpdate=true` to ProcessFullState from notifications
- For move events (MoveContainerToWorkspaceNumber, etc.):
  - The moved WINDOW is already on the TARGET workspace in the state data
  - But focus INDICES on the source workspace still point to OTHER windows
  - DON'T try to find "the moved window" by looking at focused container on source workspace
  - Let ProcessFullState handle window updates - it correctly finds windows by scanning ALL workspaces
- **Push AFTER ProcessFullState** - updates to windows won't reach clients otherwise:
  ```ahk
  _KSub_ProcessFullState(stateObj, true)
  try Store_PushToClients()  ; Critical! Send window updates to clients
  ```
- The pattern: trust EVENT for workspace change, trust STATE for window positions

### Komorebi Event Content Extraction
- Event content varies by type - use robust extraction:
  - Array: `"content": [1, 2]`
  - String: `"content": "WorkspaceName"`
  - Integer: `"content": 1`
  - Object: `"content": {"EventType": 1}` (for SocketMessage types)
- The `_KSub_ExtractContentRaw()` function tries all formats in order
- For SocketMessage events, the workspace index may be nested in an object

## Testing
Run automated tests before committing:
```powershell
.\tests\test.ps1 --live
```
Or directly (note double-slash for Git Bash):
```
AutoHotkey64.exe //ErrorStdOut tests\run_tests.ahk --live
```
Check `%TEMP%\alt_tabby_tests.log` for results.

### Test Coverage Requirements
- Unit tests for core functions
- IPC integration tests (server ↔ client)
- Real store integration (spawn actual store_server)
- Headless viewer simulation (validates display fields)
- Komorebi integration (verify workspace data flows)
- Heartbeat test (verify store→client heartbeat with rev)
- Blacklist E2E test (IPC reload, purge, file operations)
- GUI state machine tests (tests/gui_tests.ahk)

### GUI Tests (`tests/gui_tests.ahk`)
Tests the Alt-Tab GUI state machine without actual keyboard or rendering:
- State transitions: IDLE → ALT_PENDING → ACTIVE → IDLE
- Freeze behavior with FreezeWindowList option
- Workspace toggle with UseCurrentWSProjection option
- Pre-warm with AltTabPrewarmOnAlt option
- Config combination matrix (all 8 combinations of 3 booleans)
- Selection wrapping, escape cancellation, delta blocking

Run GUI tests separately:
```
AutoHotkey64.exe //ErrorStdOut tests\gui_tests.ahk
```
Check `%TEMP%\gui_tests.log` for results.

### Delta Efficiency
- Empty deltas (0 upserts, 0 removes) should not be sent - check before sending
- Rev bumps don't mean actual changes for a specific client's projection
- Use `tests/delta_diagnostic.ahk` to debug delta issues

### Window Enumeration (On-Demand Architecture)
- **WinEventHook is primary** - catches window create/destroy/show/hide/title changes in real-time
- **WinEnum is on-demand** (pump mode) - only runs when needed:
  - Startup, snapshot requests, or Z-pump trigger
  - Optional safety polling via `WinEnumSafetyPollMs` (default 0 = disabled)
- **Z-pump**: When WinEventHook adds a window (z=0), it's queued; Z-pump triggers full scan
- If WinEventHook fails to start, automatic fallback to 2-second polling

### Producer Architecture (CRITICAL)
- **WinEventHook is always enabled** - primary source for window changes AND MRU tracking
- **MRU_Lite is fallback only** - starts only if WinEventHook fails to initialize
- **Komorebi is optional** - graceful handling if not installed/running
- **WinEnum runs on-demand** (pump mode), not polling:
  - Startup (initial population)
  - Snapshot request from client (safety/accuracy)
  - Z-pump trigger (when WinEventHook adds windows with z=0)
  - Optional safety polling via `WinEnumSafetyPollMs` (default 0 = disabled)
- **Only winenum (full scan) should call BeginScan/EndScan** - these manage window presence
- Partial producers (komorebi, winevent_hook) should ONLY call UpsertWindow/UpdateFields
- WinEventHook calls `WindowStore_EnqueueForZ()` after upserting - triggers Z-pump
- WinEventHook handles MRU updates on FOREGROUND/FOCUS events (no separate polling)

### Producer Observability
- **Producer state is tracked in projection meta** - clients see what's running/failed/disabled
- States: `"running"`, `"failed"`, `"disabled"`
- State included in `meta.producers` object: `{ wineventHook, mruLite, komorebiSub, komorebiLite, iconPump, procPump }`
- Viewer status bar shows: `WEH:OK KS:OK IP:OK PP:OK` (only running/failed shown, disabled hidden)
- **No automatic retry** - if a producer fails at startup, it stays failed. User restarts store.
- KomorebiSub has built-in recovery via `IdleRecycleMs` (120s) pipe recycling
- This is **observability only** - no IPC commands to restart individual producers (too complex)

### Window Removal Safety
- Any producer can request removal via `WindowStore_RemoveWindow()`
- Store verifies `!IsWindow(hwnd)` before actually deleting - prevents race conditions
- EndScan TTL-based removal also verifies window is gone; if still exists, resets presence
- Use `forceRemove := true` parameter only for cleanup of known-stale entries

### Blacklist Filtering
- Configured in `src/shared/blacklist.txt` (file-based, hot-reloadable via IPC)
- `UseBlacklist` toggle in config.ahk enables/disables filtering
- **Filtering happens at producer level** - blacklisted windows never enter the store
- Producers that ADD windows filter first: winenum_lite, winevent_hook, komorebi_sub
- MRU producer only UPDATES existing windows (lastActivatedTick, isFocused) - no filtering needed
- Wildcards `*` and `?` supported in patterns (case-insensitive)
- File format: `[Title]`, `[Class]`, `[Pair]` sections; pairs use `Class|Title` format
- Viewer: double-click a row to blacklist it (sends IPC reload message to store)
- Store reloads blacklist on `reload_blacklist` IPC message, purges matching windows immediately
- `WindowStore_PurgeBlacklisted()` removes all windows matching current blacklist after reload

### Centralized Window Eligibility (CRITICAL)
- **All eligibility logic lives in `Blacklist_IsWindowEligible()` in `src/shared/blacklist.ahk`**
- This function combines Alt-Tab eligibility rules AND blacklist filtering
- All producers MUST use this single function - never duplicate eligibility logic
- Alt-Tab eligibility checks: WS_CHILD, WS_EX_TOOLWINDOW, WS_EX_NOACTIVATE, owner windows, visibility/cloaked
- This prevents producers from disagreeing on which windows are eligible (causing flicker)

### Heartbeat & Connection Health
- **Store broadcasts heartbeat** every `StoreHeartbeatIntervalMs` (default 5s) to all clients
- Heartbeat message: `{ type: "heartbeat", rev: <current_rev> }`
- **Viewer uses heartbeat for**:
  - Connection liveness: no message in `ViewerHeartbeatTimeoutMs` (default 12s) → reconnect
  - Drift detection: if `store.rev > local.rev` → request full projection (we missed something)
- **No blind polling**: Viewer does NOT poll on interval; relies on pushed deltas + heartbeat
- Polling only happens on: initial connect, reconnect, toggle sort/filter, manual refresh, or rev drift

### Revision Churn Prevention (CRITICAL)
- **Rev should ONLY bump when data actually changes** - not on every scan cycle
- `WindowStore_UpsertWindow` and `WindowStore_Ensure` must compare values before updating
- Pattern: `if (!row.HasOwnProp(k) || row.%k% != v) { row.%k% := v; changed := true }`
- **Internal fields** (`gWS_InternalFields`) update without bumping rev:
  - `lastSeenScanId`, `lastSeenTick`, `missingSinceTick` - scan tracking
  - `iconCooldownUntilTick`, `iconGaveUp` - icon pump state
- Rev churn = wasted CPU + network traffic (deltas sent when nothing changed)
- Debug: Set `DiagChurnLog := true` in config.ahk, check `%TEMP%\tabby_store_error.log`
- When idle, viewer's "Rev" counter should be stable

### Icon Pump Retry Logic
- **Don't enqueue hidden windows** - `_WS_EnqueueIfNeeded` skips cloaked, minimized, invisible
- After `IconMaxAttempts` (default 4), window is marked `iconGaveUp := true`
- Windows that gave up are never re-enqueued (prevents endless retry loops)
- Successful icon retrieval clears the gave-up flag and attempts counter

### Claude Code CLI Known Issues
- **tmpclaude-* files**: Claude Code creates `tmpclaude-xxxx-cwd` files in the working directory (Windows bug)
- These are added to `.gitignore` - just delete them if they appear
- Tracked at: https://github.com/anthropics/claude-code/issues/17636

### Config System (IMPORTANT)
- **Two files must stay in sync** when adding new config values:
  1. `src/shared/config.ahk` - defines the default value (e.g., `global MyNewSetting := 100`)
  2. `src/shared/config_loader.ahk` - loads from INI and creates default INI
- When adding a new config:
  1. Add the default in `config.ahk` with a comment explaining it
  2. Add a `_CL_LoadSetting_*()` call in `_CL_LoadAllSettings()`
  3. Add a case in the appropriate `_CL_LoadSetting_*()` switch block
  4. Add a commented line in `_CL_CreateDefaultIni()` for the default INI
- The INI file (`src/config.ini`) has all values commented out by default
- Users uncomment and edit values they want to customize
- **Never commit config.ini** - it's in `.gitignore` and user-specific

### State Machine
```
IDLE ──Alt down──► ALT_PENDING ──Tab──► ACTIVE ──Alt up──► IDLE
                        │                  │
                        │ Alt up (quick)   │ Escape
                        ▼                  ▼
                   QUICK_SWITCH         CANCEL
```

- **IDLE**: Connected to store, receiving deltas, cache fresh
- **ALT_PENDING**: Alt held, pre-warm snapshot requested, grace timer running
- **ACTIVE**: GUI visible, list FROZEN (no delta updates), Tab cycles selection
- **QUICK_SWITCH**: Alt+Tab+release < grace period = switch to MRU[1], no GUI
- **CANCEL**: Escape pressed, close GUI, no switch

### Critical Design Decisions

1. **Lock-in on first Tab**: Projection frozen when Tab pressed, not on Alt
   - Gives pre-warm maximum time (human reaction ~50-100ms)
   - Frozen list never reorders during interaction (matches native Windows)

2. **Pre-warm on Alt**: Request snapshot when Alt pressed
   - By Tab time, fresh data likely arrived
   - If not, use current cache (still recent from deltas)

3. **GUI always running**: Show/hide, don't create/destroy
   - Faster response than process spawn or GUI creation
   - Memory cost acceptable for responsiveness

4. **Keyboard hooks in GUI process**: No separate interceptor process
   - Hooks built into gui_interceptor.ahk for zero IPC latency
   - Direct function calls between interceptor and state machine
   - Must respond <5ms

5. **Grace period ~150ms**: Quick Alt+Tab = instant switch, no GUI

### Config Options

```ini
[AltTab]
GraceMs=150              # Delay before showing GUI
QuickSwitchMs=100        # Max time for quick switch

# Pre-warm snapshot on Alt down (default: true)
# Ensures fresh window data is available when Tab is pressed
AltTabPrewarmOnAlt=true

# Freeze window list on first Tab press (default: true)
# true = list locked when Tab pressed, stable during interaction (matches Windows)
# false = live updates continue during Alt+Tab (list may reorder)
FreezeWindowList=true

# Use server-side workspace projection filtering (default: false)
# true = CTRL toggle requests filtered projection from store
# false = CTRL toggle filters client-side from cached data
UseCurrentWSProjection=false
```

### GUI Config Option Behavior Matrix

| FreezeWindowList | UseCurrentWSProjection | Prewarm | CTRL Toggle Behavior |
|------------------|------------------------|---------|----------------------|
| true | false | true | Re-filter from frozen gGUI_AllItems |
| true | true | true | Request new projection from store |
| false | false | true | Re-filter from live gGUI_Items |
| false | true | true | Request new projection from store |

**Wait-for-data logic**: When Tab is pressed and `gGUI_Items` is empty (prewarm data hasn't arrived yet), the GUI waits up to 50ms for data to arrive before freezing. This prevents the "no windows" bug when CTRL toggling workspace mode.

### Key Metrics to Verify
- Alt+Tab detection: <5ms
- GUI show after Tab: <50ms
- Quick switch (no GUI): <25ms total

## Debug Options

Debug options are in `[Diagnostics]` section of config.ini. All disabled by default to minimize disk I/O.

### DiagChurnLog
- **File**: `%TEMP%\tabby_store_error.log`
- **Use when**: Store rev is incrementing rapidly when idle (revision churn)
- **Shows**: Which code paths are bumping rev unnecessarily
- **Enable**: Set `ChurnLog=true` in config.ini `[Diagnostics]` section

### DiagKomorebiLog
- **File**: `%TEMP%\tabby_ksub_diag.log`
- **Use when**: Workspace tracking issues - windows not showing correct workspace, CurWS not updating, move/focus events not being processed
- **Shows**: All komorebi events received, content extraction, workspace lookups, window updates
- **Enable**: Set `KomorebiLog=true` in config.ini `[Diagnostics]` section

### DebugAltTabTooltips
- **Output**: On-screen tooltips
- **Use when**: Alt-Tab overlay not appearing, wrong state transitions, quick-switch not working
- **Shows**: State machine transitions (ALT_UP arrival, selection out of range errors)
- **Enable**: Set `AltTabTooltips=true` in config.ini `[Diagnostics]` section

### DebugViewerLog
- **File**: `%TEMP%\tabby_viewer.log`
- **Use when**: Viewer not receiving deltas, connection issues
- **Shows**: Pipe connection events, delta processing
- **Enable**: Set `DebugLog=true` in config.ini `[Viewer]` section
