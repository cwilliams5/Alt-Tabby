#Requires AutoHotkey v2.0

; IPC helpers (v2 only). Stubbed for now; will be implemented with named pipes.

; Windows error codes
global IPC_ERROR_IO_PENDING := 997
global IPC_ERROR_BROKEN_PIPE := 109
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

; IPC Message Types and Timing Constants (shared with tests)
#Include %A_LineFile%\..\ipc_constants.ahk

; IPC Buffer Constants
global IPC_READ_CHUNK_SIZE := 65536       ; Max bytes to read per iteration
global IPC_BUFFER_OVERFLOW := 1048576     ; 1MB - max buffer before discard
global IPC_READ_BUF := Buffer(IPC_READ_CHUNK_SIZE)   ; Pre-allocated read buffer (reused across all reads)
global IPC_WRITE_BUF := Buffer(IPC_READ_CHUNK_SIZE)  ; Pre-allocated write buffer (reused when msg fits)

global IPC_DebugLogPath := ""

_IPC_IsLogEnabled() {
    global IPC_DebugLogPath, cfg
    return IPC_DebugLogPath || (IsSet(cfg) && IsObject(cfg) && cfg.HasOwnProp("DiagIPCLog") && cfg.DiagIPCLog)  ; lint-ignore: isset-with-default
}

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
    ; Reset log for new session (defensive cfg guard - cfg may not be initialized early)
    global LOG_PATH_IPC
    if (_IPC_IsLogEnabled())
        LogInitSession(LOG_PATH_IPC, "Alt-Tabby IPC Log")

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

; PostMessage wake: signal a peer process to check its pipe immediately.
; Safe for dead/stale hwnds (PostMessageW returns FALSE, no side effect).
; Safe during Critical "On" (messages queue, dispatch after Critical "Off").
_IPC_WakePeer(hwnd) {
    global IPC_WM_PIPE_WAKE
    if (hwnd)
        DllCall("user32\PostMessageW", "ptr", hwnd, "uint", IPC_WM_PIPE_WAKE, "ptr", 0, "ptr", 0)
}

IPC_PipeServer_Broadcast(server, msgText, wakeHwnds := 0) {
    if !IsObject(server)
        return 0
    if (!msgText || SubStr(msgText, -1) != "`n")
        msgText .= "`n"

    ; RACE FIX: Critical covers UTF-8 conversion + handle snapshot to protect
    ; IPC_WRITE_BUF from being overwritten by an interrupting IPC_PipeServer_Send call.
    ; Copy to a local buffer so we can release Critical before WriteFile calls.
    Critical "On"
    logEnabled := _IPC_IsLogEnabled()
    bytes := _IPC_StrToUtf8(msgText)
    ; Copy to local buffer since IPC_WRITE_BUF may be overwritten after Critical release
    localBuf := Buffer(bytes.len)
    DllCall("ntdll\RtlMoveMemory", "ptr", localBuf.Ptr, "ptr", bytes.buf.Ptr, "uint", bytes.len)
    localLen := bytes.len

    ; Snapshot handles atomically to prevent race with timer callback
    handles := []
    for hPipe, _ in server.clients
        handles.Push(hPipe)
    Critical "Off"

    ; Writes outside Critical — a blocked client only delays itself, not the message pump
    dead := []
    sent := 0
    for _, hPipe in handles {
        if (!_IPC_WritePipe(hPipe, localBuf, localLen)) {
            if (logEnabled)
                _IPC_Log("WritePipe failed during broadcast hPipe=" hPipe)
            dead.Push(hPipe)
        } else {
            sent += 1
        }
    }

    ; Wake all target clients after writes complete (before cleanup)
    if (IsObject(wakeHwnds)) {
        for _, wh in wakeHwnds
            _IPC_WakePeer(wh)
    }

    ; Cleanup dead handles under Critical (modifies server.clients)
    if (dead.Length > 0) {
        Critical "On"
        for _, h in dead {
            if (server.onDisconnect)
                try server.onDisconnect.Call(h)
            server.clients.Delete(h)
            _IPC_CloseHandle(h)
        }
        Critical "Off"
    }

    return sent
}

