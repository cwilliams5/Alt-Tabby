#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Cross-file globals (cfg, g_PumpPID, etc.) come from alt_tabby.ahk

; ============================================================
; Launcher Dashboard
; ============================================================
; Two-column dashboard: Keyboard Shortcuts (left), Diagnostics
; + Settings (right). Subprocess controls, settings toggles,
; and system information.
;
; Adaptive refresh: always-on slow timer while dialog is open,
; interactions temporarily boost to rapid polling, then decay:
;   Hot  (0-15s after click)  250ms  — catch subprocess settle
;   Warm (15-75s)             1s     — catch slower changes
;   Cool (75s+ / idle)        5s     — prevent deep staleness

global g_DashboardGui := 0
global g_DashboardShuttingDown := false
global g_DashControls := {}
global g_DashRefreshTick := 0
global DASH_INTERVAL_HOT := 250
global DASH_INTERVAL_WARM := 1000
global DASH_INTERVAL_COOL := 5000
global DASH_TIER_HOT_MS := 15000
global DASH_TIER_WARM_MS := 75000

; Update check state — persists across dashboard open/close
global g_DashUpdateState
g_DashUpdateState := {status: "unchecked", version: "", downloadUrl: ""}
global DASH_UPDATE_STALE_MS := 43200000  ; 12 hours

; Stats cache — read from stats.ini [Snapshot] section (written by GUI heartbeat)
global g_StatsCache := ""          ; Parsed stats snapshot Map, or "" if not loaded

