#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; g_TestingMode and other globals come from alt_tabby.ahk

; ============================================================
; Launcher Main - Core Init & Subprocess Management
; ============================================================
; Main entry point for launcher mode. Orchestrates startup:
; mutex, mismatch check, wizard, splash, subprocess launch.

; Launcher mutex global
global g_LauncherMutex := 0

; Win32 error code
global ERROR_ALREADY_EXISTS := 183

; ========================= DEBUG LOGGING =========================
; Controlled by cfg.DiagLauncherLog (config.ini [Diagnostics] LauncherLog=true)
; Log file: %TEMP%\tabby_launcher.log

_Launcher_Log(msg) {
    global cfg, LOG_PATH_LAUNCHER
    if (!cfg.DiagLauncherLog)
        return
    try {
        LogAppend(LOG_PATH_LAUNCHER, msg)
    }
}

; Call at startup to mark new session
_Launcher_LogStartup() {
    global cfg, LOG_PATH_LAUNCHER
    if (!cfg.DiagLauncherLog)
        return
    try {
        LogInitSession(LOG_PATH_LAUNCHER, "Alt-Tabby Launcher Log")
        ; Add launcher-specific context
        FileAppend("Exe: " A_ScriptFullPath "`n", LOG_PATH_LAUNCHER, "UTF-8")
        FileAppend("Compiled: " (A_IsCompiled ? "yes" : "no") " | Admin: " (A_IsAdmin ? "yes" : "no") "`n`n", LOG_PATH_LAUNCHER, "UTF-8")
    }
}

