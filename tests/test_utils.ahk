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

; --- IPC Test Callback Factory ---
; Creates a message handler closure that filters by type strings.
; Parameters:
;   &responseVar  - ByRef: stores the raw line when a matching message arrives
;   &receivedVar  - ByRef: set to true when a matching message arrives
;   filterTypes   - Array of type substrings to match (e.g., ['"type":"projection"', '"type":"snapshot"'])
;   logLabel      - Optional label for logging (empty = no logging)
; Returns: A closure suitable for IPC_PipeClient_Connect callback
_CreateTestMessageHandler(&responseVar, &receivedVar, filterTypes, logLabel := "") {
    return (line, hPipe := 0) => _TestMessageHandlerImpl(&responseVar, &receivedVar, filterTypes, logLabel, line)
}

_TestMessageHandlerImpl(&responseVar, &receivedVar, filterTypes, logLabel, line) {
    matched := false
    for _, ft in filterTypes {
        if (InStr(line, ft)) {
            matched := true
            break
        }
    }
    if (matched) {
        if (logLabel != "")
            Log("  [" logLabel "] Received: " SubStr(line, 1, 80))
        responseVar := line
        receivedVar := true
    } else {
        if (logLabel != "")
            Log("  [" logLabel "] Got other msg: " SubStr(line, 1, 60))
    }
}

; Common filter type arrays (allocated once)
global TEST_FILTER_PROJECTION := ['"type":"projection"', '"type":"snapshot"']
global TEST_FILTER_STATS := ['"type":"stats_response"']

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

global gRealStoreResponse, gRealStoreReceived
Test_OnRealStoreMessage := _CreateTestMessageHandler(&gRealStoreResponse, &gRealStoreReceived, TEST_FILTER_PROJECTION, "Real Store")

global gViewerTestResponse, gViewerTestReceived
Test_OnViewerMessage := _CreateTestMessageHandler(&gViewerTestResponse, &gViewerTestReceived, TEST_FILTER_PROJECTION, "Viewer Test")

global gWsE2EResponse, gWsE2EReceived
Test_OnWsE2EMessage := _CreateTestMessageHandler(&gWsE2EResponse, &gWsE2EReceived, TEST_FILTER_PROJECTION, "WS E2E")

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

global gBlTestResponse, gBlTestReceived
Test_OnBlacklistMessage := _CreateTestMessageHandler(&gBlTestResponse, &gBlTestReceived, TEST_FILTER_PROJECTION, "BL Test")

global gStatsTestResponse, gStatsTestReceived
Test_OnStatsMessage := _CreateTestMessageHandler(&gStatsTestResponse, &gStatsTestReceived, TEST_FILTER_STATS, "Stats Test")

global gMruTestResponse, gMruTestReceived
Test_OnMruMessage := _CreateTestMessageHandler(&gMruTestResponse, &gMruTestReceived, TEST_FILTER_PROJECTION, "MRU Test")

global gProjTestResponse, gProjTestReceived
Test_OnProjMessage := _CreateTestMessageHandler(&gProjTestResponse, &gProjTestReceived, ['"type":"projection"'])

global gMultiClient1Response, gMultiClient1Received
Test_OnMultiClient1 := _CreateTestMessageHandler(&gMultiClient1Response, &gMultiClient1Received, TEST_FILTER_PROJECTION)

global gMultiClient2Response, gMultiClient2Received
Test_OnMultiClient2 := _CreateTestMessageHandler(&gMultiClient2Response, &gMultiClient2Received, TEST_FILTER_PROJECTION)

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
}

Test_OnCompiledStoreMessage(line, hPipe := 0) {
}

; --- Temp Directory Helper ---
; Creates a temp directory, runs testFn(dir), and guarantees cleanup.
; prefix: unique name prefix for the temp dir
; testFn: callback that receives the temp dir path
_Test_WithTempDir(prefix, testFn) {
    dir := A_Temp "\" prefix "_" A_TickCount
    DirCreate(dir)
    try testFn(dir)
    finally {
        try DirDelete(dir, true)
    }
}

; --- Process Launch Helpers ---
; Windows shows the "app starting" cursor (pointer+hourglass) whenever a new
; process is launched via Run(). These helpers use CreateProcessW with
; STARTF_FORCEOFFFEEDBACK (0x80) to suppress that cursor change during tests.

