#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Cross-file globals (cfg) come from alt_tabby.ahk

; ============================================================
; Launcher Shortcuts - Start Menu, Startup, Admin-Aware
; ============================================================
; Creates and manages shortcuts with proper admin mode handling.
; Shortcuts always point to the exe; exe self-redirects to task if needed.

; Toggle Start Menu shortcut
ToggleStartMenuShortcut() {
    global g_CachedStartMenuShortcut
    _ToggleShortcut(_Shortcut_GetStartMenuPath(), "Start Menu")
    g_CachedStartMenuShortcut := _Shortcut_StartMenuExists()
}

; Toggle Startup shortcut
ToggleStartupShortcut() {
    global g_CachedStartupShortcut
    _ToggleShortcut(_Shortcut_GetStartupPath(), "Startup")
    g_CachedStartupShortcut := _Shortcut_StartupExists()
}

_ToggleShortcut(lnkPath, locationName) {
    global cfg, TOOLTIP_DURATION_SHORT, APP_NAME
    if (_Shortcut_ExistsAndPointsToUs(lnkPath)) {
        ; Our shortcut exists - remove it
        try {
            FileDelete(lnkPath)
            ToolTip("Removed from " locationName)
        } catch as e {
            ThemeMsgBox("Failed to remove shortcut:`n" e.Message, APP_NAME, "Iconx")
        }
    } else {
        ; Warn if shortcut will point to a temporary/cloud location
        exePath := _Shortcut_GetEffectiveExePath()
        if (WarnTemporaryLocation(exePath, "shortcut", "will point to", "the shortcut will break", "Create shortcut anyway?") = "No")
            return
        ; No shortcut or points elsewhere - create (handles conflict dialog internally)
        if (_CreateShortcutForCurrentMode(lnkPath)) {
            ToolTip("Added to " locationName)
        }
    }
    _Dash_StartRefreshTimer()
    HideTooltipAfter(TOOLTIP_DURATION_SHORT)
}

; Create a shortcut that always points to the exe
; The exe will self-redirect to the scheduled task if admin mode is enabled
_CreateShortcutForCurrentMode(lnkPath) {
    global cfg, APP_NAME

    exePath := _Shortcut_GetEffectiveExePath()
    iconPath := _Shortcut_GetIconPath()

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
        ThemeMsgBox("Failed to create shortcut:`n" e.Message, APP_NAME, "Iconx")
        return false
    }
}

; Recreate existing shortcuts when admin mode changes or exe is renamed/repaired.
; Uses FileExist() instead of _Shortcut_*Exists() because after an exe rename,
; shortcuts point to the old name (target doesn't match), but they still need updating.
; The shortcut filename is always "Alt-Tabby.lnk" — if it exists, it's ours.
RecreateShortcuts() {
    startMenuPath := _Shortcut_GetStartMenuPath()
    if (FileExist(startMenuPath)) {
        try FileDelete(startMenuPath)
        _CreateShortcutForCurrentMode(startMenuPath)
    }

    startupPath := _Shortcut_GetStartupPath()
    if (FileExist(startupPath)) {
        try FileDelete(startupPath)
        _CreateShortcutForCurrentMode(startupPath)
    }
}
