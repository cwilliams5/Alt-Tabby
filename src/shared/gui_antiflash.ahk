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
; 2. Off-screen + WS_EX_LAYERED: Show window at x=-32000 with alpha=0.
;    Window is "visible" to Win32 (controls render) but invisible to user.
;    On reveal, center with raw Win32 calls (DPI-safe) and set alpha=255.
;    Used for WebView2 windows as a cloaking alternative.
;
; Usage:
;   ; Normal GUI (dashboard, native editor):
;   _GUI_AntiFlashPrepare(gui, "1a1b26", true)
;   gui.Show("w800 h550")
;   ; ...build UI...
;   _GUI_AntiFlashReveal(gui, true)
;
;   ; WebView2 GUI (can't cloak):
;   _GUI_AntiFlashPrepare(gui, "1a1b26", false)
;   gui.Show("x-32000 y-32000 w900 h650")
;   ; ...create WebView2, navigate, wait for ready...
;   _GUI_AntiFlashReveal(gui, false, true)
; ============================================================

; Prepare a GUI for flash-free show. Call BEFORE Gui.Show().
; Adds WS_EX_LAYERED, sets background color, sets alpha=0.
;   gui      - Gui object (must not have been shown yet)
;   bgColor  - Background color to match dark theme (e.g., "1a1b26")
;   useCloak - true: DWM cloak (normal GUIs). false: caller must Show off-screen (WebView2)
_GUI_AntiFlashPrepare(gui, bgColor, useCloak) {
    gui.Opt("+E0x80000")  ; WS_EX_LAYERED
    gui.BackColor := bgColor
    ; .Hwnd access forces HWND creation before Show
    hwnd := gui.Hwnd
    if (useCloak)
        DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "uint", 13, "int*", 1, "uint", 4)
    DllCall("SetLayeredWindowAttributes", "ptr", hwnd, "uint", 0, "uchar", 0, "uint", 2)
}

; Reveal a prepared window. Sets alpha=255 and uncloaks/centers as needed.
;   gui          - Gui object
;   wasCloaked   - true if _GUI_AntiFlashPrepare was called with useCloak=true
;   wasOffscreen - true if window was shown at off-screen position (centers it)
_GUI_AntiFlashReveal(gui, wasCloaked, wasOffscreen := false) {
    hwnd := gui.Hwnd
    if (wasOffscreen) {
        ; Center on current monitor using raw Win32 — bypasses AHK DPI scaling.
        ; GetMonitorInfoW work area (offsets 20-32) and GetWindowRect are both
        ; in physical pixels, and SetWindowPos takes physical pixels.
        hMon := DllCall("user32\MonitorFromWindow", "ptr", hwnd, "uint", 2, "ptr")
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
        ; SWP_NOSIZE=0x0001 | SWP_NOZORDER=0x0004
        DllCall("user32\SetWindowPos", "ptr", hwnd, "ptr", 0
            , "int", cx, "int", cy, "int", 0, "int", 0, "uint", 0x0005)
    }
    ; Set alpha=255 FIRST (while still cloaked if applicable — invisible to user),
    ; THEN uncloak. Ensures window is fully opaque the instant it becomes visible.
    DllCall("SetLayeredWindowAttributes", "ptr", hwnd, "uint", 0, "uchar", 255, "uint", 2)
    if (wasCloaked)
        DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "uint", 13, "int*", 0, "uint", 4)
}
