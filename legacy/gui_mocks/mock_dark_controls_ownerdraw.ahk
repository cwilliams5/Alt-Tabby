#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
; Mock: Owner-Draw Dark Controls
; ============================================================
; Shows what FULL CONTROL looks like for every control that
; SetWindowTheme alone couldn't fully theme.
;
; Technique per control:
; -------------------------------------------------------
; Control     | Technique                    | Issue Fixed
; -------------------------------------------------------
; Button      | BS_OWNERDRAW + WM_DRAWITEM   | Blue hover
; Checkbox    | BS_OWNERDRAW + WM_DRAWITEM   | Custom check fill color
; Radio       | BS_OWNERDRAW + WM_DRAWITEM   | Custom radio fill color
; DDL         | CBS_OWNERDRAWFIXED+DRAWITEM  | Highlight + black-on-black
; Tab headers | TCS_OWNERDRAWFIXED+DRAWITEM  | Custom tab text color
; Slider      | NM_CUSTOMDRAW via WM_NOTIFY  | Gutter + handle colors
; Progress    | PBM_SETBARCOLOR/BKCOLOR      | Full color control (msgs)
; StatusBar   | SB_SETBKCOLOR                | Background color (msg)
; ListView    | LVM_SET*COLOR + header theme  | Row + header colors
; Edit        | DarkMode_CFD + WM_CTLCOLOR   | Theme is sufficient
; CANNOT FIX  | Edit selection highlight      | System COLOR_HIGHLIGHT
; -------------------------------------------------------
;
; Windows Version: Windows 10 1903+
; ============================================================

; -- Colors (GDI = BGR: 0x00BBGGRR) --
global CLR_ACCENT      := 0xD47800    ; #0078D4 blue
global CLR_ACCENT_DK   := 0x9E5A00    ; #005A9E pressed
global CLR_D_BG        := 0x1E1E1E
global CLR_D_CTRL      := 0x2D2D2D
global CLR_D_CTRL2     := 0x3C3C3C
global CLR_D_TEXT      := 0xE0E0E0
global CLR_D_BORDER    := 0x555555
global CLR_D_GUTTER    := 0x4D4D4D
global CLR_L_BG        := 0xF0F0F0
global CLR_L_CTRL      := 0xFFFFFF
global CLR_L_CTRL2     := 0xE1E1E1
global CLR_L_TEXT      := 0x000000
global CLR_L_BORDER    := 0xADADAD
global CLR_L_GUTTER    := 0xCCCCCC
global CLR_WHITE       := 0xFFFFFF
global CLR_DISABLED    := 0x808080

; AHK strings (RGB for Gui.BackColor/SetFont)
global S_D_BG := "1E1E1E", S_D_TEXT := "E0E0E0", S_D_CTRL := "2D2D2D"
global S_L_BG := "F0F0F0", S_L_TEXT := "000000"

; -- State --
global gIsDark := false
global gODMap := Map()          ; hwnd -> {type, text, ...}
global gCheckState := Map()     ; hwnd -> bool
global gRadioState := Map()     ; hwnd -> bool
global gRadioGroup := []        ; [hwnd, hwnd]
global gSliderHwnd := 0
global gHoverHwnd := 0          ; Currently hovered owner-draw control
global gDDLItems := ["Option 1", "Option 2", "Option 3", "Option 4"]
global gTabNames := ["General", "Advanced", "About"]

; GDI brushes (cached)
global gBrushDarkBg   := DllCall("CreateSolidBrush", "UInt", CLR_D_BG, "Ptr")
global gBrushDarkCtrl := DllCall("CreateSolidBrush", "UInt", CLR_D_CTRL, "Ptr")
global gBrushLightBg  := DllCall("CreateSolidBrush", "UInt", CLR_L_BG, "Ptr")
global gBrushLightCtrl := DllCall("CreateSolidBrush", "UInt", CLR_L_CTRL, "Ptr")

; -- Uxtheme (BEFORE windows) --
_UxOrd(ordinal) {
    static hMod := DllCall("GetModuleHandle", "Str", "uxtheme", "Ptr")
    return DllCall("GetProcAddress", "Ptr", hMod, "Ptr", ordinal, "Ptr")
}
DllCall(_UxOrd(135), "Int", 1, "Int")   ; SetPreferredAppMode(AllowDark)
DllCall(_UxOrd(136))                     ; FlushMenuThemes

; -- Register message handlers --
OnMessage(0x002B, OD_OnDrawItem)       ; WM_DRAWITEM
OnMessage(0x004E, OD_OnNotify)         ; WM_NOTIFY (NM_CUSTOMDRAW)
OnMessage(0x0133, OD_OnCtlColorEdit)   ; WM_CTLCOLOREDIT
OnMessage(0x0134, OD_OnCtlColorList)   ; WM_CTLCOLORLISTBOX
OnMessage(0x0138, OD_OnCtlColorStatic) ; WM_CTLCOLORSTATIC

; ============================================================
; Build GUI
; ============================================================

myGui := Gui("+Resize +MinSize600x580", "Owner-Draw Dark Controls")
myGui.SetFont("s10", "Segoe UI")
myGui.BackColor := S_L_BG

