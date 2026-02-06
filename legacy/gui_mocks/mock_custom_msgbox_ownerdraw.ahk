#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
; Mock: Custom Themed Message Box with Owner-Draw Buttons
; ============================================================
; Extension of mock_custom_msgbox.ahk that uses BS_OWNERDRAW
; + WM_DRAWITEM for full button painting control.
;
; What owner-draw gives us beyond SetWindowTheme:
; - Custom hover color (blue accent)
; - Custom pressed color
; - Custom border and corner radius
; - Per-button color differentiation (default vs secondary)
;
; Technique:
; 1. BS_OWNERDRAW (style 0x0B) replaces normal button painting
; 2. WM_DRAWITEM (0x002B) handler paints background, border, text
; 3. Hover tracking via periodic WindowFromPoint polling
; 4. RoundRect for modern rounded corners
;
; Trade-off vs SetWindowTheme approach:
; + Full color control (hover, pressed, border, per-button)
; + Consistent look across Windows versions
; - More code (~100 lines of paint logic)
; - Must handle all states manually (focus, disabled, etc.)
; - Keyboard focus rect is custom-drawn
;
; Production note: hover tracking could use TrackMouseEvent
; + WM_MOUSELEAVE via button subclassing for zero-polling.
; Timer approach used here for simplicity.
;
; Windows Version: Windows 10 1903+
; ============================================================

; -- Theme Colors (GDI uses BGR: 0x00BBGGRR) --

; Dark mode button colors
global OD_DARK_BTN_BG         := 0x3C3C3C  ; Normal background
global OD_DARK_BTN_BORDER     := 0x555555  ; Normal border
global OD_DARK_BTN_TEXT       := 0xE0E0E0  ; Normal text
global OD_DARK_BTN_HOVER_BG   := 0xD47800  ; #0078D4 blue (BGR)
global OD_DARK_BTN_PRESSED_BG := 0x9E5A00  ; #005A9E darker blue (BGR)
global OD_DARK_BTN_ACCENT_TEXT := 0xFFFFFF  ; White text on blue
global OD_DARK_BTN_DEF_BORDER := 0xD47800  ; Blue border for default button

; Light mode button colors
global OD_LIGHT_BTN_BG         := 0xE1E1E1
global OD_LIGHT_BTN_BORDER     := 0xADADAD
global OD_LIGHT_BTN_TEXT       := 0x000000
global OD_LIGHT_BTN_HOVER_BG   := 0xD47800  ; Same blue
global OD_LIGHT_BTN_PRESSED_BG := 0x9E5A00
global OD_LIGHT_BTN_ACCENT_TEXT := 0xFFFFFF
global OD_LIGHT_BTN_DEF_BORDER := 0xD47800

; Window colors (RGB strings for AHK Gui.BackColor)
global OD_DARK_BG   := "1E1E1E"
global OD_DARK_TEXT  := "E0E0E0"
global OD_LIGHT_BG  := "FFFFFF"
global OD_LIGHT_TEXT := "000000"

; DWM
global OD_DWMWA_DARK := 20

; -- Owner-draw state --
global gOD_ButtonMap := Map()   ; btnHwnd -> {text, hover, isDefault, isDark}
global gOD_HoverTimerFn := 0
global gOD_Result := ""

; -- Set preferred app mode BEFORE creating any windows --
; uxtheme ordinal #135 (SetPreferredAppMode) - ordinal-only export
; Mode: 0=Default, 1=AllowDark, 2=ForceDark, 3=ForceLight
; This themes the non-client area (close button, scrollbars, etc.)
_OD_GetUxthemeOrdinal(ordinal) {
    static hMod := DllCall("GetModuleHandle", "Str", "uxtheme", "Ptr")
    return DllCall("GetProcAddress", "Ptr", hMod, "Ptr", ordinal, "Ptr")
}
DllCall(_OD_GetUxthemeOrdinal(135), "Int", 1, "Int")  ; AllowDark
DllCall(_OD_GetUxthemeOrdinal(136))                     ; FlushMenuThemes

