#Requires AutoHotkey v2.0

; IPC helpers (v2 only). Stubbed for now; will be implemented with named pipes.

IPC_MSG_HELLO := "hello"
IPC_MSG_HELLO_ACK := "hello_ack"
IPC_MSG_SNAPSHOT_REQUEST := "snapshot_request"
IPC_MSG_SNAPSHOT := "snapshot"
IPC_MSG_DELTA := "delta"
IPC_MSG_PROJECTION_REQUEST := "projection_request"
IPC_MSG_PROJECTION := "projection"
IPC_MSG_SET_PROJECTION_OPTS := "set_projection_opts"
IPC_MSG_PING := "ping"
IPC_MSG_ERROR := "error"

global IPC_DebugLogPath := ""

IPC_DefaultProjectionOpts() {
    return {
        currentWorkspaceOnly: false,
        includeMinimized: true,
        includeCloaked: false,
        blacklistMode: "exclude",
        sort: "MRU",
        columns: "items"
    }
}

IPC_PipeServer_Start(pipeName, onMessageFn) {
    server := {
        pipeName: pipeName,
        onMessage: onMessageFn,
        pending: [],
        clients: Map(),   ; hPipe -> { buf: "" }
        timerFn: 0,
        tickMs: 100,
        idleStreak: 0
    }
    _IPC_Server_AddPending(server)
    server.timerFn := IPC__ServerTick.Bind(server)
    SetTimer(server.timerFn, server.tickMs)
    return server
}

IPC_PipeServer_Stop(server) {
    if !IsObject(server)
        return
    if (server.timerFn)
        SetTimer(server.timerFn, 0)
    for _, inst in server.pending
        _IPC_ClosePipeInstance(inst)
    for hPipe, _ in server.clients
        _IPC_CloseHandle(hPipe)
    server.pending := []
    server.clients := Map()
}

IPC_PipeServer_Broadcast(server, msgText) {
    if !IsObject(server)
        return 0
    if (!msgText || SubStr(msgText, -1) != "`n")
        msgText .= "`n"
    bytes := _IPC_StrToUtf8(msgText)
    buf := bytes.buf
    len := bytes.len
    dead := []
    sent := 0
    for hPipe, _ in server.clients {
        if (!_IPC_WritePipe(hPipe, buf, len))
            dead.Push(hPipe)
        else
            sent += 1
    }
    for _, h in dead {
        server.clients.Delete(h)
        _IPC_CloseHandle(h)
    }
    return sent
}

IPC_PipeServer_Send(server, hPipe, msgText) {
    if !IsObject(server)
        return false
    if (!server.clients.Has(hPipe))
        return false
    if (!msgText || SubStr(msgText, -1) != "`n")
        msgText .= "`n"
    bytes := _IPC_StrToUtf8(msgText)
    if (!_IPC_WritePipe(hPipe, bytes.buf, bytes.len)) {
        server.clients.Delete(hPipe)
        _IPC_CloseHandle(hPipe)
        return false
    }
    return true
}

IPC_PipeClient_Connect(pipeName, onMessageFn) {
    client := {
        pipeName: pipeName,
        onMessage: onMessageFn,
        hPipe: 0,
        buf: "",
        timerFn: 0,
        tickMs: 100
    }
    h := _IPC_ClientConnect(pipeName, 2000)
    if (!h)
        return client
    client.hPipe := h
    client.timerFn := IPC__ClientTick.Bind(client)
    SetTimer(client.timerFn, client.tickMs)
    return client
}

IPC_PipeClient_Send(client, msgText) {
    if !IsObject(client)
        return false
    if (!client.hPipe)
        return false
    if (!msgText || SubStr(msgText, -1) != "`n")
        msgText .= "`n"
    bytes := _IPC_StrToUtf8(msgText)
    return _IPC_WritePipe(client.hPipe, bytes.buf, bytes.len)
}

IPC_PipeClient_Close(client) {
    if !IsObject(client)
        return
    if (client.timerFn)
        SetTimer(client.timerFn, 0)
    if (client.hPipe) {
        _IPC_CloseHandle(client.hPipe)
        client.hPipe := 0
    }
}

; ============================ Server internals =============================

IPC__ServerTick(server) {
    ; Check pending pipe instances for connections, read from clients.
    _IPC_Server_AcceptPending(server)
    activity := _IPC_Server_ReadClients(server)
    _IPC_Server_AdjustTimer(server, activity)
}

_IPC_Server_AddPending(server) {
    inst := _IPC_CreatePipeInstance(server.pipeName)
    if (inst.hPipe)
        server.pending.Push(inst)
}

