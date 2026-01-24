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
    A_IconTip := "Alt-Tabby"
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
    storeRunning := g_StorePID && ProcessExist(g_StorePID)
    if (storeRunning) {
        tray.Add("Store: Restart", (*) => RestartStore())
    } else {
        tray.Add("Store: Launch", (*) => LaunchStore())
    }

    ; GUI status
    guiRunning := g_GuiPID && ProcessExist(g_GuiPID)
    if (guiRunning) {
        tray.Add("GUI: Restart", (*) => RestartGui())
    } else {
        tray.Add("GUI: Launch", (*) => LaunchGui())
    }

    ; Viewer status (optional, launch from menu)
    viewerRunning := g_ViewerPID && ProcessExist(g_ViewerPID)
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
    if (cfg.SetupRunAsAdmin && AdminTaskExists())
        tray.Check("Run as Administrator")

    tray.Add()

    ; Updates section
    tray.Add("Check for Updates Now", (*) => CheckForUpdates(true))
    tray.Add("Auto-check on Startup", (*) => ToggleAutoUpdate())
    if (cfg.SetupAutoUpdateCheck)
        tray.Check("Auto-check on Startup")

    tray.Add()

    tray.Add("Exit", (*) => ExitAll())
}

RestartStore() {
    global g_StorePID, TIMING_SUBPROCESS_LAUNCH
    if (g_StorePID && ProcessExist(g_StorePID))
        ProcessClose(g_StorePID)
    g_StorePID := 0
    Sleep(TIMING_SUBPROCESS_LAUNCH)
    LaunchStore()
}

RestartGui() {
    global g_GuiPID, TIMING_SUBPROCESS_LAUNCH
    if (g_GuiPID && ProcessExist(g_GuiPID))
        ProcessClose(g_GuiPID)
    g_GuiPID := 0
    Sleep(TIMING_SUBPROCESS_LAUNCH)
    LaunchGui()
}

RestartViewer() {
    global g_ViewerPID, TIMING_SUBPROCESS_LAUNCH
    if (g_ViewerPID && ProcessExist(g_ViewerPID))
        ProcessClose(g_ViewerPID)
    g_ViewerPID := 0
    Sleep(TIMING_SUBPROCESS_LAUNCH)
    LaunchViewer()
}

RestartAll() {
    global g_StorePID, g_GuiPID, g_ViewerPID

    ; Kill existing processes
    if (g_StorePID && ProcessExist(g_StorePID))
        ProcessClose(g_StorePID)
    if (g_GuiPID && ProcessExist(g_GuiPID))
        ProcessClose(g_GuiPID)
    if (g_ViewerPID && ProcessExist(g_ViewerPID))
        ProcessClose(g_ViewerPID)

    g_StorePID := 0
    g_GuiPID := 0
    g_ViewerPID := 0

    Sleep(TIMING_PROCESS_EXIT_WAIT)

    ; Relaunch core processes
    LaunchStore()
    Sleep(TIMING_SUBPROCESS_LAUNCH)
    LaunchGui()
}

ExitAll() {
    global g_StorePID, g_GuiPID, g_ViewerPID

    ; Kill all subprocesses
    if (g_StorePID && ProcessExist(g_StorePID))
        ProcessClose(g_StorePID)
    if (g_GuiPID && ProcessExist(g_GuiPID))
        ProcessClose(g_GuiPID)
    if (g_ViewerPID && ProcessExist(g_ViewerPID))
        ProcessClose(g_ViewerPID)

    ExitApp()
}

LaunchConfigEditor() {
    global TIMING_SUBPROCESS_LAUNCH
    ; Run config editor with auto-restart enabled
    ; Returns true if changes were saved
    if (ConfigEditor_Run(true)) {
        ; Restart store and GUI to apply changes
        RestartStore()
        Sleep(TIMING_SUBPROCESS_LAUNCH)
        RestartGui()
    }
}

LaunchBlacklistEditor() {
    ; Run blacklist editor
    ; IPC reload is sent automatically by the editor
    BlacklistEditor_Run()
}

; ============================================================
; TRAY MENU TOGGLES
; ============================================================

; Race condition guard for admin toggle
; Uses file-based lock instead of timer to handle long UAC dialogs
global g_AdminToggleInProgress := false
global g_AdminToggleLockFile := A_Temp "\alttabby_admin_toggle.lock"
global g_AdminToggleStartTick := 0  ; Tick-based timing instead of static counter

