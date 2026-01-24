#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Cross-file globals (cfg) come from alt_tabby.ahk

; ============================================================
; Launcher Shortcuts - Start Menu, Startup, Admin-Aware
; ============================================================
; Creates and manages shortcuts with proper admin mode handling.
; Shortcuts always point to the exe; exe self-redirects to task if needed.

; Create a shortcut file using WScript.Shell COM
_Shortcut_Create(lnkPath, targetPath, iconPath := "", description := "") {
    try {
        ; Get parent directory using SplitPath
        SplitPath(targetPath, , &targetDir)

        shell := ComObject("WScript.Shell")
        shortcut := shell.CreateShortcut(lnkPath)
        shortcut.TargetPath := targetPath
        shortcut.WorkingDirectory := targetDir
        if (iconPath && FileExist(iconPath))
            shortcut.IconLocation := iconPath
        if (description)
            shortcut.Description := description
        shortcut.Save()
        return true
    } catch as e {
        MsgBox("Failed to create shortcut:`n" e.Message, "Alt-Tabby", "Icon!")
        return false
    }
}

; Toggle Start Menu shortcut
ToggleStartMenuShortcut() {
    global cfg
    lnkPath := _Shortcut_GetStartMenuPath()
    if (FileExist(lnkPath)) {
        try {
            FileDelete(lnkPath)
            ToolTip("Removed from Start Menu")
        } catch as e {
            MsgBox("Failed to remove shortcut:`n" e.Message, "Alt-Tabby", "Icon!")
        }
    } else {
        ; Use admin-aware shortcut creation
        if (_CreateShortcutForCurrentMode(lnkPath)) {
            ToolTip("Added to Start Menu")
        }
    }
    HideTooltipAfter(TOOLTIP_DURATION_SHORT)
}

; Toggle Startup shortcut
ToggleStartupShortcut() {
    global cfg
    lnkPath := _Shortcut_GetStartupPath()
    if (FileExist(lnkPath)) {
        try {
            FileDelete(lnkPath)
            ToolTip("Removed from Startup")
        } catch as e {
            MsgBox("Failed to remove shortcut:`n" e.Message, "Alt-Tabby", "Icon!")
        }
    } else {
        ; Use admin-aware shortcut creation
        if (_CreateShortcutForCurrentMode(lnkPath)) {
            ToolTip("Added to Startup")
        }
    }
    HideTooltipAfter(TOOLTIP_DURATION_SHORT)
}

; Create a shortcut that always points to the exe
; The exe will self-redirect to the scheduled task if admin mode is enabled
_CreateShortcutForCurrentMode(lnkPath) {
    global cfg

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
            if (StrLower(existingTarget) != StrLower(ourTarget)) {
                result := MsgBox(
                    "A shortcut 'Alt-Tabby' already exists pointing to:`n" existingTarget "`n`n"
                    "Replace it with a shortcut to this installation?`n" ourTarget,
                    "Alt-Tabby - Shortcut Conflict",
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
            shortcut.Description := (cfg.SetupRunAsAdmin && AdminTaskExists())
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
        MsgBox("Failed to create shortcut:`n" e.Message, "Alt-Tabby", "Icon!")
        return false
    }
}

; Recreate existing shortcuts when admin mode changes
RecreateShortcuts() {
    ; If Start Menu shortcut exists, recreate it
    if (_Shortcut_StartMenuExists()) {
        try FileDelete(_Shortcut_GetStartMenuPath())
        _CreateShortcutForCurrentMode(_Shortcut_GetStartMenuPath())
    }

    ; If Startup shortcut exists, recreate it
    if (_Shortcut_StartupExists()) {
        try FileDelete(_Shortcut_GetStartupPath())
        _CreateShortcutForCurrentMode(_Shortcut_GetStartupPath())
    }
}
