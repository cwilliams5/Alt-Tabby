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
    global cfg, ALTTABBY_INSTALL_DIR

    ; Target: Program Files\Alt-Tabby (localized for non-English Windows)
    installDir := ALTTABBY_INSTALL_DIR
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
    global cfg, g_MismatchDialogShown, g_SkipMismatchCheck

    ; Skip if flag set (after one-time elevation from mismatch prompt)
    if (g_SkipMismatchCheck)
        return

    ; Only relevant for compiled exe
    if (!A_IsCompiled)
        return

    ; First, check config for SetupExePath
    installedPath := ""
    if (cfg.HasOwnProp("SetupExePath") && cfg.SetupExePath != "")
        installedPath := cfg.SetupExePath

    ; Also check well-known install location (handles fresh config case)
    ; This ensures we detect existing PF installs even with empty/fresh config
    global ALTTABBY_INSTALL_DIR
    pfPath := ALTTABBY_INSTALL_DIR "\AltTabby.exe"
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
    } else if (versionCompare = 0) {
        ; Current version is SAME as installed - clearer message about duplicate installations
        result := _Launcher_ShowMismatchDialog(installedPath,
            "Alt-Tabby - Same Version Running",
            "Alt-Tabby " currentVersion " is also installed at:",
            "You have the same version in two locations. Launch from the installed location instead?")

        ; Handle dialog result (same logic for same-version and older-version cases)
        _Launcher_HandleMismatchResult(result, installedPath, currentPath)
    } else {
        ; Current version is OLDER than installed
        ; Use custom 3-button dialog: Yes (launch installed) / No (run from here once) / Always (run from here always)
        result := _Launcher_ShowMismatchDialog(installedPath,
            "Alt-Tabby - Newer Version Installed",
            "A newer version (" installedVersion ") is installed at:",
            "Launch the newer installed version instead?")

        ; Handle dialog result
        _Launcher_HandleMismatchResult(result, installedPath, currentPath)
    }
}

; Common handler for mismatch dialog results
_Launcher_HandleMismatchResult(result, installedPath, currentPath) {
    global cfg, gConfigIniPath, g_MismatchDialogShown

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

        ; Check if installed version is currently running to prevent multiple instances
        _Launcher_OfferToStopInstalledInstance(installedPath)
        ; Continue running from current location
    } else {
        ; "No" - continue running from current location (one-time)
        ; Check if installed version is currently running to prevent multiple instances
        _Launcher_OfferToStopInstalledInstance(installedPath)

        ; Offer elevation if installed version has admin task but we're not elevated.
        ; This handles dev testing scenario: user wants to test THIS build with admin
        ; without affecting the installed version's task scheduler setup.
        _Launcher_OfferOneTimeElevation()
    }
}

; Check if installed version is running and offer to stop it to prevent multiple instances
; This handles the case where different InstallationIds bypass the mutex check
_Launcher_OfferToStopInstalledInstance(installedPath) {
    global TIMING_MUTEX_RELEASE_WAIT

    ; Get the exe name from the installed path
    installedExeName := ""
    SplitPath(installedPath, &installedExeName)

    if (installedExeName = "")
        return

    ; Check if any process with that name is running (other than us)
    myPID := ProcessExist()
    pid := ProcessExist(installedExeName)

    if (!pid || pid = myPID)
        return  ; Not running or only us

    result := MsgBox(
        "The installed version is currently running.`n`n"
        "Close it to avoid conflicts? (Recommended)",
        "Alt-Tabby - Instance Running",
        "YesNo Icon?"
    )

    if (result = "Yes") {
        _Launcher_KillExistingInstances()
        Sleep(TIMING_MUTEX_RELEASE_WAIT)
    }
}

; Custom 3-button dialog for mismatch: Yes / No / Always run from here
; Returns: "Yes", "No", or "Always"
; Optional params allow customization for same-version vs older-version scenarios
_Launcher_ShowMismatchDialog(installedPath, title := "", message := "", question := "") {
    global cfg

    if (title = "")
        title := "Alt-Tabby - Already Installed"
    if (message = "")
        message := "Alt-Tabby is already installed at:"
    if (question = "")
        question := "Launch the installed version instead?"

    mismatchGui := Gui("+AlwaysOnTop +Owner", title)
    mismatchGui.SetFont("s10", "Segoe UI")

    mismatchGui.AddText("w380", message)
    mismatchGui.AddText("w380 cGray", installedPath)
    mismatchGui.AddText("w380 y+15", question)

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
            if (!_Launcher_RunAsAdmin("--update-installed"))
                throw Error("RunAsAdmin failed")
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
; Wrapper for mismatch update flow - uses _Update_ApplyCore with appropriate options
_Launcher_DoUpdateInstalled(sourcePath, targetPath) {
    _Update_ApplyCore({
        sourcePath: sourcePath,
        targetPath: targetPath,
        useLockFile: false,
        validatePE: false,             ; Source is running exe, already valid
        copyMode: true,                ; FileCopy (keep source - it's the running exe)
        ensureTargetConfig: true,      ; Copy config if missing at target
        successMessage: "Alt-Tabby has been updated at:`n" targetPath,
        cleanupSourceOnFailure: false  ; Don't delete source - it's the running exe
    })
}

; ============================================================
; ONE-TIME ELEVATION OFFER
; ============================================================
; Offered after user dismisses mismatch dialog with "No" (run from here).
; Only shows if: admin task exists (installed version runs elevated) AND we're not admin.
; This handles dev testing scenario without affecting normal user flow.
; Normal users typically don't have admin mode enabled, so they won't see this.

_Launcher_OfferOneTimeElevation() {
    ; Already elevated - nothing to offer
    if (A_IsAdmin)
        return

    ; Only relevant for compiled exe
    if (!A_IsCompiled)
        return

    ; Only offer if installed version has admin task
    ; (This means the user explicitly set up admin mode before)
    if (!AdminTaskExists())
        return

    ; Offer one-time elevation for THIS session
    result := MsgBox(
        "The installed version runs as Administrator.`n`n"
        "Run this version elevated too?`n"
        "(This is one-time and won't affect the installed version)",
        "Alt-Tabby - Run Elevated?",
        "YesNo Icon?"
    )

    if (result = "Yes") {
        try {
            ; Pass --skip-mismatch to avoid showing mismatch dialog again after restart
            Run('*RunAs "' A_ScriptFullPath '" --skip-mismatch')
            ExitApp()
        } catch {
            ; UAC refused - continue without elevation
        }
    }
    ; "No" - continue without elevation
}
