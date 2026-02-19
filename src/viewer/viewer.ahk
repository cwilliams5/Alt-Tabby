#Requires AutoHotkey v2.0
#Warn VarUnset, Off

; ============================================================
; Viewer — In-process debug window for WindowList state
; ============================================================
; Shows live contents of gWS_Store in a ListView.
; Runs inside the MainProcess (gui_main.ahk), reads
; WL_GetDisplayList() directly — no IPC.
;
; Toggled via tray menu (launcher sends TABBY_CMD_TOGGLE_VIEWER)
; or programmatically via Viewer_Toggle().
; ============================================================

global gViewer_Gui := 0
global gViewer_LV := 0
global gViewer_Sort := "MRU"
global gViewer_CurrentOnly := false
global gViewer_IncludeMinimized := true
global gViewer_IncludeCloaked := true
global gViewer_Status := 0
global gViewer_SortLabel := 0
global gViewer_WSLabel := 0
global gViewer_MinLabel := 0
global gViewer_CloakLabel := 0
global gViewer_CurrentWSLabel := 0
global gViewer_RefreshTimerFn := 0
global gViewer_RefreshIntervalMs := 500  ; Polling interval when visible
global gViewer_LastRev := -1
global gViewer_ShuttingDown := false
global gBlacklistChoice := ""  ; Blacklist dialog result (shared between dialog + button callbacks)

; ========================= PUBLIC API =========================

Viewer_Toggle() {
    global gViewer_Gui, gViewer_ShuttingDown
    if (gViewer_ShuttingDown)
        return

    ; Lazy-create GUI on first toggle
    if (!gViewer_Gui)
        _Viewer_CreateGui()

    if (_Viewer_IsVisible()) {
        _Viewer_StopRefreshTimer()
        gViewer_Gui.Hide()
    } else {
        gViewer_Gui.Show("w1120 h660")
        _Viewer_Refresh()
        _Viewer_StartRefreshTimer()
    }
}

_Viewer_IsVisible() {
    global gViewer_Gui
    if (!gViewer_Gui)
        return false
    try {
        return DllCall("user32\IsWindowVisible", "ptr", gViewer_Gui.Hwnd, "int")
    } catch {
        return false
    }
}

Viewer_Shutdown() {
    global gViewer_ShuttingDown, gViewer_Gui
    gViewer_ShuttingDown := true
    _Viewer_StopRefreshTimer()
    if (gViewer_Gui) {
        try gViewer_Gui.Destroy()
        gViewer_Gui := 0
    }
}

; ========================= REFRESH =========================

_Viewer_Refresh() {
    global gViewer_Sort, gViewer_CurrentOnly, gViewer_IncludeMinimized, gViewer_IncludeCloaked
    global gViewer_LastRev, gViewer_ShuttingDown

    if (gViewer_ShuttingDown)
        return

    opts := {
        sort: gViewer_Sort,
        columns: "items",
        includeMinimized: gViewer_IncludeMinimized,
        includeCloaked: gViewer_IncludeCloaked
    }
    if (gViewer_CurrentOnly)
        opts.currentWorkspaceOnly := true

    proj := WL_GetDisplayList(opts)

    ; Skip if rev unchanged (no work to do)
    if (proj.rev = gViewer_LastRev)
        return
    gViewer_LastRev := proj.rev

    ; Update current workspace display
    _Viewer_UpdateCurrentWS(proj.meta)

    ; Update ListView
    _Viewer_UpdateList(proj.items)

    ; Update status bar
    _Viewer_UpdateStatusBar(proj)
}

_Viewer_RefreshTick() {
    _Viewer_Refresh()
}

_Viewer_StartRefreshTimer() {
    global gViewer_RefreshTimerFn, gViewer_RefreshIntervalMs
    if (gViewer_RefreshTimerFn)
        return  ; Already running
    gViewer_RefreshTimerFn := _Viewer_RefreshTick.Bind()
    SetTimer(gViewer_RefreshTimerFn, gViewer_RefreshIntervalMs)  ; lint-ignore: timer-lifecycle (cancelled via _Viewer_StopRefreshTimer using bound ref)
}