ShowDashboardDialog() {
    global g_DashboardGui, g_DashboardShuttingDown, cfg, APP_NAME
    global g_PumpPID, g_GuiPID, ALTTABBY_INSTALL_DIR
    global g_ConfigEditorPID, g_BlacklistEditorPID
    global g_DashControls, g_DashUpdateState, DASH_INTERVAL_COOL
    global gTheme_Palette

    ; If already open, focus existing dialog
    if (g_DashboardGui) {
        try WinActivate(g_DashboardGui)
        return
    }

    g_DashboardShuttingDown := false
    g_DashControls := {}

    dg := Gui("", "Alt-Tabby Dashboard")
    GUI_AntiFlashPrepare(dg, Theme_GetBgColor(), true)
    dg.SetFont("s10", "Segoe UI")
    dg.MarginX := 20
    dg.MarginY := 15
    themeEntry := Theme_ApplyToGui(dg)

    ; ---- Header: Logo + Title + Version + Links ----
    logo := _Dash_LoadLogo(dg)
    xAfterLogo := logo ? 150 : 0

    dg.SetFont("s16 Bold")
    dg.AddText("x" xAfterLogo " y15 w225", APP_NAME)

    dg.SetFont("s10 Norm")
    version := GetAppVersion()
    mutedVersion := dg.AddText("x" xAfterLogo " y+2 w225 c" Theme_GetMutedColor(), "Version " version)
    Theme_MarkMuted(mutedVersion)

    dg.SetFont("s10 Underline")
    lnkGithub := dg.AddText("x" xAfterLogo " y+4 w225 +0x100", "github.com/cwilliams5/Alt-Tabby")
    lnkGithub.OnEvent("Click", (*) => Run("https://github.com/cwilliams5/Alt-Tabby"))
    Theme_MarkAccent(lnkGithub)
    lnkOptions := dg.AddText("x" xAfterLogo " y+2 w225 +0x100", "Configuration Options")
    lnkOptions.OnEvent("Click", (*) => Run("https://github.com/cwilliams5/Alt-Tabby/blob/main/docs/options.md"))
    Theme_MarkAccent(lnkOptions)
    lnkChangelog := dg.AddText("x" xAfterLogo " y+2 w225 +0x100", "What's New")
    lnkChangelog.OnEvent("Click", (*) => Run("https://github.com/cwilliams5/Alt-Tabby/releases"))
    Theme_MarkAccent(lnkChangelog)
    dg.SetFont("s10 Norm")

    ; ============================================================
    ; TOP-RIGHT - Settings
    ; ============================================================
    dg.SetFont("s10")
    gbSettings := dg.AddGroupBox("x385 y10 w375 h130", "Settings")
    Theme_ApplyToControl(gbSettings, "GroupBox", themeEntry)

    ; Checkboxes — refresh timer corrects visual state if underlying toggle fails
    dg.SetFont("s9")

    g_DashControls.chkStartMenu := dg.AddCheckbox("x400 y35 w340", "Add to Start Menu")
    g_DashControls.chkStartMenu.Value := Shortcut_StartMenuExists() ? 1 : 0
    g_DashControls.chkStartMenu.OnEvent("Click", _Dash_OnStartMenuChk)

    g_DashControls.chkStartup := dg.AddCheckbox("x400 y59 w340", "Run at Startup")
    g_DashControls.chkStartup.Value := Shortcut_StartupExists() ? 1 : 0
    g_DashControls.chkStartup.OnEvent("Click", _Dash_OnStartupChk)

    g_DashControls.chkAutoUpdate := dg.AddCheckbox("x400 y83 w340", "Auto-check for Updates")
    g_DashControls.chkAutoUpdate.Value := cfg.SetupAutoUpdateCheck ? 1 : 0
    g_DashControls.chkAutoUpdate.OnEvent("Click", _Dash_OnAutoUpdateChk)

    Theme_ApplyToControl(g_DashControls.chkStartMenu, "Checkbox", themeEntry)
    Theme_ApplyToControl(g_DashControls.chkStartup, "Checkbox", themeEntry)
    Theme_ApplyToControl(g_DashControls.chkAutoUpdate, "Checkbox", themeEntry)

    ; Action buttons row
    dg.SetFont("s9")
    btnEditConfig := dg.AddButton("x400 y107 w115 h26", "Edit Config...")
    btnEditConfig.OnEvent("Click", (*) => LaunchConfigEditor())
    btnEditBlacklist := dg.AddButton("x520 y107 w115 h26", "Edit Blacklist...")
    btnEditBlacklist.OnEvent("Click", (*) => LaunchBlacklistEditor())
    Theme_ApplyToControl(btnEditConfig, "Button", themeEntry)
    Theme_ApplyToControl(btnEditBlacklist, "Button", themeEntry)

    ; Install to Program Files (action or status label)
    if (A_IsCompiled && !IsInProgramFiles()) {
        g_DashControls.installPFBtn := dg.AddButton("x640 y107 w115 h26", "Install to PF...")
        g_DashControls.installPFBtn.OnEvent("Click", (*) => Tray_InstallToProgramFiles())
        Theme_ApplyToControl(g_DashControls.installPFBtn, "Button", themeEntry)
    } else if (A_IsCompiled) {
        pfLabel := dg.AddText("x640 y112 w115 h20 +0x100 c" Theme_GetMutedColor(), Chr(0x2713) " Program Files")
        pfLabel.SetFont("s8", "Segoe UI")
        Theme_MarkMuted(pfLabel)
    }

    ; ============================================================
    ; MIDDLE ROW - Statistics
    ; ============================================================
    dg.SetFont("s10")
    gbStats := dg.AddGroupBox("x20 y150 w740 h110", "Statistics")
    Theme_ApplyToControl(gbStats, "GroupBox", themeEntry)

    if (cfg.StatsTrackingEnabled) {
        ; Session column (left)
        dg.SetFont("s9 Bold")
        dg.AddText("x35 y170 w170", "This Session")
        dg.SetFont("s9 Norm")

        dg.AddText("x35 y190 w90 Right", "Run Time:")
        g_DashControls.statsSessionTime := dg.AddText("x130 y190 w100 +0x100", "...")

        dg.AddText("x35 y208 w90 Right", "Alt-Tabs:")
        g_DashControls.statsSessionAltTabs := dg.AddText("x130 y208 w100 +0x100", "...")

        dg.AddText("x35 y226 w90 Right", "Quick:")
        g_DashControls.statsSessionQuick := dg.AddText("x130 y226 w100 +0x100", "...")

        ; Lifetime column (right)
        dg.SetFont("s9 Bold")
        dg.AddText("x395 y170 w170", "All Time")
        dg.SetFont("s9 Norm")

        dg.AddText("x395 y190 w90 Right", "Run Time:")
        g_DashControls.statsLifetimeTime := dg.AddText("x490 y190 w110 +0x100", "...")

        dg.AddText("x395 y208 w90 Right", "Alt-Tabs:")
        g_DashControls.statsLifetimeAltTabs := dg.AddText("x490 y208 w110 +0x100", "...")

        dg.AddText("x395 y226 w90 Right", "Quick:")
        g_DashControls.statsLifetimeQuick := dg.AddText("x490 y226 w110 +0x100", "...")

        ; More Stats button
        dg.SetFont("s9")
        btnMoreStats := dg.AddButton("x655 y229 w90 h24", "More Stats")
        btnMoreStats.OnEvent("Click", (*) => ShowStatsDialog())
        Theme_ApplyToControl(btnMoreStats, "Button", themeEntry)
    } else {
        dg.SetFont("s9")
        mutedStatsText := dg.AddText("x35 y185 w700 c" Theme_GetMutedColor(), "Statistics tracking is disabled. Enable via Edit Config > Diagnostics > StatsTracking.")
        Theme_MarkMuted(mutedStatsText)
    }

    ; ============================================================
    ; BOTTOM-LEFT - Keyboard Shortcuts
    ; ============================================================
    dg.SetFont("s10")
    gbShortcuts := dg.AddGroupBox("x20 y270 w350 h270", "Keyboard Shortcuts")
    Theme_ApplyToControl(gbShortcuts, "GroupBox", themeEntry)

    ; "Always On" section — global hotkeys that work any time
    dg.SetFont("s9 Bold")
    dg.AddText("x35 y292 w310", "Always On")
    dg.SetFont("s9 Norm")

    alwaysOn := [
        ["Alt+Tab", "Cycle forward through windows"],
        ["Alt+Shift+Tab", "Cycle backward"],
        ["Alt+Shift+F12", "Exit Alt-Tabby"]
    ]
    for i, item in alwaysOn {
        yOpt := (i = 1) ? "y+8" : "y+4"
        dg.SetFont("s9 Bold")
        dg.AddText("x35 " yOpt " w130 Right", item[1])
        dg.SetFont("s9 Norm")
        dg.AddText("x175 yp w185", item[2])
    }

    ; "In App" section — only work when overlay is visible
    dg.SetFont("s9 Bold")
    dg.AddText("x35 y+14 w310", "In App")
    dg.SetFont("s9 Norm")

    inApp := [
        ["Ctrl (hold Alt)", "Toggle workspace filter"],
        ["Escape", "Cancel and dismiss overlay"],
        ["Mouse click", "Select and activate window"],
        ["Mouse wheel", "Scroll through windows"]
    ]
    for i, item in inApp {
        yOpt := (i = 1) ? "y+8" : "y+4"
        dg.SetFont("s9 Bold")
        dg.AddText("x35 " yOpt " w130 Right", item[1])
        dg.SetFont("s9 Norm")
        dg.AddText("x175 yp w185", item[2])
    }

    ; ============================================================
    ; BOTTOM-RIGHT - Diagnostics
    ; ============================================================
    dg.SetFont("s10")
    gbDiag := dg.AddGroupBox("x385 y270 w375 h270", "Diagnostics")
    Theme_ApplyToControl(gbDiag, "GroupBox", themeEntry)

    ; Build + Elevation row
    buildType := A_IsCompiled ? "Compiled" : "Development"
    elevation := A_IsAdmin ? "Administrator" : "Standard"
    dg.SetFont("s9")
    ctlBuildInfo := dg.AddText("x400 y295 w240 +0x100", "Build: " buildType "  |  Elevation: " elevation)

    ; Escalate/De-escalate button
    escalateLabel := A_IsAdmin ? "De-escalate" : "Escalate"
    btnEscalate := dg.AddButton("x660 y291 w85 h24", escalateLabel)
    btnEscalate.OnEvent("Click", _Dash_OnEscalate)
    Theme_ApplyToControl(btnEscalate, "Button", themeEntry)

    ; Subprocess rows with buttons — handlers check live state, refresh updates labels
    ; Order: Pump, GUI, Config Editor, Blacklist Editor
    ; Colored dot controls: green=running, red=core not running, grey=optional not running
    dot := Chr(0x25CF)  ; ● BLACK CIRCLE — renders solid in any font

    ; Pump row (core — red when not running)
    subY := 322
    _Dash_AddSubprocessRow(dg, themeEntry, dot, &subY, "pump", "Enrichment Pump", g_PumpPID, true, _Dash_OnPumpBtn)

    ; GUI row (core — red when not running)
    subY += 30
    _Dash_AddSubprocessRow(dg, themeEntry, dot, &subY, "gui", "GUI", g_GuiPID, true, _Dash_OnGuiBtn)

    ; Config Editor row (optional — grey when not running)
    subY += 30
    _Dash_AddSubprocessRow(dg, themeEntry, dot, &subY, "config", "Config Editor", g_ConfigEditorPID, false, _Dash_OnConfigBtn)

    ; Blacklist Editor row (optional — grey when not running)
    subY += 30
    _Dash_AddSubprocessRow(dg, themeEntry, dot, &subY, "blacklist", "Blacklist Editor", g_BlacklistEditorPID, false, _Dash_OnBlacklistBtn)

    ; Viewer toggle (in-process debug window — no subprocess to track)
    subY += 30
    dg.AddText("x400 y" subY " w14", "")  ; spacer for alignment
    viewerLabel := dg.AddText("x420 y" subY " w170 +0x100 c" gTheme_Palette.text, "Debug Viewer")
    viewerToggleBtn := dg.AddButton("x600 y" (subY - 3) " w80 h22", "Toggle")
    viewerToggleBtn.OnEvent("Click", (*) => Tray_ToggleViewer())

    ; Info rows (read-only)
    subY += 28
    ctlInstallInfo := dg.AddText("x400 y" subY " w340 +0x100 c" Theme_GetMutedColor(), "Install: " _Dash_GetInstallInfo())
    Theme_MarkMuted(ctlInstallInfo)

    subY += 20
    ctlAdminTask := dg.AddText("x400 y" subY " w340 +0x100 c" Theme_GetMutedColor(), "Admin Task: " _Dash_GetAdminTaskInfo())
    Theme_MarkMuted(ctlAdminTask)

    subY += 20
    g_DashControls.komorebiText := dg.AddText("x400 y" subY " w340 +0x100 c" Theme_GetMutedColor(), "Komorebi: " _Dash_GetKomorebiInfo())
    Theme_MarkMuted(g_DashControls.komorebiText)

    ; ---- Bottom Row: action button + update status + OK ----
    dg.SetFont("s9")
    updateBtnLabel := _Dash_GetUpdateBtnLabel()
    g_DashControls.updateBtn := dg.AddButton("x20 y550 w100 h24", updateBtnLabel)
    g_DashControls.updateBtn.OnEvent("Click", _Dash_OnUpdateBtn)
    g_DashControls.updateBtn.Enabled := (g_DashUpdateState.status != "checking")
    Theme_ApplyToControl(g_DashControls.updateBtn, "Button", themeEntry)

    updateLabel := _Dash_GetUpdateLabel()
    g_DashControls.updateText := dg.AddText("x130 y555 w300 +0x100 c" Theme_GetMutedColor(), updateLabel)
    Theme_MarkMuted(g_DashControls.updateText)

    dg.SetFont("s10")
    btnClose := dg.AddButton("x675 y550 w80 Default", "Close")
    btnClose.OnEvent("Click", _Dash_OnClose)
    Theme_ApplyToControl(btnClose, "Button", themeEntry)

    ; Close event
    dg.OnEvent("Close", _Dash_OnClose)
    dg.OnEvent("Escape", _Dash_OnClose)

    ; ---- Tooltips ----
    hTT := Dash_CreateTooltipCtl(dg.Hwnd)
    g_DashControls.hTooltip := hTT
    if (hTT) {
        ; Header links
        Dash_SetTip(hTT, lnkGithub, "Open the project page on GitHub")
        Dash_SetTip(hTT, lnkOptions, "View all configuration options on GitHub")
        Dash_SetTip(hTT, lnkChangelog, "View release notes and changelog on GitHub")

        ; Settings
        Dash_SetTip(hTT, g_DashControls.chkStartMenu, "Create a shortcut in the Windows Start Menu")
        Dash_SetTip(hTT, g_DashControls.chkStartup, "Launch Alt-Tabby automatically when you log in")
        Dash_SetTip(hTT, g_DashControls.chkAutoUpdate, "Check GitHub for new releases on startup")
        Dash_SetTip(hTT, btnEditConfig, "Open the configuration file editor")
        Dash_SetTip(hTT, btnEditBlacklist, "Open the window blacklist editor")
        if (g_DashControls.HasOwnProp("installPFBtn"))
            Dash_SetTip(hTT, g_DashControls.installPFBtn, "Install Alt-Tabby to Program Files`nRequires administrator privileges")

        ; Statistics
        if (cfg.StatsTrackingEnabled && IsSet(btnMoreStats))
            Dash_SetTip(hTT, btnMoreStats, "View all lifetime, session, and derived statistics")

        ; Diagnostics — static tooltips on labels (SS_NOTIFY enables mouse tracking)
        Dash_SetTip(hTT, ctlBuildInfo
            , "Build type and privilege level`n"
            . "Compiled = running from AltTabby.exe`n"
            . "Development = running from AHK source")
        escalateTip := A_IsAdmin ? "Restart without administrator elevation" : "Restart with administrator elevation (UAC prompt)"
        Dash_SetTip(hTT, btnEscalate, escalateTip)
        Dash_SetTip(hTT, g_DashControls.pumpText
            , "The Enrichment Pump resolves window icons and process`n"
            . "names asynchronously in a subprocess via named pipe IPC")
        Dash_SetTip(hTT, g_DashControls.guiText
            , "The Alt+Tab overlay — handles keyboard hooks,`n"
            . "window selection, and rendering")
        Dash_SetTip(hTT, g_DashControls.configText
            , "Editor subprocess for modifying config.ini settings")
        Dash_SetTip(hTT, g_DashControls.blacklistText
            , "Editor subprocess for managing the window filter blacklist")
        Dash_SetTip(hTT, viewerLabel
            , "Debug viewer — displays live window data from the`n"
            . "WindowList for troubleshooting")
        Dash_SetTip(hTT, ctlInstallInfo
            , "Directory where Alt-Tabby is installed or running from")
        Dash_SetTip(hTT, ctlAdminTask
            , "Windows Task Scheduler task that allows Alt-Tabby`n"
            . "to run with administrator privileges without UAC prompts")
        Dash_SetTip(hTT, g_DashControls.komorebiText
            , "Komorebi tiling window manager — when running,`n"
            . "provides workspace data for filtering and labeling windows")
        Dash_SetTip(hTT, g_DashControls.updateText, "Update status — auto-checks when stale (12+ hours)")
        Dash_SetTip(hTT, btnClose, "Close the dashboard")

        ; Dynamic tooltips — must match current button state
        pumpRunning := LauncherUtils_IsRunning(g_PumpPID)
        guiRunning := LauncherUtils_IsRunning(g_GuiPID)
        configRunning := LauncherUtils_IsRunning(g_ConfigEditorPID)
        blacklistRunning := LauncherUtils_IsRunning(g_BlacklistEditorPID)
        Dash_SetTip(hTT, g_DashControls.pumpBtn, pumpRunning ? "Stop and restart the EnrichmentPump" : "Start the EnrichmentPump")
        Dash_SetTip(hTT, g_DashControls.guiBtn, guiRunning ? "Stop and restart the GUI overlay" : "Start the GUI overlay")
        Dash_SetTip(hTT, g_DashControls.configBtn, configRunning ? "Restart the configuration editor" : "Open the configuration editor")
        Dash_SetTip(hTT, g_DashControls.blacklistBtn, blacklistRunning ? "Restart the blacklist editor" : "Open the blacklist editor")
        Dash_SetTip(hTT, g_DashControls.updateBtn, _Dash_GetUpdateBtnTip())
    }

    g_DashboardGui := dg
    dg.Show("w780")
    GUI_AntiFlashReveal(dg, true)
    btnClose.Focus()

    ; Start background refresh in cool mode (no interaction yet)
    SetTimer(_Dash_RefreshDynamic, DASH_INTERVAL_COOL)

    ; Query stats if tracking is enabled (reads stats.ini written by GUI heartbeat)
    if (cfg.StatsTrackingEnabled)
        SetTimer(Dash_QueryStats, -500)

    ; Auto-check if stale (never checked, or >12h ago)
    _Dash_MaybeCheckForUpdates()
}

