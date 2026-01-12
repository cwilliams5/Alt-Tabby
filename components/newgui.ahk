#Requires AutoHotkey v2.0
; -----------------------------------------------------------------------------
; overlay_list_on_acrylic_poc_scroll_icons.ahk
; - Base: borderless acrylic (no flash)
; - Overlay: layered window same size/pos (catches all clicks), renders a simple
;            “virtual list” with columns + real icon + selection + scroll wheel.
;   Hotkeys:
;   Up/Down, Tab/Shift+Tab : change selection (keeps selection in view)
;   Mouse wheel            : scroll by rows
;   Q                      : cycle footer text (POC)
;   C / K / B              : close / kill (confirm) / blacklist (confirm)
;   Esc                    : exit
; -----------------------------------------------------------------------------

; Reveal both base + overlay together right after first painted frame
global gRevealed := false

global gHoverRow := 0        ; 1-based item index that the mouse is over; 0 = none
global gHoverBtn := ""       ; "", "close", "kill", "blacklist"

; persistent Graphics bound to the backbuffer HDC
global gG := 0

; Footer state (POC text cycle with Q)
global gFooterModes := ["All Windows", "XXX Windows", "XXX Visible Windows"]
global gFooterModeIndex := 1
global gFooterText := gFooterModes[gFooterModeIndex]


; ===== Overlay wiring compatibility (from oldgui) =====
global gGui := 0                  ; your overlay’s top-level GUI/window handle holder
global gOverlayOn := false
global gListSnap := []            ; last list handed to overlay
global gSelSnap := 1              ; last 1-based selection index

; ----- icon cache/pump (GUI-independent) -----
global gIconCache := Map()        ; hwnd -> { hicon: Ptr | 0, pid: UInt, class: Str }
global gIconQueue := []           ; hwnds pending resolution
global gIconPumpOn := false

; Use your existing config entries:
; OverlayTitle := "Switch"
; GUI_StateShort := true
; GUI_HWND_Hex := true
; UseIcons, IconBatchPerTick, IconTimerIntervalMs


; ========================= DEBUG =========================
global DebugGUI := false
global DebugLogPath := A_ScriptDir "\tabby_debug.log"

_DBG(msg) {
    if !DebugGUI {
        return
    }
    path := (DebugLogPath && DebugLogPath != "") ? DebugLogPath : (A_ScriptDir "\tabby_debug.log")
    ts := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    SplitPath(path, , &dir)
    try DirCreate(dir)
    FileAppend(ts " | " msg "`r`n", path, "UTF-8")
}

_DWM_SetAttrInt(hWnd, attrId, value) {
    buf := Buffer(4, 0)
    NumPut("Int", value, buf, 0)
    hr := DllCall("dwmapi\DwmSetWindowAttribute"
        , "ptr", hWnd
        , "int", attrId
        , "ptr", buf.Ptr
        , "int", 4
        , "int")
    _DBG(Format("DWM attr{} val={} hr={}", attrId, value, hr))
    return hr
}

_ConfirmTopmost(text, title := "Confirm") {
    global gOverlayH  ; or gBaseH – either is fine; the owner just needs to be your UI
    res := MsgBox(text, title, "YesNo Icon! Default2 0x1000")
    return (res = "Yes" || res = 6) ; string ("Yes") or numeric (6) for compatibility
}

_FooterBlockDip() {
    global ShowFooter, FooterHeightPx, FooterGapTopPx
    return ShowFooter ? (FooterGapTopPx + FooterHeightPx) : 0
}


_DebugDump(hGui) {
    try _DBG("OS: " A_OSVersion)
    try {
        enabled := 0
        hr := DllCall("dwmapi\DwmIsCompositionEnabled", "int*", &enabled, "int")
        _DBG(Format("DwmIsCompositionEnabled={} hr={}", enabled, hr))
    }
    try {
        trans := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "EnableTransparency")
        if (trans = "") {
            trans := "N/A"
        }
        _DBG("EnableTransparency=" trans)
    }
    try {
        GWL_STYLE := -16, GWL_EXSTYLE := -20
        ex := DllCall("user32\GetWindowLongPtrW", "ptr", hGui, "int", GWL_EXSTYLE, "ptr")
        st := DllCall("user32\GetWindowLongPtrW", "ptr", hGui, "int", GWL_STYLE,   "ptr")
        _DBG(Format("GUI style=0x{:X} exstyle=0x{:X}", st, ex))
    }
}

; ========================= NEWGUI PUBLIC SHIMS (ADD) =========================
global __HooksInstalled := false
global __InitOnce := false

NewGUI__EnsureCreated() {
    global __InitOnce, __HooksInstalled
    global gBase, gBaseH, gOverlay, gOverlayH, gGui
    global OverlayTitle, AlwaysOnTop
    global AcrylicAlpha, AcrylicBaseRgb, CornerRadiusPx
    global gListSnap

    if (__InitOnce && gBaseH && gOverlayH)
        return

    ; --- init DPI & GDI+ once ---
    _InitDpiAwareness()
    __Gdip_Startup()

    ; --- compute initial size from current list (or minimum) ---
    rowsDesired := _ComputeRowsToShow(IsObject(gListSnap) ? gListSnap.Length : RowsVisibleMin)
    winX := 0, winY := 0, winW := 0, winH := 0
    _GetWindowRectFromConfig(&winX, &winY, &winW, &winH, rowsDesired)

    ; --- create base (titled) window; this will be our public "GUI" handle ---
    opts := "-Caption"
    if (IsSet(AlwaysOnTop) && AlwaysOnTop)
        opts := "+AlwaysOnTop " . opts
    gBase := Gui(opts, OverlayTitle)
    _StageAndRevealAcrylic(gBase, winX, winY, winW, winH, AcrylicAlpha, AcrylicBaseRgb, CornerRadiusPx, false)
    gBaseH := gBase.Hwnd

    ; Expose the same top-level handle symbol the old code used.
    gGui := gBaseH

    ; --- layered overlay for the painted list ---
    gOverlay  := _Overlay_Create(gBaseH)
    gOverlayH := gOverlay.Hwnd

    ; --- minimal hooks (mouse + wheel + DPI) once ---
    if !__HooksInstalled {
        OnMessage(0x02E0, _OnDpiChanged) ; WM_DPICHANGED
        OnMessage(0x0200, (wParam, lParam, msg, hwnd) => (
            hwnd = gOverlayH ? ( _OnOverlayMouseMove(wParam, lParam, msg, hwnd), 0 ) : 0
        )) ; WM_MOUSEMOVE
        OnMessage(0x0201, (wParam, lParam, msg, hwnd) => (
            hwnd = gOverlayH ? ( _OnOverlayClick(lParam & 0xFFFF, (lParam >> 16) & 0xFFFF), 0 ) : 0
        )) ; WM_LBUTTONDOWN
        OnMessage(0x020A, (wParam, lParam, msg, hwnd) => (
            hwnd = gOverlayH ? ( _OnOverlayWheel(wParam, lParam), 0 ) : 0
        )) ; WM_MOUSEWHEEL
        __HooksInstalled := true
    }

    __InitOnce := true
}

NewGUI__RebuildFromList(list, selIndex) {
    global gItems, gSel, gScrollTop, gOverlayH

    ; build row models strictly from provided list (no test strings)
    gItems := []
    total := list.Length
    if (total > 0) {
        i := 1
        while (i <= total) {
            gItems.Push( NewGUI__BuildRowModel(list[i], i, total) )
            i += 1
        }
    }

    ; selection + viewport
    if (total = 0) {
        gSel := 1
        gScrollTop := 0
    } else {
        if (selIndex < 1) selIndex := 1
        if (selIndex > total) selIndex := total
        gSel := selIndex
        if (IsSet(ScrollKeepHighlightOnTop) && ScrollKeepHighlightOnTop)
            gScrollTop := gSel - 1
        else
            _EnsureVisible(total)  ; your existing helper
    }

    ; resize and paint
    rowsDesired := _ComputeRowsToShow(total)
    _ResizeWindowToRows(rowsDesired)
    _Overlay_Repaint(gOverlayH, gItems, gSel)
}


NewGUI__UpdateSelection(list, selIndex) {
    ; Rebuild (safe & simple; keeps columns/state fresh as windows change)
    NewGUI__RebuildFromList(list, selIndex)
}

NewGUI__QueueIconsForVisibleRows(list, selIndex) {
    global gIconQueue, gOverlayH, gScrollTop, RowsVisibleMax

    count := list.Length
    if (count <= 0)
        return

    ; how many rows are currently visible on the overlay
    vis := _GetVisibleRowsFromOverlay()
    if (vis <= 0)
        vis := Min(RowsVisibleMax, count)

    ; viewport top (0-based), and selected row (0-based)
    top0 := __Wrap0(gScrollTop, count)
    sel0 := __Wrap0(selIndex - 1, count)

    ; order = selected (if visible) first, then the rest of the visible rows
    seen  := Map()   ; 0-based idx -> true
    order := []

    ; selected first if it's in the visible window
    i := 0
    while (i < vis) {
        idx0 := __Wrap0(top0 + i, count)
        if (idx0 = sel0) {
            order.Push(idx0)
            seen[idx0] := true
            break
        }
        i += 1
    }

    ; then the rest, in viewport order, skipping what we've already added
    i := 0
    while (i < vis) {
        idx0 := __Wrap0(top0 + i, count)
        if !seen.Has(idx0) {
            order.Push(idx0)
            seen[idx0] := true
        }
        i += 1
    }

    ; enqueue icon resolves for rows that lack a cached icon and still exist
    for _, idx0 in order {
        it := list[idx0 + 1]              ; convert 0-based -> 1-based
        if (_Icon_GetCached(it.Hwnd) = 0 && WinExist("ahk_id " it.Hwnd)) {
            gIconQueue.Push(it.Hwnd)
        }
    }
}



NewGUI__InvalidateVisibleRows(list, selIndex) {
    global gOverlayH, gItems, gSel
    _Overlay_Repaint(gOverlayH, gItems, gSel)
}

NewGUI__Show() {
    global gBase, gOverlay
    ; Show both immediately (no “first-paint” gate so Alt+Tab never stalls)
    try gBase.Show("NA")
    try gOverlay.Show("NA")
}

NewGUI__Hide() {
    global gBase, gOverlay
    try gOverlay.Hide()
    try gBase.Hide()
}

_GetVisibleRowsFromOverlay() {
    global gOverlayH, RowHeight, MarginY
    try {
        cx := 0, cy := 0, cw := 0, ch := 0
        WinGetClientPos &cx, &cy, &cw, &ch, "ahk_id " gOverlayH
        listArea := ch - (MarginY + _HeaderBlockDip() + _FooterBlockDip() + MarginY)
        if (listArea <= 0)
            return 0
        return Max(0, Floor(listArea / RowHeight))
    } catch {
        return 0
    }
}


; ======= OLD to NEW API SHIM ========
Overlay_ShowList(list, selIndex) {
    global gGui, gOverlayOn, gListSnap, gSelSnap, UseIcons, OverlayTitle, AlwaysOnTop

    ; snapshot real list/selection (no test data)
    gListSnap := IsObject(list) ? list : []
    gSelSnap  := (selIndex >= 1 ? selIndex : 1)

    ; ensure overlay exists
    NewGUI__EnsureCreated()
    try WinSetTitle(OverlayTitle, "ahk_id " gGui)
    if (IsSet(AlwaysOnTop) && AlwaysOnTop)
        try WinSetAlwaysOnTop(1, "ahk_id " gGui)

    ; build rows from the real list (no dummy generation)
    NewGUI__RebuildFromList(gListSnap, gSelSnap)

    ; icon prefetch for currently visible rows
    if (IsSet(UseIcons) && UseIcons) {
        NewGUI__QueueIconsForVisibleRows(gListSnap, gSelSnap)
        _Icon_StartPump()
    }

    ; show right now
    NewGUI__Show()
    gOverlayOn := true
}


