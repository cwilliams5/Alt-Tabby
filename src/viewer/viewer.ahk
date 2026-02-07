#Requires AutoHotkey v2.0
; Note: #SingleInstance removed - unified exe uses #SingleInstance Off
#Warn VarUnset, Off

; Includes: Use *i (ignore if not found) for unified exe compatibility
#Include *i ..\shared\config_loader.ahk
#Include *i ..\lib\cjson.ahk
#Include *i ..\shared\ipc_pipe.ahk
#Include *i ..\shared\blacklist.ahk
#Include *i ..\shared\process_utils.ahk

; Viewer (debug) - receives snapshots/deltas from store.

global gViewer_Client := 0
global gViewer_Sort := "MRU"
global gViewer_Gui := 0
global gViewer_LV := 0
global gViewer_RowByHwnd := Map()
global gViewer_CurrentOnly := false
global gViewer_IncludeMinimized := true
global gViewer_IncludeCloaked := true
global gViewer_RecByHwnd := Map()
global gViewer_LastMsgTick := 0
global gViewer_LogPath := ""
global gViewer_Status := 0
global gViewer_SortLabel := 0
global gViewer_WSLabel := 0
global gViewer_MinLabel := 0
global gViewer_CloakLabel := 0
global gViewer_Headless := false
global gViewer_LastRev := -1
global gViewer_LastItemCount := 0
global gViewer_PushSnapCount := 0
global gViewer_PushDeltaCount := 0
global gViewer_PollCount := 0
global gViewer_HeartbeatCount := 0
global gViewer_LastUpdateType := ""
global gViewer_CurrentWSLabel := 0
global gViewer_CurrentWSName := ""
global gViewer_ProducerState := Map()  ; Producer states from store meta
global gViewer_ShuttingDown := false  ; Shutdown coordination flag
global gViewer_StoreWakeHwnd := 0    ; Store's A_ScriptHwnd for PostMessage pipe wake

global gViewer_TestMode := false
for _, arg in A_Args {
    if (SubStr(arg, 1, 6) = "--log=") {
        gViewer_LogPath := SubStr(arg, 7)
    } else if (arg = "--nogui") {
        gViewer_Headless := true
    } else if (arg = "--test") {
        gViewer_TestMode := true
    }
}

; Hide tray icon for headless/test mode (no user-facing UI needed)
if (gViewer_Headless || gViewer_TestMode)
    A_IconHidden := true

Viewer_Init() {
    global gViewer_Client, gViewer_LogPath, cfg
    global gViewer_Headless

    ; CRITICAL: Initialize config FIRST - sets all global defaults
    ConfigLoader_Init()

    ; Initialize blacklist for writing (viewer needs to know the file path)
    Blacklist_Init()

    if (cfg.DiagViewerLog && !gViewer_LogPath) {
        global LOG_PATH_VIEWER
        gViewer_LogPath := LOG_PATH_VIEWER
        LogInitSession(gViewer_LogPath, "Alt-Tabby Viewer Log")
    }
    try OnError(Viewer_OnError)
    if (!gViewer_Headless) {
        _Viewer_CreateGui()
    }
    ; Register PostMessage wake handler: store signals us after writing to the pipe
    global IPC_WM_PIPE_WAKE
    OnMessage(IPC_WM_PIPE_WAKE, _Viewer_OnPipeWake)

    _Viewer_Log("Connecting to pipe: " cfg.StorePipeName)
    gViewer_Client := IPC_PipeClient_Connect(cfg.StorePipeName, Viewer_OnMessage)
    _Viewer_Log("Connection result: hPipe=" gViewer_Client.hPipe)
    if (!gViewer_Client.hPipe && cfg.ViewerAutoStartStore) {
        _Viewer_Log("Starting store...")
        _Viewer_StartStore()
    }
    if (gViewer_Client.hPipe) {
        _Viewer_Log("Sending hello...")
        _Viewer_SendHello()
        _Viewer_Log("Requesting producer status...")
        _Viewer_RequestProducerStatus()
        _Viewer_Log("Sending projection request...")
        _Viewer_RequestProjection()
    } else {
        _Viewer_Log("Not connected, skipping initial messages")
    }

    ; Health check timer interval derived from heartbeat config
    ; Check every heartbeat interval (gives ~2-3 checks before timeout triggers)
    healthCheckMs := cfg.StoreHeartbeatIntervalMs
    SetTimer(_Viewer_Heartbeat, healthCheckMs)
}

