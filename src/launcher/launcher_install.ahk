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

; ============================================================
; INSTALL MISMATCH DETECTION
; ============================================================

; Check if we're running from a different location than the installed version
; Offers to update or launch the installed version
; Sets g_MismatchDialogShown if a dialog was displayed (to prevent race with auto-update)
_Launcher_CheckInstallMismatch() {
    global cfg, g_MismatchDialogShown, g_SkipMismatchCheck, APP_NAME

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
        result := _Launcher_ShowMismatchDialog(installedPath,
            APP_NAME " - Newer Version Running",
            "You're running a newer version (" currentVersion " vs " installedVersion ").`nInstalled at:",
            "Update the installed version?")

        if (result = "Yes") {
            _Launcher_UpdateInstalledVersion(installedPath)
            ; If we return, update failed - continue running from current location
        } else {
            ; "No" or "Always" - delegate to common handler
            _Launcher_HandleMismatchResult(result, installedPath, currentPath)
        }
    } else if (versionCompare = 0) {
        ; Current version is SAME as installed - clearer message about duplicate installations
        result := _Launcher_ShowMismatchDialog(installedPath,
            APP_NAME " - Same Version Running",
            "Alt-Tabby " currentVersion " is also installed at:",
            "You have the same version in two locations. Launch from the installed location instead?")

        ; Handle dialog result (same logic for same-version and older-version cases)
        _Launcher_HandleMismatchResult(result, installedPath, currentPath)
    } else {
        ; Current version is OLDER than installed
        ; Use custom 3-button dialog: Yes (launch installed) / No (run from here once) / Always (run from here always)
        result := _Launcher_ShowMismatchDialog(installedPath,
            APP_NAME " - Newer Version Installed",
            "A newer version (" installedVersion ") is installed at:",
            "Launch the newer installed version instead?")

        ; Handle dialog result
        _Launcher_HandleMismatchResult(result, installedPath, currentPath)
    }
}

; Common handler for mismatch dialog results
_Launcher_HandleMismatchResult(result, installedPath, currentPath) {
    global cfg, gConfigIniPath, g_MismatchDialogShown, APP_NAME

    if (result = "Yes") {
        ; Launch installed version and exit
        try {
            Run('"' installedPath '"')
            ExitApp()
        } catch as e {
            ThemeMsgBox("Could not launch installed version:`n" e.Message, APP_NAME, "Iconx")
        }
    } else if (result = "Always") {
        ; Warn if committing to a temporary location
        currentDir := ""
        SplitPath(currentPath, , &currentDir)
        if (IsTemporaryLocation(currentDir)) {
            warnResult := ThemeMsgBox(
                "You're choosing to always run from:`n" currentPath "`n`n"
                "This location may be temporary or cloud-synced.`n"
                "If you delete or move this file, Alt-Tabby won't start.`n`n"
                "Always run from here anyway?",
                APP_NAME " - Temporary Location",
                "YesNo Icon?"
            )
            if (warnResult = "No") {
                ; Treat as one-time "No" instead
                _Launcher_OfferToStopInstalledInstance(installedPath)
                _Launcher_OfferOneTimeElevation()
                return
            }
        }

        ; Update SetupExePath to current location - never ask again
        cfg.SetupExePath := currentPath
        try _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "ExePath", currentPath, "", "string")
        g_MismatchDialogShown := false  ; Allow auto-update now that mismatch is resolved

        ; Check if installed version is currently running to prevent multiple instances
        _Launcher_OfferToStopInstalledInstance(installedPath)

        ; Clean up stale admin task pointing to old location (Bug 3 fix)
        _Launcher_CleanupStaleAdminTask(installedPath, currentPath)

        ; Check for stale shortcuts that still point to the old installed path
        _Launcher_OfferToUpdateStaleShortcuts()
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
    global TIMING_MUTEX_RELEASE_WAIT, APP_NAME

    ; Get the exe name from the installed path
    installedExeName := ""
    SplitPath(installedPath, &installedExeName)

    if (installedExeName = "")
        return

    ; Check if any process with that name is running (other than us)
    if (!_Launcher_IsOtherProcessRunning(installedExeName))
        return  ; Not running or only us

    result := ThemeMsgBox(
        "The installed version is currently running.`n`n"
        "Close it to avoid conflicts? (Recommended)",
        APP_NAME " - Instance Running",
        "YesNo Icon?"
    )

    if (result = "Yes") {
        ; Kill ALL processes matching the installed exe name (launcher + store + gui).
        ; Uses specific exe name (not BuildExeNameList) because installed exe may have
        ; different name than current (e.g., "AltTabby.exe" vs "alttabby v4.exe").
        ProcessUtils_KillByNameExceptSelf(installedExeName, 10, TIMING_MUTEX_RELEASE_WAIT, true)
    }
}

