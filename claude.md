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
    config_loader.ahk - Registry-driven config system (single source of truth)
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
    gui_gdip.ahk        - GDI+ graphics helpers
    gui_win.ahk         - Window/DPI utilities
  viewer/         - Debug viewer
    viewer.ahk    - GUI with Z/MRU toggle, workspace filter
tests/
  run_tests.ahk   - Test orchestrator (includes production + test files)
  test_utils.ahk  - Test utilities: Log, Assert, IPC callbacks
  test_unit.ahk   - Unit tests (WindowStore, Config, Entry Points)
  test_live.ahk   - Live integration tests (require --live flag)
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
- `winenum.ahk`: Full-featured enumeration with DWM cloaking - **ported features**
- `komorebi_sub.ahk`: Subscription-based updates - **ported - use instead of polling**
- `New GUI Working POC.ahk`: Rich GUI with icons, DWM effects - **PORTED to Main GUI**
- `mru.ahk`, `icon_pump.ahk`, `proc_pump.ahk`: Mature enrichers **PORTED**

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
- **No inline global declarations in switch cases** - this is invalid:
  ```ahk
  ; WRONG - syntax error
  switch name {
      case "Foo": global Foo; return Foo
  }

  ; CORRECT - declare all globals at function scope first
  MyFunc(name) {
      global Foo, Bar, Baz  ; Declare all at top
      switch name {
          case "Foo": return Foo
          case "Bar": return Bar
      }
  }
  ```

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

**Common bug pattern - using globals without declaring them:**
```ahk
; WRONG - gGUI_AllItems and gGUI_FrozenItems are used but not declared global
; They become LOCAL variables, invisible to other functions!
GUI_OnStoreMessage(line) {
    global gGUI_Items, gGUI_State  ; Missing gGUI_AllItems, gGUI_FrozenItems!
    ...
    gGUI_AllItems := gGUI_Items           ; Creates LOCAL variable
    gGUI_FrozenItems := FilterItems()     ; Creates LOCAL variable
}

; CORRECT - declare ALL globals used in the function
GUI_OnStoreMessage(line) {
    global gGUI_Items, gGUI_State, gGUI_AllItems, gGUI_FrozenItems
    ...
    gGUI_AllItems := gGUI_Items           ; Updates GLOBAL
    gGUI_FrozenItems := FilterItems()     ; Updates GLOBAL
}
```
- **Symptom**: Function appears to work internally, but other functions see stale/empty values
- **Debug tip**: Add diagnostic logging to print `.Length` before AND after function calls

### Cross-File Global Visibility (CRITICAL)
- **Variables set inside a function are NOT visible to other files**, even with `global` keyword
- Setting `global Foo := 123` inside a function only makes `Foo` accessible within that file
- **For globals that other files need to see, declare them at FILE SCOPE** (outside any function):
  ```ahk
  ; In config_loader.ahk - FILE SCOPE declaration
  global StorePipeName  ; Just declare, don't initialize
  global UseIconPump

  ; Later, a function can set the value
  _CL_InitializeDefaults() {
      global StorePipeName, UseIconPump  ; Reference the file-scope globals
      StorePipeName := "tabby_store_v1"
      UseIconPump := true
  }
  ```
- The file-scope declaration makes the variable visible to all files that include this one
- The function can then set the actual value

### IsSet() Behavior with Global Declarations (CRITICAL)
- **`IsSet(Var)` returns true if the variable has been assigned ANY value, including 0, false, or ""**
- **`IsSet(Var)` returns false ONLY if the variable was declared but never assigned**
- This affects fallback patterns like:
  ```ahk
  ; In producer file - uses IsSet() for fallback
  global WinEventHook_DebounceMs := IsSet(WinEventHookDebounceMs) ? WinEventHookDebounceMs : 50
  ```
- **If you declare with an initial value, IsSet() returns true and uses that value:**
  ```ahk
  ; WRONG - IsSet() returns true, uses 0 instead of fallback 50
  global WinEventHookDebounceMs := 0

  ; CORRECT - IsSet() returns false until _CL_InitializeDefaults() sets the real value
  global WinEventHookDebounceMs  ; Declare without value
  ```
- This caused a bug where all config values were 0/false because `IsSet()` returned true for initialized-to-zero globals

### Trust Test Failures
- **When tests fail, investigate the root cause - don't dismiss failures as "timing issues" or "environment-specific"**
- If tests passed before a change and fail after, the change introduced a regression
- Compiled exe tests passing while development mode fails usually indicates a path or initialization issue
- Multiple tests failing with similar patterns (e.g., "Could not connect to store") points to a common root cause
- The test suite exists specifically to catch these issues - trust it