Overlay_UpdateSelection(list, selIndex) {
    global gListSnap, gSelSnap, UseIcons, gItems, gOverlayH, gSel

    if (!IsObject(list))
        list := []

    ; If only the selection changed (same object/length), avoid rebuild.
    sameLen := (IsObject(gItems) ? (gItems.Length = list.Length) : false)

    gListSnap := list
    gSelSnap  := selIndex

    if (sameLen && gItems.Length > 0) {
        ; paint-only selection update path
        if (selIndex < 1) selIndex := 1
        if (selIndex > gItems.Length) selIndex := gItems.Length
        gSel := selIndex
        _EnsureVisible(gItems.Length)
        _Overlay_Repaint(gOverlayH, gItems, gSel)

        if (IsSet(UseIcons) && UseIcons)
            NewGUI__QueueIconsForVisibleRows(gListSnap, gSelSnap)
        return
    }

    ; otherwise rebuild rows (length or content changed)
    NewGUI__RebuildFromList(gListSnap, gSelSnap)
    if (IsSet(UseIcons) && UseIcons)
        NewGUI__QueueIconsForVisibleRows(gListSnap, gSelSnap)
}



Overlay_Hide() {
    global gGui, gOverlayOn
    gOverlayOn := false
    NewGUI__Hide()                                   ; your hide/destroy path
    ; Optional: _Icon_ClearCache() if you want to free HICONs aggressively
}

; Returns a plain object with what your painter needs for a row
NewGUI__BuildRowModel(item, idx, total) {
    ; Main + sub
    main := item.Title
    if (StrLen(main) > 140)
        main := SubStr(main, 1, 137) . "..."
    sub  := _StateShort(item.State)

    ; Column text
    hwndStr := (IsSet(GUI_HWND_Hex) && GUI_HWND_Hex)
        ? ("0x" . Format("{:X}", item.Hwnd))
        : (item.Hwnd . "")
    ws := _GetWorkspaceForHwnd(item.Hwnd)

    ; Icon handle if cached (0 until pump resolves)
    hico := _Icon_GetCached(item.Hwnd)

    ; Include both display columns and raw fields so existing code (close/kill placeholders)
    ; can use HWND/PID/Class safely later.
    return {
        Number: "[" idx "/" total "]",
        Title:  main,
        Sub:    sub,
        Col2:   hwndStr,       ; HWND (formatted)
        Col3:   item.Pid,      ; PID
        Col4:   ws,            ; Workspace name
        Col5:   item.ZOrder,   ; Win#
        Col6:   item.Class,    ; Class
        HICON:  hico,

        ; raw passthroughs for actions / future wiring
        HWND:   item.Hwnd,
        PID:    item.Pid,
        Class:  item.Class,
        State:  item.State,
        ZOrder: item.ZOrder
    }
}


;========= ICONS =============
_Icon_GetCached(hwnd) {
    global gIconCache
    return (gIconCache.Has(hwnd) && gIconCache[hwnd].hicon) ? gIconCache[hwnd].hicon : 0
}

_Icon_StartPump() {
    global gIconPumpOn, IconTimerIntervalMs
    if (gIconPumpOn)
        return
    gIconPumpOn := true
    SetTimer(_Icon_Pump, IconTimerIntervalMs)
}

_Icon_Pump() {
    global gIconPumpOn, gIconQueue, IconBatchPerTick, gIconCache, gOverlayOn, gListSnap, gSelSnap

    if (!gOverlayOn) {
        gIconQueue := []
        gIconPumpOn := false
        SetTimer(_Icon_Pump, 0)
        return
    }

    ; resolve a few per tick
    count := 0
    changed := false
    while (gIconQueue.Length && count < IconBatchPerTick) {
        hwnd := gIconQueue.RemoveAt(1)
        if (gIconCache.Has(hwnd)) {
            count += 1
            continue
        }

        pid := 0, cls := ""
        for _, it in gListSnap {           ; fast linear scan OK for small page
            if (it.Hwnd = hwnd) {
                pid := it.Pid
                cls := it.Class
                break
            }
        }

        hico := _Icon_ResolveSmall(hwnd)
        if (!hico) {
            ; attempt from process exe if window didn’t return one
            if (pid) {
                exe := _Icon_GetProcessPath(pid)
                if (exe) {
                    hSmall := 0, hLarge := 0
                    DllCall("Shell32\ExtractIconExW","wstr",exe,"int",0,"ptr*", &hLarge,"ptr*", &hSmall,"uint",1)
                    if (hSmall) {
                        if (hLarge) DllCall("user32\DestroyIcon","ptr",hLarge)
                        hico := hSmall
                    } else if (hLarge) {
                        hico := hLarge
                    }
                }
            }
        }

        gIconCache[hwnd] := { hicon: (hico ? hico : 0), pid: pid, class: cls }
        changed := changed || (hico != 0)
        count += 1
    }

    if (!gIconQueue.Length) {
        gIconPumpOn := false
        SetTimer(_Icon_Pump, 0)
    }

    if (changed) {
        ; Ask your view to redraw only visible rows
        NewGUI__InvalidateVisibleRows(gListSnap, gSelSnap)
    }
}

_Icon_ResolveSmall(hWnd) {
    if !WinExist("ahk_id " . hWnd)
        return 0
    WM_GETICON := 0x7F
    ICON_SMALL2 := 2, ICON_SMALL := 0, ICON_BIG := 1
    try {
        h := SendMessage(WM_GETICON, ICON_SMALL2, 0, , "ahk_id " . hWnd)
        if (!h) h := SendMessage(WM_GETICON, ICON_SMALL, 0, , "ahk_id " . hWnd)
        if (!h) h := SendMessage(WM_GETICON, ICON_BIG,   0, , "ahk_id " . hWnd)
        if (h) {
            return h
        }
    }
    h := DllCall("user32\GetClassLongPtrW","ptr",hWnd,"int",-34,"ptr") ; GCLP_HICONSM
    if (!h) h := DllCall("user32\GetClassLongPtrW","ptr",hWnd,"int",-14,"ptr") ; GCLP_HICON
    return h ? h : 0
}

_Icon_GetProcessPath(pid) {
    PROCESS_QUERY_LIMITED_INFORMATION := 0x1000
    hProc := DllCall("kernel32\OpenProcess","uint",PROCESS_QUERY_LIMITED_INFORMATION,"int",0,"uint",pid,"ptr")
    if (!hProc) {
        return ""
    }
    buf := Buffer(32767 * 2, 0), sz := 32767
    ok := DllCall("kernel32\QueryFullProcessImageNameW","ptr",hProc,"uint",0,"ptr",buf.Ptr,"uint*",sz,"int")
    DllCall("kernel32\CloseHandle","ptr",hProc)
    return ok ? StrGet(buf.Ptr, "UTF-16") : ""
}

_Icon_ClearCache() {
    global gIconCache
    for hwnd, meta in gIconCache {
        if (meta.hicon)
            DllCall("user32\DestroyIcon","ptr",meta.hicon)
    }
    gIconCache := Map()
}



; ========================= WINDOW HELPERS =========================
_TryEnableDarkTitleBar(hWnd) {
    try _DWM_SetAttrInt(hWnd, 20, 1)  ; DWMWA_USE_IMMERSIVE_DARK_MODE (new)
    try _DWM_SetAttrInt(hWnd, 19, 1)  ; DWMWA_USE_IMMERSIVE_DARK_MODE (old)
}

_SetCornerPreference(hWnd, pref := 2) {
    ; 1=DoNotRound, 2=Round, 3=Small
    try _DWM_SetAttrInt(hWnd, 33, pref)  ; DWMWA_WINDOW_CORNER_PREFERENCE
}


_LoadTestIcon() {
    global gIconImg
    ; Try explorer.exe (most reliable), fall back to shell32.dll
    gIconImg := __LoadGpIconFromFile(A_WinDir "\explorer.exe", 0)
    if (!gIconImg) {
        gIconImg := __LoadGpIconFromFile(A_WinDir "\System32\shell32.dll", 4)
    }
}

_StateShort(s) {
    if !(IsSet(GUI_StateShort) && GUI_StateShort)
        return s
    sw := StrLower(Trim(s))
    if (sw = "workspaceshowing")      {
        return "WS-Shown"
        }
    else if (sw = "workspaceminimized") {
        return "WS-Min"
    }
    else if (sw = "workspacehidden")   {

     return "WS-Hidden"
    }
    else if (sw = "otherworkspace")    {
     return "Other-WS"
    }
    return s
}

_GetWorkspaceForHwnd(hwnd) {
    ws := ""
    try {
        if Komorebi_SubTryMap(hwnd, &ws) && (ws != "")
            return ws
    } catch {
    }
    return ""
}

_WrapIndex(idx, len) {
    if (len <= 0) {
        return 1
    }
    n := Mod(idx - 1, len)
    if (n < 0) n += len
    return n + 1
}


_GetIconLeftMarginDip(scale) {
    global IconLeftMargin
    try {
        return Round(IconLeftMargin * scale)
    } catch {
        return 0
    }
}

; Keep hover state (row + which button) aligned with the current cursor
; even if rows move due to scroll/selection changes.
_RecalcHoverFromCurrentCursor() {
    global gOverlayH, gHoverRow, gHoverBtn
    if (!gOverlayH) {
        return false
    }
    ; Get cursor in screen coords
    pt := Buffer(8, 0)
    if !DllCall("user32\GetCursorPos", "ptr", pt) {
        return false
    }
    ; Convert to overlay client coords (physical px)
    if !DllCall("user32\ScreenToClient", "ptr", gOverlayH, "ptr", pt.Ptr) {
        return false
    }
    x := NumGet(pt, 0, "Int")
    y := NumGet(pt, 4, "Int")

    act := "", idx := 0
    _DetectActionAtPoint(x, y, &act, &idx)

    changed := (idx != gHoverRow || act != gHoverBtn)
    gHoverRow := idx
    gHoverBtn := act
    return changed
}


_HeaderBlockDip() {
    ; 32 == 4px top pad + 28px header line height
    global ShowHeader
    return ShowHeader ? 32 : 0
}

__FontStyleFromWeight(w) {
    ; GDI+ style: 0=Regular, 1=Bold
    try {
        return (w+0 >= 600) ? 1 : 0
    } catch {
        return 0
    }
}

_EnsureGraphics() {
    global gBackHdc, gG
    ; If there's no backbuffer DC, we can't make a Graphics
    if (!gBackHdc) {
        return 0
    }
    ; Always rebuild the GDI+ Graphics from the CURRENT backbuffer HDC.
    ; This avoids intermittently using a Graphics tied to an old/invalid surface.
    if (gG) {
        try DllCall("gdiplus\GdipDeleteGraphics", "ptr", gG)
        gG := 0
    }
    DllCall("gdiplus\GdipCreateFromHDC", "ptr", gBackHdc, "ptr*", &gG)
    if (!gG) {
        return 0
    }
    SmoothingModeAntiAlias := 4
    TextRenderingHintClearTypeGridFit := 5
    DllCall("gdiplus\GdipSetSmoothingMode", "ptr", gG, "int", SmoothingModeAntiAlias)
    DllCall("gdiplus\GdipSetTextRenderingHint", "ptr", gG, "int", TextRenderingHintClearTypeGridFit)
    return gG
}

__Wrap0(i, count) {
    ; returns 0..count-1 (handles negative i)
    if (count <= 0) {
        return 0
    }
    r := Mod(i, count)
    if (r < 0) {
        r := r + count
    }
    return r
}

__Wrap1(i, count) {
    ; returns 1..count (handles negative i)
    if (count <= 0) {
        return 0
    }
    r := Mod(i - 1, count)
    if (r < 0) {
        r := r + count
    }
    return r + 1
}


