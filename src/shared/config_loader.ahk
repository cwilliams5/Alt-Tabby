#Requires AutoHotkey v2.0

; ============================================================
; Config Loader - Registry-driven Configuration System
; ============================================================
; Loads and saves configuration from config.ini using the
; registry definitions from config_registry.ahk.
;
; To add a new config:
; 1. Add an entry to gConfigRegistry in config_registry.ahk
; 2. That's it! The value is automatically available as cfg.YourConfigName
;
; Access config values via: cfg.PropertyName (e.g., cfg.AltTabGraceMs)
; ============================================================

#Include config_registry.ahk

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
    } catch as e {
        return false
    }
    return true
}

; ============================================================
; INI LOADING
; ============================================================

_CL_LoadAllSettings() {
    global gConfigIniPath, gConfigRegistry, cfg, LOG_PATH_STORE

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
                try {
                    parsedVal := Integer(val)
                } catch {
                    LogAppend(LOG_PATH_STORE, "config parse error: " entry.k "=" val " (expected int), using default")
                    continue
                }
            case "float":
                try {
                    parsedVal := Float(val)
                } catch {
                    LogAppend(LOG_PATH_STORE, "config parse error: " entry.k "=" val " (expected float), using default")
                    continue
                }
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

    ; --- Bypass Settings ---
    cfg.AltTabBypassFullscreenThreshold := clamp(cfg.AltTabBypassFullscreenThreshold, 0.90, 1.0)
    cfg.AltTabBypassFullscreenTolerancePx := clamp(cfg.AltTabBypassFullscreenTolerancePx, 0, 50)

    ; --- GUI Layout Constants ---
    cfg.GUI_IconTextGapPx := clamp(cfg.GUI_IconTextGapPx, 0, 50)
    cfg.GUI_ColumnGapPx := clamp(cfg.GUI_ColumnGapPx, 0, 50)
    cfg.GUI_HeaderHeightPx := clamp(cfg.GUI_HeaderHeightPx, 16, 60)

    ; --- Timing Settings (prevent CPU hogging or unresponsive behavior) ---
    cfg.AltTabGraceMs := clamp(cfg.AltTabGraceMs, 0, 2000)
    cfg.AltTabQuickSwitchMs := clamp(cfg.AltTabQuickSwitchMs, 0, 1000)
    cfg.AltTabAsyncActivationPollMs := clamp(cfg.AltTabAsyncActivationPollMs, 10, 100)
    cfg.AltTabAltLeewayMs := clamp(cfg.AltTabAltLeewayMs, 20, 200)

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
    cfg.KomorebiSubBatchCloakEventsMs := clamp(cfg.KomorebiSubBatchCloakEventsMs, 0, 500)
    cfg.KomorebiSubCacheMaxAgeMs := clamp(cfg.KomorebiSubCacheMaxAgeMs, 1000, 60000)

    ; --- WinEnum Settings ---
    cfg.WinEnumMissingWindowTTLMs := clamp(cfg.WinEnumMissingWindowTTLMs, 100, 10000)
    cfg.WinEnumFallbackScanIntervalMs := clamp(cfg.WinEnumFallbackScanIntervalMs, 500, 10000)

    ; --- Icon Pump GiveUp ---
    cfg.IconPumpGiveUpBackoffMs := clamp(cfg.IconPumpGiveUpBackoffMs, 1000, 30000)

    ; --- IPC Settings ---
    cfg.IPCIdleTickMs := clamp(cfg.IPCIdleTickMs, 15, 500)
    global IPC_TICK_IDLE
    IPC_TICK_IDLE := cfg.IPCIdleTickMs

    ; --- Heartbeat Settings ---
    cfg.StoreHeartbeatIntervalMs := clamp(cfg.StoreHeartbeatIntervalMs, 1000, 60000)
    cfg.ViewerHeartbeatTimeoutMs := clamp(cfg.ViewerHeartbeatTimeoutMs, 2000, 120000)

    ; --- Launcher Settings ---
    cfg.LauncherSplashDurationMs := clamp(cfg.LauncherSplashDurationMs, 0, 10000)
    cfg.LauncherSplashFadeMs := clamp(cfg.LauncherSplashFadeMs, 0, 2000)
}

