; Test Utilities - Logging, assertions, and IPC callbacks
; Included by run_tests.ahk

; --- Test Helpers ---

Log(msg) {
    global TestLogPath
    FileAppend(msg "`n", TestLogPath, "UTF-8")
}

AssertEq(actual, expected, name) {
    global TestErrors, TestPassed
    if (actual = expected) {
        Log("PASS: " name)
        TestPassed++
    } else {
        Log("FAIL: " name " - expected '" expected "', got '" actual "'")
        TestErrors++
    }
}

AssertTrue(condition, name) {
    global TestErrors, TestPassed
    if (condition) {
        Log("PASS: " name)
        TestPassed++
    } else {
        Log("FAIL: " name)
        TestErrors++
    }
}

_ArrayJoin(arr, sep := ", ") {
    out := ""
    for i, v in arr {
        if (i > 1)
            out .= sep
        out .= v
    }
    return out
}

; --- IPC Test Callbacks ---

Test_OnServerMessage(line, hPipe := 0) {
    global testServer
    ; Handle incoming requests like the real store
    Log("  [IPC] Server received: " SubStr(line, 1, 80))
    obj := ""
    try {
        obj := JSON.Load(line)
    } catch as e {
        Log("  [IPC] Parse error: " e.Message)
        return
    }
    if (!IsObject(obj) || !obj.Has("type")) {
        Log("  [IPC] Invalid message format")
        return
    }
    type := obj["type"]
    Log("  [IPC] Message type: " type)
    if (type = IPC_MSG_PROJECTION_REQUEST || type = IPC_MSG_SNAPSHOT_REQUEST) {
        ; Get projection from current WindowStore state
        opts := obj.Has("projectionOpts") ? obj["projectionOpts"] : { sort: "Z" }
        proj := WindowStore_GetProjection(opts)
        respType := (type = IPC_MSG_SNAPSHOT_REQUEST) ? IPC_MSG_SNAPSHOT : IPC_MSG_PROJECTION
        resp := {
            type: respType,
            rev: proj.rev,
            payload: { meta: proj.meta, items: proj.HasOwnProp("items") ? proj.items : [] }
        }
        ; Send response
        respJson := JSON.Dump(resp)
        Log("  [IPC] Sending response: " SubStr(respJson, 1, 80) "...")
        IPC_PipeServer_Send(testServer, hPipe, respJson)
    }
}

Test_OnClientMessage(line, hPipe := 0) {
    global gTestResponse, gTestResponseReceived
    Log("  [IPC] Client received: " SubStr(line, 1, 80))
    gTestResponse := line
    gTestResponseReceived := true
}

Test_OnRealStoreMessage(line, hPipe := 0) {
    global gRealStoreResponse, gRealStoreReceived
    ; Skip hello_ack, we want the projection response
    if (InStr(line, '"type":"projection"') || InStr(line, '"type":"snapshot"')) {
        Log("  [Real Store] Received: " SubStr(line, 1, 80))
        gRealStoreResponse := line
        gRealStoreReceived := true
    } else {
        Log("  [Real Store] Got other msg type: " SubStr(line, 1, 60))
    }
}

Test_OnViewerMessage(line, hPipe := 0) {
    global gViewerTestResponse, gViewerTestReceived
    ; Skip hello_ack, we want the projection response
    if (InStr(line, '"type":"projection"') || InStr(line, '"type":"snapshot"')) {
        Log("  [Viewer Test] Received projection: " SubStr(line, 1, 80))
        gViewerTestResponse := line
        gViewerTestReceived := true
    } else {
        Log("  [Viewer Test] Got other msg: " SubStr(line, 1, 60))
    }
}

Test_OnWsE2EMessage(line, hPipe := 0) {
    global gWsE2EResponse, gWsE2EReceived
    ; Skip hello_ack, we want the projection response
    if (InStr(line, '"type":"projection"') || InStr(line, '"type":"snapshot"')) {
        Log("  [WS E2E] Received projection: " SubStr(line, 1, 80))
        gWsE2EResponse := line
        gWsE2EReceived := true
    } else {
        Log("  [WS E2E] Got other msg: " SubStr(line, 1, 60))
    }
}

