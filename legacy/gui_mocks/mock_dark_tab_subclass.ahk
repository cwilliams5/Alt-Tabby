#Requires AutoHotkey v2.0

; ============================================================
; Mock: Tab Control Dark Mode - Approach #8
; ============================================================
; See tab_darkmode_notes.md for full approach log.
;
; SetWindowTheme("DarkMode_Explorer") for dark bg (proven working)
; + SetWindowLongPtrW subclass on the TAB CONTROL to paint text
;   AFTER the theme paints backgrounds.
;
; Strategy: Let the original WndProc paint everything (backgrounds,
; borders, hover effects via visual theme), then paint our text
; on top using GetDC. This keeps the theme chrome and just fixes text.
;
; DIAGNOSTIC: Text painted RED to verify subclass fires.
;
; How to test:
;   1. Run this script
;   2. If tab text is RED = subclass works, we swap to correct color
;   3. If tab text is BLACK = subclass not firing
;   4. Click "Toggle Theme" and check both modes
; ============================================================

global gIsDark := false
global gGui := 0
global gTabHwnd := 0
global gTabOrigProc := 0
global gTabNewProc := 0
global gColBg := 0, gColText := 0, gColEditBg := 0, gColEditText := 0
global gColSel := 0
global gBrushBg := 0, gBrushEditBg := 0, gBrushSel := 0

; ============================================================
; Helpers
; ============================================================

_GetUxOrdinal(ordinal) {
    static hMod := DllCall("GetModuleHandle", "Str", "uxtheme", "Ptr")
    if (!hMod)
        return 0
    return DllCall("GetProcAddress", "Ptr", hMod, "Ptr", ordinal, "Ptr")
}

_CR(rgb) {
    return ((rgb & 0xFF) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 0xFF)
}

_UpdateColors() {
    global gIsDark, gColBg, gColText, gColEditBg, gColEditText, gColSel
    if (gIsDark) {
        gColBg := 0x202020, gColText := 0xE0E0E0
        gColEditBg := 0x383838, gColEditText := 0xE0E0E0
        gColSel := 0x2B2B2B
    } else {
        gColBg := 0xF0F0F0, gColText := 0x000000
        gColEditBg := 0xFFFFFF, gColEditText := 0x000000
        gColSel := 0xFFFFFF
    }
}

_RecreateBrushes() {
    global gBrushBg, gBrushEditBg, gBrushSel, gColBg, gColEditBg, gColSel
    if (gBrushBg)     DllCall("DeleteObject", "Ptr", gBrushBg)
    if (gBrushEditBg) DllCall("DeleteObject", "Ptr", gBrushEditBg)
    if (gBrushSel)    DllCall("DeleteObject", "Ptr", gBrushSel)
    gBrushBg     := DllCall("CreateSolidBrush", "UInt", _CR(gColBg), "Ptr")
    gBrushEditBg := DllCall("CreateSolidBrush", "UInt", _CR(gColEditBg), "Ptr")
    gBrushSel    := DllCall("CreateSolidBrush", "UInt", _CR(gColSel), "Ptr")
}

_OnCtlColorEdit(wParam, lParam, msg, hwnd) {
    global gColEditBg, gColEditText, gBrushEditBg
    DllCall("gdi32\SetBkColor", "Ptr", wParam, "UInt", _CR(gColEditBg))
    DllCall("gdi32\SetTextColor", "Ptr", wParam, "UInt", _CR(gColEditText))
    return gBrushEditBg
}

_OnCtlColorStatic(wParam, lParam, msg, hwnd) {
    global gColBg, gColText, gBrushBg
    DllCall("gdi32\SetBkColor", "Ptr", wParam, "UInt", _CR(gColBg))
    DllCall("gdi32\SetTextColor", "Ptr", wParam, "UInt", _CR(gColText))
    return gBrushBg
}

; ============================================================
; Tab WndProc subclass
; ============================================================
; Intercepts WM_PAINT: calls original WndProc first (theme paints
; backgrounds), then paints tab text on top with our color.

