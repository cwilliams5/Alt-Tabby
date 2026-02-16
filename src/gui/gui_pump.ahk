#Requires AutoHotkey v2.0

; ============================================================
; GUIPump — EnrichmentPump client for MainProcess
; ============================================================
; Connects to the EnrichmentPump subprocess via named pipe.
; Drains icon/PID queues from WindowList, batches hwnds into
; "enrich" requests, and applies returned title/icon/process
; data back to the store.
;
; When the pump is connected, local IconPump and ProcPump timers
; are stopped — the pump handles all blocking Win32 resolution.
; If the pump is unavailable, local pumps remain as fallback.
; ============================================================

; ========================= GLOBALS =========================

global _gPump_Client := ""           ; IPC pipe client object
global _gPump_Connected := false     ; Pump connection state
global _gPump_CollectTimerFn := 0    ; Bound timer callback ref
global _gPump_CollectIntervalMs := 50  ; Batch collection interval (ms)

; ========================= PUBLIC API =========================

GUIPump_Init() {
    global cfg, _gPump_Client, _gPump_Connected, _gPump_CollectTimerFn, _gPump_CollectIntervalMs

    if (!cfg.UseEnrichmentPump)
        return false

    ; Connect to pump pipe
    _gPump_Client := IPC_PipeClient_Connect(cfg.PumpPipeName, _GUIPump_OnMessage, 2000)

    if (!IsObject(_gPump_Client) || _gPump_Client.hPipe = 0) {
        _gPump_Connected := false
        if (cfg.DiagPumpLog)
            _GUIPump_Log("INIT: Failed to connect to EnrichmentPump (pipe=" cfg.PumpPipeName "). Using inline fallback.")
        return false
    }

    _gPump_Connected := true

    ; Register PostMessage wake handler for immediate pipe reads
    global IPC_WM_PIPE_WAKE
    OnMessage(IPC_WM_PIPE_WAKE, _GUIPump_OnPipeWake)  ; lint-ignore: onmessage-collision

    ; Stop local icon/proc pumps — pump handles all enrichment.
    ; Zero out interval globals to prevent _WS_EnqueueIfNeeded from restarting
    ; local pump timers via EnsureRunning (interval=0 → early return).
    try IconPump_Stop()
    try ProcPump_Stop()
    global IconTimerIntervalMs, ProcTimerIntervalMs
    IconTimerIntervalMs := 0
    ProcTimerIntervalMs := 0

    ; Start collection timer — drains queues and sends to pump
    _gPump_CollectTimerFn := _GUIPump_CollectTick.Bind()
    SetTimer(_gPump_CollectTimerFn, _gPump_CollectIntervalMs)  ; lint-ignore: timer-lifecycle (cancelled in GUIPump_Stop via bound ref)

    if (cfg.DiagPumpLog)
        _GUIPump_Log("INIT: Connected to EnrichmentPump, local pumps stopped")

    return true
}

GUIPump_Stop() {
    global _gPump_Client, _gPump_Connected, _gPump_CollectTimerFn

    ; Stop collection timer
    if (_gPump_CollectTimerFn)
        try SetTimer(_gPump_CollectTimerFn, 0)
    _gPump_CollectTimerFn := 0

    ; Send shutdown to pump
    if (_gPump_Connected && IsObject(_gPump_Client) && _gPump_Client.hPipe != 0) {
        global IPC_MSG_PUMP_SHUTDOWN
        payload := Map("type", IPC_MSG_PUMP_SHUTDOWN)
        shutdownMsg := JSON.Dump(payload)
        try IPC_PipeClient_Send(_gPump_Client, shutdownMsg)
    }

    ; Close pipe connection
    if (IsObject(_gPump_Client))
        try IPC_PipeClient_Close(_gPump_Client)

    _gPump_Client := ""
    _gPump_Connected := false
}

; ========================= COLLECTION TIMER =========================
; Drains icon + PID queues from WindowList and sends batched requests.

