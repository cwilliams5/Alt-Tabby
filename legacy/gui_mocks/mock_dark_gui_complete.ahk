#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
; Mock: Complete Dark-Themed Settings GUI
; ============================================================
; Combines all dark mode techniques into a cohesive settings
; interface that mirrors a typical config editor pattern.
;
; Techniques integrated:
; 1. DwmSetWindowAttribute for dark title bar
; 2. SetWindowTheme for native control dark mode
; 3. WM_CTLCOLOR* for Edit/Static text colors
; 4. GUI BackColor for window background
; 5. WM_SETTINGCHANGE for auto-theme switching
; 6. Custom button panel with dark styling
; 7. ListView with dark text/background colors
; 8. Sidebar navigation with dark theme support
;
; Layout: Sidebar + Content area (similar to Alt-Tabby config editor)
;
; Windows Version: Windows 10 1903+ (build 18362)
; ============================================================

; ============================================================
; Constants & Theme Definition
; ============================================================

class Theme {
    ; Dark theme colors
    static DarkBg          := "1E1E1E"
    static DarkBgRGB       := 0x1E1E1E
    static DarkSurface     := "252526"
    static DarkSurfaceRGB  := 0x252526
    static DarkControl     := "2D2D30"
    static DarkControlRGB  := 0x2D2D30
    static DarkBorder      := "3F3F46"
    static DarkText        := "D4D4D4"
    static DarkTextRGB     := 0xD4D4D4
    static DarkTextDim     := "808080"
    static DarkAccent      := "0078D4"
    static DarkAccentRGB   := 0x0078D4
    static DarkSidebar     := "252526"
    static DarkSidebarSel  := "37373D"
    static DarkHeader      := "2D2D30"

    ; Light theme colors
    static LightBg         := "FFFFFF"
    static LightBgRGB      := 0xFFFFFF
    static LightSurface    := "F3F3F3"
    static LightSurfaceRGB := 0xF3F3F3
    static LightControl    := "FFFFFF"
    static LightControlRGB := 0xFFFFFF
    static LightText       := "1E1E1E"
    static LightTextRGB    := 0x1E1E1E
    static LightTextDim    := "6E6E6E"
    static LightAccent     := "0078D4"
    static LightSidebar    := "F3F3F3"
}

; DWM
DWMWA_USE_IMMERSIVE_DARK_MODE := 20

; ============================================================
; Global State
; ============================================================

global gIsDark := false
global gMainGui := 0
global gSidebar := 0
global gPages := Map()
global gCurrentPage := ""
global gControls := Map()
global gDarkBrush := DllCall("CreateSolidBrush", "UInt", Theme.DarkControlRGB, "Ptr")
global gDarkBgBrush := DllCall("CreateSolidBrush", "UInt", Theme.DarkBgRGB, "Ptr")
global gDarkSurfaceBrush := DllCall("CreateSolidBrush", "UInt", Theme.DarkSurfaceRGB, "Ptr")

; ============================================================
; Settings Data (mock)
; ============================================================

gSettings := [
    {section: "General", items: [
        {name: "AppName",       type: "edit",   label: "Application Name",   value: "Alt-Tabby",    desc: "Display name shown in title bar and tray"},
        {name: "Language",      type: "ddl",    label: "Language",           value: "English",      desc: "UI language", options: ["English", "German", "Japanese", "Spanish"]},
        {name: "StartMinimized",type: "check",  label: "Start Minimized",   value: true,           desc: "Start in system tray instead of showing main window"},
        {name: "RunAtStartup",  type: "check",  label: "Run at Startup",    value: true,           desc: "Launch automatically when Windows starts"},
        {name: "CheckUpdates",  type: "check",  label: "Auto-check Updates",value: true,           desc: "Check for updates on launch"},
    ]},
    {section: "Appearance", items: [
        {name: "Theme",         type: "ddl",    label: "Theme",             value: "Auto",         desc: "Color theme for the UI", options: ["Auto", "Dark", "Light"]},
        {name: "Opacity",       type: "slider", label: "Window Opacity",    value: 95, min: 20, max: 100, desc: "Overlay window opacity (20-100)"},
        {name: "FontSize",      type: "edit",   label: "Font Size",         value: "10",           desc: "UI font size in points"},
        {name: "AccentColor",   type: "edit",   label: "Accent Color",      value: "0x0078D4",     desc: "Accent color for highlights (hex RRGGBB)"},
        {name: "ShowBorder",    type: "check",  label: "Show Window Border",value: true,           desc: "Draw a border around the overlay"},
        {name: "BorderWidth",   type: "edit",   label: "Border Width",      value: "2",            desc: "Border width in pixels"},
    ]},
    {section: "Behavior", items: [
        {name: "GracePeriod",   type: "edit",   label: "Grace Period (ms)", value: "150",          desc: "Quick switch threshold in milliseconds"},
        {name: "MaxItems",      type: "edit",   label: "Max Visible Items", value: "12",           desc: "Maximum items shown in the overlay"},
        {name: "PreWarm",       type: "check",  label: "Pre-warm Data",     value: true,           desc: "Request window data when Alt is pressed"},
        {name: "CycleMode",     type: "ddl",    label: "Cycle Mode",        value: "MRU",          desc: "Window ordering mode", options: ["MRU", "Z-Order", "Alphabetical"]},
    ]},
    {section: "Advanced", items: [
        {name: "DebugLog",      type: "check",  label: "Enable Debug Log",  value: false,          desc: "Write diagnostic info to log file"},
        {name: "IPCTimeout",    type: "edit",   label: "IPC Timeout (ms)",  value: "1000",         desc: "Named pipe connection timeout"},
        {name: "PipeName",      type: "edit",   label: "Pipe Name",         value: "tabby_store",  desc: "Named pipe identifier for IPC"},
        {name: "WinEventDebounce",type: "edit",  label: "Event Debounce (ms)",value: "50",         desc: "Debounce interval for window events"},
    ]},
]

