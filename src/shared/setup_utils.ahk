#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Functions like CL_WriteIniPreserveFormat come from config_loader.ahk

; ============================================================
; Setup Utilities - Version, Task Scheduler, Shortcuts
; ============================================================
; Shared functions for first-run wizard, admin mode, and updates.
; Included by alt_tabby.ahk and tests.
;
; MsgBox icon policy: Iconx=error, Icon!=warning, Icon?=question, Iconi=info

; Task name constant - used by all task scheduler functions
global ALTTABBY_TASK_NAME := "Alt-Tabby"

; Admin task [ID:...] delimiter for embedding InstallationId in task description
global ADMIN_TASK_ID_PATTERN := "\[ID:([A-Fa-f0-9]{8})\]"

; Install directory constant - uses localized Program Files path
global ALTTABBY_INSTALL_DIR := A_ProgramFiles "\Alt-Tabby"

; PE validation constants
global PE_MIN_SIZE := 102400                ; 100KB minimum for valid AHK exe
global PE_MAX_SIZE := 52428800              ; 50MB maximum
global PE_MZ_MAGIC_1 := 77                  ; 'M' (0x4D)
global PE_MZ_MAGIC_2 := 90                  ; 'Z' (0x5A)
global PE_SIG_1 := 80                       ; 'P' (0x50)
global PE_SIG_2 := 69                       ; 'E' (0x45)

; Guard to prevent concurrent update checks (auto-update timer + manual button)
global g_UpdateCheckInProgress := false

; Update check state — persists across dashboard open/close
global g_LastUpdateCheckTick := 0
global g_LastUpdateCheckTime := ""

; ============================================================
; PATH COMPARISON HELPER
; ============================================================

; Case-insensitive path comparison (Windows paths are case-insensitive)
PathsEqual(a, b) {
    return StrLower(a) = StrLower(b)
}

; Check if admin mode is fully active (both config AND task agree)
; Used for tray menu checkmarks and shortcut descriptions
IsAdminModeFullyActive() {
    global cfg, g_CachedAdminTaskActive
    return cfg.SetupRunAsAdmin && g_CachedAdminTaskActive
}

; Cached admin task data — avoids redundant schtasks subprocess calls (~200-300ms each).
; Populated on first access, invalidated after CreateAdminTask/DeleteAdminTask.
; Only caches the default task name (ALTTABBY_TASK_NAME); overridden names bypass cache.
global g_AdminTaskCacheValid := false
global g_AdminTaskCache  ; {exists: bool, commandPath: str, installationId: str}

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
; TEMPORARY LOCATION DETECTION
; ============================================================

; Check if a path looks like a temporary or cloud-synced location
; Used to warn users before creating shortcuts to ephemeral paths
_IsTemporaryLocation(path) {
    lowerPath := StrLower(path)
    return (InStr(lowerPath, "\downloads")
        || InStr(lowerPath, "\temp")
        || InStr(lowerPath, "\desktop")
        || InStr(lowerPath, "\appdata\local\temp")
        || InStr(lowerPath, "\onedrive")
        || InStr(lowerPath, "\dropbox")
        || InStr(lowerPath, "\google drive")
        || InStr(lowerPath, "\icloud"))
}

; Warn if path is a temporary/cloud-synced location
; Returns "Yes" to proceed, "No" if user cancelled
; Parameters:
;   exePath  - Path to display in the warning
;   subject  - What will be affected (e.g., "shortcut", "shortcuts", "Alt-Tabby")
;   verb     - Action description (e.g., "will point to", "will always run from")
;   consequence - What happens if file moves (e.g., "the shortcut will break")
;   action   - Confirmation prompt (e.g., "Create shortcut anyway?")
WarnTemporaryLocation(exePath, subject, verb, consequence, action) {
    global APP_NAME
    dirPath := ""
    SplitPath(exePath, , &dirPath)
    if (!_IsTemporaryLocation(dirPath))
        return "Yes"

    msg := "This " subject " " verb ":`n" exePath "`n`n"
        . "This location may be temporary or cloud-synced.`n"
        . "If you delete or move this file, " consequence ".`n`n"
        . action
    return ThemeMsgBox(msg, APP_NAME " - Temporary Location", "YesNo Icon?")
}

; Warn if admin task would point to a temporary location
; Returns true to proceed, false if user cancelled
; Parameters:
;   exePath   - Path to exe that the admin task will point to
;   dirPath   - Directory to check (if empty, extracted from exePath)
;   extraText - Additional text to insert before the "Create admin task anyway?" line
WarnIfTempLocation_AdminTask(exePath, dirPath := "", extraText := "") {
    global APP_NAME
    if (dirPath = "") {
        SplitPath(exePath, , &dirPath)
    }
    if (!_IsTemporaryLocation(dirPath))
        return true  ; Not temporary, proceed

    msg := "The admin task will point to:`n" exePath "`n`n"
        . "This location may be temporary. If this file is moved or deleted, "
        . "admin mode will stop working.`n`n"
    if (extraText != "")
        msg .= extraText "`n`n"
    msg .= "Create admin task anyway?"

    warnResult := ThemeMsgBox(msg, APP_NAME " - Temporary Location", "YesNo Icon?")
    return (warnResult != "No")
}

; ============================================================
; DE-ELEVATION HELPER
; ============================================================

; Launch a process de-elevated via Explorer shell (ComObject Shell.Application)
; Returns true if launched successfully, false on failure
LaunchDeElevated(exePath, args := "", workDir := "") {
    if (workDir = "")
        SplitPath(exePath, , &workDir)
    try {
        shell := ComObject("Shell.Application")
        shell.ShellExecute(exePath, args, workDir)
        return true
    }
    return false
}

; ============================================================
; SELF-ELEVATION HELPER
; ============================================================

; Run the current script as administrator with the specified command-line arguments
; Returns: true if elevation was initiated, false if failed
; Note: If successful, the current process should exit to let the elevated one run
Launcher_RunAsAdmin(args) {
    try {
        if (A_IsCompiled)
            Run('*RunAs "' A_ScriptFullPath '" ' args)
        else
            Run('*RunAs "' A_AhkPath '" "' A_ScriptFullPath '" ' args)
        return true
    } catch {
        return false
    }
}

