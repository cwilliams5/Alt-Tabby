# WindowStore API (v1)

Purpose
- Single source of truth for window state.
- Producers write; consumers read via projections or IPC deltas.

Core API
- `WindowStore_Init(config?)`
- `WindowStore_BeginBatch()` / `WindowStore_EndBatch()`
- `WindowStore_BeginScan()` / `WindowStore_EndScan(graceMs?)`
- `WindowStore_SetFetchers({ ByHwnd: Func })`
- `WindowStore_SetOwnershipPolicy(mode := "off", allowedMap?)`
- `WindowStore_Ensure(hwnd, hints := 0, source := "")`
- `WindowStore_UpsertWindow(records, source := "")`
- `WindowStore_UpdateFields(hwnd, patch, source := "")`
- `WindowStore_RemoveWindow(hwnds)`
- `WindowStore_Has(hwnd)`
- `WindowStore_GetByHwnd(hwnd)`
- `WindowStore_GetProjection(opts?)`
- `WindowStore_GetIndexOf(hwnd, opts?)`
- `WindowStore_SetCurrentWorkspace(id, name?)`
- `WindowStore_GetCurrentWorkspace()`

Record fields (initial)
- Identity: `hwnd`, `title`, `class`, `pid`
- Presence: `present`, `presentNow`, `missingSinceTick`, `lastSeenScanId`
- State: `state`, `altTabEligible`, `isBlacklisted`
- Sort keys: `z`, `lastActivatedTick`, `isFocused`
- Workspace: `workspaceId`, `workspaceName`, `isOnCurrentWorkspace`
- Process: `processName`, `exePath`
- Icon: `iconHicon`, `iconCooldownUntilTick`

Ownership policy (default off)
- winenum: identity + presence + state + z
- mru: focus + lastActivatedTick
- komorebi: workspace fields
- proc_pump: processName + exePath
- icon_pump: icon fields

Queues
- `gWS_Q_Pid` (pid needs process name)
- `gWS_Q_Icon` (hwnd needs icon)
- `gWS_Q_WS` (hwnd needs workspace)