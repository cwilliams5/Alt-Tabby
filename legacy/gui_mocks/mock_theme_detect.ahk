#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
; Mock: Detect Windows Theme and React to Changes
; ============================================================
; Demonstrates how to:
; 1. Read the current Windows app theme (dark/light) from registry
; 2. Read the system theme (taskbar/start menu)
; 3. Read the accent color
; 4. Watch for real-time theme changes via WM_SETTINGCHANGE
; 5. Watch for theme changes via registry polling (fallback)
;
; Registry Keys:
;   HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize
;     - AppsUseLightTheme (DWORD): 0 = dark, 1 = light
;     - SystemUsesLightTheme (DWORD): 0 = dark, 1 = light
;
;   HKCU\SOFTWARE\Microsoft\Windows\DWM
;     - AccentColor (DWORD): AABBGGRR format
;     - ColorizationColor (DWORD): AARRGGBB format
;
; Windows Version: Windows 10 1607+ (build 14393)
; ============================================================

; -- State --
global gCurrentAppTheme := ""
global gCurrentSystemTheme := ""
global gCurrentAccentColor := ""
global gChangeCount := 0

; -- Registry constants --
REG_PERSONALIZE := "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"
REG_DWM := "HKCU\SOFTWARE\Microsoft\Windows\DWM"

; ============================================================
; Build GUI
; ============================================================

myGui := Gui("+AlwaysOnTop", "Theme Detection Demo")
myGui.SetFont("s10", "Segoe UI")

myGui.AddText("x20 y15 w400", "Real-time Windows theme detection")
myGui.AddText("x20 y40 w400", "Change your Windows theme in Settings to see updates.")
myGui.AddText("x20 y55 w400", "(Settings > Personalization > Colors)")

; Current state display
myGui.AddGroupBox("x20 y85 w420 h145", "Current Theme State")

myGui.AddText("x35 y110 w130", "App Theme:")
myGui.AddText("x170 y110 w250 vAppThemeText +Bold", "detecting...")

myGui.AddText("x35 y135 w130", "System Theme:")
myGui.AddText("x170 y135 w250 vSystemThemeText +Bold", "detecting...")

myGui.AddText("x35 y160 w130", "Accent Color:")
myGui.AddText("x170 y160 w250 vAccentText +Bold", "detecting...")
myGui.AddProgress("x170 y182 w100 h18 vAccentSwatch", 100)

myGui.AddText("x35 y205 w130", "High Contrast:")
myGui.AddText("x170 y205 w250 vHighContrastText +Bold", "detecting...")

; Change log
myGui.AddGroupBox("x20 y240 w420 h190", "Change Log")
changeLog := myGui.AddEdit("x35 y265 w390 h150 vChangeLog +Multi +ReadOnly +VScroll", "")

; Detection method info
myGui.AddGroupBox("x20 y440 w420 h100", "Detection Methods")
myGui.AddText("x35 y465 w390 +Wrap",
    "Method 1: WM_SETTINGCHANGE (0x001A) - Windows broadcasts this "
    "when theme changes. We listen for 'ImmersiveColorSet' parameter.`n`n"
    "Method 2: Registry polling (fallback) - Timer reads "
    "AppsUseLightTheme every 2 seconds. Useful when WM_SETTINGCHANGE is unreliable.")

myGui.OnEvent("Close", (*) => ExitApp())
myGui.Show("w460 h555")

; ============================================================
; Initial Detection
; ============================================================

DetectTheme()

; ============================================================
; Method 1: WM_SETTINGCHANGE listener
; ============================================================
; Windows sends WM_SETTINGCHANGE (WM_WININICHANGE = 0x001A)
; with lParam pointing to "ImmersiveColorSet" when theme changes

OnMessage(0x001A, WM_SettingChange)

WM_SettingChange(wParam, lParam, msg, hwnd) {
    ; lParam is a pointer to a string - read it
    if (lParam = 0)
        return

    settingName := StrGet(lParam, "UTF-16")
    if (settingName = "ImmersiveColorSet") {
        LogChange("WM_SETTINGCHANGE: ImmersiveColorSet detected")
        DetectTheme()
    }
}

; ============================================================
; Method 2: Registry polling fallback
; ============================================================
; Some scenarios (e.g., programmatic changes) may not trigger
; WM_SETTINGCHANGE. Poll as a safety net.

SetTimer(PollRegistryTheme, 2000)

PollRegistryTheme() {
    global gCurrentAppTheme, gCurrentSystemTheme, gCurrentAccentColor

    appTheme := ReadAppTheme()
    systemTheme := ReadSystemTheme()
    accentColor := ReadAccentColor()

    changed := false
    if (appTheme != gCurrentAppTheme) {
        LogChange("Registry poll: App theme changed to " appTheme)
        changed := true
    }
    if (systemTheme != gCurrentSystemTheme) {
        LogChange("Registry poll: System theme changed to " systemTheme)
        changed := true
    }
    if (accentColor != gCurrentAccentColor) {
        LogChange("Registry poll: Accent color changed to " accentColor)
        changed := true
    }

    if (changed)
        DetectTheme()
}

