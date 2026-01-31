#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Cross-file globals (cfg, g_StorePID, etc.) come from alt_tabby.ahk

; ============================================================
; Launcher Tray Menu - On-Demand Updates
; ============================================================
; Manages the system tray icon and context menu.
; Menu is rebuilt on right-click for current subprocess status.

TrayIconClick(wParam, lParam, msg, hwnd) {
    ; 0x205 = WM_RBUTTONUP (right-click release)
    if (lParam = 0x205) {
        ; Dismiss splash screen if still showing — user wants to interact with tray,
        ; not wait for the splash duration to finish
        HideSplashScreen()
        UpdateTrayMenu()
        A_TrayMenu.Show()  ; Must explicitly show the menu
        return 1  ; Prevent default handling (we showed it ourselves)
    }
    return 0  ; Let default handling continue for other events
}

SetupLauncherTray() {
    ; Set custom icon - embedded in exe for compiled, file for dev mode
    if (A_IsCompiled) {
        ; Icon is embedded in exe via /icon compile flag - use icon index 1
        TraySetIcon(A_ScriptFullPath, 1)
    } else {
        iconPath := A_ScriptDir "\..\img\icon.ico"
        if FileExist(iconPath)
            TraySetIcon(iconPath)
    }
    global APP_NAME
    A_IconTip := APP_NAME
    UpdateTrayMenu()
}

UpdateTrayMenu() {
    global g_StorePID, g_GuiPID, g_ViewerPID, cfg, gConfigIniPath

    ; Reload SetupRunAsAdmin from disk in case elevated instance changed it
    if (FileExist(gConfigIniPath)) {
        iniVal := IniRead(gConfigIniPath, "Setup", "RunAsAdmin", "false")
        cfg.SetupRunAsAdmin := (iniVal = "true" || iniVal = "1")
    }

    tray := A_TrayMenu
    tray.Delete()

    ; Header with version (and admin status if elevated)
    version := GetAppVersion()
    header := "Alt-Tabby v" version (A_IsAdmin ? " (Admin)" : "")
    tray.Add(header, (*) => 0)
    tray.Disable(header)
    tray.Add()

    ; Store status
    storeRunning := LauncherUtils_IsRunning(g_StorePID)
    if (storeRunning) {
        tray.Add("Store: Restart", (*) => RestartStore())
    } else {
        tray.Add("Store: Launch", (*) => LaunchStore())
    }

    ; GUI status
    guiRunning := LauncherUtils_IsRunning(g_GuiPID)
    if (guiRunning) {
        tray.Add("GUI: Restart", (*) => RestartGui())
    } else {
        tray.Add("GUI: Launch", (*) => LaunchGui())
    }

    ; Viewer status (optional, launch from menu)
    viewerRunning := LauncherUtils_IsRunning(g_ViewerPID)
    if (viewerRunning) {
        tray.Add("Viewer: Restart", (*) => RestartViewer())
    } else {
        tray.Add("Viewer: Launch", (*) => LaunchViewer())
    }

    tray.Add()

    ; Restart option (only if something is running)
    if (storeRunning || guiRunning || viewerRunning) {
        tray.Add("Restart All", (*) => RestartAll())
        tray.Add()
    }

    ; Editors
    tray.Add("Edit Config...", (*) => LaunchConfigEditor())
    tray.Add("Edit Blacklist...", (*) => LaunchBlacklistEditor())
    tray.Add()

    ; Shortcuts (with checkmarks for current state)
    tray.Add("Add to Start Menu", (*) => ToggleStartMenuShortcut())
    if (_Shortcut_StartMenuExists())
        tray.Check("Add to Start Menu")

    tray.Add("Run at Startup", (*) => ToggleStartupShortcut())
    if (_Shortcut_StartupExists())
        tray.Check("Run at Startup")

    tray.Add()

    ; Admin mode toggle
    tray.Add("Run as Administrator", (*) => ToggleAdminMode())
    if (cfg.SetupRunAsAdmin && _AdminTask_PointsToUs())
        tray.Check("Run as Administrator")

    tray.Add()

    ; Updates section
    tray.Add("Check for Updates Now", (*) => CheckForUpdates(true))
    tray.Add("Auto-check on Startup", (*) => ToggleAutoUpdate())
    if (cfg.SetupAutoUpdateCheck)
        tray.Check("Auto-check on Startup")

    tray.Add()
    tray.Add("Dashboard...", (*) => ShowDashboardDialog())
    tray.Add()

    tray.Add("Exit", (*) => ExitAll())
}

