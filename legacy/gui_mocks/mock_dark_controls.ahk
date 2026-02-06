#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
; Mock: Dark Themed Common Controls
; ============================================================
; Demonstrates dark mode styling for standard Win32 controls
; in AHK v2 GUIs.
;
; Techniques used:
; 1. DwmSetWindowAttribute for dark title bar
; 2. SetWindowTheme("DarkMode_Explorer") for controls that support it
; 3. Gui.BackColor for the window background
; 4. WM_CTLCOLOREDIT / WM_CTLCOLORSTATIC for text/background in Edit/Static
; 5. Manual font color via SetFont for labels
;
; Control Dark Mode Support Matrix:
; -------------------------------------------------
; Control        | SetWindowTheme | Notes
; -------------------------------------------------
; Edit           | Yes            | DarkMode_CFD or DarkMode_Explorer
; Button         | Partial        | Background stays light without owner-draw
; Checkbox       | Partial        | Check mark area stays light
; Radio          | Partial        | Similar to checkbox
; DropDownList   | Yes            | DarkMode_CFD works well
; ComboBox       | Yes            | DarkMode_CFD works well
; ListBox        | Yes            | DarkMode_Explorer
; ListView       | Yes            | DarkMode_Explorer - header + items
; TreeView       | Yes            | DarkMode_Explorer
; Tab3           | Partial        | Tab strip darkens, content area needs manual color
; Slider         | Yes            | DarkMode_Explorer
; Progress       | Partial        | Track darkens, bar uses system accent
; UpDown         | Partial        | Arrows darken, background may need help
; GroupBox       | No             | Text only - set font color manually
; StatusBar      | Yes            | DarkMode_Explorer
; -------------------------------------------------
;
; Windows Version: Windows 10 1903+ (build 18362)
; ============================================================

; -- Dark mode colors --
DARK_BG     := "1E1E1E"
DARK_BG_RGB := 0x1E1E1E
DARK_CTRL   := "2D2D2D"
DARK_TEXT   := "E0E0E0"
LIGHT_BG    := "F0F0F0"
LIGHT_TEXT  := "000000"

; DWM attribute
DWMWA_USE_IMMERSIVE_DARK_MODE := 20

; GDI brush for control backgrounds
global gDarkBrush := DllCall("CreateSolidBrush", "UInt", 0x2D2D2D, "Ptr")
global gDarkCtrlBrush := DllCall("CreateSolidBrush", "UInt", 0x1E1E1E, "Ptr")
global gIsDark := false

; ============================================================
; Build the Demo GUI
; ============================================================

myGui := Gui("+Resize +MinSize600x500", "Dark Controls Demo")
myGui.SetFont("s10", "Segoe UI")
myGui.BackColor := LIGHT_BG

; -- Toggle button --
toggleBtn := myGui.AddButton("x20 y15 w180 h30", "Switch to Dark Mode")
toggleBtn.OnEvent("Click", ToggleTheme)

myGui.AddText("x210 y22 w300 vModeLabel", "Current: Light Mode")

; -- GroupBox: Text Inputs --
myGui.AddGroupBox("x20 y55 w270 h120 vGroup1", "Text Inputs")
myGui.AddText("x35 y80 w80 vLabel1", "Name:")
nameEdit := myGui.AddEdit("x120 y77 w155 vNameEdit", "Sample text")
myGui.AddText("x35 y110 w80 vLabel2", "Email:")
emailEdit := myGui.AddEdit("x120 y107 w155 vEmailEdit", "user@example.com")
myGui.AddText("x35 y140 w80 vLabel3", "Number:")
numEdit := myGui.AddEdit("x120 y137 w80 vNumEdit +Number", "42")
myGui.AddUpDown("vNumUpDown Range0-100", 42)

; -- GroupBox: Selection Controls --
myGui.AddGroupBox("x310 y55 w270 h120 vGroup2", "Selection Controls")
ddl := myGui.AddDropDownList("x325 y80 w240 vDDL", ["Option 1", "Option 2", "Option 3"])
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
tab := myGui.AddTab3("x20 y355 w560 h110 vTabCtrl", ["General", "Advanced", "About"])

tab.UseTab("General")
myGui.AddText("x35 y385 w200 vTabText1", "General settings would go here.")
myGui.AddEdit("x35 y410 w250 vTabEdit1", "Tab content edit")

tab.UseTab("Advanced")
myGui.AddText("x35 y385 w200 vTabText2", "Advanced settings panel.")

tab.UseTab("About")
myGui.AddText("x35 y385 w300 vTabText3", "Dark mode control demo for AHK v2.")

tab.UseTab()

; -- Slider --
myGui.AddText("x20 y475 w80 vSliderLabel", "Slider:")
slider := myGui.AddSlider("x100 y475 w200 vSlider Range0-100 ToolTip", 50)

; -- Progress --
myGui.AddText("x320 y475 w80 vProgLabel", "Progress:")
prog := myGui.AddProgress("x400 y475 w180 h20 vProgress", 65)