; ============================================================
; Theme Detection Functions
; ============================================================

DetectTheme() {
    global gCurrentAppTheme, gCurrentSystemTheme, gCurrentAccentColor, myGui

    gCurrentAppTheme := ReadAppTheme()
    gCurrentSystemTheme := ReadSystemTheme()
    gCurrentAccentColor := ReadAccentColor()
    highContrast := IsHighContrast()

    ; Update display
    myGui["AppThemeText"].Text := gCurrentAppTheme
    myGui["SystemThemeText"].Text := gCurrentSystemTheme
    myGui["AccentText"].Text := gCurrentAccentColor
    myGui["HighContrastText"].Text := highContrast ? "YES (active)" : "No"

    ; Update accent color swatch
    ; Extract RGB from the accent color string for the progress bar
    accentRGB := ReadAccentColorRGB()
    if (accentRGB != "")
        myGui["AccentSwatch"].Opt("+Background" accentRGB)

    ; Auto-adapt the demo window itself
    isDark := (gCurrentAppTheme = "DARK")
    ApplyThemeToSelf(isDark)
}

ReadAppTheme() {
    try {
        value := RegRead(REG_PERSONALIZE, "AppsUseLightTheme")
        return (value = 0) ? "DARK" : "LIGHT"
    } catch {
        return "UNKNOWN"
    }
}

ReadSystemTheme() {
    try {
        value := RegRead(REG_PERSONALIZE, "SystemUsesLightTheme")
        return (value = 0) ? "DARK" : "LIGHT"
    } catch {
        return "UNKNOWN"
    }
}

ReadAccentColor() {
    ; ColorizationColor is in AARRGGBB format
    try {
        value := RegRead(REG_DWM, "ColorizationColor")
        return Format("0x{:08X}", value)
    } catch {
        return "UNKNOWN"
    }
}

ReadAccentColorRGB() {
    ; Return just the RGB portion for use with AHK controls
    try {
        value := RegRead(REG_DWM, "ColorizationColor")
        return Format("{:06X}", value & 0xFFFFFF)
    } catch {
        return ""
    }
}

IsHighContrast() {
    ; SPI_GETHIGHCONTRAST = 0x0042
    ; HIGHCONTRAST struct: cbSize (4), dwFlags (4), lpszDefaultScheme (ptr)
    ; HCF_HIGHCONTRASTON = 0x00000001
    hc := Buffer(A_PtrSize = 8 ? 16 : 12, 0)
    NumPut("UInt", hc.Size, hc, 0)
    DllCall("SystemParametersInfo", "UInt", 0x0042, "UInt", hc.Size, "Ptr", hc, "UInt", 0)
    flags := NumGet(hc, 4, "UInt")
    return (flags & 1) != 0
}

; ============================================================
; Self-Adapting Theme
; ============================================================

ApplyThemeToSelf(isDark) {
    global myGui
    DWMWA_USE_IMMERSIVE_DARK_MODE := 20

    if (isDark) {
        myGui.BackColor := "1E1E1E"
        myGui.SetFont("cE0E0E0")
        myGui.Title := "Theme Detection Demo [DARK]"
    } else {
        myGui.BackColor := "F0F0F0"
        myGui.SetFont("c000000")
        myGui.Title := "Theme Detection Demo [LIGHT]"
    }

    ; Dark title bar
    value := Buffer(4, 0)
    NumPut("Int", isDark ? 1 : 0, value)
    DllCall("dwmapi\DwmSetWindowAttribute",
        "Ptr", myGui.Hwnd, "Int", DWMWA_USE_IMMERSIVE_DARK_MODE,
        "Ptr", value, "Int", 4, "Int")

    ; Force title bar refresh
    style := DllCall("GetWindowLong", "Ptr", myGui.Hwnd, "Int", -16, "Int")
    DllCall("SetWindowLong", "Ptr", myGui.Hwnd, "Int", -16, "Int", style & ~0x40000)
    DllCall("SetWindowLong", "Ptr", myGui.Hwnd, "Int", -16, "Int", style)
    DllCall("SetWindowPos", "Ptr", myGui.Hwnd, "Ptr", 0,
        "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x27)

    DllCall("InvalidateRect", "Ptr", myGui.Hwnd, "Ptr", 0, "Int", 1)
}

; ============================================================
; Change Logger
; ============================================================

LogChange(msg) {
    global gChangeCount, myGui
    gChangeCount += 1
    timestamp := FormatTime(, "HH:mm:ss")
    entry := "[" timestamp "] #" gChangeCount ": " msg "`r`n"

    currentText := myGui["ChangeLog"].Text
    myGui["ChangeLog"].Text := entry currentText

    ; Flash the window briefly to indicate change
    DllCall("FlashWindow", "Ptr", myGui.Hwnd, "Int", 1)
}