; -- Toggle button (owner-draw) --
toggleBtn := myGui.AddButton("x20 y15 w180 h30", "Switch to Dark Mode")
toggleBtn.OnEvent("Click", ToggleTheme)
OD_MakeButton(toggleBtn, "Switch to Dark Mode")

myGui.AddText("x210 y22 w300 vModeLabel", "Current: Light Mode")

; -- GroupBox: Text Inputs --
myGui.AddGroupBox("x20 y55 w270 h120 vGroup1", "Text Inputs")
myGui.AddText("x35 y80 w80 vLabel1", "Name:")
myGui.AddEdit("x120 y77 w155 vNameEdit", "Select me!")
myGui.AddText("x35 y110 w80 vLabel2", "Email:")
myGui.AddEdit("x120 y107 w155 vEmailEdit", "user@example.com")
myGui.AddText("x35 y140 w80 vLabel3", "Number:")
myGui.AddEdit("x120 y137 w80 vNumEdit +Number", "42")
myGui.AddUpDown("vNumUpDown Range0-100", 42)

; -- GroupBox: Selection Controls --
myGui.AddGroupBox("x310 y55 w270 h120 vGroup2", "Selection Controls")

; DDL - owner-draw for custom highlight colors
ddl := myGui.AddDropDownList("x325 y80 w240 vDDL", gDDLItems)
ddl.Value := 1
OD_MakeDDL(ddl)

; Checkbox - owner-draw for custom check fill
cb1 := myGui.AddCheckbox("x325 y115 w120 vCB1", "Dark Mode")
cb2 := myGui.AddCheckbox("x455 y115 w120 vCB2 Checked", "Auto-save")
OD_MakeCheckbox(cb1, "Dark Mode", false)
OD_MakeCheckbox(cb2, "Auto-save", true)

; Radio - owner-draw for custom radio fill
rad1 := myGui.AddRadio("x325 y140 w120 vRad1 Checked", "Choice A")
rad2 := myGui.AddRadio("x455 y140 w120 vRad2", "Choice B")
OD_MakeRadio(rad1, "Choice A", true)
OD_MakeRadio(rad2, "Choice B", false)
gRadioGroup := [rad1.Hwnd, rad2.Hwnd]

; -- ListView --
myGui.AddText("x20 y185 w100 vLVLabel", "ListView:")
lv := myGui.AddListView("x20 y205 w560 h120 vLV", ["Name", "Type", "Status", "Value"])
lv.Add("", "Window Title", "String", "Active", "Hello World")
lv.Add("", "Opacity", "Integer", "Set", "255")
lv.Add("", "Background", "Color", "Applied", "0x1E1E1E")
lv.Add("", "Font Size", "Float", "Default", "10.0")
lv.Add("", "Accent", "Color", "Custom", "0x0078D4")
lv.ModifyCol(1, 160), lv.ModifyCol(2, 100), lv.ModifyCol(3, 100), lv.ModifyCol(4, 180)

; -- Tab Control (owner-draw for text color) --
myGui.AddText("x20 y335 w100 vTabLabel", "Tab Control:")
tab := myGui.AddTab3("x20 y355 w560 h100 vTabCtrl", gTabNames)
OD_MakeTab(tab)

tab.UseTab("General")
myGui.AddText("x35 y385 w200 vTabText1", "General settings would go here.")
myGui.AddEdit("x35 y405 w250 vTabEdit1", "Tab content edit")
tab.UseTab("Advanced")
myGui.AddText("x35 y385 w200 vTabText2", "Advanced settings panel.")
tab.UseTab("About")
myGui.AddText("x35 y385 w300 vTabText3", "Dark mode control demo for AHK v2.")
tab.UseTab()

; -- Slider (NM_CUSTOMDRAW for gutter + handle) --
myGui.AddText("x20 y465 w80 vSliderLabel", "Slider:")
slider := myGui.AddSlider("x100 y465 w200 h30 vSlider Range0-100 ToolTip", 50)
gSliderHwnd := slider.Hwnd

; -- Progress (direct color messages) --
myGui.AddText("x320 y465 w80 vProgLabel", "Progress:")
prog := myGui.AddProgress("x400 y468 w180 h20 vProgress", 65)

; -- Status Bar --
sb := myGui.AddStatusBar("vSB")
sb.SetText(" Ready - Light Mode")

; -- Hover tracking timer --
SetTimer(OD_CheckHover, 30)

myGui.OnEvent("Close", (*) => ExitApp())
myGui.Show("w600 h540")

; ============================================================
; Toggle Theme
; ============================================================

