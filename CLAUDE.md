# Alt-Tabby Assistant Context

## Project Summary
- AHK v2 Alt-Tab replacement focused on responsiveness and low latency
- Komorebi aware; uses workspace state to filter and label windows
- Keyboard hooks built into GUI process for minimal latency (no IPC delay)

## Guiding Constraints
- **Responsive** As absolutely responsive to user alt tab inputs as possible, above all other considerations.
- **Low CPU**: Event-driven, not busy loops. Adaptive polling when needed
- **AHK v2 only**: No v1 patterns. Use direct function refs, not `Func("Name")`
- **Named pipes for data IPC**: Multi-subscriber support. WM_COPYDATA for launcher control signals only (store restart, config apply)
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
**Enforcement:** The static analysis pre-gate (`check_globals.ps1`) catches missing declarations before tests run. `#Warn VarUnset, Off` remains as a safety net — it does NOT replace the checker.

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

## Trust Test Failures

- **Don't dismiss as "timing issues"** - investigate root cause
- Tests passed before, fail after = your change broke something
- Multiple failures with same pattern = common root cause
- The test suite exists to catch issues - trust it

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

## Release Packaging

- **NEVER create GitHub release without explicit user request**
- Before release: clean working tree, run FULL test suite
- Update `VERSION` file, run `compile.bat` (thin wrapper for `compile.ps1`)
- Upload `release/AltTabby.exe` directly (no zip)
- Asset MUST be named `AltTabby.exe` (auto-update depends on this)
- Do NOT include `config.ini` or `blacklist.txt` or 'stats.ini'
- Create a summary of changes and whats new
- Have a specific Full Changelog linking the compare like compare/v0.8.4...v0.8.5

---

## Testing

```powershell
.\tests\test.ps1 --live
```

**NEVER use `powershell -Command`** - it breaks argument parsing and the test will fail:
```powershell
# RIGHT - direct invocation
.\tests\test.ps1 --live

# RIGHT - if you must use powershell explicitly
powershell -File .\tests\test.ps1 --live
```

Or run AHK directly (double-slash for Git Bash):
```
AutoHotkey64.exe //ErrorStdOut tests\run_tests.ahk --live
```

Log: `%TEMP%\alt_tabby_tests.log`

GUI tests: `AutoHotkey64.exe //ErrorStdOut tests\gui_tests.ahk`

**Never suppress output** - piping to `Out-Null` breaks child process spawning.

---

## Legacy Reference

The `legacy/` folder contains original POCs and Mocks. All ported to production - kept for reference only.

---

## Additional Context

**Updating this file:** Main CLAUDE.md is for "tattoo" rules needed in every session. Domain-specific lessons go in `.claude/rules/`. Before adding anything, ask: "Would removing this cause Claude to make mistakes?"

See `.claude/rules/` for domain-specific knowledge:

| File | Contents |
|------|----------|
| `ahk-patterns.md` | AHK v2 syntax, race conditions, Critical sections, compilation |
| `architecture.md` | Process roles, producers, state machine, config system |
| `testing.md` | Test architecture, mocking patterns, coverage requirements |
| `komorebi.md` | Komorebi integration, cross-workspace activation |
| `keyboard-hooks.md` | Rapid Alt-Tab, SendMode, hook preservation, bypass mode |
| `installation.md` | Wizard, auto-update, elevation, admin mode |
| `debugging.md` | All debug options with file paths and use cases |