; Main launcher initialization
; Called from alt_tabby.ahk when g_AltTabbyMode = "launch"
Launcher_Init() {
    global g_StorePID, g_GuiPID, g_MismatchDialogShown, g_TestingMode, cfg, gConfigIniPath
    global ALTTABBY_TASK_NAME, TIMING_MUTEX_RELEASE_WAIT, TIMING_SUBPROCESS_LAUNCH, TIMING_TASK_INIT_WAIT, g_SplashStartTick, APP_NAME

    ; Log startup (clears old log if DiagLauncherLog is enabled)
    _Launcher_LogStartup()

    ; Ensure InstallationId exists (generates on first run)
    _Launcher_EnsureInstallationId()

    ; Check if another launcher is already running (named mutex)
    ; Uses InstallationId so renamed exes in same install still share mutex
    ; MUST be before mismatch check to prevent race conditions
    if (!_Launcher_AcquireMutex()) {
        ; In testing mode, don't show dialog — just exit silently
        ; (avoids invisible MsgBox blocking automated tests when user's instance is running)
        if (g_TestingMode)
            ExitApp()

        result := MsgBox(
            "Alt-Tabby is already running.`n`n"
            "Would you like to restart it?",
            APP_NAME,
            "YesNo Icon?"
        )
        if (result = "Yes") {
            _Launcher_KillExistingInstances()
            ; Retry mutex acquisition with increasing delays for slow systems
            acquired := false
            loop 3 {
                Sleep(TIMING_MUTEX_RELEASE_WAIT * A_Index)  ; 500ms, 1000ms, 1500ms
                if (_Launcher_AcquireMutex()) {
                    acquired := true
                    break
                }
            }
            if (!acquired) {
                MsgBox("Could not restart Alt-Tabby after multiple attempts.`nPlease close any remaining Alt-Tabby processes and try again.", APP_NAME, "Icon!")
                ExitApp()
            }
            ; Continue with normal startup below
        } else {
            ExitApp()
        }
    }

    ; Check if running from different location than installed version
    ; (e.g., user downloaded new version and ran from Downloads)
    ; May set g_MismatchDialogShown to prevent auto-update race
    ; Skip in testing mode to avoid blocking automated tests
    if (!g_TestingMode)
        _Launcher_CheckInstallMismatch()

    ; Repair stale SetupExePath if old file was renamed/deleted (no admin task to auto-repair)
    _Launcher_RepairStaleExePath()

    ; Clean up old exe from previous update
    _Update_CleanupOldExe()

    ; Clean up stale temp files from crashed wizard/update instances
    _Update_CleanupStaleTempFiles()

    ; Check if we should redirect to scheduled task (admin mode)
    ; Skip task redirect if mismatch was detected - user chose to run from current location
    ; Showing task repair dialog after mismatch "No" would redirect to wrong version
    ; Skip in testing mode to avoid blocking automated tests
    if (!g_TestingMode && !g_MismatchDialogShown && _ShouldRedirectToScheduledTask()) {
        exitCode := RunWait('schtasks /run /tn "' ALTTABBY_TASK_NAME '"',, "Hide")

        if (exitCode = 0) {
            Sleep(TIMING_TASK_INIT_WAIT)  ; Brief delay for task to initialize
            ExitApp()
        } else {
            ; Task failed to run - delete broken task to prevent retry loop on next launch.
            ; Without deletion, _ShouldRedirectToScheduledTask() syncs SetupRunAsAdmin
            ; back to true because the task still exists, creating an infinite loop.
            try DeleteAdminTask()
            cfg.SetupRunAsAdmin := false
            try _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "RunAsAdmin", false, false, "bool")
            _Launcher_Log("TASK_REDIRECT: schtasks /run failed (code " exitCode "), deleted broken task")
            TrayTip("Admin Mode", "Scheduled task failed (code " exitCode ") and was removed.`nRe-enable from tray menu if needed.", "Icon!")
            ; Continue with normal startup below
        }
    }

    ; Check for first-run (config exists but FirstRunCompleted is false)
    ; Skip in testing mode to avoid blocking automated tests
    if (!cfg.SetupFirstRunCompleted && !g_TestingMode) {
        ; Before showing wizard, check if there's an existing install with config
        ; This handles: user downloads new version, their config.ini is empty/missing
        ; but there's a Program Files install with a valid config
        if (_Launcher_ShouldSkipWizardForExistingInstall()) {
            ; Mismatch check will run on next iteration (already ran above)
            ; Mark wizard as complete since user has existing setup
            cfg.SetupFirstRunCompleted := true
            try _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "FirstRunCompleted", true, false, "bool")
        } else {
            ; Show first-run wizard
            ShowFirstRunWizard()
            ; If wizard was shown and exited (self-elevated), we exit here
            ; Otherwise continue to normal startup
        }
    }

    ; Show splash screen if enabled (skip in testing mode)
    if (cfg.LauncherShowSplash && !g_TestingMode)
        ShowSplashScreen()

    ; Set up tray with on-demand menu updates
    SetupLauncherTray()
    OnMessage(0x404, TrayIconClick)  ; WM_TRAYICON

    ; Register cleanup BEFORE launching subprocesses to prevent orphaned processes
    ; Safe to call early: handler guards all operations (try blocks, PID checks, mutex check)
    OnExit(_Launcher_OnExit)

    ; Launch store and GUI
    LaunchStore()
    Sleep(TIMING_SUBPROCESS_LAUNCH)
    LaunchGui()

    ; Hide splash after duration (or immediately if duration is 0)
    if (cfg.LauncherShowSplash && !g_TestingMode) {
        ; Calculate remaining time after launches
        elapsed := A_TickCount - g_SplashStartTick
        remaining := cfg.LauncherSplashDurationMs - elapsed
        if (remaining > 0)
            Sleep(remaining)
        HideSplashScreen()
    }

    ; Auto-update check if enabled (skip if mismatch dialog was shown to avoid race)
    if (cfg.SetupAutoUpdateCheck && !g_MismatchDialogShown)
        SetTimer(() => CheckForUpdates(false), -5000)

    ; Stay alive to manage subprocesses
    Persistent()
}

; Cleanup handler called on exit
_Launcher_OnExit(exitReason, exitCode) {
    global g_LauncherMutex
    try HideSplashScreen()
    try _KillAllSubprocesses()
    if (g_LauncherMutex) {
        try DllCall("CloseHandle", "ptr", g_LauncherMutex)
        g_LauncherMutex := 0
    }
    return 0  ; Allow exit to proceed
}

