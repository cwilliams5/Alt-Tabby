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

; --- Theme mode constants ---
global THEME_MODE_AUTO := "Automatic"
global THEME_MODE_DARK := "Dark"
global THEME_MODE_LIGHT := "Light"

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

; --- Owner-draw button tracking ---
; Map: btnHwnd -> {text, hover, isDefault, isDark}
global gTheme_ButtonMap := Map()
global gTheme_HoverTimerFn := 0

; --- uxtheme ordinal cache ---
global gTheme_fnSetPreferredAppMode := 0
global gTheme_fnFlushMenuThemes := 0
global gTheme_fnAllowDarkModeForWindow := 0

; ============================================================
; Dark/Light Palettes
; ============================================================
; Unified palette for both native AHK GUIs and WebView2 editors.
; WebView2 consumes these via Theme_GetWebViewJS() injection.

; Palette field names → config suffix mapping (field "bg" → config "Theme_DarkBg" / "Theme_LightBg").
; Adding a new color: add entry here AND in config_registry.ahk. Palette builders iterate this list.
global gThemeColorFields := [
    "bg", "panelBg", "tertiary", "editBg", "hover", "text", "editText",
    "textSecondary", "textMuted", "accent", "accentHover", "accentText",
    "border", "borderInput", "toggleBg", "success", "warning", "danger"
]

; Convert config int (0xRRGGBB) to 6-char hex string ("RRGGBB") for palette use.
_Theme_CfgHex(cfgProp) {
    global cfg
    return Format("{:06X}", cfg.%cfgProp%)
}

; Build palette object from config, using the given prefix ("Theme_Dark" or "Theme_Light").
_Theme_MakePalette(prefix) {
    global gThemeColorFields
    p := {}
    for _, field in gThemeColorFields {
        ; Config suffix = first letter uppercased + rest (bg → Bg, panelBg → PanelBg)
        suffix := StrUpper(SubStr(field, 1, 1)) SubStr(field, 2)
        p.%field% := _Theme_CfgHex(prefix suffix)
    }
    return p
}

_Theme_MakeDarkPalette() {
    return _Theme_MakePalette("Theme_Dark")
}

_Theme_MakeLightPalette() {
    return _Theme_MakePalette("Theme_Light")
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

    ; Owner-draw button support (WM_DRAWITEM)
    OnMessage(0x002B, _Theme_OnDrawItem)

    gTheme_Initialized := true
}

; Reload theme from config. Call after ConfigLoader_Init() to pick up
; changed palette colors, mode, title bar, button settings, etc.
; Safe to call at any time — no-op if theme not initialized.
Theme_Reload() {
    global gTheme_IsDark, gTheme_Palette, gTheme_Initialized
    if (!gTheme_Initialized)
        return

    ; Re-evaluate dark/light (config may have changed Theme_Mode)
    gTheme_IsDark := _Theme_ShouldBeDark()

    ; Rebuild palette from (now-refreshed) config values
    gTheme_Palette := gTheme_IsDark ? _Theme_MakeDarkPalette() : _Theme_MakeLightPalette()

    ; Update app mode for menus
    _Theme_ApplyAppMode()

    ; Recreate GDI brushes
    _Theme_CreateBrushes()

    ; Re-theme all tracked GUIs
    _Theme_ReapplyAll()
}

; Returns true if current theme is dark.
Theme_IsDark() {
    global gTheme_IsDark
    return gTheme_IsDark
}

; Returns background color string for anti-flash.
Theme_GetBgColor() {
    global gTheme_Palette, gTheme_Initialized
    if (!gTheme_Initialized)
        return "202020"
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

    ; Custom title bar colors (Win11 22H2+)
    _Theme_ApplyTitleBarColors(gui.Hwnd)

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
    global gTheme_IsDark, gTheme_Palette, cfg

    ; Owner-draw buttons when custom button colors enabled
    if (ctrlType = "Button" && cfg.Theme_CustomButtonColors)
        _Theme_RegisterOwnerDrawButton(ctrl)

    if (gTheme_IsDark)
        _Theme_ApplyDarkControl(ctrl, ctrlType)
    else
        _Theme_ApplyLightControl(ctrl, ctrlType)

    ; Track control for live re-theming
    if (guiEntry != "" && guiEntry.HasOwnProp("controls"))
        guiEntry.controls.Push({ctrl: ctrl, type: ctrlType})
}