; -- Status Bar --
sb := myGui.AddStatusBar("vSB")
sb.SetText(" Ready - Light Mode")

; Register WM_CTLCOLOR* messages for dark edit/static backgrounds
OnMessage(0x0133, WM_CTLCOLOREDIT)   ; WM_CTLCOLOREDIT
OnMessage(0x0134, WM_CTLCOLOREDIT)   ; WM_CTLCOLORLISTBOX
OnMessage(0x0138, WM_CTLCOLORSTATIC) ; WM_CTLCOLORSTATIC

myGui.OnEvent("Close", (*) => ExitApp())
myGui.Show("w600 h520")

; ============================================================
; Toggle Function
; ============================================================

ToggleTheme(*) {
    global gIsDark, myGui

    gIsDark := !gIsDark

    if (gIsDark) {
        myGui.BackColor := DARK_BG
        myGui.SetFont("c" DARK_TEXT)
        myGui.Title := "Dark Controls Demo [DARK]"
        myGui["ModeLabel"].Text := "Current: Dark Mode"
        toggleBtn.Text := "Switch to Light Mode"
        sb.SetText(" Ready - Dark Mode")
    } else {
        myGui.BackColor := LIGHT_BG
        myGui.SetFont("c" LIGHT_TEXT)
        myGui.Title := "Dark Controls Demo [LIGHT]"
        myGui["ModeLabel"].Text := "Current: Light Mode"
        toggleBtn.Text := "Switch to Dark Mode"
        sb.SetText(" Ready - Light Mode")
    }

    ; Dark title bar
    SetDarkTitleBar(myGui.Hwnd, gIsDark)

    ; Apply dark themes to controls
    ApplyDarkThemeToControl(myGui["NameEdit"].Hwnd, gIsDark, "DarkMode_CFD")
    ApplyDarkThemeToControl(myGui["EmailEdit"].Hwnd, gIsDark, "DarkMode_CFD")
    ApplyDarkThemeToControl(myGui["NumEdit"].Hwnd, gIsDark, "DarkMode_CFD")
    ApplyDarkThemeToControl(myGui["DDL"].Hwnd, gIsDark, "DarkMode_CFD")
    ApplyDarkThemeToControl(myGui["LV"].Hwnd, gIsDark, "DarkMode_Explorer")
    ApplyDarkThemeToControl(myGui["TabCtrl"].Hwnd, gIsDark, "DarkMode_Explorer")
    ApplyDarkThemeToControl(myGui["Slider"].Hwnd, gIsDark, "DarkMode_Explorer")
    ApplyDarkThemeToControl(myGui["SB"].Hwnd, gIsDark, "DarkMode_Explorer")

    ; ListView needs explicit colors for text and background
    if (gIsDark) {
        myGui["LV"].Opt("+Background" DARK_CTRL)
        SendMessage(0x1024, 0x00E0E0E0, 0, myGui["LV"].Hwnd)  ; LVM_SETTEXTCOLOR
        SendMessage(0x1026, 0, 0x002D2D2D, myGui["LV"].Hwnd)   ; LVM_SETTEXTBKCOLOR
        SendMessage(0x1001, 0, 0x002D2D2D, myGui["LV"].Hwnd)   ; LVM_SETBKCOLOR
    } else {
        myGui["LV"].Opt("+BackgroundDefault")
        SendMessage(0x1024, 0x00000000, 0, myGui["LV"].Hwnd)
        SendMessage(0x1026, 0, 0x00FFFFFF, myGui["LV"].Hwnd)
        SendMessage(0x1001, 0, 0x00FFFFFF, myGui["LV"].Hwnd)
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
    ; SetWindowTheme to DarkMode_Explorer/DarkMode_CFD or reset
    if (enable)
        DllCall("uxtheme\SetWindowTheme", "Ptr", hwnd, "Str", themeName, "Ptr", 0)
    else
        DllCall("uxtheme\SetWindowTheme", "Ptr", hwnd, "Ptr", 0, "Ptr", 0)
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
; WM_CTLCOLOR Handlers - Custom paint for Edit and Static controls
; ============================================================

WM_CTLCOLOREDIT(wParam, lParam, msg, hwnd) {
    global gIsDark
    if (!gIsDark)
        return 0

    ; Set text color to light gray
    DllCall("SetTextColor", "Ptr", wParam, "UInt", 0x00E0E0E0)
    ; Set background color
    DllCall("SetBkColor", "Ptr", wParam, "UInt", 0x002D2D2D)
    ; Return dark brush for control background
    return gDarkBrush
}

WM_CTLCOLORSTATIC(wParam, lParam, msg, hwnd) {
    global gIsDark
    if (!gIsDark)
        return 0

    ; Set text color to light gray
    DllCall("SetTextColor", "Ptr", wParam, "UInt", 0x00E0E0E0)
    ; Set background to match window
    DllCall("SetBkColor", "Ptr", wParam, "UInt", 0x001E1E1E)
    ; Return window background brush
    return gDarkCtrlBrush
}