; Check if we should redirect to scheduled task instead of running directly
; Returns true if: task exists, points to current exe, and we're NOT already elevated
; Note: Trusts task existence over config (handles corrupted config case)
; Handles stale task paths by:
;   - Auto-repairing if InstallationId matches (same install, just renamed/moved)
;   - Prompting user if ID doesn't match or is missing (might be different install)
_ShouldRedirectToScheduledTask() {
    global cfg, gConfigIniPath, g_TestingMode, APP_NAME

    ; Skip in testing mode - never show dialogs during automated tests
    if (IsSet(g_TestingMode) && g_TestingMode) {  ; lint-ignore: isset-with-default
        _Launcher_Log("TASK_REDIRECT: skip (testing mode)")
        return false
    }

    ; Already elevated - don't redirect (avoid infinite loop)
    if (A_IsAdmin) {
        _Launcher_Log("TASK_REDIRECT: skip (already admin)")
        return false
    }

    ; Check if task exists
    if (!AdminTaskExists()) {
        if (cfg.SetupRunAsAdmin) {
            cfg.SetupRunAsAdmin := false
            try _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "RunAsAdmin", false, false, "bool")
            _Launcher_Log("TASK_REDIRECT: synced stale RunAsAdmin=false (task deleted)")
        }
        _Launcher_Log("TASK_REDIRECT: skip (no task exists)")
        return false
    }

    ; Validate task points to current exe (handles renamed exe case)
    taskPath := _AdminTask_GetCommandPath()
    if (taskPath = "" || StrLower(taskPath) != StrLower(A_ScriptFullPath)) {
        ; If admin mode is disabled in config, don't attempt repair or prompt.
        ; This prevents UAC prompt loops after user previously declined.
        if (!cfg.SetupRunAsAdmin) {
            _Launcher_Log("TASK_REDIRECT: skip (admin mode disabled in config, stale task ignored)")
            return false
        }

        ; Task path doesn't match - check if InstallationId matches
        taskId := _AdminTask_GetInstallationId()
        currentId := (cfg.HasOwnProp("SetupInstallationId") && cfg.SetupInstallationId != "")
            ? cfg.SetupInstallationId : ""

        ; If IDs match, auto-repair without prompting (same installation, just renamed/moved)
        if (taskId != "" && currentId != "" && taskId = currentId) {
            ; Self-elevate to auto-repair task
            try {
                if (!_Launcher_RunAsAdmin("--repair-admin-task"))
                    throw Error("RunAsAdmin failed")
                ExitApp()  ; Elevated instance will handle launch
            } catch {
                ; UAC refused - fall back to non-admin
                TrayTip("Admin Mode", "Could not elevate to repair task. Running without admin privileges.", "Icon!")
                cfg.SetupRunAsAdmin := false
                try _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "RunAsAdmin", false, false, "bool")
                return false
            }
        }

        ; IDs don't match or missing - prompt user to repair.
        ; This handles: different installs, legacy tasks without ID, etc.
        ; NOTE: We intentionally prompt every time rather than using a cooldown.
        ; A cooldown was confusing and non-deterministic. Users can dismiss if needed.
        result := MsgBox(
            "The Admin Mode scheduled task points to a different location:`n"
            "Task: " taskPath "`n"
            "Current: " A_ScriptFullPath "`n`n"
            "Would you like to repair it? (requires elevation)",
            APP_NAME " - Admin Mode Repair",
            "YesNo Icon?"
        )

        if (result = "Yes") {
            ; Self-elevate to repair task
            try {
                if (!_Launcher_RunAsAdmin("--repair-admin-task"))
                    throw Error("RunAsAdmin failed")
                ExitApp()  ; Elevated instance will handle launch
            } catch {
                ; UAC refused - fall back to non-admin
                TrayTip("Admin Mode", "Administrator privileges required to repair. Running without elevation.", "Icon!")
            }
        }

        ; User said No or UAC refused - disable admin mode and continue non-elevated
        cfg.SetupRunAsAdmin := false
        try _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "RunAsAdmin", false, false, "bool")
        TrayTip("Admin Mode Disabled", "The scheduled task was stale.`nRe-enable from tray menu if needed.", "Icon!")
        return false
    }

    ; Sync config if needed (handles corrupted config case)
    if (!cfg.SetupRunAsAdmin) {
        cfg.SetupRunAsAdmin := true
        try _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "RunAsAdmin", true, false, "bool")
    }

    _Launcher_Log("TASK_REDIRECT: will redirect to scheduled task")
    return true
}

