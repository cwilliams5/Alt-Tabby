#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Cross-file globals (cfg, g_MismatchDialogShown) come from alt_tabby.ahk

; ============================================================
; Launcher Install - Program Files & Mismatch Detection
; ============================================================
; Handles installation to Program Files and detection of
; running from a different location than installed version.

; ============================================================
; PROGRAM FILES INSTALLATION
; ============================================================

InstallToProgramFiles() {
    global cfg

    ; Target: C:\Program Files\Alt-Tabby\
    installDir := "C:\Program Files\Alt-Tabby"
    srcExe := A_IsCompiled ? A_ScriptFullPath : ""
    srcDir := A_IsCompiled ? A_ScriptDir : ""

    if (!A_IsCompiled) {
        MsgBox("Program Files installation only works with compiled exe.", "Alt-Tabby", "Icon!")
        return ""
    }

    ; Check if we need admin
    if (!A_IsAdmin) {
        MsgBox("Administrator privileges required to install to Program Files.", "Alt-Tabby", "Icon!")
        return ""
    }

    ; Check if already in Program Files (use exact path comparison, not substring)
    normalizedDir := StrLower(A_ScriptDir)
    if (normalizedDir = StrLower(installDir)) {
        return A_ScriptFullPath  ; Already there
    }

    try {
        ; Create directory
        if (!DirExist(installDir))
            DirCreate(installDir)

        ; Copy exe
        FileCopy(srcExe, installDir "\AltTabby.exe", true)

        ; Copy img folder if exists
        if (DirExist(srcDir "\img"))
            DirCopy(srcDir "\img", installDir "\img", true)

        ; Copy config if exists (so user keeps their settings)
        if (FileExist(srcDir "\config.ini"))
            FileCopy(srcDir "\config.ini", installDir "\config.ini", true)

        ; Copy blacklist if exists
        if (FileExist(srcDir "\blacklist.txt"))
            FileCopy(srcDir "\blacklist.txt", installDir "\blacklist.txt", true)

        return installDir "\AltTabby.exe"
    } catch as e {
        MsgBox("Failed to install to Program Files:`n" e.Message, "Alt-Tabby", "IconX")
        return ""
    }
}

; ============================================================
; INSTALL MISMATCH DETECTION
; ============================================================

; Check if we're running from a different location than the installed version
; Offers to update or launch the installed version
; Sets g_MismatchDialogShown if a dialog was displayed (to prevent race with auto-update)
_Launcher_CheckInstallMismatch() {
    global cfg, g_MismatchDialogShown

    ; Only relevant for compiled exe
    if (!A_IsCompiled)
        return

    ; First, check config for SetupExePath
    installedPath := ""
    if (cfg.HasOwnProp("SetupExePath") && cfg.SetupExePath != "")
        installedPath := cfg.SetupExePath

    ; Also check well-known install location (handles fresh config case)
    ; This ensures we detect existing PF installs even with empty/fresh config
    pfPath := "C:\Program Files\Alt-Tabby\AltTabby.exe"
    if (installedPath = "" && FileExist(pfPath)) {
        installedPath := pfPath
    }

    ; No known installation
    if (installedPath = "")
        return

    currentPath := A_ScriptFullPath

    ; Normalize paths for comparison (case-insensitive)
    if (StrLower(installedPath) = StrLower(currentPath))
        return  ; Running from installed location, all good

    ; Check if installed exe actually exists
    if (!FileExist(installedPath))
        return  ; Installed exe is gone, continue normally

    ; Get versions
    currentVersion := GetAppVersion()
    try {
        installedVersion := FileGetVersion(installedPath)
    } catch {
        installedVersion := "0.0.0"
    }

    versionCompare := CompareVersions(currentVersion, installedVersion)

    ; Mark that we're showing a mismatch dialog (prevents auto-update race)
    g_MismatchDialogShown := true

    if (versionCompare > 0) {
        ; Current version is NEWER than installed
        result := MsgBox(
            "Alt-Tabby is installed at:`n" installedPath "`n`n"
            "You're running a newer version (" currentVersion " vs " installedVersion ").`n`n"
            "Update the installed version?",
            "Alt-Tabby - Update Installed Version?",
            "YesNo Icon?"
        )

        if (result = "Yes") {
            _Launcher_UpdateInstalledVersion(installedPath)
            ; If we return, update failed - continue running from current location
        }
        ; "No" - continue running from current location
    } else {
        ; Current version is SAME or OLDER than installed
        ; Use custom 3-button dialog: Yes (launch installed) / No (run from here once) / Always (run from here always)
        result := _Launcher_ShowMismatchDialog(installedPath)

        if (result = "Yes") {
            ; Launch installed version and exit
            try {
                Run('"' installedPath '"')
                ExitApp()
            } catch as e {
                MsgBox("Could not launch installed version:`n" e.Message, "Alt-Tabby", "Icon!")
            }
        } else if (result = "Always") {
            ; Update SetupExePath to current location - never ask again
            cfg.SetupExePath := currentPath
            try _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "ExePath", currentPath, "", "string")
            g_MismatchDialogShown := false  ; Allow auto-update now that mismatch is resolved
            ; Continue running from current location
        }
        ; "No" - continue running from current location (one-time)
    }
}

