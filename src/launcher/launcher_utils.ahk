#Requires AutoHotkey v2.0

; ============================================================
; Launcher Utilities - Subprocess Management Helpers
; ============================================================
; Provides common subprocess launch and restart patterns used
; by launcher_main.ahk and launcher_tray.ahk.
; ============================================================

; Launch a subprocess, handling compiled vs development mode
; Parameters:
;   component - "store", "gui", or "viewer"
;   pidVar    - Reference to PID variable (will be set to new PID)
;   logFunc   - Optional log function(msg) for diagnostics
; Returns: true if launched, false on failure
LauncherUtils_Launch(component, &pidVar, logFunc := "") {
    ; Build command based on compiled status and component
    if (A_IsCompiled) {
        switch component {
            case "store":
                cmd := '"' A_ScriptFullPath '" --store'
            case "gui":
                cmd := '"' A_ScriptFullPath '" --gui-only'
            case "viewer":
                cmd := '"' A_ScriptFullPath '" --viewer'
            default:
                return false
        }
    } else {
        ; Development mode - use appropriate script file
        switch component {
            case "store":
                cmd := '"' A_AhkPath '" "' A_ScriptDir '\store\store_server.ahk"'
            case "gui":
                cmd := '"' A_AhkPath '" "' A_ScriptDir '\gui\gui_main.ahk"'
            case "viewer":
                cmd := '"' A_AhkPath '" "' A_ScriptDir '\viewer\viewer.ahk"'
            default:
                return false
        }
        ; In testing mode, pass --test to child processes so they hide tray icons
        global g_TestingMode
        if (g_TestingMode)
            cmd .= " --test"
    }

    ; Log if function provided
    if (logFunc != "")
        logFunc("LAUNCH: starting " component " process")

    ; Run and capture PID
    try {
        Run(cmd, , , &pidVar)
        if (logFunc != "")
            logFunc("LAUNCH: " component " PID=" pidVar)
        return true
    } catch as e {
        if (logFunc != "")
            logFunc("LAUNCH: " component " FAILED - " e.Message)
        pidVar := 0
        return false
    }
}

; Restart a subprocess (kill if running, then launch)
; Parameters:
;   component  - "store", "gui", or "viewer"
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