; ============================================================
; BLACKLIST HELPER
; ============================================================
; NOTE: Default blacklist creation is handled by _Blacklist_CreateDefault()
; in src/shared/blacklist.ahk. This section retained for documentation.

; ============================================================
; LOG PATH HELPERS
; ============================================================
; Centralized log path generation to avoid hardcoded paths throughout codebase.
; All log files go to A_Temp with "tabby_" prefix for easy identification.

global LOG_PATH_EVENTS     := A_Temp "\tabby_events.log"
global LOG_PATH_LAUNCHER   := A_Temp "\tabby_launcher.log"
global LOG_PATH_STORE      := A_Temp "\tabby_store_error.log"
global LOG_PATH_ICONPUMP   := A_Temp "\tabby_iconpump.log"
global LOG_PATH_KSUB       := A_Temp "\tabby_ksub_diag.log"
global LOG_PATH_WINEVENT   := A_Temp "\tabby_weh_focus.log"
global LOG_PATH_PROCPUMP   := A_Temp "\tabby_procpump.log"
global LOG_PATH_IPC        := A_Temp "\tabby_ipc.log"
global LOG_PATH_VIEWER     := A_Temp "\tabby_viewer.log"

; Format a timestamp for log entries (consistent across all loggers)
; Format: "HH:mm:ss.xxx" where xxx is milliseconds from tick count
GetLogTimestamp() {
    return FormatTime(, "HH:mm:ss") "." SubStr("000" Mod(A_TickCount, 1000), -2)
}

; Write a log entry with timestamp to the specified file
; Usage: LogAppend(LOG_PATH_EVENTS, "Event occurred")
LogAppend(logPath, msg) {
    ts := GetLogTimestamp()
    try FileAppend(ts " " msg "`n", logPath, "UTF-8")
}

; Initialize a log session (delete old log, write header)
; Usage: LogInitSession(LOG_PATH_EVENTS, "Alt-Tabby Event Log")
LogInitSession(logPath, title) {
    try FileDelete(logPath)
    header := "=== " title " - " FormatTime(, "yyyy-MM-dd HH:mm:ss") " ===`n"
    header .= "Log file: " logPath "`n`n"
    try FileAppend(header, logPath, "UTF-8")
}

; ============================================================
; TIMING CONSTANTS
; ============================================================
; Centralized timing values to avoid magic numbers throughout codebase.
; These are operational delays, not user-configurable settings.

; Sleep delays (milliseconds)
global TIMING_PROCESS_EXIT_WAIT := 500    ; Wait for processes to fully exit
global TIMING_MUTEX_RELEASE_WAIT := 500   ; Wait for mutex to be released
global TIMING_TASK_READY_WAIT := 500      ; Wait for scheduled task to be ready
global TIMING_SUBPROCESS_LAUNCH := 300    ; Brief delay before launching subprocess
global TIMING_STORE_START_WAIT := 1000    ; Wait for store to start

; Tooltip durations (milliseconds, negative for one-shot timer)
global TOOLTIP_DURATION_SHORT := 1500     ; Quick feedback tooltips
global TOOLTIP_DURATION_DEFAULT := 2000   ; Standard tooltip duration
global TOOLTIP_DURATION_LONG := 3000      ; Extended tooltip for important messages

; Retry limits
global MAX_RECONNECT_ATTEMPTS := 3        ; Pipe reconnection attempts before restart
global MAX_RESTART_ATTEMPTS := 2          ; Store restart attempts before giving up

; ============================================================
; TOOLTIP HELPER
; ============================================================
; Schedule tooltip to hide after specified duration.
; Usage: HideTooltipAfter(2000) or HideTooltipAfter(TOOLTIP_DURATION_DEFAULT)
HideTooltipAfter(durationMs := 2000) {
    SetTimer(() => ToolTip(), -durationMs)
}

; ============================================================
; OBJECT/MAP HELPER
; ============================================================
; Safely get a property from an object or Map with a default fallback.
; Handles both obj.key and obj["key"] access patterns.
; Usage: val := GetProp(obj, "key", "default")
GetProp(obj, key, defaultVal := "") {
    if (!IsObject(obj))
        return defaultVal
    if (obj is Map)
        return obj.Has(key) ? obj[key] : defaultVal
    return obj.HasOwnProp(key) ? obj.%key% : defaultVal
}
