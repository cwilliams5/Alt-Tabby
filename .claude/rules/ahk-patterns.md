# AHK v2 Patterns & Pitfalls

## Syntax Rules

- String comparisons: use `StrCompare()` not `<`/`>` operators
- `#Include` is compile-time only - cannot be conditional at runtime
- Producers submit Map records; store converts to Objects internally via `WL_UpsertWindow()`. Use `rec["key"]` in producer code, `rec.key` in store/GUI code
- `_WS_GetOpt()` helper handles both Map and plain Object options (polymorphic)

## COM STA Message Pump Reentrancy

D2D/DXGI/DWM COM calls pump the STA message loop, dispatching timer callbacks
and keyboard hooks through AHK `Critical "On"`. Affected: BeginDraw, EndDraw,
DrawBitmap, CreateEffect, SetWindowPos, ShowWindow, DwmFlush. Assume arbitrary
callbacks fire during any COM call. Guard patterns need try/finally. Never start
blocking while-loops (e.g. frame loops) from code that may run during a paint's
STA pump — the loop suspends the paint quasi-thread forever (#175).
`Anim_EnsureTimer` has a deferred-start guard for this. Never do I/O
(FileAppend) in paths that fire per-STA-pump — 1000 pumps/paint × 30ms = 30s
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

## One-Shot Timer Callback Corruption (CRITICAL)

Running complex nested call chains (state machine transitions, `GUI_OnInterceptorEvent`, activation) inside a one-shot `SetTimer(func, -period)` callback permanently corrupts AHK v2's timer dispatch for that function. Future `SetTimer(func, -period)` calls silently fail. Discovered in #303.

**Fix:** Defer heavy work to a fresh timer thread:
```ahk
; WRONG — corrupts timer dispatch for MyTimer permanently
MyTimer() {
    if (needsRecovery)
        DoComplexRecovery()  ; Nested state machine + activation
}

; CORRECT — timer callback returns cleanly, work runs in isolated thread
MyTimer() {
    if (needsRecovery) {
        SetTimer(DoComplexRecovery.Bind(args), -1)
        return
    }
}
```

## Hot Path Resource Rules

In frequently-called functions (paint, input, per-window loops):
- **Buffers**: Use `static` for DllCall marshal buffers repopulated via NumPut before use.
    Exception: NOT in functions reachable during STA pump (paint, COM callers, QPC) — reentrancy overwrites the buffer mid-use. Use local `Buffer()` there.
- **GPU buffers**: Keep `Float()` on `NumPut("float", ...)` for D2D/D3D buffers — type safety, not redundancy
- **D2D objects**: Cache brushes/fonts (see `D2D_GetCachedBrush`, `gD2D_Res`), never create+destroy per-call
- **Regex**: Pre-compile patterns at load time, not per-match (see `_Blacklist_Reload`)
- **Loop constants**: Hoist `Round(N * scale)` before loops, not per-iteration

## Caller-Side Log Guards

AHK v2 evaluates all function arguments **before** the call. A guard inside the log function is too late — the string is already built. Move variables computed **only for logging** inside the guard too. Enforced by `log_guards` check.

## Compilation

- `tools/compile.ps1` is the build script; `compile.bat` is a thin wrapper for double-click convenience
- Flags: `--force` (skip smart-skip), `--test-mode` (machine-readable TIMING output), `--timing` (human-readable)
- Ahk2Exe requires `/base "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"`
- Embedded resources: icon via `/icon`, splash PNG via `@Ahk2Exe-AddResource`
- **Ahk2Exe `.html` embedding breaks on CSS `%` values** (RT_HTML dereferencing) — use `.txt` extension
- Smart-skip: compares source + resources `LastWriteTime` against exe — skips Ahk2Exe when exe is newer
- `FileInstall` source paths resolve relative to the file containing the directive, not the main script
- `src/lib/` files are excluded from static analysis (third-party code)

## Version Management

- Single source: `VERSION` file in project root
- Compiled: `tools/compile.ps1` reads VERSION for Ahk2Exe flags
- Dev: `GetAppVersion()` searches up directories for VERSION file

## Anti-Flash Window Show

`GUI_AntiFlashPrepare/Reveal` in `gui_antiflash.ahk`:
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