__GetWorkAreaFromHwndPhys(hWnd, &left, &top, &right, &bottom) {
    MONITOR_DEFAULTTONEAREST := 2
    hMon := DllCall("user32\MonitorFromWindow", "ptr", hWnd, "uint", MONITOR_DEFAULTTONEAREST, "ptr")
    if (!hMon) {
        left := top := right := bottom := 0
        return
    }
    ; MONITORINFO is 40 bytes: cbSize(4) + rcMonitor(16) + rcWork(16) + dwFlags(4)
    mi := Buffer(40, 0)
    NumPut("UInt", 40, mi, 0) ; cbSize
    if !DllCall("user32\GetMonitorInfoW", "ptr", hMon, "ptr", mi.Ptr, "int") {
        left := top := right := bottom := 0
        return
    }
    ; rcWork at offset 20
    left   := NumGet(mi, 20, "Int")
    top    := NumGet(mi, 24, "Int")
    right  := NumGet(mi, 28, "Int")
    bottom := NumGet(mi, 32, "Int")
}

_RandomSpacedText(minTotal := 5, maxTotal := 20, minRun := 4, maxRun := 8) {
    total := Round(Random(minTotal, maxTotal))
    out := ""
    run := 0
    nextBreak := Round(Random(minRun, maxRun))

    while (StrLen(out) < total) {
        if (run >= nextBreak) {
            if (StrLen(out) + 1 > total) {
                break
            }
            out .= " "
            run := 0
            nextBreak := Round(Random(minRun, maxRun))
        } else {
            ; a–z
            ch := Chr(Round(Random(97, 122)))
            out .= ch
            run += 1
        }
    }
    if (StrLen(out) > total) {
        out := SubStr(out, 1, total)
    }
    return RTrim(out)
}

__SetWindowPosPhys(hWnd, xPhys, yPhys, wPhys, hPhys) {
    SWP_NOZORDER      := 0x0004
    SWP_NOOWNERZORDER := 0x0200
    SWP_NOACTIVATE    := 0x0010
    flags := SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_NOACTIVATE
    return DllCall("user32\SetWindowPos"
        , "ptr", hWnd
        , "ptr", 0
        , "int", xPhys
        , "int", yPhys
        , "int", wPhys
        , "int", hPhys
        , "uint", flags
        , "int")
}

; Per-monitor scale from a RECT (all params are PHYSICAL px)
__GetMonitorScaleFromRect(left, top, right, bottom) {
    ; Build RECT
    rc := Buffer(16, 0)
    NumPut("Int", left,   rc, 0)
    NumPut("Int", top,    rc, 4)
    NumPut("Int", right,  rc, 8)
    NumPut("Int", bottom, rc, 12)

    ; Get HMONITOR for this rect
    MONITOR_DEFAULTTONEAREST := 2
    hMon := DllCall("user32\MonitorFromRect", "ptr", rc.Ptr, "uint", MONITOR_DEFAULTTONEAREST, "ptr")

    ; shcore!GetDpiForMonitor → effective DPI for that monitor
    dpiX := 0, dpiY := 0
    success := false
    try {
        hr := DllCall("shcore\GetDpiForMonitor", "ptr", hMon, "int", 0, "uint*", &dpiX, "uint*", &dpiY, "int") ; MDT_EFFECTIVE_DPI=0
        if (hr = 0 && dpiX > 0) {
            success := true
        }
    }
    if (success) {
        return dpiX / 96.0
    }
    ; Fallback: system DPI
    return __GetSystemScale()
}

; System DPI → scale (physical / 96)
__GetSystemScale() {
    dpi := 0
    try {
        dpi := DllCall("user32\GetDpiForSystem", "uint")
    }
    if (!dpi) {
        dpi := A_ScreenDPI
    }
    return dpi / 96.0
}

; GetWindowRect in PHYSICAL pixels (no DPI math needed here)
__GetWindowRectPhys(hWnd, &x, &y, &w, &h) {
    rc := Buffer(16, 0) ; RECT {left,top,right,bottom}
    ok := DllCall("user32\GetWindowRect", "ptr", hWnd, "ptr", rc.Ptr, "int")
    if (!ok) {
        x := y := w := h := 0
        return
    }
    left   := NumGet(rc, 0, "Int")
    top    := NumGet(rc, 4, "Int")
    right  := NumGet(rc, 8, "Int")
    bottom := NumGet(rc, 12, "Int")
    x := left
    y := top
    w := right - left
    h := bottom - top
}


_ComputeRowsToShow(count) {
    global RowsVisibleMin, RowsVisibleMax
    if (RowsVisibleMax < RowsVisibleMin) {
        ; guard: swap if user misconfigures
        tmp := RowsVisibleMin
        RowsVisibleMin := RowsVisibleMax
        RowsVisibleMax := tmp
    }
    if (count >= RowsVisibleMax)
        return RowsVisibleMax
    if (count > RowsVisibleMin)
        return count
    return RowsVisibleMin
}

_ResizeWindowToRows(rowsToShow) {
    global gBase, gBaseH, gOverlay, gOverlayH, CornerRadiusPx

    ; Compute centered x/y/w/h (DIPs) on the SAME monitor as the base window
    xDip := 0, yDip := 0, wDip := 0, hDip := 0
    _GetWindowRectForWindowMonitor(&xDip, &yDip, &wDip, &hDip, rowsToShow, gBaseH)

    ; Convert those DIPs to PHYSICAL px for exact positioning without DPI drift
    ; Use the work area of the base window's monitor to get its scale
    waL := 0, waT := 0, waR := 0, waB := 0
    __GetWorkAreaFromHwndPhys(gBaseH, &waL, &waT, &waR, &waB)
    monScale := __GetMonitorScaleFromRect(waL, waT, waR, waB)

    xPhys := Round(xDip * monScale)
    yPhys := Round(yDip * monScale)
    wPhys := Round(wDip * monScale)
    hPhys := Round(hDip * monScale)

    ; Physically move/resize both windows in lockstep (no Show() coords → no DPI hops)
    __SetWindowPosPhys(gBaseH,   xPhys, yPhys, wPhys, hPhys)
    __SetWindowPosPhys(gOverlayH, xPhys, yPhys, wPhys, hPhys)

    ; Re-apply rounded region using DIP sizes so the region matches the visual
    _ApplyRoundRegion(gBaseH, CornerRadiusPx, wDip, hDip)

    ; Make sure composition commits before the next layered blit
    try DllCall("dwmapi\DwmFlush")
}

__GetScaleForWindow(hWnd) {
    dpi := 0
    try {
        dpi := DllCall("user32\GetDpiForWindow", "ptr", hWnd, "uint")
    }
    if (!dpi) {
        dpi := A_ScreenDPI ; fallback
    }
    return dpi / 96.0
}

_InitDpiAwareness() {
    ; Prefer Per-Monitor V2; fall back gracefully if unavailable.
    try {
        ; DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
        DllCall("user32\SetProcessDpiAwarenessContext", "ptr", -4, "ptr")
    } catch {
        try {
            ; PROCESS_PER_MONITOR_DPI_AWARE = 2
            DllCall("shcore\SetProcessDpiAwareness", "int", 2, "int")
        } catch {
            ; Last resort: system-DPI aware
            try DllCall("user32\SetProcessDPIAware")
        }
    }
}

_GetWindowRectFromConfig(&x, &y, &w, &h, rowsToShow := "") {
    global ScreenWidthPct, RowHeight, MarginY

    if (rowsToShow == "" || rowsToShow < 1) {
        global RowsVisibleMin
        rowsToShow := RowsVisibleMin
    }

    left := 0, top := 0, right := 0, bottom := 0
    MonitorGetWorkArea(0, &left, &top, &right, &bottom)
    waW_phys := right - left
    waH_phys := bottom - top

    monScale := __GetMonitorScaleFromRect(left, top, right, bottom)

    pct := ScreenWidthPct
    if (pct <= 0)
        pct := 0.10
    if (pct > 1.0)
        pct := pct / 100.0

    waW_dip := waW_phys / monScale
    waH_dip := waH_phys / monScale
    left_dip := left / monScale
    top_dip  := top  / monScale

    w := Round(waW_dip * pct)

    headerBlock := _HeaderBlockDip()
    footerBlock := _FooterBlockDip()
    h := MarginY + headerBlock + rowsToShow * RowHeight + footerBlock + MarginY

    x := Round(left_dip + (waW_dip - w) / 2)
    y := Round(top_dip  + (waH_dip - h) / 2)
}

_ApplyRoundRegion(hWnd, radiusPx, optW := 0, optH := 0) {
    if (!hWnd || radiusPx <= 0) {
        return
    }

    local wx := 0, wy := 0, ww := 0, wh := 0
    local cx := 0, cy := 0, cw := 0, ch := 0
    local hrgn := 0

    if (optW > 0 && optH > 0) {
        ww := optW
        wh := optH
    } else {
        try {
            WinGetClientPos(&cx, &cy, &cw, &ch, "ahk_id " hWnd)
            if (cw > 0 && ch > 0) {
                ww := cw
                wh := ch
            }
        }
        if (ww <= 0 || wh <= 0) {
            try WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hWnd)
        }
    }

    if (ww <= 0 || wh <= 0) {
        return
    }

    hrgn := DllCall("gdi32\CreateRoundRectRgn"
        , "int", 0, "int", 0
        , "int", ww + 1, "int", wh + 1
        , "int", radiusPx * 2, "int", radiusPx * 2
        , "ptr")
    if (hrgn) {
        DllCall("user32\SetWindowRgn", "ptr", hWnd, "ptr", hrgn, "int", 1)
    }
}

_ForceNoLayered(hWnd) {
    GWL_EXSTYLE   := -20
    WS_EX_LAYERED := 0x00080000
    try {
        ex := DllCall("user32\GetWindowLongPtrW", "ptr", hWnd, "int", GWL_EXSTYLE, "ptr")
        if (ex & WS_EX_LAYERED) {
            ex := ex & ~WS_EX_LAYERED
            DllCall("user32\SetWindowLongPtrW", "ptr", hWnd, "int", GWL_EXSTYLE, "ptr", ex, "ptr")
            SWP_NOSIZE := 0x0001, SWP_NOMOVE := 0x0002, SWP_NOZORDER := 0x0004, SWP_FRAMECHANGED := 0x0020
            flags := SWP_NOSIZE | SWP_NOMOVE | SWP_NOZORDER | SWP_FRAMECHANGED
            DllCall("user32\SetWindowPos", "ptr", hWnd, "ptr", 0, "int", 0, "int", 0, "int", 0, "int", 0, "uint", flags)
            _DBG("Removed WS_EX_LAYERED.")
        }
    }
}

; Prevent default white erase (stop flash)
global __BASE_HGUI := 0
__OnEraseBk(wParam, lParam, msg, hwnd) {
    global __BASE_HGUI
    if (__BASE_HGUI && hwnd = __BASE_HGUI) {
        return 1
    }
    return 0
}
_InstallEraseBkSwallow(hWnd) {
    global __BASE_HGUI
    __BASE_HGUI := hWnd
    OnMessage(0x0014, __OnEraseBk) ; WM_ERASEBKGND
}

; ---- Perf caches (drawing + scale) ----
global gCurScale := 1.0              ; current monitor scale for our window
global gResScale := 0.0              ; scale the GDI+ resources were built for
global gRes := Map()                 ; cached GDI+ resources: brushes, fonts, families, formats

; Persistent ARGB backbuffer (reused every paint)
global gBackHdc := 0, gBackHBM := 0, gBackPrev := 0, gBackW := 0, gBackH := 0

; Paint/resize throttles
global gLastRowsDesired := -1

