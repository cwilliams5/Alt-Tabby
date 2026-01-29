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
; Setting types: "string", "int", "float", "bool"
;
; To add a new config:
; 1. Add an entry to gConfigRegistry below (with default value)
; 2. That's it! The value is automatically available as cfg.YourConfigName
; ============================================================

global gConfigRegistry := [
    ; ============================================================
    ; Alt-Tab Behavior (Most Likely to Edit)
    ; ============================================================
    {type: "section", name: "AltTab",
     desc: "Alt-Tab Behavior",
     long: "These control the Alt-Tab overlay behavior - tweak these first!"},

    {s: "AltTab", k: "GraceMs", g: "AltTabGraceMs", t: "int", default: 150,
     d: "Grace period before showing GUI (ms). During this time, if Alt is released, we do a quick switch without showing GUI."},

    {s: "AltTab", k: "QuickSwitchMs", g: "AltTabQuickSwitchMs", t: "int", default: 100,
     d: "Maximum time for quick switch without showing GUI (ms). If Alt+Tab and release happen within this time, instant switch."},

    {s: "AltTab", k: "PrewarmOnAlt", g: "AltTabPrewarmOnAlt", t: "bool", default: true,
     d: "Pre-warm snapshot on Alt down (true = request data before Tab pressed). Ensures fresh window data is available when Tab is pressed."},

    {s: "AltTab", k: "FreezeWindowList", g: "FreezeWindowList", t: "bool", default: false,
     d: "Freeze window list on first Tab press. When true, the list is locked and won't change during Alt+Tab interaction. When false, the list updates in real-time (may cause visual flicker)."},

    {s: "AltTab", k: "UseCurrentWSProjection", g: "UseCurrentWSProjection", t: "bool", default: true,
     d: "Use server-side workspace projection filtering. When true, CTRL workspace toggle requests a new projection from the store. When false, CTRL toggle filters the cached items locally (faster, but uses cached data)."},

    {s: "AltTab", k: "SwitchOnClick", g: "AltTabSwitchOnClick", t: "bool", default: true,
     d: "Activate window immediately when clicking a row (like Windows native). When false, clicking selects the row and activation happens when Alt is released."},

    {s: "AltTab", k: "AsyncActivationPollMs", g: "AltTabAsyncActivationPollMs", t: "int", default: 15,
     d: "Polling interval (ms) when switching to a window on a different workspace. Lower = more responsive but higher CPU (spawns cmd.exe each poll). Default: 15."},

    {type: "subsection", section: "AltTab", name: "Bypass",
     desc: "When to let native Windows Alt-Tab handle the switch instead of Alt-Tabby"},

    {s: "AltTab", k: "BypassFullscreen", g: "AltTabBypassFullscreen", t: "bool", default: true,
     d: "Bypass Alt-Tabby when the foreground window is fullscreen (covers ≥99% of screen). Useful for games that need native Alt-Tab behavior."},

    {s: "AltTab", k: "BypassFullscreenThreshold", g: "AltTabBypassFullscreenThreshold", t: "float", default: 0.99,
     d: "Fraction of screen dimensions a window must cover to be considered fullscreen (0.90-1.0). Lower values catch borderless windowed games that don't quite fill the screen."},

    {s: "AltTab", k: "BypassFullscreenTolerancePx", g: "AltTabBypassFullscreenTolerancePx", t: "int", default: 5,
     d: "Maximum pixels from screen edge for a window to still be considered fullscreen (0-50). Increase if borderless windows are offset by more than 5px."},

    {s: "AltTab", k: "BypassProcesses", g: "AltTabBypassProcesses", t: "string", default: "",
     d: "Comma-separated list of process names to bypass (e.g., 'game.exe,vlc.exe'). When these processes are in the foreground, native Windows Alt-Tab is used instead."},

    {type: "subsection", section: "AltTab", name: "Internal Timing",
     desc: "Internal timing parameters (usually no need to change)"},

    {s: "AltTab", k: "AltLeewayMs", g: "AltTabAltLeewayMs", t: "int", default: 60,
     d: "Alt key timing tolerance window (ms). After Alt is released, Tab presses within this window are still treated as Alt+Tab. Increase for slower typing speeds. Range: 20-200."},

    {s: "AltTab", k: "MRUFreshnessMs", g: "AltTabMRUFreshnessMs", t: "int", default: 300,
     d: "How long local MRU data is considered fresh after activation (ms). Prewarmed snapshots are skipped within this window to prevent stale data overwriting recent activations."},

    {s: "AltTab", k: "WSPollTimeoutMs", g: "AltTabWSPollTimeoutMs", t: "int", default: 200,
     d: "Timeout when polling for workspace switch completion (ms). Used during cross-workspace activation."},

    {s: "AltTab", k: "PrewarmWaitMs", g: "AltTabPrewarmWaitMs", t: "int", default: 50,
     d: "Max time to wait for prewarm data on Tab (ms). If items are empty when Tab is pressed, wait up to this long for data to arrive."},

    {s: "AltTab", k: "TabDecisionMs", g: "AltTabTabDecisionMs", t: "int", default: 24,
     d: "Tab decision window (ms). When Tab is pressed, we wait this long before committing to show the overlay. Allows detecting rapid Tab releases. Lower = more responsive but may cause accidental triggers. Range: 15-40."},

    {s: "AltTab", k: "WorkspaceSwitchSettleMs", g: "AltTabWorkspaceSwitchSettleMs", t: "int", default: 75,
     d: "Wait time after workspace switch (ms). When activating a window on a different komorebi workspace, we wait this long for the workspace to stabilize before activating the window. Increase if windows fail to activate on slow systems."},

    ; ============================================================
    ; Launcher Settings
    ; ============================================================
    {type: "section", name: "Launcher",
     desc: "Launcher Settings",
     long: "Settings for the main Alt-Tabby launcher process (splash screen, startup behavior)."},

    {s: "Launcher", k: "ShowSplash", g: "LauncherShowSplash", t: "bool", default: true,
     d: "Show splash screen on startup. Displays logo briefly while store and GUI processes start."},

    {s: "Launcher", k: "SplashDurationMs", g: "LauncherSplashDurationMs", t: "int", default: 3000,
     d: "Splash screen display duration in milliseconds (includes fade time). Set to 0 for minimum."},

    {s: "Launcher", k: "SplashFadeMs", g: "LauncherSplashFadeMs", t: "int", default: 500,
     d: "Splash screen fade in/out duration in milliseconds."},

    {s: "Launcher", k: "SplashImagePath", g: "LauncherSplashImagePath", t: "string", default: "img\logo.png",
     d: "Path to splash screen image (relative to Alt-Tabby directory, or absolute path)."},

    ; ============================================================
    ; GUI Appearance
    ; ============================================================
    {type: "section", name: "GUI",
     desc: "GUI Appearance",
     long: "Visual styling for the Alt-Tab overlay window."},

    ; --- Background Window ---
    {type: "subsection", section: "GUI", name: "Background Window",
     desc: "Window background and frame styling"},

    {s: "GUI", k: "AcrylicAlpha", g: "GUI_AcrylicAlpha", t: "int", default: 0x33,
     d: "Background transparency (0x00=transparent, 0xFF=opaque)"},

    {s: "GUI", k: "AcrylicBaseRgb", g: "GUI_AcrylicBaseRgb", t: "int", default: 0x330000,
     d: "Background tint color (hex RGB)"},

    {s: "GUI", k: "CornerRadiusPx", g: "GUI_CornerRadiusPx", t: "int", default: 18,
     d: "Window corner radius in pixels"},

    ; --- Size Config ---
    {type: "subsection", section: "GUI", name: "Size Config",
     desc: "Window and row sizing"},

    {s: "GUI", k: "ScreenWidthPct", g: "GUI_ScreenWidthPct", t: "float", default: 0.60,
     d: "GUI width as fraction of screen (0.0-1.0)"},

    {s: "GUI", k: "RowsVisibleMin", g: "GUI_RowsVisibleMin", t: "int", default: 1,
     d: "Minimum visible rows"},

    {s: "GUI", k: "RowsVisibleMax", g: "GUI_RowsVisibleMax", t: "int", default: 8,
     d: "Maximum visible rows"},

    {s: "GUI", k: "RowHeight", g: "GUI_RowHeight", t: "int", default: 56,
     d: "Height of each row in pixels"},

    {s: "GUI", k: "MarginX", g: "GUI_MarginX", t: "int", default: 18,
     d: "Horizontal margin in pixels"},

    {s: "GUI", k: "MarginY", g: "GUI_MarginY", t: "int", default: 18,
     d: "Vertical margin in pixels"},

    ; --- Virtual List Look ---
    {type: "subsection", section: "GUI", name: "Virtual List Look",
     desc: "Row and icon appearance"},

    {s: "GUI", k: "IconSize", g: "GUI_IconSize", t: "int", default: 36,
     d: "Icon size in pixels"},

    {s: "GUI", k: "IconLeftMargin", g: "GUI_IconLeftMargin", t: "int", default: 8,
     d: "Left margin before icon in pixels"},

    {s: "GUI", k: "IconTextGapPx", g: "GUI_IconTextGapPx", t: "int", default: 12,
     d: "Gap between icon and title text in pixels"},

    {s: "GUI", k: "ColumnGapPx", g: "GUI_ColumnGapPx", t: "int", default: 10,
     d: "Gap between right-side data columns in pixels"},

    {s: "GUI", k: "HeaderHeightPx", g: "GUI_HeaderHeightPx", t: "int", default: 28,
     d: "Header row height in pixels"},

    {s: "GUI", k: "RowRadius", g: "GUI_RowRadius", t: "int", default: 12,
     d: "Row corner radius in pixels"},

    {s: "GUI", k: "SelARGB", g: "GUI_SelARGB", t: "int", default: 0x662B5CAD,
     d: "Selection highlight color (ARGB)"},

    ; --- Selection & Scrolling ---
    {type: "subsection", section: "GUI", name: "Selection & Scrolling",
     desc: "Selection and scroll behavior"},

    {s: "GUI", k: "ScrollKeepHighlightOnTop", g: "GUI_ScrollKeepHighlightOnTop", t: "bool", default: true,
     d: "Keep selection at top when scrolling"},

    {s: "GUI", k: "EmptyListText", g: "GUI_EmptyListText", t: "string", default: "No Windows",
     d: "Text shown when no windows available"},

    ; --- Action Buttons ---
    {type: "subsection", section: "GUI", name: "Action Buttons",
     desc: "Row action buttons shown on hover"},

    {s: "GUI", k: "ShowCloseButton", g: "GUI_ShowCloseButton", t: "bool", default: true,
     d: "Show close button on hover"},

    {s: "GUI", k: "ShowKillButton", g: "GUI_ShowKillButton", t: "bool", default: true,
     d: "Show kill button on hover"},

    {s: "GUI", k: "ShowBlacklistButton", g: "GUI_ShowBlacklistButton", t: "bool", default: true,
     d: "Show blacklist button on hover"},

    {s: "GUI", k: "ActionBtnSizePx", g: "GUI_ActionBtnSizePx", t: "int", default: 24,
     d: "Action button size in pixels"},

    {s: "GUI", k: "ActionBtnGapPx", g: "GUI_ActionBtnGapPx", t: "int", default: 6,
     d: "Gap between action buttons in pixels"},

    {s: "GUI", k: "ActionBtnRadiusPx", g: "GUI_ActionBtnRadiusPx", t: "int", default: 6,
     d: "Action button corner radius"},

    {s: "GUI", k: "ActionFontName", g: "GUI_ActionFontName", t: "string", default: "Segoe UI Symbol",
     d: "Action button font name"},

    {s: "GUI", k: "ActionFontSize", g: "GUI_ActionFontSize", t: "int", default: 18,
     d: "Action button font size"},

    {s: "GUI", k: "ActionFontWeight", g: "GUI_ActionFontWeight", t: "int", default: 700,
     d: "Action button font weight"},

    ; --- Close Button Styling ---
    {type: "subsection", section: "GUI", name: "Close Button Styling",
     desc: "Close button appearance"},

    {s: "GUI", k: "CloseButtonBorderPx", g: "GUI_CloseButtonBorderPx", t: "int", default: 1,
     d: "Close button border width"},

    {s: "GUI", k: "CloseButtonBorderARGB", g: "GUI_CloseButtonBorderARGB", t: "int", default: 0x88FFFFFF,
     d: "Close button border color (ARGB)"},

    {s: "GUI", k: "CloseButtonBGARGB", g: "GUI_CloseButtonBGARGB", t: "int", default: 0xFF000000,
     d: "Close button background color (ARGB)"},

    {s: "GUI", k: "CloseButtonBGHoverARGB", g: "GUI_CloseButtonBGHoverARGB", t: "int", default: 0xFF888888,
     d: "Close button background color on hover (ARGB)"},

    {s: "GUI", k: "CloseButtonTextARGB", g: "GUI_CloseButtonTextARGB", t: "int", default: 0xFFFFFFFF,
     d: "Close button text color (ARGB)"},

    {s: "GUI", k: "CloseButtonTextHoverARGB", g: "GUI_CloseButtonTextHoverARGB", t: "int", default: 0xFFFF0000,
     d: "Close button text color on hover (ARGB)"},

    {s: "GUI", k: "CloseButtonGlyph", g: "GUI_CloseButtonGlyph", t: "string", default: "X",
     d: "Close button glyph character"},

    ; --- Kill Button Styling ---
    {type: "subsection", section: "GUI", name: "Kill Button Styling",
     desc: "Kill button appearance"},

    {s: "GUI", k: "KillButtonBorderPx", g: "GUI_KillButtonBorderPx", t: "int", default: 1,
     d: "Kill button border width"},

    {s: "GUI", k: "KillButtonBorderARGB", g: "GUI_KillButtonBorderARGB", t: "int", default: 0x88FFB4A5,
     d: "Kill button border color (ARGB)"},

    {s: "GUI", k: "KillButtonBGARGB", g: "GUI_KillButtonBGARGB", t: "int", default: 0xFF300000,
     d: "Kill button background color (ARGB)"},

    {s: "GUI", k: "KillButtonBGHoverARGB", g: "GUI_KillButtonBGHoverARGB", t: "int", default: 0xFFD00000,
     d: "Kill button background color on hover (ARGB)"},

    {s: "GUI", k: "KillButtonTextARGB", g: "GUI_KillButtonTextARGB", t: "int", default: 0xFFFFE8E8,
     d: "Kill button text color (ARGB)"},

    {s: "GUI", k: "KillButtonTextHoverARGB", g: "GUI_KillButtonTextHoverARGB", t: "int", default: 0xFFFFFFFF,
     d: "Kill button text color on hover (ARGB)"},

    {s: "GUI", k: "KillButtonGlyph", g: "GUI_KillButtonGlyph", t: "string", default: "K",
     d: "Kill button glyph character"},

    ; --- Blacklist Button Styling ---
    {type: "subsection", section: "GUI", name: "Blacklist Button Styling",
     desc: "Blacklist button appearance"},

    {s: "GUI", k: "BlacklistButtonBorderPx", g: "GUI_BlacklistButtonBorderPx", t: "int", default: 1,
     d: "Blacklist button border width"},

    {s: "GUI", k: "BlacklistButtonBorderARGB", g: "GUI_BlacklistButtonBorderARGB", t: "int", default: 0x88999999,
     d: "Blacklist button border color (ARGB)"},

    {s: "GUI", k: "BlacklistButtonBGARGB", g: "GUI_BlacklistButtonBGARGB", t: "int", default: 0xFF000000,
     d: "Blacklist button background color (ARGB)"},

    {s: "GUI", k: "BlacklistButtonBGHoverARGB", g: "GUI_BlacklistButtonBGHoverARGB", t: "int", default: 0xFF888888,
     d: "Blacklist button background color on hover (ARGB)"},

    {s: "GUI", k: "BlacklistButtonTextARGB", g: "GUI_BlacklistButtonTextARGB", t: "int", default: 0xFFFFFFFF,
     d: "Blacklist button text color (ARGB)"},

    {s: "GUI", k: "BlacklistButtonTextHoverARGB", g: "GUI_BlacklistButtonTextHoverARGB", t: "int", default: 0xFFFF0000,
     d: "Blacklist button text color on hover (ARGB)"},

    {s: "GUI", k: "BlacklistButtonGlyph", g: "GUI_BlacklistButtonGlyph", t: "string", default: "B",
     d: "Blacklist button glyph character"},

    ; --- Columns ---
    {type: "subsection", section: "GUI", name: "Columns",
     desc: "Extra data columns (0 = hidden)"},

    {s: "GUI", k: "ShowHeader", g: "GUI_ShowHeader", t: "bool", default: true,
     d: "Show column headers"},

    {s: "GUI", k: "ColFixed2", g: "GUI_ColFixed2", t: "int", default: 70,
     d: "Column 2 width (HWND)"},

    {s: "GUI", k: "ColFixed3", g: "GUI_ColFixed3", t: "int", default: 50,
     d: "Column 3 width (PID)"},

    {s: "GUI", k: "ColFixed4", g: "GUI_ColFixed4", t: "int", default: 60,
     d: "Column 4 width (Workspace)"},

    {s: "GUI", k: "ColFixed5", g: "GUI_ColFixed5", t: "int", default: 0,
     d: "Column 5 width (0=hidden)"},

    {s: "GUI", k: "ColFixed6", g: "GUI_ColFixed6", t: "int", default: 0,
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

    ; --- Header Font ---
    {type: "subsection", section: "GUI", name: "Header Font",
     desc: "Column header text styling"},

    {s: "GUI", k: "HdrFontName", g: "GUI_HdrFontName", t: "string", default: "Segoe UI",
     d: "Header font name"},

    {s: "GUI", k: "HdrFontSize", g: "GUI_HdrFontSize", t: "int", default: 12,
     d: "Header font size"},

    {s: "GUI", k: "HdrFontWeight", g: "GUI_HdrFontWeight", t: "int", default: 600,
     d: "Header font weight"},

    {s: "GUI", k: "HdrARGB", g: "GUI_HdrARGB", t: "int", default: 0xFFD0D6DE,
     d: "Header text color (ARGB)"},

    ; --- Main Font ---
    {type: "subsection", section: "GUI", name: "Main Font",
     desc: "Window title text styling"},

    {s: "GUI", k: "MainFontName", g: "GUI_MainFontName", t: "string", default: "Segoe UI",
     d: "Main font name"},

    {s: "GUI", k: "MainFontSize", g: "GUI_MainFontSize", t: "int", default: 20,
     d: "Main font size"},

    {s: "GUI", k: "MainFontWeight", g: "GUI_MainFontWeight", t: "int", default: 400,
     d: "Main font weight"},

    {s: "GUI", k: "MainFontNameHi", g: "GUI_MainFontNameHi", t: "string", default: "Segoe UI",
     d: "Main font name when highlighted"},

    {s: "GUI", k: "MainFontSizeHi", g: "GUI_MainFontSizeHi", t: "int", default: 20,
     d: "Main font size when highlighted"},

    {s: "GUI", k: "MainFontWeightHi", g: "GUI_MainFontWeightHi", t: "int", default: 800,
     d: "Main font weight when highlighted"},

    {s: "GUI", k: "MainARGB", g: "GUI_MainARGB", t: "int", default: 0xFFF0F0F0,
     d: "Main text color (ARGB)"},

    {s: "GUI", k: "MainARGBHi", g: "GUI_MainARGBHi", t: "int", default: 0xFFF0F0F0,
     d: "Main text color when highlighted (ARGB)"},

    ; --- Sub Font ---
    {type: "subsection", section: "GUI", name: "Sub Font",
     desc: "Subtitle row text styling"},

    {s: "GUI", k: "SubFontName", g: "GUI_SubFontName", t: "string", default: "Segoe UI",
     d: "Sub font name"},

    {s: "GUI", k: "SubFontSize", g: "GUI_SubFontSize", t: "int", default: 12,
     d: "Sub font size"},

    {s: "GUI", k: "SubFontWeight", g: "GUI_SubFontWeight", t: "int", default: 400,
     d: "Sub font weight"},

    {s: "GUI", k: "SubFontNameHi", g: "GUI_SubFontNameHi", t: "string", default: "Segoe UI",
     d: "Sub font name when highlighted"},

    {s: "GUI", k: "SubFontSizeHi", g: "GUI_SubFontSizeHi", t: "int", default: 12,
     d: "Sub font size when highlighted"},

    {s: "GUI", k: "SubFontWeightHi", g: "GUI_SubFontWeightHi", t: "int", default: 600,
     d: "Sub font weight when highlighted"},

    {s: "GUI", k: "SubARGB", g: "GUI_SubARGB", t: "int", default: 0xFFB5C0CE,
     d: "Sub text color (ARGB)"},

    {s: "GUI", k: "SubARGBHi", g: "GUI_SubARGBHi", t: "int", default: 0xFFB5C0CE,
     d: "Sub text color when highlighted (ARGB)"},

    ; --- Column Font ---
    {type: "subsection", section: "GUI", name: "Column Font",
     desc: "Column value text styling"},

    {s: "GUI", k: "ColFontName", g: "GUI_ColFontName", t: "string", default: "Segoe UI",
     d: "Column font name"},

    {s: "GUI", k: "ColFontSize", g: "GUI_ColFontSize", t: "int", default: 12,
     d: "Column font size"},

    {s: "GUI", k: "ColFontWeight", g: "GUI_ColFontWeight", t: "int", default: 400,
     d: "Column font weight"},

    {s: "GUI", k: "ColFontNameHi", g: "GUI_ColFontNameHi", t: "string", default: "Segoe UI",
     d: "Column font name when highlighted"},

    {s: "GUI", k: "ColFontSizeHi", g: "GUI_ColFontSizeHi", t: "int", default: 12,
     d: "Column font size when highlighted"},

    {s: "GUI", k: "ColFontWeightHi", g: "GUI_ColFontWeightHi", t: "int", default: 600,
     d: "Column font weight when highlighted"},

    {s: "GUI", k: "ColARGB", g: "GUI_ColARGB", t: "int", default: 0xFFF0F0F0,
     d: "Column text color (ARGB)"},

    {s: "GUI", k: "ColARGBHi", g: "GUI_ColARGBHi", t: "int", default: 0xFFF0F0F0,
     d: "Column text color when highlighted (ARGB)"},

    ; --- Scrollbar ---
    {type: "subsection", section: "GUI", name: "Scrollbar",
     desc: "Scrollbar appearance"},

    {s: "GUI", k: "ScrollBarEnabled", g: "GUI_ScrollBarEnabled", t: "bool", default: true,
     d: "Show scrollbar when content overflows"},

    {s: "GUI", k: "ScrollBarWidthPx", g: "GUI_ScrollBarWidthPx", t: "int", default: 6,
     d: "Scrollbar width in pixels"},

    {s: "GUI", k: "ScrollBarMarginRightPx", g: "GUI_ScrollBarMarginRightPx", t: "int", default: 8,
     d: "Scrollbar right margin in pixels"},

    {s: "GUI", k: "ScrollBarThumbARGB", g: "GUI_ScrollBarThumbARGB", t: "int", default: 0x88FFFFFF,
     d: "Scrollbar thumb color (ARGB)"},

    {s: "GUI", k: "ScrollBarGutterEnabled", g: "GUI_ScrollBarGutterEnabled", t: "bool", default: false,
     d: "Show scrollbar gutter background"},

    {s: "GUI", k: "ScrollBarGutterARGB", g: "GUI_ScrollBarGutterARGB", t: "int", default: 0x30000000,
     d: "Scrollbar gutter color (ARGB)"},

    ; --- Footer ---
    {type: "subsection", section: "GUI", name: "Footer",
     desc: "Footer bar appearance"},

    {s: "GUI", k: "ShowFooter", g: "GUI_ShowFooter", t: "bool", default: true,
     d: "Show footer bar"},

    {s: "GUI", k: "FooterBorderPx", g: "GUI_FooterBorderPx", t: "int", default: 0,
     d: "Footer border width in pixels"},

    {s: "GUI", k: "FooterBorderARGB", g: "GUI_FooterBorderARGB", t: "int", default: 0x33FFFFFF,
     d: "Footer border color (ARGB)"},

    {s: "GUI", k: "FooterBGRadius", g: "GUI_FooterBGRadius", t: "int", default: 0,
     d: "Footer background corner radius"},

    {s: "GUI", k: "FooterBGARGB", g: "GUI_FooterBGARGB", t: "int", default: 0x00000000,
     d: "Footer background color (ARGB)"},

    {s: "GUI", k: "FooterTextARGB", g: "GUI_FooterTextARGB", t: "int", default: 0xFFFFFFFF,
     d: "Footer text color (ARGB)"},

    {s: "GUI", k: "FooterFontName", g: "GUI_FooterFontName", t: "string", default: "Segoe UI",
     d: "Footer font name"},

    {s: "GUI", k: "FooterFontSize", g: "GUI_FooterFontSize", t: "int", default: 14,
     d: "Footer font size"},

    {s: "GUI", k: "FooterFontWeight", g: "GUI_FooterFontWeight", t: "int", default: 600,
     d: "Footer font weight"},

    {s: "GUI", k: "FooterHeightPx", g: "GUI_FooterHeightPx", t: "int", default: 24,
     d: "Footer height in pixels"},

    {s: "GUI", k: "FooterGapTopPx", g: "GUI_FooterGapTopPx", t: "int", default: 8,
     d: "Gap between content and footer in pixels"},

    {s: "GUI", k: "FooterPaddingX", g: "GUI_FooterPaddingX", t: "int", default: 12,
     d: "Footer horizontal padding in pixels"},

    ; ============================================================
    ; IPC & Pipes
    ; ============================================================
    {type: "section", name: "IPC",
     desc: "IPC & Pipes",
     long: "Named pipe for store<->client communication."},

    {s: "IPC", k: "StorePipeName", g: "StorePipeName", t: "string", default: "tabby_store_v1",
     d: "Named pipe name for store communication"},

    {s: "IPC", k: "IdleTickMs", g: "IPCIdleTickMs", t: "int", default: 100,
     d: "Client poll interval when idle (ms). Lower = more responsive but more CPU. Active tick is always 15ms."},

    ; ============================================================
    ; External Tools
    ; ============================================================
    {type: "section", name: "Tools",
     desc: "External Tools",
     long: "Paths to external executables used by Alt-Tabby."},

    {s: "Tools", k: "AhkV2Path", g: "AhkV2Path", t: "string", default: "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe",
     d: "Path to AHK v2 executable (for spawning subprocesses)"},

    {s: "Tools", k: "KomorebicExe", g: "KomorebicExe", t: "string", default: "C:\Program Files\komorebi\bin\komorebic.exe",
     d: "Path to komorebic.exe (komorebi CLI)"},

    ; ============================================================
    ; Producer Toggles
    ; ============================================================
    {type: "section", name: "Producers",
     desc: "Producer Toggles",
     long: "WinEventHook and MRU are always enabled (core functionality). These control optional producers."},

    {s: "Producers", k: "UseKomorebiSub", g: "UseKomorebiSub", t: "bool", default: true,
     d: "Komorebi subscription-based integration (preferred, event-driven)"},

    {s: "Producers", k: "UseKomorebiLite", g: "UseKomorebiLite", t: "bool", default: false,
     d: "Komorebi polling-based fallback (use if subscription fails)"},

    {s: "Producers", k: "UseIconPump", g: "UseIconPump", t: "bool", default: true,
     d: "Resolve window icons in background"},

    {s: "Producers", k: "UseProcPump", g: "UseProcPump", t: "bool", default: true,
     d: "Resolve process names in background"},

    ; ============================================================
    ; Window Filtering
    ; ============================================================
    {type: "section", name: "Filtering",
     desc: "Window Filtering",
     long: "Filter windows like native Alt-Tab (skip tool windows, etc.) and apply blacklist."},

    {s: "Filtering", k: "UseAltTabEligibility", g: "UseAltTabEligibility", t: "bool", default: true,
     d: "Filter windows like native Alt-Tab (skip tool windows, etc.)"},

    {s: "Filtering", k: "UseBlacklist", g: "UseBlacklist", t: "bool", default: true,
     d: "Apply blacklist from shared/blacklist.txt"},

    ; ============================================================
    ; WinEventHook Timing
    ; ============================================================
    {type: "section", name: "WinEventHook",
     desc: "WinEventHook Timing",
     long: "Event-driven window change detection. Events are queued then processed in batches to keep the callback fast."},

    {s: "WinEventHook", k: "DebounceMs", g: "WinEventHookDebounceMs", t: "int", default: 50,
     d: "Debounce rapid events (e.g., window moving fires many events)"},

    {s: "WinEventHook", k: "BatchMs", g: "WinEventHookBatchMs", t: "int", default: 100,
     d: "Batch processing interval - how often queued events are processed"},

    {s: "WinEventHook", k: "IdleThreshold", g: "WinEventHookIdleThreshold", t: "int", default: 10,
     d: "Empty batch ticks before pausing timer. Lower = faster idle detection, higher = more responsive to bursts."},

    ; ============================================================
    ; Z-Pump Timing
    ; ============================================================
    {type: "section", name: "ZPump",
     desc: "Z-Pump Timing",
     long: "When WinEventHook adds a window, we don't know its Z-order. Z-pump triggers a full WinEnum scan to get accurate Z-order."},

    {s: "ZPump", k: "IntervalMs", g: "ZPumpIntervalMs", t: "int", default: 200,
     d: "How often to check if Z-queue has pending windows"},

    ; ============================================================
    ; WinEnum (Full Scan) Safety Polling
    ; ============================================================
    {type: "section", name: "WinEnum",
     desc: "WinEnum Safety Polling",
     long: "WinEnum normally runs on-demand (startup, snapshot, Z-pump). Enable safety polling as a paranoid belt-and-suspenders."},

    {s: "WinEnum", k: "MissingWindowTTLMs", g: "WinEnumMissingWindowTTLMs", t: "int", default: 1200,
     d: "Grace period before removing a missing window (ms). Shorter values remove ghost windows faster (Outlook/Teams). Longer values tolerate slow-starting apps. Range: 100-10000."},

    {s: "WinEnum", k: "FallbackScanIntervalMs", g: "WinEnumFallbackScanIntervalMs", t: "int", default: 2000,
     d: "Polling interval when WinEventHook fails and fallback scanning is active (ms). Lower = more responsive but higher CPU. Range: 500-10000."},

    {s: "WinEnum", k: "SafetyPollMs", g: "WinEnumSafetyPollMs", t: "int", default: 0,
     d: "Safety polling interval (0=disabled, or 30000+ for safety net)"},

    {s: "WinEnum", k: "ValidateExistenceMs", g: "WinEnumValidateExistenceMs", t: "int", default: 5000,
     d: "Lightweight zombie detection interval (ms). Checks existing store entries via IsWindow() to remove dead windows. Much faster than full EnumWindows scan. 0=disabled."},

    ; ============================================================
    ; MRU Lite Timing (Fallback Only)
    ; ============================================================
    {type: "section", name: "MruLite",
     desc: "MRU Lite Timing",
     long: "MRU_Lite only runs if WinEventHook fails to start. It polls the foreground window to track focus changes."},

    {s: "MruLite", k: "PollMs", g: "MruLitePollMs", t: "int", default: 250,
     d: "Polling interval for focus tracking fallback"},

    ; ============================================================
    ; Icon Pump Timing
    ; ============================================================
    {type: "section", name: "IconPump",
     desc: "Icon Pump Timing",
     long: "Resolves window icons asynchronously with retry/backoff."},

    {s: "IconPump", k: "IntervalMs", g: "IconPumpIntervalMs", t: "int", default: 80,
     d: "How often the pump processes its queue"},

    {s: "IconPump", k: "BatchSize", g: "IconPumpBatchSize", t: "int", default: 16,
     d: "Max icons to process per tick (prevents lag spikes)"},

    {s: "IconPump", k: "MaxAttempts", g: "IconPumpMaxAttempts", t: "int", default: 4,
     d: "Max attempts before giving up on a window's icon"},

    {s: "IconPump", k: "AttemptBackoffMs", g: "IconPumpAttemptBackoffMs", t: "int", default: 300,
     d: "Base backoff after failed attempt (multiplied by attempt number)"},

    {s: "IconPump", k: "BackoffMultiplier", g: "IconPumpBackoffMultiplier", t: "float", default: 1.8,
     d: "Backoff multiplier for exponential backoff (1.0 = linear)"},

    {s: "IconPump", k: "GiveUpBackoffMs", g: "IconPumpGiveUpBackoffMs", t: "int", default: 5000,
     d: "Long cooldown (ms) after max icon resolution attempts are exhausted. Lower values retry sooner for problematic apps. Range: 1000-30000."},

    {s: "IconPump", k: "RefreshThrottleMs", g: "IconPumpRefreshThrottleMs", t: "int", default: 30000,
     d: "Minimum time between icon refresh checks for focused windows (ms). Windows can change icons (e.g., browser favicons), so we recheck WM_GETICON when focused after this delay."},

    {s: "IconPump", k: "IdleThreshold", g: "IconPumpIdleThreshold", t: "int", default: 5,
     d: "Empty queue ticks before pausing timer. Lower = faster idle detection, higher = more responsive to bursts."},

    ; ============================================================
    ; Process Pump Timing
    ; ============================================================
    {type: "section", name: "ProcPump",
     desc: "Process Pump Timing",
     long: "Resolves PID -> process name asynchronously."},

    {s: "ProcPump", k: "IntervalMs", g: "ProcPumpIntervalMs", t: "int", default: 100,
     d: "How often the pump processes its queue"},

    {s: "ProcPump", k: "BatchSize", g: "ProcPumpBatchSize", t: "int", default: 16,
     d: "Max PIDs to resolve per tick"},

    {s: "ProcPump", k: "IdleThreshold", g: "ProcPumpIdleThreshold", t: "int", default: 5,
     d: "Empty queue ticks before pausing timer. Lower = faster idle detection, higher = more responsive to bursts."},

    ; ============================================================
    ; Cache Limits
    ; ============================================================
    {type: "section", name: "Cache",
     desc: "Cache Limits",
     long: "Size limits for internal caches to prevent unbounded memory growth."},

    {s: "Cache", k: "ExeIconMax", g: "ExeIconCacheMax", t: "int", default: 100,
     d: "Maximum number of cached exe icons. Older entries are evicted when limit is reached."},

    {s: "Cache", k: "ProcNameMax", g: "ProcNameCacheMax", t: "int", default: 200,
     d: "Maximum number of cached process names. Older entries are evicted when limit is reached."},

    ; ============================================================
    ; Komorebi Subscription Timing
    ; ============================================================
    {type: "section", name: "KomorebiSub",
     desc: "Komorebi Subscription Timing",
     long: "Event-driven komorebi integration via named pipe."},

    {s: "KomorebiSub", k: "PollMs", g: "KomorebiSubPollMs", t: "int", default: 50,
     d: "Pipe poll interval (checking for incoming data)"},

    {s: "KomorebiSub", k: "IdleRecycleMs", g: "KomorebiSubIdleRecycleMs", t: "int", default: 120000,
     d: "Restart subscription if no events for this long (stale detection)"},

    {s: "KomorebiSub", k: "FallbackPollMs", g: "KomorebiSubFallbackPollMs", t: "int", default: 2000,
     d: "Fallback polling interval if subscription fails"},

    {s: "KomorebiSub", k: "CacheMaxAgeMs", g: "KomorebiSubCacheMaxAgeMs", t: "int", default: 10000,
     d: "Maximum age (ms) for cached workspace assignments before they are considered stale. Lower values track rapid workspace switching more accurately. Range: 1000-60000."},

    {s: "KomorebiSub", k: "BatchCloakEventsMs", g: "KomorebiSubBatchCloakEventsMs", t: "int", default: 50,
     d: "Batch cloak/uncloak events during workspace switches (ms). 0 = disabled, push immediately."},

    ; ============================================================
    ; Heartbeat & Connection Health
    ; ============================================================
    {type: "section", name: "Heartbeat",
     desc: "Heartbeat & Connection Health",
     long: "Store broadcasts heartbeat to clients for liveness detection."},

    {s: "Heartbeat", k: "StoreIntervalMs", g: "StoreHeartbeatIntervalMs", t: "int", default: 5000,
     d: "Store sends heartbeat every N ms"},

    {s: "Heartbeat", k: "ViewerTimeoutMs", g: "ViewerHeartbeatTimeoutMs", t: "int", default: 12000,
     d: "Viewer considers connection dead after N ms without any message"},

    ; ============================================================
    ; Viewer Settings
    ; ============================================================
    {type: "section", name: "Viewer",
     desc: "Viewer Settings",
     long: "Debug viewer GUI options."},

    {s: "Viewer", k: "DebugLog", g: "DebugViewerLog", t: "bool", default: false,
     d: "Enable verbose logging to error log"},

    {s: "Viewer", k: "AutoStartStore", g: "ViewerAutoStartStore", t: "bool", default: false,
     d: "Auto-start store_server if not running when viewer connects"},

    ; ============================================================
    ; Diagnostics
    ; ============================================================
    {type: "section", name: "Diagnostics",
     desc: "Diagnostics",
     long: "Debug options for troubleshooting. All disabled by default to minimize disk I/O and resource usage."},

    {s: "Diagnostics", k: "ChurnLog", g: "DiagChurnLog", t: "bool", default: false,
     d: "Log revision bump sources to %TEMP%\\tabby_store_error.log. Use when store rev is churning rapidly when idle."},

    {s: "Diagnostics", k: "KomorebiLog", g: "DiagKomorebiLog", t: "bool", default: false,
     d: "Log komorebi subscription events to %TEMP%\\tabby_ksub_diag.log. Use when workspace tracking has issues."},

    {s: "Diagnostics", k: "AltTabTooltips", g: "DebugAltTabTooltips", t: "bool", default: false,
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

    {s: "Diagnostics", k: "LauncherLog", g: "DiagLauncherLog", t: "bool", default: false,
     d: "Log launcher startup to %TEMP%\\tabby_launcher.log. Use when debugging startup issues, subprocess launch, or mutex problems."},

    {s: "Diagnostics", k: "IPCLog", g: "DiagIPCLog", t: "bool", default: false,
     d: "Log IPC pipe operations to %TEMP%\\tabby_ipc.log. Use when debugging store-GUI communication issues."},

    {s: "Diagnostics", k: "PaintTimingLog", g: "DiagPaintTimingLog", t: "bool", default: false,
     d: "Log GUI paint timing to %TEMP%\\tabby_paint_timing.log. Use when debugging slow overlay rendering after extended idle."},

    ; ============================================================
    ; Testing
    ; ============================================================
    {type: "section", name: "Testing",
     desc: "Testing",
     long: "Options for automated test suite."},

    {s: "Testing", k: "LiveDurationSec", g: "TestLiveDurationSec_Default", t: "int", default: 30,
     d: "Default duration for test_live.ahk"},

    ; ============================================================
    ; Setup (First-Run & Installation)
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
     d: "Unique installation ID (8-char hex). Generated on first run. Used for mutex naming and admin task identification."}
]
