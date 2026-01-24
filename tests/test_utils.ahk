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
        obj := JXON_Load(line)
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
        respJson := JXON_Dump(resp)
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
    global gHbTestHeartbeats, gHbTestLastRev, gHbTestReceived, IPC_MSG_HEARTBEAT
    if (InStr(line, '"type":"heartbeat"')) {
        gHbTestHeartbeats++
        Log("  [HB Test] Received heartbeat #" gHbTestHeartbeats ": " SubStr(line, 1, 60))
        ; Extract rev from message
        try {
            obj := JXON_Load(line)
            if (obj.Has("rev")) {
                gHbTestLastRev := obj["rev"]
            }
        }
        gHbTestReceived := true
    } else if (InStr(line, '"type":"snapshot"') || InStr(line, '"type":"projection"')) {
        Log("  [HB Test] Got data msg (ignoring): " SubStr(line, 1, 50))
    } else {
        Log("  [HB Test] Got other msg: " SubStr(line, 1, 50))
    }
}

Test_OnProducerStateMessage(line, hPipe := 0) {
    global gProdTestProducers, gProdTestReceived
    ; We want producer_status response (new IPC message type)
    if (InStr(line, '"type":"producer_status"')) {
        Log("  [Prod Test] Received producer_status: " SubStr(line, 1, 80))
        try {
            obj := JXON_Load(line)
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
    if (InStr(line, '"type":"projection"') || InStr(line, '"type":"snapshot"')) {
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

; --- Shared Helper Functions ---

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

; Kill all running AltTabby.exe processes
_Test_KillAllAltTabby() {
    ; Use WMI to find and kill all AltTabby.exe processes
    for proc in ComObjGet("winmgmts:").ExecQuery("Select * from Win32_Process Where Name = 'AltTabby.exe'") {
        try {
            proc.Terminate()
        }
    }
    ; Give processes time to fully exit
    Sleep(500)
}