; -------- Scale cache + DPI hook --------
_EnsureScaleCache() {
    global gCurScale, gBaseH
    s := __GetScaleForWindow(gBaseH)
    if (s <= 0) {
        s := 1.0
    }
    gCurScale := s
}

_OnDpiChanged(wParam, lParam, msg, hwnd) {
    global gResScale
    _EnsureScaleCache()
    ; Invalidate resource cache (rebuild next paint)
    gResScale := 0.0
    return 0
}

; -------- Backbuffer management (top-down 32bpp ARGB DIB) --------
_EnsureBackbuffer(wPhys, hPhys) {
    global gBackHdc, gBackHBM, gBackPrev, gBackW, gBackH, gG

    ; Create the memory DC once
    if (!gBackHdc) {
        gBackHdc := DllCall("gdi32\CreateCompatibleDC", "ptr", 0, "ptr")
        if (gG) {
            try DllCall("gdiplus\GdipDeleteGraphics", "ptr", gG)
            gG := 0
        }
    }

    ; Hidden/just-shown windows can briefly report 0x0; clamp to >=1
    wPhys := Max(1, wPhys)
    hPhys := Max(1, hPhys)

    ; No change → keep current surface
    if (wPhys = gBackW && hPhys = gBackH && gBackHBM) {
        return
    }

    ; Replace bitmap surface
    if (gBackHBM) {
        DllCall("gdi32\SelectObject", "ptr", gBackHdc, "ptr", gBackPrev, "ptr")
        DllCall("gdi32\DeleteObject", "ptr", gBackHBM)
        gBackHBM := 0
    }

    ; Build a new top-down 32bpp DIB section
    bi := Buffer(40, 0)
    NumPut("UInt", 40, bi, 0)          ; biSize
    NumPut("Int",  wPhys, bi, 4)       ; biWidth
    NumPut("Int", -hPhys, bi, 8)       ; biHeight (negative => top-down)
    NumPut("UShort", 1,  bi, 12)       ; biPlanes
    NumPut("UShort", 32, bi, 14)       ; biBitCount
    NumPut("UInt", 0,  bi, 16)         ; biCompression = BI_RGB

    pvBits := 0
    gBackHBM := DllCall("gdi32\CreateDIBSection"
        , "ptr", gBackHdc, "ptr", bi.Ptr, "uint", 0, "ptr*", &pvBits, "ptr", 0, "uint", 0, "ptr")
    gBackPrev := DllCall("gdi32\SelectObject", "ptr", gBackHdc, "ptr", gBackHBM, "ptr")

    ; Invalidate any Graphics tied to the old surface to avoid AV on next paint
    if (gG) {
        try DllCall("gdiplus\GdipDeleteGraphics", "ptr", gG)
        gG := 0
    }

    gBackW := wPhys
    gBackH := hPhys
}

; -------- GDI+ resource cache (fonts/brushes/formats) --------
_DisposeGdipResources() {
    global gRes, gResScale
    if !gRes.Count {
        gResScale := 0.0
        return
    }
    for k in ["brMain","brMainHi","brSub","brSubHi","brCol","brColHi","brHdr","brHit","brFooterText"] {
        if (gRes.Has(k) && gRes[k])
            DllCall("gdiplus\GdipDeleteBrush", "ptr", gRes[k])
    }
    for k in ["fMain","fMainHi","fSub","fSubHi","fCol","fColHi","fHdr","fAction","fFooter"] {
        if (gRes.Has(k) && gRes[k])
            DllCall("gdiplus\GdipDeleteFont", "ptr", gRes[k])
    }
    for k in ["ffMain","ffMainHi","ffSub","ffSubHi","ffCol","ffColHi","ffHdr","ffAction","ffFooter"] {
        if (gRes.Has(k) && gRes[k])
            DllCall("gdiplus\GdipDeleteFontFamily", "ptr", gRes[k])
    }
    for k in ["fmt","fmtCenter","fmtRight","fmtLeft","fmtLeftCol","fmtFooterLeft","fmtFooterCenter","fmtFooterRight"] {
        if (gRes.Has(k) && gRes[k])
            DllCall("gdiplus\GdipDeleteStringFormat", "ptr", gRes[k])
    }
    ; NEW: dispose any cached scaled icon
    if (gRes.Has("iconScaled") && gRes["iconScaled"]) {
        DllCall("gdiplus\GdipDisposeImage", "ptr", gRes["iconScaled"])
    }
    gRes := Map()
    gResScale := 0.0
}


__PointInRect(px, py, x, y, w, h) {
    return (px >= x && px < x + w && py >= y && py < y + h)
}

__Gdip_StrokeRoundRect(g, argb, x, y, w, h, r, width := 1) {
    if (w <= 0 || h <= 0) {
        return
    }
    pPath := 0, pPen := 0
    r2 := r * 2.0
    DllCall("gdiplus\GdipCreatePath", "int", 0, "ptr*", &pPath)
    DllCall("gdiplus\GdipAddPathArc",  "ptr", pPath, "float", x,          "float", y,           "float", r2, "float", r2, "float", 180.0, "float", 90.0)
    DllCall("gdiplus\GdipAddPathLine", "ptr", pPath, "float", x + r,      "float", y,           "float", x + w - r, "float", y)
    DllCall("gdiplus\GdipAddPathArc",  "ptr", pPath, "float", x + w - r2, "float", y,           "float", r2, "float", r2, "float", 270.0, "float", 90.0)
    DllCall("gdiplus\GdipAddPathLine", "ptr", pPath, "float", x + w,      "float", y + r,       "float", x + w, "float", y + h - r)
    DllCall("gdiplus\GdipAddPathArc",  "ptr", pPath, "float", x + w - r2, "float", y + h - r2,  "float", r2, "float", r2, "float", 0.0,   "float", 90.0)
    DllCall("gdiplus\GdipAddPathLine", "ptr", pPath, "float", x + w - r,  "float", y + h,       "float", x + r, "float", y + h)
    DllCall("gdiplus\GdipAddPathArc",  "ptr", pPath, "float", x,          "float", y + h - r2,  "float", r2, "float", r2, "float", 90.0,  "float", 90.0)
    DllCall("gdiplus\GdipClosePathFigure", "ptr", pPath)
    DllCall("gdiplus\GdipCreatePen1", "int", argb, "float", width, "int", 2, "ptr*", &pPen) ; UnitPixel=2
    DllCall("gdiplus\GdipDrawPath", "ptr", g, "ptr", pPen, "ptr", pPath)
    if (pPen)  {
      DllCall("gdiplus\GdipDeletePen",  "ptr", pPen)
    }
    if (pPath) {
      DllCall("gdiplus\GdipDeletePath", "ptr", pPath)
    }
}

__Gdip_DrawCenteredTextRect(g, text, x, y, w, h, argb, font) {
    global gRes
    if (!g || !font || w <= 0 || h <= 0)
        return
    fmt := (gRes.Has("fmtCenter") && gRes["fmtCenter"]) ? gRes["fmtCenter"] : 0
    if (!fmt)
        return
    rf := Buffer(16, 0)
    NumPut("Float", x, rf, 0), NumPut("Float", y, rf, 4), NumPut("Float", w, rf, 8), NumPut("Float", h, rf, 12)
    br := 0
    DllCall("gdiplus\GdipCreateSolidFill", "int", argb, "ptr*", &br)
    if (br) {
        DllCall("gdiplus\GdipDrawString", "ptr", g, "wstr", (text . ""), "int", -1, "ptr", font, "ptr", rf.Ptr, "ptr", fmt, "ptr", br)
        DllCall("gdiplus\GdipDeleteBrush", "ptr", br)
    }
}


__DrawActionButtons(g, wPhys, yRow, rowHPhys, scale, isHoveredRow := true) {
    global ShowCloseButton, ShowKillButton, ShowBlacklistButton
    global ActionBtnSizePx, ActionBtnGapPx, ActionBtnRadiusPx, MarginX
    global CloseButtonBGARGB, CloseButtonBGHoverARGB, CloseButtonBorderARGB, CloseButtonBorderPx
         , CloseButtonTextARGB, CloseButtonTextHoverARGB, CloseButtonGlyph
    global KillButtonBGARGB,  KillButtonBGHoverARGB,  KillButtonBorderARGB,  KillButtonBorderPx
         , KillButtonTextARGB, KillButtonTextHoverARGB, KillButtonGlyph
    global BlacklistButtonBGARGB, BlacklistButtonBGHoverARGB, BlacklistButtonBorderARGB, BlacklistButtonBorderPx
         , BlacklistButtonTextARGB, BlacklistButtonTextHoverARGB, BlacklistButtonGlyph
    global gHoverBtn, gRes

    size := Max(12, Round(ActionBtnSizePx * scale))
    gap  := Max(2,  Round(ActionBtnGapPx  * scale))
    rad  := Max(2,  Round(ActionBtnRadiusPx * scale))
    marR := Round(MarginX * scale)

    x := wPhys - marR - size
    y := yRow + (rowHPhys - size) // 2

    drawOne(name, glyph, bg, bgH, text, textH, border, borderPx) {
        local w := size, h := size, hovered := (gHoverBtn = name && isHoveredRow)
        local bgCol := hovered ? bgH : bg
        local txCol := hovered ? textH : text
        __Gdip_FillRoundRect(g, bgCol, x, y, w, h, rad)
        if (borderPx > 0) {
            __Gdip_StrokeRoundRect(g, border, x+0.5, y+0.5, w-1, h-1, rad, Max(1, Round(borderPx*scale)))
        }
        __Gdip_DrawCenteredTextRect(g, glyph, x, y, w, h, txCol, gRes["fAction"])
        x := x - (w + gap)
        return x
    }

    ; Order: Close (rightmost), then Kill, then Blacklist
    if (ShowCloseButton) {
        x := drawOne("close", CloseButtonGlyph, CloseButtonBGARGB, CloseButtonBGHoverARGB
            , CloseButtonTextARGB, CloseButtonTextHoverARGB, CloseButtonBorderARGB, CloseButtonBorderPx)
    }
    if (ShowKillButton) {
        x := drawOne("kill", KillButtonGlyph, KillButtonBGARGB, KillButtonBGHoverARGB
            , KillButtonTextARGB, KillButtonTextHoverARGB, KillButtonBorderARGB, KillButtonBorderPx)
    }
    if (ShowBlacklistButton) {
        x := drawOne("blacklist", BlacklistButtonGlyph, BlacklistButtonBGARGB, BlacklistButtonBGHoverARGB
            , BlacklistButtonTextARGB, BlacklistButtonTextHoverARGB, BlacklistButtonBorderARGB, BlacklistButtonBorderPx)
    }
}


