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
;   Hot  (0-15s after click)  500ms  — catch subprocess settle
;   Warm (15-75s)             3s     — catch slower changes
;   Cool (75s+ / idle)        30s    — prevent deep staleness

global g_DashboardGui := 0
global g_DashboardShuttingDown := false
global g_DashControls := {}
global g_DashRefreshTick := 0
global DASH_INTERVAL_HOT := 500
global DASH_INTERVAL_WARM := 3000
global DASH_INTERVAL_COOL := 30000
global DASH_TIER_HOT_MS := 15000
global DASH_TIER_WARM_MS := 75000

ShowDashboardDialog() {
    global g_DashboardGui, g_DashboardShuttingDown, cfg, APP_NAME
    global g_StorePID, g_GuiPID, g_ViewerPID, ALTTABBY_INSTALL_DIR
    global g_DashControls, DASH_INTERVAL_COOL

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
    dg.AddText("x" xAfterLogo " y15 w260", APP_NAME)

    dg.SetFont("s10 Norm")
    version := GetAppVersion()
    dg.AddText("x" xAfterLogo " y+2 w260", "Version " version)

    dg.AddLink("x" xAfterLogo " y+4 w260",
        '<a href="https://github.com/cwilliams5/Alt-Tabby">github.com/cwilliams5/Alt-Tabby</a>')
    dg.AddLink("x" xAfterLogo " y+2 w260",
        '<a href="https://github.com/cwilliams5/Alt-Tabby/blob/main/docs/options.md">Configuration Options</a>')

    ; ---- Two-Column Layout ----
    ; Left column: x=20, w=350  |  Gap: 15px  |  Right column: x=385, w=375
    ; Both columns start at same Y after header
    colY := 120  ; Y position below header

    ; ============================================================
    ; LEFT COLUMN - Keyboard Shortcuts
    ; ============================================================
    dg.SetFont("s10")
    dg.AddGroupBox("x20 y" colY " w350 h365", "Keyboard Shortcuts")

    yStart := "y" (colY + 25)
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
        yOpt := (i = 1) ? yStart : "y+4"
        dg.SetFont("s9 Bold")
        dg.AddText("x35 " yOpt " w130 Right", item[1])
        dg.SetFont("s9 Norm")
        dg.AddText("x175 yp w185", item[2])
    }

    ; ============================================================
    ; RIGHT COLUMN - Diagnostics + Settings
    ; ============================================================

    ; ---- Diagnostics GroupBox ----
    dg.SetFont("s10")
    dg.AddGroupBox("x385 y" colY " w375 h225", "Diagnostics")

    ; Build + Elevation row
    buildType := A_IsCompiled ? "Compiled" : "Development"
    elevation := A_IsAdmin ? "Administrator" : "Standard"
    dg.SetFont("s9")
    dg.AddText("x400 y" (colY + 25) " w240", "Build: " buildType "  |  Elevation: " elevation)

    ; Escalate/De-escalate button
    escalateLabel := A_IsAdmin ? "De-escalate" : "Escalate"
    btnEscalate := dg.AddButton("x660 y" (colY + 21) " w85 h24", escalateLabel)
    btnEscalate.OnEvent("Click", _Dash_OnEscalate)

    ; Subprocess rows with buttons — handlers check live state, refresh updates labels
    subY := colY + 52

    ; Store row
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

    ; Viewer row
    subY += 30
    viewerRunning := LauncherUtils_IsRunning(g_ViewerPID)
    viewerLabel := viewerRunning ? "Viewer: Running (PID " g_ViewerPID ")" : "Viewer: Not running"
    g_DashControls.viewerText := dg.AddText("x400 y" subY " w240", viewerLabel)
    g_DashControls.viewerBtn := dg.AddButton("x680 y" (subY - 4) " w65 h24", viewerRunning ? "Restart" : "Launch")
    g_DashControls.viewerBtn.OnEvent("Click", _Dash_OnViewerBtn)

    ; Restart All button
    subY += 30
    dg.AddButton("x660 y" (subY - 2) " w85 h24", "Restart All").OnEvent("Click", _Dash_OnRestartAllBtn)

    ; Info rows (read-only)
    subY += 28
    dg.AddText("x400 y" subY " w340", "Install: " _Dash_GetInstallInfo())

    subY += 20
    dg.AddText("x400 y" subY " w340", "Admin Task: " _Dash_GetAdminTaskInfo())

    subY += 20
    g_DashControls.komorebiText := dg.AddText("x400 y" subY " w340", "Komorebi: " _Dash_GetKomorebiInfo())

    ; ---- Settings GroupBox ----
    settingsY := colY + 235
    dg.SetFont("s10")
    dg.AddGroupBox("x385 y" settingsY " w375 h130", "Settings")

    ; Checkboxes — refresh timer corrects visual state if underlying toggle fails
    dg.SetFont("s9")
    chkY := settingsY + 25

    g_DashControls.chkStartMenu := dg.AddCheckbox("x400 y" chkY " w340", "Add to Start Menu")
    g_DashControls.chkStartMenu.Value := _Shortcut_StartMenuExists() ? 1 : 0
    g_DashControls.chkStartMenu.OnEvent("Click", _Dash_OnStartMenuChk)

    chkY += 24
    g_DashControls.chkStartup := dg.AddCheckbox("x400 y" chkY " w340", "Run at Startup")
    g_DashControls.chkStartup.Value := _Shortcut_StartupExists() ? 1 : 0
    g_DashControls.chkStartup.OnEvent("Click", _Dash_OnStartupChk)

    chkY += 24
    g_DashControls.chkAutoUpdate := dg.AddCheckbox("x400 y" chkY " w340", "Auto-check for Updates")
    g_DashControls.chkAutoUpdate.Value := cfg.SetupAutoUpdateCheck ? 1 : 0
    g_DashControls.chkAutoUpdate.OnEvent("Click", _Dash_OnAutoUpdateChk)

    ; Editor buttons
    chkY += 30
    dg.SetFont("s9")
    dg.AddButton("x400 y" chkY " w170 h26", "Edit Config...").OnEvent("Click", (*) => LaunchConfigEditor())
    dg.AddButton("x580 y" chkY " w170 h26", "Edit Blacklist...").OnEvent("Click", (*) => LaunchBlacklistEditor())

    ; ---- Bottom Buttons ----
    bottomY := colY + 375
    dg.SetFont("s10")
    dg.AddButton("x20 y" bottomY " w150", "Check for Updates").OnEvent("Click", _Dash_OnCheckUpdates)
    btnOK := dg.AddButton("x675 yp w80 Default", "OK")
    btnOK.OnEvent("Click", _Dash_OnClose)

    ; Close event
    dg.OnEvent("Close", _Dash_OnClose)
    dg.OnEvent("Escape", _Dash_OnClose)

    g_DashboardGui := dg
    dg.Show("w780")
    btnOK.Focus()

    ; Start background refresh in cool mode (no interaction yet)
    SetTimer(_Dash_RefreshDynamic, DASH_INTERVAL_COOL)
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
    _Dash_StartRefreshTimer()
}

