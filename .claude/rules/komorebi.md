# Komorebi Integration

## Subscription vs Polling

- `komorebic subscribe-pipe` only receives events when things change
- Need initial poll on startup to populate existing windows
- Subscription includes BOTH event AND full state in each notification

## State Consistency (CRITICAL)

**Notification state is inconsistent** - snapshot taken mid-operation.

For workspace focus events:
- Trust EVENT content for new workspace name/index
- DON'T trust state's `ring.focused` - may be stale
- DON'T trust per-workspace container/window focus data either (e.g., Spotify reported as Main's focused window during a Media→Main switch)
- Pass `skipWorkspaceUpdate=true` to ProcessFullState from notifications

For move events:
- Window is already on TARGET workspace in state data
- Focus indices on source workspace point to OTHER windows
- Let ProcessFullState handle window updates by scanning ALL workspaces

**Push AFTER ProcessFullState:**
```ahk
_KSub_ProcessFullState(stateObj, true)
try Store_PushToClients()  ; Critical!
```

## Event Content Extraction

Notifications are parsed once with `JSON.Load(jsonLine)` at the top of `_KSub_OnNotification`.
Content is accessed via `eventObj["content"]` — cJson returns the correct AHK type automatically:
- Array: `[1, 2]` -> AHK Array
- String: `"WorkspaceName"` -> AHK String
- Integer: `1` -> AHK Integer
- Object: `{"EventType": 1}` -> AHK Map

No manual type detection needed. Use `_KSafe_Str()`, `_KSafe_Int()` for safe property access.

## MRU During Workspace Switches

Two defenses prevent wrong MRU ordering during workspace switches:

**1. Focused hwnd caching** (`_KSub_FocusedHwndByWS`):
- State snapshot is unreliable during `FocusWorkspaceNumber` events (ALL focus data is stale, not just ring indices)
- Cache per-workspace focused hwnds from RELIABLE events (`FocusChange`, `Show` — where `skipWorkspaceUpdate=false`)
- Use cache during UNRELIABLE workspace switch events (`skipWorkspaceUpdate=true`)
- Cache ALL workspaces at once so first-time switches have data

**2. WinEventHook MRU suppression** (`gKSub_MruSuppressUntilTick`):
- During ~1s transition, Windows fires `EVENT_SYSTEM_FOREGROUND` for old/intermediate windows
- WinEventHook would give wrong window a newer MRU tick AND trigger WS MISMATCH correction
- Suppression set IMMEDIATELY on workspace event (first line, wrapped in Critical to prevent WEH's `-1` timer from interrupting)
- NEVER cleared early (not even on FocusChange) — always auto-expires after 2s
- Clearing on FocusChange created a gap during rapid switching where stale WEH events fired unsuppressed, triggering WS MISMATCH flip-flop and visible jiggle
- Komorebi handles MRU through the focused hwnd cache, so WEH suppression is harmless

**Selection after workspace switch** (`gui_workspace.ahk`):
- `sel=1` (not `sel=2`) because workspace switch is a context switch — the focused window on the NEW workspace IS what you want
- Applies in BOTH "current" and "all" workspace modes

## Cross-Workspace Activation

**Never manually uncloak** - komorebi manages cloaking.

Solution (in `gui_state.ahk:GUI_ActivateItem`):
1. Run `komorebic focus-named-workspace`
2. Poll `query focused-workspace-name` until workspace switches
3. Use SendInput trick to bypass foreground lock
4. SetWindowPos (TOPMOST then NOTOPMOST) + SetForegroundWindow

**Hide cmd.exe:** Use `WScript.Shell.Run(cmd, 0, true)` not `shell.Exec()`.

## Integration Testing

- Verify komorebi is running: `komorebic state`
- Test data flow end-to-end: komorebi -> producer -> store -> viewer
- Tests should START the store, not assume it's running
