#Requires AutoHotkey v2.0

; ============================================================
; Config Loader - Registry-driven INI support
; ============================================================
; Single source of truth: config.ahk defines defaults, this file
; defines the registry (section/key/type mappings) and handles
; INI generation and loading.
;
; To add a new config:
; 1. Add the default value in config.ahk
; 2. Add an entry to gConfigRegistry below
; 3. Add a case in _CL_ReadGlobal() and _CL_WriteGlobal()
; ============================================================

global gConfigIniPath := ""
global gConfigLoaded := false

; ============================================================
; CONFIG REGISTRY
; ============================================================
; Each entry: {s: section, k: key, g: globalName, t: type, d: description}
; Types: "string", "int", "float", "bool"

global gConfigRegistry := [
    ; === Alt-Tab Behavior (most likely to edit) ===
    {s: "AltTab", k: "GraceMs", g: "AltTabGraceMs", t: "int", d: "Grace period before showing GUI (ms)"},
    {s: "AltTab", k: "QuickSwitchMs", g: "AltTabQuickSwitchMs", t: "int", d: "Max time for quick switch without GUI (ms)"},
    {s: "AltTab", k: "PrewarmOnAlt", g: "AltTabPrewarmOnAlt", t: "bool", d: "Pre-warm snapshot on Alt down"},
    {s: "AltTab", k: "FreezeWindowList", g: "FreezeWindowList", t: "bool", d: "Freeze list on first Tab (true=stable, false=live)"},
    {s: "AltTab", k: "UseCurrentWSProjection", g: "UseCurrentWSProjection", t: "bool", d: "Use server-side workspace filtering"},

    ; === GUI Appearance ===
    {s: "GUI", k: "AcrylicAlpha", g: "GUI_AcrylicAlpha", t: "int", d: "Background transparency (hex)"},
    {s: "GUI", k: "AcrylicBaseRgb", g: "GUI_AcrylicBaseRgb", t: "int", d: "Background tint color (hex RGB)"},
    {s: "GUI", k: "CornerRadiusPx", g: "GUI_CornerRadiusPx", t: "int", d: "Window corner radius"},
    {s: "GUI", k: "ScreenWidthPct", g: "GUI_ScreenWidthPct", t: "float", d: "GUI width as fraction of screen"},
    {s: "GUI", k: "RowsVisibleMin", g: "GUI_RowsVisibleMin", t: "int", d: "Minimum visible rows"},
    {s: "GUI", k: "RowsVisibleMax", g: "GUI_RowsVisibleMax", t: "int", d: "Maximum visible rows"},
    {s: "GUI", k: "RowHeight", g: "GUI_RowHeight", t: "int", d: "Height of each row (px)"},
    {s: "GUI", k: "IconSize", g: "GUI_IconSize", t: "int", d: "Icon size (px)"},
    {s: "GUI", k: "ShowHeader", g: "GUI_ShowHeader", t: "bool", d: "Show column headers"},
    {s: "GUI", k: "ShowFooter", g: "GUI_ShowFooter", t: "bool", d: "Show footer bar"},
    {s: "GUI", k: "ShowCloseButton", g: "GUI_ShowCloseButton", t: "bool", d: "Show close button on hover"},
    {s: "GUI", k: "ShowKillButton", g: "GUI_ShowKillButton", t: "bool", d: "Show kill button on hover"},
    {s: "GUI", k: "ShowBlacklistButton", g: "GUI_ShowBlacklistButton", t: "bool", d: "Show blacklist button on hover"},
    {s: "GUI", k: "ScrollKeepHighlightOnTop", g: "GUI_ScrollKeepHighlightOnTop", t: "bool", d: "Keep selection at top when scrolling"},
    {s: "GUI", k: "EmptyListText", g: "GUI_EmptyListText", t: "string", d: "Text shown when no windows"},

    ; === IPC ===
    {s: "IPC", k: "StorePipeName", g: "StorePipeName", t: "string", d: "Named pipe for store communication"},

    ; === Tools ===
    {s: "Tools", k: "AhkV2Path", g: "AhkV2Path", t: "string", d: "Path to AHK v2 executable"},
    {s: "Tools", k: "KomorebicExe", g: "KomorebicExe", t: "string", d: "Path to komorebic.exe"},

    ; === Producers ===
    {s: "Producers", k: "UseKomorebiSub", g: "UseKomorebiSub", t: "bool", d: "Enable komorebi subscription"},
    {s: "Producers", k: "UseKomorebiLite", g: "UseKomorebiLite", t: "bool", d: "Enable komorebi polling fallback"},
    {s: "Producers", k: "UseIconPump", g: "UseIconPump", t: "bool", d: "Enable icon resolution"},
    {s: "Producers", k: "UseProcPump", g: "UseProcPump", t: "bool", d: "Enable process name resolution"},

    ; === Filtering ===
    {s: "Filtering", k: "UseAltTabEligibility", g: "UseAltTabEligibility", t: "bool", d: "Filter like native Alt-Tab"},
    {s: "Filtering", k: "UseBlacklist", g: "UseBlacklist", t: "bool", d: "Apply blacklist filtering"},

    ; === WinEventHook ===
    {s: "WinEventHook", k: "DebounceMs", g: "WinEventHookDebounceMs", t: "int", d: "Event debounce time (ms)"},
    {s: "WinEventHook", k: "BatchMs", g: "WinEventHookBatchMs", t: "int", d: "Batch processing interval (ms)"},

    ; === ZPump ===
    {s: "ZPump", k: "IntervalMs", g: "ZPumpIntervalMs", t: "int", d: "Z-order pump interval (ms)"},

    ; === WinEnum ===
    {s: "WinEnum", k: "SafetyPollMs", g: "WinEnumSafetyPollMs", t: "int", d: "Safety polling interval (0=disabled)"},

    ; === MruLite ===
    {s: "MruLite", k: "PollMs", g: "MruLitePollMs", t: "int", d: "MRU fallback poll interval (ms)"},

    ; === IconPump ===
    {s: "IconPump", k: "IntervalMs", g: "IconPumpIntervalMs", t: "int", d: "Icon pump interval (ms)"},
    {s: "IconPump", k: "BatchSize", g: "IconPumpBatchSize", t: "int", d: "Icons per batch"},
    {s: "IconPump", k: "MaxAttempts", g: "IconPumpMaxAttempts", t: "int", d: "Max retry attempts"},
    {s: "IconPump", k: "SkipHidden", g: "IconPumpSkipHidden", t: "bool", d: "Skip hidden windows"},
    {s: "IconPump", k: "IdleBackoffMs", g: "IconPumpIdleBackoffMs", t: "int", d: "Idle backoff (ms)"},
    {s: "IconPump", k: "AttemptBackoffMs", g: "IconPumpAttemptBackoffMs", t: "int", d: "Per-attempt backoff (ms)"},
    {s: "IconPump", k: "BackoffMultiplier", g: "IconPumpBackoffMultiplier", t: "float", d: "Backoff multiplier"},

    ; === ProcPump ===
    {s: "ProcPump", k: "IntervalMs", g: "ProcPumpIntervalMs", t: "int", d: "Process pump interval (ms)"},
    {s: "ProcPump", k: "BatchSize", g: "ProcPumpBatchSize", t: "int", d: "PIDs per batch"},

    ; === KomorebiSub ===
    {s: "KomorebiSub", k: "PollMs", g: "KomorebiSubPollMs", t: "int", d: "Pipe poll interval (ms)"},
    {s: "KomorebiSub", k: "IdleRecycleMs", g: "KomorebiSubIdleRecycleMs", t: "int", d: "Restart if idle (ms)"},
    {s: "KomorebiSub", k: "FallbackPollMs", g: "KomorebiSubFallbackPollMs", t: "int", d: "Fallback poll interval (ms)"},

    ; === Heartbeat ===
    {s: "Heartbeat", k: "StoreIntervalMs", g: "StoreHeartbeatIntervalMs", t: "int", d: "Store heartbeat interval (ms)"},
    {s: "Heartbeat", k: "ViewerTimeoutMs", g: "ViewerHeartbeatTimeoutMs", t: "int", d: "Viewer timeout (ms)"},

    ; === Viewer ===
    {s: "Viewer", k: "DebugLog", g: "DebugViewerLog", t: "bool", d: "Enable viewer debug logging"},
    {s: "Viewer", k: "AutoStartStore", g: "ViewerAutoStartStore", t: "bool", d: "Auto-start store if not running"},

    ; === Diagnostics ===
    {s: "Diagnostics", k: "ChurnLog", g: "DiagChurnLog", t: "bool", d: "Log rev bump sources"},
    {s: "Diagnostics", k: "KomorebiLog", g: "DiagKomorebiLog", t: "bool", d: "Log komorebi events"},
    {s: "Diagnostics", k: "AltTabTooltips", g: "DebugAltTabTooltips", t: "bool", d: "Show Alt-Tab debug tooltips"},

    ; === Testing ===
    {s: "Testing", k: "LiveDurationSec", g: "TestLiveDurationSec_Default", t: "int", d: "Default live test duration"}
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

    if (!FileExist(gConfigIniPath)) {
        _CL_CreateDefaultIni(gConfigIniPath)
    }

    _CL_LoadAllSettings()
    gConfigLoaded := true
}

