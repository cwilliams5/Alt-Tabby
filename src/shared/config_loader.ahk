#Requires AutoHotkey v2.0

; ============================================================
; Config Loader - Registry-driven Configuration System
; ============================================================
; SINGLE SOURCE OF TRUTH: gConfigRegistry contains ALL config
; definitions including defaults, types, and descriptions.
;
; To add a new config:
; 1. Add an entry to gConfigRegistry below (with default value)
; 2. That's it! The value is automatically available as cfg.YourConfigName
;
; Access config values via: cfg.PropertyName (e.g., cfg.AltTabGraceMs)
; ============================================================

global gConfigIniPath := ""
global gConfigLoaded := false

; ============================================================
; SINGLE GLOBAL CONFIG OBJECT
; ============================================================
; All config values are stored as properties on this object.
; This replaces 100+ individual global declarations.
; Dynamic property access: cfg.%name% := value

global cfg := {}

; ============================================================
; CONFIG REGISTRY - Single Source of Truth
; ============================================================
; Entry types:
;   Section:    {type: "section", name: "Name", desc: "Short", long: "Long description"}
;   Subsection: {type: "subsection", section: "Parent", name: "Name", desc: "Description"}
;   Setting:    {s: section, k: key, g: global, t: type, default: value, d: "Description"}
;
; Setting types: "string", "int", "float", "bool"

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

    {type: "subsection", section: "AltTab", name: "Bypass",
     desc: "When to let native Windows Alt-Tab handle the switch instead of Alt-Tabby"},

    {s: "AltTab", k: "BypassFullscreen", g: "AltTabBypassFullscreen", t: "bool", default: true,
     d: "Bypass Alt-Tabby when the foreground window is fullscreen (covers ≥99% of screen). Useful for games that need native Alt-Tab behavior."},

    {s: "AltTab", k: "BypassProcesses", g: "AltTabBypassProcesses", t: "string", default: "",
     d: "Comma-separated list of process names to bypass (e.g., 'game.exe,vlc.exe'). When these processes are in the foreground, native Windows Alt-Tab is used instead."},

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

    {s: "IconPump", k: "RefreshThrottleMs", g: "IconPumpRefreshThrottleMs", t: "int", default: 30000,
     d: "Minimum time between icon refresh checks for focused windows (ms). Windows can change icons (e.g., browser favicons), so we recheck WM_GETICON when focused after this delay."},

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
     d: "Set to true after first-run wizard completes."}
]

; ============================================================
; PUBLIC API
; ============================================================

; Initialize config - call this early in startup
ConfigLoader_Init(basePath := "") {
    global gConfigIniPath, gConfigLoaded

    if (basePath = "") {
        if (A_IsCompiled) {
            basePath := A_ScriptDir
        } else {
            basePath := A_ScriptDir
            if (!FileExist(basePath "\config.ini")) {
                basePath := A_ScriptDir "\.."
            }
        }
    }

    gConfigIniPath := basePath "\config.ini"

    ; Initialize all config values to defaults FIRST
    _CL_InitializeDefaults()

    if (!FileExist(gConfigIniPath)) {
        _CL_CreateDefaultIni(gConfigIniPath)
    } else {
        _CL_SupplementIni(gConfigIniPath)  ; Add missing keys
    }

    _CL_LoadAllSettings()  ; Load user overrides
    _CL_ValidateSettings() ; Clamp values to safe ranges
    gConfigLoaded := true
}

; Get the config registry (for config editor)
ConfigLoader_GetRegistry() {
    global gConfigRegistry
    return gConfigRegistry
}

; Get config value with fallback default (convenience helper)
ConfigGet(name, defaultVal := "") {
    global cfg
    return cfg.HasOwnProp(name) ? cfg.%name% : defaultVal
}

; ============================================================
; INITIALIZATION
; ============================================================

_CL_InitializeDefaults() {
    global cfg, gConfigRegistry
    for _, entry in gConfigRegistry {
        if (entry.HasOwnProp("default")) {
            cfg.%entry.g% := entry.default
        }
    }
}

; ============================================================
; INI GENERATION
; ============================================================

