#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
; Mock: Dark Themed Common Controls
; ============================================================
; Demonstrates dark mode styling for standard Win32 controls
; in AHK v2 GUIs, with honest reporting of limitations.
;
; Techniques used:
; 1. DwmSetWindowAttribute for dark title bar
; 2. SetPreferredAppMode for app-wide dark context menus
; 3. AllowDarkModeForWindow per-window dark opt-in
; 4. SetWindowTheme("DarkMode_Explorer"/"DarkMode_CFD") per-control
; 5. WM_CTLCOLOREDIT/STATIC/LISTBOX for text/background colors
; 6. LVM_SETTEXTCOLOR/SETBKCOLOR for ListView
; 7. SB_SETBKCOLOR for StatusBar
; 8. PBM_SETBARCOLOR/SETBKCOLOR for ProgressBar
;
; Control Dark Mode Support Matrix:
; -------------------------------------------------
; Control        | Theme             | Custom Colors           | Limitations
; -------------------------------------------------
; Edit           | DarkMode_CFD      | WM_CTLCOLOREDIT         | Selection highlight = system color
; Button         | DarkMode_Explorer | -                       | Works on Win10+
; Checkbox       | DarkMode_Explorer | -                       | Check fill uses theme color (no override)
; Radio          | DarkMode_Explorer | -                       | Radio fill uses theme color (no override)
; DropDownList   | DarkMode_CFD      | WM_CTLCOLORLISTBOX      | Hover highlight = theme controlled
; ListView       | DarkMode_Explorer | LVM_SET*COLOR, header   | Header via child HWND
; Tab3           | DarkMode_Explorer | -                       | Tab text color = theme controlled
; Slider         | DarkMode_Explorer | -                       | Track/thumb colors = theme controlled
; Progress       | -                 | PBM_SETBARCOLOR/BKCOLOR | Full control over colors
; UpDown         | DarkMode_Explorer | -                       | Arrow colors follow theme
; GroupBox       | -                 | Font color only          | Border = theme controlled
; StatusBar      | DarkMode_Explorer | SB_SETBKCOLOR           | Text via WM_CTLCOLORSTATIC
; -------------------------------------------------
;
; Windows Version: Windows 10 1903+ (build 18362)
; ============================================================

; -- Dark mode colors --
DARK_BG       := "1E1E1E"
DARK_BG_RGB   := 0x1E1E1E
DARK_CTRL     := "2D2D2D"
DARK_CTRL_RGB := 0x2D2D2D
DARK_TEXT     := "E0E0E0"
DARK_TEXT_RGB := 0xE0E0E0
DARK_ACCENT   := "0078D4"
DARK_ACCENT_RGB := 0x0078D4
LIGHT_BG      := "F0F0F0"
LIGHT_BG_RGB  := 0xF0F0F0
LIGHT_TEXT    := "000000"
LIGHT_TEXT_RGB := 0x000000

; DWM attribute
DWMWA_USE_IMMERSIVE_DARK_MODE := 20

; GDI brushes for WM_CTLCOLOR handlers
global gDarkBrush := DllCall("CreateSolidBrush", "UInt", DARK_CTRL_RGB, "Ptr")
global gDarkBgBrush := DllCall("CreateSolidBrush", "UInt", DARK_BG_RGB, "Ptr")
global gIsDark := false

; ============================================================
; App-Wide Dark Mode Init (SetPreferredAppMode)
; ============================================================
; Must be called BEFORE creating windows for full effect.
; Enables dark context menus, improves control theming.

_GetUxthemeOrdinal(ordinal) {
    static hMod := DllCall("GetModuleHandle", "Str", "uxtheme", "Ptr")
    return DllCall("GetProcAddress", "Ptr", hMod, "Ptr", ordinal, "Ptr")
}

AllowDarkModeForWindow(hwnd, allow) {
    ; uxtheme ordinal #133
    DllCall(_GetUxthemeOrdinal(133), "Ptr", hwnd, "Int", allow)
}

; Start with system-following mode
DllCall(_GetUxthemeOrdinal(135), "Int", 1, "Int")  ; SetPreferredAppMode(AllowDark)
DllCall(_GetUxthemeOrdinal(136))                     ; FlushMenuThemes

; ============================================================
; Build the Demo GUI
; ============================================================

myGui := Gui("+Resize +MinSize600x580", "Dark Controls Demo")
myGui.SetFont("s10", "Segoe UI")
myGui.BackColor := LIGHT_BG

; -- Toggle button --
toggleBtn := myGui.AddButton("x20 y15 w180 h30", "Switch to Dark Mode")
toggleBtn.OnEvent("Click", ToggleTheme)

myGui.AddText("x210 y22 w300 vModeLabel", "Current: Light Mode")

