; gui.ahk — list overlay with icons and rich columns (fast, non-blocking, DPI-safe)
#Requires AutoHotkey v2.0

global gGui := 0, gLV := 0
global OVERLAY_ROWS := 10

; icon infra
global gIL := 0                 ; HIMAGELIST handle
; cache maps hwnd -> { idx: <1-based icon index or 0>, pid: <UInt>, class: <Str> }
global gIconCache := Map()
global gIconQueue := []         ; pending hwnds to resolve
global gIconPumpOn := false

; current viewport snapshot for safe refresh
global gListSnap := [], gSelSnap := 1

; expects from config.ahk:
;   OverlayFont, UseIcons, IconBatchPerTick, IconTimerIntervalMs, IconSizePx

; ============================================================================

Overlay_ShowList(list, selIndex) {
    global gGui, gLV, OverlayFont

    ; If a GUI is already up, just refresh
    if (IsObject(gGui) && gGui && HasProp(gGui, "Hwnd") && gGui.Hwnd) {
        Overlay_Refresh(list, selIndex)
        return
    }

    ; Create GUI (keep last-good flags)
    gGui := Gui("+AlwaysOnTop -Caption +ToolWindow +Border", "Switch")
    gGui.Opt("+OwnDialogs")
    if (IsSet(OverlayFont) && OverlayFont) {
        try gGui.SetFont("s12", OverlayFont)
    }
    try EnableDarkMode(gGui.Hwnd)

    ; work with a *local* reference so globals can't be clobbered mid-call
    oG := gGui

    ; width relative to screen (DPI-safe)
    viewW := Floor(A_ScreenWidth * 0.85)
    if (viewW < 700)  viewW := 700
    if (viewW > 1400) viewW := 1400

    ; ListView creation (same flags as last good)
    gLV := oG.AddListView("r" OVERLAY_ROWS " w" viewW " -Hdr AltSubmit ReadOnly"
        , ["#", "Title", "Class", "PID", "State"])

    oLV := gLV  ; local alias for safety with method calls

    _LV_SetStyles(oLV, viewW)     ; sets double-buffer + column widths
    _Icon_EnsureImageList()       ; (re)attach imagelist to current LV

    Overlay_Refresh(list, selIndex)

    ; initial show to compute size — call on the local object
    try oG.Show("NA AutoSize")

    ; ==================== center + clamp (guarded + initialized) ====================
    ; HARD-INIT all locals so they are *always* assigned before any reads/tests.
    local gx := 0
    local gy := 0
    local gw := 600   ; default fallback size (prevents “unassigned local”)
    local gh := 380   ; default fallback size
    local nx := 0
    local ny := 0

    ; Try WinGetPos first (fills ByRef params; no return value in v2)
    ; These calls may fail, but gw/gh already have safe defaults.
    try WinGetPos(&gx, &gy, &gw, &gh, oG.Hwnd)

    ; If still unknown/zero, ask the control itself.
    if (!IsSet(gw) || !IsSet(gh) || gw <= 0 || gh <= 0) {
        try oG.GetPos(&gx, &gy, &gw, &gh)
    }

    ; Final sanity fallback (keep defaults if any probe failed)
    if (!IsSet(gw) || !IsSet(gh) || gw <= 0 || gh <= 0) {
        gw := 600, gh := 380
    }

    ; Compute centered position with clamps
    nx := Floor((A_ScreenWidth  - gw) / 2)
    ny := Floor((A_ScreenHeight - gh) / 2)
    if (nx < 0) nx := 0
    if (ny < 0) ny := 0
    if (nx + gw > A_ScreenWidth)  nx := A_ScreenWidth  - gw
    if (ny + gh > A_ScreenHeight) ny := A_ScreenHeight - gh

    try oG.Move(nx, ny)
}

Overlay_Refresh(list, selIndex) {
    global gGui, gLV, OVERLAY_ROWS, gIconQueue, UseIcons, gListSnap, gSelSnap
    if !(IsObject(gGui) && gGui && HasProp(gGui, "Hwnd") && gGui.Hwnd)
        return
    if !(IsObject(gLV) && HasProp(gLV, "Hwnd") && gLV.Hwnd)
        return

    total := list.Length
    try gLV.Opt("-Redraw")
    try gLV.Delete()

    if (total = 0) {
        try gLV.Opt("+Redraw")
        return
    }

    ; remember current viewport so icon pump can refresh safely
    gListSnap := list
    gSelSnap  := selIndex

    ; viewport: start at selection, show OVERLAY_ROWS wrapped
    start := selIndex
    pending := []

    i := 0
    while (++i <= OVERLAY_ROWS) {
        idx  := _WrapIndex(start + i - 1, total)
        item := list[idx]

        title := item.Title
        if (StrLen(title) > 140)
            title := SubStr(title, 1, 137) "..."

        numText := "[" idx "/" total "]"

        opt := ""
        if (UseIcons) {
            iIdx := _Icon_GetIndexFor(item.Hwnd, item.Pid, item.Class) ; -1=unresolved, 0=none, >0=ok
            if (iIdx > 0) {
                opt := "Icon" iIdx
            } else if (iIdx = 0) {
                opt := "Icon0"           ; explicitly blank
            } else { ; -1 → unresolved
                if WinExist("ahk_id " item.Hwnd)
                    pending.Push(item.Hwnd)
                opt := "Icon0"
            }
        }

        try gLV.Add(opt, numText, title, item.Class, item.Pid, item.State)
    }

    try gLV.Modify(1, "Select Vis Focus")
    try gLV.Opt("+Redraw")

    if (UseIcons && pending.Length) {
        for _, h in pending
            gIconQueue.Push(h)
        _Icon_StartPump()
    }
}