Viewer_OnMessage(line, hPipe := 0) {
    global gViewer_LastMsgTick, gViewer_LastRev, gViewer_ShuttingDown
    global gViewer_PushSnapCount, gViewer_PushDeltaCount, gViewer_PollCount, gViewer_LastUpdateType, gViewer_Headless
    global gViewer_HeartbeatCount
    global IPC_MSG_SNAPSHOT, IPC_MSG_PROJECTION, IPC_MSG_DELTA, IPC_MSG_HELLO_ACK, IPC_MSG_HEARTBEAT
    global IPC_MSG_PRODUCER_STATUS, IPC_MSG_WORKSPACE_CHANGE
    if (gViewer_ShuttingDown)
        return
    gViewer_LastMsgTick := A_TickCount
    _Viewer_Log("=== MESSAGE RECEIVED ===")
    _Viewer_Log("raw: " SubStr(line, 1, 300))
    obj := ""
    try {
        obj := JSON.Load(line)
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
    ; Skip heartbeats from this check - they should always be processed even with same rev
    if (obj.Has("rev")) {
        rev := obj["rev"]
        _Viewer_Log("rev=" rev " lastRev=" gViewer_LastRev)
        if (rev = gViewer_LastRev && type != IPC_MSG_HELLO_ACK && type != IPC_MSG_HEARTBEAT) {
            _Viewer_Log("skip duplicate rev=" rev)
            return
        }
        gViewer_LastRev := rev
    }

    if (type = IPC_MSG_HELLO_ACK) {
        ; Extract store's hwnd for PostMessage pipe wake
        global gViewer_StoreWakeHwnd
        if (obj.Has("hwnd"))
            gViewer_StoreWakeHwnd := obj["hwnd"]
        return
    }

    if (type = IPC_MSG_SNAPSHOT) {
        _Viewer_HandleItemsMessage(obj, &gViewer_PushSnapCount, "snap")
    } else if (type = IPC_MSG_PROJECTION) {
        _Viewer_HandleItemsMessage(obj, &gViewer_PollCount, "poll")
    } else if (type = IPC_MSG_DELTA) {
        ; Delta = incremental update (now tailored to our projection opts)
        ; RACE FIX: Protect cache modifications from timer interruption
        Critical "On"
        gViewer_PushDeltaCount++
        gViewer_LastUpdateType := "delta"
        if (obj.Has("payload")) {
            payload := obj["payload"]
            _Viewer_UpdateCurrentWS(payload)
            Critical "Off"
            if (payload.Has("upserts") && !gViewer_Headless) {
                _Viewer_ApplyDelta(payload)
            }
        } else {
            Critical "Off"
        }
    } else if (type = IPC_MSG_HEARTBEAT) {
        ; Heartbeat = store is alive, check if we're behind on rev
        gViewer_HeartbeatCount++
        gViewer_LastUpdateType := "hb"
        if (obj.Has("rev")) {
            storeRev := obj["rev"]
            ; If store rev is ahead, we missed something - request full projection
            if (storeRev > gViewer_LastRev && gViewer_LastRev >= 0) {
                _Viewer_Log("heartbeat: store rev " storeRev " > local rev " gViewer_LastRev " - requesting resync")
                _Viewer_RequestProjection()
            }
        }
    } else if (type = IPC_MSG_PRODUCER_STATUS) {
        ; Producer status = response to our explicit request
        _Viewer_Log("producer status received")
        if (obj.Has("producers")) {
            _Viewer_UpdateProducerState(obj["producers"])
        }
    } else if (type = IPC_MSG_WORKSPACE_CHANGE) {
        ; Workspace change = dedicated notification in OnChange delta style
        if (obj.Has("payload"))
            _Viewer_UpdateCurrentWS(obj["payload"])
    }
}

; Shared handler for SNAPSHOT and PROJECTION messages
; Both have identical structure: bump counter, update WS, extract items, update list
_Viewer_HandleItemsMessage(obj, &counter, label) {
    global gViewer_LastUpdateType, gViewer_Headless
    ; RACE FIX: Protect cache modifications from timer interruption
    Critical "On"
    counter++
    gViewer_LastUpdateType := label
    if (obj.Has("payload")) {
        payload := obj["payload"]
        _Viewer_UpdateCurrentWS(payload)
        if (payload.Has("items")) {
            items := payload["items"]
            _Viewer_Log(label " items=" items.Length)
            Critical "Off"
            if (!gViewer_Headless)
                _Viewer_UpdateList(items)
            return
        }
    }
    Critical "Off"
}

_Viewer_SendHello() {
    global gViewer_Client, IPC_MSG_HELLO
    msg := { type: IPC_MSG_HELLO, hwnd: A_ScriptHwnd, clientId: "viewer", wants: { deltas: true }, projectionOpts: _Viewer_ProjectionOpts() }
    IPC_PipeClient_Send(gViewer_Client, JSON.Dump(msg))
}

_Viewer_RequestProjection() {
    global gViewer_Client, gViewer_LastRev, IPC_MSG_PROJECTION_REQUEST, gViewer_StoreWakeHwnd
    gViewer_LastRev := -1  ; Reset to allow next response
    msg := { type: IPC_MSG_PROJECTION_REQUEST, projectionOpts: _Viewer_ProjectionOpts() }
    IPC_PipeClient_Send(gViewer_Client, JSON.Dump(msg), gViewer_StoreWakeHwnd)
}

_Viewer_RequestProducerStatus() {
    global gViewer_Client, IPC_MSG_PRODUCER_STATUS_REQUEST, gViewer_StoreWakeHwnd
    if (!gViewer_Client || !gViewer_Client.hPipe)
        return
    msg := { type: IPC_MSG_PRODUCER_STATUS_REQUEST }
    IPC_PipeClient_Send(gViewer_Client, JSON.Dump(msg), gViewer_StoreWakeHwnd)
}

; Common reconnect sequence: send hello, request producer status, log
_Viewer_OnConnected(logMsg) {
    global gViewer_StoreWakeHwnd
    gViewer_StoreWakeHwnd := 0  ; Reset until HELLO_ACK brings fresh store hwnd
    _Viewer_SendHello()
    _Viewer_RequestProducerStatus()
    _Viewer_Log(logMsg)
}

; Update producer state from IPC response (not from meta anymore)
_Viewer_UpdateProducerState(producers) {
    global gViewer_ProducerState, gViewer_Headless
    if (!IsObject(producers))
        return
    gViewer_ProducerState := Map()
    if (producers is Map) {
        for name, state in producers
            gViewer_ProducerState[name] := state
    } else {
        for name in ["wineventHook", "mruLite", "komorebiSub", "komorebiLite", "iconPump", "procPump"] {
            try {
                if (producers.HasOwnProp(name))
                    gViewer_ProducerState[name] := producers.%name%
            }
        }
    }
    ; Update status bar display
    if (!gViewer_Headless)
        _Viewer_UpdateStatusBar()
}

_Viewer_ProjectionOpts() {
    global gViewer_Sort, gViewer_CurrentOnly, gViewer_IncludeMinimized, gViewer_IncludeCloaked
    return {
        sort: gViewer_Sort,
        columns: "items",
        currentWorkspaceOnly: gViewer_CurrentOnly,
        includeMinimized: gViewer_IncludeMinimized,
        includeCloaked: gViewer_IncludeCloaked
    }
}

_Viewer_CreateGui() {
    global gViewer_Gui, gViewer_LV, gViewer_Status
    global gViewer_SortLabel, gViewer_WSLabel, gViewer_CurrentWSLabel
    global gViewer_MinLabel, gViewer_CloakLabel

    gViewer_Gui := Gui("+Resize +AlwaysOnTop", "WindowStore Viewer")

    ; === Top toolbar - toggle buttons ===
    xPos := 10

    ; Sort toggle
    btn := gViewer_Gui.AddButton("x" xPos " y10 w70 h24", "Sort")
    btn.OnEvent("Click", _Viewer_ToggleSort)
    gViewer_SortLabel := gViewer_Gui.AddText("x" (xPos + 75) " y14 w35 h20", "[MRU]")
    xPos += 115

    ; Workspace toggle
    btn2 := gViewer_Gui.AddButton("x" xPos " y10 w70 h24", "WS")
    btn2.OnEvent("Click", _Viewer_ToggleCurrentWS)
    gViewer_WSLabel := gViewer_Gui.AddText("x" (xPos + 75) " y14 w50 h20", "[All]")
    xPos += 130

    ; Minimized toggle
    btn3 := gViewer_Gui.AddButton("x" xPos " y10 w70 h24", "Min")
    btn3.OnEvent("Click", _Viewer_ToggleMinimized)
    gViewer_MinLabel := gViewer_Gui.AddText("x" (xPos + 75) " y14 w35 h20", "[Y]")
    xPos += 115

    ; Cloaked toggle
    btn4 := gViewer_Gui.AddButton("x" xPos " y10 w70 h24", "Cloak")
    btn4.OnEvent("Click", _Viewer_ToggleCloaked)
    gViewer_CloakLabel := gViewer_Gui.AddText("x" (xPos + 75) " y14 w35 h20", "[Y]")
    xPos += 115

    ; Current workspace display
    gViewer_Gui.AddText("x" xPos " y14 w50 h20", "CurWS:")
    gViewer_CurrentWSLabel := gViewer_Gui.AddText("x" (xPos + 50) " y14 w70 h20 +0x100", "---")
    xPos += 130

    ; Refresh button
    btn5 := gViewer_Gui.AddButton("x" xPos " y10 w60 h24", "Refresh")
    btn5.OnEvent("Click", (*) => _Viewer_RequestProjection())
    xPos += 70

    ; Status button (refresh producer status)
    btn6 := gViewer_Gui.AddButton("x" xPos " y10 w50 h24", "Status")
    btn6.OnEvent("Click", (*) => _Viewer_RequestProducerStatus())

    ; === ListView in middle ===
    ; Columns: Z, MRU, HWND, PID, Title, Class, WS, Cur, Process, Foc, Clk, Min, Icon
    gViewer_LV := gViewer_Gui.AddListView("x10 y44 w1100 h570 +LV0x10000",
        ["Z", "MRU", "HWND", "PID", "Title", "Class", "WS", "Cur", "Process", "Foc", "Clk", "Min", "Icon"])

    ; === Bottom status bar ===
    gViewer_Status := gViewer_Gui.AddText("x10 y620 w1100 h20", "Disconnected")

    ; Set column widths
    gViewer_LV.ModifyCol(1, 35)   ; Z
    gViewer_LV.ModifyCol(2, 90)   ; MRU (tick)
    gViewer_LV.ModifyCol(3, 75)   ; HWND
    gViewer_LV.ModifyCol(4, 45)   ; PID
    gViewer_LV.ModifyCol(5, 280)  ; Title
    gViewer_LV.ModifyCol(6, 130)  ; Class
    gViewer_LV.ModifyCol(7, 60)   ; Workspace
    gViewer_LV.ModifyCol(8, 30)   ; isOnCurrentWorkspace (Cur)
    gViewer_LV.ModifyCol(9, 90)   ; Process
    gViewer_LV.ModifyCol(10, 30)  ; Focused
    gViewer_LV.ModifyCol(11, 30)  ; Cloaked
    gViewer_LV.ModifyCol(12, 30)  ; Minimized
    gViewer_LV.ModifyCol(13, 70)  ; Icon (HICON value)

    ; Double-click to blacklist a window
    gViewer_LV.OnEvent("DoubleClick", _Viewer_OnBlacklist)

    gViewer_Gui.OnEvent("Close", (*) => (_Viewer_Shutdown(), ExitApp()))
    gViewer_Gui.OnEvent("Size", _Viewer_OnResize)
    gViewer_Gui.Show("w1120 h660")
}

; Graceful shutdown - stops timer first, then closes IPC
_Viewer_Shutdown() {
    global gViewer_ShuttingDown, gViewer_Client
    gViewer_ShuttingDown := true
    SetTimer(_Viewer_Heartbeat, 0)  ; Stop timer FIRST
    if (IsObject(gViewer_Client) && gViewer_Client.hPipe)
        IPC_PipeClient_Close(gViewer_Client)
    gViewer_Client := 0
}

; Check if GUI is still valid (not destroyed)
_Viewer_IsGuiValid() {
    global gViewer_Gui
    if (!gViewer_Gui)
        return false
    try {
        hwnd := gViewer_Gui.Hwnd
        return hwnd != 0
    } catch {
        return false
    }
}

_Viewer_OnResize(gui, minMax, w, h) {
    global gViewer_LV, gViewer_Status, gViewer_ShuttingDown

    ; Guard against shutdown or destroyed GUI
    if (gViewer_ShuttingDown || !_Viewer_IsGuiValid())
        return

    if (minMax = -1) {
        return  ; Minimized
    }
    ; ListView: top=44, bottom margin=30 (for status bar)
    try gViewer_LV.Move(, , w - 20, h - 74)
    ; Status bar at bottom
    try gViewer_Status.Move(10, h - 26, w - 20)
}

_Viewer_ToggleSort(*) {
    global gViewer_Sort, gViewer_SortLabel, gViewer_LastItemCount, gViewer_ShuttingDown
    if (gViewer_ShuttingDown)
        return
    gViewer_Sort := (gViewer_Sort = "Z") ? "MRU" : "Z"
    gViewer_SortLabel.Text := "[" gViewer_Sort "]"
    ; Force full refresh by resetting cache
    gViewer_LastItemCount := 0
    _Viewer_RequestProjection()
}

_Viewer_ToggleCurrentWS(*) {
    global gViewer_CurrentOnly, gViewer_WSLabel, gViewer_ShuttingDown
    if (gViewer_ShuttingDown)
        return
    gViewer_CurrentOnly := !gViewer_CurrentOnly
    gViewer_WSLabel.Text := gViewer_CurrentOnly ? "[Cur]" : "[All]"
    ; Update server with new projection opts so future pushes are filtered correctly
    _Viewer_SendProjectionOpts()
    _Viewer_RequestProjection()
}

_Viewer_ToggleMinimized(*) {
    global gViewer_IncludeMinimized, gViewer_MinLabel, gViewer_ShuttingDown
    if (gViewer_ShuttingDown)
        return
    gViewer_IncludeMinimized := !gViewer_IncludeMinimized
    gViewer_MinLabel.Text := gViewer_IncludeMinimized ? "[Y]" : "[N]"
    _Viewer_SendProjectionOpts()
    _Viewer_RequestProjection()
}

_Viewer_ToggleCloaked(*) {
    global gViewer_IncludeCloaked, gViewer_CloakLabel, gViewer_ShuttingDown
    if (gViewer_ShuttingDown)
        return
    gViewer_IncludeCloaked := !gViewer_IncludeCloaked
    gViewer_CloakLabel.Text := gViewer_IncludeCloaked ? "[Y]" : "[N]"
    _Viewer_SendProjectionOpts()
    _Viewer_RequestProjection()
}

_Viewer_SendProjectionOpts() {
    global gViewer_Client, IPC_MSG_SET_PROJECTION_OPTS, gViewer_StoreWakeHwnd
    if (!IsObject(gViewer_Client) || !gViewer_Client.hPipe)
        return
    msg := { type: IPC_MSG_SET_PROJECTION_OPTS, projectionOpts: _Viewer_ProjectionOpts() }
    IPC_PipeClient_Send(gViewer_Client, JSON.Dump(msg), gViewer_StoreWakeHwnd)
}

_Viewer_UpdateList(items) {
    global gViewer_LV, gViewer_RowByHwnd, gViewer_RecByHwnd, gViewer_LastItemCount
    global gViewer_Sort, gViewer_ShuttingDown
    if (gViewer_ShuttingDown)
        return

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
        row := gViewer_LV.Add("", _Viewer_BuildRowArgs(rec)*)
        gViewer_RowByHwnd[hwnd] := row
        gViewer_RecByHwnd[hwnd] := rec
    }

    gViewer_LastItemCount := items.Length

    ; Re-enable redraw
    gViewer_LV.Opt("+Redraw")
}

