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
;
; Collection timer is EVENT-DRIVEN: starts on enqueue (via
; GUIPump_EnsureRunning), pauses after idle threshold. IPC
; client timer runs at 8ms only when a request is in flight
; (safety net); PostMessage wake provides instant delivery.
; ============================================================

; ========================= GLOBALS =========================

global _gPump_Client := ""           ; IPC pipe client object
global _gPump_Connected := false     ; Pump connection state
global _gPump_CollectTimerFn := 0    ; Bound timer callback ref
global _gPump_CollectIntervalMs := 50  ; Batch collection interval (ms)
global _gPump_LastRequestTick := 0   ; Tick when last enrich request was sent
global _gPump_LastResponseTick := 0  ; Tick when last response was received
global _gPump_FailureNotified := false ; Prevent duplicate PUMP_FAILED notifications

; Event-driven collection timer state
global _gPump_TimerOn := false       ; Whether collection timer is running
global _gPump_IdleTicks := 0         ; Consecutive empty ticks
global _gPump_IdleThreshold := 5     ; Empty ticks before pausing (matches local pumps)

; IPC client timer management
global _gPump_ClientTimerOn := false  ; Whether IPC client poll timer is running

; PostMessage wake hwnd exchange
global _gPump_PumpHwnd := 0          ; Pump process hwnd (for GUI→pump wake)
global _gPump_HelloSent := false     ; Whether first request included guiHwnd

; ========================= PUBLIC API =========================

GUIPump_Init() {
    global cfg, _gPump_Client, _gPump_Connected, _gPump_CollectTimerFn, _gPump_CollectIntervalMs
    global _gPump_TimerOn, _gPump_IdleTicks, _gPump_ClientTimerOn
    global _gPump_PumpHwnd, _gPump_HelloSent

    mode := cfg.AdditionalWindowInformation
    if (mode != "Always" && mode != "NonBlocking")
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

    ; Stop default graduated-cooldown timer — we control it based on request state.
    ; IPC client timer runs at 8ms only when a request is in flight (safety net).
    if (_gPump_Client.timerFn)
        SetTimer(_gPump_Client.timerFn, 0)
    _gPump_ClientTimerOn := false

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
    _gPump_TimerOn := true
    _gPump_IdleTicks := 0

    ; Reset hello state (needed for reconnect — new pump needs GUI hwnd)
    _gPump_HelloSent := false
    _gPump_PumpHwnd := 0

    if (cfg.DiagPumpLog) {
        global gGUI_LauncherHwnd
        _GUIPump_Log("INIT: Connected to EnrichmentPump, local pumps stopped (launcherHwnd=" gGUI_LauncherHwnd ")")
    }

    return true
}

