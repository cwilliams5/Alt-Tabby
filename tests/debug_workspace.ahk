#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn VarUnset, Off

; Debug script to check if workspace data flows through the store
; Logs to file instead of popups

#Include %A_ScriptDir%\..\src\shared\config.ahk
#Include %A_ScriptDir%\..\src\shared\cjson.ahk
#Include %A_ScriptDir%\..\src\shared\ipc_pipe.ahk

global gDebugResponse := ""
global gDebugReceived := false
global IPC_MSG_HELLO, IPC_MSG_PROJECTION_REQUEST

global LogPath := A_Temp "\workspace_debug.log"
try FileDelete(LogPath)

Log(msg) {
    global LogPath
    FileAppend(FormatTime(, "HH:mm:ss") " " msg "`n", LogPath, "UTF-8")
}

Log("=== Workspace Data Debug ===")
Log("KomorebicExe path: " KomorebicExe)
Log("KomorebicExe exists: " (FileExist(KomorebicExe) ? "YES" : "NO"))

; Connect to the running store
Log("Connecting to store pipe: " StorePipeName)
client := IPC_PipeClient_Connect(StorePipeName, Debug_OnMessage)

if (!client.hPipe) {
    Log("FAIL: Could not connect to store. Is store_server running?")
    ExitApp(1)
}

Log("Connected to store")

; Send hello
helloMsg := { type: IPC_MSG_HELLO, clientId: "debug", wants: { deltas: false } }
IPC_PipeClient_Send(client, JSON.Dump(helloMsg))
Log("Sent hello")

Sleep(200)

; Send projection request
projMsg := { type: IPC_MSG_PROJECTION_REQUEST, projectionOpts: { sort: "Z", columns: "items", includeMinimized: true, includeCloaked: true } }
IPC_PipeClient_Send(client, JSON.Dump(projMsg))
Log("Sent projection request")

; Wait for response
waitStart := A_TickCount
while (!gDebugReceived && (A_TickCount - waitStart) < 5000) {
    Sleep(100)
}

if (!gDebugReceived) {
    Log("FAIL: No response from store")
    ExitApp(1)
}

; Parse and analyze response
Log("")
Log("=== Analyzing Response ===")

try {
    resp := JSON.Load(gDebugResponse)
    if (!resp.Has("payload") || !resp["payload"].Has("items")) {
        Log("FAIL: Response missing payload/items")
        ExitApp(1)
    }

    items := resp["payload"]["items"]
    Log("Total items: " items.Length)

    ; Analyze workspace data
    hasWorkspace := 0
    hasCloaked := 0
    workspaces := Map()

    for _, item in items {
        wsName := item.Has("workspaceName") ? item["workspaceName"] : ""
        isCloaked := item.Has("isCloaked") ? item["isCloaked"] : false
        title := item.Has("title") ? item["title"] : ""
        hwnd := item.Has("hwnd") ? item["hwnd"] : 0

        if (wsName != "") {
            hasWorkspace++
            if (!workspaces.Has(wsName))
                workspaces[wsName] := 0
            workspaces[wsName]++
        }
        if (isCloaked)
            hasCloaked++

        ; Log all items
        Log("  [" A_Index "] hwnd=" hwnd " ws='" wsName "' cloaked=" isCloaked " title=" SubStr(title, 1, 50))
    }

    Log("")
    Log("=== Summary ===")
    Log("Items with workspaceName: " hasWorkspace "/" items.Length)
    Log("Items with isCloaked=true: " hasCloaked "/" items.Length)

    if (workspaces.Count > 0) {
        Log("")
        Log("Workspaces found:")
        for ws, count in workspaces
            Log("  " ws ": " count " windows")
        Log("")
        Log("SUCCESS: Workspace data is flowing!")
    } else {
        Log("")
        Log("*** FAIL: NO WORKSPACE DATA IN STORE ***")
        Log("Komorebi producer is not updating WindowStore")
    }

} catch as e {
    Log("FAIL: Parse error: " e.Message)
}

IPC_PipeClient_Close(client)
Log("")
Log("Log file: " LogPath)
ExitApp(0)

Debug_OnMessage(line, hPipe := 0) {
    global gDebugResponse, gDebugReceived
    Log("Received message type: " SubStr(line, 1, 50))
    if (InStr(line, '"type":"projection"') || InStr(line, '"type":"snapshot"')) {
        gDebugResponse := line
        gDebugReceived := true
    }
}
