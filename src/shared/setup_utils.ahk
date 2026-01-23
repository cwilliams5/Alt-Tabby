#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Functions like _CL_WriteIniPreserveFormat come from config_loader.ahk

; ============================================================
; Setup Utilities - Version, Task Scheduler, Shortcuts
; ============================================================
; Shared functions for first-run wizard, admin mode, and updates.
; Included by alt_tabby.ahk and tests.

; ============================================================
; VERSION MANAGEMENT
; ============================================================

; Get the application version
; In compiled mode, reads from exe file version info
; In dev mode, reads from VERSION file in project root
GetAppVersion() {
    if (A_IsCompiled) {
        try {
            return FileGetVersion(A_ScriptFullPath)
        }
    }

    ; Dev mode: find VERSION file by looking up from script directory
    searchDir := A_ScriptDir
    loop 5 {  ; Search up to 5 levels
        versionFile := searchDir "\VERSION"
        if (FileExist(versionFile)) {
            try {
                version := Trim(FileRead(versionFile), " `t`r`n")
                if (version != "")
                    return version
            }
        }
        ; Go up one directory
        SplitPath(searchDir, , &searchDir)
        if (searchDir = "")
            break
    }

    return "0.0.0"  ; Fallback if VERSION file not found
}

; Compare two version strings (semver-style: X.Y.Z)
; Returns: 1 if v1 > v2, -1 if v1 < v2, 0 if equal
CompareVersions(v1, v2) {
    parts1 := StrSplit(v1, ".")
    parts2 := StrSplit(v2, ".")
    Loop 3 {
        p1 := parts1.Has(A_Index) ? Integer(parts1[A_Index]) : 0
        p2 := parts2.Has(A_Index) ? Integer(parts2[A_Index]) : 0
        if (p1 > p2)
            return 1
        if (p1 < p2)
            return -1
    }
    return 0
}

; ============================================================
; TASK SCHEDULER (ADMIN MODE)
; ============================================================

; Create a scheduled task with highest privileges (UAC-free admin)
CreateAdminTask(exePath) {
    taskName := "Alt-Tabby"

    ; Build XML for scheduled task
    ; Key: <RunLevel>HighestAvailable</RunLevel> = Run with highest privileges
    xml := '<?xml version="1.0" encoding="UTF-16"?>'
    xml .= '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">'
    xml .= '<Principals><Principal id="Author">'
    xml .= '<LogonType>InteractiveToken</LogonType>'
    xml .= '<RunLevel>HighestAvailable</RunLevel>'
    xml .= '</Principal></Principals>'
    xml .= '<Settings>'
    xml .= '<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>'
    xml .= '<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>'
    xml .= '<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>'
    xml .= '<AllowStartOnDemand>true</AllowStartOnDemand>'
    xml .= '<Enabled>true</Enabled>'
    xml .= '<Hidden>true</Hidden>'
    xml .= '<RunOnlyIfIdle>false</RunOnlyIfIdle>'
    xml .= '<WakeToRun>false</WakeToRun>'
    xml .= '</Settings>'
    xml .= '<Actions><Exec>'
    xml .= '<Command>"' exePath '"</Command>'
    xml .= '</Exec></Actions>'
    xml .= '</Task>'

    ; Write temp XML file
    xmlPath := A_Temp "\alttabby_task.xml"
    try FileDelete(xmlPath)
    FileAppend(xml, xmlPath, "UTF-16")

    ; Import task via schtasks (requires admin for HighestAvailable)
    result := RunWait('schtasks /create /tn "' taskName '" /xml "' xmlPath '" /f', , "Hide")

    try FileDelete(xmlPath)

    return (result = 0)
}

; Delete the admin scheduled task
DeleteAdminTask() {
    result := RunWait('schtasks /delete /tn "Alt-Tabby" /f', , "Hide")
    return (result = 0)
}

; Check if admin task exists
AdminTaskExists() {
    result := RunWait('schtasks /query /tn "Alt-Tabby"', , "Hide")
    return (result = 0)  ; 0 = task exists
}

