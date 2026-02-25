#Requires AutoHotkey v2.0
#Include gui_math.ahk

; Windows Helper Functions - DPI, positioning, acrylic

; Initialize DPI awareness
Win_InitDpiAwareness() {
    try {
        DllCall("user32\SetProcessDpiAwarenessContext", "ptr", -4, "ptr")
        return
    }
    try {
        DllCall("shcore\SetProcessDpiAwareness", "int", 2, "int")
        return
    }
    try {
        DllCall("user32\SetProcessDPIAware")
    }
}

; Get work area for monitor containing window
Win_GetWorkAreaFromHwnd(hWnd, &left, &top, &right, &bottom) {
    hMon := DllCall("user32\MonitorFromWindow", "ptr", hWnd, "uint", 2, "ptr")
    if (!hMon) {
        left := 0
        top := 0
        right := 0
        bottom := 0
        return
    }
    ; MONITORINFO (40 bytes): cbSize(4) + rcMonitor(16) + rcWork(16) + dwFlags(4)
    ; rcMonitor: left(4) top(8) right(12) bottom(16)
    ; rcWork:    left(20) top(24) right(28) bottom(32)
    mi := Buffer(40, 0)
    NumPut("UInt", 40, mi, 0)
    if (!DllCall("user32\GetMonitorInfoW", "ptr", hMon, "ptr", mi.Ptr, "int")) {
        left := 0
        top := 0
        right := 0
        bottom := 0
        return
    }
    ; rcWork (work area excluding taskbar)
    left := NumGet(mi, 20, "Int")
    top := NumGet(mi, 24, "Int")
    right := NumGet(mi, 28, "Int")
    bottom := NumGet(mi, 32, "Int")
}

; Get full monitor bounds (including taskbar) for window's monitor
Win_GetMonitorBoundsFromHwnd(hWnd, &left, &top, &right, &bottom) {
    hMon := DllCall("user32\MonitorFromWindow", "ptr", hWnd, "uint", 2, "ptr")
    if (!hMon) {
        left := 0
        top := 0
        right := 0
        bottom := 0
        return
    }
    ; MONITORINFO layout: see Win_GetWorkAreaFromHwnd above
    mi := Buffer(40, 0)
    NumPut("UInt", 40, mi, 0)
    if (!DllCall("user32\GetMonitorInfoW", "ptr", hMon, "ptr", mi.Ptr, "int")) {
        left := 0
        top := 0
        right := 0
        bottom := 0
        return
    }
    ; rcMonitor (full bounds including taskbar)
    left := NumGet(mi, 4, "Int")
    top := NumGet(mi, 8, "Int")
    right := NumGet(mi, 12, "Int")
    bottom := NumGet(mi, 16, "Int")
}

; Win_GetMonitorHandle and Win_GetMonitorLabel moved to win_utils.ahk

; Get monitor scale from rect
Win_GetMonitorScale(left, top, right, bottom) {
    rc := Buffer(16, 0)
    NumPut("Int", left, rc, 0)
    NumPut("Int", top, rc, 4)
    NumPut("Int", right, rc, 8)
    NumPut("Int", bottom, rc, 12)
    hMon := DllCall("user32\MonitorFromRect", "ptr", rc.Ptr, "uint", 2, "ptr")
    dpiX := 0
    dpiY := 0
    try {
        hr := DllCall("shcore\GetDpiForMonitor", "ptr", hMon, "int", 0, "uint*", &dpiX, "uint*", &dpiY, "int")
        if (hr = 0 && dpiX > 0) {
            return dpiX / 96.0
        }
    }
    return _Win_GetSystemScale()
}

; Get system DPI scale
_Win_GetSystemScale() {
    dpi := 0
    try {
        dpi := DllCall("user32\GetDpiForSystem", "uint")
    }
    if (!dpi) {
        dpi := A_ScreenDPI
    }
    return dpi / 96.0
}

; Get DPI scale for window
Win_GetScaleForWindow(hWnd) {
    dpi := 0
    try {
        dpi := DllCall("user32\GetDpiForWindow", "ptr", hWnd, "uint")
    }
    if (!dpi) {
        dpi := A_ScreenDPI
    }
    return dpi / 96.0
}

; Get window rect in physical pixels
Win_GetRectPhys(hWnd, &x, &y, &w, &h) {
    static rc := Buffer(16, 0)  ; static: reused per-call, repopulated before each DllCall
    ok := DllCall("user32\GetWindowRect", "ptr", hWnd, "ptr", rc.Ptr, "int")
    if (!ok) {
        x := 0
        y := 0
        w := 0
        h := 0
        return
    }
    left := NumGet(rc, 0, "Int")
    top := NumGet(rc, 4, "Int")
    right := NumGet(rc, 8, "Int")
    bottom := NumGet(rc, 12, "Int")
    x := left
    y := top
    w := right - left
    h := bottom - top
}

; Set window position in physical pixels
Win_SetPosPhys(hWnd, xPhys, yPhys, wPhys, hPhys) {
    global SWP_NOZORDER, SWP_NOOWNERZORDER, SWP_NOACTIVATE
    flags := SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_NOACTIVATE
    return DllCall("user32\SetWindowPos", "ptr", hWnd, "ptr", 0, "int", xPhys, "int", yPhys, "int", wPhys, "int", hPhys, "uint", flags, "int")
}

