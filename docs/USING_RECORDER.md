# Flight Recorder — Analysis Guide

The flight recorder is an always-on, in-memory ring buffer that captures the last ~2000 events (configurable) from Alt-Tabby's keyboard hook, state machine, activation logic, focus tracking, and workspace management. When the user presses the dump hotkey (F12 by default), it dumps everything to a timestamped file for analysis.

## Enabling

`[Diagnostics] FlightRecorder=true` in config.ini (default: enabled).

When enabled, the dump hotkey is registered (pass-through — the key still works in other apps). When disabled, no memory is allocated and no hotkey exists.

### Config Options

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `FlightRecorder` | bool | true | Enable/disable the flight recorder |
| `FlightRecorderBufferSize` | int | 2000 | Ring buffer size (500–10000). 2000 ≈ 30s of typical activity. |
| `FlightRecorderHotkey` | string | F12 | Dump hotkey (AHK v2 syntax, e.g. `F12`, `^F12`, `+F11`) |

## Triggering a Dump

Press the dump hotkey (**F12** by default) immediately after experiencing a problem. An InputBox appears for an optional note describing what happened. The dump is saved to the `recorder/` folder (next to the exe or project root in dev mode).

Each dump is a separate file: `fr_YYYYMMDD_HHMMSS.txt`

## Performance Impact

Near-zero. Each event is a single array-index write (~1 microsecond). No string formatting, no file I/O, no conditionals beyond the `gFR_Enabled` check. The dump (file write + hwnd resolution) only happens on F12.

## Reading a Dump File

Each dump has three sections:

### 1. Global State Snapshot

Captured atomically at dump time. Shows the state of every relevant global variable:

- **GUI State** — `IDLE`, `ALT_PENDING`, or `ACTIVE`
- **gINT_SessionActive** — whether an Alt-Tab session is in progress
- **gINT_BypassMode** — whether Tab hooks are disabled (fullscreen/game bypass)
- **gINT_AltIsDown / TabPending / TabHeld** — keyboard hook state
- **gGUI_PendingPhase** — async cross-workspace activation state (`""` = none)
- **Foreground Window** — what Windows considers the active window at dump time

### 2. Window List State

Shows the internal state of the WindowList data layer:

- **gWS_Rev** — current revision counter (increments on every change)
- **gWS_Store.Count** — number of tracked windows
- **SortOrderDirty / ContentDirty / MRUBumpOnly** — dirty flags indicating pending updates
- **DirtyHwnds.Count** — number of hwnds with pending cosmetic changes
- **IconQueue / PidQueue / ZQueue lengths** — enrichment work queues

### 3. Live Items

The current window list as Alt-Tabby knows it. Shows hwnd, title, process name, workspace, and whether it's on the current workspace. This is what the user would see if they pressed Alt-Tab right now.

### 4. Event Trace

Chronological (newest first) list of events with millisecond timestamps relative to the dump time. This is the core diagnostic data.

## Event Reference

### Interceptor Events (keyboard hooks)

| Event | Fields | Meaning |
|-------|--------|---------|
| `ALT_DN` | session | Alt key pressed. session=1 means a session was already active. |
| `ALT_UP` | session, presses, tabPending, async | Alt key released. presses=0 means no Tab was pressed. |
| `TAB_DN` | session, altDown, pending, held | Tab key pressed. altDown=0 means Alt wasn't held (shouldn't fire). |
| `TAB_UP` | held | Tab key released. |
| `TAB_DECIDE` | altDown, altUpFlag | Timer fired to decide if Tab was Alt+Tab or standalone. |
| `TAB_DECIDE_INNER` | isAltTab, altDown, altUpFlag, altRecent | Decision made. isAltTab=1 means it was an Alt+Tab. |
| `ESC` | session, presses | Escape pressed. |
| `BYPASS` | ON/OFF | Tab hooks enabled/disabled (fullscreen detection). |

### State Machine Events

