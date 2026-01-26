#Requires AutoHotkey v2.0
; Note: #SingleInstance removed - unified exe uses #SingleInstance Off
; When running standalone, multiple instances are OK for development

; Includes: Use *i (ignore if not found) to handle both:
; - Standalone: files found via %A_ScriptDir%\..\ path
; - Included from alt_tabby.ahk: files already loaded, paths don't match but that's OK
#Include *i %A_ScriptDir%\..\shared\config_loader.ahk
#Include *i %A_ScriptDir%\..\shared\json.ahk
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

global gStore_Server := 0
global gStore_ClientOpts := Map()      ; hPipe -> projection opts
global gStore_LastBroadcastRev := -1
global gStore_TestMode := false
global gStore_ErrorLog := ""
global gStore_LastClientLog := 0
global gStore_LastClientRev := Map()   ; hPipe -> last rev sent
global gStore_LastClientProj := Map()  ; hPipe -> last projection items (for delta calc)
global gStore_LastClientMeta := Map()  ; hPipe -> last meta sent (for workspace change detection)

; Producer state tracking: "running", "disabled", "failed"
global gStore_ProducerState := Map()
gStore_ProducerState["wineventHook"] := "disabled"
gStore_ProducerState["mruLite"] := "disabled"
gStore_ProducerState["komorebiSub"] := "disabled"
gStore_ProducerState["komorebiLite"] := "disabled"
gStore_ProducerState["iconPump"] := "disabled"
gStore_ProducerState["procPump"] := "disabled"

; Parse command-line args into local vars first (ConfigLoader_Init will set defaults)
global gStore_CmdLinePipe := ""  ; Command-line override for pipe name
for _, arg in A_Args {
    if (arg = "--test")
        gStore_TestMode := true
    else if (SubStr(arg, 1, 6) = "--log=")
        gStore_ErrorLog := SubStr(arg, 7)
    else if (SubStr(arg, 1, 7) = "--pipe=")
        gStore_CmdLinePipe := SubStr(arg, 8)
}
if (gStore_TestMode) {
    try OnError(Store_OnError)
    IPC_DebugLogPath := A_ScriptDir "\..\..\tests\windowstore_ipc.log"
    try FileDelete(IPC_DebugLogPath)
    Store_LogError("store_dir=" A_ScriptDir)
    Store_LogError("ipc_exists=" (FileExist(A_ScriptDir "\..\shared\ipc_pipe.ahk") ? "1" : "0"))
}