; Custom 3-button dialog for mismatch: Yes / No / Always run from here
; Returns: "Yes", "No", or "Always"
; Optional params allow customization for same-version vs older-version scenarios
_Launcher_ShowMismatchDialog(installedPath, title := "", message := "", question := "") {
    global cfg, APP_NAME

    if (title = "")
        title := APP_NAME " - Already Installed"
    if (message = "")
        message := "Alt-Tabby is already installed at:"
    if (question = "")
        question := "Launch the installed version instead?"

    mismatchGui := Gui("+AlwaysOnTop +Owner", title)
    _GUI_AntiFlashPrepare(mismatchGui, Theme_GetBgColor(), true)
    mismatchGui.MarginX := 24
    mismatchGui.MarginY := 16
    mismatchGui.SetFont("s10", "Segoe UI")
    themeEntry := Theme_ApplyToGui(mismatchGui)

    contentW := 440

    ; Header in accent
    hdr := mismatchGui.AddText("w" contentW " c" Theme_GetAccentColor(), message)
    Theme_MarkAccent(hdr)

    ; Path in muted color
    mutedPath := mismatchGui.AddText("w" contentW " y+8 c" Theme_GetMutedColor(), installedPath)
    Theme_MarkMuted(mutedPath)

    ; Question
    mismatchGui.AddText("w" contentW " y+16", question)

    result := ""  ; Will be set by button clicks

    ; Buttons: [Yes] [Always run from here] ... gap ... [No]
    btnW := 100
    btnYes := mismatchGui.AddButton("x24 w" btnW " y+24 Default", "Yes")
    btnAlways := mismatchGui.AddButton("x+8 w160", "Always run from here")
    btnNo := mismatchGui.AddButton("x" (24 + contentW - btnW) " yp w" btnW, "No")

    Theme_ApplyToControl(btnYes, "Button", themeEntry)
    Theme_ApplyToControl(btnAlways, "Button", themeEntry)
    Theme_ApplyToControl(btnNo, "Button", themeEntry)

    btnYes.OnEvent("Click", (*) => (result := "Yes", Theme_UntrackGui(mismatchGui), mismatchGui.Destroy()))
    btnNo.OnEvent("Click", (*) => (result := "No", Theme_UntrackGui(mismatchGui), mismatchGui.Destroy()))
    btnAlways.OnEvent("Click", (*) => (result := "Always", Theme_UntrackGui(mismatchGui), mismatchGui.Destroy()))
    mismatchGui.OnEvent("Close", (*) => (result := "No", Theme_UntrackGui(mismatchGui), mismatchGui.Destroy()))

    mismatchGui.Show("w488 Center")
    _GUI_AntiFlashReveal(mismatchGui, true)
    WinWaitClose(mismatchGui)

    return result
}

