#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
; Mock: Dark Themed Common Controls (Theme-Only, No Owner-Draw)
; ============================================================
; Maximum dark mode WITHOUT BS_OWNERDRAW / CBS_OWNERDRAWFIXED /
; TCS_OWNERDRAWFIXED. Uses only SetWindowTheme, WM_CTLCOLOR*,
; NM_CUSTOMDRAW, and AllowDarkModeForWindow.
;
; Techniques used:
; 1. SetPreferredAppMode for dark menus (FREE - no per-control work)
; 2. DwmSetWindowAttribute for dark title bar
; 3. AllowDarkModeForWindow per window (before controls for DDL/Tab)
; 4. SetWindowTheme("DarkMode_Explorer"/"DarkMode_CFD") per control
; 5. WM_CTLCOLOR* handlers for Edit/Static/GroupBox bg+text
; 6. NM_CUSTOMDRAW for ListView items + Header (selection/hover colors)
; 7. GroupBox visual style stripping for text color control
;
; What CANNOT be customized without owner-draw:
;   - Button hover/pressed color (theme-controlled)
;   - Checkbox check fill color (theme-controlled)
;   - Radio button fill color (theme-controlled)
;   - DDL item highlight color (theme-controlled)
;   - Tab header text/bg color (theme-controlled)
;   - Slider channel/thumb colors (need NM_CUSTOMDRAW SKIPDEFAULT)
;
; What CAN be customized (same as owner-draw):
;   - All text/label colors (WM_CTLCOLORSTATIC)
;   - GroupBox label color (WM_CTLCOLORBTN + strip visual styles)
;   - Edit text/bg (WM_CTLCOLOREDIT + DarkMode_CFD)
;   - ListView selection/hover/unfocused colors (NM_CUSTOMDRAW)
;   - ListView header hover/sort arrows (NM_CUSTOMDRAW via subclass)
;   - Progress bar/gutter colors (PBM messages)
;   - StatusBar bg/text (DarkMode_Explorer + AllowDarkModeForWindow)
;
; Windows Version: Windows 10 1903+ (build 18362)
; ============================================================

; -- Colors (GDI = BGR: 0x00BBGGRR) --
global CLR_ACCENT    := 0xD47800    ; #0078D4 blue
global CLR_D_BG      := 0x1E1E1E
global CLR_D_CTRL    := 0x2D2D2D
global CLR_D_CTRL2   := 0x3C3C3C
global CLR_D_TEXT    := 0xE0E0E0
global CLR_D_BORDER  := 0x555555
global CLR_L_BG      := 0xF0F0F0
global CLR_L_CTRL    := 0xFFFFFF
global CLR_L_CTRL2   := 0xE1E1E1
global CLR_L_TEXT    := 0x000000
global CLR_L_BORDER  := 0xADADAD
global CLR_RED_LITE  := 0x8080FF    ; Light red - header hover proof
global CLR_GREEN     := 0x00FF00    ; Selected+focused proof
global CLR_MAGENTA   := 0xFF00FF    ; Selected+unfocused proof
global CLR_YELLOW    := 0x00FFFF    ; Hover proof

; AHK strings (RGB for Gui.BackColor)
global S_D_BG := "1E1E1E", S_D_TEXT := "E0E0E0", S_D_CTRL := "2D2D2D"
global S_L_BG := "F0F0F0", S_L_TEXT := "000000"

; -- State --
global gIsDark := false
global gLVHwnd := 0
global gLVHeaderHwnd := 0
global gLVSubclassCB := 0
global gLVHotRow := -1
global gHdrHotItem := -1
global gSortCol := -1
global gSortAsc := true
global gLVColumns := ["Name", "Type", "Status", "Value"]
global gSliderHwnd := 0
global gDpiScale := DllCall("GetDpiForSystem", "UInt") / 96.0
global gSBHwnd := 0
global gSBText := " Ready - Light Mode"
global gSBSubclassCB := 0

; GDI brushes (cached for WM_CTLCOLOR*)
global gBrushDarkBg   := DllCall("CreateSolidBrush", "UInt", CLR_D_BG, "Ptr")
global gBrushDarkCtrl := DllCall("CreateSolidBrush", "UInt", CLR_D_CTRL, "Ptr")
global gBrushLightBg  := DllCall("CreateSolidBrush", "UInt", CLR_L_BG, "Ptr")
global gBrushLightCtrl := DllCall("CreateSolidBrush", "UInt", CLR_L_CTRL, "Ptr")