### Test Architecture (CRITICAL - Never Copy Production Code)
- **NEVER copy production function implementations into test files** - this creates divergence where tests pass but production fails
- **Always `#Include` production files** and mock ONLY the visual/external layer
- If tests have copied code, they become useless - they test the copy, not the actual code

**Correct test file structure:**
```ahk
; 1. Define globals that match production (state variables, constants)
global gGUI_State := "IDLE"
global IPC_MSG_DELTA := "delta"

; 2. Define MOCKS for visual/external layer BEFORE includes
; These are functions from files you DON'T include (gui_paint.ahk, gui_overlay.ahk, ipc_pipe.ahk)
GUI_Repaint() { }  ; Visual - mock as no-op
GUI_HideOverlay() { global gGUI_OverlayVisible; gGUI_OverlayVisible := false }
IPC_PipeClient_Send(client, msg) { global gMockMessages; gMockMessages.Push(msg) }

; 3. INCLUDE actual production files (business logic we're testing)
#Include %A_ScriptDir%\..\src\gui\gui_state.ahk
#Include %A_ScriptDir%\..\src\gui\gui_store.ahk

; 4. Test utilities and tests call REAL production functions
```

**What to mock vs include:**
- **Mock**: Visual rendering (GUI_Repaint, GUI_ResizeToRows), IPC sending, DWM calls, actual GUI objects
- **Include**: State machine logic, data transformation, filtering, business rules

**Test data format must match JSON expectations:**
```ahk
; WRONG - uppercase keys don't match what GUI_ConvertStoreItems expects
items.Push({ Title: "Win1", Class: "MyClass" })

; CORRECT - lowercase keys match JSON format from store
items.Push({ title: "Win1", class: "MyClass", lastActivatedTick: A_TickCount })
```

**Delta format must match production:**
```ahk
; WRONG - production GUI_ApplyDelta expects "upserts", not "items"
{ type: "delta", payload: { items: [...] } }

; CORRECT - matches what GUI_ApplyDelta looks for
{ type: "delta", payload: { upserts: [...] } }
```

**How to verify tests are testing production code:**
1. Intentionally break a production function
2. Run tests - they should FAIL
3. If tests still pass, they're testing copied code, not production

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

### Main Test Suite Structure
The main test suite (`run_tests.ahk`) is split into modular files:

| File | Purpose | When Run |
|------|---------|----------|
| `run_tests.ahk` | Orchestrator - includes production files and test modules | Always |
| `test_utils.ahk` | Log, AssertEq, AssertTrue, IPC test callbacks | Always (included) |
| `test_unit.ahk` | Unit tests: WindowStore, Config, Entry Points | Always |
| `test_live.ahk` | Live integration: IPC, Store, Viewer, Komorebi, Compiled exe | Only with `--live` |

**Key design principles:**
- `run_tests.ahk` `#Include`s production files (json.ahk, windowstore.ahk, ipc_pipe.ahk, etc.)
- Test files only define test utilities and test functions - NO copied production code
- Tests call actual production functions via the includes
- This ensures tests validate real behavior, not stale copies

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

### Config System (Single Source of Truth)
- **Single object**: All config values stored in `global cfg := {}` object
- **Access via**: `cfg.PropertyName` (e.g., `cfg.AltTabGraceMs`, `cfg.GUI_RowHeight`)
- **Single source of truth**: `gConfigRegistry` in `src/shared/config_loader.ahk` contains ALL config definitions
- **Registry includes defaults**: Each setting has a `default` value - no separate config.ahk needed
- **INI supplementing**: Missing keys in existing config.ini are automatically added on startup
- **Config editor**: `--config` flag or tray menu launches GUI editor with section/subsection headers

**When adding a new config:**
1. Add ONE entry to `gConfigRegistry` in `config_loader.ahk`
2. That's it! The value is automatically available as `cfg.YourConfigName`

**Registry Schema:**
```ahk
global gConfigRegistry := [
    ; Section header
    {type: "section", name: "AltTab",
     desc: "Alt-Tab Behavior",
     long: "These control the Alt-Tab overlay behavior - tweak these first!"},

    ; Setting with default - automatically available as cfg.AltTabGraceMs
    {s: "AltTab", k: "GraceMs", g: "AltTabGraceMs", t: "int", default: 150,
     d: "Grace period before showing GUI (ms). During this time, if Alt is released, we do a quick switch."},

    ; Subsection header (for GUI grouping)
    {type: "subsection", section: "GUI", name: "Background Window",
     desc: "Window background and frame styling"},

    ; Setting in subsection - automatically available as cfg.GUI_AcrylicAlpha
    {s: "GUI", k: "AcrylicAlpha", g: "GUI_AcrylicAlpha", t: "int", default: 0x33,
     d: "Background transparency (0x00=transparent, 0xFF=opaque)"},
]
```