; ============================================================
; Interaction Handlers — check live state, act, trigger refresh
; ============================================================

_Dash_OnPumpBtn(*) {
    global g_PumpPID
    if (LauncherUtils_IsRunning(g_PumpPID))
        RestartPump()
    else
        LaunchPump()
}

_Dash_OnGuiBtn(*) {
    global g_GuiPID
    if (LauncherUtils_IsRunning(g_GuiPID))
        RestartGui()
    else
        LaunchGui()
}

; (Viewer is now in-process — toggled via Tray_ToggleViewer)

_Dash_OnConfigBtn(*) {
    global g_ConfigEditorPID
    if (LauncherUtils_IsRunning(g_ConfigEditorPID))
        RestartConfigEditor()
    else
        LaunchConfigEditor()
}

_Dash_OnBlacklistBtn(*) {
    global g_BlacklistEditorPID
    if (LauncherUtils_IsRunning(g_BlacklistEditorPID))
        RestartBlacklistEditor()
    else
        LaunchBlacklistEditor()
}

_Dash_OnStartMenuChk(*) {
    ToggleStartMenuShortcut()
}

_Dash_OnStartupChk(*) {
    ToggleStartupShortcut()
}

_Dash_OnAutoUpdateChk(*) {
    ToggleAutoUpdate()
}