; Custom 3-button dialog for mismatch: Yes / No / Always run from here
; Returns: "Yes", "No", or "Always"
_Launcher_ShowMismatchDialog(installedPath) {
    global cfg

    mismatchGui := Gui("+AlwaysOnTop +Owner", "Alt-Tabby - Already Installed")
    mismatchGui.SetFont("s10", "Segoe UI")

    mismatchGui.AddText("w380", "Alt-Tabby is already installed at:")
    mismatchGui.AddText("w380 cGray", installedPath)
    mismatchGui.AddText("w380 y+15", "Launch the installed version instead?")

    result := ""  ; Will be set by button clicks

    btnYes := mismatchGui.AddButton("w100 y+20 Default", "Yes")
    btnNo := mismatchGui.AddButton("w100 x+10", "No")
    btnAlways := mismatchGui.AddButton("w140 x+10", "Always run from here")

    btnYes.OnEvent("Click", (*) => (result := "Yes", mismatchGui.Destroy()))
    btnNo.OnEvent("Click", (*) => (result := "No", mismatchGui.Destroy()))
    btnAlways.OnEvent("Click", (*) => (result := "Always", mismatchGui.Destroy()))
    mismatchGui.OnEvent("Close", (*) => (result := "No", mismatchGui.Destroy()))

    mismatchGui.Show()
    WinWaitClose(mismatchGui)

    return result
}

; Update the installed version with the current exe
_Launcher_UpdateInstalledVersion(installedPath) {
    global cfg, gConfigIniPath

    installedDir := ""
    SplitPath(installedPath, , &installedDir)

    ; Check if we need elevation
    if (_Update_NeedsElevation(installedDir)) {
        ; Save update info and self-elevate (use <|> delimiter to handle pipe chars in paths)
        updateInfo := A_ScriptFullPath "<|>" installedPath
        updateFile := A_Temp "\alttabby_install_update.txt"
        try FileDelete(updateFile)
        FileAppend(updateInfo, updateFile, "UTF-8")

        try {
            Run('*RunAs "' A_ScriptFullPath '" --update-installed')
            ExitApp()
        } catch {
            MsgBox("Update requires administrator privileges.", "Alt-Tabby", "Icon!")
            try FileDelete(updateFile)
            return
        }
    }

    ; Apply update directly
    _Launcher_DoUpdateInstalled(A_ScriptFullPath, installedPath)
}