; Extract command path from existing scheduled task XML
; Returns empty string if task doesn't exist or can't be parsed
_AdminTask_GetCommandPath() {
    tempFile := A_Temp "\alttabby_task_query.xml"
    try FileDelete(tempFile)

    ; Export task to XML (schtasks /xml outputs to stdout, redirect to file)
    result := RunWait('cmd.exe /c schtasks /query /tn "Alt-Tabby" /xml > "' tempFile '"',, "Hide")
    if (result != 0 || !FileExist(tempFile))
        return ""

    try {
        xml := FileRead(tempFile, "UTF-8")
        FileDelete(tempFile)

        ; Extract: <Command>"path"</Command> or <Command>path</Command>
        if (RegExMatch(xml, '<Command>"?([^"<]+)"?</Command>', &match))
            return match[1]
    }
    return ""
}

; ============================================================
; SHORTCUT PATH HELPERS
; ============================================================

; Get the path where Start Menu shortcut would be
_Shortcut_GetStartMenuPath() {
    return A_AppData "\Microsoft\Windows\Start Menu\Programs\Alt-Tabby.lnk"
}

; Get the path where Startup shortcut would be
_Shortcut_GetStartupPath() {
    return A_Startup "\Alt-Tabby.lnk"
}

; Check if Start Menu shortcut exists
_Shortcut_StartMenuExists() {
    return FileExist(_Shortcut_GetStartMenuPath())
}

; Check if Startup shortcut exists
_Shortcut_StartupExists() {
    return FileExist(_Shortcut_GetStartupPath())
}

; Get the icon path - in compiled mode, icon is embedded in exe
_Shortcut_GetIconPath() {
    if (A_IsCompiled)
        return A_ScriptFullPath  ; Icon is embedded in exe
    else
        return A_ScriptDir "\..\img\icon.ico"
}

; Get the effective exe path (installed location or current)
_Shortcut_GetEffectiveExePath() {
    global cfg
    if (IsSet(cfg) && cfg.HasOwnProp("SetupExePath") && cfg.SetupExePath != "" && FileExist(cfg.SetupExePath))
        return cfg.SetupExePath
    return A_IsCompiled ? A_ScriptFullPath : A_ScriptFullPath
}

; ============================================================
; AUTO-UPDATE SYSTEM
; ============================================================
; Flow: Check GitHub → Download to temp → Swap exe → Relaunch
; Handles elevation for Program Files installs.

; Check for updates and optionally offer to install
; showIfCurrent: If true, show message even when up to date
CheckForUpdates(showIfCurrent := false) {
    currentVersion := GetAppVersion()
    apiUrl := "https://api.github.com/repos/cwilliams5/Alt-Tabby/releases/latest"
    whr := ""  ; Declare outside try for cleanup

    try {
        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.Open("GET", apiUrl, false)
        whr.SetRequestHeader("User-Agent", "Alt-Tabby/" currentVersion)
        whr.Send()

        if (whr.Status = 200) {
            response := whr.ResponseText
            whr := ""  ; Release COM BEFORE processing (we have the text)

            ; Parse JSON for tag_name and download URL
            if (!RegExMatch(response, '"tag_name"\s*:\s*"v?([^"]+)"', &tagMatch))
                return

            latestVersion := tagMatch[1]

            if (CompareVersions(latestVersion, currentVersion) > 0) {
                ; Newer version available - offer to update
                result := MsgBox(
                    "Alt-Tabby " latestVersion " is available!`n"
                    "You have: " currentVersion "`n`n"
                    "Would you like to download and install the update now?",
                    "Update Available",
                    "YesNo Icon?"
                )

                if (result = "Yes") {
                    ; Find download URL for AltTabby.exe
                    downloadUrl := _Update_FindExeDownloadUrl(response)
                    if (downloadUrl)
                        _Update_DownloadAndApply(downloadUrl, latestVersion)
                    else
                        MsgBox("Could not find download URL for AltTabby.exe in the release.", "Update Error", "Icon!")
                }
            } else if (showIfCurrent) {
                TrayTip("Up to Date", "You're running the latest version (" currentVersion ")", "Iconi")
            }
        } else if (showIfCurrent) {
            TrayTip("Update Check Failed", "HTTP Status: " whr.Status, "Icon!")
            whr := ""  ; Release COM on error path
        }
    } catch as e {
        whr := ""  ; Ensure release on exception
        if (showIfCurrent)
            TrayTip("Update Check Failed", "Could not check for updates:`n" e.Message, "Icon!")
    }
    whr := ""  ; Final safety - ensure release on all exit paths
}