**Entry types:**
- `Section`: `{type: "section", name, desc, long}` - INI section with tab in config editor
- `Subsection`: `{type: "subsection", section, name, desc}` - Visual grouping in GUI only
- `Setting`: `{s, k, g, t, default, d}` - Actual config value (stored as `cfg.g`)

**Accessing config values:**
```ahk
; Direct access (most common)
if (cfg.AltTabPrewarmOnAlt) { ... }
timeout := cfg.ViewerHeartbeatTimeoutMs

; Defensive access (for code that may run before ConfigLoader_Init)
useAltTab := cfg.HasOwnProp("UseAltTabEligibility") ? cfg.UseAltTabEligibility : true

; In functions, declare global cfg
MyFunction() {
    global cfg
    if (cfg.SomeSetting) { ... }
}
```

**CRITICAL - ConfigLoader_Init() Must Be Called First:**
- Every entry point that uses config MUST call `ConfigLoader_Init()` before accessing `cfg`
- Entry points that need config: `gui_main.ahk`, `viewer.ahk`, `store_server.ahk`
- Each calls `ConfigLoader_Init()` at the START of their init function
- **Symptom of missing init**: Property access errors on `cfg`
- Tests include an "Entry Point Initialization Test" that catches this by actually running each entry point

**Key functions:**
- `_CL_InitializeDefaults()` - Sets all `cfg.` properties from registry defaults
- `_CL_SupplementIni(path)` - Adds missing keys to existing config.ini
- `_CL_CreateDefaultIni(path)` - Creates full INI with section/subsection comments
- `_CL_ReadGlobal(name, type)` / `_CL_WriteGlobal(name, value)` - Dynamic property access (used by config editor)

**Config sections (in order of user relevance):**
1. `[AltTab]` - Alt-Tab behavior (most likely to edit)
2. `[GUI]` - Appearance settings (with many subsections)
3. `[IPC]`, `[Tools]`, `[Producers]`, etc. - Advanced settings

- **Never commit config.ini** - it's in `.gitignore` and user-specific
- User edits in config.ini override registry defaults

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

### Cross-Workspace Window Activation (CRITICAL)

When activating a window on a different komorebi workspace, several challenges must be handled:

**The Problem:**
- `komorebic focus-named-workspace` switches workspace but focuses komorebi's "last used" window, not our target
- `SetForegroundWindow` alone fails due to Windows' foreground lock restrictions
- Manual uncloaking with `DwmSetWindowAttribute(DWMWA_CLOAK)` pulls windows to the WRONG workspace - never do this!

**The Solution (in `gui_state.ahk:GUI_ActivateItem`):**

1. **Switch workspace and poll for completion:**
   ```ahk
   Run('"' cfg.KomorebicExe '" focus-named-workspace "' wsName '"', , "Hide")

   ; Poll with WScript.Shell.Run (window style 0 = hidden, true = wait)
   shell := ComObject("WScript.Shell")
   queryCmd := 'cmd.exe /c "' cfg.KomorebicExe '" query focused-workspace-name > "' tempFile '"'
   shell.Run(queryCmd, 0, true)  ; Hidden cmd.exe, wait for completion
   ```

2. **Use komorebi's activation pattern (SendInput trick):**
   ```ahk
   ; Send dummy mouse input to bypass foreground lock
   input := Buffer(40, 0)
   NumPut("uint", 0, input, 0)  ; INPUT_MOUSE
   DllCall("user32\SendInput", "uint", 1, "ptr", input, "int", 40)

   ; SetWindowPos to bring to top
   DllCall("user32\SetWindowPos", "ptr", hwnd, "ptr", -1, ...)  ; HWND_TOPMOST
   DllCall("user32\SetWindowPos", "ptr", hwnd, "ptr", -2, ...)  ; HWND_NOTOPMOST

   ; Now SetForegroundWindow works
   DllCall("user32\SetForegroundWindow", "ptr", hwnd)
   ```

**Key Lessons:**
- **Never manually uncloak** - komorebi manages cloaking; interfering pulls windows across workspaces
- **Must wait for workspace switch** - fixed sleep is unreliable; poll `query focused-workspace-name`
- **Hide cmd.exe properly** - use `WScript.Shell.Run(cmd, 0, true)` not `shell.Exec()` which flashes
- **SendInput trick is essential** - bypasses Windows' foreground lock that blocks background processes
- **SetWindowPos before SetForegroundWindow** - brings window to top first

