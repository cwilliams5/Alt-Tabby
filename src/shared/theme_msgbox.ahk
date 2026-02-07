#Requires AutoHotkey v2.0

; ============================================================
; ThemeMsgBox - Themed Message Box Replacement
; ============================================================
; Drop-in replacement for MsgBox() that respects the theme system.
; Parses MsgBox-compatible option strings for near-mechanical migration:
;
;   ; Before:
;   MsgBox("Error", "Title", "Iconx")
;   result := MsgBox("Question?", "Title", "YesNo Icon?")
;
;   ; After:
;   ThemeMsgBox("Error", "Title", "Iconx")
;   result := ThemeMsgBox("Question?", "Title", "YesNo Icon?")
;
; Returns same strings as MsgBox: "OK", "Yes", "No", "Cancel"
; Falls back to native MsgBox if theme system is not initialized.
; ============================================================

; Result storage for modal wait
global gTMB_Result := ""

; Show a themed message box. Parameters match MsgBox signature.
;   text    - Message text
;   title   - Window title (default "Message")
;   options - MsgBox-compatible option string: "Iconx", "YesNo Icon?", etc.
; Returns: "OK", "Yes", "No", or "Cancel"
ThemeMsgBox(text, title := "Message", options := "") {
    global gTMB_Result, gTheme_Initialized, gTheme_Palette

    ; Fall back to native MsgBox if theme not initialized
    if (!gTheme_Initialized) {
        try return MsgBox(text, title, options)
        catch
            return "OK"
    }

    gTMB_Result := ""

    ; Parse options string
    icon := _TMB_ParseIcon(options)
    buttons := _TMB_ParseButtons(options)
    defaultBtn := _TMB_ParseDefault(options)

    isDark := Theme_IsDark()
    palette := {}
    palette.bg := gTheme_Palette.bg
    palette.panelBg := gTheme_Palette.panelBg
    palette.text := gTheme_Palette.text

    ; Calculate layout
    textWidth := 340
    iconWidth := (icon != "") ? 48 : 0
    iconPad := (icon != "") ? 16 : 0
    contentX := 20 + iconWidth + iconPad
    msgWidth := contentX + textWidth + 20

    ; Measure text height (approximate: 20px per line)
    lines := StrSplit(text, "`n")
    textHeight := Max(lines.Length * 20, 40)

    ; Total height: padding + content + button panel
    contentH := Max(textHeight, iconWidth) + 20
    btnPanelH := 55
    totalH := 20 + contentH + btnPanelH

    ; Create GUI
    msgGui := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox", title)
    _GUI_AntiFlashPrepare(msgGui, Theme_GetBgColor(), true)
    msgGui.SetFont("s10", "Segoe UI")

    ; Apply theme
    themeEntry := Theme_ApplyToGui(msgGui)

    ; -- Icon --
    if (icon != "") {
        iconChar := ""
        switch icon {
            case "Error":    iconChar := Chr(0x274C)   ; Red X
            case "Warning":  iconChar := Chr(0x26A0)   ; Warning triangle
            case "Info":     iconChar := Chr(0x2139)   ; Info circle
            case "Question": iconChar := Chr(0x2753)   ; Question mark
        }
        msgGui.SetFont("s28", "Segoe UI Emoji")
        msgGui.AddText("x20 y20 w48 h48 +Center", iconChar)
        ; Restore font
        msgGui.SetFont("s10 c" palette.text, "Segoe UI")
    }

    ; -- Message text --
    msgGui.AddText("x" contentX " y25 w" textWidth " +Wrap", text)

    ; -- Buttons --
    btnW := 88
    btnH := 32
    btnY := 20 + contentH + 12
    btnSpacing := 8

    ; Determine button list
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

    for i, btnText in btnList {
        isDefault := (defaultBtn > 0) ? (i = defaultBtn) : (i = 1)
        btn := msgGui.AddButton(
            "x" btnX " y" btnY " w" btnW " h" btnH
            (isDefault ? " +Default" : ""),
            btnText)
        btn.OnEvent("Click", _TMB_BtnClick.Bind(btnText, msgGui))
        Theme_ApplyToControl(btn, "Button", themeEntry)
        btnX += btnW + btnSpacing
    }

    ; -- Escape/Close handlers --
    ; Determine cancel result based on button layout
    cancelResult := "Cancel"
    if (buttons = "OK")
        cancelResult := "OK"
    else if (buttons = "YesNo")
        cancelResult := "No"

    msgGui.OnEvent("Escape", (*) => (gTMB_Result := cancelResult, Theme_UntrackGui(msgGui), msgGui.Destroy()))
    msgGui.OnEvent("Close", (*) => (gTMB_Result := cancelResult, Theme_UntrackGui(msgGui), msgGui.Destroy()))

    ; Show centered
    msgGui.Show("w" msgWidth " h" totalH)
    _GUI_AntiFlashReveal(msgGui, true)

    ; Wait for result
    WinWaitClose(msgGui.Hwnd)

    return gTMB_Result
}

_TMB_BtnClick(btnText, gui, *) {
    global gTMB_Result
    gTMB_Result := btnText
    Theme_UntrackGui(gui)
    gui.Destroy()
}

; ============================================================
; Option string parsing
; ============================================================

_TMB_ParseIcon(options) {
    if (InStr(options, "Iconx"))
        return "Error"
    if (InStr(options, "Icon!"))
        return "Warning"
    if (InStr(options, "Iconi"))
        return "Info"
    if (InStr(options, "Icon?"))
        return "Question"
    return ""
}

_TMB_ParseButtons(options) {
    ; Check multi-button patterns first (longer strings)
    if (InStr(options, "YesNoCancel"))
        return "YesNoCancel"
    if (InStr(options, "YesNo"))
        return "YesNo"
    if (InStr(options, "OKCancel"))
        return "OKCancel"
    ; Check for explicit OK or default
    return "OK"
}

_TMB_ParseDefault(options) {
    if (InStr(options, "Default2"))
        return 2
    if (InStr(options, "Default3"))
        return 3
    return 0  ; 0 = default (first button)
}
