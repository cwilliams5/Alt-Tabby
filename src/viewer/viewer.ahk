#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn VarUnset, Off

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
global gViewer_SortLabel := 0
global gViewer_WSLabel := 0
global gViewer_Headless := false
global gViewer_LastRev := -1
global gViewer_LastItemCount := 0
global gViewer_PushCount := 0
global gViewer_PollCount := 0
global gViewer_LastUpdateType := ""

for _, arg in A_Args {
    if (SubStr(arg, 1, 6) = "--log=") {
        gViewer_LogPath := SubStr(arg, 7)
    } else if (arg = "--nogui") {
        gViewer_Headless := true
    }
}

Viewer_Init() {
    global gViewer_Client, StorePipeName
    global gViewer_LogPath, ViewerAutoStartStore
    if (IsSet(DebugViewerLog) && DebugViewerLog && !gViewer_LogPath) {
        gViewer_LogPath := A_Temp "\tabby_viewer.log"
    }
    try OnError(Viewer_OnError)
    if (!gViewer_Headless) {
        _Viewer_CreateGui()
    }
    _Viewer_Log("Connecting to pipe: " StorePipeName)
    gViewer_Client := IPC_PipeClient_Connect(StorePipeName, Viewer_OnMessage)
    _Viewer_Log("Connection result: hPipe=" gViewer_Client.hPipe)
    if (!gViewer_Client.hPipe && IsSet(ViewerAutoStartStore) && ViewerAutoStartStore) {
        _Viewer_Log("Starting store...")
        _Viewer_StartStore()
    }
    if (gViewer_Client.hPipe) {
        _Viewer_Log("Sending hello...")
        _Viewer_SendHello()
        _Viewer_Log("Sending projection request...")
        _Viewer_RequestProjection()
    } else {
        _Viewer_Log("Not connected, skipping initial messages")
    }
    SetTimer(_Viewer_Heartbeat, 2000)
}

Viewer_OnMessage(line, hPipe := 0) {
    global gViewer_LastMsgTick, gViewer_LastRev
    global gViewer_PushCount, gViewer_PollCount, gViewer_LastUpdateType, gViewer_Headless
    global IPC_MSG_SNAPSHOT, IPC_MSG_PROJECTION, IPC_MSG_DELTA, IPC_MSG_HELLO_ACK
    gViewer_LastMsgTick := A_TickCount
    _Viewer_Log("=== MESSAGE RECEIVED ===")
    _Viewer_Log("raw: " SubStr(line, 1, 300))
    obj := ""
    try {
        obj := JXON_Load(line)
    } catch as e {
        _Viewer_Log("JSON parse error: " e.Message)
        return
    }
    if (!IsObject(obj)) {
        _Viewer_Log("Not an object")
        return
    }
    if (!obj.Has("type")) {
        _Viewer_Log("Missing type field")
        return
    }
    type := obj["type"]
    _Viewer_Log("type=" type " (expecting snapshot=" IPC_MSG_SNAPSHOT " or projection=" IPC_MSG_PROJECTION ")")

    ; Check revision to avoid duplicate processing
    if (obj.Has("rev")) {
        rev := obj["rev"]
        _Viewer_Log("rev=" rev " lastRev=" gViewer_LastRev)
        if (rev = gViewer_LastRev && type != IPC_MSG_HELLO_ACK) {
            _Viewer_Log("skip duplicate rev=" rev)
            return
        }
        gViewer_LastRev := rev
    }

    if (type = IPC_MSG_SNAPSHOT) {
        ; Snapshot = push from store
        gViewer_PushCount++
        gViewer_LastUpdateType := "push"
        if (obj.Has("payload") && obj["payload"].Has("items")) {
            items := obj["payload"]["items"]
            _Viewer_Log("push items=" items.Length)
            if (!gViewer_Headless) {
                _Viewer_UpdateList(items)
            }
        }
    } else if (type = IPC_MSG_PROJECTION) {
        ; Projection = response to our request (poll)
        gViewer_PollCount++
        gViewer_LastUpdateType := "poll"
        if (obj.Has("payload") && obj["payload"].Has("items")) {
            items := obj["payload"]["items"]
            _Viewer_Log("poll items=" items.Length)
            if (!gViewer_Headless) {
                _Viewer_UpdateList(items)
            }
        }
    } else if (type = IPC_MSG_DELTA) {
        ; Delta = push from store
        gViewer_PushCount++
        gViewer_LastUpdateType := "push"
        if (obj.Has("payload") && obj["payload"].Has("upserts")) {
            if (!gViewer_Headless) {
                _Viewer_ApplyDelta(obj["payload"])
            }
        }
    }
}