; Get the config registry (for future config editor)
ConfigLoader_GetRegistry() {
    global gConfigRegistry
    return gConfigRegistry
}

; ============================================================
; INI GENERATION (reads defaults from globals)
; ============================================================

_CL_CreateDefaultIni(path) {
    global gConfigRegistry

    content := "; Alt-Tabby Configuration`n"
    content .= "; Uncomment and edit values to customize. Delete a line to use defaults.`n"
    content .= "; Changes take effect on next startup.`n"
    content .= "`n"

    ; Group entries by section
    sections := Map()
    for _, cfg in gConfigRegistry {
        if (!sections.Has(cfg.s))
            sections[cfg.s] := []
        sections[cfg.s].Push(cfg)
    }

    ; Define section order (most important first)
    sectionOrder := ["AltTab", "GUI", "IPC", "Tools", "Producers", "Filtering",
                     "WinEventHook", "ZPump", "WinEnum", "MruLite",
                     "IconPump", "ProcPump", "KomorebiSub",
                     "Heartbeat", "Viewer", "Diagnostics", "Testing"]

    for _, sect in sectionOrder {
        if (!sections.Has(sect))
            continue

        content .= "[" sect "]`n"

        for _, cfg in sections[sect] {
            ; Read current default value from the global
            defaultVal := _CL_ReadGlobal(cfg.g, cfg.t)

            ; Add description as comment
            content .= "; " cfg.d "`n"

            ; Add setting (commented out so defaults are used)
            content .= "; " cfg.k "=" _CL_FormatValue(defaultVal, cfg.t) "`n"
        }
        content .= "`n"
    }

    try FileAppend(content, path, "UTF-8")
}