ToggleTheme(*) {
    global gIsDark, myGui

    gIsDark := !gIsDark

    ; Update SetPreferredAppMode
    DllCall(_UxOrd(135), "Int", gIsDark ? 2 : 3, "Int")  ; ForceDark / ForceLight
    DllCall(_UxOrd(136))  ; FlushMenuThemes

    if (gIsDark) {
        myGui.BackColor := S_D_BG
        myGui.SetFont("c" S_D_TEXT)
        myGui.Title := "Owner-Draw Dark Controls [DARK]"
        myGui["ModeLabel"].Text := "Current: Dark Mode"
        gODMap[toggleBtn.Hwnd].text := "Switch to Light Mode"
        sb.SetText(" Ready - Dark Mode")
    } else {
        myGui.BackColor := S_L_BG
        myGui.SetFont("c" S_L_TEXT)
        myGui.Title := "Owner-Draw Dark Controls [LIGHT]"
        myGui["ModeLabel"].Text := "Current: Light Mode"
        gODMap[toggleBtn.Hwnd].text := "Switch to Dark Mode"
        sb.SetText(" Ready - Light Mode")
    }

    ; Dark title bar + AllowDarkModeForWindow
    SetDarkTitleBar(myGui.Hwnd, gIsDark)
    DllCall(_UxOrd(133), "Ptr", myGui.Hwnd, "Int", gIsDark)

    ; Edit controls - theme is sufficient
    for vName in ["NameEdit", "EmailEdit", "NumEdit", "TabEdit1"]
        ApplyTheme(myGui[vName].Hwnd, gIsDark, "DarkMode_CFD")

    ; UpDown - theme only
    ApplyTheme(myGui["NumUpDown"].Hwnd, gIsDark, "DarkMode_Explorer")

    ; ListView items
    ApplyTheme(myGui["LV"].Hwnd, gIsDark, "DarkMode_Explorer")
    if (gIsDark) {
        myGui["LV"].Opt("+Background" S_D_CTRL)
        SendMessage(0x1024, CLR_D_TEXT, 0, myGui["LV"].Hwnd)   ; LVM_SETTEXTCOLOR
        SendMessage(0x1026, 0, CLR_D_CTRL, myGui["LV"].Hwnd)   ; LVM_SETTEXTBKCOLOR
        SendMessage(0x1001, 0, CLR_D_CTRL, myGui["LV"].Hwnd)   ; LVM_SETBKCOLOR
    } else {
        myGui["LV"].Opt("+BackgroundDefault")
        SendMessage(0x1024, CLR_L_TEXT, 0, myGui["LV"].Hwnd)
        SendMessage(0x1026, 0, CLR_L_CTRL, myGui["LV"].Hwnd)
        SendMessage(0x1001, 0, CLR_L_CTRL, myGui["LV"].Hwnd)
    }

    ; ListView header - AllowDarkModeForWindow + theme + WM_THEMECHANGED
    hHeader := SendMessage(0x101F, 0, 0, myGui["LV"].Hwnd)
    if (hHeader) {
        DllCall(_UxOrd(133), "Ptr", hHeader, "Int", gIsDark)
        ApplyTheme(hHeader, gIsDark, "DarkMode_Explorer")
        SendMessage(0x031A, 0, 0, hHeader)  ; WM_THEMECHANGED
    }

    ; Progress bar - direct color messages
    SendMessage(0x2001, 0, gIsDark ? CLR_D_CTRL : CLR_L_CTRL2, myGui["Progress"].Hwnd)  ; PBM_SETBKCOLOR
    SendMessage(0x0409, 0, CLR_ACCENT, myGui["Progress"].Hwnd)                           ; PBM_SETBARCOLOR

    ; StatusBar
    ApplyTheme(myGui["SB"].Hwnd, gIsDark, "DarkMode_Explorer")
    SendMessage(0x2001, 0, gIsDark ? CLR_D_CTRL : CLR_L_BG, myGui["SB"].Hwnd)  ; SB_SETBKCOLOR

    ; Slider - theme for base, NM_CUSTOMDRAW handles the rest
    ApplyTheme(gSliderHwnd, gIsDark, "DarkMode_Explorer")

    ; Invalidate all owner-draw controls
    for hwnd, _ in gODMap
        DllCall("InvalidateRect", "Ptr", hwnd, "Ptr", 0, "Int", 1)

    ; Force full redraw
    DllCall("InvalidateRect", "Ptr", myGui.Hwnd, "Ptr", 0, "Int", 1)
    DllCall("UpdateWindow", "Ptr", myGui.Hwnd)
    ForceRedrawTitleBar(myGui.Hwnd)
}

; ============================================================
; WM_DRAWITEM Handler (0x002B)
; ============================================================
; Dispatches by CtlType: ODT_COMBOBOX=3, ODT_BUTTON=4, ODT_TAB=101
;
; DRAWITEMSTRUCT (x64):
;   0:  CtlType(4)  4: CtlID(4)  8: itemID(4)  12: itemAction(4)
;   16: itemState(4)  20: pad(4)  24: hwndItem(8)  32: hDC(8)
;   40: rcItem(16: left,top,right,bottom)  56: itemData(8)

OD_OnDrawItem(wParam, lParam, msg, hwnd) {
    ctlType := NumGet(lParam, 0, "UInt")
    switch ctlType {
        case 3:   return OD_DrawDDL(lParam)    ; ODT_COMBOBOX
        case 4:   return OD_DrawBtn(lParam)    ; ODT_BUTTON
        case 101: return OD_DrawTab(lParam)    ; ODT_TAB
    }
    return 0
}

