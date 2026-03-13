<!-- Auto-generated from CLAUDE.md + .claude/rules/ -- do not edit manually -->

# Alt-Tabby Assistant Context

## Project Summary
- AHK v2 Alt-Tab replacement focused on responsiveness and low latency
- Komorebi aware; uses workspace state to filter and label windows
- Keyboard hooks built into GUI process for minimal latency (no IPC delay)

## Guiding Constraints
- **Responsive** As absolutely responsive to user alt tab inputs as possible, above all other considerations.
- **Low CPU**: Event-driven, not busy loops. Adaptive polling when needed
- **AHK v2 only**: No v1 patterns. Use direct function refs, not `Func("Name")`
- **Named pipes for pump IPC**: EnrichmentPump subprocess for icon/process resolution. WM_COPYDATA for launcher control signals only (full restart, config apply)
- **Testing**: Run `.\tests\test.ps1 --live` to validate changes. NEVER use `powershell -Command`

---

## CRITICAL - AHK v2 Global Scoping

### Global Constants Require Declaration

Global constants at file scope are NOT automatically accessible inside functions:
```ahk
MyFunc() {
    global IPC_MSG_SNAPSHOT, IPC_MSG_PROJECTION  ; Required!
    if (type = IPC_MSG_SNAPSHOT) { ... }
}
```
**Enforcement:** The static analysis pre-gate (`check_globals.ps1`) catches missing declarations before tests run. `#Warn VarUnset, Off` remains as a safety net â€” it does NOT replace the checker.

### Cross-File Global Visibility

Variables set inside a function are NOT visible to other files, even with `global`. For globals that other files need:
```ahk
; FILE SCOPE declaration (outside any function)
global StorePipeName

; Function sets the value
_CL_InitializeDefaults() {
    global StorePipeName
    StorePipeName := "tabby_store_v1"
}
```

### IsSet() Behavior

`IsSet(Var)` returns true if assigned ANY value (including 0, false, ""). Only returns false if declared but never assigned:
```ahk
; WRONG - IsSet() returns true, uses 0 instead of fallback
global WinEventHookDebounceMs := 0

; CORRECT - IsSet() returns false until real value set
global WinEventHookDebounceMs  ; Declare without value
```

---

## Static Analysis Boundaries

### Global Ownership (`ownership.manifest`)

Read `ownership.manifest` (project root) before investigating who mutates a global. The pre-gate enforces:
- Global NOT in manifest â†’ only the declaring file mutates it (guaranteed)
- Global IS in manifest â†’ all writers are listed explicitly (guaranteed)

The declaring file is also always authorized. Stale entries are auto-removed by the pre-gate, so the manifest always reflects actual code. When adding a new cross-file mutation, add the entry to the manifest or the pre-gate will block.

When consolidating globals into Maps: only pack when ownership is uniform (all keys written by same files). Don't pack when ownership varies per key â€” it collapses precise manifest entries into one vague entry.

### Function Visibility (`_` prefix)

- `_FuncName()` = private to declaring file. Only that file may call or reference it.
- `FuncName()` = public API. Any file may call or reference it.
- To make a private function public, rename it to drop the `_` prefix.

Enforced by pre-gate. Don't create `_` functions intended for cross-file use.

---

## Query Tools (context-efficient search)

Query tools live in `tools/`. Prefer these over reading full files or grepping:
- `query_global_ownership.ps1 <globalName>` â€” who declares, writes, and reads a global. `-Generate` previews manifest diff. `-Discover` shows all coupling hotspots
- `query_function_visibility.ps1 <funcName>` â€” where defined, public/private, all callers
- `query_function.ps1 <funcName>` â€” extract full function body without loading the entire file
- `query_interface.ps1 <filename>` â€” public functions + globals for a file (like help(module))
- `query_config.ps1` â€” no args: shows section/group index. With keyword: fuzzy search. `-Section <name>`: list section. `-Usage <key>`: which files consume a config value
- `query_callchain.ps1 <funcName>` â€” call graph from a function: what it calls (or `-Reverse` for callers), to `-Depth N` levels. Primary tool for tracing code paths

