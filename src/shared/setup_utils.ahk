#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Functions like _CL_WriteIniPreserveFormat come from config_loader.ahk

; ============================================================
; Setup Utilities - Version, Task Scheduler, Shortcuts
; ============================================================
; Shared functions for first-run wizard, admin mode, and updates.
; Included by alt_tabby.ahk and tests.

; Task name constant - used by all task scheduler functions
global ALTTABBY_TASK_NAME := "Alt-Tabby"

; PE validation constants
global PE_MIN_SIZE := 102400                ; 100KB minimum for valid AHK exe
global PE_MAX_SIZE := 52428800              ; 50MB maximum
global PE_MZ_MAGIC_1 := 77                  ; 'M' (0x4D)
global PE_MZ_MAGIC_2 := 90                  ; 'Z' (0x5A)
global PE_SIG_1 := 80                       ; 'P' (0x50)
global PE_SIG_2 := 69                       ; 'E' (0x45)

; Guard to prevent concurrent update checks (auto-update timer + manual button)
global g_UpdateCheckInProgress := false

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
; Handles: leading 'v' prefix (e.g., "v1.0.0") and pre-release suffixes (e.g., "1.0.0-beta")
CompareVersions(v1, v2) {
    ; Strip leading 'v' if present
    v1 := RegExReplace(v1, "^v", "")
    v2 := RegExReplace(v2, "^v", "")

    parts1 := StrSplit(v1, ".")
    parts2 := StrSplit(v2, ".")
    Loop 3 {
        p1Str := parts1.Has(A_Index) ? parts1[A_Index] : "0"
        p2Str := parts2.Has(A_Index) ? parts2[A_Index] : "0"

        ; Strip pre-release suffix (e.g., "1-beta" -> "1")
        p1Str := RegExReplace(p1Str, "-.*$", "")
        p2Str := RegExReplace(p2Str, "-.*$", "")

        try {
            p1 := Integer(p1Str)
            p2 := Integer(p2Str)
        } catch {
            p1 := 0
            p2 := 0
        }

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
; Includes InstallationId in description for identification
CreateAdminTask(exePath, installId := "") {
    global ALTTABBY_TASK_NAME, cfg
    taskName := ALTTABBY_TASK_NAME

    ; Get InstallationId if not provided
    if (installId = "" && IsSet(cfg) && cfg.HasOwnProp("SetupInstallationId"))
        installId := cfg.SetupInstallationId

    ; Build description with embedded ID for later identification
    taskDesc := "Alt-Tabby Admin Task"
    if (installId != "")
        taskDesc .= " [ID:" installId "]"

    ; Build XML for scheduled task
    ; Key: <RunLevel>HighestAvailable</RunLevel> = Run with highest privileges
    xml := '<?xml version="1.0" encoding="UTF-16"?>'
    xml .= '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">'
    xml .= '<RegistrationInfo>'
    xml .= '<Description>' taskDesc '</Description>'
    xml .= '</RegistrationInfo>'
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
    global ALTTABBY_TASK_NAME
    result := RunWait('schtasks /delete /tn "' ALTTABBY_TASK_NAME '" /f', , "Hide")
    return (result = 0)
}

; Check if admin task exists
AdminTaskExists() {
    global ALTTABBY_TASK_NAME
    result := RunWait('schtasks /query /tn "' ALTTABBY_TASK_NAME '"', , "Hide")
    return (result = 0)  ; 0 = task exists
}

; Extract command path from existing scheduled task XML
; Returns empty string if task doesn't exist or can't be parsed
_AdminTask_GetCommandPath() {
    global ALTTABBY_TASK_NAME
    tempFile := A_Temp "\alttabby_task_query.xml"
    try FileDelete(tempFile)

    ; Export task to XML (schtasks /xml outputs to stdout, redirect to file)
    result := RunWait('cmd.exe /c schtasks /query /tn "' ALTTABBY_TASK_NAME '" /xml > "' tempFile '"',, "Hide")
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

; Extract InstallationId from task description
; Returns empty string if task doesn't exist or has no ID
_AdminTask_GetInstallationId() {
    global ALTTABBY_TASK_NAME
    tempFile := A_Temp "\alttabby_task_query.xml"
    try FileDelete(tempFile)

    ; Export task to XML
    result := RunWait('cmd.exe /c schtasks /query /tn "' ALTTABBY_TASK_NAME '" /xml > "' tempFile '"',, "Hide")
    if (result != 0 || !FileExist(tempFile))
        return ""

    try {
        xml := FileRead(tempFile, "UTF-8")
        FileDelete(tempFile)

        ; Extract: <Description>Alt-Tabby Admin Task [ID:XXXXXXXX]</Description>
        if (RegExMatch(xml, '\[ID:([A-Fa-f0-9]{8})\]', &match))
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
; Uses effective exe path to ensure icon remains valid even if user deletes the running exe
_Shortcut_GetIconPath() {
    if (A_IsCompiled)
        return _Shortcut_GetEffectiveExePath()  ; Icon is embedded in exe - use same path as shortcut target
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
    global g_UpdateCheckInProgress

    ; Prevent concurrent update checks (auto-update timer + manual button race)
    if (g_UpdateCheckInProgress) {
        if (showIfCurrent)
            TrayTip("Update Check", "An update check is already in progress.", "Iconi")
        return
    }
    g_UpdateCheckInProgress := true

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
            if (!RegExMatch(response, '"tag_name"\s*:\s*"v?([^"]+)"', &tagMatch)) {
                g_UpdateCheckInProgress := false
                return
            }

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
    g_UpdateCheckInProgress := false
}

; Parse GitHub API response to find AltTabby.exe download URL
_Update_FindExeDownloadUrl(jsonResponse) {
    ; Look for browser_download_url containing AltTabby.exe (case-insensitive)
    if (RegExMatch(jsonResponse, 'i)"browser_download_url"\s*:\s*"([^"]*AltTabby\.exe[^"]*)"', &match))
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
        whr.SetTimeouts(30000, 30000, 30000, 120000)  ; 30s connect/send/receive, 120s total
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
        ; Save update info and self-elevate (use <|> delimiter to handle pipe chars in paths)
        updateInfo := tempExe "<|>" currentExe
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

    ; Bug 5 fix: Validate directory exists first
    ; If directory doesn't exist, we'll need admin to create it (e.g., Program Files)
    if (!DirExist(targetDir))
        return true

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

; Kill all instances of Alt-Tabby exes except the current one
; This releases file locks on the exe before updating
; Handles renamed exes by killing processes matching:
;   1. Current exe name (from A_ScriptFullPath)
;   2. Target exe name (passed as parameter, for updates)
;   3. Exe name from cfg.SetupExePath (installed location, may differ)
_Update_KillOtherProcesses(targetExeName := "") {
    global cfg
    myPID := ProcessExist()  ; Get our own PID

    ; Build list of exe names to kill (avoid duplicates, case-insensitive)
    exeNames := []
    seenNames := Map()  ; Track seen names for deduplication

    ; 1. Current exe name
    currentName := ""
    SplitPath(A_ScriptFullPath, &currentName)
    if (currentName != "") {
        exeNames.Push(currentName)
        seenNames[StrLower(currentName)] := true
    }

    ; 2. Target exe name (for updates, passed by caller)
    if (targetExeName != "") {
        lowerTarget := StrLower(targetExeName)
        if (!seenNames.Has(lowerTarget)) {
            exeNames.Push(targetExeName)
            seenNames[lowerTarget] := true
        }
    }

    ; 3. Configured install path exe name (may be different if user renamed)
    if (IsSet(cfg) && cfg.HasOwnProp("SetupExePath") && cfg.SetupExePath != "") {
        configName := ""
        SplitPath(cfg.SetupExePath, &configName)
        if (configName != "") {
            lowerConfig := StrLower(configName)
            if (!seenNames.Has(lowerConfig)) {
                exeNames.Push(configName)
                seenNames[lowerConfig] := true
            }
        }
    }

    ; Kill all matching processes (except ourselves)
    ; Using ProcessExist/ProcessClose instead of WMI (WMI can fail in elevated contexts)
    for exeName in exeNames {
        loop 10 {  ; Max 10 iterations per exe name to avoid infinite loop
            pid := ProcessExist(exeName)
            if (!pid || pid = myPID)
                break
            try ProcessClose(pid)
            Sleep(100)  ; Brief pause for process to terminate
        }
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
        ; Pass target exe name to handle renamed exes
        targetExeName := ""
        SplitPath(targetExePath, &targetExeName)
        _Update_KillOtherProcesses(targetExeName)
        Sleep(TIMING_PROCESS_EXIT_WAIT)  ; Give processes time to fully exit

        ; Remove any previous .old file
        if (FileExist(oldExePath))
            FileDelete(oldExePath)

        ; Bug 2 fix: Specific error handling for exe rename
        ; This can fail due to antivirus, file locks, or disk errors
        try {
            FileMove(targetExePath, oldExePath)
        } catch as renameErr {
            MsgBox("Could not rename existing version:`n" renameErr.Message "`n`nUpdate aborted. The file may be locked by antivirus or another process.", "Update Error", "Icon!")
            return
        }

        ; Validate PE header before applying (catches corrupted downloads, HTML error pages)
        if (!_Update_ValidatePEFile(newExePath)) {
            ; Restore the old exe
            if (FileExist(oldExePath))
                FileMove(oldExePath, targetExePath)
            MsgBox("Downloaded file appears to be corrupted (invalid PE header).`nUpdate aborted.", "Update Error", "Icon!")
            return
        }

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

        ; Bug 1 fix: Update admin task if TARGET has admin mode enabled, with error handling
        if (targetRunAsAdmin && AdminTaskExists()) {
            ; Recreate task with new exe path
            DeleteAdminTask()
            if (!CreateAdminTask(targetExePath)) {
                ; Task creation failed - disable admin mode to avoid broken state
                MsgBox("Could not recreate admin task after update.`n`n"
                    "Admin mode has been disabled. You can re-enable it from the tray menu.",
                    "Alt-Tabby - Admin Mode Error", "Icon!")
                cfg.SetupRunAsAdmin := false
                if (FileExist(targetConfigPath))
                    try _CL_WriteIniPreserveFormat(targetConfigPath, "Setup", "RunAsAdmin", false, false, "bool")
            }
        }

        ; Success! Launch new version and exit
        TrayTip("Update Complete", "Alt-Tabby has been updated. Restarting...", "Iconi")
        Sleep(TIMING_STORE_START_WAIT)

        ; Bug 8 fix: Extended cleanup delay with retry for slow systems
        ; Uses timeout instead of ping (ping fails on systems with ICMP blocked)
        ; First attempt after 4 seconds, retry after another 4 seconds if first fails
        cleanupCmd := 'cmd.exe /c timeout /t 4 /nobreak > nul 2>&1 && del "' oldExePath '" 2>nul || (timeout /t 4 /nobreak > nul 2>&1 && del "' oldExePath '")'
        Run(cleanupCmd,, "Hide")

        Run('"' targetExePath '"')
        ExitApp()

    } catch as e {
        ; Bug 3 fix: Track and communicate rollback result
        rollbackSuccess := false
        if (!FileExist(targetExePath) && FileExist(oldExePath)) {
            try {
                FileMove(oldExePath, targetExePath)
                rollbackSuccess := true
            }
        }

        ; Clean up downloaded exe on failure (Priority 4 fix)
        if (FileExist(newExePath))
            try FileDelete(newExePath)

        if (rollbackSuccess)
            MsgBox("Update failed:`n" e.Message "`n`nThe previous version has been restored.", "Update Error", "Icon!")
        else if (FileExist(targetExePath))
            MsgBox("Update failed:`n" e.Message, "Update Error", "Icon!")
        else
            MsgBox("Update failed and could not restore previous version.`n`n" e.Message "`n`nPlease reinstall Alt-Tabby.", "Alt-Tabby Critical", "Iconx")
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

; Clean up stale temp files from crashed wizard/update instances (Priority 3 fix)
; Called on startup after _Update_CleanupOldExe
_Update_CleanupStaleTempFiles() {
    staleFiles := [
        A_Temp "\alttabby_wizard.json",
        A_Temp "\alttabby_update.txt",
        A_Temp "\alttabby_install_update.txt",
        A_Temp "\alttabby_admin_toggle.lock"
    ]

    for filePath in staleFiles {
        if (FileExist(filePath)) {
            try {
                modTime := FileGetTime(filePath, "M")
                if (DateDiff(A_Now, modTime, "Hours") >= 1)
                    FileDelete(filePath)
            }
        }
    }

    ; Clean up old downloaded exes
    Loop Files A_Temp "\AltTabby_*.exe" {
        try {
            if (DateDiff(A_Now, A_LoopFileTimeModified, "Hours") >= 1)
                FileDelete(A_LoopFilePath)
        }
    }
}

; Validate that a file is a valid PE executable
; Checks: file size, MZ magic, and PE signature at e_lfanew
; Returns true if valid PE, false otherwise
_Update_ValidatePEFile(filePath) {
    global PE_MIN_SIZE, PE_MAX_SIZE, PE_MZ_MAGIC_1, PE_MZ_MAGIC_2, PE_SIG_1, PE_SIG_2
    try {
        ; Check file size - too small = corrupted/truncated, too large = not a normal exe
        fileSize := FileGetSize(filePath)
        if (fileSize < PE_MIN_SIZE || fileSize > PE_MAX_SIZE)
            return false

        f := FileOpen(filePath, "r")
        if (!f)
            return false

        ; Read DOS header (64 bytes) - contains MZ magic and e_lfanew offset
        buf := Buffer(64)
        bytesRead := f.RawRead(buf, 64)
        if (bytesRead < 64) {
            f.Close()
            return false
        }

        ; Check MZ magic bytes at offset 0
        byte1 := NumGet(buf, 0, "UChar")
        byte2 := NumGet(buf, 1, "UChar")
        if (byte1 != PE_MZ_MAGIC_1 || byte2 != PE_MZ_MAGIC_2) {
            f.Close()
            return false
        }

        ; Get e_lfanew (offset to PE header) at offset 0x3C (60)
        ; This should be a reasonable offset (typically 64-1024)
        e_lfanew := NumGet(buf, 0x3C, "UInt")
        if (e_lfanew < 64 || e_lfanew > 1024) {
            f.Close()
            return false
        }

        ; Seek to PE header and read PE signature
        f.Seek(e_lfanew)
        peBuf := Buffer(4)
        bytesRead := f.RawRead(peBuf, 4)
        f.Close()

        if (bytesRead < 4)
            return false

        ; PE signature: 'P' 'E' 0x00 0x00
        pe1 := NumGet(peBuf, 0, "UChar")
        pe2 := NumGet(peBuf, 1, "UChar")
        pe3 := NumGet(peBuf, 2, "UChar")
        pe4 := NumGet(peBuf, 3, "UChar")

        return (pe1 = PE_SIG_1 && pe2 = PE_SIG_2 && pe3 = 0 && pe4 = 0)
    } catch {
        return false
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

        ; Bug 6 fix: Add specific error for corrupted state file
        parts := StrSplit(content, "<|>")
        if (parts.Length != 2) {
            MsgBox("Update state file was corrupted.`nExpected 2 parts, got " parts.Length ".`nContent: " SubStr(content, 1, 100), "Alt-Tabby", "Icon!")
            return false
        }

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