_Dash_OnEscalate(*) {
    _Dash_OnClose()
    ToggleAdminMode()
}

_Dash_OnUpdateBtn(*) {
    global g_DashUpdateState
    if (g_DashUpdateState.status = "available" && g_DashUpdateState.downloadUrl != "") {
        ; Install mode — close dashboard and apply update
        url := g_DashUpdateState.downloadUrl
        ver := g_DashUpdateState.version
        _Dash_OnClose()
        Update_DownloadAndApply(url, ver)
    } else {
        ; Check mode — trigger async version check
        g_DashUpdateState.status := "checking"
        g_DashUpdateState.version := ""
        g_DashUpdateState.downloadUrl := ""
        Dash_StartRefreshTimer()
        SetTimer(_Dash_CheckForUpdatesAsync, -1)
    }
}

_Dash_OnClose(*) {
    global g_DashboardGui, g_DashboardShuttingDown, g_DashControls
    g_DashboardShuttingDown := true
    SetTimer(_Dash_RefreshDynamic, 0)
    if (g_DashboardGui) {
        Theme_UntrackGui(g_DashboardGui)
        g_DashboardGui.Destroy()
        g_DashboardGui := 0
    }
    g_DashControls := {}
}

; ============================================================
; Adaptive Refresh
; ============================================================
; Always-on timer while dialog is open. Interactions boost to
; hot (250ms), decays to warm (1s) then cool (5s).

; Update dashboard update-check state from external callers (e.g., setup_utils)
Dash_SetUpdateState(status, version := "", url := "") {
    global g_DashUpdateState, g_DashboardGui
    g_DashUpdateState.status := status
    g_DashUpdateState.version := version
    g_DashUpdateState.downloadUrl := url
    if (g_DashboardGui)
        Dash_StartRefreshTimer()
}

