#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
; Mock: Custom Themed Message Box Replacement
; ============================================================
; Standard MsgBox cannot be themed - it uses system colors and
; ignores DwmSetWindowAttribute. This creates a custom replacement
; that supports dark mode.
;
; Features:
; - Dark/light mode support
; - Icon display (Info, Warning, Error, Question)
; - Yes/No/Cancel button layouts
; - Owner window support (modal behavior)
; - Keyboard shortcuts (Enter = default, Escape = cancel)
; - Auto-detect system theme
;
; Usage in production code:
;   result := DarkMsgBox("Save changes?", "Confirm", "YesNoCancel", "Question")
;   if (result = "Yes") { ... }
;
; Windows Version: Windows 10 1903+
; ============================================================

; -- Colors --
global DMSG_DARK_BG := "1E1E1E"
global DMSG_DARK_PANEL := "2D2D2D"
global DMSG_DARK_TEXT := "E0E0E0"
global DMSG_DARK_BTN_BG := "3C3C3C"
global DMSG_DARK_BTN_HOVER := "4C4C4C"

global DMSG_LIGHT_BG := "FFFFFF"
global DMSG_LIGHT_PANEL := "F0F0F0"
global DMSG_LIGHT_TEXT := "000000"

global DMSG_DWMWA_DARK := 20

; -- Result storage --
global gDMSG_Result := ""

; ============================================================
; Public API
; ============================================================

; Show a themed message box
; text: Message text
; title: Window title
; buttons: "OK", "OKCancel", "YesNo", "YesNoCancel"
; icon: "Info", "Warning", "Error", "Question", or ""
; darkMode: true/false/-1 (auto-detect)
; ownerHwnd: parent window HWND for modal behavior (0 = none)
; Returns: "OK", "Yes", "No", "Cancel"
DarkMsgBox(text, title := "Message", buttons := "OK", icon := "", darkMode := -1, ownerHwnd := 0) {
    global gDMSG_Result
    gDMSG_Result := ""

    ; Auto-detect theme
    if (darkMode = -1)
        darkMode := IsSystemDarkMode()

    ; Calculate layout
    textWidth := 340
    iconWidth := (icon != "") ? 48 : 0
    iconPad := (icon != "") ? 16 : 0
    contentX := 20 + iconWidth + iconPad
    msgWidth := contentX + textWidth + 20

    ; Measure text height (approximate: 16px per line)
    lines := StrSplit(text, "`n")
    textHeight := Max(lines.Length * 20, 40)

    ; Total height: padding + content + button panel
    contentH := Max(textHeight, iconWidth) + 20
    btnPanelH := 55
    totalH := 20 + contentH + btnPanelH

    ; Create GUI
    msgGui := Gui("+Owner" ownerHwnd " -MinimizeBox -MaximizeBox", title)
    msgGui.SetFont("s10", "Segoe UI")

    if (darkMode) {
        msgGui.BackColor := DMSG_DARK_BG
        msgGui.SetFont("c" DMSG_DARK_TEXT)
    } else {
        msgGui.BackColor := DMSG_LIGHT_BG
        msgGui.SetFont("c" DMSG_LIGHT_TEXT)
    }

    ; -- Icon --
    if (icon != "") {
        ; Use Unicode symbols as icons (no external resources needed)
        iconChar := ""
        iconColor := ""
        switch icon {
            case "Info":     iconChar := Chr(0x2139),  iconColor := "0078D4"   ; Blue
            case "Warning":  iconChar := Chr(0x26A0),  iconColor := "FFB900"   ; Yellow
            case "Error":    iconChar := Chr(0x274C),   iconColor := "E81123"   ; Red
            case "Question": iconChar := Chr(0x2753),   iconColor := "0078D4"   ; Blue
        }
        msgGui.SetFont("s28", "Segoe UI Emoji")
        msgGui.AddText("x20 y20 w48 h48 +Center", iconChar)
        ; Restore normal font
        msgGui.SetFont("s10", "Segoe UI")
        if (darkMode)
            msgGui.SetFont("c" DMSG_DARK_TEXT)
        else
            msgGui.SetFont("c" DMSG_LIGHT_TEXT)
    }

    ; -- Message text --
    msgGui.AddText("x" contentX " y25 w" textWidth " +Wrap", text)

    ; -- Button panel background --
    ; We simulate a panel with a different background using a colored text control
    panelY := 20 + contentH
    panelColor := darkMode ? DMSG_DARK_PANEL : DMSG_LIGHT_PANEL

    ; -- Buttons --
    btnW := 88
    btnH := 32
    btnY := panelY + 12
    btnSpacing := 8

    ; Determine button layout
    btnList := []
    switch buttons {
        case "OK":           btnList := ["OK"]
        case "OKCancel":     btnList := ["OK", "Cancel"]
        case "YesNo":        btnList := ["Yes", "No"]
        case "YesNoCancel":  btnList := ["Yes", "No", "Cancel"]
    }

    ; Right-align buttons
    totalBtnW := btnList.Length * btnW + (btnList.Length - 1) * btnSpacing
    btnX := msgWidth - totalBtnW - 20

    btnCtrls := []
    for i, btnText in btnList {
        btn := msgGui.AddButton(
            "x" btnX " y" btnY " w" btnW " h" btnH
            (i = 1 ? " +Default" : ""),
            btnText)
        btn.OnEvent("Click", MsgBoxBtnClick.Bind(btnText, msgGui))
        btnCtrls.Push(btn)
        btnX += btnW + btnSpacing
    }

    ; -- Dark theme for buttons --
    ; DarkMode_Explorer gives buttons dark background with standard hover.
    ; Button hover/highlight color is theme-controlled. Custom colors (e.g.,
    ; blue accent on primary button) require BS_OWNERDRAW + WM_DRAWITEM
    ; (full owner-draw painting). This is the same limitation as checkbox
    ; fill color - Win32 visual styles control the hover appearance.
    if (darkMode) {
        for btn in btnCtrls
            DllCall("uxtheme\SetWindowTheme", "Ptr", btn.Hwnd, "Str", "DarkMode_Explorer", "Ptr", 0)
    }

    ; -- Dark title bar --
    if (darkMode) {
        val := Buffer(4, 0)
        NumPut("Int", 1, val)
        DllCall("dwmapi\DwmSetWindowAttribute",
            "Ptr", msgGui.Hwnd, "Int", DMSG_DWMWA_DARK,
            "Ptr", val, "Int", 4, "Int")
    }

    ; -- Escape key handler --
    msgGui.OnEvent("Escape", (*) => (gDMSG_Result := "Cancel", msgGui.Destroy()))
    msgGui.OnEvent("Close", (*) => (gDMSG_Result := "Cancel", msgGui.Destroy()))

    ; Show centered on owner or screen
    msgGui.Show("w" msgWidth " h" totalH)

    ; Disable owner if specified (modal)
    if (ownerHwnd)
        DllCall("EnableWindow", "Ptr", ownerHwnd, "Int", 0)

    ; Wait for result
    WinWaitClose(msgGui.Hwnd)

    ; Re-enable owner
    if (ownerHwnd) {
        DllCall("EnableWindow", "Ptr", ownerHwnd, "Int", 1)
        DllCall("SetForegroundWindow", "Ptr", ownerHwnd)
    }

    return gDMSG_Result
}