_IPC_Server_AcceptPending(server) {
    connected := []
    for idx, inst in server.pending {
        if (_IPC_CheckConnect(inst)) {
            server.clients[inst.hPipe] := { buf: "" }
            connected.Push(idx)
            _IPC_Server_AddPending(server)
        }
    }
    ; remove connected instances from pending list (reverse order)
    Loop connected.Length {
        i := connected[connected.Length - A_Index + 1]
        server.pending.RemoveAt(i)
    }
}

_IPC_Server_ReadClients(server) {
    dead := []
    activity := 0
    for hPipe, state in server.clients {
        readStatus := _IPC_ReadPipeLines(hPipe, state, server.onMessage)
        if (readStatus < 0)
            dead.Push(hPipe)
        else if (readStatus > 0)
            activity += readStatus
    }
    for _, h in dead {
        server.clients.Delete(h)
        _IPC_CloseHandle(h)
    }
    return activity
}

; ============================ Client internals =============================

IPC__ClientTick(client) {
    if (!client.hPipe)
        return
    readStatus := _IPC_ReadPipeLines(client.hPipe, client, client.onMessage)
    if (readStatus < 0) {
        _IPC_CloseHandle(client.hPipe)
        client.hPipe := 0
        if (client.timerFn)
            SetTimer(client.timerFn, 0)
        return
    }
    _IPC_Client_AdjustTimer(client, readStatus)
}

; ============================== Pipe helpers ===============================

_IPC_CreatePipeInstance(pipeName) {
    PIPE_ACCESS_DUPLEX := 0x00000003
    FILE_FLAG_OVERLAPPED := 0x40000000
    PIPE_TYPE_MESSAGE := 0x00000004
    PIPE_READMODE_MESSAGE := 0x00000002
    PIPE_WAIT := 0x00000000
    hPipe := DllCall("CreateNamedPipeW"
        , "str", "\\.\pipe\" pipeName
        , "uint", PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED
        , "uint", PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT
        , "uint", 255
        , "uint", 65536
        , "uint", 65536
        , "uint", 0
        , "ptr", 0
        , "ptr")
    if (!hPipe || hPipe = -1)
        return { hPipe: 0 }
    hEvent := DllCall("CreateEventW", "ptr", 0, "int", 1, "int", 0, "ptr", 0, "ptr")
    if (!hEvent) {
        _IPC_CloseHandle(hPipe)
        return { hPipe: 0 }
    }
    over := Buffer(A_PtrSize=8 ? 32 : 20, 0)
    NumPut("ptr", hEvent, over, (A_PtrSize=8) ? 24 : 16)
    ok := DllCall("ConnectNamedPipe", "ptr", hPipe, "ptr", over.Ptr, "int")
    pending := false
    connected := false
    if (!ok) {
        gle := DllCall("GetLastError", "uint")
        if (gle = 997) {
            pending := true
        } else if (gle = 535) {
            connected := true
        } else {
            _IPC_CloseHandle(hEvent)
            _IPC_CloseHandle(hPipe)
            return { hPipe: 0 }
        }
    } else {
        connected := true
    }
    _IPC_Log("pipe_create hPipe=" hPipe " hEvent=" hEvent " pending=" pending " connected=" connected)
    return { hPipe: hPipe, hEvent: hEvent, over: over, pending: pending, connected: connected }
}

_IPC_CheckConnect(inst) {
    if (!inst.hPipe)
        return false
    if (inst.connected)
        return true
    if (inst.pending) {
        wait := DllCall("WaitForSingleObject", "ptr", inst.hEvent, "uint", 1, "uint")
        if (wait = 0) { ; WAIT_OBJECT_0
            bytes := 0
            DllCall("GetOverlappedResult", "ptr", inst.hPipe, "ptr", inst.over.Ptr, "uint*", &bytes, "int", 1)
            inst.connected := true
            inst.pending := false
            _IPC_CloseHandle(inst.hEvent)
            _IPC_Log("pipe_connected hPipe=" inst.hPipe)
            return true
        }
        return false
    }
    return false
}

_IPC_Log(msg) {
    global IPC_DebugLogPath
    if (!IPC_DebugLogPath)
        return
    try FileAppend(msg "`n", IPC_DebugLogPath, "UTF-8")
}

_IPC_ClosePipeInstance(inst) {
    if (IsObject(inst)) {
        if (inst.hEvent)
            _IPC_CloseHandle(inst.hEvent)
        if (inst.hPipe)
            _IPC_CloseHandle(inst.hPipe)
    }
}