IPC_PipeServer_Send(server, hPipe, msgText, wakeHwnd := 0) {
    if !IsObject(server)
        return false
    ; RACE FIX: Wrap check-then-act + UTF-8 conversion in Critical to protect
    ; IPC_WRITE_BUF and server.clients. Copy buffer locally before release.
    Critical "On"
    if (!server.clients.Has(hPipe)) {
        Critical "Off"
        return false
    }
    if (!msgText || SubStr(msgText, -1) != "`n")
        msgText .= "`n"
    bytes := _IPC_StrToUtf8(msgText)
    ; Copy to local buffer since IPC_WRITE_BUF may be overwritten after Critical release
    localBuf := Buffer(bytes.len)
    DllCall("ntdll\RtlMoveMemory", "ptr", localBuf.Ptr, "ptr", bytes.buf.Ptr, "uint", bytes.len)
    localLen := bytes.len
    Critical "Off"

    ; Write outside Critical — a blocked client only delays the caller, not the message pump
    if (!_IPC_WritePipe(hPipe, localBuf, localLen)) {
        if (_IPC_IsLogEnabled())
            _IPC_Log("WritePipe failed during send hPipe=" hPipe)
        Critical "On"
        if (server.onDisconnect)
            try server.onDisconnect.Call(hPipe)
        server.clients.Delete(hPipe)
        _IPC_CloseHandle(hPipe)
        Critical "Off"
        return false
    }
    _IPC_WakePeer(wakeHwnd)
    return true
}

IPC_PipeClient_Connect(pipeName, onMessageFn, timeoutMs := 2000) {
    client := {
        pipeName: pipeName,
        onMessage: onMessageFn,
        hPipe: 0,
        buf: "",
        bufLen: 0,
        timerFn: 0,
        tickMs: 100,
        idleStreak: 0
    }
    h := _IPC_ClientConnect(pipeName, timeoutMs)
    if (!h)
        return client
    client.hPipe := h
    client.timerFn := IPC__ClientTick.Bind(client)
    SetTimer(client.timerFn, client.tickMs)
    return client
}

IPC_PipeClient_Send(client, msgText, wakeHwnd := 0) {
    if !IsObject(client)
        return false
    if (!client.hPipe)
        return false
    if (!msgText || SubStr(msgText, -1) != "`n")
        msgText .= "`n"
    ; RACE FIX: Protect global IPC_WRITE_BUF from concurrent access.
    ; Not all callers hold Critical (e.g., GUI_OnClick releases Critical
    ; before calling through to workspace toggle/blacklist reload).
    ; Copy to local buffer so WriteFile happens outside Critical.
    Critical "On"
    bytes := _IPC_StrToUtf8(msgText)
    localBuf := Buffer(bytes.len)
    DllCall("ntdll\RtlMoveMemory", "ptr", localBuf.Ptr, "ptr", bytes.buf.Ptr, "uint", bytes.len)
    localLen := bytes.len
    Critical "Off"

    result := _IPC_WritePipe(client.hPipe, localBuf, localLen)
    if (result)
        _IPC_WakePeer(wakeHwnd)
    return result
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
    global IPC_ERROR_IO_PENDING, IPC_ERROR_PIPE_CONNECTED
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
            server.clients[inst.hPipe] := { buf: "", bufLen: 0 }
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
IPC_CreateOpenSecurityAttrs() {
    global IPC_SECURITY_ATTRS_SIZE
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
    global IPC_READ_CHUNK_SIZE, IPC_OVERLAPPED_SIZE, IPC_OVERLAPPED_EVENT_OFFSET
    global IPC_ERROR_IO_PENDING, IPC_ERROR_PIPE_CONNECTED
    logEnabled := _IPC_IsLogEnabled()

    ; Create security attributes with NULL DACL to allow non-elevated processes
    ; to connect when we're running as administrator
    pSA := IPC_CreateOpenSecurityAttrs()

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
    if (!hPipe || hPipe = -1) {
        if (logEnabled)
            _IPC_Log("CreateNamedPipeW failed GLE=" DllCall("GetLastError", "uint") " pipe=" pipeName)
        return { hPipe: 0 }
    }
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
            if (logEnabled)
                _IPC_Log("ConnectNamedPipe unexpected GLE=" gle " hPipe=" hPipe)
            _IPC_CloseHandle(hEvent)
            _IPC_CloseHandle(hPipe)
            return { hPipe: 0 }
        }
    } else {
        connected := true
    }
    if (logEnabled)
        _IPC_Log("pipe_create hPipe=" hPipe " hEvent=" hEvent " pending=" pending " connected=" connected)
    return { hPipe: hPipe, hEvent: hEvent, over: over, pending: pending, connected: connected }
}

