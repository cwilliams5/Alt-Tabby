#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Cross-file globals (cfg, g_StorePID, etc.) come from alt_tabby.ahk

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
global g_LastUpdateCheckTick := 0
global g_DashUpdateState
g_DashUpdateState := {status: "unchecked", version: "", downloadUrl: ""}
global DASH_UPDATE_STALE_MS := 43200000  ; 12 hours

; Producer status cache — queried once after store launch, shown in dashboard
global g_ProducerStatusCache := ""

ShowDashboardDialog() {
    global g_DashboardGui, g_DashboardShuttingDown, cfg, APP_NAME
    global g_StorePID, g_GuiPID, g_ViewerPID, ALTTABBY_INSTALL_DIR
    global g_ConfigEditorPID, g_BlacklistEditorPID
    global g_DashControls, g_DashUpdateState, g_ProducerStatusCache, DASH_INTERVAL_COOL

    ; If already open, focus existing dialog
    if (g_DashboardGui) {
        try WinActivate(g_DashboardGui)
        return
    }

    g_DashboardShuttingDown := false
    g_DashControls := {}

    dg := Gui("", "Alt-Tabby Dashboard")
    dg.SetFont("s10", "Segoe UI")
    dg.MarginX := 20
    dg.MarginY := 15

    ; ---- Header: Logo + Title + Version + Links ----
    logo := _Dash_LoadLogo(dg)
    xAfterLogo := logo ? 150 : 0

    dg.SetFont("s16 Bold")
    dg.AddText("x" xAfterLogo " y15 w225", APP_NAME)

    dg.SetFont("s10 Norm")
    version := GetAppVersion()
    dg.AddText("x" xAfterLogo " y+2 w225", "Version " version)

    lnkGithub := dg.AddLink("x" xAfterLogo " y+4 w225",
        '<a href="https://github.com/cwilliams5/Alt-Tabby">github.com/cwilliams5/Alt-Tabby</a>')
    lnkOptions := dg.AddLink("x" xAfterLogo " y+2 w225",
        '<a href="https://github.com/cwilliams5/Alt-Tabby/blob/main/docs/options.md">Configuration Options</a>')

    ; ============================================================
    ; TOP-RIGHT - Settings
    ; ============================================================
    dg.SetFont("s10")
    dg.AddGroupBox("x385 y10 w375 h130", "Settings")

    ; Checkboxes — refresh timer corrects visual state if underlying toggle fails
    dg.SetFont("s9")

    g_DashControls.chkStartMenu := dg.AddCheckbox("x400 y35 w340", "Add to Start Menu")
    g_DashControls.chkStartMenu.Value := _Shortcut_StartMenuExists() ? 1 : 0
    g_DashControls.chkStartMenu.OnEvent("Click", _Dash_OnStartMenuChk)

    g_DashControls.chkStartup := dg.AddCheckbox("x400 y59 w340", "Run at Startup")
    g_DashControls.chkStartup.Value := _Shortcut_StartupExists() ? 1 : 0
    g_DashControls.chkStartup.OnEvent("Click", _Dash_OnStartupChk)

    g_DashControls.chkAutoUpdate := dg.AddCheckbox("x400 y83 w340", "Auto-check for Updates")
    g_DashControls.chkAutoUpdate.Value := cfg.SetupAutoUpdateCheck ? 1 : 0
    g_DashControls.chkAutoUpdate.OnEvent("Click", _Dash_OnAutoUpdateChk)

    ; Editor buttons
    dg.SetFont("s9")
    btnEditConfig := dg.AddButton("x400 y113 w170 h26", "Edit Config...")
    btnEditConfig.OnEvent("Click", (*) => LaunchConfigEditor())
    btnEditBlacklist := dg.AddButton("x580 y113 w170 h26", "Edit Blacklist...")
    btnEditBlacklist.OnEvent("Click", (*) => LaunchBlacklistEditor())

    ; ============================================================
    ; BOTTOM-LEFT - Keyboard Shortcuts
    ; ============================================================
    dg.SetFont("s10")
    dg.AddGroupBox("x20 y150 w350 h265", "Keyboard Shortcuts")

    ; "Always On" section — global hotkeys that work any time
    dg.SetFont("s9 Bold")
    dg.AddText("x35 y172 w310", "Always On")
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
    dg.AddGroupBox("x385 y150 w375 h265", "Diagnostics")

    ; Build + Elevation row
    buildType := A_IsCompiled ? "Compiled" : "Development"
    elevation := A_IsAdmin ? "Administrator" : "Standard"
    dg.SetFont("s9")
    ctlBuildInfo := dg.AddText("x400 y175 w240 +0x100", "Build: " buildType "  |  Elevation: " elevation)

    ; Escalate/De-escalate button
    escalateLabel := A_IsAdmin ? "De-escalate" : "Escalate"
    btnEscalate := dg.AddButton("x660 y171 w85 h24", escalateLabel)
    btnEscalate.OnEvent("Click", _Dash_OnEscalate)

    ; Subprocess rows with buttons — handlers check live state, refresh updates labels
    ; Order: Store, Producers, GUI, Config Editor, Blacklist Editor, Viewer
    ; Status dots: Chr(0x1F7E2) = green circle, Chr(0x1F534) = red circle
    dotOK := Chr(0x1F7E2)
    dotStop := Chr(0x1F534)

    ; Store row
    subY := 202
    storeRunning := LauncherUtils_IsRunning(g_StorePID)
    storeLabel := (storeRunning ? dotOK : dotStop) " Store: " (storeRunning ? "Running (PID " g_StorePID ")" : "Not running")
    g_DashControls.storeText := dg.AddText("x400 y" subY " w260 +0x100", storeLabel)
    g_DashControls.storeBtn := dg.AddButton("x680 y" (subY - 4) " w65 h24", storeRunning ? "Restart" : "Launch")
    g_DashControls.storeBtn.OnEvent("Click", _Dash_OnStoreBtn)

    ; Producer status line (full-width row, no button)
    subY += 20
    prodLabel := g_ProducerStatusCache != "" ? "Producers: " g_ProducerStatusCache : ""
    g_DashControls.producerText := dg.AddText("x400 y" subY " w275 +0x100", prodLabel)

    ; GUI row
    subY += 18
    guiRunning := LauncherUtils_IsRunning(g_GuiPID)
    guiLabel := (guiRunning ? dotOK : dotStop) " GUI: " (guiRunning ? "Running (PID " g_GuiPID ")" : "Not running")
    g_DashControls.guiText := dg.AddText("x400 y" subY " w260 +0x100", guiLabel)
    g_DashControls.guiBtn := dg.AddButton("x680 y" (subY - 4) " w65 h24", guiRunning ? "Restart" : "Launch")
    g_DashControls.guiBtn.OnEvent("Click", _Dash_OnGuiBtn)

    ; Config Editor row
    subY += 30
    configRunning := LauncherUtils_IsRunning(g_ConfigEditorPID)
    configLabel := (configRunning ? dotOK : dotStop) " Config Editor: " (configRunning ? "Running (PID " g_ConfigEditorPID ")" : "Not running")
    g_DashControls.configText := dg.AddText("x400 y" subY " w260 +0x100", configLabel)
    g_DashControls.configBtn := dg.AddButton("x680 y" (subY - 4) " w65 h24", configRunning ? "Restart" : "Launch")
    g_DashControls.configBtn.OnEvent("Click", _Dash_OnConfigBtn)

    ; Blacklist Editor row
    subY += 30
    blacklistRunning := LauncherUtils_IsRunning(g_BlacklistEditorPID)
    blacklistLabel := (blacklistRunning ? dotOK : dotStop) " Blacklist Editor: " (blacklistRunning ? "Running (PID " g_BlacklistEditorPID ")" : "Not running")
    g_DashControls.blacklistText := dg.AddText("x400 y" subY " w260 +0x100", blacklistLabel)
    g_DashControls.blacklistBtn := dg.AddButton("x680 y" (subY - 4) " w65 h24", blacklistRunning ? "Restart" : "Launch")
    g_DashControls.blacklistBtn.OnEvent("Click", _Dash_OnBlacklistBtn)

    ; Viewer row
    subY += 30
    viewerRunning := LauncherUtils_IsRunning(g_ViewerPID)
    viewerLabel := (viewerRunning ? dotOK : dotStop) " Viewer: " (viewerRunning ? "Running (PID " g_ViewerPID ")" : "Not running")
    g_DashControls.viewerText := dg.AddText("x400 y" subY " w260 +0x100", viewerLabel)
    g_DashControls.viewerBtn := dg.AddButton("x680 y" (subY - 4) " w65 h24", viewerRunning ? "Restart" : "Launch")
    g_DashControls.viewerBtn.OnEvent("Click", _Dash_OnViewerBtn)

    ; Info rows (read-only)
    subY += 28
    ctlInstallInfo := dg.AddText("x400 y" subY " w340 +0x100", "Install: " _Dash_GetInstallInfo())

    subY += 20
    ctlAdminTask := dg.AddText("x400 y" subY " w340 +0x100", "Admin Task: " _Dash_GetAdminTaskInfo())

    subY += 20
    g_DashControls.komorebiText := dg.AddText("x400 y" subY " w340 +0x100", "Komorebi: " _Dash_GetKomorebiInfo())

    ; ---- Bottom Row: action button + update status + OK ----
    dg.SetFont("s9")
    updateBtnLabel := _Dash_GetUpdateBtnLabel()
    g_DashControls.updateBtn := dg.AddButton("x20 y425 w100 h24", updateBtnLabel)
    g_DashControls.updateBtn.OnEvent("Click", _Dash_OnUpdateBtn)
    g_DashControls.updateBtn.Enabled := (g_DashUpdateState.status != "checking")

    updateLabel := _Dash_GetUpdateLabel()
    g_DashControls.updateText := dg.AddText("x130 y430 w300 +0x100", updateLabel)

    dg.SetFont("s10")
    btnOK := dg.AddButton("x675 y425 w80 Default", "OK")
    btnOK.OnEvent("Click", _Dash_OnClose)

    ; Close event
    dg.OnEvent("Close", _Dash_OnClose)
    dg.OnEvent("Escape", _Dash_OnClose)

    ; ---- Tooltips ----
    hTT := _Dash_CreateTooltipCtl(dg.Hwnd)
    g_DashControls.hTooltip := hTT
    if (hTT) {
        ; Header links
        _Dash_SetTip(hTT, lnkGithub, "Open the project page on GitHub")
        _Dash_SetTip(hTT, lnkOptions, "View all configuration options on GitHub")

        ; Settings
        _Dash_SetTip(hTT, g_DashControls.chkStartMenu, "Create a shortcut in the Windows Start Menu")
        _Dash_SetTip(hTT, g_DashControls.chkStartup, "Launch Alt-Tabby automatically when you log in")
        _Dash_SetTip(hTT, g_DashControls.chkAutoUpdate, "Check GitHub for new releases on startup")
        _Dash_SetTip(hTT, btnEditConfig, "Open the configuration file editor")
        _Dash_SetTip(hTT, btnEditBlacklist, "Open the window blacklist editor")

        ; Diagnostics — static tooltips on labels (SS_NOTIFY enables mouse tracking)
        _Dash_SetTip(hTT, ctlBuildInfo
            , "Build type and privilege level`n"
            . "Compiled = running from AltTabby.exe`n"
            . "Development = running from AHK source")
        escalateTip := A_IsAdmin ? "Restart without administrator elevation" : "Restart with administrator elevation (UAC prompt)"
        _Dash_SetTip(hTT, btnEscalate, escalateTip)
        _Dash_SetTip(hTT, g_DashControls.storeText
            , "The WindowStore server tracks all open windows and`n"
            . "serves data to the GUI and other subscribers via named pipes")
        _Dash_SetTip(hTT, g_DashControls.producerText
            , "Status of store data producers`n"
            . "WEH = Window Event Hook (tracks focus, title, window changes)`n"
            . "KS = Komorebi Subscription (workspace events from komorebi)`n"
            . "KL = Komorebi Lite (workspace polling fallback)`n"
            . "IP = Icon Pump (resolves window icons asynchronously)`n"
            . "PP = Process Pump (resolves process names asynchronously)`n"
            . "MRU = MRU Tracker (focus tracking fallback if WEH fails)")
        _Dash_SetTip(hTT, g_DashControls.guiText
            , "The Alt+Tab overlay — handles keyboard hooks,`n"
            . "window selection, and rendering")
        _Dash_SetTip(hTT, g_DashControls.configText
            , "Editor subprocess for modifying config.ini settings")
        _Dash_SetTip(hTT, g_DashControls.blacklistText
            , "Editor subprocess for managing the window filter blacklist")
        _Dash_SetTip(hTT, g_DashControls.viewerText
            , "Debug viewer — displays live window data from the`n"
            . "WindowStore for troubleshooting")
        _Dash_SetTip(hTT, ctlInstallInfo
            , "Directory where Alt-Tabby is installed or running from")
        _Dash_SetTip(hTT, ctlAdminTask
            , "Windows Task Scheduler task that allows Alt-Tabby`n"
            . "to run with administrator privileges without UAC prompts")
        _Dash_SetTip(hTT, g_DashControls.komorebiText
            , "Komorebi tiling window manager — when running,`n"
            . "provides workspace data for filtering and labeling windows")
        _Dash_SetTip(hTT, g_DashControls.updateText, "Update status — auto-checks when stale (12+ hours)")
        _Dash_SetTip(hTT, btnOK, "Close the dashboard")

        ; Dynamic tooltips — must match current button state
        _Dash_SetTip(hTT, g_DashControls.storeBtn, storeRunning ? "Stop and restart the WindowStore" : "Start the WindowStore server")
        _Dash_SetTip(hTT, g_DashControls.guiBtn, guiRunning ? "Stop and restart the GUI overlay" : "Start the GUI overlay")
        _Dash_SetTip(hTT, g_DashControls.configBtn, configRunning ? "Restart the configuration editor" : "Open the configuration editor")
        _Dash_SetTip(hTT, g_DashControls.blacklistBtn, blacklistRunning ? "Restart the blacklist editor" : "Open the blacklist editor")
        _Dash_SetTip(hTT, g_DashControls.viewerBtn, viewerRunning ? "Restart the debug viewer" : "Open the debug viewer")
        _Dash_SetTip(hTT, g_DashControls.updateBtn, _Dash_GetUpdateBtnTip())
    }

    g_DashboardGui := dg
    dg.Show("w780")
    btnOK.Focus()

    ; Start background refresh in cool mode (no interaction yet)
    SetTimer(_Dash_RefreshDynamic, DASH_INTERVAL_COOL)

    ; Query producer status if store is running but cache is empty
    if (LauncherUtils_IsRunning(g_StorePID) && g_ProducerStatusCache = "")
        SetTimer(_Dash_QueryProducerStatus, -2000)

    ; Auto-check if stale (never checked, or >12h ago)
    _Dash_MaybeCheckForUpdates()
}