_Dash_OnGuiBtn(*) {
    global g_GuiPID
    if (LauncherUtils_IsRunning(g_GuiPID))
        RestartGui()
    else
        LaunchGui()
    _Dash_StartRefreshTimer()
}

_Dash_OnViewerBtn(*) {
    global g_ViewerPID
    if (LauncherUtils_IsRunning(g_ViewerPID))
        RestartViewer()
    else
        LaunchViewer()
    _Dash_StartRefreshTimer()
}

_Dash_OnRestartAllBtn(*) {
    RestartAll()
    _Dash_StartRefreshTimer()
}

_Dash_OnStartMenuChk(*) {
    ToggleStartMenuShortcut()
    _Dash_StartRefreshTimer()
}

_Dash_OnStartupChk(*) {
    ToggleStartupShortcut()
    _Dash_StartRefreshTimer()
}

_Dash_OnAutoUpdateChk(*) {
    ToggleAutoUpdate()
    _Dash_StartRefreshTimer()
}

_Dash_OnEscalate(*) {
    _Dash_OnClose()
    ToggleAdminMode()
}

_Dash_OnCheckUpdates(*) {
    _Dash_OnClose()
    CheckForUpdates(true)
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
; hot (500ms), decays to warm (3s) then cool (30s).

_Dash_StartRefreshTimer() {
    global g_DashRefreshTick, DASH_INTERVAL_HOT
    g_DashRefreshTick := A_TickCount
    SetTimer(_Dash_RefreshDynamic, DASH_INTERVAL_HOT)
}

_Dash_RefreshDynamic() {
    global g_DashboardGui, g_DashControls, g_DashRefreshTick
    global g_StorePID, g_GuiPID, g_ViewerPID, cfg
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

    newState := Map(
        "storeText", storeRunning ? "Store: Running (PID " g_StorePID ")" : "Store: Not running",
        "storeBtn", storeRunning ? "Restart" : "Launch",
        "guiText", guiRunning ? "GUI: Running (PID " g_GuiPID ")" : "GUI: Not running",
        "guiBtn", guiRunning ? "Restart" : "Launch",
        "viewerText", viewerRunning ? "Viewer: Running (PID " g_ViewerPID ")" : "Viewer: Not running",
        "viewerBtn", viewerRunning ? "Restart" : "Launch",
        "komorebiText", "Komorebi: " _Dash_GetKomorebiInfo(),
        "chkStartMenu", _Shortcut_StartMenuExists() ? 1 : 0,
        "chkStartup", _Shortcut_StartupExists() ? 1 : 0,
        "chkAutoUpdate", cfg.SetupAutoUpdateCheck ? 1 : 0
    )

    ; Diff against current control values — skip redraw if nothing changed
    changed := false
    if (g_DashControls.storeText.Value != newState["storeText"]
        || g_DashControls.storeBtn.Text != newState["storeBtn"]
        || g_DashControls.guiText.Value != newState["guiText"]
        || g_DashControls.guiBtn.Text != newState["guiBtn"]
        || g_DashControls.viewerText.Value != newState["viewerText"]
        || g_DashControls.viewerBtn.Text != newState["viewerBtn"]
        || g_DashControls.komorebiText.Value != newState["komorebiText"]
        || g_DashControls.chkStartMenu.Value != newState["chkStartMenu"]
        || g_DashControls.chkStartup.Value != newState["chkStartup"]
        || g_DashControls.chkAutoUpdate.Value != newState["chkAutoUpdate"])
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
    g_DashControls.viewerText.Value := newState["viewerText"]
    g_DashControls.viewerBtn.Text := newState["viewerBtn"]
    g_DashControls.komorebiText.Value := newState["komorebiText"]
    g_DashControls.chkStartMenu.Value := newState["chkStartMenu"]
    g_DashControls.chkStartup.Value := newState["chkStartup"]
    g_DashControls.chkAutoUpdate.Value := newState["chkAutoUpdate"]

    ; Re-enable repaints and force a single
    DllCall("user32\SendMessage", "ptr", hWnd, "uint", 0xB, "ptr", 1, "ptr", 0)  ; WM_SETREDRAW TRUE
    DllCall("user32\RedrawWindow", "ptr", hWnd, "ptr", 0, "ptr", 0, "uint", 0x0107)  ; RDW_INVALIDATE|RDW_ERASE|RDW_UPDATENOW
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