Store_Init() {
    global gStore_Server, gStore_CmdLinePipe, cfg

    ; Load config.ini (overrides defaults from gConfigRegistry)
    ; Let ConfigLoader_Init() determine path based on A_IsCompiled:
    ; - Compiled: uses A_ScriptDir (exe directory)
    ; - Development: tries A_ScriptDir, then A_ScriptDir "\..\"
    ConfigLoader_Init()

    ; Apply command-line overrides AFTER config init (command line wins)
    if (gStore_CmdLinePipe != "")
        cfg.StorePipeName := gStore_CmdLinePipe

    ; Load blacklist before anything else
    if (!Blacklist_Init()) {
        Store_LogInfo("blacklist.txt not found, using empty blacklist")
    } else {
        stats := Blacklist_GetStats()
        Store_LogInfo("blacklist loaded: " stats.titles " titles, " stats.classes " classes, " stats.pairs " pairs")
    }

    WindowStore_Init()
    if (!_Store_HasIpcSymbols()) {
        Store_LogError("ipc_pipe symbols missing")
        ExitApp(1)
    }
    gStore_Server := IPC_PipeServer_Start(cfg.StorePipeName, Store_OnMessage, Store_OnClientDisconnect)

    ; Initialize producers BEFORE first scan so they can enrich data

    ; Komorebi is optional - graceful if not installed
    if (cfg.UseKomorebiSub) {
        ksubOk := KomorebiSub_Init()
        gStore_ProducerState["komorebiSub"] := ksubOk ? "running" : "failed"
    } else if (cfg.UseKomorebiLite) {
        kLiteOk := KomorebiLite_Init()
        gStore_ProducerState["komorebiLite"] := kLiteOk ? "running" : "failed"
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
        Store_LogInfo("WinEventHook failed to start - enabling MRU_Lite fallback and safety polling")
        gStore_ProducerState["wineventHook"] := "failed"
        ; Fallback: enable MRU_Lite for focus tracking
        MRU_Lite_Init()
        gStore_ProducerState["mruLite"] := "running"
        ; Fallback: enable safety polling if hook fails
        SetTimer(Store_FullScan, 2000)
    } else {
        ; Hook working - it handles MRU tracking internally
        Store_LogInfo("WinEventHook active - MRU tracking via hook")
        gStore_ProducerState["wineventHook"] := "running"
        ; Start Z-pump for on-demand scans
        SetTimer(Store_ZPumpTick, cfg.ZPumpIntervalMs)

        ; Optional safety net polling (usually disabled)
        if (cfg.WinEnumSafetyPollMs > 0) {
            SetTimer(Store_FullScan, cfg.WinEnumSafetyPollMs)
        }
    }

    ; Start lightweight existence validation (catches zombies from crashes)
    if (cfg.WinEnumValidateExistenceMs > 0) {
        SetTimer(Store_ValidateExistenceTick, cfg.WinEnumValidateExistenceMs)
    }

    ; NOTE: Producer state is NOT stored in gWS_Meta anymore (removes bloat from deltas/snapshots)
    ; Clients that need producer status should send IPC_MSG_PRODUCER_STATUS_REQUEST

    ; Start heartbeat timer for client connection health
    SetTimer(Store_HeartbeatTick, cfg.StoreHeartbeatIntervalMs)
}