; Rebuild ListView from cached records (for re-sorting without network request)
_Viewer_RebuildFromCache() {
    global gViewer_LV, gViewer_RowByHwnd, gViewer_RecByHwnd, gViewer_Sort, gViewer_ShuttingDown
    if (gViewer_ShuttingDown)
        return

    ; Collect all cached records into array
    items := []
    for hwnd, rec in gViewer_RecByHwnd {
        items.Push(rec)
    }

    if (items.Length = 0)
        return

    ; Sort locally
    _Viewer_SortItems(items, gViewer_Sort)

    ; Rebuild ListView
    gViewer_LV.Opt("-Redraw")
    gViewer_LV.Delete()
    gViewer_RowByHwnd := Map()

    for _, rec in items {
        hwnd := _Viewer_Get(rec, "hwnd", 0)
        row := gViewer_LV.Add("", _Viewer_BuildRowArgs(rec)*)
        gViewer_RowByHwnd[hwnd] := row
    }

    gViewer_LV.Opt("+Redraw")
}

_Viewer_ApplyDelta(payload) {
    global gViewer_LV, gViewer_RowByHwnd, gViewer_RecByHwnd, gViewer_Sort, gViewer_ShuttingDown
    if (gViewer_ShuttingDown)
        return

    ; Handle removes locally - remove from cache, then rebuild
    hadRemoves := false
    if (payload.Has("removes") && payload["removes"].Length) {
        for _, hwnd in payload["removes"] {
            if (gViewer_RecByHwnd.Has(hwnd)) {
                gViewer_RecByHwnd.Delete(hwnd)
                hadRemoves := true
            }
            if (gViewer_RowByHwnd.Has(hwnd)) {
                gViewer_RowByHwnd.Delete(hwnd)
            }
        }
    }

    ; If only removes and no upserts, rebuild from cache
    if (!payload.Has("upserts") || payload["upserts"].Length = 0) {
        if (hadRemoves) {
            _Viewer_RebuildFromCache()
        }
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

        ; Merge sparse records into existing cache (sparse deltas may only contain changed fields)
        if (gViewer_RecByHwnd.Has(hwnd)) {
            existing := gViewer_RecByHwnd[hwnd]
            old := existing  ; Reference for sort comparison before merge

            ; Check if sort order might have changed (use old value as fallback for sparse records)
            if (gViewer_Sort = "Z" && _Viewer_Get(rec, "z", _Viewer_Get(old, "z", 0)) != _Viewer_Get(old, "z", 0)) {
                needsRefresh := true
            } else if (gViewer_Sort = "MRU" && _Viewer_Get(rec, "lastActivatedTick", _Viewer_Get(old, "lastActivatedTick", 0)) != _Viewer_Get(old, "lastActivatedTick", 0)) {
                needsRefresh := true
            }

            ; Merge: update only fields present in the sparse record
            if (rec is Map) {
                for k, v in rec
                    existing[k] := v
            } else {
                for k in rec.OwnProps()
                    existing.%k% := rec.%k%
            }
        } else {
            ; New record: store as-is
            gViewer_RecByHwnd[hwnd] := rec
        }

        ; Use the merged record for display (ensures all fields are present)
        displayRec := gViewer_RecByHwnd[hwnd]
        if (gViewer_RowByHwnd.Has(hwnd)) {
            row := gViewer_RowByHwnd[hwnd]
            gViewer_LV.Modify(row, "", _Viewer_BuildRowArgs(displayRec)*)
        } else {
            row := gViewer_LV.Add("", _Viewer_BuildRowArgs(displayRec)*)
            gViewer_RowByHwnd[hwnd] := row
        }
    }

    gViewer_LV.Opt("+Redraw")

    if (needsRefresh || hadRemoves) {
        ; Re-sort locally instead of requesting new projection
        ; Also rebuild if removes happened (row numbers shift)
        _Viewer_RebuildFromCache()
    }
}

