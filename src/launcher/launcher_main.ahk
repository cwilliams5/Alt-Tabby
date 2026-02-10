#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; g_TestingMode and other globals come from alt_tabby.ahk

; ============================================================
; Launcher Main - Core Init & Subprocess Management
; ============================================================
; Main entry point for launcher mode. Orchestrates startup:
; mutex, mismatch check, wizard, splash, subprocess launch.

; Launcher mutex global (per-InstallationId - allows renamed exes in same install)
global g_LauncherMutex := 0

; Global active mutex (system-wide - prevents multiple installations running)
global g_ActiveMutex := 0

; WM_COPYDATA debounce state (IsSet pattern - unset until first signal received)
global g_LastStoreRestartTick  ; Debounce RESTART_STORE signals
global g_LastFullRestartTick   ; Debounce RESTART_ALL signals

; Win32 error code
global ERROR_ALREADY_EXISTS := 183

; Subprocess PID tracking — owner (read by launcher_about, launcher_stats, etc.)
global g_StorePID := 0
global g_GuiPID := 0
global g_ViewerPID := 0

; ========================= DEBUG LOGGING =========================
; Controlled by cfg.DiagLauncherLog (config.ini [Diagnostics] LauncherLog=true)
; Log file: %TEMP%\tabby_launcher.log

Launcher_Log(msg) {
    global cfg, LOG_PATH_LAUNCHER
    if (!cfg.DiagLauncherLog)
        return
    try {
        LogAppend(LOG_PATH_LAUNCHER, msg)
    }
}