_TabWndProc(hWnd, uMsg, wParam, lParam) {
    global gTabOrigProc, gColText, gColBg, gColSel, gBrushBg, gBrushSel

    if (uMsg = 0x000F) {  ; WM_PAINT
        ; Let original paint backgrounds/chrome
        result := DllCall("user32\CallWindowProcW", "Ptr", gTabOrigProc,
            "Ptr", hWnd, "UInt", uMsg, "Ptr", wParam, "Ptr", lParam, "Ptr")

        ; Now paint our text on top
        hdc := DllCall("user32\GetDC", "Ptr", hWnd, "Ptr")
        if (hdc) {
            tabCount := DllCall("user32\SendMessageW", "Ptr", hWnd, "UInt", 0x1304, "Ptr", 0, "Ptr", 0, "Int")
            selIdx := DllCall("user32\SendMessageW", "Ptr", hWnd, "UInt", 0x130B, "Ptr", 0, "Ptr", 0, "Int")

            ; Get font
            hFont := DllCall("user32\SendMessageW", "Ptr", hWnd, "UInt", 0x0031, "Ptr", 0, "Ptr", 0, "Ptr")
            hOldFont := 0
            if (hFont)
                hOldFont := DllCall("gdi32\SelectObject", "Ptr", hdc, "Ptr", hFont, "Ptr")

            DllCall("gdi32\SetBkMode", "Ptr", hdc, "Int", 1)  ; TRANSPARENT
            DllCall("gdi32\SetTextColor", "Ptr", hdc, "UInt", _CR(gColText))

            tabRc := Buffer(16, 0)
            textBuf := Buffer(512, 0)
            tci := Buffer(A_PtrSize = 8 ? 40 : 28, 0)
            pszOff := A_PtrSize = 8 ? 16 : 12
            cchOff := A_PtrSize = 8 ? 24 : 16

            loop tabCount {
                idx := A_Index - 1

                ; Get item rect
                DllCall("user32\SendMessageW", "Ptr", hWnd, "UInt", 0x130A, "Ptr", idx, "Ptr", tabRc.Ptr)

                ; Get text
                NumPut("UInt", 0x0001, tci, 0)
                NumPut("Ptr", textBuf.Ptr, tci, pszOff)
                NumPut("Int", 255, tci, cchOff)
                NumPut("UShort", 0, textBuf, 0)
                DllCall("user32\SendMessageW", "Ptr", hWnd, "UInt", 0x133C, "Ptr", idx, "Ptr", tci.Ptr)

                ; NO FillRect — let the theme paint backgrounds
                ; Just draw our text on top with transparent bg
                ; DT_CENTER=1 | DT_VCENTER=4 | DT_SINGLELINE=0x20
                DllCall("user32\DrawTextW", "Ptr", hdc, "Ptr", textBuf.Ptr, "Int", -1, "Ptr", tabRc.Ptr, "UInt", 0x25)
            }

            if (hOldFont)
                DllCall("gdi32\SelectObject", "Ptr", hdc, "Ptr", hOldFont)

            DllCall("user32\ReleaseDC", "Ptr", hWnd, "Ptr", hdc)
        }
        return result
    }

    return DllCall("user32\CallWindowProcW", "Ptr", gTabOrigProc,
        "Ptr", hWnd, "UInt", uMsg, "Ptr", wParam, "Ptr", lParam, "Ptr")
}

; ============================================================
; Setup
; ============================================================

try {
    sysVal := RegRead("HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme")
    gIsDark := (sysVal = 0)
} catch
    gIsDark := false

_UpdateColors()
_RecreateBrushes()

fnSPAM := _GetUxOrdinal(135)
if (fnSPAM) DllCall(fnSPAM, "Int", gIsDark ? 2 : 3, "Int")
fnFlush := _GetUxOrdinal(136)
if (fnFlush) DllCall(fnFlush)

OnMessage(0x0133, _OnCtlColorEdit)
OnMessage(0x0138, _OnCtlColorStatic)

gGui := Gui("+Resize", "Tab Dark Mode - WndProc paint-over (#8)")
gGui.SetFont("s9", "Segoe UI")
gGui.BackColor := Format("{:06X}", gColBg)

buf := Buffer(4, 0)
NumPut("Int", gIsDark ? 1 : 0, buf, 0)
try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", gGui.Hwnd, "Int", 20, "Ptr", buf.Ptr, "Int", 4, "Int")

fnAllow := _GetUxOrdinal(133)
if (fnAllow) DllCall(fnAllow, "Ptr", gGui.Hwnd, "Int", gIsDark)

; --- Tab control ---
tabs := gGui.AddTab3("vTabs x10 y10 w500 h300", ["Title Patterns", "Class Patterns", "Pair Patterns"])
gTabHwnd := tabs.Hwnd

