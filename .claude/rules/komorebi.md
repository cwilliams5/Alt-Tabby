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
