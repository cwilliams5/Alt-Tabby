#Requires AutoHotkey v2.0

; IPC helpers (v2 only). Stubbed for now; will be implemented with named pipes.

; Windows error codes
global IPC_ERROR_IO_PENDING := 997
global IPC_ERROR_PIPE_CONNECTED := 535
global IPC_ERROR_PIPE_BUSY := 231
global IPC_ERROR_FILE_NOT_FOUND := 2
global IPC_ERROR_MORE_DATA := 234

; Structure sizes (platform-dependent)
global IPC_OVERLAPPED_SIZE := (A_PtrSize = 8) ? 32 : 20
global IPC_OVERLAPPED_EVENT_OFFSET := (A_PtrSize = 8) ? 24 : 16
global IPC_SECURITY_ATTRS_SIZE := (A_PtrSize = 8) ? 24 : 12

; Pipe creation constants
global IPC_PIPE_ACCESS_DUPLEX := 0x00000003
global IPC_FILE_FLAG_OVERLAPPED := 0x40000000
global IPC_PIPE_TYPE_MESSAGE := 0x00000004
global IPC_PIPE_READMODE_MESSAGE := 0x00000002
global IPC_PIPE_WAIT := 0x00000000

; IPC Message Types
global IPC_MSG_HELLO := "hello"
global IPC_MSG_HELLO_ACK := "hello_ack"
global IPC_MSG_SNAPSHOT_REQUEST := "snapshot_request"
global IPC_MSG_SNAPSHOT := "snapshot"
global IPC_MSG_DELTA := "delta"
global IPC_MSG_PROJECTION_REQUEST := "projection_request"
global IPC_MSG_PROJECTION := "projection"
global IPC_MSG_SET_PROJECTION_OPTS := "set_projection_opts"
global IPC_MSG_PING := "ping"
global IPC_MSG_ERROR := "error"
global IPC_MSG_RELOAD_BLACKLIST := "reload_blacklist"
global IPC_MSG_HEARTBEAT := "heartbeat"
global IPC_MSG_PRODUCER_STATUS_REQUEST := "producer_status_request"
global IPC_MSG_PRODUCER_STATUS := "producer_status"

; IPC Timing Constants (milliseconds)
global IPC_TICK_ACTIVE := 15        ; Server/client tick when active (messages pending)
global IPC_TICK_IDLE := 100         ; Client tick when no activity (overridable via cfg.IPCIdleTickMs)
global IPC_TICK_SERVER_IDLE := 250  ; Server tick when no clients connected
global IPC_WAIT_PIPE_TIMEOUT := 200 ; WaitNamedPipe timeout for client connect
global IPC_WAIT_SINGLE_OBJ := 1     ; WaitForSingleObject timeout (busy poll)

; IPC Buffer Constants
global IPC_READ_CHUNK_SIZE := 65536       ; Max bytes to read per iteration
global IPC_BUFFER_OVERFLOW := 1048576     ; 1MB - max buffer before discard
global IPC_READ_BUF := Buffer(IPC_READ_CHUNK_SIZE)  ; Pre-allocated read buffer (reused across all reads)

global IPC_DebugLogPath := ""

IPC_DefaultProjectionOpts() {
    return {
        currentWorkspaceOnly: false,
        includeMinimized: true,
        includeCloaked: false,
        sort: "MRU",
        columns: "items"
    }
}