Dash_StartRefreshTimer() {
    global g_DashboardGui, g_DashRefreshTick, DASH_INTERVAL_HOT
    if (!g_DashboardGui)
        return
    g_DashRefreshTick := A_TickCount
    SetTimer(_Dash_RefreshDynamic, DASH_INTERVAL_HOT)
}

_Dash_RefreshDynamic() {
    global g_DashboardGui, g_DashControls, g_DashRefreshTick
    global g_GuiPID, g_PumpPID, cfg
    global g_ConfigEditorPID, g_BlacklistEditorPID
    global g_DashUpdateState
    global gTheme_Palette
    global g_StatsCache
    global DASH_INTERVAL_HOT, DASH_INTERVAL_WARM, DASH_INTERVAL_COOL
    global DASH_TIER_HOT_MS, DASH_TIER_WARM_MS

    ; Stop if dialog closed or shutting down
    global g_DashboardShuttingDown
    if (!g_DashboardGui || g_DashboardShuttingDown) {
        SetTimer(_Dash_RefreshDynamic, 0)
        return
    }

    ; Adaptive interval: decay from hot → warm → cool
    elapsed := A_TickCount - g_DashRefreshTick
    if (elapsed < DASH_TIER_HOT_MS)
        nextInterval := DASH_INTERVAL_HOT
    else if (elapsed < DASH_TIER_WARM_MS)
        nextInterval := DASH_INTERVAL_WARM
    else
        nextInterval := DASH_INTERVAL_COOL
    SetTimer(_Dash_RefreshDynamic, nextInterval)

    ; Re-query stats from disk during HOT/WARM intervals
    if (cfg.StatsTrackingEnabled && nextInterval <= DASH_INTERVAL_WARM)
        SetTimer(Dash_QueryStats, -1)

    ; Build new state snapshot — compute all values before touching any controls
    pumpRunning := LauncherUtils_IsRunning(g_PumpPID)
    guiRunning := LauncherUtils_IsRunning(g_GuiPID)
    configRunning := LauncherUtils_IsRunning(g_ConfigEditorPID)
    blacklistRunning := LauncherUtils_IsRunning(g_BlacklistEditorPID)

    newState := Map(
        "pumpDotColor", pumpRunning ? "c" gTheme_Palette.success : "c" gTheme_Palette.danger,
        "pumpText", "Pump: " (pumpRunning ? "Running (PID " g_PumpPID ")" : "Not running"),
        "pumpBtn", pumpRunning ? "Restart" : "Launch",
        "guiDotColor", guiRunning ? "c" gTheme_Palette.success : "c" gTheme_Palette.danger,
        "guiText", "GUI: " (guiRunning ? "Running (PID " g_GuiPID ")" : "Not running"),
        "guiBtn", guiRunning ? "Restart" : "Launch",
        "configDotColor", configRunning ? "c" gTheme_Palette.success : "c" gTheme_Palette.textMuted,
        "configText", "Config Editor: " (configRunning ? "Running (PID " g_ConfigEditorPID ")" : "Not running"),
        "configBtn", configRunning ? "Restart" : "Launch",
        "blacklistDotColor", blacklistRunning ? "c" gTheme_Palette.success : "c" gTheme_Palette.textMuted,
        "blacklistText", "Blacklist Editor: " (blacklistRunning ? "Running (PID " g_BlacklistEditorPID ")" : "Not running"),
        "blacklistBtn", blacklistRunning ? "Restart" : "Launch",
        "komorebiText", "Komorebi: " _Dash_GetKomorebiInfo(),
        "chkStartMenu", Shortcut_StartMenuExists() ? 1 : 0,
        "chkStartup", Shortcut_StartupExists() ? 1 : 0,
        "chkAutoUpdate", cfg.SetupAutoUpdateCheck ? 1 : 0,
        "updateText", _Dash_GetUpdateLabel(),
        "updateBtn", _Dash_GetUpdateBtnLabel(),
        "updateBtnEnabled", (g_DashUpdateState.status != "checking") ? 1 : 0
    )

    ; Add stats fields if tracking is enabled and controls exist
    if (g_DashControls.HasOwnProp("statsSessionTime")) {
        if (IsObject(g_StatsCache)) {
            newState["statsSessionTime"] := Stats_FormatDuration(Stats_MapGet(g_StatsCache, "SessionRunTimeSec"))
            newState["statsSessionAltTabs"] := Stats_FormatNumber(Stats_MapGet(g_StatsCache, "SessionAltTabs"))
            newState["statsSessionQuick"] := Stats_FormatNumber(Stats_MapGet(g_StatsCache, "SessionQuickSwitches"))
            newState["statsLifetimeTime"] := Stats_FormatDuration(Stats_MapGet(g_StatsCache, "TotalRunTimeSec") + Stats_MapGet(g_StatsCache, "SessionRunTimeSec"))
            newState["statsLifetimeAltTabs"] := Stats_FormatNumber(Stats_MapGet(g_StatsCache, "TotalAltTabs"))
            newState["statsLifetimeQuick"] := Stats_FormatNumber(Stats_MapGet(g_StatsCache, "TotalQuickSwitches"))
        } else {
            newState["statsSessionTime"] := "..."
            newState["statsSessionAltTabs"] := "..."
            newState["statsSessionQuick"] := "..."
            newState["statsLifetimeTime"] := "..."
            newState["statsLifetimeAltTabs"] := "..."
            newState["statsLifetimeQuick"] := "..."
        }
    }

    ; Diff against current control values — skip redraw if nothing changed
    ; Guard: controls may have been destroyed between state build and diff
    if (!g_DashControls.HasOwnProp("pumpDotColor"))
        return
    changed := false
    if (g_DashControls.pumpDotColor != newState["pumpDotColor"]
        || g_DashControls.pumpText.Value != newState["pumpText"]
        || g_DashControls.pumpBtn.Text != newState["pumpBtn"]
        || g_DashControls.guiDotColor != newState["guiDotColor"]
        || g_DashControls.guiText.Value != newState["guiText"]
        || g_DashControls.guiBtn.Text != newState["guiBtn"]
        || g_DashControls.configDotColor != newState["configDotColor"]
        || g_DashControls.configText.Value != newState["configText"]
        || g_DashControls.configBtn.Text != newState["configBtn"]
        || g_DashControls.blacklistDotColor != newState["blacklistDotColor"]
        || g_DashControls.blacklistText.Value != newState["blacklistText"]
        || g_DashControls.blacklistBtn.Text != newState["blacklistBtn"]
        || g_DashControls.komorebiText.Value != newState["komorebiText"]
        || g_DashControls.chkStartMenu.Value != newState["chkStartMenu"]
        || g_DashControls.chkStartup.Value != newState["chkStartup"]
        || g_DashControls.chkAutoUpdate.Value != newState["chkAutoUpdate"]
        || g_DashControls.updateText.Value != newState["updateText"]
        || g_DashControls.updateBtn.Text != newState["updateBtn"]
        || g_DashControls.updateBtn.Enabled != newState["updateBtnEnabled"])
        changed := true

    ; Check stats controls for changes
    if (!changed && g_DashControls.HasOwnProp("statsSessionTime") && newState.Has("statsSessionTime")) {
        if (g_DashControls.statsSessionTime.Value != newState["statsSessionTime"]
            || g_DashControls.statsSessionAltTabs.Value != newState["statsSessionAltTabs"]
            || g_DashControls.statsSessionQuick.Value != newState["statsSessionQuick"]
            || g_DashControls.statsLifetimeTime.Value != newState["statsLifetimeTime"]
            || g_DashControls.statsLifetimeAltTabs.Value != newState["statsLifetimeAltTabs"]
            || g_DashControls.statsLifetimeQuick.Value != newState["statsLifetimeQuick"])
            changed := true
    }

    if (!changed)
        return

    ; Suppress repaints while updating controls
    hWnd := g_DashboardGui.Hwnd
    DllCall("user32\SendMessage", "ptr", hWnd, "uint", 0xB, "ptr", 0, "ptr", 0)  ; WM_SETREDRAW FALSE

    ; Update dot colors via SetFont (only when changed to avoid flicker)
    if (g_DashControls.pumpDotColor != newState["pumpDotColor"]) {
        g_DashControls.pumpDot.SetFont(newState["pumpDotColor"])
        g_DashControls.pumpDotColor := newState["pumpDotColor"]
    }
    if (g_DashControls.guiDotColor != newState["guiDotColor"]) {
        g_DashControls.guiDot.SetFont(newState["guiDotColor"])
        g_DashControls.guiDotColor := newState["guiDotColor"]
    }
    if (g_DashControls.configDotColor != newState["configDotColor"]) {
        g_DashControls.configDot.SetFont(newState["configDotColor"])
        g_DashControls.configDotColor := newState["configDotColor"]
    }
    if (g_DashControls.blacklistDotColor != newState["blacklistDotColor"]) {
        g_DashControls.blacklistDot.SetFont(newState["blacklistDotColor"])
        g_DashControls.blacklistDotColor := newState["blacklistDotColor"]
    }

    g_DashControls.pumpText.Value := newState["pumpText"]
    g_DashControls.pumpBtn.Text := newState["pumpBtn"]
    g_DashControls.guiText.Value := newState["guiText"]
    g_DashControls.guiBtn.Text := newState["guiBtn"]
    g_DashControls.configText.Value := newState["configText"]
    g_DashControls.configBtn.Text := newState["configBtn"]
    g_DashControls.blacklistText.Value := newState["blacklistText"]
    g_DashControls.blacklistBtn.Text := newState["blacklistBtn"]
    g_DashControls.komorebiText.Value := newState["komorebiText"]
    g_DashControls.chkStartMenu.Value := newState["chkStartMenu"]
    g_DashControls.chkStartup.Value := newState["chkStartup"]
    g_DashControls.chkAutoUpdate.Value := newState["chkAutoUpdate"]
    g_DashControls.updateText.Value := newState["updateText"]
    g_DashControls.updateBtn.Text := newState["updateBtn"]
    g_DashControls.updateBtn.Enabled := newState["updateBtnEnabled"]

    ; Update stats controls
    if (g_DashControls.HasOwnProp("statsSessionTime") && newState.Has("statsSessionTime")) {
        g_DashControls.statsSessionTime.Value := newState["statsSessionTime"]
        g_DashControls.statsSessionAltTabs.Value := newState["statsSessionAltTabs"]
        g_DashControls.statsSessionQuick.Value := newState["statsSessionQuick"]
        g_DashControls.statsLifetimeTime.Value := newState["statsLifetimeTime"]
        g_DashControls.statsLifetimeAltTabs.Value := newState["statsLifetimeAltTabs"]
        g_DashControls.statsLifetimeQuick.Value := newState["statsLifetimeQuick"]
    }

    ; Update dynamic tooltips to match button state
    if (g_DashControls.HasOwnProp("hTooltip") && g_DashControls.hTooltip) {
        hTT := g_DashControls.hTooltip
        _Dash_UpdateTip(hTT, g_DashControls.pumpBtn, pumpRunning ? "Stop and restart the Enrichment Pump" : "Start the Enrichment Pump")
        _Dash_UpdateTip(hTT, g_DashControls.guiBtn, guiRunning ? "Stop and restart the GUI overlay" : "Start the GUI overlay")
        _Dash_UpdateTip(hTT, g_DashControls.configBtn, configRunning ? "Restart the configuration editor" : "Open the configuration editor")
        _Dash_UpdateTip(hTT, g_DashControls.blacklistBtn, blacklistRunning ? "Restart the blacklist editor" : "Open the blacklist editor")
        _Dash_UpdateTip(hTT, g_DashControls.updateBtn, _Dash_GetUpdateBtnTip())
    }

    ; Re-enable repaints and force a single
    DllCall("user32\SendMessage", "ptr", hWnd, "uint", 0xB, "ptr", 1, "ptr", 0)  ; WM_SETREDRAW TRUE
    DllCall("user32\RedrawWindow", "ptr", hWnd, "ptr", 0, "ptr", 0, "uint", 0x0107)  ; RDW_INVALIDATE|RDW_ERASE|RDW_UPDATENOW
}