; -- Uxtheme ordinals (BEFORE windows) --
_UxOrd(ordinal) {
    static hMod := DllCall("GetModuleHandle", "Str", "uxtheme", "Ptr")
    return DllCall("GetProcAddress", "Ptr", hMod, "Ptr", ordinal, "Ptr")
}
DllCall(_UxOrd(135), "Int", 3, "Int")   ; SetPreferredAppMode(ForceLight) - start light
DllCall(_UxOrd(136))                     ; FlushMenuThemes

; -- Register message handlers --
OnMessage(0x0133, WM_CTLCOLOREDIT)   ; WM_CTLCOLOREDIT
OnMessage(0x0134, WM_CTLCOLORLISTBOX) ; WM_CTLCOLORLISTBOX
OnMessage(0x0135, WM_CTLCOLORBTN)    ; WM_CTLCOLORBTN (GroupBox)
OnMessage(0x0138, WM_CTLCOLORSTATIC) ; WM_CTLCOLORSTATIC
OnMessage(0x004E, OnNotify)          ; WM_NOTIFY (NM_CUSTOMDRAW)

; ============================================================
; Build the Demo GUI
; ============================================================

myGui := Gui("+Resize +MinSize600x580", "Dark Controls Demo")
myGui.SetFont("s10", "Segoe UI")
myGui.BackColor := S_L_BG

; -- Toggle button --
toggleBtn := myGui.AddButton("x20 y15 w180 h30", "Switch to Dark Mode")
toggleBtn.OnEvent("Click", ToggleTheme)

myGui.AddText("x210 y22 w300 vModeLabel", "Current: Light Mode")

; -- GroupBox: Text Inputs --
myGui.AddGroupBox("x20 y55 w270 h120 vGroup1", "Text Inputs")
myGui.AddText("x35 y80 w80 vLabel1", "Name:")
myGui.AddEdit("x120 y77 w155 vNameEdit", "Sample text")
myGui.AddText("x35 y110 w80 vLabel2", "Email:")
myGui.AddEdit("x120 y107 w155 vEmailEdit", "user@example.com")
myGui.AddText("x35 y140 w80 vLabel3", "Number:")
myGui.AddEdit("x120 y137 w80 vNumEdit +Number", "42")
myGui.AddUpDown("vNumUpDown Range0-100", 42)

; -- GroupBox: Selection Controls --
myGui.AddGroupBox("x310 y55 w270 h130 vGroup2", "Selection Controls")
ddl := myGui.AddDropDownList("x325 y80 w240 vDDL", ["Option 1", "Option 2", "Option 3"])
ddl.Value := 1
cb1 := myGui.AddCheckbox("x325 y115 w120 vCB1", "Dark Mode")
cb2 := myGui.AddCheckbox("x455 y115 w120 vCB2 Checked", "Auto-save")
myGui.AddRadio("x325 y145 w120 vRad1 Checked", "Choice A")
myGui.AddRadio("x455 y145 w120 vRad2", "Choice B")

; -- ListView --
myGui.AddText("x20 y195 w100 vLVLabel", "ListView:")
lv := myGui.AddListView("x20 y215 w560 h120 vLV", gLVColumns)
lv.Add("", "Window Title", "String", "Active", "Hello World")
lv.Add("", "Opacity", "Integer", "Set", "255")
lv.Add("", "Background", "Color", "Applied", "0x1E1E1E")
lv.Add("", "Font Size", "Float", "Default", "10.0")
lv.Add("", "Accent", "Color", "Custom", "0x0078D4")
lv.ModifyCol(1, 160), lv.ModifyCol(2, 100), lv.ModifyCol(3, 100), lv.ModifyCol(4, 180)
gLVHwnd := lv.Hwnd

; -- Tab Control --
myGui.AddText("x20 y345 w100 vTabLabel", "Tab Control:")
tab := myGui.AddTab3("x20 y365 w560 h100 vTabCtrl", ["General", "Advanced", "About"])