; Try to acquire the launcher mutex
; Returns true if acquired (we're the only launcher), false if already held
; Uses InstallationId so renamed exes within same installation share mutex
_Launcher_AcquireMutex() {
    global g_LauncherMutex, cfg, ERROR_ALREADY_EXISTS

    ; Build mutex name using InstallationId (prevents different-named exes running together)
    ; Falls back to hardcoded name if no ID yet (shouldn't happen - EnsureInstallationId runs first)
    installId := (cfg.HasOwnProp("SetupInstallationId") && cfg.SetupInstallationId != "")
        ? cfg.SetupInstallationId : "default"
    mutexName := "AltTabby_Launcher_" installId

    ; Try to create named mutex
    g_LauncherMutex := DllCall("CreateMutex", "ptr", 0, "int", 1, "str", mutexName, "ptr")
    lastError := DllCall("GetLastError")

    if (lastError = ERROR_ALREADY_EXISTS) {
        ; Mutex already exists - another launcher is running
        _Launcher_Log("MUTEX: already exists (err=" ERROR_ALREADY_EXISTS "), another launcher running")
        if (g_LauncherMutex) {
            DllCall("CloseHandle", "ptr", g_LauncherMutex)
            g_LauncherMutex := 0
        }
        return false
    }

    _Launcher_Log("MUTEX: acquired successfully (name=" mutexName ")")
    return (g_LauncherMutex != 0)
}

; Ensure InstallationId exists, generate if missing
; Called early in startup before mutex acquisition
;
; IMPORTANT: Only recover InstallationId from existing admin task if current exe is in
; the SAME DIRECTORY as the task's target path. This prevents a hijacking scenario where:
;   1. User runs fresh exe from Downloads while PF install has admin task
;   2. ID would be recovered from task
;   3. Auto-repair would silently redirect task to Downloads
;
; Auto-repair is still useful when user renames exe or deletes config in same directory.
_Launcher_EnsureInstallationId() {
    global cfg, gConfigIniPath

    if (cfg.HasOwnProp("SetupInstallationId") && cfg.SetupInstallationId != "")
        return  ; Already have ID

    ; Check if existing task has an ID we should reuse
    ; Only recover if we're in the SAME DIRECTORY as the task's target
    if (AdminTaskExists()) {
        taskPath := _AdminTask_GetCommandPath()
        if (taskPath != "") {
            taskDir := ""
            SplitPath(taskPath, , &taskDir)

            ; Only recover if we're in the same directory as the task target
            if (taskDir != "" && StrLower(taskDir) = StrLower(A_ScriptDir)) {
                existingId := _AdminTask_GetInstallationId()
                if (existingId != "") {
                    cfg.SetupInstallationId := existingId
                    try _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "InstallationId", existingId, "", "string")
                    return
                }
            }
        }
    }

    ; Generate new ID (different location or no matching task)
    installId := _Launcher_GenerateId()
    cfg.SetupInstallationId := installId
    try _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "InstallationId", installId, "", "string")
}

; Generate an 8-character hex ID
_Launcher_GenerateId() {
    ; Use combination of tick count and random for uniqueness
    DllCall("QueryPerformanceCounter", "Int64*", &counter := 0)
    seed := Random(0, 0x7FFFFFFF)  ; Random integer in valid range
    combined := counter ^ seed ^ A_TickCount

    ; Format as 8-char hex
    id := Format("{:08X}", combined & 0xFFFFFFFF)
    return id
}

; Check if we should skip wizard due to existing installation
; Returns true if: there's an existing Program Files install with valid config
_Launcher_ShouldSkipWizardForExistingInstall() {
    global cfg

    ; Only relevant when FirstRunCompleted is false (would show wizard)
    if (cfg.SetupFirstRunCompleted)
        return false

    ; Check for Program Files installation (localized for non-English Windows)
    global ALTTABBY_INSTALL_DIR
    pfDir := ALTTABBY_INSTALL_DIR
    pfPath := pfDir "\AltTabby.exe"
    pfConfigPath := pfDir "\config.ini"

    ; If running from Program Files, don't skip (let wizard show for fresh PF installs)
    if (InStr(A_ScriptDir, pfDir))
        return false

    ; Check if Program Files install exists with completed setup
    if (FileExist(pfPath) && FileExist(pfConfigPath)) {
        try {
            firstRunVal := IniRead(pfConfigPath, "Setup", "FirstRunCompleted", "false")
            if (firstRunVal = "true" || firstRunVal = "1") {
                ; Existing install has completed setup - skip wizard
                ; The mismatch dialog will offer to launch installed version or run from here
                return true
            }
        }
    }

    return false
}