_Viewer_Heartbeat() {
    global gViewer_Client, gViewer_LastMsgTick, cfg, gViewer_ShuttingDown
    global gViewer_Status, gViewer_PushSnapCount, gViewer_PushDeltaCount, gViewer_PollCount
    global gViewer_HeartbeatCount, gViewer_LastUpdateType

    ; Guard against shutdown or destroyed GUI
    if (gViewer_ShuttingDown || !_Viewer_IsGuiValid())
        return

    timeoutMs := cfg.ViewerHeartbeatTimeoutMs

    if (!IsObject(gViewer_Client) || !gViewer_Client.hPipe) {
        ; Not connected - try non-blocking connect (single attempt, no busy-wait loop)
        gViewer_Client := IPC_PipeClient_Connect(cfg.StorePipeName, Viewer_OnMessage, 0)
        if (gViewer_Client.hPipe)
            _Viewer_OnConnected("Reconnected to store")
        try gViewer_Status.Text := "Disconnected"
        return
    }

    ; Check for heartbeat timeout - if no message in timeoutMs, connection may be dead
    if (gViewer_LastMsgTick && (A_TickCount - gViewer_LastMsgTick) > timeoutMs) {
        _Viewer_Log("Heartbeat timeout (" timeoutMs "ms) - attempting reconnect")
        ; Close current connection and try non-blocking reconnect
        IPC_PipeClient_Close(gViewer_Client)
        gViewer_Client := IPC_PipeClient_Connect(cfg.StorePipeName, Viewer_OnMessage, 0)
        if (gViewer_Client.hPipe)
            _Viewer_OnConnected("Reconnected after timeout")
        return
    }

    ; Update status bar
    _Viewer_UpdateStatusBar()
}