; ============================================================
; Build GUI
; ============================================================

BuildMainGUI() {
    global gMainGui, gSidebar, gIsDark

    ; Detect system theme for initial state
    gIsDark := IsSystemDarkMode()

    sidebarW := 200
    contentW := 440
    totalW := sidebarW + contentW
    totalH := 520

    gMainGui := Gui("+Resize +MinSize" totalW "x400", "Settings")
    gMainGui.SetFont("s10", "Segoe UI")
    gMainGui.MarginX := 0
    gMainGui.MarginY := 0

    ; -- Sidebar --
    sidebarItems := []
    for section in gSettings
        sidebarItems.Push(section.section)

    gSidebar := gMainGui.AddListBox("x0 y0 w" sidebarW " h" (totalH - 50) " vSidebar", sidebarItems)
    gSidebar.OnEvent("Change", OnSidebarSelect)

    ; -- Theme toggle button at bottom of sidebar --
    themeBtn := gMainGui.AddButton("x10 y" (totalH - 45) " w" (sidebarW - 20) " h35 vThemeToggle",
        gIsDark ? "Switch to Light" : "Switch to Dark")
    themeBtn.OnEvent("Click", ToggleTheme)

    ; -- Content pages --
    for section in gSettings {
        BuildPage(section, sidebarW, contentW, totalH - 50)
    }

    ; -- Footer buttons --
    footerY := totalH - 45
    gMainGui.AddButton("x" (totalW - 200) " y" footerY " w88 h32 vSaveBtn +Default", "Save")
        .OnEvent("Click", OnSave)
    gMainGui.AddButton("x" (totalW - 105) " y" footerY " w88 h32 vCancelBtn", "Cancel")
        .OnEvent("Click", (*) => ExitApp())

    ; Apply initial theme
    ApplyTheme(gIsDark)

    ; Select first page
    gSidebar.Value := 1
    OnSidebarSelect(gSidebar, "")

    ; Register message handlers
    OnMessage(0x0133, WM_CTLCOLOREDIT)   ; WM_CTLCOLOREDIT
    OnMessage(0x0134, WM_CTLCOLOREDIT)   ; WM_CTLCOLORLISTBOX
    OnMessage(0x0138, WM_CTLCOLORSTATIC) ; WM_CTLCOLORSTATIC

    ; Listen for system theme changes
    OnMessage(0x001A, WM_SettingChange)

    gMainGui.OnEvent("Close", (*) => ExitApp())
    gMainGui.OnEvent("Size", OnResize)

    ; Show with dark title bar if needed
    if (gIsDark)
        SetDarkTitleBar(gMainGui.Hwnd, true)

    gMainGui.Show("w" totalW " h" totalH)

    ; Force title bar update after show
    if (gIsDark)
        ForceRedrawTitleBar(gMainGui.Hwnd)
}

