#Requires AutoHotkey v2.0
#SingleInstance Force

#Include %A_ScriptDir%\..\shared\config.ahk
#Include %A_ScriptDir%\..\shared\json.ahk
#Include %A_ScriptDir%\..\shared\ipc_pipe.ahk
#Include %A_ScriptDir%\windowstore.ahk
#Include %A_ScriptDir%\winenum_lite.ahk
#Include %A_ScriptDir%\mru_lite.ahk
#Include %A_ScriptDir%\komorebi_lite.ahk

global gStore_Server := 0
global gStore_ClientOpts := Map() ; hPipe -> projection opts
global gStore_LastBroadcastRev := -1
global gStore_TestMode := false
global gStore_ErrorLog := ""
global gStore_LastClientLog := 0
global gStore_LastClientRev := Map()
global gStore_LastProj := []

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
    SetTimer(Store_ScanTick, StoreScanIntervalMs)
    if (IsSet(UseMruLite) && UseMruLite)
        MRU_Lite_Init()
    if (IsSet(UseKomorebiLite) && UseKomorebiLite)
        KomorebiLite_Init()
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
        Store_BroadcastSnapshot()
    }
}

Store_BroadcastSnapshot() {
    global gStore_Server, gStore_TestMode
    payload := WindowStore_GetProjection({ sort: "Z", columns: "items" })
    msg := {
        type: IPC_MSG_SNAPSHOT,
        rev: payload.rev,
        payload: { meta: payload.meta, items: payload.items }
    }
    sent := IPC_PipeServer_Broadcast(gStore_Server, JXON_Dump(msg))
    if (gStore_TestMode)
    {
        Store_LogError("broadcast_sent=" sent " items=" payload.items.Length)
        if (payload.items.Length = 0 && gWS_Store.Count > 0) {
            for _, rec in gWS_Store {
                Store_LogError("sample_present=" rec.present " state=" rec.state)
                break
            }
        }
    }
    Store_PushDeltas(payload)
    gStore_LastProj := payload.items
}

Store_PushDeltas(payload) {
    global gStore_Server, gStore_LastClientRev
    for hPipe, _ in gStore_Server.clients {
        last := gStore_LastClientRev.Has(hPipe) ? gStore_LastClientRev[hPipe] : -1
        if (last = payload.rev)
            continue
        delta := Store_BuildDelta(payload, last)
        IPC_PipeServer_Send(gStore_Server, hPipe, JXON_Dump(delta))
        gStore_LastClientRev[hPipe] := payload.rev
    }
}

Store_BuildDelta(payload, baseRev) {
    global gStore_LastProj
    prev := gStore_LastProj
    next := payload.items

    prevMap := Map()
    for _, rec in prev
        prevMap[rec.hwnd] := rec
    nextMap := Map()
    for _, rec in next
        nextMap[rec.hwnd] := rec

    upserts := []
    removes := []

    for hwnd, rec in nextMap {
        if (!prevMap.Has(hwnd)) {
            upserts.Push(rec)
        } else {
            ; naive compare of key fields
            old := prevMap[hwnd]
            if (rec.title != old.title || rec.state != old.state || rec.z != old.z || rec.pid != old.pid)
                upserts.Push(rec)
        }
    }
    for hwnd, _ in prevMap {
        if (!nextMap.Has(hwnd))
            removes.Push(hwnd)
    }

    return {
        type: IPC_MSG_DELTA,
        rev: payload.rev,
        baseRev: baseRev,
        payload: { meta: payload.meta, upserts: upserts, removes: removes }
    }
}

Store_OnMessage(line, hPipe := 0) {
    global gStore_ClientOpts
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
        gStore_LastClientRev[hPipe] := WindowStore_GetRev()
        ack := {
            type: IPC_MSG_HELLO_ACK,
            rev: WindowStore_GetRev(),
            payload: { meta: WindowStore_GetCurrentWorkspace(), capabilities: { deltas: false } }
        }
        IPC_PipeServer_Send(gStore_Server, hPipe, JXON_Dump(ack))
        return
    }
    if (type = IPC_MSG_SET_PROJECTION_OPTS) {
        if (obj.Has("projectionOpts"))
            gStore_ClientOpts[hPipe] := obj["projectionOpts"]
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
            payload: { meta: proj.meta, items: proj.Has("items") ? proj.items : [] }
        }
        IPC_PipeServer_Send(gStore_Server, hPipe, JXON_Dump(resp))
        gStore_LastClientRev[hPipe] := proj.rev
        return
    }
}

Store_Init()

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