**Reference:** Komorebi's `raise_and_focus_window` in [windows_api.rs](https://github.com/LGUG2Z/komorebi/blob/master/komorebi/src/windows_api.rs)

### Rapid Alt-Tab & Keyboard Hook Preservation (CRITICAL)

When doing rapid Alt+Tab sequences (especially during cross-workspace activation), keyboard events can be lost due to hook uninstallation. This section documents the hard-won lessons from fixing this.

#### SendMode("Event") is Mandatory

**The Problem:**
- AHK's default `SendInput` mode temporarily **uninstalls all keyboard hooks** during Send operations
- When `Send("{Blind}{vkE8}")` runs in our interceptor, the hook is briefly gone (~1ms)
- User's rapid keypress (Alt or Tab) during this window is lost at the Windows level
- The keypress never reaches AHK - it's gone forever

**The Fix:**
```ahk
; At the TOP of gui_main.ahk, before anything else
SendMode("Event")  ; Keep keyboard hooks active during Send
```

**Why This Matters:**
- `SendInput`: Fast, buffers input, but **uninstalls hook**
- `SendEvent`: Slightly slower, but **hook stays active**
- For Alt-Tab, keeping the hook is far more important than send speed

**References:**
- [AHK SendMode docs](https://www.autohotkey.com/docs/v2/lib/SendMode.htm)
- [Forum discussion on hook uninstallation](https://www.autohotkey.com/boards/viewtopic.php?t=127074)

#### Critical "On" in All Hotkey Callbacks

**The Problem:**
Without `Critical "On"`, one hotkey callback can interrupt another mid-execution:
1. User presses Tab → `INT_Tab_Down` starts running
2. User releases Alt → `INT_Alt_Up` interrupts `INT_Tab_Down`
3. `INT_Alt_Up` resets state to IDLE
4. `INT_Tab_Down` resumes but state is now wrong
5. Tab event is effectively lost

**The Fix:**
```ahk
INT_Alt_Down(*) {
    Critical "On"  ; Prevent other hotkeys from interrupting
    ; ... handler code
}

INT_Tab_Down(*) {
    Critical "On"  ; Prevent other hotkeys from interrupting
    ; ... handler code
}
```

**Apply to ALL hotkey handlers:**
- `INT_Alt_Down`, `INT_Alt_Up`
- `INT_Tab_Down`, `INT_Tab_Up`
- `INT_Tab_Decide`, `INT_Tab_Decide_Inner`
- `INT_Ctrl_Down`, `INT_Escape_Down`
- `GUI_OnInterceptorEvent` (state machine entry point)

#### komorebic Also Uses SendInput (Hook Uninstallation)

**The Problem:**
When we call `komorebic focus-named-workspace`, komorebi internally uses `SendInput` for its window activation. This **also uninstalls our keyboard hook** briefly!

```
User presses Alt+Tab → we switch workspace
komorebic runs SendInput → OUR hook is uninstalled
User presses Tab (for next Alt+Tab) → TAB IS LOST
```

**The Fix:** Async activation with event buffering (see below)

#### Async Activation with Event Buffering

**The Pattern:**
Cross-workspace activation is now **non-blocking** (async). During the workspace switch:
1. Events are BUFFERED, not processed immediately
2. Keyboard hook keeps running between timer fires
3. After activation completes, buffered events are processed in order

**Implementation (in `gui_state.ahk`):**
```ahk
; Async state
global gGUI_PendingPhase := ""    ; "polling", "waiting", "flushing", or ""
global gGUI_EventBuffer := []      ; Queued events during async

; In GUI_OnInterceptorEvent - buffer events if async in progress
if (gGUI_PendingPhase != "") {
    if (evCode = TABBY_EV_ESCAPE) {
        _GUI_CancelPendingActivation()  ; ESC cancels immediately
        return
    }
    gGUI_EventBuffer.Push({ev: evCode, flags: flags, lParam: lParam})
    return
}
```

**Lost Tab Detection:**
If komorebic's SendInput causes Tab to be lost, we detect and synthesize it:
```ahk
; In _GUI_ProcessEventBuffer
; Pattern: ALT_DN + ALT_UP without TAB means Tab was lost
hasAltDn := false, hasTab := false, hasAltUp := false
for ev in events {
    if (ev.ev = TABBY_EV_ALT_DOWN) hasAltDn := true
    if (ev.ev = TABBY_EV_TAB_STEP) hasTab := true
    if (ev.ev = TABBY_EV_ALT_UP) hasAltUp := true
}
if (hasAltDn && hasAltUp && !hasTab) {
    ; Lost Tab detected! Insert synthetic TAB after ALT_DN
    events.InsertAt(altDnIdx + 1, {ev: TABBY_EV_TAB_STEP, flags: 0, lParam: 0})
}
```

#### Local MRU Updates (Faster Than Store Deltas)

**The Problem:**
During rapid Alt+Tab, we're faster than the store's delta pipeline:
1. Alt+Tab #1: Activate window A
2. We update local MRU (A is now position 1)
3. But pre-warm snapshot from BEFORE activation arrives
4. Snapshot overwrites our local MRU with stale data
5. Alt+Tab #2: Selects WRONG window (sees stale MRU order)

**The Fix:** Track local MRU timestamp and skip stale snapshots:
```ahk
; In gui_main.ahk
global gGUI_LastLocalMRUTick := 0

; In GUI_ActivateItem - after successful activation
gGUI_LastLocalMRUTick := A_TickCount  ; Mark that we just updated MRU

; In GUI_OnInterceptorEvent (ALT_DOWN) - skip prewarm if MRU fresh
mruAge := A_TickCount - gGUI_LastLocalMRUTick
if (mruAge > 300) {
    GUI_RequestSnapshot()  ; OK to prewarm
} else {
    ; Skip - our local MRU is fresher than store's
}

; In GUI_OnStoreMessage - skip snapshot if MRU fresh
if (mruAge < 300 && !isToggleResponse) {
    ; Skip this snapshot - would overwrite our fresh local MRU
    gGUI_StoreRev := obj["rev"]  ; Still update rev
    return
}
```

**Also update local workspace immediately:**
```ahk
; After cross-workspace activation completes
gGUI_CurrentWSName := gGUI_PendingWSName  ; Don't wait for IPC

; Update all items' isOnCurrentWorkspace flags
for item in gGUI_Items {
    if (item.HasOwnProp("WS")) {
        item.isOnCurrentWorkspace := (item.WS = gGUI_CurrentWSName)
    }
}
```

#### Debugging Rapid Alt-Tab Issues

**Enable event logging:** Set `EventLog=true` in config.ini `[Diagnostics]` section (see DiagEventLog below).

**Log file:** `%TEMP%\tabby_events.log`

**What to look for:**
- `INT: Alt_Down` / `INT: Alt_Up` / `INT: Tab_Down` - interceptor events
- `BUFFERING` - events being queued during async
- `PREWARM: skipped` - local MRU protection working
- `SNAPSHOT: skipped` - stale snapshot protection working
- `MRU UPDATE` - local MRU being updated after activation
- Missing `Tab_Down` between `Alt_Down` and `Alt_Up` = lost Tab event

**Pattern for lost events:**
```
Alt_Down (session=false)    ; First Alt+Tab
Tab_Down (session=false)    ; Tab received
ACTIVATE                    ; Switch happens
Alt_Down (session=false)    ; Second Alt+Tab starts
Alt_Up (session=false)      ; NO TAB IN BETWEEN = Tab was lost
```

#### Summary: The Full Defense Stack

1. **SendMode("Event")** - keeps hook active during our Sends
2. **Critical "On"** - prevents callback interruption
3. **Async activation** - non-blocking to allow keyboard events
4. **Event buffering** - queue events during async, process after
5. **Lost Tab detection** - synthesize Tab if ALT_DN+ALT_UP without TAB
6. **Local MRU tracking** - skip stale prewarmed/in-flight snapshots
7. **Local WS update** - update workspace state immediately, don't wait for IPC

**Ultimate limitation:** If a keypress is lost before reaching AHK's hook (at Windows/driver level), there's nothing we can do. This happens at extreme speeds (4+ rapid Alt+Tabs). For normal use, the above defenses make Alt-Tabby **more responsive than native Windows Alt+Tab**.

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

### DiagEventLog
- **File**: `%TEMP%\tabby_events.log`
- **Use when**: Rapid Alt-Tab issues, events being lost, wrong window selected
- **Shows**: All interceptor events (Alt/Tab down/up), state machine transitions, async activation phases, event buffering, MRU updates
- **Enable**: Set `EventLog=true` in config.ini `[Diagnostics]` section
- **Pattern to look for**: Missing `Tab_Down` between `Alt_Down` and `Alt_Up` indicates Tab was lost during hook uninstallation