; ============================================================
; Interaction Handlers — check live state, act, trigger refresh
; ============================================================

_Dash_OnStoreBtn(*) {
    global g_StorePID
    if (LauncherUtils_IsRunning(g_StorePID))
        RestartStore()
    else
        LaunchStore()
}

_Dash_OnGuiBtn(*) {
    global g_GuiPID
    if (LauncherUtils_IsRunning(g_GuiPID))
        RestartGui()
    else
        LaunchGui()
}

_Dash_OnViewerBtn(*) {
    global g_ViewerPID
    if (LauncherUtils_IsRunning(g_ViewerPID))
        RestartViewer()
    else
        LaunchViewer()
}

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
        _Update_DownloadAndApply(url, ver)
    } else {
        ; Check mode — trigger async version check
        g_DashUpdateState.status := "checking"
        g_DashUpdateState.version := ""
        g_DashUpdateState.downloadUrl := ""
        _Dash_StartRefreshTimer()
        SetTimer(_Dash_CheckForUpdatesAsync, -1)
    }
}

_Dash_OnClose(*) {
    global g_DashboardGui, g_DashboardShuttingDown, g_DashControls
    g_DashboardShuttingDown := true
    SetTimer(_Dash_RefreshDynamic, 0)
    if (g_DashboardGui) {
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

_Dash_StartRefreshTimer() {
    global g_DashboardGui, g_DashRefreshTick, DASH_INTERVAL_HOT
    if (!g_DashboardGui)
        return
    g_DashRefreshTick := A_TickCount
    SetTimer(_Dash_RefreshDynamic, DASH_INTERVAL_HOT)
}

_Dash_RefreshDynamic() {
    global g_DashboardGui, g_DashControls, g_DashRefreshTick
    global g_StorePID, g_GuiPID, g_ViewerPID, cfg
    global g_ConfigEditorPID, g_BlacklistEditorPID
    global g_DashUpdateState, g_ProducerStatusCache
    global DASH_INTERVAL_HOT, DASH_INTERVAL_WARM, DASH_INTERVAL_COOL
    global DASH_TIER_HOT_MS, DASH_TIER_WARM_MS

    ; Stop if dialog closed
    if (!g_DashboardGui) {
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

    ; Build new state snapshot — compute all values before touching any controls
    storeRunning := LauncherUtils_IsRunning(g_StorePID)
    guiRunning := LauncherUtils_IsRunning(g_GuiPID)
    viewerRunning := LauncherUtils_IsRunning(g_ViewerPID)
    configRunning := LauncherUtils_IsRunning(g_ConfigEditorPID)
    blacklistRunning := LauncherUtils_IsRunning(g_BlacklistEditorPID)

    dotOK := Chr(0x1F7E2)
    dotStop := Chr(0x1F534)

    newState := Map(
        "storeText", (storeRunning ? dotOK : dotStop) " Store: " (storeRunning ? "Running (PID " g_StorePID ")" : "Not running"),
        "storeBtn", storeRunning ? "Restart" : "Launch",
        "guiText", (guiRunning ? dotOK : dotStop) " GUI: " (guiRunning ? "Running (PID " g_GuiPID ")" : "Not running"),
        "guiBtn", guiRunning ? "Restart" : "Launch",
        "configText", (configRunning ? dotOK : dotStop) " Config Editor: " (configRunning ? "Running (PID " g_ConfigEditorPID ")" : "Not running"),
        "configBtn", configRunning ? "Restart" : "Launch",
        "blacklistText", (blacklistRunning ? dotOK : dotStop) " Blacklist Editor: " (blacklistRunning ? "Running (PID " g_BlacklistEditorPID ")" : "Not running"),
        "blacklistBtn", blacklistRunning ? "Restart" : "Launch",
        "viewerText", (viewerRunning ? dotOK : dotStop) " Viewer: " (viewerRunning ? "Running (PID " g_ViewerPID ")" : "Not running"),
        "viewerBtn", viewerRunning ? "Restart" : "Launch",
        "komorebiText", "Komorebi: " _Dash_GetKomorebiInfo(),
        "chkStartMenu", _Shortcut_StartMenuExists() ? 1 : 0,
        "chkStartup", _Shortcut_StartupExists() ? 1 : 0,
        "chkAutoUpdate", cfg.SetupAutoUpdateCheck ? 1 : 0,
        "producerText", g_ProducerStatusCache != "" ? "Producers: " g_ProducerStatusCache : "",
        "updateText", _Dash_GetUpdateLabel(),
        "updateBtn", _Dash_GetUpdateBtnLabel(),
        "updateBtnEnabled", (g_DashUpdateState.status != "checking") ? 1 : 0
    )

    ; Diff against current control values — skip redraw if nothing changed
    changed := false
    if (g_DashControls.storeText.Value != newState["storeText"]
        || g_DashControls.storeBtn.Text != newState["storeBtn"]
        || g_DashControls.guiText.Value != newState["guiText"]
        || g_DashControls.guiBtn.Text != newState["guiBtn"]
        || g_DashControls.configText.Value != newState["configText"]
        || g_DashControls.configBtn.Text != newState["configBtn"]
        || g_DashControls.blacklistText.Value != newState["blacklistText"]
        || g_DashControls.blacklistBtn.Text != newState["blacklistBtn"]
        || g_DashControls.viewerText.Value != newState["viewerText"]
        || g_DashControls.viewerBtn.Text != newState["viewerBtn"]
        || g_DashControls.komorebiText.Value != newState["komorebiText"]
        || g_DashControls.chkStartMenu.Value != newState["chkStartMenu"]
        || g_DashControls.chkStartup.Value != newState["chkStartup"]
        || g_DashControls.chkAutoUpdate.Value != newState["chkAutoUpdate"]
        || g_DashControls.producerText.Value != newState["producerText"]
        || g_DashControls.updateText.Value != newState["updateText"]
        || g_DashControls.updateBtn.Text != newState["updateBtn"]
        || g_DashControls.updateBtn.Enabled != newState["updateBtnEnabled"])
        changed := true

    if (!changed)
        return

    ; Suppress repaints while updating controls
    hWnd := g_DashboardGui.Hwnd
    DllCall("user32\SendMessage", "ptr", hWnd, "uint", 0xB, "ptr", 0, "ptr", 0)  ; WM_SETREDRAW FALSE

    g_DashControls.storeText.Value := newState["storeText"]
    g_DashControls.storeBtn.Text := newState["storeBtn"]
    g_DashControls.guiText.Value := newState["guiText"]
    g_DashControls.guiBtn.Text := newState["guiBtn"]
    g_DashControls.configText.Value := newState["configText"]
    g_DashControls.configBtn.Text := newState["configBtn"]
    g_DashControls.blacklistText.Value := newState["blacklistText"]
    g_DashControls.blacklistBtn.Text := newState["blacklistBtn"]
    g_DashControls.viewerText.Value := newState["viewerText"]
    g_DashControls.viewerBtn.Text := newState["viewerBtn"]
    g_DashControls.komorebiText.Value := newState["komorebiText"]
    g_DashControls.chkStartMenu.Value := newState["chkStartMenu"]
    g_DashControls.chkStartup.Value := newState["chkStartup"]
    g_DashControls.chkAutoUpdate.Value := newState["chkAutoUpdate"]
    g_DashControls.producerText.Value := newState["producerText"]
    g_DashControls.updateText.Value := newState["updateText"]
    g_DashControls.updateBtn.Text := newState["updateBtn"]
    g_DashControls.updateBtn.Enabled := newState["updateBtnEnabled"]

    ; Update dynamic tooltips to match button state
    if (g_DashControls.HasOwnProp("hTooltip") && g_DashControls.hTooltip) {
        hTT := g_DashControls.hTooltip
        _Dash_UpdateTip(hTT, g_DashControls.storeBtn, storeRunning ? "Stop and restart the WindowStore" : "Start the WindowStore server")
        _Dash_UpdateTip(hTT, g_DashControls.guiBtn, guiRunning ? "Stop and restart the GUI overlay" : "Start the GUI overlay")
        _Dash_UpdateTip(hTT, g_DashControls.configBtn, configRunning ? "Restart the configuration editor" : "Open the configuration editor")
        _Dash_UpdateTip(hTT, g_DashControls.blacklistBtn, blacklistRunning ? "Restart the blacklist editor" : "Open the blacklist editor")
        _Dash_UpdateTip(hTT, g_DashControls.viewerBtn, viewerRunning ? "Restart the debug viewer" : "Open the debug viewer")
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
        _Dash_StartRefreshTimer()
        SetTimer(_Dash_CheckForUpdatesAsync, -1)
    }
}

_Dash_CheckForUpdatesAsync() {
    global g_DashUpdateState, g_LastUpdateCheckTick, g_DashboardGui

    currentVersion := GetAppVersion()
    apiUrl := "https://api.github.com/repos/cwilliams5/Alt-Tabby/releases/latest"
    whr := ""

    try {
        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.Open("GET", apiUrl, false)
        whr.SetRequestHeader("User-Agent", "Alt-Tabby/" currentVersion)
        whr.Send()

        if (whr.Status = 200) {
            response := whr.ResponseText
            whr := ""  ; Release COM before processing

            if (!RegExMatch(response, '"tag_name"\s*:\s*"v?([^"]+)"', &tagMatch)) {
                g_DashUpdateState.status := "error"
                g_LastUpdateCheckTick := A_TickCount
                _Dash_StartRefreshTimer()
                return
            }

            latestVersion := tagMatch[1]
            g_LastUpdateCheckTick := A_TickCount

            if (CompareVersions(latestVersion, currentVersion) > 0) {
                g_DashUpdateState.status := "available"
                g_DashUpdateState.version := latestVersion
                g_DashUpdateState.downloadUrl := _Update_FindExeDownloadUrl(response)
            } else {
                g_DashUpdateState.status := "uptodate"
                g_DashUpdateState.version := ""
                g_DashUpdateState.downloadUrl := ""
            }
        } else {
            g_DashUpdateState.status := "error"
            g_LastUpdateCheckTick := A_TickCount
        }
    } catch {
        whr := ""
        g_DashUpdateState.status := "error"
        g_LastUpdateCheckTick := A_TickCount
    }
    whr := ""  ; Final safety

    ; Trigger refresh if dashboard still open
    if (g_DashboardGui)
        _Dash_StartRefreshTimer()
}

; ============================================================
; Logo Loader
; ============================================================

_Dash_LoadLogo(dg) {
    ; Dev mode: load from file
    if (!A_IsCompiled) {
        imgPath := A_ScriptDir "\..\img\logo.png"
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

    pBitmap := _Splash_LoadBitmapFromResource(10)
    if (!pBitmap) {
        DllCall("gdiplus\GdiplusShutdown", "ptr", token)
        DllCall("FreeLibrary", "ptr", hModule)
        return false
    }

    ; Create thumbnail preserving aspect ratio (707x548 -> 116x90)
    pThumb := 0
    DllCall("gdiplus\GdipGetImageThumbnail", "ptr", pBitmap, "uint", 116, "uint", 90, "ptr*", &pThumb, "ptr", 0, "ptr", 0)
    srcBitmap := pThumb ? pThumb : pBitmap

    ; Convert to HBITMAP with system button face color as background
    bgColor := DllCall("user32\GetSysColor", "int", 15, "uint")  ; COLOR_3DFACE
    r := (bgColor & 0xFF)
    g := (bgColor >> 8) & 0xFF
    b := (bgColor >> 16) & 0xFF
    argbBg := 0xFF000000 | (r << 16) | (g << 8) | b

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

    if (_AdminTask_PointsToUs())
        return "Active (points to this exe)"

    taskPath := _AdminTask_GetCommandPath()
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
; Producer Status Query (one-shot IPC to store)
; ============================================================
; Connects to store pipe, requests producer status, caches result.
; Called on a delayed timer after store launch/restart.

_Dash_QueryProducerStatus() {
    global g_ProducerStatusCache, cfg
    global IPC_MSG_PRODUCER_STATUS_REQUEST, IPC_MSG_PRODUCER_STATUS

    pipeName := cfg.StorePipeName
    g_ProducerStatusCache := ""

    ; One-shot IPC: connect, send request, read response, disconnect
    client := IPC_PipeClient_Connect(pipeName, (*) => 0, 2000)
    if (!client.hPipe)
        return

    ; Stop the client's internal read timer BEFORE sending to prevent it
    ; from consuming our response via the no-op callback
    if (client.timerFn)
        SetTimer(client.timerFn, 0)

    ; Send producer status request
    msg := '{"type":"' IPC_MSG_PRODUCER_STATUS_REQUEST '"}'
    IPC_PipeClient_Send(client, msg)

    ; Poll with PeekNamedPipe (non-blocking) then ReadFile when data arrives
    readBuf := Buffer(4096, 0)
    bytesRead := 0
    response := ""
    startTick := A_TickCount
    while ((A_TickCount - startTick) < 3000) {
        bytesAvail := 0
        DllCall("kernel32\PeekNamedPipe"
            , "ptr", client.hPipe
            , "ptr", 0, "uint", 0, "ptr", 0
            , "uint*", &bytesAvail
            , "ptr", 0)
        if (bytesAvail > 0) {
            result := DllCall("kernel32\ReadFile"
                , "ptr", client.hPipe
                , "ptr", readBuf.Ptr
                , "uint", 4096
                , "uint*", &bytesRead
                , "ptr", 0
                , "int")
            if (result && bytesRead > 0) {
                response := StrGet(readBuf, bytesRead, "UTF-8")
                break
            }
        }
        Sleep(50)
    }

    IPC_PipeClient_Close(client)

    if (response = "")
        return

    ; Parse response — may contain multiple newline-delimited messages
    ; (hello/snapshot may arrive before producer_status)
    for _, line in StrSplit(response, "`n") {
        line := Trim(line, " `t`r")
        if (line = "")
            continue
        try {
            obj := JSON.Load(line)
            if (obj.Has("type") && obj["type"] = IPC_MSG_PRODUCER_STATUS && obj.Has("producers")) {
                g_ProducerStatusCache := _Dash_FormatProducerStatus(obj["producers"])
                _Dash_StartRefreshTimer()
                return
            }
        }
    }
}

; Format producer states with colored dots: "🟢WEH 🟢KS 🟢IP 🟢PP"
; Disabled producers omitted, MRU only shown if active (fallback)
_Dash_FormatProducerStatus(producers) {
    dotOK := Chr(0x1F7E2)
    dotFail := Chr(0x1F534)

    abbrevs := [
        ["WEH", "wineventHook"],
        ["MRU", "mruLite"],
        ["KS", "komorebiSub"],
        ["KL", "komorebiLite"],
        ["IP", "iconPump"],
        ["PP", "procPump"]
    ]

    parts := []
    for _, pair in abbrevs {
        abbrev := pair[1]
        name := pair[2]
        state := ""
        if (producers is Map) {
            if (producers.Has(name))
                state := producers[name]
        } else {
            try {
                if (producers.HasOwnProp(name))
                    state := producers.%name%
            }
        }
        if (state = "running")
            parts.Push(dotOK abbrev)
        else if (state = "failed")
            parts.Push(dotFail abbrev)
        ; Skip disabled — keeps line compact
    }

    result := ""
    for _, part in parts
        result .= (result ? " " : "") part
    return result
}

; ============================================================
; Tooltip Helpers (Win32 TOOLTIPS_CLASS common control)
; ============================================================

; Create a tooltip control attached to a parent window
_Dash_CreateTooltipCtl(hwndParent) {
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
_Dash_SetTip(hTT, ctl, text) {
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