tab.UseTab("General")
myGui.AddText("x35 y395 w200 vTabText1", "General settings would go here.")
myGui.AddEdit("x35 y415 w250 vTabEdit1", "Tab content edit")
tab.UseTab("Advanced")
myGui.AddText("x35 y395 w200 vTabText2", "Advanced settings panel.")
tab.UseTab("About")
myGui.AddText("x35 y395 w300 vTabText3", "Dark mode control demo for AHK v2.")
tab.UseTab()

; -- Slider --
myGui.AddText("x20 y475 w80 vSliderLabel", "Slider:")
slider := myGui.AddSlider("x100 y475 w200 h30 vSlider Range0-100 ToolTip", 50)
gSliderHwnd := slider.Hwnd

; -- Progress --
myGui.AddText("x320 y475 w80 vProgLabel", "Progress:")
prog := myGui.AddProgress("x400 y478 w180 h20 vProgress", 65)

; -- Status Bar --
sb := myGui.AddStatusBar("vSB")
sb.SetText(" Ready - Light Mode")

; -- Hover tracking timer --
SetTimer(CheckHover, 30)

myGui.OnEvent("Close", (*) => ExitApp())
myGui.Show("w600 h560")

; Apply initial state after Show
ApplyInitialState()

; ============================================================
; Initial State
; ============================================================

ApplyInitialState() {
    global myGui, prog, sb, gLVHwnd, gLVHeaderHwnd, gLVSubclassCB, gSBHwnd, gSBSubclassCB

    ; LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFERED
    SendMessage(0x1036, 0x00010020, 0x00010020, gLVHwnd)

    ; LVS_SHOWSELALWAYS - show selection even when control loses focus
    style := DllCall("GetWindowLong", "Ptr", gLVHwnd, "Int", -16, "Int")
    DllCall("SetWindowLong", "Ptr", gLVHwnd, "Int", -16, "Int", style | 0x0008)

    ; Get ListView header HWND for NM_CUSTOMDRAW via subclass
    gLVHeaderHwnd := DllCall("SendMessageW", "Ptr", gLVHwnd, "UInt", 0x101F, "Ptr", 0, "Ptr", 0, "Ptr")

    ; Subclass ListView to intercept header NM_CUSTOMDRAW
    if (gLVHeaderHwnd) {
        gLVSubclassCB := CallbackCreate(LVSubclass, , 6)
        DllCall("comctl32\SetWindowSubclass", "Ptr", gLVHwnd,
            "Ptr", gLVSubclassCB, "UPtr", 1, "Ptr", 0)
    }

    ; Status bar - subclass for full WM_PAINT control (grip removal + dark text)
    gSBHwnd := sb.Hwnd
    DllCall("uxtheme\SetWindowTheme", "Ptr", gSBHwnd, "Str", "", "Str", "")
    sbStyle := DllCall("GetWindowLong", "Ptr", gSBHwnd, "Int", -16, "Int")
    DllCall("SetWindowLong", "Ptr", gSBHwnd, "Int", -16, "Int", sbStyle & ~0x0100)  ; ~SBARS_SIZEGRIP
    gSBSubclassCB := CallbackCreate(SBSubclass, , 6)
    DllCall("comctl32\SetWindowSubclass", "Ptr", gSBHwnd,
        "Ptr", gSBSubclassCB, "UPtr", 2, "Ptr", 0)
    DllCall("InvalidateRect", "Ptr", gSBHwnd, "Ptr", 0, "Int", 1)

    ; Progress bar - strip visual styles so color messages work
    DllCall("uxtheme\SetWindowTheme", "Ptr", prog.Hwnd, "Str", "", "Str", "")
    DllCall("SendMessageW", "Ptr", prog.Hwnd, "UInt", 0x2001, "Ptr", 0, "Ptr", CLR_L_CTRL2)  ; PBM_SETBKCOLOR
    DllCall("SendMessageW", "Ptr", prog.Hwnd, "UInt", 0x0409, "Ptr", 0, "Ptr", CLR_ACCENT)    ; PBM_SETBARCOLOR
}

; ============================================================
; Toggle Theme
; ============================================================