; Build a command line to relaunch the current script (compiled or dev mode)
; DRY helper — replaces 7+ occurrences of the compiled/dev branch pattern
BuildSelfCommand(args := "") {
    if (A_IsCompiled)
        cmd := '"' A_ScriptFullPath '"'
    else
        cmd := '"' A_AhkPath '" "' A_ScriptFullPath '"'
    if (args != "")
        cmd .= " " args
    return cmd
}

; Write result to admin toggle lock file for the non-elevated instance to read.
; Valid results: "ok", "cancelled", "failed"
AdminToggle_WriteResult(result) {
    global TEMP_ADMIN_TOGGLE_LOCK
    try {
        tempPath := TEMP_ADMIN_TOGGLE_LOCK ".tmp"
        try FileDelete(tempPath)
        FileAppend(result, tempPath)  ; lint-ignore: fileappend-encoding
        FileMove(tempPath, TEMP_ADMIN_TOGGLE_LOCK, true)  ; Atomic overwrite
    }
}

; ============================================================
; SUBPROCESS TIMEOUT HELPER
; ============================================================
; Runs a command with a timeout. Returns the exit code, or -1 on timeout.
; Uses Run (non-blocking) + ProcessWaitClose with timeout + ProcessClose on timeout.
; Timeout in milliseconds; default 10 seconds (generous for schtasks).

_RunWithTimeout(cmd, timeoutMs := 10000, options := "Hide") {
    pid := 0
    try {
        Run(cmd, , options, &pid)
    } catch {
        return -1
    }
    if (!pid)
        return -1

    ; Wait for process to finish within timeout (seconds for ProcessWaitClose)
    timeoutSec := timeoutMs / 1000
    result := ProcessWaitClose(pid, timeoutSec)
    if (result = 0 && ProcessExist(pid)) {
        ; Timeout — process still running, force kill
        try ProcessClose(pid)
        return -1
    }

    ; Process finished (either caught by WaitClose or already exited) — get exit code
    try return _ProcessGetExitCode(pid)
    return 0
}

; Get exit code of a recently-exited process via Win32 API
_ProcessGetExitCode(pid) {
    global PROCESS_QUERY_LIMITED_INFORMATION
    hProcess := DllCall("OpenProcess", "UInt", PROCESS_QUERY_LIMITED_INFORMATION, "Int", 0, "UInt", pid, "Ptr")
    if (!hProcess)
        return 0
    exitCode := 0
    DllCall("GetExitCodeProcess", "Ptr", hProcess, "UInt*", &exitCode)
    DllCall("CloseHandle", "Ptr", hProcess)
    return exitCode
}

; ============================================================
; TASK SCHEDULER (ADMIN MODE)
; ============================================================

; Create a scheduled task with highest privileges (UAC-free admin)
; Includes InstallationId in description for identification
; Returns false if user cancels due to existing task conflict
CreateAdminTask(exePath, installId := "", taskNameOverride := "") {
    global ALTTABBY_TASK_NAME, cfg, g_TestingMode, APP_NAME
    taskName := (taskNameOverride != "") ? taskNameOverride : ALTTABBY_TASK_NAME

    ; Check if task exists pointing to different location (another installation)
    ; Warn user before silently overwriting another installation's admin mode
    ; Skip dialog in testing mode to avoid blocking automated tests
    if (AdminTaskExists(taskName)) {
        existingPath := AdminTask_GetCommandPath(taskName)
        if (existingPath != "" && !PathsEqual(existingPath, exePath)) {
            ; In testing mode, just proceed without prompting
            if (g_TestingMode) {
                ; Auto-proceed in testing mode
            } else {
                result := ThemeMsgBox(
                    "Another Alt-Tabby installation has Admin Mode enabled:`n"
                    existingPath "`n`n"
                    "Enabling it here will disable it there.`n"
                    "Continue?",
                    APP_NAME " - Admin Mode Conflict",
                    "YesNo Icon?"
                )
                if (result = "No")
                    return false
            }
        }
    }

    ; Get InstallationId if not provided
    if (installId = "" && IsSet(cfg) && cfg.HasOwnProp("SetupInstallationId"))  ; lint-ignore: isset-with-default
        installId := cfg.SetupInstallationId

    ; Build description with embedded ID for later identification (see ADMIN_TASK_ID_PATTERN)
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
    result := _RunWithTimeout('schtasks /create /tn "' taskName '" /xml "' xmlPath '" /f')

    try FileDelete(xmlPath)
    _AdminTask_InvalidateCache()

    return (result = 0)
}

; Delete the admin scheduled task
DeleteAdminTask(taskNameOverride := "") {
    global ALTTABBY_TASK_NAME
    taskName := (taskNameOverride != "") ? taskNameOverride : ALTTABBY_TASK_NAME
    result := _RunWithTimeout('schtasks /delete /tn "' taskName '" /f')
    _AdminTask_InvalidateCache()
    return (result = 0)
}

; Get cached admin task data (exists, commandPath, installationId) in a single schtasks call.
; First call fetches XML and parses both fields; subsequent calls return cached result.
; Only caches the default task name; callers with taskNameOverride bypass the cache.
_AdminTask_GetCachedData() {
    global g_AdminTaskCacheValid, g_AdminTaskCache, ADMIN_TASK_ID_PATTERN

    if (g_AdminTaskCacheValid)
        return g_AdminTaskCache

    ; Fetch XML once and parse all fields
    xml := _AdminTask_FetchXML()
    result := {exists: false, commandPath: "", installationId: ""}

    if (xml != "") {
        result.exists := true
        if (RegExMatch(xml, '<Command>"?([^"<]+)"?</Command>', &cmdMatch))
            result.commandPath := cmdMatch[1]
        if (RegExMatch(xml, ADMIN_TASK_ID_PATTERN, &idMatch))
            result.installationId := idMatch[1]
    }

    g_AdminTaskCache := result
    g_AdminTaskCacheValid := true
    return result
}

