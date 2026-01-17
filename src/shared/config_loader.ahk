#Requires AutoHotkey v2.0

; ============================================================
; Config Loader - INI file support with defaults from config.ahk
; ============================================================
; Loads user settings from config.ini. If a setting is present in
; the INI file, it overrides the default from config.ahk.
; Creates default config.ini if missing.
; ============================================================

global gConfigIniPath := ""
global gConfigLoaded := false

; Initialize config - call this early in startup
; basePath: directory containing config.ini (defaults to script dir's parent)
ConfigLoader_Init(basePath := "") {
    global gConfigIniPath, gConfigLoaded

    if (basePath = "")
        basePath := A_ScriptDir "\.."

    gConfigIniPath := basePath "\config.ini"

    ; Create default config.ini if missing
    if (!FileExist(gConfigIniPath)) {
        _CL_CreateDefaultIni(gConfigIniPath)
    }

    ; Load settings from INI, overriding config.ahk defaults
    _CL_LoadAllSettings()
    gConfigLoaded := true
}

; Load all settings - direct assignments, no dynamic variable magic
_CL_LoadAllSettings() {
    global gConfigIniPath

    ; Each setting: read from INI, if not empty, assign to global
    ; This is verbose but avoids AHK v2 global declaration issues

    _CL_LoadSetting_String("IPC", "StorePipeName")
    _CL_LoadSetting_String("Tools", "AhkV2Path")
    _CL_LoadSetting_String("Tools", "KomorebicExe")

    _CL_LoadSetting_Bool("Producers", "UseKomorebiSub")
    _CL_LoadSetting_Bool("Producers", "UseKomorebiLite")
    _CL_LoadSetting_Bool("Producers", "UseIconPump")
    _CL_LoadSetting_Bool("Producers", "UseProcPump")

    _CL_LoadSetting_Bool("Filtering", "UseAltTabEligibility")
    _CL_LoadSetting_Bool("Filtering", "UseBlacklist")

    _CL_LoadSetting_Int("WinEventHook", "DebounceMs", "WinEventHookDebounceMs")
    _CL_LoadSetting_Int("WinEventHook", "BatchMs", "WinEventHookBatchMs")

    _CL_LoadSetting_Int("ZPump", "IntervalMs", "ZPumpIntervalMs")
    _CL_LoadSetting_Int("WinEnum", "SafetyPollMs", "WinEnumSafetyPollMs")
    _CL_LoadSetting_Int("MruLite", "PollMs", "MruLitePollMs")

    _CL_LoadSetting_Int("IconPump", "IntervalMs", "IconPumpIntervalMs")
    _CL_LoadSetting_Int("IconPump", "BatchSize", "IconPumpBatchSize")
    _CL_LoadSetting_Int("IconPump", "MaxAttempts", "IconPumpMaxAttempts")
    _CL_LoadSetting_Bool("IconPump", "SkipHidden", "IconPumpSkipHidden")
    _CL_LoadSetting_Int("IconPump", "IdleBackoffMs", "IconPumpIdleBackoffMs")
    _CL_LoadSetting_Int("IconPump", "AttemptBackoffMs", "IconPumpAttemptBackoffMs")
    _CL_LoadSetting_Float("IconPump", "BackoffMultiplier", "IconPumpBackoffMultiplier")

    _CL_LoadSetting_Int("ProcPump", "IntervalMs", "ProcPumpIntervalMs")
    _CL_LoadSetting_Int("ProcPump", "BatchSize", "ProcPumpBatchSize")

    _CL_LoadSetting_Int("KomorebiSub", "PollMs", "KomorebiSubPollMs")
    _CL_LoadSetting_Int("KomorebiSub", "IdleRecycleMs", "KomorebiSubIdleRecycleMs")
    _CL_LoadSetting_Int("KomorebiSub", "FallbackPollMs", "KomorebiSubFallbackPollMs")

    _CL_LoadSetting_Int("Heartbeat", "StoreIntervalMs", "StoreHeartbeatIntervalMs")
    _CL_LoadSetting_Int("Heartbeat", "ViewerTimeoutMs", "ViewerHeartbeatTimeoutMs")

    _CL_LoadSetting_Bool("Viewer", "DebugLog", "DebugViewerLog")
    _CL_LoadSetting_Bool("Viewer", "AutoStartStore", "ViewerAutoStartStore")

    _CL_LoadSetting_Bool("Diagnostics", "ChurnLog", "DiagChurnLog")
    _CL_LoadSetting_Int("Testing", "LiveDurationSec", "TestLiveDurationSec_Default")

    _CL_LoadSetting_Int("AltTab", "GraceMs", "AltTabGraceMs")
    _CL_LoadSetting_Bool("AltTab", "PrewarmOnAlt", "AltTabPrewarmOnAlt")
    _CL_LoadSetting_Int("AltTab", "QuickSwitchMs", "AltTabQuickSwitchMs")
}

; Individual setting loaders - each handles its own global
_CL_LoadSetting_String(section, key, globalName := "") {
    global gConfigIniPath
    if (globalName = "")
        globalName := key
    val := IniRead(gConfigIniPath, section, key, "")
    if (val = "")
        return
    ; Use switch to assign to correct global - avoids dynamic global issues
    switch globalName {
        case "StorePipeName":
            global StorePipeName
            StorePipeName := val
        case "AhkV2Path":
            global AhkV2Path
            AhkV2Path := val
        case "KomorebicExe":
            global KomorebicExe
            KomorebicExe := val
    }
}

_CL_LoadSetting_Bool(section, key, globalName := "") {
    global gConfigIniPath
    if (globalName = "")
        globalName := key
    val := IniRead(gConfigIniPath, section, key, "")
    if (val = "")
        return
    boolVal := (val = "true" || val = "1" || val = "yes")
    switch globalName {
        case "UseKomorebiSub":
            global UseKomorebiSub
            UseKomorebiSub := boolVal
        case "UseKomorebiLite":
            global UseKomorebiLite
            UseKomorebiLite := boolVal
        case "UseIconPump":
            global UseIconPump
            UseIconPump := boolVal
        case "UseProcPump":
            global UseProcPump
            UseProcPump := boolVal
        case "UseAltTabEligibility":
            global UseAltTabEligibility
            UseAltTabEligibility := boolVal
        case "UseBlacklist":
            global UseBlacklist
            UseBlacklist := boolVal
        case "IconPumpSkipHidden":
            global IconPumpSkipHidden
            IconPumpSkipHidden := boolVal
        case "DebugViewerLog":
            global DebugViewerLog
            DebugViewerLog := boolVal
        case "ViewerAutoStartStore":
            global ViewerAutoStartStore
            ViewerAutoStartStore := boolVal
        case "DiagChurnLog":
            global DiagChurnLog
            DiagChurnLog := boolVal
        case "AltTabPrewarmOnAlt":
            global AltTabPrewarmOnAlt
            AltTabPrewarmOnAlt := boolVal
    }
}

_CL_LoadSetting_Int(section, key, globalName := "") {
    global gConfigIniPath
    if (globalName = "")
        globalName := key
    val := IniRead(gConfigIniPath, section, key, "")
    if (val = "")
        return
    intVal := Integer(val)
    switch globalName {
        case "WinEventHookDebounceMs":
            global WinEventHookDebounceMs
            WinEventHookDebounceMs := intVal
        case "WinEventHookBatchMs":
            global WinEventHookBatchMs
            WinEventHookBatchMs := intVal
        case "ZPumpIntervalMs":
            global ZPumpIntervalMs
            ZPumpIntervalMs := intVal
        case "WinEnumSafetyPollMs":
            global WinEnumSafetyPollMs
            WinEnumSafetyPollMs := intVal
        case "MruLitePollMs":
            global MruLitePollMs
            MruLitePollMs := intVal
        case "IconPumpIntervalMs":
            global IconPumpIntervalMs
            IconPumpIntervalMs := intVal
        case "IconPumpBatchSize":
            global IconPumpBatchSize
            IconPumpBatchSize := intVal
        case "IconPumpMaxAttempts":
            global IconPumpMaxAttempts
            IconPumpMaxAttempts := intVal
        case "IconPumpIdleBackoffMs":
            global IconPumpIdleBackoffMs
            IconPumpIdleBackoffMs := intVal
        case "IconPumpAttemptBackoffMs":
            global IconPumpAttemptBackoffMs
            IconPumpAttemptBackoffMs := intVal
        case "ProcPumpIntervalMs":
            global ProcPumpIntervalMs
            ProcPumpIntervalMs := intVal
        case "ProcPumpBatchSize":
            global ProcPumpBatchSize
            ProcPumpBatchSize := intVal
        case "KomorebiSubPollMs":
            global KomorebiSubPollMs
            KomorebiSubPollMs := intVal
        case "KomorebiSubIdleRecycleMs":
            global KomorebiSubIdleRecycleMs
            KomorebiSubIdleRecycleMs := intVal
        case "KomorebiSubFallbackPollMs":
            global KomorebiSubFallbackPollMs
            KomorebiSubFallbackPollMs := intVal
        case "StoreHeartbeatIntervalMs":
            global StoreHeartbeatIntervalMs
            StoreHeartbeatIntervalMs := intVal
        case "ViewerHeartbeatTimeoutMs":
            global ViewerHeartbeatTimeoutMs
            ViewerHeartbeatTimeoutMs := intVal
        case "TestLiveDurationSec_Default":
            global TestLiveDurationSec_Default
            TestLiveDurationSec_Default := intVal
        case "AltTabGraceMs":
            global AltTabGraceMs
            AltTabGraceMs := intVal
        case "AltTabQuickSwitchMs":
            global AltTabQuickSwitchMs
            AltTabQuickSwitchMs := intVal
    }
}

_CL_LoadSetting_Float(section, key, globalName := "") {
    global gConfigIniPath
    if (globalName = "")
        globalName := key
    val := IniRead(gConfigIniPath, section, key, "")
    if (val = "")
        return
    floatVal := Float(val)
    switch globalName {
        case "IconPumpBackoffMultiplier":
            global IconPumpBackoffMultiplier
            IconPumpBackoffMultiplier := floatVal
    }
}

; Create default config.ini
_CL_CreateDefaultIni(path) {
    content := "; Alt-Tabby Configuration`n"
    content .= "; Edit this file to customize settings. Delete a line to use defaults.`n"
    content .= "; Changes take effect on next startup.`n"
    content .= "`n"

    content .= "[IPC]`n"
    content .= "; Named pipe for store<->client communication`n"
    content .= "; StorePipeName=tabby_store_v1`n"
    content .= "`n"

    content .= "[Tools]`n"
    content .= "; Path to AHK v2 executable (for spawning subprocesses)`n"
    content .= "; AhkV2Path=C:\\Program Files\\AutoHotkey\\v2\\AutoHotkey64.exe`n"
    content .= "; Path to komorebic.exe (komorebi CLI)`n"
    content .= "; KomorebicExe=C:\\Program Files\\komorebi\\bin\\komorebic.exe`n"
    content .= "`n"

    content .= "[Producers]`n"
    content .= "; Komorebi integration - adds workspace names to windows`n"
    content .= "; UseKomorebiSub=true`n"
    content .= "; UseKomorebiLite=false`n"
    content .= "; Enrichment pumps - add icons and process names asynchronously`n"
    content .= "; UseIconPump=true`n"
    content .= "; UseProcPump=true`n"
    content .= "`n"

    content .= "[Filtering]`n"
    content .= "; Filter windows like native Alt-Tab (skip tool windows, etc.)`n"
    content .= "; UseAltTabEligibility=true`n"
    content .= "; Apply blacklist from blacklist.txt`n"
    content .= "; UseBlacklist=true`n"
    content .= "`n"

    content .= "[WinEventHook]`n"
    content .= "; Event-driven window change detection timing (ms)`n"
    content .= "; DebounceMs=50`n"
    content .= "; BatchMs=100`n"
    content .= "`n"

    content .= "[ZPump]`n"
    content .= "; Z-order enrichment pump interval (ms)`n"
    content .= "; IntervalMs=200`n"
    content .= "`n"

    content .= "[WinEnum]`n"
    content .= "; Safety polling interval (0=disabled, 30000+=paranoid safety net)`n"
    content .= "; SafetyPollMs=0`n"
    content .= "`n"

    content .= "[MruLite]`n"
    content .= "; MRU fallback polling interval (only if WinEventHook fails)`n"
    content .= "; PollMs=250`n"
    content .= "`n"

    content .= "[IconPump]`n"
    content .= "; Icon resolution timing`n"
    content .= "; IntervalMs=80`n"
    content .= "; BatchSize=16`n"
    content .= "; MaxAttempts=4`n"
    content .= "; SkipHidden=true`n"
    content .= "; IdleBackoffMs=1500`n"
    content .= "; AttemptBackoffMs=300`n"
    content .= "; BackoffMultiplier=1.8`n"
    content .= "`n"

    content .= "[ProcPump]`n"
    content .= "; Process name resolution timing`n"
    content .= "; IntervalMs=100`n"
    content .= "; BatchSize=16`n"
    content .= "`n"

    content .= "[KomorebiSub]`n"
    content .= "; Komorebi subscription timing`n"
    content .= "; PollMs=50`n"
    content .= "; IdleRecycleMs=120000`n"
    content .= "; FallbackPollMs=2000`n"
    content .= "`n"

    content .= "[Heartbeat]`n"
    content .= "; Connection health timing`n"
    content .= "; StoreIntervalMs=5000`n"
    content .= "; ViewerTimeoutMs=12000`n"
    content .= "`n"

    content .= "[Viewer]`n"
    content .= "; Debug viewer options`n"
    content .= "; DebugLog=false`n"
    content .= "; AutoStartStore=false`n"
    content .= "`n"

    content .= "[Diagnostics]`n"
    content .= "; Debug options`n"
    content .= "; ChurnLog=false`n"
    content .= "`n"

    content .= "[AltTab]`n"
    content .= "; Alt-Tab GUI behavior`n"
    content .= "; GraceMs=150`n"
    content .= "; PrewarmOnAlt=true`n"
    content .= "; QuickSwitchMs=100`n"

    try FileAppend(content, path, "UTF-8")
}

; Create default blacklist.txt if missing
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