_Viewer_StopRefreshTimer() {
    global gViewer_RefreshTimerFn
    if (gViewer_RefreshTimerFn) {
        try SetTimer(gViewer_RefreshTimerFn, 0)
        gViewer_RefreshTimerFn := 0
    }
}

; ========================= GUI CREATION =========================

_Viewer_CreateGui() {
    global gViewer_Gui, gViewer_LV, gViewer_Status
    global gViewer_SortLabel, gViewer_WSLabel, gViewer_CurrentWSLabel
    global gViewer_MinLabel, gViewer_CloakLabel

    gViewer_Gui := Gui("+Resize +AlwaysOnTop", "WindowList Viewer")

    ; === Top toolbar - toggle buttons ===
    xPos := 10

    ; Sort toggle
    btn := gViewer_Gui.AddButton("x" xPos " y10 w70 h24", "Sort")
    btn.OnEvent("Click", _Viewer_ToggleSort)
    gViewer_SortLabel := gViewer_Gui.AddText("x" (xPos + 75) " y14 w35 h20", "[MRU]")
    xPos += 115

    ; Workspace toggle
    btn2 := gViewer_Gui.AddButton("x" xPos " y10 w70 h24", "WS")
    btn2.OnEvent("Click", _Viewer_ToggleCurrentWS)
    gViewer_WSLabel := gViewer_Gui.AddText("x" (xPos + 75) " y14 w50 h20", "[All]")
    xPos += 130

    ; Minimized toggle
    btn3 := gViewer_Gui.AddButton("x" xPos " y10 w70 h24", "Min")
    btn3.OnEvent("Click", _Viewer_ToggleMinimized)
    gViewer_MinLabel := gViewer_Gui.AddText("x" (xPos + 75) " y14 w35 h20", "[Y]")
    xPos += 115

    ; Cloaked toggle
    btn4 := gViewer_Gui.AddButton("x" xPos " y10 w70 h24", "Cloak")
    btn4.OnEvent("Click", _Viewer_ToggleCloaked)
    gViewer_CloakLabel := gViewer_Gui.AddText("x" (xPos + 75) " y14 w35 h20", "[Y]")
    xPos += 115

    ; Current workspace display
    gViewer_Gui.AddText("x" xPos " y14 w50 h20", "CurWS:")
    gViewer_CurrentWSLabel := gViewer_Gui.AddText("x" (xPos + 50) " y14 w70 h20 +0x100", "---")
    xPos += 130

    ; Refresh button
    btn5 := gViewer_Gui.AddButton("x" xPos " y10 w60 h24", "Refresh")
    btn5.OnEvent("Click", (*) => (_Viewer_ForceRefresh()))

    ; === ListView in middle ===
    ; Columns: Z, MRU, HWND, PID, Title, Class, WS, Cur, Process, Foc, Clk, Min, Icon
    gViewer_LV := gViewer_Gui.AddListView("x10 y44 w1100 h570 +LV0x10000",
        ["Z", "MRU", "HWND", "PID", "Title", "Class", "WS", "Cur", "Process", "Foc", "Clk", "Min", "Icon"])

    ; === Bottom status bar ===
    gViewer_Status := gViewer_Gui.AddText("x10 y620 w1100 h20", "Ready")

    ; Set column widths
    gViewer_LV.ModifyCol(1, 35)   ; Z
    gViewer_LV.ModifyCol(2, 90)   ; MRU (tick)
    gViewer_LV.ModifyCol(3, 75)   ; HWND
    gViewer_LV.ModifyCol(4, 45)   ; PID
    gViewer_LV.ModifyCol(5, 280)  ; Title
    gViewer_LV.ModifyCol(6, 130)  ; Class
    gViewer_LV.ModifyCol(7, 60)   ; Workspace
    gViewer_LV.ModifyCol(8, 30)   ; isOnCurrentWorkspace (Cur)
    gViewer_LV.ModifyCol(9, 90)   ; Process
    gViewer_LV.ModifyCol(10, 30)  ; Focused
    gViewer_LV.ModifyCol(11, 30)  ; Cloaked
    gViewer_LV.ModifyCol(12, 30)  ; Minimized
    gViewer_LV.ModifyCol(13, 70)  ; Icon (HICON value)

    ; Double-click to blacklist a window
    gViewer_LV.OnEvent("DoubleClick", _Viewer_OnBlacklist)

    gViewer_Gui.OnEvent("Close", _Viewer_OnClose)
    gViewer_Gui.OnEvent("Size", _Viewer_OnResize)
}