ToggleAdminMode() {
    global cfg, gConfigIniPath, g_AdminToggleInProgress, g_AdminToggleLockFile

    ; Prevent re-entry during async elevation
    if (g_AdminToggleInProgress) {
        ToolTip("Operation in progress, please wait...")
        HideTooltipAfter(TOOLTIP_DURATION_SHORT)
        return
    }

    if (cfg.SetupRunAsAdmin) {
        ; Disable admin mode - doesn't require elevation
        DeleteAdminTask()
        cfg.SetupRunAsAdmin := false
        _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "RunAsAdmin", false, false, "bool")
        RecreateShortcuts()  ; Update shortcuts (still point to exe, but description changes)

        ; Offer restart to apply change immediately
        result := MsgBox("Admin mode disabled.`n`nRestart Alt-Tabby to run without elevation?", "Alt-Tabby", "YesNo Icon?")
        if (result = "Yes") {
            ; Restart non-elevated by running the exe directly
            if A_IsCompiled
                Run('"' A_ScriptFullPath '"')
            else
                Run('"' A_AhkPath '" "' A_ScriptFullPath '"')
            ExitAll()
        } else {
            ToolTip("Admin mode disabled - changes apply on next launch")
            HideTooltipAfter(TOOLTIP_DURATION_DEFAULT)
        }
    } else {
        ; Enable admin mode - requires elevation to create scheduled task
        if (!A_IsAdmin) {
            result := MsgBox("Creating the admin task requires elevation.`n`nA UAC prompt will appear.", "Alt-Tabby", "OKCancel Icon!")
            if (result = "Cancel")
                return

            ; Self-elevate with --enable-admin-task flag
            try {
                ; Create lock file before elevation (will be deleted by elevated instance)
                try FileDelete(g_AdminToggleLockFile)
                FileAppend(A_TickCount, g_AdminToggleLockFile)
                g_AdminToggleInProgress := true
                g_AdminToggleStartTick := A_TickCount  ; Track start time for timeout

                if A_IsCompiled
                    Run('*RunAs "' A_ScriptFullPath '" --enable-admin-task')
                else
                    Run('*RunAs "' A_AhkPath '" "' A_ScriptFullPath '" --enable-admin-task')

                ; Start polling for lock file deletion (elevated instance will delete it)
                ; Check every 500ms, timeout after 30 seconds
                SetTimer(_AdminToggle_CheckComplete, -500)
                ToolTip("Creating admin task...")
                HideTooltipAfter(TOOLTIP_DURATION_DEFAULT)
            } catch {
                g_AdminToggleInProgress := false
                try FileDelete(g_AdminToggleLockFile)
                MsgBox("UAC was cancelled. Admin mode was not enabled.", "Alt-Tabby", "Icon!")
            }
            return
        }

        ; We're already admin - create task directly
        exePath := _Shortcut_GetEffectiveExePath()
        if (CreateAdminTask(exePath)) {
            cfg.SetupRunAsAdmin := true
            _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "RunAsAdmin", true, false, "bool")
            RecreateShortcuts()  ; Update to point to schtasks
            ToolTip("Admin mode enabled")
            HideTooltipAfter(TOOLTIP_DURATION_SHORT)
        } else {
            MsgBox("Failed to create scheduled task.", "Alt-Tabby", "Iconx")
        }
    }
}

; Polling callback to check if elevated instance completed
; Uses tick-based timing for timeout (30 seconds) to prevent static variable state leaks
_AdminToggle_CheckComplete() {
    global g_AdminToggleInProgress, g_AdminToggleLockFile, g_AdminToggleStartTick

    if (!FileExist(g_AdminToggleLockFile)) {
        ; Lock file deleted - elevated instance completed
        g_AdminToggleInProgress := false
        return
    }

    ; Use tick-based timing instead of static counter (prevents state leaks if timer cancelled)
    elapsed := A_TickCount - g_AdminToggleStartTick
    if (elapsed >= 30000) {  ; 30 seconds
        ; Timeout - assume something went wrong
        g_AdminToggleInProgress := false
        try FileDelete(g_AdminToggleLockFile)
        return
    }

    ; Keep checking
    SetTimer(_AdminToggle_CheckComplete, -500)
}

ToggleAutoUpdate() {
    global cfg, gConfigIniPath
    cfg.SetupAutoUpdateCheck := !cfg.SetupAutoUpdateCheck
    _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "AutoUpdateCheck", cfg.SetupAutoUpdateCheck, true, "bool")
    ToolTip(cfg.SetupAutoUpdateCheck ? "Auto-update enabled" : "Auto-update disabled")
    HideTooltipAfter(TOOLTIP_DURATION_SHORT)
}