; ============================================================
; Dashboard Update Check (non-blocking, no popups)
; ============================================================

_Dash_GetUpdateLabel() {
    global g_DashUpdateState
    switch g_DashUpdateState.status {
        case "checking": return "Update: Checking..."
        case "uptodate": return "Update: Up to date"
        case "available": return "Update: Version " g_DashUpdateState.version " available"
        case "error": return "Update: Check failed"
        default: return "Update: Not checked"
    }
}

_Dash_GetUpdateBtnLabel() {
    global g_DashUpdateState
    if (g_DashUpdateState.status = "available")
        return "Install"
    if (g_DashUpdateState.status = "checking")
        return "Checking..."
    return "Check Now"
}

_Dash_MaybeCheckForUpdates() {
    global g_LastUpdateCheckTick, g_DashUpdateState, DASH_UPDATE_STALE_MS
    ; Check if never checked or stale (>12h)
    if (g_LastUpdateCheckTick = 0 || (A_TickCount - g_LastUpdateCheckTick) >= DASH_UPDATE_STALE_MS) {
        g_DashUpdateState.status := "checking"
        Dash_StartRefreshTimer()
        SetTimer(_Dash_CheckForUpdatesAsync, -1)
    }
}

_Dash_CheckForUpdatesAsync() {
    global g_DashboardGui
    CheckForUpdates(false, false)
    if (g_DashboardGui)
        Dash_StartRefreshTimer()
}

