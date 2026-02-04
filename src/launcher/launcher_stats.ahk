#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Cross-file globals (cfg, g_StatsCache, etc.) come from alt_tabby.ahk

; ============================================================
; Launcher Stats - Detailed Statistics Dialog
; ============================================================
; Full stats screen showing all lifetime, session, and derived
; statistics. Opened from the dashboard "More Stats" button.

global g_StatsGui := 0
global g_StatsControls := Map()  ; key -> control reference for in-place refresh

ShowStatsDialog() {
    global g_StatsGui, g_StatsControls, g_StatsCache, cfg, g_StorePID

    ; If already open, focus existing dialog
    if (g_StatsGui) {
        try WinActivate(g_StatsGui)
        return
    }

    ; Query fresh stats if store is running
    if (LauncherUtils_IsRunning(g_StorePID))
        _Dash_QueryStats()

    sg := Gui("", "Alt-Tabby Statistics")
    sg.SetFont("s10", "Segoe UI")
    sg.MarginX := 20
    sg.MarginY := 15

    ; Check if tracking is enabled
    if (!cfg.StatsTrackingEnabled) {
        sg.AddText("w400", "Statistics tracking is disabled.")
        sg.AddText("w400 y+4 cGray", "Enable via Edit Config > Diagnostics > StatsTracking")
        sg.SetFont("s10")
        btnClose := sg.AddButton("w80 y+20 Default", "Close")
        btnClose.OnEvent("Click", (*) => _StatsDialog_Close())
        sg.OnEvent("Close", (*) => _StatsDialog_Close())
        sg.OnEvent("Escape", (*) => _StatsDialog_Close())
        g_StatsGui := sg
        sg.Show("w440")
        return
    }

    g_StatsControls := Map()

    ; Create Win32 tooltip control (SS_NOTIFY + tooltips_class32, same as dashboard)
    hTT := _Dash_CreateTooltipCtl(sg.Hwnd)

    ; ---- Lifetime Stats (left column) ----
    sg.AddGroupBox("x20 y10 w260 h310", "Lifetime")
    sg.SetFont("s9")

    yPos := 35
    lifetimeKeys := [
        ["Run Time", "lifetime_RunTime", "Total time Alt-Tabby has been running across all sessions"],
        ["Sessions", "lifetime_Sessions", "Number of times Alt-Tabby has been launched"],
        ["Alt-Tab Activations", "lifetime_AltTabs", "Times you opened the Alt-Tab overlay and switched windows"],
        ["Quick Switches", "lifetime_QuickSwitches", "Fast Alt+Tab taps that switched without showing the overlay"],
        ["Tab Steps", "lifetime_TabSteps", "Total Tab presses while the overlay was open"],
        ["Cancellations", "lifetime_Cancellations", "Times you opened the overlay but pressed Escape to cancel"],
        ["Cross-Workspace", "lifetime_CrossWorkspace", "Window switches that crossed komorebi workspaces"],
        ["Workspace Toggles", "lifetime_WorkspaceToggles", "Direct workspace switches via the overlay workspace bar"],
        ["Window Updates", "lifetime_WindowUpdates", "Window create/destroy/change events processed by the store"],
        ["Blacklist Skips", "lifetime_BlacklistSkips", "Windows excluded from the overlay by blacklist rules"],
        ["Peak Windows", "lifetime_PeakWindows", "Highest number of windows tracked at once in any session"],
        ["Longest Session", "lifetime_LongestSession", "Duration of the longest single run of Alt-Tabby"]
    ]

    for _, row in lifetimeKeys {
        lbl := sg.AddText("x35 y" yPos " w130 Right +0x100", row[1] ":")
        if (hTT)
            _Dash_SetTip(hTT, lbl, row[3])
        ctrl := sg.AddText("x170 y" yPos " w100", "")
        g_StatsControls[row[2]] := ctrl
        yPos += 22
    }

    ; ---- This Session (right column) ----
    sg.SetFont("s10")
    sg.AddGroupBox("x295 y10 w260 h310", "This Session")
    sg.SetFont("s9")

    yPos := 35
    sessionKeys := [
        ["Run Time", "session_RunTime", "How long Alt-Tabby has been running this session"],
        ["Alt-Tabs", "session_AltTabs", "Window switches via the overlay this session"],
        ["Quick Switches", "session_QuickSwitches", "Fast Alt+Tab switches without showing the overlay"],
        ["Tab Steps", "session_TabSteps", "Tab presses while the overlay was open"],
        ["Cancellations", "session_Cancellations", "Times you cancelled out of the overlay with Escape"],
        ["Cross-Workspace", "session_CrossWorkspace", "Switches that crossed komorebi workspaces"],
        ["Workspace Toggles", "session_WorkspaceToggles", "Direct workspace switches via the workspace bar"],
        ["Window Updates", "session_WindowUpdates", "Window events processed by the store this session"],
        ["Blacklist Skips", "session_BlacklistSkips", "Windows excluded by blacklist rules this session"],
        ["Peak Windows", "session_PeakWindows", "Most windows tracked at once this session"]
    ]

    for _, row in sessionKeys {
        lbl := sg.AddText("x310 y" yPos " w130 Right +0x100", row[1] ":")
        if (hTT)
            _Dash_SetTip(hTT, lbl, row[3])
        ctrl := sg.AddText("x445 y" yPos " w100", "")
        g_StatsControls[row[2]] := ctrl
        yPos += 22
    }

    ; ---- Insights (left column, same width as Lifetime) ----
    sg.SetFont("s10")
    sg.AddGroupBox("x20 y330 w260 h118", "Insights")
    sg.SetFont("s9")

    yPos := 355
    insightKeys := [
        ["Avg Alt-Tabs / Hour", "insight_AvgPerHour", "Average number of Alt-Tab activations per hour of run time"],
        ["Quick Switch Rate", "insight_QuickPct", "Percentage of switches that were quick (no overlay shown)"],
        ["Cancel Rate", "insight_CancelRate", "Percentage of overlay opens that were cancelled with Escape"],
        ["Avg Tabs per Switch", "insight_AvgTabs", "Average number of Tab presses per overlay activation"]
    ]

    for _, row in insightKeys {
        lbl := sg.AddText("x35 y" yPos " w150 Right +0x100", row[1] ":")
        if (hTT)
            _Dash_SetTip(hTT, lbl, row[3])
        ctrl := sg.AddText("x190 y" yPos " w80", "")
        g_StatsControls[row[2]] := ctrl
        yPos += 22
    }

    ; ---- Icon (right of Insights, beneath This Session) ----
    _StatsDialog_LoadIcon(sg)

    ; ---- Buttons ----
    sg.SetFont("s10")
    btnRefresh := sg.AddButton("x380 y480 w85 h28", "Refresh")
    btnRefresh.OnEvent("Click", (*) => _StatsDialog_Refresh())
    btnClose := sg.AddButton("x470 y480 w85 h28 Default", "Close")
    btnClose.OnEvent("Click", (*) => _StatsDialog_Close())

    sg.OnEvent("Close", (*) => _StatsDialog_Close())
    sg.OnEvent("Escape", (*) => _StatsDialog_Close())

    g_StatsGui := sg

    ; Populate values before showing
    _StatsDialog_UpdateValues()

    sg.Show("w575")
}