_CL_CreateDefaultIni(path) {
    global gConfigRegistry

    content := ";;; Alt-Tabby Configuration`n"
    content .= ";;; Settings are commented out by default (use registry defaults).`n"
    content .= ";;; Uncomment a line to customize. Delete file to restore all defaults.`n"
    content .= "`n"

    currentSection := ""

    for _, entry in gConfigRegistry {
        if (entry.HasOwnProp("type") && entry.type = "section") {
            content .= "[" entry.name "]`n"
            if (entry.HasOwnProp("long"))
                content .= ";;; " entry.long "`n"
            content .= "`n"
            currentSection := entry.name
        }
        else if (entry.HasOwnProp("type") && entry.type = "subsection") {
            content .= ";;; --- " entry.name " ---`n"
            if (entry.HasOwnProp("desc"))
                content .= ";;; " entry.desc "`n"
        }
        else if (entry.HasOwnProp("default")) {
            ; Setting - description with ;;; and default value commented out with ;
            content .= ";;; " entry.d "`n"
            content .= "; " entry.k "=" _CL_FormatValue(entry.default, entry.t) "`n"
        }
    }

    try FileAppend(content, path, "UTF-8")
}

_CL_SupplementIni(path) {
    global gConfigRegistry

    ; Read entire file
    content := FileRead(path, "UTF-8")
    lines := StrSplit(content, "`n", "`r")
    modified := false

    ; Build list of missing keys per section
    missingBySection := Map()
    for _, entry in gConfigRegistry {
        if (!entry.HasOwnProp("default"))
            continue

        ; Check if key exists (commented or uncommented)
        keyPattern := "^\s*;?\s*" entry.k "\s*="
        keyFound := false
        inSection := false

        for _, line in lines {
            trimmed := Trim(line)
            if (SubStr(trimmed, 1, 1) = "[" && SubStr(trimmed, -1) = "]") {
                sectionName := SubStr(trimmed, 2, -1)
                inSection := (sectionName = entry.s)
            } else if (inSection && RegExMatch(trimmed, keyPattern)) {
                keyFound := true
                break
            }
        }

        if (!keyFound) {
            if (!missingBySection.Has(entry.s))
                missingBySection[entry.s] := []
            missingBySection[entry.s].Push(entry)
            modified := true
        }
    }

    if (!modified)
        return

    ; Rebuild file with missing keys inserted at end of each section
    newLines := []
    currentSection := ""

    for idx, line in lines {
        trimmed := Trim(line)

        ; Detect section change
        if (SubStr(trimmed, 1, 1) = "[" && SubStr(trimmed, -1) = "]") {
            ; Before moving to new section, add missing keys to current section
            if (currentSection != "" && missingBySection.Has(currentSection)) {
                for _, entry in missingBySection[currentSection] {
                    newLines.Push(";;; " entry.d)
                    newLines.Push("; " entry.k "=" _CL_FormatValue(entry.default, entry.t))
                }
                missingBySection.Delete(currentSection)
            }
            currentSection := SubStr(trimmed, 2, -1)
        }

        newLines.Push(line)
    }

    ; Handle last section
    if (currentSection != "" && missingBySection.Has(currentSection)) {
        for _, entry in missingBySection[currentSection] {
            newLines.Push(";;; " entry.d)
            newLines.Push("; " entry.k "=" _CL_FormatValue(entry.default, entry.t))
        }
    }

    ; Add any sections that don't exist yet
    for sectionName, entries in missingBySection {
        newLines.Push("")
        newLines.Push("[" sectionName "]")
        for _, entry in entries {
            newLines.Push(";;; " entry.d)
            newLines.Push("; " entry.k "=" _CL_FormatValue(entry.default, entry.t))
        }
    }

    ; Write back safely - write to temp first, then replace
    ; Build content string (AHK v2 arrays don't have Join)
    content := ""
    for i, line in newLines {
        content .= (i > 1 ? "`n" : "") . line
    }

    tempPath := path ".tmp"
    try {
        if (FileExist(tempPath))
            FileDelete(tempPath)
        FileAppend(content, tempPath, "UTF-8")
        ; Only delete original after temp write succeeded
        FileDelete(path)
        FileMove(tempPath, path)
    } catch as e {
        ; Clean up temp file on failure
        try FileDelete(tempPath)
        throw e  ; Re-throw so caller knows it failed
    }
}

_CL_FormatValue(val, type) {
    if (type = "bool")
        return val ? "true" : "false"
    if (type = "int" && IsInteger(val) && val >= 0x10)
        return Format("0x{:X}", val)  ; Hex for large ints (colors, etc.)
    if (type = "float")
        return Format("{:.2f}", val)  ; 2 decimal places for floats
    return String(val)
}

; Write to INI preserving comments and structure (unlike IniWrite which reorganizes)
; If value equals default, comments out the line; otherwise uncomments it
_CL_WriteIniPreserveFormat(path, section, key, value, defaultVal := "", valType := "string") {
    if (!FileExist(path))
        return false

    content := FileRead(path, "UTF-8")
    lines := StrSplit(content, "`n", "`r")

    ; Determine if value equals default (should be commented out)
    formattedValue := _CL_FormatValue(value, valType)
    formattedDefault := _CL_FormatValue(defaultVal, valType)
    shouldComment := (formattedValue = formattedDefault)

    inSection := false
    keyFound := false
    newLines := []

    for i, line in lines {
        trimmed := Trim(line)

        ; Check for section headers
        if (RegExMatch(trimmed, "^\[(.+)\]$", &m)) {
            inSection := (m[1] = section)
        }

        ; Check for key in correct section (commented or uncommented)
        if (inSection && !keyFound) {
            ; Match both "; Key=" and "Key="
            if (RegExMatch(trimmed, "^;?\s*" key "\s*=")) {
                ; Found the key - replace with proper format
                if (shouldComment)
                    newLines.Push("; " key "=" formattedValue)
                else
                    newLines.Push(key "=" formattedValue)
                keyFound := true
                continue
            }
        }

        newLines.Push(line)
    }

    ; If key not found, add it at end of section
    if (!keyFound) {
        ; Find end of section and insert there
        newLines2 := []
        inSection := false
        added := false

        for i, line in newLines {
            trimmed := Trim(line)

            if (RegExMatch(trimmed, "^\[(.+)\]$", &m)) {
                ; Before entering new section, add key if we were in target section
                if (inSection && !added) {
                    if (shouldComment)
                        newLines2.Push("; " key "=" formattedValue)
                    else
                        newLines2.Push(key "=" formattedValue)
                    added := true
                }
                inSection := (m[1] = section)
            }

            newLines2.Push(line)
        }

        ; If still not added (section was last), add at end
        if (!added) {
            if (shouldComment)
                newLines2.Push("; " key "=" formattedValue)
            else
                newLines2.Push(key "=" formattedValue)
        }

        newLines := newLines2
    }

    ; Write back the file
    newContent := ""
    for i, line in newLines {
        newContent .= line
        if (i < newLines.Length)
            newContent .= "`n"
    }

    try {
        FileDelete(path)
        FileAppend(newContent, path, "UTF-8")
    }
    return true
}

; ============================================================
; INI LOADING
; ============================================================

_CL_LoadAllSettings() {
    global gConfigIniPath, gConfigRegistry, cfg

    for _, entry in gConfigRegistry {
        if (!entry.HasOwnProp("default"))
            continue  ; Skip section/subsection headers

        val := IniRead(gConfigIniPath, entry.s, entry.k, "")
        if (val = "")
            continue

        ; Parse value based on type
        switch entry.t {
            case "bool":
                parsedVal := (val = "true" || val = "1" || val = "yes")
            case "int":
                ; Handle hex values
                if (SubStr(val, 1, 2) = "0x")
                    parsedVal := Integer(val)
                else
                    parsedVal := Integer(val)
            case "float":
                parsedVal := Float(val)
            default:
                parsedVal := val
        }

        cfg.%entry.g% := parsedVal
    }
}

; ============================================================
; CONFIG VALIDATION
; ============================================================
; Clamp numeric values to safe ranges to prevent crashes from invalid config

_CL_ValidateSettings() {
    global cfg

    ; Helper to clamp a value to a range
    clamp := (val, minVal, maxVal) => Max(minVal, Min(maxVal, val))

    ; --- GUI Size Settings (prevent division by zero, rendering issues) ---
    cfg.GUI_RowHeight := clamp(cfg.GUI_RowHeight, 20, 200)
    cfg.GUI_ScreenWidthPct := clamp(cfg.GUI_ScreenWidthPct, 0.1, 1.0)
    cfg.GUI_RowsVisibleMin := clamp(cfg.GUI_RowsVisibleMin, 1, 20)
    cfg.GUI_RowsVisibleMax := clamp(cfg.GUI_RowsVisibleMax, 1, 50)
    cfg.GUI_IconSize := clamp(cfg.GUI_IconSize, 8, 256)
    cfg.GUI_MarginX := clamp(cfg.GUI_MarginX, 0, 200)
    cfg.GUI_MarginY := clamp(cfg.GUI_MarginY, 0, 200)
    cfg.GUI_CornerRadiusPx := clamp(cfg.GUI_CornerRadiusPx, 0, 100)
    cfg.GUI_RowRadius := clamp(cfg.GUI_RowRadius, 0, 50)

    ; Ensure RowsVisibleMin <= RowsVisibleMax
    if (cfg.GUI_RowsVisibleMin > cfg.GUI_RowsVisibleMax)
        cfg.GUI_RowsVisibleMin := cfg.GUI_RowsVisibleMax

    ; --- Action Button Settings ---
    cfg.GUI_ActionBtnSizePx := clamp(cfg.GUI_ActionBtnSizePx, 12, 64)
    cfg.GUI_ActionBtnGapPx := clamp(cfg.GUI_ActionBtnGapPx, 0, 50)
    cfg.GUI_ActionBtnRadiusPx := clamp(cfg.GUI_ActionBtnRadiusPx, 0, 32)
    cfg.GUI_ActionFontSize := clamp(cfg.GUI_ActionFontSize, 8, 48)

    ; --- Font Sizes ---
    cfg.GUI_HdrFontSize := clamp(cfg.GUI_HdrFontSize, 6, 48)
    cfg.GUI_MainFontSize := clamp(cfg.GUI_MainFontSize, 8, 72)
    cfg.GUI_MainFontSizeHi := clamp(cfg.GUI_MainFontSizeHi, 8, 72)
    cfg.GUI_SubFontSize := clamp(cfg.GUI_SubFontSize, 6, 48)
    cfg.GUI_SubFontSizeHi := clamp(cfg.GUI_SubFontSizeHi, 6, 48)
    cfg.GUI_ColFontSize := clamp(cfg.GUI_ColFontSize, 6, 48)
    cfg.GUI_ColFontSizeHi := clamp(cfg.GUI_ColFontSizeHi, 6, 48)
    cfg.GUI_FooterFontSize := clamp(cfg.GUI_FooterFontSize, 6, 48)
    cfg.GUI_FooterHeightPx := clamp(cfg.GUI_FooterHeightPx, 0, 100)

    ; --- Scrollbar ---
    cfg.GUI_ScrollBarWidthPx := clamp(cfg.GUI_ScrollBarWidthPx, 2, 30)

    ; --- Timing Settings (prevent CPU hogging or unresponsive behavior) ---
    cfg.AltTabGraceMs := clamp(cfg.AltTabGraceMs, 0, 2000)
    cfg.AltTabQuickSwitchMs := clamp(cfg.AltTabQuickSwitchMs, 0, 1000)

    ; --- Producer Intervals (min 10ms to prevent CPU spin) ---
    cfg.WinEventHookDebounceMs := clamp(cfg.WinEventHookDebounceMs, 10, 1000)
    cfg.WinEventHookBatchMs := clamp(cfg.WinEventHookBatchMs, 10, 2000)
    cfg.ZPumpIntervalMs := clamp(cfg.ZPumpIntervalMs, 50, 5000)
    cfg.MruLitePollMs := clamp(cfg.MruLitePollMs, 50, 5000)
    cfg.IconPumpIntervalMs := clamp(cfg.IconPumpIntervalMs, 20, 1000)
    cfg.IconPumpBatchSize := clamp(cfg.IconPumpBatchSize, 1, 100)
    cfg.IconPumpMaxAttempts := clamp(cfg.IconPumpMaxAttempts, 1, 20)
    cfg.IconPumpAttemptBackoffMs := clamp(cfg.IconPumpAttemptBackoffMs, 50, 5000)
    cfg.IconPumpBackoffMultiplier := clamp(cfg.IconPumpBackoffMultiplier, 1.0, 5.0)
    cfg.IconPumpRefreshThrottleMs := clamp(cfg.IconPumpRefreshThrottleMs, 1000, 300000)
    cfg.ProcPumpIntervalMs := clamp(cfg.ProcPumpIntervalMs, 20, 1000)
    cfg.ProcPumpBatchSize := clamp(cfg.ProcPumpBatchSize, 1, 100)
    cfg.KomorebiSubPollMs := clamp(cfg.KomorebiSubPollMs, 10, 1000)
    cfg.KomorebiSubIdleRecycleMs := clamp(cfg.KomorebiSubIdleRecycleMs, 10000, 600000)
    cfg.KomorebiSubFallbackPollMs := clamp(cfg.KomorebiSubFallbackPollMs, 500, 30000)

    ; --- Heartbeat Settings ---
    cfg.StoreHeartbeatIntervalMs := clamp(cfg.StoreHeartbeatIntervalMs, 1000, 60000)
    cfg.ViewerHeartbeatTimeoutMs := clamp(cfg.ViewerHeartbeatTimeoutMs, 2000, 120000)

    ; --- Launcher Settings ---
    cfg.LauncherSplashDurationMs := clamp(cfg.LauncherSplashDurationMs, 0, 10000)
    cfg.LauncherSplashFadeMs := clamp(cfg.LauncherSplashFadeMs, 0, 2000)
}

; ============================================================
; GLOBAL ACCESS HELPERS (for config editor compatibility)
; ============================================================
; These use dynamic property access - no switch statements needed!

_CL_ReadGlobal(name, type := "string") {
    global cfg
    return cfg.HasOwnProp(name) ? cfg.%name% : ""
}

_CL_WriteGlobal(name, val) {
    global cfg
    cfg.%name% := val
}

; ============================================================
; BLACKLIST HELPER
; ============================================================

ConfigLoader_CreateDefaultBlacklist(path) {
    if (FileExist(path))
        return true

    content := "; Alt-Tabby Blacklist Configuration`n"
    content .= "; Windows matching these patterns are excluded from the window list.`n"
    content .= "; Wildcards: * (any chars), ? (single char) - case-insensitive`n"
    content .= ";`n"
    content .= "; To blacklist a window from the viewer, click the X button on its row.`n"
    content .= "`n"
    content .= "[Title]`n"
    content .= "komoborder*`n"
    content .= "YasbBar`n"
    content .= "NVIDIA GeForce Overlay`n"
    content .= "DWM Notification Window`n"
    content .= "MSCTFIME UI`n"
    content .= "Default IME`n"
    content .= "Task Switching`n"
    content .= "Command Palette`n"
    content .= "GDI+ Window*`n"
    content .= "Windows Input Experience`n"
    content .= "Program Manager`n"
    content .= "`n"
    content .= "[Class]`n"
    content .= "komoborder*`n"
    content .= "CEF-OSC-WIDGET`n"
    content .= "Dwm`n"
    content .= "MSCTFIME UI`n"
    content .= "IME`n"
    content .= "MSTaskSwWClass`n"
    content .= "MSTaskListWClass`n"
    content .= "Shell_TrayWnd`n"
    content .= "Shell_SecondaryTrayWnd`n"
    content .= "GDI+ Hook Window Class`n"
    content .= "XamlExplorerHostIslandWindow`n"
    content .= "WinUIDesktopWin32WindowClass`n"
    content .= "Windows.UI.Core.CoreWindow`n"
    content .= "Qt*QWindow*`n"
    content .= "AutoHotkeyGUI`n"
    content .= "`n"
    content .= "[Pair]`n"
    content .= "; Format: Class|Title (both must match)`n"
    content .= "GDI+ Hook Window Class|GDI+ Window*`n"

    try {
        FileAppend(content, path, "UTF-8")
        return true
    } catch {
        return false
    }
}
