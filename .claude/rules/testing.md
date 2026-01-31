# Testing Guidelines

## Running Tests

```powershell
.\tests\test.ps1 --live
```

**Flags:** `--live` (integration tests), `--force-compile` (force recompilation), `--timing` (detailed hierarchical timing report)

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

Logs: `%TEMP%\alt_tabby_tests.log` (unit tests). `--live` runs suites in parallel with separate logs: `alt_tabby_tests_core.log`, `alt_tabby_tests_features.log`, `alt_tabby_tests_execution.log`

**Pre-gate:** Static analysis (`tests/static_analysis.ps1`) runs before all tests. If any function uses a file-scope global without a `global` declaration, the suite is blocked. Fix by adding `global <name>` inside the flagged function. New checks are auto-discovered as `tests/check_*.ps1`.

**Pre-gate gates ALL test types** — not just unit tests. Static analysis catches AHK coding errors that pass both `/validate` AND compilation but cause **runtime dialog popups** requiring user interaction. These popups break automated test flow for any process running AHK code — including the compiled exe in live tests. Do NOT "optimize" by removing the pre-gate dependency for any test type.

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

- **Poll, don't sleep** — Use `WaitForFlag(&flag)` / `WaitForStorePipe(name)` from `test_utils.ahk`, not fixed `Sleep()`. Adaptive polling exits as soon as data arrives.
- **Process launching** — Use `LaunchTestStore(pipeName)` and `_Test_RunSilent(cmdLine)` from `test_utils.ahk`. These handle cursor suppression and cleanup.

## Performance Benchmarking

`tests/bench_unit_split.ps1` — Measures AHK startup overhead and per-file unit test times to evaluate parallel split strategies. Run when considering changes to test parallelization.

## Trust Test Failures

- Don't dismiss as "timing issues" - investigate root cause
- Tests passed before, fail after = your change broke something
- Multiple failures with same pattern = common root cause
