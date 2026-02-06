# Dark Mode System

## Design Decisions

- **Theme config**: `Theme` setting in config registry: `Automatic`/`Dark`/`Light`, default `Automatic`
- **Main alt-tab overlay**: EXCLUDED from dark mode system (already dark, fully configurable ARGB colors, acrylic/transparent - separate concern)
- **Debug viewer**: EXCLUDED (intentionally simple)
- **WebView2 editors**: Handled separately via CSS custom properties (already have Tokyo Night theme, just add light variable set + data-theme attribute switched by AHK via ExecuteScript)
- **Color palette**: Middle ground - base colors that derive others. Not per-element, not too simple. Expandable later.

## Windows APIs (Initialization Order Matters)

### 1. SetPreferredAppMode (BEFORE creating windows)
```ahk
; uxtheme ordinal #135 - ordinal-only export, no named export
; Mode: 0=Default, 1=AllowDark, 2=ForceDark, 3=ForceLight
_GetUxthemeOrdinal(ordinal) {
    static hMod := DllCall("GetModuleHandle", "Str", "uxtheme", "Ptr")
    return DllCall("GetProcAddress", "Ptr", hMod, "Ptr", ordinal, "Ptr")
}
DllCall(_GetUxthemeOrdinal(135), "Int", 1, "Int")  ; AllowDark
DllCall(_GetUxthemeOrdinal(136))                     ; FlushMenuThemes (#136)
```
- Affects: tray menu, all context menus, popup menus - ALL FREE
- For Automatic mode: use `AllowDark` (1) - follows system
- For explicit Dark/Light: use `ForceDark` (2) / `ForceLight` (3)
- Undocumented but stable since Win10 1903 (5+ years), used by Explorer internally

### 2. Dark Title Bar (per window)
```ahk
; DWMWA_USE_IMMERSIVE_DARK_MODE = 20 (Win10 2004+), fallback 19 (1809-1909)
; DOCUMENTED API - already exists as Win_EnableDarkTitleBar() in gui_win.ahk:204
```
- Win11 22H2+ also supports: DWMWA_BORDER_COLOR(34), DWMWA_CAPTION_COLOR(35), DWMWA_TEXT_COLOR(36)
- Border and caption colors are INDEPENDENT (can separate)

### 3. AllowDarkModeForWindow (per window, before controls)
```ahk
; uxtheme ordinal #133
DllCall(_GetUxthemeOrdinal(133), "Ptr", hwnd, "Int", true)
```

### 4. SetWindowTheme (per control, AFTER creation)
```ahk
; Theme strings differ by control type!
DllCall("uxtheme\SetWindowTheme", "Ptr", ctrlHwnd, "Str", themeName, "Ptr", 0)
; Then notify: SendMessage(0x031A, 0, 0, ctrlHwnd)  ; WM_THEMECHANGED
```

### 5. WM_CTLCOLOR* handlers (OnMessage)
```ahk
OnMessage(0x0133, WM_CTLCOLOREDIT)   ; Edit controls
OnMessage(0x0134, WM_CTLCOLORLISTBOX) ; ListBox/DDL dropdown
OnMessage(0x0138, WM_CTLCOLORSTATIC) ; Static text, checkboxes, radios
```

## Control Theme Strings
| Control | Theme String | Custom Colors |
|---------|-------------|---------------|
| Edit | `DarkMode_CFD` | WM_CTLCOLOREDIT |
| DropDownList/ComboBox | `DarkMode_CFD` | WM_CTLCOLORLISTBOX + AllowDarkModeForWindow |
| Button | `DarkMode_Explorer` | Hover = theme only |
| Checkbox | `DarkMode_Explorer` | Check fill = theme only |
| Radio | `DarkMode_Explorer` | Radio fill = theme only |
| ListView | `DarkMode_Explorer` | LVM_SETTEXTCOLOR(0x1024), LVM_SETTEXTBKCOLOR(0x1026), LVM_SETBKCOLOR(0x1001) |
| ListView Header | `DarkMode_Explorer` | Get via LVM_GETHEADER(0x101F), needs AllowDarkModeForWindow + WM_THEMECHANGED |
| Tab3 | `DarkMode_Explorer` | Tab text = theme only |
| Slider | `DarkMode_Explorer` | Gutter/handle = theme only (custom needs NM_CUSTOMDRAW) |
| Progress | N/A | PBM_SETBKCOLOR(0x2001), PBM_SETBARCOLOR(0x0409) - FULL CONTROL |
| UpDown | `DarkMode_Explorer` | Arrow colors follow theme |
| StatusBar | `DarkMode_Explorer` | SB_SETBKCOLOR(0x2001) |
| GroupBox | N/A | Font color only, border = theme |

## System Theme Detection
```ahk
; Read current theme
IsDarkMode() {
    try {
        value := RegRead("HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme")
        return (value = 0)  ; 0 = dark, 1 = light
    }
    return false
}

; React to changes - WM_SETTINGCHANGE (0x001A)
OnMessage(0x001A, OnSettingChange)
OnSettingChange(wParam, lParam, msg, hwnd) {
    if (lParam && StrGet(lParam, "UTF-16") = "ImmersiveColorSet") {
        ; Theme changed - re-read and apply
    }
}
```