ToggleTheme(*) {
    global gIsDark, myGui

    gIsDark := !gIsDark

    ; Update SetPreferredAppMode (dark menus, context menus - FREE)
    DllCall(_UxOrd(135), "Int", gIsDark ? 2 : 3, "Int")  ; ForceDark / ForceLight
    DllCall(_UxOrd(136))  ; FlushMenuThemes

    if (gIsDark) {
        myGui.BackColor := S_D_BG
        myGui.Title := "Dark Controls Demo [DARK]"
        myGui["ModeLabel"].Text := "Current: Dark Mode"
        toggleBtn.Text := "Switch to Light Mode"
    } else {
        myGui.BackColor := S_L_BG
        myGui.Title := "Dark Controls Demo [LIGHT]"
        myGui["ModeLabel"].Text := "Current: Light Mode"
        toggleBtn.Text := "Switch to Dark Mode"
    }

    ; Dark title bar
    SetDarkTitleBar(myGui.Hwnd, gIsDark)

    ; AllowDarkModeForWindow on main window
    DllCall(_UxOrd(133), "Ptr", myGui.Hwnd, "Int", gIsDark)

    ; GroupBox - strip visual styles so WM_CTLCOLORBTN controls text color
    for vName in ["Group1", "Group2"] {
        if (gIsDark)
            DllCall("uxtheme\SetWindowTheme", "Ptr", myGui[vName].Hwnd, "Str", "", "Str", "")
        else
            DllCall("uxtheme\SetWindowTheme", "Ptr", myGui[vName].Hwnd, "Ptr", 0, "Ptr", 0)
    }

    ; Edit controls - DarkMode_CFD
    for vName in ["NameEdit", "EmailEdit", "NumEdit", "TabEdit1"]
        ApplyTheme(myGui[vName].Hwnd, gIsDark, "DarkMode_CFD")

    ; UpDown - DarkMode_Explorer
    ApplyTheme(myGui["NumUpDown"].Hwnd, gIsDark, "DarkMode_Explorer")

    ; DDL - AllowDarkModeForWindow + DarkMode_CFD
    DllCall(_UxOrd(133), "Ptr", myGui["DDL"].Hwnd, "Int", gIsDark)
    ApplyTheme(myGui["DDL"].Hwnd, gIsDark, "DarkMode_CFD")

    ; Checkboxes + Radios - strip visual styles in dark mode (same fix as GroupBox).
    ; DarkMode_Explorer + AllowDarkModeForWindow + SetFont all fail to change text color.
    ; Classic renderer respects WM_CTLCOLORSTATIC for text color.
    ; Trade-off: check/radio indicator uses system colors (light fill) in dark mode.
    for vName in ["CB1", "CB2", "Rad1", "Rad2"] {
        if (gIsDark)
            DllCall("uxtheme\SetWindowTheme", "Ptr", myGui[vName].Hwnd, "Str", "", "Str", "")
        else
            DllCall("uxtheme\SetWindowTheme", "Ptr", myGui[vName].Hwnd, "Ptr", 0, "Ptr", 0)
    }

    ; Tab control - AllowDarkModeForWindow + DarkMode_Explorer + SetFont
    DllCall(_UxOrd(133), "Ptr", myGui["TabCtrl"].Hwnd, "Int", gIsDark)
    ApplyTheme(myGui["TabCtrl"].Hwnd, gIsDark, "DarkMode_Explorer")
    myGui["TabCtrl"].SetFont("c" (gIsDark ? S_D_TEXT : S_L_TEXT))

    ; Button - AllowDarkModeForWindow + DarkMode_Explorer (hover color is theme-controlled)
    toggleBtn.Opt(gIsDark ? "+Background" S_D_CTRL : "+BackgroundDefault")
    DllCall(_UxOrd(133), "Ptr", toggleBtn.Hwnd, "Int", gIsDark)
    ApplyTheme(toggleBtn.Hwnd, gIsDark, "DarkMode_Explorer")

    ; Slider - DarkMode_Explorer
    ApplyTheme(myGui["Slider"].Hwnd, gIsDark, "DarkMode_Explorer")

    ; StatusBar - subclass handles all painting (DarkMode_Explorer unreliable)
    SB_SetText(gIsDark ? " Ready - Dark Mode" : " Ready - Light Mode")

    ; ListView - DarkMode_Explorer + explicit row colors
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

    ; ListView header - AllowDarkModeForWindow + DarkMode_Explorer
    if (gLVHeaderHwnd) {
        DllCall(_UxOrd(133), "Ptr", gLVHeaderHwnd, "Int", gIsDark)
        ApplyTheme(gLVHeaderHwnd, gIsDark, "DarkMode_Explorer")
    }

    ; Progress bar - visual styles already stripped, just update colors
    DllCall("SendMessageW", "Ptr", myGui["Progress"].Hwnd, "UInt", 0x2001, "Ptr", 0,
        "Ptr", gIsDark ? CLR_D_CTRL : CLR_L_CTRL2)   ; PBM_SETBKCOLOR
    DllCall("SendMessageW", "Ptr", myGui["Progress"].Hwnd, "UInt", 0x0409, "Ptr", 0,
        "Ptr", CLR_ACCENT)                             ; PBM_SETBARCOLOR

    ; Force full redraw INCLUDING all child controls
    ; RDW_INVALIDATE(0x01) | RDW_ERASE(0x04) | RDW_ALLCHILDREN(0x80) | RDW_UPDATENOW(0x100)
    DllCall("RedrawWindow", "Ptr", myGui.Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x185)
    ForceRedrawTitleBar(myGui.Hwnd)
}

