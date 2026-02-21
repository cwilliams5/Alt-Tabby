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

; --- Core state ---
global gViewer_Gui := 0
global gViewer_LV := 0
global gViewer_Sort := "MRU"   ; Internal: always MRU for WL_GetDisplayList opts
global gViewer_CurrentOnly := false
global gViewer_IncludeMinimized := true
global gViewer_IncludeCloaked := true
global gViewer_Status := 0
global gViewer_CurrentWSLabel := 0
global gViewer_RefreshTimerFn := 0
global gViewer_RefreshIntervalMs  ; Set from cfg.DiagViewerRefreshMs at init
global gViewer_LastRev := -1
global gViewer_ShuttingDown := false
global gBlacklistChoice := ""  ; Blacklist dialog result

; --- Toolbar buttons ---
global gViewer_WSBtn := 0
global gViewer_MinBtn := 0
global gViewer_CloakBtn := 0

; --- Subclass + custom draw state ---
global gViewer_LVSubclassCB := 0       ; CallbackCreate ref (prevent GC)
global gViewer_LVHeaderHwnd := 0        ; Cached header HWND
global gViewer_SortCol := -1            ; Column sort index (-1 = default MRU)
global gViewer_SortAsc := true          ; Sort ascending?
global gViewer_HotRow := -1             ; Hovered row (-1 = none)
global gViewer_HdrHotItem := -1         ; Hovered header item (-1 = none)
global gViewer_HoverTimerFn := 0        ; Bound ref for hover timer
global gViewer_CachedItems := []        ; Items for custom draw lookups
global gViewer_GuiEntry := 0            ; Theme tracking entry
global gViewer_FirstShow := true        ; Anti-flash first-show flag
global gViewer_LastTipHwnd := 0         ; Tooltip hover tracking
global gViewer_MenuActions := Map()     ; Context menu action data (keyed by item name)
global gViewer_CtxMenu := 0             ; Context menu object (must survive past Show() for callback)

; --- Header custom draw GDI cache ---
global gViewer_HdrBrushCache := Map()   ; color (uint) -> HBRUSH
global gViewer_HdrPenCache := Map()     ; color (uint) -> HPEN

; Column names (0-indexed for header draw)
global gViewer_Columns := ["Z", "MRU", "HWND", "PID", "Title", "Class", "WS", "Cur", "Process", "Foc", "Clk", "Min", "Icon"]

; Column-to-field mapping for sort
global gViewer_ColFields := ["z", "lastActivatedTick", "hwnd", "pid", "title", "class", "workspaceName", "isOnCurrentWorkspace", "processName", "isFocused", "isCloaked", "isMinimized", "iconHicon"]
; Columns that use string comparison (all others are numeric)
global gViewer_ColIsString := Map(4, true, 5, true, 6, true, 8, true)

; ========================= PUBLIC API =========================