_EnsureGdipResources(scale) {
    global gRes, gResScale
    if (Abs(gResScale - scale) < 0.001 && gRes.Count) {
        return
    }
    _DisposeGdipResources()
    __Gdip_Startup()

    ; ---- Brushes ----
    global MainARGB, MainARGBHi, SubARGB, SubARGBHi, ColARGB, ColARGBHi, HdrARGB, FooterTextARGB
    br := 0
    for _ in [ ["brMain",    MainARGB]
             , ["brMainHi",  MainARGBHi]
             , ["brSub",     SubARGB]
             , ["brSubHi",   SubARGBHi]
             , ["brCol",     ColARGB]
             , ["brColHi",   ColARGBHi]
             , ["brHdr",     HdrARGB]
             , ["brHit",     0x01000000]
             , ["brFooterText", FooterTextARGB] ] {
        DllCall("gdiplus\GdipCreateSolidFill", "int", _[2], "ptr*", &br)
        gRes[ _[1] ] := br, br := 0
    }

    ; ---- Fonts (hardened fallbacks) ----
    global MainFontName, MainFontSize, MainFontWeight
         , MainFontNameHi,  MainFontSizeHi,  MainFontWeightHi
         , SubFontName,     SubFontSize,     SubFontWeight
         , SubFontNameHi,   SubFontSizeHi,   SubFontWeightHi
         , ColFontName,     ColFontSize,     ColFontWeight
         , ColFontNameHi,   ColFontSizeHi,   ColFontWeightHi
         , HdrFontName,     HdrFontSize,     HdrFontWeight
         , ActionFontName,  ActionFontSize,  ActionFontWeight
         , FooterFontName,  FooterFontSize,  FooterFontWeight

    UnitPixel := 2

    mkFont(name, size, weight, keyFam, keyFont) {
        local fam := 0, f := 0, style := __FontStyleFromWeight(weight)
        ; Try requested family
        DllCall("gdiplus\GdipCreateFontFamilyFromName", "wstr", name, "ptr", 0, "ptr*", &fam)
        ; Fallback to Segoe UI
        if (!fam) {
            DllCall("gdiplus\GdipCreateFontFamilyFromName", "wstr", "Segoe UI", "ptr", 0, "ptr*", &fam)
        }
        ; Fallback to generic Sans-Serif
        if (!fam) {
            DllCall("gdiplus\GdipGetGenericFontFamilySansSerif", "ptr*", &fam)
        }
        if (fam) {
            DllCall("gdiplus\GdipCreateFont", "ptr", fam, "float", Max(1, size*scale)
                , "int", style, "int", UnitPixel, "ptr*", &f)
            if (!f) {
                ; last-ditch: 12px Segoe UI
                local fam2 := 0
                DllCall("gdiplus\GdipCreateFontFamilyFromName", "wstr", "Segoe UI", "ptr", 0, "ptr*", &fam2)
                if (!fam2)
                    DllCall("gdiplus\GdipGetGenericFontFamilySansSerif", "ptr*", &fam2)
                if (fam2)
                    DllCall("gdiplus\GdipCreateFont", "ptr", fam2, "float", 12*scale, "int", style, "int", UnitPixel, "ptr*", &f)
                if (fam2)
                    gRes[keyFam] := fam2
            } else {
                gRes[keyFam] := fam
            }
            gRes[keyFont] := f
        }
    }

    mkFont(MainFontName,    MainFontSize,    MainFontWeight,    "ffMain",   "fMain")
    mkFont(MainFontNameHi,  MainFontSizeHi,  MainFontWeightHi,  "ffMainHi", "fMainHi")
    mkFont(SubFontName,     SubFontSize,     SubFontWeight,     "ffSub",    "fSub")
    mkFont(SubFontNameHi,   SubFontSizeHi,   SubFontWeightHi,   "ffSubHi",  "fSubHi")
    mkFont(ColFontName,     ColFontSize,     ColFontWeight,     "ffCol",    "fCol")
    mkFont(ColFontNameHi,   ColFontSizeHi,   ColFontWeightHi,   "ffColHi",  "fColHi")
    mkFont(HdrFontName,     HdrFontSize,     HdrFontWeight,     "ffHdr",    "fHdr")
    mkFont(ActionFontName,  ActionFontSize,  ActionFontWeight,  "ffAction", "fAction")
    mkFont(FooterFontName,  FooterFontSize,  FooterFontWeight,  "ffFooter", "fFooter")

    ; ---- String formats ----
    StringAlignmentNear := 0, StringAlignmentCenter := 1, StringAlignmentFar := 2
    StringFormatFlagsNoWrap := 0x00001000
    StringFormatFlagsNoClip := 0x00004000
    StringTrimmingEllipsisCharacter := 3
    flags := StringFormatFlagsNoWrap | StringFormatFlagsNoClip

    mkFmt(&out, align, valign) {
        out := 0
        DllCall("gdiplus\GdipCreateStringFormat", "int", 0, "ushort", 0, "ptr*", &out)
        if (!out)
            return
        DllCall("gdiplus\GdipSetStringFormatFlags",     "ptr", out, "int", flags)
        DllCall("gdiplus\GdipSetStringFormatTrimming",  "ptr", out, "int", StringTrimmingEllipsisCharacter)
        DllCall("gdiplus\GdipSetStringFormatAlign",     "ptr", out, "int", align)
        DllCall("gdiplus\GdipSetStringFormatLineAlign", "ptr", out, "int", valign)
    }

    fmt := 0, fmtC := 0, fmtR := 0, fmtLcol := 0
    mkFmt(&fmt,     StringAlignmentNear,   StringAlignmentNear)
    mkFmt(&fmtC,    StringAlignmentCenter, StringAlignmentNear)
    mkFmt(&fmtR,    StringAlignmentFar,    StringAlignmentNear)
    mkFmt(&fmtLcol, StringAlignmentNear,   StringAlignmentNear)

    if (fmt)     gRes["fmt"]        := fmt
    if (fmtC)    gRes["fmtCenter"]  := fmtC
    if (fmtR)    gRes["fmtRight"]   := fmtR
    if (fmtLcol) {
        gRes["fmtLeft"]    := fmtLcol, gRes["fmtLeftCol"] := fmtLcol
    }

    ; Footer formats (center vertically)
    fL := 0, fC := 0, fR := 0
    mkFmt(&fL, StringAlignmentNear,   StringAlignmentCenter)
    mkFmt(&fC, StringAlignmentCenter, StringAlignmentCenter)
    mkFmt(&fR, StringAlignmentFar,    StringAlignmentCenter)
    if (fL) gRes["fmtFooterLeft"]   := fL
    if (fC) gRes["fmtFooterCenter"] := fC
    if (fR) gRes["fmtFooterRight"]  := fR

    gResScale := scale
}



_EnsureScaledIcon(scale, ISize, pSrcIcon) {
    global gRes
    if (!pSrcIcon || ISize <= 0) {
        return 0
    }
    if (gRes.Has("iconScaled") && gRes["iconScaled"] && gRes.Has("iconScalePx") && gRes["iconScalePx"] = ISize) {
        return gRes["iconScaled"]
    }
    ; Dispose previous
    if (gRes.Has("iconScaled") && gRes["iconScaled"]) {
        DllCall("gdiplus\GdipDisposeImage", "ptr", gRes["iconScaled"])
        gRes["iconScaled"] := 0
    }

    PixelFormat32bppPARGB := 0x26200A
    pDst := 0, g2 := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", ISize, "int", ISize, "int", 0, "int", PixelFormat32bppPARGB, "ptr", 0, "ptr*", &pDst)
    DllCall("gdiplus\GdipGetImageGraphicsContext", "ptr", pDst, "ptr*", &g2)
    ; Interpolation high-quality for visual parity with GDI+ scaling in DrawImageRectI
    InterpolationModeHighQualityBicubic := 7
    DllCall("gdiplus\GdipSetInterpolationMode", "ptr", g2, "int", InterpolationModeHighQualityBicubic)
    DllCall("gdiplus\GdipDrawImageRectI", "ptr", g2, "ptr", pSrcIcon, "int", 0, "int", 0, "int", ISize, "int", ISize)
    if (g2) {
        DllCall("gdiplus\GdipDeleteGraphics", "ptr", g2)
    }

    gRes["iconScaled"] := pDst
    gRes["iconScalePx"] := ISize
    return pDst
}