BuildPage(section, startX, contentW, contentH) {
    global gMainGui, gPages, gControls

    ; Create a child GUI for each page (hidden by default)
    pageGui := Gui("+Parent" gMainGui.Hwnd " -Caption +E0x10000")  ; WS_EX_CONTROLPARENT
    pageGui.SetFont("s10", "Segoe UI")
    pageGui.MarginX := 15
    pageGui.MarginY := 10

    yPos := 15

    ; Section header
    pageGui.SetFont("s14 Bold", "Segoe UI")
    pageGui.AddText("x15 y" yPos " w" (contentW - 30) " vHeader_" section.section, section.section)
    pageGui.SetFont("s10 Normal", "Segoe UI")
    yPos += 40

    ; Settings items
    for item in section.items {
        ; Label
        pageGui.AddText("x15 y" yPos " w180 h22 vLabel_" item.name " +0x200", item.label)

        ; Control
        ctrlX := 200
        ctrlW := contentW - 220

        switch item.type {
            case "edit":
                ctrl := pageGui.AddEdit("x" ctrlX " y" (yPos - 2) " w" Min(ctrlW, 200) " h24 vCtrl_" item.name, item.value)
                gControls[item.name] := {ctrl: ctrl, type: "edit", hwnd: ctrl.Hwnd}

            case "check":
                ctrl := pageGui.AddCheckbox("x" ctrlX " y" yPos " w" ctrlW " vCtrl_" item.name
                    (item.value ? " Checked" : ""), "")
                gControls[item.name] := {ctrl: ctrl, type: "check", hwnd: ctrl.Hwnd}

            case "ddl":
                ctrl := pageGui.AddDropDownList("x" ctrlX " y" (yPos - 2) " w" Min(ctrlW, 200) " vCtrl_" item.name, item.options)
                ; Set initial value
                for i, opt in item.options {
                    if (opt = item.value) {
                        ctrl.Value := i
                        break
                    }
                }
                gControls[item.name] := {ctrl: ctrl, type: "ddl", hwnd: ctrl.Hwnd}

            case "slider":
                ctrl := pageGui.AddSlider("x" ctrlX " y" yPos " w" Min(ctrlW, 200) " vCtrl_" item.name
                    " Range" item.min "-" item.max " ToolTip", item.value)
                gControls[item.name] := {ctrl: ctrl, type: "slider", hwnd: ctrl.Hwnd}
        }

        ; Description text
        yPos += 28
        pageGui.SetFont("s8", "Segoe UI")
        pageGui.AddText("x15 y" yPos " w" (contentW - 30) " vDesc_" item.name " +Wrap", item.desc)
        pageGui.SetFont("s10", "Segoe UI")

        yPos += 30
    }

    gPages[section.section] := {gui: pageGui, height: yPos}
}

; ============================================================
; Navigation
; ============================================================

OnSidebarSelect(ctrl, *) {
    global gCurrentPage, gPages, gMainGui

    selected := ctrl.Text
    if (selected = gCurrentPage)
        return

    ; Hide current page
    if (gCurrentPage != "" && gPages.Has(gCurrentPage)) {
        gPages[gCurrentPage].gui.Show("Hide")
    }

    ; Show selected page
    gCurrentPage := selected
    if (gPages.Has(selected)) {
        page := gPages[selected]
        ; Position page in content area
        sidebarW := 200
        page.gui.Show("x" sidebarW " y0 w440 h" Max(page.height, 470) " NoActivate")
    }
}

; ============================================================
; Theme Switching
; ============================================================

ToggleTheme(*) {
    global gIsDark
    gIsDark := !gIsDark
    ApplyTheme(gIsDark)
}

ApplyTheme(isDark) {
    global gMainGui, gSidebar, gPages, gControls

    ; Window background
    if (isDark) {
        gMainGui.BackColor := Theme.DarkBg
        gMainGui.SetFont("c" Theme.DarkText)
        gMainGui.Title := "Settings [Dark Mode]"
        gMainGui["ThemeToggle"].Text := "Switch to Light"
    } else {
        gMainGui.BackColor := Theme.LightBg
        gMainGui.SetFont("c" Theme.LightText)
        gMainGui.Title := "Settings [Light Mode]"
        gMainGui["ThemeToggle"].Text := "Switch to Dark"
    }

    ; Dark title bar
    SetDarkTitleBar(gMainGui.Hwnd, isDark)
    ForceRedrawTitleBar(gMainGui.Hwnd)

    ; Sidebar theme
    ApplyDarkThemeToControl(gSidebar.Hwnd, isDark, "DarkMode_Explorer")

    ; Apply to all pages
    for name, page in gPages {
        if (isDark) {
            page.gui.BackColor := Theme.DarkBg
            page.gui.SetFont("c" Theme.DarkText)
        } else {
            page.gui.BackColor := Theme.LightBg
            page.gui.SetFont("c" Theme.LightText)
        }
    }

    ; Apply to individual controls
    for name, info in gControls {
        switch info.type {
            case "edit":
                ApplyDarkThemeToControl(info.hwnd, isDark, "DarkMode_CFD")
            case "ddl":
                ApplyDarkThemeToControl(info.hwnd, isDark, "DarkMode_CFD")
            case "slider":
                ApplyDarkThemeToControl(info.hwnd, isDark, "DarkMode_Explorer")
        }
    }

    ; Force full repaint
    DllCall("InvalidateRect", "Ptr", gMainGui.Hwnd, "Ptr", 0, "Int", 1)
    DllCall("UpdateWindow", "Ptr", gMainGui.Hwnd)

    ; Repaint pages
    for name, page in gPages {
        DllCall("InvalidateRect", "Ptr", page.gui.Hwnd, "Ptr", 0, "Int", 1)
        DllCall("UpdateWindow", "Ptr", page.gui.Hwnd)
    }
}