Viewer_Toggle() {
    global gViewer_Gui, gViewer_ShuttingDown, gViewer_FirstShow
    if (gViewer_ShuttingDown)
        return

    ; Lazy-create GUI on first toggle
    if (!gViewer_Gui)
        _Viewer_CreateGui()

    if (_Viewer_IsVisible()) {
        _Viewer_StopRefreshTimer()
        _Viewer_StopHoverTimer()
        gViewer_Gui.Hide()
    } else {
        if (gViewer_FirstShow) {
            gViewer_Gui.Show("w1120 h660")
            GUI_AntiFlashReveal(gViewer_Gui, true)
            gViewer_FirstShow := false
        } else {
            gViewer_Gui.Show("w1120 h660")
        }
        _Viewer_Refresh()
        _Viewer_StartRefreshTimer()
        _Viewer_StartHoverTimer()
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
    global gViewer_ShuttingDown, gViewer_Gui, gViewer_LV, gViewer_LVSubclassCB
    gViewer_ShuttingDown := true
    _Viewer_StopRefreshTimer()
    _Viewer_StopHoverTimer()
    _Viewer_ClearHeaderCache()

    ; Unregister WM_NOTIFY handler
    OnMessage(0x004E, _Viewer_OnWMNotify, 0)

    ; Remove subclass BEFORE destroying GUI (strict order)
    if (gViewer_LVSubclassCB && gViewer_LV) {
        try DllCall("comctl32\RemoveWindowSubclass", "Ptr", gViewer_LV.Hwnd,
            "Ptr", gViewer_LVSubclassCB, "UPtr", 1)
        try {
            CallbackFree(gViewer_LVSubclassCB)
        } catch {
        }
        gViewer_LVSubclassCB := 0
    }

    if (gViewer_Gui) {
        try Theme_UntrackGui(gViewer_Gui)
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
    global gViewer_Gui, gViewer_LV, gViewer_Status, gViewer_CurrentWSLabel
    global gViewer_WSBtn, gViewer_MinBtn, gViewer_CloakBtn
    global gViewer_GuiEntry, gViewer_LVHeaderHwnd, gViewer_Columns

    gViewer_Gui := Gui("+Resize +AlwaysOnTop", "WindowList Viewer")
    GUI_AntiFlashPrepare(gViewer_Gui, Theme_GetBgColor())
    gViewer_Gui.SetFont("s9", "Segoe UI")
    gViewer_GuiEntry := Theme_ApplyToGui(gViewer_Gui)

    ; === Top toolbar — toggle buttons ===
    xPos := 10

    ; Workspace toggle
    gViewer_WSBtn := gViewer_Gui.AddButton("x" xPos " y8 w80 h26", "WS: All")
    gViewer_WSBtn.OnEvent("Click", _Viewer_ToggleCurrentWS)
    Theme_ApplyToControl(gViewer_WSBtn, "Button", gViewer_GuiEntry)
    xPos += 88

    ; Minimized toggle
    gViewer_MinBtn := gViewer_Gui.AddButton("x" xPos " y8 w60 h26", "+Min")
    gViewer_MinBtn.OnEvent("Click", _Viewer_ToggleMinimized)
    Theme_ApplyToControl(gViewer_MinBtn, "Button", gViewer_GuiEntry)
    xPos += 68

    ; Cloaked toggle
    gViewer_CloakBtn := gViewer_Gui.AddButton("x" xPos " y8 w68 h26", "+Cloak")
    gViewer_CloakBtn.OnEvent("Click", _Viewer_ToggleCloaked)
    Theme_ApplyToControl(gViewer_CloakBtn, "Button", gViewer_GuiEntry)
    xPos += 76

    ; Current workspace display
    wsLbl := gViewer_Gui.AddText("x" xPos " y12 w45 h20", "CurWS:")
    Theme_MarkMuted(wsLbl)
    gViewer_CurrentWSLabel := gViewer_Gui.AddText("x" (xPos + 48) " y12 w80 h20 +0x100", "---")
    Theme_MarkAccent(gViewer_CurrentWSLabel)

    ; === ListView ===
    gViewer_LV := gViewer_Gui.AddListView("x10 y42 w1100 h572 +LV0x10000",
        gViewer_Columns)
    Theme_ApplyToControl(gViewer_LV, "ListView", gViewer_GuiEntry)

    ; Extended styles: full row select + double buffering (reduces flicker)
    SendMessage(0x1036, 0x00010020, 0x00010020, gViewer_LV.Hwnd)  ; LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFERED

    ; Show selection even when unfocused
    style := DllCall("GetWindowLong", "Ptr", gViewer_LV.Hwnd, "Int", -16, "Int")
    DllCall("SetWindowLong", "Ptr", gViewer_LV.Hwnd, "Int", -16, "Int", style | 0x0008)  ; LVS_SHOWSELALWAYS

    ; === Bottom status bar ===
    gViewer_Status := gViewer_Gui.AddText("x10 y620 w1100 h20", "Ready")
    Theme_MarkMuted(gViewer_Status)

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

    ; --- Event handlers ---
    ; Double-click to blacklist a window
    gViewer_LV.OnEvent("DoubleClick", _Viewer_OnBlacklist)
    ; Column click sort
    gViewer_LV.OnEvent("ColClick", _Viewer_OnColClick)
    ; Row NM_CUSTOMDRAW + focus via global WM_NOTIFY handler
    ; (OnNotify approach crashes on right-click; OnMessage is proven in legacy mock)
    OnMessage(0x004E, _Viewer_OnWMNotify) ; lint-ignore: onmessage-collision

    gViewer_Gui.OnEvent("Close", _Viewer_OnClose)
    gViewer_Gui.OnEvent("Size", _Viewer_OnResize)

    ; Install ListView subclass for header NM_CUSTOMDRAW ONLY
    ; (row NM_CUSTOMDRAW goes from ListView -> parent via OnNotify above)
    _Viewer_InstallSubclass()

    ; Register for live re-theming
    Theme_OnChange(_Viewer_OnThemeChange)
}

_Viewer_OnClose(*) {
    global gViewer_Gui
    _Viewer_StopRefreshTimer()
    _Viewer_StopHoverTimer()
    gViewer_Gui.Hide()
}

; ========================= LIST UPDATE =========================

_Viewer_UpdateList(items) {
    global gViewer_LV, gViewer_Sort, gViewer_ShuttingDown, gViewer_CachedItems
    global gViewer_SortCol, gViewer_SortAsc
    if (gViewer_ShuttingDown || !gViewer_LV)
        return

    ; Column sort takes priority over MRU/Z
    if (gViewer_SortCol >= 0)
        _Viewer_SortByColumn(items, gViewer_SortCol, gViewer_SortAsc)
    else
        _Viewer_SortItems(items, gViewer_Sort)

    ; Cache for custom draw (focused row detection, re-sorting)
    Critical "On"
    gViewer_CachedItems := items
    Critical "Off"

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
        producerStatus := _Viewer_GetProducerStatus()
        gViewer_Status.Text := itemCount " items | Rev: " gViewer_LastRev " | " producerStatus
    }
}

_Viewer_GetProducerStatus() {
    weh := WinEventHook_IsRunning() ? "ok" : "--"
    pumpOk := GUIPump_IsConnected()
    ; Icon/Proc run in EnrichmentPump subprocess when connected, local fallback otherwise
    icon := (pumpOk || IconPump_IsEnabled()) ? "ok" : "--"
    proc := (pumpOk || ProcPump_IsEnabled()) ? "ok" : "--"
    pump := pumpOk ? "ok" : "--"

    if (KomorebiSub_IsConnected())
        komo := "sub"
    else if (KomorebiSub_IsFallback())
        komo := "poll"
    else
        komo := "--"

    return "WEH:" weh "  Icon:" icon "  Proc:" proc "  Komo:" komo "  Pump:" pump
}

; ========================= CURRENT WORKSPACE =========================

_Viewer_UpdateCurrentWS(meta) {
    global gViewer_CurrentWSLabel, gViewer_ShuttingDown
    if (gViewer_ShuttingDown || !IsObject(gViewer_CurrentWSLabel))
        return
    wsName := ""
    if (meta is Map) {
        wsName := meta.Get("currentWSName", "")
    } else if (IsObject(meta)) {
        try wsName := meta.currentWSName
    }
    if (wsName != "")
        gViewer_CurrentWSLabel.Text := wsName
}

; ========================= TOGGLE CALLBACKS =========================

_Viewer_ToggleCurrentWS(*) {
    global gViewer_CurrentOnly, gViewer_WSBtn, gViewer_LastRev, gViewer_ShuttingDown
    if (gViewer_ShuttingDown)
        return
    gViewer_CurrentOnly := !gViewer_CurrentOnly
    _Viewer_SetBtnText(gViewer_WSBtn, gViewer_CurrentOnly ? "WS: Cur" : "WS: All")
    gViewer_LastRev := -1
    _Viewer_Refresh()
}

_Viewer_ToggleMinimized(*) {
    global gViewer_IncludeMinimized, gViewer_MinBtn, gViewer_LastRev, gViewer_ShuttingDown
    if (gViewer_ShuttingDown)
        return
    gViewer_IncludeMinimized := !gViewer_IncludeMinimized
    _Viewer_SetBtnText(gViewer_MinBtn, gViewer_IncludeMinimized ? "+Min" : "-Min")
    gViewer_LastRev := -1
    _Viewer_Refresh()
}

_Viewer_ToggleCloaked(*) {
    global gViewer_IncludeCloaked, gViewer_CloakBtn, gViewer_LastRev, gViewer_ShuttingDown
    if (gViewer_ShuttingDown)
        return
    gViewer_IncludeCloaked := !gViewer_IncludeCloaked
    _Viewer_SetBtnText(gViewer_CloakBtn, gViewer_IncludeCloaked ? "+Cloak" : "-Cloak")
    gViewer_LastRev := -1
    _Viewer_Refresh()
}

; Update button text for both normal and owner-draw button modes
_Viewer_SetBtnText(btn, text) {
    global gTheme_ButtonMap
    btn.Text := text
    if (gTheme_ButtonMap.Has(btn.Hwnd))
        gTheme_ButtonMap[btn.Hwnd].text := text
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

    ; ListView: top=42, bottom margin=30 (for status bar)
    try gViewer_LV.Move(, , w - 20, h - 72)
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
        return rec.Get(key, defaultVal)
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
        QuickSort(items, _Viewer_CmpZ)
    else
        QuickSort(items, _Viewer_CmpMRU)
}

_Viewer_SortByColumn(items, colIdx, ascending) {
    global gViewer_ColFields, gViewer_ColIsString
    if (!IsObject(items) || items.Length <= 1)
        return
    if (colIdx < 0 || colIdx >= gViewer_ColFields.Length)
        return

    fieldName := gViewer_ColFields[colIdx + 1]
    isString := gViewer_ColIsString.Has(colIdx)

    ; Build comparator closure
    cmp := _Viewer_MakeColumnCmp(fieldName, isString, ascending)
    QuickSort(items, cmp)
}

_Viewer_MakeColumnCmp(fieldName, isString, ascending) {
    return (a, b) => _Viewer_CmpCol(a, b, fieldName, isString, ascending)
}

_Viewer_CmpCol(a, b, fieldName, isString, ascending) {
    av := _Viewer_Get(a, fieldName, isString ? "" : 0)
    bv := _Viewer_Get(b, fieldName, isString ? "" : 0)
    if (isString) {
        result := StrCompare(String(av), String(bv))
    } else {
        av := IsNumber(av) ? av : 0
        bv := IsNumber(bv) ? bv : 0
        result := (av < bv) ? -1 : (av > bv) ? 1 : 0
    }
    return ascending ? result : -result
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

; ========================= SUBCLASS INSTALL =========================
; Subclass on ListView intercepts WM_NOTIFY from its child header
; control. This is the ONLY way to custom-draw headers because the
; header sends NM_CUSTOMDRAW to its parent (the ListView), not to
; the grandparent (the Gui).
;
; Row NM_CUSTOMDRAW and LVN_COLUMNCLICK go from ListView to the
; Gui (parent), handled via OnNotify/OnEvent above.

_Viewer_InstallSubclass() {
    global gViewer_LV, gViewer_LVSubclassCB, gViewer_LVHeaderHwnd

    ; Cache header HWND
    gViewer_LVHeaderHwnd := DllCall("SendMessageW", "Ptr", gViewer_LV.Hwnd,
        "UInt", 0x101F, "Ptr", 0, "Ptr", 0, "Ptr")  ; LVM_GETHEADER

    if (!gViewer_LVHeaderHwnd)
        return

    ; Create callback and install subclass
    gViewer_LVSubclassCB := CallbackCreate(_Viewer_LVSubclassProc, , 6)
    DllCall("comctl32\SetWindowSubclass", "Ptr", gViewer_LV.Hwnd,
        "Ptr", gViewer_LVSubclassCB, "UPtr", 1, "Ptr", 0)
}

; ========================= SUBCLASS CALLBACK (HEADER ONLY) =========================
; Only intercepts header NM_CUSTOMDRAW. All other notifications pass through.

_Viewer_LVSubclassProc(hwnd, uMsg, wParam, lParam, uIdSubclass, dwRefData) { ; lint-ignore: dead-param
    global gViewer_LVHeaderHwnd, gViewer_ShuttingDown

    if (gViewer_ShuttingDown || uMsg != 0x004E)  ; Not WM_NOTIFY
        return DllCall("comctl32\DefSubclassProc", "Ptr", hwnd, "UInt", uMsg, "Ptr", wParam, "Ptr", lParam, "Ptr")

    code := NumGet(lParam, 16, "Int")
    hwndFrom := NumGet(lParam, 0, "Ptr")

    ; Header NM_CUSTOMDRAW only
    if (code = -12 && hwndFrom = gViewer_LVHeaderHwnd)
        return _Viewer_DrawHeader(lParam)

    return DllCall("comctl32\DefSubclassProc", "Ptr", hwnd, "UInt", uMsg, "Ptr", wParam, "Ptr", lParam, "Ptr")
}

; ========================= HEADER CUSTOM DRAW =========================
;
; NMCUSTOMDRAW (x64):
;   0: hwndFrom(8)  8: idFrom(8)  16: code(4)  20: pad(4)
;   24: dwDrawStage(4)  28: pad(4)  32: hdc(8)
;   40: rc(16)  56: dwItemSpec(8)  64: uItemState(4)

_Viewer_DrawHeader(lParam) {
    global gViewer_LVHeaderHwnd, gViewer_Columns, gViewer_SortCol, gViewer_SortAsc
    global gViewer_HdrHotItem, gTheme_Palette, gViewer_Sort

    stage := NumGet(lParam, 24, "UInt")

    if (stage = 0x01)  ; CDDS_PREPAINT
        return 0x30    ; CDRF_NOTIFYITEMDRAW | CDRF_NOTIFYPOSTPAINT

    if (stage = 0x02) {  ; CDDS_POSTPAINT — fill empty area after last column
        hdc := NumGet(lParam, 32, "Ptr")
        count := DllCall("SendMessageW", "Ptr", gViewer_LVHeaderHwnd, "UInt", 0x1200,
            "Ptr", 0, "Ptr", 0, "Int")  ; HDM_GETITEMCOUNT
        if (count > 0) {
            itemRc := Buffer(16, 0)
            DllCall("SendMessageW", "Ptr", gViewer_LVHeaderHwnd, "UInt", 0x1207,
                "Ptr", count - 1, "Ptr", itemRc)  ; HDM_GETITEMRECT
            lastRight := NumGet(itemRc, 8, "Int")
            headerRc := Buffer(16)
            DllCall("GetClientRect", "Ptr", gViewer_LVHeaderHwnd, "Ptr", headerRc)
            headerRight := NumGet(headerRc, 8, "Int")
            headerBottom := NumGet(headerRc, 12, "Int")
            if (lastRight < headerRight) {
                fillRc := Buffer(16)
                NumPut("Int", lastRight, "Int", 0, "Int", headerRight, "Int", headerBottom, fillRc)
                DllCall("FillRect", "Ptr", hdc, "Ptr", fillRc, "Ptr", _Viewer_GetCachedBrush(Theme_ColorToInt(gTheme_Palette.tertiary)))
            }
        }
        return 0
    }

    if (stage != 0x10001)  ; CDDS_ITEMPREPAINT
        return 0

    hdc := NumGet(lParam, 32, "Ptr")
    left := NumGet(lParam, 40, "Int"), top := NumGet(lParam, 44, "Int")
    right := NumGet(lParam, 48, "Int"), bottom := NumGet(lParam, 52, "Int")
    itemIndex := Integer(NumGet(lParam, 56, "UPtr"))
    isHot := (itemIndex = gViewer_HdrHotItem)

    ; Determine if this column shows a sort arrow
    showArrow := false
    arrowAsc := gViewer_SortAsc
    if (gViewer_SortCol >= 0 && itemIndex = gViewer_SortCol) {
        showArrow := true
    } else if (gViewer_SortCol < 0 && itemIndex = 1) {
        ; Default MRU mode: arrow on MRU column (descending = most recent first)
        showArrow := true
        arrowAsc := false
    }

    ; Background: hover / sorted column tint / normal
    if (isHot)
        bg := Theme_ColorToInt(gTheme_Palette.hover)
    else if (showArrow)
        bg := _Viewer_SortedHeaderBg()
    else
        bg := Theme_ColorToInt(gTheme_Palette.tertiary)

    rc := Buffer(16)
    NumPut("Int", left, "Int", top, "Int", right, "Int", bottom, rc)
    DllCall("FillRect", "Ptr", hdc, "Ptr", rc, "Ptr", _Viewer_GetCachedBrush(bg))

    ; Bottom border
    bdPen := _Viewer_GetCachedPen(Theme_ColorToInt(gTheme_Palette.border))
    old := DllCall("SelectObject", "Ptr", hdc, "Ptr", bdPen, "Ptr")
    DllCall("MoveToEx", "Ptr", hdc, "Int", left, "Int", bottom - 1, "Ptr", 0)
    DllCall("LineTo", "Ptr", hdc, "Int", right, "Int", bottom - 1)
    DllCall("SelectObject", "Ptr", hdc, "Ptr", old, "Ptr")

    ; Header text
    headerText := (itemIndex < gViewer_Columns.Length) ? gViewer_Columns[itemIndex + 1] : ""
    hFont := DllCall("SendMessageW", "Ptr", gViewer_LVHeaderHwnd, "UInt", 0x0031, "Ptr", 0, "Ptr", 0, "Ptr")
    if (hFont)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", hFont, "Ptr")
    DllCall("SetTextColor", "Ptr", hdc, "UInt", Theme_ColorToInt(gTheme_Palette.text))
    DllCall("SetBkMode", "Ptr", hdc, "Int", 1)  ; TRANSPARENT
    textRc := Buffer(16)
    NumPut("Int", left + 8, "Int", top, "Int", right - 24, "Int", bottom, textRc)
    DllCall("DrawText", "Ptr", hdc, "Str", headerText, "Int", -1,
        "Ptr", textRc, "UInt", 0x24)  ; DT_LEFT | DT_VCENTER | DT_SINGLELINE

    ; Sort arrow (filled triangle via GDI Polygon)
    if (showArrow) {
        arrowX := right - 18
        midY := (top + bottom) // 2
        arrowColor := Theme_ColorToInt(gTheme_Palette.accent)
        old1 := DllCall("SelectObject", "Ptr", hdc, "Ptr", _Viewer_GetCachedPen(arrowColor), "Ptr")
        old2 := DllCall("SelectObject", "Ptr", hdc, "Ptr", _Viewer_GetCachedBrush(arrowColor), "Ptr")
        ; 3 POINT structs = 24 bytes
        pts := Buffer(24, 0)
        if (arrowAsc) {
            NumPut("Int", arrowX + 4, "Int", midY - 3, pts, 0)   ; top center
            NumPut("Int", arrowX,     "Int", midY + 3, pts, 8)   ; bottom left
            NumPut("Int", arrowX + 8, "Int", midY + 3, pts, 16)  ; bottom right
        } else {
            NumPut("Int", arrowX,     "Int", midY - 3, pts, 0)   ; top left
            NumPut("Int", arrowX + 8, "Int", midY - 3, pts, 8)   ; top right
            NumPut("Int", arrowX + 4, "Int", midY + 3, pts, 16)  ; bottom center
        }
        DllCall("Polygon", "Ptr", hdc, "Ptr", pts, "Int", 3)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", old1, "Ptr")
        DllCall("SelectObject", "Ptr", hdc, "Ptr", old2, "Ptr")
    }

    return 0x04  ; CDRF_SKIPDEFAULT — must skip ALL items, not just hot
}

; ========================= ROW CUSTOM DRAW (OnNotify) =========================
;
; Receives NM_CUSTOMDRAW from the ListView via OnNotify(-12).
; This notification goes from ListView -> Gui parent (NOT through the
; subclass, which only sees header -> ListView notifications).
;
; NMLVCUSTOMDRAW extends NMCUSTOMDRAW:
;   80: clrText(4)  84: clrTextBk(4)  88: iSubItem(4)

; WM_NOTIFY handler for row NM_CUSTOMDRAW + focus events
; Routes notifications from the ListView to the appropriate handler.
; Only intercepts notifications from our ListView; everything else falls through.
_Viewer_OnWMNotify(wParam, lParam, msg, hwnd) { ; lint-ignore: dead-param  lint-ignore: mixed-returns
    global gViewer_LV, gViewer_Gui, gViewer_ShuttingDown
    if (gViewer_ShuttingDown || !gViewer_LV || !gViewer_Gui)
        return
    if (hwnd != gViewer_Gui.Hwnd)
        return
    hwndFrom := NumGet(lParam, 0, "Ptr")
    if (hwndFrom != gViewer_LV.Hwnd)
        return
    code := NumGet(lParam, 16, "Int")
    if (code = -12)          ; NM_CUSTOMDRAW
        return _Viewer_DrawListViewRow(lParam)
    if (code = -5) {         ; NM_RCLICK — defer menu to next message cycle
        SetTimer(_Viewer_ShowContextMenu, -1)
        return
    }
    if (code = -7 || code = -8)  ; NM_SETFOCUS / NM_KILLFOCUS
        DllCall("InvalidateRect", "Ptr", gViewer_LV.Hwnd, "Ptr", 0, "Int", 1)
}

_Viewer_DrawListViewRow(lParam) {
    global gViewer_HotRow, gViewer_CachedItems, gTheme_Palette, gViewer_LV

    stage := NumGet(lParam, 24, "UInt")

    if (stage = 0x01)   ; CDDS_PREPAINT
        return 0x20     ; CDRF_NOTIFYITEMDRAW

    if (stage != 0x10001)  ; Not CDDS_ITEMPREPAINT
        return 0        ; CDRF_DODEFAULT

    itemIdx := Integer(NumGet(lParam, 56, "UPtr"))

    ; Check actual selection state via LVM_GETITEMSTATE (more reliable than uItemState)
    isSelected := DllCall("SendMessageW", "Ptr", gViewer_LV.Hwnd, "UInt", 0x102C,
        "Ptr", itemIdx, "Ptr", 0x0002, "UInt") & 0x0002  ; LVIS_SELECTED
    isHot := (itemIdx = gViewer_HotRow)

    ; Check if this row is the focused window
    isFocusedWindow := false
    try {
        items := gViewer_CachedItems
        if (IsObject(items) && itemIdx < items.Length)
            isFocusedWindow := !!_Viewer_Get(items[itemIdx + 1], "isFocused", 0)
    }

    ; Determine colors based on state priority: selected > hover > focused window > alternating
    if (isSelected) {
        ; CRITICAL: Clear CDIS_SELECTED(0x01) + CDIS_FOCUS(0x10) to prevent theme override
        NumPut("UInt", NumGet(lParam, 64, "UInt") & ~0x0011, lParam, 64)
        ; Use high-contrast selection: dark accent bg + light text in dark mode, vice versa
        txColor := Theme_IsDark() ? 0xFFFFFF : 0x000000
        bgColor := _Viewer_SelectionBg()
    } else if (isHot) {
        txColor := Theme_ColorToInt(gTheme_Palette.text)
        bgColor := Theme_ColorToInt(gTheme_Palette.hover)
    } else if (isFocusedWindow) {
        txColor := Theme_ColorToInt(gTheme_Palette.text)
        bgColor := _Viewer_FocusedRowBg()
    } else {
        txColor := Theme_ColorToInt(gTheme_Palette.editText)
        bgColor := (itemIdx & 1) ? _Viewer_AltRowBg() : Theme_ColorToInt(gTheme_Palette.editBg)
    }

    NumPut("UInt", txColor, lParam, 80)   ; clrText
    NumPut("UInt", bgColor, lParam, 84)   ; clrTextBk
    return 0x02  ; CDRF_NEWFONT
}

; ========================= CUSTOM DRAW COLOR HELPERS =========================

; Sorted column header — slight tint of tertiary
_Viewer_SortedHeaderBg() {
    global gTheme_Palette
    base := Theme_ColorToInt(gTheme_Palette.tertiary)
    ; Lighten/darken slightly
    r := (base) & 0xFF, g := (base >> 8) & 0xFF, b := (base >> 16) & 0xFF
    if (Theme_IsDark()) {
        r := Min(r + 12, 255), g := Min(g + 12, 255), b := Min(b + 12, 255)
    } else {
        r := Max(r - 12, 0), g := Max(g - 12, 0), b := Max(b - 12, 0)
    }
    return (b << 16) | (g << 8) | r
}

; Alternating row — subtle variant of editBg
_Viewer_AltRowBg() {
    global gTheme_Palette
    base := Theme_ColorToInt(gTheme_Palette.editBg)
    r := (base) & 0xFF, g := (base >> 8) & 0xFF, b := (base >> 16) & 0xFF
    if (Theme_IsDark()) {
        r := Min(r + 8, 255), g := Min(g + 8, 255), b := Min(b + 8, 255)
    } else {
        r := Max(r - 8, 0), g := Max(g - 8, 0), b := Max(b - 8, 0)
    }
    return (b << 16) | (g << 8) | r
}

; Focused window row — 15% accent blend over editBg
_Viewer_FocusedRowBg() {
    global gTheme_Palette
    base := Theme_ColorToInt(gTheme_Palette.editBg)
    accent := Theme_ColorToInt(gTheme_Palette.accent)
    blend := 0.15
    br := (base) & 0xFF, bg := (base >> 8) & 0xFF, bb := (base >> 16) & 0xFF
    ar := (accent) & 0xFF, ag := (accent >> 8) & 0xFF, ab := (accent >> 16) & 0xFF
    r := Integer(br * (1 - blend) + ar * blend)
    g := Integer(bg * (1 - blend) + ag * blend)
    b := Integer(bb * (1 - blend) + ab * blend)
    return (b << 16) | (g << 8) | r
}

; Selection row — muted accent (40% accent over editBg) for readable contrast
_Viewer_SelectionBg() {
    global gTheme_Palette
    base := Theme_ColorToInt(gTheme_Palette.editBg)
    accent := Theme_ColorToInt(gTheme_Palette.accent)
    blend := 0.40
    br := (base) & 0xFF, bg := (base >> 8) & 0xFF, bb := (base >> 16) & 0xFF
    ar := (accent) & 0xFF, ag := (accent >> 8) & 0xFF, ab := (accent >> 16) & 0xFF
    r := Integer(br * (1 - blend) + ar * blend)
    g := Integer(bg * (1 - blend) + ag * blend)
    b := Integer(bb * (1 - blend) + ab * blend)
    return (b << 16) | (g << 8) | r
}

; ========================= HEADER GDI CACHE =========================

; Get or create a cached GDI brush for the given color.
; Working set is ~4 colors (tertiary, hover, sorted, accent); no eviction needed.
; Invalidated on theme change via _Viewer_ClearHeaderCache().
_Viewer_GetCachedBrush(color) {
    global gViewer_HdrBrushCache
    if (gViewer_HdrBrushCache.Has(color))
        return gViewer_HdrBrushCache[color]
    hBrush := DllCall("CreateSolidBrush", "UInt", color, "Ptr")
    gViewer_HdrBrushCache[color] := hBrush
    return hBrush
}

; Get or create a cached GDI pen for the given color.
_Viewer_GetCachedPen(color) {
    global gViewer_HdrPenCache
    if (gViewer_HdrPenCache.Has(color))
        return gViewer_HdrPenCache[color]
    hPen := DllCall("CreatePen", "Int", 0, "Int", 1, "UInt", color, "Ptr")
    gViewer_HdrPenCache[color] := hPen
    return hPen
}

; Destroy all cached header GDI objects. Call on theme change and shutdown.
_Viewer_ClearHeaderCache() {
    global gViewer_HdrBrushCache, gViewer_HdrPenCache
    for _, h in gViewer_HdrBrushCache
        try DllCall("DeleteObject", "Ptr", h)
    for _, h in gViewer_HdrPenCache
        try DllCall("DeleteObject", "Ptr", h)
    gViewer_HdrBrushCache := Map()
    gViewer_HdrPenCache := Map()
}

; ========================= HOVER TRACKING =========================

_Viewer_StartHoverTimer() {
    global gViewer_HoverTimerFn
    if (gViewer_HoverTimerFn)
        return
    gViewer_HoverTimerFn := _Viewer_CheckHover.Bind()
    SetTimer(gViewer_HoverTimerFn, 30)  ; lint-ignore: timer-lifecycle (cancelled via _Viewer_StopHoverTimer using bound ref)
}

_Viewer_StopHoverTimer() {
    global gViewer_HoverTimerFn, gViewer_LastTipHwnd
    if (gViewer_HoverTimerFn) {
        try SetTimer(gViewer_HoverTimerFn, 0)
        gViewer_HoverTimerFn := 0
    }
    ; Clear any lingering tooltip
    if (gViewer_LastTipHwnd != 0) {
        gViewer_LastTipHwnd := 0
        ToolTip(, , , 2)
    }
}

_Viewer_CheckHover() {
    global gViewer_LV, gViewer_LVHeaderHwnd, gViewer_HotRow, gViewer_HdrHotItem
    global gViewer_ShuttingDown, gViewer_LastTipHwnd
    global gViewer_WSBtn, gViewer_MinBtn, gViewer_CloakBtn
    if (gViewer_ShuttingDown || !gViewer_LV)
        return

    pt := Buffer(8, 0)
    DllCall("GetCursorPos", "Ptr", pt)

    ; -- ListView row hover --
    newHotRow := -1
    lvPt := Buffer(8, 0)
    NumPut("Int", NumGet(pt, 0, "Int"), "Int", NumGet(pt, 4, "Int"), lvPt)
    DllCall("ScreenToClient", "Ptr", gViewer_LV.Hwnd, "Ptr", lvPt)
    ; LVHITTESTINFO: POINT(8) + flags(4) + iItem(4) + iSubItem(4) + iGroup(4) = 24
    hitInfo := Buffer(24, 0)
    NumPut("Int", NumGet(lvPt, 0, "Int"), "Int", NumGet(lvPt, 4, "Int"), hitInfo)
    hitRow := DllCall("SendMessageW", "Ptr", gViewer_LV.Hwnd, "UInt", 0x1012,
        "Ptr", 0, "Ptr", hitInfo, "Int")  ; LVM_HITTEST
    if (hitRow >= 0)
        newHotRow := hitRow
    if (newHotRow != gViewer_HotRow) {
        oldRow := gViewer_HotRow
        gViewer_HotRow := newHotRow
        if (oldRow >= 0)
            _Viewer_InvalidateRow(oldRow)
        if (newHotRow >= 0)
            _Viewer_InvalidateRow(newHotRow)
    }

    ; -- Header item hover --
    hwndUnder := DllCall("WindowFromPoint", "Int64", NumGet(pt, 0, "Int64"), "Ptr")
    newHotHdr := -1
    if (hwndUnder = gViewer_LVHeaderHwnd) {
        hdrPt := Buffer(8, 0)
        NumPut("Int", NumGet(pt, 0, "Int"), "Int", NumGet(pt, 4, "Int"), hdrPt)
        DllCall("ScreenToClient", "Ptr", gViewer_LVHeaderHwnd, "Ptr", hdrPt)
        ; HDHITTESTINFO: POINT(8) + flags(4) + iItem(4) = 16
        hdrHit := Buffer(16, 0)
        NumPut("Int", NumGet(hdrPt, 0, "Int"), "Int", NumGet(hdrPt, 4, "Int"), hdrHit)
        DllCall("SendMessageW", "Ptr", gViewer_LVHeaderHwnd, "UInt", 0x1206,
            "Ptr", 0, "Ptr", hdrHit)  ; HDM_HITTEST
        hitItem := NumGet(hdrHit, 12, "Int")
        flags := NumGet(hdrHit, 8, "UInt")
        if (flags & 0x06)  ; HHT_ONHEADER(0x02) | HHT_ONDIVIDER(0x04)
            newHotHdr := hitItem
    }
    if (newHotHdr != gViewer_HdrHotItem) {
        gViewer_HdrHotItem := newHotHdr
        if (gViewer_LVHeaderHwnd)
            DllCall("InvalidateRect", "Ptr", gViewer_LVHeaderHwnd, "Ptr", 0, "Int", 1)
    }

    ; -- Button tooltips (tooltip #2, avoids collision with toast #1) --
    tipText := ""
    if (IsObject(gViewer_WSBtn) && hwndUnder = gViewer_WSBtn.Hwnd)
        tipText := "Show all workspaces or current only"
    else if (IsObject(gViewer_MinBtn) && hwndUnder = gViewer_MinBtn.Hwnd)
        tipText := "Include (+) or exclude (-) minimized windows"
    else if (IsObject(gViewer_CloakBtn) && hwndUnder = gViewer_CloakBtn.Hwnd)
        tipText := "Include (+) or exclude (-) cloaked windows"

    if (tipText != "") {
        if (hwndUnder != gViewer_LastTipHwnd) {
            gViewer_LastTipHwnd := hwndUnder
            ToolTip(tipText, , , 2)
        }
    } else if (gViewer_LastTipHwnd != 0) {
        gViewer_LastTipHwnd := 0
        ToolTip(, , , 2)
    }
}

_Viewer_InvalidateRow(rowIdx) {
    global gViewer_LV
    rc := Buffer(16, 0)
    NumPut("Int", 0, rc, 0)  ; LVIR_BOUNDS
    DllCall("SendMessageW", "Ptr", gViewer_LV.Hwnd, "UInt", 0x100E, "Ptr", rowIdx, "Ptr", rc)  ; LVM_GETITEMRECT
    DllCall("InvalidateRect", "Ptr", gViewer_LV.Hwnd, "Ptr", rc, "Int", 1)
}

; ========================= COLUMN CLICK SORT =========================

_Viewer_OnColClick(lv, col) { ; lint-ignore: dead-param
    global gViewer_SortCol, gViewer_SortAsc, gViewer_LVHeaderHwnd, gViewer_LastRev
    global gViewer_ShuttingDown
    if (gViewer_ShuttingDown)
        return

    colIdx := col - 1  ; AHK v2 OnEvent("ColClick") is 1-based

    if (colIdx = gViewer_SortCol) {
        gViewer_SortAsc := !gViewer_SortAsc
    } else {
        gViewer_SortCol := colIdx
        gViewer_SortAsc := true
    }

    ; Force header repaint (sort arrow update)
    if (gViewer_LVHeaderHwnd)
        DllCall("InvalidateRect", "Ptr", gViewer_LVHeaderHwnd, "Ptr", 0, "Int", 1)

    ; Re-sort and update
    gViewer_LastRev := -1
    _Viewer_Refresh()
}

; ========================= CONTEXT MENU =========================

_Viewer_ShowContextMenu() {
    global gViewer_ShuttingDown, gViewer_LV
    if (gViewer_ShuttingDown)
        return

    try {
        ; Get selected row (0 = no selection)
        idx := DllCall("SendMessageW", "Ptr", gViewer_LV.Hwnd,
            "UInt", 0x100C, "Ptr", -1, "Ptr", 0x0002, "Ptr")  ; LVM_GETNEXTITEM, LVNI_SELECTED
        row := (idx >= 0) ? idx + 1 : 0  ; Convert 0-based to 1-based
        cellHwnd := ""
        cellPid := ""
        cellTitle := ""
        cellClass := ""
        cellProc := ""
        if (row > 0) {
            cellHwnd := gViewer_LV.GetText(row, 3)
            cellPid := gViewer_LV.GetText(row, 4)
            cellTitle := gViewer_LV.GetText(row, 5)
            cellClass := gViewer_LV.GetText(row, 6)
            cellProc := gViewer_LV.GetText(row, 9)
        }

        ; Store action data in global map — menu callback looks up by item name
        ; Menu object MUST be global — local Menu gets GC'd when Show() returns,
        ; before AHK launches the callback thread (root cause of silent callback failure)
        global gViewer_MenuActions, gViewer_CtxMenu
        gViewer_MenuActions := Map()
        gViewer_CtxMenu := Menu()

        if (row > 0) {
            truncTitle := SubStr(cellTitle, 1, 30) (StrLen(cellTitle) > 30 ? "..." : "")
            n1 := "Blacklist Class: " cellClass
            n2 := "Blacklist Title: " truncTitle
            n3 := "Blacklist Pair: " cellClass "|" truncTitle
            gViewer_MenuActions[n1] := {action: "bl_class", arg1: cellClass, arg2: cellTitle}
            gViewer_MenuActions[n2] := {action: "bl_title", arg1: cellClass, arg2: cellTitle}
            gViewer_MenuActions[n3] := {action: "bl_pair", arg1: cellClass, arg2: cellTitle}
            gViewer_CtxMenu.Add(n1, _Viewer_OnMenuClick)
            gViewer_CtxMenu.Add(n2, _Viewer_OnMenuClick)
            gViewer_CtxMenu.Add(n3, _Viewer_OnMenuClick)
            gViewer_CtxMenu.Add()  ; separator
            gViewer_MenuActions["Close Window"] := {action: "close", arg1: cellHwnd, arg2: ""}
            gViewer_MenuActions["Kill Process (PID " cellPid ")"] := {action: "kill", arg1: cellPid, arg2: ""}
            gViewer_CtxMenu.Add("Close Window", _Viewer_OnMenuClick)
            gViewer_CtxMenu.Add("Kill Process (PID " cellPid ")", _Viewer_OnMenuClick)
            gViewer_CtxMenu.Add()  ; separator
        }

        gViewer_MenuActions["Copy All Rows"] := {action: "copy_all", arg1: "", arg2: ""}
        gViewer_CtxMenu.Add("Copy All Rows", _Viewer_OnMenuClick)

        if (row > 0) {
            gViewer_MenuActions["Copy Row"] := {action: "copy_row", arg1: row, arg2: ""}
            gViewer_CtxMenu.Add("Copy Row", _Viewer_OnMenuClick)
            gViewer_MenuActions["Copy HWND"] := {action: "copy", arg1: cellHwnd, arg2: ""}
            gViewer_MenuActions["Copy Title"] := {action: "copy", arg1: cellTitle, arg2: ""}
            gViewer_MenuActions["Copy Class"] := {action: "copy", arg1: cellClass, arg2: ""}
            gViewer_MenuActions["Copy Process"] := {action: "copy", arg1: cellProc, arg2: ""}
            gViewer_CtxMenu.Add("Copy HWND", _Viewer_OnMenuClick)
            gViewer_CtxMenu.Add("Copy Title", _Viewer_OnMenuClick)
            gViewer_CtxMenu.Add("Copy Class", _Viewer_OnMenuClick)
            gViewer_CtxMenu.Add("Copy Process", _Viewer_OnMenuClick)
        }

        ; Ensure thread is interruptible so callback thread can launch after Show() returns
        Critical "Off"
        gViewer_CtxMenu.Show()
    } catch as e {
        global LOG_PATH_STORE
        try LogAppend(LOG_PATH_STORE, "ContextMenu error: " e.Message " Extra=" e.Extra)
    }
}

; Menu click callback — looks up action data from gViewer_MenuActions by item name
_Viewer_OnMenuClick(itemName, itemPos, menuObj) { ; lint-ignore: dead-param
    global gViewer_MenuActions
    if (!gViewer_MenuActions.Has(itemName))
        return
    data := gViewer_MenuActions[itemName]
    action := data.action
    arg1 := data.arg1
    arg2 := data.arg2

    if (action = "bl_class")
        _Viewer_DoBlacklist("class", arg1, arg2)
    else if (action = "bl_title")
        _Viewer_DoBlacklist("title", arg1, arg2)
    else if (action = "bl_pair")
        _Viewer_DoBlacklist("pair", arg1, arg2)
    else if (action = "close")
        _Viewer_DoCloseWindow(arg1)
    else if (action = "kill")
        _Viewer_DoKillProcess(arg1)
    else if (action = "copy_all")
        _Viewer_DoCopyAll()
    else if (action = "copy_row")
        _Viewer_DoCopyRow(arg1)
    else if (action = "copy")
        A_Clipboard := arg1
}

_Viewer_DoBlacklist(mode, cls, ttl) {
    success := false
    toastMsg := ""
    if (mode = "class") {
        success := Blacklist_AddClass(cls)
        toastMsg := "Blacklisted class: " cls
    } else if (mode = "title") {
        success := Blacklist_AddTitle(ttl)
        toastMsg := "Blacklisted title: " ttl
    } else if (mode = "pair") {
        success := Blacklist_AddPair(cls, ttl)
        toastMsg := "Blacklisted pair: " cls "|" ttl
    }

    if (!success) {
        _Viewer_ShowToast("Failed to write to blacklist.txt")
        return
    }

    ; Reload blacklist and purge directly (in-process)
    Blacklist_Init()
    WL_PurgeBlacklisted()
    _Viewer_ShowToast(toastMsg)
    _Viewer_ForceRefresh()
}

_Viewer_DoCloseWindow(hwndStr) {
    try {
        hwnd := Integer(hwndStr)
        WinClose("ahk_id " hwnd)
    } catch {
        _Viewer_ShowToast("Failed to close window")
        return
    }
    _Viewer_ForceRefresh()
}

_Viewer_DoKillProcess(pidStr) {
    try {
        pid := Integer(pidStr)
        ProcessClose(pid)
    } catch {
        _Viewer_ShowToast("Failed to kill process")
        return
    }
    _Viewer_ForceRefresh()
}

_Viewer_DoCopyAll() {
    global gViewer_Columns, gViewer_LV
    lv := gViewer_LV
    ; Build TSV with headers
    text := ""
    for _, col in gViewer_Columns
        text .= col "`t"
    text := RTrim(text, "`t") "`n"

    ; Build rows
    rowCount := lv.GetCount()
    loop rowCount {
        row := A_Index
        line := ""
        loop gViewer_Columns.Length
            line .= lv.GetText(row, A_Index) "`t"
        text .= RTrim(line, "`t") "`n"
    }

    A_Clipboard := text
    _Viewer_ShowToast("Copied " rowCount " rows to clipboard")
}

_Viewer_DoCopyRow(row) {
    global gViewer_Columns, gViewer_LV
    line := ""
    loop gViewer_Columns.Length
        line .= gViewer_LV.GetText(row, A_Index) "`t"
    A_Clipboard := RTrim(line, "`t")
    _Viewer_ShowToast("Copied row to clipboard")
}

; ========================= THEME CHANGE =========================

_Viewer_OnThemeChange() {
    global gViewer_Gui, gViewer_LV, gViewer_LVHeaderHwnd, gViewer_ShuttingDown
    if (gViewer_ShuttingDown || !gViewer_Gui)
        return

    ; Flush cached GDI objects — palette colors have changed
    _Viewer_ClearHeaderCache()

    ; Theme system already re-applies tracked controls.
    ; Force repaint for our custom draw areas.
    if (gViewer_LV)
        DllCall("InvalidateRect", "Ptr", gViewer_LV.Hwnd, "Ptr", 0, "Int", 1)
    if (gViewer_LVHeaderHwnd)
        DllCall("InvalidateRect", "Ptr", gViewer_LVHeaderHwnd, "Ptr", 0, "Int", 1)
}

; ========================= BLACKLIST (DOUBLE-CLICK) =========================

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

    _Viewer_DoBlacklist(choice, class, title)
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
    dlgEntry := Theme_ApplyToGui(dlg)

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

    btn1 := dlg.AddButton("x24 y+24 w100 h30", "Add Class")
    btn1.OnEvent("Click", (*) => _Viewer_BlacklistChoice(dlg, "class"))
    Theme_ApplyToControl(btn1, "Button", dlgEntry)
    btn2 := dlg.AddButton("x132 yp w100 h30", "Add Title")
    btn2.OnEvent("Click", (*) => _Viewer_BlacklistChoice(dlg, "title"))
    Theme_ApplyToControl(btn2, "Button", dlgEntry)
    btn3 := dlg.AddButton("x240 yp w100 h30", "Add Pair")
    btn3.OnEvent("Click", (*) => _Viewer_BlacklistChoice(dlg, "pair"))
    Theme_ApplyToControl(btn3, "Button", dlgEntry)
    btn4 := dlg.AddButton("x364 yp w100 h30", "Cancel")
    btn4.OnEvent("Click", (*) => _Viewer_BlacklistChoice(dlg, ""))
    Theme_ApplyToControl(btn4, "Button", dlgEntry)

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
