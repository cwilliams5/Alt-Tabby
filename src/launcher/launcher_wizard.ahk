#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Cross-file globals (cfg, gConfigIniPath) come from alt_tabby.ahk

; ============================================================
; Launcher Wizard - First-Run Setup
; ============================================================
; Shows a setup wizard on first launch with options for:
; - Start Menu shortcut
; - Startup shortcut
; - Install to Program Files
; - Run as Administrator
; - Auto-update checking

; Wizard globals
global g_WizardGui := 0
global g_WizardShuttingDown := false  ; Shutdown coordination flag

; Mark first-run as completed and record exe path
_WizardMarkComplete() {
    Setup_SetFirstRunCompleted(true)
    Setup_SetExePath(A_ScriptFullPath)
}

ShowFirstRunWizard() {
    global g_WizardGui, cfg, gTheme_Palette

    dlgResult := Theme_CreateModalDialog("Welcome to Alt-Tabby", "+AlwaysOnTop", 468)
    g_WizardGui := dlgResult.gui
    themeEntry := dlgResult.themeEntry

    ; Logo (centered in 468px client width)
    _Wizard_LoadLogo(g_WizardGui)

    ; Subtitle in accent color
    sub := g_WizardGui.AddText("x24 w420 y+12 Center c" gTheme_Palette.accent, "Let's set up a few things to get you started:")
    Theme_MarkAccent(sub)

    ; Checkboxes - all pre-checked
    chk1 := g_WizardGui.AddCheckbox("vStartMenu x24 w420 y+14 Checked", "Add to Start Menu")
    chk2 := g_WizardGui.AddCheckbox("vStartup w420 y+8 Checked", "Run at Startup")
    chk3 := g_WizardGui.AddCheckbox("vInstall w420 y+8 Checked", "Install to Program Files")
    chk4 := g_WizardGui.AddCheckbox("vAdmin w420 y+8 Checked", "Run as Administrator")
    chk5 := g_WizardGui.AddCheckbox("vAutoUpdate w420 y+8 Checked", "Check for updates automatically")

    ; Muted note
    note := g_WizardGui.AddText("w420 y+16 c" Theme_GetMutedColor() " +Wrap",
        "Run as Administrator allows detecting Alt-Tab from certain apps like Task Manager "
        "that otherwise won't. This and Install to Program Files require a one-time "
        "permissions approval (UAC).")
    note.SetFont("s8", "Segoe UI")
    Theme_MarkMuted(note)

    ; Buttons - right-aligned (Apply + gap + Skip = 120+8+100 = 228, right edge at 444)
    btn2 := g_WizardGui.AddButton("x216 w120 y+20 Default", "Apply && Launch")
    btn2.OnEvent("Click", _WizardApply)
    btn1 := g_WizardGui.AddButton("w100 x+8", "Skip")
    btn1.OnEvent("Click", _WizardSkip)

    Theme_ApplyToControl(chk1, "Checkbox", themeEntry)
    Theme_ApplyToControl(chk2, "Checkbox", themeEntry)
    Theme_ApplyToControl(chk3, "Checkbox", themeEntry)
    Theme_ApplyToControl(chk4, "Checkbox", themeEntry)
    Theme_ApplyToControl(chk5, "Checkbox", themeEntry)
    Theme_ApplyToControl(btn1, "Button", themeEntry)
    Theme_ApplyToControl(btn2, "Button", themeEntry)

    g_WizardGui.OnEvent("Close", _WizardSkip)
    Theme_ShowModalDialog(g_WizardGui, 468)
}

; Load logo into wizard GUI (centered, 116x90)
_Wizard_LoadLogo(wg) {
    global gTheme_Palette, RES_ID_LOGO
    ; Center logo: (468 client width - 116 logo width) / 2 = 176
    logoOpts := "x176 w116 h90"

    ; Dev mode: load from file
    if (!A_IsCompiled) {
        imgPath := A_ScriptDir "\..\resources\img\logo.png"
        if (FileExist(imgPath))
            wg.AddPicture(logoOpts, imgPath)
        return
    }

    ; Compiled mode: use shared GDI+ thumbnail loader
    hBitmap := LauncherUtils_LoadGdipThumb(RES_ID_LOGO, 116, 90)
    if (!hBitmap)
        return

    wg.AddPicture(logoOpts, "HBITMAP:*" hBitmap)
}

