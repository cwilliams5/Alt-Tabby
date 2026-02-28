# Debug Diagnostics

All in `[Diagnostics]` section of config.ini. Disabled by default. All logs in `%TEMP%\`.

- **ChurnLog** → `tabby_store_error.log` — Window data rev incrementing rapidly when idle
- **KomorebiLog** → `tabby_ksub_diag.log` — Workspace tracking, CurWS not updating
- **AltTabTooltips** → On-screen tooltips — Overlay not appearing, wrong state transitions
- **ViewerLog** (`DebugLog=true` in `[Viewer]`) → `tabby_viewer.log` — Viewer refresh issues
- **EventLog** → `tabby_events.log` — Rapid Alt-Tab, events lost. Pattern: missing `Tab_Down` between `Alt_Down`/`Alt_Up` = lost Tab
- **WinEventLog** → `tabby_weh_focus.log` — Focus tracking, bypass mode problems
- **StoreLog** → `tabby_store_error.log` — MainProcess startup, blacklist loading
- **IconPumpLog** → `tabby_iconpump.log` — Icon resolution, cloaked windows missing icons
- **ProcPumpLog** → `tabby_procpump.log` — Process name resolution failures
- **LauncherLog** → `tabby_launcher.log` — Startup issues, subprocess not launching
- **IPCLog** → `tabby_ipc.log` — Pump IPC communication issues
- **PaintTimingLog** → `tabby_paint_timing.log` — Slow overlay rendering. Logs first paint, paint after 60s+ idle, any >100ms. Auto-trimmed to 100KB.
- **WebViewLog** → `tabby_webview_debug.log` — WebView2 config editor issues
- **ShaderLog** → `tabby_shader.log` — D3D11 shader compilation, iChannel texture loading, SRV/sampler binding

- **FlightRecorder** → `recorder/fr_YYYYMMDD_HHMMSS.txt` — In-memory ring buffer (default 2000 events ≈ 30s). Press F12 (configurable) to dump. Shows state snapshot, WindowList state, live items, and full event trace with hwnd resolution. Near-zero cost when enabled. Config: `FlightRecorderBufferSize` (int, 500-10000), `FlightRecorderHotkey` (string, default F12). See `docs/USING_RECORDER.md` for analysis guide.

`_GUI_LogError()` always logs to `tabby_store_error.log` (no config flag). `_GUI_LogInfo()` respects `StoreLog`.
