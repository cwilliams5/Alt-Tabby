# Debug Diagnostics

All in `[Diagnostics]` section of config.ini. Disabled by default. All logs in `%TEMP%\`.

- **ChurnLog** → `tabby_store_error.log` — Store rev incrementing rapidly when idle
- **KomorebiLog** → `tabby_ksub_diag.log` — Workspace tracking, CurWS not updating
- **AltTabTooltips** → On-screen tooltips — Overlay not appearing, wrong state transitions
- **ViewerLog** (`DebugLog=true` in `[Viewer]`) → `tabby_viewer.log` — Viewer not receiving deltas
- **EventLog** → `tabby_events.log` — Rapid Alt-Tab, events lost. Pattern: missing `Tab_Down` between `Alt_Down`/`Alt_Up` = lost Tab
- **WinEventLog** → `tabby_weh_focus.log` — Focus tracking, bypass mode problems
- **StoreLog** → `tabby_store_error.log` — Store startup, blacklist loading
- **IconPumpLog** → `tabby_iconpump.log` — Icon resolution, cloaked windows missing icons
- **ProcPumpLog** → `tabby_procpump.log` — Process name resolution failures
- **LauncherLog** → `tabby_launcher.log` — Startup issues, subprocess not launching
- **IPCLog** → `tabby_ipc.log` — Store-GUI communication issues
- **PaintTimingLog** → `tabby_paint_timing.log` — Slow overlay rendering. Logs first paint, paint after 60s+ idle, any >100ms. Auto-trimmed to 100KB.
- **WebViewLog** → `tabby_webview_debug.log` — WebView2 config editor issues

`Store_LogError()` always logs to `tabby_store_error.log` (no config flag). `Store_LogInfo()` respects `StoreLog`.