; ============================================================
; WM_CTLCOLOR Handlers
; ============================================================
; CRITICAL: return valid brushes for BOTH dark and light modes.
; Returning 0 = NULL brush = no background painting (broken).

WM_CTLCOLOREDIT(wParam, lParam, msg, hwnd) {
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

WM_CTLCOLORLISTBOX(wParam, lParam, msg, hwnd) {
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

WM_CTLCOLORSTATIC(wParam, lParam, msg, hwnd) {
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

; GroupBox is a BUTTON class (BS_GROUPBOX) - sends WM_CTLCOLORBTN, NOT WM_CTLCOLORSTATIC.
; Visual styles must be stripped for this to take effect (theme engine ignores it).
WM_CTLCOLORBTN(wParam, lParam, msg, hwnd) {
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
; WM_NOTIFY - NM_CUSTOMDRAW for ListView
; ============================================================
; NM_CUSTOMDRAW lets us control selection/hover colors WITHOUT owner-draw.
; This is the same technique as the owner-draw mock's OD_DrawListView.

OnNotify(wParam, lParam, msg, hwnd) {
    global gLVHwnd, gSliderHwnd
    code := NumGet(lParam, 16, "Int")
    hwndFrom := NumGet(lParam, 0, "Ptr")

    if (code = -12) {  ; NM_CUSTOMDRAW
        if (hwndFrom = gSliderHwnd)
            return DrawSlider(lParam)
        if (hwndFrom = gLVHwnd)
            return DrawListView(lParam)
    }

    if (code = -108 && hwndFrom = gLVHwnd)  ; LVN_COLUMNCLICK
        OnColumnClick(lParam)

    ; Force repaint on focus change (selected+focused vs selected+unfocused colors)
    if ((code = -7 || code = -8) && hwndFrom = gLVHwnd)  ; NM_SETFOCUS / NM_KILLFOCUS
        DllCall("InvalidateRect", "Ptr", gLVHwnd, "Ptr", 0, "Int", 1)
}

; -- Slider Custom Draw (channel + thumb with state-aware colors) --
; NM_CUSTOMDRAW is NOT owner-draw - it's a notification, same as ListView.
; Thumb states detected via uItemState: CDIS_HOT(0x40)=hover, CDIS_SELECTED(0x01)=grabbed
DrawSlider(lParam) {
    global gIsDark, gSliderHwnd, gDpiScale
    stage := NumGet(lParam, 24, "UInt")

    if (stage = 0x01)  ; CDDS_PREPAINT
        return 0x20    ; CDRF_NOTIFYITEMDRAW

    if (stage != 0x10001)  ; CDDS_ITEMPREPAINT
        return 0

    hdc  := NumGet(lParam, 32, "Ptr")
    left := NumGet(lParam, 40, "Int"), top := NumGet(lParam, 44, "Int")
    right := NumGet(lParam, 48, "Int"), bottom := NumGet(lParam, 52, "Int")
    part := NumGet(lParam, 56, "UPtr")       ; TBCD_CHANNEL=3, TBCD_THUMB=2, TBCD_TICS=1
    itemState := NumGet(lParam, 64, "UInt")  ; CDIS_HOT=0x40, CDIS_SELECTED=0x01

    if (part = 3) {  ; TBCD_CHANNEL (gutter)
        ; Two-tone: filled portion = accent, empty = gutter
        pos := SendMessage(0x0400, 0, 0, gSliderHwnd)       ; TBM_GETPOS
        rangeMin := SendMessage(0x0401, 0, 0, gSliderHwnd)  ; TBM_GETRANGEMIN
        rangeMax := SendMessage(0x0402, 0, 0, gSliderHwnd)  ; TBM_GETRANGEMAX
        channelW := right - left
        fillW := (rangeMax > rangeMin) ? Round((pos - rangeMin) / (rangeMax - rangeMin) * channelW) : 0

        if (fillW > 0) {
            fb := DllCall("CreateSolidBrush", "UInt", CLR_ACCENT, "Ptr")
            frc := Buffer(16)
            NumPut("Int", left, "Int", top, "Int", left + fillW, "Int", bottom, frc)
            DllCall("FillRect", "Ptr", hdc, "Ptr", frc, "Ptr", fb)
            DllCall("DeleteObject", "Ptr", fb)
        }
        if (left + fillW < right) {
            gutterClr := gIsDark ? 0x4D4D4D : 0xCCCCCC
            eb := DllCall("CreateSolidBrush", "UInt", gutterClr, "Ptr")
            erc := Buffer(16)
            NumPut("Int", left + fillW, "Int", top, "Int", right, "Int", bottom, erc)
            DllCall("FillRect", "Ptr", hdc, "Ptr", erc, "Ptr", eb)
            DllCall("DeleteObject", "Ptr", eb)
        }
        return 0x04  ; CDRF_SKIPDEFAULT
    }

    if (part = 2) {  ; TBCD_THUMB
        ; State-aware colors: normal=blue, hover=RED, grabbed=GREEN (proof of control)
        if (itemState & 0x01)       ; CDIS_SELECTED (pressed/grabbed)
            thumbClr := CLR_GREEN
        else if (itemState & 0x40)  ; CDIS_HOT (hover)
            thumbClr := 0x0000FF    ; Pure red BGR
        else
            thumbClr := CLR_ACCENT  ; Normal = accent blue

        thumbBrush := DllCall("CreateSolidBrush", "UInt", thumbClr, "Ptr")
        thumbPen := DllCall("CreatePen", "Int", 0, "Int", 1, "UInt", thumbClr, "Ptr")
        old1 := DllCall("SelectObject", "Ptr", hdc, "Ptr", thumbPen, "Ptr")
        old2 := DllCall("SelectObject", "Ptr", hdc, "Ptr", thumbBrush, "Ptr")
        DllCall("Ellipse", "Ptr", hdc, "Int", left, "Int", top, "Int", right, "Int", bottom)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", old1, "Ptr")
        DllCall("SelectObject", "Ptr", hdc, "Ptr", old2, "Ptr")
        DllCall("DeleteObject", "Ptr", thumbPen), DllCall("DeleteObject", "Ptr", thumbBrush)
        return 0x04  ; CDRF_SKIPDEFAULT
    }

    return 0  ; CDRF_DODEFAULT for tics
}

; -- ListView Item Custom Draw (4 distinct states) --
; Selection colors controlled by clearing CDIS_SELECTED|CDIS_FOCUS from uItemState,
; then setting custom clrTextBk. Without clearing, theme paints its own blue highlight.
;
; Proof colors (same as owner-draw mock for comparison):
;   Normal          = theme-appropriate
;   Hover           = YELLOW
;   Selected+Focus  = GREEN
;   Selected+NoFocus = MAGENTA
DrawListView(lParam) {
    global gIsDark, gLVHwnd, gLVHotRow
    stage := NumGet(lParam, 24, "UInt")

    if (stage = 0x01)  ; CDDS_PREPAINT
        return 0x20    ; CDRF_NOTIFYITEMDRAW

    if (stage != 0x10001)  ; CDDS_ITEMPREPAINT
        return 0

    itemIdx := Integer(NumGet(lParam, 56, "UPtr"))

    ; Check actual selection state via LVM_GETITEMSTATE
    isSelected := DllCall("SendMessageW", "Ptr", gLVHwnd, "UInt", 0x102C,
        "Ptr", itemIdx, "Ptr", 0x0002, "UInt") & 0x0002  ; LVIS_SELECTED
    isHot := (itemIdx = gLVHotRow)

    if (isSelected) {
        ; Clear CDIS_SELECTED(0x01) + CDIS_FOCUS(0x10) so theme doesn't paint over us
        NumPut("UInt", NumGet(lParam, 64, "UInt") & ~0x0011, lParam, 64)

        hasFocus := (DllCall("GetFocus", "Ptr") = gLVHwnd)
        if (hasFocus) {
            NumPut("UInt", CLR_L_TEXT, lParam, 80)     ; clrText
            NumPut("UInt", CLR_GREEN, lParam, 84)      ; clrTextBk - GREEN proof
        } else {
            NumPut("UInt", CLR_L_TEXT, lParam, 80)
            NumPut("UInt", CLR_MAGENTA, lParam, 84)    ; MAGENTA proof
        }
    } else if (isHot) {
        NumPut("UInt", CLR_L_TEXT, lParam, 80)
        NumPut("UInt", CLR_YELLOW, lParam, 84)         ; YELLOW proof
    } else {
        NumPut("UInt", gIsDark ? CLR_D_TEXT : CLR_L_TEXT, lParam, 80)
        NumPut("UInt", gIsDark ? CLR_D_CTRL : CLR_L_CTRL, lParam, 84)
    }
    return 0x02  ; CDRF_NEWFONT
}

; -- ListView Header Custom Draw (via subclass) --
; Header sends NM_CUSTOMDRAW to its parent (ListView).
; Must paint ALL items - CDRF_DODEFAULT lets theme paint its own hover.
DrawHeader(lParam) {
    global gIsDark, gLVColumns, gLVHeaderHwnd, gSortCol, gSortAsc, gHdrHotItem
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
                "Ptr", count - 1, "Ptr", itemRc)  ; HDM_GETITEMRECT
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
    isHot := (itemIndex = gHdrHotItem)

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
        pts := Buffer(24, 0)
        if (gSortAsc) {
            NumPut("Int", arrowX + 4, "Int", midY - 3, pts, 0)
            NumPut("Int", arrowX,     "Int", midY + 3, pts, 8)
            NumPut("Int", arrowX + 8, "Int", midY + 3, pts, 16)
        } else {
            NumPut("Int", arrowX,     "Int", midY - 3, pts, 0)
            NumPut("Int", arrowX + 8, "Int", midY - 3, pts, 8)
            NumPut("Int", arrowX + 4, "Int", midY + 3, pts, 16)
        }
        DllCall("Polygon", "Ptr", hdc, "Ptr", pts, "Int", 3)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", old1, "Ptr")
        DllCall("SelectObject", "Ptr", hdc, "Ptr", old2, "Ptr")
        DllCall("DeleteObject", "Ptr", arrowPen)
        DllCall("DeleteObject", "Ptr", arrowBrush)
    }

    return 0x04  ; CDRF_SKIPDEFAULT
}

; -- ListView Subclass (intercepts header NM_CUSTOMDRAW) --
LVSubclass(hwnd, uMsg, wParam, lParam, uIdSubclass, dwRefData) {
    global gLVHeaderHwnd
    if (uMsg = 0x004E && gLVHeaderHwnd) {  ; WM_NOTIFY
        code := NumGet(lParam, 16, "Int")
        if (code = -12) {  ; NM_CUSTOMDRAW
            hwndFrom := NumGet(lParam, 0, "Ptr")
            if (hwndFrom = gLVHeaderHwnd)
                return DrawHeader(lParam)
        }
    }
    return DllCall("comctl32\DefSubclassProc", "Ptr", hwnd, "UInt", uMsg, "Ptr", wParam, "Ptr", lParam, "Ptr")
}

; -- Column Click (sort indicator) --
OnColumnClick(lParam) {
    global gSortCol, gSortAsc, gLVHeaderHwnd
    colIdx := NumGet(lParam, 28, "Int")  ; NMLISTVIEW.iSubItem
    if (colIdx = gSortCol)
        gSortAsc := !gSortAsc
    else {
        gSortCol := colIdx
        gSortAsc := true
    }
    DllCall("InvalidateRect", "Ptr", gLVHeaderHwnd, "Ptr", 0, "Int", 1)
}

; ============================================================
; StatusBar Subclass (full WM_PAINT - continuous border, no grip)
; ============================================================

SBSubclass(hwnd, msg, wParam, lParam, subclassId, refData) {
    global gIsDark, gSBText
    if (msg = 0x000F) {  ; WM_PAINT
        ps := Buffer(72, 0)
        hdc := DllCall("BeginPaint", "Ptr", hwnd, "Ptr", ps, "Ptr")

        clientRc := Buffer(16)
        DllCall("GetClientRect", "Ptr", hwnd, "Ptr", clientRc)

        ; Fill entire client area
        bgBrush := DllCall("CreateSolidBrush", "UInt", gIsDark ? CLR_D_BG : CLR_L_BG, "Ptr")
        DllCall("FillRect", "Ptr", hdc, "Ptr", clientRc, "Ptr", bgBrush)
        DllCall("DeleteObject", "Ptr", bgBrush)

        ; Sunken edge around entire client area (continuous, no gap)
        edgeRc := Buffer(16)
        DllCall("RtlMoveMemory", "Ptr", edgeRc, "Ptr", clientRc, "UInt", 16)
        DllCall("DrawEdge", "Ptr", hdc, "Ptr", edgeRc, "UInt", 0x000A, "UInt", 0x000F)

        ; Draw text
        hFont := DllCall("SendMessageW", "Ptr", hwnd, "UInt", 0x0031, "Ptr", 0, "Ptr", 0, "Ptr")
        if (hFont)
            DllCall("SelectObject", "Ptr", hdc, "Ptr", hFont, "Ptr")
        DllCall("SetBkMode", "Ptr", hdc, "Int", 1)
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

SB_SetText(text) {
    global gSBText, gSBHwnd
    gSBText := text
    DllCall("InvalidateRect", "Ptr", gSBHwnd, "Ptr", 0, "Int", 1)
}

; ============================================================
; Hover Tracking
; ============================================================

CheckHover() {
    global gLVHwnd, gLVHotRow, gLVHeaderHwnd, gHdrHotItem
    pt := Buffer(8, 0)
    DllCall("GetCursorPos", "Ptr", pt)
    hwndUnder := DllCall("WindowFromPoint", "Int64", NumGet(pt, 0, "Int64"), "Ptr")

    ; -- ListView row hover --
    if (gLVHwnd) {
        newHotRow := -1
        lvPt := Buffer(8, 0)
        NumPut("Int", NumGet(pt, 0, "Int"), "Int", NumGet(pt, 4, "Int"), lvPt)
        DllCall("ScreenToClient", "Ptr", gLVHwnd, "Ptr", lvPt)
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
                InvalidateLVRow(oldRow)
            if (newHotRow >= 0)
                InvalidateLVRow(newHotRow)
        }
    }

    ; -- Header item hover --
    if (gLVHeaderHwnd) {
        newHotHdr := -1
        if (hwndUnder = gLVHeaderHwnd) {
            hdrPt := Buffer(8, 0)
            NumPut("Int", NumGet(pt, 0, "Int"), "Int", NumGet(pt, 4, "Int"), hdrPt)
            DllCall("ScreenToClient", "Ptr", gLVHeaderHwnd, "Ptr", hdrPt)
            hdrHit := Buffer(16, 0)
            NumPut("Int", NumGet(hdrPt, 0, "Int"), "Int", NumGet(hdrPt, 4, "Int"), hdrHit)
            DllCall("SendMessageW", "Ptr", gLVHeaderHwnd, "UInt", 0x1206,
                "Ptr", 0, "Ptr", hdrHit)  ; HDM_HITTEST
            hitItem := NumGet(hdrHit, 12, "Int")
            flags := NumGet(hdrHit, 8, "UInt")
            if (flags & 0x06)  ; HHT_ONHEADER | HHT_ONDIVIDER
                newHotHdr := hitItem
        }
        if (newHotHdr != gHdrHotItem) {
            gHdrHotItem := newHotHdr
            DllCall("InvalidateRect", "Ptr", gLVHeaderHwnd, "Ptr", 0, "Int", 1)
        }
    }
}

InvalidateLVRow(rowIdx) {
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