| Event | Fields | Meaning |
|-------|--------|---------|
| `STATE` | -> IDLE/ALT_PENDING/ACTIVE | State transition. |
| `FREEZE` | items, sel | Display items frozen for overlay. sel=selection index. |
| `GRACE_FIRE` | state, visible | Grace timer fired (delayed overlay show). |
| `QUICK_SWITCH` | timeSinceTab | Alt released quickly — no overlay, direct switch. |
| `ACTIVATE_START` | hwnd, onCurrentWS | Activation attempt beginning. |
| `ACTIVATE_RESULT` | hwnd, success, fg | Activation outcome. success: 0=failed (fg is a different window), 1=confirmed, 2=transitional (fg was NULL during activation transition — treated as success). |
| `ACTIVATE_GONE` | hwnd | Selected window no longer exists at activation time. |
| `MRU_UPDATE` | hwnd, result | Local MRU reorder after activation. result=0 means hwnd not found. |
| `BUFFER_PUSH` | event, bufLen | Event buffered during async activation. |

### Focus & Workspace Events

| Event | Fields | Meaning |
|-------|--------|---------|
| `FOCUS` | hwnd | WinEventHook detected a new foreground window. |
| `FOCUS_SUPPRESS` | hwnd, remainingMs | Focus event suppressed (komorebi workspace transition). remainingMs = time until suppression expires. |
| `WS_SWITCH` | | Komorebi workspace switch detected. |
| `WS_TOGGLE` | newMode, displayCount | User toggled workspace filter. newMode: 1=all, 2=current. |

### Data Layer Events

| Event | Fields | Meaning |
|-------|--------|---------|
| `REFRESH` | items | Live items refreshed from WindowList. |
| `SCAN_COMPLETE` | foundCount, storeCount | Full window enumeration finished. foundCount=windows discovered, storeCount=total in store after scan. |
| `COSMETIC_PATCH` | patchedCount, baseCount | In-place title/icon/process update during ACTIVE state. |
| `PRODUCER_INIT` | type, success | Producer startup result. type: 1=KomorebiSub, 2=WinEventHook, 3=Pump. success: 0/1. |
| `SESSION_START` | | Flight recorder initialized (process startup). |

## Analyzing Dumps

### Correlating Events

A normal quick Alt-Tab sequence looks like:
```
ALT_DN → TAB_DN → TAB_DECIDE → TAB_DECIDE_INNER(isAltTab=1) → STATE→ACTIVE → FREEZE → ALT_UP → QUICK_SWITCH → ACTIVATE_START → ACTIVATE_RESULT(success=1) → MRU_UPDATE(result=1) → STATE→IDLE
```

Look for deviations from this pattern. Common things to check:

**Is the event chain complete?** Every ALT_DN should eventually lead to STATE→IDLE. If the chain is broken, find where it stops.

**Are there unexpected gaps?** Large time gaps between events suggest something was blocking (Critical section held too long, or a slow operation).

**What does ACTIVATE_RESULT show?** success=0 means Windows rejected the activation. The `fg` field shows what window IS foreground — this helps identify what's blocking.

**Is BYPASS mode on?** If BYPASS=ON appears, Tab hooks are disabled. No TAB_DN events will appear until BYPASS=OFF.

**Is focus being suppressed?** FOCUS_SUPPRESS events mean komorebi workspace switching is active. Focus events are ignored during the suppression window to prevent MRU corruption from transient windows.

**Is the buffer being used?** BUFFER_PUSH events mean async cross-workspace activation is in progress. Events are queued, not processed immediately.

**Are scans finding everything?** Compare SCAN_COMPLETE's foundCount with storeCount. If storeCount >> foundCount, ghost windows may be accumulating.

### Multiple Dumps

When analyzing a set of dumps, look for:
- Common patterns across failures (same event missing, same activation failure)
- Whether the same window/process is always involved
- Whether bypass mode correlates with failures
- Time-of-day patterns (system load, background processes)

### Hwnd Resolution

Hwnds in the event trace are resolved to window titles and process names at dump time. Windows that closed between the event and the dump show as `(gone)`. The Live Items section provides the authoritative mapping for currently-open windows.

## File Locations

- **Compiled**: `<exe dir>\recorder\`
- **Dev mode**: `<project root>\recorder\`
- **Config entries**: `[Diagnostics] FlightRecorder`, `FlightRecorderBufferSize`, `FlightRecorderHotkey`
- **Source**: `src/gui/gui_flight_recorder.ahk`
