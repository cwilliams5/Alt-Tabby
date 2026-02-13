#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Cross-file globals (cfg, g_TestingMode, etc.) come from alt_tabby.ahk

; ============================================================
; Launcher Tray Menu - On-Demand Updates
; ============================================================
; Manages the system tray icon and context menu.
; Menu is rebuilt on right-click for current subprocess status.

; Cached expensive checks — populated at startup, updated after toggle operations.
; Avoids ~500ms of schtasks subprocess + COM shortcut calls on every right-click.
global g_CachedAdminTaskActive := false
global g_CachedStartMenuShortcut := false
global g_CachedStartupShortcut := false
global g_NeedsAdminReload := true  ; Flag for admin config reload (start true for initial load)

; Editor PIDs — declared here (sole writer via LaunchConfigEditor/LaunchBlacklistEditor)
global g_ConfigEditorPID := 0
global g_BlacklistEditorPID := 0

TrayIconClick(wParam, lParam, msg, hwnd) {
    ; 0x205 = WM_RBUTTONUP (right-click release)
    if (lParam = 0x205) {
        ; Dismiss splash screen if still showing — user wants to interact with tray,
        ; not wait for the splash duration to finish
        HideSplashScreen()
        _UpdateTrayMenu()
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
        iconPath := A_ScriptDir "\..\resources\img\icon.ico"
        if FileExist(iconPath)
            TraySetIcon(iconPath)
    }
    global APP_NAME
    A_IconTip := APP_NAME
    _Tray_RefreshCache()
    _UpdateTrayMenu()
}

_UpdateTrayMenu() {
    global cfg, gConfigIniPath, g_NeedsAdminReload

    ; Reload SetupRunAsAdmin from disk only when admin toggle may have occurred
    ; (avoids disk I/O on every right-click)
    if (g_NeedsAdminReload && FileExist(gConfigIniPath)) {
        cfg.SetupRunAsAdmin := ReadIniBool(gConfigIniPath, "Setup", "RunAsAdmin")
        g_NeedsAdminReload := false
    }

    tray := A_TrayMenu
    tray.Delete()

    ; Header with version
    version := GetAppVersion()
    header := "Alt-Tabby v" version
    tray.Add(header, (*) => 0)
    tray.Disable(header)
    tray.Add()

    ; Dev submenu (above Diagnostics, only when enabled)
    if (cfg.LauncherShowTrayDebugItems) {
        tray.Add("Dev", _Tray_BuildDevMenu())
        tray.Add()
    }

    ; Submenus
    tray.Add("Diagnostics", _Tray_BuildDiagnosticsMenu())
    tray.Add("Update", _Tray_BuildUpdateMenu())
    tray.Add("Settings", _Tray_BuildSettingsMenu())
    tray.Add()

    tray.Add("Show Stats...", (*) => ShowStatsDialog())

    ; "About / Help..." — bold via tray.Default, with app icon
    ; NOTE: The tray menu deliberately uses "About / Help..." while the popup window
    ; is called "Dashboard". This is an intentional UX decision — do not "fix" this.
    aboutLabel := "About / Help..."
    tray.Add(aboutLabel, (*) => ShowDashboardDialog())
    tray.Default := aboutLabel
    iconPath := _Tray_GetIconPath()
    if (iconPath != "") {
        if (A_IsCompiled)
            tray.SetIcon(aboutLabel, iconPath, 1)
        else
            tray.SetIcon(aboutLabel, iconPath)
    }
    tray.Add()

    tray.Add("Exit", (*) => _ExitAll())
}

; ============================================================
; SUBMENU BUILDERS
; ============================================================