_CL_FormatValue(val, type) {
    if (type = "bool")
        return val ? "true" : "false"
    if (type = "int" && IsInteger(val) && val >= 0x10)
        return Format("0x{:X}", val)  ; Hex for large ints (colors, etc.)
    return String(val)
}

; ============================================================
; INI LOADING
; ============================================================

_CL_LoadAllSettings() {
    global gConfigIniPath, gConfigRegistry

    for _, cfg in gConfigRegistry {
        val := IniRead(gConfigIniPath, cfg.s, cfg.k, "")
        if (val = "")
            continue

        ; Parse value based on type
        switch cfg.t {
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

        _CL_WriteGlobal(cfg.g, parsedVal)
    }
}

; ============================================================
; GLOBAL ACCESS HELPERS
; ============================================================
; AHK v2 requires explicit global declarations, so we use switch
; statements to access globals by name. This is the only place
; these switch statements exist - the rest of the code is data-driven.

_CL_ReadGlobal(name, type := "string") {
    ; Declare all globals at function scope first
    global AltTabGraceMs, AltTabQuickSwitchMs, AltTabPrewarmOnAlt, FreezeWindowList, UseCurrentWSProjection
    global GUI_AcrylicAlpha, GUI_AcrylicBaseRgb, GUI_CornerRadiusPx, GUI_ScreenWidthPct
    global GUI_RowsVisibleMin, GUI_RowsVisibleMax, GUI_RowHeight, GUI_IconSize
    global GUI_ShowHeader, GUI_ShowFooter, GUI_ShowCloseButton, GUI_ShowKillButton, GUI_ShowBlacklistButton
    global GUI_ScrollKeepHighlightOnTop, GUI_EmptyListText
    global StorePipeName, AhkV2Path, KomorebicExe
    global UseKomorebiSub, UseKomorebiLite, UseIconPump, UseProcPump
    global UseAltTabEligibility, UseBlacklist
    global WinEventHookDebounceMs, WinEventHookBatchMs, ZPumpIntervalMs, WinEnumSafetyPollMs, MruLitePollMs
    global IconPumpIntervalMs, IconPumpBatchSize, IconPumpMaxAttempts, IconPumpSkipHidden
    global IconPumpIdleBackoffMs, IconPumpAttemptBackoffMs, IconPumpBackoffMultiplier
    global ProcPumpIntervalMs, ProcPumpBatchSize
    global KomorebiSubPollMs, KomorebiSubIdleRecycleMs, KomorebiSubFallbackPollMs
    global StoreHeartbeatIntervalMs, ViewerHeartbeatTimeoutMs
    global DebugViewerLog, ViewerAutoStartStore
    global DiagChurnLog, DiagKomorebiLog, DebugAltTabTooltips
    global TestLiveDurationSec_Default

    switch name {
        case "AltTabGraceMs": return AltTabGraceMs
        case "AltTabQuickSwitchMs": return AltTabQuickSwitchMs
        case "AltTabPrewarmOnAlt": return AltTabPrewarmOnAlt
        case "FreezeWindowList": return FreezeWindowList
        case "UseCurrentWSProjection": return UseCurrentWSProjection
        case "GUI_AcrylicAlpha": return GUI_AcrylicAlpha
        case "GUI_AcrylicBaseRgb": return GUI_AcrylicBaseRgb
        case "GUI_CornerRadiusPx": return GUI_CornerRadiusPx
        case "GUI_ScreenWidthPct": return GUI_ScreenWidthPct
        case "GUI_RowsVisibleMin": return GUI_RowsVisibleMin
        case "GUI_RowsVisibleMax": return GUI_RowsVisibleMax
        case "GUI_RowHeight": return GUI_RowHeight
        case "GUI_IconSize": return GUI_IconSize
        case "GUI_ShowHeader": return GUI_ShowHeader
        case "GUI_ShowFooter": return GUI_ShowFooter
        case "GUI_ShowCloseButton": return GUI_ShowCloseButton
        case "GUI_ShowKillButton": return GUI_ShowKillButton
        case "GUI_ShowBlacklistButton": return GUI_ShowBlacklistButton
        case "GUI_ScrollKeepHighlightOnTop": return GUI_ScrollKeepHighlightOnTop
        case "GUI_EmptyListText": return GUI_EmptyListText
        case "StorePipeName": return StorePipeName
        case "AhkV2Path": return AhkV2Path
        case "KomorebicExe": return KomorebicExe
        case "UseKomorebiSub": return UseKomorebiSub
        case "UseKomorebiLite": return UseKomorebiLite
        case "UseIconPump": return UseIconPump
        case "UseProcPump": return UseProcPump
        case "UseAltTabEligibility": return UseAltTabEligibility
        case "UseBlacklist": return UseBlacklist
        case "WinEventHookDebounceMs": return WinEventHookDebounceMs
        case "WinEventHookBatchMs": return WinEventHookBatchMs
        case "ZPumpIntervalMs": return ZPumpIntervalMs
        case "WinEnumSafetyPollMs": return WinEnumSafetyPollMs
        case "MruLitePollMs": return MruLitePollMs
        case "IconPumpIntervalMs": return IconPumpIntervalMs
        case "IconPumpBatchSize": return IconPumpBatchSize
        case "IconPumpMaxAttempts": return IconPumpMaxAttempts
        case "IconPumpSkipHidden": return IconPumpSkipHidden
        case "IconPumpIdleBackoffMs": return IconPumpIdleBackoffMs
        case "IconPumpAttemptBackoffMs": return IconPumpAttemptBackoffMs
        case "IconPumpBackoffMultiplier": return IconPumpBackoffMultiplier
        case "ProcPumpIntervalMs": return ProcPumpIntervalMs
        case "ProcPumpBatchSize": return ProcPumpBatchSize
        case "KomorebiSubPollMs": return KomorebiSubPollMs
        case "KomorebiSubIdleRecycleMs": return KomorebiSubIdleRecycleMs
        case "KomorebiSubFallbackPollMs": return KomorebiSubFallbackPollMs
        case "StoreHeartbeatIntervalMs": return StoreHeartbeatIntervalMs
        case "ViewerHeartbeatTimeoutMs": return ViewerHeartbeatTimeoutMs
        case "DebugViewerLog": return DebugViewerLog
        case "ViewerAutoStartStore": return ViewerAutoStartStore
        case "DiagChurnLog": return DiagChurnLog
        case "DiagKomorebiLog": return DiagKomorebiLog
        case "DebugAltTabTooltips": return DebugAltTabTooltips
        case "TestLiveDurationSec_Default": return TestLiveDurationSec_Default
    }
    return ""
}

_CL_WriteGlobal(name, val) {
    ; Declare all globals at function scope first
    global AltTabGraceMs, AltTabQuickSwitchMs, AltTabPrewarmOnAlt, FreezeWindowList, UseCurrentWSProjection
    global GUI_AcrylicAlpha, GUI_AcrylicBaseRgb, GUI_CornerRadiusPx, GUI_ScreenWidthPct
    global GUI_RowsVisibleMin, GUI_RowsVisibleMax, GUI_RowHeight, GUI_IconSize
    global GUI_ShowHeader, GUI_ShowFooter, GUI_ShowCloseButton, GUI_ShowKillButton, GUI_ShowBlacklistButton
    global GUI_ScrollKeepHighlightOnTop, GUI_EmptyListText
    global StorePipeName, AhkV2Path, KomorebicExe
    global UseKomorebiSub, UseKomorebiLite, UseIconPump, UseProcPump
    global UseAltTabEligibility, UseBlacklist
    global WinEventHookDebounceMs, WinEventHookBatchMs, ZPumpIntervalMs, WinEnumSafetyPollMs, MruLitePollMs
    global IconPumpIntervalMs, IconPumpBatchSize, IconPumpMaxAttempts, IconPumpSkipHidden
    global IconPumpIdleBackoffMs, IconPumpAttemptBackoffMs, IconPumpBackoffMultiplier
    global ProcPumpIntervalMs, ProcPumpBatchSize
    global KomorebiSubPollMs, KomorebiSubIdleRecycleMs, KomorebiSubFallbackPollMs
    global StoreHeartbeatIntervalMs, ViewerHeartbeatTimeoutMs
    global DebugViewerLog, ViewerAutoStartStore
    global DiagChurnLog, DiagKomorebiLog, DebugAltTabTooltips
    global TestLiveDurationSec_Default

    switch name {
        case "AltTabGraceMs": AltTabGraceMs := val
        case "AltTabQuickSwitchMs": AltTabQuickSwitchMs := val
        case "AltTabPrewarmOnAlt": AltTabPrewarmOnAlt := val
        case "FreezeWindowList": FreezeWindowList := val
        case "UseCurrentWSProjection": UseCurrentWSProjection := val
        case "GUI_AcrylicAlpha": GUI_AcrylicAlpha := val
        case "GUI_AcrylicBaseRgb": GUI_AcrylicBaseRgb := val
        case "GUI_CornerRadiusPx": GUI_CornerRadiusPx := val
        case "GUI_ScreenWidthPct": GUI_ScreenWidthPct := val
        case "GUI_RowsVisibleMin": GUI_RowsVisibleMin := val
        case "GUI_RowsVisibleMax": GUI_RowsVisibleMax := val
        case "GUI_RowHeight": GUI_RowHeight := val
        case "GUI_IconSize": GUI_IconSize := val
        case "GUI_ShowHeader": GUI_ShowHeader := val
        case "GUI_ShowFooter": GUI_ShowFooter := val
        case "GUI_ShowCloseButton": GUI_ShowCloseButton := val
        case "GUI_ShowKillButton": GUI_ShowKillButton := val
        case "GUI_ShowBlacklistButton": GUI_ShowBlacklistButton := val
        case "GUI_ScrollKeepHighlightOnTop": GUI_ScrollKeepHighlightOnTop := val
        case "GUI_EmptyListText": GUI_EmptyListText := val
        case "StorePipeName": StorePipeName := val
        case "AhkV2Path": AhkV2Path := val
        case "KomorebicExe": KomorebicExe := val
        case "UseKomorebiSub": UseKomorebiSub := val
        case "UseKomorebiLite": UseKomorebiLite := val
        case "UseIconPump": UseIconPump := val
        case "UseProcPump": UseProcPump := val
        case "UseAltTabEligibility": UseAltTabEligibility := val
        case "UseBlacklist": UseBlacklist := val
        case "WinEventHookDebounceMs": WinEventHookDebounceMs := val
        case "WinEventHookBatchMs": WinEventHookBatchMs := val
        case "ZPumpIntervalMs": ZPumpIntervalMs := val
        case "WinEnumSafetyPollMs": WinEnumSafetyPollMs := val
        case "MruLitePollMs": MruLitePollMs := val
        case "IconPumpIntervalMs": IconPumpIntervalMs := val
        case "IconPumpBatchSize": IconPumpBatchSize := val
        case "IconPumpMaxAttempts": IconPumpMaxAttempts := val
        case "IconPumpSkipHidden": IconPumpSkipHidden := val
        case "IconPumpIdleBackoffMs": IconPumpIdleBackoffMs := val
        case "IconPumpAttemptBackoffMs": IconPumpAttemptBackoffMs := val
        case "IconPumpBackoffMultiplier": IconPumpBackoffMultiplier := val
        case "ProcPumpIntervalMs": ProcPumpIntervalMs := val
        case "ProcPumpBatchSize": ProcPumpBatchSize := val
        case "KomorebiSubPollMs": KomorebiSubPollMs := val
        case "KomorebiSubIdleRecycleMs": KomorebiSubIdleRecycleMs := val
        case "KomorebiSubFallbackPollMs": KomorebiSubFallbackPollMs := val
        case "StoreHeartbeatIntervalMs": StoreHeartbeatIntervalMs := val
        case "ViewerHeartbeatTimeoutMs": ViewerHeartbeatTimeoutMs := val
        case "DebugViewerLog": DebugViewerLog := val
        case "ViewerAutoStartStore": ViewerAutoStartStore := val
        case "DiagChurnLog": DiagChurnLog := val
        case "DiagKomorebiLog": DiagKomorebiLog := val
        case "DebugAltTabTooltips": DebugAltTabTooltips := val
        case "TestLiveDurationSec_Default": TestLiveDurationSec_Default := val
    }
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
