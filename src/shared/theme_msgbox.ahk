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
    global gTMB_Result, gTheme_Initialized

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

    ; Create GUI
    msgGui := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox", title)
    GUI_AntiFlashPrepare(msgGui, Theme_GetBgColor())
    msgGui.MarginX := 24
    msgGui.MarginY := 16
    msgGui.SetFont("s10", "Segoe UI")
    themeEntry := Theme_ApplyToGui(msgGui)

    contentW := 440
    iconW := 48
    iconPad := 16
    accentColor := Theme_GetAccentColor()
    textW := (icon != "") ? (contentW - iconW - iconPad) : contentW

    ; Icon (emoji) + message text
    if (icon != "") {
        iconChar := ""
        switch icon {
            case "Error":    iconChar := Chr(0x274C)   ; Red X
            case "Warning":  iconChar := Chr(0x26A0)   ; Warning triangle
            case "Info":     iconChar := Chr(0x2139)   ; Info circle
            case "Question": iconChar := Chr(0x2753)   ; Question mark
        }
        msgGui.SetFont("s28", "Segoe UI Emoji")
        msgGui.AddText("x24 w" iconW " h" iconW " +Center", iconChar)
        msgGui.SetFont("s10", "Segoe UI")

        ; Message text next to icon — vertically center single-line, top-align multi-line
        isSingleLine := !InStr(text, "`n") && StrLen(text) < (textW / 7)
        textYOff := isSingleLine ? 14 : 4
        hdr := msgGui.AddText("x" (24 + iconW + iconPad) " yp+" textYOff " w" textW " +Wrap c" accentColor, text)
        Theme_MarkAccent(hdr)
    } else {
        hdr := msgGui.AddText("w" contentW " +Wrap c" accentColor, text)
        Theme_MarkAccent(hdr)
    }

    ; Buttons - right-aligned group, consistent sizing
    btnW := 100
    btnH := 30
    btnGap := 8

    btnList := []
    switch buttons {
        case "OK":           btnList := ["OK"]
        case "OKCancel":     btnList := ["OK", "Cancel"]
        case "YesNo":        btnList := ["Yes", "No"]
        case "YesNoCancel":  btnList := ["Yes", "No", "Cancel"]
    }

    totalBtnW := btnList.Length * btnW + (btnList.Length - 1) * btnGap
    btnStartX := 24 + contentW - totalBtnW

    for i, btnText in btnList {
        isDefault := (defaultBtn > 0) ? (i = defaultBtn) : (i = 1)
        yOpt := (i = 1) ? "y+24" : "yp"
        btn := msgGui.AddButton(
            "x" btnStartX " " yOpt " w" btnW " h" btnH
            (isDefault ? " +Default" : ""),
            btnText)
        btn.OnEvent("Click", _TMB_BtnClick.Bind(btnText, msgGui))
        Theme_ApplyToControl(btn, "Button", themeEntry)
        btnStartX += btnW + btnGap
    }

    ; Escape/Close handlers
    cancelResult := "Cancel"
    if (buttons = "OK")
        cancelResult := "OK"
    else if (buttons = "YesNo")
        cancelResult := "No"

    msgGui.OnEvent("Escape", (*) => (gTMB_Result := cancelResult, Theme_UntrackGui(msgGui), msgGui.Destroy()))
    msgGui.OnEvent("Close", (*) => (gTMB_Result := cancelResult, Theme_UntrackGui(msgGui), msgGui.Destroy()))

    ; Show - fixed width, auto height
    msgGui.Show("w488 Center")
    GUI_AntiFlashReveal(msgGui, true)

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