_Viewer_UpdateStatusBar() {
    global gViewer_Status, gViewer_LastMsgTick, gViewer_LastRev, gViewer_ShuttingDown
    global gViewer_PushSnapCount, gViewer_PushDeltaCount, gViewer_PollCount
    global gViewer_HeartbeatCount, gViewer_LastUpdateType

    ; Guard against shutdown or destroyed GUI
    if (gViewer_ShuttingDown || !_Viewer_IsGuiValid())
        return

    try {
        elapsed := gViewer_LastMsgTick ? (A_TickCount - gViewer_LastMsgTick) : 0
        typeStr := gViewer_LastUpdateType ? gViewer_LastUpdateType : "none"
        prodStr := _Viewer_FormatProducerState()
        gViewer_Status.Text := "Rev:" gViewer_LastRev " | " typeStr " " elapsed "ms | S:" gViewer_PushSnapCount " D:" gViewer_PushDeltaCount " H:" gViewer_HeartbeatCount " P:" gViewer_PollCount " | " prodStr
    }
}

_Viewer_Log(msg) {
    global gViewer_LogPath
    if (!gViewer_LogPath) {
        return
    }
    LogAppend(gViewer_LogPath, msg)
}

; Format producer states for status bar display
; Shows abbreviated names with symbols: ✓=running, ✗=failed, -=disabled
_Viewer_FormatProducerState() {
    global gViewer_ProducerState

    if (!gViewer_ProducerState.Count)
        return "Producers: ?"

    parts := []

    ; Show key producers with symbols
    ; WEH = WinEventHook, MRU = MRU_Lite, KS = KomorebiSub, IP = IconPump, PP = ProcPump
    _Viewer_AddProdStatus(&parts, "WEH", "wineventHook")
    _Viewer_AddProdStatus(&parts, "MRU", "mruLite")
    _Viewer_AddProdStatus(&parts, "KS", "komorebiSub")
    _Viewer_AddProdStatus(&parts, "KL", "komorebiLite")
    _Viewer_AddProdStatus(&parts, "IP", "iconPump")
    _Viewer_AddProdStatus(&parts, "PP", "procPump")

    result := ""
    for _, part in parts
        result .= (result ? " " : "") . part
    return result
}