; -- DDL Item Drawing --
OD_DrawDDL(lParam) {
    global gIsDark, gDDLItems, gODMap
    itemID    := NumGet(lParam, 8, "UInt")
    itemState := NumGet(lParam, 16, "UInt")
    btnHwnd   := NumGet(lParam, 24, "Ptr")
    hdc       := NumGet(lParam, 32, "Ptr")
    left := NumGet(lParam, 40, "Int"), top := NumGet(lParam, 44, "Int")
    right := NumGet(lParam, 48, "Int"), bottom := NumGet(lParam, 52, "Int")

    if (!gODMap.Has(btnHwnd))
        return 0

    ; itemID = 0xFFFFFFFF means empty
    if (itemID = 0xFFFFFFFF) {
        brush := DllCall("CreateSolidBrush", "UInt", gIsDark ? CLR_D_CTRL : CLR_L_CTRL, "Ptr")
        rc := Buffer(16)
        NumPut("Int", left, "Int", top, "Int", right, "Int", bottom, rc)
        DllCall("FillRect", "Ptr", hdc, "Ptr", rc, "Ptr", brush)
        DllCall("DeleteObject", "Ptr", brush)
        return 1
    }

    isSelected := (itemState & 0x0001)  ; ODS_SELECTED
    itemText := (itemID < gDDLItems.Length) ? gDDLItems[itemID + 1] : ""

    ; Colors: selected = blue accent, normal = control bg
    if (isSelected) {
        bgColor := CLR_ACCENT
        txColor := CLR_WHITE
    } else {
        bgColor := gIsDark ? CLR_D_CTRL : CLR_L_CTRL
        txColor := gIsDark ? CLR_D_TEXT : CLR_L_TEXT
    }

    ; Fill background
    brush := DllCall("CreateSolidBrush", "UInt", bgColor, "Ptr")
    rc := Buffer(16)
    NumPut("Int", left, "Int", top, "Int", right, "Int", bottom, rc)
    DllCall("FillRect", "Ptr", hdc, "Ptr", rc, "Ptr", brush)
    DllCall("DeleteObject", "Ptr", brush)

    ; Draw text
    DllCall("SetTextColor", "Ptr", hdc, "UInt", txColor)
    DllCall("SetBkMode", "Ptr", hdc, "Int", 1)  ; TRANSPARENT
    textRc := Buffer(16)
    NumPut("Int", left + 4, "Int", top, "Int", right - 4, "Int", bottom, textRc)
    DllCall("DrawText", "Ptr", hdc, "Str", itemText, "Int", -1,
        "Ptr", textRc, "UInt", 0x24)  ; DT_LEFT | DT_VCENTER | DT_SINGLELINE
    return 1
}

; -- Button / Checkbox / Radio Drawing --
OD_DrawBtn(lParam) {
    global gIsDark, gODMap, gCheckState, gRadioState, gHoverHwnd
    itemState := NumGet(lParam, 16, "UInt")
    btnHwnd   := NumGet(lParam, 24, "Ptr")
    hdc       := NumGet(lParam, 32, "Ptr")
    left := NumGet(lParam, 40, "Int"), top := NumGet(lParam, 44, "Int")
    right := NumGet(lParam, 48, "Int"), bottom := NumGet(lParam, 52, "Int")

    if (!gODMap.Has(btnHwnd))
        return 0

    info := gODMap[btnHwnd]
    isPressed := (itemState & 0x0001)
    isFocused := (itemState & 0x0010)
    isHover   := (gHoverHwnd = btnHwnd)

    switch info.type {
        case "checkbox": return OD_PaintCheckbox(hdc, left, top, right, bottom, btnHwnd, info, isHover, isFocused)
        case "radio":    return OD_PaintRadio(hdc, left, top, right, bottom, btnHwnd, info, isHover, isFocused)
        case "button":   return OD_PaintButton(hdc, left, top, right, bottom, btnHwnd, info, isPressed, isHover, isFocused)
    }
    return 0
}

OD_PaintButton(hdc, left, top, right, bottom, btnHwnd, info, isPressed, isHover, isFocused) {
    global gIsDark
    if (isPressed) {
        bg := CLR_ACCENT_DK, tx := CLR_WHITE, bd := CLR_ACCENT_DK
    } else if (isHover) {
        bg := CLR_ACCENT, tx := CLR_WHITE, bd := CLR_ACCENT
    } else {
        bg := gIsDark ? CLR_D_CTRL2 : CLR_L_CTRL2
        tx := gIsDark ? CLR_D_TEXT : CLR_L_TEXT
        bd := gIsDark ? CLR_D_BORDER : CLR_L_BORDER
    }
    pen := DllCall("CreatePen", "Int", 0, "Int", 1, "UInt", bd, "Ptr")
    brush := DllCall("CreateSolidBrush", "UInt", bg, "Ptr")
    old1 := DllCall("SelectObject", "Ptr", hdc, "Ptr", pen, "Ptr")
    old2 := DllCall("SelectObject", "Ptr", hdc, "Ptr", brush, "Ptr")
    DllCall("RoundRect", "Ptr", hdc, "Int", left, "Int", top, "Int", right, "Int", bottom, "Int", 4, "Int", 4)
    DllCall("SelectObject", "Ptr", hdc, "Ptr", old1, "Ptr")
    DllCall("SelectObject", "Ptr", hdc, "Ptr", old2, "Ptr")
    DllCall("DeleteObject", "Ptr", pen), DllCall("DeleteObject", "Ptr", brush)

    hFont := SendMessage(0x0031, 0, 0, btnHwnd)
    if (hFont) DllCall("SelectObject", "Ptr", hdc, "Ptr", hFont, "Ptr")
    DllCall("SetTextColor", "Ptr", hdc, "UInt", tx)
    DllCall("SetBkMode", "Ptr", hdc, "Int", 1)
    rc := Buffer(16)
    NumPut("Int", left, "Int", top, "Int", right, "Int", bottom, rc)
    DllCall("DrawText", "Ptr", hdc, "Str", info.text, "Int", -1, "Ptr", rc, "UInt", 0x25)
    return 1
}