; -------- Paint directly into backbuffer using GDI+ over HDC --------
__Gdip_PaintOverlay(items, selIndex, wPhys, hPhys, scrollTop := "", pIcon := 0, scale := 1.0) {
    global RowHeight, MarginX, MarginY, IconSize, RowRadius, SelARGB
         , gScrollTop, gIconImg, ShowHeader, EmptyListText
         , ColFixed2, ColFixed3, ColFixed4, ColFixed5, ColFixed6
         , Col2Name, Col3Name, Col4Name, Col5Name, Col6Name
         , gHoverRow, MainARGB, ShowFooter, FooterHeightPx, FooterGapTopPx

    _EnsureGdipResources(scale)
    global gRes, gBackHdc

    g := _EnsureGraphics()
    if (!g)
        return

    ; Clear + full-surface hit matte
    DllCall("gdiplus\GdipGraphicsClear", "ptr", g, "int", 0x00000000)
    DllCall("gdiplus\GdipFillRectangle", "ptr", g, "ptr", gRes["brHit"], "float", 0, "float", 0, "float", wPhys, "float", hPhys)

    if (scrollTop == "")
        scrollTop := gScrollTop
    if (!pIcon && IsSet(gIconImg) && gIconImg)
        pIcon := gIconImg

    fmtLeft := (gRes.Has("fmtLeft") && gRes["fmtLeft"]) ? gRes["fmtLeft"] : gRes["fmt"]

    ; ---- Metrics (PHYSICAL px) ----
    RowH    := Max(1, Round(RowHeight * scale))
    Mx      := Round(MarginX  * scale)
    My      := Round(MarginY  * scale)
    ISize   := Round(IconSize * scale)
    Rad     := Round(RowRadius * scale)
    gapText := Round(12 * scale)
    gapCols := Round(10 * scale)
    hdrY4   := Round(4  * scale)
    hdrH28  := Round(28 * scale)

    iconLeftDip := _GetIconLeftMarginDip(scale)

    y     := My
    leftX := Mx + iconLeftDip
    textX := leftX + ISize + gapText

    ; Right-side columns (use consistent keys Col2..Col6)
    cols := []
    Col6W := Round(ColFixed6 * scale), Col5W := Round(ColFixed5 * scale)
    Col4W := Round(ColFixed4 * scale), Col3W := Round(ColFixed3 * scale)
    Col2W := Round(ColFixed2 * scale)

    rightX := wPhys - Mx
    if (Col6W > 0) { 
        x := rightX - Col6W, cols.Push({name:Col6Name, w:Col6W, key:"Col6", x:x}), rightX := x - gapCols 
    }
    if (Col5W > 0) { 
        x := rightX - Col5W, cols.Push({name:Col5Name, w:Col5W, key:"Col5", x:x}), rightX := x - gapCols
     }
    if (Col4W > 0) { 
        x := rightX - Col4W, cols.Push({name:Col4Name, w:Col4W, key:"Col4", x:x}), rightX := x - gapCols 
    }
    if (Col3W > 0) { 
        x := rightX - Col3W, cols.Push({name:Col3Name, w:Col3W, key:"Col3", x:x}), rightX := x - gapCols
     }
    if (Col2W > 0) { 
        x := rightX - Col2W, cols.Push({name:Col2Name, w:Col2W, key:"Col2", x:x}), rightX := x - gapCols 
    }

    textW := (rightX - Round(16*scale)) - textX
    if (textW < 0)
        textW := 0

    ; ---- Optional header ----
    if (ShowHeader) {
        hdrY := y + hdrY4
        __Gdip_DrawText(g, "Title", textX, hdrY, textW, Round(20*scale), gRes["brHdr"], gRes["fHdr"], fmtLeft)
        for _, col in cols {
            __Gdip_DrawText(g, col.name, col.x, hdrY, col.w, Round(20*scale), gRes["brHdr"], gRes["fHdr"], gRes["fmt"])
        }
        y += hdrH28
    }

    contentTopY := y
    count := items.Length

    ; Compute available rows area (reserve space for footer if shown)
    footerH := ShowFooter ? Round(FooterHeightPx * scale) : 0
    footerGap := ShowFooter ? Round(FooterGapTopPx * scale) : 0
    availH := hPhys - My - contentTopY - footerH - footerGap
    if (availH < 0)
        availH := 0

    rowsCap := (availH > 0) ? Floor(availH / RowH) : 0
    rowsToDraw := (count <= rowsCap) ? count : rowsCap

    ; ---- Empty list ----
    if (count = 0) {
        rectX := Mx
        rectW := wPhys - 2*Mx
        rectH := RowH
        rectY := contentTopY + Max(0, (availH - rectH) // 2)
        __Gdip_DrawCenteredTextRect(g, EmptyListText, rectX, rectY, rectW, rectH, MainARGB, gRes["fMain"])
        ; still draw footer (below)
    } else if (rowsToDraw > 0) {
        start0 := __Wrap0(scrollTop, count)
        i := 0
        yRow := y

        while (i < rowsToDraw && (yRow + RowH <= contentTopY + availH)) {
            idx0 := __Wrap0(start0 + i, count)
            idx1 := idx0 + 1
            cur  := items[idx1]
            isSel := (idx1 = selIndex)

            if (isSel)
                __Gdip_FillRoundRect(g, SelARGB, Mx - Round(4*scale), yRow - Round(2*scale), wPhys - 2*Mx + Round(8*scale), RowH, Rad)

            ; ---- Icon (per row) ----
            ix := leftX
            iy := yRow + (RowH - ISize)//2
            drewIcon := false
            if (cur.HasOwnProp("HICON") && cur.HICON) {
                pImg := 0
                DllCall("gdiplus\GdipCreateBitmapFromHICON", "ptr", cur.HICON, "ptr*", &pImg)
                if (pImg) {
                    DllCall("gdiplus\GdipDrawImageRectI", "ptr", g, "ptr", pImg, "int", ix, "int", iy, "int", ISize, "int", ISize)
                    DllCall("gdiplus\GdipDisposeImage", "ptr", pImg)
                    drewIcon := true
                }
            }
            if (!drewIcon) {
                if (pIcon) {
                    DllCall("gdiplus\GdipDrawImageRectI", "ptr", g, "ptr", pIcon, "int", ix, "int", iy, "int", ISize, "int", ISize)
                } else {
                    __Gdip_FillEllipse(g, __ARGB_FromIndex(idx1), ix, iy, ISize, ISize)
                }
            }

            ; ---- Text (main + sub) ----
            fMainUse  := isSel ? gRes["fMainHi"] : gRes["fMain"]
            fSubUse   := isSel ? gRes["fSubHi"]  : gRes["fSub"]
            fColUse   := isSel ? gRes["fColHi"]  : gRes["fCol"]
            brMainUse := isSel ? gRes["brMainHi"] : gRes["brMain"]
            brSubUse  := isSel ? gRes["brSubHi"]  : gRes["brSub"]
            brColUse  := isSel ? gRes["brColHi"]  : gRes["brCol"]

            title := cur.HasOwnProp("Title") ? cur.Title : ""
            __Gdip_DrawText(g, title, textX, yRow + Round(6*scale),  textW, Round(24*scale), brMainUse, fMainUse, fmtLeft)

            sub := cur.HasOwnProp("Sub") ? cur.Sub : ""
            __Gdip_DrawText(g, sub,   textX, yRow + Round(28*scale), textW, Round(18*scale), brSubUse,  fSubUse,  fmtLeft)

            ; ---- Right columns ----
            for _, col in cols {
                val := cur.HasOwnProp(col.key) ? cur.%col.key% : ""
                __Gdip_DrawText(g, val, col.x, yRow + Round(10*scale), col.w, Round(20*scale), brColUse, fColUse, gRes["fmt"])
            }

            ; ---- Row actions on hover ----
            if (idx1 = gHoverRow) {
                __DrawActionButtons(g, wPhys, yRow, RowH, scale, true)
            }

            yRow += RowH
            i += 1
        }
    }

    ; virtual scrollbar if needed
    if (count > rowsToDraw && rowsToDraw > 0) {
        __DrawVirtualScrollbar(g, wPhys, contentTopY, rowsToDraw, RowH, scrollTop, count, scale)
    }

    ; Footer (bottom anchored)
    if (ShowFooter) {
        _DrawFooter(g, wPhys, hPhys, scale)
    }
}


; =================== Paint-only selection update (ADD) ===================
Overlay_SetSelection(selIndex) {
    global gItems, gSel, gOverlayH
    if (!IsObject(gItems) || gItems.Length = 0)
        return
    if (selIndex < 1)
        selIndex := 1
    if (selIndex > gItems.Length)
        selIndex := gItems.Length

    gSel := selIndex
    _EnsureVisible(gItems.Length)
    _Overlay_Repaint(gOverlayH, gItems, gSel)
}


_DetectActionAtPoint(xPhys, yPhys, &action, &idx1) {
    global gItems, gScrollTop, gOverlayH, MarginY, RowHeight
    global ShowCloseButton, ShowKillButton, ShowBlacklistButton
    global ActionBtnSizePx, ActionBtnGapPx, MarginX

    action := "", idx1 := 0
    count := gItems.Length
    if (count <= 0) {
        return
    }

    scale := __GetScaleForWindow(gOverlayH)
    RowH := Max(1, Round(RowHeight * scale))
    My   := Round(MarginY  * scale)
    hdr  := Round(_HeaderBlockDip() * scale)
    topY := My + hdr

    if (yPhys < topY) {
        return
    }

    vis := _GetVisibleRowsFromOverlay()
    if (vis <= 0) {
        return
    }
    local rel := yPhys - topY
    local rowVis := Floor(rel / RowH) + 1
    if (rowVis < 1 || rowVis > vis) {
        return
    }

    ; 1-based item index under cursor (wrap-aware viewport)
    local idx0 := __Wrap0(gScrollTop + (rowVis - 1), count)
    idx1 := idx0 + 1

    ; Build button rects (right aligned)
    size := Max(12, Round(ActionBtnSizePx * scale))
    gap  := Max(2,  Round(ActionBtnGapPx  * scale))
    marR := Round(MarginX * scale)

    ox := 0, oy := 0, ow := 0, oh := 0
    __GetWindowRectPhys(gOverlayH, &ox, &oy, &ow, &oh)

    x := ow - marR - size
    y := topY + (rowVis - 1) * RowH + (RowH - size) // 2

    ; Test in order: Close (rightmost), Kill, Blacklist
    if (ShowCloseButton && __PointInRect(xPhys, yPhys, x, y, size, size)) {
        action := "close"
        return
    }
    x := x - (size + gap)
    if (ShowKillButton && __PointInRect(xPhys, yPhys, x, y, size, size)) {
        action := "kill"
        return
    }
    x := x - (size + gap)
    if (ShowBlacklistButton && __PointInRect(xPhys, yPhys, x, y, size, size)) {
        action := "blacklist"
        return
    }
}

; ========================= ACRYLIC (ACCENT) =========================
ApplyAccentAcrylic(hWnd, alpha, baseRgb) {
    bb := (baseRgb >> 16) & 0xFF
    gg := (baseRgb >> 8)  & 0xFF
    rr := (baseRgb)       & 0xFF
    grad := (alpha << 24) | (bb << 16) | (gg << 8) | rr  ; 0xAABBGGRR

    ACCENT_ENABLE_ACRYLICBLURBEHIND := 4
    accent := Buffer(16, 0)
    NumPut("Int", ACCENT_ENABLE_ACRYLICBLURBEHIND, accent, 0)
    NumPut("Int", 0, accent, 4)
    NumPut("Int", grad, accent, 8)
    NumPut("Int", 0, accent, 12)

    WCA_ACCENT_POLICY := 19
    data := Buffer(A_PtrSize * 3, 0)
    NumPut("Int", WCA_ACCENT_POLICY, data, 0)
    NumPut("Ptr", accent.Ptr,        data, A_PtrSize)
    NumPut("Int", accent.Size,       data, A_PtrSize*2)

    ok := DllCall("user32\SetWindowCompositionAttribute", "ptr", hWnd, "ptr", data.Ptr, "int")
    _DBG("SetWindowCompositionAttribute(Acrylic) ok=" ok " alpha=" alpha " baseRgb=0x" Format("{:06X}", baseRgb))
    return ok
}

; ========================= STAGE + REVEAL (no flash) =========================
_StageAndRevealAcrylic(guiObj, x, y, wDip, hDip, alpha, baseRgb, cornerRadius, revealNow := true) {
    ; 1) Create/size hidden (width/height only, let AHK/DWM establish actual size)
    guiObj.Show("Hide w" wDip " h" hDip)
    hWnd := guiObj.Hwnd

    ; 2) Read actual PHYSICAL window size now
    curX := 0, curY := 0, curW := 0, curH := 0
    __GetWindowRectPhys(hWnd, &curX, &curY, &curW, &curH)

    ; 3) Get the work area of the monitor this window is on (PHYSICAL)
    waL := 0, waT := 0, waR := 0, waB := 0
    __GetWorkAreaFromHwndPhys(hWnd, &waL, &waT, &waR, &waB)
    waW := waR - waL
    waH := waB - waT

    ; 4) Compute perfect physical center and move (still hidden → no flash)
    tgtX := waL + (waW - curW) // 2
    tgtY := waT + (waH - curH) // 2
    __SetWindowPosPhys(hWnd, tgtX, tgtY, curW, curH)

    ; 5) Cosmetics (after size is final)
    _TryEnableDarkTitleBar(hWnd)
    _SetCornerPreference(hWnd, 2)
    _ForceNoLayered(hWnd)
    _InstallEraseBkSwallow(hWnd)
    _ApplyRoundRegion(hWnd, cornerRadius, wDip, hDip)

    ; 6) Apply acrylic
    ApplyAccentAcrylic(hWnd, alpha, baseRgb)
    try DllCall("dwmapi\DwmFlush")

    ; 7) Reveal now or defer for a synchronized reveal with overlay
    if (revealNow) {
        guiObj.Show("NA")
        SetTimer(() => _ApplyRoundRegion(hWnd, cornerRadius), -1)
    }
}


; ========================= GDI+ HELPERS =========================
__Gdip_Startup() {
    ; Start GDI+ once; keep the token internally (and mirror to a global for shutdown).
    static token := 0
    if (token)
        return token

    si := Buffer(A_PtrSize=8 ? 24 : 16, 0)  ; GdiplusStartupInput
    NumPut("UInt", 1, si, 0)                ; version = 1

    status := DllCall("gdiplus\GdiplusStartup", "ptr*", &token, "ptr", si.Ptr, "ptr", 0, "int")
    if (status = 0 && token) {
        global gGdipToken
        gGdipToken := token   ; optional mirror for shutdown visibility
        return token
    }
    return 0
}

__Gdip_FillRoundRect(g, argb, x, y, w, h, r) {
    if (w <= 0 || h <= 0) {
        return
    }
    if (r <= 0) {
        pBr := 0
        DllCall("gdiplus\GdipCreateSolidFill", "int", argb, "ptr*", &pBr)
        DllCall("gdiplus\GdipFillRectangle", "ptr", g, "ptr", pBr, "float", x, "float", y, "float", w, "float", h)
        if (pBr) {
            DllCall("gdiplus\GdipDeleteBrush", "ptr", pBr)
        }
        return
    }
    pPath := 0
    pBr   := 0
    r2    := r * 2.0
    DllCall("gdiplus\GdipCreatePath", "int", 0, "ptr*", &pPath)
    DllCall("gdiplus\GdipAddPathArc",  "ptr", pPath, "float", x,          "float", y,           "float", r2, "float", r2, "float", 180.0, "float", 90.0)
    DllCall("gdiplus\GdipAddPathLine", "ptr", pPath, "float", x + r,      "float", y,           "float", x + w - r, "float", y)
    DllCall("gdiplus\GdipAddPathArc",  "ptr", pPath, "float", x + w - r2, "float", y,           "float", r2, "float", r2, "float", 270.0, "float", 90.0)
    DllCall("gdiplus\GdipAddPathLine", "ptr", pPath, "float", x + w,      "float", y + r,       "float", x + w, "float", y + h - r)
    DllCall("gdiplus\GdipAddPathArc",  "ptr", pPath, "float", x + w - r2, "float", y + h - r2,  "float", r2, "float", r2, "float", 0.0,   "float", 90.0)
    DllCall("gdiplus\GdipAddPathLine", "ptr", pPath, "float", x + w - r,  "float", y + h,       "float", x + r, "float", y + h)
    DllCall("gdiplus\GdipAddPathArc",  "ptr", pPath, "float", x,          "float", y + h - r2,  "float", r2, "float", r2, "float", 90.0,  "float", 90.0)
    DllCall("gdiplus\GdipClosePathFigure", "ptr", pPath)
    DllCall("gdiplus\GdipCreateSolidFill", "int", argb, "ptr*", &pBr)
    DllCall("gdiplus\GdipFillPath", "ptr", g, "ptr", pBr, "ptr", pPath)
    if (pBr) {
        DllCall("gdiplus\GdipDeleteBrush", "ptr", pBr)
    }
    if (pPath) {
        DllCall("gdiplus\GdipDeletePath",  "ptr", pPath)
    }
}