_Tray_BuildDiagnosticsMenu() {
    global g_StorePID, g_GuiPID, g_ViewerPID, g_CachedAdminTaskActive
    global g_ConfigEditorPID, g_BlacklistEditorPID, cfg

    m := Menu()

    ; Build info (disabled)
    buildType := A_IsCompiled ? "Compiled" : "Dev"
    version := GetAppVersion()
    buildLabel := "Build: " buildType " v" version
    m.Add(buildLabel, (*) => 0)
    m.Disable(buildLabel)

    ; Komorebi status (disabled)
    kPid := ProcessExist("komorebi.exe")
    kLabel := kPid ? "Komorebi: Running (PID " kPid ")" : "Komorebi: Not Running"
    m.Add(kLabel, (*) => 0)
    m.Disable(kLabel)

    ; Elevation status (clickable — toggles admin mode)
    if (A_IsAdmin)
        elevLabel := "Elevation: Administrator | De-Escalate"
    else
        elevLabel := "Elevation: Standard | Escalate"
    m.Add(elevLabel, (*) => ToggleAdminMode())

    m.Add()

    ; Subprocess rows — label includes status AND action
    m.Add(_Tray_ComponentLabel("Window Tracker", g_StorePID), (*) => (LauncherUtils_IsRunning(g_StorePID) ? RestartStore() : LaunchStore()))
    m.Add(_Tray_ComponentLabel("Overlay", g_GuiPID), (*) => (LauncherUtils_IsRunning(g_GuiPID) ? RestartGui() : LaunchGui()))
    m.Add(_Tray_ComponentLabel("Config Editor", g_ConfigEditorPID), (*) => (LauncherUtils_IsRunning(g_ConfigEditorPID) ? RestartConfigEditor() : LaunchConfigEditor()))
    m.Add(_Tray_ComponentLabel("Blacklist Editor", g_BlacklistEditorPID), (*) => (LauncherUtils_IsRunning(g_BlacklistEditorPID) ? RestartBlacklistEditor() : LaunchBlacklistEditor()))
    m.Add(_Tray_ComponentLabel("Viewer", g_ViewerPID), (*) => (LauncherUtils_IsRunning(g_ViewerPID) ? RestartViewer() : LaunchViewer()))

    m.Add()

    ; Admin Task
    if (g_CachedAdminTaskActive)
        taskLabel := "Admin Task: Active | Uninstall"
    else
        taskLabel := "Admin Task: Not Configured | Install"
    m.Add(taskLabel, (*) => ToggleAdminMode())

    return m
}

_Tray_BuildUpdateMenu() {
    global g_DashUpdateState, g_LastUpdateCheckTime, cfg

    m := Menu()

    ; Status line (disabled)
    statusLabel := _Tray_GetUpdateStatusLabel()
    m.Add(statusLabel, (*) => 0)
    m.Disable(statusLabel)

    ; Action item
    if (g_DashUpdateState.status = "available" && g_DashUpdateState.version != "") {
        installLabel := "Install v" g_DashUpdateState.version
        m.Add(installLabel, (*) => _Tray_OnUpdateInstall())
    } else if (g_DashUpdateState.status = "checking") {
        checkingLabel := "Checking..."
        m.Add(checkingLabel, (*) => 0)
        m.Disable(checkingLabel)
    } else {
        m.Add("Check Now", (*) => CheckForUpdates(true))
    }

    m.Add()

    ; Auto-check toggle
    m.Add("Auto-Check for Updates", (*) => ToggleAutoUpdate())
    if (cfg.SetupAutoUpdateCheck)
        m.Check("Auto-Check for Updates")

    return m
}

