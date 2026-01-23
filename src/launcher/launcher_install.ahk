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
        result := MsgBox(
            "Alt-Tabby is already installed at:`n" installedPath "`n`n"
            "Launch the installed version instead?",
            "Alt-Tabby - Already Installed",
            "YesNo Icon?"
        )

        if (result = "Yes") {
            ; Launch installed version and exit
            try {
                Run('"' installedPath '"')
                ExitApp()
            } catch as e {
                MsgBox("Could not launch installed version:`n" e.Message, "Alt-Tabby", "Icon!")
            }
        }
        ; "No" - continue running from current location
    }
}

; Update the installed version with the current exe
_Launcher_UpdateInstalledVersion(installedPath) {
    global cfg, gConfigIniPath

    installedDir := ""
    SplitPath(installedPath, , &installedDir)

    ; Check if we need elevation
    if (_Update_NeedsElevation(installedDir)) {
        ; Save update info and self-elevate
        updateInfo := A_ScriptFullPath "|" installedPath
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
    backupPath := targetPath ".old"

    try {
        ; Kill all other AltTabby.exe processes (store, gui, viewer)
        ; This releases file locks so we can rename/delete the exe
        _Update_KillOtherProcesses()
        Sleep(500)  ; Give processes time to fully exit

        ; Remove any previous backup
        if (FileExist(backupPath))
            FileDelete(backupPath)

        ; Backup current installed version
        FileMove(targetPath, backupPath)

        ; Copy new version
        FileCopy(sourcePath, targetPath)

        ; Update config to reflect the target path
        if (IsSet(cfg) && IsSet(gConfigIniPath)) {
            cfg.SetupExePath := targetPath
            try _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "ExePath", targetPath, "", "string")
        }

        ; Update admin task if enabled - task needs to point to target location
        if (IsSet(cfg) && cfg.HasOwnProp("SetupRunAsAdmin") && cfg.SetupRunAsAdmin) {
            if (AdminTaskExists()) {
                ; Recreate task with target exe path
                DeleteAdminTask()
                CreateAdminTask(targetPath)
            }
        }

        ; Success - launch from installed location and exit
        TrayTip("Update Complete", "Alt-Tabby has been updated at:`n" targetPath, "Iconi")
        Sleep(1000)

        ; Schedule cleanup of .old file after we exit
        ; The ping command adds a ~1 second delay for our process to fully exit
        cleanupCmd := 'cmd.exe /c ping 127.0.0.1 -n 2 > nul && del "' backupPath '"'
        Run(cleanupCmd,, "Hide")

        Run('"' targetPath '"')
        ExitApp()

    } catch as e {
        ; Try to restore backup
        if (!FileExist(targetPath) && FileExist(backupPath)) {
            try FileMove(backupPath, targetPath)
        }
        MsgBox("Update failed:`n" e.Message, "Alt-Tabby", "Icon!")
    }
}