_IPC_CheckConnect(inst) {
    global IPC_WAIT_SINGLE_OBJ
    if (!inst.hPipe)
        return false
    if (inst.connected) {
        _IPC_CloseHandle(inst.hEvent)
        return true
    }
    if (inst.pending) {
        wait := DllCall("WaitForSingleObject", "ptr", inst.hEvent, "uint", IPC_WAIT_SINGLE_OBJ, "uint")
        if (wait = 0) { ; WAIT_OBJECT_0
            bytes := 0
            DllCall("GetOverlappedResult", "ptr", inst.hPipe, "ptr", inst.over.Ptr, "uint*", &bytes, "int", 1)
            inst.connected := true
            inst.pending := false
            _IPC_CloseHandle(inst.hEvent)
            if (_IPC_IsLogEnabled())
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
        if (IsSet(cfg) && IsObject(cfg) && cfg.HasOwnProp("DiagIPCLog") && cfg.DiagIPCLog)  ; lint-ignore: isset-with-default
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
    global IPC_WAIT_SINGLE_OBJ, IPC_ERROR_PIPE_BUSY, IPC_ERROR_FILE_NOT_FOUND, IPC_WAIT_PIPE_TIMEOUT, TIMING_PIPE_RETRY_WAIT
    logEnabled := _IPC_IsLogEnabled()
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
            if (logEnabled)
                _IPC_Log("pipe_client_connected hPipe=" hPipe)
            return hPipe
        }
        gle := DllCall("GetLastError", "uint")
        if (gle != IPC_ERROR_PIPE_BUSY && gle != IPC_ERROR_FILE_NOT_FOUND) {
            if (logEnabled)
                _IPC_Log("ClientConnect unexpected GLE=" gle " pipe=" pipeName)
            return 0
        }
        ; Non-blocking mode: single attempt, return immediately on failure
        if (timeoutMs <= 0)
            return 0
        if ((A_TickCount - start) > timeoutMs)
            return 0
        ; CRITICAL: WaitNamedPipeW returns immediately when pipe doesn't exist,
        ; creating a CPU-burning busy-wait that blocks the message queue and freezes
        ; keyboard/mouse input (low-level hooks can't be processed).
        ; Sleep pumps the AHK message queue, allowing hook callbacks to run.
        if (gle = IPC_ERROR_FILE_NOT_FOUND)
            Sleep(TIMING_PIPE_RETRY_WAIT)
        else
            DllCall("WaitNamedPipeW", "str", name, "uint", IPC_WAIT_PIPE_TIMEOUT)
    }
}

_IPC_ReadPipeLines(hPipe, stateObj, onMessageFn) {
    global IPC_READ_BUF, IPC_READ_CHUNK_SIZE, IPC_ERROR_MORE_DATA, IPC_BUFFER_OVERFLOW
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
    chunkLen := StrLen(chunk)

    ; Prevent unbounded buffer growth - O(1) check using tracked length
    if (stateObj.bufLen + chunkLen > IPC_BUFFER_OVERFLOW) {
        if (_IPC_IsLogEnabled())
            _IPC_Log("BUFFER OVERFLOW: client exceeded " IPC_BUFFER_OVERFLOW " bytes, disconnecting")
        stateObj.buf := ""
        stateObj.bufLen := 0
        return -1  ; Signal error - disconnect client
    }

    stateObj.buf .= chunk
    stateObj.bufLen += chunkLen

    _IPC_ParseLines(stateObj, onMessageFn, hPipe)
    return bytesRead
}

_IPC_ParseLines(stateObj, onMessageFn, hPipe := 0) {
    ; Offset-based parsing: track position instead of slicing per-message.
    ; Reduces from O(N) SubStr copies to O(1) final copy for N messages in a burst.
    offset := 1
    while true {
        pos := InStr(stateObj.buf, "`n", , offset)
        if (!pos)
            break
        line := SubStr(stateObj.buf, offset, pos - offset)
        offset := pos + 1
        if (SubStr(line, -1) = "`r")
            line := SubStr(line, 1, -1)
        if (line != "") {
            try onMessageFn.Call(line, hPipe)
            catch as e {
                if (_IPC_IsLogEnabled())
                    _IPC_Log("Message callback error: " e.Message " | line: " SubStr(line, 1, 100))
            }
        }
    }
    ; Single slice at end instead of per-message
    if (offset > 1) {
        stateObj.buf := SubStr(stateObj.buf, offset)
        stateObj.bufLen := StrLen(stateObj.buf)
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
    global IPC_WRITE_BUF, IPC_READ_CHUNK_SIZE
    ; Convert to UTF-8 buffer with exact length.
    ; Reuse pre-allocated write buffer when message fits (avoids heap alloc per send).
    ; Safe: IPC_PipeClient_Send wraps StrToUtf8+WritePipe in Critical "On".
    len := StrPut(str, "UTF-8") - 1
    if (len <= IPC_READ_CHUNK_SIZE) {
        StrPut(str, IPC_WRITE_BUF, "UTF-8")
        return { buf: IPC_WRITE_BUF, len: len }
    }
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
    global IPC_TICK_ACTIVE, IPC_TICK_SERVER_IDLE, IPC_TICK_IDLE, IPC_SERVER_IDLE_STREAK_THRESHOLD
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
    if (server.idleStreak >= IPC_SERVER_IDLE_STREAK_THRESHOLD)
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
    global IPC_TICK_ACTIVE, IPC_TICK_IDLE
    global IPC_COOLDOWN_PHASE1_TICKS, IPC_COOLDOWN_PHASE2_TICKS, IPC_COOLDOWN_PHASE3_TICKS
    global IPC_COOLDOWN_PHASE1_MS, IPC_COOLDOWN_PHASE2_MS
    if (activityBytes > 0) {
        client.idleStreak := 0
        IPC_SetClientTick(client, IPC_TICK_ACTIVE)
        return
    }
    ; Graduated cooldown: stay responsive during bursty activity (workspace switches,
    ; rapid Alt-Tab) then back off gradually to save CPU when truly idle.
    ; At 8ms ticks: 10 idle ticks = 80ms before first step-up.
    client.idleStreak += 1
    if (client.idleStreak < IPC_COOLDOWN_PHASE1_TICKS)
        return  ; Stay at current (active) tick
    if (client.idleStreak < IPC_COOLDOWN_PHASE2_TICKS)
        IPC_SetClientTick(client, IPC_COOLDOWN_PHASE1_MS)
    else if (client.idleStreak < IPC_COOLDOWN_PHASE3_TICKS)
        IPC_SetClientTick(client, IPC_COOLDOWN_PHASE2_MS)
    else
        IPC_SetClientTick(client, IPC_TICK_IDLE)
}

IPC_SetClientTick(client, ms) {
    if (client.tickMs = ms)
        return
    client.tickMs := ms
    if (client.timerFn)
        SetTimer(client.timerFn, client.tickMs)
}