Overlay_UpdateSelection(list, selIndex) {
    Overlay_Refresh(list, selIndex)
}

Overlay_Hide() {
    global gGui, gLV, gIL
    try {
        if (IsObject(gLV) && HasProp(gLV, "Hwnd") && gLV.Hwnd) {
            ; Detach imagelist so LV doesn’t destroy it on destroy (extra safety)
            gLV.SetImageList(0, 1)   ; LVSIL_SMALL
        }
        if (IsObject(gGui) && HasProp(gGui, "Hwnd") && gGui.Hwnd)
            gGui.Destroy()
    }
    gGui := 0, gLV := 0
}

; ============================================================================

_LV_AsCtrl(lvOrHwnd) {
    ; Accept either a ListView control object or its HWND.
    if IsObject(lvOrHwnd)
        return lvOrHwnd
    try {
        return GuiCtrlFromHwnd(lvOrHwnd)
    } catch {
        return 0
    }
}

_LV_SetStyles(lvOrHwnd, viewW) {
    lv := _LV_AsCtrl(lvOrHwnd)
    if !lv
        return  ; lv isn't ready; just bail

    ; Column widths from known width (Overlay_ShowList already computes viewW)
    w := viewW
    if (!w)
        w := 1000

    inner := w - 24
    col1 := 110
    col2 := Floor(inner * 0.52)
    col3 := Floor(inner * 0.26)
    col4 := 90
    col5 := inner - (col1 + col2 + col3 + col4)
    if (col5 < 90)
        col5 := 90

    ; Guarded ModifyCol calls (lv is a GuiCtrl object now)
    try lv.ModifyCol(1, col1)
    try lv.ModifyCol(2, col2)
    try lv.ModifyCol(3, col3)
    try lv.ModifyCol(4, col4)
    try lv.ModifyCol(5, col5)

    ; Double-buffering via LVM_SETEXTENDEDLISTVIEWSTYLE
    try {
        LVS_EX_DOUBLEBUFFER := 0x00010000
        DllCall("user32\SendMessage"
            , "ptr", lv.Hwnd
            , "uint", 0x1036              ; LVM_SETEXTENDEDLISTVIEWSTYLE
            , "uptr", LVS_EX_DOUBLEBUFFER
            , "ptr", LVS_EX_DOUBLEBUFFER)
    }
}

_WrapIndex(idx, len) {
    if (len <= 0)
        return 1
    n := Mod(idx - 1, len)
    if (n < 0)
        n += len
    return n + 1
}

; =================== ICONS (non-blocking) ===================

_Icon_IsImageListAlive() {
    global gIL
    if (!gIL)
        return false
    cnt := DllCall("Comctl32\ImageList_GetImageCount", "ptr", gIL, "int")
    ; returns -1 (0xFFFFFFFF) on error
    return (cnt >= 0)
}

_Icon_EnsureImageList() {
    global gIL, gLV, IconSizePx, gIconCache
    ; If we have one but it’s dead (LV destroyed it), recreate and clear cache
    if (gIL && !_Icon_IsImageListAlive()) {
        gIL := 0
        gIconCache := Map()   ; stale indices no longer valid
    }

    if (!gIL) {
        ILC_COLOR32 := 0x20, ILC_MASK := 0x01
        gIL := DllCall("Comctl32\ImageList_Create"
            , "int", IconSizePx, "int", IconSizePx
            , "uint", ILC_COLOR32|ILC_MASK
            , "int", 32, "int", 32, "ptr")
    }
    ; Always attach to the current ListView (new control each session)
    if (IsObject(gLV) && HasProp(gLV, "Hwnd") && gLV.Hwnd)
        gLV.SetImageList(gIL, 1)  ; LVSIL_SMALL
}

; Return:
;   >0  = cached icon index (valid)
;   0   = known no-icon (blank)
;   -1  = unresolved (queue it)
_Icon_GetIndexFor(hwnd, pid, cls) {
    global gIconCache
    if !gIconCache.Has(hwnd)
        return -1

    meta := gIconCache[hwnd]

    if (Type(meta) != "Object")
        return meta

    ; Validate against current PID/Class to avoid HWND-reuse icon ghosts.
    if (HasProp(meta, "pid") && HasProp(meta, "class") && meta.pid = pid && meta.class = cls)
        return meta.idx

    ; Stale entry → clear and resolve again.
    gIconCache.Delete(hwnd)
    return -1
}

