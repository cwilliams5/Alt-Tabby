#Requires AutoHotkey v2.0
#Warn VarUnset, Off

; ============================================================
; EnrichmentPump — Blocking icon/title/proc resolution process
; ============================================================
; Launched as AltTabby.exe --pump. Offloads blocking Win32 calls
; (SendMessageTimeoutW for icons, WinGetTitle, OpenProcess) from
; MainProcess so the keyboard hook thread is never blocked.
;
; IPC protocol (over named pipe, JSON via cJSON):
;   enrich     Main → Pump  {type:"enrich", hwnds:[1234,5678]}
;   enrichment Pump → Main  {type:"enrichment", results:{...}}
;   shutdown   Main → Pump  {type:"shutdown"}
;
; HICON cross-process: HICON handles are system-wide USER objects
; in win32k.sys shared kernel memory. Numeric values passed over
; IPC are valid in any process on the same session.
; ============================================================

; ========================= GLOBALS =========================

global _Pump_Server := ""
global _Pump_ClientPipe := 0        ; hPipe of connected MainProcess client
global _Pump_OwnedIcons := Map()    ; hwnd → HICON (ownership tracking for cleanup)
global _Pump_ExeIconCache := Map()  ; exePath → master HICON (dedup across windows)
global _Pump_ProcNameCache := Map() ; pid → processName (positive cache)
global _Pump_FailedPidCache := Map() ; pid → tick (negative cache)
global _Pump_FailedPidCacheTTL := 60000
global _Pump_IconPruneIntervalMs := 300000  ; Default 5min, overridden from config
global _Pump_LastPruneTick := 0
global _Pump_DiagEnabled := false

; ========================= INIT =========================

_Pump_Init() {
    global cfg, _Pump_Server, _Pump_IconPruneIntervalMs, _Pump_DiagEnabled

    ; Load config
    ConfigLoader_Init()

    ; Load config values
    if (cfg.HasOwnProp("PumpIconPruneIntervalMs"))
        _Pump_IconPruneIntervalMs := cfg.PumpIconPruneIntervalMs
    _Pump_DiagEnabled := cfg.HasOwnProp("DiagPumpLog") ? cfg.DiagPumpLog : false

    ; Initialize blacklist (for title-based re-check on enrichment)
    Blacklist_Init()

    _Pump_Log("INIT: Starting EnrichmentPump, pipe=" cfg.PumpPipeName)

    ; Start pipe server (single client — MainProcess)
    _Pump_Server := IPC_PipeServer_Start(cfg.PumpPipeName, _Pump_OnMessage, _Pump_OnDisconnect)

    ; Register PostMessage wake handler
    global IPC_WM_PIPE_WAKE
    OnMessage(IPC_WM_PIPE_WAKE, _Pump_OnPipeWake)  ; lint-ignore: onmessage-collision

    ; Start HICON prune timer
    SetTimer(_Pump_PruneOwnedIcons, _Pump_IconPruneIntervalMs)

    _Pump_Log("INIT: EnrichmentPump ready")
}

; ========================= IPC HANDLERS =========================

_Pump_OnMessage(msg, hPipe) {
    global _Pump_ClientPipe, _Pump_Server
    _Pump_ClientPipe := hPipe

    _Pump_Log("OnMessage received, len=" StrLen(msg))

    try {
        parsed := JSON.Load(msg)
    } catch {
        _Pump_Log("ERROR: Failed to parse message")
        return
    }

    global IPC_MSG_ENRICH, IPC_MSG_PUMP_SHUTDOWN
    msgType := parsed.Has("type") ? parsed["type"] : ""

    switch msgType {
        case IPC_MSG_ENRICH:
            _Pump_HandleEnrich(_Pump_Server, hPipe, parsed)
        case IPC_MSG_PUMP_SHUTDOWN:
            _Pump_Log("SHUTDOWN: Received shutdown request")
            _Pump_Cleanup()
            ExitApp(0)
        default:
            _Pump_Log("WARN: Unknown message type: " msgType)
    }
}