_Viewer_SendHello() {
    global gViewer_Client, IPC_MSG_HELLO
    msg := { type: IPC_MSG_HELLO, clientId: "viewer", wants: { deltas: true }, projectionOpts: _Viewer_ProjectionOpts() }
    IPC_PipeClient_Send(gViewer_Client, JXON_Dump(msg))
}

_Viewer_RequestProjection() {
    global gViewer_Client, gViewer_LastRev, IPC_MSG_PROJECTION_REQUEST
    gViewer_LastRev := -1  ; Reset to allow next response
    msg := { type: IPC_MSG_PROJECTION_REQUEST, projectionOpts: _Viewer_ProjectionOpts() }
    IPC_PipeClient_Send(gViewer_Client, JXON_Dump(msg))
}

_Viewer_ProjectionOpts() {
    global gViewer_Sort, gViewer_CurrentOnly
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
    global gViewer_Gui, gViewer_LV, gViewer_Status
    global gViewer_SortLabel, gViewer_WSLabel

    gViewer_Gui := Gui("+Resize +AlwaysOnTop", "WindowStore Viewer")

    ; Sort toggle
    btn := gViewer_Gui.AddButton("x10 y10 w120 h28", "Toggle Sort")
    btn.OnEvent("Click", _Viewer_ToggleSort)
    gViewer_SortLabel := gViewer_Gui.AddText("x135 y14 w60 h20", "[Z]")

    ; Workspace toggle
    btn2 := gViewer_Gui.AddButton("x200 y10 w120 h28", "Toggle WS")
    btn2.OnEvent("Click", _Viewer_ToggleCurrentWS)
    gViewer_WSLabel := gViewer_Gui.AddText("x325 y14 w80 h20", "[All]")

    ; Refresh button
    btn3 := gViewer_Gui.AddButton("x420 y10 w80 h28", "Refresh")
    btn3.OnEvent("Click", (*) => _Viewer_RequestProjection())

    ; Status
    gViewer_Status := gViewer_Gui.AddText("x510 y14 w400 h20", "Disconnected")

    ; ListView with all columns
    ; Columns: Z, MRU, HWND, PID, Title, Class, State, WS, Process, Focus, Cloak, Min, Icon
    gViewer_LV := gViewer_Gui.AddListView("x10 y48 w1200 h600 +LV0x10000",
        ["Z", "MRU", "HWND", "PID", "Title", "Class", "State", "WS", "Process", "Foc", "Clk", "Min", "Icon"])

    ; Set column widths
    gViewer_LV.ModifyCol(1, 35)   ; Z
    gViewer_LV.ModifyCol(2, 90)   ; MRU (tick)
    gViewer_LV.ModifyCol(3, 75)   ; HWND
    gViewer_LV.ModifyCol(4, 45)   ; PID
    gViewer_LV.ModifyCol(5, 280)  ; Title
    gViewer_LV.ModifyCol(6, 130)  ; Class
    gViewer_LV.ModifyCol(7, 100)  ; State
    gViewer_LV.ModifyCol(8, 60)   ; Workspace
    gViewer_LV.ModifyCol(9, 90)   ; Process
    gViewer_LV.ModifyCol(10, 30)  ; Focused
    gViewer_LV.ModifyCol(11, 30)  ; Cloaked
    gViewer_LV.ModifyCol(12, 30)  ; Minimized
    gViewer_LV.ModifyCol(13, 70)  ; Icon (HICON value)

    gViewer_Gui.OnEvent("Close", (*) => ExitApp())
    gViewer_Gui.OnEvent("Size", _Viewer_OnResize)
    gViewer_Gui.Show("w1120 h660")
}

_Viewer_OnResize(gui, minMax, w, h) {
    global gViewer_LV
    if (minMax = -1) {
        return  ; Minimized
    }
    gViewer_LV.Move(, , w - 20, h - 58)
}

