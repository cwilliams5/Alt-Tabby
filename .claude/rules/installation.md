# Installation & Updates

## First-Run Wizard

Triggered when `cfg.SetupFirstRunCompleted` is false. Options:
1. Add to Start Menu
2. Run at Startup (default checked)
3. Install to Program Files
4. Run as Administrator
5. Auto-check updates (default checked)

## Self-Elevation

When "Install to Program Files" or "Run as Administrator" selected:
1. Wizard saves choices to `%TEMP%\alttabby_wizard.json`
2. Re-launches with `--wizard-continue` via `*RunAs`
3. Elevated instance applies choices and continues

## Task Scheduler Admin Mode

- Creates task "Alt-Tabby" with `HighestAvailable` run level
- Shortcuts point to exe (not schtasks) for correct icon
- Exe self-redirects via `_ShouldRedirectToScheduledTask()`
- No UAC prompts after initial setup

**Limitation:** Only ONE installation can have admin mode enabled (task name is hardcoded).

## Auto-Update System

1. `CheckForUpdates()` fetches GitHub API
2. Compares versions with `CompareVersions()`
3. Downloads `AltTabby.exe` to `%TEMP%`
4. Renames running exe to `.old` (Windows allows this)
5. Moves new exe to target location
6. Launches new exe and exits

**Elevation:** If write fails (Program Files), saves state to `%TEMP%\alttabby_update.txt` and re-launches with `--apply-update` via `*RunAs`.

**Config path for updates:** When updating from different location, write to TARGET config.ini, not source.

## Single-Instance Detection

Launcher uses named mutex "AltTabby_Launcher":
- If exists: "Already running. Restart?" dialog
- Mutex auto-released on exit/crash
- Does NOT affect store/gui subprocesses

## Installation Mismatch

Detects running exe from different location than installed:
- Newer version running: Offer to update installed
- Same/older: Offer to launch installed version instead
- If user chooses "No" or "Always run from here", offers to close running installed instance

## InstallationId Recovery Rules

**Critical Design Decision**: Only recover InstallationId from existing admin task if current exe is in the SAME DIRECTORY as the task's target path.

Why this matters:
- Auto-repair (silent task update when IDs match) is useful when user renames their exe
- But ID recovery + auto-repair creates a hijacking path if recovery happens across directories
- Example: Fresh exe from Downloads would recover ID from PF install's task, then auto-repair would silently redirect task to Downloads

The fix ensures:
- Renamed exe in same directory → ID recovered → auto-repair works (good)
- Fresh exe in different directory → new ID generated → no auto-repair (safe)