IPC_PipeServer_Start(pipeName, onMessageFn, onDisconnectFn := 0) {
    server := {
        pipeName: pipeName,
        onMessage: onMessageFn,
        onDisconnect: onDisconnectFn,  ; Called when a client disconnects (hPipe passed)
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

    ; Snapshot handles atomically to prevent race with timer callback
    Critical "On"
    handles := []
    for hPipe, _ in server.clients
        handles.Push(hPipe)
    Critical "Off"

    dead := []
    sent := 0
    for _, hPipe in handles {
        if (!_IPC_WritePipe(hPipe, buf, len))
            dead.Push(hPipe)
        else
            sent += 1
    }

    ; Cleanup dead handles atomically
    Critical "On"
    for _, h in dead {
        server.clients.Delete(h)
        _IPC_CloseHandle(h)
    }
    Critical "Off"

    return sent
}

IPC_PipeServer_Send(server, hPipe, msgText) {
    if !IsObject(server)
        return false
    ; RACE FIX: Wrap check-then-act in Critical to prevent concurrent modification
    ; of server.clients between Has() check and Delete() on failure
    Critical "On"
    if (!server.clients.Has(hPipe)) {
        Critical "Off"
        return false
    }
    if (!msgText || SubStr(msgText, -1) != "`n")
        msgText .= "`n"
    bytes := _IPC_StrToUtf8(msgText)
    if (!_IPC_WritePipe(hPipe, bytes.buf, bytes.len)) {
        server.clients.Delete(hPipe)
        _IPC_CloseHandle(hPipe)
        Critical "Off"
        return false
    }
    Critical "Off"
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
    ; Wrap in Critical to prevent race conditions with Broadcast
    Critical "On"
    try {
        ; Check pending pipe instances for connections, read from clients.
        _IPC_Server_AcceptPending(server)
        activity := _IPC_Server_ReadClients(server)
        _IPC_Server_AdjustTimer(server, activity)
    }
    Critical "Off"
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
            ; DON'T call _IPC_Server_AddPending here - modifies array during iteration!
        }
    }
    ; Remove connected instances from pending list (reverse order)
    Loop connected.Length {
        i := connected[connected.Length - A_Index + 1]
        server.pending.RemoveAt(i)
    }
    ; Add new pending instances AFTER iteration completes
    ; (one new instance per connected client to maintain pending pool)
    Loop connected.Length {
        _IPC_Server_AddPending(server)
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
        ; Call onDisconnect callback before cleanup (allows tracking map cleanup)
        if (server.onDisconnect)
            try server.onDisconnect.Call(h)
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

; Create SECURITY_ATTRIBUTES with NULL DACL to allow non-elevated processes to connect
; This is needed when running as administrator - otherwise non-elevated clients can't connect
_IPC_CreateOpenSecurityAttrs() {
    ; Use static buffers so they persist for the lifetime of the pipe
    static pSD := 0
    static pSA := 0

    ; SECURITY_DESCRIPTOR size: 20 bytes (32-bit) or 40 bytes (64-bit)
    ; Using 40 to be safe
    if (!pSD) {
        pSD := Buffer(40, 0)

        ; Initialize security descriptor
        ; SECURITY_DESCRIPTOR_REVISION = 1
        ok := DllCall("advapi32\InitializeSecurityDescriptor"
            , "ptr", pSD.Ptr
            , "uint", 1  ; SECURITY_DESCRIPTOR_REVISION
            , "int")

        if (!ok)
            return 0

        ; Set NULL DACL (grants full access to everyone)
        ; SetSecurityDescriptorDacl(pSD, bDaclPresent=TRUE, pDacl=NULL, bDaclDefaulted=FALSE)
        ok := DllCall("advapi32\SetSecurityDescriptorDacl"
            , "ptr", pSD.Ptr
            , "int", 1    ; bDaclPresent = TRUE (DACL is present)
            , "ptr", 0    ; pDacl = NULL (NULL DACL = allow all access)
            , "int", 0    ; bDaclDefaulted = FALSE
            , "int")

        if (!ok)
            return 0
    }

    ; Create SECURITY_ATTRIBUTES structure
    ; struct SECURITY_ATTRIBUTES {
    ;   DWORD  nLength;              // offset 0, size 4
    ;   LPVOID lpSecurityDescriptor; // offset 4 (32-bit) or 8 (64-bit), size 4/8
    ;   BOOL   bInheritHandle;       // offset 8 (32-bit) or 16 (64-bit), size 4
    ; }
    if (!pSA) {
        saSize := IPC_SECURITY_ATTRS_SIZE
        pSA := Buffer(saSize, 0)

        ; nLength
        NumPut("uint", saSize, pSA, 0)
        ; lpSecurityDescriptor (at offset A_PtrSize due to alignment)
        NumPut("ptr", pSD.Ptr, pSA, A_PtrSize)
        ; bInheritHandle (at offset A_PtrSize + A_PtrSize)
        NumPut("int", 0, pSA, A_PtrSize * 2)
    }

    return pSA.Ptr
}

_IPC_CreatePipeInstance(pipeName) {
    global IPC_PIPE_ACCESS_DUPLEX, IPC_FILE_FLAG_OVERLAPPED
    global IPC_PIPE_TYPE_MESSAGE, IPC_PIPE_READMODE_MESSAGE, IPC_PIPE_WAIT

    ; Create security attributes with NULL DACL to allow non-elevated processes
    ; to connect when we're running as administrator
    pSA := _IPC_CreateOpenSecurityAttrs()

    hPipe := DllCall("CreateNamedPipeW"
        , "str", "\\.\pipe\" pipeName
        , "uint", IPC_PIPE_ACCESS_DUPLEX | IPC_FILE_FLAG_OVERLAPPED
        , "uint", IPC_PIPE_TYPE_MESSAGE | IPC_PIPE_READMODE_MESSAGE | IPC_PIPE_WAIT
        , "uint", 255
        , "uint", IPC_READ_CHUNK_SIZE   ; output buffer size
        , "uint", IPC_READ_CHUNK_SIZE   ; input buffer size
        , "uint", 0
        , "ptr", pSA   ; security attrs (NULL DACL = allow all)
        , "ptr")
    if (!hPipe || hPipe = -1)
        return { hPipe: 0 }
    hEvent := DllCall("CreateEventW", "ptr", 0, "int", 1, "int", 0, "ptr", 0, "ptr")
    if (!hEvent) {
        _IPC_CloseHandle(hPipe)
        return { hPipe: 0 }
    }
    over := Buffer(IPC_OVERLAPPED_SIZE, 0)
    NumPut("ptr", hEvent, over, IPC_OVERLAPPED_EVENT_OFFSET)
    ok := DllCall("ConnectNamedPipe", "ptr", hPipe, "ptr", over.Ptr, "int")
    pending := false
    connected := false
    if (!ok) {
        gle := DllCall("GetLastError", "uint")
        if (gle = IPC_ERROR_IO_PENDING) {
            pending := true
        } else if (gle = IPC_ERROR_PIPE_CONNECTED) {
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
        wait := DllCall("WaitForSingleObject", "ptr", inst.hEvent, "uint", IPC_WAIT_SINGLE_OBJ, "uint")
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
    global IPC_DebugLogPath, cfg, LOG_PATH_IPC
    ; Use explicit path if set (test mode), otherwise check config flag
    logPath := IPC_DebugLogPath
    if (!logPath) {
        ; Check config flag - cfg may not be initialized early in startup
        if (IsSet(cfg) && IsObject(cfg) && cfg.HasOwnProp("DiagIPCLog") && cfg.DiagIPCLog)
            logPath := LOG_PATH_IPC
        else
            return
    }
    try {
        ts := GetLogTimestamp()
        FileAppend(ts " " msg "`n", logPath, "UTF-8")
    }
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
        if (gle != IPC_ERROR_PIPE_BUSY && gle != IPC_ERROR_FILE_NOT_FOUND)
            return 0
        if ((A_TickCount - start) > timeoutMs)
            return 0
        DllCall("WaitNamedPipeW", "str", name, "uint", IPC_WAIT_PIPE_TIMEOUT)
    }
}

_IPC_ReadPipeLines(hPipe, stateObj, onMessageFn) {
    global IPC_READ_BUF
    avail := _IPC_PeekAvailable(hPipe)
    if (avail < 0)
        return -1
    if (avail = 0)
        return 0
    toRead := Min(avail, IPC_READ_CHUNK_SIZE)
    bytesRead := 0
    ok := DllCall("ReadFile", "ptr", hPipe, "ptr", IPC_READ_BUF.Ptr, "uint", toRead, "uint*", &bytesRead, "ptr", 0)
    if (!ok) {
        gle := DllCall("GetLastError", "uint")
        if (gle = IPC_ERROR_MORE_DATA)
            return 0
        return -1
    }
    if (bytesRead <= 0)
        return 0
    chunk := StrGet(IPC_READ_BUF.Ptr, bytesRead, "UTF-8")
    stateObj.buf .= chunk

    ; Prevent unbounded buffer growth - protects against malformed clients
    if (StrLen(stateObj.buf) > IPC_BUFFER_OVERFLOW) {
        stateObj.buf := ""
        return -1  ; Signal error - disconnect client
    }

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
            catch as e {
                _IPC_Log("Message callback error: " e.Message " | line: " SubStr(line, 1, 100))
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
        _IPC_SetServerTick(server, IPC_TICK_ACTIVE)
        return
    }
    if (server.clients.Count = 0) {
        _IPC_SetServerTick(server, IPC_TICK_SERVER_IDLE)
        return
    }
    server.idleStreak += 1
    if (server.idleStreak >= 8)
        _IPC_SetServerTick(server, IPC_TICK_IDLE)
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
        _IPC_SetClientTick(client, IPC_TICK_ACTIVE)
        return
    }
    _IPC_SetClientTick(client, IPC_TICK_IDLE)
}

_IPC_SetClientTick(client, ms) {
    if (client.tickMs = ms)
        return
    client.tickMs := ms
    if (client.timerFn)
        SetTimer(client.timerFn, client.tickMs)
}
