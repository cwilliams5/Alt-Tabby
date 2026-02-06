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
; CONFIG INITIALIZATION SAFETY
; ============================================================
; Assert that ConfigLoader_Init() has been called before accessing cfg.
; Use in module Start() functions to catch initialization order bugs early.

_CL_AssertInitialized(caller := "") {
    global gConfigLoaded
    if (!gConfigLoaded) {
        msg := "ConfigLoader_Init() must be called before "
        msg .= caller ? caller : "accessing cfg"
        throw Error(msg)
    }
}

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
; readOnly: if true, skip modifying existing config.ini (supplement/cleanup). Use for
;           tests to avoid file contention when multiple processes run in parallel.
;           Note: Creating a NEW config.ini is always allowed (no contention risk).
ConfigLoader_Init(basePath := "", readOnly := false) {
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

    global STATS_INI_PATH
    STATS_INI_PATH := basePath "\stats.ini"

    ; Initialize all config values to defaults FIRST
    _CL_InitializeDefaults()

    if (!FileExist(gConfigIniPath)) {
        ; Creating a new file is always safe (no contention - first writer wins)
        _CL_CreateDefaultIni(gConfigIniPath)
    } else if (!readOnly) {
        ; Only modify existing files if not in readOnly mode
        ; This avoids contention when multiple test processes run in parallel
        _CL_SupplementIni(gConfigIniPath)  ; Add missing keys
        _CL_CleanupOrphanedKeys(gConfigIniPath)  ; Remove obsolete keys
    }

    _CL_LoadAllSettings()  ; Load user overrides
    _CL_ValidateSettings() ; Clamp values to safe ranges
    gConfigLoaded := true

    ; Cache frequently-accessed config values for hot paths
    ; Config changes trigger full process restart, so cache invalidation is automatic
    _CL_CacheHotPathValues()
}

; ============================================================
; HOT PATH CACHED CONFIG VALUES
; ============================================================
; These globals cache frequently-accessed config values to avoid
; cfg.HasOwnProp() lookups in hot paths (called 30+ times per Alt-Tab).
; Config changes trigger process restart, so no invalidation needed.
; Named gCached_* to distinguish from cfg.* properties.

global gCached_MRUFreshnessMs := 300
global gCached_PrewarmWaitMs := 50
global gCached_UseAltTabEligibility := true
global gCached_UseBlacklist := true

_CL_CacheHotPathValues() {
    global cfg
    global gCached_MRUFreshnessMs, gCached_PrewarmWaitMs
    global gCached_UseAltTabEligibility, gCached_UseBlacklist

    gCached_MRUFreshnessMs := cfg.HasOwnProp("AltTabMRUFreshnessMs") ? cfg.AltTabMRUFreshnessMs : 300
    gCached_PrewarmWaitMs := cfg.HasOwnProp("AltTabPrewarmWaitMs") ? cfg.AltTabPrewarmWaitMs : 50
    gCached_UseAltTabEligibility := cfg.HasOwnProp("UseAltTabEligibility") ? cfg.UseAltTabEligibility : true
    gCached_UseBlacklist := cfg.HasOwnProp("UseBlacklist") ? cfg.UseBlacklist : true
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
        ; Atomic overwrite: MoveFileEx with MOVEFILE_REPLACE_EXISTING on NTFS
        FileMove(tempPath, path, true)
    } catch as e {
        ; Clean up temp file on failure
        try FileDelete(tempPath)
        throw e  ; Re-throw so caller knows it failed
    }
}