_Viewer_AddProdStatus(&parts, abbrev, name) {
    global gViewer_ProducerState
    if (!gViewer_ProducerState.Has(name))
        return
    state := gViewer_ProducerState[name]
    if (state = "running")
        parts.Push(abbrev ":OK")
    else if (state = "failed")
        parts.Push(abbrev ":FAIL")
    ; Skip disabled producers to keep status line compact
}

_Viewer_UpdateCurrentWS(payload) {
    global gViewer_CurrentWSLabel, gViewer_CurrentWSName, gViewer_Headless
    if (!payload.Has("meta"))
        return
    meta := payload["meta"]
    wsName := ""
    if (meta is Map) {
        wsName := meta.Has("currentWSName") ? meta["currentWSName"] : ""
    } else if (IsObject(meta)) {
        try wsName := meta.currentWSName
    }
    if (wsName != "" && wsName != gViewer_CurrentWSName) {
        gViewer_CurrentWSName := wsName
        if (!gViewer_Headless && IsObject(gViewer_CurrentWSLabel)) {
            gViewer_CurrentWSLabel.Text := wsName
        }
    }
    ; NOTE: Producer state is now obtained via IPC_MSG_PRODUCER_STATUS_REQUEST
    ; (no longer included in meta to reduce delta/snapshot bloat)
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

; Build ListView row values from a record
; Returns an array that can be passed to gViewer_LV.Add/Modify using splat operator (*)
_Viewer_BuildRowArgs(rec) {
    hwnd := _Viewer_Get(rec, "hwnd", 0)
    return [
        _Viewer_Get(rec, "z", ""),
        _Viewer_Get(rec, "lastActivatedTick", ""),
        "0x" Format("{:X}", hwnd),
        _Viewer_Get(rec, "pid", ""),
        _Viewer_Get(rec, "title", ""),
        _Viewer_Get(rec, "class", ""),
        _Viewer_Get(rec, "workspaceName", ""),
        _Viewer_Get(rec, "isOnCurrentWorkspace", 0) ? "1" : "0",
        _Viewer_Get(rec, "processName", ""),
        _Viewer_Get(rec, "isFocused", 0) ? "Y" : "",
        _Viewer_Get(rec, "isCloaked", 0) ? "Y" : "",
        _Viewer_Get(rec, "isMinimized", 0) ? "Y" : "",
        _Viewer_IconStr(_Viewer_Get(rec, "iconHicon", 0))
    ]
}

_Viewer_IconStr(hicon) {
    if (!hicon || hicon = 0) {
        return ""
    }
    return "0x" Format("{:X}", hicon)
}

_Viewer_StartStore() {
    global cfg
    storePath := A_ScriptDir "\..\store\store_server.ahk"
    runner := (cfg.AhkV2Path != "" && FileExist(cfg.AhkV2Path)) ? cfg.AhkV2Path : A_AhkPath
    ProcessUtils_RunHidden('"' runner '" "' storePath '"')
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
    ; Primary: Z-order (ascending, lower = closer to top)
    az := _Viewer_Get(a, "z", 0)
    bz := _Viewer_Get(b, "z", 0)
    if (az != bz)
        return (az < bz) ? -1 : 1
    ; Tie-breaker: MRU (descending, higher tick = more recent = first)
    at := _Viewer_Get(a, "lastActivatedTick", 0)
    bt := _Viewer_Get(b, "lastActivatedTick", 0)
    if (at != bt)
        return (at > bt) ? -1 : 1
    ; Final tie-breaker: hwnd for stability
    ah := _Viewer_Get(a, "hwnd", 0)
    bh := _Viewer_Get(b, "hwnd", 0)
    return (ah < bh) ? -1 : (ah > bh) ? 1 : 0
}

_Viewer_CmpMRU(a, b) {
    ; Primary: MRU (descending, higher tick = more recent = first)
    at := _Viewer_Get(a, "lastActivatedTick", 0)
    bt := _Viewer_Get(b, "lastActivatedTick", 0)
    if (at != bt)
        return (at > bt) ? -1 : 1
    ; Fallback for windows with no MRU data: use Z-order
    az := _Viewer_Get(a, "z", 0)
    bz := _Viewer_Get(b, "z", 0)
    if (az != bz)
        return (az < bz) ? -1 : 1
    ; Final tie-breaker: hwnd for stability
    ah := _Viewer_Get(a, "hwnd", 0)
    bh := _Viewer_Get(b, "hwnd", 0)
    return (ah < bh) ? -1 : (ah > bh) ? 1 : 0
}

; Handle double-click to blacklist a window
_Viewer_OnBlacklist(lv, row) {
    global gViewer_Client, gViewer_RecByHwnd, gViewer_RowByHwnd, IPC_MSG_RELOAD_BLACKLIST, gViewer_ShuttingDown

    if (gViewer_ShuttingDown || row = 0)
        return

    ; Find the hwnd for this row
    hwnd := 0
    for h, r in gViewer_RecByHwnd {
        if (gViewer_RowByHwnd.Has(h) && gViewer_RowByHwnd[h] = row) {
            hwnd := h
            break
        }
    }

    if (!hwnd || !gViewer_RecByHwnd.Has(hwnd))
        return

    rec := gViewer_RecByHwnd[hwnd]
    class := _Viewer_Get(rec, "class", "")
    title := _Viewer_Get(rec, "title", "")

    if (class = "" && title = "")
        return

    ; Show blacklist options dialog
    choice := _Viewer_ShowBlacklistDialog(class, title)
    if (choice = "")
        return

    ; Write to blacklist file based on choice
    success := false
    toastMsg := ""
    if (choice = "class") {
        success := Blacklist_AddClass(class)
        toastMsg := "Blacklisted class: " class
    } else if (choice = "title") {
        success := Blacklist_AddTitle(title)
        toastMsg := "Blacklisted title: " title
    } else if (choice = "pair") {
        success := Blacklist_AddPair(class, title)
        toastMsg := "Blacklisted pair: " class "|" title
    }

    if (!success) {
        _Viewer_ShowToast("Failed to write to blacklist.txt")
        return
    }

    ; Send reload message to store
    if (IsObject(gViewer_Client) && gViewer_Client.hPipe) {
        global gViewer_StoreWakeHwnd
        msg := { type: IPC_MSG_RELOAD_BLACKLIST }
        IPC_PipeClient_Send(gViewer_Client, JSON.Dump(msg), gViewer_StoreWakeHwnd)
    }

    _Viewer_ShowToast(toastMsg)
}

; Show dialog with blacklist options
_Viewer_ShowBlacklistDialog(class, title) {
    global gBlacklistChoice := "", gViewer_ShuttingDown
    if (gViewer_ShuttingDown)
        return ""

    dlg := Gui("+AlwaysOnTop +Owner", "Blacklist Window")
    dlg.MarginX := 24
    dlg.MarginY := 16
    dlg.SetFont("s10", "Segoe UI")

    dlg.AddText("w440", "Add to blacklist:")
    lblC := dlg.AddText("x24 w50 h20 y+12 +0x200", "Class:")
    lblC.SetFont("s10 bold", "Segoe UI")
    dlg.AddText("x78 yp w386 h20 +0x200", class)
    displayTitle := SubStr(title, 1, 50) (StrLen(title) > 50 ? "..." : "")
    lblT := dlg.AddText("x24 w50 h20 y+4 +0x200", "Title:")
    lblT.SetFont("s10 bold", "Segoe UI")
    dlg.AddText("x78 yp w386 h20 +0x200", displayTitle)

    ; Action buttons (left) + Cancel (right-aligned with gap)
    dlg.AddButton("x24 y+20 w100 h30", "Add Class").OnEvent("Click", (*) => _Viewer_BlacklistChoice(dlg, "class"))
    dlg.AddButton("x132 yp w100 h30", "Add Title").OnEvent("Click", (*) => _Viewer_BlacklistChoice(dlg, "title"))
    dlg.AddButton("x240 yp w100 h30", "Add Pair").OnEvent("Click", (*) => _Viewer_BlacklistChoice(dlg, "pair"))
    dlg.AddButton("x374 yp w90 h30", "Cancel").OnEvent("Click", (*) => _Viewer_BlacklistChoice(dlg, ""))

    dlg.OnEvent("Close", (*) => _Viewer_BlacklistChoice(dlg, ""))
    dlg.OnEvent("Escape", (*) => _Viewer_BlacklistChoice(dlg, ""))

    dlg.Show("w488 Center")

    ; Wait for dialog to close
    WinWaitClose(dlg)

    return gBlacklistChoice
}

_Viewer_BlacklistChoice(dlg, choice) {
    global gBlacklistChoice
    gBlacklistChoice := choice
    dlg.Destroy()
}

; Show a temporary toast notification
_Viewer_ShowToast(message) {
    global gViewer_Gui, TOOLTIP_DURATION_DEFAULT

    ; Create tooltip-style toast near the main window
    if (IsObject(gViewer_Gui)) {
        ToolTip(message)
        HideTooltipAfter(TOOLTIP_DURATION_DEFAULT)
    }
}

; PostMessage wake handler: store signals us after writing to the pipe
_Viewer_OnPipeWake(wParam, lParam, msg, hwnd) {
    global gViewer_Client
    if (IsObject(gViewer_Client) && gViewer_Client.hPipe)
        IPC__ClientTick(gViewer_Client)
    return 0
}

; OnExit wrapper for viewer cleanup
_Viewer_OnExitWrapper(reason, code) {
    _Viewer_Shutdown()
    return 0
}

; Auto-init only if running standalone or if mode is "viewer"
if (!IsSet(g_AltTabbyMode) || g_AltTabbyMode = "viewer") {  ; lint-ignore: isset-with-default
    Viewer_Init()
    OnExit(_Viewer_OnExitWrapper)
}