__Gdip_DrawText(g, text, x, y, w, h, br, font, fmt) {
    ; Harden all inputs to prevent GDI+ AVs (0xc0000005)
    if (!g)
        return
    if (w <= 0 || h <= 0)
        return
    if (!font || !fmt || !br)
        return
    rf := Buffer(16, 0)
    NumPut("Float", x, rf, 0)
    NumPut("Float", y, rf, 4)
    NumPut("Float", w, rf, 8)
    NumPut("Float", h, rf, 12)
    ; GDI+ will fault if any pointer is invalid. We bail if so.
    DllCall("gdiplus\GdipDrawString", "ptr", g, "wstr", (text . ""), "int", -1
        , "ptr", font, "ptr", rf.Ptr, "ptr", fmt, "ptr", br)
}


__Gdip_FillEllipse(g, argb, x, y, w, h) {
    pBr := 0
    DllCall("gdiplus\GdipCreateSolidFill", "int", argb, "ptr*", &pBr)
    DllCall("gdiplus\GdipFillEllipse", "ptr", g, "ptr", pBr, "float", x, "float", y, "float", w, "float", h)
    if (pBr) {
        DllCall("gdiplus\GdipDeleteBrush", "ptr", pBr)
    }
}

; ===== Icon loading (explorer.exe) → GDI+ image =====
__LoadGpIconFromFile(path, index := 0) {
    __Gdip_Startup()
    hIconLarge := 0
    got := DllCall("shell32\ExtractIconExW", "wstr", path, "int", index, "ptr*", &hIconLarge, "ptr", 0, "uint", 1, "uint")
    if (got = 0 || !hIconLarge) {
        return 0
    }
    pImg := 0
    DllCall("gdiplus\GdipCreateBitmapFromHICON", "ptr", hIconLarge, "ptr*", &pImg)
    DllCall("user32\DestroyIcon", "ptr", hIconLarge)
    return pImg  ; caller must GdipDisposeImage
}

__DrawVirtualScrollbar(g, wPhys, contentTopY, rowsDrawn, rowHPhys, scrollTop, count, scale) {
    global ScrollBarEnabled, ScrollBarWidthPx, ScrollBarMarginRightPx
         , ScrollBarThumbARGB, ScrollBarGutterEnabled, ScrollBarGutterARGB

    if (!ScrollBarEnabled) {
        return
    }
    if (count <= 0 || rowsDrawn <= 0 || rowHPhys <= 0) {
        return
    }

    ; viewport and track geometry (PHYSICAL px)
    trackH := rowsDrawn * rowHPhys
    if (trackH <= 0) {
        return
    }
    trackW := Max(2, Round(ScrollBarWidthPx * scale))
    marR   := Max(0, Round(ScrollBarMarginRightPx * scale))
    x      := wPhys - marR - trackW
    y      := contentTopY
    r      := trackW // 2  ; pill radius

    ; thumb size scales by visible/count (min height guard)
    visCount := rowsDrawn
    thumbH := Max(3, Floor(trackH * visCount / count))

    ; wrap-aware start (0..count-1)
    start0 := __Wrap0(scrollTop, count)
    startRatio := start0 / count
    y1 := y + Floor(startRatio * trackH)
    y2 := y1 + thumbH
    yEnd := y + trackH

    ; brushes
    brThumb := 0, brGutter := 0
    DllCall("gdiplus\GdipCreateSolidFill", "int", ScrollBarThumbARGB, "ptr*", &brThumb)

    if (ScrollBarGutterEnabled) {
        DllCall("gdiplus\GdipCreateSolidFill", "int", ScrollBarGutterARGB, "ptr*", &brGutter)
        __Gdip_FillRoundRect(g, ScrollBarGutterARGB, x, y, trackW, trackH, r)
    }

    ; draw thumb (1 or 2 segments if wrapping across end → top)
    if (y2 <= yEnd) {
        __Gdip_FillRoundRect(g, ScrollBarThumbARGB, x, y1, trackW, thumbH, r)
    } else {
        ; segment 1: bottom tail
        h1 := yEnd - y1
        if (h1 > 0) {
            __Gdip_FillRoundRect(g, ScrollBarThumbARGB, x, y1, trackW, h1, r)
        }
        ; segment 2: wrap to top
        h2 := y2 - yEnd
        if (h2 > 0) {
            __Gdip_FillRoundRect(g, ScrollBarThumbARGB, x, y, trackW, h2, r)
        }
    }

    if (brThumb)  {
        DllCall("gdiplus\GdipDeleteBrush", "ptr", brThumb)
    }
    if (brGutter) {
        DllCall("gdiplus\GdipDeleteBrush", "ptr", brGutter)
    }
}


__ARGB_FromIndex(i) {
    ; fallback colored circle (unused if icon loads)
    r := (37 * i)  & 0xFF
    g := (71 * i)  & 0xFF
    b := (113 * i) & 0xFF
    return (0xCC << 24) | (r << 16) | (g << 8) | b
}

; ========================= OVERLAY (layered) =========================
global gBase := 0, gOverlay := 0, gBaseH := 0, gOverlayH := 0
global gItems := [], gSel := 1
global gScrollTop := 0
global gIconImg := 0

_BuildSampleItems() {
    arr := []
    ; vary count a bit to simulate changing results
    count := Round(Random(4, 12))
    i := 1
    while (i <= count) {
        hwnd := Format("0x{:X}", 0x10000 + Round(Random(1000, 99999)))
        title := _RandomSpacedText(5, 20, 4, 8)
        arr.Push({
            Title: title,
            Class: "Class" i,
            HWND:  hwnd,
            PID:   "" Round(Random(500, 99999))
        })
        i += 1
    }
    return arr
}

_HideOverlay() {
    global gBase, gOverlay
    try gOverlay.Hide()
    try gBase.Hide()
}

_ShowOverlay() {
    global gBase, gBaseH, gOverlay, gOverlayH, gItems, gSel, gScrollTop

    ; simulate changed contents each time we show
    gItems := _BuildSampleItems()
    gSel := 1
    gScrollTop := 0

    ; Ensure the base is visible/sized so GetWindowRect returns valid dimensions
    try gBase.Show("NA")

    ; Force size/rows to match new item count before repaint (ensures non-zero backbuffer)
    rowsDesired := _ComputeRowsToShow(gItems.Length)
    _ResizeWindowToRows(rowsDesired)

    ; Now (re)paint and reveal overlay
    _Overlay_Repaint(gOverlayH, gItems, gSel)
    try gOverlay.Show("NA")
    try DllCall("dwmapi\DwmFlush")
}

_Overlay_Create(ownerHwnd) {
    ; Create overlay as hidden first to avoid any black flash before first paint
    ov := Gui("+AlwaysOnTop -Caption +ToolWindow +Owner" ownerHwnd)
    ov.Show("Hide")

    ; Match owner (base) window position/size in PHYSICAL pixels
    ox := 0, oy := 0, ow := 0, oh := 0
    __GetWindowRectPhys(ownerHwnd, &ox, &oy, &ow, &oh)
    __SetWindowPosPhys(ov.Hwnd, ox, oy, ow, oh)

    return ov
}

_GetWindowRectForWindowMonitor(&x, &y, &w, &h, rowsToShow, hWnd) {
    global ScreenWidthPct, RowHeight, MarginY

    waL := 0, waT := 0, waR := 0, waB := 0
    __GetWorkAreaFromHwndPhys(hWnd, &waL, &waT, &waR, &waB)

    monScale := __GetMonitorScaleFromRect(waL, waT, waR, waB)

    waW_dip := (waR - waL) / monScale
    waH_dip := (waB - waT) / monScale
    left_dip := waL / monScale
    top_dip  := waT / monScale

    pct := ScreenWidthPct
    if (pct <= 0)
        pct := 0.10
    if (pct > 1.0)
        pct := pct / 100.0

    w := Round(waW_dip * pct)

    headerBlock := _HeaderBlockDip()
    footerBlock := _FooterBlockDip()
    h := MarginY + headerBlock + rowsToShow * RowHeight + footerBlock + MarginY

    x := Round(left_dip + (waW_dip - w) / 2)
    y := Round(top_dip  + (waH_dip - h) / 2)
}

_DrawFooter(g, wPhys, hPhys, scale) {
    global ShowFooter, FooterHeightPx, FooterGapTopPx, FooterBGARGB, FooterBGRadius
         , FooterBorderPx, FooterBorderARGB, FooterPaddingX, FooterTextAlign
         , FooterTextARGB, MarginX, MarginY, gFooterText, gRes

    if (!ShowFooter)
        return

    fh := Max(1, Round(FooterHeightPx * scale))
    mx := Round(MarginX * scale)
    my := Round(MarginY * scale)

    x := mx
    y := hPhys - my - fh
    w := wPhys - 2*mx
    r := Max(0, Round(FooterBGRadius * scale))

    __Gdip_FillRoundRect(g, FooterBGARGB, x, y, w, fh, r)
    if (FooterBorderPx > 0)
        __Gdip_StrokeRoundRect(g, FooterBorderARGB, x+0.5, y+0.5, w-1, fh-1, r, Max(1, Round(FooterBorderPx*scale)))

    pad := Max(0, Round(FooterPaddingX * scale))
    tx := x + pad
    tw := w - 2*pad

    t := StrLower(Trim(FooterTextAlign))
    fmt := gRes.Has("fmtFooterCenter") ? gRes["fmtFooterCenter"] : (gRes.Has("fmtCenter") ? gRes["fmtCenter"] : 0)
    if (t = "left")
        fmt := gRes.Has("fmtFooterLeft")  ? gRes["fmtFooterLeft"]  : (gRes.Has("fmt") ? gRes["fmt"] : fmt)
    else if (t = "right")
        fmt := gRes.Has("fmtFooterRight") ? gRes["fmtFooterRight"] : (gRes.Has("fmtRight") ? gRes["fmtRight"] : fmt)

    rf := Buffer(16, 0)
    NumPut("Float", tx, rf, 0)
    NumPut("Float", y,  rf, 4)
    NumPut("Float", tw, rf, 8)
    NumPut("Float", fh, rf, 12)

    DllCall("gdiplus\GdipDrawString"
        , "ptr", g
        , "wstr", gFooterText
        , "int", -1
        , "ptr", gRes["fFooter"]
        , "ptr", rf.Ptr
        , "ptr", fmt
        , "ptr", gRes["brFooterText"])
}

_ScrollBy(step) {
    global gScrollTop, gItems, gOverlayH, gSel

    vis := _GetVisibleRowsFromOverlay()
    if (vis <= 0) {
        return
    }
    count := gItems.Length
    if (count <= 0) {
        return
    }

    visEff := Min(vis, count)
    if (count <= visEff) {
        ; Everything fits; nothing to scroll.
        return
    }

    ; Wrap-aware scrolling for the circular viewport
    gScrollTop := __Wrap0(gScrollTop + step, count)

    ; Recompute hover from current cursor so action icons stay under the pointer
    _RecalcHoverFromCurrentCursor()

    _Overlay_Repaint(gOverlayH, gItems, gSel)
}


