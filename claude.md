# Alt-Tabby Assistant Context

## Project Summary
- AHK v2 Alt-Tab replacement focused on responsiveness and low latency.
- Komorebi aware; uses workspace state to filter and label windows.
- Hotkey interception is split into a separate micro process for speed.

## Architecture (4-Process Design)
1. **Interceptor** (micro): Ultra-fast Alt+Tab hook, isolated for timing. Communicates via IPC.
2. **WindowStore + Producers**: Single process hosting store, winenum, MRU, komorebi producers. Named pipe server for multi-subscriber.
3. **AltLogic + GUI**: Consumer process with overlay, MRU selection, window activation.
4. **Debug Viewer**: Diagnostic tool showing Z/MRU-ordered window list from store.

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
  viewer/         - Debug viewer
    viewer.ahk    - GUI with Z/MRU toggle, workspace filter
tests/
  run_tests.ahk   - Automated test suite (unit + live)
  test.ps1        - PowerShell test runner
legacy/
  components_legacy/  - Original ChatGPT work (reference only)
```

## Key Files
- `src/store/store_server.ahk`: WindowStore main entry point
- `src/store/windowstore.ahk`: Core store with GetProjection, UpsertWindow, scan APIs
- `src/shared/ipc_pipe.ahk`: Multi-subscriber named pipe IPC
- `src/viewer/viewer.ahk`: Debug viewer GUI
- `tests/run_tests.ahk`: Automated tests

## Legacy Components (in legacy/components_legacy/)
These are from the original ChatGPT work. Some are battle-tested:
- `interceptor.ahk`: Solid Alt+Tab hook with grace period - **port this**
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

### Testing from Git Bash
- Use `//ErrorStdOut` (double slash) to prevent Git Bash path expansion
- Git Bash converts `/ErrorStdOut` → `C:/Program Files/Git/ErrorStdOut` (wrong!)
- Correct: `"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" //ErrorStdOut "path\to\script.ahk"`

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

## Next Steps (Planned)
1. Port legacy interceptor to `src/interceptor/`
2. Wire legacy GUI as the real AltLogic consumer