; Detect and repair stale SetupExePath when old file no longer exists.
; Handles the case where user renamed the exe without admin mode (no auto-repair path).
; If SetupExePath is set, doesn't match current path, AND the old file is gone,
; silently update config and recreate shortcuts pointing to the new name.
_Launcher_RepairStaleExePath() {
    global cfg, gConfigIniPath

    if (!A_IsCompiled)
        return

    ; Check if SetupExePath is set but stale (file doesn't exist)
    if (!cfg.HasOwnProp("SetupExePath") || cfg.SetupExePath = "")
        return
    if (StrLower(cfg.SetupExePath) = StrLower(A_ScriptFullPath))
        return  ; Already correct
    if (FileExist(cfg.SetupExePath))
        return  ; Old path still exists (mismatch check handles this)

    ; SetupExePath points to non-existent file - update to current path
    cfg.SetupExePath := A_ScriptFullPath
    try _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "ExePath", A_ScriptFullPath, "", "string")

    ; Recreate shortcuts if they exist (they point to old name)
    RecreateShortcuts()
}

; Check if another process with the given exe name is running (excluding our PID)
; Fast path: ProcessExist returns PID != ours → true
; If returns 0: no process, false
; If returns our PID: use tasklist to check for other PIDs
_Launcher_IsOtherProcessRunning(exeName, excludePID := 0) {
    if (excludePID = 0)
        excludePID := ProcessExist()

    ; Fast path: check ProcessExist
    pid := ProcessExist(exeName)
    if (!pid)
        return false  ; No process at all
    if (pid != excludePID)
        return true  ; Found another process immediately

    ; ProcessExist returned our own PID — use tasklist to check for others
    tempFile := A_Temp "\alttabby_proccheck.tmp"
    try FileDelete(tempFile)
    try {
        cmd := 'cmd.exe /c tasklist /FI "IMAGENAME eq ' exeName '" /FI "PID ne ' excludePID '" /NH > "' tempFile '"'
        RunWait(cmd,, "Hide")
        if (FileExist(tempFile)) {
            output := FileRead(tempFile, "UTF-8")
            FileDelete(tempFile)
            ; tasklist outputs "INFO: No tasks..." when no match, otherwise shows process lines
            ; A real match will contain the exe name in the output
            if (InStr(output, exeName))
                return true
        }
    } catch {
        try FileDelete(tempFile)
    }
    return false
}

; Kill all processes matching exeName except ourselves
; Uses taskkill as primary mechanism (immune to ProcessExist PID ordering),
; with ProcessClose loop as fallback for stragglers.
; Used by _Launcher_KillExistingInstances and _Launcher_OfferToStopInstalledInstance
_Launcher_KillProcessByName(exeName, maxAttempts := 10, sleepMs := 0) {
    global TIMING_PROCESS_TERMINATE_WAIT, TIMING_SETUP_SETTLE
    if (sleepMs = 0)
        sleepMs := TIMING_PROCESS_TERMINATE_WAIT
    myPID := ProcessExist()

    ; Primary: taskkill (reliable for same-name processes)
    try RunWait('taskkill /F /IM "' exeName '" /FI "PID ne ' myPID '"',, "Hide")
    Sleep(TIMING_SETUP_SETTLE)

    ; Fallback: ProcessClose loop for any stragglers
    loop maxAttempts {
        pid := ProcessExist(exeName)
        if (!pid || pid = myPID)
            break
        try ProcessClose(pid)
        Sleep(sleepMs)
    }
}

; Kill all existing instances of Alt-Tabby exes except ourselves
; Uses ProcessExist/ProcessClose loop instead of WMI (WMI can fail with 0x800401F3)
; Handles renamed exes by killing processes matching:
;   1. Current exe name (from A_ScriptFullPath)
;   2. Exe name from cfg.SetupExePath (installed location, may differ)
_Launcher_KillExistingInstances() {
    for exeName in ProcessUtils_BuildExeNameList() {
        _Launcher_KillProcessByName(exeName)
    }
}

; ============================================================
; SUBPROCESS LAUNCH
; ============================================================

LaunchStore() {
    global g_StorePID
    LauncherUtils_Launch("store", &g_StorePID, _Launcher_Log)
}

LaunchGui() {
    global g_GuiPID
    LauncherUtils_Launch("gui", &g_GuiPID, _Launcher_Log)
}

LaunchViewer() {
    global g_ViewerPID
    LauncherUtils_Launch("viewer", &g_ViewerPID, _Launcher_Log)
}