_StatsDialog_Close() {
    global g_StatsGui, g_StatsControls
    if (g_StatsGui) {
        g_StatsGui.Destroy()
        g_StatsGui := 0
    }
    g_StatsControls := Map()
}

_StatsDialog_Refresh() {
    global g_StatsGui, g_StorePID
    if (!g_StatsGui)
        return
    if (LauncherUtils_IsRunning(g_StorePID))
        _Dash_QueryStats()
    _StatsDialog_UpdateValues()
}

; Update all value controls in-place from current g_StatsCache
_StatsDialog_UpdateValues() {
    global g_StatsControls, g_StatsCache

    cache := IsObject(g_StatsCache) ? g_StatsCache : Map()

    ; Lifetime values
    _StatsCtl_Set("lifetime_RunTime", _Stats_FormatDuration(_Stats_MapGet(cache, "TotalRunTimeSec") + _Stats_MapGet(cache, "SessionRunTimeSec")))
    _StatsCtl_Set("lifetime_Sessions", _Stats_FormatNumber(_Stats_MapGet(cache, "TotalSessions")))
    _StatsCtl_Set("lifetime_AltTabs", _Stats_FormatNumber(_Stats_MapGet(cache, "TotalAltTabs")))
    _StatsCtl_Set("lifetime_QuickSwitches", _Stats_FormatNumber(_Stats_MapGet(cache, "TotalQuickSwitches")))
    _StatsCtl_Set("lifetime_TabSteps", _Stats_FormatNumber(_Stats_MapGet(cache, "TotalTabSteps")))
    _StatsCtl_Set("lifetime_Cancellations", _Stats_FormatNumber(_Stats_MapGet(cache, "TotalCancellations")))
    _StatsCtl_Set("lifetime_CrossWorkspace", _Stats_FormatNumber(_Stats_MapGet(cache, "TotalCrossWorkspace")))
    _StatsCtl_Set("lifetime_WorkspaceToggles", _Stats_FormatNumber(_Stats_MapGet(cache, "TotalWorkspaceToggles")))
    _StatsCtl_Set("lifetime_WindowUpdates", _Stats_FormatNumber(_Stats_MapGet(cache, "TotalWindowUpdates")))
    _StatsCtl_Set("lifetime_BlacklistSkips", _Stats_FormatNumber(_Stats_MapGet(cache, "TotalBlacklistSkips")))
    _StatsCtl_Set("lifetime_PeakWindows", _Stats_FormatNumber(_Stats_MapGet(cache, "PeakWindowsInSession")))
    _StatsCtl_Set("lifetime_LongestSession", _Stats_FormatDuration(_Stats_MapGet(cache, "LongestSessionSec")))

    ; Session values
    _StatsCtl_Set("session_RunTime", _Stats_FormatDuration(_Stats_MapGet(cache, "SessionRunTimeSec")))
    _StatsCtl_Set("session_AltTabs", _Stats_FormatNumber(_Stats_MapGet(cache, "SessionAltTabs")))
    _StatsCtl_Set("session_QuickSwitches", _Stats_FormatNumber(_Stats_MapGet(cache, "SessionQuickSwitches")))
    _StatsCtl_Set("session_TabSteps", _Stats_FormatNumber(_Stats_MapGet(cache, "SessionTabSteps")))
    _StatsCtl_Set("session_Cancellations", _Stats_FormatNumber(_Stats_MapGet(cache, "SessionCancellations")))
    _StatsCtl_Set("session_CrossWorkspace", _Stats_FormatNumber(_Stats_MapGet(cache, "SessionCrossWorkspace")))
    _StatsCtl_Set("session_WorkspaceToggles", _Stats_FormatNumber(_Stats_MapGet(cache, "SessionWorkspaceToggles")))
    _StatsCtl_Set("session_WindowUpdates", _Stats_FormatNumber(_Stats_MapGet(cache, "SessionWindowUpdates")))
    _StatsCtl_Set("session_BlacklistSkips", _Stats_FormatNumber(_Stats_MapGet(cache, "SessionBlacklistSkips")))
    _StatsCtl_Set("session_PeakWindows", _Stats_FormatNumber(_Stats_MapGet(cache, "SessionPeakWindows")))

    ; Insight values
    _StatsCtl_Set("insight_AvgPerHour", String(_Stats_MapGet(cache, "DerivedAvgAltTabsPerHour")))
    _StatsCtl_Set("insight_QuickPct", String(_Stats_MapGet(cache, "DerivedQuickSwitchPct")) "%")
    _StatsCtl_Set("insight_CancelRate", String(_Stats_MapGet(cache, "DerivedCancelRate")) "%")
    _StatsCtl_Set("insight_AvgTabs", String(_Stats_MapGet(cache, "DerivedAvgTabsPerSwitch")))
}

