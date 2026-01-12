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
global gViewer_RecByHwnd := Map()
global gViewer_LastMsgTick := 0
global gViewer_LogPath := ""
global gViewer_Status := 0
global gViewer_Headless := false

for _, arg in A_Args {
    if (SubStr(arg, 1, 6) = "--log=")
        gViewer_LogPath := SubStr(arg, 7)
    else if (arg = "--nogui")
        gViewer_Headless := true
}

Viewer_Init() {
    global gViewer_Client, StorePipeName
    global gViewer_LogPath, ViewerAutoStartStore
    if (IsSet(DebugViewerLog) && DebugViewerLog && !gViewer_LogPath)
        gViewer_LogPath := A_Temp "\tabby_viewer.log"
    try OnError(Viewer_OnError)
    if (!gViewer_Headless)
        _Viewer_CreateGui()
    gViewer_Client := IPC_PipeClient_Connect(StorePipeName, Viewer_OnMessage)
    if (!gViewer_Client.hPipe && IsSet(ViewerAutoStartStore) && ViewerAutoStartStore)
        _Viewer_StartStore()
    _Viewer_SendHello()
    _Viewer_RequestProjection()
    SetTimer(_Viewer_Heartbeat, 1000)
}

Viewer_OnMessage(line, hPipe := 0) {
    global gViewer_LastMsgTick
    gViewer_LastMsgTick := A_TickCount
    _Viewer_Log("msg " line)
    obj := ""
    try obj := JXON_Load(line)
    catch {
        return
    }
    if (!IsObject(obj) || !obj.Has("type"))
        return
    type := obj["type"]
    if (type = IPC_MSG_SNAPSHOT || type = IPC_MSG_PROJECTION || type = IPC_MSG_DELTA) {
        if (obj.Has("payload") && obj["payload"].Has("items")) {
            items := obj["payload"]["items"]
            _Viewer_Log("items=" items.Length)
            if (!gViewer_Headless)
                _Viewer_UpdateList(items)
        } else if (obj.Has("payload") && obj["payload"].Has("upserts")) {
            if (!gViewer_Headless)
                _Viewer_ApplyDelta(obj["payload"])
        }
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
    global gViewer_Status
    gViewer_Gui := Gui("+Resize +AlwaysOnTop", "WindowStore Viewer")
    btn := gViewer_Gui.AddButton("x10 y10 w160 h28", "Toggle Z/MRU")
    btn.OnEvent("Click", _Viewer_ToggleSort)
    btn2 := gViewer_Gui.AddButton("x180 y10 w200 h28", "Toggle Current WS")
    btn2.OnEvent("Click", _Viewer_ToggleCurrentWS)
    btn3 := gViewer_Gui.AddButton("x390 y10 w120 h28", "Refresh")
    btn3.OnEvent("Click", (*) => _Viewer_RequestProjection())
    gViewer_Status := gViewer_Gui.AddText("x520 y14 w380 h20", "Disconnected")
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
    gViewer_RecByHwnd := Map()
    for _, rec in items {
        hwnd := _Viewer_Get(rec, "hwnd", 0)
        row := gViewer_LV.Add("", _Viewer_Get(rec, "z", ""), "0x" Format("{:X}", hwnd), _Viewer_Get(rec, "pid", ""), _Viewer_Get(rec, "title", ""), _Viewer_Get(rec, "class", ""), _Viewer_Get(rec, "state", ""), _Viewer_Get(rec, "workspaceName", ""), _Viewer_Get(rec, "processName", ""), _Viewer_Get(rec, "isFocused", 0) ? "Y" : "")
        gViewer_RowByHwnd[hwnd] := row
        gViewer_RecByHwnd[hwnd] := rec
    }
}

_Viewer_ApplyDelta(payload) {
    global gViewer_LV, gViewer_RowByHwnd
    global gViewer_RecByHwnd, gViewer_Sort
    if (payload.Has("removes") && payload["removes"].Length) {
        _Viewer_RequestProjection()
        return
    }
    if !(payload.Has("upserts"))
        return
    needsRefresh := false
    for _, rec in payload["upserts"] {
        if (!IsObject(rec))
            continue
        hwnd := _Viewer_Get(rec, "hwnd", 0)
        if (!hwnd)
            continue
        if (gViewer_RecByHwnd.Has(hwnd)) {
            old := gViewer_RecByHwnd[hwnd]
            if (gViewer_Sort = "Z" && _Viewer_Get(rec, "z", 0) != _Viewer_Get(old, "z", 0))
                needsRefresh := true
            else if (gViewer_Sort = "MRU" && _Viewer_Get(rec, "lastActivatedTick", 0) != _Viewer_Get(old, "lastActivatedTick", 0))
                needsRefresh := true
        }
        if (gViewer_RowByHwnd.Has(hwnd)) {
            row := gViewer_RowByHwnd[hwnd]
            gViewer_LV.Modify(row, "", _Viewer_Get(rec, "z", ""), "0x" Format("{:X}", hwnd), _Viewer_Get(rec, "pid", ""), _Viewer_Get(rec, "title", ""), _Viewer_Get(rec, "class", ""), _Viewer_Get(rec, "state", ""), _Viewer_Get(rec, "workspaceName", ""), _Viewer_Get(rec, "processName", ""), _Viewer_Get(rec, "isFocused", 0) ? "Y" : "")
        } else {
            row := gViewer_LV.Add("", _Viewer_Get(rec, "z", ""), "0x" Format("{:X}", hwnd), _Viewer_Get(rec, "pid", ""), _Viewer_Get(rec, "title", ""), _Viewer_Get(rec, "class", ""), _Viewer_Get(rec, "state", ""), _Viewer_Get(rec, "workspaceName", ""), _Viewer_Get(rec, "processName", ""), _Viewer_Get(rec, "isFocused", 0) ? "Y" : "")
            gViewer_RowByHwnd[hwnd] := row
        }
        gViewer_RecByHwnd[hwnd] := rec
    }
    if (needsRefresh)
        _Viewer_RequestProjection()
}

_Viewer_Heartbeat() {
    global gViewer_Client, gViewer_LastMsgTick, StorePipeName
    global gViewer_Status
    if (!IsObject(gViewer_Client) || !gViewer_Client.hPipe) {
        gViewer_Client := IPC_PipeClient_Connect(StorePipeName, Viewer_OnMessage)
        if (gViewer_Client.hPipe) {
            _Viewer_SendHello()
            _Viewer_RequestProjection()
        }
        if (IsObject(gViewer_Status))
            gViewer_Status.Text := "Disconnected"
        return
    }
    if (gViewer_LastMsgTick && (A_TickCount - gViewer_LastMsgTick) > 3000) {
        _Viewer_RequestProjection()
    }
    if (IsObject(gViewer_Status))
        gViewer_Status.Text := "Connected (last msg " (A_TickCount - gViewer_LastMsgTick) " ms)"
}

_Viewer_Log(msg) {
    global gViewer_LogPath
    if (!gViewer_LogPath)
        return
    try FileAppend(msg "`n", gViewer_LogPath, "UTF-8")
}

_Viewer_Get(rec, key, defaultVal := "") {
    if (rec is Map) {
        return rec.Has(key) ? rec[key] : defaultVal
    }
    try {
        return rec.%key%
    } catch {
        return defaultVal
    }
}

_Viewer_StartStore() {
    global AhkV2Path
    storePath := A_ScriptDir "\..\store\store_server.ahk"
    runner := (IsSet(AhkV2Path) && FileExist(AhkV2Path)) ? AhkV2Path : A_AhkPath
    Run('"' runner '" "' storePath '"', , "Hide")
}

Viewer_OnError(err, *) {
    _Viewer_Log("error " err.Message)
    ExitApp(1)
    return true
}

Viewer_Init()
