# Installation & Updates

## Key Constraints

- **Admin mode**: Task Scheduler task "Alt-Tabby" with `HighestAvailable`. Only ONE installation can have admin mode (task name hardcoded). Exe self-redirects via `_ShouldRedirectToScheduledTask()`.
- **Auto-update trick**: Renames running exe to `.old` (Windows allows this), moves new exe in place, relaunches.
- **Elevation pattern**: Save state to `%TEMP%` file → relaunch with `--flag` via `*RunAs` → elevated instance reads state file.
- **Config path for updates**: Write to TARGET config.ini, not source.
- **Single-instance**: Named mutex "AltTabby_Launcher" — does NOT affect gui/pump subprocesses.

## InstallationId Recovery Rules

**Critical Design Decision**: Only recover InstallationId from existing admin task if current exe is in the SAME DIRECTORY as the task's target path.

Why this matters:
- Auto-repair (silent task update when IDs match) is useful when user renames their exe
- But ID recovery + auto-repair creates a hijacking path if recovery happens across directories
- Example: Fresh exe from Downloads would recover ID from PF install's task, then auto-repair would silently redirect task to Downloads

The fix ensures:
- Renamed exe in same directory → ID recovered → auto-repair works (good)
- Fresh exe in different directory → new ID generated → no auto-repair (safe)
