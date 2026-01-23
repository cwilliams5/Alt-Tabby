#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; g_TestingMode and other globals come from alt_tabby.ahk

; ============================================================
; Launcher Main - Core Init & Subprocess Management
; ============================================================
; Main entry point for launcher mode. Orchestrates startup:
; mutex, mismatch check, wizard, splash, subprocess launch.

; Launcher mutex global
global g_LauncherMutex := 0

; Main launcher initialization
; Called from alt_tabby.ahk when g_AltTabbyMode = "launch"
Launcher_Init() {
    global g_StorePID, g_GuiPID, g_MismatchDialogShown, g_TestingMode, cfg, gConfigIniPath

    ; Ensure InstallationId exists (generates on first run)
    _Launcher_EnsureInstallationId()

    ; Check if another launcher is already running (named mutex)
    ; Uses InstallationId so renamed exes in same install still share mutex
    ; MUST be before mismatch check to prevent race conditions
    if (!_Launcher_AcquireMutex()) {
        result := MsgBox(
            "Alt-Tabby is already running.`n`n"
            "Would you like to restart it?",
            "Alt-Tabby",
            "YesNo Icon?"
        )
        if (result = "Yes") {
            _Launcher_KillExistingInstances()
            Sleep(500)  ; Wait for mutex to be released
            if (!_Launcher_AcquireMutex()) {
                MsgBox("Could not restart Alt-Tabby. Please try again.", "Alt-Tabby", "Icon!")
                ExitApp()
            }
            ; Continue with normal startup below
        } else {
            ExitApp()
        }
    }

    ; Check if running from different location than installed version
    ; (e.g., user downloaded new version and ran from Downloads)
    ; May set g_MismatchDialogShown to prevent auto-update race
    ; Skip in testing mode to avoid blocking automated tests
    if (!g_TestingMode)
        _Launcher_CheckInstallMismatch()

    ; Clean up old exe from previous update
    _Update_CleanupOldExe()

    ; Check if we should redirect to scheduled task (admin mode)
    ; Skip task redirect if mismatch was detected - user chose to run from current location
    ; Showing task repair dialog after mismatch "No" would redirect to wrong version
    if (!g_MismatchDialogShown && _ShouldRedirectToScheduledTask()) {
        global ALTTABBY_TASK_NAME
        exitCode := RunWait('schtasks /run /tn "' ALTTABBY_TASK_NAME '"',, "Hide")

        if (exitCode = 0) {
            Sleep(100)  ; Brief delay for task to initialize
            ExitApp()
        } else {
            ; Task failed to run - fall back to non-admin mode
            cfg.SetupRunAsAdmin := false
            try _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "RunAsAdmin", false, false, "bool")
            TrayTip("Admin Mode Error", "Scheduled task failed (code " exitCode "). Running without elevation.", "Icon!")
            ; Continue with normal startup below
        }
    }

    ; Check for first-run (config exists but FirstRunCompleted is false)
    ; Skip in testing mode to avoid blocking automated tests
    if (!cfg.SetupFirstRunCompleted && !g_TestingMode) {
        ; Before showing wizard, check if there's an existing install with config
        ; This handles: user downloads new version, their config.ini is empty/missing
        ; but there's a Program Files install with a valid config
        if (_Launcher_ShouldSkipWizardForExistingInstall()) {
            ; Mismatch check will run on next iteration (already ran above)
            ; Mark wizard as complete since user has existing setup
            cfg.SetupFirstRunCompleted := true
            try _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "FirstRunCompleted", true, false, "bool")
        } else {
            ; Show first-run wizard
            ShowFirstRunWizard()
            ; If wizard was shown and exited (self-elevated), we exit here
            ; Otherwise continue to normal startup
        }
    }

    ; Show splash screen if enabled
    if (cfg.LauncherShowSplash)
        ShowSplashScreen()

    ; Set up tray with on-demand menu updates
    SetupLauncherTray()
    OnMessage(0x404, TrayIconClick)  ; WM_TRAYICON

    ; Launch store and GUI
    LaunchStore()
    Sleep(300)
    LaunchGui()

    ; Hide splash after duration (or immediately if duration is 0)
    if (cfg.LauncherShowSplash) {
        ; Calculate remaining time after launches
        elapsed := A_TickCount - g_SplashStartTick
        remaining := cfg.LauncherSplashDurationMs - elapsed
        if (remaining > 0)
            Sleep(remaining)
        HideSplashScreen()
    }

    ; Auto-update check if enabled (skip if mismatch dialog was shown to avoid race)
    if (cfg.SetupAutoUpdateCheck && !g_MismatchDialogShown)
        SetTimer(() => CheckForUpdates(false), -5000)

    ; Register cleanup on exit
    OnExit(_Launcher_OnExit)

    ; Stay alive to manage subprocesses
    Persistent()
}