; Parse GitHub API response to find AltTabby.exe download URL
_Update_FindExeDownloadUrl(jsonResponse) {
    ; Look for browser_download_url containing AltTabby.exe
    if (RegExMatch(jsonResponse, '"browser_download_url"\s*:\s*"([^"]*AltTabby\.exe[^"]*)"', &match))
        return match[1]
    return ""
}

; Download update and apply it
_Update_DownloadAndApply(downloadUrl, newVersion) {
    ; Determine paths
    currentExe := A_ScriptFullPath
    exeDir := ""
    SplitPath(currentExe, , &exeDir)
    tempExe := A_Temp "\AltTabby_" newVersion ".exe"

    ; Clean up any existing partial download from previous failed attempt
    if (FileExist(tempExe))
        try FileDelete(tempExe)

    ; Show progress
    TrayTip("Downloading Update", "Downloading Alt-Tabby " newVersion "...", "Iconi")

    ; Declare COM objects outside try for cleanup
    whr := ""
    stream := ""

    ; Download to temp
    try {
        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.Open("GET", downloadUrl, false)
        whr.SetRequestHeader("User-Agent", "Alt-Tabby/" GetAppVersion())
        whr.Send()

        if (whr.Status != 200) {
            MsgBox("Download failed: HTTP " whr.Status, "Update Error", "Icon!")
            whr := ""  ; Release COM before return
            return
        }

        ; Save response body to file
        stream := ComObject("ADODB.Stream")
        stream.Type := 1  ; Binary
        stream.Open()
        stream.Write(whr.ResponseBody)
        stream.SaveToFile(tempExe, 2)  ; 2 = overwrite
        stream.Close()
        stream := ""  ; Release ADODB.Stream after close
        whr := ""     ; Release WinHttp
    } catch as e {
        stream := ""  ; Cleanup COM objects on error
        whr := ""
        ; Clean up partial download
        if (FileExist(tempExe))
            try FileDelete(tempExe)
        MsgBox("Download failed:`n" e.Message, "Update Error", "Icon!")
        return
    }

    ; Check if we need elevation to write to exe directory
    if (_Update_NeedsElevation(exeDir)) {
        ; Save update info and self-elevate
        updateInfo := tempExe "|" currentExe
        updateFile := A_Temp "\alttabby_update.txt"
        try FileDelete(updateFile)
        FileAppend(updateInfo, updateFile, "UTF-8")

        try {
            if A_IsCompiled
                Run('*RunAs "' A_ScriptFullPath '" --apply-update')
            else
                Run('*RunAs "' A_AhkPath '" "' A_ScriptFullPath '" --apply-update')
            ExitApp()
        } catch {
            MsgBox("Update requires administrator privileges.`nPlease run as administrator to update.", "Update Error", "Icon!")
            try FileDelete(updateFile)
            try FileDelete(tempExe)  ; Clean up downloaded exe
            return
        }
    }

    ; Apply the update directly
    _Update_ApplyAndRelaunch(tempExe, currentExe)
}

; Check if we need elevation to write to the target directory
_Update_NeedsElevation(targetDir) {
    if (A_IsAdmin)
        return false

    ; Try to create a temp file in the target directory
    testFile := targetDir "\alttabby_write_test.tmp"
    try {
        FileAppend("test", testFile)
        FileDelete(testFile)
        return false  ; Write succeeded, no elevation needed
    } catch {
        return true  ; Write failed, need elevation
    }
}

; Kill all instances of this exe except the current one
; This releases file locks on the exe before updating
; Gets exe name dynamically to support renamed executables (e.g., "alttabby v4.exe")
_Update_KillOtherProcesses() {
    myPID := ProcessExist()  ; Get our own PID

    ; Get exe name dynamically (handles renamed exe)
    exeName := ""
    SplitPath(A_ScriptFullPath, &exeName)

    ; Loop to kill all instances of this exe except ourselves
    ; Using ProcessExist/ProcessClose instead of WMI (WMI can fail in elevated contexts)
    loop 10 {  ; Max 10 iterations to avoid infinite loop
        pid := ProcessExist(exeName)
        if (!pid || pid = myPID)
            break
        try ProcessClose(pid)
        Sleep(100)  ; Brief pause for process to terminate
    }
}