_Tray_BuildSettingsMenu() {
    global cfg, g_CachedAdminTaskActive, g_CachedStartMenuShortcut, g_CachedStartupShortcut

    m := Menu()

    ; Editors
    m.Add("Edit Config...", (*) => LaunchConfigEditor())
    if (cfg.LauncherShowTrayDebugItems) {
        m.Add("Edit Config (AHK)...", (*) => LaunchConfigEditor(true))
        m.Add("Edit Config Registry...", (*) => _LaunchConfigRegistryEditor())
    }
    m.Add("Edit Blacklist...", (*) => LaunchBlacklistEditor())
    m.Add()

    ; Shortcut toggles
    m.Add("Add to Start Menu", (*) => ToggleStartMenuShortcut())
    if (g_CachedStartMenuShortcut)
        m.Check("Add to Start Menu")

    m.Add("Run at Startup", (*) => ToggleStartupShortcut())
    if (g_CachedStartupShortcut)
        m.Check("Run at Startup")

    ; Auto-check toggle (intentional duplicate — also in Update submenu)
    m.Add("Auto-Check for Updates", (*) => ToggleAutoUpdate())
    if (cfg.SetupAutoUpdateCheck)
        m.Check("Auto-Check for Updates")

    m.Add()

    ; Install to Program Files (action item, not toggle)
    if (A_IsCompiled) {
        if (IsInProgramFiles()) {
            pfLabel := "Installed to Program Files"
            m.Add(pfLabel, (*) => 0)
            m.Disable(pfLabel)
        } else {
            m.Add("Install to Program Files...", (*) => Tray_InstallToProgramFiles())
        }
    }

    ; Admin mode toggle
    m.Add("Run as Administrator", (*) => ToggleAdminMode())
    if (IsAdminModeFullyActive())
        m.Check("Run as Administrator")

    return m
}

_Tray_BuildDevMenu() {
    m := Menu()

    m.Add("Edit Config Registry...", (*) => _LaunchConfigRegistryEditor())
    m.Add()
    m.Add("First-Run Wizard", (*) => ShowFirstRunWizard())
    m.Add("Admin Repair Dialog", (*) => Launcher_ShowAdminRepairDialog("C:\fake\task\path.exe"))
    m.Add("Install Mismatch Dialog", (*) => Launcher_ShowMismatchDialog(
        "C:\Program Files\Alt-Tabby\AltTabby.exe",
        "Installation Mismatch",
        "Alt-Tabby is already installed at a different location:",
        "Would you like to update the installed version?"))
    m.Add("Blacklist Dialog", (*) => GUI_ShowBlacklistDialog("ExampleClass", "Example Window Title"))
    m.Add("ThemeMsgBox (All Features)", (*) => _Tray_TestThemeMsgBox())

    return m
}

_Tray_TestThemeMsgBox() {
    ; Exercise all icon types and button layouts
    ThemeMsgBox("This is an error message.", "Error Test", "Iconx")
    ThemeMsgBox("This is a warning message.", "Warning Test", "Icon!")
    ThemeMsgBox("This is an info message.", "Info Test", "Iconi")
    result := ThemeMsgBox("This is a question with YesNoCancel.`n`nDefault is button 2 (No).`n`nDo you want to proceed?",
        "Question Test", "YesNoCancel Icon? Default2")
    ThemeMsgBox("You chose: " result, "Result", "Iconi")
}

; ============================================================
; TRAY MENU HELPERS
; ============================================================

_Tray_ComponentLabel(label, pid) {
    return LauncherUtils_IsRunning(pid)
        ? label ": Running (PID " pid ") | Restart"
        : label ": Not Running | Launch"
}

_Tray_GetIconPath() {
    if (A_IsCompiled)
        return A_ScriptFullPath
    devIcon := A_ScriptDir "\..\resources\img\icon.ico"
    if (FileExist(devIcon))
        return devIcon
    return ""
}

_Tray_GetUpdateStatusLabel() {
    global g_DashUpdateState, g_LastUpdateCheckTime
    timeSuffix := (g_LastUpdateCheckTime != "") ? " | " g_LastUpdateCheckTime : ""

    switch g_DashUpdateState.status {
        case "unchecked": return "Not Checked"
        case "checking": return "Checking..."
        case "uptodate": return "Up to Date" timeSuffix
        case "available": return "v" g_DashUpdateState.version " Available" timeSuffix
        case "error": return "Check Failed" timeSuffix
        default: return "Not Checked"
    }
}

_Tray_RefreshCache() {
    global g_CachedAdminTaskActive, g_CachedStartMenuShortcut, g_CachedStartupShortcut
    g_CachedAdminTaskActive := AdminTask_PointsToUs()
    g_CachedStartMenuShortcut := Shortcut_StartMenuExists()
    g_CachedStartupShortcut := Shortcut_StartupExists()
}