; Update the installed version with the current exe
_Launcher_UpdateInstalledVersion(installedPath) {
    global cfg, gConfigIniPath, APP_NAME

    installedDir := ""
    SplitPath(installedPath, , &installedDir)

    ; Check if we need elevation
    if (_Update_NeedsElevation(installedDir)) {
        ; Save update info and self-elevate
        global UPDATE_INFO_DELIMITER
        updateInfo := A_ScriptFullPath UPDATE_INFO_DELIMITER installedPath
        updateFile := A_Temp "\alttabby_install_update.txt"
        try FileDelete(updateFile)
        FileAppend(updateInfo, updateFile, "UTF-8")

        try {
            if (!_Launcher_RunAsAdmin("--update-installed"))
                throw Error("RunAsAdmin failed")
            ExitApp()
        } catch {
            ThemeMsgBox("Update requires administrator privileges.", APP_NAME, "Iconx")
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
    global cfg, g_StorePID, g_GuiPID, g_ViewerPID
    _Update_ApplyCore({
        sourcePath: sourcePath,
        targetPath: targetPath,
        useLockFile: false,
        validatePE: false,             ; Source is running exe, already valid
        copyMode: true,                ; FileCopy (keep source - it's the running exe)
        successMessage: "Alt-Tabby has been updated at:`n" targetPath,
        cleanupSourceOnFailure: false, ; Don't delete source - it's the running exe
        overwriteUserData: cfg.SetupFirstRunCompleted,  ; Only push config if source was configured (prevents fresh download from overwriting target's customizations)
        killPids: {gui: g_GuiPID, store: g_StorePID, viewer: g_ViewerPID}
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
    global APP_NAME
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
    result := ThemeMsgBox(
        "The installed version runs as Administrator.`n`n"
        "Run this version elevated too?`n"
        "(This is one-time and won't affect the installed version)",
        APP_NAME " - Run Elevated?",
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

; ============================================================
; STALE SHORTCUT DETECTION
; ============================================================
; After "Always run from here", check if startup/Start Menu shortcuts
; still point to the old installed path. Offer to update them so the
; user doesn't end up launching the wrong version on next boot.

_Launcher_OfferToUpdateStaleShortcuts() {
    global APP_NAME

    ; Only relevant for compiled exe
    if (!A_IsCompiled)
        return

    ; Check if any shortcuts exist but DON'T point to us
    startupPath := _Shortcut_GetStartupPath()
    startMenuPath := _Shortcut_GetStartMenuPath()

    startupStale := FileExist(startupPath) && !_Shortcut_ExistsAndPointsToUs(startupPath)
    startMenuStale := FileExist(startMenuPath) && !_Shortcut_ExistsAndPointsToUs(startMenuPath)

    if (!startupStale && !startMenuStale)
        return

    ; Build description of which shortcuts are stale
    staleList := ""
    if (startupStale)
        staleList .= "- Startup shortcut`n"
    if (startMenuStale)
        staleList .= "- Start Menu shortcut`n"

    result := ThemeMsgBox(
        "The following shortcuts point to a different location:`n`n"
        staleList "`n"
        "Update them to point to this version?`n"
        "(Otherwise they'll keep launching the old version)",
        APP_NAME " - Update Shortcuts?",
        "YesNo Icon?"
    )

    if (result = "Yes") {
        RecreateShortcuts()
    }
}

; Check if running from the Program Files install directory
_IsInProgramFiles() {
    global ALTTABBY_INSTALL_DIR
    return StrLower(A_ScriptDir) = StrLower(ALTTABBY_INSTALL_DIR)
}

; Clean up stale admin task pointing to old location when user chooses "Always run from here"
; Offers to disable admin mode for the old installation to prevent confusing repair dialogs
_Launcher_CleanupStaleAdminTask(oldPath, newPath) {
    global cfg, gConfigIniPath, APP_NAME

    ; Check if admin task exists and points to the old location
    if (!AdminTaskExists())
        return

    taskPath := _AdminTask_GetCommandPath()
    if (taskPath = "")
        return

    ; If task already points to us, nothing to do
    if (StrLower(taskPath) = StrLower(newPath))
        return

    ; Task points to old location - ask user what to do
    result := ThemeMsgBox(
        "The installed version has Admin Mode enabled:`n" taskPath "`n`n"
        "Disable Admin Mode for that location?`n"
        "(Otherwise you may see confusing repair prompts later)",
        APP_NAME " - Admin Mode Conflict",
        "YesNo Icon?"
    )

    if (result = "Yes") {
        if (A_IsAdmin) {
            ; We have admin - delete task directly
            DeleteAdminTask()
            cfg.SetupRunAsAdmin := false
            try _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "RunAsAdmin", false, false, "bool")
        } else {
            ; Need elevation to delete task
            try {
                if (_Launcher_RunAsAdmin("--disable-admin-task")) {
                    ; Elevated instance will handle it, update local config
                    cfg.SetupRunAsAdmin := false
                    try _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "RunAsAdmin", false, false, "bool")
                }
            } catch {
                ; UAC refused - warn user
                TrayTip("Admin Mode", "Could not disable Admin Mode.`nYou may see repair prompts later.", "Icon!")
            }
        }
    }
}