_Icon_StartPump() {
    global gIconPumpOn, IconTimerIntervalMs
    if (gIconPumpOn)
        return
    gIconPumpOn := true
    SetTimer(_Icon_Pump, IconTimerIntervalMs)
}

_Icon_Pump() {
    global gIconPumpOn, gIconQueue, IconBatchPerTick, gIconCache, gIL, gGui, gLV, gListSnap, gSelSnap

    if !(IsObject(gGui) && gGui && HasProp(gGui, "Hwnd") && gGui.Hwnd) {
        gIconQueue := []
        gIconPumpOn := false
        SetTimer(_Icon_Pump, 0)
        return
    }

    ; If IL died for any reason, recreate & force re-attach; icons will repopulate lazily
    _Icon_EnsureImageList()

    changed := false
    count := 0
    while (gIconQueue.Length && count < IconBatchPerTick) {
        hwnd := gIconQueue.RemoveAt(1)

        if (gIconCache.Has(hwnd)) {
            count++
            continue
        }

        if !WinExist("ahk_id " hwnd) {
            gIconCache[hwnd] := { idx: 0, pid: 0, class: "" } ; known none
            count++
            continue
        }

        ; find current pid/class from the latest snapshot (so we store metadata)
        pid := 0, cls := ""
        for _, it in gListSnap {
            if (it.Hwnd = hwnd) {
                pid := it.Pid
                cls := it.Class
                break
            }
        }

        hIcon := _Icon_ResolveSmall(hwnd)
        if (hIcon) {
            idx := DllCall("Comctl32\ImageList_AddIcon", "ptr", gIL, "ptr", hIcon, "int")
            DllCall("user32\DestroyIcon", "ptr", hIcon)
            gIconCache[hwnd] := { idx: idx + 1, pid: pid, class: cls }
            changed := true
        } else {
            gIconCache[hwnd] := { idx: 0, pid: pid, class: cls } ; no icon
        }
        count++
    }

    if (gIconQueue.Length = 0) {
        gIconPumpOn := false
        SetTimer(_Icon_Pump, 0)
    }

    if (changed && IsObject(gGui) && HasProp(gGui, "Hwnd") && gGui.Hwnd) {
        Overlay_Refresh(gListSnap, gSelSnap)
    }
}

_Icon_ResolveSmall(hWnd) {
    if !WinExist("ahk_id " hWnd)
        return 0

    WM_GETICON := 0x7F
    ICON_SMALL2 := 2, ICON_SMALL := 0, ICON_BIG := 1

    ; Query the window (safe)
    try {
        h := SendMessage(WM_GETICON, ICON_SMALL2, 0, , "ahk_id " hWnd)
        if (!h)
            h := SendMessage(WM_GETICON, ICON_SMALL, 0, , "ahk_id " hWnd)
        if (!h)
            h := SendMessage(WM_GETICON, ICON_BIG,   0, , "ahk_id " hWnd)
        if (h)
            return h
    } catch {
        return 0
    }

    ; Class icon
    h := DllCall("user32\GetClassLongPtrW", "ptr", hWnd, "int", -34, "ptr") ; GCLP_HICONSM
    if (!h)
        h := DllCall("user32\GetClassLongPtrW", "ptr", hWnd, "int", -14, "ptr") ; GCLP_HICON
    if (h)
        return h

    ; Extract from process exe
    pidBuf := Buffer(4, 0)
    DllCall("user32\GetWindowThreadProcessId", "ptr", hWnd, "ptr", pidBuf.Ptr, "uint")
    pid := NumGet(pidBuf, 0, "UInt")
    exe := _Icon_GetProcessPath(pid)
    if (!exe)
        return 0

    hSmall := 0, hLarge := 0
    DllCall("Shell32\ExtractIconExW", "wstr", exe, "int", 0, "ptr*", &hLarge, "ptr*", &hSmall, "uint", 1)
    if (hSmall) {
        if (hLarge)
            DllCall("user32\DestroyIcon", "ptr", hLarge)
        return hSmall
    }
    if (hLarge)
        return hLarge
    return 0
}

_Icon_GetProcessPath(pid) {
    PROCESS_QUERY_LIMITED_INFORMATION := 0x1000
    hProc := DllCall("kernel32\OpenProcess", "uint", PROCESS_QUERY_LIMITED_INFORMATION, "int", 0, "uint", pid, "ptr")
    if (!hProc)
        return ""
    bufSize := 32767
    buf := Buffer(bufSize * 2, 0)
    sizeVar := bufSize
    ok := DllCall("kernel32\QueryFullProcessImageNameW", "ptr", hProc, "uint", 0, "ptr", buf.Ptr, "uint*", sizeVar, "int")
    DllCall("kernel32\CloseHandle", "ptr", hProc)
    if (!ok)
        return ""
    return StrGet(buf.Ptr, "UTF-16")
}
