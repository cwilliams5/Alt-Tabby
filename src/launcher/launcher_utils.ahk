#Requires AutoHotkey v2.0

; ============================================================
; Launcher Utilities - Subprocess Management Helpers
; ============================================================
; Provides common subprocess launch and restart patterns used
; by launcher_main.ahk and launcher_tray.ahk.
; ============================================================

; Launch a subprocess, handling compiled vs development mode
; Parameters:
;   component - "gui" or "pump"
;   pidVar    - Reference to PID variable (will be set to new PID)
;   logFunc   - Optional log function(msg) for diagnostics
; Returns: true if launched, false on failure
LauncherUtils_Launch(component, &pidVar, logFunc := "") {
    global g_TestingMode
    ; Build command based on compiled status and component
    launcherArg := " --launcher-hwnd=" A_ScriptHwnd

    if (A_IsCompiled) {
        exe := '"' A_ScriptFullPath '" '
        switch component {
            case "gui":
                cmd := exe "--gui-only" launcherArg
                if (g_TestingMode)
                    cmd .= " --testing-mode"
            case "pump":   cmd := exe "--pump"
            default:       return false
        }
    } else {
        ; Development mode - use appropriate script file
        ahk := '"' A_AhkPath '" "'
        srcDir := A_ScriptDir "\"
        switch component {
            case "gui":    cmd := ahk srcDir 'gui\gui_main.ahk"' launcherArg
            case "pump":   cmd := ahk srcDir 'alt_tabby.ahk" --pump'
            default:       return false
        }
        ; In testing mode, pass --test to child processes so they hide tray icons
        if (g_TestingMode)
            cmd .= " --test"
    }

    ; Log if function provided
    if (logFunc != "")
        logFunc("LAUNCH: starting " component " process")

    ; Run and capture PID
    ; ProcessUtils_Run suppresses cursor feedback in test mode
    try {
        ProcessUtils_Run(cmd, &pidVar)
        if (pidVar) {
            if (logFunc != "")
                logFunc("LAUNCH: " component " PID=" pidVar)
            return true
        }
        if (logFunc != "")
            logFunc("LAUNCH: " component " FAILED - ProcessUtils_Run returned 0")
        return false
    } catch as e {
        if (logFunc != "")
            logFunc("LAUNCH: " component " FAILED - " e.Message)
        pidVar := 0
        return false
    }
}

; Restart a subprocess (kill if running, then launch)
; Parameters:
;   component  - "gui" or "pump"
;   pidVar     - Reference to PID variable
;   waitMs     - Milliseconds to wait between kill and launch (default 200)
;   logFunc    - Optional log function(msg) for diagnostics
; Returns: true if relaunched, false on failure
LauncherUtils_Restart(component, &pidVar, waitMs := 200, logFunc := "") {
    ; Kill existing process if running
    if (pidVar && ProcessExist(pidVar)) {
        if (logFunc != "")
            logFunc("RESTART: killing " component " PID=" pidVar)
        ProcessClose(pidVar)
    }
    pidVar := 0

    ; Wait for clean shutdown
    Sleep(waitMs)

    ; Launch new instance
    return LauncherUtils_Launch(component, &pidVar, logFunc)
}

; Check if a subprocess is running
; Parameters:
;   pid - Process ID to check
; Returns: true if running, false otherwise
LauncherUtils_IsRunning(pid) {
    return (pid && ProcessExist(pid))
}

; ============================================================
; GDI+ Thumbnail Loader (compiled mode only)
; ============================================================
; Loads an embedded resource image, resizes it with high-quality bicubic
; interpolation, and returns an HBITMAP suitable for Gui.AddPicture().
; Uses theme-aware background color for transparency compositing.
;
; Parameters:
;   resId - Resource ID (e.g., RES_ID_LOGO, RES_ID_ICON)
;   w, h  - Target dimensions
; Returns: HBITMAP handle, or 0 on failure. Caller owns the HBITMAP.
LauncherUtils_LoadGdipThumb(resId, w, h) {
    hModule := DllCall("LoadLibrary", "str", "gdiplus", "ptr")
    if (!hModule)
        return 0

    si := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
    NumPut("UInt", 1, si, 0)
    token := 0
    DllCall("gdiplus\GdiplusStartup", "ptr*", &token, "ptr", si.Ptr, "ptr", 0)
    if (!token) {
        DllCall("FreeLibrary", "ptr", hModule)
        return 0
    }

    pBitmap := Splash_LoadBitmapFromResource(resId)
    if (!pBitmap) {
        DllCall("gdiplus\GdiplusShutdown", "ptr", token)
        DllCall("FreeLibrary", "ptr", hModule)
        return 0
    }

    ; High-quality resize preserving aspect ratio
    pThumb := GdipResizeHQ(pBitmap, w, h)
    srcBitmap := pThumb ? pThumb : pBitmap

    ; Convert to HBITMAP with theme-aware background color
    global gTheme_Palette
    argbBg := 0xFF000000 | Integer("0x" gTheme_Palette.bg)

    hBitmap := 0
    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "ptr", srcBitmap, "ptr*", &hBitmap, "uint", argbBg)

    ; Cleanup GDI+ resources
    if (pThumb)
        DllCall("gdiplus\GdipDisposeImage", "ptr", pThumb)
    DllCall("gdiplus\GdipDisposeImage", "ptr", pBitmap)
    DllCall("gdiplus\GdiplusShutdown", "ptr", token)
    DllCall("FreeLibrary", "ptr", hModule)

    return hBitmap
}
