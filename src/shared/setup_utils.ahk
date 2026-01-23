#Requires AutoHotkey v2.0

; ============================================================
; Setup Utilities - Version, Task Scheduler, Shortcuts
; ============================================================
; Shared functions for first-run wizard, admin mode, and updates.
; Included by alt_tabby.ahk and tests.

; Version constant for development mode (compiled mode reads from exe metadata)
global APP_VERSION := "0.4.0"

; ============================================================
; VERSION MANAGEMENT
; ============================================================

; Get the application version
; In compiled mode, reads from exe file version info
; In dev mode, returns APP_VERSION constant
GetAppVersion() {
    global APP_VERSION
    if (A_IsCompiled) {
        try {
            return FileGetVersion(A_ScriptFullPath)
        } catch {
            return APP_VERSION
        }
    }
    return APP_VERSION
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
    xml .= '<Hidden>false</Hidden>'
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

; Get the icon path
_Shortcut_GetIconPath() {
    if (A_IsCompiled)
        return A_ScriptDir "\img\icon.ico"
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
; UPDATE CHECKING
; ============================================================

CheckForUpdates(showIfCurrent := false) {
    currentVersion := GetAppVersion()
    apiUrl := "https://api.github.com/repos/cwilliams5/Alt-Tabby/releases/latest"

    try {
        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.Open("GET", apiUrl, false)
        whr.SetRequestHeader("User-Agent", "Alt-Tabby/" currentVersion)
        whr.Send()

        if (whr.Status = 200) {
            response := whr.ResponseText
            ; Parse JSON for "tag_name" - GitHub tags are like "v0.4.0"
            if (RegExMatch(response, '"tag_name"\s*:\s*"v?([^"]+)"', &match)) {
                latestVersion := match[1]
                if (CompareVersions(latestVersion, currentVersion) > 0) {
                    ; Newer version available
                    TrayTip("Update Available", "Alt-Tabby " latestVersion " is available!`nCurrent: " currentVersion "`n`nVisit the tray menu to download.", "Info")
                } else if (showIfCurrent) {
                    TrayTip("Up to Date", "You're running the latest version (" currentVersion ")", "Info")
                }
            }
        } else if (showIfCurrent) {
            TrayTip("Update Check Failed", "HTTP Status: " whr.Status, "Warning")
        }
    } catch as e {
        if (showIfCurrent)
            TrayTip("Update Check Failed", "Could not check for updates:`n" e.Message, "Warning")
    }
}