_Tray_OnUpdateInstall() {
    global g_DashUpdateState
    if (g_DashUpdateState.status = "available" && g_DashUpdateState.downloadUrl != "")
        Update_DownloadAndApply(g_DashUpdateState.downloadUrl, g_DashUpdateState.version)
}

RestartStore() {
    Launcher_RestartStore()
    Dash_StartRefreshTimer()
}

RestartGui() {
    Launcher_RestartGui()
    Dash_StartRefreshTimer()
}

RestartViewer() {
    Launcher_RestartViewer()
    Dash_StartRefreshTimer()
}

_ExitAll() {
    global g_ConfigEditorPID, g_BlacklistEditorPID
    Launcher_ShutdownSubprocesses({config: g_ConfigEditorPID, blacklist: g_BlacklistEditorPID})
    ExitApp()
}

LaunchConfigEditor(forceNative := false) {
    global g_ConfigEditorPID, cfg
    ; If already running, activate existing window instead of launching duplicate
    if (g_ConfigEditorPID && ProcessExist(g_ConfigEditorPID)) {
        try WinActivate("ahk_pid " g_ConfigEditorPID)
        return
    }
    args := "--config --launcher-hwnd=" A_ScriptHwnd
    if (forceNative || cfg.LauncherForceNativeEditor)
        args .= " --force-native"
    Run(BuildSelfCommand(args), , , &g_ConfigEditorPID)
    Dash_StartRefreshTimer()
}

LaunchBlacklistEditor() {
    global g_BlacklistEditorPID
    ; If already running, activate existing window instead of launching duplicate
    if (g_BlacklistEditorPID && ProcessExist(g_BlacklistEditorPID)) {
        try WinActivate("Alt-Tabby Blacklist Editor ahk_pid " g_BlacklistEditorPID)
        return
    }
    Run(BuildSelfCommand("--blacklist"), , , &g_BlacklistEditorPID)
    Dash_StartRefreshTimer()
}