; Invalidate the admin task cache. Must be called after CreateAdminTask/DeleteAdminTask.
_AdminTask_InvalidateCache() {
    global g_AdminTaskCacheValid
    g_AdminTaskCacheValid := false
}

; Check if admin task exists
AdminTaskExists(taskNameOverride := "") {
    global ALTTABBY_TASK_NAME
    ; Use cache for default task name (avoids ~200-300ms schtasks call)
    if (taskNameOverride = "")
        return _AdminTask_GetCachedData().exists

    taskName := taskNameOverride
    result := _RunWithTimeout('schtasks /query /tn "' taskName '"')
    return (result = 0)  ; 0 = task exists
}

; Fetch raw XML from a scheduled task via schtasks /query /xml
; Returns XML string or "" on failure. Handles temp file creation/cleanup.
_AdminTask_FetchXML(taskNameOverride := "") {
    global ALTTABBY_TASK_NAME
    taskName := (taskNameOverride != "") ? taskNameOverride : ALTTABBY_TASK_NAME
    tempFile := A_Temp "\alttabby_task_query.xml"
    try FileDelete(tempFile)

    result := _RunWithTimeout('cmd.exe /c schtasks /query /tn "' taskName '" /xml > "' tempFile '"')
    if (result != 0 || !FileExist(tempFile))
        return ""

    try {
        xml := FileRead(tempFile, "UTF-8")
        FileDelete(tempFile)
        return xml
    }
    return ""
}

; Extract command path from existing scheduled task XML
; Returns empty string if task doesn't exist or can't be parsed
AdminTask_GetCommandPath(taskNameOverride := "") {
    ; Use cache for default task name
    if (taskNameOverride = "")
        return _AdminTask_GetCachedData().commandPath

    xml := _AdminTask_FetchXML(taskNameOverride)
    if (xml = "")
        return ""
    if (RegExMatch(xml, '<Command>"?([^"<]+)"?</Command>', &match))
        return match[1]
    return ""
}

; Extract InstallationId from task description
; Returns empty string if task doesn't exist or has no ID
AdminTask_GetInstallationId() {
    return _AdminTask_GetCachedData().installationId
}

; Check if admin task exists AND points to the current exe
; Used for tray menu checkmark - prevents misleading state when task points elsewhere
AdminTask_PointsToUs() {
    data := _AdminTask_GetCachedData()
    if (!data.exists || data.commandPath = "")
        return false
    return PathsEqual(data.commandPath, A_ScriptFullPath)
}

; Ensure admin task exists and points to the given exe with the given ID.
; Skips delete+create if already correct (unless deleteFirst is true).
; Returns true on success, false on failure.
AdminTask_EnsurePointsTo(exePath, installId, deleteFirst := false) {
    if (!deleteFirst && AdminTaskExists()) {
        existingPath := AdminTask_GetCommandPath()
        existingId := AdminTask_GetInstallationId()
        if (PathsEqual(existingPath, exePath) && existingId = installId)
            return true
    }
    if (AdminTaskExists())
        DeleteAdminTask()
    return CreateAdminTask(exePath, installId)
}

; Run the admin scheduled task via schtasks, with optional pre-delay.
; Returns the schtasks exit code (0 = success).
RunAdminTask(sleepMs := 0) {
    global ALTTABBY_TASK_NAME
    if (sleepMs > 0)
        Sleep(sleepMs)
    return _RunWithTimeout('schtasks /run /tn "' ALTTABBY_TASK_NAME '"')
}

; ============================================================
; ADMIN DECLINED MARKER (BUG 3 fix)
; ============================================================
; Temp file marker for when UAC is declined but config write to PF fails.
; Persists across sessions until config write succeeds. NOT cleaned up by
; Update_CleanupStaleTempFiles() — must persist until the loop is broken.

_Setup_WriteAdminDeclinedMarker() {
    global TEMP_ADMIN_DECLINED_MARKER
    try FileAppend(A_Now, TEMP_ADMIN_DECLINED_MARKER, "UTF-8")
}

Setup_HasAdminDeclinedMarker() {
    global TEMP_ADMIN_DECLINED_MARKER
    return FileExist(TEMP_ADMIN_DECLINED_MARKER) ? true : false
}

Setup_ClearAdminDeclinedMarker() {
    global TEMP_ADMIN_DECLINED_MARKER
    try FileDelete(TEMP_ADMIN_DECLINED_MARKER)
}

; ============================================================
; CONFIG SETUP WRITE HELPERS (DRY consolidation)
; ============================================================
; Centralized helpers for writing Setup config values to gConfigIniPath.
; For cross-location writes (targetConfigPath), use CL_WriteIniPreserveFormat directly.

Setup_SetRunAsAdmin(value, writeMarkerOnFail := false) {
    global cfg, gConfigIniPath
    cfg.SetupRunAsAdmin := value
    writeOk := false
    try writeOk := CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "RunAsAdmin", value, false, "bool")
    if (!writeOk && writeMarkerOnFail && !value)
        _Setup_WriteAdminDeclinedMarker()
    return writeOk
}

Setup_SetExePath(value) {
    global cfg, gConfigIniPath
    cfg.SetupExePath := value
    try return CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "ExePath", value, "", "string")
    return false
}

Setup_SetFirstRunCompleted(value) {
    global cfg, gConfigIniPath
    cfg.SetupFirstRunCompleted := value
    try return CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "FirstRunCompleted", value, false, "bool")
    return false
}

Setup_SetInstallationId(value) {
    global cfg, gConfigIniPath
    cfg.SetupInstallationId := value
    try return CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "InstallationId", value, "", "string")
    return false
}

; Read a boolean value from an INI file (handles "true"/"1" as true, everything else as false)
ReadIniBool(filePath, section, key, default := false) {
    try {
        iniVal := IniRead(filePath, section, key, default ? "true" : "false")
        return (iniVal = "true" || iniVal = "1")
    }
    return default
}

; ============================================================
; SHORTCUT PATH HELPERS
; ============================================================

; Get the path where Start Menu shortcut would be
Shortcut_GetStartMenuPath() {
    return A_AppData "\Microsoft\Windows\Start Menu\Programs\Alt-Tabby.lnk"
}

