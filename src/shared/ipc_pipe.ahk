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
    ; TODO: implement named pipe server with multi-subscriber support.
    return { pipeName: pipeName, onMessage: onMessageFn }
}

IPC_PipeServer_Stop(server) {
    ; TODO: cleanup handles.
}

IPC_PipeServer_Broadcast(server, msgText) {
    ; TODO: send msgText to all clients.
}

IPC_PipeClient_Connect(pipeName, onMessageFn) {
    ; TODO: connect and start read loop.
    return { pipeName: pipeName, onMessage: onMessageFn }
}

IPC_PipeClient_Send(client, msgText) {
    ; TODO: send msgText to server.
}

IPC_PipeClient_Close(client) {
    ; TODO: cleanup handles.
}