_Viewer_ToggleSort(*) {
    global gViewer_Sort, gViewer_SortLabel, gViewer_LastItemCount
    gViewer_Sort := (gViewer_Sort = "Z") ? "MRU" : "Z"
    gViewer_SortLabel.Text := "[" gViewer_Sort "]"
    ; Force full refresh by resetting cache
    gViewer_LastItemCount := 0
    _Viewer_RequestProjection()
}

_Viewer_ToggleCurrentWS(*) {
    global gViewer_CurrentOnly, gViewer_WSLabel
    gViewer_CurrentOnly := !gViewer_CurrentOnly
    gViewer_WSLabel.Text := gViewer_CurrentOnly ? "[Current]" : "[All]"
    _Viewer_RequestProjection()
}

_Viewer_UpdateList(items) {
    global gViewer_LV, gViewer_RowByHwnd, gViewer_RecByHwnd, gViewer_LastItemCount
    global gViewer_Sort

    ; Local sort - viewer controls its own sort order
    _Viewer_SortItems(items, gViewer_Sort)

    ; Always do full refresh to ensure correct sort order
    ; ListView rows don't reorder when cell values change, so we must rebuild

    ; Disable redraw during update
    gViewer_LV.Opt("-Redraw")

    gViewer_LV.Delete()
    gViewer_RowByHwnd := Map()
    gViewer_RecByHwnd := Map()

    for _, rec in items {
        hwnd := _Viewer_Get(rec, "hwnd", 0)
        row := gViewer_LV.Add("",
            _Viewer_Get(rec, "z", ""),
            _Viewer_Get(rec, "lastActivatedTick", ""),
            "0x" Format("{:X}", hwnd),
            _Viewer_Get(rec, "pid", ""),
            _Viewer_Get(rec, "title", ""),
            _Viewer_Get(rec, "class", ""),
            _Viewer_Get(rec, "state", ""),
            _Viewer_Get(rec, "workspaceName", ""),
            _Viewer_Get(rec, "processName", ""),
            _Viewer_Get(rec, "isFocused", 0) ? "Y" : "",
            _Viewer_Get(rec, "isCloaked", 0) ? "Y" : "",
            _Viewer_Get(rec, "isMinimized", 0) ? "Y" : "",
            _Viewer_IconStr(_Viewer_Get(rec, "iconHicon", 0))
        )
        gViewer_RowByHwnd[hwnd] := row
        gViewer_RecByHwnd[hwnd] := rec
    }

    gViewer_LastItemCount := items.Length

    ; Re-enable redraw
    gViewer_LV.Opt("+Redraw")
}

_Viewer_IncrementalUpdate(items) {
    global gViewer_LV, gViewer_RowByHwnd, gViewer_RecByHwnd

    ; Disable redraw during update
    gViewer_LV.Opt("-Redraw")

    seen := Map()
    for _, rec in items {
        hwnd := _Viewer_Get(rec, "hwnd", 0)
        seen[hwnd] := true

        if (gViewer_RowByHwnd.Has(hwnd)) {
            row := gViewer_RowByHwnd[hwnd]
            old := gViewer_RecByHwnd[hwnd]

            ; Check if anything changed
            if (_Viewer_RecChanged(old, rec)) {
                gViewer_LV.Modify(row, "",
                    _Viewer_Get(rec, "z", ""),
                    _Viewer_Get(rec, "lastActivatedTick", ""),
                    "0x" Format("{:X}", hwnd),
                    _Viewer_Get(rec, "pid", ""),
                    _Viewer_Get(rec, "title", ""),
                    _Viewer_Get(rec, "class", ""),
                    _Viewer_Get(rec, "state", ""),
                    _Viewer_Get(rec, "workspaceName", ""),
                    _Viewer_Get(rec, "processName", ""),
                    _Viewer_Get(rec, "isFocused", 0) ? "Y" : "",
                    _Viewer_Get(rec, "isCloaked", 0) ? "Y" : "",
                    _Viewer_Get(rec, "isMinimized", 0) ? "Y" : ""
                )
                gViewer_RecByHwnd[hwnd] := rec
            }
        } else {
            ; New window - add it
            row := gViewer_LV.Add("",
                _Viewer_Get(rec, "z", ""),
                _Viewer_Get(rec, "lastActivatedTick", ""),
                "0x" Format("{:X}", hwnd),
                _Viewer_Get(rec, "pid", ""),
                _Viewer_Get(rec, "title", ""),
                _Viewer_Get(rec, "class", ""),
                _Viewer_Get(rec, "state", ""),
                _Viewer_Get(rec, "workspaceName", ""),
                _Viewer_Get(rec, "processName", ""),
                _Viewer_Get(rec, "isFocused", 0) ? "Y" : "",
                _Viewer_Get(rec, "isCloaked", 0) ? "Y" : "",
                _Viewer_Get(rec, "isMinimized", 0) ? "Y" : ""
            )
            gViewer_RowByHwnd[hwnd] := row
            gViewer_RecByHwnd[hwnd] := rec
        }
    }

    ; Remove windows that are no longer present
    toRemove := []
    for hwnd, row in gViewer_RowByHwnd {
        if (!seen.Has(hwnd)) {
            toRemove.Push(hwnd)
        }
    }
    if (toRemove.Length > 0) {
        ; Need full refresh if items were removed (row numbers shift)
        gViewer_LV.Opt("+Redraw")
        _Viewer_UpdateList(items)
        return
    }

    ; Re-enable redraw
    gViewer_LV.Opt("+Redraw")
}

