#Requires AutoHotkey v2.0

; ============================================================
; GUI Anti-Flash - Eliminate white flash on window creation
; ============================================================
; Dark-themed windows flash white on creation because DWM composites
; the default white background before the app paints. Two techniques:
;
; 1. DWM Cloaking (DWMWA_CLOAK=13): Prevents DWM from compositing
;    the window at all. Best option — no frame outline, no content flash.
;    Used by Chrome/Firefox for the same purpose.
;    Limitation: WebView2 needs DWM composition to initialize, so
;    cloaking at creation time crashes it.
;
; 2. Off-screen + deferred cloak: Show window at x=-32000 with alpha=0.
;    Window is "visible" to Win32 (controls render) but invisible to user.
;    WebView2 can't be cloaked at creation (needs DWM composition to init),
;    but CAN be cloaked after initialization. On reveal: cloak first, then
;    center with raw Win32 (DPI-safe), set alpha=255, and uncloak — same
;    zero-flash result as technique 1, just deferred.
;
; Usage:
;   ; Normal GUI (dashboard, native editor):
;   GUI_AntiFlashPrepare(gui, "1a1b26")
;   gui.Show("w800 h550")
;   ; ...build UI...
;   GUI_AntiFlashReveal(gui, true)
;
;   ; WebView2 GUI (can't cloak):
;   GUI_AntiFlashPrepare(gui, "1a1b26")
;   gui.Show("x-32000 y-32000 w900 h650")
;   ; ...create WebView2, navigate, wait for ready...
;   GUI_AntiFlashReveal(gui, false, true)
; ============================================================

; Prepare a GUI for flash-free show. Call BEFORE Gui.Show().
; Adds WS_EX_LAYERED, sets background color, sets alpha=0.
;   gui      - Gui object (must not have been shown yet)
;   bgColor  - Background color to match dark theme (e.g., "1a1b26")
GUI_AntiFlashPrepare(gui, bgColor) {
    global DWMWA_CLOAK, WS_EX_LAYERED
    gui.Opt("+E" WS_EX_LAYERED)
    gui.BackColor := bgColor
    ; .Hwnd access forces HWND creation before Show
    hwnd := gui.Hwnd
    ; Always cloak — prevents DWM from compositing the frame during Show().
    ; For WebView2: caller must uncloak before WebView2.create() (needs DWM
    ; composition to init), then Reveal re-cloaks for the center+show sequence.
    DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "uint", DWMWA_CLOAK, "int*", 1, "uint", 4)
    DllCall("SetLayeredWindowAttributes", "ptr", hwnd, "uint", 0, "uchar", 0, "uint", 2)
}

; Reveal a prepared window. Sets alpha=255 and uncloaks/centers as needed.
;   gui          - Gui object
;   wasCloaked   - true if GUI_AntiFlashPrepare was called with useCloak=true
;   wasOffscreen - true if window was shown at off-screen position (centers it)
GUI_AntiFlashReveal(gui, wasCloaked, wasOffscreen := false) {
    global DWMWA_CLOAK, MONITOR_DEFAULTTONEAREST, SWP_NOSIZE, SWP_NOZORDER
    hwnd := gui.Hwnd
    if (wasOffscreen) {
        ; WebView2 path: cloak NOW (safe — WebView2 is already initialized),
        ; then center while cloaked so the frame move is completely invisible.
        DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "uint", DWMWA_CLOAK, "int*", 1, "uint", 4)
        ; Center on current monitor using raw Win32 — bypasses AHK DPI scaling.
        ; GetMonitorInfoW work area (offsets 20-32) and GetWindowRect are both
        ; in physical pixels, and SetWindowPos takes physical pixels.
        hMon := DllCall("user32\MonitorFromWindow", "ptr", hwnd, "uint", MONITOR_DEFAULTTONEAREST, "ptr")
        mi := Buffer(40, 0)
        NumPut("UInt", 40, mi, 0)
        DllCall("user32\GetMonitorInfoW", "ptr", hMon, "ptr", mi.Ptr)
        wL := NumGet(mi, 20, "Int"), wT := NumGet(mi, 24, "Int")
        wR := NumGet(mi, 28, "Int"), wB := NumGet(mi, 32, "Int")
        rect := Buffer(16, 0)
        DllCall("user32\GetWindowRect", "ptr", hwnd, "ptr", rect.Ptr)
        winW := NumGet(rect, 8, "Int") - NumGet(rect, 0, "Int")
        winH := NumGet(rect, 12, "Int") - NumGet(rect, 4, "Int")
        cx := wL + (wR - wL - winW) // 2
        cy := wT + (wB - wT - winH) // 2
        DllCall("user32\SetWindowPos", "ptr", hwnd, "ptr", 0
            , "int", cx, "int", cy, "int", 0, "int", 0, "uint", SWP_NOSIZE | SWP_NOZORDER)
        wasCloaked := true  ; Uncloak below after alpha is set
    }
    ; Set alpha=255 FIRST (while still cloaked — invisible to user),
    ; THEN uncloak. Ensures window is fully opaque the instant it becomes visible.
    DllCall("SetLayeredWindowAttributes", "ptr", hwnd, "uint", 0, "uchar", 255, "uint", 2)
    if (wasCloaked)
        DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "uint", DWMWA_CLOAK, "int*", 0, "uint", 4)
    ; Remove WS_EX_LAYERED — no longer needed after reveal. Leaving it on causes
    ; flashing with WM_SETREDRAW + RedrawWindow (dashboard refresh).
    global WS_EX_LAYERED
    gui.Opt("-E" WS_EX_LAYERED)
}
