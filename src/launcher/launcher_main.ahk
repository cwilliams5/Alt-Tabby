#Requires AutoHotkey v2.0

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
    global g_StorePID, g_GuiPID, g_MismatchDialogShown, g_TestingMode, cfg

    ; Check if another launcher is already running (named mutex)
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
    if (_ShouldRedirectToScheduledTask()) {
        Run('schtasks /run /tn "Alt-Tabby"',, "Hide")
        ExitApp()
    }

    ; Check for first-run (config exists but FirstRunCompleted is false)
    ; Skip in testing mode to avoid blocking automated tests
    if (!cfg.SetupFirstRunCompleted && !g_TestingMode) {
        ; Show first-run wizard
        ShowFirstRunWizard()
        ; If wizard was shown and exited (self-elevated), we exit here
        ; Otherwise continue to normal startup
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
; Returns true if: task exists and we're NOT already elevated
; Note: Trusts task existence over config (handles corrupted config case)
_ShouldRedirectToScheduledTask() {
    global cfg, gConfigIniPath

    ; Already elevated - don't redirect (avoid infinite loop)
    if (A_IsAdmin)
        return false

    ; Check if task exists
    taskExists := AdminTaskExists()

    ; If task exists but config says disabled, update config to match reality
    ; This handles case where config was corrupted/reset
    if (taskExists && !cfg.SetupRunAsAdmin) {
        cfg.SetupRunAsAdmin := true
        try _CL_WriteIniPreserveFormat(gConfigIniPath, "Setup", "RunAsAdmin", true, false, "bool")
    }

    ; Only redirect if task exists and we're not admin
    if (!taskExists)
        return false

    return true
}

; Try to acquire the launcher mutex
; Returns true if acquired (we're the only launcher), false if already held
_Launcher_AcquireMutex() {
    global g_LauncherMutex

    ; Try to create named mutex
    g_LauncherMutex := DllCall("CreateMutex", "ptr", 0, "int", 1, "str", "AltTabby_Launcher", "ptr")
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
