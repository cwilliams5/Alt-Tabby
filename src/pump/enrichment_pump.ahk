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
global _Pump_PrevIconSource := Map() ; hwnd → {method, rawH, exePath} (nochange detection)
global _Pump_ProcNameCache := Map() ; pid → processName (positive cache)
global _Pump_FailedPidCache := Map() ; pid → tick (negative cache)
global _Pump_FailedPidCacheTTL  ; Set from cfg.ProcPumpFailedPidRetryMs at init
global _Pump_IconPruneIntervalMs := 300000  ; Default 5min, overridden from config
global _Pump_DiagEnabled := false
global _Pump_GuiHwnd := 0             ; GUI process hwnd (for PostMessage wake on response)
global _Pump_HelloAcked := false       ; Whether we've sent our pumpHwnd back to GUI

; ========================= INIT =========================

_Pump_Init() {
    global cfg, _Pump_Server, _Pump_IconPruneIntervalMs, _Pump_DiagEnabled, _Pump_FailedPidCacheTTL

    ; Cloaked windows (other komorebi workspaces) are hidden from AHK by default.
    ; Without this, WinGetPID/WinGetTitle fail for cloaked windows → no processName/icon.
    DetectHiddenWindows(true)

    ; Load config
    ConfigLoader_Init()

    ; Load config values
    _Pump_IconPruneIntervalMs := cfg.PumpIconPruneIntervalMs
    _Pump_FailedPidCacheTTL := cfg.ProcPumpFailedPidRetryMs
    _Pump_DiagEnabled := cfg.DiagPumpLog

    ; Initialize blacklist (for title-based re-check on enrichment)
    Blacklist_Init()

    if (_Pump_DiagEnabled)
        _Pump_Log("INIT: Starting EnrichmentPump, pipe=" cfg.PumpPipeName)

    ; Start pipe server (single client — MainProcess)
    _Pump_Server := IPC_PipeServer_Start(cfg.PumpPipeName, _Pump_OnMessage, _Pump_OnDisconnect)
    if (!IsObject(_Pump_Server)) {
        _Pump_Log("FATAL: Failed to start pipe server, exiting")
        ExitApp(1)
    }

    ; Register PostMessage wake handler
    global IPC_WM_PIPE_WAKE
    OnMessage(IPC_WM_PIPE_WAKE, _Pump_OnPipeWake)  ; lint-ignore: onmessage-collision

    ; Start HICON prune timer
    SetTimer(_Pump_PruneOwnedIcons, _Pump_IconPruneIntervalMs)

    _Pump_Log("INIT: EnrichmentPump ready")
}

; ========================= IPC HANDLERS =========================

_Pump_OnMessage(msg, hPipe) {
    global _Pump_ClientPipe, _Pump_Server, _Pump_DiagEnabled
    _Pump_ClientPipe := hPipe

    if (_Pump_DiagEnabled)
        _Pump_Log("OnMessage received, len=" StrLen(msg))

    try {
        parsed := JSON.Load(msg)
    } catch {
        _Pump_Log("ERROR: Failed to parse message")
        return
    }

    global IPC_MSG_ENRICH, IPC_MSG_PUMP_SHUTDOWN
    msgType := parsed.Get("type", "")

    switch msgType {
        case IPC_MSG_ENRICH:
            _Pump_HandleEnrich(_Pump_Server, hPipe, parsed)
        case IPC_MSG_PUMP_SHUTDOWN:
            _Pump_Log("SHUTDOWN: Received shutdown request")
            _Pump_Cleanup()
            ExitApp(0)
        default:
            if (_Pump_DiagEnabled)
                _Pump_Log("WARN: Unknown message type: " msgType)
    }
}

_Pump_OnDisconnect(hPipe) {
    global _Pump_ClientPipe, _Pump_DiagEnabled
    if (_Pump_DiagEnabled)
        _Pump_Log("Client disconnected hPipe=" hPipe)
    if (_Pump_ClientPipe = hPipe)
        _Pump_ClientPipe := 0
}

_Pump_OnPipeWake(wParam, lParam, msg, hwnd) { ; lint-ignore: dead-param
    global _Pump_Server
    if (IsObject(_Pump_Server))
        IPC__ServerTick(_Pump_Server)
    return 0
}

; ========================= ENRICHMENT =========================

