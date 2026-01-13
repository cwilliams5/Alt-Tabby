#Requires AutoHotkey v2.0
#SingleInstance Force

#Include %A_ScriptDir%\..\shared\config.ahk
#Include %A_ScriptDir%\..\shared\json.ahk
#Include %A_ScriptDir%\..\shared\ipc_pipe.ahk
#Include %A_ScriptDir%\..\shared\blacklist.ahk
#Include %A_ScriptDir%\windowstore.ahk
#Include %A_ScriptDir%\winenum_lite.ahk
#Include %A_ScriptDir%\mru_lite.ahk
#Include %A_ScriptDir%\komorebi_lite.ahk
#Include %A_ScriptDir%\komorebi_sub.ahk
#Include %A_ScriptDir%\icon_pump.ahk
#Include %A_ScriptDir%\proc_pump.ahk
#Include %A_ScriptDir%\winevent_hook.ahk

global gStore_Server := 0
global gStore_ClientOpts := Map()      ; hPipe -> projection opts
global gStore_LastBroadcastRev := -1
global gStore_TestMode := false
global gStore_ErrorLog := ""
global gStore_LastClientLog := 0
global gStore_LastClientRev := Map()   ; hPipe -> last rev sent
global gStore_LastClientProj := Map()  ; hPipe -> last projection items (for delta calc)

for _, arg in A_Args {
    if (arg = "--test")
        gStore_TestMode := true
    else if (SubStr(arg, 1, 6) = "--log=")
        gStore_ErrorLog := SubStr(arg, 7)
    else if (SubStr(arg, 1, 7) = "--pipe=")
        StorePipeName := SubStr(arg, 8)
}
if (gStore_TestMode) {
    try OnError(Store_OnError)
    IPC_DebugLogPath := A_ScriptDir "\..\..\tests\windowstore_ipc.log"
    try FileDelete(IPC_DebugLogPath)
    Store_LogError("store_dir=" A_ScriptDir)
    Store_LogError("ipc_exists=" (FileExist(A_ScriptDir "\..\shared\ipc_pipe.ahk") ? "1" : "0"))
}

Store_Init() {
    global gStore_Server, StorePipeName

    ; Load blacklist before anything else
    if (!Blacklist_Init()) {
        Store_LogError("blacklist.txt not found, using empty blacklist")
    } else {
        stats := Blacklist_GetStats()
        Store_LogError("blacklist loaded: " stats.titles " titles, " stats.classes " classes, " stats.pairs " pairs")
    }

    WindowStore_Init()
    if (!_Store_HasIpcSymbols()) {
        Store_LogError("ipc_pipe symbols missing")
        ExitApp(1)
    }
    gStore_Server := IPC_PipeServer_Start(StorePipeName, Store_OnMessage)

    ; Initialize producers BEFORE first scan so they can enrich data
    ; MRU is always enabled (essential for alt-tab)
    MRU_Lite_Init()

    ; Komorebi is optional - graceful if not installed
    if (IsSet(UseKomorebiSub) && UseKomorebiSub)
        KomorebiSub_Init()
    else if (IsSet(UseKomorebiLite) && UseKomorebiLite)
        KomorebiLite_Init()

    ; Pumps
    if (IsSet(UseIconPump) && UseIconPump)
        IconPump_Start()
    if (IsSet(UseProcPump) && UseProcPump)
        ProcPump_Start()

    ; Do initial full scan AFTER producers init so data includes komorebi workspace info
    Store_FullScan()

    ; WinEventHook is always enabled (primary source of window changes)
    if (!WinEventHook_Start()) {
        Store_LogError("WinEventHook failed to start - enabling safety polling")
        ; Fallback: enable safety polling if hook fails
        SetTimer(Store_FullScan, 2000)
    } else {
        ; Hook working - start Z-pump for on-demand scans
        SetTimer(Store_ZPumpTick, 200)

        ; Optional safety net polling (usually disabled)
        safetyMs := IsSet(WinEnumSafetyPollMs) ? WinEnumSafetyPollMs : 0
        if (safetyMs > 0) {
            SetTimer(Store_FullScan, safetyMs)
        }
    }

    ; Start heartbeat timer for client connection health
    heartbeatMs := IsSet(StoreHeartbeatIntervalMs) ? StoreHeartbeatIntervalMs : 5000
    SetTimer(Store_HeartbeatTick, heartbeatMs)
}