_GUIPump_CollectTick() {
    global _gPump_Client, _gPump_Connected, cfg, FR_EV_ENRICH_REQ

    if (!_gPump_Connected || !IsObject(_gPump_Client) || _gPump_Client.hPipe = 0)
        return

    ; Drain icon queue — collect hwnds that need enrichment
    hwnds := WL_PopIconBatch(32)

    ; Also drain PID queue — collect PIDs, then resolve to hwnds
    ; The pump resolves processName by hwnd (via WinGetPID + OpenProcess),
    ; so we need hwnds, not PIDs. Merge PID windows into the hwnd batch.
    pids := WL_PopPidBatch(32)
    if (pids.Length > 0) {
        ; Find hwnds with these PIDs that aren't already in the batch
        pidSet := Map()
        for _, pid in pids
            pidSet[pid] := true
        ; Get hwnds from store by PID
        pidHwnds := WL_GetHwndsByPids(pidSet)
        ; Merge, deduplicating
        hwndSet := Map()
        for _, h in hwnds
            hwndSet[h] := true
        for _, h in pidHwnds {
            if (!hwndSet.Has(h)) {
                hwnds.Push(h)
                hwndSet[h] := true
            }
        }
    }

    if (hwnds.Length = 0)
        return

    ; Build enrich request
    FR_Record(FR_EV_ENRICH_REQ, hwnds.Length)
    global IPC_MSG_ENRICH
    request := Map("type", IPC_MSG_ENRICH, "hwnds", hwnds)
    requestJson := JSON.Dump(request)

    if (cfg.DiagPumpLog)
        _GUIPump_Log("CollectTick sending " hwnds.Length " hwnds, jsonLen=" StrLen(requestJson))

    ; Send to pump
    ok := IPC_PipeClient_Send(_gPump_Client, requestJson)
    if (!ok) {
        _gPump_Connected := false
        if (cfg.DiagPumpLog)
            _GUIPump_Log("ERROR: Pipe write failed, pump disconnected. Restarting local pumps.")
        ; Restart local pumps as fallback
        _GUIPump_RestartLocalPumps()
    }
}

; ========================= MESSAGE HANDLER =========================

_GUIPump_OnMessage(msg, hPipe) {
    global cfg, FR_EV_ENRICH_RESP

    try {
        parsed := JSON.Load(msg)
    } catch {
        if (cfg.DiagPumpLog)
            _GUIPump_Log("ERROR: Failed to parse pump response, msg=" SubStr(msg, 1, 200))
        return
    }

    global IPC_MSG_ENRICHMENT
    msgType := parsed.Has("type") ? parsed["type"] : ""

    if (msgType != IPC_MSG_ENRICHMENT) {
        if (cfg.DiagPumpLog)
            _GUIPump_Log("WARN: unexpected type='" msgType "' (expected '" IPC_MSG_ENRICHMENT "')")
        return
    }

    if (!parsed.Has("results")) {
        if (cfg.DiagPumpLog)
            _GUIPump_Log("WARN: no 'results' key in response")
        return
    }

    results := parsed["results"]
    applied := 0
    iconCount := 0

    for hwndStr, data in results {
        hwnd := hwndStr + 0
        if (!hwnd)
            continue

        fields := Map()

        ; Apply title
        if (data.Has("title"))
            fields["title"] := data["title"]

        ; Apply process name
        if (data.Has("processName"))
            fields["processName"] := data["processName"]

        ; Apply exe path
        if (data.Has("exePath"))
            fields["exePath"] := data["exePath"]

        ; Apply icon (HICON numeric value — valid cross-process)
        if (data.Has("iconHicon")) {
            fields["iconHicon"] := data["iconHicon"]
            fields["iconMethod"] := data.Has("iconMethod") ? data["iconMethod"] : "pump"
            iconCount++
        }

        ; Always update refresh tick when enrichment ran (even without icon result).
        ; Prevents re-enqueue before throttle period expires when pump returns "unchanged".
        ; iconLastRefreshTick is in gWS_InternalFields — no rev bump or dirty marking.
        fields["iconLastRefreshTick"] := A_TickCount

        if (fields.Count > 0) {
            WL_UpdateFields(hwnd, fields, "pump_enrich")
            applied++
        }
    }

    if (cfg.DiagPumpLog)
        _GUIPump_Log("OnMessage: applied=" applied " iconCount=" iconCount)
    FR_Record(FR_EV_ENRICH_RESP, applied)

    ; Trigger a cosmetic rev bump so GUI sees new icons/titles
    if (applied > 0) {
        global gWS_OnStoreChanged
        if (gWS_OnStoreChanged)
            gWS_OnStoreChanged(false)  ; cosmetic only (icons/titles, not structural)
    }
}

; ========================= PIPE WAKE =========================

_GUIPump_OnPipeWake(wParam, lParam, msg, hwnd) {
    Critical "On"
    global _gPump_Client
    if (IsObject(_gPump_Client))
        IPC__ClientTick(_gPump_Client)
    Critical "Off"
    return 0
}

; ========================= FALLBACK =========================

_GUIPump_RestartLocalPumps() {
    global cfg
    if (cfg.UseIconPump)
        IconPump_Start()
    if (cfg.UseProcPump)
        ProcPump_Start()
    if (cfg.DiagPumpLog)
        _GUIPump_Log("FALLBACK: Restarted local icon/proc pumps")
}

; ========================= LOGGING =========================

_GUIPump_Log(msg) {
    global cfg
    if (!cfg.DiagPumpLog)
        return
    try LogAppend(A_Temp "\tabby_pump.log", msg)
}