## GUI Surfaces Needing Dark Mode (8 native GUIs + 52 MsgBox calls)

### Native AHK GUIs
| GUI | File | Complexity | Key Controls |
|-----|------|-----------|-------------|
| Dashboard | launcher_about.ahk:58 | COMPLEX | Text, Checkbox(3), Button(many), Link(2), GroupBox(4), Picture |
| Statistics | launcher_stats.ahk:26 | MODERATE | Text(many), GroupBox(3), Button(2), Picture |
| Config Editor Native | config_editor_native.ahk:173 | PARTIAL DARK | ListBox, Text, Edit, Checkbox, UpDown, DDL, Button - has dark bg but light controls |
| Blacklist Editor | blacklist_editor.ahk:60 | MODERATE | Tab3(3), Text, Edit(3 multi-line), Button(2) |
| First-Run Wizard | launcher_wizard.ahk:30 | SIMPLE | Text, Checkbox(5), Button(2) |
| GUI Blacklist Dialog | gui_input.ahk:584 | SIMPLE | Text(3), Button(3-4) |
| Admin Repair Dialog | launcher_main.ahk:430 | SIMPLE | Text(4), Button(3) |
| Install Mismatch Dialog | launcher_install.ahk:276 | SIMPLE | Text(3), Button(3) |

### MsgBox Calls (52 total, need ThemeMsgBox replacement)
| Pattern | Count | Files |
|---------|-------|-------|
| Error (Iconx) | ~25 | setup_utils, launcher_install, alt_tabby, launcher_shortcuts |
| Warning (Icon!) | ~8 | launcher_tray, launcher_wizard |
| Info (Iconi) | ~4 | blacklist_editor, config_editor_native |
| YesNo | ~10 | setup_utils, launcher_tray, launcher_main, launcher_install |
| YesNoCancel | ~3 | blacklist_editor, config_editor_native |
| OKCancel | ~2 | setup_utils |

### System-Managed (cannot theme directly)
- **Tooltips** (~20): Follow system dark mode. Could use SystemThemeAwareToolTip library (nperovic)
- **TrayTip**: System notification style
- **Tray Menu**: FREE with SetPreferredAppMode

## Existing Infrastructure
- `Win_EnableDarkTitleBar()` at gui_win.ahk:204 - already exists, only used for overlay
- `_GUI_AntiFlashPrepare()` at gui_antiflash.ahk:41 - parameterized bgColor (light=F0F0F0, dark=16213e)
- Config Editor Native has partial dark theming with hardcoded colors (bg dark, controls light)

## AHK v2 Syntax Pitfalls (discovered during mocking)
- `+Bold` is NOT a valid control option - use `SetFont("Bold")` before AddText, then `SetFont("Norm")` after
- `"Normal"` is NOT valid in SetFont - use `"Norm"`
- uxtheme ordinals are NOT named exports - must use `GetProcAddress` with ordinal as Ptr
- Multi-line strings with escaped quotes: use continuation sections `"(LTrim...)"` not `.=` with backtick-n (encoding issues)

## Win32 Limitations (cannot control without owner-draw)
- Checkbox check fill color
- Radio button fill color
- Button hover/highlight color
- Slider gutter and handle colors
- Tab control text color
- Edit text selection highlight color (system COLOR_HIGHLIGHT)
- DDL hover highlight color in dropdown
- GroupBox border color

## Mock Files
Located in `legacy/gui_mocks/` - standalone runnable AHK v2 demos:
- mock_dark_titlebar.ahk - DWM dark title bar + Win11 custom colors
- mock_dark_controls.ahk - All controls with theme support matrix
- mock_theme_detect.ahk - Registry + WM_SETTINGCHANGE detection
- mock_custom_msgbox.ahk - Drop-in DarkMsgBox() replacement
- mock_dark_gui_complete.ahk - Full settings GUI (needs work)
- mock_dark_tray_menu.ahk - SetPreferredAppMode vs owner-draw comparison

## WebView2 Editor Dark Mode (separate from native GUIs)
- Already uses CSS custom properties (Tokyo Night theme)
- Add light theme variable set under `:root[data-theme="light"]`
- AHK switches via `wv.ExecuteScript('document.documentElement.dataset.theme = "dark"')`
- `DefaultBackgroundColor` on WebView2 control must also swap (currently hardcoded dark ABGR)
- For Automatic mode: WebView2 supports `prefers-color-scheme` CSS media query natively

## Implementation Plan (draft)
1. Add `Theme` config entry to registry (Automatic/Dark/Light)
2. Create `src/shared/theme.ahk` - centralized theme system:
   - Base color palette (configurable in registry)
   - `Theme_Init()` - detect mode, set SetPreferredAppMode
   - `Theme_ApplyToGui(gui)` - apply dark title bar, BackColor, AllowDarkMode
   - `Theme_ApplyToControl(ctrl, type)` - per-control SetWindowTheme + colors
   - `Theme_IsDark()` - current state
   - WM_SETTINGCHANGE listener for Automatic mode
3. Create `src/shared/theme_msgbox.ahk` - ThemeMsgBox() drop-in replacement
4. Update anti-flash bgColor to use theme colors
5. Update each GUI surface to call Theme_ApplyToGui/Control
6. Update WebView2 editors to pass theme via ExecuteScript
7. Test with mock files first, then integrate