; Get the current muted/gray text color appropriate for the theme.
Theme_GetMutedColor() {
    global gTheme_Palette, gTheme_Initialized
    if (!gTheme_Initialized)
        return "888888"
    return gTheme_Palette.textMuted
}

; Get the current accent color appropriate for the theme.
Theme_GetAccentColor() {
    global gTheme_Palette, gTheme_Initialized
    if (!gTheme_Initialized)
        return "7AA2F7"
    return gTheme_Palette.accent
}

; Create a themed modal dialog with standard boilerplate (anti-flash, margins, font, theme).
; Returns {gui, themeEntry, width} — caller adds controls, then calls Theme_ShowModalDialog().
;   title  - Window title
;   opts   - Gui options string (default: "+AlwaysOnTop +Owner")
;   width  - Dialog width in pixels (default: 488)
Theme_CreateModalDialog(title, opts := "+AlwaysOnTop +Owner", width := 488) {
    g := Gui(opts, title)
    GUI_AntiFlashPrepare(g, Theme_GetBgColor(), true)
    g.MarginX := 24
    g.MarginY := 16
    g.SetFont("s10", "Segoe UI")
    themeEntry := Theme_ApplyToGui(g)
    return {gui: g, themeEntry: themeEntry, width: width}
}

; Show a themed modal dialog and block until closed.
;   g     - Gui object (from Theme_CreateModalDialog().gui)
;   width - Dialog width (default: 488)
Theme_ShowModalDialog(g, width := 488) {
    g.Show("w" width " Center")
    GUI_AntiFlashReveal(g, true)
    WinWaitClose(g)
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
    global cfg, THEME_MODE_AUTO, THEME_MODE_DARK, THEME_MODE_LIGHT
    mode := ""
    try mode := cfg.Theme_Mode
    if (mode = "")
        mode := THEME_MODE_AUTO

    switch mode {
        case THEME_MODE_DARK:
            return true
        case THEME_MODE_LIGHT:
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
    global THEME_MODE_AUTO, THEME_MODE_DARK, THEME_MODE_LIGHT

    if (!gTheme_fnSetPreferredAppMode)
        return

    mode := ""
    try mode := cfg.Theme_Mode
    if (mode = "")
        mode := THEME_MODE_AUTO

    ; 0=Default, 1=AllowDark, 2=ForceDark, 3=ForceLight
    switch mode {
        case THEME_MODE_DARK:
            DllCall(gTheme_fnSetPreferredAppMode, "Int", 2, "Int")  ; ForceDark
        case THEME_MODE_LIGHT:
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
            SendMessage(0x2001, 0, Theme_ColorToInt(gTheme_Palette.bg), ctrl.Hwnd)
        case "Progress":
            ; Progress doesn't use SetWindowTheme
            ; PBM_SETBKCOLOR = 0x2001, PBM_SETBARCOLOR = 0x0409
            SendMessage(0x2001, 0, Theme_ColorToInt(gTheme_Palette.editBg), ctrl.Hwnd)
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
    textColor := Theme_ColorToInt(gTheme_Palette.editText)
    bgColor := Theme_ColorToInt(gTheme_Palette.editBg)
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
    textColor := Theme_ColorToInt(gTheme_Palette.editText)
    bgColor := Theme_ColorToInt(gTheme_Palette.editBg)
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
    DllCall("SetBkColor", "Ptr", wParam, "UInt", Theme_ColorToInt(gTheme_Palette.editBg))
    DllCall("SetTextColor", "Ptr", wParam, "UInt", Theme_ColorToInt(gTheme_Palette.editText))
    return gTheme_BrushEditBg
}

_Theme_OnCtlColorListBox(wParam, lParam, msg, hwnd) {
    global gTheme_Initialized, gTheme_Palette, gTheme_BrushEditBg, gTheme_BrushBg, gTheme_BrushPanelBg
    global gTheme_SidebarHwnds
    if (!gTheme_Initialized)
        return
    ; Sidebar listboxes use panelBg (frame color) instead of edit bg
    if (gTheme_SidebarHwnds.Has(lParam)) {
        DllCall("SetBkColor", "Ptr", wParam, "UInt", Theme_ColorToInt(gTheme_Palette.panelBg))
        DllCall("SetTextColor", "Ptr", wParam, "UInt", Theme_ColorToInt(gTheme_Palette.text))
        return gTheme_BrushPanelBg
    }
    DllCall("SetBkColor", "Ptr", wParam, "UInt", Theme_ColorToInt(gTheme_Palette.editBg))
    DllCall("SetTextColor", "Ptr", wParam, "UInt", Theme_ColorToInt(gTheme_Palette.editText))
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

    DllCall("SetBkColor", "Ptr", wParam, "UInt", Theme_ColorToInt(bgStr))

    ; Accent controls: use accent color (links, clickable text)
    if (gTheme_AccentHwnds.Has(lParam)) {
        DllCall("SetTextColor", "Ptr", wParam, "UInt", Theme_ColorToInt(gTheme_Palette.accent))
        return bgBrush
    }

    ; Muted controls: use muted text color
    if (gTheme_MutedHwnds.Has(lParam)) {
        DllCall("SetTextColor", "Ptr", wParam, "UInt", Theme_ColorToInt(gTheme_Palette.textMuted))
        return bgBrush
    }

    ; Normal: use palette text color
    DllCall("SetTextColor", "Ptr", wParam, "UInt", Theme_ColorToInt(gTheme_Palette.text))
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
            DllCall("gdi32\SetTextColor", "Ptr", hdc, "UInt", Theme_ColorToInt(gTheme_Palette.text))

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
    global THEME_MODE_AUTO
    mode := ""
    try mode := cfg.Theme_Mode
    if (mode = "")
        mode := THEME_MODE_AUTO
    if (mode != THEME_MODE_AUTO)
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
        _Theme_ApplyTitleBarColors(gui.Hwnd)

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

    ; Update owner-draw button dark/light state
    global gTheme_ButtonMap
    for btnHwnd, info in gTheme_ButtonMap
        info.isDark := gTheme_IsDark

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
    gTheme_BrushBg := DllCall("CreateSolidBrush", "UInt", Theme_ColorToInt(gTheme_Palette.bg), "Ptr")
    gTheme_BrushPanelBg := DllCall("CreateSolidBrush", "UInt", Theme_ColorToInt(gTheme_Palette.panelBg), "Ptr")
    gTheme_BrushEditBg := DllCall("CreateSolidBrush", "UInt", Theme_ColorToInt(gTheme_Palette.editBg), "Ptr")
}

; ============================================================
; Internal: Color utilities
; ============================================================

; Convert "RRGGBB" hex string to COLORREF int (0x00BBGGRR)
Theme_ColorToInt(hexStr) {
    val := Integer("0x" hexStr)
    rr := (val >> 16) & 0xFF
    gg := (val >> 8) & 0xFF
    bb := val & 0xFF
    return (bb << 16) | (gg << 8) | rr
}

; Convert config int (0xRRGGBB) to COLORREF int (0x00BBGGRR)
_Theme_CfgToColorRef(cfgInt) {
    rr := (cfgInt >> 16) & 0xFF
    gg := (cfgInt >> 8) & 0xFF
    bb := cfgInt & 0xFF
    return (bb << 16) | (gg << 8) | rr
}

; ============================================================
; Custom Title Bar Colors (Win11 22H2+)
; ============================================================
; DWMWA_BORDER_COLOR=34, DWMWA_CAPTION_COLOR=35, DWMWA_TEXT_COLOR=36
; Colors are COLORREF format (0x00BBGGRR). On Win10 or pre-22H2, the
; DwmSetWindowAttribute calls silently fail — no harm done.

_Theme_ApplyTitleBarColors(hWnd) {
    global cfg, gTheme_IsDark

    prefix := gTheme_IsDark ? "Theme_DarkTitleBar" : "Theme_LightTitleBar"
    static buf := Buffer(4, 0)

    ; Caption background + text (gated by CustomTitleBarColors)
    if (cfg.Theme_CustomTitleBarColors) {
        ; Caption background (DWMWA_CAPTION_COLOR = 35)
        NumPut("UInt", _Theme_CfgToColorRef(cfg.%prefix "Bg"%), buf)
        try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hWnd, "Int", 35, "Ptr", buf.Ptr, "Int", 4, "Int")

        ; Title text (DWMWA_TEXT_COLOR = 36)
        NumPut("UInt", _Theme_CfgToColorRef(cfg.%prefix "Text"%), buf)
        try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hWnd, "Int", 36, "Ptr", buf.Ptr, "Int", 4, "Int")
    }

    ; Border (gated independently by CustomTitleBarBorder)
    if (cfg.Theme_CustomTitleBarBorder) {
        ; Border (DWMWA_BORDER_COLOR = 34)
        NumPut("UInt", _Theme_CfgToColorRef(cfg.%prefix "Border"%), buf)
        try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hWnd, "Int", 34, "Ptr", buf.Ptr, "Int", 4, "Int")
    }
}

