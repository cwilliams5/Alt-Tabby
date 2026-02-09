#Requires AutoHotkey v2.0
#SingleInstance Off  ; Allow multiple instances (tests run overlapping stores)

; Includes: Use *i (ignore if not found) to handle both:
; - Standalone: files found via %A_ScriptDir%\..\ path
; - Included from alt_tabby.ahk: files already loaded, paths don't match but that's OK
#Include *i %A_ScriptDir%\..\shared\config_loader.ahk
#Include *i %A_ScriptDir%\..\lib\cjson.ahk
#Include *i %A_ScriptDir%\..\shared\ipc_pipe.ahk
#Include *i %A_ScriptDir%\..\shared\blacklist.ahk
#Include *i %A_ScriptDir%\..\shared\process_utils.ahk
#Include *i %A_ScriptDir%\..\shared\win_utils.ahk
#Include *i %A_ScriptDir%\..\shared\pump_utils.ahk
#Include *i %A_ScriptDir%\windowstore.ahk
#Include *i %A_ScriptDir%\winenum_lite.ahk
#Include *i %A_ScriptDir%\mru_lite.ahk
#Include *i %A_ScriptDir%\komorebi_lite.ahk
#Include *i %A_ScriptDir%\komorebi_sub.ahk
#Include *i %A_ScriptDir%\icon_pump.ahk
#Include *i %A_ScriptDir%\proc_pump.ahk
#Include *i %A_ScriptDir%\winevent_hook.ahk

; Stats tracking
global gStats_Lifetime := Map()   ; key -> integer, loaded from/flushed to stats.ini
global gStats_Session := Map()    ; key -> integer, this session only

global gStore_Server := 0
; Per-client state: hPipe -> {opts, lastRev, lastProj, lastMeta, pushCount}
; Consolidates all per-client tracking into a single Map for simpler cleanup and iteration.
global gStore_ClientState := Map()
global gStore_LastBroadcastRev := -1
global gStore_TestMode := false
; NOTE: Fallback scan interval now in config: cfg.WinEnumFallbackScanIntervalMs (default 2000)
global gStore_ErrorLog := ""
global gStore_LastClientLog := 0
global gStore_LastSendTick := 0       ; Tick of last message sent to ANY client (heartbeat or delta)
global gStore_CachedHeartbeatJson := ""
global gStore_CachedHeartbeatRev := -1
global gStore_HeartbeatCount
global gStore_ScanInProgress := false  ; Re-entrancy guard for Store_FullScan

; Timer stagger offsets (negative = one-shot) to avoid thundering herd
global STORE_STAGGER_ZPUMP_MS := -17
global STORE_STAGGER_VALIDATE_MS := -37
global STORE_STAGGER_HEARTBEAT_MS := -53

; Producer state tracking: "running", "disabled", "failed"
global gStore_ProducerState := Map()
for _, _name in PRODUCER_NAMES
    gStore_ProducerState[_name] := "disabled"

; Parse command-line args into local vars first (ConfigLoader_Init will set defaults)
global gStore_CmdLinePipe := ""  ; Command-line override for pipe name
global gStore_CmdLineHeartbeatMs := 0  ; Command-line override for heartbeat interval
for _, arg in A_Args {
    if (arg = "--test")
        gStore_TestMode := true
    else if (SubStr(arg, 1, 6) = "--log=")
        gStore_ErrorLog := SubStr(arg, 7)
    else if (SubStr(arg, 1, 7) = "--pipe=")
        gStore_CmdLinePipe := SubStr(arg, 8)
    else if (SubStr(arg, 1, 15) = "--heartbeat-ms=")
        gStore_CmdLineHeartbeatMs := Integer(SubStr(arg, 16))
}
if (gStore_TestMode) {
    A_IconHidden := true  ; No tray icon when launched by test runner
    try OnError(Store_OnError)
    IPC_DebugLogPath := A_ScriptDir "\..\..\tests\windowstore_ipc.log"
    try FileDelete(IPC_DebugLogPath)
    Store_LogError("store_dir=" A_ScriptDir)
    Store_LogError("ipc_exists=" (FileExist(A_ScriptDir "\..\shared\ipc_pipe.ahk") ? "1" : "0"))
}

