#Requires AutoHotkey v2.0
#SingleInstance Force

#Include %A_ScriptDir%\..\shared\config.ahk
#Include %A_ScriptDir%\..\shared\json.ahk
#Include %A_ScriptDir%\..\shared\ipc_pipe.ahk
#Include %A_ScriptDir%\windowstore.ahk
#Include %A_ScriptDir%\winenum_lite.ahk
#Include %A_ScriptDir%\mru_lite.ahk
#Include %A_ScriptDir%\komorebi_lite.ahk
#Include %A_ScriptDir%\komorebi_sub.ahk
#Include %A_ScriptDir%\icon_pump.ahk
#Include %A_ScriptDir%\proc_pump.ahk

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
    global gStore_Server, StorePipeName, StoreScanIntervalMs
    WindowStore_Init()
    if (!_Store_HasIpcSymbols()) {
        Store_LogError("ipc_pipe symbols missing")
        ExitApp(1)
    }
    gStore_Server := IPC_PipeServer_Start(StorePipeName, Store_OnMessage)
    ; Initialize producers BEFORE first scan so they can enrich data
    if (IsSet(UseMruLite) && UseMruLite)
        MRU_Lite_Init()
    if (IsSet(UseKomorebiSub) && UseKomorebiSub)
        KomorebiSub_Init()
    else if (IsSet(UseKomorebiLite) && UseKomorebiLite)
        KomorebiLite_Init()
    if (IsSet(UseIconPump) && UseIconPump)
        IconPump_Start()
    if (IsSet(UseProcPump) && UseProcPump)
        ProcPump_Start()
    ; Do initial scan AFTER producers init so data includes komorebi workspace info
    Store_ScanTick()
    SetTimer(Store_ScanTick, StoreScanIntervalMs)
}

Store_ScanTick() {
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
            if (rec.title != old.title || rec.state != old.state || rec.z != old.z
                || rec.pid != old.pid || rec.isFocused != old.isFocused
                || rec.workspaceName != old.workspaceName || rec.isCloaked != old.isCloaked
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
}

Store_Init()

OnExit(Store_OnExit)

Store_OnExit(reason, code) {
    global gStore_Server
    ; Stop all timers before exit to prevent errors
    try {
        SetTimer(Store_ScanTick, 0)
    }
    try {
        if (IsSet(MRU_Lite_Tick)) {
            SetTimer(MRU_Lite_Tick, 0)
        }
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