; Cleanup handler called on exit
_Launcher_OnExit(exitReason, exitCode) {
    global g_LauncherMutex
    try HideSplashScreen()
    if (g_LauncherMutex) {
        try DllCall("CloseHandle", "ptr", g_LauncherMutex)
        g_LauncherMutex := 0
    }
    return 0  ; Allow exit to proceed
}

; Check if we should redirect to scheduled task instead of running directly
; Returns true if: task exists, points to current exe, and we're NOT already elevated
; Note: Trusts task existence over config (handles corrupted config case)
; Handles stale task paths by:
;   - Auto-repairing if InstallationId matches (same install, just renamed/moved)
;   - Prompting user if ID doesn't match or is missing (might be different install)
_ShouldRedirectToScheduledTask() {
    global cfg, gConfigIniPath

    ; Already elevated - don't redirect (avoid infinite loop)
    if (A_IsAdmin)
        return false

    ; Check if task exists
    if (!AdminTaskExists())
        return false

    ; Validate task points to current exe (handles renamed exe case)
    taskPath := _AdminTask_GetCommandPath()
    if (taskPath = "" || StrLower(taskPath) != StrLower(A_ScriptFullPath)) {
        ; Task path doesn't match - check if InstallationId matches
        taskId := _AdminTask_GetInstallationId()
        currentId := (cfg.HasOwnProp("SetupInstallationId") && cfg.SetupInstallationId != "")
            ? cfg.SetupInstallationId : ""

        ; If IDs match, auto-repair without prompting (same installation, just renamed/moved)
        if (taskId != "" && currentId != "" && taskId = currentId) {
            ; Self-elevate to auto-repair task
            try {
                if (A_IsCompiled)
                    Run('*RunAs "' A_ScriptFullPath '" --repair-admin-task')
                else
                    Run('*RunAs "' A_AhkPath '" "' A_ScriptFullPath '" --repair-admin-task')
                ExitApp()  ; Elevated instance will handle launch
            } catch {
                ; UAC refused - fall back to non-admin
                TrayTip("Admin Mode", "Could not elevate to repair task. Running without admin privileges.", "Icon!")
                cfg.SetupRunAsAdmin := false
                try _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "RunAsAdmin", false, false, "bool")
                return false
            }
        }

        ; IDs don't match or missing - use cooldown-based prompting
        ; This handles: different installs, legacy tasks without ID, etc.
        lastRepairTick := 0
        try {
            lastRepairStr := IniRead(gConfigIniPath, "Setup", "LastTaskRepairTick", "0")
            lastRepairTick := Integer(lastRepairStr)
        }
        repairCooldownMs := 86400000  ; 24 hours

        if (lastRepairTick > 0 && (A_TickCount - lastRepairTick) < repairCooldownMs) {
            ; Within cooldown period - silently disable admin mode and continue
            cfg.SetupRunAsAdmin := false
            try _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "RunAsAdmin", false, false, "bool")
            return false
        }

        ; Task is stale and ID doesn't match - offer to repair
        result := MsgBox(
            "The Admin Mode scheduled task points to a different location:`n"
            "Task: " taskPath "`n"
            "Current: " A_ScriptFullPath "`n`n"
            "Would you like to repair it? (requires elevation)",
            "Alt-Tabby - Admin Mode Repair",
            "YesNo Icon?"
        )

        if (result = "Yes") {
            ; Self-elevate to repair task
            try {
                if (A_IsCompiled)
                    Run('*RunAs "' A_ScriptFullPath '" --repair-admin-task')
                else
                    Run('*RunAs "' A_AhkPath '" "' A_ScriptFullPath '" --repair-admin-task')
                ; Record repair attempt tick (will be updated again on success)
                try _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "LastTaskRepairTick", A_TickCount, 0, "int")
                ExitApp()  ; Elevated instance will handle launch
            } catch {
                ; UAC refused - fall back to non-admin
                TrayTip("Admin Mode", "Administrator privileges required to repair. Running without elevation.", "Icon!")
            }
        }

        ; User said No or UAC refused - disable admin mode and continue non-elevated
        ; Record the tick to start cooldown period (only for non-matching IDs)
        cfg.SetupRunAsAdmin := false
        try _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "RunAsAdmin", false, false, "bool")
        try _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "LastTaskRepairTick", A_TickCount, 0, "int")
        TrayTip("Admin Mode Disabled", "The scheduled task was stale.`nRe-enable from tray menu if needed.", "Icon!")
        return false
    }

    ; Sync config if needed (handles corrupted config case)
    if (!cfg.SetupRunAsAdmin) {
        cfg.SetupRunAsAdmin := true
        try _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "RunAsAdmin", true, false, "bool")
    }

    return true
}

