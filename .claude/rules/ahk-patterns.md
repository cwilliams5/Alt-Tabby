# AHK v2 Patterns & Pitfalls

## Syntax Rules

- Use direct function refs, not `Func("Name")` (v1 pattern)
- String comparisons: use `StrCompare()` not `<`/`>` operators
- `#Include` is compile-time only - cannot be conditional at runtime
- Store expects Map records from producers: use `rec["key"]` not `rec.key`
- `_WS_GetOpt()` helper handles both Map and plain Object options

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

## Hot Path Resource Rules

In frequently-called functions (paint, input, per-window loops):
- **Buffers**: Use `static` for DllCall marshal buffers repopulated via NumPut before use
- **GDI+ objects**: Cache brushes/pens/fonts (see `Gdip_GetCachedBrush`, `gGdip_Res`), never create+destroy per-call
- **Regex**: Pre-compile patterns at load time, not per-match (see `Blacklist_Reload`)
- **Loop constants**: Hoist `Round(N * scale)` before loops, not per-iteration

## Caller-Side Log Guards (CRITICAL)

AHK v2 evaluates all function arguments **before** the call. A guard inside the log function is too late — the string is already built:
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
- **Ahk2Exe `.html` embedding breaks on CSS `%` values** (RT_HTML dereferencing) — use `.txt` extension
- Smart-skip: compares source + resources `LastWriteTime` against exe — skips Ahk2Exe when exe is newer
- `FileInstall` source paths resolve relative to the file containing the directive, not the main script
- `src/lib/` files are excluded from static analysis (third-party code)

## Version Management

- Single source: `VERSION` file in project root
- Compiled: `compile.ps1` reads VERSION for Ahk2Exe flags
- Dev: `GetAppVersion()` searches up directories for VERSION file

## Anti-Flash Window Show

`_GUI_AntiFlashPrepare/Reveal` in `gui_antiflash.ahk`:
- **Normal GUIs**: DWM cloaking (DWMWA_CLOAK=13) — zero flash
- **WebView2**: Off-screen (-32000) + WS_EX_LAYERED alpha=0 — cloaking crashes WebView2
- **Centering**: Raw Win32 (GetMonitorInfoW + SetWindowPos) — AHK `Gui.Move` has DPI scaling issues
- **Order matters**: Set alpha=255 FIRST (while still cloaked), THEN uncloak

## Compiled vs Development Paths

```ahk
if (A_IsCompiled)
    configPath := A_ScriptDir "\config.ini"
else
    configPath := A_ScriptDir "\..\config.ini"
```