_Viewer_RecChanged(old, new) {
    ; Compare key fields
    if (_Viewer_Get(old, "z", 0) != _Viewer_Get(new, "z", 0)) {
        return true
    }
    if (_Viewer_Get(old, "title", "") != _Viewer_Get(new, "title", "")) {
        return true
    }
    if (_Viewer_Get(old, "state", "") != _Viewer_Get(new, "state", "")) {
        return true
    }
    if (_Viewer_Get(old, "isFocused", 0) != _Viewer_Get(new, "isFocused", 0)) {
        return true
    }
    if (_Viewer_Get(old, "processName", "") != _Viewer_Get(new, "processName", "")) {
        return true
    }
    if (_Viewer_Get(old, "workspaceName", "") != _Viewer_Get(new, "workspaceName", "")) {
        return true
    }
    if (_Viewer_Get(old, "lastActivatedTick", 0) != _Viewer_Get(new, "lastActivatedTick", 0)) {
        return true
    }
    return false
}

_Viewer_ApplyDelta(payload) {
    global gViewer_LV, gViewer_RowByHwnd, gViewer_RecByHwnd, gViewer_Sort

    ; Handle removes
    if (payload.Has("removes") && payload["removes"].Length) {
        _Viewer_RequestProjection()
        return
    }

    if (!payload.Has("upserts")) {
        return
    }

    gViewer_LV.Opt("-Redraw")

    needsRefresh := false
    for _, rec in payload["upserts"] {
        if (!IsObject(rec)) {
            continue
        }
        hwnd := _Viewer_Get(rec, "hwnd", 0)
        if (!hwnd) {
            continue
        }

        ; Check if sort order might have changed
        if (gViewer_RecByHwnd.Has(hwnd)) {
            old := gViewer_RecByHwnd[hwnd]
            if (gViewer_Sort = "Z" && _Viewer_Get(rec, "z", 0) != _Viewer_Get(old, "z", 0)) {
                needsRefresh := true
            } else if (gViewer_Sort = "MRU" && _Viewer_Get(rec, "lastActivatedTick", 0) != _Viewer_Get(old, "lastActivatedTick", 0)) {
                needsRefresh := true
            }
        }

        if (gViewer_RowByHwnd.Has(hwnd)) {
            row := gViewer_RowByHwnd[hwnd]
            gViewer_LV.Modify(row, "",
                _Viewer_Get(rec, "z", ""),
                _Viewer_Get(rec, "lastActivatedTick", ""),
                "0x" Format("{:X}", hwnd),
                _Viewer_Get(rec, "pid", ""),
                _Viewer_Get(rec, "title", ""),
                _Viewer_Get(rec, "class", ""),
                _Viewer_Get(rec, "state", ""),
                _Viewer_Get(rec, "workspaceName", ""),
                _Viewer_Get(rec, "processName", ""),
                _Viewer_Get(rec, "isFocused", 0) ? "Y" : "",
                _Viewer_Get(rec, "isCloaked", 0) ? "Y" : "",
                _Viewer_Get(rec, "isMinimized", 0) ? "Y" : ""
            )
        } else {
            row := gViewer_LV.Add("",
                _Viewer_Get(rec, "z", ""),
                _Viewer_Get(rec, "lastActivatedTick", ""),
                "0x" Format("{:X}", hwnd),
                _Viewer_Get(rec, "pid", ""),
                _Viewer_Get(rec, "title", ""),
                _Viewer_Get(rec, "class", ""),
                _Viewer_Get(rec, "state", ""),
                _Viewer_Get(rec, "workspaceName", ""),
                _Viewer_Get(rec, "processName", ""),
                _Viewer_Get(rec, "isFocused", 0) ? "Y" : "",
                _Viewer_Get(rec, "isCloaked", 0) ? "Y" : "",
                _Viewer_Get(rec, "isMinimized", 0) ? "Y" : ""
            )
            gViewer_RowByHwnd[hwnd] := row
        }
        gViewer_RecByHwnd[hwnd] := rec
    }

    gViewer_LV.Opt("+Redraw")

    if (needsRefresh) {
        _Viewer_RequestProjection()
    }
}