_WizardSkip(*) {
    global g_WizardGui, g_WizardShuttingDown, cfg, gConfigIniPath
    if (g_WizardShuttingDown)
        return
    g_WizardShuttingDown := true

    ; Mark first-run as completed even if skipped
    ; Also record exe path so mismatch detection works for custom locations
    _WizardMarkComplete()

    try g_WizardGui.Destroy()

    ; Brief note about configuring later
    TrayTip("Alt-Tabby", "Setup skipped. Configure later from tray menu.", "Icon!")
}

_WizardApply(*) {
    global g_WizardGui, g_WizardShuttingDown, cfg, gConfigIniPath
    if (g_WizardShuttingDown)
        return
    g_WizardShuttingDown := true

    ; Get checkbox states
    startMenu := g_WizardGui["StartMenu"].Value
    startup := g_WizardGui["Startup"].Value
    install := g_WizardGui["Install"].Value
    admin := g_WizardGui["Admin"].Value
    autoUpdate := g_WizardGui["AutoUpdate"].Value

    ; Check if selected options require admin
    needsAdmin := install || admin
    if (needsAdmin && !A_IsAdmin) {
        ; Save wizard choices to temp file, re-launch elevated with --wizard-continue flag
        choices := JSON.Dump(Map(
            "startMenu", startMenu,
            "startup", startup,
            "install", install,
            "admin", admin,
            "autoUpdate", autoUpdate
        ))
        choicesFile := A_Temp "\alttabby_wizard.json"
        try FileDelete(choicesFile)
        FileAppend(choices, choicesFile, "UTF-8")

        ; Self-elevate and continue wizard
        ; User may cancel UAC - handle gracefully
        try {
            if (!Launcher_RunAsAdmin("--wizard-continue"))
                throw Error("RunAsAdmin failed")

            g_WizardGui.Destroy()
            ExitApp()  ; Exit non-elevated instance
        } catch as e {
            ; UAC was cancelled or failed - clean up temp file and ask user
            try FileDelete(choicesFile)
            result := ThemeMsgBox(
                "Administrator privileges are required for:`n"
                "- Install to Program Files`n"
                "- Run as Administrator`n`n"
                "These options will be skipped.`n`n"
                "Continue with remaining options (shortcuts, auto-update)?",
                "Alt-Tabby Setup",
                "YesNo Icon?"
            )
            if (result = "No") {
                ; Mark first-run as completed so wizard doesn't show on every launch
                _WizardMarkComplete()
                g_WizardShuttingDown := false  ; Allow clean exit
                try g_WizardGui.Destroy()
                return  ; Exit wizard completely
            }
            ; Continue with non-admin options only
            install := false
            admin := false
            ; Temp location warning is now handled in _WizardApplyChoices()
        }
    }

    ; Apply choices (without admin options if UAC was cancelled)
    _WizardApplyChoices(startMenu, startup, install, admin, autoUpdate)
    try g_WizardGui.Destroy()

    ; Show completion feedback (unless self-elevating, which exits before reaching here)
    TrayTip("Alt-Tabby", "Setup complete! Alt-Tabby is now running.", "Icon!")
}