Test_OnHeartbeatMessage(line, hPipe := 0) {
    global gHbTestHeartbeats, gHbTestLastRev, gHbTestReceived
    global gHbTestLivenessCount
    ; The liveness contract: client receives SOME message within heartbeat interval.
    ; Any message type (heartbeat, delta, snapshot) counts as proof of liveness.
    gHbTestLivenessCount++
    if (InStr(line, '"type":"heartbeat"')) {
        gHbTestHeartbeats++
        Log("  [HB Test] Received heartbeat #" gHbTestHeartbeats ": " SubStr(line, 1, 60))
        try {
            obj := JSON.Load(line)
            if (obj.Has("rev"))
                gHbTestLastRev := obj["rev"]
        }
        gHbTestReceived := true
    } else if (InStr(line, '"type":"delta"')) {
        Log("  [HB Test] Got delta (liveness #" gHbTestLivenessCount "): " SubStr(line, 1, 50))
    } else if (InStr(line, '"type":"snapshot"') || InStr(line, '"type":"projection"')) {
        Log("  [HB Test] Got data msg (liveness #" gHbTestLivenessCount "): " SubStr(line, 1, 50))
    } else {
        Log("  [HB Test] Got other msg (liveness #" gHbTestLivenessCount "): " SubStr(line, 1, 50))
    }
}

Test_OnProducerStateMessage(line, hPipe := 0) {
    global gProdTestProducers, gProdTestReceived
    ; We want producer_status response (new IPC message type)
    if (InStr(line, '"type":"producer_status"')) {
        Log("  [Prod Test] Received producer_status: " SubStr(line, 1, 80))
        try {
            obj := JSON.Load(line)
            if (obj.Has("producers")) {
                gProdTestProducers := obj["producers"]
            }
        }
        gProdTestReceived := true
    } else {
        Log("  [Prod Test] Got other msg: " SubStr(line, 1, 50))
    }
}

Test_OnBlacklistMessage(line, hPipe := 0) {
    global gBlTestResponse, gBlTestReceived
    ; We want projection/snapshot responses
    if (InStr(line, '"type":"projection"') || InStr(line, '"type":"snapshot"')) {
        Log("  [BL Test] Received: " SubStr(line, 1, 60))
        gBlTestResponse := line
        gBlTestReceived := true
    } else {
        Log("  [BL Test] Got other msg: " SubStr(line, 1, 50))
    }
}

Test_OnMruMessage(line, hPipe := 0) {
    global gMruTestResponse, gMruTestReceived
    ; We want projection/snapshot responses
    if (InStr(line, '"type":"projection"') || InStr(line, '"type":"snapshot"')) {
        Log("  [MRU Test] Received: " SubStr(line, 1, 60))
        gMruTestResponse := line
        gMruTestReceived := true
    } else {
        Log("  [MRU Test] Got other msg: " SubStr(line, 1, 50))
    }
}

Test_OnProjMessage(line, hPipe := 0) {
    global gProjTestResponse, gProjTestReceived
    ; We want projection/snapshot responses
    if (InStr(line, '"type":"projection"') || InStr(line, '"type":"snapshot"')) {
        gProjTestResponse := line
        gProjTestReceived := true
    }
}

Test_OnMultiClient1(line, hPipe := 0) {
    global gMultiClient1Response, gMultiClient1Received
    if (InStr(line, '"type":"projection"') || InStr(line, '"type":"snapshot"')) {
        gMultiClient1Response := line
        gMultiClient1Received := true
    }
}

Test_OnMultiClient2(line, hPipe := 0) {
    global gMultiClient2Response, gMultiClient2Received
    if (InStr(line, '"type":"projection"') || InStr(line, '"type":"snapshot"')) {
        gMultiClient2Response := line
        gMultiClient2Received := true
    }
}

