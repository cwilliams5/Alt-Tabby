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
; Control     | Technique                    | Proves Control Of
; -------------------------------------------------------
; Button      | BS_OWNERDRAW + WM_DRAWITEM   | Hover/pressed bg color
; Checkbox    | BS_OWNERDRAW + WM_DRAWITEM   | Check fill color (RED proof)
; Radio       | BS_OWNERDRAW + WM_DRAWITEM   | Radio fill color (RED proof)
; DDL items   | CBS_OWNERDRAWFIXED+DRAWITEM  | Highlight=RED, item colors
; Tab headers | TCS_OWNERDRAWFIXED+DRAWITEM  | Tab text/bg color
; Slider      | NM_CUSTOMDRAW via WM_NOTIFY  | Channel=YELLOW, thumb=RED
; Progress    | SetWindowTheme("")+PBM msgs  | Bar=blue, gutter=custom
; StatusBar   | DarkMode_Explorer+AllowDark  | Bg + text via theme
; ListView    | NM_CUSTOMDRAW (SKIPDEFAULT)  | Selection=GREEN, hover=YELLOW
; LV Header   | NM_CUSTOMDRAW via subclass   | Hover=LIGHT RED, sort arrows
; Edit        | DarkMode_CFD + WM_CTLCOLOR   | Theme handles well
; -------------------------------------------------------
; CANNOT CONTROL per-control (Win32 limitation):
;   - Edit selection highlight (system COLOR_HIGHLIGHT)
;   - UpDown button hover colors (no NM_CUSTOMDRAW support)
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
global CLR_RED         := 0x0000FF    ; Pure red (BGR) - proves slider thumb control
global CLR_RED_LITE    := 0x8080FF    ; Light red (BGR) - header hover proof
global CLR_YELLOW      := 0x00FFFF    ; Yellow (BGR) - proves slider fill control
global CLR_GREEN       := 0x00FF00    ; Green (BGR) - proves ListView selected+focused control
global CLR_MAGENTA     := 0xFF00FF    ; Magenta (BGR) - proves ListView selected+unfocused control
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
global gLVHotRow := -1          ; Currently hovered ListView row (-1 = none)
global gHdrHotItem := -1        ; Currently hovered header item (-1 = none)
global gDDLItems := ["Option 1", "Option 2", "Option 3", "Option 4"]
global gTabNames := ["General", "Advanced", "About"]
global gLVColumns := ["Name", "Type", "Status", "Value"]
global gLVHwnd := 0
global gLVHeaderHwnd := 0
global gLVSubclassCB := 0       ; Callback pointer for ListView subclass
global gDpiScale := DllCall("GetDpiForSystem", "UInt") / 96.0
global gSortCol := -1              ; Currently sorted column (-1 = none)
global gSortAsc := true            ; Sort direction (true = ascending)
global gSBHwnd := 0                ; Status bar HWND (for owner-draw)
global gSBText := " Ready - Light Mode"  ; Status bar text (owner-drawn)
global gSBSubclassCB := 0          ; Callback pointer for StatusBar subclass

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
DllCall(_UxOrd(135), "Int", 3, "Int")   ; SetPreferredAppMode(ForceLight) - start light
DllCall(_UxOrd(136))                     ; FlushMenuThemes

; -- Register message handlers --
OnMessage(0x002B, OD_OnDrawItem)       ; WM_DRAWITEM
OnMessage(0x004E, OD_OnNotify)         ; WM_NOTIFY (NM_CUSTOMDRAW)
OnMessage(0x0133, OD_OnCtlColorEdit)   ; WM_CTLCOLOREDIT
OnMessage(0x0134, OD_OnCtlColorList)   ; WM_CTLCOLORLISTBOX
OnMessage(0x0135, OD_OnCtlColorBtn)    ; WM_CTLCOLORBTN (GroupBox text)
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
myGui.AddGroupBox("x310 y55 w270 h130 vGroup2", "Selection Controls")

; DDL - CBS_OWNERDRAWFIXED MUST be set at creation time (+0x0010)
; Setting via SetWindowLong after creation doesn't propagate to dropdown list window
ddl := myGui.AddDropDownList("x325 y80 w240 vDDL +0x0010", gDDLItems)
ddl.Value := 1
OD_MakeDDL(ddl)

; Checkbox - owner-draw for custom check fill
cb1 := myGui.AddCheckbox("x325 y115 w120 h24 vCB1", "Dark Mode")
cb2 := myGui.AddCheckbox("x455 y115 w120 h24 vCB2 Checked", "Auto-save")
OD_MakeCheckbox(cb1, "Dark Mode", false)
OD_MakeCheckbox(cb2, "Auto-save", true)

; Radio - owner-draw for custom radio fill
rad1 := myGui.AddRadio("x325 y145 w120 h24 vRad1 Checked", "Choice A")
rad2 := myGui.AddRadio("x455 y145 w120 h24 vRad2", "Choice B")
OD_MakeRadio(rad1, "Choice A", true)
OD_MakeRadio(rad2, "Choice B", false)
gRadioGroup := [rad1.Hwnd, rad2.Hwnd]

; -- ListView --
myGui.AddText("x20 y185 w100 vLVLabel", "ListView:")
lv := myGui.AddListView("x20 y205 w560 h120 vLV", gLVColumns)
lv.Add("", "Window Title", "String", "Active", "Hello World")
lv.Add("", "Opacity", "Integer", "Set", "255")
lv.Add("", "Background", "Color", "Applied", "0x1E1E1E")
lv.Add("", "Font Size", "Float", "Default", "10.0")
lv.Add("", "Accent", "Color", "Custom", "0x0078D4")
lv.ModifyCol(1, 160), lv.ModifyCol(2, 100), lv.ModifyCol(3, 100), lv.ModifyCol(4, 180)
gLVHwnd := lv.Hwnd

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
; Disable visual styles so PBM_SETBARCOLOR/SETBKCOLOR work (no effect under visual styles)
DllCall("uxtheme\SetWindowTheme", "Ptr", prog.Hwnd, "Str", "", "Str", "")