; Get the path where Startup shortcut would be
Shortcut_GetStartupPath() {
    return A_Startup "\Alt-Tabby.lnk"
}

; Check if Start Menu shortcut exists AND points to current exe
; Returns false if shortcut exists but points to different location (prevents misleading checkmarks)
Shortcut_StartMenuExists() {
    return Shortcut_ExistsAndPointsToUs(Shortcut_GetStartMenuPath())
}

; Check if Startup shortcut exists AND points to current exe
; Returns false if shortcut exists but points to different location (prevents misleading checkmarks)
Shortcut_StartupExists() {
    return Shortcut_ExistsAndPointsToUs(Shortcut_GetStartupPath())
}

; Helper: Check if shortcut exists and its target matches current exe
Shortcut_ExistsAndPointsToUs(lnkPath) {
    if (!FileExist(lnkPath))
        return false

    try {
        shell := ComObject("WScript.Shell")
        shortcut := shell.CreateShortcut(lnkPath)
        targetPath := shortcut.TargetPath

        ; In compiled mode, compare target to effective exe path (respects SetupExePath)
        ; In dev mode, compare to AutoHotkey.exe (we're run via AHK)
        ourTarget := A_IsCompiled ? Shortcut_GetEffectiveExePath() : A_AhkPath

        return PathsEqual(targetPath, ourTarget)
    } catch {
        ; If we can't read the shortcut, assume it doesn't match
        return false
    }
}

; Get the icon path - in compiled mode, icon is embedded in exe
; Uses effective exe path to ensure icon remains valid even if user deletes the running exe
Shortcut_GetIconPath() {
    if (A_IsCompiled)
        return Shortcut_GetEffectiveExePath()  ; Icon is embedded in exe - use same path as shortcut target
    else
        return A_ScriptDir "\..\resources\img\icon.ico"
}

; Get the effective exe path (installed location or current)
Shortcut_GetEffectiveExePath() {
    global cfg
    if (IsSet(cfg) && cfg.HasOwnProp("SetupExePath") && cfg.SetupExePath != "" && FileExist(cfg.SetupExePath))  ; lint-ignore: isset-with-default
        return cfg.SetupExePath
    return A_IsCompiled ? A_ScriptFullPath : A_ScriptFullPath
}

; ============================================================
; AUTO-UPDATE SYSTEM
; ============================================================
; Flow: Check GitHub → Download to temp → Swap exe → Relaunch
; Handles elevation for Program Files installs.

_Update_Log(msg) {
    global cfg, LOG_PATH_UPDATE
    if (!cfg.DiagUpdateLog)
        return
    try LogAppend(LOG_PATH_UPDATE, msg)
}

; Check for updates and optionally offer to install
; showIfCurrent: If true, show message even when up to date
CheckForUpdates(showIfCurrent := false, showModal := true) {
    global g_UpdateCheckInProgress, g_LastUpdateCheckTick, g_LastUpdateCheckTime, cfg

    ; Prevent concurrent update checks (auto-update timer + manual button race)
    if (g_UpdateCheckInProgress) {
        if (showIfCurrent)
            TrayTip("Update Check", "An update check is already in progress.", "Iconi")
        return
    }
    g_UpdateCheckInProgress := true

    currentVersion := GetAppVersion()
    if (cfg.DiagUpdateLog)
        _Update_Log("CheckForUpdates: current=" currentVersion " showModal=" showModal)
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
                _Update_Log("CheckForUpdates: failed to parse tag_name from response")
                Dash_SetUpdateState("error")
                g_LastUpdateCheckTick := A_TickCount
                g_LastUpdateCheckTime := FormatTime(, "MMM d, h:mm tt")
                g_UpdateCheckInProgress := false
                return
            }

            latestVersion := tagMatch[1]
            g_LastUpdateCheckTick := A_TickCount
            g_LastUpdateCheckTime := FormatTime(, "MMM d, h:mm tt")
            if (cfg.DiagUpdateLog)
                _Update_Log("CheckForUpdates: latest=" latestVersion " current=" currentVersion)

            if (CompareVersions(latestVersion, currentVersion) > 0) {
                ; Sync dashboard state — update available
                downloadUrl := _Update_FindExeDownloadUrl(response)
                Dash_SetUpdateState("available", latestVersion, downloadUrl ? downloadUrl : "")

                ; Newer version available - offer to update
                if (showModal) {
                    result := ThemeMsgBox(
                        "Alt-Tabby " latestVersion " is available!`n"
                        "You have: " currentVersion "`n`n"
                        "Would you like to download and install the update now?",
                        "Update Available",
                        "YesNo Icon?"
                    )

                    if (result = "Yes") {
                        if (downloadUrl)
                            Update_DownloadAndApply(downloadUrl, latestVersion)
                        else
                            ThemeMsgBox("Could not find download URL for AltTabby.exe in the release.", "Update Error", "Iconx")
                    }
                }
            } else {
                ; Sync dashboard state — up to date
                Dash_SetUpdateState("uptodate")
                if (showIfCurrent && showModal)
                    TrayTip("Up to Date", "You're running the latest version (" currentVersion ")", "Iconi")
            }
        } else {
            ; Sync dashboard state — HTTP error
            if (cfg.DiagUpdateLog)
                _Update_Log("CheckForUpdates: HTTP error status=" whr.Status)
            Dash_SetUpdateState("error")
            g_LastUpdateCheckTick := A_TickCount
            g_LastUpdateCheckTime := FormatTime(, "MMM d, h:mm tt")
            if (showIfCurrent && showModal) {
                TrayTip("Update Check Failed", "HTTP Status: " whr.Status, "Icon!")
            }
            whr := ""  ; Release COM on error path
        }
    } catch as e {
        whr := ""  ; Ensure release on exception
        if (cfg.DiagUpdateLog)
            _Update_Log("CheckForUpdates: exception: " e.Message)
        ; Sync dashboard state — exception
        Dash_SetUpdateState("error")
        g_LastUpdateCheckTick := A_TickCount
        g_LastUpdateCheckTime := FormatTime(, "MMM d, h:mm tt")
        if (showIfCurrent && showModal)
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
Update_DownloadAndApply(downloadUrl, newVersion) {
    global cfg
    ; Determine paths
    currentExe := A_ScriptFullPath
    exeDir := ""
    SplitPath(currentExe, , &exeDir)
    tempExe := A_Temp "\AltTabby_" newVersion ".exe"
    if (cfg.DiagUpdateLog)
        _Update_Log("DownloadAndApply: version=" newVersion " target=" tempExe)

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
        if (cfg.DiagUpdateLog)
            _Update_Log("DownloadAndApply: downloading from " downloadUrl)
        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.Open("GET", downloadUrl, false)
        whr.SetTimeouts(30000, 30000, 30000, 120000)  ; 30s connect/send/receive, 120s total
        whr.SetRequestHeader("User-Agent", "Alt-Tabby/" GetAppVersion())
        whr.Send()

        if (whr.Status != 200) {
            if (cfg.DiagUpdateLog)
                _Update_Log("DownloadAndApply: HTTP error status=" whr.Status)
            ThemeMsgBox("Download failed: HTTP " whr.Status, "Update Error", "Iconx")
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
        if (cfg.DiagUpdateLog)
            _Update_Log("DownloadAndApply: download saved to " tempExe)
    } catch as e {
        stream := ""  ; Cleanup COM objects on error
        whr := ""
        if (cfg.DiagUpdateLog)
            _Update_Log("DownloadAndApply: download exception: " e.Message)
        ; Clean up partial download
        if (FileExist(tempExe))
            try FileDelete(tempExe)
        ThemeMsgBox("The update could not be downloaded. Check your internet connection and try again.`n`nDetails: " e.Message, "Update Error", "Iconx")
        return
    }

    ; Check if we need elevation to write to exe directory
    if (Update_NeedsElevation(exeDir)) {
        if (cfg.DiagUpdateLog)
            _Update_Log("DownloadAndApply: elevation required for " exeDir)
        ; Save update info and self-elevate
        global TEMP_UPDATE_STATE
        WriteStateFile(TEMP_UPDATE_STATE, tempExe, currentExe)

        try {
            if (!Launcher_RunAsAdmin("--apply-update"))
                throw Error("RunAsAdmin failed")
            ExitApp()
        } catch {
            _Update_Log("DownloadAndApply: elevation failed")
            ThemeMsgBox("Update requires administrator privileges.`nPlease run as administrator to update.", "Update Error", "Iconx")
            try FileDelete(TEMP_UPDATE_STATE)
            try FileDelete(tempExe)  ; Clean up downloaded exe
            return
        }
    }

    ; Apply the update directly
    _Update_Log("DownloadAndApply: applying directly (no elevation needed)")
    _Update_ApplyAndRelaunch(tempExe, currentExe)
}

; Check if we need elevation to write to the target directory
Update_NeedsElevation(targetDir) {
    if (A_IsAdmin)
        return false

    ; Bug 5 fix: Validate directory exists first
    ; If directory doesn't exist, we'll need admin to create it (e.g., Program Files)
    if (!DirExist(targetDir))
        return true

    ; Try to create a temp file in the target directory
    testFile := targetDir "\alttabby_write_test.tmp"
    try {
        FileAppend("test", testFile)  ; lint-ignore: fileappend-encoding
        FileDelete(testFile)
        return false  ; Write succeeded, no elevation needed
    } catch {
        return true  ; Write failed, need elevation
    }
}

; ============================================================
; UPDATE CORE - Shared logic for applying updates
; ============================================================
; Used by both Launcher_DoUpdateInstalled (mismatch update) and
; _Update_ApplyAndRelaunch (auto-update). Extracted to eliminate duplication.
;
; Options:
;   sourcePath - Path to new exe (source of update)
;   targetPath - Path to install to (destination)
;   useLockFile - Use lock file to prevent concurrent updates
;   validatePE - Validate PE header before applying
;   copyMode - true = FileCopy (keep source), false = FileMove (delete source)
;   successMessage - Message to show in TrayTip on success
;   cleanupSourceOnFailure - Delete source file if update fails
;   relaunchAfter - After success: show TrayTip, cleanup .old, relaunch+exit (default: true)
;   overwriteUserData - Copy config/blacklist even if target already has them (default: false)
;   killPids - Optional {gui:, store:, viewer:} PIDs for graceful shutdown before force-kill

Update_ApplyCore(opts) {
    global cfg, gConfigIniPath, TIMING_PROCESS_EXIT_WAIT, TIMING_STORE_START_WAIT, APP_NAME

    sourcePath := opts.HasOwnProp("sourcePath") ? opts.sourcePath : ""
    targetPath := opts.HasOwnProp("targetPath") ? opts.targetPath : ""
    useLockFile := opts.HasOwnProp("useLockFile") ? opts.useLockFile : false
    validatePE := opts.HasOwnProp("validatePE") ? opts.validatePE : false
    copyMode := opts.HasOwnProp("copyMode") ? opts.copyMode : false
    successMessage := opts.HasOwnProp("successMessage") ? opts.successMessage : "Alt-Tabby has been updated."
    cleanupSourceOnFailure := opts.HasOwnProp("cleanupSourceOnFailure") ? opts.cleanupSourceOnFailure : false
    relaunchAfter := opts.HasOwnProp("relaunchAfter") ? opts.relaunchAfter : true
    overwriteUserData := opts.HasOwnProp("overwriteUserData") ? opts.overwriteUserData : false
    killPids := opts.HasOwnProp("killPids") ? opts.killPids : ""

    lockFile := ""
    if (useLockFile) {
        global TEMP_UPDATE_LOCK
        lockFile := TEMP_UPDATE_LOCK
        if (FileExist(lockFile)) {
            try {
                modTime := FileGetTime(lockFile, "M")
                if (DateDiff(A_Now, modTime, "Minutes") < 5) {
                    ThemeMsgBox("Another update is in progress. Please wait.", APP_NAME, "Icon!")
                    return
                }
                FileDelete(lockFile)
            }
        }
        try FileAppend(A_Now, lockFile)  ; lint-ignore: fileappend-encoding
    }

    targetDir := ""
    SplitPath(targetPath, , &targetDir)
    targetConfigPath := targetDir "\config.ini"
    backupPath := targetPath ".old"

    try {
        ; Ensure target directory exists (e.g., fresh install to Program Files)
        if (!DirExist(targetDir))
            DirCreate(targetDir)

        ; Kill all other AltTabby.exe processes
        ; When killPids provided: graceful shutdown first (flush stats), then force sweep
        ; When no PIDs: force-only (elevated CLI modes without launcher context)
        targetExeName := ""
        SplitPath(targetPath, &targetExeName)
        killOpts := {force: true, targetExeName: targetExeName}
        if (killPids)
            killOpts.pids := killPids
        ProcessUtils_KillAltTabby(killOpts)
        Sleep(TIMING_PROCESS_EXIT_WAIT)

        ; Rename existing exe to .old (skip if no exe at target, e.g., fresh PF directory)
        if (FileExist(targetPath)) {
            if (FileExist(backupPath))
                FileDelete(backupPath)
            try {
                FileMove(targetPath, backupPath)
            } catch as renameErr {
                if (lockFile != "")
                    try FileDelete(lockFile)
                ThemeMsgBox("Could not rename existing version:`n" renameErr.Message "`n`nUpdate aborted. The file may be locked by antivirus or another process.", "Update Error", "Iconx")
                return
            }
        }

        ; Validate PE header if requested
        if (validatePE && !_Update_ValidatePEFile(sourcePath)) {
            if (FileExist(backupPath))
                FileMove(backupPath, targetPath)
            if (lockFile != "")
                try FileDelete(lockFile)
            ThemeMsgBox("Downloaded file appears to be corrupted (invalid PE header).`nUpdate aborted.", "Update Error", "Iconx")
            return
        }

        ; Copy or move new exe to target location
        if (copyMode)
            FileCopy(sourcePath, targetPath)
        else
            FileMove(sourcePath, targetPath)

        ; Copy user data files (config, stats, blacklist) to target if missing/merge
        srcDir := ""
        SplitPath(gConfigIniPath, , &srcDir)
        _Update_CopyUserData(srcDir, targetDir, overwriteUserData)

        ; Update config at target location (track write failures for user warning)
        writeWarnings := []
        cfg.SetupExePath := targetPath
        if (FileExist(targetConfigPath)) {
            try {
                CL_WriteIniPreserveFormat(targetConfigPath, "Setup", "ExePath", targetPath, "", "string")
            } catch {
                writeWarnings.Push("ExePath")
            }
        }

        ; Read admin mode from target config
        targetRunAsAdmin := ReadIniBool(targetConfigPath, "Setup", "RunAsAdmin")

        ; Update admin task if target has admin mode enabled
        if (targetRunAsAdmin && AdminTaskExists()) {
            targetInstallId := ""
            if (FileExist(targetConfigPath)) {
                try targetInstallId := IniRead(targetConfigPath, "Setup", "InstallationId", "")
            }
            if (targetInstallId = "") {
                targetInstallId := Launcher_GenerateId()
                if (FileExist(targetConfigPath)) {
                    try {
                        CL_WriteIniPreserveFormat(targetConfigPath, "Setup", "InstallationId", targetInstallId, "", "string")
                    } catch {
                        writeWarnings.Push("InstallationId")
                    }
                }
            }

            if (!AdminTask_EnsurePointsTo(targetPath, targetInstallId)) {
                ThemeMsgBox("Could not recreate admin task after update.`n`n"
                    "Admin mode has been disabled. You can re-enable it from the tray menu.",
                    APP_NAME " - Admin Mode Error", "Icon!")
                cfg.SetupRunAsAdmin := false
                if (FileExist(targetConfigPath)) {
                    try {
                        CL_WriteIniPreserveFormat(targetConfigPath, "Setup", "RunAsAdmin", false, false, "bool")
                    } catch {
                        writeWarnings.Push("RunAsAdmin")
                    }
                }
            }
        }

        ; Warn about config write failures (exe update succeeded but config may be stale)
        if (writeWarnings.Length > 0) {
            failedFields := ""
            for f in writeWarnings
                failedFields .= (failedFields != "" ? ", " : "") f
            ThemeMsgBox("Update succeeded, but some settings could not be saved:`n" failedFields "`n`nConfig: " targetConfigPath "`nYou may need to reconfigure from the tray menu.", APP_NAME " - Config Warning", "Icon!")
        }

        ; Sync runtime config for shortcut description (source config may differ from target)
        cfg.SetupRunAsAdmin := targetRunAsAdmin

        ; Recreate shortcuts to point to updated exe (Bug 5 fix)
        ; This ensures shortcuts work after exe rename + auto-update
        RecreateShortcuts()

        ; Success — relaunch unless caller handles it (e.g., wizard)
        if (relaunchAfter) {
            TrayTip("Update Complete", successMessage, "Iconi")
            Sleep(TIMING_STORE_START_WAIT)

            ; Cleanup command for backup
            cleanupCmd := 'cmd.exe /c timeout /t 4 /nobreak > nul 2>&1 && del "' backupPath '" 2>nul || (timeout /t 4 /nobreak > nul 2>&1 && del "' backupPath '")'
            Run(cleanupCmd,, "Hide")

            if (lockFile != "")
                try FileDelete(lockFile)

            ; Launch new version — de-elevate if admin mode is not configured
            if (A_IsAdmin && !targetRunAsAdmin) {
                if (LaunchDeElevated(targetPath, "", targetDir))
                    ExitApp()
                TrayTip("Note", "Running elevated. Restart manually for non-admin mode.", "Icon!")
                return
            }
            Run('"' targetPath '"')
            ExitApp()
        }

        if (lockFile != "")
            try FileDelete(lockFile)

    } catch as e {
        ; Rollback - handle partial/corrupted targetPath from failed copy/move
        rollbackSuccess := false
        if (FileExist(targetPath)) {
            ; targetPath exists but may be partial/corrupted from failed copy/move
            ; Remove it so we can restore the known-good backup (or just clean up partial on fresh install)
            try FileDelete(targetPath)
        }
        if (!FileExist(targetPath) && FileExist(backupPath)) {
            try {
                FileMove(backupPath, targetPath)
                rollbackSuccess := true
            }
        }

        ; Clean up source on failure if requested
        if (cleanupSourceOnFailure && FileExist(sourcePath))
            try FileDelete(sourcePath)

        if (lockFile != "")
            try FileDelete(lockFile)

        if (rollbackSuccess)
            ThemeMsgBox("The update could not be applied. The previous version has been restored.`n`nDetails: " e.Message, "Update Error", "Iconx")
        else if (FileExist(targetPath))
            ThemeMsgBox("The update could not be applied. The file may be locked by antivirus or another process.`n`nDetails: " e.Message, "Update Error", "Iconx")
        else
            ThemeMsgBox("The update failed and the previous version could not be restored.`nPlease reinstall Alt-Tabby.`n`nDetails: " e.Message, "Alt-Tabby Critical", "Iconx")
    }
}

; Apply update: rename current exe, move new exe, relaunch
; Wrapper for auto-update flow - uses Update_ApplyCore with appropriate options
_Update_ApplyAndRelaunch(newExePath, targetExePath) {
    global g_StorePID, g_GuiPID, g_ViewerPID
    Update_ApplyCore({
        sourcePath: newExePath,
        targetPath: targetExePath,
        useLockFile: true,
        validatePE: true,
        copyMode: false,               ; FileMove (delete source after copy)
        successMessage: "Alt-Tabby has been updated. Restarting...",
        cleanupSourceOnFailure: true,
        killPids: {gui: g_GuiPID, store: g_StorePID, viewer: g_ViewerPID}
    })
}

; Called on startup to clean up old exe from previous update
; This is a fallback - the elevated updater schedules cleanup via cmd.exe,
; but this handles cases where: (1) exe is not in Program Files (no elevation needed),
; or (2) the scheduled cmd cleanup somehow failed
Update_CleanupOldExe() {
    if (!A_IsCompiled)
        return

    oldExe := A_ScriptFullPath ".old"
    if (FileExist(oldExe)) {
        try FileDelete(oldExe)
    }
}

; Clean up stale temp files from crashed wizard/update instances (Priority 3 fix)
; Called on startup after Update_CleanupOldExe
Update_CleanupStaleTempFiles() {
    global TEMP_ADMIN_TOGGLE_LOCK, TEMP_WIZARD_STATE, TEMP_UPDATE_STATE, TEMP_UPDATE_LOCK, TEMP_INSTALL_PF_STATE, TEMP_INSTALL_UPDATE_STATE
    staleFiles := [
        TEMP_WIZARD_STATE,
        TEMP_UPDATE_STATE,
        TEMP_INSTALL_UPDATE_STATE,
        TEMP_ADMIN_TOGGLE_LOCK,
        TEMP_UPDATE_LOCK,
        TEMP_INSTALL_PF_STATE
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

; Copy user data files (config, blacklist, stats) from source to target directory.
; Config and blacklist: copy only if not present at target (preserve customizations).
; When overwrite=true, config and blacklist are always copied (mismatch-update flow).
; Stats: merge additively if both exist, copy if source-only.
; No-op when srcDir == targetDir (e.g., auto-update in place).
_Update_CopyUserData(srcDir, targetDir, overwrite := false) {
    if (PathsEqual(srcDir, targetDir))
        return

    ; Config: copy if not present, or always if overwrite (mismatch-update pushes active config)
    if (FileExist(srcDir "\config.ini") && (overwrite || !FileExist(targetDir "\config.ini")))
        try FileCopy(srcDir "\config.ini", targetDir "\config.ini", true)

    ; Blacklist: copy if not present, or always if overwrite
    if (FileExist(srcDir "\blacklist.txt") && (overwrite || !FileExist(targetDir "\blacklist.txt")))
        try FileCopy(srcDir "\blacklist.txt", targetDir "\blacklist.txt", true)

    ; Stats: merge if both exist, copy if source-only
    srcStats := srcDir "\stats.ini"
    targetStats := targetDir "\stats.ini"
    if (FileExist(srcStats)) {
        if (!FileExist(targetStats)) {
            try FileCopy(srcStats, targetStats)
        } else {
            _Update_MergeStats(srcStats, targetStats)
        }
    }
    ; Stats backup: copy if not present (don't merge backups)
    if (FileExist(srcDir "\stats.ini.bak") && !FileExist(targetDir "\stats.ini.bak"))
        try FileCopy(srcDir "\stats.ini.bak", targetDir "\stats.ini.bak")
}

; Merge stats from source into target, adding counters together (Bug 4 fix)
; This preserves both sets of stats when updating across installations.
; Uses delta-based merge: tracks source snapshots at merge time so repeated
; merges only add what's new (prevents double-counting AND silent data loss).
_Update_MergeStats(srcPath, targetPath) {
    ; IMPORTANT: These keys must match the lifetime counter keys written by _Stats_FlushToDisk().
    ; If you add/rename a lifetime stat, update this list too.
    lifetimeKeys := [
        "TotalSessions",
        "TotalAltTabs",
        "TotalQuickSwitches",
        "TotalTabSteps",
        "TotalCancellations",
        "TotalCrossWS",
        "TotalWSToggles"
    ]

    ; Resolve target installation ID (survives directory renames)
    targetDir := ""
    SplitPath(targetPath, , &targetDir)
    targetConfigPath := targetDir "\config.ini"
    targetInstallId := ""
    if (FileExist(targetConfigPath))
        try targetInstallId := IniRead(targetConfigPath, "Setup", "InstallationId", "")

    ; Check if we've previously merged to this same target
    previouslyMerged := false
    if (targetInstallId != "") {
        try {
            lastMergedToId := IniRead(srcPath, "Merged", "LastMergedToId", "")
            if (lastMergedToId = targetInstallId)
                previouslyMerged := true
        }
    }
    if (!previouslyMerged) {
        try {
            lastMerged := IniRead(srcPath, "Merged", "LastMergedTo", "")
            if (PathsEqual(lastMerged, targetPath))
                previouslyMerged := true
        }
    }

    if (previouslyMerged) {
        ; Delta merge: only add stats accumulated since last merge
        hasNewStats := false
        for key in lifetimeKeys {
            try {
                srcVal := Integer(IniRead(srcPath, "Lifetime", key, "0"))
                snapVal := Integer(IniRead(srcPath, "Merged", "Snap_" key, "0"))
                if (srcVal != snapVal) {
                    hasNewStats := true
                    break
                }
            }
        }
        if (!hasNewStats)
            return  ; Source unchanged since last merge — true duplicate

        ; Apply deltas (current source - snapshot) to target
        for key in lifetimeKeys {
            try {
                srcVal := Integer(IniRead(srcPath, "Lifetime", key, "0"))
                snapVal := Integer(IniRead(srcPath, "Merged", "Snap_" key, "0"))
                delta := srcVal - snapVal
                if (delta > 0) {
                    targetVal := Integer(IniRead(targetPath, "Lifetime", key, "0"))
                    IniWrite(targetVal + delta, targetPath, "Lifetime", key)
                }
            }
        }
    } else {
        ; First merge to this target: add full source values
        for key in lifetimeKeys {
            try {
                srcVal := Integer(IniRead(srcPath, "Lifetime", key, "0"))
                targetVal := Integer(IniRead(targetPath, "Lifetime", key, "0"))
                IniWrite(srcVal + targetVal, targetPath, "Lifetime", key)
            }
        }
    }

    ; Record merge marker and snapshot of current source values
    try IniWrite(targetPath, srcPath, "Merged", "LastMergedTo")
    if (targetInstallId != "")
        try IniWrite(targetInstallId, srcPath, "Merged", "LastMergedToId")
    for key in lifetimeKeys {
        try {
            srcVal := Integer(IniRead(srcPath, "Lifetime", key, "0"))
            IniWrite(srcVal, srcPath, "Merged", "Snap_" key)
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

        ; Read DOS header + PE signature in one session, then close immediately.
        ; Single close point eliminates handle leak risk on early-return paths.
        f := FileOpen(filePath, "r")
        if (!f)
            return false

        buf := Buffer(64)
        dosRead := f.RawRead(buf, 64)

        ; Read PE signature only if DOS header looks valid enough to contain e_lfanew
        peBuf := Buffer(4)
        peRead := 0
        e_lfanew := 0
        if (dosRead >= 64) {
            e_lfanew := NumGet(buf, 0x3C, "UInt")
            if (e_lfanew >= 64 && e_lfanew <= 1024) {
                f.Seek(e_lfanew)
                peRead := f.RawRead(peBuf, 4)
            }
        }
        f.Close()

        ; Validate DOS header
        if (dosRead < 64)
            return false
        if (NumGet(buf, 0, "UChar") != PE_MZ_MAGIC_1 || NumGet(buf, 1, "UChar") != PE_MZ_MAGIC_2)
            return false
        if (e_lfanew < 64 || e_lfanew > 1024)
            return false

        ; Validate PE signature: 'P' 'E' 0x00 0x00
        if (peRead < 4)
            return false
        return (NumGet(peBuf, 0, "UChar") = PE_SIG_1
            && NumGet(peBuf, 1, "UChar") = PE_SIG_2
            && NumGet(peBuf, 2, "UChar") = 0
            && NumGet(peBuf, 3, "UChar") = 0)
    } catch {
        return false
    }
}

; Read and consume a state file (source<|>target format).
; Deletes the file after reading. Throws on missing/invalid file or missing source.
; Returns {source, target} object. Callers handle their own post-validation.
ReadStateFile(filePath) {
    global UPDATE_INFO_DELIMITER
    if (!FileExist(filePath))
        throw Error("State file not found: " filePath)
    content := FileRead(filePath, "UTF-8")
    FileDelete(filePath)
    parts := StrSplit(content, UPDATE_INFO_DELIMITER)
    if (parts.Length != 2)
        throw Error("Invalid state file: expected 2 parts, got " parts.Length)
    if (!FileExist(parts[1]))
        throw Error("Source file not found: " parts[1])
    return {source: parts[1], target: parts[2]}
}

; Write a state file in source<|>target format (companion to ReadStateFile).
WriteStateFile(filePath, sourcePath, targetPath) {
    global UPDATE_INFO_DELIMITER
    try FileDelete(filePath)
    FileAppend(sourcePath UPDATE_INFO_DELIMITER targetPath, filePath, "UTF-8")
}

; Called when launched with --apply-update flag (elevated)
Update_ContinueFromElevation() {
    global APP_NAME, TEMP_UPDATE_STATE

    if (!FileExist(TEMP_UPDATE_STATE))
        return false

    try {
        state := ReadStateFile(TEMP_UPDATE_STATE)
        newExePath := state.source
        targetExePath := state.target

        ; Validate source path is in TEMP directory (expected from download)
        ; Use proper path prefix check, not substring (prevents edge cases like C:\MyTempBackup\...)
        tempWithSep := RTrim(A_Temp, "\") "\"
        if (SubStr(newExePath, 1, StrLen(tempWithSep)) != tempWithSep) {
            ThemeMsgBox("Invalid update source path (not in temp):`n" newExePath, APP_NAME, "Iconx")
            try FileDelete(newExePath)  ; Clean up orphaned temp exe
            return false
        }

        ; Validate target is the same exe we're running from.
        ; For --apply-update, the elevated instance IS the same exe, so A_ScriptFullPath
        ; matches the original target. Path equality is both more secure (exact match)
        ; and more permissive (works with any exe name, not just ones containing "tabby").
        if (!PathsEqual(targetExePath, A_ScriptFullPath)) {
            ThemeMsgBox("Update target doesn't match running executable.`n"
                "Target: " targetExePath "`n"
                "Running: " A_ScriptFullPath, APP_NAME, "Icon!")
            try FileDelete(newExePath)  ; Clean up orphaned temp exe
            return false
        }

        _Update_ApplyAndRelaunch(newExePath, targetExePath)
        return true  ; Won't reach here if successful (ExitApp called)
    } catch {
        return false
    }
}