_Pump_HandleEnrich(server, hPipe, parsed) {
    global _Pump_GuiHwnd, _Pump_HelloAcked, _Pump_DiagEnabled

    if (!parsed.Has("hwnds"))
        return

    ; Extract GUI hwnd from hello (first request includes guiHwnd for PostMessage wake)
    if (!_Pump_GuiHwnd && (guiHwnd := parsed.Get("guiHwnd", 0))) {
        _Pump_GuiHwnd := guiHwnd + 0
        if (_Pump_DiagEnabled)
            _Pump_Log("HELLO: Received guiHwnd=" _Pump_GuiHwnd)
    }

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
            processName := _Pump_ResolveProcessName(pid, &exePath)
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
        if (r.Get("iconHicon", 0))
            iconResultCount++
    }
    if (_Pump_DiagEnabled)
        _Pump_Log("HandleEnrich: " hwnds.Length " hwnds requested, " results.Count " results, " iconResultCount " with icons")

    response := Map("type", IPC_MSG_ENRICHMENT, "results", results)

    ; Include our hwnd on first response so GUI can PostMessage wake us
    if (_Pump_GuiHwnd && !_Pump_HelloAcked) {
        response["pumpHwnd"] := A_ScriptHwnd
        _Pump_HelloAcked := true
        if (_Pump_DiagEnabled)
            _Pump_Log("HELLO: Sending pumpHwnd=" A_ScriptHwnd " to GUI")
    }

    responseJson := JSON.Dump(response)

    if (_Pump_DiagEnabled)
        _Pump_Log("Response JSON length: " StrLen(responseJson))

    ; Send response with PostMessage wake to GUI (if hwnd known)
    IPC_PipeServer_Send(server, hPipe, responseJson, _Pump_GuiHwnd)
}

; ========================= ICON RESOLUTION =========================
; Uses icon resolution functions from src/core/icon_pump.ahk (global scope via alt_tabby.ahk includes).
; These are pure Win32 DllCalls — no WindowList dependency.

; Returns {h: HICON, method: string} or {h: 0, method: ""/"unchanged"}
; "unchanged" = icon source matches previous resolution, skip IPC/GDI+ reconversion
_Pump_ResolveIcon(hwnd, pid, exePath) {
    global _Pump_OwnedIcons, _Pump_ExeIconCache, _Pump_PrevIconSource
    global IP_METHOD_WM_GETICON, IP_METHOD_UWP, IP_METHOD_EXE, IP_METHOD_UNCHANGED

    h := 0
    method := ""
    isVisible := DllCall("user32\IsWindowVisible", "ptr", hwnd, "int")

    ; Try WM_GETICON / class icon — use raw handle for nochange detection
    if (isVisible) {
        rawH := IP_GetRawWindowIcon(hwnd)
        if (rawH) {
            ; Nochange: same raw handle = window icon hasn't changed
            if (prev := _Pump_PrevIconSource.Get(hwnd, 0)) {
                if (prev.method = IP_METHOD_WM_GETICON && prev.rawH = rawH)
                    return {h: 0, method: IP_METHOD_UNCHANGED}
            }
            h := DllCall("user32\CopyIcon", "ptr", rawH, "ptr")
            if (h) {
                method := IP_METHOD_WM_GETICON
                _Pump_PrevIconSource[hwnd] := {method: IP_METHOD_WM_GETICON, rawH: rawH, exePath: ""}
            }
        }
    }

    ; Try UWP package icon (no nochange optimization — rare, always re-resolve)
    if (!h && pid > 0) {
        h := IP_TryResolveFromUWP(pid)
        if (h) {
            method := IP_METHOD_UWP
            _Pump_PrevIconSource[hwnd] := {method: IP_METHOD_UWP, rawH: 0, exePath: ""}
        }
    }

    ; Fallback: process EXE icon (cached per exe path)
    if (!h && exePath != "") {
        ; Nochange: same exePath = same exe icon (master is cached)
        if (prev := _Pump_PrevIconSource.Get(hwnd, 0)) {
            if (prev.method = IP_METHOD_EXE && prev.exePath = exePath)
                return {h: 0, method: IP_METHOD_UNCHANGED}
        }
        if (cachedIcon := _Pump_ExeIconCache.Get(exePath, 0)) {
            h := DllCall("user32\CopyIcon", "ptr", cachedIcon, "ptr")
        } else {
            master := IP_ExtractExeIcon(exePath)
            if (master) {
                _Pump_ExeIconCache[exePath] := master
                h := DllCall("user32\CopyIcon", "ptr", master, "ptr")
            }
        }
        if (h) {
            method := IP_METHOD_EXE
            _Pump_PrevIconSource[hwnd] := {method: IP_METHOD_EXE, rawH: 0, exePath: exePath}
        }
    }

    if (h) {
        ; Track ownership — destroy old HICON if re-enriching same hwnd
        if (oldIcon := _Pump_OwnedIcons.Get(hwnd, 0))
            try DllCall("user32\DestroyIcon", "ptr", oldIcon)
        _Pump_OwnedIcons[hwnd] := h
    }

    return {h: h, method: method}
}

