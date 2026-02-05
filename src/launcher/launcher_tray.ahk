#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Cross-file globals (cfg, g_StorePID, etc.) come from alt_tabby.ahk

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
        iconPath := A_ScriptDir "\..\resources\icon.ico"
        if FileExist(iconPath)
            TraySetIcon(iconPath)
    }
    global APP_NAME
    A_IconTip := APP_NAME
    _Tray_RefreshCache()
    UpdateTrayMenu()
}

UpdateTrayMenu() {
    global cfg, gConfigIniPath

    ; Reload SetupRunAsAdmin from disk in case elevated instance changed it
    if (FileExist(gConfigIniPath)) {
        iniVal := IniRead(gConfigIniPath, "Setup", "RunAsAdmin", "false")
        cfg.SetupRunAsAdmin := (iniVal = "true" || iniVal = "1")
    }

    tray := A_TrayMenu
    tray.Delete()

    ; Header with version
    version := GetAppVersion()
    header := "Alt-Tabby v" version
    tray.Add(header, (*) => 0)
    tray.Disable(header)
    tray.Add()

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

    tray.Add("Exit", (*) => ExitAll())
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
    ; Store
    storeRunning := LauncherUtils_IsRunning(g_StorePID)
    storeLabel := storeRunning
        ? "Store: Running (PID " g_StorePID ") | Restart"
        : "Store: Not Running | Launch"
    m.Add(storeLabel, (*) => (LauncherUtils_IsRunning(g_StorePID) ? RestartStore() : LaunchStore()))

    ; GUI
    guiRunning := LauncherUtils_IsRunning(g_GuiPID)
    guiLabel := guiRunning
        ? "GUI: Running (PID " g_GuiPID ") | Restart"
        : "GUI: Not Running | Launch"
    m.Add(guiLabel, (*) => (LauncherUtils_IsRunning(g_GuiPID) ? RestartGui() : LaunchGui()))

    ; Config Editor
    configRunning := LauncherUtils_IsRunning(g_ConfigEditorPID)
    configLabel := configRunning
        ? "Config Editor: Running (PID " g_ConfigEditorPID ") | Restart"
        : "Config Editor: Not Running | Launch"
    m.Add(configLabel, (*) => (LauncherUtils_IsRunning(g_ConfigEditorPID) ? RestartConfigEditor() : LaunchConfigEditor()))

    ; Blacklist Editor
    blacklistRunning := LauncherUtils_IsRunning(g_BlacklistEditorPID)
    blacklistLabel := blacklistRunning
        ? "Blacklist Editor: Running (PID " g_BlacklistEditorPID ") | Restart"
        : "Blacklist Editor: Not Running | Launch"
    m.Add(blacklistLabel, (*) => (LauncherUtils_IsRunning(g_BlacklistEditorPID) ? RestartBlacklistEditor() : LaunchBlacklistEditor()))

    ; Viewer
    viewerRunning := LauncherUtils_IsRunning(g_ViewerPID)
    viewerLabel := viewerRunning
        ? "Viewer: Running (PID " g_ViewerPID ") | Restart"
        : "Viewer: Not Running | Launch"
    m.Add(viewerLabel, (*) => (LauncherUtils_IsRunning(g_ViewerPID) ? RestartViewer() : LaunchViewer()))

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

    ; Admin mode toggle
    m.Add("Run as Administrator", (*) => ToggleAdminMode())
    if (cfg.SetupRunAsAdmin && g_CachedAdminTaskActive)
        m.Check("Run as Administrator")

    return m
}

; ============================================================
; TRAY MENU HELPERS
; ============================================================

_Tray_GetIconPath() {
    if (A_IsCompiled)
        return A_ScriptFullPath
    devIcon := A_ScriptDir "\..\resources\icon.ico"
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
    g_CachedAdminTaskActive := _AdminTask_PointsToUs()
    g_CachedStartMenuShortcut := _Shortcut_StartMenuExists()
    g_CachedStartupShortcut := _Shortcut_StartupExists()
}

_Tray_OnUpdateInstall() {
    global g_DashUpdateState
    if (g_DashUpdateState.status = "available" && g_DashUpdateState.downloadUrl != "")
        _Update_DownloadAndApply(g_DashUpdateState.downloadUrl, g_DashUpdateState.version)
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

ExitAll() {
    global g_ConfigEditorPID, g_BlacklistEditorPID
    ; Hard kill editors on full exit (not in _GracefulShutdown — editors survive restarts)
    if (g_ConfigEditorPID && ProcessExist(g_ConfigEditorPID))
        ProcessClose(g_ConfigEditorPID)
    if (g_BlacklistEditorPID && ProcessExist(g_BlacklistEditorPID))
        ProcessClose(g_BlacklistEditorPID)
    _GracefulShutdown()
    ExitApp()
}

_GracefulShutdown() {
    global g_StorePID, g_GuiPID, g_ViewerPID

    ; 1. Hard kill non-core processes (viewer)
    if (g_ViewerPID && ProcessExist(g_ViewerPID))
        ProcessClose(g_ViewerPID)
    g_ViewerPID := 0

    ; PostMessage needs to find AHK's hidden message windows
    prevDHW := A_DetectHiddenWindows
    DetectHiddenWindows(true)

    ; 2. Graceful shutdown GUI first (sends final stats to still-alive store)
    if (g_GuiPID && ProcessExist(g_GuiPID)) {
        ; Target AHK's hidden message window (class "AutoHotkey"), not GUI windows
        ; (class "AutoHotkeyGUI") — WM_CLOSE on a Gui window just hides it
        try PostMessage(0x0010, , , , "ahk_pid " g_GuiPID " ahk_class AutoHotkey")  ; WM_CLOSE
        deadline := A_TickCount + 3000
        while (ProcessExist(g_GuiPID) && A_TickCount < deadline)
            Sleep(10)
        if (ProcessExist(g_GuiPID))
            ProcessClose(g_GuiPID)
    }
    g_GuiPID := 0

    ; 3. Graceful shutdown store second (flushes stats to disk)
    if (g_StorePID && ProcessExist(g_StorePID)) {
        try PostMessage(0x0010, , , , "ahk_pid " g_StorePID " ahk_class AutoHotkey")  ; WM_CLOSE
        deadline := A_TickCount + 5000
        while (ProcessExist(g_StorePID) && A_TickCount < deadline)
            Sleep(10)
        if (ProcessExist(g_StorePID))
            ProcessClose(g_StorePID)
    }
    g_StorePID := 0

    DetectHiddenWindows(prevDHW)
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
    isCurrentlyEnabled := cfg.SetupRunAsAdmin && g_CachedAdminTaskActive

    if (isCurrentlyEnabled) {
        ; Disable admin mode - doesn't require elevation
        DeleteAdminTask()
        g_CachedAdminTaskActive := false
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
            result := MsgBox("Creating the admin task requires elevation.`n`nA UAC prompt will appear.", APP_NAME, "OKCancel Iconi")
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
            g_CachedAdminTaskActive := true
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
    global g_AdminToggleInProgress, TEMP_ADMIN_TOGGLE_LOCK, g_AdminToggleStartTick, g_CachedAdminTaskActive
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
        g_CachedAdminTaskActive := true
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
