#Requires AutoHotkey v2.0
#SingleInstance Force

#Include ..\shared\config.ahk
#Include ..\shared\json.ahk
#Include ..\shared\ipc_pipe.ahk

global gViewer_Client := 0
global gViewer_Sort := "Z"
global gViewer_Gui := 0
global gViewer_LV := 0

Viewer_Init() {
    global gViewer_Client, StorePipeName
    _Viewer_CreateGui()
    gViewer_Client := IPC_PipeClient_Connect(StorePipeName, Func("Viewer_OnMessage"))
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
    if (type = IPC_MSG_SNAPSHOT || type = IPC_MSG_PROJECTION) {
        if (obj.Has("payload") && obj["payload"].Has("items"))
            _Viewer_UpdateList(obj["payload"]["items"])
    }
}

_Viewer_SendHello() {
    global gViewer_Client
    msg := { type: IPC_MSG_HELLO, clientId: "viewer", wants: { deltas: false }, projectionOpts: _Viewer_ProjectionOpts() }
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
        currentWorkspaceOnly: false,
        includeMinimized: true,
        includeCloaked: true,
        blacklistMode: "exclude"
    }
}

_Viewer_CreateGui() {
    global gViewer_Gui, gViewer_LV
    gViewer_Gui := Gui("+Resize", "WindowStore Viewer")
    btn := gViewer_Gui.AddButton("x10 y10 w160 h28", "Toggle Z/MRU")
    btn.OnEvent("Click", _Viewer_ToggleSort)
    gViewer_LV := gViewer_Gui.AddListView("x10 y48 w900 h500", ["Z", "HWND", "PID", "Title", "Class", "State", "Workspace", "Process", "Focused"])
    gViewer_Gui.Show()
}

_Viewer_ToggleSort(*) {
    global gViewer_Sort
    gViewer_Sort := (gViewer_Sort = "Z") ? "MRU" : "Z"
    _Viewer_RequestProjection()
}

_Viewer_UpdateList(items) {
    global gViewer_LV
    gViewer_LV.Delete()
    for _, rec in items {
        gViewer_LV.Add("", rec.Has("z") ? rec.z : "", "0x" Format("{:X}", rec.hwnd), rec.pid, rec.title, rec.class, rec.state, rec.workspaceName, rec.processName, rec.isFocused ? "Y" : "")
    }
}

Viewer_Init()