; -- GroupBox: Text Inputs --
myGui.AddGroupBox("x20 y55 w270 h120 vGroup1", "Text Inputs")
myGui.AddText("x35 y80 w80 vLabel1", "Name:")
nameEdit := myGui.AddEdit("x120 y77 w155 vNameEdit", "Select me to test highlight")
myGui.AddText("x35 y110 w80 vLabel2", "Email:")
emailEdit := myGui.AddEdit("x120 y107 w155 vEmailEdit", "user@example.com")
myGui.AddText("x35 y140 w80 vLabel3", "Number:")
numEdit := myGui.AddEdit("x120 y137 w80 vNumEdit +Number", "42")
myGui.AddUpDown("vNumUpDown Range0-100", 42)

; -- GroupBox: Selection Controls --
myGui.AddGroupBox("x310 y55 w270 h120 vGroup2", "Selection Controls")
ddl := myGui.AddDropDownList("x325 y80 w240 vDDL", ["Option 1", "Option 2", "Option 3", "Option 4"])
ddl.Value := 1
cb1 := myGui.AddCheckbox("x325 y115 w120 vCB1", "Dark Mode")
cb2 := myGui.AddCheckbox("x455 y115 w120 vCB2 Checked", "Auto-save")
myGui.AddRadio("x325 y140 w120 vRad1 Checked", "Choice A")
myGui.AddRadio("x455 y140 w120 vRad2", "Choice B")

; -- ListView --
myGui.AddText("x20 y185 w100 vLVLabel", "ListView:")
lv := myGui.AddListView("x20 y205 w560 h120 vLV", ["Name", "Type", "Status", "Value"])
lv.Add("", "Window Title", "String", "Active", "Hello World")
lv.Add("", "Opacity", "Integer", "Set", "255")
lv.Add("", "Background", "Color", "Applied", "0x1E1E1E")
lv.Add("", "Font Size", "Float", "Default", "10.0")
lv.Add("", "Accent", "Color", "Custom", "0x0078D4")
lv.ModifyCol(1, 160)
lv.ModifyCol(2, 100)
lv.ModifyCol(3, 100)
lv.ModifyCol(4, 180)

; -- Tab Control --
myGui.AddText("x20 y335 w100 vTabLabel", "Tab Control:")
tab := myGui.AddTab3("x20 y355 w560 h100 vTabCtrl", ["General", "Advanced", "About"])

tab.UseTab("General")
myGui.AddText("x35 y385 w200 vTabText1", "General settings would go here.")
myGui.AddEdit("x35 y405 w250 vTabEdit1", "Tab content edit")

tab.UseTab("Advanced")
myGui.AddText("x35 y385 w200 vTabText2", "Advanced settings panel.")

tab.UseTab("About")
myGui.AddText("x35 y385 w300 vTabText3", "Dark mode control demo for AHK v2.")

tab.UseTab()

; -- Slider --
myGui.AddText("x20 y465 w80 vSliderLabel", "Slider:")
slider := myGui.AddSlider("x100 y465 w200 h30 vSlider Range0-100 ToolTip", 50)

; -- Progress --
myGui.AddText("x320 y465 w80 vProgLabel", "Progress:")
prog := myGui.AddProgress("x400 y468 w180 h20 vProgress", 65)

; -- Status Bar --
sb := myGui.AddStatusBar("vSB")
sb.SetText(" Ready - Light Mode")

; Register WM_CTLCOLOR* messages for dark edit/static backgrounds
OnMessage(0x0133, WM_CTLCOLOREDIT)   ; WM_CTLCOLOREDIT
OnMessage(0x0134, WM_CTLCOLORLISTBOX) ; WM_CTLCOLORLISTBOX
OnMessage(0x0138, WM_CTLCOLORSTATIC) ; WM_CTLCOLORSTATIC

myGui.OnEvent("Close", (*) => ExitApp())
myGui.Show("w600 h540")

; ============================================================
; Toggle Function
; ============================================================