; ========================= PROCESS NAME RESOLUTION =========================
; Uses proc_pump.ahk resolution pattern but with pump-local cache.

_Pump_ResolveProcessName(pid, &outPath := "") {
    global _Pump_ProcNameCache, _Pump_FailedPidCache, _Pump_FailedPidCacheTTL

    outPath := ""
    if (pid <= 0)
        return ""

    ; Check positive cache (path not cached — only name)
    if (cachedName := _Pump_ProcNameCache.Get(pid, ""))
        return cachedName

    ; Check negative cache
    if (failedTick := _Pump_FailedPidCache.Get(pid, 0)) {
        if ((A_TickCount - failedTick) < _Pump_FailedPidCacheTTL)
            return ""
        _Pump_FailedPidCache.Delete(pid)
    }

    ; Resolve — single ProcessUtils_GetPath call, caller gets path via outPath
    outPath := ProcessUtils_GetPath(pid)
    if (outPath = "") {
        _Pump_FailedPidCache[pid] := A_TickCount
        return ""
    }

    name := ProcessUtils_Basename(outPath)
    if (name != "")
        _Pump_ProcNameCache[pid] := name

    return name
}

; ========================= SELF-PRUNING =========================
; Periodically check IsWindow for owned HICONs, destroy orphans.
; Also prunes dead PIDs from process name and failed-PID caches.
; Configurable interval (default 5 minutes) — icons are small, leak is slow.

_Pump_PruneOwnedIcons() {
    global _Pump_OwnedIcons, _Pump_PrevIconSource, _Pump_DiagEnabled
    global _Pump_ProcNameCache, _Pump_FailedPidCache

    ; --- Icon pruning: destroy HICONs for windows that no longer exist ---
    toRemove := []
    if (_Pump_OwnedIcons.Count > 0 || _Pump_PrevIconSource.Count > 0) {
        for hwnd, _ in _Pump_OwnedIcons {
            if (!DllCall("user32\IsWindow", "ptr", hwnd, "int"))
                toRemove.Push(hwnd)
        }

        for _, hwnd in toRemove {
            try DllCall("user32\DestroyIcon", "ptr", _Pump_OwnedIcons[hwnd])
            _Pump_OwnedIcons.Delete(hwnd)
            _Pump_PrevIconSource.Delete(hwnd)
        }

        ; Also prune prev source entries for windows not in OwnedIcons
        toRemovePrev := []
        for hwnd, _ in _Pump_PrevIconSource {
            if (!DllCall("user32\IsWindow", "ptr", hwnd, "int"))
                toRemovePrev.Push(hwnd)
        }
        for _, hwnd in toRemovePrev
            _Pump_PrevIconSource.Delete(hwnd)
    }

    ; --- PID cache pruning: remove entries for dead processes ---
    prunedPids := 0
    if (_Pump_ProcNameCache.Count > 0) {
        deadPids := []
        for pid, _ in _Pump_ProcNameCache {
            if (!ProcessExist(pid))
                deadPids.Push(pid)
        }
        for _, pid in deadPids
            _Pump_ProcNameCache.Delete(pid)
        prunedPids += deadPids.Length
    }
    if (_Pump_FailedPidCache.Count > 0) {
        deadPids := []
        for pid, _ in _Pump_FailedPidCache {
            if (!ProcessExist(pid))
                deadPids.Push(pid)
        }
        for _, pid in deadPids
            _Pump_FailedPidCache.Delete(pid)
        prunedPids += deadPids.Length
    }

    pruned := toRemove.Length + prunedPids
    if (pruned > 0 && _Pump_DiagEnabled)
        _Pump_Log("PRUNE: " toRemove.Length " orphaned HICONs (" _Pump_OwnedIcons.Count " remaining), " prunedPids " dead PIDs (" _Pump_ProcNameCache.Count " proc + " _Pump_FailedPidCache.Count " failed remaining)")
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
    global _Pump_Server, _Pump_OwnedIcons, _Pump_ExeIconCache, _Pump_PrevIconSource

    ; Stop prune timer
    try SetTimer(_Pump_PruneOwnedIcons, 0)

    ; Destroy all owned HICONs
    for _, hIcon in _Pump_OwnedIcons
        try DllCall("user32\DestroyIcon", "ptr", hIcon)
    _Pump_OwnedIcons := Map()

    ; Destroy exe icon cache masters
    for _, hIcon in _Pump_ExeIconCache
        try DllCall("user32\DestroyIcon", "ptr", hIcon)
    _Pump_ExeIconCache := Map()

    ; Clear nochange detection cache
    _Pump_PrevIconSource := Map()

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