GUIPump_Stop() {
    global _gPump_Client, _gPump_Connected, _gPump_CollectTimerFn, _gPump_TimerOn

    ; Stop collection timer
    if (_gPump_CollectTimerFn)
        try SetTimer(_gPump_CollectTimerFn, 0)
    _gPump_CollectTimerFn := 0
    _gPump_TimerOn := false

    ; Stop IPC client timer
    _GUIPump_StopClientTimer()

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

; Wake collection timer from idle pause (called from _WS_EnqueueIfNeeded)
GUIPump_EnsureRunning() {
    global _gPump_TimerOn, _gPump_IdleTicks, _gPump_CollectIntervalMs, _gPump_CollectTimerFn
    if (!_gPump_CollectTimerFn)  ; Not initialized or pump not connected
        return
    Pump_EnsureRunning(&_gPump_TimerOn, &_gPump_IdleTicks, _gPump_CollectIntervalMs, _gPump_CollectTimerFn)
}

; ========================= COLLECTION TIMER =========================
; Drains icon + PID queues from WindowList and sends batched requests.
; Event-driven: started by GUIPump_EnsureRunning, pauses after idle threshold.

_GUIPump_CollectTick() {
    global _gPump_Client, _gPump_Connected, cfg, FR_EV_ENRICH_REQ
    global _gPump_LastRequestTick, _gPump_LastResponseTick
    global _gPump_IdleTicks, _gPump_IdleThreshold, _gPump_TimerOn, _gPump_CollectTimerFn
    global _gPump_HelloSent, _gPump_PumpHwnd

    if (!_gPump_Connected)
        return

    ; Hang detection: sent request but no response within timeout.
    ; Must run before idle check — timer must stay running while request is in flight.
    if (_gPump_LastRequestTick > _gPump_LastResponseTick
        && (A_TickCount - _gPump_LastRequestTick) > cfg.PumpHangTimeoutMs) {
        if (cfg.DiagPumpLog)
            _GUIPump_Log("HUNG: No response for " (A_TickCount - _gPump_LastRequestTick) "ms, declaring pump hung")
        _GUIPump_HandleFailure("hung")
        return
    }

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

    if (hwnds.Length = 0) {
        ; Don't pause if waiting for a response — need timer running for hang detection
        if (_gPump_LastRequestTick > _gPump_LastResponseTick)
            return
        Pump_HandleIdle(&_gPump_IdleTicks, _gPump_IdleThreshold, &_gPump_TimerOn, _gPump_CollectTimerFn)
        return
    }

    ; Reset idle counter on work
    _gPump_IdleTicks := 0

    ; Build enrich request
    FR_Record(FR_EV_ENRICH_REQ, hwnds.Length)
    global IPC_MSG_ENRICH
    request := Map("type", IPC_MSG_ENRICH, "hwnds", hwnds)

    ; Include GUI hwnd on first request so pump can PostMessage wake us
    if (!_gPump_HelloSent) {
        request["guiHwnd"] := A_ScriptHwnd
        _gPump_HelloSent := true
    }

    requestJson := JSON.Dump(request)

    if (cfg.DiagPumpLog)
        _GUIPump_Log("CollectTick sending " hwnds.Length " hwnds, jsonLen=" StrLen(requestJson))

    ; Send to pump (with PostMessage wake if we know pump's hwnd)
    ok := IPC_PipeClient_Send(_gPump_Client, requestJson, _gPump_PumpHwnd)
    if (!ok) {
        _GUIPump_HandleFailure("pipe_write")
        return
    }
    _gPump_LastRequestTick := A_TickCount

    ; Start IPC client timer as safety-net poll for response (8ms)
    _GUIPump_StartClientTimer()
}

; ========================= MESSAGE HANDLER =========================

_GUIPump_OnMessage(msg, hPipe) {
    global cfg, FR_EV_ENRICH_RESP, _gPump_LastResponseTick, _gPump_LastRequestTick
    global _gPump_PumpHwnd
    _gPump_LastResponseTick := A_TickCount

    ; If no request outstanding, stop client poll timer
    if (_gPump_LastResponseTick >= _gPump_LastRequestTick)
        _GUIPump_StopClientTimer()

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

    ; Extract pump's hwnd from hello response (one-time)
    if (!_gPump_PumpHwnd && parsed.Has("pumpHwnd")) {
        _gPump_PumpHwnd := parsed["pumpHwnd"] + 0
        if (cfg.DiagPumpLog)
            _GUIPump_Log("HELLO: Received pumpHwnd=" _gPump_PumpHwnd)
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

; ========================= IPC CLIENT TIMER =========================
; Managed by request state: 8ms when request in flight, off otherwise.
; PostMessage wake provides instant delivery; this is the safety net.

_GUIPump_StartClientTimer() {
    global _gPump_Client, _gPump_ClientTimerOn, IPC_TICK_ACTIVE
    if (_gPump_ClientTimerOn || !IsObject(_gPump_Client) || !_gPump_Client.timerFn)
        return
    SetTimer(_gPump_Client.timerFn, IPC_TICK_ACTIVE)  ; 8ms — fast safety-net poll
    _gPump_ClientTimerOn := true
}

_GUIPump_StopClientTimer() {
    global _gPump_Client, _gPump_ClientTimerOn
    if (!_gPump_ClientTimerOn || !IsObject(_gPump_Client) || !_gPump_Client.timerFn)
        return
    SetTimer(_gPump_Client.timerFn, 0)
    _gPump_ClientTimerOn := false
}

; ========================= FAILURE & RECOVERY =========================

; Unified failure handler for both crash (pipe write fail) and hang (response timeout).
; Falls back to local pumps immediately, then notifies launcher to restart the pump.
_GUIPump_HandleFailure(reason) {
    global _gPump_Client, _gPump_Connected, _gPump_CollectTimerFn, _gPump_FailureNotified
    global _gPump_TimerOn
    global cfg, gGUI_LauncherHwnd, TABBY_CMD_PUMP_FAILED, WM_COPYDATA

    if (cfg.DiagPumpLog)
        _GUIPump_Log("FAILURE (" reason "): Disconnecting pump, falling back to local pumps")

    _gPump_Connected := false

    ; Stop collection timer
    if (_gPump_CollectTimerFn)
        try SetTimer(_gPump_CollectTimerFn, 0)
    _gPump_CollectTimerFn := 0
    _gPump_TimerOn := false

    ; Stop IPC client timer
    _GUIPump_StopClientTimer()

    ; Close pipe
    if (IsObject(_gPump_Client))
        try IPC_PipeClient_Close(_gPump_Client)
    _gPump_Client := ""

    ; Restart local pumps as immediate fallback
    _GUIPump_RestartLocalPumps()

    ; Notify launcher to restart the pump (once per failure — prevents flood)
    if (!_gPump_FailureNotified && gGUI_LauncherHwnd) {
        _gPump_FailureNotified := true
        cds := Buffer(A_PtrSize * 3, 0)
        NumPut("uptr", TABBY_CMD_PUMP_FAILED, cds, 0)
        DllCall("user32\SendMessageTimeoutW"
            , "ptr", gGUI_LauncherHwnd
            , "uint", WM_COPYDATA
            , "ptr", A_ScriptHwnd
            , "ptr", cds.Ptr
            , "uint", 0x0002   ; SMTO_ABORTIFHUNG
            , "uint", 3000
            , "ptr*", &_ := 0
            , "ptr")
    }
}

; Called by gui_main.ahk when launcher sends TABBY_CMD_PUMP_RESTARTED.
; Attempts to reconnect to the freshly-restarted pump subprocess.
GUIPump_Reconnect() {
    global _gPump_LastRequestTick, _gPump_LastResponseTick, _gPump_FailureNotified, cfg

    ; Reset failure tracking state
    _gPump_LastRequestTick := 0
    _gPump_LastResponseTick := 0
    _gPump_FailureNotified := false

    ; GUIPump_Init handles pipe connect, stops local pumps if successful
    result := GUIPump_Init()
    if (cfg.DiagPumpLog)
        _GUIPump_Log("RECONNECT: " (result ? "Success — pump connection restored" : "Failed — staying on local pumps"))
    return result
}

_GUIPump_RestartLocalPumps() {
    global cfg
    if (cfg.AdditionalWindowInformation != "Always") {
        if (cfg.DiagPumpLog)
            _GUIPump_Log("FALLBACK: Skipped local pumps (mode=" cfg.AdditionalWindowInformation ")")
        return
    }
    IconPump_Start()
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
