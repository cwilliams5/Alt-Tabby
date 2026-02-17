#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Cross-file globals (cfg) come from alt_tabby.ahk

; ============================================================
; Launcher Shortcuts - Start Menu, Startup, Admin-Aware
; ============================================================
; Creates and manages shortcuts with proper admin mode handling.
; Shortcuts always point to the exe; exe self-redirects to task if needed.

; Cached shortcut existence checks — populated at startup, updated after toggle operations.
global g_CachedStartMenuShortcut := false
global g_CachedStartupShortcut := false

; Refresh both shortcut caches (called from launcher_tray and after toggle operations)
Shortcut_RefreshCaches() {
    global g_CachedStartMenuShortcut, g_CachedStartupShortcut
    g_CachedStartMenuShortcut := Shortcut_StartMenuExists()
    g_CachedStartupShortcut := Shortcut_StartupExists()
}

; Toggle Start Menu shortcut
ToggleStartMenuShortcut() {
    global g_CachedStartMenuShortcut
    _ToggleShortcut(Shortcut_GetStartMenuPath(), "Start Menu")
    g_CachedStartMenuShortcut := Shortcut_StartMenuExists()
}

; Toggle Startup shortcut
ToggleStartupShortcut() {
    global g_CachedStartupShortcut
    _ToggleShortcut(Shortcut_GetStartupPath(), "Startup")
    g_CachedStartupShortcut := Shortcut_StartupExists()
}

_ToggleShortcut(lnkPath, locationName) {
    global cfg, TOOLTIP_DURATION_SHORT, APP_NAME
    if (Shortcut_ExistsAndPointsToUs(lnkPath)) {
        ; Our shortcut exists - remove it
        try {
            FileDelete(lnkPath)
            ToolTip("Removed from " locationName)
        } catch as e {
            ThemeMsgBox("Could not remove the shortcut. The file may be in use or the location protected.`n`nDetails: " e.Message, APP_NAME, "Iconx")
        }
    } else {
        ; Warn if shortcut will point to a temporary/cloud location
        exePath := Shortcut_GetEffectiveExePath()
        if (WarnTemporaryLocation(exePath, "shortcut", "will point to", "the shortcut will break", "Create shortcut anyway?") = "No")
            return
        ; No shortcut or points elsewhere - create (handles conflict dialog internally)
        if (CreateShortcutForCurrentMode(lnkPath)) {
            ToolTip("Added to " locationName)
        }
    }
    Dash_Refresh()
    HideTooltipAfter(TOOLTIP_DURATION_SHORT)
}

; Create a shortcut that always points to the exe
; The exe will self-redirect to the scheduled task if admin mode is enabled
CreateShortcutForCurrentMode(lnkPath) {
    global cfg, APP_NAME

    exePath := Shortcut_GetEffectiveExePath()
    iconPath := Shortcut_GetIconPath()

    ; Check for conflicting shortcut from different installation
    if (FileExist(lnkPath)) {
        try {
            shell := ComObject("WScript.Shell")
            existing := shell.CreateShortcut(lnkPath)
            existingTarget := existing.TargetPath

            ; Get target to compare (in dev mode, compare scripts; in compiled, compare exes)
            ourTarget := A_IsCompiled ? exePath : A_AhkPath

            ; If shortcut points to a different location, warn user
            if (!PathsEqual(existingTarget, ourTarget)) {
                result := ThemeMsgBox(
                    "A shortcut 'Alt-Tabby' already exists pointing to:`n" existingTarget "`n`n"
                    "Replace it with a shortcut to this installation?`n" ourTarget,
                    APP_NAME " - Shortcut Conflict",
                    "YesNo Icon?"
                )
                if (result = "No")
                    return false
                ; User chose Yes - continue to overwrite
            }
        }
        ; If we can't read existing shortcut, proceed with overwrite
    }

    try {
        shell := ComObject("WScript.Shell")
        shortcut := shell.CreateShortcut(lnkPath)

        ; Always point to our exe - it will self-redirect to scheduled task if needed
        if (A_IsCompiled) {
            shortcut.TargetPath := exePath
            ; Only show "(Admin)" if task actually exists (not just config says so)
            shortcut.Description := IsAdminModeFullyActive()
                ? "Alt-Tabby Window Switcher (Admin)"
                : "Alt-Tabby Window Switcher"
        } else {
            ; Dev mode: AutoHotkey.exe with script as argument
            shortcut.TargetPath := A_AhkPath
            shortcut.Arguments := '"' A_ScriptFullPath '"'
            shortcut.Description := "Alt-Tabby Window Switcher (Dev)"
        }

        ; Set working directory
        SplitPath(exePath, , &workDir)
        shortcut.WorkingDirectory := workDir

        ; Set icon
        if (iconPath && FileExist(iconPath))
            shortcut.IconLocation := iconPath

        shortcut.Save()
        return true
    } catch as e {
        ThemeMsgBox("Could not create the shortcut. The file may be locked or the location protected.`n`nDetails: " e.Message, APP_NAME, "Iconx")
        return false
    }
}

; Recreate existing shortcuts when admin mode changes or exe is renamed/repaired.
; Uses FileExist() instead of _Shortcut_*Exists() because after an exe rename,
; shortcuts point to the old name (target doesn't match), but they still need updating.
; The shortcut filename is always "Alt-Tabby.lnk" — if it exists, it's ours.
RecreateShortcuts() {
    startMenuPath := Shortcut_GetStartMenuPath()
    if (FileExist(startMenuPath)) {
        try FileDelete(startMenuPath)
        CreateShortcutForCurrentMode(startMenuPath)
    }

    startupPath := Shortcut_GetStartupPath()
    if (FileExist(startupPath)) {
        try FileDelete(startupPath)
        CreateShortcutForCurrentMode(startupPath)
    }
}
