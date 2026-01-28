# Debug Options

All in `[Diagnostics]` section of config.ini. Disabled by default.

## DiagChurnLog
- **File**: `%TEMP%\tabby_store_error.log`
- **Use when**: Store rev incrementing rapidly when idle
- **Enable**: `ChurnLog=true`

## DiagKomorebiLog
- **File**: `%TEMP%\tabby_ksub_diag.log`
- **Use when**: Workspace tracking issues, CurWS not updating
- **Enable**: `KomorebiLog=true`

## DebugAltTabTooltips
- **Output**: On-screen tooltips
- **Use when**: Overlay not appearing, wrong state transitions
- **Enable**: `AltTabTooltips=true`

## DebugViewerLog
- **File**: `%TEMP%\tabby_viewer.log`
- **Use when**: Viewer not receiving deltas
- **Enable**: `DebugLog=true` in `[Viewer]` section

## DiagEventLog
- **File**: `%TEMP%\tabby_events.log`
- **Use when**: Rapid Alt-Tab issues, events lost
- **Enable**: `EventLog=true`
- **Pattern**: Missing `Tab_Down` between `Alt_Down` and `Alt_Up` = Tab lost

## DiagWinEventLog
- **File**: `%TEMP%\tabby_weh_focus.log`
- **Use when**: Focus tracking issues, bypass mode problems
- **Enable**: `WinEventLog=true`

## DiagStoreLog
- **File**: `%TEMP%\tabby_store_error.log`
- **Use when**: Store startup issues, blacklist loading
- **Enable**: `StoreLog=true`

## DiagIconPumpLog
- **File**: `%TEMP%\tabby_iconpump.log`
- **Use when**: Icon resolution issues, cloaked windows missing icons
- **Enable**: `IconPumpLog=true`

## DiagProcPumpLog
- **File**: `%TEMP%\tabby_procpump.log`
- **Use when**: Process name resolution failures
- **Enable**: `ProcPumpLog=true`

## DiagLauncherLog
- **File**: `%TEMP%\tabby_launcher.log`
- **Use when**: Startup issues, subprocess not launching
- **Enable**: `LauncherLog=true`

## DiagIPCLog
- **File**: `%TEMP%\tabby_ipc.log`
- **Use when**: Store-GUI communication issues
- **Enable**: `IPCLog=true`

## DiagPaintTimingLog
- **File**: `%TEMP%\tabby_paint_timing.log`
- **Use when**: Slow overlay rendering after extended idle, paint performance issues
- **Enable**: `PaintTimingLog=true`
- **Details**: Logs per-paint step timings (getRect, getScale, backbuf, paintOverlay, updateLayer). Logs first paint, paint after 60s+ idle, and any paint >100ms. Auto-trimmed to 100KB (keeps last 50KB). Log deleted on fresh boot.

## Store_LogError (Always Active)
- **File**: `%TEMP%\tabby_store_error.log`
- No config flag - errors always logged
- `Store_LogInfo()` respects `DiagStoreLog`

## Icon Resolution System

Methods (priority order): WM_GETICON -> UWP -> EXE

Modes:
- NO_ICON: Try all methods
- UPGRADE: Has fallback icon, now visible -> try WM_GETICON
- REFRESH: Has WM_GETICON, gained focus -> recheck (icons can change)

**WinExist vs IsWindow:** `WinExist()` returns FALSE for cloaked windows. Use `DllCall("user32\IsWindow")` instead.

## Revision Churn Prevention

Rev should ONLY bump when data actually changes:
```ahk
if (!row.HasOwnProp(k) || row.%k% != v) {
    row.%k% := v
    changed := true
}
```

Internal fields (`lastSeenScanId`, `iconCooldownUntilTick`, etc.) update without bumping rev.