_Viewer_Heartbeat() {
    global gViewer_Client, gViewer_LastMsgTick, StorePipeName
    global gViewer_Status, gViewer_PushCount, gViewer_PollCount, gViewer_LastUpdateType

    if (!IsObject(gViewer_Client) || !gViewer_Client.hPipe) {
        gViewer_Client := IPC_PipeClient_Connect(StorePipeName, Viewer_OnMessage)
        if (gViewer_Client.hPipe) {
            _Viewer_SendHello()
        }
        if (IsObject(gViewer_Status)) {
            gViewer_Status.Text := "Disconnected"
        }
        return
    }

    ; Only request refresh if no updates received in 5 seconds
    if (gViewer_LastMsgTick && (A_TickCount - gViewer_LastMsgTick) > 5000) {
        _Viewer_RequestProjection()
    }

    if (IsObject(gViewer_Status)) {
        elapsed := A_TickCount - gViewer_LastMsgTick
        typeStr := gViewer_LastUpdateType ? gViewer_LastUpdateType : "none"
        gViewer_Status.Text := "Last: " typeStr " " elapsed "ms ago | Push: " gViewer_PushCount " | Poll: " gViewer_PollCount
    }
}

_Viewer_Log(msg) {
    global gViewer_LogPath
    if (!gViewer_LogPath) {
        return
    }
    try FileAppend(FormatTime(, "HH:mm:ss") " " msg "`n", gViewer_LogPath, "UTF-8")
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

_Viewer_IconStr(hicon) {
    if (!hicon || hicon = 0) {
        return ""
    }
    return "0x" Format("{:X}", hicon)
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

; Sort items array locally based on sort mode
_Viewer_SortItems(items, sortMode) {
    if (!IsObject(items) || items.Length <= 1)
        return
    if (sortMode = "Z")
        _Viewer_InsertionSort(items, _Viewer_CmpZ)
    else
        _Viewer_InsertionSort(items, _Viewer_CmpMRU)
}

_Viewer_InsertionSort(arr, cmp) {
    len := arr.Length
    Loop len {
        i := A_Index
        if (i = 1)
            continue
        key := arr[i]
        j := i - 1
        while (j >= 1 && cmp(arr[j], key) > 0) {
            arr[j + 1] := arr[j]
            j -= 1
        }
        arr[j + 1] := key
    }
}

_Viewer_CmpZ(a, b) {
    az := _Viewer_Get(a, "z", 0)
    bz := _Viewer_Get(b, "z", 0)
    return (az < bz) ? -1 : (az > bz) ? 1 : 0
}

_Viewer_CmpMRU(a, b) {
    ; MRU: most recently activated first (descending)
    at := _Viewer_Get(a, "lastActivatedTick", 0)
    bt := _Viewer_Get(b, "lastActivatedTick", 0)
    return (at > bt) ? -1 : (at < bt) ? 1 : 0
}

Viewer_Init()