; Called when --wizard-continue flag is passed (after elevation)
; Returns: "installed" if we should launch from new location, true if normal continue, false on error
WizardContinue() {
    global cfg, gConfigIniPath, ALTTABBY_TASK_NAME, TIMING_TASK_READY_WAIT

    choicesFile := A_Temp "\alttabby_wizard.json"
    if (!FileExist(choicesFile))
        return false

    ; Read saved choices
    try {
        choicesJson := FileRead(choicesFile, "UTF-8")
        FileDelete(choicesFile)  ; Delete immediately after reading
        choices := JSON.Load(choicesJson)
    } catch {
        try FileDelete(choicesFile)  ; Safety cleanup if read succeeded but delete/parse failed
        return false
    }

    ; Apply the choices (we're elevated now)
    ; Returns the installed exe path if we installed elsewhere, empty string otherwise
    installedPath := _WizardApplyChoices(
        choices["startMenu"],
        choices["startup"],
        choices["install"],
        choices["admin"],
        choices["autoUpdate"]
    )

    ; If we installed to a different location, launch from there
    if (installedPath != "") {
        if (cfg.SetupRunAsAdmin && AdminTaskExists()) {
            ; Launch via schtasks for immediate elevation (avoids intermediate non-elevated hop)
            exitCode := RunAdminTask(TIMING_TASK_READY_WAIT)
            if (exitCode != 0)
                Run('"' installedPath '"')  ; Fallback to direct launch
        } else {
            Run('"' installedPath '"')
        }
        return "installed"
    }

    return true
}

; Internal: Apply wizard choices (called from both wizard and continuation)
; Returns the installed exe path if we installed to a different location, empty string otherwise
_WizardApplyChoices(startMenu, startup, install, admin, autoUpdate) {
    global cfg, gConfigIniPath, APP_NAME, ALTTABBY_INSTALL_DIR

    ; Determine exe path
    exePath := A_ScriptFullPath
    installedElsewhere := ""
    installSucceeded := false

    ; Step 1: Install to Program Files (if selected)
    ; Uses Update_ApplyCore() — same code path as tray/dashboard install and auto-update
    if (install) {
        targetPath := ALTTABBY_INSTALL_DIR "\AltTabby.exe"
        if (IsInProgramFiles()) {
            ; Already in Program Files
            installSucceeded := true
        } else {
            installOk := false
            try {
                Update_ApplyCore({
                    sourcePath: A_ScriptFullPath,
                    targetPath: targetPath,
                    useLockFile: false,
                    validatePE: false,
                    copyMode: true,
                    cleanupSourceOnFailure: false,
                    relaunchAfter: false
                })
                installOk := true
            } catch as e {
                if (cfg.DiagLauncherLog)
                    Launcher_Log("WIZARD PF install failed: " e.Message)
            }
            if (installOk && FileExist(targetPath)) {
                exePath := targetPath
                installedElsewhere := targetPath
                installSucceeded := true
                ; Update config path to point to new location so subsequent writes go there
                newDir := ""
                SplitPath(targetPath, , &newDir)
                ConfigLoader_SetBasePath(newDir)

                ; Ensure PF config has our InstallationId (may differ if PF had existing config)
                if (cfg.HasOwnProp("SetupInstallationId") && cfg.SetupInstallationId != "")
                    Setup_SetInstallationId(cfg.SetupInstallationId)
            }
        }
    }

    ; Step 1.5: Clean up stale admin task if admin mode was NOT selected.
    ; We're elevated (install requires it), so we can delete.
    ; Without this, a previous install's task forces admin mode on the new install.
    if (!admin && install && installSucceeded && AdminTaskExists()) {
        DeleteAdminTask()
    }

    ; Step 2: Create admin task (if selected) - needs final exe path
    if (admin) {
        ; Only create admin task if:
        ; - Install wasn't requested, OR
        ; - Install was requested AND succeeded
        ; This prevents stale task pointing to temporary location
        if (!install || installSucceeded) {
            ; Warn if admin task would point to a temporary location (no install selected)
            if (!install && !WarnIfTempLocation_AdminTask(exePath, A_ScriptDir,
                    "Consider using 'Install to Program Files' for a permanent setup."))
                admin := false

            if (admin) {
                if (CreateAdminTask(exePath)) {
                    Setup_SetRunAsAdmin(true)
                } else {
                    ; Task creation failed - notify user
                    ThemeMsgBox("Admin mode could not be enabled.`nAlt-Tabby will run with standard permissions — most features still work.", APP_NAME, "Icon!")
                    admin := false  ; Prevent Step 3 (line 312) from writing RunAsAdmin=true
                }
            }
        } else {
            ; Install was requested but failed - don't create task pointing to temp location
            ThemeMsgBox("Admin mode requires successful installation.`nPlease try again or enable admin mode later from the tray menu.", APP_NAME, "Iconx")
        }
    }

    ; Step 3: Save config
    Setup_SetAutoUpdateCheck(autoUpdate)
    Setup_SetFirstRunCompleted(true)
    Setup_SetExePath(exePath)
    Setup_SetRunAsAdmin(admin)

    ; Step 4: Create shortcuts AFTER admin mode is set (so they point correctly)
    ; Warn if shortcuts will point to a temporary location (unless PF install succeeded)
    if ((startMenu || startup) && !installSucceeded) {
        if (WarnTemporaryLocation(exePath, "shortcuts", "will point to", "the shortcuts will break", "Create shortcuts anyway?") = "No") {
            startMenu := false
            startup := false
        }
    }
    if (startMenu)
        CreateShortcutForCurrentMode(Shortcut_GetStartMenuPath())
    if (startup)
        CreateShortcutForCurrentMode(Shortcut_GetStartupPath())

    return installedElsewhere
}
