# Flight Recorder — Analysis Guide

The flight recorder is an always-on, in-memory ring buffer that captures the last ~2000 events from Alt-Tabby's keyboard hook, state machine, activation logic, and IPC layer. When the user presses F12, it dumps everything to a timestamped file for analysis.

## Enabling

`[Diagnostics] FlightRecorder=true` in config.ini (default: enabled).

When enabled, the F12 hotkey is registered (pass-through — F12 still works in other apps). When disabled, no memory is allocated and no hotkey exists.

## Triggering a Dump

Press **F12** immediately after experiencing a problem. An InputBox appears for an optional note describing what happened. The dump is saved to the `recorder/` folder (next to the exe or project root in dev mode).

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
- **LastLocalMRUTick** — age of last local MRU update (freshness guard)
- **Foreground Window** — what Windows considers the active window at dump time

### 2. Live Items

The current window list as Alt-Tabby knows it. Shows hwnd, title, process name, workspace, and whether it's on the current workspace. This is what the user would see if they pressed Alt-Tab right now.

### 3. Event Trace

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
| `MRU_UPDATE` | hwnd, result | Local MRU reorder after activation. result=0 means hwnd not found. |
| `BUFFER_PUSH` | event, bufLen | Event buffered during async activation. |
| `PREWARM_SKIP` | mruAge | Prewarm snapshot skipped because local MRU is fresh. |
| `FG_RECONCILE` | hwnd, wasPos | External focus change detected at Alt press. Foreground window was at position `wasPos` in MRU, moved to #1. Fixes race where taskbar/mouse clicks haven't arrived as store deltas yet. |

### IPC Events (store communication)

| Event | Fields | Meaning |
|-------|--------|---------|
| `SNAPSHOT_REQ` | | Requested snapshot from store. |
| `SNAPSHOT_RECV` | items | Received snapshot with N items. |
| `SNAPSHOT_SKIP` | reason | Snapshot rejected. reason: frozen/async_pending/mru_fresh |
| `SNAPSHOT_TOP` | hwnd1, hwnd2, hwnd3 | Top 3 MRU items after accepting a snapshot. Helps diagnose MRU corruption from store data. |
| `DELTA_RECV` | mruChanged, memberChanged, focusHwnd | Incremental update received. |

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

**Are snapshots being skipped?** SNAPSHOT_SKIP with reason=mru_fresh means the freshness guard is blocking store data. Check the PREWARM_SKIP mruAge to see how stale the local MRU is.

**Is the buffer being used?** BUFFER_PUSH events mean async cross-workspace activation is in progress. Events are queued, not processed immediately.

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
- **Config entry**: `[Diagnostics] FlightRecorder` (`cfg.DiagFlightRecorder`)
- **Source**: `src/gui/gui_flight_recorder.ahk`