; Broadcast heartbeat to all clients with current rev for drift detection
Store_HeartbeatTick() {
    global gStore_Server, IPC_MSG_HEARTBEAT

    if (!IsObject(gStore_Server) || !gStore_Server.clients.Count)
        return

    ; Log churn diagnostics (what fields and sources are triggering rev bumps)
    if (IsSet(DiagChurnLog) && DiagChurnLog) {
        churn := WindowStore_GetChurnDiag(true)
        if (churn["sources"].Count > 0 || churn["fields"].Count > 0) {
            srcParts := ""
            for src, count in churn["sources"]
                srcParts .= (srcParts ? ", " : "") . src "=" count
            fldParts := ""
            for fld, count in churn["fields"]
                fldParts .= (fldParts ? ", " : "") . fld "=" count
            Store_LogError("CHURN src=[" srcParts "] fields=[" fldParts "]")
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
Store_PushToClients() {
    global gStore_Server, gStore_ClientOpts, gStore_LastClientRev, gStore_LastClientProj, gStore_TestMode

    if (!IsObject(gStore_Server) || !gStore_Server.clients.Count)
        return

    sent := 0
    for hPipe, _ in gStore_Server.clients {
        ; Get this client's projection opts (or defaults)
        opts := gStore_ClientOpts.Has(hPipe) ? gStore_ClientOpts[hPipe] : IPC_DefaultProjectionOpts()

        ; Generate projection tailored to this client
        proj := WindowStore_GetProjection(opts)

        ; Get client's previous projection for delta calculation
        prevItems := gStore_LastClientProj.Has(hPipe) ? gStore_LastClientProj[hPipe] : []
        lastRev := gStore_LastClientRev.Has(hPipe) ? gStore_LastClientRev[hPipe] : -1

        ; Skip if nothing changed for this client
        if (lastRev = proj.rev)
            continue

        ; Send delta if client has previous state, otherwise full snapshot
        if (prevItems.Length > 0) {
            msg := Store_BuildClientDelta(prevItems, proj.items, proj.meta, proj.rev, lastRev)
            ; Skip sending empty deltas (rev bumped but nothing changed for this client)
            if (msg.payload.upserts.Length = 0 && msg.payload.removes.Length = 0)
                continue
        } else {
            msg := {
                type: IPC_MSG_SNAPSHOT,
                rev: proj.rev,
                payload: { meta: proj.meta, items: proj.items }
            }
        }
        IPC_PipeServer_Send(gStore_Server, hPipe, JXON_Dump(msg))

        ; Update client's tracking state
        gStore_LastClientRev[hPipe] := proj.rev
        gStore_LastClientProj[hPipe] := proj.items
        sent++
    }

    if (gStore_TestMode && sent > 0) {
        Store_LogError("pushed to " sent " clients")
    }
}

; Build delta between previous and current projection for a specific client
Store_BuildClientDelta(prevItems, nextItems, meta, rev, baseRev) {
    prevMap := Map()
    for _, rec in prevItems
        prevMap[rec.hwnd] := rec
    nextMap := Map()
    for _, rec in nextItems
        nextMap[rec.hwnd] := rec

    upserts := []
    removes := []

    ; Find new/changed items
    for hwnd, rec in nextMap {
        if (!prevMap.Has(hwnd)) {
            upserts.Push(rec)
        } else {
            old := prevMap[hwnd]
            ; Compare key fields that matter for display
            if (rec.title != old.title || rec.z != old.z
                || rec.pid != old.pid || rec.isFocused != old.isFocused
                || rec.workspaceName != old.workspaceName || rec.isCloaked != old.isCloaked
                || rec.isMinimized != old.isMinimized || rec.isOnCurrentWorkspace != old.isOnCurrentWorkspace
                || rec.processName != old.processName || rec.iconHicon != old.iconHicon) {
                upserts.Push(rec)
            }
        }
    }

    ; Find removed items
    for hwnd, _ in prevMap {
        if (!nextMap.Has(hwnd))
            removes.Push(hwnd)
    }

    return {
        type: IPC_MSG_DELTA,
        rev: rev,
        baseRev: baseRev,
        payload: { meta: meta, upserts: upserts, removes: removes }
    }
}

Store_OnMessage(line, hPipe := 0) {
    global gStore_ClientOpts, gStore_LastClientRev, gStore_LastClientProj
    obj := ""
    try obj := JXON_Load(line)
    catch {
        return
    }
    if (!IsObject(obj) || !obj.Has("type"))
        return
    type := obj["type"]
    if (type = IPC_MSG_HELLO) {
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
        msg := {
            type: IPC_MSG_SNAPSHOT,
            rev: proj.rev,
            payload: { meta: proj.meta, items: proj.items }
        }
        IPC_PipeServer_Send(gStore_Server, hPipe, JXON_Dump(msg))
        gStore_LastClientRev[hPipe] := proj.rev
        gStore_LastClientProj[hPipe] := proj.items
        return
    }
    if (type = IPC_MSG_SET_PROJECTION_OPTS) {
        if (obj.Has("projectionOpts")) {
            gStore_ClientOpts[hPipe] := obj["projectionOpts"]
            ; Clear last projection so client gets fresh snapshot with new opts
            gStore_LastClientProj[hPipe] := []
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
        resp := {
            type: respType,
            rev: proj.rev,
            payload: { meta: proj.meta, items: proj.HasOwnProp("items") ? proj.items : [] }
        }
        IPC_PipeServer_Send(gStore_Server, hPipe, JXON_Dump(resp))
        gStore_LastClientRev[hPipe] := proj.rev
        return
    }
    if (type = IPC_MSG_RELOAD_BLACKLIST) {
        ; Reload blacklist from file
        Blacklist_Reload()
        stats := Blacklist_GetStats()
        Store_LogError("blacklist reloaded: " stats.titles " titles, " stats.classes " classes, " stats.pairs " pairs")

        ; Purge windows that now match the blacklist
        purgeResult := WindowStore_PurgeBlacklisted()
        Store_LogError("blacklist purge removed " purgeResult.removed " windows")

        ; Clear all client projections to force fresh delta calculation
        for clientPipe, _ in gStore_LastClientProj {
            gStore_LastClientProj[clientPipe] := []
        }

        ; Push updated projections to clients immediately
        Store_PushToClients()
        return
    }
}

Store_Init()

OnExit(Store_OnExit)

Store_OnExit(reason, code) {
    global gStore_Server
    ; Stop all timers and hooks before exit to prevent errors
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
        WinEventHook_Stop()
    }
    try {
        SetTimer(MRU_Lite_Tick, 0)
    }
    try {
        if (IsObject(gStore_Server)) {
            IPC_PipeServer_Stop(gStore_Server)
        }
    }
    return 0  ; Allow exit
}

Store_OnError(err, *) {
    global gStore_ErrorLog
    path := gStore_ErrorLog ? gStore_ErrorLog : (A_Temp "\tabby_store_error.log")
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
    global gStore_ErrorLog
    path := gStore_ErrorLog ? gStore_ErrorLog : (A_Temp "\tabby_store_error.log")
    try FileAppend("store_error " FormatTime(, "yyyy-MM-dd HH:mm:ss") "`n" msg "`n", path, "UTF-8")
}

_Store_HasIpcSymbols() {
    try {
        tmp := IPC_MSG_HELLO
        return true
    } catch {
        return false
    }
}