_LaunchConfigRegistryEditor() {
    global APP_NAME
    ; Standalone dev tool — not compiled into the exe, must find the .ahk file
    ; Dev mode: A_ScriptDir = src/ (from alt_tabby.ahk), so editors\...
    ; Compiled from project root: src\editors\...
    ; Compiled from release/: ..\src\editors\...
    scriptPath := ""
    candidates := [
        A_ScriptDir "\editors\config_registry_editor.ahk",
        A_ScriptDir "\src\editors\config_registry_editor.ahk",
        A_ScriptDir "\..\src\editors\config_registry_editor.ahk"
    ]
    for _, path in candidates {
        if (FileExist(path)) {
            scriptPath := path
            break
        }
    }

    if (scriptPath = "") {
        ThemeMsgBox("The Config Registry Editor is a developer-only tool and was not found relative to this installation.", APP_NAME, "Iconx")
        return
    }

    ; Need AHK v2 to run standalone script (cfg.AhkV2Path resolved at startup)
    global cfg
    ahkPath := (cfg.AhkV2Path != "" && FileExist(cfg.AhkV2Path)) ? cfg.AhkV2Path : A_AhkPath
    if (ahkPath = "" || !FileExist(ahkPath)) {
        ThemeMsgBox("AutoHotkey v2 not found. Set AhkV2Path in config or install AutoHotkey v2.", APP_NAME, "Iconx")
        return
    }
    try Run('"' ahkPath '" "' scriptPath '"')
    catch as e
        ThemeMsgBox("Failed to launch Config Registry Editor:`n" e.Message, APP_NAME, "Iconx")
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
    global cfg, gConfigIniPath, g_AdminToggleInProgress, TEMP_ADMIN_TOGGLE_LOCK, g_CachedAdminTaskActive
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
    isCurrentlyEnabled := IsAdminModeFullyActive()

    if (isCurrentlyEnabled) {
        ; Disable admin mode - try to delete task (may need elevation)
        deleted := DeleteAdminTask()
        if (!deleted && !A_IsAdmin) {
            ; Non-elevated — elevate to delete the task
            try {
                if (Launcher_RunAsAdmin("--disable-admin-task"))
                    Sleep(500)  ; Brief wait for elevated instance
                else
                    throw Error("RunAsAdmin failed")
            } catch {
                TrayTip("Admin Mode", "Could not remove scheduled task. It will be cleaned up on next restart.", "Icon!")
            }
        }
        g_CachedAdminTaskActive := false
        Setup_SetRunAsAdmin(false)
        RecreateShortcuts()  ; Update shortcuts (still point to exe, but description changes)

        ; Offer restart to apply change immediately
        result := ThemeMsgBox("Admin mode disabled.`n`nRestart Alt-Tabby to run without elevation?", APP_NAME, "YesNo Icon?")
        if (result = "Yes") {
            ; Launch non-elevated via Explorer shell (de-escalation)
            launched := false
            if (A_IsAdmin) {
                launched := LaunchDeElevated(
                    A_IsCompiled ? A_ScriptFullPath : A_AhkPath,
                    A_IsCompiled ? "" : '"' A_ScriptFullPath '"',
                    A_ScriptDir)
            }
            if (!launched) {
                ; Fallback: direct launch (still elevated if we're admin, but better than nothing)
                Run(BuildSelfCommand())
            }
            _ExitAll()
        } else {
            ToolTip("Admin mode disabled - changes apply on next launch")
            HideTooltipAfter(TOOLTIP_DURATION_DEFAULT)
        }
    } else {
        ; Enable admin mode - requires elevation to create scheduled task
        if (!A_IsAdmin) {
            result := ThemeMsgBox("Creating the admin task requires elevation.`n`nA UAC prompt will appear.", APP_NAME, "OKCancel Iconi")
            if (result = "Cancel")
                return

            ; Self-elevate with --enable-admin-task flag
            try {
                ; Create lock file before elevation (will be deleted by elevated instance)
                try FileDelete(TEMP_ADMIN_TOGGLE_LOCK)
                FileAppend(A_TickCount, TEMP_ADMIN_TOGGLE_LOCK)
                g_AdminToggleInProgress := true
                g_AdminToggleStartTick := A_TickCount  ; Track start time for timeout

                if (!Launcher_RunAsAdmin("--enable-admin-task"))
                    throw Error("RunAsAdmin failed")

                ; Start polling for lock file deletion (elevated instance will delete it)
                SetTimer(_AdminToggle_CheckComplete, -ADMIN_TOGGLE_POLL_MS)
                ToolTip("Creating admin task...")
                HideTooltipAfter(TOOLTIP_DURATION_DEFAULT)
            } catch {
                g_AdminToggleInProgress := false
                try FileDelete(TEMP_ADMIN_TOGGLE_LOCK)
                ThemeMsgBox("UAC was cancelled. Admin mode was not enabled.", APP_NAME, "Icon!")
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
            g_CachedAdminTaskActive := true
            Setup_SetRunAsAdmin(true)
            RecreateShortcuts()  ; Update to point to schtasks
            ToolTip("Admin mode enabled")
            HideTooltipAfter(TOOLTIP_DURATION_SHORT)
        } else {
            ThemeMsgBox("Failed to create scheduled task.", APP_NAME, "Iconx")
        }
    }
}

; Polling callback to check if elevated instance completed
; Reads file content to determine outcome: numeric = still in progress, string = result
_AdminToggle_CheckComplete() {
    global g_AdminToggleInProgress, TEMP_ADMIN_TOGGLE_LOCK, g_AdminToggleStartTick, g_CachedAdminTaskActive
    global ADMIN_TOGGLE_POLL_MS, ADMIN_TOGGLE_TIMEOUT_MS
    global TOOLTIP_DURATION_DEFAULT, APP_NAME
    global ALTTABBY_TASK_NAME, TIMING_TASK_READY_WAIT, TIMING_SUBPROCESS_LAUNCH, cfg, gConfigIniPath

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
        g_CachedAdminTaskActive := true
        ; Re-read config from disk — the elevated instance wrote SetupRunAsAdmin=true
        cfg.SetupRunAsAdmin := ReadIniBool(gConfigIniPath, "Setup", "RunAsAdmin")

        ; Offer restart so the user gets elevation immediately
        result := ThemeMsgBox("Admin mode enabled.`n`nRestart Alt-Tabby now to run with elevation?", APP_NAME, "YesNo Icon?")
        if (result = "Yes") {
            ; Shut down subprocesses FIRST so mutex releases before new instance boots
            Launcher_ShutdownSubprocesses()

            exitCode := RunAdminTask(TIMING_TASK_READY_WAIT)
            if (exitCode = 0) {
                ExitApp()
            } else {
                ; Task failed - relaunch store+gui as fallback
                LaunchStore()
                Sleep(TIMING_SUBPROCESS_LAUNCH)
                LaunchGui()
                ThemeMsgBox("Failed to launch via scheduled task (exit code " exitCode ").`nPlease restart Alt-Tabby manually.", APP_NAME, "Iconx")
            }
        } else {
            ToolTip("Admin mode enabled - changes apply on next launch")
            HideTooltipAfter(TOOLTIP_DURATION_DEFAULT)
        }
    } else if (content = "cancelled") {
        ToolTip("Admin mode setup was cancelled")
        HideTooltipAfter(TOOLTIP_DURATION_DEFAULT)
    } else if (content = "failed") {
        ThemeMsgBox("Failed to create scheduled task.`nPlease try again.", APP_NAME, "Iconx")
    } else {
        TrayTip("Admin Mode", "Unexpected result: " content, "Icon!")
    }
}

Tray_InstallToProgramFiles() {
    global APP_NAME, ALTTABBY_INSTALL_DIR, TEMP_INSTALL_PF_STATE
    global g_UpdateCheckInProgress

    if (!A_IsCompiled || IsInProgramFiles())
        return

    ; Prevent race with auto-update download (P4 fix)
    if (g_UpdateCheckInProgress) {
        ThemeMsgBox("An update check is in progress. Please wait for it to finish before installing.", APP_NAME, "Icon!")
        return
    }

    result := ThemeMsgBox(
        "Install Alt-Tabby to Program Files?`n`n"
        "Location: " ALTTABBY_INSTALL_DIR "`n`n"
        "This requires administrator privileges.`n"
        "Alt-Tabby will restart from the new location.",
        APP_NAME " - Install to Program Files",
        "OKCancel Icon?"
    )
    if (result = "Cancel")
        return

    ; Write state file: source<|>target (same format as update-installed)
    targetPath := ALTTABBY_INSTALL_DIR "\AltTabby.exe"
    WriteStateFile(TEMP_INSTALL_PF_STATE, A_ScriptFullPath, targetPath)

    ; Self-elevate and exit (elevated instance handles install + relaunch)
    try {
        if (!Launcher_RunAsAdmin("--install-to-pf"))
            throw Error("RunAsAdmin failed")
        _ExitAll()
    } catch {
        try FileDelete(TEMP_INSTALL_PF_STATE)
        ThemeMsgBox("Installation requires administrator privileges.`nThe UAC prompt may have been cancelled.", APP_NAME, "Icon!")
    }
}

ToggleAutoUpdate() {
    global cfg, gConfigIniPath, TOOLTIP_DURATION_SHORT, APP_NAME
    newValue := !cfg.SetupAutoUpdateCheck
    writeOk := false
    try writeOk := CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "AutoUpdateCheck", newValue, true, "bool")
    if (!writeOk) {
        ThemeMsgBox("Could not save setting. Config file may be read-only or locked.", APP_NAME, "Icon!")
        return
    }
    cfg.SetupAutoUpdateCheck := newValue
    Dash_StartRefreshTimer()
    ToolTip(newValue ? "Auto-update enabled" : "Auto-update disabled")
    HideTooltipAfter(TOOLTIP_DURATION_SHORT)
}