_Pump_OnDisconnect(hPipe) {
    global _Pump_ClientPipe
    _Pump_Log("Client disconnected hPipe=" hPipe)
    if (_Pump_ClientPipe = hPipe)
        _Pump_ClientPipe := 0
}

_Pump_OnPipeWake(wParam, lParam, msg, hwnd) {
    global _Pump_Server
    if (IsObject(_Pump_Server))
        IPC__ServerTick(_Pump_Server)
    return 0
}

; ========================= ENRICHMENT =========================

_Pump_HandleEnrich(server, hPipe, parsed) {
    if (!parsed.Has("hwnds"))
        return

    hwnds := parsed["hwnds"]
    if (!IsObject(hwnds) || hwnds.Length = 0)
        return

    results := Map()

    for _, hwnd in hwnds {
        hwnd := hwnd + 0
        if (!hwnd || !DllCall("user32\IsWindow", "ptr", hwnd, "int"))
            continue

        result := Map()

        ; Resolve process name first (needed for exe icon fallback)
        pid := 0
        try pid := WinGetPID("ahk_id " hwnd)
        processName := ""
        exePath := ""
        if (pid > 0) {
            processName := _Pump_ResolveProcessName(pid)
            exePath := ProcessUtils_GetPath(pid)
            if (processName != "")
                result["processName"] := processName
            if (exePath != "")
                result["exePath"] := exePath
        }

        ; Resolve title (blocking WinGetTitle via SendMessage)
        title := ""
        if (!DllCall("user32\IsHungAppWindow", "ptr", hwnd, "int")) {
            try title := WinGetTitle("ahk_id " hwnd)
        }
        if (title != "")
            result["title"] := title

        ; Resolve icon (blocking SendMessageTimeoutW)
        iconResult := _Pump_ResolveIcon(hwnd, pid, exePath)
        if (iconResult.h) {
            result["iconHicon"] := iconResult.h
            result["iconMethod"] := iconResult.method
        }

        if (result.Count > 0)
            results[String(hwnd)] := result
    }

    ; Build response
    global IPC_MSG_ENRICHMENT
    iconResultCount := 0
    for _, r in results {
        if (r.Has("iconHicon") && r["iconHicon"])
            iconResultCount++
    }
    _Pump_Log("HandleEnrich: " hwnds.Length " hwnds requested, " results.Count " results, " iconResultCount " with icons")

    response := Map("type", IPC_MSG_ENRICHMENT, "results", results)
    responseJson := JSON.Dump(response)

    _Pump_Log("Response JSON length: " StrLen(responseJson))

    ; Send response with wake
    global IPC_WM_PIPE_WAKE
    wakeHwnd := 0
    ; MainProcess sets wakeHwnd via hello — for now, send without wake
    IPC_PipeServer_Send(server, hPipe, responseJson, wakeHwnd)
}

; ========================= ICON RESOLUTION =========================
; Uses icon_pump.ahk resolution functions (included via alt_tabby.ahk).
; These are pure Win32 DllCalls — no WindowList dependency.

; Returns {h: HICON, method: string} or {h: 0, method: ""}
_Pump_ResolveIcon(hwnd, pid, exePath) {
    global _Pump_OwnedIcons, _Pump_ExeIconCache

    ; Try WM_GETICON / class icon (window must be visible for reliable results)
    h := 0
    method := ""
    isVisible := DllCall("user32\IsWindowVisible", "ptr", hwnd, "int")
    if (isVisible) {
        h := IP_TryResolveFromWindow(hwnd)
        if (h)
            method := "wm_geticon"
    }

    ; Try UWP package icon
    if (!h && pid > 0) {
        h := IP_TryResolveFromUWP(hwnd, pid)
        if (h)
            method := "uwp"
    }

    ; Fallback: process EXE icon (cached per exe path)
    if (!h && exePath != "") {
        if (_Pump_ExeIconCache.Has(exePath)) {
            h := DllCall("user32\CopyIcon", "ptr", _Pump_ExeIconCache[exePath], "ptr")
        } else {
            master := IP_ExtractExeIcon(exePath)
            if (master) {
                _Pump_ExeIconCache[exePath] := master
                h := DllCall("user32\CopyIcon", "ptr", master, "ptr")
            }
        }
        if (h)
            method := "exe"
    }

    if (h) {
        ; Track ownership — destroy old HICON if re-enriching same hwnd
        if (_Pump_OwnedIcons.Has(hwnd))
            try DllCall("user32\DestroyIcon", "ptr", _Pump_OwnedIcons[hwnd])
        _Pump_OwnedIcons[hwnd] := h
    }

    return {h: h, method: method}
}