RestartStore() {
    global g_StorePID, TIMING_SUBPROCESS_LAUNCH
    LauncherUtils_Restart("store", &g_StorePID, TIMING_SUBPROCESS_LAUNCH, _Launcher_Log)
    _Dash_StartRefreshTimer()
}

RestartGui() {
    global g_GuiPID, TIMING_SUBPROCESS_LAUNCH
    LauncherUtils_Restart("gui", &g_GuiPID, TIMING_SUBPROCESS_LAUNCH, _Launcher_Log)
    _Dash_StartRefreshTimer()
}

RestartViewer() {
    global g_ViewerPID, TIMING_SUBPROCESS_LAUNCH
    LauncherUtils_Restart("viewer", &g_ViewerPID, TIMING_SUBPROCESS_LAUNCH, _Launcher_Log)
    _Dash_StartRefreshTimer()
}

RestartAll() {
    global TIMING_PROCESS_EXIT_WAIT, TIMING_SUBPROCESS_LAUNCH

    _KillAllSubprocesses()
    _Dash_StartRefreshTimer()
    Sleep(TIMING_PROCESS_EXIT_WAIT)

    ; Relaunch core processes
    LaunchStore()
    Sleep(TIMING_SUBPROCESS_LAUNCH)
    LaunchGui()
}

ExitAll() {
    global g_ConfigEditorPID, g_BlacklistEditorPID
    _KillAllSubprocesses()
    ; Kill editors on full exit (not in _KillAllSubprocesses — editors survive RestartAll)
    if (g_ConfigEditorPID && ProcessExist(g_ConfigEditorPID))
        ProcessClose(g_ConfigEditorPID)
    if (g_BlacklistEditorPID && ProcessExist(g_BlacklistEditorPID))
        ProcessClose(g_BlacklistEditorPID)
    ExitApp()
}

_KillAllSubprocesses() {
    global g_StorePID, g_GuiPID, g_ViewerPID
    if (g_StorePID && ProcessExist(g_StorePID))
        ProcessClose(g_StorePID)
    if (g_GuiPID && ProcessExist(g_GuiPID))
        ProcessClose(g_GuiPID)
    if (g_ViewerPID && ProcessExist(g_ViewerPID))
        ProcessClose(g_ViewerPID)
    g_StorePID := 0
    g_GuiPID := 0
    g_ViewerPID := 0
}

LaunchConfigEditor() {
    global g_ConfigEditorPID
    ; If already running, activate existing window instead of launching duplicate
    if (g_ConfigEditorPID && ProcessExist(g_ConfigEditorPID)) {
        try WinActivate("Alt-Tabby Configuration ahk_pid " g_ConfigEditorPID)
        return
    }
    if (A_IsCompiled)
        Run('"' A_ScriptFullPath '" --config --launcher-hwnd=' A_ScriptHwnd, , , &g_ConfigEditorPID)
    else
        Run('"' A_AhkPath '" "' A_ScriptFullPath '" --config --launcher-hwnd=' A_ScriptHwnd, , , &g_ConfigEditorPID)
    _Dash_StartRefreshTimer()
}

LaunchBlacklistEditor() {
    global g_BlacklistEditorPID
    ; If already running, activate existing window instead of launching duplicate
    if (g_BlacklistEditorPID && ProcessExist(g_BlacklistEditorPID)) {
        try WinActivate("Alt-Tabby Blacklist Editor ahk_pid " g_BlacklistEditorPID)
        return
    }
    if (A_IsCompiled)
        Run('"' A_ScriptFullPath '" --blacklist', , , &g_BlacklistEditorPID)
    else
        Run('"' A_AhkPath '" "' A_ScriptFullPath '" --blacklist', , , &g_BlacklistEditorPID)
    _Dash_StartRefreshTimer()
}

RestartConfigEditor() {
    global g_ConfigEditorPID, TIMING_SUBPROCESS_LAUNCH
    if (g_ConfigEditorPID && ProcessExist(g_ConfigEditorPID))
        ProcessClose(g_ConfigEditorPID)
    g_ConfigEditorPID := 0
    Sleep(TIMING_SUBPROCESS_LAUNCH)
    LaunchConfigEditor()
}

RestartBlacklistEditor() {
    global g_BlacklistEditorPID, TIMING_SUBPROCESS_LAUNCH
    if (g_BlacklistEditorPID && ProcessExist(g_BlacklistEditorPID))
        ProcessClose(g_BlacklistEditorPID)
    g_BlacklistEditorPID := 0
    Sleep(TIMING_SUBPROCESS_LAUNCH)
    LaunchBlacklistEditor()
}