Additional domain-specific query tools (ipc, timers, impact, mutations, includes, messages, state) exist in `tools/` â€” run `ls tools/query_*.ps1` to discover when needed.

For deep multi-module flow tracing, use `/trace <question>` â€” spawns an agent in separate context that uses all query tools and returns only the semantic answer.

These return semantic answers, not raw text. The work runs in PowerShell â€” only the answer enters context.

When facing a new "load big file to find small answer" pattern, consider building a query tool rather than adding a rule. Rules cost context every session; query tools cost context only when called.

---

## Git Bash Path Expansion

Git Bash converts `/param` to `C:/Program Files/Git/param`. Use double slashes:
```bash
# WRONG
AutoHotkey64.exe /ErrorStdOut script.ahk

# CORRECT
AutoHotkey64.exe //ErrorStdOut script.ahk
```
Windows batch files (`.bat`) run in cmd.exe - single slashes work there.

---

## Legacy Reference

The `legacy/` folder contains original POCs and Mocks. All ported to production - kept for reference only.

---

# AHK v2 Patterns & Pitfalls

## Syntax Rules

- Use direct function refs, not `Func("Name")` (v1 pattern)
- String comparisons: use `StrCompare()` not `<`/`>` operators
- `#Include` is compile-time only - cannot be conditional at runtime
- Producers submit Map records; store converts to Objects internally via `WL_UpsertWindow()`. Use `rec["key"]` in producer code, `rec.key` in store/GUI code
- `_WS_GetOpt()` helper handles both Map and plain Object options (polymorphic)

## No Inline Globals in Switch Cases

```ahk
; WRONG - syntax error
switch name {
    case "Foo": global Foo; return Foo
}

; CORRECT - declare at function scope
MyFunc(name) {
    global Foo, Bar, Baz
    switch name {
        case "Foo": return Foo
    }
}
```

## COM STA Message Pump Reentrancy