; ========================= PROCESS NAME RESOLUTION =========================
; Uses proc_pump.ahk resolution pattern but with pump-local cache.

_Pump_ResolveProcessName(pid) {
    global _Pump_ProcNameCache, _Pump_FailedPidCache, _Pump_FailedPidCacheTTL

    if (pid <= 0)
        return ""

    ; Check positive cache
    if (_Pump_ProcNameCache.Has(pid))
        return _Pump_ProcNameCache[pid]

    ; Check negative cache
    if (_Pump_FailedPidCache.Has(pid)) {
        if ((A_TickCount - _Pump_FailedPidCache[pid]) < _Pump_FailedPidCacheTTL)
            return ""
        _Pump_FailedPidCache.Delete(pid)
    }

    ; Resolve
    path := ProcessUtils_GetPath(pid)
    if (path = "") {
        _Pump_FailedPidCache[pid] := A_TickCount
        return ""
    }

    name := ProcessUtils_Basename(path)
    if (name != "")
        _Pump_ProcNameCache[pid] := name

    return name
}

; ========================= HICON SELF-PRUNING =========================
; Periodically check IsWindow for owned HICONs, destroy orphans.
; Configurable interval (default 5 minutes) — icons are small, leak is slow.

_Pump_PruneOwnedIcons() {
    global _Pump_OwnedIcons
    if (_Pump_OwnedIcons.Count = 0)
        return

    toRemove := []
    for hwnd, hIcon in _Pump_OwnedIcons {
        if (!DllCall("user32\IsWindow", "ptr", hwnd, "int"))
            toRemove.Push(hwnd)
    }

    for _, hwnd in toRemove {
        try DllCall("user32\DestroyIcon", "ptr", _Pump_OwnedIcons[hwnd])
        _Pump_OwnedIcons.Delete(hwnd)
    }

    if (toRemove.Length > 0)
        _Pump_Log("PRUNE: destroyed " toRemove.Length " orphaned HICONs, " _Pump_OwnedIcons.Count " remaining")
}

; ========================= LOGGING =========================

_Pump_Log(msg) {
    global _Pump_DiagEnabled
    if (!_Pump_DiagEnabled)
        return
    try LogAppend(A_Temp "\tabby_pump.log", msg)
}

; ========================= CLEANUP =========================

_Pump_Cleanup() {
    global _Pump_Server, _Pump_OwnedIcons, _Pump_ExeIconCache

    ; Stop prune timer
    try SetTimer(_Pump_PruneOwnedIcons, 0)

    ; Destroy all owned HICONs
    for hwnd, hIcon in _Pump_OwnedIcons
        try DllCall("user32\DestroyIcon", "ptr", hIcon)
    _Pump_OwnedIcons := Map()

    ; Destroy exe icon cache masters
    for exe, hIcon in _Pump_ExeIconCache
        try DllCall("user32\DestroyIcon", "ptr", hIcon)
    _Pump_ExeIconCache := Map()

    ; Stop pipe server
    if (IsObject(_Pump_Server))
        IPC_PipeServer_Stop(_Pump_Server)

    _Pump_Log("CLEANUP: EnrichmentPump shutdown complete")
}

; ========================= AUTO-INIT =========================
; Auto-init only if running in pump mode

if (IsSet(g_AltTabbyMode) && g_AltTabbyMode = "pump") {
    _Pump_Init()
    OnExit((reason, code) => (_Pump_Cleanup(), 0))
    Persistent()
}
