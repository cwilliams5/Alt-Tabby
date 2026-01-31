#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Cross-file globals (cfg, g_StorePID, etc.) come from alt_tabby.ahk

; ============================================================
; Launcher About Dialog
; ============================================================
; Non-blocking About dialog showing version, links, keyboard
; shortcuts, and system information.

global g_AboutGui := 0
global g_AboutShuttingDown := false

ShowAboutDialog() {
    global g_AboutGui, g_AboutShuttingDown, cfg, APP_NAME
    global g_StorePID, g_GuiPID, g_ViewerPID, ALTTABBY_INSTALL_DIR

    ; If already open, focus existing dialog
    if (g_AboutGui) {
        try WinActivate(g_AboutGui)
        return
    }

    g_AboutShuttingDown := false

    aboutGui := Gui("", APP_NAME " - About")
    aboutGui.SetFont("s10", "Segoe UI")
    aboutGui.MarginX := 20
    aboutGui.MarginY := 15

    ; ---- Header: Logo + Title + Version + Links ----
    ; Logo: 707x548 source, scaled to h90 preserving aspect ratio (~116x90)
    logo := _About_LoadLogo(aboutGui)
    xAfterLogo := logo ? 150 : 0  ; 116px logo + 20px margin + 14px gap

    aboutGui.SetFont("s16 Bold")
    aboutGui.AddText("x" xAfterLogo " y15 w260", APP_NAME)

    aboutGui.SetFont("s10 Norm")
    version := GetAppVersion()
    aboutGui.AddText("x" xAfterLogo " y+2 w260", "Version " version)

    aboutGui.AddLink("x" xAfterLogo " y+4 w260",
        '<a href="https://github.com/cwilliams5/Alt-Tabby">github.com/cwilliams5/Alt-Tabby</a>')
    aboutGui.AddLink("x" xAfterLogo " y+2 w260",
        '<a href="https://github.com/cwilliams5/Alt-Tabby/blob/main/docs/options.md">Configuration Options</a>')

    ; ---- Keyboard Shortcuts ----
    aboutGui.SetFont("s10")
    gb1 := aboutGui.AddGroupBox("x20 y+18 w380 h195", "Keyboard Shortcuts")

    yStart := "yp+25"
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
        aboutGui.SetFont("s9 Bold")
        aboutGui.AddText("x35 " yOpt " w130 Right", item[1])
        aboutGui.SetFont("s9 Norm")
        aboutGui.AddText("x175 yp w215", item[2])
    }

    ; ---- System Information ----
    aboutGui.SetFont("s10")
    gb2 := aboutGui.AddGroupBox("x20 y+18 w380 h175", "Diagnostics")

    ; Build info
    buildType := A_IsCompiled ? "Compiled" : "Development"
    elevation := A_IsAdmin ? "Administrator" : "Standard"
    aboutGui.SetFont("s9")
    aboutGui.AddText("x35 yp+25 w355", "Build: " buildType "  |  Elevation: " elevation)

    ; Subprocess status
    storeStatus := LauncherUtils_IsRunning(g_StorePID)
        ? "Running (PID " g_StorePID ")" : "Not running"
    aboutGui.AddText("x35 y+4 w355", "Store: " storeStatus)

    guiStatus := LauncherUtils_IsRunning(g_GuiPID)
        ? "Running (PID " g_GuiPID ")" : "Not running"
    aboutGui.AddText("x35 y+4 w355", "GUI: " guiStatus)

    viewerStatus := LauncherUtils_IsRunning(g_ViewerPID)
        ? "Running (PID " g_ViewerPID ")" : "Not running"
    aboutGui.AddText("x35 y+4 w355", "Viewer: " viewerStatus)

    ; Install location
    installInfo := _About_GetInstallInfo()
    aboutGui.AddText("x35 y+4 w355", "Install: " installInfo)

    ; Admin task status
    adminInfo := _About_GetAdminTaskInfo()
    aboutGui.AddText("x35 y+4 w355", "Admin Task: " adminInfo)

    ; Komorebi status
    komorebiInfo := _About_GetKomorebiInfo()
    aboutGui.AddText("x35 y+4 w355", "Komorebi: " komorebiInfo)

    ; ---- Buttons ----
    aboutGui.SetFont("s10")
    aboutGui.AddButton("x140 y+25 w150", "Check for Updates").OnEvent("Click", _About_OnCheckUpdates)
    btnOK := aboutGui.AddButton("x300 yp w80 Default", "OK")
    btnOK.OnEvent("Click", _About_OnClose)

    ; Close event
    aboutGui.OnEvent("Close", _About_OnClose)
    aboutGui.OnEvent("Escape", _About_OnClose)

    g_AboutGui := aboutGui
    aboutGui.Show("AutoSize")
    btnOK.Focus()  ; Start with OK focused, not the first link
}

_About_LoadLogo(aboutGui) {
    ; Dev mode: load from file
    if (!A_IsCompiled) {
        imgPath := A_ScriptDir "\..\img\logo.png"
        if (FileExist(imgPath)) {
            aboutGui.AddPicture("x20 y15 w116 h90", imgPath)
            return true
        }
        return false
    }

    ; Compiled mode: extract from embedded resource, convert to HBITMAP
    ; Load GDI+ if not already loaded
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
    ; This avoids transparency halos on the Gui background
    bgColor := DllCall("user32\GetSysColor", "int", 15, "uint")  ; COLOR_3DFACE
    ; Convert BGR to ARGB
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

    aboutGui.AddPicture("x20 y15 w116 h90", "HBITMAP:*" hBitmap)
    return true
}

_About_GetInstallInfo() {
    global cfg, ALTTABBY_INSTALL_DIR

    ; Check cfg.SetupExePath first
    if (cfg.HasOwnProp("SetupExePath") && cfg.SetupExePath != "") {
        installDir := ""
        SplitPath(cfg.SetupExePath, , &installDir)
        return installDir
    }

    ; Check if running from well-known install dir
    if (InStr(StrLower(A_ScriptDir), StrLower(ALTTABBY_INSTALL_DIR)))
        return A_ScriptDir

    return A_ScriptDir " (portable)"
}

_About_GetAdminTaskInfo() {
    if (!AdminTaskExists())
        return "Not configured"

    if (_AdminTask_PointsToUs())
        return "Active (points to this exe)"

    taskPath := _AdminTask_GetCommandPath()
    if (taskPath != "")
        return "Active (points to: " taskPath ")"

    return "Active (unknown target)"
}

_About_GetKomorebiInfo() {
    pid := ProcessExist("komorebi.exe")
    if (pid)
        return "Running (PID " pid ")"
    return "Not running"
}

_About_OnClose(*) {
    global g_AboutGui, g_AboutShuttingDown
    g_AboutShuttingDown := true
    if (g_AboutGui) {
        g_AboutGui.Destroy()
        g_AboutGui := 0
    }
}

_About_OnCheckUpdates(*) {
    _About_OnClose()
    CheckForUpdates(true)
}
