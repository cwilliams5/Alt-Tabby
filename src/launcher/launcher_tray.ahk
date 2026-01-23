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
    global g_StorePID
    if (g_StorePID && ProcessExist(g_StorePID))
        ProcessClose(g_StorePID)
    g_StorePID := 0
    Sleep(300)
    LaunchStore()
}

RestartGui() {
    global g_GuiPID
    if (g_GuiPID && ProcessExist(g_GuiPID))
        ProcessClose(g_GuiPID)
    g_GuiPID := 0
    Sleep(300)
    LaunchGui()
}

RestartViewer() {
    global g_ViewerPID
    if (g_ViewerPID && ProcessExist(g_ViewerPID))
        ProcessClose(g_ViewerPID)
    g_ViewerPID := 0
    Sleep(300)
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

    Sleep(500)

    ; Relaunch core processes
    LaunchStore()
    Sleep(300)
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
    ; Run config editor with auto-restart enabled
    ; Returns true if changes were saved
    if (ConfigEditor_Run(true)) {
        ; Restart store and GUI to apply changes
        RestartStore()
        Sleep(300)
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

ToggleAdminMode() {
    global cfg, gConfigIniPath

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
            SetTimer(() => ToolTip(), -2000)
        }
    } else {
        ; Enable admin mode - requires elevation to create scheduled task
        if (!A_IsAdmin) {
            result := MsgBox("Creating the admin task requires elevation.`n`nA UAC prompt will appear.", "Alt-Tabby", "OKCancel Icon!")
            if (result = "Cancel")
                return

            ; Self-elevate with --enable-admin-task flag
            try {
                if A_IsCompiled
                    Run('*RunAs "' A_ScriptFullPath '" --enable-admin-task')
                else
                    Run('*RunAs "' A_AhkPath '" "' A_ScriptFullPath '" --enable-admin-task')
                ; Don't exit - the elevated instance will create the task and exit
                ; We'll see the result on next tray menu open
                ToolTip("Creating admin task...")
                SetTimer(() => ToolTip(), -2000)
            } catch {
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
            SetTimer(() => ToolTip(), -1500)
        } else {
            MsgBox("Failed to create scheduled task.", "Alt-Tabby", "Iconx")
        }
    }
}

ToggleAutoUpdate() {
    global cfg, gConfigIniPath
    cfg.SetupAutoUpdateCheck := !cfg.SetupAutoUpdateCheck
    _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "AutoUpdateCheck", cfg.SetupAutoUpdateCheck, true, "bool")
    ToolTip(cfg.SetupAutoUpdateCheck ? "Auto-update enabled" : "Auto-update disabled")
    SetTimer(() => ToolTip(), -1500)
}
