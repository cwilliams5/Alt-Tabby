# Testing Guidelines

## Running Tests

```powershell
.\tests\test.ps1 --live
```

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

Log: `%TEMP%\alt_tabby_tests.log`

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

## Trust Test Failures

- Don't dismiss as "timing issues" - investigate root cause
- Tests passed before, fail after = your change broke something
- Multiple failures with same pattern = common root cause