; ============================================================
; Logo Loader
; ============================================================

_Dash_LoadLogo(dg) {
    global RES_ID_LOGO
    ; Dev mode: load from file
    if (!A_IsCompiled) {
        imgPath := A_ScriptDir "\..\resources\img\logo.png"
        if (FileExist(imgPath)) {
            dg.AddPicture("x20 y15 w116 h90", imgPath)
            return true
        }
        return false
    }

    ; Compiled mode: extract from embedded resource, convert to HBITMAP
    hModule := DllCall("LoadLibrary", "str", "gdiplus", "ptr")
    if (!hModule)
        return false

    si := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
    NumPut("UInt", 1, si, 0)
    token := 0
    DllCall("gdiplus\GdiplusStartup", "ptr*", &token, "ptr", si.Ptr, "ptr", 0)
    if (!token) {
        DllCall("FreeLibrary", "ptr", hModule)
        return false
    }

    pBitmap := Splash_LoadBitmapFromResource(RES_ID_LOGO)
    if (!pBitmap) {
        DllCall("gdiplus\GdiplusShutdown", "ptr", token)
        DllCall("FreeLibrary", "ptr", hModule)
        return false
    }

    ; High-quality resize preserving aspect ratio (707x548 -> 116x90)
    pThumb := GdipResizeHQ(pBitmap, 116, 90)
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

    if (!hBitmap)
        return false

    dg.AddPicture("x20 y15 w116 h90", "HBITMAP:*" hBitmap)
    return true
}

; ============================================================
; Subprocess Row Helper
; ============================================================
; Adds a subprocess row: colored dot + label + action button.
; Parameters:
;   dg         - Gui object
;   themeEntry - theme entry for control theming
;   dot        - dot character
;   &subY      - y position (ByRef, not modified - caller manages offsets)
;   prefix     - control name prefix (e.g. "store", "gui")
;   displayName- human label (e.g. "Store", "GUI")
;   pid        - process ID variable to check
;   isCore     - true = red when not running, false = grey when not running
;   clickFn    - function ref for button click handler

_Dash_AddSubprocessRow(dg, themeEntry, dot, &subY, prefix, displayName, pid, isCore, clickFn) {
    global g_DashControls, gTheme_Palette
    isRunning := LauncherUtils_IsRunning(pid)
    notRunningColor := isCore ? gTheme_Palette.danger : gTheme_Palette.textMuted
    dotColor := isRunning ? "c" gTheme_Palette.success : "c" notRunningColor
    dg.SetFont("s9 " dotColor)
    dotCtl := dg.AddText("x400 y" subY " w14", dot)
    Theme_MarkSemantic(dotCtl)
    dg.SetFont("s9 cDefault")
    label := displayName ": " (isRunning ? "Running (PID " pid ")" : "Not running")
    textCtl := dg.AddText("x414 y" subY " w246 +0x100", label)
    btnCtl := dg.AddButton("x680 y" (subY - 4) " w65 h24", isRunning ? "Restart" : "Launch")
    btnCtl.OnEvent("Click", clickFn)
    Theme_ApplyToControl(btnCtl, "Button", themeEntry)
    g_DashControls.%prefix%Dot := dotCtl
    g_DashControls.%prefix%DotColor := dotColor
    g_DashControls.%prefix%Text := textCtl
    g_DashControls.%prefix%Btn := btnCtl
}

; ============================================================
; Info Helpers (read-only, snapshot at dialog-open or refresh)
; ============================================================

_Dash_GetInstallInfo() {
    global cfg, ALTTABBY_INSTALL_DIR

    if (cfg.HasOwnProp("SetupExePath") && cfg.SetupExePath != "") {
        installDir := ""
        SplitPath(cfg.SetupExePath, , &installDir)
        return installDir
    }

    if (InStr(StrLower(A_ScriptDir), StrLower(ALTTABBY_INSTALL_DIR)))
        return A_ScriptDir

    return A_ScriptDir " (portable)"
}

_Dash_GetAdminTaskInfo() {
    if (!AdminTaskExists())
        return "Not configured"

    if (AdminTask_PointsToUs())
        return "Active (points to this exe)"

    taskPath := AdminTask_GetCommandPath()
    if (taskPath != "")
        return "Active (points to: " taskPath ")"

    return "Active (unknown target)"
}

_Dash_GetKomorebiInfo() {
    pid := ProcessExist("komorebi.exe")
    if (pid)
        return "Running (PID " pid ")"
    return "Not running"
}

