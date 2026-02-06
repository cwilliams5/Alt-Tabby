#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
; Mock: Dark Title Bar via DwmSetWindowAttribute
; ============================================================
; Demonstrates applying dark mode to a window's title bar using
; the undocumented DWMWA_USE_IMMERSIVE_DARK_MODE attribute.
;
; Key Points:
; - DWMWA_USE_IMMERSIVE_DARK_MODE = 20 (Windows 10 1903+)
; - Older builds used attribute 19 (pre-1903 insider builds)
; - Must be set BEFORE the window is shown, or the title bar
;   won't update until the window is resized/redrawn
; - Also affects the window's system menu (right-click title bar)
; - The window border color follows the dark/light setting
;
; Windows Version Requirements:
; - Windows 10 version 1903 (build 18362) or later
; - Windows 11 works with attribute 20
; ============================================================

; -- Constants --
DWMWA_USE_IMMERSIVE_DARK_MODE := 20
DWMWA_USE_IMMERSIVE_DARK_MODE_OLD := 19  ; Pre-1903 insider builds
DWMWA_BORDER_COLOR := 34                 ; Win11 22H2+: set border color
DWMWA_CAPTION_COLOR := 35                ; Win11 22H2+: set title bar color
DWMWA_TEXT_COLOR := 36                   ; Win11 22H2+: set title text color

isDark := false

; -- Create GUI --
myGui := Gui("+Resize", "Dark Title Bar Demo - Light Mode")
myGui.SetFont("s10", "Segoe UI")
myGui.BackColor := "FFFFFF"

myGui.AddText("x20 y20 w400", "This demo shows how DwmSetWindowAttribute can toggle`nthe title bar between dark and light modes.")
myGui.AddText("x20 y65 w400 vStatusText", "Current: LIGHT mode title bar")

toggleBtn := myGui.AddButton("x20 y100 w200 h35", "Toggle Dark Title Bar")
toggleBtn.OnEvent("Click", ToggleDarkTitleBar)

myGui.AddGroupBox("x20 y150 w400 h140", "Win11 22H2+ Features")
myGui.AddText("x35 y175 w370 +Wrap", "Windows 11 22H2 added attributes for custom border color, caption (title bar) color, and title text color. These work independently of the dark mode attribute.")

customBtn := myGui.AddButton("x35 y230 w180 h30", "Custom Title Colors")
customBtn.OnEvent("Click", ApplyCustomColors)

resetBtn := myGui.AddButton("x225 y230 w180 h30", "Reset Colors")
resetBtn.OnEvent("Click", ResetColors)

myGui.AddText("x20 y305 w400 +Wrap vInfoText",
    "Note: The dark mode attribute must be set BEFORE Gui.Show() "
    "for the initial render. After that, toggling requires the window "
    "to be redrawn (the DWM applies it on next composition).")

myGui.OnEvent("Close", (*) => ExitApp())
myGui.Show("w440 h360")

; -- Functions --

ToggleDarkTitleBar(*) {
    global isDark, myGui
    isDark := !isDark
    value := isDark ? 1 : 0

    ; Apply dark mode attribute
    SetDarkMode(myGui.Hwnd, value)

    ; Update GUI to reflect state
    myGui.Title := isDark ? "Dark Title Bar Demo - Dark Mode" : "Dark Title Bar Demo - Light Mode"
    myGui["StatusText"].Text := isDark ? "Current: DARK mode title bar" : "Current: LIGHT mode title bar"
    myGui.BackColor := isDark ? "1E1E1E" : "FFFFFF"

    ; Update text colors for visibility
    textColor := isDark ? "E0E0E0" : "000000"
    myGui.SetFont("c" textColor)

    ; Force title bar repaint by toggling WS_VISIBLE
    ; This ensures the dark mode attribute takes effect immediately
    ForceRedrawTitleBar(myGui.Hwnd)
}

SetDarkMode(hwnd, enable) {
    ; Try attribute 20 first (Windows 10 1903+)
    value := Buffer(4, 0)
    NumPut("Int", enable, value)
    hr := DllCall("dwmapi\DwmSetWindowAttribute",
        "Ptr", hwnd,
        "Int", DWMWA_USE_IMMERSIVE_DARK_MODE,
        "Ptr", value,
        "Int", 4,
        "Int")

    if (hr != 0) {
        ; Fall back to attribute 19 for older insider builds
        DllCall("dwmapi\DwmSetWindowAttribute",
            "Ptr", hwnd,
            "Int", DWMWA_USE_IMMERSIVE_DARK_MODE_OLD,
            "Ptr", value,
            "Int", 4,
            "Int")
    }
}

ForceRedrawTitleBar(hwnd) {
    ; Method: Briefly toggle WS_THICKFRAME to force DWM to recompose
    ; This is more reliable than InvalidateRect or RedrawWindow for title bars
    style := DllCall("GetWindowLong", "Ptr", hwnd, "Int", -16, "Int")  ; GWL_STYLE
    DllCall("SetWindowLong", "Ptr", hwnd, "Int", -16, "Int", style & ~0x40000)  ; Remove WS_THICKFRAME
    DllCall("SetWindowLong", "Ptr", hwnd, "Int", -16, "Int", style)             ; Restore it
    ; Trigger recomposition
    DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", 0,
        "Int", 0, "Int", 0, "Int", 0, "Int", 0,
        "UInt", 0x27)  ; SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED
}

ApplyCustomColors(*) {
    global myGui
    ; Win11 22H2+ custom title bar colors
    ; Colors are COLORREF format: 0x00BBGGRR

    ; Dark blue border
    borderColor := Buffer(4, 0)
    NumPut("UInt", 0x00993300, borderColor)  ; Dark blue in BGR
    DllCall("dwmapi\DwmSetWindowAttribute",
        "Ptr", myGui.Hwnd, "Int", DWMWA_BORDER_COLOR,
        "Ptr", borderColor, "Int", 4, "Int")

    ; Dark caption background
    captionColor := Buffer(4, 0)
    NumPut("UInt", 0x00332200, captionColor)  ; Very dark blue in BGR
    DllCall("dwmapi\DwmSetWindowAttribute",
        "Ptr", myGui.Hwnd, "Int", DWMWA_CAPTION_COLOR,
        "Ptr", captionColor, "Int", 4, "Int")

    ; White text
    textColor := Buffer(4, 0)
    NumPut("UInt", 0x00FFFFFF, textColor)
    DllCall("dwmapi\DwmSetWindowAttribute",
        "Ptr", myGui.Hwnd, "Int", DWMWA_TEXT_COLOR,
        "Ptr", textColor, "Int", 4, "Int")
}

ResetColors(*) {
    global myGui
    ; DWMWA_COLOR_DEFAULT = 0xFFFFFFFF resets to system default
    defaultColor := Buffer(4, 0)
    NumPut("UInt", 0xFFFFFFFF, defaultColor)

    DllCall("dwmapi\DwmSetWindowAttribute",
        "Ptr", myGui.Hwnd, "Int", DWMWA_BORDER_COLOR,
        "Ptr", defaultColor, "Int", 4, "Int")
    DllCall("dwmapi\DwmSetWindowAttribute",
        "Ptr", myGui.Hwnd, "Int", DWMWA_CAPTION_COLOR,
        "Ptr", defaultColor, "Int", 4, "Int")
    DllCall("dwmapi\DwmSetWindowAttribute",
        "Ptr", myGui.Hwnd, "Int", DWMWA_TEXT_COLOR,
        "Ptr", defaultColor, "Int", 4, "Int")
}