; Actually perform the update (called directly or after elevation)
_Launcher_DoUpdateInstalled(sourcePath, targetPath) {
    global cfg, gConfigIniPath

    targetDir := ""
    SplitPath(targetPath, , &targetDir)
    targetConfigPath := targetDir "\config.ini"  ; Target's config location
    backupPath := targetPath ".old"

    try {
        ; Kill all other AltTabby.exe processes (store, gui, viewer)
        ; This releases file locks so we can rename/delete the exe
        _Update_KillOtherProcesses()
        Sleep(500)  ; Give processes time to fully exit

        ; Remove any previous backup
        if (FileExist(backupPath))
            FileDelete(backupPath)

        ; Bug 2 fix: Specific error handling for exe rename
        ; This can fail due to antivirus, file locks, or disk errors
        try {
            FileMove(targetPath, backupPath)
        } catch as renameErr {
            MsgBox("Could not rename existing version:`n" renameErr.Message "`n`nUpdate aborted. The file may be locked by antivirus or another process.", "Update Error", "Icon!")
            return
        }

        ; Copy new version
        FileCopy(sourcePath, targetPath)

        ; Update config AT THE TARGET location (not source location where we're running from)
        ; This ensures the installed version has the correct SetupExePath
        cfg.SetupExePath := targetPath
        ; Ensure target config exists (may be missing for fresh installs)
        if (!FileExist(targetConfigPath)) {
            if (FileExist(gConfigIniPath))
                try FileCopy(gConfigIniPath, targetConfigPath)
        }
        if (FileExist(targetConfigPath)) {
            try _CL_WriteIniPreserveFormat(targetConfigPath, "Setup", "ExePath", targetPath, "", "string")
        }

        ; Read admin mode from TARGET config (not source config we loaded at startup)
        ; The target location may have different settings than where this exe is running from
        targetRunAsAdmin := false
        if (FileExist(targetConfigPath)) {
            iniVal := IniRead(targetConfigPath, "Setup", "RunAsAdmin", "false")
            targetRunAsAdmin := (iniVal = "true" || iniVal = "1")
        }

        ; Bug 1 fix: Update admin task if TARGET has admin mode enabled, with error handling
        if (targetRunAsAdmin && AdminTaskExists()) {
            ; Recreate task with target exe path
            DeleteAdminTask()
            if (!CreateAdminTask(targetPath)) {
                ; Task creation failed - disable admin mode to avoid broken state
                TrayTip("Admin Mode Error", "Could not recreate admin task. Admin mode has been disabled.", "Icon!")
                cfg.SetupRunAsAdmin := false
                if (FileExist(targetConfigPath))
                    try _CL_WriteIniPreserveFormat(targetConfigPath, "Setup", "RunAsAdmin", false, false, "bool")
            }
        }

        ; Success - launch from installed location and exit
        TrayTip("Update Complete", "Alt-Tabby has been updated at:`n" targetPath, "Iconi")
        Sleep(1000)

        ; Bug 8 fix: Extended cleanup delay with retry for slow systems
        ; First attempt after 4 seconds, retry after another 4 seconds if first fails
        cleanupCmd := 'cmd.exe /c ping 127.0.0.1 -n 5 > nul && del "' backupPath '" 2>nul || (ping 127.0.0.1 -n 5 > nul && del "' backupPath '")'
        Run(cleanupCmd,, "Hide")

        Run('"' targetPath '"')
        ExitApp()

    } catch as e {
        ; Bug 3 fix: Track and communicate rollback result
        rollbackSuccess := false
        if (!FileExist(targetPath) && FileExist(backupPath)) {
            try {
                FileMove(backupPath, targetPath)
                rollbackSuccess := true
            }
        }

        if (rollbackSuccess)
            MsgBox("Update failed:`n" e.Message "`n`nThe previous version has been restored.", "Update Error", "Icon!")
        else if (FileExist(targetPath))
            MsgBox("Update failed:`n" e.Message, "Update Error", "Icon!")
        else
            MsgBox("Update failed and could not restore previous version.`n`n" e.Message "`n`nPlease reinstall Alt-Tabby.", "Alt-Tabby Critical", "Iconx")
    }
}