; ============================================================
; Stats Query (reads stats.ini written by GUI heartbeat)
; ============================================================
; Reads [Snapshot] section from stats.ini for dashboard display.
; Called on dashboard open and periodically during HOT/WARM refresh.

Dash_QueryStats() {
    global g_GuiPID, IPC_WM_STATS_REQUEST

    if (!LauncherUtils_IsRunning(g_GuiPID))
        return

    ; PostMessage (non-blocking) — GUI will respond asynchronously via WM_COPYDATA.
    ; Cannot use SendMessage here: AHK v2 can't dispatch the GUI's WM_COPYDATA
    ; response back to our OnMessage handler while we're blocked in SendMessage.
    DetectHiddenWindows(true)
    guiHwnd := 0
    try guiHwnd := WinGetID("ahk_pid " g_GuiPID)
    if (!guiHwnd) {
        DetectHiddenWindows(false)
        return
    }
    try PostMessage(IPC_WM_STATS_REQUEST, A_ScriptHwnd, 0, , "ahk_id " guiHwnd)
    DetectHiddenWindows(false)
}

; ============================================================
; Stats Format Helpers
; ============================================================

; Safely get a numeric value from a Map (returns 0 if missing or not a Map)
Stats_MapGet(m, key) {
    if (!IsObject(m))
        return 0
    return m.Has(key) ? m[key] : 0
}

; Format seconds into human-readable duration: "5s", "12m", "2h 15m", "3d 4h", "1y 42d"
Stats_FormatDuration(totalSec) {
    totalSec := Integer(totalSec)
    if (totalSec < 60)
        return totalSec "s"
    if (totalSec < 3600) {
        m := Floor(totalSec / 60)
        return m "m"
    }
    h := Floor(totalSec / 3600)
    m := Floor(Mod(totalSec, 3600) / 60)
    if (h >= 24) {
        d := Floor(h / 24)
        if (d >= 365) {
            y := Floor(d / 365)
            rd := Mod(d, 365)
            if (rd > 0)
                return y "y " rd "d"
            return y "y"
        }
        rh := Mod(h, 24)
        if (rh > 0)
            return d "d " rh "h"
        return d "d"
    }
    if (m > 0)
        return h "h " m "m"
    return h "h"
}

; Format an integer with comma separators: 47832 → "47,832"
Stats_FormatNumber(n) {
    s := String(Integer(n))
    len := StrLen(s)
    if (len <= 3)
        return s
    result := ""
    loop len {
        i := len - A_Index + 1
        if (A_Index > 1 && Mod(A_Index - 1, 3) = 0)
            result := "," result
        result := SubStr(s, i, 1) result
    }
    return result
}

; ============================================================
; Tooltip Helpers (Win32 TOOLTIPS_CLASS common control)
; ============================================================

; Create a tooltip control attached to a parent window
Dash_CreateTooltipCtl(hwndParent) {
    hTT := DllCall("CreateWindowEx"
        , "uint", 0x8          ; WS_EX_TOPMOST
        , "str", "tooltips_class32"
        , "str", ""
        , "uint", 0x80000003   ; WS_POPUP | TTS_ALWAYSTIP | TTS_NOPREFIX
        , "int", 0x80000000    ; CW_USEDEFAULT
        , "int", 0x80000000
        , "int", 0x80000000
        , "int", 0x80000000
        , "ptr", hwndParent
        , "ptr", 0, "ptr", 0, "ptr", 0
        , "ptr")
    if (!hTT)
        return 0

    ; Enable multiline tooltips (wrap at 400px)
    DllCall("SendMessage", "ptr", hTT, "uint", 0x418, "ptr", 0, "ptr", 400)  ; TTM_SETMAXTIPWIDTH
    return hTT
}

; Associate a tooltip string with a GUI control
Dash_SetTip(hTT, ctl, text) {
    ; TOOLINFOW struct offsets (platform-dependent)
    ptrOff := A_PtrSize = 8 ? 16 : 12     ; uId
    textOff := A_PtrSize = 8 ? 48 : 36    ; lpszText
    cbSize := A_PtrSize = 8 ? 72 : 48     ; includes lpReserved (COMCTL32 v6)

    ti := Buffer(cbSize, 0)
    NumPut("uint", cbSize, ti, 0)                    ; cbSize
    NumPut("uint", 0x11, ti, 4)                       ; uFlags: TTF_IDISHWND(0x1) | TTF_SUBCLASS(0x10)
    NumPut("ptr", ctl.Gui.Hwnd, ti, 8)               ; hwnd (parent)
    NumPut("uptr", ctl.Hwnd, ti, ptrOff)             ; uId (control hwnd)
    NumPut("ptr", StrPtr(text), ti, textOff)          ; lpszText

    DllCall("SendMessage", "ptr", hTT, "uint", 0x432, "ptr", 0, "ptr", ti.Ptr)  ; TTM_ADDTOOLW
}

; Update an existing tooltip's text (for dynamic button tooltips)
_Dash_UpdateTip(hTT, ctl, text) {
    ptrOff := A_PtrSize = 8 ? 16 : 12
    textOff := A_PtrSize = 8 ? 48 : 36
    cbSize := A_PtrSize = 8 ? 72 : 48

    ti := Buffer(cbSize, 0)
    NumPut("uint", cbSize, ti, 0)
    NumPut("uint", 0x11, ti, 4)                       ; TTF_IDISHWND | TTF_SUBCLASS
    NumPut("ptr", ctl.Gui.Hwnd, ti, 8)
    NumPut("uptr", ctl.Hwnd, ti, ptrOff)
    NumPut("ptr", StrPtr(text), ti, textOff)

    DllCall("SendMessage", "ptr", hTT, "uint", 0x439, "ptr", 0, "ptr", ti.Ptr)  ; TTM_UPDATETIPTEXTW
}

; Get tooltip text for update button based on current state
_Dash_GetUpdateBtnTip() {
    global g_DashUpdateState
    if (g_DashUpdateState.status = "available")
        return "Install version " g_DashUpdateState.version
    if (g_DashUpdateState.status = "checking")
        return "Checking for updates..."
    return "Check GitHub for new versions"
}
