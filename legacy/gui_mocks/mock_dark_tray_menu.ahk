#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
; Mock: Dark Tray Menu
; ============================================================
; Evaluates two approaches to dark context/tray menus:
;
; APPROACH A: Undocumented uxtheme APIs (Simple - ~20 lines)
;   SetPreferredAppMode() + FlushMenuThemes()
;   - Tells Windows to render ALL menus for this process in dark mode
;   - Works on Windows 10 1903+ (build 18362)
;   - Uses ordinal-exported functions from uxtheme.dll (#135, #136, #104)
;   - These are UNDOCUMENTED and may break in future Windows updates
;   - Microsoft uses them internally (Explorer, Settings app, etc.)
;   - Has worked stable since 1903 through Win11 24H2
;
; APPROACH B: Owner-drawn menus (Complex - ~200+ lines)
;   MF_OWNERDRAW + WM_DRAWITEM/WM_MEASUREITEM
;   - Full control over menu rendering via GDI
;   - Works on ALL Windows versions
;   - Significant code complexity
;   - Must handle: text, icons, separators, highlights, checkmarks, submenus
;   - Risk of visual inconsistency with system menus
;
; VERDICT FOR ALT-TABBY:
;   Approach A is strongly recommended. The undocumented APIs have been
;   stable for 5+ years across Windows 10 and 11. Alt-Tabby already
;   requires Win10 1903+ for DWMWA_USE_IMMERSIVE_DARK_MODE. The ~20 lines
;   of code vs ~200+ lines of owner-draw is a clear win for maintenance.
;   The owner-draw approach is shown below for completeness but would be
;   over-engineering for this use case.
;
; Windows Version: Windows 10 1903+ (build 18362)
; ============================================================

; ============================================================
; APPROACH A: Undocumented uxtheme SetPreferredAppMode
; ============================================================
; This is the SIMPLE approach. ~20 lines of actual dark menu code.
;
; uxtheme.dll ordinal exports (no named exports):
;   #135 = SetPreferredAppMode(mode)
;     mode: 0=Default, 1=AllowDark, 2=ForceDark, 3=ForceLight, 4=Max
;   #136 = FlushMenuThemes()
;     Forces menu theme cache to update
;   #104 = AllowDarkModeForWindow(hwnd, allow)
;     Per-window dark mode allowance (not needed for menus)
;   #133 = AllowDarkModeForApp(allow) [DEPRECATED - use #135 instead]
;     Was used pre-1903, superseded by SetPreferredAppMode

global gDarkMenuEnabled := false
global gApproachANote := ""

; -- Approach A Functions --
; These functions are ordinal-only exports (no named export), so we
; resolve via GetProcAddress with ordinal numbers cast as Ptr.

_GetUxthemeOrdinal(ordinal) {
    static hMod := DllCall("GetModuleHandle", "Str", "uxtheme", "Ptr")
    return DllCall("GetProcAddress", "Ptr", hMod, "Ptr", ordinal, "Ptr")
}

; Enable dark mode for all menus in this process
EnableDarkMenus() {
    ; SetPreferredAppMode(2) = ForceDark (ordinal #135)
    try {
        DllCall(_GetUxthemeOrdinal(135), "Int", 2, "Int")
        ; FlushMenuThemes() forces immediate update (ordinal #136)
        DllCall(_GetUxthemeOrdinal(136))
        return true
    } catch as e {
        ; Ordinal exports may not exist on older Windows
        return false
    }
}

; Disable dark mode for menus (restore system default)
DisableDarkMenus() {
    try {
        ; SetPreferredAppMode(0) = Default (ordinal #135)
        DllCall(_GetUxthemeOrdinal(135), "Int", 0, "Int")
        DllCall(_GetUxthemeOrdinal(136))
        return true
    } catch {
        return false
    }
}

; Follow system theme for menus
AutoDarkMenus() {
    try {
        ; SetPreferredAppMode(1) = AllowDark (ordinal #135)
        DllCall(_GetUxthemeOrdinal(135), "Int", 1, "Int")
        DllCall(_GetUxthemeOrdinal(136))
        return true
    } catch {
        return false
    }
}

; ============================================================
; APPROACH B: Owner-Drawn Menu (Complex)
; ============================================================
; Shown for comparison ONLY. This is what you'd need if you wanted
; pixel-perfect control or needed to support pre-1903 Windows.
;
; The code below demonstrates the pattern but is intentionally
; simplified. A production owner-drawn menu would also need:
; - Submenu arrow rendering
; - Checkmark/radio rendering
; - Icon rendering (extracting and drawing HBITMAP)
; - Keyboard accelerator underlines
; - High-DPI scaling
; - Proper hit testing
; - Accessibility support
;
; Total production code estimate: 300-500 lines

global OD_ITEMS := Map()  ; itemID -> {text, isSeparator}
global OD_DARK_BG    := 0x2D2D2D
global OD_DARK_TEXT  := 0xE0E0E0
global OD_DARK_SEL   := 0x404040
global OD_DARK_SEP   := 0x404040
global OD_ITEM_H     := 28
global OD_SEP_H      := 9
global OD_MENU_FONT  := 0

; WM_MEASUREITEM handler for owner-drawn menus
WM_MEASUREITEM(wParam, lParam, msg, hwnd) {
    ; MEASUREITEMSTRUCT: CtlType(4) CtlID(4) itemID(4) itemWidth(4) itemHeight(4) itemData(ptr)
    ctlType := NumGet(lParam, 0, "UInt")
    if (ctlType != 3)  ; ODT_MENU = 3
        return 0

    itemID := NumGet(lParam, 8, "UInt")
    if (OD_ITEMS.Has(itemID) && OD_ITEMS[itemID].isSeparator)
        NumPut("UInt", OD_SEP_H, lParam, 16)       ; itemHeight
    else
        NumPut("UInt", OD_ITEM_H, lParam, 16)      ; itemHeight

    NumPut("UInt", 200, lParam, 12)                  ; itemWidth
    return 1
}

; WM_DRAWITEM handler for owner-drawn menus
WM_DRAWITEM(wParam, lParam, msg, hwnd) {
    ; DRAWITEMSTRUCT offsets:
    ;   0:  CtlType (4)
    ;   4:  CtlID (4)
    ;   8:  itemID (4)
    ;   12: itemAction (4)
    ;   16: itemState (4)
    ;   20: hwndItem (ptr)
    ;   20+ptr: hDC (ptr)
    ;   20+2*ptr: rcItem (RECT = 4 ints = 16 bytes)
    ;   20+2*ptr+16: itemData (ptr)

    ctlType := NumGet(lParam, 0, "UInt")
    if (ctlType != 3)  ; ODT_MENU
        return 0

    itemID := NumGet(lParam, 8, "UInt")
    itemState := NumGet(lParam, 16, "UInt")
    ptrSize := A_PtrSize

    hDC := NumGet(lParam, 20 + ptrSize, "Ptr")
    rcLeft   := NumGet(lParam, 20 + 2 * ptrSize, "Int")
    rcTop    := NumGet(lParam, 20 + 2 * ptrSize + 4, "Int")
    rcRight  := NumGet(lParam, 20 + 2 * ptrSize + 8, "Int")
    rcBottom := NumGet(lParam, 20 + 2 * ptrSize + 12, "Int")

    isSelected := (itemState & 0x0001)  ; ODS_SELECTED

    ; Fill background
    bgColor := isSelected ? OD_DARK_SEL : OD_DARK_BG
    hBrush := DllCall("CreateSolidBrush", "UInt", bgColor, "Ptr")
    rc := Buffer(16)
    NumPut("Int", rcLeft, "Int", rcTop, "Int", rcRight, "Int", rcBottom, rc)
    DllCall("FillRect", "Ptr", hDC, "Ptr", rc, "Ptr", hBrush)
    DllCall("DeleteObject", "Ptr", hBrush)

    if (!OD_ITEMS.Has(itemID))
        return 1

    item := OD_ITEMS[itemID]

    if (item.isSeparator) {
        ; Draw separator line
        sepY := rcTop + (OD_SEP_H // 2)
        hPen := DllCall("CreatePen", "Int", 0, "Int", 1, "UInt", OD_DARK_SEP, "Ptr")
        oldPen := DllCall("SelectObject", "Ptr", hDC, "Ptr", hPen, "Ptr")
        DllCall("MoveToEx", "Ptr", hDC, "Int", rcLeft + 4, "Int", sepY, "Ptr", 0)
        DllCall("LineTo", "Ptr", hDC, "Int", rcRight - 4, "Int", sepY)
        DllCall("SelectObject", "Ptr", hDC, "Ptr", oldPen)
        DllCall("DeleteObject", "Ptr", hPen)
        return 1
    }

    ; Draw text
    DllCall("SetBkMode", "Ptr", hDC, "Int", 1)  ; TRANSPARENT
    DllCall("SetTextColor", "Ptr", hDC, "UInt", OD_DARK_TEXT)

    ; Create/select font
    if (!OD_MENU_FONT) {
        OD_MENU_FONT := DllCall("CreateFont",
            "Int", -13,         ; height (negative = character height)
            "Int", 0,           ; width
            "Int", 0,           ; escapement
            "Int", 0,           ; orientation
            "Int", 400,         ; weight (FW_NORMAL)
            "UInt", 0,          ; italic
            "UInt", 0,          ; underline
            "UInt", 0,          ; strikeout
            "UInt", 1,          ; charset (DEFAULT_CHARSET)
            "UInt", 0,          ; out precision
            "UInt", 0,          ; clip precision
            "UInt", 0,          ; quality
            "UInt", 0,          ; pitch and family
            "Str", "Segoe UI",  ; face name
            "Ptr")
    }
    oldFont := DllCall("SelectObject", "Ptr", hDC, "Ptr", OD_MENU_FONT, "Ptr")

    textRc := Buffer(16)
    NumPut("Int", rcLeft + 28, "Int", rcTop, "Int", rcRight - 4, "Int", rcBottom, textRc)
    DllCall("DrawText", "Ptr", hDC, "Str", item.text, "Int", -1,
        "Ptr", textRc, "UInt", 0x0024)  ; DT_SINGLELINE | DT_VCENTER

    DllCall("SelectObject", "Ptr", hDC, "Ptr", oldFont)
    return 1
}

; Helper: Create an owner-drawn menu
CreateOwnerDrawnMenu() {
    global OD_ITEMS
    OD_ITEMS := Map()

    hMenu := DllCall("CreatePopupMenu", "Ptr")

    ; Add items with MF_OWNERDRAW flag
    AddODItem(hMenu, 1001, "Owner-Drawn Item 1")
    AddODItem(hMenu, 1002, "Owner-Drawn Item 2")
    AddODSeparator(hMenu, 1003)
    AddODItem(hMenu, 1004, "Settings...")
    AddODItem(hMenu, 1005, "About")
    AddODSeparator(hMenu, 1006)
    AddODItem(hMenu, 1007, "Exit")

    return hMenu
}

AddODItem(hMenu, id, text) {
    global OD_ITEMS
    OD_ITEMS[id] := {text: text, isSeparator: false}
    ; MF_OWNERDRAW = 0x0100
    DllCall("AppendMenu", "Ptr", hMenu, "UInt", 0x0100, "UInt", id, "Ptr", 0)
}

AddODSeparator(hMenu, id) {
    global OD_ITEMS
    OD_ITEMS[id] := {text: "", isSeparator: true}
    ; MF_OWNERDRAW | MF_SEPARATOR = 0x0100 | 0x0800
    DllCall("AppendMenu", "Ptr", hMenu, "UInt", 0x0900, "UInt", id, "Ptr", 0)
}

; ============================================================
; Demo GUI
; ============================================================

demoGui := Gui(, "Dark Tray Menu Demo")
demoGui.SetFont("s10", "Segoe UI")

demoGui.AddText("x20 y15 w460 +Wrap",
    "This demo compares two approaches to dark tray/context menus.`n"
    "Right-click the tray icon to see the current approach in action.")

; Approach A section
demoGui.AddGroupBox("x20 y60 w460 h160", "APPROACH A: SetPreferredAppMode (Recommended)")
demoGui.AddText("x35 y85 w430 +Wrap",
    "Uses undocumented uxtheme.dll ordinal exports to enable dark menus "
    "for the entire process. Microsoft's own apps use this internally.")
demoGui.AddText("x35 y130 w430 +Wrap",
    "Code: ~20 lines | Complexity: Minimal | Risk: Undocumented but stable 5+ years")

btnForceDark := demoGui.AddButton("x35 y170 w130 h30", "Force Dark")
btnForceDark.OnEvent("Click", (*) => (EnableDarkMenus(), UpdateStatus("A: Force Dark")))

btnAllowDark := demoGui.AddButton("x175 y170 w130 h30", "Follow System")
btnAllowDark.OnEvent("Click", (*) => (AutoDarkMenus(), UpdateStatus("A: Follow System")))

btnForceLight := demoGui.AddButton("x315 y170 w130 h30", "Force Light")
btnForceLight.OnEvent("Click", (*) => (DisableDarkMenus(), UpdateStatus("A: Force Light (Default)")))

; Approach B section
demoGui.AddGroupBox("x20 y230 w460 h160", "APPROACH B: Owner-Drawn Menu (For Comparison)")
demoGui.AddText("x35 y255 w430 +Wrap",
    "Full GDI owner-draw of every menu item. Complete control over "
    "rendering but requires handling text, icons, separators, hover "
    "states, checkmarks, submenus, accessibility, and high-DPI.")
demoGui.AddText("x35 y310 w430 +Wrap",
    "Code: 300-500 lines (production) | Complexity: High | Risk: Visual inconsistency")

btnODShow := demoGui.AddButton("x35 y350 w200 h30", "Show Owner-Drawn Menu")
btnODShow.OnEvent("Click", ShowOwnerDrawnMenu)

; Status
demoGui.AddGroupBox("x20 y400 w460 h70", "Current State")
demoGui.AddText("x35 y425 w430 vStatusText", "Mode: Default (system menus are light)")
demoGui.AddText("x35 y445 w430 vNoteText +Wrap cGray", "Right-click the tray icon to test Approach A")

; Code comparison
demoGui.AddGroupBox("x20 y480 w460 h170", "Code Comparison")

demoGui.SetFont("s9", "Consolas")
codeText := "; --- APPROACH A: entire implementation ---"
codeText .= "`nEnableDarkMenus() {"
codeText .= "`n    DllCall(""uxtheme\SetPreferredAppMode"", ""Int"", 2, ""Int"")"
codeText .= "`n    DllCall(""uxtheme\FlushMenuThemes"")"
codeText .= "`n}"
codeText .= "`n"
codeText .= "`n; --- APPROACH B: just the WM_DRAWITEM text portion ---"
codeText .= "`n; (+ 150 more lines for background, separators,"
codeText .= "`n;  icons, font, WM_MEASUREITEM, menu creation...)"
demoGui.AddText("x35 y505 w430 +Wrap", codeText)
demoGui.SetFont("s10", "Segoe UI")

demoGui.OnEvent("Close", (*) => ExitApp())
demoGui.Show("w500 h665")

; ============================================================
; Tray Menu Setup (Approach A is applied to this)
; ============================================================

; Build a standard AHK tray menu
SetupTrayMenu()

SetupTrayMenu() {
    tray := A_TrayMenu
    tray.Delete()

    tray.Add("Dark Tray Menu Demo", (*) => WinActivate(demoGui.Hwnd))
    tray.Default := "Dark Tray Menu Demo"
    tray.Add()

    ; Submenu to test nested dark menus
    sub := Menu()
    sub.Add("Sub Item 1", (*) => ToolTip("Sub 1"))
    sub.Add("Sub Item 2", (*) => ToolTip("Sub 2"))
    sub.Add()
    sub.Add("Sub Item 3", (*) => ToolTip("Sub 3"))
    tray.Add("Submenu Test", sub)

    tray.Add()
    tray.Add("Toggle Check", ToggleCheckItem)
    tray.Add("Disabled Item", (*) => 0)
    tray.Disable("Disabled Item")
    tray.Add()
    tray.Add("Exit", (*) => ExitApp())
}

ToggleCheckItem(*) {
    static checked := false
    checked := !checked
    if (checked)
        A_TrayMenu.Check("Toggle Check")
    else
        A_TrayMenu.Uncheck("Toggle Check")
}

; ============================================================
; Owner-Drawn Menu Display
; ============================================================

; Register WM_MEASUREITEM and WM_DRAWITEM for Approach B
OnMessage(0x002C, WM_MEASUREITEM)  ; WM_MEASUREITEM
OnMessage(0x002B, WM_DRAWITEM)     ; WM_DRAWITEM

ShowOwnerDrawnMenu(*) {
    global demoGui
    hMenu := CreateOwnerDrawnMenu()

    ; Get cursor position for menu placement
    pt := Buffer(8)
    DllCall("GetCursorPos", "Ptr", pt)
    x := NumGet(pt, 0, "Int")
    y := NumGet(pt, 4, "Int")

    ; TPM_LEFTALIGN | TPM_RETURNCMD = 0x0100
    DllCall("SetForegroundWindow", "Ptr", demoGui.Hwnd)
    cmd := DllCall("TrackPopupMenu", "Ptr", hMenu,
        "UInt", 0x0100, "Int", x, "Int", y,
        "Int", 0, "Ptr", demoGui.Hwnd, "Ptr", 0, "UInt")

    DllCall("DestroyMenu", "Ptr", hMenu)

    if (cmd) {
        global OD_ITEMS
        if (OD_ITEMS.Has(cmd))
            UpdateStatus("B: Clicked '" OD_ITEMS[cmd].text "'")
    }
}

; ============================================================
; Status Updates
; ============================================================

UpdateStatus(mode) {
    global demoGui
    demoGui["StatusText"].Text := "Mode: " mode
}
