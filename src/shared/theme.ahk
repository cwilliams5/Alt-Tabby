#Requires AutoHotkey v2.0

; ============================================================
; Theme System - Centralized Dark/Light Mode Support
; ============================================================
; Provides dark/light mode for all native AHK GUIs (excluding
; the main overlay and debug viewer). Uses Windows APIs:
;   - SetPreferredAppMode (uxtheme #135) for menus
;   - DwmSetWindowAttribute for title bars
;   - AllowDarkModeForWindow (uxtheme #133) per window
;   - SetWindowTheme per control
;   - WM_CTLCOLOR handlers for custom bg/text colors
;
; Usage:
;   Theme_Init()                        ; Once at startup, before any GUI
;   Theme_ApplyToGui(gui)               ; After Gui() constructor
;   Theme_ApplyToControl(ctrl, "Edit")  ; After each control is created
;   bgColor := Theme_GetBgColor()       ; For anti-flash
;   isDark := Theme_IsDark()            ; Query current state
;
; Multi-process: Each process calls Theme_Init() independently.
; WM_SETTINGCHANGE is broadcast by Windows to all processes.
; ============================================================

; --- Theme state ---
global gTheme_IsDark := false
global gTheme_Palette := {}
global gTheme_Initialized := false

; --- Cached GDI brushes for WM_CTLCOLOR (one per palette swap) ---
global gTheme_BrushBg := 0
global gTheme_BrushPanelBg := 0
global gTheme_BrushEditBg := 0

; --- Tracked GUIs for live re-theming ---
; Each entry: {gui: guiObj, controls: [{ctrl: ctrlObj, type: "Edit"}, ...]}
global gTheme_TrackedGuis := []

; --- WM_CTLCOLORSTATIC control classification ---
; Semantic: status dots etc. with hardcoded colors (skip text color override)
; Muted: descriptive text that uses Theme_GetMutedColor() instead of palette.text
global gTheme_SemanticHwnds := Map()
global gTheme_MutedHwnds := Map()
global gTheme_AccentHwnds := Map()       ; Link-like controls using palette.accent
global gTheme_PanelParentHwnds := Map()  ; Parent HWNDs whose children use panelBg
global gTheme_SidebarHwnds := Map()      ; ListBoxes styled as navigation sidebars (bg, no border)
global gTheme_TabSubclass := Map()        ; Tab WndProc subclasses: hwnd -> {origProc, callback}

; --- Change callbacks for GUIs with special re-theming needs ---
global gTheme_ChangeCallbacks := []

; --- uxtheme ordinal cache ---
global gTheme_fnSetPreferredAppMode := 0
global gTheme_fnFlushMenuThemes := 0
global gTheme_fnAllowDarkModeForWindow := 0

; ============================================================
; Dark/Light Palettes
; ============================================================
; Unified palette for both native AHK GUIs and WebView2 editors.
; WebView2 consumes these via Theme_GetWebViewJS() injection.

; Convert config int (0xRRGGBB) to 6-char hex string ("RRGGBB") for palette use.
_Theme_CfgHex(cfgProp) {
    global cfg
    return Format("{:06X}", cfg.%cfgProp%)
}

_Theme_MakeDarkPalette() {
    p := {}
    p.bg            := _Theme_CfgHex("Theme_DarkBg")
    p.panelBg       := _Theme_CfgHex("Theme_DarkPanelBg")
    p.tertiary      := _Theme_CfgHex("Theme_DarkTertiary")
    p.editBg        := _Theme_CfgHex("Theme_DarkEditBg")
    p.hover         := _Theme_CfgHex("Theme_DarkHover")
    p.text          := _Theme_CfgHex("Theme_DarkText")
    p.editText      := _Theme_CfgHex("Theme_DarkEditText")
    p.textSecondary := _Theme_CfgHex("Theme_DarkTextSecondary")
    p.textMuted     := _Theme_CfgHex("Theme_DarkTextMuted")
    p.accent        := _Theme_CfgHex("Theme_DarkAccent")
    p.accentHover   := _Theme_CfgHex("Theme_DarkAccentHover")
    p.accentText    := _Theme_CfgHex("Theme_DarkAccentText")
    p.border        := _Theme_CfgHex("Theme_DarkBorder")
    p.borderInput   := _Theme_CfgHex("Theme_DarkBorderInput")
    p.toggleBg      := _Theme_CfgHex("Theme_DarkToggleBg")
    p.success       := _Theme_CfgHex("Theme_DarkSuccess")
    p.warning       := _Theme_CfgHex("Theme_DarkWarning")
    p.danger        := _Theme_CfgHex("Theme_DarkDanger")
    return p
}

_Theme_MakeLightPalette() {
    p := {}
    p.bg            := _Theme_CfgHex("Theme_LightBg")
    p.panelBg       := _Theme_CfgHex("Theme_LightPanelBg")
    p.tertiary      := _Theme_CfgHex("Theme_LightTertiary")
    p.editBg        := _Theme_CfgHex("Theme_LightEditBg")
    p.hover         := _Theme_CfgHex("Theme_LightHover")
    p.text          := _Theme_CfgHex("Theme_LightText")
    p.editText      := _Theme_CfgHex("Theme_LightEditText")
    p.textSecondary := _Theme_CfgHex("Theme_LightTextSecondary")
    p.textMuted     := _Theme_CfgHex("Theme_LightTextMuted")
    p.accent        := _Theme_CfgHex("Theme_LightAccent")
    p.accentHover   := _Theme_CfgHex("Theme_LightAccentHover")
    p.accentText    := _Theme_CfgHex("Theme_LightAccentText")
    p.border        := _Theme_CfgHex("Theme_LightBorder")
    p.borderInput   := _Theme_CfgHex("Theme_LightBorderInput")
    p.toggleBg      := _Theme_CfgHex("Theme_LightToggleBg")
    p.success       := _Theme_CfgHex("Theme_LightSuccess")
    p.warning       := _Theme_CfgHex("Theme_LightWarning")
    p.danger        := _Theme_CfgHex("Theme_LightDanger")
    return p
}

; ============================================================
; Public API
; ============================================================

; Initialize theme system. Call once per process, BEFORE any Gui().
; Requires cfg.Theme_Mode to be available (ConfigLoader_Init first).
Theme_Init() {
    global gTheme_IsDark, gTheme_Palette, gTheme_Initialized
    global gTheme_fnSetPreferredAppMode, gTheme_fnFlushMenuThemes, gTheme_fnAllowDarkModeForWindow

    if (gTheme_Initialized)
        return

    ; Cache uxtheme ordinals
    gTheme_fnSetPreferredAppMode := _Theme_GetUxthemeOrdinal(135)
    gTheme_fnFlushMenuThemes := _Theme_GetUxthemeOrdinal(136)
    gTheme_fnAllowDarkModeForWindow := _Theme_GetUxthemeOrdinal(133)

    ; Determine dark/light
    gTheme_IsDark := _Theme_ShouldBeDark()

    ; Set palette
    gTheme_Palette := gTheme_IsDark ? _Theme_MakeDarkPalette() : _Theme_MakeLightPalette()

    ; Set preferred app mode for menus (BEFORE creating windows)
    _Theme_ApplyAppMode()

    ; Create GDI brushes
    _Theme_CreateBrushes()

    ; Register WM_CTLCOLOR handlers
    OnMessage(0x0133, _Theme_OnCtlColorEdit)     ; WM_CTLCOLOREDIT
    OnMessage(0x0134, _Theme_OnCtlColorListBox)   ; WM_CTLCOLORLISTBOX
    OnMessage(0x0138, _Theme_OnCtlColorStatic)    ; WM_CTLCOLORSTATIC

    ; Listen for system theme changes (Automatic mode)
    OnMessage(0x001A, _Theme_OnSettingChange)     ; WM_SETTINGCHANGE

    gTheme_Initialized := true
}

; Returns true if current theme is dark.
Theme_IsDark() {
    global gTheme_IsDark
    return gTheme_IsDark
}

; Returns background color string for anti-flash.
Theme_GetBgColor() {
    global gTheme_Palette
    return gTheme_Palette.bg
}

; Apply theme to a Gui object. Call after Gui() constructor, before Show().
; Tracks the GUI for live re-theming on WM_SETTINGCHANGE.
Theme_ApplyToGui(gui) {
    global gTheme_IsDark, gTheme_Palette, gTheme_fnAllowDarkModeForWindow
    global gTheme_TrackedGuis

    gui.BackColor := gTheme_Palette.bg

    ; Dark title bar
    if (gTheme_IsDark) {
        _Theme_SetDarkTitleBar(gui.Hwnd, true)
        ; AllowDarkModeForWindow (uxtheme #133)
        if (gTheme_fnAllowDarkModeForWindow)
            DllCall(gTheme_fnAllowDarkModeForWindow, "Ptr", gui.Hwnd, "Int", true)
    } else {
        _Theme_SetDarkTitleBar(gui.Hwnd, false)
        if (gTheme_fnAllowDarkModeForWindow)
            DllCall(gTheme_fnAllowDarkModeForWindow, "Ptr", gui.Hwnd, "Int", false)
    }

    ; Set default font color
    gui.SetFont("c" gTheme_Palette.text)

    ; Track for live re-theming
    entry := {gui: gui, controls: []}
    gTheme_TrackedGuis.Push(entry)

    ; Return entry so callers can use Theme_ApplyToControl with it
    return entry
}

; Apply theme to a single control. Call after AddXxx().
;   ctrl     - Control object returned by gui.AddXxx()
;   ctrlType - "Edit", "Button", "Checkbox", "Radio", "DDL", "ComboBox",
;              "ListBox", "ListView", "Tab", "Slider", "UpDown", "Progress",
;              "StatusBar", "GroupBox"
;   guiEntry - (optional) entry returned by Theme_ApplyToGui for tracking
Theme_ApplyToControl(ctrl, ctrlType, guiEntry := "") {
    global gTheme_IsDark, gTheme_Palette

    if (gTheme_IsDark)
        _Theme_ApplyDarkControl(ctrl, ctrlType)
    else
        _Theme_ApplyLightControl(ctrl, ctrlType)

    ; Track control for live re-theming
    if (guiEntry != "" && guiEntry.HasOwnProp("controls"))
        guiEntry.controls.Push({ctrl: ctrl, type: ctrlType})
}

; Convenience: apply theme to an array of {ctrl, type} pairs.
Theme_ApplyToControls(pairs, guiEntry := "") {
    for pair in pairs
        Theme_ApplyToControl(pair.ctrl, pair.type, guiEntry)
}

; Set themed font color on a text control. Handles light/dark mode
; and preserves semantic colors (like status dots).
Theme_SetTextColor(ctrl, color := "") {
    global gTheme_Palette
    if (color = "")
        color := gTheme_Palette.text
    ctrl.SetFont("c" color)
}

; Get the current muted/gray text color appropriate for the theme.
Theme_GetMutedColor() {
    global gTheme_Palette
    return gTheme_Palette.textMuted
}

; Get the current accent color appropriate for the theme.
Theme_GetAccentColor() {
    global gTheme_Palette
    return gTheme_Palette.accent
}

; Register a callback to be called when the theme changes.
; Useful for GUIs with child windows or special re-theming needs.
Theme_OnChange(callback) {
    global gTheme_ChangeCallbacks
    gTheme_ChangeCallbacks.Push(callback)
}

; Apply dark/light window theme to an arbitrary HWND (scrollbar, etc.).
; Use for child windows not tracked by Theme_ApplyToGui.
Theme_ApplyToWindow(hwnd) {
    global gTheme_IsDark, gTheme_fnAllowDarkModeForWindow
    if (gTheme_fnAllowDarkModeForWindow)
        DllCall(gTheme_fnAllowDarkModeForWindow, "Ptr", hwnd, "Int", gTheme_IsDark)
    themeStr := gTheme_IsDark ? "DarkMode_Explorer" : ""
    DllCall("uxtheme\SetWindowTheme", "Ptr", hwnd, "Str", themeStr, "Ptr", 0)
    SendMessage(0x031A, 0, 0, hwnd)  ; WM_THEMECHANGED
}

; Generate JavaScript to apply palette as CSS custom properties on the root element.
; Unifies WebView2 colors with the native theme palette.
; Usage: webView.ExecuteScript(Theme_GetWebViewJS())
Theme_GetWebViewJS() {
    global gTheme_Palette, gTheme_IsDark
    p := gTheme_Palette
    theme := gTheme_IsDark ? "dark" : "light"
    js := "document.documentElement.dataset.theme='" theme "';"
    js .= "var s=document.documentElement.style;"
    js .= "s.setProperty('--bg-primary','#" p.bg "');"
    js .= "s.setProperty('--bg-secondary','#" p.panelBg "');"
    js .= "s.setProperty('--bg-tertiary','#" p.tertiary "');"
    js .= "s.setProperty('--bg-input','#" p.editBg "');"
    js .= "s.setProperty('--bg-hover','#" p.hover "');"
    js .= "s.setProperty('--text-primary','#" p.text "');"
    js .= "s.setProperty('--text-secondary','#" p.textSecondary "');"
    js .= "s.setProperty('--text-muted','#" p.textMuted "');"
    js .= "s.setProperty('--text-desc','#" p.accent "');"
    js .= "s.setProperty('--accent','#" p.accent "');"
    js .= "s.setProperty('--accent-hover','#" p.accentHover "');"
    js .= "s.setProperty('--border','#" p.border "');"
    js .= "s.setProperty('--border-input','#" p.borderInput "');"
    js .= "s.setProperty('--toggle-bg','#" p.toggleBg "');"
    js .= "s.setProperty('--toggle-active','#" p.accent "');"
    js .= "s.setProperty('--btn-primary-text','#" p.accentText "');"
    js .= "s.setProperty('--success','#" p.success "');"
    js .= "s.setProperty('--warning','#" p.warning "');"
    js .= "s.setProperty('--danger','#" p.danger "');"
    return js
}

; Get ABGR uint for WebView2 DefaultBackgroundColor from palette.bg.
; COREWEBVIEW2_COLOR format: 0xAA_BB_GG_RR
Theme_GetWebViewBgColor() {
    global gTheme_Palette
    val := Integer("0x" gTheme_Palette.bg)
    rr := (val >> 16) & 0xFF
    gg := (val >> 8) & 0xFF
    bb := val & 0xFF
    return 0xFF000000 | (bb << 16) | (gg << 8) | rr
}

; Mark a GUI as using panelBg background.
; WM_CTLCOLORSTATIC will use panelBg instead of bg for its children.
Theme_MarkPanel(gui) {
    global gTheme_PanelParentHwnds
    gTheme_PanelParentHwnds[gui.Hwnd] := true
}

; Mark a static control as semantic (status dots, etc.).
; WM_CTLCOLORSTATIC will preserve its text color but fix its background.
Theme_MarkSemantic(ctrl) {
    global gTheme_SemanticHwnds
    gTheme_SemanticHwnds[ctrl.Hwnd] := true
}

; Mark a static control as muted text.
; WM_CTLCOLORSTATIC will use Theme_GetMutedColor() instead of palette.text.
Theme_MarkMuted(ctrl) {
    global gTheme_MutedHwnds
    gTheme_MutedHwnds[ctrl.Hwnd] := true
}

; Mark a static control as accent-colored (links, clickable text).
; WM_CTLCOLORSTATIC will use palette.accent instead of palette.text.
Theme_MarkAccent(ctrl) {
    global gTheme_AccentHwnds
    gTheme_AccentHwnds[ctrl.Hwnd] := true
}

; Mark a ListBox as a navigation sidebar. Removes the 3D sunken border
; and uses main bg color instead of editBg for a panel-like appearance.
Theme_MarkSidebar(ctrl) {
    global gTheme_SidebarHwnds
    gTheme_SidebarHwnds[ctrl.Hwnd] := true
    ; Remove WS_EX_CLIENTEDGE (0x200) — the 3D sunken border
    exStyle := DllCall("user32\GetWindowLongPtrW", "Ptr", ctrl.Hwnd, "Int", -20, "Ptr")
    DllCall("user32\SetWindowLongPtrW", "Ptr", ctrl.Hwnd, "Int", -20, "Ptr", exStyle & ~0x200, "Ptr")
}

; Untrack a GUI (call before Gui.Destroy() to prevent stale references).
Theme_UntrackGui(gui) {
    global gTheme_TrackedGuis, gTheme_TabSubclass
    idx := 0
    for i, entry in gTheme_TrackedGuis {
        try {
            if (entry.gui.Hwnd = gui.Hwnd) {
                ; Restore tab WndProc subclasses before destruction
                for ctrlEntry in entry.controls {
                    if (ctrlEntry.type = "Tab" && gTheme_TabSubclass.Has(ctrlEntry.ctrl.Hwnd)) {
                        sub := gTheme_TabSubclass[ctrlEntry.ctrl.Hwnd]
                        DllCall("user32\SetWindowLongPtrW", "Ptr", ctrlEntry.ctrl.Hwnd, "Int", -4, "Ptr", sub.origProc, "Ptr")
                        CallbackFree(sub.callback)
                        gTheme_TabSubclass.Delete(ctrlEntry.ctrl.Hwnd)
                    }
                }
                idx := i
                break
            }
        }
    }
    if (idx > 0)
        gTheme_TrackedGuis.RemoveAt(idx)
}

; ============================================================
; Internal: Determine dark/light
; ============================================================

_Theme_ShouldBeDark() {
    global cfg
    mode := ""
    try mode := cfg.Theme_Mode
    if (mode = "")
        mode := "Automatic"

    switch mode {
        case "Dark":
            return true
        case "Light":
            return false
        default:
            ; Automatic - follow system
            return _Theme_IsSystemDark()
    }
}

_Theme_IsSystemDark() {
    try {
        value := RegRead("HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme")
        return (value = 0)
    } catch {
        return false
    }
}

; ============================================================
; Internal: uxtheme ordinals
; ============================================================

_Theme_GetUxthemeOrdinal(ordinal) {
    static hMod := DllCall("GetModuleHandle", "Str", "uxtheme", "Ptr")
    if (!hMod)
        return 0
    return DllCall("GetProcAddress", "Ptr", hMod, "Ptr", ordinal, "Ptr")
}

; ============================================================
; Internal: SetPreferredAppMode for menus
; ============================================================

_Theme_ApplyAppMode() {
    global gTheme_fnSetPreferredAppMode, gTheme_fnFlushMenuThemes, cfg

    if (!gTheme_fnSetPreferredAppMode)
        return

    mode := ""
    try mode := cfg.Theme_Mode
    if (mode = "")
        mode := "Automatic"

    ; 0=Default, 1=AllowDark, 2=ForceDark, 3=ForceLight
    switch mode {
        case "Dark":
            DllCall(gTheme_fnSetPreferredAppMode, "Int", 2, "Int")  ; ForceDark
        case "Light":
            DllCall(gTheme_fnSetPreferredAppMode, "Int", 3, "Int")  ; ForceLight
        default:
            DllCall(gTheme_fnSetPreferredAppMode, "Int", 1, "Int")  ; AllowDark (follows system)
    }

    if (gTheme_fnFlushMenuThemes)
        DllCall(gTheme_fnFlushMenuThemes)
}

; ============================================================
; Internal: Title bar
; ============================================================

_Theme_SetDarkTitleBar(hWnd, enable) {
    buf := Buffer(4, 0)
    NumPut("Int", enable ? 1 : 0, buf, 0)
    ; DWMWA_USE_IMMERSIVE_DARK_MODE = 20 (Win10 2004+)
    try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hWnd, "Int", 20, "Ptr", buf.Ptr, "Int", 4, "Int")
    ; Fallback: attribute 19 (Win10 1809-1909)
    try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hWnd, "Int", 19, "Ptr", buf.Ptr, "Int", 4, "Int")
}

; ============================================================
; Internal: Per-control theming
; ============================================================

_Theme_ApplyDarkControl(ctrl, ctrlType) {
    global gTheme_Palette, gTheme_fnAllowDarkModeForWindow

    themeStr := ""
    switch ctrlType {
        case "Edit":
            ; DarkMode_Explorer for dark scrollbars (WM_CTLCOLOREDIT handles text/bg)
            themeStr := "DarkMode_Explorer"
        case "ComboBox":
            themeStr := "DarkMode_CFD"
        case "DDL":
            themeStr := "DarkMode_CFD"
            ; DDL dropdown needs AllowDarkModeForWindow
            if (gTheme_fnAllowDarkModeForWindow)
                DllCall(gTheme_fnAllowDarkModeForWindow, "Ptr", ctrl.Hwnd, "Int", true)
        case "ListBox":
            ; DarkMode_Explorer for dark scrollbars (WM_CTLCOLORLISTBOX handles text/bg)
            themeStr := "DarkMode_Explorer"
        case "Button", "Checkbox", "Radio", "Slider", "UpDown":
            themeStr := "DarkMode_Explorer"
        case "Tab":
            ; Tab background via SetWindowTheme; text color via WndProc subclass
            ; (install subclass via Theme_InstallTabSubclass after all UseTab calls)
            if (gTheme_fnAllowDarkModeForWindow)
                DllCall(gTheme_fnAllowDarkModeForWindow, "Ptr", ctrl.Hwnd, "Int", true)
            themeStr := "DarkMode_Explorer"
        case "ListView":
            themeStr := "DarkMode_Explorer"
            _Theme_ApplyDarkListView(ctrl)
        case "StatusBar":
            themeStr := "DarkMode_Explorer"
            ; SB_SETBKCOLOR = 0x2001
            SendMessage(0x2001, 0, _Theme_ColorToInt(gTheme_Palette.bg), ctrl.Hwnd)
        case "Progress":
            ; Progress doesn't use SetWindowTheme
            ; PBM_SETBKCOLOR = 0x2001, PBM_SETBARCOLOR = 0x0409
            SendMessage(0x2001, 0, _Theme_ColorToInt(gTheme_Palette.editBg), ctrl.Hwnd)
        case "GroupBox":
            ; GroupBox border follows theme, just set text color
            ctrl.SetFont("c" gTheme_Palette.text)
    }

    if (themeStr != "") {
        DllCall("uxtheme\SetWindowTheme", "Ptr", ctrl.Hwnd, "Str", themeStr, "Ptr", 0)
        SendMessage(0x031A, 0, 0, ctrl.Hwnd)  ; WM_THEMECHANGED
    }
}

_Theme_ApplyLightControl(ctrl, ctrlType) {
    global gTheme_Palette, gTheme_fnAllowDarkModeForWindow
    ; In light mode, reset to default theme
    switch ctrlType {
        case "Edit", "ComboBox", "ListBox":
            DllCall("uxtheme\SetWindowTheme", "Ptr", ctrl.Hwnd, "Str", "", "Ptr", 0)
            SendMessage(0x031A, 0, 0, ctrl.Hwnd)  ; WM_THEMECHANGED
        case "DDL":
            DllCall("uxtheme\SetWindowTheme", "Ptr", ctrl.Hwnd, "Str", "", "Ptr", 0)
            if (gTheme_fnAllowDarkModeForWindow)
                DllCall(gTheme_fnAllowDarkModeForWindow, "Ptr", ctrl.Hwnd, "Int", false)
            SendMessage(0x031A, 0, 0, ctrl.Hwnd)
        case "Button", "Checkbox", "Radio", "Slider", "UpDown":
            DllCall("uxtheme\SetWindowTheme", "Ptr", ctrl.Hwnd, "Str", "", "Ptr", 0)
            SendMessage(0x031A, 0, 0, ctrl.Hwnd)
        case "Tab":
            ; Tab background via SetWindowTheme; text color via WndProc subclass
            if (gTheme_fnAllowDarkModeForWindow)
                DllCall(gTheme_fnAllowDarkModeForWindow, "Ptr", ctrl.Hwnd, "Int", false)
            DllCall("uxtheme\SetWindowTheme", "Ptr", ctrl.Hwnd, "Str", "", "Ptr", 0)
            SendMessage(0x031A, 0, 0, ctrl.Hwnd)
        case "ListView":
            DllCall("uxtheme\SetWindowTheme", "Ptr", ctrl.Hwnd, "Str", "", "Ptr", 0)
            _Theme_ApplyLightListView(ctrl)
            ; Reset header
            hHeader := SendMessage(0x101F, 0, 0, ctrl.Hwnd)  ; LVM_GETHEADER
            if (hHeader) {
                if (gTheme_fnAllowDarkModeForWindow)
                    DllCall(gTheme_fnAllowDarkModeForWindow, "Ptr", hHeader, "Int", false)
                DllCall("uxtheme\SetWindowTheme", "Ptr", hHeader, "Str", "", "Ptr", 0)
                SendMessage(0x031A, 0, 0, hHeader)
            }
        case "StatusBar":
            DllCall("uxtheme\SetWindowTheme", "Ptr", ctrl.Hwnd, "Str", "", "Ptr", 0)
            SendMessage(0x031A, 0, 0, ctrl.Hwnd)
        case "GroupBox":
            ctrl.SetFont("c" gTheme_Palette.text)
    }
}

_Theme_ApplyDarkListView(ctrl) {
    global gTheme_Palette
    textColor := _Theme_ColorToInt(gTheme_Palette.editText)
    bgColor := _Theme_ColorToInt(gTheme_Palette.editBg)
    SendMessage(0x1024, 0, textColor, ctrl.Hwnd)  ; LVM_SETTEXTCOLOR
    SendMessage(0x1026, 0, bgColor, ctrl.Hwnd)     ; LVM_SETTEXTBKCOLOR
    SendMessage(0x1001, 0, bgColor, ctrl.Hwnd)     ; LVM_SETBKCOLOR

    ; Header control
    hHeader := SendMessage(0x101F, 0, 0, ctrl.Hwnd)  ; LVM_GETHEADER
    if (hHeader) {
        global gTheme_fnAllowDarkModeForWindow
        if (gTheme_fnAllowDarkModeForWindow)
            DllCall(gTheme_fnAllowDarkModeForWindow, "Ptr", hHeader, "Int", true)
        DllCall("uxtheme\SetWindowTheme", "Ptr", hHeader, "Str", "DarkMode_Explorer", "Ptr", 0)
        SendMessage(0x031A, 0, 0, hHeader)  ; WM_THEMECHANGED
    }
}

_Theme_ApplyLightListView(ctrl) {
    global gTheme_Palette
    textColor := _Theme_ColorToInt(gTheme_Palette.editText)
    bgColor := _Theme_ColorToInt(gTheme_Palette.editBg)
    SendMessage(0x1024, 0, textColor, ctrl.Hwnd)
    SendMessage(0x1026, 0, bgColor, ctrl.Hwnd)
    SendMessage(0x1001, 0, bgColor, ctrl.Hwnd)
}

; ============================================================
; Internal: WM_CTLCOLOR handlers
; ============================================================

_Theme_OnCtlColorEdit(wParam, lParam, msg, hwnd) {
    global gTheme_Initialized, gTheme_Palette, gTheme_BrushEditBg
    if (!gTheme_Initialized)
        return
    DllCall("SetBkColor", "Ptr", wParam, "UInt", _Theme_ColorToInt(gTheme_Palette.editBg))
    DllCall("SetTextColor", "Ptr", wParam, "UInt", _Theme_ColorToInt(gTheme_Palette.editText))
    return gTheme_BrushEditBg
}

_Theme_OnCtlColorListBox(wParam, lParam, msg, hwnd) {
    global gTheme_Initialized, gTheme_Palette, gTheme_BrushEditBg, gTheme_BrushBg, gTheme_BrushPanelBg
    global gTheme_SidebarHwnds
    if (!gTheme_Initialized)
        return
    ; Sidebar listboxes use panelBg (frame color) instead of edit bg
    if (gTheme_SidebarHwnds.Has(lParam)) {
        DllCall("SetBkColor", "Ptr", wParam, "UInt", _Theme_ColorToInt(gTheme_Palette.panelBg))
        DllCall("SetTextColor", "Ptr", wParam, "UInt", _Theme_ColorToInt(gTheme_Palette.text))
        return gTheme_BrushPanelBg
    }
    DllCall("SetBkColor", "Ptr", wParam, "UInt", _Theme_ColorToInt(gTheme_Palette.editBg))
    DllCall("SetTextColor", "Ptr", wParam, "UInt", _Theme_ColorToInt(gTheme_Palette.editText))
    return gTheme_BrushEditBg
}

_Theme_OnCtlColorStatic(wParam, lParam, msg, hwnd) {
    global gTheme_Initialized, gTheme_Palette, gTheme_BrushBg, gTheme_BrushPanelBg
    global gTheme_SemanticHwnds, gTheme_MutedHwnds, gTheme_AccentHwnds, gTheme_PanelParentHwnds
    if (!gTheme_Initialized)
        return

    ; Semantic controls (status dots): let AHK's built-in handler
    ; use gui.BackColor + control's SetFont color
    if (gTheme_SemanticHwnds.Has(lParam))
        return

    ; Pick bg color/brush based on parent (panel vs main)
    isPanel := gTheme_PanelParentHwnds.Has(hwnd)
    bgStr := isPanel ? gTheme_Palette.panelBg : gTheme_Palette.bg
    bgBrush := isPanel ? gTheme_BrushPanelBg : gTheme_BrushBg

    DllCall("SetBkColor", "Ptr", wParam, "UInt", _Theme_ColorToInt(bgStr))

    ; Accent controls: use accent color (links, clickable text)
    if (gTheme_AccentHwnds.Has(lParam)) {
        DllCall("SetTextColor", "Ptr", wParam, "UInt", _Theme_ColorToInt(gTheme_Palette.accent))
        return bgBrush
    }

    ; Muted controls: use muted text color
    if (gTheme_MutedHwnds.Has(lParam)) {
        DllCall("SetTextColor", "Ptr", wParam, "UInt", _Theme_ColorToInt(gTheme_Palette.textMuted))
        return bgBrush
    }

    ; Normal: use palette text color
    DllCall("SetTextColor", "Ptr", wParam, "UInt", _Theme_ColorToInt(gTheme_Palette.text))
    return bgBrush
}

; ============================================================
; Tab WndProc Subclass (text color override)
; ============================================================
; AHK v2 internally handles WM_NOTIFY/NM_CUSTOMDRAW for Tab3 controls —
; OnMessage callbacks never receive them. SetWindowTheme controls tab
; background but not text color. The only way to control tab text is to
; subclass via SetWindowLongPtrW and paint text AFTER the theme paints
; backgrounds. See legacy/gui_mocks/tab_darkmode_notes.md for details.

; Install WndProc subclass on a Tab3 control for text color override.
; MUST be called AFTER all UseTab() calls (AHK re-subclasses during tab setup).
Theme_InstallTabSubclass(tabCtrl) {
    global gTheme_TabSubclass
    hwnd := tabCtrl.Hwnd

    ; Don't install twice
    if (gTheme_TabSubclass.Has(hwnd))
        return

    origProc := DllCall("user32\GetWindowLongPtrW", "Ptr", hwnd, "Int", -4, "Ptr")
    callback := CallbackCreate(_Theme_TabWndProc, "", 4)
    DllCall("user32\SetWindowLongPtrW", "Ptr", hwnd, "Int", -4, "Ptr", callback, "Ptr")

    gTheme_TabSubclass[hwnd] := {origProc: origProc, callback: callback}
}

; WndProc for subclassed Tab controls.
; Intercepts WM_PAINT: lets original WndProc paint backgrounds/chrome via
; visual theme, then paints tab text on top with our palette color.
_Theme_TabWndProc(hWnd, uMsg, wParam, lParam) {
    global gTheme_TabSubclass, gTheme_Palette

    if (!gTheme_TabSubclass.Has(hWnd))
        return 0

    origProc := gTheme_TabSubclass[hWnd].origProc

    if (uMsg = 0x000F) {  ; WM_PAINT
        ; Let original WndProc paint backgrounds/chrome
        result := DllCall("user32\CallWindowProcW", "Ptr", origProc,
            "Ptr", hWnd, "UInt", uMsg, "Ptr", wParam, "Ptr", lParam, "Ptr")

        ; Paint tab text on top with palette color
        hdc := DllCall("user32\GetDC", "Ptr", hWnd, "Ptr")
        if (hdc) {
            tabCount := DllCall("user32\SendMessageW", "Ptr", hWnd, "UInt", 0x1304, "Ptr", 0, "Ptr", 0, "Int")

            hFont := DllCall("user32\SendMessageW", "Ptr", hWnd, "UInt", 0x0031, "Ptr", 0, "Ptr", 0, "Ptr")
            hOldFont := 0
            if (hFont)
                hOldFont := DllCall("gdi32\SelectObject", "Ptr", hdc, "Ptr", hFont, "Ptr")

            DllCall("gdi32\SetBkMode", "Ptr", hdc, "Int", 1)  ; TRANSPARENT
            DllCall("gdi32\SetTextColor", "Ptr", hdc, "UInt", _Theme_ColorToInt(gTheme_Palette.text))

            ; Static buffers — repopulated via NumPut before each use
            static tabRc := Buffer(16, 0)
            static textBuf := Buffer(512, 0)
            static tci := Buffer(A_PtrSize = 8 ? 40 : 28, 0)
            static pszOff := A_PtrSize = 8 ? 16 : 12
            static cchOff := A_PtrSize = 8 ? 24 : 16

            loop tabCount {
                idx := A_Index - 1
                DllCall("user32\SendMessageW", "Ptr", hWnd, "UInt", 0x130A, "Ptr", idx, "Ptr", tabRc.Ptr)
                NumPut("UInt", 0x0001, tci, 0)  ; TCIF_TEXT
                NumPut("Ptr", textBuf.Ptr, tci, pszOff)
                NumPut("Int", 255, tci, cchOff)
                NumPut("UShort", 0, textBuf, 0)
                DllCall("user32\SendMessageW", "Ptr", hWnd, "UInt", 0x133C, "Ptr", idx, "Ptr", tci.Ptr)
                ; DT_CENTER | DT_VCENTER | DT_SINGLELINE = 0x25
                DllCall("user32\DrawTextW", "Ptr", hdc, "Ptr", textBuf.Ptr, "Int", -1, "Ptr", tabRc.Ptr, "UInt", 0x25)
            }

            if (hOldFont)
                DllCall("gdi32\SelectObject", "Ptr", hdc, "Ptr", hOldFont)

            DllCall("user32\ReleaseDC", "Ptr", hWnd, "Ptr", hdc)
        }
        return result
    }

    return DllCall("user32\CallWindowProcW", "Ptr", origProc,
        "Ptr", hWnd, "UInt", uMsg, "Ptr", wParam, "Ptr", lParam, "Ptr")
}

; ============================================================
; Internal: WM_SETTINGCHANGE listener
; ============================================================

_Theme_OnSettingChange(wParam, lParam, msg, hwnd) {
    global gTheme_IsDark, gTheme_Palette, gTheme_Initialized, cfg
    if (!gTheme_Initialized)
        return

    ; Only react to theme changes
    if (!lParam)
        return
    try {
        setting := StrGet(lParam, "UTF-16")
        if (setting != "ImmersiveColorSet")
            return
    } catch {
        return
    }

    ; Only re-evaluate in Automatic mode
    mode := ""
    try mode := cfg.Theme_Mode
    if (mode = "")
        mode := "Automatic"
    if (mode != "Automatic")
        return

    ; Check if theme actually changed
    newIsDark := _Theme_IsSystemDark()
    if (newIsDark = gTheme_IsDark)
        return

    ; Swap theme
    gTheme_IsDark := newIsDark
    gTheme_Palette := newIsDark ? _Theme_MakeDarkPalette() : _Theme_MakeLightPalette()

    ; Update app mode for menus
    _Theme_ApplyAppMode()

    ; Recreate brushes
    _Theme_CreateBrushes()

    ; Re-theme all tracked GUIs
    _Theme_ReapplyAll()
}

; ============================================================
; Internal: Live re-theming
; ============================================================

_Theme_ReapplyAll() {
    global gTheme_TrackedGuis, gTheme_IsDark, gTheme_Palette, gTheme_fnAllowDarkModeForWindow

    ; Clean up destroyed GUIs first
    cleaned := []
    for entry in gTheme_TrackedGuis {
        try {
            _ := entry.gui.Hwnd  ; Will throw if destroyed
            cleaned.Push(entry)
        }
    }
    gTheme_TrackedGuis := cleaned

    ; Re-apply to each tracked GUI
    for entry in gTheme_TrackedGuis {
        gui := entry.gui

        ; Update GUI background
        gui.BackColor := gTheme_Palette.bg

        ; Update title bar
        _Theme_SetDarkTitleBar(gui.Hwnd, gTheme_IsDark)

        ; AllowDarkModeForWindow
        if (gTheme_fnAllowDarkModeForWindow)
            DllCall(gTheme_fnAllowDarkModeForWindow, "Ptr", gui.Hwnd, "Int", gTheme_IsDark)

        ; Update default font color
        gui.SetFont("c" gTheme_Palette.text)

        ; Re-apply to each tracked control
        for ctrlEntry in entry.controls {
            try {
                if (gTheme_IsDark)
                    _Theme_ApplyDarkControl(ctrlEntry.ctrl, ctrlEntry.type)
                else
                    _Theme_ApplyLightControl(ctrlEntry.ctrl, ctrlEntry.type)
            }
        }

        ; Force repaint (RDW_ALLCHILDREN ensures tab subclass WM_PAINT fires)
        try DllCall("user32\RedrawWindow", "Ptr", gui.Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x0585)
    }

    ; Notify registered callbacks (child GUIs, special re-theming)
    global gTheme_ChangeCallbacks
    for callback in gTheme_ChangeCallbacks {
        try callback()
    }
}

; ============================================================
; Internal: GDI brush management
; ============================================================

_Theme_CreateBrushes() {
    global gTheme_BrushBg, gTheme_BrushPanelBg, gTheme_BrushEditBg, gTheme_Palette

    ; Destroy old brushes
    if (gTheme_BrushBg)
        DllCall("DeleteObject", "Ptr", gTheme_BrushBg)
    if (gTheme_BrushPanelBg)
        DllCall("DeleteObject", "Ptr", gTheme_BrushPanelBg)
    if (gTheme_BrushEditBg)
        DllCall("DeleteObject", "Ptr", gTheme_BrushEditBg)

    ; Create new brushes
    gTheme_BrushBg := DllCall("CreateSolidBrush", "UInt", _Theme_ColorToInt(gTheme_Palette.bg), "Ptr")
    gTheme_BrushPanelBg := DllCall("CreateSolidBrush", "UInt", _Theme_ColorToInt(gTheme_Palette.panelBg), "Ptr")
    gTheme_BrushEditBg := DllCall("CreateSolidBrush", "UInt", _Theme_ColorToInt(gTheme_Palette.editBg), "Ptr")
}

; ============================================================
; Internal: Color utilities
; ============================================================

; Convert "RRGGBB" hex string to COLORREF int (0x00BBGGRR)
_Theme_ColorToInt(hexStr) {
    val := Integer("0x" hexStr)
    rr := (val >> 16) & 0xFF
    gg := (val >> 8) & 0xFF
    bb := val & 0xFF
    return (bb << 16) | (gg << 8) | rr
}
