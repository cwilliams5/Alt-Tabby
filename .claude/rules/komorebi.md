# Komorebi Integration

## Subscription vs Polling

- `komorebic subscribe-pipe` only receives events when things change
- Need initial poll on startup to populate existing windows
- Subscription includes BOTH event AND full state in each notification

## State Consistency (CRITICAL)

**Notification state is inconsistent** — snapshot taken mid-operation.

**Workspace focus events:**
- Trust EVENT content for new workspace name/index
- DON'T trust state's `ring.focused` or per-workspace focus data — may be stale
- Pass `skipWorkspaceUpdate=true` to ProcessFullState from notifications

**Move events:**
- Window is already on TARGET workspace in state data
- TARGET workspace focus indices ARE reliable; source workspace indices are not
- Must update focused hwnd cache for target workspace BEFORE ProcessFullState runs
- Push to clients AFTER ProcessFullState completes

Use `KSafe_Str()`, `KSafe_Int()` for safe property access on event content.

## MRU During Workspace Switches

**1. Focused hwnd caching** — Cache per-workspace focused hwnds from RELIABLE events (`FocusChange`, `Show` where `skipWorkspaceUpdate=false`). Use cache during UNRELIABLE workspace switch events. Cache ALL workspaces at once so first-time switches have data.

**2. WinEventHook MRU suppression** — During ~1s transition, Windows fires `EVENT_SYSTEM_FOREGROUND` for old/intermediate windows. Suppression set IMMEDIATELY on workspace event, auto-expires after 2s. **NEVER cleared early** — clearing on FocusChange created a gap during rapid switching where stale WEH events triggered WS MISMATCH flip-flop and visible jiggle.

**Selection after workspace switch**: `sel=1` (not `sel=2`) — workspace switch is a context switch, the focused window on the NEW workspace is what you want.

## Cross-Workspace Activation

**Never manually uncloak** — komorebi manages cloaking.

Activation sequence: `komorebic focus-named-workspace` → poll until switch → SendInput trick to bypass foreground lock → SetWindowPos (TOPMOST/NOTOPMOST) + SetForegroundWindow.

**Hide cmd.exe:** Use `WScript.Shell.Run(cmd, 0, true)` not `shell.Exec()`.

## Integration Testing

- Verify komorebi is running: `komorebic state`
- Test data flow end-to-end: komorebi → producer → store → viewer
- Tests should START the store, not assume it's running
