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
    gQueueSet[hwnd] := true
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

## #SingleInstance in Multi-Process Architecture

- Entry point (`alt_tabby.ahk`): `#SingleInstance Off`
- Module files: NO `#SingleInstance` directive
- This allows store + gui from same exe with different args

## Compilation

- Use `compile.bat` (cmd.exe, single slashes)
- Ahk2Exe requires `/base "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"`
- Embedded resources: icon via `/icon`, splash PNG via `@Ahk2Exe-AddResource`

## Version Management

- Single source: `VERSION` file in project root
- Compiled: `compile.bat` reads VERSION for Ahk2Exe flags
- Dev: `GetAppVersion()` searches up directories for VERSION file

## Compiled vs Development Paths

```ahk
if (A_IsCompiled)
    configPath := A_ScriptDir "\config.ini"
else
    configPath := A_ScriptDir "\..\config.ini"
```