; Call at startup to mark new session
Launcher_LogStartup() {
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
    Launcher_LogStartup()

    ; Ensure InstallationId exists (generates on first run)
    Launcher_EnsureInstallationId()

    ; Check config writability early - warn once if settings can't be saved
    ; (e.g., read-only file, OneDrive sync lock, antivirus interference)
    _Launcher_CheckConfigWritable()

    ; Check if another launcher is already running (named mutex)
    ; Uses InstallationId so renamed exes in same install still share mutex
    ; MUST be before mismatch check to prevent race conditions
    if (!Launcher_AcquireMutex()) {
        ; In testing mode, don't show dialog — just exit silently
        ; (avoids invisible MsgBox blocking automated tests when user's instance is running)
        if (g_TestingMode)
            ExitApp()

        result := ThemeMsgBox(
            "Alt-Tabby is already running.`n`n"
            "Would you like to restart it?",
            APP_NAME,
            "YesNo Icon?"
        )
        if (result = "Yes") {
            ProcessUtils_KillAltTabby({force: true})
            ; Retry mutex acquisition with increasing delays for slow systems
            acquired := false
            loop 3 {
                Sleep(TIMING_MUTEX_RELEASE_WAIT * A_Index)  ; 500ms, 1000ms, 1500ms
                if (Launcher_AcquireMutex()) {
                    acquired := true
                    break
                }
            }
            if (!acquired) {
                ThemeMsgBox("Could not restart Alt-Tabby after multiple attempts.`nPlease close any remaining Alt-Tabby processes and try again.", APP_NAME, "Iconx")
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
        Launcher_CheckInstallMismatch()

    ; Repair stale SetupExePath if old file was renamed/deleted (no admin task to auto-repair)
    _Launcher_RepairStaleExePath()

    ; Clean up old exe from previous update
    Update_CleanupOldExe()

    ; Clean up stale temp files from crashed wizard/update instances
    Update_CleanupStaleTempFiles()

    ; Check if we should redirect to scheduled task (admin mode)
    ; Skip task redirect if mismatch was detected - user chose to run from current location
    ; Showing task repair dialog after mismatch "No" would redirect to wrong version
    ; Skip in testing mode to avoid blocking automated tests
    if (!g_TestingMode && !g_MismatchDialogShown && _ShouldRedirectToScheduledTask()) {
        exitCode := RunAdminTask()

        if (exitCode = 0) {
            Sleep(TIMING_TASK_INIT_WAIT)  ; Brief delay for task to initialize
            ExitApp()
        } else {
            ; Task failed to run - delete broken task to prevent retry loop on next launch.
            ; Without deletion, _ShouldRedirectToScheduledTask() syncs SetupRunAsAdmin
            ; back to true because the task still exists, creating an infinite loop.
            try DeleteAdminTask()
            Setup_SetRunAsAdmin(false)
            if (cfg.DiagLauncherLog)
            Launcher_Log("TASK_REDIRECT: schtasks /run failed (code " exitCode "), deleted broken task")
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
            Setup_SetFirstRunCompleted(true)
        } else {
            ; Show first-run wizard
            ShowFirstRunWizard()
            ; If wizard was shown and exited (self-elevated), we exit here
            ; Otherwise continue to normal startup
        }
    }

    Launcher_StartSubprocesses()
}

; Shared subprocess launch sequence used by both Launcher_Init() and wizard-continue.
; Handles: splash, tray, OnExit, active mutex, store+gui launch, HWND file, splash hide,
; auto-update check, and Persistent().
; skipMismatchGuard: true when called from wizard-continue (mismatch can't have happened)
Launcher_StartSubprocesses(skipMismatchGuard := false) {
    global g_MismatchDialogShown, g_TestingMode, cfg, gConfigIniPath
    global TIMING_MUTEX_RELEASE_WAIT, TIMING_SUBPROCESS_LAUNCH, g_SplashStartTick, APP_NAME

    ; Show splash screen if enabled (skip in testing mode)
    if (cfg.LauncherSplashScreen != "None" && !g_TestingMode)
        ShowSplashScreen()

    ; Set up tray with on-demand menu updates
    SetupLauncherTray()
    global WM_TRAYICON, WM_COPYDATA
    OnMessage(WM_TRAYICON, TrayIconClick)
    OnMessage(WM_COPYDATA, _Launcher_OnCopyData)

    ; Register cleanup BEFORE launching subprocesses to prevent orphaned processes
    ; Safe to call early: handler guards all operations (try blocks, PID checks, mutex check)
    OnExit(_Launcher_OnExit)

    ; Acquire system-wide active mutex before launching subprocesses
    ; This prevents multiple installations from running simultaneously
    ; Skip in testing mode to allow parallel test execution
    if (!g_TestingMode && !_Launcher_AcquireActiveMutex()) {
        result := ThemeMsgBox(
            "Another Alt-Tabby installation is already running.`n`n"
            "Only one installation can be active at a time.`n"
            "Close the other installation and try again?",
            APP_NAME,
            "YesNo Iconx"
        )
        if (result = "Yes") {
            ; Kill ALL Alt-Tabby processes system-wide
            _Launcher_KillAllAltTabbyProcesses()
            Sleep(TIMING_MUTEX_RELEASE_WAIT)
            if (!_Launcher_AcquireActiveMutex()) {
                ThemeMsgBox("Could not acquire active lock.`nPlease close Alt-Tabby manually and try again.", APP_NAME, "Iconx")
                ExitApp()
            }
        } else {
            ExitApp()
        }
    }

    ; Launch store and GUI
    LaunchStore()
    Sleep(TIMING_SUBPROCESS_LAUNCH)
    LaunchGui()

    ; In testing mode, write our HWND to temp file so lifecycle tests can send WM_COPYDATA
    ; (test processes are launched with CREATE_NO_WINDOW which hides AHK's message window
    ; from WinGetList/WinGetID, so tests can't discover the HWND externally)
    ; Filename derived from exe name so renamed copies (e.g., AltTabby_lifecycle.exe) don't collide
    if (g_TestingMode) {
        exeName := ""
        SplitPath(A_ScriptFullPath, &exeName)
        exeBase := RegExReplace(exeName, "\.exe$", "")
        hwndPath := A_Temp "\" StrLower(exeBase) "_hwnd.txt"
        try FileDelete(hwndPath)
        try FileAppend(A_ScriptHwnd, hwndPath)
    }

    ; Hide splash after duration/loops complete
    if (cfg.LauncherSplashScreen != "None" && !g_TestingMode) {
        if (cfg.LauncherSplashScreen = "Image") {
            ; Image mode: wait for configured duration
            elapsed := A_TickCount - g_SplashStartTick
            remaining := cfg.LauncherSplashImageDurationMs - elapsed
            if (remaining > 0)
                Sleep(remaining)
            HideSplashScreen()
        } else if (cfg.LauncherSplashScreen = "Animation") {
            ; Animation mode: wait for animation to complete its loops
            ; (timers stop automatically when loops are done)
            maxLoops := cfg.LauncherSplashAnimLoops
            if (maxLoops > 0) {
                ; Poll until animation completes (loop count reached or window destroyed)
                while (IsSplashActive()) {
                    Sleep(100)
                }
            }
            ; Always call HideSplashScreen to ensure cleanup
            HideSplashScreen()
        }
    }

    ; Auto-update check if enabled (skip if mismatch dialog was shown to avoid race)
    mismatchShown := skipMismatchGuard ? false : g_MismatchDialogShown
    if (cfg.SetupAutoUpdateCheck && !mismatchShown)
        SetTimer(() => CheckForUpdates(false), -5000)

    ; Stay alive to manage subprocesses
    Persistent()
}

; Cleanup handler called on exit
_Launcher_OnExit(exitReason, exitCode) {
    global g_LauncherMutex, g_ActiveMutex, g_ConfigEditorPID, g_BlacklistEditorPID
    try HideSplashScreen()
    try Launcher_ShutdownSubprocesses({config: g_ConfigEditorPID, blacklist: g_BlacklistEditorPID})
    if (g_LauncherMutex) {
        try DllCall("CloseHandle", "ptr", g_LauncherMutex)
        g_LauncherMutex := 0
    }
    if (g_ActiveMutex) {
        try DllCall("CloseHandle", "ptr", g_ActiveMutex)
        g_ActiveMutex := 0
    }
    return 0  ; Allow exit to proceed
}

; Handle WM_COPYDATA control signals from child processes
; GUI sends RESTART_STORE when store health check fails
; Config editor sends RESTART_ALL when settings are saved
_Launcher_OnCopyData(wParam, lParam, msg, hwnd) {
    global TABBY_CMD_RESTART_STORE, TABBY_CMD_RESTART_ALL, cfg
    global g_LastStoreRestartTick, g_LastFullRestartTick

    dwData := NumGet(lParam, 0, "uptr")

    if (dwData = TABBY_CMD_RESTART_STORE) {
        if (cfg.DiagLauncherLog)
            Launcher_Log("IPC: Received RESTART_STORE from hwnd=" wParam)
        if (IsSet(g_LastStoreRestartTick) && (A_TickCount - g_LastStoreRestartTick) < 5000) {
            Launcher_Log("IPC: RESTART_STORE debounced")
            return 1
        }
        g_LastStoreRestartTick := A_TickCount
        SetTimer(() => RestartStore(), -1)
        return 1
    }

    if (dwData = TABBY_CMD_RESTART_ALL) {
        if (cfg.DiagLauncherLog)
            Launcher_Log("IPC: Received RESTART_ALL from hwnd=" wParam)
        if (IsSet(g_LastFullRestartTick) && (A_TickCount - g_LastFullRestartTick) < 5000) {
            Launcher_Log("IPC: RESTART_ALL debounced")
            return 1
        }
        g_LastFullRestartTick := A_TickCount
        SetTimer(_Launcher_ApplyConfigChanges, -1)
        return 1
    }

    return 0
}

; Apply config changes: reload config for the launcher, re-theme launcher
; surfaces in-place, then restart store+GUI (which read config fresh on launch).
_Launcher_ApplyConfigChanges() {
    Launcher_Log("ApplyConfigChanges: reloading config and theme for launcher")

    ; 1. Reload config from INI so launcher picks up new values
    ConfigLoader_Init()

    ; 2. Re-apply theme to launcher's own surfaces (tray menus, dashboard, etc.)
    Theme_Reload()

    ; 3. Restart store + GUI (they read config fresh on startup)
    _Launcher_RestartStoreAndGui()
}

_Launcher_RestartStoreAndGui() {
    global TIMING_SUBPROCESS_LAUNCH
    Launcher_ShutdownSubprocesses()
    LaunchStore()
    Sleep(TIMING_SUBPROCESS_LAUNCH)
    LaunchGui()
}

Launcher_RestartStore() {
    global g_StorePID, TIMING_SUBPROCESS_LAUNCH
    LauncherUtils_Restart("store", &g_StorePID, TIMING_SUBPROCESS_LAUNCH, Launcher_Log)
}

Launcher_RestartGui() {
    global g_GuiPID, TIMING_SUBPROCESS_LAUNCH
    LauncherUtils_Restart("gui", &g_GuiPID, TIMING_SUBPROCESS_LAUNCH, Launcher_Log)
}

Launcher_RestartViewer() {
    global g_ViewerPID, TIMING_SUBPROCESS_LAUNCH
    LauncherUtils_Restart("viewer", &g_ViewerPID, TIMING_SUBPROCESS_LAUNCH, Launcher_Log)
}

; Kills subprocesses + resets PIDs. Optional editor PIDs passed by caller.
Launcher_ShutdownSubprocesses(editors := 0) {
    global g_StorePID, g_GuiPID, g_ViewerPID
    opts := {pids: {gui: g_GuiPID, store: g_StorePID, viewer: g_ViewerPID}}
    if (IsObject(editors))
        opts.editors := editors
    ProcessUtils_KillAltTabby(opts)
    g_GuiPID := 0, g_StorePID := 0, g_ViewerPID := 0
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
        Launcher_Log("TASK_REDIRECT: skip (testing mode)")
        return false
    }

    ; Already elevated - don't redirect (avoid infinite loop)
    if (A_IsAdmin) {
        Launcher_Log("TASK_REDIRECT: skip (already admin)")
        return false
    }

    ; Check admin-declined marker (temp file for when PF config write fails).
    ; Breaks the UAC prompt loop: declined -> can't write to PF -> disk still says true -> repeat.
    if (Setup_HasAdminDeclinedMarker()) {
        writeOk := Setup_SetRunAsAdmin(false)
        if (writeOk)
            Setup_ClearAdminDeclinedMarker()
        if (cfg.DiagLauncherLog)
            Launcher_Log("TASK_REDIRECT: skip (admin declined marker, writeOk=" writeOk ")")
        return false
    }

    ; Fast path: if admin mode was never configured, skip schtasks query entirely.
    ; Saves ~200-300ms for non-admin users (the common case).
    if (!cfg.SetupRunAsAdmin) {
        Launcher_Log("TASK_REDIRECT: skip (admin not configured)")
        return false
    }

    ; Check if task exists (cfg.SetupRunAsAdmin is true here — fast path returned above)
    if (!AdminTaskExists()) {
        Setup_SetRunAsAdmin(false)
        Launcher_Log("TASK_REDIRECT: synced stale RunAsAdmin=false (task deleted)")
        return false
    }

    ; Validate task points to current exe (handles renamed exe case)
    taskPath := AdminTask_GetCommandPath()
    if (taskPath = "" || !PathsEqual(taskPath, A_ScriptFullPath)) {
        ; If admin mode is disabled in config, don't attempt repair or prompt.
        ; This prevents UAC prompt loops after user previously declined.
        if (!cfg.SetupRunAsAdmin) {
            Launcher_Log("TASK_REDIRECT: skip (admin mode disabled in config, stale task ignored)")
            return false
        }

        ; Task path doesn't match - check if InstallationId matches
        taskId := AdminTask_GetInstallationId()
        currentId := (cfg.HasOwnProp("SetupInstallationId") && cfg.SetupInstallationId != "")
            ? cfg.SetupInstallationId : ""

        ; If IDs match, check if task target still exists before auto-repairing
        if (taskId != "" && currentId != "" && taskId = currentId) {
            ; Check if task's target exe still exists - if so, no need to repair.
            ; This prevents flip-flop when two differently-named exes in the same dir
            ; share config/InstallationId (e.g., AltTabby.exe and AltTabby_backup.exe).
            ; Only auto-repair when the task target is genuinely missing.
            if (FileExist(taskPath)) {
                if (cfg.DiagLauncherLog)
                    Launcher_Log("TASK_REDIRECT: skip auto-repair (task target exists: " taskPath ")")
                return false  ; Don't redirect to task, run normally
            }

            ; Task target is missing - self-elevate to auto-repair task
            try {
                if (!Launcher_RunAsAdmin("--repair-admin-task"))
                    throw Error("RunAsAdmin failed")
                ExitApp()  ; Elevated instance will handle launch
            } catch {
                ; UAC refused - fall back to non-admin
                TrayTip("Admin Mode", "Could not elevate to repair task. Running without admin privileges.", "Icon!")
                Setup_SetRunAsAdmin(false, true)  ; marker on fail: breaks PF UAC loop
                _Launcher_RepairExePathAfterAdminDecline()
                return false
            }
        }

        ; IDs don't match or missing - prompt user to repair.
        ; This handles: different installs, legacy tasks without ID, etc.
        ; Check if user previously said "Don't ask again"
        if (cfg.SetupSuppressAdminRepairPrompt) {
            Launcher_Log("TASK_REDIRECT: skip (repair prompt suppressed by user)")
            return false
        }

        ; Show custom dialog with "Don't ask again" option
        result := Launcher_ShowAdminRepairDialog(taskPath)

        if (result = "Yes") {
            ; Self-elevate to repair task
            try {
                if (!Launcher_RunAsAdmin("--repair-admin-task"))
                    throw Error("RunAsAdmin failed")
                ExitApp()  ; Elevated instance will handle launch
            } catch {
                ; UAC refused - fall back to non-admin
                TrayTip("Admin Mode", "Administrator privileges required to repair. Running without elevation.", "Icon!")
            }
        }

        ; User said No or "Don't ask again" or UAC refused - disable admin mode and continue non-elevated
        Setup_SetRunAsAdmin(false, true)  ; marker on fail: breaks PF UAC loop
        _Launcher_RepairExePathAfterAdminDecline()
        if (result != "Yes")  ; Only show traytip if not attempting repair
            TrayTip("Admin Mode Disabled", "The scheduled task was stale.`nRe-enable from tray menu if needed.", "Icon!")
        return false
    }

    ; Sync config if needed (handles corrupted config case)
    if (!cfg.SetupRunAsAdmin) {
        Setup_SetRunAsAdmin(true)
    }

    Launcher_Log("TASK_REDIRECT: will redirect to scheduled task")
    return true
}

; Repair ExePath + shortcuts when declining admin repair with a stale path.
; Without this, there's a one-boot gap where shortcuts point to the old exe name.
_Launcher_RepairExePathAfterAdminDecline() {
    global cfg
    if (cfg.SetupExePath != "" && !PathsEqual(cfg.SetupExePath, A_ScriptFullPath) && !FileExist(cfg.SetupExePath)) {
        Setup_SetExePath(A_ScriptFullPath)
        RecreateShortcuts()
    }
}

; Write the SuppressAdminRepairPrompt flag, wrapped in try for use in fat-arrow closures
_Launcher_WriteSuppressFlag() {
    global gConfigIniPath
    try CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "SuppressAdminRepairPrompt", true, false, "bool")
}

; Custom dialog for admin task repair with "Don't ask again" option
; Returns: "Yes" (repair), "No" (skip this time), or "Never" (don't ask again)
Launcher_ShowAdminRepairDialog(taskPath) {
    global cfg, gConfigIniPath, APP_NAME

    dlgResult := Theme_CreateModalDialog(APP_NAME " - Admin Mode Repair")
    repairGui := dlgResult.gui
    themeEntry := dlgResult.themeEntry

    contentW := 440
    mutedColor := Theme_GetMutedColor()

    ; Header in accent
    hdr := repairGui.AddText("w" contentW " c" Theme_GetAccentColor(), "The admin mode scheduled task points to a different location:")
    Theme_MarkAccent(hdr)

    ; Task path - bold label + muted value
    lblTask := repairGui.AddText("x24 w50 h20 y+12 +0x200", "Task:")
    lblTask.SetFont("s10 bold", "Segoe UI")
    valTask := repairGui.AddText("x78 yp w" (contentW - 54) " h20 +0x200 c" mutedColor, taskPath)
    Theme_MarkMuted(valTask)

    ; Current path - bold label + muted value
    lblCurr := repairGui.AddText("x24 w65 h20 y+4 +0x200", "Current:")
    lblCurr.SetFont("s10 bold", "Segoe UI")
    valCurr := repairGui.AddText("x93 yp w" (contentW - 69) " h20 +0x200 c" mutedColor, A_ScriptFullPath)
    Theme_MarkMuted(valCurr)

    ; Question + UAC note
    repairGui.AddText("x24 w" contentW " y+16", "Would you like to repair it?")
    noteUAC := repairGui.AddText("w" contentW " y+4 c" mutedColor, "Requires a one-time permissions approval (UAC).")
    noteUAC.SetFont("s8", "Segoe UI")
    Theme_MarkMuted(noteUAC)

    result := ""  ; Will be set by button clicks

    ; Buttons: [Yes] ... gap ... [No] [Don't ask again]
    btnW := 100
    btnYes := repairGui.AddButton("x24 w" btnW " y+24 Default", "Yes")
    btnNever := repairGui.AddButton("x" (24 + contentW - btnW - 8 - 140) " yp w140", "Don't ask again")
    btnNo := repairGui.AddButton("x+8 w" btnW, "No")

    Theme_ApplyToControl(btnYes, "Button", themeEntry)
    Theme_ApplyToControl(btnNo, "Button", themeEntry)
    Theme_ApplyToControl(btnNever, "Button", themeEntry)

    btnYes.OnEvent("Click", (*) => (result := "Yes", Theme_UntrackGui(repairGui), repairGui.Destroy()))
    btnNo.OnEvent("Click", (*) => (result := "No", Theme_UntrackGui(repairGui), repairGui.Destroy()))
    btnNever.OnEvent("Click", (*) => (
        result := "Never",
        cfg.SetupSuppressAdminRepairPrompt := true,
        _Launcher_WriteSuppressFlag(),
        Theme_UntrackGui(repairGui),
        repairGui.Destroy()
    ))
    repairGui.OnEvent("Close", (*) => (result := "No", Theme_UntrackGui(repairGui), repairGui.Destroy()))

    Theme_ShowModalDialog(repairGui)

    return result
}

; Try to acquire the launcher mutex
; Returns true if acquired (we're the only launcher), false if already held
; Uses InstallationId so renamed exes within same installation share mutex
Launcher_AcquireMutex() {
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
        if (cfg.DiagLauncherLog)
            Launcher_Log("MUTEX: already exists (err=" ERROR_ALREADY_EXISTS "), another launcher running")
        if (g_LauncherMutex) {
            DllCall("CloseHandle", "ptr", g_LauncherMutex)
            g_LauncherMutex := 0
        }
        return false
    }

    if (cfg.DiagLauncherLog)
        Launcher_Log("MUTEX: acquired successfully (name=" mutexName ")")
    return (g_LauncherMutex != 0)
}

; Try to acquire the system-wide active mutex
; Returns true if acquired, false if another installation is running
; This is separate from the launcher mutex (which uses InstallationId) to prevent
; multiple installations from running simultaneously regardless of their ID.
_Launcher_AcquireActiveMutex() {
    global g_ActiveMutex, ERROR_ALREADY_EXISTS

    ; System-wide mutex with no ID suffix
    mutexName := "AltTabby_Active"

    g_ActiveMutex := DllCall("CreateMutex", "ptr", 0, "int", 1, "str", mutexName, "ptr")
    lastError := DllCall("GetLastError")

    if (lastError = ERROR_ALREADY_EXISTS) {
        Launcher_Log("ACTIVE_MUTEX: already exists, another installation running")
        if (g_ActiveMutex) {
            DllCall("CloseHandle", "ptr", g_ActiveMutex)
            g_ActiveMutex := 0
        }
        return false
    }

    Launcher_Log("ACTIVE_MUTEX: acquired successfully")
    return (g_ActiveMutex != 0)
}

; Kill all Alt-Tabby processes system-wide (for cross-installation conflicts)
; More aggressive than ProcessUtils_KillAltTabby - kills any AltTabby*.exe via WMI
_Launcher_KillAllAltTabbyProcesses() {
    global TIMING_SETUP_SETTLE
    myPID := ProcessExist()

    ; Kill any process with "alttabby" in the name (case-insensitive)
    ; Use WMI to find all matching processes
    try {
        wmi := ComObject("WbemScripting.SWbemLocator").ConnectServer(".", "root\cimv2")
        query := "SELECT ProcessId, Name FROM Win32_Process WHERE Name LIKE '%tabby%'"
        for process in wmi.ExecQuery(query) {
            if (process.ProcessId != myPID) {
                try ProcessClose(process.ProcessId)
            }
        }
    } catch {
        ; Fallback: use taskkill with wildcard patterns
        ; Note: taskkill doesn't support wildcards in /IM, so we try common patterns
        currentExeName := ""
        SplitPath(A_ScriptFullPath, &currentExeName)
        fallbackPatterns := ["AltTabby.exe", "alttabby.exe", "Alt-Tabby.exe"]
        if (currentExeName != "") {
            alreadyCovered := false
            for p in fallbackPatterns {
                if (PathsEqual(p, currentExeName)) {
                    alreadyCovered := true
                    break
                }
            }
            if (!alreadyCovered)
                fallbackPatterns.Push(currentExeName)
        }
        for pattern in fallbackPatterns {
            try RunWait('taskkill /F /IM "' pattern '" /FI "PID ne ' myPID '"',, "Hide")
        }
    }

    Sleep(TIMING_SETUP_SETTLE)
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
Launcher_EnsureInstallationId() {
    global cfg, gConfigIniPath

    if (cfg.HasOwnProp("SetupInstallationId") && cfg.SetupInstallationId != "")
        return  ; Already have ID

    ; Check if existing task has an ID we should reuse
    ; Only recover if we're in the SAME DIRECTORY as the task's target
    if (AdminTaskExists()) {
        taskPath := AdminTask_GetCommandPath()
        if (taskPath != "") {
            taskDir := ""
            SplitPath(taskPath, , &taskDir)

            ; Only recover if we're in the same directory as the task target
            if (taskDir != "" && PathsEqual(taskDir, A_ScriptDir)) {
                existingId := AdminTask_GetInstallationId()
                if (existingId != "") {
                    Setup_SetInstallationId(existingId)
                    return
                }
            }
        }
    }

    ; Generate new ID (different location or no matching task)
    Setup_SetInstallationId(Launcher_GenerateId())
}

; Generate an 8-character hex ID
Launcher_GenerateId() {
    ; Use combination of tick count and random for uniqueness
    DllCall("QueryPerformanceCounter", "Int64*", &counter := 0)
    seed := Random(0, 0x7FFFFFFF)  ; Random integer in valid range
    combined := counter ^ seed ^ A_TickCount

    ; Format as 8-char hex
    id := Format("{:08X}", combined & 0xFFFFFFFF)
    return id
}

; Check if config.ini is writable. Shows a one-time warning if not.
; Catches: read-only attribute, antivirus locks, OneDrive/Dropbox sync locks.
; Only warns — does NOT block startup.
_Launcher_CheckConfigWritable() {
    global gConfigIniPath, APP_NAME, cfg

    ; Skip if config doesn't exist yet (wizard will create it)
    if (!FileExist(gConfigIniPath))
        return

    ; Try writing a harmless test key, then remove it
    testKey := "_WriteTest"
    try {
        IniWrite("1", gConfigIniPath, "Setup", testKey)
        IniDelete(gConfigIniPath, "Setup", testKey)
        return  ; Writable
    }

    ; Write failed — warn once per session
    if (cfg.DiagLauncherLog)
        Launcher_Log("CONFIG_WRITABLE: config.ini is not writable: " gConfigIniPath)
    try ThemeMsgBox(
        "The config file is not writable:`n" gConfigIniPath "`n`n"
        "Settings changes won't be saved this session.`n"
        "This can happen with read-only files, cloud-synced folders, or antivirus locks.",
        APP_NAME " - Config Warning", "Icon!")
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
    if (PathsEqual(cfg.SetupExePath, A_ScriptFullPath))
        return  ; Already correct
    if (FileExist(cfg.SetupExePath))
        return  ; Old path still exists (mismatch check handles this)

    ; If admin mode is active with a task, skip repair here — the admin repair path
    ; in _ShouldRedirectToScheduledTask() handles ExePath, shortcuts, and task update.
    ; If admin repair later fails (UAC refused), admin mode gets disabled, and next
    ; launch hits this function normally.
    if (cfg.SetupRunAsAdmin && AdminTaskExists())
        return

    ; SetupExePath points to non-existent file - update to current path
    Setup_SetExePath(A_ScriptFullPath)

    ; Recreate shortcuts if they exist (they point to old name)
    RecreateShortcuts()
}

; Check if another process with the given exe name is running (excluding our PID)
; Fast path: ProcessExist returns PID != ours → true
; If returns 0: no process, false
; If returns our PID: use tasklist to check for other PIDs
Launcher_IsOtherProcessRunning(exeName, excludePID := 0) {
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

; ============================================================
; SUBPROCESS LAUNCH
; ============================================================

LaunchStore() {
    global g_StorePID
    LauncherUtils_Launch("store", &g_StorePID, Launcher_Log)
    Dash_OnStoreRestart()
}

LaunchGui() {
    global g_GuiPID
    LauncherUtils_Launch("gui", &g_GuiPID, Launcher_Log)
    Dash_StartRefreshTimer()
}

LaunchViewer() {
    global g_ViewerPID
    LauncherUtils_Launch("viewer", &g_ViewerPID, Launcher_Log)
    Dash_StartRefreshTimer()
}