Test_OnMultiClient3(line, hPipe := 0) {
    global gMultiClient3Response, gMultiClient3Received
    ; Client 3 expects hwndsOnly format - ignore stale broadcasts with items format
    ; that arrive before HELLO is processed (race between connect and HELLO)
    if ((InStr(line, '"type":"projection"') || InStr(line, '"type":"snapshot"'))
        && InStr(line, '"hwnds"')) {
        gMultiClient3Response := line
        gMultiClient3Received := true
    }
}

Test_OnStandaloneMessage(line, hPipe := 0) {
    global gStandaloneTestReceived
    gStandaloneTestReceived := true
}

Test_OnCompiledStoreMessage(line, hPipe := 0) {
    global gCompiledStoreReceived
    gCompiledStoreReceived := true
}

; --- Process Launch Helpers ---
; Windows shows the "app starting" cursor (pointer+hourglass) whenever a new
; process is launched via Run(). These helpers use CreateProcessW with
; STARTF_FORCEOFFFEEDBACK (0x80) to suppress that cursor change during tests.

; Launch a process hidden without cursor feedback.
; Returns true on success. Sets outPid to the new process ID.
_Test_RunSilent(cmdLine, &outPid := 0) {
    outPid := 0

    ; CreateProcessW requires writable command line buffer
    cmdBuf := Buffer((StrLen(cmdLine) + 1) * 2)
    StrPut(cmdLine, cmdBuf, "UTF-16")

    ; STARTUPINFOW (104 bytes on 64-bit)
    si := Buffer(104, 0)
    NumPut("UInt", 104, si, 0)    ; cb = sizeof(STARTUPINFOW)
    NumPut("UInt", 0x81, si, 60)  ; dwFlags: STARTF_USESHOWWINDOW | STARTF_FORCEOFFFEEDBACK
    ; wShowWindow at offset 64 = 0 (SW_HIDE) from zero-init

    ; PROCESS_INFORMATION (24 bytes on 64-bit)
    pi := Buffer(24, 0)

    result := DllCall("CreateProcessW",
        "Ptr", 0,            ; lpApplicationName
        "Ptr", cmdBuf,       ; lpCommandLine (writable)
        "Ptr", 0,            ; lpProcessAttributes
        "Ptr", 0,            ; lpThreadAttributes
        "Int", 0,            ; bInheritHandles
        "UInt", 0x08000000,  ; dwCreationFlags: CREATE_NO_WINDOW
        "Ptr", 0,            ; lpEnvironment
        "Ptr", 0,            ; lpCurrentDirectory
        "Ptr", si,           ; lpStartupInfo
        "Ptr", pi,           ; lpProcessInformation
        "Int")

    if (result) {
        outPid := NumGet(pi, 16, "UInt")                     ; dwProcessId
        DllCall("CloseHandle", "Ptr", NumGet(pi, 0, "Ptr"))  ; hProcess
        DllCall("CloseHandle", "Ptr", NumGet(pi, 8, "Ptr"))  ; hThread
    }

    return result
}

; Launch a process hidden without cursor feedback and wait for it to exit.
; Returns the process exit code, or -1 on failure.
_Test_RunWaitSilent(cmdLine, workDir := "") {
    cmdBuf := Buffer((StrLen(cmdLine) + 1) * 2)
    StrPut(cmdLine, cmdBuf, "UTF-16")

    si := Buffer(104, 0)
    NumPut("UInt", 104, si, 0)
    NumPut("UInt", 0x81, si, 60)

    pi := Buffer(24, 0)

    wdBuf := 0
    wdPtr := 0
    if (workDir != "") {
        wdBuf := Buffer((StrLen(workDir) + 1) * 2)
        StrPut(workDir, wdBuf, "UTF-16")
        wdPtr := wdBuf.Ptr
    }

    result := DllCall("CreateProcessW",
        "Ptr", 0, "Ptr", cmdBuf,
        "Ptr", 0, "Ptr", 0,
        "Int", 0,
        "UInt", 0x08000000,
        "Ptr", 0,
        "Ptr", wdPtr,
        "Ptr", si, "Ptr", pi,
        "Int")

    if (!result)
        return -1

    hProcess := NumGet(pi, 0, "Ptr")
    DllCall("CloseHandle", "Ptr", NumGet(pi, 8, "Ptr"))  ; hThread

    DllCall("WaitForSingleObject", "Ptr", hProcess, "UInt", 0xFFFFFFFF)

    exitCode := 0
    DllCall("GetExitCodeProcess", "Ptr", hProcess, "UInt*", &exitCode)
    DllCall("CloseHandle", "Ptr", hProcess)

    return exitCode
}