ToggleTheme(*) {
    global gIsDark, myGui

    gIsDark := !gIsDark

    ; -- Set SetPreferredAppMode to match --
    if (gIsDark) {
        DllCall(_GetUxthemeOrdinal(135), "Int", 2, "Int")  ; ForceDark
    } else {
        DllCall(_GetUxthemeOrdinal(135), "Int", 3, "Int")  ; ForceLight
    }
    DllCall(_GetUxthemeOrdinal(136))  ; FlushMenuThemes

    if (gIsDark) {
        myGui.BackColor := DARK_BG
        myGui.SetFont("c" DARK_TEXT)
        myGui.Title := "Dark Controls Demo [DARK]"
        myGui["ModeLabel"].Text := "Current: Dark Mode"
        toggleBtn.Text := "Switch to Light Mode"
    } else {
        myGui.BackColor := LIGHT_BG
        myGui.SetFont("c" LIGHT_TEXT)
        myGui.Title := "Dark Controls Demo [LIGHT]"
        myGui["ModeLabel"].Text := "Current: Light Mode"
        toggleBtn.Text := "Switch to Dark Mode"
    }

    ; Dark title bar
    SetDarkTitleBar(myGui.Hwnd, gIsDark)

    ; Allow dark mode for the main window
    AllowDarkModeForWindow(myGui.Hwnd, gIsDark)

    ; -- Buttons --
    ApplyDarkThemeToControl(toggleBtn.Hwnd, gIsDark, "DarkMode_Explorer")

    ; -- Text inputs --
    ApplyDarkThemeToControl(myGui["NameEdit"].Hwnd, gIsDark, "DarkMode_CFD")
    ApplyDarkThemeToControl(myGui["EmailEdit"].Hwnd, gIsDark, "DarkMode_CFD")
    ApplyDarkThemeToControl(myGui["NumEdit"].Hwnd, gIsDark, "DarkMode_CFD")
    ApplyDarkThemeToControl(myGui["NumUpDown"].Hwnd, gIsDark, "DarkMode_Explorer")

    ; -- DropDownList --
    ; Apply theme + AllowDarkMode to fix dropdown list rendering
    AllowDarkModeForWindow(myGui["DDL"].Hwnd, gIsDark)
    ApplyDarkThemeToControl(myGui["DDL"].Hwnd, gIsDark, "DarkMode_CFD")
    ; Also get the ComboBox's internal list (child window) and theme it
    hDDLList := DllCall("FindWindowEx", "Ptr", 0, "Ptr", 0, "Str", "ComboLBox", "Ptr", 0, "Ptr")
    if (hDDLList) {
        AllowDarkModeForWindow(hDDLList, gIsDark)
        ApplyDarkThemeToControl(hDDLList, gIsDark, "DarkMode_CFD")
    }

    ; -- Checkboxes and Radios --
    ; SetWindowTheme gives them dark background. Check/radio fill color
    ; is drawn by the theme and cannot be independently controlled without owner-draw.
    ApplyDarkThemeToControl(myGui["CB1"].Hwnd, gIsDark, "DarkMode_Explorer")
    ApplyDarkThemeToControl(myGui["CB2"].Hwnd, gIsDark, "DarkMode_Explorer")
    ApplyDarkThemeToControl(myGui["Rad1"].Hwnd, gIsDark, "DarkMode_Explorer")
    ApplyDarkThemeToControl(myGui["Rad2"].Hwnd, gIsDark, "DarkMode_Explorer")

    ; -- ListView --
    ApplyDarkThemeToControl(myGui["LV"].Hwnd, gIsDark, "DarkMode_Explorer")
    ; ListView header is a child window - get and theme it separately
    hHeader := SendMessage(0x101F, 0, 0, myGui["LV"].Hwnd)  ; LVM_GETHEADER
    if (hHeader) {
        AllowDarkModeForWindow(hHeader, gIsDark)
        ApplyDarkThemeToControl(hHeader, gIsDark, "DarkMode_Explorer")
        SendMessage(0x031A, 0, 0, hHeader)  ; WM_THEMECHANGED
    }
    ; ListView row colors
    if (gIsDark) {
        myGui["LV"].Opt("+Background" DARK_CTRL)
        SendMessage(0x1024, DARK_TEXT_RGB, 0, myGui["LV"].Hwnd)  ; LVM_SETTEXTCOLOR
        SendMessage(0x1026, 0, DARK_CTRL_RGB, myGui["LV"].Hwnd)  ; LVM_SETTEXTBKCOLOR
        SendMessage(0x1001, 0, DARK_CTRL_RGB, myGui["LV"].Hwnd)  ; LVM_SETBKCOLOR
    } else {
        myGui["LV"].Opt("+BackgroundDefault")
        SendMessage(0x1024, LIGHT_TEXT_RGB, 0, myGui["LV"].Hwnd)
        SendMessage(0x1026, 0, LIGHT_BG_RGB, myGui["LV"].Hwnd)
        SendMessage(0x1001, 0, LIGHT_BG_RGB, myGui["LV"].Hwnd)
    }

    ; -- Tab Control --
    ; SetWindowTheme darkens the tab strip but tab text color is
    ; theme-controlled and cannot be independently changed.
    ApplyDarkThemeToControl(myGui["TabCtrl"].Hwnd, gIsDark, "DarkMode_Explorer")
    ; Theme edit controls inside tabs too
    ApplyDarkThemeToControl(myGui["TabEdit1"].Hwnd, gIsDark, "DarkMode_CFD")

    ; -- Slider --
    ; SetWindowTheme gives dark track/thumb. The gutter and handle colors
    ; are fully theme-controlled - no per-control color API exists.
    ; Custom colors would require NM_CUSTOMDRAW handler (owner-draw).
    ApplyDarkThemeToControl(myGui["Slider"].Hwnd, gIsDark, "DarkMode_Explorer")

    ; -- Progress Bar --
    ; Progress bar supports custom colors via messages - full control!
    if (gIsDark) {
        SendMessage(0x2001, 0, DARK_CTRL_RGB, myGui["Progress"].Hwnd)   ; PBM_SETBKCOLOR (gutter)
        SendMessage(0x0409, 0, DARK_ACCENT_RGB, myGui["Progress"].Hwnd) ; PBM_SETBARCOLOR (bar)
    } else {
        SendMessage(0x2001, 0, 0x00FFFFFF, myGui["Progress"].Hwnd)
        SendMessage(0x0409, 0, 0x0000FF00, myGui["Progress"].Hwnd)      ; Green for demo
    }

    ; -- Status Bar --
    ApplyDarkThemeToControl(myGui["SB"].Hwnd, gIsDark, "DarkMode_Explorer")
    ; StatusBar background via SB_SETBKCOLOR
    if (gIsDark) {
        SendMessage(0x2001, 0, DARK_CTRL_RGB, myGui["SB"].Hwnd)  ; SB_SETBKCOLOR
        sb.SetText(" Ready - Dark Mode")
    } else {
        SendMessage(0x2001, 0, 0x00FFFFFF, myGui["SB"].Hwnd)
        sb.SetText(" Ready - Light Mode")
    }

    ; Force redraw of all controls
    DllCall("InvalidateRect", "Ptr", myGui.Hwnd, "Ptr", 0, "Int", 1)
    DllCall("UpdateWindow", "Ptr", myGui.Hwnd)

    ; Force title bar recompose
    ForceRedrawTitleBar(myGui.Hwnd)
}