_Viewer_OnClose(*) {
    global gViewer_Gui
    _Viewer_StopRefreshTimer()
    gViewer_Gui.Hide()
}

; ========================= LIST UPDATE =========================

_Viewer_UpdateList(items) {
    global gViewer_LV, gViewer_Sort, gViewer_ShuttingDown
    if (gViewer_ShuttingDown || !gViewer_LV)
        return

    ; Local sort — viewer controls its own sort order
    _Viewer_SortItems(items, gViewer_Sort)

    ; Disable redraw during update
    gViewer_LV.Opt("-Redraw")
    gViewer_LV.Delete()

    for _, rec in items {
        gViewer_LV.Add("", _Viewer_BuildRowArgs(rec)*)
    }

    ; Re-enable redraw
    gViewer_LV.Opt("+Redraw")
}

; ========================= STATUS BAR =========================

_Viewer_UpdateStatusBar(proj := 0) {
    global gViewer_Status, gViewer_LastRev, gViewer_ShuttingDown
    if (gViewer_ShuttingDown || !gViewer_Status)
        return

    try {
        itemCount := proj ? proj.items.Length : 0
        path := proj ? proj.cachePath : "?"
        gViewer_Status.Text := "Rev:" gViewer_LastRev " | " itemCount " items | path:" path
    }
}

; ========================= CURRENT WORKSPACE =========================

_Viewer_UpdateCurrentWS(meta) {
    global gViewer_CurrentWSLabel, gViewer_ShuttingDown
    if (gViewer_ShuttingDown || !IsObject(gViewer_CurrentWSLabel))
        return
    wsName := ""
    if (meta is Map) {
        wsName := meta.Has("currentWSName") ? meta["currentWSName"] : ""
    } else if (IsObject(meta)) {
        try wsName := meta.currentWSName
    }
    if (wsName != "")
        gViewer_CurrentWSLabel.Text := wsName
}

; ========================= TOGGLE CALLBACKS =========================

_Viewer_ToggleSort(*) {
    global gViewer_Sort, gViewer_SortLabel, gViewer_LastRev, gViewer_ShuttingDown
    if (gViewer_ShuttingDown)
        return
    gViewer_Sort := (gViewer_Sort = "Z") ? "MRU" : "Z"
    gViewer_SortLabel.Text := "[" gViewer_Sort "]"
    gViewer_LastRev := -1  ; Force refresh
    _Viewer_Refresh()
}

_Viewer_ToggleCurrentWS(*) {
    global gViewer_CurrentOnly, gViewer_WSLabel, gViewer_LastRev, gViewer_ShuttingDown
    if (gViewer_ShuttingDown)
        return
    gViewer_CurrentOnly := !gViewer_CurrentOnly
    gViewer_WSLabel.Text := gViewer_CurrentOnly ? "[Cur]" : "[All]"
    gViewer_LastRev := -1
    _Viewer_Refresh()
}

_Viewer_ToggleMinimized(*) {
    global gViewer_IncludeMinimized, gViewer_MinLabel, gViewer_LastRev, gViewer_ShuttingDown
    if (gViewer_ShuttingDown)
        return
    gViewer_IncludeMinimized := !gViewer_IncludeMinimized
    gViewer_MinLabel.Text := gViewer_IncludeMinimized ? "[Y]" : "[N]"
    gViewer_LastRev := -1
    _Viewer_Refresh()
}

_Viewer_ToggleCloaked(*) {
    global gViewer_IncludeCloaked, gViewer_CloakLabel, gViewer_LastRev, gViewer_ShuttingDown
    if (gViewer_ShuttingDown)
        return
    gViewer_IncludeCloaked := !gViewer_IncludeCloaked
    gViewer_CloakLabel.Text := gViewer_IncludeCloaked ? "[Y]" : "[N]"
    gViewer_LastRev := -1
    _Viewer_Refresh()
}

_Viewer_ForceRefresh() {
    global gViewer_LastRev
    gViewer_LastRev := -1
    _Viewer_Refresh()
}

; ========================= RESIZE =========================