; Apply rounded region to window
Win_ApplyRoundRegion(hWnd, radiusPx, optW := 0, optH := 0) {
    if (!hWnd || radiusPx <= 0) {
        return
    }

    ww := 0
    wh := 0

    if (optW > 0 && optH > 0) {
        ww := optW
        wh := optH
    } else {
        ; Try client size first
        ; Use try-catch to handle exceptions and ensure variables are always set
        cw := 0
        ch := 0
        try {
            cx := 0
            cy := 0
            WinGetClientPos(&cx, &cy, &cw, &ch, "ahk_id " hWnd)
        } catch {
            cw := 0
            ch := 0
        }
        if (cw > 0 && ch > 0) {
            ww := cw
            wh := ch
        }

        ; Fall back to window size
        if (ww <= 0 || wh <= 0) {
            winW := 0
            winH := 0
            try {
                wx := 0
                wy := 0
                WinGetPos(&wx, &wy, &winW, &winH, "ahk_id " hWnd)
            } catch {
                winW := 0
                winH := 0
            }
            if (winW > 0) {
                ww := winW
            }
            if (winH > 0) {
                wh := winH
            }
        }
    }

    if (ww <= 0 || wh <= 0) {
        return
    }

    hrgn := 0
    try {
        hrgn := DllCall("gdi32\CreateRoundRectRgn", "int", 0, "int", 0, "int", ww + 1, "int", wh + 1, "int", radiusPx * 2, "int", radiusPx * 2, "ptr")
    } catch {
        hrgn := 0
    }
    if (hrgn) {
        DllCall("user32\SetWindowRgn", "ptr", hWnd, "ptr", hrgn, "int", 1)
    }
}

; Apply acrylic blur effect (argbColor = 0xAARRGGBB)
Win_ApplyAcrylic(hWnd, argbColor) {
    alpha := (argbColor >> 24) & 0xFF
    rr := (argbColor >> 16) & 0xFF
    gg := (argbColor >> 8) & 0xFF
    bb := (argbColor) & 0xFF
    grad := (alpha << 24) | (bb << 16) | (gg << 8) | rr

    accent := Buffer(16, 0)
    NumPut("Int", 4, accent, 0)  ; ACCENT_ENABLE_ACRYLICBLURBEHIND
    NumPut("Int", 0, accent, 4)
    NumPut("Int", grad, accent, 8)
    NumPut("Int", 0, accent, 12)

    data := Buffer(A_PtrSize * 3, 0)
    NumPut("Int", 19, data, 0)  ; WCA_ACCENT_POLICY
    NumPut("Ptr", accent.Ptr, data, A_PtrSize)
    NumPut("Int", accent.Size, data, A_PtrSize * 2)

    return DllCall("user32\SetWindowCompositionAttribute", "ptr", hWnd, "ptr", data.Ptr, "int")
}

; Enable dark title bar
Win_EnableDarkTitleBar(hWnd) {
    global DWMWA_USE_IMMERSIVE_DARK_MODE, DWMWA_USE_IMMERSIVE_DARK_MODE_19
    buf := Buffer(4, 0)
    NumPut("Int", 1, buf, 0)
    try {
        DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hWnd, "int", DWMWA_USE_IMMERSIVE_DARK_MODE, "ptr", buf.Ptr, "int", 4, "int")
    }
    try {
        DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hWnd, "int", DWMWA_USE_IMMERSIVE_DARK_MODE_19, "ptr", buf.Ptr, "int", 4, "int")
    }
}

; Set corner preference (rounded)
Win_SetCornerPreference(hWnd, pref := 2) {
    global DWMWA_WINDOW_CORNER_PREFERENCE
    buf := Buffer(4, 0)
    NumPut("Int", pref, buf, 0)
    try {
        DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hWnd, "int", DWMWA_WINDOW_CORNER_PREFERENCE, "ptr", buf.Ptr, "int", 4, "int")
    }
}

; Remove WS_EX_LAYERED style
Win_ForceNoLayered(hWnd) { ; lint-ignore: dead-function
    global GWL_EXSTYLE, WS_EX_LAYERED, SWP_NOSIZE, SWP_NOMOVE, SWP_NOZORDER, SWP_FRAMECHANGED
    try {
        ex := DllCall("user32\GetWindowLongPtrW", "ptr", hWnd, "int", GWL_EXSTYLE, "ptr")
        if (ex & WS_EX_LAYERED) {
            ex := ex & ~WS_EX_LAYERED
            DllCall("user32\SetWindowLongPtrW", "ptr", hWnd, "int", GWL_EXSTYLE, "ptr", ex, "ptr")
            DllCall("user32\SetWindowPos", "ptr", hWnd, "ptr", 0, "int", 0, "int", 0, "int", 0, "int", 0, "uint", SWP_NOSIZE | SWP_NOMOVE | SWP_NOZORDER | SWP_FRAMECHANGED)
        }
    }
}

; Win_Wrap0, Win_Wrap1 moved to gui_math.ahk

; Extend DWM frame into entire client area (for D2D transparent rendering)
Win_DwmExtendFrame(hWnd) {
    margins := Buffer(16, 0)
    NumPut("int", -1, "int", -1, "int", -1, "int", -1, margins)
    try {
        DllCall("dwmapi\DwmExtendFrameIntoClientArea", "ptr", hWnd, "ptr", margins.Ptr, "int")
    }
}

; Set window class background brush to hollow (DWM material shows through)
Win_SetHollowBrush(hWnd) {
    hollowBrush := DllCall("GetStockObject", "int", 5, "ptr")  ; HOLLOW_BRUSH
    DllCall("SetClassLongPtrW", "ptr", hWnd, "int", -10, "ptr", hollowBrush, "ptr")  ; GCL_HBRBACKGROUND
}

; DWM flush
Win_DwmFlush() {
    try {
        DllCall("dwmapi\DwmFlush")
    }
}

; Confirmation dialog (topmost)
Win_ConfirmTopmost(text, title := "Confirm") {
    res := ThemeMsgBox(text, title, "YesNo Icon! Default2 0x1000")
    return (res = "Yes" || res = 6)
}