; ============================================================
; Dark Mode Helpers
; ============================================================

SetDarkTitleBar(hwnd, enable) {
    value := Buffer(4, 0)
    NumPut("Int", enable ? 1 : 0, value)
    DllCall("dwmapi\DwmSetWindowAttribute",
        "Ptr", hwnd, "Int", DWMWA_USE_IMMERSIVE_DARK_MODE,
        "Ptr", value, "Int", 4, "Int")
}

ApplyDarkThemeToControl(hwnd, enable, themeName) {
    if (enable)
        DllCall("uxtheme\SetWindowTheme", "Ptr", hwnd, "Str", themeName, "Ptr", 0)
    else
        DllCall("uxtheme\SetWindowTheme", "Ptr", hwnd, "Ptr", 0, "Ptr", 0)
    ; Notify control that theme changed
    SendMessage(0x031A, 0, 0, hwnd)  ; WM_THEMECHANGED
}

ForceRedrawTitleBar(hwnd) {
    style := DllCall("GetWindowLong", "Ptr", hwnd, "Int", -16, "Int")
    DllCall("SetWindowLong", "Ptr", hwnd, "Int", -16, "Int", style & ~0x40000)
    DllCall("SetWindowLong", "Ptr", hwnd, "Int", -16, "Int", style)
    DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", 0,
        "Int", 0, "Int", 0, "Int", 0, "Int", 0,
        "UInt", 0x27)  ; SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED
}

; ============================================================
; WM_CTLCOLOR Handlers
; ============================================================

WM_CTLCOLOREDIT(wParam, lParam, msg, hwnd) {
    global gIsDark
    if (!gIsDark)
        return 0
    DllCall("SetTextColor", "Ptr", wParam, "UInt", DARK_TEXT_RGB)
    DllCall("SetBkColor", "Ptr", wParam, "UInt", DARK_CTRL_RGB)
    return gDarkBrush
}

WM_CTLCOLORLISTBOX(wParam, lParam, msg, hwnd) {
    global gIsDark
    if (!gIsDark)
        return 0
    ; This handles the dropdown list portion of DropDownList/ComboBox
    DllCall("SetTextColor", "Ptr", wParam, "UInt", DARK_TEXT_RGB)
    DllCall("SetBkColor", "Ptr", wParam, "UInt", DARK_CTRL_RGB)
    return gDarkBrush
}

WM_CTLCOLORSTATIC(wParam, lParam, msg, hwnd) {
    global gIsDark
    if (!gIsDark)
        return 0
    DllCall("SetTextColor", "Ptr", wParam, "UInt", DARK_TEXT_RGB)
    DllCall("SetBkColor", "Ptr", wParam, "UInt", DARK_BG_RGB)
    return gDarkBgBrush
}