_Viewer_OnResize(gui, minMax, w, h) { ; lint-ignore: dead-param
    global gViewer_LV, gViewer_Status, gViewer_ShuttingDown

    if (gViewer_ShuttingDown)
        return
    if (minMax = -1)
        return  ; Minimized

    ; ListView: top=44, bottom margin=30 (for status bar)
    try gViewer_LV.Move(, , w - 20, h - 74)
    ; Status bar at bottom
    try gViewer_Status.Move(10, h - 26, w - 20)
}

; ========================= ROW FORMATTING =========================

_Viewer_BuildRowArgs(rec) {
    hwnd := _Viewer_Get(rec, "hwnd", 0)
    return [
        _Viewer_Get(rec, "z", ""),
        _Viewer_Get(rec, "lastActivatedTick", ""),
        "0x" Format("{:X}", hwnd),
        _Viewer_Get(rec, "pid", ""),
        _Viewer_Get(rec, "title", ""),
        _Viewer_Get(rec, "class", ""),
        _Viewer_Get(rec, "workspaceName", ""),
        _Viewer_Get(rec, "isOnCurrentWorkspace", 0) ? "1" : "0",
        _Viewer_Get(rec, "processName", ""),
        _Viewer_Get(rec, "isFocused", 0) ? "Y" : "",
        _Viewer_Get(rec, "isCloaked", 0) ? "Y" : "",
        _Viewer_Get(rec, "isMinimized", 0) ? "Y" : "",
        _Viewer_IconStr(_Viewer_Get(rec, "iconHicon", 0))
    ]
}

_Viewer_IconStr(hicon) {
    if (!hicon || hicon = 0)
        return ""
    return "0x" Format("{:X}", hicon)
}

_Viewer_Get(rec, key, defaultVal := "") {
    if (rec is Map) {
        return rec.Has(key) ? rec[key] : defaultVal
    }
    try {
        return rec.%key%
    } catch {
        return defaultVal
    }
}

; ========================= SORTING =========================

_Viewer_SortItems(items, sortMode) {
    if (!IsObject(items) || items.Length <= 1)
        return
    if (sortMode = "Z")
        _Viewer_InsertionSort(items, _Viewer_CmpZ)
    else
        _Viewer_InsertionSort(items, _Viewer_CmpMRU)
}

_Viewer_InsertionSort(arr, cmp) {
    len := arr.Length
    Loop len {
        i := A_Index
        if (i = 1)
            continue
        key := arr[i]
        j := i - 1
        while (j >= 1 && cmp(arr[j], key) > 0) {
            arr[j + 1] := arr[j]
            j -= 1
        }
        arr[j + 1] := key
    }
}

_Viewer_CmpZ(a, b) {
    az := _Viewer_Get(a, "z", 0)
    bz := _Viewer_Get(b, "z", 0)
    if (az != bz)
        return (az < bz) ? -1 : 1
    at := _Viewer_Get(a, "lastActivatedTick", 0)
    bt := _Viewer_Get(b, "lastActivatedTick", 0)
    if (at != bt)
        return (at > bt) ? -1 : 1
    ah := _Viewer_Get(a, "hwnd", 0)
    bh := _Viewer_Get(b, "hwnd", 0)
    return (ah < bh) ? -1 : (ah > bh) ? 1 : 0
}

_Viewer_CmpMRU(a, b) {
    at := _Viewer_Get(a, "lastActivatedTick", 0)
    bt := _Viewer_Get(b, "lastActivatedTick", 0)
    if (at != bt)
        return (at > bt) ? -1 : 1
    az := _Viewer_Get(a, "z", 0)
    bz := _Viewer_Get(b, "z", 0)
    if (az != bz)
        return (az < bz) ? -1 : 1
    ah := _Viewer_Get(a, "hwnd", 0)
    bh := _Viewer_Get(b, "hwnd", 0)
    return (ah < bh) ? -1 : (ah > bh) ? 1 : 0
}

; ========================= BLACKLIST =========================