; Register WM_DRAWITEM globally (checks button map, no-ops for unknown controls)
OnMessage(0x002B, OD_WM_DRAWITEM)

; ============================================================
; Public API
; ============================================================

DarkMsgBoxOD(text, title := "Message", buttons := "OK", icon := "", darkMode := -1, ownerHwnd := 0) {
    global gOD_Result, gOD_ButtonMap, gOD_HoverTimerFn
    gOD_Result := ""
    gOD_ButtonMap := Map()

    if (darkMode = -1)
        darkMode := OD_IsSystemDarkMode()

    ; --- Layout ---
    textWidth := 340
    iconWidth := (icon != "") ? 48 : 0
    iconPad := (icon != "") ? 16 : 0
    contentX := 20 + iconWidth + iconPad
    msgWidth := contentX + textWidth + 20

    lines := StrSplit(text, "`n")
    textHeight := Max(lines.Length * 20, 40)
    contentH := Max(textHeight, iconWidth) + 20
    btnPanelH := 55
    totalH := 20 + contentH + btnPanelH

    ; --- Create GUI ---
    msgGui := Gui("+Owner" ownerHwnd " -MinimizeBox -MaximizeBox", title)
    msgGui.SetFont("s10", "Segoe UI")

    if (darkMode) {
        msgGui.BackColor := OD_DARK_BG
        msgGui.SetFont("c" OD_DARK_TEXT)
    } else {
        msgGui.BackColor := OD_LIGHT_BG
        msgGui.SetFont("c" OD_LIGHT_TEXT)
    }

    ; --- Icon (Unicode symbols, no external resources) ---
    if (icon != "") {
        iconChar := ""
        switch icon {
            case "Info":     iconChar := Chr(0x2139)
            case "Warning":  iconChar := Chr(0x26A0)
            case "Error":    iconChar := Chr(0x274C)
            case "Question": iconChar := Chr(0x2753)
        }
        msgGui.SetFont("s28", "Segoe UI Emoji")
        msgGui.AddText("x20 y20 w48 h48 +Center", iconChar)
        msgGui.SetFont("s10", "Segoe UI")
        msgGui.SetFont("c" (darkMode ? OD_DARK_TEXT : OD_LIGHT_TEXT))
    }

    ; --- Message text ---
    msgGui.AddText("x" contentX " y25 w" textWidth " +Wrap", text)

    ; --- Buttons ---
    btnW := 88
    btnH := 32
    panelY := 20 + contentH
    btnY := panelY + 12
    btnSpacing := 8

    btnList := []
    switch buttons {
        case "OK":           btnList := ["OK"]
        case "OKCancel":     btnList := ["OK", "Cancel"]
        case "YesNo":        btnList := ["Yes", "No"]
        case "YesNoCancel":  btnList := ["Yes", "No", "Cancel"]
    }

    totalBtnW := btnList.Length * btnW + (btnList.Length - 1) * btnSpacing
    btnX := msgWidth - totalBtnW - 20

    for i, btnText in btnList {
        btn := msgGui.AddButton(
            "x" btnX " y" btnY " w" btnW " h" btnH
            (i = 1 ? " +Default" : ""),
            btnText)
        btn.OnEvent("Click", OD_BtnClick.Bind(btnText, msgGui))

        ; Replace button style with BS_OWNERDRAW (0x0B)
        ; Clears BS_PUSHBUTTON/BS_DEFPUSHBUTTON bits (low nibble)
        ; We track isDefault ourselves for custom border rendering
        style := DllCall("GetWindowLong", "Ptr", btn.Hwnd, "Int", -16, "Int")
        style := (style & ~0xF) | 0xB
        DllCall("SetWindowLong", "Ptr", btn.Hwnd, "Int", -16, "Int", style)

        ; Register in tracking map
        gOD_ButtonMap[btn.Hwnd] := {
            text: btnText,
            hover: false,
            isDefault: (i = 1),
            isDark: darkMode ? true : false
        }

        btnX += btnW + btnSpacing
    }

    ; --- Dark window frame (title bar + close button) ---
    ; AllowDarkModeForWindow (ordinal #133) - themes non-client controls
    DllCall(_OD_GetUxthemeOrdinal(133), "Ptr", msgGui.Hwnd, "Int", darkMode ? 1 : 0)
    ; Dark title bar via DWM
    if (darkMode) {
        val := Buffer(4, 0)
        NumPut("Int", 1, val)
        DllCall("dwmapi\DwmSetWindowAttribute",
            "Ptr", msgGui.Hwnd, "Int", OD_DWMWA_DARK,
            "Ptr", val, "Int", 4, "Int")
    }

    ; --- Start hover tracking (30ms poll) ---
    gOD_HoverTimerFn := OD_CheckHover
    SetTimer(gOD_HoverTimerFn, 30)

    ; --- Keyboard / close ---
    msgGui.OnEvent("Escape", (*) => (gOD_Result := "Cancel", msgGui.Destroy()))
    msgGui.OnEvent("Close", (*) => (gOD_Result := "Cancel", msgGui.Destroy()))

    ; --- Show and block ---
    msgGui.Show("w" msgWidth " h" totalH)

    if (ownerHwnd)
        DllCall("EnableWindow", "Ptr", ownerHwnd, "Int", 0)

    WinWaitClose(msgGui.Hwnd)

    ; --- Cleanup ---
    SetTimer(gOD_HoverTimerFn, 0)
    gOD_ButtonMap := Map()

    if (ownerHwnd) {
        DllCall("EnableWindow", "Ptr", ownerHwnd, "Int", 1)
        DllCall("SetForegroundWindow", "Ptr", ownerHwnd)
    }

    return gOD_Result
}

; ============================================================
; WM_DRAWITEM Handler (0x002B)
; ============================================================
; DRAWITEMSTRUCT layout (64-bit):
;   Offset  Size  Field
;   0       4     CtlType (ODT_BUTTON = 4)
;   4       4     CtlID
;   8       4     itemID
;   12      4     itemAction
;   16      4     itemState (ODS_SELECTED=0x01, ODS_FOCUS=0x10, ODS_DISABLED=0x04)
;   20      4     (padding for pointer alignment)
;   24      8     hwndItem
;   32      8     hDC
;   40      16    rcItem (left, top, right, bottom as INT)
;   56      8     itemData

OD_WM_DRAWITEM(wParam, lParam, msg, hwnd) {
    global gOD_ButtonMap

    ; Only handle buttons (ODT_BUTTON = 4)
    if (NumGet(lParam, 0, "UInt") != 4)
        return 0

    ; Parse struct
    itemState := NumGet(lParam, 16, "UInt")
    btnHwnd   := NumGet(lParam, 24, "Ptr")
    hdc       := NumGet(lParam, 32, "Ptr")
    left      := NumGet(lParam, 40, "Int")
    top       := NumGet(lParam, 44, "Int")
    right     := NumGet(lParam, 48, "Int")
    bottom    := NumGet(lParam, 52, "Int")

    ; Only paint our tracked buttons
    if (!gOD_ButtonMap.Has(btnHwnd))
        return 0

    btnInfo := gOD_ButtonMap[btnHwnd]

    ; Decode state
    isPressed  := (itemState & 0x0001)  ; ODS_SELECTED
    isFocused  := (itemState & 0x0010)  ; ODS_FOCUS
    isDisabled := (itemState & 0x0004)  ; ODS_DISABLED
    isHover    := btnInfo.hover

    ; --- Choose colors ---
    if (btnInfo.isDark) {
        if (isPressed) {
            bgColor     := OD_DARK_BTN_PRESSED_BG
            textColor   := OD_DARK_BTN_ACCENT_TEXT
            borderColor := OD_DARK_BTN_PRESSED_BG
        } else if (isHover) {
            bgColor     := OD_DARK_BTN_HOVER_BG
            textColor   := OD_DARK_BTN_ACCENT_TEXT
            borderColor := OD_DARK_BTN_HOVER_BG
        } else {
            bgColor     := OD_DARK_BTN_BG
            textColor   := OD_DARK_BTN_TEXT
            borderColor := btnInfo.isDefault ? OD_DARK_BTN_DEF_BORDER : OD_DARK_BTN_BORDER
        }
    } else {
        if (isPressed) {
            bgColor     := OD_LIGHT_BTN_PRESSED_BG
            textColor   := OD_LIGHT_BTN_ACCENT_TEXT
            borderColor := OD_LIGHT_BTN_PRESSED_BG
        } else if (isHover) {
            bgColor     := OD_LIGHT_BTN_HOVER_BG
            textColor   := OD_LIGHT_BTN_ACCENT_TEXT
            borderColor := OD_LIGHT_BTN_HOVER_BG
        } else {
            bgColor     := OD_LIGHT_BTN_BG
            textColor   := OD_LIGHT_BTN_TEXT
            borderColor := btnInfo.isDefault ? OD_LIGHT_BTN_DEF_BORDER : OD_LIGHT_BTN_BORDER
        }
    }

    if (isDisabled)
        textColor := 0x808080

    ; --- Paint rounded rectangle (fill + border) ---
    pen := DllCall("CreatePen", "Int", 0, "Int", 1, "UInt", borderColor, "Ptr")
    brush := DllCall("CreateSolidBrush", "UInt", bgColor, "Ptr")
    oldPen := DllCall("SelectObject", "Ptr", hdc, "Ptr", pen, "Ptr")
    oldBrush := DllCall("SelectObject", "Ptr", hdc, "Ptr", brush, "Ptr")

    DllCall("RoundRect", "Ptr", hdc,
        "Int", left, "Int", top, "Int", right, "Int", bottom,
        "Int", 4, "Int", 4)

    DllCall("SelectObject", "Ptr", hdc, "Ptr", oldPen, "Ptr")
    DllCall("SelectObject", "Ptr", hdc, "Ptr", oldBrush, "Ptr")
    DllCall("DeleteObject", "Ptr", pen)
    DllCall("DeleteObject", "Ptr", brush)

    ; --- Select the button's font into DC ---
    hFont := SendMessage(0x0031, 0, 0, btnHwnd)  ; WM_GETFONT
    oldFont := 0
    if (hFont)
        oldFont := DllCall("SelectObject", "Ptr", hdc, "Ptr", hFont, "Ptr")

    ; --- Draw centered text ---
    DllCall("SetTextColor", "Ptr", hdc, "UInt", textColor)
    DllCall("SetBkMode", "Ptr", hdc, "Int", 1)  ; TRANSPARENT

    rc := Buffer(16)
    NumPut("Int", left, "Int", top, "Int", right, "Int", bottom, rc)
    DllCall("DrawText", "Ptr", hdc, "Str", btnInfo.text, "Int", -1,
        "Ptr", rc, "UInt", 0x25)  ; DT_CENTER | DT_VCENTER | DT_SINGLELINE

    if (oldFont)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", oldFont, "Ptr")

    ; --- Focus rectangle (only when keyboard-focused, not hovered/pressed) ---
    if (isFocused && !isHover && !isPressed) {
        focusRc := Buffer(16)
        NumPut("Int", left + 3, "Int", top + 3, "Int", right - 3, "Int", bottom - 3, focusRc)
        DllCall("DrawFocusRect", "Ptr", hdc, "Ptr", focusRc)
    }

    return 1
}

; ============================================================
; Hover Tracking (timer-based)
; ============================================================

OD_CheckHover() {
    global gOD_ButtonMap

    if (gOD_ButtonMap.Count = 0)
        return

    ; Get window under cursor
    pt := Buffer(8, 0)
    DllCall("GetCursorPos", "Ptr", pt)
    hwndUnder := DllCall("WindowFromPoint",
        "Int64", NumGet(pt, 0, "Int64"), "Ptr")

    for btnHwnd, info in gOD_ButtonMap {
        wasHover := info.hover
        info.hover := (hwndUnder = btnHwnd)
        if (wasHover != info.hover)
            DllCall("InvalidateRect", "Ptr", btnHwnd, "Ptr", 0, "Int", 1)
    }
}

; ============================================================
; Helpers
; ============================================================

OD_BtnClick(btnText, gui, *) {
    global gOD_Result
    gOD_Result := btnText
    gui.Destroy()
}

OD_IsSystemDarkMode() {
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

demoGui := Gui(, "Owner-Draw MsgBox Demo")
demoGui.SetFont("s10", "Segoe UI")
demoGui.BackColor := "F0F0F0"

demoGui.AddText("x20 y15 w400", "Owner-draw buttons with custom hover colors.")
demoGui.AddText("x20 y35 w400", "Compare with mock_custom_msgbox.ahk (theme-only).")

demoGui.AddGroupBox("x20 y65 w280 h130", "Dark Mode MsgBoxes")

btn1 := demoGui.AddButton("x35 y90 w250 h28", "Info - OK (Dark)")
btn1.OnEvent("Click", (*) => OD_ShowResult(DarkMsgBoxOD(
    "This is an informational message.`nDark mode with owner-draw buttons.",
    "Information", "OK", "Info", true, demoGui.Hwnd)))

btn2 := demoGui.AddButton("x35 y123 w250 h28", "Warning - YesNo (Dark)")
btn2.OnEvent("Click", (*) => OD_ShowResult(DarkMsgBoxOD(
    "Are you sure you want to proceed?`nThis action cannot be undone.",
    "Warning", "YesNo", "Warning", true, demoGui.Hwnd)))

btn3 := demoGui.AddButton("x35 y158 w250 h28", "Error - OKCancel (Dark)")
btn3.OnEvent("Click", (*) => OD_ShowResult(DarkMsgBoxOD(
    "An error occurred while saving the file.`nWould you like to retry?",
    "Error", "OKCancel", "Error", true, demoGui.Hwnd)))

demoGui.AddGroupBox("x20 y205 w280 h130", "Light Mode MsgBoxes")

btn4 := demoGui.AddButton("x35 y230 w250 h28", "Question - YesNoCancel (Light)")
btn4.OnEvent("Click", (*) => OD_ShowResult(DarkMsgBoxOD(
    "Do you want to save changes to this document before closing?",
    "Save Changes?", "YesNoCancel", "Question", false, demoGui.Hwnd)))

btn5 := demoGui.AddButton("x35 y263 w250 h28", "Info - OK (Light)")
btn5.OnEvent("Click", (*) => OD_ShowResult(DarkMsgBoxOD(
    "Operation completed successfully.",
    "Success", "OK", "Info", false, demoGui.Hwnd)))

btn6 := demoGui.AddButton("x35 y296 w250 h28", "Auto-detect Theme")
btn6.OnEvent("Click", (*) => OD_ShowResult(DarkMsgBoxOD(
    "This message box automatically detects your Windows theme setting "
    "and applies dark or light mode accordingly.",
    "Auto Theme", "OKCancel", "Info", -1, demoGui.Hwnd)))

demoGui.AddGroupBox("x20 y345 w280 h50", "Result")
demoGui.AddText("x35 y368 w250 vResultText", "Click a button above...")

demoGui.OnEvent("Close", (*) => ExitApp())
demoGui.Show("w320 h410")

OD_ShowResult(result) {
    global demoGui
    demoGui["ResultText"].Text := "Result: " result
}