; Set a stats control value by key (safe — skips if control not found)
_StatsCtl_Set(key, value) {
    global g_StatsControls
    if (g_StatsControls.Has(key))
        g_StatsControls[key].Value := value
}

; Load icon.png into the stats dialog (dev: file, compiled: resource ID 11)
_StatsDialog_LoadIcon(sg) {
    ; Dev mode: load from file
    if (!A_IsCompiled) {
        imgPath := A_ScriptDir "\..\resources\icon.png"
        if (FileExist(imgPath)) {
            sg.AddPicture("x385 y349 w80 h80", imgPath)
        }
        return
    }

    ; Compiled mode: extract from embedded resource, convert to HBITMAP
    hModule := DllCall("LoadLibrary", "str", "gdiplus", "ptr")
    if (!hModule)
        return

    si := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
    NumPut("UInt", 1, si, 0)
    token := 0
    DllCall("gdiplus\GdiplusStartup", "ptr*", &token, "ptr", si.Ptr, "ptr", 0)
    if (!token) {
        DllCall("FreeLibrary", "ptr", hModule)
        return
    }

    pBitmap := _Splash_LoadBitmapFromResource(11)
    if (!pBitmap) {
        DllCall("gdiplus\GdiplusShutdown", "ptr", token)
        DllCall("FreeLibrary", "ptr", hModule)
        return
    }

    ; High-quality resize to 80x80
    pThumb := _GdipResizeHQ(pBitmap, 80, 80)
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
        return

    sg.AddPicture("x385 y349 w80 h80", "HBITMAP:*" hBitmap)
}

; High-quality GDI+ image resize using bicubic interpolation.
; Returns a new GDI+ bitmap pointer (caller must dispose), or 0 on failure.
_GdipResizeHQ(pSrcBitmap, w, h) {
    pDst := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", w, "int", h, "int", 0, "int", 0x26200A, "ptr", 0, "ptr*", &pDst)
    if (!pDst)
        return 0

    pGraphics := 0
    DllCall("gdiplus\GdipGetImageGraphicsContext", "ptr", pDst, "ptr*", &pGraphics)
    if (!pGraphics) {
        DllCall("gdiplus\GdipDisposeImage", "ptr", pDst)
        return 0
    }

    DllCall("gdiplus\GdipSetInterpolationMode", "ptr", pGraphics, "int", 7)  ; HighQualityBicubic
    DllCall("gdiplus\GdipSetPixelOffsetMode", "ptr", pGraphics, "int", 4)    ; HighQuality (avoids edge clipping)
    DllCall("gdiplus\GdipDrawImageRectI", "ptr", pGraphics, "ptr", pSrcBitmap, "int", 0, "int", 0, "int", w, "int", h)
    DllCall("gdiplus\GdipDeleteGraphics", "ptr", pGraphics)

    return pDst
}
