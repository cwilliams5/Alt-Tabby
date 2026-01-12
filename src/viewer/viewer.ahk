#Requires AutoHotkey v2.0
#SingleInstance Force

#Include ..\shared\config.ahk
#Include ..\shared\json.ahk
#Include ..\shared\ipc_pipe.ahk

; Viewer (debug) - receives snapshots/deltas from store.

global gViewer_Client := 0
global gViewer_Sort := "Z"
global gViewer_Gui := 0
global gViewer_LV := 0
global gViewer_RowByHwnd := Map()
global gViewer_CurrentOnly := false

Viewer_Init() {
    global gViewer_Client, StorePipeName
    _Viewer_CreateGui()
    gViewer_Client := IPC_PipeClient_Connect(StorePipeName, Viewer_OnMessage)
    _Viewer_SendHello()
    _Viewer_RequestProjection()
}

Viewer_OnMessage(line, hPipe := 0) {
    obj := ""
    try obj := JXON_Load(line)
    catch {
        return
    }
    if (!IsObject(obj) || !obj.Has("type"))
        return
    type := obj["type"]
    if (type = IPC_MSG_SNAPSHOT || type = IPC_MSG_PROJECTION || type = IPC_MSG_DELTA) {
        if (obj.Has("payload") && obj["payload"].Has("items"))
            _Viewer_UpdateList(obj["payload"]["items"])
        else if (obj.Has("payload") && obj["payload"].Has("upserts"))
            _Viewer_ApplyDelta(obj["payload"])
    }
}

_Viewer_SendHello() {
    global gViewer_Client
    msg := { type: IPC_MSG_HELLO, clientId: "viewer", wants: { deltas: true }, projectionOpts: _Viewer_ProjectionOpts() }
    IPC_PipeClient_Send(gViewer_Client, JXON_Dump(msg))
}

_Viewer_RequestProjection() {
    global gViewer_Client
    msg := { type: IPC_MSG_PROJECTION_REQUEST, projectionOpts: _Viewer_ProjectionOpts() }
    IPC_PipeClient_Send(gViewer_Client, JXON_Dump(msg))
}

_Viewer_ProjectionOpts() {
    global gViewer_Sort
    return {
        sort: gViewer_Sort,
        columns: "items",
        currentWorkspaceOnly: gViewer_CurrentOnly,
        includeMinimized: true,
        includeCloaked: true,
        blacklistMode: "exclude"
    }
}

_Viewer_CreateGui() {
    global gViewer_Gui, gViewer_LV
    gViewer_Gui := Gui("+Resize +AlwaysOnTop", "WindowStore Viewer")
    btn := gViewer_Gui.AddButton("x10 y10 w160 h28", "Toggle Z/MRU")
    btn.OnEvent("Click", _Viewer_ToggleSort)
    btn2 := gViewer_Gui.AddButton("x180 y10 w200 h28", "Toggle Current WS")
    btn2.OnEvent("Click", _Viewer_ToggleCurrentWS)
    gViewer_LV := gViewer_Gui.AddListView("x10 y48 w900 h500", ["Z", "HWND", "PID", "Title", "Class", "State", "Workspace", "Process", "Focused"])
    gViewer_Gui.Show()
}

_Viewer_ToggleSort(*) {
    global gViewer_Sort
    gViewer_Sort := (gViewer_Sort = "Z") ? "MRU" : "Z"
    _Viewer_RequestProjection()
}

_Viewer_ToggleCurrentWS(*) {
    global gViewer_CurrentOnly
    gViewer_CurrentOnly := !gViewer_CurrentOnly
    _Viewer_RequestProjection()
}

_Viewer_UpdateList(items) {
    global gViewer_LV
    gViewer_LV.Delete()
    gViewer_RowByHwnd := Map()
    for _, rec in items {
        row := gViewer_LV.Add("", rec.Has("z") ? rec.z : "", "0x" Format("{:X}", rec.hwnd), rec.pid, rec.title, rec.class, rec.state, rec.workspaceName, rec.processName, rec.isFocused ? "Y" : "")
        gViewer_RowByHwnd[rec.hwnd] := row
    }
}

_Viewer_ApplyDelta(payload) {
    global gViewer_LV, gViewer_RowByHwnd
    if (payload.Has("removes") && payload["removes"].Length) {
        _Viewer_RequestProjection()
        return
    }
    if !(payload.Has("upserts"))
        return
    for _, rec in payload["upserts"] {
        if (!IsObject(rec) || !rec.Has("hwnd"))
            continue
        if (gViewer_RowByHwnd.Has(rec.hwnd)) {
            row := gViewer_RowByHwnd[rec.hwnd]
            gViewer_LV.Modify(row, "", rec.Has("z") ? rec.z : "", "0x" Format("{:X}", rec.hwnd), rec.pid, rec.title, rec.class, rec.state, rec.workspaceName, rec.processName, rec.isFocused ? "Y" : "")
        } else {
            row := gViewer_LV.Add("", rec.Has("z") ? rec.z : "", "0x" Format("{:X}", rec.hwnd), rec.pid, rec.title, rec.class, rec.state, rec.workspaceName, rec.processName, rec.isFocused ? "Y" : "")
            gViewer_RowByHwnd[rec.hwnd] := row
        }
    }
}

Viewer_Init()