; Try to acquire the launcher mutex
; Returns true if acquired (we're the only launcher), false if already held
; Uses InstallationId so renamed exes within same installation share mutex
_Launcher_AcquireMutex() {
    global g_LauncherMutex, cfg

    ; Build mutex name using InstallationId (prevents different-named exes running together)
    ; Falls back to hardcoded name if no ID yet (shouldn't happen - EnsureInstallationId runs first)
    installId := (cfg.HasOwnProp("SetupInstallationId") && cfg.SetupInstallationId != "")
        ? cfg.SetupInstallationId : "default"
    mutexName := "AltTabby_Launcher_" installId

    ; Try to create named mutex
    g_LauncherMutex := DllCall("CreateMutex", "ptr", 0, "int", 1, "str", mutexName, "ptr")
    lastError := DllCall("GetLastError")

    ; ERROR_ALREADY_EXISTS = 183
    if (lastError = 183) {
        ; Mutex already exists - another launcher is running
        if (g_LauncherMutex) {
            DllCall("CloseHandle", "ptr", g_LauncherMutex)
            g_LauncherMutex := 0
        }
        return false
    }

    return (g_LauncherMutex != 0)
}

; Ensure InstallationId exists, generate if missing
; Called early in startup before mutex acquisition
_Launcher_EnsureInstallationId() {
    global cfg, gConfigIniPath

    if (cfg.HasOwnProp("SetupInstallationId") && cfg.SetupInstallationId != "")
        return  ; Already have ID

    ; Generate 8-character hex ID
    installId := _Launcher_GenerateId()
    cfg.SetupInstallationId := installId
    try _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "InstallationId", installId, "", "string")
}

; Generate an 8-character hex ID
_Launcher_GenerateId() {
    ; Use combination of tick count and random for uniqueness
    DllCall("QueryPerformanceCounter", "Int64*", &counter := 0)
    Random(&seed := 0)
    combined := counter ^ seed ^ A_TickCount

    ; Format as 8-char hex
    id := Format("{:08X}", combined & 0xFFFFFFFF)
    return id
}

; Check if we should skip wizard due to existing installation
; Returns true if: there's an existing Program Files install with valid config
_Launcher_ShouldSkipWizardForExistingInstall() {
    global cfg

    ; Only relevant when FirstRunCompleted is false (would show wizard)
    if (cfg.SetupFirstRunCompleted)
        return false

    ; Check for Program Files installation
    pfPath := "C:\Program Files\Alt-Tabby\AltTabby.exe"
    pfConfigPath := "C:\Program Files\Alt-Tabby\config.ini"

    ; If running from Program Files, don't skip (let wizard show for fresh PF installs)
    if (InStr(A_ScriptDir, "C:\Program Files\Alt-Tabby"))
        return false

    ; Check if Program Files install exists with completed setup
    if (FileExist(pfPath) && FileExist(pfConfigPath)) {
        try {
            firstRunVal := IniRead(pfConfigPath, "Setup", "FirstRunCompleted", "false")
            if (firstRunVal = "true" || firstRunVal = "1") {
                ; Existing install has completed setup - skip wizard
                ; The mismatch dialog will offer to launch installed version or run from here
                return true
            }
        }
    }

    return false
}

; Kill all existing instances of this exe except ourselves
; Uses ProcessExist/ProcessClose loop instead of WMI (WMI can fail with 0x800401F3)
; Gets exe name dynamically to support renamed executables (e.g., "alttabby v4.exe")
_Launcher_KillExistingInstances() {
    myPID := ProcessExist()  ; Get our own PID

    ; Get exe name dynamically (handles renamed exe)
    exeName := ""
    SplitPath(A_ScriptFullPath, &exeName)

    ; Loop to kill all instances of this exe except ourselves
    loop 10 {  ; Max 10 iterations to avoid infinite loop
        pid := ProcessExist(exeName)
        if (!pid || pid = myPID)
            break
        try ProcessClose(pid)
        Sleep(100)  ; Brief pause for process to terminate
    }
}

; ============================================================
; SUBPROCESS LAUNCH
; ============================================================

LaunchStore() {
    global g_StorePID
    if (A_IsCompiled) {
        Run('"' A_ScriptFullPath '" --store', , , &g_StorePID)
    } else {
        Run('"' A_AhkPath '" "' A_ScriptDir '\store\store_server.ahk"', , , &g_StorePID)
    }
}

LaunchGui() {
    global g_GuiPID
    if (A_IsCompiled) {
        Run('"' A_ScriptFullPath '" --gui-only', , , &g_GuiPID)
    } else {
        Run('"' A_AhkPath '" "' A_ScriptDir '\gui\gui_main.ahk"', , , &g_GuiPID)
    }
}

LaunchViewer() {
    global g_ViewerPID
    if (A_IsCompiled) {
        Run('"' A_ScriptFullPath '" --viewer', , , &g_ViewerPID)
    } else {
        Run('"' A_AhkPath '" "' A_ScriptDir '\viewer\viewer.ahk"', , , &g_ViewerPID)
    }
}