_IPC_ClientConnect(pipeName, timeoutMs := 2000) {
    name := "\\.\pipe\" pipeName
    start := A_TickCount
    loop {
        hPipe := DllCall("CreateFileW"
            , "str", name
            , "uint", 0xC0000000 ; GENERIC_READ|GENERIC_WRITE
            , "uint", 0
            , "ptr", 0
            , "uint", 3
            , "uint", 0
            , "ptr", 0
            , "ptr")
        if (hPipe && hPipe != -1)
        {
            mode := 0x00000002 ; PIPE_READMODE_MESSAGE
            DllCall("SetNamedPipeHandleState", "ptr", hPipe, "uint*", &mode, "ptr", 0, "ptr", 0)
            _IPC_Log("pipe_client_connected hPipe=" hPipe)
            return hPipe
        }
        gle := DllCall("GetLastError", "uint")
        if (gle != 231 && gle != 2) ; ERROR_PIPE_BUSY or ERROR_FILE_NOT_FOUND
            return 0
        if ((A_TickCount - start) > timeoutMs)
            return 0
        DllCall("WaitNamedPipeW", "str", name, "uint", 200)
    }
}

_IPC_ReadPipeLines(hPipe, stateObj, onMessageFn) {
    avail := _IPC_PeekAvailable(hPipe)
    if (avail < 0)
        return -1
    if (avail = 0)
        return 0
    toRead := Min(avail, 65536)
    buf := Buffer(toRead)
    bytesRead := 0
    ok := DllCall("ReadFile", "ptr", hPipe, "ptr", buf.Ptr, "uint", toRead, "uint*", &bytesRead, "ptr", 0)
    if (!ok) {
        gle := DllCall("GetLastError", "uint")
        if (gle = 234) ; ERROR_MORE_DATA
            return 0
        return -1
    }
    if (bytesRead <= 0)
        return 0
    chunk := StrGet(buf.Ptr, bytesRead, "UTF-8")
    stateObj.buf .= chunk
    _IPC_ParseLines(stateObj, onMessageFn, hPipe)
    return bytesRead
}

_IPC_ParseLines(stateObj, onMessageFn, hPipe := 0) {
    while true {
        pos := InStr(stateObj.buf, "`n")
        if (!pos)
            break
        line := SubStr(stateObj.buf, 1, pos - 1)
        stateObj.buf := SubStr(stateObj.buf, pos + 1)
        if (SubStr(line, -1) = "`r")
            line := SubStr(line, 1, -1)
        if (line != "") {
            try onMessageFn.Call(line, hPipe)
            catch {
            }
        }
    }
}

_IPC_PeekAvailable(hPipe) {
    bytesAvail := 0
    ok := DllCall("PeekNamedPipe", "ptr", hPipe, "ptr", 0, "uint", 0, "uint*", 0, "uint*", &bytesAvail, "uint*", 0)
    if (!ok)
        return -1
    return bytesAvail
}

_IPC_WritePipe(hPipe, bufPtr, len) {
    wrote := 0
    ok := DllCall("WriteFile", "ptr", hPipe, "ptr", bufPtr, "uint", len, "uint*", &wrote, "ptr", 0)
    return ok && (wrote = len)
}

_IPC_StrToUtf8(str) {
    ; Convert to UTF-8 buffer with exact length.
    len := StrPut(str, "UTF-8") - 1
    buf := Buffer(len)
    StrPut(str, buf, "UTF-8")
    return { buf: buf, len: len }
}

_IPC_CloseHandle(h) {
    if (h && h != -1)
        DllCall("CloseHandle", "ptr", h)
}

; ============================== Timer policy ===============================

_IPC_Server_AdjustTimer(server, activityBytes) {
    ; Keep CPU low: slow tick when idle, speed up when active.
    if (activityBytes > 0) {
        server.idleStreak := 0
        _IPC_SetServerTick(server, 15)
        return
    }
    if (server.clients.Count = 0) {
        _IPC_SetServerTick(server, 250)
        return
    }
    server.idleStreak += 1
    if (server.idleStreak >= 8)
        _IPC_SetServerTick(server, 100)
}

_IPC_SetServerTick(server, ms) {
    if (server.tickMs = ms)
        return
    server.tickMs := ms
    if (server.timerFn)
        SetTimer(server.timerFn, server.tickMs)
}

_IPC_Client_AdjustTimer(client, activityBytes) {
    if (activityBytes > 0) {
        _IPC_SetClientTick(client, 15)
        return
    }
    _IPC_SetClientTick(client, 100)
}

_IPC_SetClientTick(client, ms) {
    if (client.tickMs = ms)
        return
    client.tickMs := ms
    if (client.timerFn)
        SetTimer(client.timerFn, client.tickMs)
}