; Prepare CreateProcessW buffers: writable command line, STARTUPINFOW, PROCESS_INFORMATION.
; Returns object with {cmdBuf, si, pi} ready for DllCall("CreateProcessW", ...).
_Test_PrepareCreateProcessBuffers(cmdLine) {
    cmdBuf := Buffer((StrLen(cmdLine) + 1) * 2)
    StrPut(cmdLine, cmdBuf, "UTF-16")

    ; STARTUPINFOW (104 bytes on 64-bit)
    si := Buffer(104, 0)
    NumPut("UInt", 104, si, 0)    ; cb = sizeof(STARTUPINFOW)
    NumPut("UInt", 0x81, si, 60)  ; dwFlags: STARTF_USESHOWWINDOW | STARTF_FORCEOFFFEEDBACK
    ; wShowWindow at offset 64 = 0 (SW_HIDE) from zero-init

    ; PROCESS_INFORMATION (24 bytes on 64-bit)
    pi := Buffer(24, 0)

    return {cmdBuf: cmdBuf, si: si, pi: pi}
}

; Launch a process hidden without cursor feedback.
; Returns true on success. Sets outPid to the new process ID.
_Test_RunSilent(cmdLine, &outPid := 0) {
    outPid := 0

    bufs := _Test_PrepareCreateProcessBuffers(cmdLine)

    result := DllCall("CreateProcessW",
        "Ptr", 0,            ; lpApplicationName
        "Ptr", bufs.cmdBuf,  ; lpCommandLine (writable)
        "Ptr", 0,            ; lpProcessAttributes
        "Ptr", 0,            ; lpThreadAttributes
        "Int", 0,            ; bInheritHandles
        "UInt", 0x08000000,  ; dwCreationFlags: CREATE_NO_WINDOW
        "Ptr", 0,            ; lpEnvironment
        "Ptr", 0,            ; lpCurrentDirectory
        "Ptr", bufs.si,      ; lpStartupInfo
        "Ptr", bufs.pi,      ; lpProcessInformation
        "Int")

    if (result) {
        outPid := NumGet(bufs.pi, 16, "UInt")                     ; dwProcessId
        DllCall("CloseHandle", "Ptr", NumGet(bufs.pi, 0, "Ptr"))  ; hProcess
        DllCall("CloseHandle", "Ptr", NumGet(bufs.pi, 8, "Ptr"))  ; hThread
    }

    return result
}

; Launch a process hidden without cursor feedback and wait for it to exit.
; Returns the process exit code, or -1 on failure.
_Test_RunWaitSilent(cmdLine, workDir := "") {
    bufs := _Test_PrepareCreateProcessBuffers(cmdLine)

    wdBuf := 0
    wdPtr := 0
    if (workDir != "") {
        wdBuf := Buffer((StrLen(workDir) + 1) * 2)
        StrPut(workDir, wdBuf, "UTF-16")
        wdPtr := wdBuf.Ptr
    }

    result := DllCall("CreateProcessW",
        "Ptr", 0, "Ptr", bufs.cmdBuf,
        "Ptr", 0, "Ptr", 0,
        "Int", 0,
        "UInt", 0x08000000,
        "Ptr", 0,
        "Ptr", wdPtr,
        "Ptr", bufs.si, "Ptr", bufs.pi,
        "Int")

    if (!result)
        return -1

    hProcess := NumGet(bufs.pi, 0, "Ptr")
    DllCall("CloseHandle", "Ptr", NumGet(bufs.pi, 8, "Ptr"))  ; hThread

    DllCall("WaitForSingleObject", "Ptr", hProcess, "UInt", 0xFFFFFFFF)

    exitCode := 0
    DllCall("GetExitCodeProcess", "Ptr", hProcess, "UInt*", &exitCode)
    DllCall("CloseHandle", "Ptr", hProcess)

    return exitCode
}

; --- Shared Helper Functions ---

; Wait for a store's named pipe to become available
; Returns true if pipe is ready, false on timeout
; Uses WaitNamedPipeW instead of CreateFile to avoid consuming a pipe instance
; (CreateFile opens and closes a real connection, wasting a server slot)
WaitForStorePipe(pipeName, timeoutMs := 5000) {
    pipePath := "\\.\pipe\" pipeName
    start := A_TickCount
    while ((A_TickCount - start) < timeoutMs) {
        ; WaitNamedPipeW returns true when pipe instance is available
        ; without actually connecting (no server slot consumed)
        if (DllCall("WaitNamedPipeW", "Str", pipePath, "UInt", 250))
            return true
        ; ERROR_FILE_NOT_FOUND (2) = pipe doesn't exist yet, retry
        Sleep(50)
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

; Repeat a string n times (O(n log n) doubling for large counts)
_RepeatStr(str, count) {
    if (count <= 0)
        return ""
    result := str
    n := 1
    while (n * 2 <= count) {
        result .= result
        n *= 2
    }
    if (n < count)
        result .= SubStr(result, 1, StrLen(str) * (count - n))
    return result
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