; ============================================================
; Owner-Draw Buttons
; ============================================================
; When Theme_CustomButtonColors is enabled, buttons are converted to
; BS_OWNERDRAW and painted via WM_DRAWITEM with custom hover/pressed colors.
;
; NOTE: Owner-drawn MENUS are impossible in AHK v2. The menu modal loop
; (WM_ENTERMENULOOP) sets an uninterruptible flag that blocks all OnMessage
; handlers for messages < 0x312. WM_MEASUREITEM (0x2C) and WM_DRAWITEM (0x2B)
; never fire during menu display. Use SetPreferredAppMode (uxtheme #135) for
; menu dark mode instead. For fully custom menus, use a GUI-based popup.
;
; DRAWITEMSTRUCT x64 offsets: hDC=32, rcItem=40, itemData=56
; (4-byte padding after itemState on x64)

_Theme_RegisterOwnerDrawButton(ctrl) {
    global gTheme_ButtonMap, gTheme_HoverTimerFn, gTheme_IsDark

    ; Get button text before converting to owner-draw
    btnText := ctrl.Text

    ; Check if this is a default button (BS_DEFPUSHBUTTON = 0x01)
    style := DllCall("GetWindowLong", "Ptr", ctrl.Hwnd, "Int", -16, "Int")
    isDefault := (style & 0x0F) = 0x01

    ; Convert to BS_OWNERDRAW (0x0B) — clears low nibble, sets owner-draw
    style := (style & ~0xF) | 0xB
    DllCall("SetWindowLong", "Ptr", ctrl.Hwnd, "Int", -16, "Int", style)

    ; Register in tracking map
    gTheme_ButtonMap[ctrl.Hwnd] := {
        text: btnText,
        hover: false,
        isDefault: isDefault,
        isDark: gTheme_IsDark
    }

    ; Start hover tracking timer if not already running
    if (!gTheme_HoverTimerFn) {
        gTheme_HoverTimerFn := _Theme_CheckButtonHover
        SetTimer(gTheme_HoverTimerFn, 30)  ; lint-ignore: timer-lifecycle (process-lifetime hover polling)
    }
}

; WM_DRAWITEM handler for owner-draw buttons
_Theme_OnDrawItem(wParam, lParam, msg, hwnd) {
    global gTheme_ButtonMap, gTheme_Palette, cfg

    ; Only handle buttons (ODT_BUTTON = 4)
    if (NumGet(lParam, 0, "UInt") != 4)
        return 0

    btnHwnd := NumGet(lParam, 24, "Ptr")
    if (!gTheme_ButtonMap.Has(btnHwnd))
        return 0

    btnInfo := gTheme_ButtonMap[btnHwnd]

    ; Parse DRAWITEMSTRUCT
    itemState := NumGet(lParam, 16, "UInt")
    hdc       := NumGet(lParam, 32, "Ptr")
    left      := NumGet(lParam, 40, "Int")
    top       := NumGet(lParam, 44, "Int")
    right     := NumGet(lParam, 48, "Int")
    bottom    := NumGet(lParam, 52, "Int")

    isPressed  := (itemState & 0x0001)  ; ODS_SELECTED
    isFocused  := (itemState & 0x0010)  ; ODS_FOCUS
    isHover    := btnInfo.hover

    ; Get colors from config
    prefix := btnInfo.isDark ? "Theme_DarkButton" : "Theme_LightButton"
    hoverBg   := _Theme_CfgToColorRef(cfg.%prefix "HoverBg"%)
    hoverText := _Theme_CfgToColorRef(cfg.%prefix "HoverText"%)

    ; Derive pressed color (darken hover by 20%)
    pressedBg := _Theme_DarkenColorRef(hoverBg)

    ; Normal state uses palette colors
    normalBg     := Theme_ColorToInt(gTheme_Palette.tertiary)
    normalBorder := Theme_ColorToInt(gTheme_Palette.borderInput)
    normalText   := Theme_ColorToInt(gTheme_Palette.text)
    defBorder    := hoverBg  ; Default button gets accent border

    ; Choose colors based on state
    if (isPressed) {
        bgColor     := pressedBg
        textColor   := hoverText
        borderColor := pressedBg
    } else if (isHover) {
        bgColor     := hoverBg
        textColor   := hoverText
        borderColor := hoverBg
    } else {
        bgColor     := normalBg
        textColor   := normalText
        borderColor := btnInfo.isDefault ? defBorder : normalBorder
    }

    ; Paint rounded rectangle
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

    ; Draw text
    hFont := SendMessage(0x0031, 0, 0, btnHwnd)  ; WM_GETFONT
    oldFont := 0
    if (hFont)
        oldFont := DllCall("SelectObject", "Ptr", hdc, "Ptr", hFont, "Ptr")
    DllCall("SetTextColor", "Ptr", hdc, "UInt", textColor)
    DllCall("SetBkMode", "Ptr", hdc, "Int", 1)  ; TRANSPARENT
    static rc := Buffer(16, 0)
    NumPut("Int", left, "Int", top, "Int", right, "Int", bottom, rc)
    DllCall("DrawText", "Ptr", hdc, "Str", btnInfo.text, "Int", -1,
        "Ptr", rc, "UInt", 0x25)  ; DT_CENTER | DT_VCENTER | DT_SINGLELINE
    if (oldFont)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", oldFont, "Ptr")

    ; Focus rectangle (keyboard only, not during hover/press)
    if (isFocused && !isHover && !isPressed) {
        static focusRc := Buffer(16, 0)
        NumPut("Int", left + 3, "Int", top + 3, "Int", right - 3, "Int", bottom - 3, focusRc)
        DllCall("DrawFocusRect", "Ptr", hdc, "Ptr", focusRc)
    }

    return 1
}

; Darken a COLORREF by ~20% for pressed state
_Theme_DarkenColorRef(colorRef) {
    bb := (colorRef >> 16) & 0xFF
    gg := (colorRef >> 8) & 0xFF
    rr := colorRef & 0xFF
    return (Integer(bb * 0.75) << 16) | (Integer(gg * 0.75) << 8) | Integer(rr * 0.75)
}

; Timer: poll cursor position to track button hover state
_Theme_CheckButtonHover() {
    global gTheme_ButtonMap
    if (gTheme_ButtonMap.Count = 0)
        return

    pt := Buffer(8, 0)
    DllCall("GetCursorPos", "Ptr", pt)
    hwndUnder := DllCall("WindowFromPoint",
        "Int64", NumGet(pt, 0, "Int64"), "Ptr")

    for btnHwnd, info in gTheme_ButtonMap {
        wasHover := info.hover
        info.hover := (hwndUnder = btnHwnd)
        if (wasHover != info.hover)
            DllCall("InvalidateRect", "Ptr", btnHwnd, "Ptr", 0, "Int", 1)
    }
}