; ============================================================
; Event Handlers
; ============================================================

OnSave(*) {
    global gMainGui, gIsDark
    ; In production, save to INI here
    title := gIsDark ? "Saved" : "Saved"
    msg := "Settings have been saved successfully."

    ; Use our dark-aware approach
    if (gIsDark) {
        ; Show themed save confirmation
        saveGui := Gui("+Owner" gMainGui.Hwnd " -MinimizeBox -MaximizeBox +ToolWindow", "Saved")
        saveGui.BackColor := Theme.DarkBg
        saveGui.SetFont("s10 c" Theme.DarkText, "Segoe UI")
        SetDarkTitleBar(saveGui.Hwnd, true)
        saveGui.AddText("x20 y20 w250", msg)
        okBtn := saveGui.AddButton("x100 y60 w88 h30 +Default", "OK")
        okBtn.OnEvent("Click", (*) => saveGui.Destroy())
        saveGui.OnEvent("Escape", (*) => saveGui.Destroy())
        saveGui.Show("w290 h110")
        ForceRedrawTitleBar(saveGui.Hwnd)
    } else {
        MsgBox(msg, title, "Iconi")
    }
}

OnResize(gui, minMax, width, height) {
    global gSidebar, gCurrentPage, gPages

    if (minMax = -1)  ; Minimized
        return

    sidebarW := 200
    contentW := width - sidebarW

    ; Resize sidebar
    gSidebar.Move(0, 0, sidebarW, height - 50)
    gMainGui["ThemeToggle"].Move(10, height - 45, sidebarW - 20, 35)

    ; Resize current page
    if (gCurrentPage != "" && gPages.Has(gCurrentPage)) {
        page := gPages[gCurrentPage]
        page.gui.Move(sidebarW, 0, contentW, height - 50)
    }

    ; Reposition footer buttons
    gMainGui["SaveBtn"].Move(width - 200, height - 45, 88, 32)
    gMainGui["CancelBtn"].Move(width - 105, height - 45, 88, 32)
}

; ============================================================
; System Theme Detection
; ============================================================

WM_SettingChange(wParam, lParam, msg, hwnd) {
    if (lParam = 0)
        return
    settingName := StrGet(lParam, "UTF-16")
    if (settingName = "ImmersiveColorSet") {
        ; Check if theme mode in settings is "Auto"
        ; For this demo, always auto-switch
        newDark := IsSystemDarkMode()
        global gIsDark
        if (newDark != gIsDark) {
            gIsDark := newDark
            ApplyTheme(gIsDark)
        }
    }
}

IsSystemDarkMode() {
    try {
        value := RegRead("HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme")
        return (value = 0)
    } catch {
        return false
    }
}

; ============================================================
; WM_CTLCOLOR Handlers
; ============================================================

WM_CTLCOLOREDIT(wParam, lParam, msg, hwnd) {
    global gIsDark
    if (!gIsDark)
        return 0

    DllCall("SetTextColor", "Ptr", wParam, "UInt", Theme.DarkTextRGB)
    DllCall("SetBkColor", "Ptr", wParam, "UInt", Theme.DarkControlRGB)
    return gDarkBrush
}

WM_CTLCOLORSTATIC(wParam, lParam, msg, hwnd) {
    global gIsDark
    if (!gIsDark)
        return 0

    DllCall("SetTextColor", "Ptr", wParam, "UInt", Theme.DarkTextRGB)
    DllCall("SetBkColor", "Ptr", wParam, "UInt", Theme.DarkBgRGB)
    return gDarkBgBrush
}

; ============================================================
; DWM Helpers
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
; Launch
; ============================================================

BuildMainGUI()