MsgBoxBtnClick(btnText, gui, *) {
    global gDMSG_Result
    gDMSG_Result := btnText
    gui.Destroy()
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
; Demo GUI
; ============================================================

demoGui := Gui(, "Custom MsgBox Demo")
demoGui.SetFont("s10", "Segoe UI")
demoGui.BackColor := "F0F0F0"

demoGui.AddText("x20 y15 w400", "Test the custom themed message box replacement.")
demoGui.AddText("x20 y35 w400", "Each button shows a different configuration.")

demoGui.AddGroupBox("x20 y65 w280 h130", "Dark Mode MsgBoxes")

btn1 := demoGui.AddButton("x35 y90 w250 h28", "Info - OK (Dark)")
btn1.OnEvent("Click", (*) => ShowResult(DarkMsgBox(
    "This is an informational message.`nDark mode is applied automatically.",
    "Information", "OK", "Info", true, demoGui.Hwnd)))

btn2 := demoGui.AddButton("x35 y123 w250 h28", "Warning - YesNo (Dark)")
btn2.OnEvent("Click", (*) => ShowResult(DarkMsgBox(
    "Are you sure you want to proceed?`nThis action cannot be undone.",
    "Warning", "YesNo", "Warning", true, demoGui.Hwnd)))

btn3 := demoGui.AddButton("x35 y158 w250 h28", "Error - OKCancel (Dark)")
btn3.OnEvent("Click", (*) => ShowResult(DarkMsgBox(
    "An error occurred while saving the file.`nWould you like to retry?",
    "Error", "OKCancel", "Error", true, demoGui.Hwnd)))

demoGui.AddGroupBox("x20 y205 w280 h130", "Light Mode MsgBoxes")

btn4 := demoGui.AddButton("x35 y230 w250 h28", "Question - YesNoCancel (Light)")
btn4.OnEvent("Click", (*) => ShowResult(DarkMsgBox(
    "Do you want to save changes to this document before closing?",
    "Save Changes?", "YesNoCancel", "Question", false, demoGui.Hwnd)))

btn5 := demoGui.AddButton("x35 y263 w250 h28", "Info - OK (Light)")
btn5.OnEvent("Click", (*) => ShowResult(DarkMsgBox(
    "Operation completed successfully.",
    "Success", "OK", "Info", false, demoGui.Hwnd)))

btn6 := demoGui.AddButton("x35 y296 w250 h28", "Auto-detect Theme")
btn6.OnEvent("Click", (*) => ShowResult(DarkMsgBox(
    "This message box automatically detects your Windows theme setting "
    "and applies dark or light mode accordingly.",
    "Auto Theme", "OKCancel", "Info", -1, demoGui.Hwnd)))

demoGui.AddGroupBox("x20 y345 w280 h50", "Result")
demoGui.AddText("x35 y368 w250 vResultText", "Click a button above...")

demoGui.OnEvent("Close", (*) => ExitApp())
demoGui.Show("w320 h410")

ShowResult(result) {
    global demoGui
    demoGui["ResultText"].Text := "Result: " result
}
