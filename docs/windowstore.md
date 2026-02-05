# WindowStore API (v1)

Purpose
- Single source of truth for window state.
- Producers write; consumers read via projections or IPC deltas.

Core API
- `WindowStore_Init(config?)`
- `WindowStore_BeginScan()` / `WindowStore_EndScan(graceMs?)`
- `WindowStore_UpsertWindow(records, source := "")` - Batch upsert window records
- `WindowStore_UpdateFields(hwnd, patch, source := "")` - Update specific fields on a window
- `WindowStore_RemoveWindow(hwnds, forceRemove := false)` - Remove windows (verifies IsWindow unless forced)
- `WindowStore_ValidateExistence()` - Lightweight zombie detection
- `WindowStore_PurgeBlacklisted()` - Remove all blacklisted windows
- `WindowStore_Ensure(hwnd, hints := 0, source := "")` - Ensure window exists, create if needed
- `WindowStore_Has(hwnd)` - Check if hwnd exists in store (via gWS_Store.Has)
- `WindowStore_GetByHwnd(hwnd)` - Get record by hwnd (via gWS_Store[hwnd])
- `WindowStore_GetProjection(opts?)` - Get filtered/sorted projection
- `WindowStore_GetRev()` - Get current revision number
- `WindowStore_GetChurnDiag(reset := true)` - Get diagnostic churn stats
- `WindowStore_SetCurrentWorkspace(id, name?)` - Set current workspace
- `WindowStore_GetCurrentWorkspace()` - Get current workspace meta

Queue Management (for pumps)
- `WindowStore_EnqueueIconRefresh(hwnd)` - Queue window for icon resolution
- `WindowStore_PopIconBatch(count := 16)` - Pop batch of hwnds needing icons
- `WindowStore_PopPidBatch(count := 16)` - Pop batch of pids needing process names
- `WindowStore_EnqueueForZ(hwnd)` - Queue window for Z-order update
- `WindowStore_HasPendingZ()` / `WindowStore_PendingZCount()` / `WindowStore_ClearZQueue()`

Cache API
- `WindowStore_GetProcNameCached(pid)` - Get cached process name
- `WindowStore_UpdateProcessName(pid, name)` - Update process name cache
- `WindowStore_GetExeIconCopy(exePath)` - Get cached icon copy
- `WindowStore_ExeIconCachePut(exePath, hIcon)` - Store icon in cache

Record fields (full)
- Identity: `hwnd`, `title`, `class`, `pid`
- Presence: `present`, `presentNow`, `missingSinceTick`, `lastSeenScanId`, `lastSeenTick`
- State: `altTabEligible`, `isCloaked`, `isMinimized`, `isVisible`
- Sort keys: `z`, `lastActivatedTick`, `isFocused`
- Workspace: `workspaceId`, `workspaceName`, `isOnCurrentWorkspace`
- Process: `processName`, `exePath`
- Icon: `iconHicon`, `iconCooldownUntilTick`, `iconGaveUp`, `iconMethod`, `iconLastRefreshTick`

Internal fields (don't bump rev when changed)
- `iconCooldownUntilTick` - Backoff timer for icon retry
- `lastSeenScanId` - Scan tracking
- `lastSeenTick` - Timestamp tracking
- `missingSinceTick` - When window went missing
- `iconGaveUp` - True if all icon methods failed
- `iconMethod` - How icon was obtained: "wm_geticon", "uwp", "exe", or ""
- `iconLastRefreshTick` - Throttle for WM_GETICON refresh

Projection item fields (sent to clients via _WS_ToItem)
- `hwnd`, `title`, `class`, `pid`
- `z`, `lastActivatedTick`, `isFocused`
- `isCloaked`, `isMinimized`
- `workspaceName`, `workspaceId`, `isOnCurrentWorkspace`
- `processName`, `iconHicon`, `present`

Producer responsibilities
- winenum: identity + presence + state + z (via BeginScan/EndScan)
- winevent_hook: create/destroy events, focus/MRU updates
- mru_lite: focus + lastActivatedTick (fallback if winevent_hook fails)
- komorebi_sub/lite: workspace fields
- proc_pump: processName + exePath
- icon_pump: icon fields

Note: Only winenum should call BeginScan/EndScan. Other producers use UpsertWindow/UpdateFields.

Queues
- `gWS_IconQueue` / `gWS_IconQueueDedup` - hwnds needing icons
- `gWS_PidQueue` / `gWS_PidQueueDedup` - pids needing process names
- `gWS_ZQueue` / `gWS_ZQueueDedup` - hwnds needing Z-order (triggers winenum pump)