_Overlay_Repaint(hOv, items, selIndex) {
    global gBaseH, gOverlay, gLastRowsDesired, gLastItemCount

    ; ----- Throttled dynamic height: only when rows-to-show actually changes -----
    count := items.Length
    rowsDesired := _ComputeRowsToShow(count)
    if (rowsDesired != gLastRowsDesired) {
        _ResizeWindowToRows(rowsDesired)
        gLastRowsDesired := rowsDesired
    }

    ; Base rect in PHYSICAL pixels
    phX := 0, phY := 0, phW := 0, phH := 0
    __GetWindowRectPhys(gBaseH, &phX, &phY, &phW, &phH)

    ; Ensure scale + backbuffer + resources
    _EnsureScaleCache()
    scale := gCurScale
    _EnsureBackbuffer(phW, phH)

    ; Paint directly into backbuffer
    __Gdip_PaintOverlay(items, selIndex, phW, phH, "", 0, scale)

    ; BLENDFUNCTION
    bf := Buffer(4, 0)
    NumPut("UChar", 0x00, bf, 0) ; AC_SRC_OVER
    NumPut("UChar", 0x00, bf, 1)
    NumPut("UChar", 255,  bf, 2) ; per-pixel alpha
    NumPut("UChar", 0x01, bf, 3) ; AC_SRC_ALPHA

    ; SIZE and POINT (PHYSICAL)
    sz := Buffer(8, 0), ptDst := Buffer(8, 0), ptSrc := Buffer(8, 0)
    NumPut("Int", phW, sz, 0), NumPut("Int", phH, sz, 4)
    NumPut("Int", phX, ptDst, 0), NumPut("Int", phY, ptDst, 4)

    ; Ensure WS_EX_LAYERED
    GWL_EXSTYLE := -20, WS_EX_LAYERED := 0x80000
    ex := DllCall("user32\GetWindowLongPtrW", "ptr", hOv, "int", GWL_EXSTYLE, "ptr")
    if !(ex & WS_EX_LAYERED) {
        ex |= WS_EX_LAYERED
        DllCall("user32\SetWindowLongPtrW", "ptr", hOv, "int", GWL_EXSTYLE, "ptr", ex, "ptr")
    }

    ; Update layered directly from persistent backbuffer DC/bitmap
    ULW_ALPHA := 0x2
    hdcScreen := DllCall("user32\GetDC", "ptr", 0, "ptr")
    DllCall("user32\UpdateLayeredWindow"
        , "ptr", hOv
        , "ptr", hdcScreen
        , "ptr", ptDst.Ptr
        , "ptr", sz.Ptr
        , "ptr", gBackHdc
        , "ptr", ptSrc.Ptr
        , "int", 0
        , "ptr", bf.Ptr
        , "uint", ULW_ALPHA
        , "int")
    DllCall("user32\ReleaseDC", "ptr", 0, "ptr", hdcScreen)

    ; Synchronized first reveal
    _RevealBaseAndOverlayTogether()
}

; Keep selection visible after changing gSel
_EnsureVisible(totalCount) {
    global gSel, gScrollTop
    vis := _GetVisibleRowsFromOverlay()
    if (vis <= 0 || totalCount <= 0) {
        return
    }
    visEff := Min(vis, totalCount)
    if (visEff <= 0) {
        return
    }
    if (gSel < gScrollTop + 1) {
        gScrollTop := gSel - 1
    } else if (gSel > gScrollTop + visEff) {
        gScrollTop := gSel - visEff
    }
    if (gScrollTop < 0)
        gScrollTop := 0
    maxTop := Max(0, totalCount - visEff)
    if (gScrollTop > maxTop)
        gScrollTop := maxTop
}

; Full-row click → select clicked row (not just icon)
_OnOverlayClick(x, y) {
    global gItems, gSel, gOverlayH, MarginY, RowHeight, gScrollTop, ScrollKeepHighlightOnTop

    ; Action buttons first
    act := "", idx := 0
    _DetectActionAtPoint(x, y, &act, &idx)
    if (act != "") {
        _Action_Perform(act, idx)
        return
    }

    count := gItems.Length
    if (count = 0)
        return

    scale := __GetScaleForWindow(gOverlayH)
    yDip := Round(y / scale)
    rowsTopDip := MarginY + _HeaderBlockDip()
    if (yDip < rowsTopDip)
        return

    vis := _GetVisibleRowsFromOverlay()
    if (vis <= 0)
        return
    rowsDrawn := Min(vis, count)

    idxVisible := ((yDip - rowsTopDip) // RowHeight) + 1
    if (idxVisible < 1)  idxVisible := 1
    if (idxVisible > rowsDrawn)
        return

    top0 := gScrollTop
    idx0 := __Wrap0(top0 + (idxVisible - 1), count)
    gSel := idx0 + 1

    if (ScrollKeepHighlightOnTop)
        gScrollTop := gSel - 1

    ; Sync with logic so Alt-Up activates clicked item
    NewGUI__NotifyLogicSelection(gSel)

    ; Paint-only selection update
    _Overlay_Repaint(gOverlayH, gItems, gSel)
}



_OnOverlayMouseMove(wParam, lParam, msg, hwnd) {
    global gOverlayH, gHoverRow, gHoverBtn, gItems, gSel
    if (hwnd != gOverlayH) {
        return 0
    }
    x := lParam & 0xFFFF
    y := (lParam >> 16) & 0xFFFF

    act := "", idx := 0
    _DetectActionAtPoint(x, y, &act, &idx)

    prevRow := gHoverRow
    prevBtn := gHoverBtn
    gHoverRow := idx
    gHoverBtn := act

    if (gHoverRow != prevRow || gHoverBtn != prevBtn) {
        _Overlay_Repaint(gOverlayH, gItems, gSel)
    }
    return 0
}

_MoveSelection(delta) {
    global gSel, gItems, gScrollTop, gOverlayH, ScrollKeepHighlightOnTop

    if (gItems.Length = 0 || delta = 0) {
        return
    }

    count := gItems.Length
    vis := _GetVisibleRowsFromOverlay()
    if (vis <= 0) {
        vis := 1
    }
    if (vis > count) {
        vis := count
    }

    if (ScrollKeepHighlightOnTop) {
        if (delta > 0) {
            gSel := __Wrap1(gSel + 1, count)
        } else {
            gSel := __Wrap1(gSel - 1, count)
        }
        gScrollTop := gSel - 1
    } else {
        top0 := gScrollTop
        if (delta > 0) {
            gSel := __Wrap1(gSel + 1, count)
            sel0 := gSel - 1
            pos := __Wrap0(sel0 - top0, count)
            if (pos >= vis || pos = vis - 1)
                gScrollTop := sel0 - (vis - 1)
        } else {
            gSel := __Wrap1(gSel - 1, count)
            sel0 := gSel - 1
            pos := __Wrap0(sel0 - top0, count)
            if (pos >= vis || pos = 0)
                gScrollTop := sel0
        }
    }

    _RecalcHoverFromCurrentCursor()

    ; Sync to logic (ensures Alt-Up acts on the same selection)
    NewGUI__NotifyLogicSelection(gSel)

    ; Paint only (no rebuild) to avoid scroll/selection “snap back”
    _Overlay_Repaint(gOverlayH, gItems, gSel)
}




_RemoveItemAt(idx1) {
    global gItems, gSel, gScrollTop, gOverlayH
    if (idx1 < 1 || idx1 > gItems.Length)
        return

    ; mirror removal into logic list first
    NewGUI__NotifyLogicRemove(idx1)

    ; update UI copy
    gItems.RemoveAt(idx1)

    if (gItems.Length = 0) {
        gSel := 1
        gScrollTop := 0
        _Overlay_Repaint(gOverlayH, gItems, gSel)
        return
    }

    if (gSel > gItems.Length)
        gSel := gItems.Length

    _EnsureVisible(gItems.Length)
    _RecalcHoverFromCurrentCursor()

    ; keep logic in sync with final selection
    NewGUI__NotifyLogicSelection(gSel)

    _Overlay_Repaint(gOverlayH, gItems, gSel)
}




_Action_Perform(action, idx1 := 0) {
    global gItems, gSel
    if (idx1 = 0) {
        idx1 := gSel
    }
    if (idx1 < 1 || idx1 > gItems.Length) {
        return
    }
    cur := gItems[idx1]

    if (action = "close") {
        ; TODO: Real close: PostMessage(WM_CLOSE) to cur.HWND
        _RemoveItemAt(idx1)
        return
    }
    if (action = "kill") {
        pid := cur.HasOwnProp("PID") ? cur.PID : "?"
        ttl := cur.HasOwnProp("Title") ? cur.Title : "window"
        if _ConfirmTopmost("Are you sure you want to TERMINATE process " pid " for '" ttl "'?", "Confirm terminate") {
            ; TODO: ProcessClose(pid)
            _RemoveItemAt(idx1)
        }
        return
    }

    if (action = "blacklist") {
        ttl := cur.HasOwnProp("Title") ? cur.Title : "window"
        cls := cur.HasOwnProp("Class") ? cur.Class : "?"
        if _ConfirmTopmost("Blacklist '" ttl "' from class '" cls "'?", "Confirm blacklist") {
            ; TODO: add to config/store
            _RemoveItemAt(idx1)
        }
        return
    }

}

; Mouse wheel scroll (row-based)
_OnOverlayWheel(wParam, lParam) {
    global gOverlayH, ScrollKeepHighlightOnTop
    delta := (wParam >> 16) & 0xFFFF
    if (delta >= 0x8000) {
        delta -= 0x10000
    }
    step := (delta > 0) ? -1 : 1  ; up = -1, down = +1

    if (ScrollKeepHighlightOnTop) {
        _MoveSelection(step)
    } else {
        _ScrollBy(step)
    }
}

_RevealBaseAndOverlayTogether() {
    global gBase, gBaseH, gOverlay, CornerRadiusPx, gRevealed
    if (gRevealed) {
        return
    }
    ; Re-apply rounded region once on-screen, then show both windows
    try _ApplyRoundRegion(gBaseH, CornerRadiusPx)
    try gBase.Show("NA")
    try gOverlay.Show("NA")
    try DllCall("dwmapi\DwmFlush")
    gRevealed := true
}

; =================== Logic notification helpers (ADD) ===================

NewGUI__NotifyLogicSelection(selIndex) {
    ; Safe call into altlogic (no dependency explosions)
    try ALTAB_UI_OnSelectionChanged(selIndex)
}

NewGUI__NotifyLogicRemove(idx1) {
    try ALTAB_UI_OnRemoveAt(idx1)
}

; ========================= MAIN =========================

; ========================= HOTKEYS =========================
Up:: {
    _MoveSelection(-1)
}
Down:: {
    _MoveSelection(1)
}

; C = Close (no confirmation)
;c:: {
;    global AllowCloseKeystroke
;    if (AllowCloseKeystroke) {
;        _Action_Perform("close")
;    }
;}

; K = Kill (confirm)
;k:: {
;    global AllowKillKeystroke
;    if (AllowKillKeystroke) {
;        _Action_Perform("kill")
;    }
;}

; B = Blacklist (confirm)
;b:: {
;    global AllowBlacklistKeystroke
;    if (AllowBlacklistKeystroke) {
;        _Action_Perform("blacklist")
;    }
;}


; Q = cycle footer scope text (POC only)
;q:: {
;    global gFooterModes, gFooterModeIndex, gFooterText, gOverlayH, gItems, gSel
;    gFooterModeIndex := (gFooterModeIndex >= gFooterModes.Length) ? 1 : (gFooterModeIndex + 1)
;    gFooterText := gFooterModes[gFooterModeIndex]
;    _Overlay_Repaint(gOverlayH, gItems, gSel)
;}