; --- Shared Helper Functions ---

; Wait for a store's named pipe to become available
; Returns true if pipe is ready, false on timeout
WaitForStorePipe(pipeName, timeoutMs := 3000) {
    pipePath := "\\.\pipe\" pipeName
    start := A_TickCount
    while ((A_TickCount - start) < timeoutMs) {
        ; Try to open the pipe - succeeds when store is ready
        hPipe := DllCall("CreateFile",
            "Str", pipePath,
            "UInt", 0x80000000,  ; GENERIC_READ
            "UInt", 0,
            "Ptr", 0,
            "UInt", 3,          ; OPEN_EXISTING
            "UInt", 0,
            "Ptr", 0,
            "Ptr")
        if (hPipe != -1) {
            DllCall("CloseHandle", "Ptr", hPipe)
            return true
        }
        Sleep(50)  ; Poll every 50ms
    }
    return false
}

; Launch a test store process with adaptive waiting
; Returns pipe name on success, empty string on failure
LaunchTestStore(pipeName := "", &outPid := 0) {
    if (pipeName = "")
        pipeName := "test_store_" A_TickCount "_" Random(1000, 9999)

    storePath := A_ScriptDir "\..\src\store\store_server.ahk"
    outPid := 0

    if (!_Test_RunSilent('"' A_AhkPath '" /ErrorStdOut "' storePath '" --test --pipe=' pipeName, &outPid)) {
        Log("ERROR: Failed to launch store")
        return ""
    }

    if (!WaitForStorePipe(pipeName, 3000)) {
        Log("ERROR: Store pipe not ready within 3s: " pipeName)
        if (outPid)
            try ProcessClose(outPid)
        return ""
    }

    return pipeName
}

; Cleanup a test store process
CleanupTestStore(pid) {
    if (pid)
        try ProcessClose(pid)
}

; Wait for a flag variable to become true
; Returns the flag value (true if set, false on timeout)
WaitForFlag(&flag, timeoutMs := 2000, pollMs := 20) {
    start := A_TickCount
    while (!flag && (A_TickCount - start) < timeoutMs)
        Sleep(pollMs)
    return flag
}

; Join array elements with a separator
_JoinArray(arr, sep) {
    result := ""
    for i, item in arr {
        if (i > 1)
            result .= sep
        result .= item
    }
    return result
}

; Repeat a string n times
_RepeatStr(str, count) {
    result := ""
    loop count
        result .= str
    return result
}

; Extract the body of a named function from source code.
; Returns the function body text (between outer braces), or "" if not found.
; Handles nested braces correctly.
_Test_ExtractFuncBody(code, funcName) {
    ; Find the function definition
    pos := InStr(code, funcName "(")
    if (!pos)
        return ""

    ; Find opening brace
    bracePos := InStr(code, "{", , pos)
    if (!bracePos)
        return ""

    ; Count braces to find matching close
    depth := 1
    i := bracePos + 1
    codeLen := StrLen(code)
    while (i <= codeLen && depth > 0) {
        ch := SubStr(code, i, 1)
        if (ch = "{")
            depth++
        else if (ch = "}")
            depth--
        i++
    }

    if (depth != 0)
        return ""

    return SubStr(code, bracePos, i - bracePos)
}

; Kill all running AltTabby.exe processes
_Test_KillAllAltTabby() {
    ; Use WMI to find and kill all AltTabby.exe processes
    for proc in ComObjGet("winmgmts:").ExecQuery("Select * from Win32_Process Where Name = 'AltTabby.exe'") {
        try {
            proc.Terminate()
        }
    }
    ; Give processes time to fully exit
    Sleep(200)
}