; Apply update: rename current exe, move new exe, relaunch
_Update_ApplyAndRelaunch(newExePath, targetExePath) {
    global cfg, gConfigIniPath

    targetDir := ""
    SplitPath(targetExePath, , &targetDir)
    targetConfigPath := targetDir "\config.ini"  ; Target's config location
    oldExePath := targetExePath ".old"

    try {
        ; Kill all other AltTabby.exe processes (store, gui, viewer)
        ; This releases file locks so we can rename/delete the exe
        _Update_KillOtherProcesses()
        Sleep(500)  ; Give processes time to fully exit

        ; Remove any previous .old file
        if (FileExist(oldExePath))
            FileDelete(oldExePath)

        ; Rename current exe to .old (Windows allows this even while running)
        FileMove(targetExePath, oldExePath)

        ; Move new exe to target location
        FileMove(newExePath, targetExePath)

        ; Update config AT THE TARGET location (not source location where we're running from)
        ; For auto-update this is usually the same, but for mismatch updates they may differ
        cfg.SetupExePath := targetExePath
        if (FileExist(targetConfigPath)) {
            try _CL_WriteIniPreserveFormat(targetConfigPath, "Setup", "ExePath", targetExePath, "", "string")
        }

        ; Read admin mode from TARGET config (not source config we loaded at startup)
        ; This ensures we correctly handle cases where target has different settings
        targetRunAsAdmin := false
        if (FileExist(targetConfigPath)) {
            iniVal := IniRead(targetConfigPath, "Setup", "RunAsAdmin", "false")
            targetRunAsAdmin := (iniVal = "true" || iniVal = "1")
        }

        ; Update admin task if TARGET has admin mode enabled
        if (targetRunAsAdmin && AdminTaskExists()) {
            ; Recreate task with new exe path
            DeleteAdminTask()
            CreateAdminTask(targetExePath)
        }

        ; Success! Launch new version and exit
        TrayTip("Update Complete", "Alt-Tabby has been updated. Restarting...", "Iconi")
        Sleep(1000)

        ; Schedule cleanup of .old file after we exit (we can't delete our own running exe)
        ; The ping command adds a ~1 second delay for our process to fully exit
        cleanupCmd := 'cmd.exe /c ping 127.0.0.1 -n 2 > nul && del "' oldExePath '"'
        Run(cleanupCmd,, "Hide")

        Run('"' targetExePath '"')
        ExitApp()

    } catch as e {
        ; Try to restore old exe if something went wrong
        if (!FileExist(targetExePath) && FileExist(oldExePath)) {
            try FileMove(oldExePath, targetExePath)
        }
        MsgBox("Update failed:`n" e.Message "`n`nThe previous version has been restored.", "Update Error", "Icon!")
    }
}

; Called on startup to clean up old exe from previous update
; This is a fallback - the elevated updater schedules cleanup via cmd.exe,
; but this handles cases where: (1) exe is not in Program Files (no elevation needed),
; or (2) the scheduled cmd cleanup somehow failed
_Update_CleanupOldExe() {
    if (!A_IsCompiled)
        return

    oldExe := A_ScriptFullPath ".old"
    if (FileExist(oldExe)) {
        try FileDelete(oldExe)
    }
}

; Called when launched with --apply-update flag (elevated)
_Update_ContinueFromElevation() {
    updateFile := A_Temp "\alttabby_update.txt"

    if (!FileExist(updateFile))
        return false

    try {
        content := FileRead(updateFile, "UTF-8")
        FileDelete(updateFile)

        parts := StrSplit(content, "|")
        if (parts.Length != 2)
            return false

        newExePath := parts[1]
        targetExePath := parts[2]

        ; Security validation: ensure source file exists
        if (!FileExist(newExePath)) {
            MsgBox("Update source file not found:`n" newExePath, "Alt-Tabby", "Icon!")
            return false
        }

        ; Validate source path is in TEMP directory (expected from download)
        if (!InStr(newExePath, A_Temp)) {
            MsgBox("Invalid update source path (not in temp):`n" newExePath, "Alt-Tabby", "Icon!")
            return false
        }

        ; Validate target path looks like an Alt-Tabby executable
        ; Allow renamed exes (e.g., "alttabby v4.exe") as long as they contain "tabby"
        targetName := ""
        SplitPath(targetExePath, &targetName)
        if (!RegExMatch(targetName, "i)\.exe$") || !InStr(StrLower(targetName), "tabby")) {
            MsgBox("Invalid update target path:`n" targetExePath, "Alt-Tabby", "Icon!")
            return false
        }

        _Update_ApplyAndRelaunch(newExePath, targetExePath)
        return true  ; Won't reach here if successful (ExitApp called)
    } catch {
        return false
    }
}