; ============================================================
; TRAY MENU TOGGLES
; ============================================================

; Race condition guard for admin toggle
; Uses file-based lock instead of timer to handle long UAC dialogs
global g_AdminToggleInProgress := false
global g_AdminToggleStartTick := 0  ; Tick-based timing instead of static counter

; Admin toggle timing constants
global ADMIN_TOGGLE_POLL_MS := 500
global ADMIN_TOGGLE_TIMEOUT_MS := 30000

ToggleAdminMode() {
    global cfg, gConfigIniPath, g_AdminToggleInProgress, TEMP_ADMIN_TOGGLE_LOCK
    global TOOLTIP_DURATION_SHORT, TOOLTIP_DURATION_DEFAULT, g_AdminToggleStartTick, APP_NAME
    global ADMIN_TOGGLE_POLL_MS

    ; Prevent re-entry during async elevation
    if (g_AdminToggleInProgress) {
        ToolTip("Operation in progress, please wait...")
        HideTooltipAfter(TOOLTIP_DURATION_SHORT)
        return
    }

    ; Check BOTH config AND task existence AND that task points to us
    ; This prevents state mismatch when config says enabled but task points elsewhere
    isCurrentlyEnabled := cfg.SetupRunAsAdmin && _AdminTask_PointsToUs()

    if (isCurrentlyEnabled) {
        ; Disable admin mode - doesn't require elevation
        DeleteAdminTask()
        cfg.SetupRunAsAdmin := false
        _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "RunAsAdmin", false, false, "bool")
        RecreateShortcuts()  ; Update shortcuts (still point to exe, but description changes)

        ; Offer restart to apply change immediately
        result := MsgBox("Admin mode disabled.`n`nRestart Alt-Tabby to run without elevation?", APP_NAME, "YesNo Icon?")
        if (result = "Yes") {
            ; Launch non-elevated via Explorer shell (de-escalation)
            launched := false
            if (A_IsAdmin) {
                try {
                    shell := ComObject("Shell.Application")
                    shell.ShellExecute(
                        A_IsCompiled ? A_ScriptFullPath : A_AhkPath,
                        A_IsCompiled ? "" : '"' A_ScriptFullPath '"',
                        A_ScriptDir)
                    launched := true
                }
            }
            if (!launched) {
                ; Fallback: direct launch (still elevated if we're admin, but better than nothing)
                if A_IsCompiled
                    Run('"' A_ScriptFullPath '"')
                else
                    Run('"' A_AhkPath '" "' A_ScriptFullPath '"')
            }
            ExitAll()
        } else {
            ToolTip("Admin mode disabled - changes apply on next launch")
            HideTooltipAfter(TOOLTIP_DURATION_DEFAULT)
        }
    } else {
        ; Enable admin mode - requires elevation to create scheduled task
        if (!A_IsAdmin) {
            result := MsgBox("Creating the admin task requires elevation.`n`nA UAC prompt will appear.", APP_NAME, "OKCancel Icon!")
            if (result = "Cancel")
                return

            ; Self-elevate with --enable-admin-task flag
            try {
                ; Create lock file before elevation (will be deleted by elevated instance)
                try FileDelete(TEMP_ADMIN_TOGGLE_LOCK)
                FileAppend(A_TickCount, TEMP_ADMIN_TOGGLE_LOCK)
                g_AdminToggleInProgress := true
                g_AdminToggleStartTick := A_TickCount  ; Track start time for timeout

                if (!_Launcher_RunAsAdmin("--enable-admin-task"))
                    throw Error("RunAsAdmin failed")

                ; Start polling for lock file deletion (elevated instance will delete it)
                SetTimer(_AdminToggle_CheckComplete, -ADMIN_TOGGLE_POLL_MS)
                ToolTip("Creating admin task...")
                HideTooltipAfter(TOOLTIP_DURATION_DEFAULT)
            } catch {
                g_AdminToggleInProgress := false
                try FileDelete(TEMP_ADMIN_TOGGLE_LOCK)
                MsgBox("UAC was cancelled. Admin mode was not enabled.", APP_NAME, "Icon!")
            }
            return
        }

        ; We're already admin - create task directly
        exePath := A_ScriptFullPath
        exeDir := ""
        SplitPath(exePath, , &exeDir)

        ; Warn if admin task would point to a temporary location
        if (!WarnIfTempLocation_AdminTask(exePath, exeDir))
            return

        if (CreateAdminTask(exePath)) {
            cfg.SetupRunAsAdmin := true
            _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "RunAsAdmin", true, false, "bool")
            RecreateShortcuts()  ; Update to point to schtasks
            ToolTip("Admin mode enabled")
            HideTooltipAfter(TOOLTIP_DURATION_SHORT)
        } else {
            MsgBox("Failed to create scheduled task.", APP_NAME, "Iconx")
        }
    }
}