_Viewer_OnBlacklist(lv, row) {
    global gViewer_ShuttingDown
    if (gViewer_ShuttingDown || row = 0)
        return

    ; Get cell values directly from ListView
    class := lv.GetText(row, 6)   ; Column 6 = Class
    title := lv.GetText(row, 5)   ; Column 5 = Title

    if (class = "" && title = "")
        return

    ; Show blacklist options dialog
    choice := _Viewer_ShowBlacklistDialog(class, title)
    if (choice = "")
        return

    ; Write to blacklist file
    success := false
    toastMsg := ""
    if (choice = "class") {
        success := Blacklist_AddClass(class)
        toastMsg := "Blacklisted class: " class
    } else if (choice = "title") {
        success := Blacklist_AddTitle(title)
        toastMsg := "Blacklisted title: " title
    } else if (choice = "pair") {
        success := Blacklist_AddPair(class, title)
        toastMsg := "Blacklisted pair: " class "|" title
    }

    if (!success) {
        _Viewer_ShowToast("Failed to write to blacklist.txt")
        return
    }

    ; Reload blacklist and purge directly (in-process)
    Blacklist_Init()
    WL_PurgeBlacklisted()

    _Viewer_ShowToast(toastMsg)

    ; Force refresh to show updated list
    _Viewer_ForceRefresh()
}

_Viewer_ShowBlacklistDialog(class, title) {
    global gBlacklistChoice, gViewer_ShuttingDown
    gBlacklistChoice := ""
    if (gViewer_ShuttingDown)
        return ""

    dlg := Gui("+AlwaysOnTop +Owner", "Blacklist Window")
    GUI_AntiFlashPrepare(dlg, Theme_GetBgColor())
    dlg.MarginX := 24
    dlg.MarginY := 16
    dlg.SetFont("s10", "Segoe UI")
    Theme_ApplyToGui(dlg)

    contentW := 440
    mutedColor := Theme_GetMutedColor()

    hdr := dlg.AddText("w" contentW " c" Theme_GetAccentColor(), "Add to blacklist:")
    Theme_MarkAccent(hdr)
    lblC := dlg.AddText("x24 w50 h20 y+12 +0x200", "Class:")
    lblC.SetFont("s10 bold", "Segoe UI")
    valC := dlg.AddText("x78 yp w" (contentW - 54) " h20 +0x200 c" mutedColor, class)
    Theme_MarkMuted(valC)
    displayTitle := SubStr(title, 1, 50) (StrLen(title) > 50 ? "..." : "")
    lblT := dlg.AddText("x24 w50 h20 y+4 +0x200", "Title:")
    lblT.SetFont("s10 bold", "Segoe UI")
    valT := dlg.AddText("x78 yp w" (contentW - 54) " h20 +0x200 c" mutedColor, displayTitle)
    Theme_MarkMuted(valT)

    dlg.AddButton("x24 y+24 w100 h30", "Add Class").OnEvent("Click", (*) => _Viewer_BlacklistChoice(dlg, "class"))
    dlg.AddButton("x132 yp w100 h30", "Add Title").OnEvent("Click", (*) => _Viewer_BlacklistChoice(dlg, "title"))
    dlg.AddButton("x240 yp w100 h30", "Add Pair").OnEvent("Click", (*) => _Viewer_BlacklistChoice(dlg, "pair"))
    dlg.AddButton("x364 yp w100 h30", "Cancel").OnEvent("Click", (*) => _Viewer_BlacklistChoice(dlg, ""))

    dlg.OnEvent("Close", (*) => _Viewer_BlacklistChoice(dlg, ""))
    dlg.OnEvent("Escape", (*) => _Viewer_BlacklistChoice(dlg, ""))

    dlg.Show("w488 Center")
    GUI_AntiFlashReveal(dlg, true)
    WinWaitClose(dlg)
    return gBlacklistChoice
}

_Viewer_BlacklistChoice(dlg, choice) {
    global gBlacklistChoice
    gBlacklistChoice := choice
    try Theme_UntrackGui(dlg)
    dlg.Destroy()
}

_Viewer_ShowToast(message) {
    global gViewer_Gui, TOOLTIP_DURATION_DEFAULT
    if (IsObject(gViewer_Gui)) {
        ToolTip(message)
        HideTooltipAfter(TOOLTIP_DURATION_DEFAULT)
    }
}

; ========================= AUTO-INIT =========================
; Viewer initializes in GUI mode — it's an in-process debug window.
; No init needed at load time — GUI is lazy-created on first Viewer_Toggle().