Store_Init() {
    global gStore_Server, gStore_CmdLinePipe, cfg
    global gStore_CmdLineHeartbeatMs, gStore_ProducerState

    ; Load config.ini (overrides defaults from gConfigRegistry)
    ; Let ConfigLoader_Init() determine path based on A_IsCompiled:
    ; - Compiled: uses A_ScriptDir (exe directory)
    ; - Development: tries A_ScriptDir, then A_ScriptDir "\..\"
    ; In test mode, use readOnly to avoid file contention when multiple
    ; test processes run in parallel (they'd all try to supplement config.ini)
    global gStore_TestMode
    ConfigLoader_Init("", gStore_TestMode)

    ; Initialize stats tracking (loads lifetime stats from disk)
    Stats_Init()

    ; Reset store log for new session (unconditional - Store_LogError is always-on)
    global LOG_PATH_STORE
    LogInitSession(LOG_PATH_STORE, "Alt-Tabby Store Log")

    ; Apply command-line overrides AFTER config init (command line wins)
    if (gStore_CmdLinePipe != "")
        cfg.StorePipeName := gStore_CmdLinePipe
    if (gStore_CmdLineHeartbeatMs > 0)
        cfg.StoreHeartbeatIntervalMs := gStore_CmdLineHeartbeatMs

    ; Load blacklist before anything else
    if (!Blacklist_Init()) {
        if (cfg.DiagStoreLog)
            Store_LogInfo("blacklist.txt not found, using empty blacklist")
    } else if (cfg.DiagStoreLog) {
        stats := Blacklist_GetStats()
        Store_LogInfo("blacklist loaded: " stats.titles " titles, " stats.classes " classes, " stats.pairs " pairs")
    }

    WindowStore_Init()
    if (!_Store_HasIpcSymbols()) {
        Store_LogError("ipc_pipe symbols missing")
        ExitApp(1)
    }
    gStore_Server := IPC_PipeServer_Start(cfg.StorePipeName, Store_OnMessage, Store_OnClientDisconnect)

    ; Register PostMessage wake handler: clients PostMessage us after writing to the pipe
    ; so we read data immediately instead of waiting for the next timer tick (0-100ms savings)
    global IPC_WM_PIPE_WAKE
    OnMessage(IPC_WM_PIPE_WAKE, _Store_OnPipeWake)

    ; Initialize producers BEFORE first scan so they can enrich data

    ; Komorebi is optional - graceful if not installed
    if (cfg.UseKomorebiSub) {
        ksubOk := KomorebiSub_Init()
        gStore_ProducerState["komorebiSub"] := ksubOk ? "running" : "failed"
        if (ksubOk) {
            if (cfg.DiagStoreLog)
                Store_LogInfo("KomorebiSub active")
        } else
            Store_LogError("KomorebiSub failed to start")
    } else if (cfg.UseKomorebiLite) {
        kLiteOk := KomorebiLite_Init()
        gStore_ProducerState["komorebiLite"] := kLiteOk ? "running" : "failed"
        if (kLiteOk) {
            if (cfg.DiagStoreLog)
                Store_LogInfo("KomorebiLite active")
        } else
            Store_LogError("KomorebiLite failed to start")
    }

    ; Pumps
    if (cfg.UseIconPump) {
        IconPump_Start()
        gStore_ProducerState["iconPump"] := "running"
    }
    if (cfg.UseProcPump) {
        ProcPump_Start()
        gStore_ProducerState["procPump"] := "running"
    }

    ; Do initial full scan AFTER producers init so data includes komorebi workspace info
    Store_FullScan()

    ; WinEventHook is always enabled (primary source of window changes + MRU tracking)
    hookOk := WinEventHook_Start()
    if (!hookOk) {
        Store_LogError("WinEventHook failed to start - enabling MRU_Lite fallback and safety polling")
        gStore_ProducerState["wineventHook"] := "failed"
        ; Fallback: enable MRU_Lite for focus tracking
        MRU_Lite_Init()
        gStore_ProducerState["mruLite"] := "running"
        ; Fallback: enable safety polling if hook fails
        SetTimer(Store_FullScan, cfg.WinEnumFallbackScanIntervalMs)
    } else {
        ; Hook working - it handles MRU tracking internally
        if (cfg.DiagStoreLog)
            Store_LogInfo("WinEventHook active - MRU tracking via hook")
        gStore_ProducerState["wineventHook"] := "running"
        ; Start Z-pump for on-demand scans (staggered to avoid timer alignment)
        global STORE_STAGGER_ZPUMP_MS, STORE_STAGGER_VALIDATE_MS, STORE_STAGGER_HEARTBEAT_MS
        SetTimer(_Store_StartZPump, STORE_STAGGER_ZPUMP_MS)

        ; Optional safety net polling (usually disabled)
        if (cfg.WinEnumSafetyPollMs > 0) {
            SetTimer(Store_FullScan, cfg.WinEnumSafetyPollMs)
        }
    }

    ; Stagger remaining timers to avoid thundering herd when multiple timers
    ; align on the same tick. One-shot timers (-N) fire once at the offset,
    ; then the callback starts the periodic timer.
    ; Start lightweight existence validation (catches zombies from crashes)
    if (cfg.WinEnumValidateExistenceMs > 0) {
        SetTimer(_Store_StartValidateExistence, STORE_STAGGER_VALIDATE_MS)
    }

    ; NOTE: Producer state is NOT stored in gWS_Meta anymore (removes bloat from deltas/snapshots)
    ; Clients that need producer status should send IPC_MSG_PRODUCER_STATUS_REQUEST

    ; Start heartbeat timer for client connection health (staggered)
    SetTimer(_Store_StartHeartbeat, STORE_STAGGER_HEARTBEAT_MS)
}

; Broadcast heartbeat to all clients with current rev for drift detection
; Also performs periodic maintenance: cleanup orphaned entries, prune caches
Store_HeartbeatTick() {
    global gStore_Server, IPC_MSG_HEARTBEAT, cfg

    ; Safety net: clean up any orphaned client Map entries
    ; Primary cleanup happens in Store_OnClientDisconnect (via IPC callback)
    ; RACE FIX: Include heartbeat counter in Critical section
    if (IsObject(gStore_Server)) {
        Critical "On"
        _Store_CleanupDisconnectedClients()
        global gStore_HeartbeatCount
        if (!IsSet(gStore_HeartbeatCount))
            gStore_HeartbeatCount := 0
        gStore_HeartbeatCount += 1
        Critical "Off"
    }

    ; Early exit if no clients - skip expensive pruning operations
    ; (prune operations only matter when we're actively serving clients)
    if (!IsObject(gStore_Server) || !gStore_Server.clients.Count)
        return

    ; Prune stale workspace cache entries (Issue #3 - memory leak prevention)
    try KomorebiSub_PruneStaleCache()

    ; Prune dead PIDs from process name cache (prevents unbounded growth)
    try WindowStore_PruneProcNameCache()

    ; Prune orphaned exe paths from icon cache (exe paths not used by any live window)
    try WindowStore_PruneExeIconCache()

    ; Prune expired entries from proc pump failed PID cache
    try ProcPump_PruneFailedPidCache()

    ; Periodic log rotation for diagnostic logs (~every 60s)
    if (Mod(gStore_HeartbeatCount, 12) = 0)
        _Store_RotateDiagLogs()

    ; Flush stats to disk every ~5 minutes (60 heartbeats at 5s interval)
    if (Mod(gStore_HeartbeatCount, 60) = 0)
        try Stats_FlushToDisk()

    ; Periodic full sync: send complete snapshot to all clients for full-state healing
    ; This catches issues that per-row healing cannot fix (e.g., ghost rows, missing rows)
    if (cfg.IPCFullSyncEvery > 0 && Mod(gStore_HeartbeatCount, cfg.IPCFullSyncEvery) = 0) {
        Store_ForceFullSync()
        return  ; Full sync subsumes heartbeat
    }

    ; Log churn diagnostics (what fields and sources are triggering rev bumps)
    if (cfg.DiagChurnLog) {
        churn := WindowStore_GetChurnDiag(true)
        if (churn["sources"].Count > 0 || churn["fields"].Count > 0) {
            srcParts := ""
            for src, count in churn["sources"]
                srcParts .= (srcParts ? ", " : "") . src "=" count
            fldParts := ""
            for fld, count in churn["fields"]
                fldParts .= (fldParts ? ", " : "") . fld "=" count
            Store_LogInfo("CHURN src=[" srcParts "] fields=[" fldParts "]")
        }
    }

    ; Only send heartbeat when no message (delta or heartbeat) was sent recently.
    ; Store_PushToClients updates gStore_LastSendTick on every delta/snapshot,
    ; so heartbeats are naturally suppressed when data is flowing.
    ; Clients use time-based health monitoring (gGUI_LastMsgTick / gViewer_LastMsgTick)
    ; and timeout after ViewerHeartbeatTimeoutMs (default 12s), so they don't care
    ; whether they receive heartbeats or deltas — just that SOMETHING arrives.
    global gStore_LastSendTick
    if (gStore_LastSendTick && (A_TickCount - gStore_LastSendTick) < cfg.StoreHeartbeatIntervalMs)
        return
    rev := WindowStore_GetRev()
    global gStore_CachedHeartbeatJson, gStore_CachedHeartbeatRev
    if (rev != gStore_CachedHeartbeatRev) {
        gStore_CachedHeartbeatJson := JSON.Dump({ type: IPC_MSG_HEARTBEAT, rev: rev })
        gStore_CachedHeartbeatRev := rev
    }
    ; No PostMessage wake for heartbeats — they're liveness-only (12s timeout).
    ; Clients pick them up on the next timer tick (0-100ms), which is fine.
    IPC_PipeServer_Broadcast(gStore_Server, gStore_CachedHeartbeatJson)
    gStore_LastSendTick := A_TickCount
}

; Timer stagger helpers: one-shot callbacks that start periodic timers.
; Called from Store_Init with offset delays to prevent thundering herd.
_Store_StartZPump() {
    global cfg
    SetTimer(Store_ZPumpTick, cfg.ZPumpIntervalMs)
}
_Store_StartValidateExistence() {
    global cfg
    SetTimer(Store_ValidateExistenceTick, cfg.WinEnumValidateExistenceMs)
}
_Store_StartHeartbeat() {
    global cfg
    SetTimer(Store_HeartbeatTick, cfg.StoreHeartbeatIntervalMs)
}

; PostMessage wake handler: a client wrote to our pipe and signaled us.
; Read immediately instead of waiting for next timer tick.
_Store_OnPipeWake(wParam, lParam, msg, hwnd) {
    global gStore_Server
    if (IsObject(gStore_Server))
        IPC__ServerTick(gStore_Server)
    return 0
}

; Deferred scan: runs after immediate snapshot response, catches recently-created windows.
; Uses _WEH_PushIfRevChanged to send correction delta only if scan found changes.
_Store_DeferredScanAndPush() {
    Store_FullScan()
    WindowStore_ClearZQueue()
    ; Push correction delta if scan discovered changes
    _WEH_PushIfRevChanged(true)
}

; Rotate diagnostic logs that are enabled (called every 12th heartbeat, ~60s)
_Store_RotateDiagLogs() {
    global cfg
    global LOG_PATH_STORE, LOG_PATH_KSUB, LOG_PATH_WINEVENT
    global LOG_PATH_ICONPUMP, LOG_PATH_PROCPUMP, LOG_PATH_IPC
    global LOG_PATH_WEBVIEW
    ; Always trim store log -- Store_LogError() writes unconditionally
    LogTrim(LOG_PATH_STORE)
    if (cfg.DiagKomorebiLog)
        LogTrim(LOG_PATH_KSUB)
    if (cfg.DiagWinEventLog)
        LogTrim(LOG_PATH_WINEVENT)
    if (cfg.DiagIconPumpLog)
        LogTrim(LOG_PATH_ICONPUMP)
    if (cfg.DiagProcPumpLog)
        LogTrim(LOG_PATH_PROCPUMP)
    if (cfg.DiagIPCLog)
        LogTrim(LOG_PATH_IPC)
    if (cfg.DiagWebViewLog)
        LogTrim(LOG_PATH_WEBVIEW)
}

; Force full snapshot to all clients - resets tracking so PushToClients sends SNAPSHOT not DELTA
; Used by FullSyncEvery heartbeat-counted full-state healing to fix ghost/missing rows
Store_ForceFullSync() {
    global gStore_Server, gStore_ClientState

    if (!IsObject(gStore_Server) || !gStore_Server.clients.Count)
        return

    ; Reset per-client tracking so PushToClients treats them as new
    ; (empty prevItems → IPC_MSG_SNAPSHOT instead of delta)
    Critical "On"
    _Store_CleanupDisconnectedClients()
    for hPipe, _ in gStore_Server.clients {
        if (gStore_ClientState.Has(hPipe)) {
            cs := gStore_ClientState[hPipe]
            cs.lastRev := -1      ; Bypass rev-skip check
            cs.lastProj := []     ; Force snapshot path
            cs.lastMeta := ""
            cs.pushCount := 0
        }
    }
    Critical "Off"

    Store_PushToClients()
}

; Z-Pump: triggers full scan when windows need Z-order enrichment
Store_ZPumpTick() {
    if (!WindowStore_HasPendingZ())
        return
    ; Windows need Z-order - run full scan
    Store_FullScan()
    ; Clear the queue after scan
    WindowStore_ClearZQueue()
}

; Lightweight zombie detection - validates existing store entries still exist
Store_ValidateExistenceTick() {
    result := WindowStore_ValidateExistence()
    if (result.removed > 0) {
        Store_PushToClients()
    }
}

; Full winenum scan - runs on startup, snapshot request, Z-pump trigger, or safety polling
Store_FullScan() {
    global gStore_LastBroadcastRev, gStore_Server, gStore_TestMode, gStore_LastClientLog, gWS_Store
    global gStore_ScanInProgress
    ; RACE FIX: Re-entrancy guard — if WinEnumLite_ScanAll() is interrupted by an IPC
    ; timer that triggers another Store_FullScan, the nested scan would corrupt gWS_ScanId
    ; and cause EndScan to incorrectly mark windows as missing
    Critical "On"
    if (gStore_ScanInProgress) {
        Critical "Off"
        return
    }
    gStore_ScanInProgress := true
    Critical "Off"

    if (gStore_TestMode && (A_TickCount - gStore_LastClientLog) > 3000) {
        gStore_LastClientLog := A_TickCount
        try Store_LogError("clients=" gStore_Server.clients.Count " store=" gWS_Store.Count " rev=" WindowStore_GetRev())
    }
    WindowStore_BeginScan()
    recs := ""
    try recs := WinEnumLite_ScanAll()
    if (IsObject(recs))
        WindowStore_UpsertWindow(recs, "winenum_lite")
    WindowStore_EndScan()
    ; RACE FIX: Wrap read-check-write in Critical to prevent two callers
    ; from both reading same old rev and both pushing (duplicate broadcast)
    Critical "On"
    gStore_ScanInProgress := false
    rev := WindowStore_GetRev()
    if (rev != gStore_LastBroadcastRev) {
        gStore_LastBroadcastRev := rev
        Critical "Off"
        Store_PushToClients()
    } else {
        Critical "Off"
    }
}

; Push tailored projections to each client based on their registered opts
; Uses Critical section to atomically snapshot client handles, preventing race
; conditions where clients disconnect during iteration
Store_PushToClients() {
    global gStore_Server, gStore_ClientState, gStore_TestMode
    global IPC_MSG_SNAPSHOT, IPC_MSG_DELTA, gStore_LastSendTick, cfg
    global gWS_DeltaPendingHwnds

    if (!IsObject(gStore_Server) || !gStore_Server.clients.Count)
        return

    ; Atomically clean up disconnected clients and snapshot current handles + state
    ; This prevents race conditions if clients disconnect during iteration
    ; RACE FIX: Also snapshot client state - it can be modified by Store_OnMessage
    ; (HELLO, SET_PROJECTION_OPTS, PROJECTION_REQUEST)
    Critical "On"
    _Store_CleanupDisconnectedClients()
    ; PERF: Reuse static containers to avoid Map()/Array() allocation each push cycle
    static clientHandles := []
    static clientOptsSnapshot := Map()
    static clientPrevProj := Map()
    static clientPrevRev := Map()
    static clientPrevMeta := Map()
    static clientWakeHwnds := Map()
    clientHandles.Length := 0
    clientOptsSnapshot.Clear()
    clientPrevProj.Clear()
    clientPrevRev.Clear()
    clientPrevMeta.Clear()
    clientWakeHwnds.Clear()
    for hPipe, _ in gStore_Server.clients {
        clientHandles.Push(hPipe)
        if (gStore_ClientState.Has(hPipe)) {
            cs := gStore_ClientState[hPipe]
            clientOptsSnapshot[hPipe] := cs.opts
            clientPrevProj[hPipe] := cs.lastProj
            clientPrevRev[hPipe] := cs.lastRev
            clientPrevMeta[hPipe] := cs.lastMeta
            clientWakeHwnds[hPipe] := cs.HasOwnProp("wakeHwnd") ? cs.wakeHwnd : 0
        }
    }
    ; Snapshot dirty set and clear immediately - any updates during this push
    ; will mark the NEW dirty set and be caught on next push
    dirtySnapshot := gWS_DeltaPendingHwnds.Clone()
    gWS_DeltaPendingHwnds := Map()
    Critical "Off"

    ; In OnChange mode, send dedicated workspace_change message when workspace changes
    global IPC_MSG_WORKSPACE_CHANGE
    wsJustChanged := WindowStore_ConsumeWorkspaceChangedFlag()

    ; Early exit: if nothing changed and no workspace switch, skip all client work
    if (dirtySnapshot.Count = 0 && !wsJustChanged) {
        return
    }

    if (wsJustChanged && cfg.IPCWorkspaceDeltaStyle = "OnChange") {
        wsMeta := WindowStore_GetCurrentWorkspace()
        ; Direct string build — avoids cJSON object alloc + marshaling overhead for fixed-format template
        safeName := StrReplace(StrReplace(wsMeta.name, '\', '\\'), '"', '\"')
        wsMsg := '{"type":"workspace_change","payload":{"meta":{"currentWSId":' wsMeta.id ',"currentWSName":"' safeName '"}}}'
        for _, hPipe in clientHandles {
            if (!clientOptsSnapshot.Has(hPipe))
                continue
            wh := clientWakeHwnds.Has(hPipe) ? clientWakeHwnds[hPipe] : 0
            IPC_PipeServer_Send(gStore_Server, hPipe, wsMsg, wh)
        }
        gStore_LastSendTick := A_TickCount
    }

    ; Cache projections by normalized opts key within this push cycle.
    ; When multiple clients have equivalent opts (e.g. GUI + Viewer both default
    ; to MRU/items/includeCloaked), this avoids redundant store iteration + sort.
    ; PERF: Reuse static containers to avoid Map() allocation each push cycle
    static projCache := Map()
    ; Cache serialized JSON for snapshot messages by optsKey.
    ; Snapshots are identical for the same optsKey (same projection, same rev),
    ; so we can avoid redundant JSON.Dump calls when multiple clients need snapshots.
    static jsonSnapshotCache := Map()
    ; Cache serialized JSON for delta messages by composite key (optsKey|lastRev|isSparse|includeMeta).
    ; When two clients have the same optsKey AND lastRev, their prevItems are identical
    ; (they received the same projection at that rev), so deltas are identical.
    ; Avoids redundant Store_BuildClientDelta + JSON.Dump per-client.
    static deltaCache := Map()
    projCache.Clear()
    jsonSnapshotCache.Clear()
    deltaCache.Clear()

    sent := 0
    for _, hPipe in clientHandles {
        ; Skip clients that haven't sent HELLO yet - they have no registered opts.
        ; The HELLO handler sends an initial snapshot with correct format, so
        ; broadcasting here would just waste work and send the wrong format.
        if (!clientOptsSnapshot.Has(hPipe))
            continue

        opts := clientOptsSnapshot[hPipe]

        ; Generate projection tailored to this client (cached per opts fingerprint)
        optsKey := _Store_OptsKey(opts)
        if (projCache.Has(optsKey))
            proj := projCache[optsKey]
        else {
            proj := WindowStore_GetProjection(opts)
            projCache[optsKey] := proj
        }

        ; Get client's previous projection for delta calculation (from snapshot)
        prevItems := clientPrevProj.Has(hPipe) ? clientPrevProj[hPipe] : []
        lastRev := clientPrevRev.Has(hPipe) ? clientPrevRev[hPipe] : -1
        prevMeta := clientPrevMeta.Has(hPipe) ? clientPrevMeta[hPipe] : ""

        ; Skip if nothing changed for this client
        if (lastRev = proj.rev)
            continue

        ; Check if meta changed (workspace name)
        metaChanged := WindowStore_MetaChanged(prevMeta, proj.meta)

        ; Per-client push counter for sparse/full sync cycling
        ; (read from snapshot, update live state after send)
        cs := gStore_ClientState.Has(hPipe) ? gStore_ClientState[hPipe] : ""
        pushCount := IsObject(cs) ? cs.pushCount + 1 : 1

        ; Determine sparse vs full row mode
        sparseN := cfg.IPCFullRowEvery
        isSparse := sparseN > 0 && Mod(pushCount, sparseN) != 0
        ; Meta inclusion: always on full row sync; in Always mode; or when meta changed
        isAlwaysMode := (cfg.IPCWorkspaceDeltaStyle = "Always")
        includeMeta := !isSparse || isAlwaysMode || metaChanged

        ; Resolve client wake hwnd for PostMessage after send
        wh := clientWakeHwnds.Has(hPipe) ? clientWakeHwnds[hPipe] : 0

        ; Send delta if client has previous state, otherwise full snapshot
        if (prevItems.Length > 0) {
            ; Delta cache: clients with same (optsKey, lastRev, isSparse, includeMeta)
            ; produce identical deltas — reuse serialized JSON.
            deltaKey := optsKey "|" lastRev "|" isSparse "|" includeMeta
            if (deltaCache.Has(deltaKey)) {
                cached := deltaCache[deltaKey]
                if (cached.skip)
                    continue
                IPC_PipeServer_Send(gStore_Server, hPipe, cached.jsonStr, wh)
            } else {
                msg := Store_BuildClientDelta(prevItems, proj.items, proj.meta, proj.rev, lastRev, isSparse, includeMeta, dirtySnapshot)
                ; Skip sending empty deltas ONLY if meta also didn't change
                ; Always send if meta changed (workspace switch) even with no window changes
                skip := (msg.payload.upserts.Length = 0 && msg.payload.removes.Length = 0 && !metaChanged)
                jsonStr := skip ? "" : JSON.Dump(msg)
                deltaCache[deltaKey] := { skip: skip, jsonStr: jsonStr }
                if (skip)
                    continue
                IPC_PipeServer_Send(gStore_Server, hPipe, jsonStr, wh)
            }
        } else {
            ; Initial snapshot: identical for same optsKey, safe to cache serialized JSON
            if (jsonSnapshotCache.Has(optsKey)) {
                IPC_PipeServer_Send(gStore_Server, hPipe, jsonSnapshotCache[optsKey], wh)
            } else {
                msg := {
                    type: IPC_MSG_SNAPSHOT,
                    rev: proj.rev,
                    payload: { meta: proj.meta, items: proj.items }
                }
                jsonStr := JSON.Dump(msg)
                jsonSnapshotCache[optsKey] := jsonStr
                IPC_PipeServer_Send(gStore_Server, hPipe, jsonStr, wh)
            }
        }

        ; RACE FIX: Wrap client tracking updates in Critical
        ; Store_OnMessage also modifies client state when client sends HELLO or SET_PROJECTION_OPTS
        Critical "On"
        if (gStore_ClientState.Has(hPipe)) {
            cs := gStore_ClientState[hPipe]
            cs.lastRev := proj.rev
            cs.lastProj := proj.items
            cs.lastMeta := proj.meta
            cs.pushCount := pushCount
        }
        Critical "Off"
        sent++
    }

    if (sent > 0)
        gStore_LastSendTick := A_TickCount
    if (gStore_TestMode && sent > 0) {
        Store_LogError("pushed to " sent " clients")
    }

    ; PERF: Bound diagnostic maps to prevent unbounded memory growth
    ; Unconditional: maps may retain entries from when logging was previously enabled
    global gWS_DiagChurn, gWS_DiagSource
    ; RACE FIX: Protect map swap from UpsertWindow/_WS_BumpRev writing to old reference
    Critical "On"
    if (gWS_DiagChurn.Count > 1000)
        gWS_DiagChurn := Map()
    if (gWS_DiagSource.Count > 1000)
        gWS_DiagSource := Map()
    Critical "Off"
}

; Build delta message for a specific client (uses WindowStore_BuildDelta for core logic)
; DESIGN: Workspace metadata in deltas controlled by IPCWorkspaceDeltaStyle config.
; 'Always' mode includes meta in every delta (self-healing, default). 'OnChange' mode
; only includes meta when workspace changes, and sends workspace_change messages for
; dedicated notification. The includeMeta parameter reflects this configuration.
Store_BuildClientDelta(prevItems, nextItems, meta, rev, baseRev, sparse := false, includeMeta := true, dirtyHwnds := 0) {
    global IPC_MSG_DELTA
    delta := WindowStore_BuildDelta(prevItems, nextItems, sparse, dirtyHwnds)
    payload := { upserts: delta.upserts, removes: delta.removes }
    if (includeMeta)
        payload.meta := meta
    return {
        type: IPC_MSG_DELTA,
        rev: rev,
        baseRev: baseRev,
        payload: payload
    }
}

; Broadcast workspace flip delta to all connected clients.
; Called by komorebi_sub after SetCurrentWorkspace to deliver the workspace change
; immediately (~0.5ms) instead of waiting for a full Store_PushToClients (~5ms).
;
; ANTI-JIGGLE (Part 1 of 2 — see also gui_overlay.ahk GUI_ResizeToRows):
; Sends META ONLY (workspace name/id), NOT item upserts.  The flips array
; contains _WS_ToItem records whose isOnCurrentWorkspace just changed, but
; their lastActivatedTick values are STALE (ProcessFullState hasn't updated
; MRU yet).  Sending these stale items causes the GUI to repaint with the
; correct item COUNT but wrong MRU ORDER (old focused window at slot #1),
; then PushToClients ~5ms later sends correct MRU → second repaint → jiggle.
; Fix: send only meta here.  PushToClients sends ONE delta with both the
; workspace flips AND correct MRU data, so the GUI gets one clean repaint.
;
; Parameters:
;   flips - Array of _WS_ToItem records (kept for API compat, not sent to clients)
Store_BroadcastWorkspaceFlips(flips) {
    global gStore_Server, gStore_ClientState, gStore_LastSendTick, gStore_LastBroadcastRev
    global IPC_MSG_DELTA

    if (!IsObject(gStore_Server) || !gStore_Server.clients.Count)
        return

    wsMeta := WindowStore_GetCurrentWorkspace()
    rev := WindowStore_GetRev()
    ; Direct string build — avoids cJSON object alloc + marshaling overhead for fixed-format template
    safeName := StrReplace(StrReplace(wsMeta.name, '\', '\\'), '"', '\"')
    msg := '{"type":"delta","rev":' rev ',"baseRev":' (rev - 1)
        . ',"payload":{"meta":{"currentWSId":' wsMeta.id ',"currentWSName":"' safeName '"},"upserts":[],"removes":[]}}'

    ; Broadcast to all clients that have completed HELLO (have registered opts)
    ; Clients without opts haven't connected yet and will get a full snapshot on HELLO
    Critical "On"
    for hPipe, _ in gStore_Server.clients {
        if (gStore_ClientState.Has(hPipe)) {
            cs := gStore_ClientState[hPipe]
            wh := cs.HasOwnProp("wakeHwnd") ? cs.wakeHwnd : 0
            IPC_PipeServer_Send(gStore_Server, hPipe, msg, wh)
            cs.lastRev := rev
        }
    }
    ; Consume workspace changed flag so the subsequent Store_PushToClients
    ; doesn't re-send the workspace_change message
    WindowStore_ConsumeWorkspaceChangedFlag()
    Critical "Off"
    gStore_LastBroadcastRev := rev
    gStore_LastSendTick := A_TickCount
}

Store_OnMessage(line, hPipe := 0) {
    global gStore_ClientState
    global gStore_Server, gStore_LastSendTick
    global IPC_MSG_HELLO, IPC_MSG_HELLO_ACK, IPC_MSG_SNAPSHOT, IPC_MSG_PROJECTION
    global IPC_MSG_SET_PROJECTION_OPTS, IPC_MSG_SNAPSHOT_REQUEST, IPC_MSG_PROJECTION_REQUEST
    global IPC_MSG_RELOAD_BLACKLIST, IPC_MSG_PRODUCER_STATUS_REQUEST, IPC_MSG_PRODUCER_STATUS
    global IPC_MSG_STATS_UPDATE, IPC_MSG_STATS_REQUEST, IPC_MSG_STATS_RESPONSE
    global gStats_Lifetime, gStats_Session, STATS_CUMULATIVE_KEYS
    global cfg
    obj := ""
    try obj := JSON.Load(line)
    catch as err {
        ; Log malformed JSON when diagnostics enabled (helps debug IPC issues)
        if (cfg.DiagStoreLog) {
            preview := (StrLen(line) > 80) ? SubStr(line, 1, 80) "..." : line
            Store_LogInfo("JSON parse error: " err.Message " | content: " preview)
        }
        return
    }
    if (!IsObject(obj) || !obj.Has("type"))
        return
    type := obj["type"]
    if (type = IPC_MSG_HELLO) {
        ; RACE FIX: Wrap ALL client Map modifications in single Critical section
        ; to prevent timer interrupts from seeing inconsistent state between
        ; initial writes and final projection tracking updates
        Critical "On"
        ; Extract client's wake hwnd for PostMessage pipe wake (0 if not provided)
        wakeHwnd := obj.Has("hwnd") ? obj["hwnd"] : 0
        opts := obj.Has("projectionOpts") ? obj["projectionOpts"] : IPC_DefaultProjectionOpts()
        gStore_ClientState[hPipe] := {opts: opts, lastRev: -1, lastProj: [], lastMeta: "", pushCount: 0, wakeHwnd: wakeHwnd}

        ; Send hello ack with store's hwnd so client can PostMessage us
        ack := {
            type: IPC_MSG_HELLO_ACK,
            hwnd: A_ScriptHwnd,
            payload: { meta: WindowStore_GetCurrentWorkspace(), capabilities: { deltas: true } }
        }
        IPC_PipeServer_Send(gStore_Server, hPipe, JSON.Dump(ack), wakeHwnd)

        ; Immediately send initial projection with client's opts
        proj := WindowStore_GetProjection(opts)
        ; Handle both items and hwndsOnly response formats (same logic as PROJECTION_REQUEST)
        payload := { meta: proj.meta }
        if (proj.HasOwnProp("hwnds"))
            payload.hwnds := proj.hwnds
        else
            payload.items := proj.HasOwnProp("items") ? proj.items : []
        msg := {
            type: IPC_MSG_SNAPSHOT,
            rev: proj.rev,
            payload: payload
        }
        IPC_PipeServer_Send(gStore_Server, hPipe, JSON.Dump(msg), wakeHwnd)
        cs := gStore_ClientState[hPipe]
        cs.lastRev := proj.rev
        cs.lastProj := proj.HasOwnProp("items") ? proj.items : []
        gStore_LastSendTick := A_TickCount
        Critical "Off"
        return
    }
    if (type = IPC_MSG_SET_PROJECTION_OPTS) {
        if (obj.Has("projectionOpts") && gStore_ClientState.Has(hPipe)) {
            ; RACE FIX: Wrap client state modifications in Critical
            Critical "On"
            cs := gStore_ClientState[hPipe]
            cs.opts := obj["projectionOpts"]
            ; Clear last projection/meta so client gets fresh snapshot with new opts
            cs.lastProj := []
            cs.lastMeta := ""
            Critical "Off"
        }
        return
    }
    if (type = IPC_MSG_SNAPSHOT_REQUEST || type = IPC_MSG_PROJECTION_REQUEST) {
        ; Snapshot requests: serve immediately from current state, then scan deferred.
        ; WinEventHook already tracks window lifecycle, so current state is usually accurate.
        ; The deferred scan catches edge cases (windows created in last ~100ms).
        ; If the scan discovers changes, Store_PushToClients sends a correction delta.
        if (type = IPC_MSG_SNAPSHOT_REQUEST) {
            SetTimer(_Store_DeferredScanAndPush, -1)
        }
        opts := IPC_DefaultProjectionOpts()
        if (gStore_ClientState.Has(hPipe))
            opts := gStore_ClientState[hPipe].opts
        if (obj.Has("projectionOpts")) {
            opts := obj["projectionOpts"]
            ; Persist opts for future pushes so Store_PushToClients uses the same
            ; filter (e.g. currentWorkspaceOnly) the client just requested.
            ; Without this, pushes use stale default opts, creating a mismatch
            ; between what the client has and what the store thinks it has.
            if (gStore_ClientState.Has(hPipe))
                gStore_ClientState[hPipe].opts := opts
        }
        ; Flush any pending komorebi data before building the projection.
        ; When the GUI toggles workspace mode (Ctrl) right after a workspace switch,
        ; the projection request can arrive before the komorebi event has been polled.
        ; Without this flush, the projection is served with stale MRU ticks (the old
        ; workspace's focused window still appears as #1 instead of the new workspace's).
        try KomorebiSub_Poll()
        proj := WindowStore_GetProjection(opts)
        respType := (type = IPC_MSG_SNAPSHOT_REQUEST) ? IPC_MSG_SNAPSHOT : IPC_MSG_PROJECTION
        ; Handle both items and hwndsOnly response formats
        payload := { meta: proj.meta }
        if (proj.HasOwnProp("hwnds"))
            payload.hwnds := proj.hwnds
        else
            payload.items := proj.HasOwnProp("items") ? proj.items : []
        resp := {
            type: respType,
            rev: proj.rev,
            payload: payload
        }
        wh := (gStore_ClientState.Has(hPipe) && gStore_ClientState[hPipe].HasOwnProp("wakeHwnd")) ? gStore_ClientState[hPipe].wakeHwnd : 0
        IPC_PipeServer_Send(gStore_Server, hPipe, JSON.Dump(resp), wh)
        ; RACE FIX: Update ALL client tracking to match what was actually sent.
        ; Without this, Store_PushToClients computes deltas against stale prevItems
        ; (from the last push, not the projection response). When the GUI has replaced
        ; its items with workspace-filtered projection data, sparse deltas for items
        ; NOT in the GUI's map create ghost entries with empty fields.
        Critical "On"
        if (gStore_ClientState.Has(hPipe)) {
            cs := gStore_ClientState[hPipe]
            cs.lastRev := proj.rev
            cs.lastProj := proj.HasOwnProp("items") ? proj.items : []
            cs.lastMeta := proj.meta
        }
        Critical "Off"
        gStore_LastSendTick := A_TickCount
        return
    }
    if (type = IPC_MSG_RELOAD_BLACKLIST) {
        ; Reload blacklist from file
        Blacklist_Reload()
        if (cfg.DiagStoreLog) {
            stats := Blacklist_GetStats()
            Store_LogInfo("blacklist reloaded: " stats.titles " titles, " stats.classes " classes, " stats.pairs " pairs")
        }

        ; Purge windows that now match the blacklist
        purgeResult := WindowStore_PurgeBlacklisted()
        if (cfg.DiagStoreLog)
            Store_LogInfo("blacklist purge removed " purgeResult.removed " windows")

        ; Clear all client projections/meta to force fresh delta calculation
        Critical "On"
        for _, cs in gStore_ClientState {
            cs.lastProj := []
            cs.lastMeta := ""
        }
        Critical "Off"

        ; Push updated projections to clients immediately
        Store_PushToClients()
        return
    }
    if (type = IPC_MSG_PRODUCER_STATUS_REQUEST) {
        ; Return current producer states (on-demand, not in every delta/snapshot)
        producers := _Store_GetProducerStates()
        resp := {
            type: IPC_MSG_PRODUCER_STATUS,
            producers: producers
        }
        wh := (gStore_ClientState.Has(hPipe) && gStore_ClientState[hPipe].HasOwnProp("wakeHwnd")) ? gStore_ClientState[hPipe].wakeHwnd : 0
        IPC_PipeServer_Send(gStore_Server, hPipe, JSON.Dump(resp), wh)
        return
    }
    if (type = IPC_MSG_STATS_UPDATE) {
        ; Accumulate GUI session stats into lifetime (GUI sends deltas since last send)
        ; RACE FIX: Protect gStats_Lifetime from concurrent Stats_FlushToDisk (heartbeat timer)
        Critical "On"
        for _, key in STATS_CUMULATIVE_KEYS {
            if (obj.Has(key))
                gStats_Lifetime[key] := gStats_Lifetime.Get(key, 0) + obj[key]
        }
        Critical "Off"
        return
    }
    if (type = IPC_MSG_STATS_REQUEST) {
        ; Build response combining lifetime + session stats + derived values
        ; RACE FIX: Protect gStats_Lifetime/gStats_Session reads from Stats_FlushToDisk (heartbeat timer)
        ; Release Critical before IPC_PipeServer_Send to avoid holding lock during I/O
        Critical "On"
        resp := { type: IPC_MSG_STATS_RESPONSE }

        ; Copy all lifetime stats
        for key, val in gStats_Lifetime
            resp.%key% := val

        ; Add current session info (use sessionStartTick which never resets, unlike startTick)
        sessionSec := Round((A_TickCount - gStats_Session.Get("sessionStartTick", A_TickCount)) / 1000)
        resp.SessionRunTimeSec := sessionSec
        resp.SessionPeakWindows := gStats_Session.Get("peakWindows", 0)

        ; Session activity deltas (current lifetime - baseline at launch)
        resp.SessionAltTabs := gStats_Lifetime.Get("TotalAltTabs", 0) - gStats_Session.Get("baselineAltTabs", 0)
        resp.SessionQuickSwitches := gStats_Lifetime.Get("TotalQuickSwitches", 0) - gStats_Session.Get("baselineQuickSwitches", 0)
        resp.SessionTabSteps := gStats_Lifetime.Get("TotalTabSteps", 0) - gStats_Session.Get("baselineTabSteps", 0)
        resp.SessionCancellations := gStats_Lifetime.Get("TotalCancellations", 0) - gStats_Session.Get("baselineCancellations", 0)
        resp.SessionCrossWorkspace := gStats_Lifetime.Get("TotalCrossWorkspace", 0) - gStats_Session.Get("baselineCrossWorkspace", 0)
        resp.SessionWorkspaceToggles := gStats_Lifetime.Get("TotalWorkspaceToggles", 0) - gStats_Session.Get("baselineWorkspaceToggles", 0)
        resp.SessionWindowUpdates := gStats_Lifetime.Get("TotalWindowUpdates", 0) - gStats_Session.Get("baselineWindowUpdates", 0)
        resp.SessionBlacklistSkips := gStats_Lifetime.Get("TotalBlacklistSkips", 0) - gStats_Session.Get("baselineBlacklistSkips", 0)

        ; Derived stats (compute here so dashboard just displays)
        totalRunSec := gStats_Lifetime.Get("TotalRunTimeSec", 0) + sessionSec
        totalAltTabs := gStats_Lifetime.Get("TotalAltTabs", 0)
        totalQuick := gStats_Lifetime.Get("TotalQuickSwitches", 0)
        totalCancels := gStats_Lifetime.Get("TotalCancellations", 0)
        totalTabs := gStats_Lifetime.Get("TotalTabSteps", 0)
        totalActivations := totalAltTabs + totalQuick

        resp.DerivedAvgAltTabsPerHour := (totalRunSec > 0) ? Round(totalAltTabs / (totalRunSec / 3600), 1) : 0
        resp.DerivedQuickSwitchPct := (totalActivations > 0) ? Round(totalQuick / totalActivations * 100, 1) : 0
        resp.DerivedCancelRate := (totalAltTabs + totalCancels > 0) ? Round(totalCancels / (totalAltTabs + totalCancels) * 100, 1) : 0
        resp.DerivedAvgTabsPerSwitch := (totalAltTabs > 0) ? Round(totalTabs / totalAltTabs, 1) : 0
        Critical "Off"

        wh := (gStore_ClientState.Has(hPipe) && gStore_ClientState[hPipe].HasOwnProp("wakeHwnd")) ? gStore_ClientState[hPipe].wakeHwnd : 0
        IPC_PipeServer_Send(gStore_Server, hPipe, JSON.Dump(resp), wh)
        return
    }
}

; Get current producer states as plain object (for IPC response)
_Store_GetProducerStates() {
    global gStore_ProducerState
    producers := {}
    Critical "On"
    for name, state in gStore_ProducerState
        producers.%name% := state
    Critical "Off"
    return producers
}

; Immediate cleanup callback when a client disconnects (called by IPC layer)
; This is the primary cleanup mechanism - prevents stale entries from accumulating
Store_OnClientDisconnect(hPipe) {
    global gStore_ClientState
    Critical "On"
    gStore_ClientState.Delete(hPipe)
    Critical "Off"
}

; Clean up tracking for disconnected clients (prevents memory leak)
; NOTE: This is now a safety net - primary cleanup is Store_OnClientDisconnect
_Store_CleanupDisconnectedClients() {
    global gStore_Server, gStore_ClientState

    ; Collect stale pipes first (cannot delete during iteration)
    stalePipes := []
    for hPipe, _ in gStore_ClientState {
        if (!gStore_Server.clients.Has(hPipe))
            stalePipes.Push(hPipe)
    }
    for _, hPipe in stalePipes
        gStore_ClientState.Delete(hPipe)
}

; Build a stable string key from projection opts for cache deduplication.
; Two opts objects with the same 5 projection fields produce the same key.
_Store_OptsKey(opts) {
    s := _WS_GetOpt(opts, "sort", "MRU")
    cw := _WS_GetOpt(opts, "currentWorkspaceOnly", false)
    im := _WS_GetOpt(opts, "includeMinimized", true)
    ic := _WS_GetOpt(opts, "includeCloaked", false)
    co := _WS_GetOpt(opts, "columns", "items")
    return s "|" cw "|" im "|" ic "|" co
}

; ============================================================
; STATS ENGINE
; ============================================================

; Cumulative stat keys - GUI sends deltas for these via stats_update
global STATS_CUMULATIVE_KEYS := [
    "TotalAltTabs", "TotalQuickSwitches", "TotalTabSteps",
    "TotalCancellations", "TotalCrossWorkspace", "TotalWorkspaceToggles"
]

; All lifetime stat keys - used for initialization and serialization
global STATS_LIFETIME_KEYS := [
    "TotalRunTimeSec", "TotalSessions",
    "TotalAltTabs", "TotalQuickSwitches", "TotalTabSteps",
    "TotalCancellations", "TotalCrossWorkspace", "TotalWorkspaceToggles",
    "TotalWindowUpdates", "TotalBlacklistSkips",
    "PeakWindowsInSession", "LongestSessionSec"
]

Stats_Init() {
    global gStats_Lifetime, gStats_Session, STATS_LIFETIME_KEYS, STATS_INI_PATH, cfg

    if (!cfg.StatsTrackingEnabled)
        return

    statsPath := STATS_INI_PATH

    ; --- Crash recovery ---
    bakExists := FileExist(statsPath ".bak")
    iniExists := FileExist(statsPath)

    if (bakExists && !iniExists) {
        ; Crash before any writes completed -- .bak is the last known good
        try FileMove(statsPath ".bak", statsPath)
    } else if (bakExists && iniExists) {
        ; Crash during or after write -- check sentinel
        flushStatus := ""
        try flushStatus := IniRead(statsPath, "Lifetime", "_FlushStatus", "")
        if (flushStatus = "complete") {
            ; .ini write finished fully -- discard .bak
            try FileDelete(statsPath ".bak")
        } else {
            ; .ini is partial -- .bak has previous good state
            try FileDelete(statsPath)
            try FileMove(statsPath ".bak", statsPath)
        }
    }

    ; --- Load lifetime stats from disk ---
    for _, key in STATS_LIFETIME_KEYS {
        val := 0
        if (FileExist(statsPath)) {
            try {
                raw := IniRead(statsPath, "Lifetime", key, "0")
                val := Integer(raw)
            }
        }
        gStats_Lifetime[key] := val
    }

    ; Increment session count
    gStats_Lifetime["TotalSessions"] := gStats_Lifetime.Get("TotalSessions", 0) + 1

    ; Session tracking
    gStats_Session["startTick"] := A_TickCount
    gStats_Session["sessionStartTick"] := A_TickCount  ; Never reset — used for session runtime reporting
    gStats_Session["peakWindows"] := 0

    ; Save baseline for session activity reporting (current - baseline = this session)
    gStats_Session["baselineAltTabs"] := gStats_Lifetime.Get("TotalAltTabs", 0)
    gStats_Session["baselineQuickSwitches"] := gStats_Lifetime.Get("TotalQuickSwitches", 0)
    gStats_Session["baselineTabSteps"] := gStats_Lifetime.Get("TotalTabSteps", 0)
    gStats_Session["baselineCancellations"] := gStats_Lifetime.Get("TotalCancellations", 0)
    gStats_Session["baselineCrossWorkspace"] := gStats_Lifetime.Get("TotalCrossWorkspace", 0)
    gStats_Session["baselineWorkspaceToggles"] := gStats_Lifetime.Get("TotalWorkspaceToggles", 0)
    gStats_Session["baselineWindowUpdates"] := gStats_Lifetime.Get("TotalWindowUpdates", 0)
    gStats_Session["baselineBlacklistSkips"] := gStats_Lifetime.Get("TotalBlacklistSkips", 0)
}

Stats_FlushToDisk() {
    global gStats_Lifetime, gStats_Session, STATS_LIFETIME_KEYS, STATS_INI_PATH, cfg

    if (!cfg.StatsTrackingEnabled)
        return

    statsPath := STATS_INI_PATH

    ; Compute run time: existing lifetime + current session
    sessionSec := (A_TickCount - gStats_Session.Get("startTick", A_TickCount)) / 1000
    gStats_Lifetime["TotalRunTimeSec"] := gStats_Lifetime.Get("TotalRunTimeSec", 0) + Round(sessionSec)
    ; Reset session start so we don't double-count on next flush
    gStats_Session["startTick"] := A_TickCount

    ; Update longest session (use total session time, not just segment since last flush)
    totalSessionSec := (A_TickCount - gStats_Session.Get("sessionStartTick", A_TickCount)) / 1000
    if (totalSessionSec > gStats_Lifetime.Get("LongestSessionSec", 0))
        gStats_Lifetime["LongestSessionSec"] := Round(totalSessionSec)

    ; Crash protection: backup existing file
    if (FileExist(statsPath))
        try FileCopy(statsPath, statsPath ".bak", true)

    ; Remove sentinel from previous flush (will be re-written as last key)
    try IniDelete(statsPath, "Lifetime", "_FlushStatus")

    ; Write all stats
    for _, key in STATS_LIFETIME_KEYS {
        try IniWrite(gStats_Lifetime.Get(key, 0), statsPath, "Lifetime", key)
    }

    ; Sentinel: MUST be last write
    try IniWrite("complete", statsPath, "Lifetime", "_FlushStatus")

    ; Success -- remove backup
    try FileDelete(statsPath ".bak")
}

; Auto-init only if running standalone or if mode is "store"
; When included from alt_tabby.ahk with a different mode, skip init.
if (!IsSet(g_AltTabbyMode) || g_AltTabbyMode = "store") {  ; lint-ignore: isset-with-default
    Store_Init()
    OnExit(Store_OnExit)
    Persistent()
}

Store_OnExit(reason, code) {
    global gStore_Server
    ; Stop all timers and hooks before exit to prevent errors

    ; Stop core timers (periodic + one-shot stagger helpers)
    try {
        SetTimer(Store_FullScan, 0)
    }
    try {
        SetTimer(_Store_DeferredScanAndPush, 0)
    }
    try {
        SetTimer(Store_ZPumpTick, 0)
    }
    try {
        SetTimer(_Store_StartZPump, 0)
    }
    try {
        SetTimer(Store_HeartbeatTick, 0)
    }
    try {
        SetTimer(_Store_StartHeartbeat, 0)
    }
    try {
        SetTimer(Store_ValidateExistenceTick, 0)
    }
    try {
        SetTimer(_Store_StartValidateExistence, 0)
    }

    ; Stop WinEventHook (frees callback too)
    try {
        WinEventHook_Stop()
    }

    ; Stop MRU fallback timer
    try {
        SetTimer(MRU_Lite_Tick, 0)
    }

    ; Stop pumps
    try {
        IconPump_Stop()
    }
    try {
        ProcPump_Stop()
    }

    ; Stop Komorebi producers
    try {
        KomorebiSub_Stop()
    }
    try {
        KomorebiLite_Stop()
    }

    ; Clean up icons before exit (prevents HICON resource leaks)
    try {
        WindowStore_CleanupAllIcons()
    }
    try {
        WindowStore_CleanupExeIconCache()
    }
    try {
        IconPump_CleanupUwpCache()
    }

    ; Flush stats to disk before stopping IPC (final persist)
    try Stats_FlushToDisk()

    ; Stop IPC server
    try {
        if (IsObject(gStore_Server)) {
            IPC_PipeServer_Stop(gStore_Server)
        }
    }
    return 0  ; Allow exit
}

Store_OnError(err, *) {
    msg := "store_error msg=" err.Message " file=" err.File " line=" err.Line " what=" err.What
    LogAppend(_Store_LogPath(), msg)
    ExitApp(1)
    return true
}

Store_LogError(msg) {
    LogAppend(_Store_LogPath(), "store_error " msg)
}

; Informational logging - controlled by DiagStoreLog config flag
Store_LogInfo(msg) {
    global cfg
    if (!cfg.DiagStoreLog)
        return
    LogAppend(_Store_LogPath(), "store_info " msg)
}

; Resolve store log path: test override or centralized constant
_Store_LogPath() {
    global gStore_ErrorLog, LOG_PATH_STORE
    return gStore_ErrorLog ? gStore_ErrorLog : LOG_PATH_STORE
}

_Store_HasIpcSymbols() {
    global IPC_MSG_HELLO
    try {
        tmp := IPC_MSG_HELLO
        return true
    } catch {
        return false
    }
}
