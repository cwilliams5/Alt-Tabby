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

ShowFirstRunWizard() {
    global g_WizardGui, cfg

    g_WizardGui := Gui("+AlwaysOnTop", "Welcome to Alt-Tabby")
    g_WizardGui.SetFont("s10", "Segoe UI")

    g_WizardGui.AddText("w400", "Let's set up a few things to get you started:")
    g_WizardGui.AddText("w400 y+5", "")

    g_WizardGui.AddCheckbox("vStartMenu w400", "Add to Start Menu")
    g_WizardGui.AddCheckbox("vStartup w400 Checked", "Run at Startup (recommended)")
    g_WizardGui.AddCheckbox("vInstall w400", "Install to Program Files")
    g_WizardGui.AddCheckbox("vAdmin w400", "Run as Administrator (for elevated windows)")
    g_WizardGui.AddCheckbox("vAutoUpdate w400 Checked", "Check for updates automatically")

    g_WizardGui.AddText("w400 y+15 cGray", "Note: 'Install to Program Files' and 'Run as Administrator'")
    g_WizardGui.AddText("w400 cGray", "require a one-time UAC elevation.")

    g_WizardGui.AddButton("w100 y+20", "Skip").OnEvent("Click", WizardSkip)
    g_WizardGui.AddButton("w120 x+10 Default", "Apply && Start").OnEvent("Click", WizardApply)

    g_WizardGui.OnEvent("Close", WizardSkip)
    g_WizardGui.Show()
    WinWaitClose(g_WizardGui)
}

WizardSkip(*) {
    global g_WizardGui, g_WizardShuttingDown, cfg, gConfigIniPath
    if (g_WizardShuttingDown)
        return
    g_WizardShuttingDown := true

    ; Mark first-run as completed even if skipped
    cfg.SetupFirstRunCompleted := true
    _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "FirstRunCompleted", true, false, "bool")

    try g_WizardGui.Destroy()
}

WizardApply(*) {
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
        choices := JXON_Dump(Map(
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
            if (!_Launcher_RunAsAdmin("--wizard-continue"))
                throw Error("RunAsAdmin failed")

            g_WizardGui.Destroy()
            ExitApp()  ; Exit non-elevated instance
        } catch as e {
            ; UAC was cancelled or failed - clean up temp file and ask user
            try FileDelete(choicesFile)
            result := MsgBox(
                "Administrator privileges are required for:`n"
                "- Install to Program Files`n"
                "- Run as Administrator`n`n"
                "These options will be skipped.`n`n"
                "Continue with remaining options (shortcuts, auto-update)?",
                "Alt-Tabby Setup",
                "YesNo Icon?"
            )
            if (result = "No") {
                g_WizardShuttingDown := false  ; Allow clean exit
                try g_WizardGui.Destroy()
                return  ; Exit wizard completely
            }
            ; Continue with non-admin options only
            install := false
            admin := false

            ; Warn if shortcuts will point to potentially temporary location
            if (startup || startMenu) {
                currentDir := ""
                SplitPath(A_ScriptFullPath, , &currentDir)
                lowerDir := StrLower(currentDir)

                ; Check if current location looks temporary or cloud-synced
                isTemporary := (InStr(lowerDir, "\downloads")
                    || InStr(lowerDir, "\temp")
                    || InStr(lowerDir, "\desktop")
                    || InStr(lowerDir, "\appdata\local\temp")
                    || InStr(lowerDir, "\onedrive")
                    || InStr(lowerDir, "\dropbox")
                    || InStr(lowerDir, "\google drive")
                    || InStr(lowerDir, "\icloud"))

                if (isTemporary) {
                    result2 := MsgBox(
                        "Shortcuts will point to:`n" A_ScriptFullPath "`n`n"
                        "This location may be temporary or cloud-synced.`n"
                        "If you delete or move this file, the shortcuts will break.`n`n"
                        "Create shortcuts anyway?",
                        "Alt-Tabby Setup",
                        "YesNo Icon?"
                    )
                    if (result2 = "No") {
                        startup := false
                        startMenu := false
                    }
                }
            }
        }
    }

    ; Apply choices (without admin options if UAC was cancelled)
    _WizardApplyChoices(startMenu, startup, install, admin, autoUpdate)
    try g_WizardGui.Destroy()
}

; Called when --wizard-continue flag is passed (after elevation)
; Returns: "installed" if we should launch from new location, true if normal continue, false on error
WizardContinue() {
    global cfg, gConfigIniPath

    choicesFile := A_Temp "\alttabby_wizard.json"
    if (!FileExist(choicesFile))
        return false

    ; Read saved choices
    try {
        choicesJson := FileRead(choicesFile, "UTF-8")
        FileDelete(choicesFile)  ; Delete immediately after reading
        choices := JXON_Load(choicesJson)
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
        Run('"' installedPath '"')
        return "installed"  ; Signal caller to exit
    }

    return true
}

; Internal: Apply wizard choices (called from both wizard and continuation)
; Returns the installed exe path if we installed to a different location, empty string otherwise
_WizardApplyChoices(startMenu, startup, install, admin, autoUpdate) {
    global cfg, gConfigIniPath

    ; Determine exe path
    exePath := A_ScriptFullPath
    installedElsewhere := ""
    installSucceeded := false

    ; Step 1: Install to Program Files (if selected)
    if (install) {
        newPath := InstallToProgramFiles()
        if (newPath != "" && newPath != A_ScriptFullPath) {
            exePath := newPath
            installedElsewhere := newPath
            installSucceeded := true
            ; Update config path to point to new location so subsequent writes go there
            newDir := ""
            SplitPath(newPath, , &newDir)
            gConfigIniPath := newDir "\config.ini"
        } else if (newPath = "") {
            ; Install failed - exePath stays at current location
            installSucceeded := false
        } else {
            ; newPath = A_ScriptFullPath means we were already in Program Files
            installSucceeded := true
        }
    }

    ; Step 2: Create admin task (if selected) - needs final exe path
    if (admin) {
        ; Only create admin task if:
        ; - Install wasn't requested, OR
        ; - Install was requested AND succeeded
        ; This prevents stale task pointing to temporary location
        if (!install || installSucceeded) {
            if (CreateAdminTask(exePath)) {
                cfg.SetupRunAsAdmin := true
                _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "RunAsAdmin", true, false, "bool")
            } else {
                ; Task creation failed - notify user
                MsgBox("Warning: Could not create administrator task.`nAlt-Tabby will run without admin privileges.", "Alt-Tabby", "Icon!")
                ; Don't set cfg.SetupRunAsAdmin since task creation failed
            }
        } else {
            ; Install was requested but failed - don't create task pointing to temp location
            MsgBox("Admin mode requires successful installation.`nPlease try again or enable admin mode later from the tray menu.", "Alt-Tabby", "Icon!")
        }
    }

    ; Step 3: Save config
    cfg.SetupExePath := exePath
    cfg.SetupAutoUpdateCheck := autoUpdate
    cfg.SetupFirstRunCompleted := true
    _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "ExePath", exePath, "", "string")
    _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "AutoUpdateCheck", autoUpdate, true, "bool")
    _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "FirstRunCompleted", true, false, "bool")

    ; Step 4: Create shortcuts AFTER admin mode is set (so they point correctly)
    if (startMenu)
        _CreateShortcutForCurrentMode(_Shortcut_GetStartMenuPath())
    if (startup)
        _CreateShortcutForCurrentMode(_Shortcut_GetStartupPath())

    return installedElsewhere
}
