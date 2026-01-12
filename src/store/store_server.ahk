#Requires AutoHotkey v2.0
#SingleInstance Force

#Include ..\shared\config.ahk
#Include ..\shared\json.ahk
#Include ..\shared\ipc_pipe.ahk
#Include windowstore.ahk
#Include winenum_lite.ahk

global gStore_Server := 0
global gStore_ClientOpts := Map() ; hPipe -> projection opts
global gStore_LastBroadcastRev := -1
global gStore_TestMode := false
global gStore_ErrorLog := ""

for _, arg in A_Args {
    if (arg = "--test")
        gStore_TestMode := true
    else if (SubStr(arg, 1, 6) = "--log=")
        gStore_ErrorLog := SubStr(arg, 7)
}
if (gStore_TestMode)
    OnError(Func("Store_OnError"))

Store_Init() {
    global gStore_Server, StorePipeName, StoreScanIntervalMs
    WindowStore_Init()
    gStore_Server := IPC_PipeServer_Start(StorePipeName, Func("Store_OnMessage"))
    SetTimer(Store_ScanTick, StoreScanIntervalMs)
}

Store_ScanTick() {
    global gStore_LastBroadcastRev, gStore_Server
    WindowStore_BeginScan()
    recs := WinEnumLite_ScanAll()
    WindowStore_UpsertWindow(recs, "winenum_lite")
    WindowStore_EndScan()
    rev := WindowStore_GetRev()
    if (rev != gStore_LastBroadcastRev) {
        gStore_LastBroadcastRev := rev
        Store_BroadcastSnapshot()
    }
}

Store_BroadcastSnapshot() {
    global gStore_Server
    payload := WindowStore_GetProjection({ sort: "Z", columns: "items" })
    msg := {
        type: IPC_MSG_SNAPSHOT,
        rev: payload.rev,
        payload: { meta: payload.meta, items: payload.items }
    }
    IPC_PipeServer_Broadcast(gStore_Server, JXON_Dump(msg))
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
        return
    }
}

Store_Init()

Store_OnError(err, *) {
    global gStore_ErrorLog
    path := gStore_ErrorLog ? gStore_ErrorLog : (A_Temp "\tabby_store_error.log")
    msg := "store_error " FormatTime(, "yyyy-MM-dd HH:mm:ss") "`n" err.Message "`n"
    try FileAppend(msg, path, "UTF-8")
    ExitApp(1)
    return true
}
