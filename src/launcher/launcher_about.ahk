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

ShowDashboardDialog() {
    global g_DashboardGui, g_DashboardShuttingDown, cfg, APP_NAME
    global g_StorePID, g_GuiPID, g_ViewerPID, ALTTABBY_INSTALL_DIR
    global g_ConfigEditorPID, g_BlacklistEditorPID
    global g_DashControls, g_DashUpdateState, DASH_INTERVAL_COOL

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

    dg.AddLink("x" xAfterLogo " y+4 w225",
        '<a href="https://github.com/cwilliams5/Alt-Tabby">github.com/cwilliams5/Alt-Tabby</a>')
    dg.AddLink("x" xAfterLogo " y+2 w225",
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
    dg.AddButton("x400 y113 w170 h26", "Edit Config...").OnEvent("Click", (*) => LaunchConfigEditor())
    dg.AddButton("x580 y113 w170 h26", "Edit Blacklist...").OnEvent("Click", (*) => LaunchBlacklistEditor())

    ; ============================================================
    ; BOTTOM-LEFT - Keyboard Shortcuts
    ; ============================================================
    dg.SetFont("s10")
    dg.AddGroupBox("x20 y150 w350 h265", "Keyboard Shortcuts")

    shortcuts := [
        ["Alt+Tab", "Cycle forward through windows"],
        ["Alt+Shift+Tab", "Cycle backward"],
        ["Ctrl (hold Alt)", "Toggle workspace filter"],
        ["Escape", "Cancel and dismiss overlay"],
        ["Mouse click", "Select and activate window"],
        ["Mouse wheel", "Scroll through windows"],
        ["Alt+Shift+F12", "Exit Alt-Tabby"]
    ]

    for i, item in shortcuts {
        yOpt := (i = 1) ? "y175" : "y+4"
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
    dg.AddText("x400 y175 w240", "Build: " buildType "  |  Elevation: " elevation)

    ; Escalate/De-escalate button
    escalateLabel := A_IsAdmin ? "De-escalate" : "Escalate"
    btnEscalate := dg.AddButton("x660 y171 w85 h24", escalateLabel)
    btnEscalate.OnEvent("Click", _Dash_OnEscalate)

    ; Subprocess rows with buttons — handlers check live state, refresh updates labels
    ; Order: Store, GUI, Config Editor, Blacklist Editor, Viewer

    ; Store row
    subY := 202
    storeRunning := LauncherUtils_IsRunning(g_StorePID)
    storeLabel := storeRunning ? "Store: Running (PID " g_StorePID ")" : "Store: Not running"
    g_DashControls.storeText := dg.AddText("x400 y" subY " w240", storeLabel)
    g_DashControls.storeBtn := dg.AddButton("x680 y" (subY - 4) " w65 h24", storeRunning ? "Restart" : "Launch")
    g_DashControls.storeBtn.OnEvent("Click", _Dash_OnStoreBtn)

    ; GUI row
    subY += 30
    guiRunning := LauncherUtils_IsRunning(g_GuiPID)
    guiLabel := guiRunning ? "GUI: Running (PID " g_GuiPID ")" : "GUI: Not running"
    g_DashControls.guiText := dg.AddText("x400 y" subY " w240", guiLabel)
    g_DashControls.guiBtn := dg.AddButton("x680 y" (subY - 4) " w65 h24", guiRunning ? "Restart" : "Launch")
    g_DashControls.guiBtn.OnEvent("Click", _Dash_OnGuiBtn)

    ; Config Editor row
    subY += 30
    configRunning := LauncherUtils_IsRunning(g_ConfigEditorPID)
    configLabel := configRunning ? "Config Editor: Running (PID " g_ConfigEditorPID ")" : "Config Editor: Not running"
    g_DashControls.configText := dg.AddText("x400 y" subY " w240", configLabel)
    g_DashControls.configBtn := dg.AddButton("x680 y" (subY - 4) " w65 h24", configRunning ? "Restart" : "Launch")
    g_DashControls.configBtn.OnEvent("Click", _Dash_OnConfigBtn)

    ; Blacklist Editor row
    subY += 30
    blacklistRunning := LauncherUtils_IsRunning(g_BlacklistEditorPID)
    blacklistLabel := blacklistRunning ? "Blacklist Editor: Running (PID " g_BlacklistEditorPID ")" : "Blacklist Editor: Not running"
    g_DashControls.blacklistText := dg.AddText("x400 y" subY " w240", blacklistLabel)
    g_DashControls.blacklistBtn := dg.AddButton("x680 y" (subY - 4) " w65 h24", blacklistRunning ? "Restart" : "Launch")
    g_DashControls.blacklistBtn.OnEvent("Click", _Dash_OnBlacklistBtn)

    ; Viewer row
    subY += 30
    viewerRunning := LauncherUtils_IsRunning(g_ViewerPID)
    viewerLabel := viewerRunning ? "Viewer: Running (PID " g_ViewerPID ")" : "Viewer: Not running"
    g_DashControls.viewerText := dg.AddText("x400 y" subY " w240", viewerLabel)
    g_DashControls.viewerBtn := dg.AddButton("x680 y" (subY - 4) " w65 h24", viewerRunning ? "Restart" : "Launch")
    g_DashControls.viewerBtn.OnEvent("Click", _Dash_OnViewerBtn)

    ; Info rows (read-only)
    subY += 28
    dg.AddText("x400 y" subY " w340", "Install: " _Dash_GetInstallInfo())

    subY += 20
    dg.AddText("x400 y" subY " w340", "Admin Task: " _Dash_GetAdminTaskInfo())

    subY += 20
    g_DashControls.komorebiText := dg.AddText("x400 y" subY " w340", "Komorebi: " _Dash_GetKomorebiInfo())

    ; ---- Bottom Row: Update status + OK ----
    dg.SetFont("s9")
    updateLabel := _Dash_GetUpdateLabel()
    g_DashControls.updateText := dg.AddText("x20 y430 w400", updateLabel)
    g_DashControls.updateInstallBtn := dg.AddButton("x430 y425 w65 h24", "Install")
    g_DashControls.updateInstallBtn.OnEvent("Click", _Dash_OnInstallBtn)
    g_DashControls.updateInstallBtn.Visible := (g_DashUpdateState.status = "available")
    g_DashControls.updateCheckBtn := dg.AddButton("x500 y425 w100 h24", "Check Now")
    g_DashControls.updateCheckBtn.OnEvent("Click", _Dash_OnCheckNowBtn)

    dg.SetFont("s10")
    btnOK := dg.AddButton("x675 y425 w80 Default", "OK")
    btnOK.OnEvent("Click", _Dash_OnClose)

    ; Close event
    dg.OnEvent("Close", _Dash_OnClose)
    dg.OnEvent("Escape", _Dash_OnClose)

    g_DashboardGui := dg
    dg.Show("w780")
    btnOK.Focus()

    ; Start background refresh in cool mode (no interaction yet)
    SetTimer(_Dash_RefreshDynamic, DASH_INTERVAL_COOL)

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

_Dash_OnCheckNowBtn(*) {
    global g_DashUpdateState
    g_DashUpdateState.status := "checking"
    g_DashUpdateState.version := ""
    g_DashUpdateState.downloadUrl := ""
    _Dash_StartRefreshTimer()
    SetTimer(_Dash_CheckForUpdatesAsync, -1)
}

_Dash_OnInstallBtn(*) {
    global g_DashUpdateState
    if (g_DashUpdateState.status != "available" || g_DashUpdateState.downloadUrl = "")
        return
    url := g_DashUpdateState.downloadUrl
    ver := g_DashUpdateState.version
    _Dash_OnClose()
    _Update_DownloadAndApply(url, ver)
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
    global g_DashUpdateState
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

    newState := Map(
        "storeText", storeRunning ? "Store: Running (PID " g_StorePID ")" : "Store: Not running",
        "storeBtn", storeRunning ? "Restart" : "Launch",
        "guiText", guiRunning ? "GUI: Running (PID " g_GuiPID ")" : "GUI: Not running",
        "guiBtn", guiRunning ? "Restart" : "Launch",
        "configText", configRunning ? "Config Editor: Running (PID " g_ConfigEditorPID ")" : "Config Editor: Not running",
        "configBtn", configRunning ? "Restart" : "Launch",
        "blacklistText", blacklistRunning ? "Blacklist Editor: Running (PID " g_BlacklistEditorPID ")" : "Blacklist Editor: Not running",
        "blacklistBtn", blacklistRunning ? "Restart" : "Launch",
        "viewerText", viewerRunning ? "Viewer: Running (PID " g_ViewerPID ")" : "Viewer: Not running",
        "viewerBtn", viewerRunning ? "Restart" : "Launch",
        "komorebiText", "Komorebi: " _Dash_GetKomorebiInfo(),
        "chkStartMenu", _Shortcut_StartMenuExists() ? 1 : 0,
        "chkStartup", _Shortcut_StartupExists() ? 1 : 0,
        "chkAutoUpdate", cfg.SetupAutoUpdateCheck ? 1 : 0,
        "updateText", _Dash_GetUpdateLabel(),
        "updateInstallVisible", (g_DashUpdateState.status = "available") ? 1 : 0
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
        || g_DashControls.updateText.Value != newState["updateText"]
        || g_DashControls.updateInstallBtn.Visible != newState["updateInstallVisible"])
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
    g_DashControls.updateText.Value := newState["updateText"]
    g_DashControls.updateInstallBtn.Visible := newState["updateInstallVisible"]

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