; -- Status Bar --
sb := myGui.AddStatusBar("vSB -0x0100")  ; -SBARS_SIZEGRIP (can't theme the grip)
sb.SetText(" Ready - Light Mode")

; -- Hover tracking timer --
SetTimer(OD_CheckHover, 30)

myGui.OnEvent("Close", (*) => ExitApp())
myGui.Show("w600 h540")

; Apply initial state (progress colors, header subclass, etc.)
ApplyInitialState()

; ============================================================
; Initial State
; ============================================================

ApplyInitialState() {
    global myGui, prog, sb, gLVHwnd, gLVHeaderHwnd, gLVSubclassCB, gSBHwnd, gSBSubclassCB

    ; Enable full row select + double-buffer (reduces flicker during repaint)
    SendMessage(0x1036, 0x00010020, 0x00010020, gLVHwnd)  ; LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFERED

    ; LVS_SHOWSELALWAYS - show selection even when control loses focus
    style := DllCall("GetWindowLong", "Ptr", gLVHwnd, "Int", -16, "Int")
    DllCall("SetWindowLong", "Ptr", gLVHwnd, "Int", -16, "Int", style | 0x0008)

    ; Progress bar - set initial light mode colors (visual styles already disabled)
    DllCall("SendMessageW", "Ptr", prog.Hwnd, "UInt", 0x2001, "Ptr", 0, "Ptr", CLR_L_CTRL2)  ; PBM_SETBKCOLOR
    DllCall("SendMessageW", "Ptr", prog.Hwnd, "UInt", 0x0409, "Ptr", 0, "Ptr", CLR_ACCENT)    ; PBM_SETBARCOLOR

    ; Get ListView header HWND for NM_CUSTOMDRAW interception
    gLVHeaderHwnd := DllCall("SendMessageW", "Ptr", gLVHwnd, "UInt", 0x101F, "Ptr", 0, "Ptr", 0, "Ptr")

    ; Subclass ListView to intercept header's NM_CUSTOMDRAW
    ; Header sends WM_NOTIFY to its parent (ListView), which normally handles it internally.
    ; Subclassing lets us intercept and custom-paint header items (e.g., hover color).
    if (gLVHeaderHwnd) {
        gLVSubclassCB := CallbackCreate(OD_LVSubclass, , 6)
        DllCall("comctl32\SetWindowSubclass", "Ptr", gLVHwnd,
            "Ptr", gLVSubclassCB, "UPtr", 1, "Ptr", 0)
    }

    ; Status bar - strip visual styles so SB_SETBKCOLOR works, then owner-draw for text color
    gSBHwnd := sb.Hwnd
    DllCall("uxtheme\SetWindowTheme", "Ptr", gSBHwnd, "Str", "", "Str", "")
    ; Remove sizing grip (can't change its color - uses system colors for 3D etching)
    sbStyle := DllCall("GetWindowLong", "Ptr", gSBHwnd, "Int", -16, "Int")
    DllCall("SetWindowLong", "Ptr", gSBHwnd, "Int", -16, "Int", sbStyle & ~0x0100)  ; ~SBARS_SIZEGRIP
    DllCall("SendMessageW", "Ptr", gSBHwnd, "UInt", 0x2001, "Ptr", 0, "Ptr", CLR_L_BG)  ; SB_SETBKCOLOR
    ; SB_SETTEXTW = 0x040B (NOT 0x040D which is SB_GETTEXTW!)
    DllCall("SendMessageW", "Ptr", gSBHwnd, "UInt", 0x040B, "Ptr", 0x1000, "Ptr", 0)     ; SB_SETTEXTW part 0 | SBT_OWNERDRAW

    ; Subclass status bar to fully own WM_PAINT (continuous border, no grip).
    ; The grip is drawn by the classic renderer regardless of SBARS_SIZEGRIP removal.
    gSBSubclassCB := CallbackCreate(OD_SBSubclass, , 6)
    DllCall("comctl32\SetWindowSubclass", "Ptr", gSBHwnd,
        "Ptr", gSBSubclassCB, "UPtr", 2, "Ptr", 0)

    ; Force repaint so our subclass handles the initial draw (Show() painted before subclass was installed)
    DllCall("InvalidateRect", "Ptr", gSBHwnd, "Ptr", 0, "Int", 1)
}

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
        myGui.Title := "Owner-Draw Dark Controls [DARK]"
        myGui["ModeLabel"].Text := "Current: Dark Mode"
        gODMap[toggleBtn.Hwnd].text := "Switch to Light Mode"
    } else {
        myGui.BackColor := S_L_BG
        myGui.Title := "Owner-Draw Dark Controls [LIGHT]"
        myGui["ModeLabel"].Text := "Current: Light Mode"
        gODMap[toggleBtn.Hwnd].text := "Switch to Dark Mode"
    }

    ; Dark title bar + AllowDarkModeForWindow
    SetDarkTitleBar(myGui.Hwnd, gIsDark)
    DllCall(_UxOrd(133), "Ptr", myGui.Hwnd, "Int", gIsDark)

    ; Label text colors: handled by WM_CTLCOLORSTATIC (works fine for Text controls).
    ; GroupBox text color: BS_GROUPBOX ignores WM_CTLCOLORBTN when visual styles are active.
    ; Strip visual styles so the classic renderer uses our WM_CTLCOLORBTN colors.
    for vName in ["Group1", "Group2"] {
        if (gIsDark)
            DllCall("uxtheme\SetWindowTheme", "Ptr", myGui[vName].Hwnd, "Str", "", "Str", "")
        else
            DllCall("uxtheme\SetWindowTheme", "Ptr", myGui[vName].Hwnd, "Ptr", 0, "Ptr", 0)
    }

    ; Edit controls - theme is sufficient
    for vName in ["NameEdit", "EmailEdit", "NumEdit", "TabEdit1"]
        ApplyTheme(myGui[vName].Hwnd, gIsDark, "DarkMode_CFD")

    ; UpDown - theme only (no NM_CUSTOMDRAW support for hover colors)
    ApplyTheme(myGui["NumUpDown"].Hwnd, gIsDark, "DarkMode_Explorer")

    ; DDL - AllowDarkModeForWindow + DarkMode_CFD for frame and arrow button
    DllCall(_UxOrd(133), "Ptr", myGui["DDL"].Hwnd, "Int", gIsDark)
    ApplyTheme(myGui["DDL"].Hwnd, gIsDark, "DarkMode_CFD")

    ; Tab control - theme for tab strip
    DllCall(_UxOrd(133), "Ptr", myGui["TabCtrl"].Hwnd, "Int", gIsDark)
    ApplyTheme(myGui["TabCtrl"].Hwnd, gIsDark, "DarkMode_Explorer")

    ; ListView items - theme for scrollbar/general dark look
    ; Selection colors handled by clearing CDIS_SELECTED in NM_CUSTOMDRAW
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

    ; ListView header - AllowDarkModeForWindow + theme
    if (gLVHeaderHwnd) {
        DllCall(_UxOrd(133), "Ptr", gLVHeaderHwnd, "Int", gIsDark)
        ApplyTheme(gLVHeaderHwnd, gIsDark, "DarkMode_Explorer")
    }

    ; Progress bar - visual styles disabled at creation, color messages work
    DllCall("SendMessageW", "Ptr", myGui["Progress"].Hwnd, "UInt", 0x2001, "Ptr", 0,
        "Ptr", gIsDark ? CLR_D_CTRL : CLR_L_CTRL2)   ; PBM_SETBKCOLOR
    DllCall("SendMessageW", "Ptr", myGui["Progress"].Hwnd, "UInt", 0x0409, "Ptr", 0,
        "Ptr", CLR_ACCENT)                             ; PBM_SETBARCOLOR

    ; StatusBar - visual styles stripped at init, SB_SETBKCOLOR for gaps/grip,
    ; owner-draw (SBT_OWNERDRAW) for text color control via WM_DRAWITEM
    DllCall("SendMessageW", "Ptr", gSBHwnd, "UInt", 0x2001,
        "Ptr", 0, "Ptr", gIsDark ? CLR_D_BG : CLR_L_BG)  ; SB_SETBKCOLOR
    SB_SetText(gIsDark ? " Ready - Dark Mode" : " Ready - Light Mode")

    ; Slider - theme for base, NM_CUSTOMDRAW handles the rest
    ApplyTheme(gSliderHwnd, gIsDark, "DarkMode_Explorer")

    ; Notify main window of theme change (triggers WM_CTLCOLOR* for all children)
    SendMessage(0x031A, 0, 0, myGui.Hwnd)  ; WM_THEMECHANGED

    ; Force full redraw INCLUDING all child controls
    ; RDW_INVALIDATE(0x01) | RDW_ERASE(0x04) | RDW_ALLCHILDREN(0x80) | RDW_UPDATENOW(0x100)
    DllCall("RedrawWindow", "Ptr", myGui.Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x185)
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
    global gSBHwnd
    ; Check status bar first (owner-drawn parts don't use standard CtlType)
    hwndItem := NumGet(lParam, 24, "Ptr")
    if (hwndItem = gSBHwnd)
        return OD_DrawStatusBar(lParam)
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

    ; Colors: selected = RED (proof of control), normal = control bg
    if (isSelected) {
        bgColor := CLR_RED
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
    hFont := DllCall("SendMessageW", "Ptr", btnHwnd, "UInt", 0x0031, "Ptr", 0, "Ptr", 0, "Ptr")
    if (hFont)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", hFont, "Ptr")
    DllCall("SetTextColor", "Ptr", hdc, "UInt", txColor)
    DllCall("SetBkMode", "Ptr", hdc, "Int", 1)  ; TRANSPARENT
    pad := Round(6 * gDpiScale)
    textRc := Buffer(16)
    NumPut("Int", left + pad, "Int", top, "Int", right - pad, "Int", bottom, textRc)
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

    hFont := DllCall("SendMessageW", "Ptr", btnHwnd, "UInt", 0x0031, "Ptr", 0, "Ptr", 0, "Ptr")
    if (hFont)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", hFont, "Ptr")
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
    boxSize := Round(18 * gDpiScale)
    boxY := top + ((bottom - top - boxSize) // 2)
    boxL := left + 2, boxR := boxL + boxSize, boxT := boxY, boxB := boxY + boxSize

    ; Box border + fill - RED to prove we control check fill color
    if (checked) {
        boxBg := CLR_RED
        boxBd := CLR_RED
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

    ; Check mark (white lines on red)
    if (checked) {
        penW := Max(2, Round(2 * gDpiScale))
        checkPen := DllCall("CreatePen", "Int", 0, "Int", penW, "UInt", CLR_WHITE, "Ptr")
        old3 := DllCall("SelectObject", "Ptr", hdc, "Ptr", checkPen, "Ptr")
        pad := Round(3 * gDpiScale)
        arm := Round(9 * gDpiScale)
        cx := boxL + pad, cy := boxT + boxSize // 2
        DllCall("MoveToEx", "Ptr", hdc, "Int", cx, "Int", cy, "Ptr", 0)
        DllCall("LineTo", "Ptr", hdc, "Int", cx + pad, "Int", cy + pad)
        DllCall("LineTo", "Ptr", hdc, "Int", cx + arm, "Int", cy - pad)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", old3, "Ptr")
        DllCall("DeleteObject", "Ptr", checkPen)
    }

    ; Label text
    hFont := DllCall("SendMessageW", "Ptr", btnHwnd, "UInt", 0x0031, "Ptr", 0, "Ptr", 0, "Ptr")
    if (hFont)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", hFont, "Ptr")
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
    circSize := Round(18 * gDpiScale)
    circY := top + ((bottom - top - circSize) // 2)
    circL := left + 2, circR := circL + circSize, circT := circY, circB := circY + circSize

    ; Clear area
    clearBrush := DllCall("CreateSolidBrush", "UInt", gIsDark ? CLR_D_BG : CLR_L_BG, "Ptr")
    clearRc := Buffer(16)
    NumPut("Int", left, "Int", top, "Int", right, "Int", bottom, clearRc)
    DllCall("FillRect", "Ptr", hdc, "Ptr", clearRc, "Ptr", clearBrush)
    DllCall("DeleteObject", "Ptr", clearBrush)

    ; Outer circle - RED to prove we control radio fill color
    bd := selected ? CLR_RED : (gIsDark ? CLR_D_BORDER : CLR_L_BORDER)
    bg := selected ? CLR_RED : (gIsDark ? CLR_D_CTRL2 : CLR_L_CTRL)
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
        m := Round(4 * gDpiScale)
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
    hFont := DllCall("SendMessageW", "Ptr", btnHwnd, "UInt", 0x0031, "Ptr", 0, "Ptr", 0, "Ptr")
    if (hFont)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", hFont, "Ptr")
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

    hFont := DllCall("SendMessageW", "Ptr", tabHwnd, "UInt", 0x0031, "Ptr", 0, "Ptr", 0, "Ptr")
    if (hFont)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", hFont, "Ptr")
    DllCall("SetTextColor", "Ptr", hdc, "UInt", tx)
    DllCall("SetBkMode", "Ptr", hdc, "Int", 1)
    DllCall("DrawText", "Ptr", hdc, "Str", tabText, "Int", -1,
        "Ptr", rc, "UInt", 0x25)  ; DT_CENTER | DT_VCENTER | DT_SINGLELINE
    return 1
}

; ============================================================
; WM_NOTIFY Handler - NM_CUSTOMDRAW for Slider + ListView
; ============================================================
; NMCUSTOMDRAW (x64):
;   0: hwndFrom(8)  8: idFrom(8)  16: code(4)  20: pad(4)
;   24: dwDrawStage(4)  28: pad(4)  32: hdc(8)
;   40: rc(16)  56: dwItemSpec(8)  64: uItemState(4)
;
; NMLVCUSTOMDRAW extends NMCUSTOMDRAW:
;   80: clrText(4)  84: clrTextBk(4)  88: iSubItem(4)

OD_OnNotify(wParam, lParam, msg, hwnd) {
    global gSliderHwnd, gLVHwnd
    code := NumGet(lParam, 16, "Int")
    hwndFrom := NumGet(lParam, 0, "Ptr")

    if (code = -12) {  ; NM_CUSTOMDRAW
        if (hwndFrom = gSliderHwnd)
            return OD_DrawSlider(lParam)
        if (hwndFrom = gLVHwnd)
            return OD_DrawListView(lParam)
    }

    if (code = -108 && hwndFrom = gLVHwnd)  ; LVN_COLUMNCLICK
        OD_OnColumnClick(lParam)

    ; Force repaint on focus change so selected+focused vs selected+unfocused colors update
    if ((code = -7 || code = -8) && hwndFrom = gLVHwnd)  ; NM_SETFOCUS / NM_KILLFOCUS
        DllCall("InvalidateRect", "Ptr", gLVHwnd, "Ptr", 0, "Int", 1)
}

; -- Slider Custom Draw --
OD_DrawSlider(lParam) {
    global gIsDark, gSliderHwnd
    stage := NumGet(lParam, 24, "UInt")

    if (stage = 0x01)  ; CDDS_PREPAINT
        return 0x20    ; CDRF_NOTIFYITEMDRAW

    if (stage != 0x10001)  ; CDDS_ITEMPREPAINT
        return 0

    hdc  := NumGet(lParam, 32, "Ptr")
    left := NumGet(lParam, 40, "Int"), top := NumGet(lParam, 44, "Int")
    right := NumGet(lParam, 48, "Int"), bottom := NumGet(lParam, 52, "Int")
    part := NumGet(lParam, 56, "UPtr")  ; TBCD_CHANNEL=3, TBCD_THUMB=2, TBCD_TICS=1

    if (part = 3) {  ; TBCD_CHANNEL (gutter)
        ; Two-tone: filled = YELLOW (proof), empty = gutter color
        pos := SendMessage(0x0400, 0, 0, gSliderHwnd)       ; TBM_GETPOS
        rangeMin := SendMessage(0x0401, 0, 0, gSliderHwnd)  ; TBM_GETRANGEMIN
        rangeMax := SendMessage(0x0402, 0, 0, gSliderHwnd)  ; TBM_GETRANGEMAX
        channelW := right - left
        fillW := (rangeMax > rangeMin) ? Round((pos - rangeMin) / (rangeMax - rangeMin) * channelW) : 0

        ; Filled portion - YELLOW to prove we control it
        if (fillW > 0) {
            fb := DllCall("CreateSolidBrush", "UInt", CLR_YELLOW, "Ptr")
            frc := Buffer(16)
            NumPut("Int", left, "Int", top, "Int", left + fillW, "Int", bottom, frc)
            DllCall("FillRect", "Ptr", hdc, "Ptr", frc, "Ptr", fb)
            DllCall("DeleteObject", "Ptr", fb)
        }
        ; Empty portion - gutter
        if (left + fillW < right) {
            eb := DllCall("CreateSolidBrush", "UInt", gIsDark ? CLR_D_GUTTER : CLR_L_GUTTER, "Ptr")
            erc := Buffer(16)
            NumPut("Int", left + fillW, "Int", top, "Int", right, "Int", bottom, erc)
            DllCall("FillRect", "Ptr", hdc, "Ptr", erc, "Ptr", eb)
            DllCall("DeleteObject", "Ptr", eb)
        }
        return 0x04  ; CDRF_SKIPDEFAULT
    }

    if (part = 2) {  ; TBCD_THUMB - RED to prove custom draw works
        thumbBrush := DllCall("CreateSolidBrush", "UInt", CLR_RED, "Ptr")
        thumbPen := DllCall("CreatePen", "Int", 0, "Int", 1, "UInt", CLR_RED, "Ptr")
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

; -- ListView Custom Draw (4 distinct states for proof-of-control) --
; Selection colors controlled by clearing CDIS_SELECTED|CDIS_FOCUS from uItemState,
; then setting custom clrTextBk. Without clearing, the theme engine paints its own
; blue highlight OVER our colors. Pattern from AHK LV_Colors class by "just me".
;
; Four states proved with distinct colors:
;   Normal          = white/dark bg (theme-appropriate)
;   Hover           = YELLOW
;   Selected+Focus  = GREEN
;   Selected+NoFocus = MAGENTA
OD_DrawListView(lParam) {
    global gIsDark, gLVHwnd, gLVHotRow
    stage := NumGet(lParam, 24, "UInt")

    if (stage = 0x01)  ; CDDS_PREPAINT
        return 0x20    ; CDRF_NOTIFYITEMDRAW

    if (stage != 0x10001)  ; CDDS_ITEMPREPAINT
        return 0

    itemIdx := Integer(NumGet(lParam, 56, "UPtr"))

    ; Check actual selection state via LVM_GETITEMSTATE (more reliable than uItemState)
    isSelected := DllCall("SendMessageW", "Ptr", gLVHwnd, "UInt", 0x102C,
        "Ptr", itemIdx, "Ptr", 0x0002, "UInt") & 0x0002  ; LVIS_SELECTED
    isHot := (itemIdx = gLVHotRow)  ; Manual hover tracking

    if (isSelected) {
        ; CRITICAL: Clear CDIS_SELECTED(0x01) + CDIS_FOCUS(0x10) from uItemState
        ; Without this, the theme engine paints its own selection highlight OVER our colors
        NumPut("UInt", NumGet(lParam, 64, "UInt") & ~0x0011, lParam, 64)

        ; Detect if ListView has keyboard focus
        hasFocus := (DllCall("GetFocus", "Ptr") = gLVHwnd)
        if (hasFocus) {
            ; GREEN - proves selected+focused color control
            NumPut("UInt", CLR_L_TEXT, lParam, 80)     ; clrText
            NumPut("UInt", CLR_GREEN, lParam, 84)      ; clrTextBk
        } else {
            ; MAGENTA - proves selected+unfocused color control
            NumPut("UInt", CLR_L_TEXT, lParam, 80)
            NumPut("UInt", CLR_MAGENTA, lParam, 84)
        }
    } else if (isHot) {
        ; YELLOW - proves hover color control
        NumPut("UInt", CLR_L_TEXT, lParam, 80)
        NumPut("UInt", CLR_YELLOW, lParam, 84)
    } else {
        ; Normal - theme-appropriate colors
        NumPut("UInt", gIsDark ? CLR_D_TEXT : CLR_L_TEXT, lParam, 80)
        NumPut("UInt", gIsDark ? CLR_D_CTRL : CLR_L_CTRL, lParam, 84)
    }
    return 0x02  ; CDRF_NEWFONT
}

; -- ListView Header Custom Draw (all items for full control) --
; Called from OD_LVSubclass - header NM_CUSTOMDRAW goes to ListView, not main window.
; Must paint ALL items (not just hot) because returning CDRF_DODEFAULT for non-hot
; items lets the theme engine draw its own hover highlight that we can't override.
OD_DrawHeader(lParam) {
    global gIsDark, gLVColumns, gLVHeaderHwnd, gSortCol, gSortAsc
    stage := NumGet(lParam, 24, "UInt")

    if (stage = 0x01)  ; CDDS_PREPAINT
        return 0x30    ; CDRF_NOTIFYITEMDRAW | CDRF_NOTIFYPOSTPAINT

    if (stage = 0x02) {  ; CDDS_POSTPAINT - fill empty area after last column
        hdc := NumGet(lParam, 32, "Ptr")
        count := DllCall("SendMessageW", "Ptr", gLVHeaderHwnd, "UInt", 0x1200,
            "Ptr", 0, "Ptr", 0, "Int")  ; HDM_GETITEMCOUNT
        if (count > 0) {
            itemRc := Buffer(16, 0)
            DllCall("SendMessageW", "Ptr", gLVHeaderHwnd, "UInt", 0x1207,
                "Ptr", count - 1, "Ptr", itemRc)  ; HDM_GETITEMRECT (last column)
            lastRight := NumGet(itemRc, 8, "Int")
            headerRc := Buffer(16)
            DllCall("GetClientRect", "Ptr", gLVHeaderHwnd, "Ptr", headerRc)
            headerRight := NumGet(headerRc, 8, "Int")
            headerBottom := NumGet(headerRc, 12, "Int")
            if (lastRight < headerRight) {
                fillRc := Buffer(16)
                NumPut("Int", lastRight, "Int", 0, "Int", headerRight, "Int", headerBottom, fillRc)
                fillBrush := DllCall("CreateSolidBrush", "UInt", gIsDark ? CLR_D_CTRL : CLR_L_CTRL, "Ptr")
                DllCall("FillRect", "Ptr", hdc, "Ptr", fillRc, "Ptr", fillBrush)
                DllCall("DeleteObject", "Ptr", fillBrush)
            }
        }
        return 0
    }

    if (stage != 0x10001)  ; CDDS_ITEMPREPAINT
        return 0

    hdc := NumGet(lParam, 32, "Ptr")
    left := NumGet(lParam, 40, "Int"), top := NumGet(lParam, 44, "Int")
    right := NumGet(lParam, 48, "Int"), bottom := NumGet(lParam, 52, "Int")
    itemIndex := Integer(NumGet(lParam, 56, "UPtr"))
    isHot := (itemIndex = gHdrHotItem)  ; Manual hover tracking (CDIS_HOT unreliable)

    ; Hot = LIGHT RED (proof), sorted = subtle tint, normal = theme bg
    if (isHot)
        bg := CLR_RED_LITE
    else if (itemIndex = gSortCol)
        bg := gIsDark ? 0x3A3A3A : 0xE8E8E8
    else
        bg := gIsDark ? CLR_D_CTRL : CLR_L_CTRL

    brush := DllCall("CreateSolidBrush", "UInt", bg, "Ptr")
    rc := Buffer(16)
    NumPut("Int", left, "Int", top, "Int", right, "Int", bottom, rc)
    DllCall("FillRect", "Ptr", hdc, "Ptr", rc, "Ptr", brush)
    DllCall("DeleteObject", "Ptr", brush)

    ; Bottom border
    bdPen := DllCall("CreatePen", "Int", 0, "Int", 1, "UInt", gIsDark ? CLR_D_BORDER : CLR_L_BORDER, "Ptr")
    old := DllCall("SelectObject", "Ptr", hdc, "Ptr", bdPen, "Ptr")
    DllCall("MoveToEx", "Ptr", hdc, "Int", left, "Int", bottom - 1, "Ptr", 0)
    DllCall("LineTo", "Ptr", hdc, "Int", right, "Int", bottom - 1)
    DllCall("SelectObject", "Ptr", hdc, "Ptr", old, "Ptr")
    DllCall("DeleteObject", "Ptr", bdPen)

    ; Header text
    headerText := (itemIndex < gLVColumns.Length) ? gLVColumns[itemIndex + 1] : ""
    hFont := DllCall("SendMessageW", "Ptr", gLVHeaderHwnd, "UInt", 0x0031, "Ptr", 0, "Ptr", 0, "Ptr")
    if (hFont)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", hFont, "Ptr")
    DllCall("SetTextColor", "Ptr", hdc, "UInt", gIsDark ? CLR_D_TEXT : CLR_L_TEXT)
    DllCall("SetBkMode", "Ptr", hdc, "Int", 1)  ; TRANSPARENT
    textRc := Buffer(16)
    NumPut("Int", left + 8, "Int", top, "Int", right - 24, "Int", bottom, textRc)
    DllCall("DrawText", "Ptr", hdc, "Str", headerText, "Int", -1,
        "Ptr", textRc, "UInt", 0x24)  ; DT_LEFT | DT_VCENTER | DT_SINGLELINE

    ; Sort arrow (filled triangle via GDI Polygon)
    if (itemIndex = gSortCol) {
        arrowX := right - 18
        midY := (top + bottom) // 2
        arrowPen := DllCall("CreatePen", "Int", 0, "Int", 1, "UInt", gIsDark ? CLR_D_TEXT : CLR_L_TEXT, "Ptr")
        arrowBrush := DllCall("CreateSolidBrush", "UInt", gIsDark ? CLR_D_TEXT : CLR_L_TEXT, "Ptr")
        old1 := DllCall("SelectObject", "Ptr", hdc, "Ptr", arrowPen, "Ptr")
        old2 := DllCall("SelectObject", "Ptr", hdc, "Ptr", arrowBrush, "Ptr")
        ; 3 POINT structs = 3 * {LONG x, LONG y} = 24 bytes
        pts := Buffer(24, 0)
        if (gSortAsc) {
            NumPut("Int", arrowX + 4, "Int", midY - 3, pts, 0)   ; top center
            NumPut("Int", arrowX,     "Int", midY + 3, pts, 8)   ; bottom left
            NumPut("Int", arrowX + 8, "Int", midY + 3, pts, 16)  ; bottom right
        } else {
            NumPut("Int", arrowX,     "Int", midY - 3, pts, 0)   ; top left
            NumPut("Int", arrowX + 8, "Int", midY - 3, pts, 8)   ; top right
            NumPut("Int", arrowX + 4, "Int", midY + 3, pts, 16)  ; bottom center
        }
        DllCall("Polygon", "Ptr", hdc, "Ptr", pts, "Int", 3)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", old1, "Ptr")
        DllCall("SelectObject", "Ptr", hdc, "Ptr", old2, "Ptr")
        DllCall("DeleteObject", "Ptr", arrowPen)
        DllCall("DeleteObject", "Ptr", arrowBrush)
    }

    return 0x04  ; CDRF_SKIPDEFAULT
}

; -- ListView Subclass Callback --
; Header sends NM_CUSTOMDRAW to its parent (ListView), which handles it internally.
; This subclass intercepts those messages so we can custom-paint header hover colors.
OD_LVSubclass(hwnd, uMsg, wParam, lParam, uIdSubclass, dwRefData) {
    global gLVHeaderHwnd
    if (uMsg = 0x004E && gLVHeaderHwnd) {  ; WM_NOTIFY
        code := NumGet(lParam, 16, "Int")
        if (code = -12) {  ; NM_CUSTOMDRAW
            hwndFrom := NumGet(lParam, 0, "Ptr")
            if (hwndFrom = gLVHeaderHwnd)
                return OD_DrawHeader(lParam)
        }
    }
    return DllCall("comctl32\DefSubclassProc", "Ptr", hwnd, "UInt", uMsg, "Ptr", wParam, "Ptr", lParam, "Ptr")
}

; -- ListView Column Click (sort indicator) --
OD_OnColumnClick(lParam) {
    global gSortCol, gSortAsc, gLVHeaderHwnd
    ; NMLISTVIEW x64: iSubItem at offset 28
    colIdx := NumGet(lParam, 28, "Int")

    if (colIdx = gSortCol) {
        gSortAsc := !gSortAsc
    } else {
        gSortCol := colIdx
        gSortAsc := true
    }

    ; Force header repaint to show/update sort arrow
    DllCall("InvalidateRect", "Ptr", gLVHeaderHwnd, "Ptr", 0, "Int", 1)
}

; ============================================================
; WM_CTLCOLOR Handlers
; ============================================================
; CRITICAL: returning 0 means NULL brush = NO background painting (black).
; Must return a valid brush for BOTH dark and light modes.
; Returning nothing (no return statement) defers to system default.

OD_OnCtlColorEdit(wParam, lParam, msg, hwnd) {
    global gIsDark
    if (gIsDark) {
        DllCall("SetTextColor", "Ptr", wParam, "UInt", CLR_D_TEXT)
        DllCall("SetBkColor", "Ptr", wParam, "UInt", CLR_D_CTRL)
        return gBrushDarkCtrl
    }
    DllCall("SetTextColor", "Ptr", wParam, "UInt", CLR_L_TEXT)
    DllCall("SetBkColor", "Ptr", wParam, "UInt", CLR_L_CTRL)
    return gBrushLightCtrl
}

OD_OnCtlColorList(wParam, lParam, msg, hwnd) {
    global gIsDark
    if (gIsDark) {
        DllCall("SetTextColor", "Ptr", wParam, "UInt", CLR_D_TEXT)
        DllCall("SetBkColor", "Ptr", wParam, "UInt", CLR_D_CTRL)
        return gBrushDarkCtrl
    }
    DllCall("SetTextColor", "Ptr", wParam, "UInt", CLR_L_TEXT)
    DllCall("SetBkColor", "Ptr", wParam, "UInt", CLR_L_CTRL)
    return gBrushLightCtrl
}

OD_OnCtlColorStatic(wParam, lParam, msg, hwnd) {
    global gIsDark
    if (gIsDark) {
        DllCall("SetTextColor", "Ptr", wParam, "UInt", CLR_D_TEXT)
        DllCall("SetBkColor", "Ptr", wParam, "UInt", CLR_D_BG)
        return gBrushDarkBg
    }
    DllCall("SetTextColor", "Ptr", wParam, "UInt", CLR_L_TEXT)
    DllCall("SetBkColor", "Ptr", wParam, "UInt", CLR_L_BG)
    return gBrushLightBg
}

; GroupBox is a BUTTON class control (BS_GROUPBOX) - sends WM_CTLCOLORBTN, NOT WM_CTLCOLORSTATIC.
; Owner-drawn buttons (BS_OWNERDRAW) don't send this, so only GroupBox hits this handler.
OD_OnCtlColorBtn(wParam, lParam, msg, hwnd) {
    global gIsDark
    if (gIsDark) {
        DllCall("SetTextColor", "Ptr", wParam, "UInt", CLR_D_TEXT)
        DllCall("SetBkColor", "Ptr", wParam, "UInt", CLR_D_BG)
        return gBrushDarkBg
    }
    DllCall("SetTextColor", "Ptr", wParam, "UInt", CLR_L_TEXT)
    DllCall("SetBkColor", "Ptr", wParam, "UInt", CLR_L_BG)
    return gBrushLightBg
}

; ============================================================
; StatusBar Owner-Draw
; ============================================================

OD_DrawStatusBar(lParam) {
    global gIsDark, gSBText
    hdc    := NumGet(lParam, 32, "Ptr")
    left   := NumGet(lParam, 40, "Int")
    top    := NumGet(lParam, 44, "Int")
    right  := NumGet(lParam, 48, "Int")
    bottom := NumGet(lParam, 52, "Int")

    ; Fill background
    bgColor := gIsDark ? CLR_D_BG : CLR_L_BG
    brush := DllCall("CreateSolidBrush", "UInt", bgColor, "Ptr")
    rc := Buffer(16)
    NumPut("Int", left, "Int", top, "Int", right, "Int", bottom, rc)
    DllCall("FillRect", "Ptr", hdc, "Ptr", rc, "Ptr", brush)
    DllCall("DeleteObject", "Ptr", brush)

    ; Draw text
    DllCall("SetBkMode", "Ptr", hdc, "Int", 1)  ; TRANSPARENT
    DllCall("SetTextColor", "Ptr", hdc, "UInt", gIsDark ? CLR_D_TEXT : CLR_L_TEXT)
    NumPut("Int", left + 4, rc, 0)  ; Inset text slightly
    DllCall("DrawTextW", "Ptr", hdc, "Str", gSBText, "Int", -1, "Ptr", rc,
        "UInt", 0x24)  ; DT_SINGLELINE(0x20) | DT_VCENTER(0x04)

    return true
}

SB_SetText(text) {
    global gSBText, gSBHwnd
    gSBText := text
    ; SB_SETTEXTW = 0x040B (NOT 0x040D which is SB_GETTEXTW!)
    DllCall("SendMessageW", "Ptr", gSBHwnd, "UInt", 0x040B, "Ptr", 0x1000, "Ptr", 0)
}

; Subclass: fully handle WM_PAINT to draw a continuous border across the
; entire status bar. The default handler only draws the sunken edge around
; part 0, leaving a gap where the grip area was.
OD_SBSubclass(hwnd, msg, wParam, lParam, subclassId, refData) {
    global gIsDark, gSBText
    if (msg = 0x000F) {  ; WM_PAINT
        ps := Buffer(72, 0)  ; PAINTSTRUCT (x64)
        hdc := DllCall("BeginPaint", "Ptr", hwnd, "Ptr", ps, "Ptr")

        clientRc := Buffer(16)
        DllCall("GetClientRect", "Ptr", hwnd, "Ptr", clientRc)

        ; Fill entire client area
        bgBrush := DllCall("CreateSolidBrush", "UInt", gIsDark ? CLR_D_BG : CLR_L_BG, "Ptr")
        DllCall("FillRect", "Ptr", hdc, "Ptr", clientRc, "Ptr", bgBrush)
        DllCall("DeleteObject", "Ptr", bgBrush)

        ; Draw sunken edge around entire client area (continuous, no gap)
        edgeRc := Buffer(16)
        DllCall("RtlMoveMemory", "Ptr", edgeRc, "Ptr", clientRc, "UInt", 16)
        DllCall("DrawEdge", "Ptr", hdc, "Ptr", edgeRc, "UInt", 0x000A, "UInt", 0x000F)
        ; EDGE_SUNKEN = 0x0A, BF_RECT = 0x0F

        ; Draw text inside the edge
        hFont := DllCall("SendMessageW", "Ptr", hwnd, "UInt", 0x0031, "Ptr", 0, "Ptr", 0, "Ptr")
        if (hFont)
            DllCall("SelectObject", "Ptr", hdc, "Ptr", hFont, "Ptr")
        DllCall("SetBkMode", "Ptr", hdc, "Int", 1)  ; TRANSPARENT
        DllCall("SetTextColor", "Ptr", hdc, "UInt", gIsDark ? CLR_D_TEXT : CLR_L_TEXT)
        textRc := Buffer(16)
        NumPut("Int", NumGet(clientRc, 0, "Int") + 6, "Int", NumGet(clientRc, 4, "Int"),
            "Int", NumGet(clientRc, 8, "Int") - 4, "Int", NumGet(clientRc, 12, "Int"), textRc)
        DllCall("DrawTextW", "Ptr", hdc, "Str", gSBText, "Int", -1, "Ptr", textRc,
            "UInt", 0x24)  ; DT_SINGLELINE | DT_VCENTER

        DllCall("EndPaint", "Ptr", hwnd, "Ptr", ps)
        return 0
    }
    return DllCall("comctl32\DefSubclassProc", "Ptr", hwnd, "UInt", msg,
        "Ptr", wParam, "Ptr", lParam, "Ptr")
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
    ; CBS_OWNERDRAWFIXED already set at creation (+0x0010) - don't change style here!
    ; Setting via SetWindowLong AFTER creation doesn't propagate to dropdown list window.
    itemH := Round(24 * gDpiScale)
    SendMessage(0x0153, 0, itemH, ctrl.Hwnd)    ; CB_SETITEMHEIGHT list items
    SendMessage(0x0153, -1, itemH, ctrl.Hwnd)   ; CB_SETITEMHEIGHT selection face
    gODMap[ctrl.Hwnd] := {type: "ddl"}
}

OD_MakeTab(ctrl) {
    ; TCS_OWNERDRAWFIXED for custom tab header painting
    style := DllCall("GetWindowLong", "Ptr", ctrl.Hwnd, "Int", -16, "Int")
    ; Add TCS_OWNERDRAWFIXED(0x2000) + WS_CLIPCHILDREN(0x02000000)
    ; WS_CLIPCHILDREN prevents tab header repaints from erasing content area
    ; (fixes "contents disappear on mouseover" bug)
    DllCall("SetWindowLong", "Ptr", ctrl.Hwnd, "Int", -16, "Int", style | 0x2000 | 0x02000000)
    ; NOTE: Tab is NOT added to gODMap - no hover tracking needed for tabs.
    ; Adding it would cause the hover timer to InvalidateRect the entire tab control,
    ; which erases the content area and causes child controls to disappear.
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
    global gODMap, gHoverHwnd, gLVHwnd, gLVHotRow, gLVHeaderHwnd, gHdrHotItem
    pt := Buffer(8, 0)
    DllCall("GetCursorPos", "Ptr", pt)
    hwndUnder := DllCall("WindowFromPoint", "Int64", NumGet(pt, 0, "Int64"), "Ptr")

    ; -- Owner-draw control hover --
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

    ; -- ListView row hover (manual CDIS_HOT) --
    ; Don't gate on hwndUnder=gLVHwnd — WindowFromPoint may return a child/parent.
    ; LVM_HITTEST naturally returns -1 when cursor isn't over any item.
    if (gLVHwnd) {
        newHotRow := -1
        lvPt := Buffer(8, 0)
        NumPut("Int", NumGet(pt, 0, "Int"), "Int", NumGet(pt, 4, "Int"), lvPt)
        DllCall("ScreenToClient", "Ptr", gLVHwnd, "Ptr", lvPt)
        ; LVHITTESTINFO: POINT(8) + flags(4) + iItem(4) + iSubItem(4) + iGroup(4) = 24
        hitInfo := Buffer(24, 0)
        NumPut("Int", NumGet(lvPt, 0, "Int"), "Int", NumGet(lvPt, 4, "Int"), hitInfo)
        hitRow := DllCall("SendMessageW", "Ptr", gLVHwnd, "UInt", 0x1012,
            "Ptr", 0, "Ptr", hitInfo, "Int")  ; LVM_HITTEST
        if (hitRow >= 0)
            newHotRow := hitRow
        if (newHotRow != gLVHotRow) {
            oldRow := gLVHotRow
            gLVHotRow := newHotRow
            if (oldRow >= 0)
                OD_InvalidateLVRow(oldRow)
            if (newHotRow >= 0)
                OD_InvalidateLVRow(newHotRow)
        }
    }

    ; -- Header item hover (manual CDIS_HOT) --
    if (gLVHeaderHwnd) {
        newHotHdr := -1
        if (hwndUnder = gLVHeaderHwnd) {
            hdrPt := Buffer(8, 0)
            NumPut("Int", NumGet(pt, 0, "Int"), "Int", NumGet(pt, 4, "Int"), hdrPt)
            DllCall("ScreenToClient", "Ptr", gLVHeaderHwnd, "Ptr", hdrPt)
            ; HDHITTESTINFO: POINT(8) + flags(4) + iItem(4) = 16
            hdrHit := Buffer(16, 0)
            NumPut("Int", NumGet(hdrPt, 0, "Int"), "Int", NumGet(hdrPt, 4, "Int"), hdrHit)
            DllCall("SendMessageW", "Ptr", gLVHeaderHwnd, "UInt", 0x1206,
                "Ptr", 0, "Ptr", hdrHit)  ; HDM_HITTEST
            hitItem := NumGet(hdrHit, 12, "Int")  ; iItem at offset 12
            flags := NumGet(hdrHit, 8, "UInt")
            if (flags & 0x06)  ; HHT_ONHEADER(0x02) | HHT_ONDIVIDER(0x04)
                newHotHdr := hitItem
        }
        if (newHotHdr != gHdrHotItem) {
            gHdrHotItem := newHotHdr
            DllCall("InvalidateRect", "Ptr", gLVHeaderHwnd, "Ptr", 0, "Int", 1)
        }
    }
}

OD_InvalidateLVRow(rowIdx) {
    global gLVHwnd
    rc := Buffer(16, 0)
    NumPut("Int", 0, rc, 0)  ; LVIR_BOUNDS
    DllCall("SendMessageW", "Ptr", gLVHwnd, "UInt", 0x100E, "Ptr", rowIdx, "Ptr", rc)
    DllCall("InvalidateRect", "Ptr", gLVHwnd, "Ptr", rc, "Int", 1)
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