; Remove orphaned keys from known sections
; "Orphaned" = key exists in config.ini but not in gConfigRegistry
; Only removes from sections we own (defined in registry); unknown sections preserved
_CL_CleanupOrphanedKeys(path) {
    global gConfigRegistry

    if (!FileExist(path))
        return

    ; Build map of known sections -> known keys
    knownSections := Map()  ; section name -> Map of key names
    for _, entry in gConfigRegistry {
        if (entry.HasOwnProp("type") && entry.type = "section") {
            if (!knownSections.Has(entry.name))
                knownSections[entry.name] := Map()
        } else if (entry.HasOwnProp("s") && entry.HasOwnProp("k")) {
            if (!knownSections.Has(entry.s))
                knownSections[entry.s] := Map()
            knownSections[entry.s][entry.k] := true
        }
    }

    content := FileRead(path, "UTF-8")
    lines := StrSplit(content, "`n", "`r")

    newLines := []
    pendingComments := []  ; Buffer for ;;; comment lines before a key
    currentSection := ""
    sectionIsKnown := false
    modified := false

    for _, line in lines {
        trimmed := Trim(line)

        ; Section header
        if (SubStr(trimmed, 1, 1) = "[" && SubStr(trimmed, -1) = "]") {
            ; Flush any pending comments (they weren't followed by an orphan key)
            for _, c in pendingComments
                newLines.Push(c)
            pendingComments := []

            currentSection := SubStr(trimmed, 2, -1)
            sectionIsKnown := knownSections.Has(currentSection)
            newLines.Push(line)
            continue
        }

        ; Description comment line (;;; prefix) - buffer it
        if (SubStr(trimmed, 1, 3) = ";;;") {
            pendingComments.Push(line)
            continue
        }

        ; Key line (commented or uncommented): ; Key=... or Key=...
        if (RegExMatch(trimmed, "^;?\s*([A-Za-z_][A-Za-z0-9_]*)\s*=", &m)) {
            keyName := m[1]

            ; Check if this is an orphaned key in a known section
            if (sectionIsKnown && !knownSections[currentSection].Has(keyName)) {
                ; Orphaned - skip this line AND its pending comments
                pendingComments := []
                modified := true
                continue
            }

            ; Valid key - flush pending comments and keep this line
            for _, c in pendingComments
                newLines.Push(c)
            pendingComments := []
            newLines.Push(line)
            continue
        }

        ; Any other line (blank, regular comment, etc.)
        ; Flush pending comments first
        for _, c in pendingComments
            newLines.Push(c)
        pendingComments := []
        newLines.Push(line)
    }

    ; Flush any trailing pending comments
    for _, c in pendingComments
        newLines.Push(c)

    if (!modified)
        return

    ; Write back safely
    newContent := ""
    for i, line in newLines {
        newContent .= (i > 1 ? "`n" : "") . line
    }

    tempPath := path ".tmp"
    try {
        if (FileExist(tempPath))
            FileDelete(tempPath)
        FileAppend(newContent, tempPath, "UTF-8")
        FileMove(tempPath, path, true)
    } catch as e {
        try FileDelete(tempPath)
        throw e
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

    ; Atomic write: temp file then move, so a crash mid-write can't lose the config
    tempPath := path ".tmp"
    try {
        if (FileExist(tempPath))
            FileDelete(tempPath)
        FileAppend(newContent, tempPath, "UTF-8")
        ; Atomic overwrite: MoveFileEx with MOVEFILE_REPLACE_EXISTING on NTFS
        FileMove(tempPath, path, true)
    } catch as e {
        try FileDelete(tempPath)
        global LOG_PATH_STORE
        LogAppend(LOG_PATH_STORE, "config write error: " e.Message " path=" path)
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
            case "enum":
                found := false
                for _, opt in entry.options {
                    if (opt = val) {
                        found := true
                        break
                    }
                }
                if (found)
                    parsedVal := val
                else {
                    LogAppend(LOG_PATH_STORE, "config parse error: " entry.k "=" val " (not a valid option), using default")
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
    global cfg, gConfigRegistry

    ; Helper to clamp a value to a range
    clamp := (val, minVal, maxVal) => Max(minVal, Min(maxVal, val))

    ; --- Registry-driven clamping (replaces ~100 hardcoded clamp lines) ---
    for _, entry in gConfigRegistry {
        if (!entry.HasOwnProp("min"))
            continue
        cfg.%entry.g% := clamp(cfg.%entry.g%, entry.min, entry.max)
    }

    ; --- Cross-field constraints (can't be expressed as simple min/max) ---
    if (cfg.GUI_RowsVisibleMin > cfg.GUI_RowsVisibleMax)
        cfg.GUI_RowsVisibleMin := cfg.GUI_RowsVisibleMax
    if (cfg.DiagLogKeepKB >= cfg.DiagLogMaxKB)
        cfg.DiagLogKeepKB := cfg.DiagLogMaxKB // 2

    ; --- String enum validation ---
    if (cfg.IPCWorkspaceDeltaStyle != "Always" && cfg.IPCWorkspaceDeltaStyle != "OnChange")
        cfg.IPCWorkspaceDeltaStyle := "Always"

    ; --- Derived globals (must come after clamping) ---
    global IPC_TICK_IDLE
    IPC_TICK_IDLE := cfg.IPCIdleTickMs
    global MAX_RECONNECT_ATTEMPTS, TIMING_STORE_START_WAIT
    MAX_RECONNECT_ATTEMPTS := cfg.IPCMaxReconnectAttempts
    TIMING_STORE_START_WAIT := cfg.IPCStoreStartWaitMs
    global LOG_MAX_BYTES, LOG_KEEP_BYTES
    LOG_MAX_BYTES := cfg.DiagLogMaxKB * 1024
    LOG_KEEP_BYTES := cfg.DiagLogKeepKB * 1024
    global TOOLTIP_DURATION_SHORT, TOOLTIP_DURATION_DEFAULT, TOOLTIP_DURATION_LONG
    TOOLTIP_DURATION_SHORT := cfg.GUI_TooltipDurationMs
    TOOLTIP_DURATION_DEFAULT := cfg.GUI_TooltipDurationMs
    TOOLTIP_DURATION_LONG := cfg.GUI_TooltipDurationMs
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
global LOG_PATH_PAINT_TIMING := A_Temp "\tabby_paint_timing.log"

; Stats file path -- set properly in ConfigLoader_Init() alongside gConfigIniPath
global STATS_INI_PATH

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

; Log rotation constants (shared across all diagnostic logs)
; These are initialized from config values in _CL_ValidateSettings()
global LOG_MAX_BYTES := 102400   ; Default 100KB, overridden from cfg.DiagLogMaxKB
global LOG_KEEP_BYTES := 51200   ; Default 50KB, overridden from cfg.DiagLogKeepKB

; Trim a log file if it exceeds LOG_MAX_BYTES, keeping the tail
; Usage: LogTrim(LOG_PATH_EVENTS)
LogTrim(logPath) {
    global LOG_MAX_BYTES, LOG_KEEP_BYTES
    try {
        if (!FileExist(logPath))
            return
        size := FileGetSize(logPath)
        if (size <= LOG_MAX_BYTES)
            return
        content := FileRead(logPath)
        keepChars := LOG_KEEP_BYTES
        if (StrLen(content) > keepChars) {
            tail := SubStr(content, StrLen(content) - keepChars + 1)
            nlPos := InStr(tail, "`n")
            if (nlPos > 0)
                tail := SubStr(tail, nlPos + 1)
            FileDelete(logPath)
            FileAppend("... (log trimmed) ...`n" tail, logPath)
        }
    }
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
global TIMING_STORE_START_WAIT := 1000    ; Default, overridden from cfg.IPCStoreStartWaitMs
global TIMING_TASK_INIT_WAIT := 100      ; Wait for scheduled task to initialize
global TIMING_PROCESS_TERMINATE_WAIT := 100  ; Wait for process to terminate
global TIMING_FILE_WRITE_WAIT := 100     ; Wait for file to write
global TIMING_IPC_FIRE_WAIT := 10        ; Allow IPC timer to fire
global TIMING_STORE_PROCESS_WAIT := 100  ; Wait for store to process
global TIMING_PIPE_RETRY_WAIT := 50      ; Pipe connection retry delay
global TIMING_SETUP_SETTLE := 200        ; Setup settle delay

; Tooltip durations (milliseconds)
; All set to the same value from cfg.GUI_TooltipDurationMs in _CL_ValidateSettings()
global TOOLTIP_DURATION_SHORT := 2000
global TOOLTIP_DURATION_DEFAULT := 2000
global TOOLTIP_DURATION_LONG := 2000

; Retry limits
global MAX_RECONNECT_ATTEMPTS := 3        ; Default, overridden from cfg.IPCMaxReconnectAttempts
global MAX_RESTART_ATTEMPTS := 2          ; Store restart attempts before giving up

; WM_COPYDATA command IDs (launcher <-> client control signals)
global TABBY_CMD_RESTART_STORE := 1   ; GUI -> launcher: restart store only
global TABBY_CMD_RESTART_ALL := 2     ; Config editor -> launcher: restart store + GUI

; Shared path/delimiter constants
global TEMP_ADMIN_TOGGLE_LOCK := A_Temp "\alttabby_admin_toggle.lock"
global TEMP_WIZARD_STATE := A_Temp "\alttabby_wizard.json"
global TEMP_UPDATE_STATE := A_Temp "\alttabby_update.txt"
global TEMP_UPDATE_LOCK := A_Temp "\alttabby_update.lock"
global UPDATE_INFO_DELIMITER := "<|>"

; Application name constant
global APP_NAME := "Alt-Tabby"

; ============================================================
; TOOLTIP HELPER
; ============================================================
; Schedule tooltip to hide after specified duration.
; Usage: HideTooltipAfter(2000) or HideTooltipAfter(TOOLTIP_DURATION_DEFAULT)
HideTooltipAfter(durationMs := 2000) {
    SetTimer(() => ToolTip(), -durationMs)
}