; SetWindowTheme for dark background (proven working in approach #5)
if (fnAllow) DllCall(fnAllow, "Ptr", gTabHwnd, "Int", gIsDark)
if (gIsDark)
    DllCall("uxtheme\SetWindowTheme", "Ptr", gTabHwnd, "Str", "DarkMode_Explorer", "Ptr", 0)

; Subclass AFTER tab creation, AFTER UseTab calls below
; (to avoid AHK re-subclassing during tab setup)

; Tab content
tabs.UseTab("Title Patterns")
gGui.AddText("x20 y45 w480", "Title patterns - match window titles:")
ed1 := gGui.AddEdit("vEdit1 x20 y65 w470 h210 +Multi +WantReturn +VScroll", "First tab content`nLine 2")

tabs.UseTab("Class Patterns")
gGui.AddText("x20 y45 w480", "Class patterns - match window class names:")
ed2 := gGui.AddEdit("vEdit2 x20 y65 w470 h210 +Multi +WantReturn +VScroll", "Second tab content")

tabs.UseTab("Pair Patterns")
gGui.AddText("x20 y45 w480", "Pair patterns - Class|Title pairs:")
ed3 := gGui.AddEdit("vEdit3 x20 y65 w470 h210 +Multi +WantReturn +VScroll", "Third tab content")

tabs.UseTab()

if (gIsDark) {
    for ed in [ed1, ed2, ed3]
        DllCall("uxtheme\SetWindowTheme", "Ptr", ed.Hwnd, "Str", "DarkMode_Explorer", "Ptr", 0)
}

btnToggle := gGui.AddButton("x10 y320 w130 h30", "Toggle Theme")
btnToggle.OnEvent("Click", _OnToggle)
gGui.AddText("vStatus x150 y326 w350", "Mode: " (gIsDark ? "DARK" : "LIGHT") " | #8 text-only paint-over (no FillRect)")

gGui.OnEvent("Close", (*) => ExitApp())

; --- Install WndProc subclass LAST (after all tab setup) ---
gTabOrigProc := DllCall("user32\GetWindowLongPtrW", "Ptr", gTabHwnd, "Int", -4, "Ptr")
gTabNewProc := CallbackCreate(_TabWndProc, "", 4)
DllCall("user32\SetWindowLongPtrW", "Ptr", gTabHwnd, "Int", -4, "Ptr", gTabNewProc, "Ptr")

; Verify subclass stuck
currentProc := DllCall("user32\GetWindowLongPtrW", "Ptr", gTabHwnd, "Int", -4, "Ptr")
subclassOk := (currentProc = gTabNewProc)

gGui.Show("w520 h360")

; Show subclass verification in status
try gGui["Status"].Value := "Mode: " (gIsDark ? "DARK" : "LIGHT") " | #8 subclass=" (subclassOk ? "OK" : "FAILED")

; ============================================================
; Toggle
; ============================================================

_OnToggle(*) {
    global gIsDark, gGui, gTabHwnd, gTabNewProc

    gIsDark := !gIsDark
    _UpdateColors()
    _RecreateBrushes()

    fnSPAM := _GetUxOrdinal(135)
    if (fnSPAM) DllCall(fnSPAM, "Int", gIsDark ? 2 : 3, "Int")
    fnFlush := _GetUxOrdinal(136)
    if (fnFlush) DllCall(fnFlush)

    global gColBg
    gGui.BackColor := Format("{:06X}", gColBg)
    buf := Buffer(4, 0)
    NumPut("Int", gIsDark ? 1 : 0, buf, 0)
    try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", gGui.Hwnd, "Int", 20, "Ptr", buf.Ptr, "Int", 4, "Int")

    fnAllow := _GetUxOrdinal(133)
    if (fnAllow) DllCall(fnAllow, "Ptr", gGui.Hwnd, "Int", gIsDark)

    ; Tab theme
    if (fnAllow) DllCall(fnAllow, "Ptr", gTabHwnd, "Int", gIsDark)
    tabTheme := gIsDark ? "DarkMode_Explorer" : "Explorer"
    DllCall("uxtheme\SetWindowTheme", "Ptr", gTabHwnd, "Str", tabTheme, "Ptr", 0)

    ; Edit controls
    for name in ["Edit1", "Edit2", "Edit3"] {
        try {
            ec := gGui[name]
            DllCall("uxtheme\SetWindowTheme", "Ptr", ec.Hwnd, "Str", (gIsDark ? "DarkMode_Explorer" : "Explorer"), "Ptr", 0)
        }
    }

    ; Verify subclass still installed
    currentProc := DllCall("user32\GetWindowLongPtrW", "Ptr", gTabHwnd, "Int", -4, "Ptr")
    subclassOk := (currentProc = gTabNewProc)

    DllCall("user32\RedrawWindow", "Ptr", gGui.Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x0585)

    try gGui["Status"].Value := "Mode: " (gIsDark ? "DARK" : "LIGHT") " | #8 subclass=" (subclassOk ? "OK" : "FAILED")
}