; Polling callback to check if elevated instance completed
; Reads file content to determine outcome: numeric = still in progress, string = result
_AdminToggle_CheckComplete() {
    global g_AdminToggleInProgress, TEMP_ADMIN_TOGGLE_LOCK, g_AdminToggleStartTick
    global ADMIN_TOGGLE_POLL_MS, ADMIN_TOGGLE_TIMEOUT_MS
    global TOOLTIP_DURATION_DEFAULT, APP_NAME
    global ALTTABBY_TASK_NAME, TIMING_TASK_READY_WAIT, cfg, gConfigIniPath

    if (!FileExist(TEMP_ADMIN_TOGGLE_LOCK)) {
        ; Lock file gone entirely - elevated instance crashed or was killed
        g_AdminToggleInProgress := false
        TrayTip("Admin Mode", "Operation did not complete. The elevated process may have crashed.", "Icon!")
        return
    }

    ; Read file content to determine state
    try content := Trim(FileRead(TEMP_ADMIN_TOGGLE_LOCK), " `t`r`n")
    catch {
        ; File exists but can't read - retry
        SetTimer(_AdminToggle_CheckComplete, -ADMIN_TOGGLE_POLL_MS)
        return
    }

    ; Numeric content = original tick stamp = still in progress
    if (IsNumber(content)) {
        ; Use tick-based timing for timeout
        elapsed := A_TickCount - g_AdminToggleStartTick
        if (elapsed >= ADMIN_TOGGLE_TIMEOUT_MS) {
            g_AdminToggleInProgress := false
            try FileDelete(TEMP_ADMIN_TOGGLE_LOCK)
            TrayTip("Admin Mode", "Operation timed out. Please try again.`nIf the problem persists, restart Alt-Tabby.", "Icon!")
            return
        }
        ; Keep checking
        SetTimer(_AdminToggle_CheckComplete, -ADMIN_TOGGLE_POLL_MS)
        return
    }

    ; Non-numeric content = result from elevated instance
    g_AdminToggleInProgress := false
    try FileDelete(TEMP_ADMIN_TOGGLE_LOCK)

    if (content = "ok") {
        ; Re-read config from disk — the elevated instance wrote SetupRunAsAdmin=true
        if (FileExist(gConfigIniPath)) {
            iniVal := IniRead(gConfigIniPath, "Setup", "RunAsAdmin", "false")
            cfg.SetupRunAsAdmin := (iniVal = "true" || iniVal = "1")
        }

        ; Offer restart so the user gets elevation immediately
        result := MsgBox("Admin mode enabled.`n`nRestart Alt-Tabby now to run with elevation?", APP_NAME, "YesNo Icon?")
        if (result = "Yes") {
            ; Launch elevated instance via scheduled task
            Sleep(TIMING_TASK_READY_WAIT)
            exitCode := RunWait('schtasks /run /tn "' ALTTABBY_TASK_NAME '"',, "Hide")
            if (exitCode = 0) {
                ExitAll()
            } else {
                MsgBox("Failed to launch via scheduled task (exit code " exitCode ").`nPlease restart Alt-Tabby manually.", APP_NAME, "Iconx")
            }
        } else {
            ToolTip("Admin mode enabled - changes apply on next launch")
            HideTooltipAfter(TOOLTIP_DURATION_DEFAULT)
        }
    } else if (content = "cancelled") {
        ToolTip("Admin mode setup was cancelled")
        HideTooltipAfter(TOOLTIP_DURATION_DEFAULT)
    } else if (content = "failed") {
        MsgBox("Failed to create scheduled task.`nPlease try again.", APP_NAME, "Iconx")
    } else {
        TrayTip("Admin Mode", "Unexpected result: " content, "Icon!")
    }
}

ToggleAutoUpdate() {
    global cfg, gConfigIniPath, TOOLTIP_DURATION_SHORT
    cfg.SetupAutoUpdateCheck := !cfg.SetupAutoUpdateCheck
    _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "AutoUpdateCheck", cfg.SetupAutoUpdateCheck, true, "bool")
    _Dash_StartRefreshTimer()
    ToolTip(cfg.SetupAutoUpdateCheck ? "Auto-update enabled" : "Auto-update disabled")
    HideTooltipAfter(TOOLTIP_DURATION_SHORT)
}