D2D/DXGI/DWM COM calls pump the STA message loop, dispatching timer callbacks
and keyboard hooks through AHK `Critical "On"`. Affected: BeginDraw, EndDraw,
DrawBitmap, CreateEffect, SetWindowPos, ShowWindow, DwmFlush. Assume arbitrary
callbacks fire during any COM call. Guard patterns need try/finally. Never start
blocking while-loops (e.g. frame loops) from code that may run during a paint's
STA pump â€” the loop suspends the paint quasi-thread forever (#175).
`Anim_EnsureTimer` has a deferred-start guard for this. Never do I/O
(FileAppend) in paths that fire per-STA-pump â€” 1000 pumps/paint Ã— 30ms = 30s
paint.

## Race Conditions & Critical Sections

AHK v2 timers and hotkeys CAN interrupt each other. Use `Critical "On"` for:
1. Incrementing counters: `gRev += 1`
2. Check-then-act: `if (!map.Has(k)) { map[k] := v }`
3. Map iteration during modification
4. State transitions

**Pattern for atomic operations:**
```ahk
Critical "On"
if (!gQueue.Has(hwnd)) {
    gQueue.Push(hwnd)
    gQueueDedup[hwnd] := true
}
Critical "Off"
```

**Safe Map iteration:**
```ahk
Critical "On"
handles := []
for hPipe, _ in gServer.clients
    handles.Push(hPipe)
Critical "Off"

for _, hPipe in handles
    SendToClient(hPipe, msg)
```

**Don't forget `Critical "Off"` at ALL exit points** including `continue` and early `return`.

## Avoid Static Variables in Timer Callbacks

Use tick-based timing instead of static counters that can leak state if timer is cancelled.

## One-Shot Timer Callback Corruption (CRITICAL)

Running complex nested call chains (state machine transitions, `GUI_OnInterceptorEvent`, activation) inside a one-shot `SetTimer(func, -period)` callback permanently corrupts AHK v2's timer dispatch for that function. Future `SetTimer(func, -period)` calls silently fail. Discovered in #303.

**Fix:** Defer heavy work to a fresh timer thread:
```ahk
; WRONG â€” corrupts timer dispatch for MyTimer permanently
MyTimer() {
    if (needsRecovery)
        DoComplexRecovery()  ; Nested state machine + activation
}

; CORRECT â€” timer callback returns cleanly, work runs in isolated thread
MyTimer() {
    if (needsRecovery) {
        SetTimer(DoComplexRecovery.Bind(args), -1)
        return
    }
}
```

## Hot Path Resource Rules

In frequently-called functions (paint, input, per-window loops):
- **Buffers**: Use `static` for DllCall marshal buffers repopulated via NumPut before use
- **D2D objects**: Cache brushes/fonts (see `D2D_GetCachedBrush`, `gD2D_Res`), never create+destroy per-call
- **Regex**: Pre-compile patterns at load time, not per-match (see `Blacklist_Reload`)
- **Loop constants**: Hoist `Round(N * scale)` before loops, not per-iteration

## Caller-Side Log Guards (CRITICAL)

AHK v2 evaluates all function arguments **before** the call. A guard inside the log function is too late â€” the string is already built:
```ahk
; WRONG - string built unconditionally, discarded when logging disabled
GUI_LogEvent("SKIP hwnd=" hwnd " '" title "' mode=" mode)

; CORRECT - string never built when logging disabled
if (cfg.DiagEventLog)
    GUI_LogEvent("SKIP hwnd=" hwnd " '" title "' mode=" mode)
```

Move variables computed **only for logging** inside the guard too. Keep the guard inside the log function as a safety net.

## #SingleInstance in Multi-Process Architecture

- Entry point (`alt_tabby.ahk`): `#SingleInstance Off`
- Module files: NO `#SingleInstance` directive
- This allows store + gui from same exe with different args

## Compilation

- `compile.ps1` is the build script; `compile.bat` is a thin wrapper for double-click convenience
- Flags: `--force` (skip smart-skip), `--test-mode` (machine-readable TIMING output), `--timing` (human-readable)
- Ahk2Exe requires `/base "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"`
- Embedded resources: icon via `/icon`, splash PNG via `@Ahk2Exe-AddResource`
- **Ahk2Exe `.html` embedding breaks on CSS `%` values** (RT_HTML dereferencing) â€” use `.txt` extension
- Smart-skip: compares source + resources `LastWriteTime` against exe â€” skips Ahk2Exe when exe is newer
- `FileInstall` source paths resolve relative to the file containing the directive, not the main script
- `src/lib/` files are excluded from static analysis (third-party code)

## Version Management

- Single source: `VERSION` file in project root
- Compiled: `compile.ps1` reads VERSION for Ahk2Exe flags
- Dev: `GetAppVersion()` searches up directories for VERSION file

## Anti-Flash Window Show

`GUI_AntiFlashPrepare/Reveal` in `gui_antiflash.ahk`:
- **Normal GUIs**: DWM cloaking (DWMWA_CLOAK=13) â€” zero flash
- **WebView2**: Off-screen (-32000) + WS_EX_LAYERED alpha=0 â€” cloaking crashes WebView2
- **Centering**: Raw Win32 (GetMonitorInfoW + SetWindowPos) â€” AHK `Gui.Move` has DPI scaling issues
- **Order matters**: Set alpha=255 FIRST (while still cloaked), THEN uncloak

## Compiled vs Development Paths

```ahk
if (A_IsCompiled)
    configPath := A_ScriptDir "\config.ini"
else
    configPath := A_ScriptDir "\..\config.ini"
```

---

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
- `src/lib/` - Third-party libraries only (cjson, WebView2, Direct2D, etc.). NOT `src/shared/`.
- `src/shared/window_list.ahk` - Core window data API (store, display list, dirty tracking)
- `src/shared/ipc_pipe.ahk` - Named pipe IPC (used by EnrichmentPump)
- `src/shared/config_registry.ahk` - All config definitions
- `src/shared/blacklist.ahk` - Window eligibility logic
- `src/shared/stats.ahk` - Lifetime & session usage statistics
- `src/gui/gui_main.ahk` - MainProcess init, producers, heartbeat, cleanup
- `src/gui/gui_data.ahk` - Live data layer (refresh, pre-cache, display eviction during ACTIVE)
- `src/gui/gui_activation.ahk` - Window activation engine (sync, async cross-workspace, COM uncloaking, robust Win32 activation)
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
2. WinEventHook's `WL_UpdateFields()` returns `exists: false`
3. **FIX:** When focus event comes for unknown window, check eligibility and ADD it immediately with MRU data
4. Without this fix, new windows appear at BOTTOM of Alt+Tab list

### Ghost Window Detection (CRITICAL)
Some apps (Outlook, etc.) REUSE HWNDs for temporary windows:
1. Window is added when eligible
2. App "closes" window but HWND still exists (just hidden/cloaked)
3. `IsWindow()` returns true, so standard validation doesn't remove it
4. **FIX:** `WL_ValidateExistence()` also checks `Blacklist_IsWindowEligible()`
5. Ghost windows are removed when they become ineligible

## State Machine

```
IDLE â”€â”€Alt downâ”€â”€> ALT_PENDING â”€â”€Tabâ”€â”€> ACTIVE â”€â”€Alt upâ”€â”€> IDLE
                        â”‚                  â”‚
                        â”‚ Alt up (quick)   â”‚ Escape
                        v                  v
                   (quick switch)       (cancel)
```

States: `IDLE`, `ALT_PENDING`, `ACTIVE`

## Critical Design Decisions

1. **Lock-in on first Tab** - Display list frozen when Tab pressed (not Alt). Freeze is reference-based: `gGUI_DisplayItems` holds refs to live store records. Structural stability (ordering, membership) is frozen; cosmetic fields (title, icon, processName) flow live. The list may shrink during ACTIVE (window destroys are signal, not noise) but never grows or reorders.
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
- **Array sections**: `array_section: N` on a section entry enables repeatable instances (e.g., `[Shader.1]`..`[Shader.4]`). Keys use `{N}` template expansion (e.g., `Shader{N}_ShaderName` â†’ `cfg.Shader1_ShaderName`)

## Theme System

- `src/shared/theme.ahk` + `theme_msgbox.ahk` â€” centralized dark/light mode for all native AHK GUIs
- Main overlay is excluded (has its own ARGB colors); debug viewer uses the theme system
- `Theme_Init()` must be called **before any `Gui()` constructor** (sets SetPreferredAppMode)
- `Theme_ApplyToGui(gui)` after constructor, `Theme_ApplyToControl(ctrl, type)` after each control
- `ThemeMsgBox()` is a drop-in MsgBox replacement â€” use it for all new message boxes
- WebView2 editors: `Theme_GetWebViewJS()` generates CSS custom properties
- Reacts to system theme changes via WM_SETTINGCHANGE automatically

## Flight Recorder

In-memory ring buffer (`gui_flight_recorder.ahk`) in MainProcess. `FR_Record(ev, d1..d4)` is the hot path (~1Î¼s, zero allocation â€” writes into pre-allocated array slots). F12 (configurable) dumps state snapshot + WindowList state + live items + event trace to `recorder/` folder. Events cover keyboard hooks, state machine, activation, focus tracking, workspace switches, scans, and producer init. See `docs/USING_RECORDER.md` for analysis guide.

## Stats

Stats engine (`stats.ahk`) runs in-process within MainProcess. `Stats_Accumulate()` for GUI delta counters, `Stats_FlushToDisk()` on heartbeat timer, `Stats_GetSnapshot()` for dashboard queries. Crash-safe with `.bak` sentinel pattern.

## Compositor Stack

Paint pipeline composites layers bottom-to-top in `_GUI_PaintOverlay`:

1. **DWM Surface** (unchanged)
2. **User Background Image** (`BGImg_Draw`)
3. **Shader Layers 1..N** (0-4 stackable D3D11 HLSL shaders, `FX_DrawShaderLayers`)
4. **Mouse Effect** (0-1 dedicated slot receiving cursor position, `FX_DrawMouseEffect`)
5. **Selection/Hover Effect** (shader-based or simple D2D fill, `FX_DrawSelectionEffect`)
6. **Inner Shadow + Hover** (D2D1 SoftRect chains)
7. **Window List + text** (GDI+/D2D)

Shader rendering: D3D11 pixel shaders compiled from HLSLâ†’DXBC. Each layer renders to an intermediate texture, composited via `DrawImage` with per-layer opacity. Common cbuffer (112 bytes) provides `time`, `resolution`, `iMouse`, `selRect`, `selColor`, etc. â€” see `src/shaders/alt_tabby_common.hlsl`.

Shader directories:
- `src/shaders/` â€” background shaders (stackable layers)
- `src/shaders/mouse/` â€” mouse effects (cursor tracking via `iMouse`)
- `src/shaders/selection/` â€” selection effects (row geometry + user colors via cbuffer)

Key files: `src/gui/d2d_shader.ahk` (D3D11 pipeline), `src/gui/gui_effects.ahk` (compositor), `src/gui/shader_bundle.ahk` + `src/gui/shader_resources.ahk` (auto-generated by `tools/shader_bundle.ps1`).

## Key Metrics

- Alt+Tab detection: <5ms
- GUI show after Tab: <50ms
- Quick switch: <25ms total

---

# Debug Diagnostics

All in `[Diagnostics]` section of config.ini. Disabled by default. All logs in `%TEMP%\`.

- **ChurnLog** â†’ `tabby_store_error.log` â€” Window data rev incrementing rapidly when idle
- **KomorebiLog** â†’ `tabby_ksub_diag.log` â€” Workspace tracking, CurWS not updating
- **AltTabTooltips** â†’ On-screen tooltips â€” Overlay not appearing, wrong state transitions
- **ViewerLog** (`DebugLog=true` in `[Viewer]`) â†’ `tabby_viewer.log` â€” Viewer refresh issues
- **EventLog** â†’ `tabby_events.log` â€” Rapid Alt-Tab, events lost. Pattern: missing `Tab_Down` between `Alt_Down`/`Alt_Up` = lost Tab
- **WinEventLog** â†’ `tabby_weh_focus.log` â€” Focus tracking, bypass mode problems
- **StoreLog** â†’ `tabby_store_error.log` â€” MainProcess startup, blacklist loading
- **IconPumpLog** â†’ `tabby_iconpump.log` â€” Icon resolution, cloaked windows missing icons
- **ProcPumpLog** â†’ `tabby_procpump.log` â€” Process name resolution failures
- **LauncherLog** â†’ `tabby_launcher.log` â€” Startup issues, subprocess not launching
- **IPCLog** â†’ `tabby_ipc.log` â€” Pump IPC communication issues
- **PaintTimingLog** â†’ `tabby_paint_timing.log` â€” Slow overlay rendering. Logs first paint, paint after 60s+ idle, any >100ms. Auto-trimmed to 100KB.
- **WebViewLog** â†’ `tabby_webview_debug.log` â€” WebView2 config editor issues
- **ShaderLog** â†’ `tabby_shader.log` â€” D3D11 shader compilation, iChannel texture loading, SRV/sampler binding

- **FlightRecorder** â†’ `recorder/fr_YYYYMMDD_HHMMSS.txt` â€” In-memory ring buffer (default 2000 events). Press F12 (configurable) to dump. Shows state snapshot, WindowList state, live items, and full event trace with hwnd resolution. Near-zero cost when enabled. Config: `FlightRecorderBufferSize` (int, 500-10000), `FlightRecorderHotkey` (string, default F12). See `docs/USING_RECORDER.md` for analysis guide.

`_GUI_LogError()` always logs to `tabby_store_error.log` (no config flag). `_GUI_LogInfo()` respects `StoreLog`.

---

# Installation & Updates

## Key Constraints

- **Admin mode**: Task Scheduler task "Alt-Tabby" with `HighestAvailable`. Only ONE installation can have admin mode (task name hardcoded). Exe self-redirects via `_ShouldRedirectToScheduledTask()`.
- **Auto-update trick**: Renames running exe to `.old` (Windows allows this), moves new exe in place, relaunches.
- **Elevation pattern**: Save state to `%TEMP%` file â†’ relaunch with `--flag` via `*RunAs` â†’ elevated instance reads state file.
- **Config path for updates**: Write to TARGET config.ini, not source.
- **Single-instance**: Named mutex "AltTabby_Launcher" â€” does NOT affect gui/pump subprocesses.

## InstallationId Recovery Rules

**Critical Design Decision**: Only recover InstallationId from existing admin task if current exe is in the SAME DIRECTORY as the task's target path.

Why this matters:
- Auto-repair (silent task update when IDs match) is useful when user renames their exe
- But ID recovery + auto-repair creates a hijacking path if recovery happens across directories
- Example: Fresh exe from Downloads would recover ID from PF install's task, then auto-repair would silently redirect task to Downloads

The fix ensures:
- Renamed exe in same directory â†’ ID recovered â†’ auto-repair works (good)
- Fresh exe in different directory â†’ new ID generated â†’ no auto-repair (safe)

---

# Keyboard Hooks & Rapid Alt-Tab

## Core Rules

- **`SendMode("Event")` is mandatory** â€” AHK's default `SendInput` temporarily uninstalls all keyboard hooks. User keypresses during that window are lost forever.
- **`Critical "On"` in all hotkey callbacks** â€” Without it, one callback can interrupt another mid-execution. Apply to: `_INT_Alt_Down/_INT_Alt_Up`, `_INT_Tab_Down/_INT_Tab_Up`, `_INT_Tab_Decide`, `_INT_Ctrl_Down`, `_INT_Escape_Down`, `GUI_OnInterceptorEvent`.
- **komorebic also uninstalls hooks** â€” `komorebic focus-named-workspace` uses SendInput internally. Fix: async activation with event buffering.

## Key Patterns

- **Async activation**: Buffer events in `gGUI_EventBuffer` while `gGUI_PendingPhase != ""`. Escape cancels pending activation.
- **Lost Tab detection**: ALT_DN + ALT_UP without TAB = Tab was lost. Synthesize it.
- **In-process MRU**: Window data lives in MainProcess â€” MRU is always authoritative, no stale snapshot risk.

## Game Mode Bypass

Disables Tab hooks when fullscreen game or blacklisted process is focused. WinEventHook sets `isFocused: true` â†’ GUI calls `INT_ShouldBypassWindow(hwnd)` â†’ `Hotkey("$*Tab", "Off")`. When focus leaves, Tab hotkeys re-enabled.

**Critical fix:** Filter windows with empty titles in WinEventHook callback â€” prevents Task Switching UI from poisoning focus tracking.

## CRITICAL: Critical Sections During Rendering (Context-Dependent)

**`GUI_OnInterceptorEvent` (hotkey handler):** Keep `Critical "On"` for the entire handler. Releasing before render caused partial glass, mapping corruption, and stale projection data. No internal abort points â€” unsafe to interrupt.

**`_GUI_GraceTimerFired` (deferred timer):** Release Critical BEFORE `_GUI_ShowOverlayWithFrozen()`. This is safe because the show path has 3 RACE FIX abort points that detect `gGUI_State != "ACTIVE"`. Keeping Critical during the 1-2s first paint exceeds Windows' `LowLevelHooksTimeout` (~300ms), causing silent hook removal â€” the original #303 bug.

**Rule of thumb:** Release Critical before heavy COM work (D2D paint, ShowWindow, DwmFlush) only when the rendering path has internal state-change abort points. Otherwise keep it held.

## Defense Stack

1. `SendMode("Event")` â€” keeps hook active
2. `Critical "On"` â€” prevents callback interruption
3. Context-dependent Critical during render (see above)
4. Async activation â€” non-blocking
5. Event buffering â€” queue during async
6. Lost Tab detection â€” synthesize if needed
7. `GetAsyncKeyState(VK_MENU)` â€” physical Alt polling detects lost hooks (#303)
8. Active-state watchdog â€” 500ms safety net catches any stuck ACTIVE (#303)

---

# Komorebi Integration

## Subscription vs Polling

- `komorebic subscribe-pipe` only receives events when things change
- Need initial poll on startup to populate existing windows
- Subscription includes BOTH event AND full state in each notification

## State Consistency (CRITICAL)

**Notification state is inconsistent** â€” snapshot taken mid-operation.

**Workspace focus events:**
- Trust EVENT content for new workspace name/index
- DON'T trust state's `ring.focused` or per-workspace focus data â€” may be stale
- Pass `skipWorkspaceUpdate=true` to ProcessFullState from notifications

**Move events:**
- Window is already on TARGET workspace in state data
- TARGET workspace focus indices ARE reliable; source workspace indices are not
- Must update focused hwnd cache for target workspace BEFORE ProcessFullState runs
- Push to clients AFTER ProcessFullState completes

Use `KSafe_Str()`, `KSafe_Int()` for safe property access on event content.

## MRU During Workspace Switches

**1. Focused hwnd caching** â€” Cache per-workspace focused hwnds from RELIABLE events (`FocusChange`, `Show` where `skipWorkspaceUpdate=false`). Use cache during UNRELIABLE workspace switch events. Cache ALL workspaces at once so first-time switches have data.

**2. WinEventHook MRU suppression** â€” During ~1s transition, Windows fires `EVENT_SYSTEM_FOREGROUND` for old/intermediate windows. Suppression set IMMEDIATELY on workspace event, auto-expires after 2s. **NEVER cleared early** â€” clearing on FocusChange created a gap during rapid switching where stale WEH events triggered WS MISMATCH flip-flop and visible jiggle.

**Selection after workspace switch**: `sel=1` (not `sel=2`) â€” workspace switch is a context switch, the focused window on the NEW workspace is what you want.

## Cross-Workspace Activation

**Never manually uncloak** â€” komorebi manages cloaking.

Activation sequence: `komorebic focus-named-workspace` â†’ poll until switch â†’ SendInput trick to bypass foreground lock â†’ SetWindowPos (TOPMOST/NOTOPMOST) + SetForegroundWindow.

**Hide cmd.exe:** Use `WScript.Shell.Run(cmd, 0, true)` not `shell.Exec()`.

## Integration Testing

- Verify komorebi is running: `komorebic state`
- Test data flow end-to-end: komorebi â†’ producer â†’ store â†’ viewer
- Tests should START the store, not assume it's running

---

# Testing Guidelines

## Running Tests

```powershell
.\tests\test.ps1 --live
```

**Flags:** `--live` (integration tests), `--force-compile` (force recompilation), `--timing` (detailed hierarchical timing report), `--invasive` (tests that disrupt the desktop, e.g., workspace switching)

**NEVER use `powershell -Command`** - it breaks argument parsing and fails hard:
```powershell
# WRONG - will exit with FATAL FAILURE
powershell -Command ".\tests\test.ps1 --live"

# RIGHT - direct invocation
.\tests\test.ps1 --live

# RIGHT - explicit powershell with -File flag
powershell -File .\tests\test.ps1 --live
```

Or run AHK directly (double-slash for Git Bash):
```
AutoHotkey64.exe //ErrorStdOut tests\run_tests.ahk --live
```

Logs: `%TEMP%\alt_tabby_tests_<worktree>.log` (unit tests). `--live` adds suite suffixes: `_core`, `_features`, `_execution`, etc.

**Pre-gate:** Static analysis (`tests/static_analysis.ps1`) runs before all tests. If any function uses a file-scope global without a `global` declaration, the suite is blocked. Fix by adding `global <name>` inside the flagged function. New checks are auto-discovered as `tests/check_*.ps1`.

**Pre-gate gates ALL test types** â€” not just unit tests. Static analysis catches AHK coding errors that pass both `/validate` AND compilation but cause **runtime dialog popups** requiring user interaction. These popups break automated test flow for any process running AHK code â€” including the compiled exe in live tests. Do NOT "optimize" by removing the pre-gate dependency for any test type.

**Pipeline dependency model:**

| Test Type | Gated By | Why |
|-----------|----------|-----|
| GUI + Unit tests | Pre-Gate only | Run AHK source directly via `#Include` |
| Live tests | Pre-Gate + Compilation | Launch compiled `AltTabby.exe` |

GUI and unit tests launch right after pre-gate passes. Live tests launch after compilation completes. When compilation finishes during pre-gate (typical), all tests launch at the same time.

## Test Architecture (CRITICAL)

**NEVER copy production code into test files** - tests become useless (test the copy, not production).

**Correct structure:**
```ahk
; 1. Define globals matching production
global gGUI_State := "IDLE"

; 2. Define MOCKS for visual/external layer BEFORE includes
GUI_Repaint() { }
GUI_HideOverlay() { global gGUI_OverlayVisible; gGUI_OverlayVisible := false }

; 3. INCLUDE production files
#Include %A_ScriptDir%\..\src\gui\gui_state.ahk

; 4. Tests call REAL production functions
```

**What to mock vs include:**
- Mock: Visual rendering, IPC sending, DWM calls, GUI objects
- Include: State machine logic, data transformation, business rules

**Verify tests work:** Break a production function intentionally - tests should fail.

## Test Data Format

```ahk
; WRONG - uppercase keys
items.Push({ Title: "Win1" })

; CORRECT - lowercase matches JSON from store
items.Push({ title: "Win1", class: "MyClass", lastActivatedTick: A_TickCount })
```

## Coverage Requirements

- Unit tests for core functions
- IPC integration (server <-> client)
- Real store integration
- Komorebi integration
- Heartbeat test
- Blacklist E2E test
- GUI state machine tests (`tests/gui_tests.ahk`)

## GUI Tests

Run separately:
```
AutoHotkey64.exe //ErrorStdOut tests\gui_tests.ahk
```
Tests state transitions, freeze behavior, workspace toggle, config combinations.

## Test Patterns

- **Poll, don't sleep** â€” Use `WaitForFlag(&flag)` from `test_utils.ahk`, not fixed `Sleep()`. Adaptive polling exits as soon as data arrives.
- **Process launching** â€” Use `_Test_RunSilent(cmdLine)` from `test_utils.ahk`. Handles cursor suppression and cleanup.

## Performance Benchmarking

`tests/bench_unit_split.ps1` â€” Measures AHK startup overhead and per-file unit test times to evaluate parallel split strategies. Run when considering changes to test parallelization.

## Trust Test Failures

- Don't dismiss as "timing issues" - investigate root cause
- Tests passed before, fail after = your change broke something
- Multiple failures with same pattern = common root cause

---

# Workflow

## GitHub Issues for Non-Trivial Work

When the approved plan involves multi-file changes, new features, or investigation-driven fixes: create a GitHub issue before implementation. Simple fixes (typos, one-liners, obvious bugs) go straight to PR.

**Issue content** â€” distill the plan to:
- Problem/goal (one sentence)
- Action items (only the surviving TODOs)
- Key decisions (non-obvious choices, one line each)

Omit investigation notes, rejected candidates, and false positives. PR references `Closes #N`.

## Worktree Agents

All file edits and new files must stay within your worktree. Never modify files in the main checkout or other worktrees.
Live tests (`--live`) are worktree-safe: scoped process kills, isolated pipes/mutexes, worktree-prefixed logs.