; Broadcast heartbeat to all clients with current rev for drift detection
; Also performs periodic maintenance: cleanup orphaned entries, prune caches
Store_HeartbeatTick() {
    global gStore_Server, IPC_MSG_HEARTBEAT

    ; Safety net: clean up any orphaned client Map entries
    ; Primary cleanup happens in Store_OnClientDisconnect (via IPC callback)
    if (IsObject(gStore_Server)) {
        Critical "On"
        _Store_CleanupDisconnectedClients()
        Critical "Off"
    }

    ; Prune stale workspace cache entries (Issue #3 - memory leak prevention)
    try KomorebiSub_PruneStaleCache()

    ; Prune dead PIDs from process name cache (prevents unbounded growth)
    try WindowStore_PruneProcNameCache()

    if (!IsObject(gStore_Server) || !gStore_Server.clients.Count)
        return

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

    rev := WindowStore_GetRev()
    msg := JXON_Dump({ type: IPC_MSG_HEARTBEAT, rev: rev })
    IPC_PipeServer_Broadcast(gStore_Server, msg)
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
    global gStore_LastBroadcastRev, gStore_Server, gStore_TestMode, gStore_LastClientLog
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
    rev := WindowStore_GetRev()
    if (rev != gStore_LastBroadcastRev) {
        gStore_LastBroadcastRev := rev
        Store_PushToClients()
    }
}

; Push tailored projections to each client based on their registered opts
; Uses Critical section to atomically snapshot client handles, preventing race
; conditions where clients disconnect during iteration
Store_PushToClients() {
    global gStore_Server, gStore_ClientOpts, gStore_LastClientRev, gStore_LastClientProj, gStore_LastClientMeta, gStore_TestMode
    global IPC_MSG_SNAPSHOT, IPC_MSG_DELTA

    if (!IsObject(gStore_Server) || !gStore_Server.clients.Count)
        return

    ; Atomically clean up disconnected clients and snapshot current handles + opts
    ; This prevents race conditions if clients disconnect during iteration
    ; RACE FIX: Also snapshot gStore_ClientOpts - it can be modified by Store_OnMessage
    Critical "On"
    _Store_CleanupDisconnectedClients()
    clientHandles := []
    clientOptsSnapshot := Map()
    for hPipe, _ in gStore_Server.clients {
        clientHandles.Push(hPipe)
        if (gStore_ClientOpts.Has(hPipe))
            clientOptsSnapshot[hPipe] := gStore_ClientOpts[hPipe]
    }
    Critical "Off"

    sent := 0
    for _, hPipe in clientHandles {
        ; Get this client's projection opts (or defaults) from snapshot
        opts := clientOptsSnapshot.Has(hPipe) ? clientOptsSnapshot[hPipe] : IPC_DefaultProjectionOpts()

        ; Generate projection tailored to this client
        proj := WindowStore_GetProjection(opts)

        ; Get client's previous projection for delta calculation
        prevItems := gStore_LastClientProj.Has(hPipe) ? gStore_LastClientProj[hPipe] : []
        lastRev := gStore_LastClientRev.Has(hPipe) ? gStore_LastClientRev[hPipe] : -1
        prevMeta := gStore_LastClientMeta.Has(hPipe) ? gStore_LastClientMeta[hPipe] : ""

        ; Skip if nothing changed for this client
        if (lastRev = proj.rev)
            continue

        ; Check if meta changed (workspace name)
        metaChanged := Store_MetaChanged(prevMeta, proj.meta)

        ; Send delta if client has previous state, otherwise full snapshot
        if (prevItems.Length > 0) {
            msg := Store_BuildClientDelta(prevItems, proj.items, proj.meta, proj.rev, lastRev)
            ; Skip sending empty deltas ONLY if meta also didn't change
            ; Always send if meta changed (workspace switch) even with no window changes
            if (msg.payload.upserts.Length = 0 && msg.payload.removes.Length = 0 && !metaChanged)
                continue
        } else {
            msg := {
                type: IPC_MSG_SNAPSHOT,
                rev: proj.rev,
                payload: { meta: proj.meta, items: proj.items }
            }
        }
        IPC_PipeServer_Send(gStore_Server, hPipe, JXON_Dump(msg))

        ; RACE FIX: Wrap client tracking updates in Critical
        ; Store_OnMessage also modifies these maps when client sends HELLO or SET_PROJECTION_OPTS
        Critical "On"
        gStore_LastClientRev[hPipe] := proj.rev
        gStore_LastClientProj[hPipe] := proj.items
        gStore_LastClientMeta[hPipe] := proj.meta
        Critical "Off"
        sent++
    }

    if (gStore_TestMode && sent > 0) {
        Store_LogError("pushed to " sent " clients")
    }
}

; Check if meta changed (specifically currentWSName for workspace tracking)
Store_MetaChanged(prevMeta, nextMeta) {
    if (prevMeta = "")
        return true  ; No previous meta, consider it changed

    ; Compare workspace name - the critical field for workspace tracking
    prevWSName := ""
    nextWSName := ""

    if (IsObject(prevMeta)) {
        if (prevMeta is Map)
            prevWSName := prevMeta.Has("currentWSName") ? prevMeta["currentWSName"] : ""
        else
            try prevWSName := prevMeta.currentWSName
    }

    if (IsObject(nextMeta)) {
        if (nextMeta is Map)
            nextWSName := nextMeta.Has("currentWSName") ? nextMeta["currentWSName"] : ""
        else
            try nextWSName := nextMeta.currentWSName
    }

    return (prevWSName != nextWSName)
}

; Build delta message for a specific client (uses WindowStore_BuildDelta for core logic)
Store_BuildClientDelta(prevItems, nextItems, meta, rev, baseRev) {
    global IPC_MSG_DELTA
    delta := WindowStore_BuildDelta(prevItems, nextItems)
    return {
        type: IPC_MSG_DELTA,
        rev: rev,
        baseRev: baseRev,
        payload: { meta: meta, upserts: delta.upserts, removes: delta.removes }
    }
}

Store_OnMessage(line, hPipe := 0) {
    global gStore_ClientOpts, gStore_LastClientRev, gStore_LastClientProj
    global gStore_Server, gStore_LastClientMeta
    global IPC_MSG_HELLO, IPC_MSG_HELLO_ACK, IPC_MSG_SNAPSHOT, IPC_MSG_PROJECTION
    global IPC_MSG_SET_PROJECTION_OPTS, IPC_MSG_SNAPSHOT_REQUEST, IPC_MSG_PROJECTION_REQUEST
    global IPC_MSG_RELOAD_BLACKLIST, IPC_MSG_PRODUCER_STATUS_REQUEST, IPC_MSG_PRODUCER_STATUS
    obj := ""
    try obj := JXON_Load(line)
    catch as err {
        ; Log malformed JSON when diagnostics enabled (helps debug IPC issues)
        preview := (StrLen(line) > 80) ? SubStr(line, 1, 80) "..." : line
        Store_LogInfo("JSON parse error: " err.Message " | content: " preview)
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
        opts := obj.Has("projectionOpts") ? obj["projectionOpts"] : IPC_DefaultProjectionOpts()
        gStore_ClientOpts[hPipe] := opts
        gStore_LastClientRev[hPipe] := -1  ; Will get updated when we send initial projection
        gStore_LastClientProj[hPipe] := [] ; No previous projection yet

        ; Send hello ack (no rev - it's just an ack, snapshot follows with rev)
        ack := {
            type: IPC_MSG_HELLO_ACK,
            payload: { meta: WindowStore_GetCurrentWorkspace(), capabilities: { deltas: true } }
        }
        IPC_PipeServer_Send(gStore_Server, hPipe, JXON_Dump(ack))

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
        IPC_PipeServer_Send(gStore_Server, hPipe, JXON_Dump(msg))
        gStore_LastClientRev[hPipe] := proj.rev
        gStore_LastClientProj[hPipe] := proj.HasOwnProp("items") ? proj.items : []
        Critical "Off"
        return
    }
    if (type = IPC_MSG_SET_PROJECTION_OPTS) {
        if (obj.Has("projectionOpts")) {
            ; RACE FIX: Wrap client Map modifications in Critical
            Critical "On"
            gStore_ClientOpts[hPipe] := obj["projectionOpts"]
            ; Clear last projection/meta so client gets fresh snapshot with new opts
            gStore_LastClientProj[hPipe] := []
            gStore_LastClientMeta[hPipe] := ""
            Critical "Off"
        }
        return
    }
    if (type = IPC_MSG_SNAPSHOT_REQUEST || type = IPC_MSG_PROJECTION_REQUEST) {
        ; Snapshot requests trigger a full scan for accuracy
        if (type = IPC_MSG_SNAPSHOT_REQUEST) {
            Store_FullScan()
            WindowStore_ClearZQueue()
        }
        opts := IPC_DefaultProjectionOpts()
        if (gStore_ClientOpts.Has(hPipe))
            opts := gStore_ClientOpts[hPipe]
        if (obj.Has("projectionOpts"))
            opts := obj["projectionOpts"]
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
        IPC_PipeServer_Send(gStore_Server, hPipe, JXON_Dump(resp))
        gStore_LastClientRev[hPipe] := proj.rev
        return
    }
    if (type = IPC_MSG_RELOAD_BLACKLIST) {
        ; Reload blacklist from file
        Blacklist_Reload()
        stats := Blacklist_GetStats()
        Store_LogInfo("blacklist reloaded: " stats.titles " titles, " stats.classes " classes, " stats.pairs " pairs")

        ; Purge windows that now match the blacklist
        purgeResult := WindowStore_PurgeBlacklisted()
        Store_LogInfo("blacklist purge removed " purgeResult.removed " windows")

        ; Clear all client projections/meta to force fresh delta calculation
        Critical "On"
        for clientPipe, _ in gStore_LastClientProj {
            gStore_LastClientProj[clientPipe] := []
            gStore_LastClientMeta[clientPipe] := ""
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
        IPC_PipeServer_Send(gStore_Server, hPipe, JXON_Dump(resp))
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
    global gStore_ClientOpts, gStore_LastClientRev, gStore_LastClientProj, gStore_LastClientMeta
    Critical "On"
    gStore_ClientOpts.Delete(hPipe)
    gStore_LastClientRev.Delete(hPipe)
    gStore_LastClientProj.Delete(hPipe)
    gStore_LastClientMeta.Delete(hPipe)
    Critical "Off"
}

; Clean up tracking maps for disconnected clients (prevents memory leak)
; Check ALL tracking maps, not just gStore_LastClientRev - this handles race
; conditions where disconnect happens between map updates
; NOTE: This is now a safety net - primary cleanup is Store_OnClientDisconnect
_Store_CleanupDisconnectedClients() {
    global gStore_Server, gStore_ClientOpts, gStore_LastClientRev, gStore_LastClientProj, gStore_LastClientMeta

    ; Collect all known hPipes from all tracking maps
    allPipes := Map()
    for hPipe, _ in gStore_LastClientRev
        allPipes[hPipe] := true
    for hPipe, _ in gStore_LastClientProj
        allPipes[hPipe] := true
    for hPipe, _ in gStore_LastClientMeta
        allPipes[hPipe] := true
    for hPipe, _ in gStore_ClientOpts
        allPipes[hPipe] := true

    ; Clean up any that are no longer connected
    for hPipe, _ in allPipes {
        if (!gStore_Server.clients.Has(hPipe)) {
            gStore_LastClientRev.Delete(hPipe)
            gStore_LastClientProj.Delete(hPipe)
            gStore_LastClientMeta.Delete(hPipe)
            gStore_ClientOpts.Delete(hPipe)
        }
    }
}

; Auto-init only if running standalone or if mode is "store"
; When included from alt_tabby.ahk with a different mode, skip init.
if (!IsSet(g_AltTabbyMode) || g_AltTabbyMode = "store") {
    Store_Init()
    OnExit(Store_OnExit)
    Persistent()
}

Store_OnExit(reason, code) {
    global gStore_Server
    ; Stop all timers and hooks before exit to prevent errors

    ; Stop core timers
    try {
        SetTimer(Store_FullScan, 0)
    }
    try {
        SetTimer(Store_ZPumpTick, 0)
    }
    try {
        SetTimer(Store_HeartbeatTick, 0)
    }
    try {
        SetTimer(Store_ValidateExistenceTick, 0)
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

    ; Stop IPC server
    try {
        if (IsObject(gStore_Server)) {
            IPC_PipeServer_Stop(gStore_Server)
        }
    }
    return 0  ; Allow exit
}

Store_OnError(err, *) {
    global gStore_ErrorLog, LOG_PATH_STORE
    path := gStore_ErrorLog ? gStore_ErrorLog : LOG_PATH_STORE
    msg := "store_error " FormatTime(, "yyyy-MM-dd HH:mm:ss") "`n"
        . "msg=" err.Message "`n"
        . "file=" err.File "`n"
        . "line=" err.Line "`n"
        . "what=" err.What "`n"
    try FileAppend(msg, path, "UTF-8")
    ExitApp(1)
    return true
}

Store_LogError(msg) {
    global gStore_ErrorLog, LOG_PATH_STORE
    path := gStore_ErrorLog ? gStore_ErrorLog : LOG_PATH_STORE
    try FileAppend("store_error " FormatTime(, "yyyy-MM-dd HH:mm:ss") "`n" msg "`n", path, "UTF-8")
}

; Informational logging - controlled by DiagStoreLog config flag
Store_LogInfo(msg) {
    global gStore_ErrorLog, cfg, LOG_PATH_STORE
    if (!cfg.DiagStoreLog)
        return
    path := gStore_ErrorLog ? gStore_ErrorLog : LOG_PATH_STORE
    try FileAppend("store_info " FormatTime(, "yyyy-MM-dd HH:mm:ss") "`n" msg "`n", path, "UTF-8")
}

_Store_HasIpcSymbols() {
    try {
        tmp := IPC_MSG_HELLO
        return true
    } catch {
        return false
    }
}