OD_PaintCheckbox(hdc, left, top, right, bottom, btnHwnd, info, isHover, isFocused) {
    global gIsDark, gCheckState
    checked := gCheckState.Get(btnHwnd, false)
    boxSize := 16
    boxY := top + ((bottom - top - boxSize) // 2)
    boxL := left + 2, boxR := boxL + boxSize, boxT := boxY, boxB := boxY + boxSize

    ; Box border + fill
    if (checked) {
        boxBg := CLR_ACCENT
        boxBd := CLR_ACCENT
    } else {
        boxBg := gIsDark ? CLR_D_CTRL2 : CLR_L_CTRL
        boxBd := gIsDark ? CLR_D_BORDER : CLR_L_BORDER
    }

    ; Clear entire area first (prevent artifacts)
    clearBrush := DllCall("CreateSolidBrush", "UInt", gIsDark ? CLR_D_BG : CLR_L_BG, "Ptr")
    clearRc := Buffer(16)
    NumPut("Int", left, "Int", top, "Int", right, "Int", bottom, clearRc)
    DllCall("FillRect", "Ptr", hdc, "Ptr", clearRc, "Ptr", clearBrush)
    DllCall("DeleteObject", "Ptr", clearBrush)

    pen := DllCall("CreatePen", "Int", 0, "Int", 1, "UInt", boxBd, "Ptr")
    brush := DllCall("CreateSolidBrush", "UInt", boxBg, "Ptr")
    old1 := DllCall("SelectObject", "Ptr", hdc, "Ptr", pen, "Ptr")
    old2 := DllCall("SelectObject", "Ptr", hdc, "Ptr", brush, "Ptr")
    DllCall("RoundRect", "Ptr", hdc, "Int", boxL, "Int", boxT, "Int", boxR, "Int", boxB, "Int", 3, "Int", 3)
    DllCall("SelectObject", "Ptr", hdc, "Ptr", old1, "Ptr")
    DllCall("SelectObject", "Ptr", hdc, "Ptr", old2, "Ptr")
    DllCall("DeleteObject", "Ptr", pen), DllCall("DeleteObject", "Ptr", brush)

    ; Check mark (white lines on blue)
    if (checked) {
        checkPen := DllCall("CreatePen", "Int", 0, "Int", 2, "UInt", CLR_WHITE, "Ptr")
        old3 := DllCall("SelectObject", "Ptr", hdc, "Ptr", checkPen, "Ptr")
        cx := boxL + 3, cy := boxT + boxSize // 2
        DllCall("MoveToEx", "Ptr", hdc, "Int", cx, "Int", cy, "Ptr", 0)
        DllCall("LineTo", "Ptr", hdc, "Int", cx + 3, "Int", cy + 3)
        DllCall("LineTo", "Ptr", hdc, "Int", cx + 9, "Int", cy - 3)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", old3, "Ptr")
        DllCall("DeleteObject", "Ptr", checkPen)
    }

    ; Label text
    hFont := SendMessage(0x0031, 0, 0, btnHwnd)
    if (hFont) DllCall("SelectObject", "Ptr", hdc, "Ptr", hFont, "Ptr")
    DllCall("SetTextColor", "Ptr", hdc, "UInt", gIsDark ? CLR_D_TEXT : CLR_L_TEXT)
    DllCall("SetBkMode", "Ptr", hdc, "Int", 1)
    textRc := Buffer(16)
    NumPut("Int", boxR + 6, "Int", top, "Int", right, "Int", bottom, textRc)
    DllCall("DrawText", "Ptr", hdc, "Str", info.text, "Int", -1, "Ptr", textRc, "UInt", 0x24)

    ; Focus rect
    if (isFocused) {
        focRc := Buffer(16)
        NumPut("Int", boxR + 4, "Int", top + 2, "Int", right - 2, "Int", bottom - 2, focRc)
        DllCall("DrawFocusRect", "Ptr", hdc, "Ptr", focRc)
    }
    return 1
}

OD_PaintRadio(hdc, left, top, right, bottom, btnHwnd, info, isHover, isFocused) {
    global gIsDark, gRadioState
    selected := gRadioState.Get(btnHwnd, false)
    circSize := 16
    circY := top + ((bottom - top - circSize) // 2)
    circL := left + 2, circR := circL + circSize, circT := circY, circB := circY + circSize

    ; Clear area
    clearBrush := DllCall("CreateSolidBrush", "UInt", gIsDark ? CLR_D_BG : CLR_L_BG, "Ptr")
    clearRc := Buffer(16)
    NumPut("Int", left, "Int", top, "Int", right, "Int", bottom, clearRc)
    DllCall("FillRect", "Ptr", hdc, "Ptr", clearRc, "Ptr", clearBrush)
    DllCall("DeleteObject", "Ptr", clearBrush)

    ; Outer circle
    bd := selected ? CLR_ACCENT : (gIsDark ? CLR_D_BORDER : CLR_L_BORDER)
    bg := selected ? CLR_ACCENT : (gIsDark ? CLR_D_CTRL2 : CLR_L_CTRL)
    pen := DllCall("CreatePen", "Int", 0, "Int", 1, "UInt", bd, "Ptr")
    brush := DllCall("CreateSolidBrush", "UInt", bg, "Ptr")
    old1 := DllCall("SelectObject", "Ptr", hdc, "Ptr", pen, "Ptr")
    old2 := DllCall("SelectObject", "Ptr", hdc, "Ptr", brush, "Ptr")
    DllCall("Ellipse", "Ptr", hdc, "Int", circL, "Int", circT, "Int", circR, "Int", circB)
    DllCall("SelectObject", "Ptr", hdc, "Ptr", old1, "Ptr")
    DllCall("SelectObject", "Ptr", hdc, "Ptr", old2, "Ptr")
    DllCall("DeleteObject", "Ptr", pen), DllCall("DeleteObject", "Ptr", brush)

    ; Inner dot (white on blue)
    if (selected) {
        m := 4
        dotPen := DllCall("CreatePen", "Int", 0, "Int", 1, "UInt", CLR_WHITE, "Ptr")
        dotBrush := DllCall("CreateSolidBrush", "UInt", CLR_WHITE, "Ptr")
        old3 := DllCall("SelectObject", "Ptr", hdc, "Ptr", dotPen, "Ptr")
        old4 := DllCall("SelectObject", "Ptr", hdc, "Ptr", dotBrush, "Ptr")
        DllCall("Ellipse", "Ptr", hdc, "Int", circL+m, "Int", circT+m, "Int", circR-m, "Int", circB-m)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", old3, "Ptr")
        DllCall("SelectObject", "Ptr", hdc, "Ptr", old4, "Ptr")
        DllCall("DeleteObject", "Ptr", dotPen), DllCall("DeleteObject", "Ptr", dotBrush)
    }

    ; Label text
    hFont := SendMessage(0x0031, 0, 0, btnHwnd)
    if (hFont) DllCall("SelectObject", "Ptr", hdc, "Ptr", hFont, "Ptr")
    DllCall("SetTextColor", "Ptr", hdc, "UInt", gIsDark ? CLR_D_TEXT : CLR_L_TEXT)
    DllCall("SetBkMode", "Ptr", hdc, "Int", 1)
    textRc := Buffer(16)
    NumPut("Int", circR + 6, "Int", top, "Int", right, "Int", bottom, textRc)
    DllCall("DrawText", "Ptr", hdc, "Str", info.text, "Int", -1, "Ptr", textRc, "UInt", 0x24)
    return 1
}

; -- Tab Header Drawing --
OD_DrawTab(lParam) {
    global gIsDark, gTabNames
    itemID    := NumGet(lParam, 8, "UInt")
    itemState := NumGet(lParam, 16, "UInt")
    tabHwnd   := NumGet(lParam, 24, "Ptr")
    hdc       := NumGet(lParam, 32, "Ptr")
    left := NumGet(lParam, 40, "Int"), top := NumGet(lParam, 44, "Int")
    right := NumGet(lParam, 48, "Int"), bottom := NumGet(lParam, 52, "Int")

    isSelected := (itemState & 0x0001)
    tabText := (itemID < gTabNames.Length) ? gTabNames[itemID + 1] : ""

    ; Selected tab = window bg, unselected = slightly different
    if (isSelected) {
        bg := gIsDark ? CLR_D_BG : CLR_L_BG
    } else {
        bg := gIsDark ? CLR_D_CTRL : CLR_L_CTRL2
    }
    tx := gIsDark ? CLR_D_TEXT : CLR_L_TEXT

    brush := DllCall("CreateSolidBrush", "UInt", bg, "Ptr")
    rc := Buffer(16)
    NumPut("Int", left, "Int", top, "Int", right, "Int", bottom, rc)
    DllCall("FillRect", "Ptr", hdc, "Ptr", rc, "Ptr", brush)
    DllCall("DeleteObject", "Ptr", brush)

    hFont := SendMessage(0x0031, 0, 0, tabHwnd)
    if (hFont) DllCall("SelectObject", "Ptr", hdc, "Ptr", hFont, "Ptr")
    DllCall("SetTextColor", "Ptr", hdc, "UInt", tx)
    DllCall("SetBkMode", "Ptr", hdc, "Int", 1)
    DllCall("DrawText", "Ptr", hdc, "Str", tabText, "Int", -1,
        "Ptr", rc, "UInt", 0x25)  ; DT_CENTER | DT_VCENTER | DT_SINGLELINE
    return 1
}

; ============================================================
; WM_NOTIFY Handler - NM_CUSTOMDRAW for Slider
; ============================================================
; NMCUSTOMDRAW (x64):
;   0: hwndFrom(8)  8: idFrom(8)  16: code(4)  20: pad(4)
;   24: dwDrawStage(4)  28: pad(4)  32: hdc(8)
;   40: rc(16)  56: dwItemSpec(8)  64: uItemState(4)

OD_OnNotify(wParam, lParam, msg, hwnd) {
    global gSliderHwnd, gIsDark
    code := NumGet(lParam, 16, "Int")
    if (code != -12)  ; NM_CUSTOMDRAW
        return

    hwndFrom := NumGet(lParam, 0, "Ptr")
    if (hwndFrom != gSliderHwnd)
        return

    stage := NumGet(lParam, 24, "UInt")

    ; CDDS_PREPAINT = 1 -> ask for per-item notifications
    if (stage = 0x01)
        return 0x20  ; CDRF_NOTIFYITEMDRAW

    ; CDDS_ITEMPREPAINT = 0x10001
    if (stage != 0x10001)
        return 0

    hdc  := NumGet(lParam, 32, "Ptr")
    left := NumGet(lParam, 40, "Int"), top := NumGet(lParam, 44, "Int")
    right := NumGet(lParam, 48, "Int"), bottom := NumGet(lParam, 52, "Int")
    part := NumGet(lParam, 56, "UPtr")  ; TBCD_CHANNEL=3, TBCD_THUMB=2, TBCD_TICS=1

    if (part = 3) {  ; TBCD_CHANNEL (gutter)
        ; Two-tone: filled portion (accent) + empty portion (gutter)
        pos := SendMessage(0x0400, 0, 0, gSliderHwnd)       ; TBM_GETPOS
        rangeMin := SendMessage(0x0401, 0, 0, gSliderHwnd)  ; TBM_GETRANGEMIN
        rangeMax := SendMessage(0x0402, 0, 0, gSliderHwnd)  ; TBM_GETRANGEMAX
        channelW := right - left
        fillW := (rangeMax > rangeMin) ? Round((pos - rangeMin) / (rangeMax - rangeMin) * channelW) : 0

        ; Filled (accent)
        if (fillW > 0) {
            fb := DllCall("CreateSolidBrush", "UInt", CLR_ACCENT, "Ptr")
            frc := Buffer(16)
            NumPut("Int", left, "Int", top, "Int", left + fillW, "Int", bottom, frc)
            DllCall("FillRect", "Ptr", hdc, "Ptr", frc, "Ptr", fb)
            DllCall("DeleteObject", "Ptr", fb)
        }
        ; Empty (gutter)
        if (left + fillW < right) {
            eb := DllCall("CreateSolidBrush", "UInt", gIsDark ? CLR_D_GUTTER : CLR_L_GUTTER, "Ptr")
            erc := Buffer(16)
            NumPut("Int", left + fillW, "Int", top, "Int", right, "Int", bottom, erc)
            DllCall("FillRect", "Ptr", hdc, "Ptr", erc, "Ptr", eb)
            DllCall("DeleteObject", "Ptr", eb)
        }
        return 0x04  ; CDRF_SKIPDEFAULT
    }

    if (part = 2) {  ; TBCD_THUMB (handle)
        thumbBrush := DllCall("CreateSolidBrush", "UInt", CLR_ACCENT, "Ptr")
        thumbPen := DllCall("CreatePen", "Int", 0, "Int", 1, "UInt", CLR_ACCENT, "Ptr")
        old1 := DllCall("SelectObject", "Ptr", hdc, "Ptr", thumbPen, "Ptr")
        old2 := DllCall("SelectObject", "Ptr", hdc, "Ptr", thumbBrush, "Ptr")
        DllCall("Ellipse", "Ptr", hdc, "Int", left, "Int", top, "Int", right, "Int", bottom)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", old1, "Ptr")
        DllCall("SelectObject", "Ptr", hdc, "Ptr", old2, "Ptr")
        DllCall("DeleteObject", "Ptr", thumbPen), DllCall("DeleteObject", "Ptr", thumbBrush)
        return 0x04  ; CDRF_SKIPDEFAULT
    }

    return 0  ; CDRF_DODEFAULT for tics etc.
}

; ============================================================
; WM_CTLCOLOR Handlers
; ============================================================

OD_OnCtlColorEdit(wParam, lParam, msg, hwnd) {
    global gIsDark
    if (!gIsDark) return 0
    DllCall("SetTextColor", "Ptr", wParam, "UInt", CLR_D_TEXT)
    DllCall("SetBkColor", "Ptr", wParam, "UInt", CLR_D_CTRL)
    return gBrushDarkCtrl
}

OD_OnCtlColorList(wParam, lParam, msg, hwnd) {
    global gIsDark
    if (!gIsDark) return 0
    DllCall("SetTextColor", "Ptr", wParam, "UInt", CLR_D_TEXT)
    DllCall("SetBkColor", "Ptr", wParam, "UInt", CLR_D_CTRL)
    return gBrushDarkCtrl
}

OD_OnCtlColorStatic(wParam, lParam, msg, hwnd) {
    global gIsDark
    if (!gIsDark) return 0
    DllCall("SetTextColor", "Ptr", wParam, "UInt", CLR_D_TEXT)
    DllCall("SetBkColor", "Ptr", wParam, "UInt", CLR_D_BG)
    return gBrushDarkBg
}

; ============================================================
; Owner-Draw Setup Helpers
; ============================================================

OD_MakeButton(ctrl, text) {
    global gODMap
    style := DllCall("GetWindowLong", "Ptr", ctrl.Hwnd, "Int", -16, "Int")
    DllCall("SetWindowLong", "Ptr", ctrl.Hwnd, "Int", -16, "Int", (style & ~0xF) | 0xB)
    gODMap[ctrl.Hwnd] := {type: "button", text: text}
}

OD_MakeCheckbox(ctrl, text, checked) {
    global gODMap, gCheckState
    style := DllCall("GetWindowLong", "Ptr", ctrl.Hwnd, "Int", -16, "Int")
    DllCall("SetWindowLong", "Ptr", ctrl.Hwnd, "Int", -16, "Int", (style & ~0xF) | 0xB)
    gODMap[ctrl.Hwnd] := {type: "checkbox", text: text}
    gCheckState[ctrl.Hwnd] := checked
    ctrl.OnEvent("Click", OD_ToggleCheck)
}

OD_MakeRadio(ctrl, text, selected) {
    global gODMap, gRadioState
    style := DllCall("GetWindowLong", "Ptr", ctrl.Hwnd, "Int", -16, "Int")
    DllCall("SetWindowLong", "Ptr", ctrl.Hwnd, "Int", -16, "Int", (style & ~0xF) | 0xB)
    gODMap[ctrl.Hwnd] := {type: "radio", text: text}
    gRadioState[ctrl.Hwnd] := selected
    ctrl.OnEvent("Click", OD_SelectRadio)
}

OD_MakeDDL(ctrl) {
    global gODMap
    style := DllCall("GetWindowLong", "Ptr", ctrl.Hwnd, "Int", -16, "Int")
    DllCall("SetWindowLong", "Ptr", ctrl.Hwnd, "Int", -16, "Int", style | 0x0010 | 0x0200)
    ; CBS_OWNERDRAWFIXED=0x0010, CBS_HASSTRINGS=0x0200
    SendMessage(0x0153, 0, 24, ctrl.Hwnd)    ; CB_SETITEMHEIGHT list items
    SendMessage(0x0153, -1, 24, ctrl.Hwnd)   ; CB_SETITEMHEIGHT selection
    gODMap[ctrl.Hwnd] := {type: "ddl"}
}

OD_MakeTab(ctrl) {
    global gODMap
    style := DllCall("GetWindowLong", "Ptr", ctrl.Hwnd, "Int", -16, "Int")
    DllCall("SetWindowLong", "Ptr", ctrl.Hwnd, "Int", -16, "Int", style | 0x2000)
    ; TCS_OWNERDRAWFIXED=0x2000
    gODMap[ctrl.Hwnd] := {type: "tab"}
}

; ============================================================
; Interaction Handlers
; ============================================================

OD_ToggleCheck(ctrl, *) {
    global gCheckState
    gCheckState[ctrl.Hwnd] := !gCheckState.Get(ctrl.Hwnd, false)
    DllCall("InvalidateRect", "Ptr", ctrl.Hwnd, "Ptr", 0, "Int", 1)
}

OD_SelectRadio(ctrl, *) {
    global gRadioState, gRadioGroup
    for _, hwnd in gRadioGroup
        gRadioState[hwnd] := false
    gRadioState[ctrl.Hwnd] := true
    for _, hwnd in gRadioGroup
        DllCall("InvalidateRect", "Ptr", hwnd, "Ptr", 0, "Int", 1)
}

; ============================================================
; Hover Tracking
; ============================================================

OD_CheckHover() {
    global gODMap, gHoverHwnd
    pt := Buffer(8, 0)
    DllCall("GetCursorPos", "Ptr", pt)
    hwndUnder := DllCall("WindowFromPoint", "Int64", NumGet(pt, 0, "Int64"), "Ptr")

    newHover := 0
    if (gODMap.Has(hwndUnder))
        newHover := hwndUnder

    if (newHover != gHoverHwnd) {
        oldHover := gHoverHwnd
        gHoverHwnd := newHover
        if (oldHover && gODMap.Has(oldHover))
            DllCall("InvalidateRect", "Ptr", oldHover, "Ptr", 0, "Int", 1)
        if (newHover)
            DllCall("InvalidateRect", "Ptr", newHover, "Ptr", 0, "Int", 1)
    }
}

; ============================================================
; Helpers
; ============================================================

SetDarkTitleBar(hwnd, enable) {
    value := Buffer(4, 0)
    NumPut("Int", enable ? 1 : 0, value)
    DllCall("dwmapi\DwmSetWindowAttribute",
        "Ptr", hwnd, "Int", 20, "Ptr", value, "Int", 4, "Int")
}

ApplyTheme(hwnd, enable, themeName) {
    if (enable)
        DllCall("uxtheme\SetWindowTheme", "Ptr", hwnd, "Str", themeName, "Ptr", 0)
    else
        DllCall("uxtheme\SetWindowTheme", "Ptr", hwnd, "Ptr", 0, "Ptr", 0)
    SendMessage(0x031A, 0, 0, hwnd)  ; WM_THEMECHANGED
}

ForceRedrawTitleBar(hwnd) {
    style := DllCall("GetWindowLong", "Ptr", hwnd, "Int", -16, "Int")
    DllCall("SetWindowLong", "Ptr", hwnd, "Int", -16, "Int", style & ~0x40000)
    DllCall("SetWindowLong", "Ptr", hwnd, "Int", -16, "Int", style)
    DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", 0,
        "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x27)
}
