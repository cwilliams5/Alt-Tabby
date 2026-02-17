#Requires AutoHotkey v2.0

; ============================================================
; Config Registry - Single Source of Truth for All Settings
; ============================================================
; This file contains ONLY the config registry definition.
; All config loading/saving logic is in config_loader.ahk.
;
; Entry types:
;   Section:    {type: "section", name: "Name", desc: "Short", long: "Long description"}
;   Subsection: {type: "subsection", section: "Parent", name: "Name", desc: "Description"}
;   Setting:    {s: section, k: key, g: global, t: type, default: value, d: "Description"}
;
; Setting types: "string", "int", "float", "bool", "enum"
;   Enum settings also have: options: ["val1", "val2", ...]
;
; Optional constraint fields (int/float only):
;   min/max — numeric bounds (present together or not at all)
;   fmt     — format hint: "hex" for color values (hex display, no slider)
;
; To add a new config:
; 1. Add an entry to gConfigRegistry below (with default value)
; 2. That's it! The value is automatically available as cfg.YourConfigName
; ============================================================

global gConfigRegistry := [
    ; ============================================================
    ; Alt-Tab Behavior
    ; ============================================================
    {type: "section", name: "AltTab",
     desc: "Alt-Tab Behavior",
     long: "These control the Alt-Tab overlay behavior - tweak these first!"},

    {s: "AltTab", k: "GraceMs", g: "AltTabGraceMs", t: "int", default: 150,
     min: 0, max: 2000,
     d: "Grace period before showing GUI (ms). During this time, if Alt is released, we do a quick switch without showing GUI."},

    {s: "AltTab", k: "QuickSwitchMs", g: "AltTabQuickSwitchMs", t: "int", default: 100,
     min: 0, max: 1000,
     d: "Maximum time for quick switch without showing GUI (ms). If Alt+Tab and release happen within this time, instant switch."},

    {s: "AltTab", k: "SwitchOnClick", g: "AltTabSwitchOnClick", t: "bool", default: true,
     d: "Activate window immediately when clicking a row (like Windows native). When false, clicking selects the row and activation happens when Alt is released."},

    {s: "AltTab", k: "AsyncActivationPollMs", g: "AltTabAsyncActivationPollMs", t: "int", default: 15,
     min: 10, max: 100,
     d: "Polling interval (ms) when switching to a window on a different workspace. Lower = more responsive but higher CPU."},

    {type: "subsection", section: "AltTab", name: "Bypass",
     desc: "When to let native Windows Alt-Tab handle the switch instead of Alt-Tabby"},

    {s: "AltTab", k: "BypassFullscreen", g: "AltTabBypassFullscreen", t: "bool", default: true,
     d: "Bypass Alt-Tabby when the foreground window is fullscreen (covers >=99%% of screen). Useful for games that need native Alt-Tab behavior."},

    {s: "AltTab", k: "BypassFullscreenThreshold", g: "AltTabBypassFullscreenThreshold", t: "float", default: 0.99,
     min: 0.5, max: 1.0,
     d: "Fraction of screen dimensions a window must cover to be considered fullscreen. Lower values catch borderless windowed games that don't quite fill the screen."},

    {s: "AltTab", k: "BypassFullscreenTolerancePx", g: "AltTabBypassFullscreenTolerancePx", t: "int", default: 5,
     min: 0, max: 50,
     d: "Maximum pixels from screen edge for a window to still be considered fullscreen. Increase if borderless windows are offset by more than 5px."},

    {s: "AltTab", k: "BypassProcesses", g: "AltTabBypassProcesses", t: "string", default: "",
     d: "Comma-separated list of process names to bypass (e.g., 'game.exe,vlc.exe'). When these processes are in the foreground, native Windows Alt-Tab is used instead."},

    {type: "subsection", section: "AltTab", name: "Internal Timing",
     desc: "Internal timing parameters (usually no need to change)"},

    {s: "AltTab", k: "AltLeewayMs", g: "AltTabAltLeewayMs", t: "int", default: 60,
     min: 20, max: 200,
     d: "Alt key timing tolerance window (ms). After Alt is released, Tab presses within this window are still treated as Alt+Tab. Increase for slower typing speeds."},

    {s: "AltTab", k: "MRUFreshnessMs", g: "AltTabMRUFreshnessMs", t: "int", default: 300,
     min: 50, max: 2000,
     d: "After switching windows, how long to trust local window order before accepting updates from the store (ms). Prevents the list from briefly reverting after a switch."},

    {s: "AltTab", k: "WSPollTimeoutMs", g: "AltTabWSPollTimeoutMs", t: "int", default: 200,
     min: 50, max: 2000,
     d: "Timeout when polling for workspace switch completion (ms). Used during cross-workspace activation."},

    {s: "AltTab", k: "TabDecisionMs", g: "AltTabTabDecisionMs", t: "int", default: 24,
     min: 15, max: 100,
     d: "Tab decision window (ms). When Tab is pressed, we wait this long before committing to show the overlay. Allows detecting rapid Tab releases. Lower = more responsive but may cause accidental triggers."},

    {s: "AltTab", k: "WorkspaceSwitchSettleMs", g: "AltTabWorkspaceSwitchSettleMs", t: "int", default: 75,
     min: 0, max: 500,
     d: "Wait time after workspace switch (ms). When activating a window on a different komorebi workspace, we wait this long for the workspace to stabilize before activating the window. Increase if windows fail to activate on slow systems."},

    ; ============================================================
    ; Launcher Settings
    ; ============================================================
    {type: "section", name: "Launcher",
     desc: "Launcher Settings",
     long: "Settings for the main Alt-Tabby launcher process (splash screen, startup behavior)."},

    {s: "Launcher", k: "SplashScreen", g: "LauncherSplashScreen", t: "enum", default: "Image",
     options: ["Image", "Animation", "None"],
     d: "Splash screen mode. Image = static PNG logo with fade. Animation = animated WebP. None = disabled."},

    {type: "subsection", section: "Launcher", name: "Image Splash",
     desc: "Settings for static image splash screen"},

    {s: "Launcher", k: "SplashImageDurationMs", g: "LauncherSplashImageDurationMs", t: "int", default: 3000,
     min: 0, max: 10000,
     d: "Image splash screen display duration in milliseconds (includes fade time). Set to 0 for minimum."},

    {s: "Launcher", k: "SplashImageFadeMs", g: "LauncherSplashImageFadeMs", t: "int", default: 500,
     min: 0, max: 2000,
     d: "Image splash screen fade in/out duration in milliseconds."},

    {type: "subsection", section: "Launcher", name: "Animation Splash",
     desc: "Settings for animated WebP splash screen"},

    {s: "Launcher", k: "SplashAnimFadeInFixedMs", g: "LauncherSplashAnimFadeInFixedMs", t: "int", default: 0,
     min: 0, max: 5000,
     d: "Fade in duration while frozen on first frame (ms). 0 = skip fixed fade in."},

    {s: "Launcher", k: "SplashAnimFadeInAnimMs", g: "LauncherSplashAnimFadeInAnimMs", t: "int", default: 500,
     min: 0, max: 5000,
     d: "Fade in duration while animation plays (ms). 0 = skip animated fade in."},

    {s: "Launcher", k: "SplashAnimFadeOutAnimMs", g: "LauncherSplashAnimFadeOutAnimMs", t: "int", default: 500,
     min: 0, max: 5000,
     d: "Fade out duration while animation plays (ms). 0 = skip animated fade out."},

    {s: "Launcher", k: "SplashAnimFadeOutFixedMs", g: "LauncherSplashAnimFadeOutFixedMs", t: "int", default: 0,
     min: 0, max: 5000,
     d: "Fade out duration while frozen on last frame (ms). 0 = skip fixed fade out."},

    {s: "Launcher", k: "SplashAnimLoops", g: "LauncherSplashAnimLoops", t: "int", default: 1,
     min: 0, max: 100,
     d: "Number of animation loops before auto-closing. 0 = loop forever (requires manual dismiss)."},

    {s: "Launcher", k: "SplashAnimBufferFrames", g: "LauncherSplashAnimBufferFrames", t: "int", default: 24,
     min: 0, max: 500,
     d: "Streaming decode buffer size. 0 = load all frames upfront (~500MB). >0 = buffer N frames (~4MB per frame at 1280x720). Default 24 = ~88MB, 1 second buffer at 24fps."},

    {type: "subsection", section: "Launcher", name: "Editor & Debug",
     desc: "Config editor and debug menu options"},

    {s: "Launcher", k: "ForceNativeEditor", g: "LauncherForceNativeEditor", t: "bool", default: false,
     d: "Always use the native AHK config editor instead of the WebView2 version."},

    {s: "Launcher", k: "ShowTrayDebugItems", g: "LauncherShowTrayDebugItems", t: "bool", default: false,
     d: "Show the Dev menu and extra editor options in the tray menu. Useful for testing dialogs and debugging."},

    ; ============================================================
    ; Theme & Dark Mode
    ; ============================================================
    {type: "section", name: "Theme",
     desc: "Theme & Dark Mode",
     long: "Color theme for dialogs and editors. The main Alt-Tab overlay has its own color settings in GUI Appearance."},

    {s: "Theme", k: "Theme", g: "Theme_Mode", t: "enum", default: "Automatic",
     options: ["Automatic", "Dark", "Light"],
     d: "Color theme for dialogs and editors. Automatic follows the Windows system setting."},

    {type: "subsection", section: "Theme", name: "Customize Dark Mode Colors",
     desc: "Override individual colors for dark mode. Leave at defaults for the standard dark theme."},

    {s: "Theme", k: "DarkBg", g: "Theme_DarkBg", t: "int", default: 0x202020,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Main background"},
    {s: "Theme", k: "DarkPanelBg", g: "Theme_DarkPanelBg", t: "int", default: 0x2B2B2B,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Panel / secondary background"},
    {s: "Theme", k: "DarkTertiary", g: "Theme_DarkTertiary", t: "int", default: 0x333333,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Tertiary background (cards, hover zones)"},
    {s: "Theme", k: "DarkEditBg", g: "Theme_DarkEditBg", t: "int", default: 0x383838,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Edit / input background"},
    {s: "Theme", k: "DarkHover", g: "Theme_DarkHover", t: "int", default: 0x404040,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Hover highlight"},
    {s: "Theme", k: "DarkText", g: "Theme_DarkText", t: "int", default: 0xE0E0E0,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Primary text"},
    {s: "Theme", k: "DarkEditText", g: "Theme_DarkEditText", t: "int", default: 0xE0E0E0,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Edit / input text"},
    {s: "Theme", k: "DarkTextSecondary", g: "Theme_DarkTextSecondary", t: "int", default: 0xAAAAAA,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Secondary text"},
    {s: "Theme", k: "DarkTextMuted", g: "Theme_DarkTextMuted", t: "int", default: 0x888888,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Muted / disabled text"},
    {s: "Theme", k: "DarkAccent", g: "Theme_DarkAccent", t: "int", default: 0x60CDFF,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Accent / link color"},
    {s: "Theme", k: "DarkAccentHover", g: "Theme_DarkAccentHover", t: "int", default: 0x78D6FF,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Accent hover state"},
    {s: "Theme", k: "DarkAccentText", g: "Theme_DarkAccentText", t: "int", default: 0x202020,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Text on accent background"},
    {s: "Theme", k: "DarkBorder", g: "Theme_DarkBorder", t: "int", default: 0x404040,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Standard border"},
    {s: "Theme", k: "DarkBorderInput", g: "Theme_DarkBorderInput", t: "int", default: 0x505050,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Input border"},
    {s: "Theme", k: "DarkToggleBg", g: "Theme_DarkToggleBg", t: "int", default: 0x505050,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Toggle switch off state"},
    {s: "Theme", k: "DarkSuccess", g: "Theme_DarkSuccess", t: "int", default: 0x9ECE6A,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Success indicator"},
    {s: "Theme", k: "DarkWarning", g: "Theme_DarkWarning", t: "int", default: 0xE0AF68,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Warning indicator"},
    {s: "Theme", k: "DarkDanger", g: "Theme_DarkDanger", t: "int", default: 0xF7768E,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Danger indicator"},

    {type: "subsection", section: "Theme", name: "Customize Light Mode Colors",
     desc: "Override individual colors for light mode. Leave at defaults for the standard light theme."},

    {s: "Theme", k: "LightBg", g: "Theme_LightBg", t: "int", default: 0xF0F0F0,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Main background"},
    {s: "Theme", k: "LightPanelBg", g: "Theme_LightPanelBg", t: "int", default: 0xFFFFFF,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Panel / secondary background"},
    {s: "Theme", k: "LightTertiary", g: "Theme_LightTertiary", t: "int", default: 0xEBEBEB,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Tertiary background (cards, hover zones)"},
    {s: "Theme", k: "LightEditBg", g: "Theme_LightEditBg", t: "int", default: 0xFFFFFF,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Edit / input background"},
    {s: "Theme", k: "LightHover", g: "Theme_LightHover", t: "int", default: 0xE0E0E0,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Hover highlight"},
    {s: "Theme", k: "LightText", g: "Theme_LightText", t: "int", default: 0x000000,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Primary text"},
    {s: "Theme", k: "LightEditText", g: "Theme_LightEditText", t: "int", default: 0x000000,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Edit / input text"},
    {s: "Theme", k: "LightTextSecondary", g: "Theme_LightTextSecondary", t: "int", default: 0x444444,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Secondary text"},
    {s: "Theme", k: "LightTextMuted", g: "Theme_LightTextMuted", t: "int", default: 0x666666,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Muted / disabled text"},
    {s: "Theme", k: "LightAccent", g: "Theme_LightAccent", t: "int", default: 0x0066CC,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Accent / link color"},
    {s: "Theme", k: "LightAccentHover", g: "Theme_LightAccentHover", t: "int", default: 0x0055AA,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Accent hover state"},
    {s: "Theme", k: "LightAccentText", g: "Theme_LightAccentText", t: "int", default: 0xFFFFFF,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Text on accent background"},
    {s: "Theme", k: "LightBorder", g: "Theme_LightBorder", t: "int", default: 0xD0D0D0,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Standard border"},
    {s: "Theme", k: "LightBorderInput", g: "Theme_LightBorderInput", t: "int", default: 0xBBBBBB,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Input border"},
    {s: "Theme", k: "LightToggleBg", g: "Theme_LightToggleBg", t: "int", default: 0xCCCCCC,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Toggle switch off state"},
    {s: "Theme", k: "LightSuccess", g: "Theme_LightSuccess", t: "int", default: 0x2E7D32,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Success indicator"},
    {s: "Theme", k: "LightWarning", g: "Theme_LightWarning", t: "int", default: 0xE65100,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Warning indicator"},
    {s: "Theme", k: "LightDanger", g: "Theme_LightDanger", t: "int", default: 0xC62828,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Danger indicator"},

    {type: "subsection", section: "Theme", name: "Title Bar Colors (Win11)",
     desc: "Custom title bar background and text colors. Win11 22H2+ only; ignored on Win10. Disabling may require closing and reopening dialogs to fully revert."},

    {s: "Theme", k: "CustomTitleBarColors", g: "Theme_CustomTitleBarColors", t: "bool", default: false,
     d: "Enable custom title bar background and text colors on Win11. When off, Windows manages title bar colors."},
    {s: "Theme", k: "DarkTitleBarBg", g: "Theme_DarkTitleBarBg", t: "int", default: 0x202020,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Dark mode title bar background"},
    {s: "Theme", k: "DarkTitleBarText", g: "Theme_DarkTitleBarText", t: "int", default: 0xE0E0E0,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Dark mode title bar text"},
    {s: "Theme", k: "LightTitleBarBg", g: "Theme_LightTitleBarBg", t: "int", default: 0xF0F0F0,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Light mode title bar background"},
    {s: "Theme", k: "LightTitleBarText", g: "Theme_LightTitleBarText", t: "int", default: 0x000000,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Light mode title bar text"},

    {type: "subsection", section: "Theme", name: "Title Bar Border Color (Win11)",
     desc: "Custom window border color. Win11 22H2+ only; ignored on Win10. Independent of title bar colors above. Disabling may require closing and reopening dialogs to fully revert."},

    {s: "Theme", k: "CustomTitleBarBorder", g: "Theme_CustomTitleBarBorder", t: "bool", default: false,
     d: "Enable custom window border color on Win11. When off, Windows manages the border color."},
    {s: "Theme", k: "DarkTitleBarBorder", g: "Theme_DarkTitleBarBorder", t: "int", default: 0x60CDFF,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Dark mode window border color"},
    {s: "Theme", k: "LightTitleBarBorder", g: "Theme_LightTitleBarBorder", t: "int", default: 0x0066CC,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Light mode window border color"},

    {type: "subsection", section: "Theme", name: "Button Hover Colors",
     desc: "Custom accent-colored button hover. Uses owner-draw for full color control."},

    {s: "Theme", k: "CustomButtonColors", g: "Theme_CustomButtonColors", t: "bool", default: false,
     d: "Enable custom button hover/pressed colors. When off, buttons use standard Windows theme."},
    {s: "Theme", k: "DarkButtonHoverBg", g: "Theme_DarkButtonHoverBg", t: "int", default: 0x60CDFF,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Dark mode button hover background"},
    {s: "Theme", k: "DarkButtonHoverText", g: "Theme_DarkButtonHoverText", t: "int", default: 0x202020,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Dark mode button hover text"},
    {s: "Theme", k: "LightButtonHoverBg", g: "Theme_LightButtonHoverBg", t: "int", default: 0x0066CC,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Light mode button hover background"},
    {s: "Theme", k: "LightButtonHoverText", g: "Theme_LightButtonHoverText", t: "int", default: 0xFFFFFF,
     min: 0, max: 0xFFFFFF, fmt: "hex", d: "Light mode button hover text"},

    ; ============================================================
    ; GUI Appearance
    ; ============================================================
    {type: "section", name: "GUI",
     desc: "GUI Appearance",
     long: "Visual styling for the Alt-Tab overlay window."},

    {type: "subsection", section: "GUI", name: "Background Window",
     desc: "Window background and frame styling"},

    {s: "GUI", k: "AcrylicColor", g: "GUI_AcrylicColor", t: "int", default: 0x33000033,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Background tint color with alpha (0xAARRGGBB)"},

    {s: "GUI", k: "CornerRadiusPx", g: "GUI_CornerRadiusPx", t: "int", default: 18,
     min: 0, max: 100,
     d: "Window corner radius in pixels"},

    {type: "subsection", section: "GUI", name: "Size Config",
     desc: "Window and row sizing"},

    {s: "GUI", k: "ScreenWidthPct", g: "GUI_ScreenWidthPct", t: "float", default: 0.6,
     min: 0.1, max: 1.0,
     d: "GUI width as fraction of screen"},

    {s: "GUI", k: "RowsVisibleMin", g: "GUI_RowsVisibleMin", t: "int", default: 1,
     min: 1, max: 20,
     d: "Minimum visible rows"},

    {s: "GUI", k: "RowsVisibleMax", g: "GUI_RowsVisibleMax", t: "int", default: 8,
     min: 1, max: 50,
     d: "Maximum visible rows"},

    {s: "GUI", k: "RowHeight", g: "GUI_RowHeight", t: "int", default: 56,
     min: 20, max: 200,
     d: "Height of each row in pixels"},

    {s: "GUI", k: "MarginX", g: "GUI_MarginX", t: "int", default: 18,
     min: 0, max: 200,
     d: "Horizontal margin in pixels"},

    {s: "GUI", k: "MarginY", g: "GUI_MarginY", t: "int", default: 18,
     min: 0, max: 200,
     d: "Vertical margin in pixels"},

    {type: "subsection", section: "GUI", name: "Virtual List Look",
     desc: "Row and icon appearance"},

    {s: "GUI", k: "IconSize", g: "GUI_IconSize", t: "int", default: 36,
     min: 8, max: 256,
     d: "Icon size in pixels"},

    {s: "GUI", k: "IconLeftMargin", g: "GUI_IconLeftMargin", t: "int", default: 8,
     min: 0, max: 100,
     d: "Left margin before icon in pixels"},

    {s: "GUI", k: "IconTextGapPx", g: "GUI_IconTextGapPx", t: "int", default: 12,
     min: 0, max: 50,
     d: "Gap between icon and title text in pixels"},

    {s: "GUI", k: "ColumnGapPx", g: "GUI_ColumnGapPx", t: "int", default: 10,
     min: 0, max: 50,
     d: "Gap between right-side data columns in pixels"},

    {s: "GUI", k: "HeaderHeightPx", g: "GUI_HeaderHeightPx", t: "int", default: 28,
     min: 16, max: 60,
     d: "Header row height in pixels"},

    {s: "GUI", k: "RowRadius", g: "GUI_RowRadius", t: "int", default: 12,
     min: 0, max: 50,
     d: "Row corner radius in pixels"},

    {s: "GUI", k: "SelARGB", g: "GUI_SelARGB", t: "int", default: 0x662B5CAD,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Selection highlight color (ARGB)"},

    {type: "subsection", section: "GUI", name: "Selection & Scrolling",
     desc: "Selection and scroll behavior"},

    {s: "GUI", k: "ScrollKeepHighlightOnTop", g: "GUI_ScrollKeepHighlightOnTop", t: "bool", default: true,
     d: "Keep selection at top when scrolling"},

    {s: "GUI", k: "EmptyListText", g: "GUI_EmptyListText", t: "string", default: "No Windows",
     d: "Text shown when no windows available"},

    {type: "subsection", section: "GUI", name: "Tooltips",
     desc: "Feedback tooltip timing for accessibility"},

    {s: "GUI", k: "TooltipDurationMs", g: "GUI_TooltipDurationMs", t: "int", default: 2000,
     min: 500, max: 10000,
     d: "Tooltip display duration in milliseconds. Increase for accessibility."},

    {s: "GUI", k: "HoverPollIntervalMs", g: "GUI_HoverPollIntervalMs", t: "int", default: 100,
     min: 50, max: 500,
     d: "Hover state polling interval (ms). Lower = more responsive but higher CPU."},

    {type: "subsection", section: "GUI", name: "Action Buttons",
     desc: "Row action buttons shown on hover"},

    {s: "GUI", k: "ShowCloseButton", g: "GUI_ShowCloseButton", t: "bool", default: true,
     d: "Show close button on hover"},

    {s: "GUI", k: "ShowKillButton", g: "GUI_ShowKillButton", t: "bool", default: true,
     d: "Show kill button on hover"},

    {s: "GUI", k: "ShowBlacklistButton", g: "GUI_ShowBlacklistButton", t: "bool", default: true,
     d: "Show blacklist button on hover"},

    {s: "GUI", k: "ActionBtnSizePx", g: "GUI_ActionBtnSizePx", t: "int", default: 24,
     min: 12, max: 64,
     d: "Action button size in pixels"},

    {s: "GUI", k: "ActionBtnGapPx", g: "GUI_ActionBtnGapPx", t: "int", default: 6,
     min: 0, max: 50,
     d: "Gap between action buttons in pixels"},

    {s: "GUI", k: "ActionBtnRadiusPx", g: "GUI_ActionBtnRadiusPx", t: "int", default: 6,
     min: 0, max: 32,
     d: "Action button corner radius"},

    {s: "GUI", k: "ActionFontName", g: "GUI_ActionFontName", t: "string", default: "Segoe UI Symbol",
     d: "Action button font name"},

    {s: "GUI", k: "ActionFontSize", g: "GUI_ActionFontSize", t: "int", default: 18,
     min: 8, max: 48,
     d: "Action button font size"},

    {s: "GUI", k: "ActionFontWeight", g: "GUI_ActionFontWeight", t: "int", default: 700,
     min: 100, max: 900,
     d: "Action button font weight"},

    {type: "subsection", section: "GUI", name: "Close Button Styling",
     desc: "Close button appearance"},

    {s: "GUI", k: "CloseButtonBorderPx", g: "GUI_CloseButtonBorderPx", t: "int", default: 1,
     min: 0, max: 10,
     d: "Close button border width"},

    {s: "GUI", k: "CloseButtonBorderARGB", g: "GUI_CloseButtonBorderARGB", t: "int", default: 0x88FFFFFF,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Close button border color (ARGB)"},

    {s: "GUI", k: "CloseButtonBGARGB", g: "GUI_CloseButtonBGARGB", t: "int", default: 0xFF000000,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Close button background color (ARGB)"},

    {s: "GUI", k: "CloseButtonBGHoverARGB", g: "GUI_CloseButtonBGHoverARGB", t: "int", default: 0xFF888888,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Close button background color on hover (ARGB)"},

    {s: "GUI", k: "CloseButtonTextARGB", g: "GUI_CloseButtonTextARGB", t: "int", default: 0xFFFFFFFF,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Close button text color (ARGB)"},

    {s: "GUI", k: "CloseButtonTextHoverARGB", g: "GUI_CloseButtonTextHoverARGB", t: "int", default: 0xFFFF0000,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Close button text color on hover (ARGB)"},

    {s: "GUI", k: "CloseButtonGlyph", g: "GUI_CloseButtonGlyph", t: "string", default: "X",
     d: "Close button glyph character"},

    {type: "subsection", section: "GUI", name: "Kill Button Styling",
     desc: "Kill button appearance"},

    {s: "GUI", k: "KillButtonBorderPx", g: "GUI_KillButtonBorderPx", t: "int", default: 1,
     min: 0, max: 10,
     d: "Kill button border width"},

    {s: "GUI", k: "KillButtonBorderARGB", g: "GUI_KillButtonBorderARGB", t: "int", default: 0x88FFB4A5,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Kill button border color (ARGB)"},

    {s: "GUI", k: "KillButtonBGARGB", g: "GUI_KillButtonBGARGB", t: "int", default: 0xFF300000,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Kill button background color (ARGB)"},

    {s: "GUI", k: "KillButtonBGHoverARGB", g: "GUI_KillButtonBGHoverARGB", t: "int", default: 0xFFD00000,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Kill button background color on hover (ARGB)"},

    {s: "GUI", k: "KillButtonTextARGB", g: "GUI_KillButtonTextARGB", t: "int", default: 0xFFFFE8E8,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Kill button text color (ARGB)"},

    {s: "GUI", k: "KillButtonTextHoverARGB", g: "GUI_KillButtonTextHoverARGB", t: "int", default: 0xFFFFFFFF,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Kill button text color on hover (ARGB)"},

    {s: "GUI", k: "KillButtonGlyph", g: "GUI_KillButtonGlyph", t: "string", default: "K",
     d: "Kill button glyph character"},

    {type: "subsection", section: "GUI", name: "Blacklist Button Styling",
     desc: "Blacklist button appearance"},

    {s: "GUI", k: "BlacklistButtonBorderPx", g: "GUI_BlacklistButtonBorderPx", t: "int", default: 1,
     min: 0, max: 10,
     d: "Blacklist button border width"},

    {s: "GUI", k: "BlacklistButtonBorderARGB", g: "GUI_BlacklistButtonBorderARGB", t: "int", default: 0x88999999,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Blacklist button border color (ARGB)"},

    {s: "GUI", k: "BlacklistButtonBGARGB", g: "GUI_BlacklistButtonBGARGB", t: "int", default: 0xFF000000,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Blacklist button background color (ARGB)"},

    {s: "GUI", k: "BlacklistButtonBGHoverARGB", g: "GUI_BlacklistButtonBGHoverARGB", t: "int", default: 0xFF888888,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Blacklist button background color on hover (ARGB)"},

    {s: "GUI", k: "BlacklistButtonTextARGB", g: "GUI_BlacklistButtonTextARGB", t: "int", default: 0xFFFFFFFF,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Blacklist button text color (ARGB)"},

    {s: "GUI", k: "BlacklistButtonTextHoverARGB", g: "GUI_BlacklistButtonTextHoverARGB", t: "int", default: 0xFFFF0000,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Blacklist button text color on hover (ARGB)"},

    {s: "GUI", k: "BlacklistButtonGlyph", g: "GUI_BlacklistButtonGlyph", t: "string", default: "B",
     d: "Blacklist button glyph character"},

    {type: "subsection", section: "GUI", name: "Columns",
     desc: "Extra data columns (0 = hidden)"},

    {s: "GUI", k: "ShowHeader", g: "GUI_ShowHeader", t: "bool", default: true,
     d: "Show column headers"},

    {s: "GUI", k: "ColFixed2", g: "GUI_ColFixed2", t: "int", default: 70,
     min: 0, max: 500,
     d: "Column 2 width (HWND)"},

    {s: "GUI", k: "ColFixed3", g: "GUI_ColFixed3", t: "int", default: 50,
     min: 0, max: 500,
     d: "Column 3 width (PID)"},

    {s: "GUI", k: "ColFixed4", g: "GUI_ColFixed4", t: "int", default: 60,
     min: 0, max: 500,
     d: "Column 4 width (Workspace)"},

    {s: "GUI", k: "ColFixed5", g: "GUI_ColFixed5", t: "int", default: 0,
     min: 0, max: 500,
     d: "Column 5 width (0=hidden)"},

    {s: "GUI", k: "ColFixed6", g: "GUI_ColFixed6", t: "int", default: 0,
     min: 0, max: 500,
     d: "Column 6 width (0=hidden)"},

    {s: "GUI", k: "Col2Name", g: "GUI_Col2Name", t: "string", default: "HWND",
     d: "Column 2 header name"},

    {s: "GUI", k: "Col3Name", g: "GUI_Col3Name", t: "string", default: "PID",
     d: "Column 3 header name"},

    {s: "GUI", k: "Col4Name", g: "GUI_Col4Name", t: "string", default: "WS",
     d: "Column 4 header name"},

    {s: "GUI", k: "Col5Name", g: "GUI_Col5Name", t: "string", default: "",
     d: "Column 5 header name"},

    {s: "GUI", k: "Col6Name", g: "GUI_Col6Name", t: "string", default: "",
     d: "Column 6 header name"},

    {type: "subsection", section: "GUI", name: "Header Font",
     desc: "Column header text styling"},

    {s: "GUI", k: "HdrFontName", g: "GUI_HdrFontName", t: "string", default: "Segoe UI",
     d: "Header font name"},

    {s: "GUI", k: "HdrFontSize", g: "GUI_HdrFontSize", t: "int", default: 12,
     min: 6, max: 48,
     d: "Header font size"},

    {s: "GUI", k: "HdrFontWeight", g: "GUI_HdrFontWeight", t: "int", default: 600,
     min: 100, max: 900,
     d: "Header font weight"},

    {s: "GUI", k: "HdrARGB", g: "GUI_HdrARGB", t: "int", default: 0xFFD0D6DE,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Header text color (ARGB)"},

    {type: "subsection", section: "GUI", name: "Main Font",
     desc: "Window title text styling"},

    {s: "GUI", k: "MainFontName", g: "GUI_MainFontName", t: "string", default: "Segoe UI",
     d: "Main font name"},

    {s: "GUI", k: "MainFontSize", g: "GUI_MainFontSize", t: "int", default: 20,
     min: 8, max: 72,
     d: "Main font size"},

    {s: "GUI", k: "MainFontWeight", g: "GUI_MainFontWeight", t: "int", default: 400,
     min: 100, max: 900,
     d: "Main font weight"},

    {s: "GUI", k: "MainFontNameHi", g: "GUI_MainFontNameHi", t: "string", default: "Segoe UI",
     d: "Main font name when highlighted"},

    {s: "GUI", k: "MainFontSizeHi", g: "GUI_MainFontSizeHi", t: "int", default: 20,
     min: 8, max: 72,
     d: "Main font size when highlighted"},

    {s: "GUI", k: "MainFontWeightHi", g: "GUI_MainFontWeightHi", t: "int", default: 800,
     min: 100, max: 900,
     d: "Main font weight when highlighted"},

    {s: "GUI", k: "MainARGB", g: "GUI_MainARGB", t: "int", default: 0xFFF0F0F0,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Main text color (ARGB)"},

    {s: "GUI", k: "MainARGBHi", g: "GUI_MainARGBHi", t: "int", default: 0xFFF0F0F0,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Main text color when highlighted (ARGB)"},

    {type: "subsection", section: "GUI", name: "Sub Font",
     desc: "Subtitle row text styling"},

    {s: "GUI", k: "SubFontName", g: "GUI_SubFontName", t: "string", default: "Segoe UI",
     d: "Sub font name"},

    {s: "GUI", k: "SubFontSize", g: "GUI_SubFontSize", t: "int", default: 12,
     min: 6, max: 48,
     d: "Sub font size"},

    {s: "GUI", k: "SubFontWeight", g: "GUI_SubFontWeight", t: "int", default: 400,
     min: 100, max: 900,
     d: "Sub font weight"},

    {s: "GUI", k: "SubFontNameHi", g: "GUI_SubFontNameHi", t: "string", default: "Segoe UI",
     d: "Sub font name when highlighted"},

    {s: "GUI", k: "SubFontSizeHi", g: "GUI_SubFontSizeHi", t: "int", default: 12,
     min: 6, max: 48,
     d: "Sub font size when highlighted"},

    {s: "GUI", k: "SubFontWeightHi", g: "GUI_SubFontWeightHi", t: "int", default: 600,
     min: 100, max: 900,
     d: "Sub font weight when highlighted"},

    {s: "GUI", k: "SubARGB", g: "GUI_SubARGB", t: "int", default: 0xFFB5C0CE,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Sub text color (ARGB)"},

    {s: "GUI", k: "SubARGBHi", g: "GUI_SubARGBHi", t: "int", default: 0xFFB5C0CE,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Sub text color when highlighted (ARGB)"},

    {type: "subsection", section: "GUI", name: "Column Font",
     desc: "Column value text styling"},

    {s: "GUI", k: "ColFontName", g: "GUI_ColFontName", t: "string", default: "Segoe UI",
     d: "Column font name"},

    {s: "GUI", k: "ColFontSize", g: "GUI_ColFontSize", t: "int", default: 12,
     min: 6, max: 48,
     d: "Column font size"},

    {s: "GUI", k: "ColFontWeight", g: "GUI_ColFontWeight", t: "int", default: 400,
     min: 100, max: 900,
     d: "Column font weight"},

    {s: "GUI", k: "ColFontNameHi", g: "GUI_ColFontNameHi", t: "string", default: "Segoe UI",
     d: "Column font name when highlighted"},

    {s: "GUI", k: "ColFontSizeHi", g: "GUI_ColFontSizeHi", t: "int", default: 12,
     min: 6, max: 48,
     d: "Column font size when highlighted"},

    {s: "GUI", k: "ColFontWeightHi", g: "GUI_ColFontWeightHi", t: "int", default: 600,
     min: 100, max: 900,
     d: "Column font weight when highlighted"},

    {s: "GUI", k: "ColARGB", g: "GUI_ColARGB", t: "int", default: 0xFFF0F0F0,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Column text color (ARGB)"},

    {s: "GUI", k: "ColARGBHi", g: "GUI_ColARGBHi", t: "int", default: 0xFFF0F0F0,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Column text color when highlighted (ARGB)"},

    {type: "subsection", section: "GUI", name: "Scrollbar",
     desc: "Scrollbar appearance"},

    {s: "GUI", k: "ScrollBarEnabled", g: "GUI_ScrollBarEnabled", t: "bool", default: true,
     d: "Show scrollbar when content overflows"},

    {s: "GUI", k: "ScrollBarWidthPx", g: "GUI_ScrollBarWidthPx", t: "int", default: 6,
     min: 2, max: 30,
     d: "Scrollbar width in pixels"},

    {s: "GUI", k: "ScrollBarMarginRightPx", g: "GUI_ScrollBarMarginRightPx", t: "int", default: 8,
     min: 0, max: 50,
     d: "Scrollbar right margin in pixels"},

    {s: "GUI", k: "ScrollBarThumbARGB", g: "GUI_ScrollBarThumbARGB", t: "int", default: 0x88FFFFFF,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Scrollbar thumb color (ARGB)"},

    {s: "GUI", k: "ScrollBarGutterEnabled", g: "GUI_ScrollBarGutterEnabled", t: "bool", default: false,
     d: "Show scrollbar gutter background"},

    {s: "GUI", k: "ScrollBarGutterARGB", g: "GUI_ScrollBarGutterARGB", t: "int", default: 0x30000000,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Scrollbar gutter color (ARGB)"},

    {type: "subsection", section: "GUI", name: "Footer",
     desc: "Footer bar appearance"},

    {s: "GUI", k: "ShowFooter", g: "GUI_ShowFooter", t: "bool", default: true,
     d: "Show footer bar"},

    {s: "GUI", k: "FooterBorderPx", g: "GUI_FooterBorderPx", t: "int", default: 0,
     min: 0, max: 10,
     d: "Footer border width in pixels"},

    {s: "GUI", k: "FooterBorderARGB", g: "GUI_FooterBorderARGB", t: "int", default: 0x33FFFFFF,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Footer border color (ARGB)"},

    {s: "GUI", k: "FooterBGRadius", g: "GUI_FooterBGRadius", t: "int", default: 0,
     min: 0, max: 50,
     d: "Footer background corner radius"},

    {s: "GUI", k: "FooterBGARGB", g: "GUI_FooterBGARGB", t: "int", default: 0,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Footer background color (ARGB)"},

    {s: "GUI", k: "FooterTextARGB", g: "GUI_FooterTextARGB", t: "int", default: 0xFFFFFFFF,
     min: 0, max: 0xFFFFFFFF, fmt: "hex",
     d: "Footer text color (ARGB)"},

    {s: "GUI", k: "FooterFontName", g: "GUI_FooterFontName", t: "string", default: "Segoe UI",
     d: "Footer font name"},

    {s: "GUI", k: "FooterFontSize", g: "GUI_FooterFontSize", t: "int", default: 14,
     min: 6, max: 48,
     d: "Footer font size"},

    {s: "GUI", k: "FooterFontWeight", g: "GUI_FooterFontWeight", t: "int", default: 600,
     min: 100, max: 900,
     d: "Footer font weight"},

    {s: "GUI", k: "FooterHeightPx", g: "GUI_FooterHeightPx", t: "int", default: 24,
     min: 0, max: 100,
     d: "Footer height in pixels"},

    {s: "GUI", k: "FooterGapTopPx", g: "GUI_FooterGapTopPx", t: "int", default: 8,
     min: 0, max: 50,
     d: "Gap between content and footer in pixels"},

    {s: "GUI", k: "FooterPaddingX", g: "GUI_FooterPaddingX", t: "int", default: 12,
     min: 0, max: 100,
     d: "Footer horizontal padding in pixels"},

    ; ============================================================
    ; Komorebi Integration
    ; ============================================================
    {type: "section", name: "Komorebi",
     desc: "Komorebi Integration",
     long: "Settings for komorebi tiling window manager integration."},

    {s: "Komorebi", k: "CrossWorkspaceMethod", g: "KomorebiCrossWorkspaceMethod", t: "enum", default: "MimicNative",
     options: ["MimicNative", "RevealMove", "SwitchActivate"],
     d: "How Alt-Tabby activates windows on other workspaces.`n"
      . "MimicNative = directly uncloaks and activates via COM (like native Alt+Tab), letting komorebi reconcile.`n"
      . "RevealMove = uncloaks window, focuses it, then commands komorebi to move it back to its workspace.`n"
      . "SwitchActivate = commands komorebi to switch first, waits for confirmation, then activates (may flash previously focused window).`n"
      . "MimicNative and RevealMove require COM and fall back to SwitchActivate if COM fails."},

    {s: "Komorebi", k: "MimicNativeSettleMs", g: "KomorebiMimicNativeSettleMs", t: "int", default: 0,
     min: 0, max: 1000,
     d: "Milliseconds to wait after SwitchTo before returning (0 = no delay). Increase if cross-workspace activation is unreliable on slower systems."},

    {s: "Komorebi", k: "UseSocket", g: "KomorebiUseSocket", t: "bool", default: true,
     d: "Send commands directly to komorebi's named pipe instead of spawning komorebic.exe. Faster. Falls back to komorebic.exe if socket unavailable."},

    {s: "Komorebi", k: "WorkspaceConfirmationMethod", g: "KomorebiWorkspaceConfirmMethod", t: "enum", default: "PollCloak",
     options: ["PollKomorebic", "PollCloak", "AwaitDelta"],
     d: "How Alt-Tabby verifies a workspace switch completed (only used when CrossWorkspaceMethod=SwitchActivate).`n"
      . "PollKomorebic = polls komorebic CLI (spawns cmd.exe every 15ms), works on multi-monitor but highest CPU.`n"
      . "PollCloak = checks DWM cloaked state (recommended, sub-microsecond DllCall).`n"
      . "AwaitDelta = waits for store delta, lowest CPU but potentially higher latency."},

    {type: "subsection", section: "Komorebi", name: "Subscription",
     desc: "Event-driven komorebi integration via named pipe"},

    {s: "Komorebi", k: "SubPollMs", g: "KomorebiSubPollMs", t: "int", default: 50,
     min: 10, max: 1000,
     d: "Pipe poll interval (checking for incoming data)"},

    {s: "Komorebi", k: "SubIdleRecycleMs", g: "KomorebiSubIdleRecycleMs", t: "int", default: 120000,
     min: 10000, max: 600000,
     d: "Restart subscription if no events for this long (stale detection)"},

    {s: "Komorebi", k: "SubFallbackPollMs", g: "KomorebiSubFallbackPollMs", t: "int", default: 2000,
     min: 500, max: 30000,
     d: "Fallback polling interval if subscription fails"},

    {s: "Komorebi", k: "SubCacheMaxAgeMs", g: "KomorebiSubCacheMaxAgeMs", t: "int", default: 10000,
     min: 1000, max: 60000,
     d: "Maximum age (ms) for cached workspace assignments before they are considered stale. Lower values track rapid workspace switching more accurately."},

    {s: "Komorebi", k: "SubBatchCloakEventsMs", g: "KomorebiSubBatchCloakEventsMs", t: "int", default: 50,
     min: 0, max: 500,
     d: "Batch cloak/uncloak events during workspace switches (ms). 0 = disabled, push immediately."},

    {s: "Komorebi", k: "MruSuppressionMs", g: "KomorebiMruSuppressionMs", t: "int", default: 2000,
     min: 500, max: 5000,
     d: "Duration (ms) to suppress WinEventHook MRU updates after a workspace switch. Prevents focus events from corrupting window order during transitions."},

    ; ============================================================
    ; Setup & Installation
    ; ============================================================
    {type: "section", name: "Setup",
     desc: "Setup & Installation",
     long: "Installation paths and first-run settings. Managed automatically by the setup wizard."},

    {s: "Setup", k: "ExePath", g: "SetupExePath", t: "string", default: "",
     d: "Full path to AltTabby.exe after installation. Empty = use current location."},

    {s: "Setup", k: "RunAsAdmin", g: "SetupRunAsAdmin", t: "bool", default: false,
     d: "Run with administrator privileges via Task Scheduler (no UAC prompts after setup)."},

    {s: "Setup", k: "AutoUpdateCheck", g: "SetupAutoUpdateCheck", t: "bool", default: true,
     d: "Automatically check for updates on startup."},

    {s: "Setup", k: "FirstRunCompleted", g: "SetupFirstRunCompleted", t: "bool", default: false,
     d: "Set to true after first-run wizard completes."},

    {s: "Setup", k: "InstallationId", g: "SetupInstallationId", t: "string", default: "",
     d: "Unique installation ID (8-char hex). Generated on first run. Used for mutex naming and admin task identification."},

    {s: "Setup", k: "SuppressAdminRepairPrompt", g: "SetupSuppressAdminRepairPrompt", t: "bool", default: false,
     d: "Don't prompt to repair stale admin task. Set automatically when user clicks 'Don't ask again'."},

    ; ============================================================
    ; External Tools
    ; ============================================================
    {type: "section", name: "Tools",
     desc: "External Tools",
     long: "Paths to external executables used by Alt-Tabby."},

    {s: "Tools", k: "AhkV2Path", g: "AhkV2Path", t: "string", default: "",
     d: "Path to AHK v2 executable (for spawning subprocesses). Leave empty to auto-discover via PATH and known install locations"},

    {s: "Tools", k: "KomorebicExe", g: "KomorebicExe", t: "string", default: "",
     d: "Path to komorebic.exe. Leave empty to auto-discover via PATH and known install locations"},

    ; ============================================================
    ; IPC & Communication
    ; ============================================================
    {type: "section", name: "IPC",
     desc: "IPC & Communication",
     long: "Named pipe IPC for enrichment pump and launcher control signals."},

    {s: "IPC", k: "PumpPipeName", g: "PumpPipeName", t: "string", default: "tabby_pump_v1",
     d: "Named pipe name for enrichment pump communication"},

    {s: "IPC", k: "IdleTickMs", g: "IPCIdleTickMs", t: "int", default: 100,
     min: 15, max: 500,
     d: "Pump poll interval when idle (ms). Lower = more responsive but more CPU."},

    {s: "IPC", k: "MaxReconnectAttempts", g: "IPCMaxReconnectAttempts", t: "int", default: 3,
     min: 1, max: 10,
     d: "Maximum pump pipe reconnection attempts before triggering restart."},

    {s: "IPC", k: "StoreStartWaitMs", g: "IPCStoreStartWaitMs", t: "int", default: 1000,
     min: 500, max: 5000,
     d: "Time to wait for main process to start on launch (ms). Increase on slow systems."},

    ; ============================================================
    ; Window Store
    ; ============================================================
    {type: "section", name: "Store",
     desc: "Window Store",
     long: "Window store configuration: producers, filtering, timing, and caching. Most users won't need to change these."},

    {type: "subsection", section: "Store", name: "Producer Toggles",
     desc: "WinEventHook and MRU are always enabled (core). These control optional producers"},

    {s: "Store", k: "UseKomorebiSub", g: "UseKomorebiSub", t: "bool", default: true,
     d: "Komorebi subscription-based integration (preferred, event-driven)"},

    {s: "Store", k: "UseKomorebiLite", g: "UseKomorebiLite", t: "bool", default: false,
     d: "Komorebi polling-based fallback (use if subscription fails)"},

    {s: "Store", k: "UseEnrichmentPump", g: "UseEnrichmentPump", t: "bool", default: true,
     d: "Use separate process for blocking icon/title/proc resolution (recommended for responsiveness)"},

    {s: "Store", k: "UseIconPump", g: "UseIconPump", t: "bool", default: true,
     d: "Resolve window icons in background"},

    {s: "Store", k: "UseProcPump", g: "UseProcPump", t: "bool", default: true,
     d: "Resolve process names in background"},

    {s: "Store", k: "PumpIconPruneIntervalMs", g: "PumpIconPruneIntervalMs", t: "int", default: 300000,
     min: 10000, max: 3600000,
     d: "Interval (ms) for pump to prune HICONs of closed windows"},

    {s: "Store", k: "PumpHangTimeoutMs", g: "PumpHangTimeoutMs", t: "int", default: 15000,
     min: 5000, max: 60000,
     d: "Time (ms) without a pump response before declaring it hung and restarting"},

    {type: "subsection", section: "Store", name: "Window Filtering",
     desc: "Filter windows like native Alt-Tab (skip tool windows, etc.) and apply blacklist"},

    {s: "Store", k: "UseAltTabEligibility", g: "UseAltTabEligibility", t: "bool", default: true,
     d: "Filter windows like native Alt-Tab (skip tool windows, etc.)"},

    {s: "Store", k: "UseBlacklist", g: "UseBlacklist", t: "bool", default: true,
     d: "Apply blacklist from shared/blacklist.txt"},

    {type: "subsection", section: "Store", name: "WinEventHook",
     desc: "Event-driven window change detection. Events are queued then processed in batches"},

    {s: "Store", k: "DebounceMs", g: "WinEventHookDebounceMs", t: "int", default: 50,
     min: 10, max: 1000,
     d: "Debounce rapid events (e.g., window moving fires many events)"},

    {s: "Store", k: "BatchMs", g: "WinEventHookBatchMs", t: "int", default: 100,
     min: 10, max: 2000,
     d: "Batch processing interval - how often queued events are processed"},

    {s: "Store", k: "IdleThreshold", g: "WinEventHookIdleThreshold", t: "int", default: 10,
     min: 1, max: 100,
     d: "Empty batch ticks before pausing timer. Lower = faster idle detection, higher = more responsive to bursts."},

    {s: "GUI", k: "ActiveRepaintDebounceMs", g: "GUI_ActiveRepaintDebounceMs", t: "int", default: 250,
     min: 0, max: 2000,
     d: "Minimum interval between cosmetic repaints while overlay is active (ms). Prevents animated titles from flooding repaints. 0 = no debounce."},

    {type: "subsection", section: "Store", name: "Z-Pump",
     desc: "When WinEventHook adds a window, Z-pump triggers a WinEnum scan for accurate Z-order"},

    {s: "Store", k: "IntervalMs", g: "ZPumpIntervalMs", t: "int", default: 200,
     min: 50, max: 5000,
     d: "How often to check for windows needing Z-order updates (ms)"},

    {type: "subsection", section: "Store", name: "WinEnum",
     desc: "Full window enumeration (startup, snapshot, Z-pump, safety polling)"},

    {s: "Store", k: "MissingWindowGraceMs", g: "WinEnumMissingWindowTTLMs", t: "int", default: 1200,
     min: 100, max: 10000,
     d: "Grace period before removing a missing window (ms). Shorter values remove ghost windows faster (Outlook/Teams). Longer values tolerate slow-starting apps."},

    {s: "Store", k: "FallbackScanIntervalMs", g: "WinEnumFallbackScanIntervalMs", t: "int", default: 2000,
     min: 500, max: 10000,
     d: "Polling interval when WinEventHook fails and fallback scanning is active (ms). Lower = more responsive but higher CPU."},

    {s: "Store", k: "SafetyPollMs", g: "WinEnumSafetyPollMs", t: "int", default: 0,
     min: 0, max: 300000,
     d: "Safety polling interval (0=disabled, or 30000+ for safety net)"},

    {s: "Store", k: "ValidateExistenceMs", g: "WinEnumValidateExistenceMs", t: "int", default: 5000,
     min: 0, max: 60000,
     d: "How often to check for dead/zombie windows (ms). Lightweight check that removes windows that no longer exist. 0 = disabled."},

    {type: "subsection", section: "Store", name: "MRU Lite",
     desc: "Fallback focus tracker (only runs if WinEventHook fails to start)"},

    {s: "Store", k: "PollMs", g: "MruLitePollMs", t: "int", default: 250,
     min: 50, max: 5000,
     d: "Polling interval for focus tracking fallback"},

    {type: "subsection", section: "Store", name: "Icon Pump",
     desc: "Resolves window icons asynchronously with retry/backoff"},

    {s: "Store", k: "IntervalMs", g: "IconPumpIntervalMs", t: "int", default: 80,
     min: 20, max: 1000,
     d: "How often the pump processes its queue"},

    {s: "Store", k: "BatchSize", g: "IconPumpBatchSize", t: "int", default: 16,
     min: 1, max: 100,
     d: "Max icons to process per tick (prevents lag spikes)"},

    {s: "Store", k: "MaxAttempts", g: "IconPumpMaxAttempts", t: "int", default: 4,
     min: 1, max: 20,
     d: "Max attempts before giving up on a window's icon"},

    {s: "Store", k: "AttemptBackoffMs", g: "IconPumpAttemptBackoffMs", t: "int", default: 300,
     min: 50, max: 5000,
     d: "Base backoff after failed attempt (multiplied by attempt number)"},

    {s: "Store", k: "BackoffMultiplier", g: "IconPumpBackoffMultiplier", t: "float", default: 1.8,
     min: 1.0, max: 5.0,
     d: "Backoff multiplier for exponential backoff (1.0 = linear)"},

    {s: "Store", k: "GiveUpBackoffMs", g: "IconPumpGiveUpBackoffMs", t: "int", default: 5000,
     min: 1000, max: 30000,
     d: "Long cooldown (ms) after max icon resolution attempts are exhausted. Lower values retry sooner for problematic apps."},

    {s: "Store", k: "RefreshThrottleMs", g: "IconPumpRefreshThrottleMs", t: "int", default: 5000,
     min: 1000, max: 300000,
     d: "Minimum time between icon refresh checks per window (ms). Icons are rechecked on focus and title change. The per-window throttle prevents spam from terminals with animated titles."},

    {s: "Store", k: "IconRefreshOnTitleChange", g: "IconRefreshOnTitleChange", t: "bool", default: true,
     d: "Re-check window icons when title changes (e.g., browser tab switch). Per-window throttle (RefreshThrottleMs) prevents spam."},

    {s: "Store", k: "IdleThreshold", g: "IconPumpIdleThreshold", t: "int", default: 5,
     min: 1, max: 100,
     d: "Empty queue ticks before pausing timer. Lower = faster idle detection, higher = more responsive to bursts."},

    {s: "Store", k: "ResolveTimeoutMs", g: "IconPumpResolveTimeoutMs", t: "int", default: 500,
     min: 100, max: 2000,
     d: "WM_GETICON timeout in milliseconds. Increase for slow or hung applications that need more time to respond."},

    {type: "subsection", section: "Store", name: "Process Pump",
     desc: "Resolves PID -> process name asynchronously"},

    {s: "Store", k: "IntervalMs", g: "ProcPumpIntervalMs", t: "int", default: 100,
     min: 20, max: 1000,
     d: "How often the pump processes its queue"},

    {s: "Store", k: "BatchSize", g: "ProcPumpBatchSize", t: "int", default: 16,
     min: 1, max: 100,
     d: "Max PIDs to resolve per tick"},

    {s: "Store", k: "IdleThreshold", g: "ProcPumpIdleThreshold", t: "int", default: 5,
     min: 1, max: 100,
     d: "Empty queue ticks before pausing timer. Lower = faster idle detection, higher = more responsive to bursts."},

    {s: "Store", k: "FailedPidRetryMs", g: "ProcPumpFailedPidRetryMs", t: "int", default: 60000,
     min: 5000, max: 300000,
     d: "How long (ms) before retrying process name lookup for a PID that previously failed."},

    {type: "subsection", section: "Store", name: "Cache Limits",
     desc: "Size limits for internal caches to prevent unbounded memory growth"},

    {s: "Store", k: "UwpLogoMax", g: "UwpLogoCacheMax", t: "int", default: 50,
     min: 5, max: 500,
     d: "Maximum number of cached UWP logo paths. Prevents repeated manifest parsing for multi-window UWP apps."},

    ; ============================================================
    ; Diagnostics
    ; ============================================================
    {type: "section", name: "Diagnostics",
     desc: "Diagnostics",
     long: "Debug options, viewer settings, and test configuration. All logging disabled by default."},

    {s: "Diagnostics", k: "FlightRecorder", g: "DiagFlightRecorder", t: "bool", default: true,
     d: "Enable in-memory flight recorder. Press F12 after a missed Alt-Tab to dump the last ~30s of events to the recorder/ folder. Near-zero performance impact."},

    {s: "Diagnostics", k: "FlightRecorderBufferSize", g: "DiagFlightRecorderBufferSize", t: "int", default: 2000, min: 500, max: 10000,
     d: "Number of events kept in the flight recorder ring buffer. 2000 ≈ 30s of typical activity. Higher values capture more history at ~48 bytes per slot."},

    {s: "Diagnostics", k: "FlightRecorderHotkey", g: "DiagFlightRecorderHotkey", t: "string", default: "*F12",
     d: "Hotkey to dump the flight recorder buffer. Use AHK v2 hotkey syntax (e.g. *F12, ^F12, +F11). * prefix = fire regardless of modifiers (works during Alt-Tab). Pass-through: the key still reaches other apps."},

    {s: "Diagnostics", k: "ChurnLog", g: "DiagChurnLog", t: "bool", default: false,
     d: "Log revision bump sources to %TEMP%\\tabby_store_error.log. Use when store rev is churning rapidly when idle."},

    {s: "Diagnostics", k: "KomorebiLog", g: "DiagKomorebiLog", t: "bool", default: false,
     d: "Log komorebi subscription events to %TEMP%\\tabby_ksub_diag.log. Use when workspace tracking has issues."},

    {s: "Diagnostics", k: "AltTabTooltips", g: "DiagAltTabTooltips", t: "bool", default: false,
     d: "Show tooltips for Alt-Tab state machine debugging. Use when overlay behavior is incorrect."},

    {s: "Diagnostics", k: "EventLog", g: "DiagEventLog", t: "bool", default: false,
     d: "Log Alt-Tab events to %TEMP%\\tabby_events.log. Use when debugging rapid Alt-Tab or event timing issues."},

    {s: "Diagnostics", k: "WinEventLog", g: "DiagWinEventLog", t: "bool", default: false,
     d: "Log WinEventHook focus events to %TEMP%\\tabby_weh_focus.log. Use when focus tracking issues occur."},

    {s: "Diagnostics", k: "StoreLog", g: "DiagStoreLog", t: "bool", default: false,
     d: "Log store startup and operational info to %TEMP%\\tabby_store_error.log. Use for general store debugging."},

    {s: "Diagnostics", k: "IconPumpLog", g: "DiagIconPumpLog", t: "bool", default: false,
     d: "Log icon pump operations to %TEMP%\\tabby_iconpump.log. Use when debugging icon resolution issues (cloaked windows, UWP apps)."},

    {s: "Diagnostics", k: "ProcPumpLog", g: "DiagProcPumpLog", t: "bool", default: false,
     d: "Log process pump operations to %TEMP%\\tabby_procpump.log. Use when debugging process name resolution failures."},

    {s: "Diagnostics", k: "PumpLog", g: "DiagPumpLog", t: "bool", default: false,
     d: "Log EnrichmentPump operations to %TEMP%\\tabby_pump.log. Use when debugging icon/title/process enrichment in the pump subprocess."},

    {s: "Diagnostics", k: "LauncherLog", g: "DiagLauncherLog", t: "bool", default: false,
     d: "Log launcher startup to %TEMP%\\tabby_launcher.log. Use when debugging startup issues, subprocess launch, or mutex problems."},

    {s: "Diagnostics", k: "IPCLog", g: "DiagIPCLog", t: "bool", default: false,
     d: "Log IPC pipe operations to %TEMP%\\tabby_ipc.log. Use when debugging store-GUI communication issues."},

    {s: "Diagnostics", k: "PaintTimingLog", g: "DiagPaintTimingLog", t: "bool", default: false,
     d: "Log GUI paint timing to %TEMP%\\tabby_paint_timing.log. Use when debugging slow overlay rendering after extended idle."},

    {s: "Diagnostics", k: "WebViewLog", g: "DiagWebViewLog", t: "bool", default: false,
     d: "Log WebView2 config editor errors to %TEMP%\\tabby_webview_debug.log. Use when debugging config editor issues."},

    {s: "Diagnostics", k: "UpdateLog", g: "DiagUpdateLog", t: "bool", default: false,
     d: "Log auto-update check and apply steps to %TEMP%\\tabby_update.log. Use when debugging update failures."},

    {s: "Diagnostics", k: "CosmeticPatchLog", g: "DiagCosmeticPatchLog", t: "bool", default: false,
     d: "Log cosmetic patch operations during ACTIVE state to %TEMP%\\tabby_cosmetic_patch.log. Use when debugging title/icon/processName updates in the overlay."},

    {s: "Diagnostics", k: "StatsTracking", g: "StatsTrackingEnabled", t: "bool", default: true,
     d: "Track usage statistics (Alt-Tabs, quick switches, etc.) and persist to stats.ini. Shown in the dashboard."},

    {type: "subsection", section: "Diagnostics", name: "Log Size Limits",
     desc: "Control diagnostic log file sizes"},

    {s: "Diagnostics", k: "LogMaxKB", g: "DiagLogMaxKB", t: "int", default: 100,
     min: 50, max: 1000,
     d: "Maximum diagnostic log file size in KB before trimming."},

    {s: "Diagnostics", k: "LogKeepKB", g: "DiagLogKeepKB", t: "int", default: 50,
     min: 25, max: 500,
     d: "Size to keep after log trim in KB. Must be less than LogMaxKB."},

    {type: "subsection", section: "Diagnostics", name: "Viewer",
     desc: "Debug viewer GUI options"},

    {s: "Diagnostics", k: "ViewerDebugLog", g: "DiagViewerLog", t: "bool", default: false,
     d: "Enable verbose viewer logging to error log"},

    {s: "Diagnostics", k: "ViewerAutoStartStore", g: "ViewerAutoStartStore", t: "bool", default: false,
     d: "Auto-start store_server if not running when viewer connects"},

]
