#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn VarUnset, Off  ; Suppress warnings for functions defined in includes

; Automated test runner
; Usage: AutoHotkey64.exe tests/run_tests.ahk [--live]

global TestLogPath := A_Temp "\alt_tabby_tests.log"
global TestErrors := 0
global TestPassed := 0
global testServer := 0
global gTestClient := 0
global gTestResponse := ""
global gTestResponseReceived := false
global gRealStoreResponse := ""
global gRealStoreReceived := false

try FileDelete(TestLogPath)
Log("=== Alt-Tabby Test Run " FormatTime(, "yyyy-MM-dd HH:mm:ss") " ===")
Log("Log file: " TestLogPath)

; Check for --live flag
RunLiveTests := false
for _, arg in A_Args {
    if (arg = "--live")
        RunLiveTests := true
}

; Include files needed for testing
#Include %A_ScriptDir%\..\src\shared\config.ahk
#Include %A_ScriptDir%\..\src\shared\json.ahk
#Include %A_ScriptDir%\..\src\shared\ipc_pipe.ahk
#Include %A_ScriptDir%\..\src\store\windowstore.ahk
#Include %A_ScriptDir%\..\src\store\winenum_lite.ahk
#Include %A_ScriptDir%\..\src\store\komorebi_sub.ahk

Log("`n--- WindowStore Unit Tests ---")

; Test 1: _WS_GetOpt with Map
testMap := Map("sort", "Z", "includeMinimized", false)
AssertEq(_WS_GetOpt(testMap, "sort", "MRU"), "Z", "_WS_GetOpt with Map")

; Test 2: _WS_GetOpt with plain Object
testObj := { sort: "Title", columns: "hwndsOnly" }
AssertEq(_WS_GetOpt(testObj, "sort", "MRU"), "Title", "_WS_GetOpt with plain Object")

; Test 3: _WS_GetOpt default value
AssertEq(_WS_GetOpt(testObj, "missing", "default"), "default", "_WS_GetOpt default value")

; Test 4: _WS_GetOpt with non-object
AssertEq(_WS_GetOpt(0, "key", "fallback"), "fallback", "_WS_GetOpt with non-object")

; Test 5: WindowStore basic operations
WindowStore_Init()
WindowStore_BeginScan()

testRecs := []
rec1 := Map()
rec1["hwnd"] := 12345
rec1["title"] := "Test Window 1"
rec1["class"] := "TestClass"
rec1["pid"] := 100
rec1["state"] := "WorkspaceShowing"
rec1["z"] := 1
testRecs.Push(rec1)

rec2 := Map()
rec2["hwnd"] := 67890
rec2["title"] := "Test Window 2"
rec2["class"] := "TestClass2"
rec2["pid"] := 200
rec2["state"] := "WorkspaceShowing"
rec2["z"] := 2
testRecs.Push(rec2)

result := WindowStore_UpsertWindow(testRecs, "test")
AssertEq(result.added, 2, "WindowStore_UpsertWindow adds records")

; Test 6: GetProjection with plain object opts (THE BUG FIX)
proj := WindowStore_GetProjection({ sort: "Z", columns: "items" })
AssertEq(proj.items.Length, 2, "GetProjection with plain object opts")

; Test 7: GetProjection with Map opts
projMap := WindowStore_GetProjection(Map("sort", "Title"))
AssertEq(projMap.items.Length, 2, "GetProjection with Map opts")

; Test 8: Z-order sorting
projZ := WindowStore_GetProjection({ sort: "Z" })
AssertEq(projZ.items[1].z, 1, "Z-order sorting (first item z=1)")

; Live tests
if (RunLiveTests) {
    Log("`n--- Live Integration Tests ---")

    realWindows := WinEnumLite_ScanAll()
    AssertTrue(realWindows.Length > 0, "WinEnumLite finds windows (" realWindows.Length " found)")

    if (realWindows.Length > 0) {
        Log("  Sample windows:")
        count := 0
        for _, rec in realWindows {
            if (count >= 3)
                break
            Log("    hwnd=" rec["hwnd"] " title=" SubStr(rec["title"], 1, 40))
            count++
        }
    }

    ; Reset and test full pipeline
    global gWS_Store := Map()
    global gWS_Rev := 0
    WindowStore_Init()
    WindowStore_BeginScan()
    WindowStore_UpsertWindow(realWindows, "winenum_lite")
    WindowStore_EndScan()

    proj := WindowStore_GetProjection({ sort: "Z" })
    AssertTrue(proj.items.Length > 0, "Full pipeline produces projection (" proj.items.Length " items)")

    ; --- IPC Test: Store Server and Client ---
    Log("`n--- IPC Integration Tests ---")

    ; Start a test store server on a unique pipe
    testPipeName := "\\.\pipe\alt_tabby_test_" A_TickCount
    testServer := IPC_PipeServer_Start(testPipeName, Test_OnServerMessage)
    AssertTrue(IsObject(testServer), "IPC server started")

    ; Give server a moment to set up pending connection
    Sleep(100)

    ; Connect client
    gTestResponse := ""
    gTestResponseReceived := false
    gTestClient := IPC_PipeClient_Connect(testPipeName, Test_OnClientMessage)
    AssertTrue(gTestClient.hPipe != 0, "IPC client connected")

    if (gTestClient.hPipe) {
        ; Give connection time to establish
        Sleep(200)

        ; Send projection request
        reqMsg := { type: IPC_MSG_PROJECTION_REQUEST, projectionOpts: { sort: "Z", columns: "items" } }
        IPC_PipeClient_Send(gTestClient, JXON_Dump(reqMsg))

        ; Wait for response (with timeout)
        waitStart := A_TickCount
        while (!gTestResponseReceived && (A_TickCount - waitStart) < 3000) {
            Sleep(50)
        }

        if (gTestResponseReceived) {
            try {
                respObj := JXON_Load(gTestResponse)
                hasItems := respObj.Has("payload") && respObj["payload"].Has("items")
                AssertTrue(hasItems, "IPC response contains items array")
                if (hasItems) {
                    items := respObj["payload"]["items"]
                    itemCount := items.Length
                    Log("  IPC received " itemCount " items from store")

                    ; Validate projection includes required fields
                    if (itemCount > 0) {
                        sample := items[1]
                        requiredFields := ["hwnd", "title", "class", "pid", "state", "z",
                            "lastActivatedTick", "isFocused", "isCloaked", "isMinimized",
                            "workspaceName", "processName", "present"]
                        missingFields := []
                        for _, field in requiredFields {
                            if (!sample.Has(field)) {
                                missingFields.Push(field)
                            }
                        }
                        if (missingFields.Length = 0) {
                            Log("PASS: Projection contains all required fields")
                            TestPassed++
                        } else {
                            Log("FAIL: Projection missing fields: " _ArrayJoin(missingFields, ", "))
                            TestErrors++
                        }
                    }
                }
            } catch as e {
                Log("FAIL: IPC response parse error - " e.Message)
                TestErrors++
            }
        } else {
            Log("FAIL: IPC response timeout")
            TestErrors++
        }

        ; Cleanup client
        IPC_PipeClient_Close(gTestClient)
    }

    ; Cleanup server
    IPC_PipeServer_Stop(testServer)

    ; --- Real Store Integration Test ---
    Log("`n--- Real Store Integration Test ---")

    ; Start the real store_server process
    storePath := A_ScriptDir "\..\src\store\store_server.ahk"
    testStorePipe := "tabby_test_store_" A_TickCount
    storeArgs := '/ErrorStdOut "' storePath '" --pipe=' testStorePipe
    storePid := 0

    try {
        Run('"' A_AhkPath '" ' storeArgs, , "Hide", &storePid)
    } catch {
        Log("SKIP: Could not start store_server")
        storePid := 0
    }

    if (storePid) {
        ; Wait for store to start
        Sleep(1500)

        ; Connect as a client (like the viewer does)
        global gRealStoreResponse := ""
        global gRealStoreReceived := false
        realClient := IPC_PipeClient_Connect(testStorePipe, Test_OnRealStoreMessage)

        if (realClient.hPipe) {
            Log("PASS: Connected to real store_server")
            TestPassed++

            ; Send hello like the viewer does
            helloMsg := { type: IPC_MSG_HELLO, clientId: "test", wants: { deltas: true } }
            IPC_PipeClient_Send(realClient, JXON_Dump(helloMsg))

            ; Send projection request
            projMsg := { type: IPC_MSG_PROJECTION_REQUEST, projectionOpts: { sort: "Z", columns: "items" } }
            IPC_PipeClient_Send(realClient, JXON_Dump(projMsg))

            ; Wait for response
            waitStart := A_TickCount
            while (!gRealStoreReceived && (A_TickCount - waitStart) < 5000) {
                Sleep(100)
            }

            if (gRealStoreReceived) {
                Log("PASS: Received response from real store")
                TestPassed++
                try {
                    respObj := JXON_Load(gRealStoreResponse)
                    if (respObj.Has("payload") && respObj["payload"].Has("items")) {
                        itemCount := respObj["payload"]["items"].Length
                        Log("  Real store returned " itemCount " items")
                        AssertTrue(itemCount > 0, "Real store returns windows")
                    } else {
                        Log("FAIL: Real store response missing items")
                        TestErrors++
                    }
                } catch as e {
                    Log("FAIL: Real store response parse error: " e.Message)
                    TestErrors++
                }
            } else {
                Log("FAIL: Timeout waiting for real store response")
                TestErrors++
            }

            IPC_PipeClient_Close(realClient)
        } else {
            Log("FAIL: Could not connect to real store_server")
            TestErrors++
        }

        ; Kill the store process
        try {
            ProcessClose(storePid)
        }
    }

    ; --- Headless Viewer Simulation Test ---
    Log("`n--- Headless Viewer Simulation Test ---")

    ; Start a fresh store for viewer test
    viewerStorePipe := "tabby_viewer_test_" A_TickCount
    viewerStorePid := 0

    try {
        Run('"' A_AhkPath '" /ErrorStdOut "' storePath '" --pipe=' viewerStorePipe, , "Hide", &viewerStorePid)
    } catch as e {
        Log("SKIP: Could not start store for viewer test: " e.Message)
        viewerStorePid := 0
    }

    if (viewerStorePid) {
        Sleep(1500)

        global gViewerTestResponse := ""
        global gViewerTestReceived := false
        global gViewerTestHelloAck := false

        viewerClient := IPC_PipeClient_Connect(viewerStorePipe, Test_OnViewerMessage)

        if (viewerClient.hPipe) {
            Log("PASS: Viewer connected to store")
            TestPassed++

            ; Send hello like real viewer
            helloMsg := { type: IPC_MSG_HELLO, clientId: "test_viewer", wants: { deltas: true } }
            IPC_PipeClient_Send(viewerClient, JXON_Dump(helloMsg))

            ; Send projection request with MRU sort
            projMsg := { type: IPC_MSG_PROJECTION_REQUEST, projectionOpts: { sort: "MRU", columns: "items" } }
            IPC_PipeClient_Send(viewerClient, JXON_Dump(projMsg))

            ; Wait for response
            waitStart := A_TickCount
            while (!gViewerTestReceived && (A_TickCount - waitStart) < 5000) {
                Sleep(100)
            }

            if (gViewerTestReceived) {
                Log("PASS: Viewer received projection response")
                TestPassed++

                try {
                    respObj := JXON_Load(gViewerTestResponse)
                    if (respObj.Has("payload") && respObj["payload"].Has("items")) {
                        items := respObj["payload"]["items"]
                        if (items.Length > 0) {
                            ; Validate critical fields for viewer display
                            sample := items[1]
                            viewerFields := ["hwnd", "title", "z", "lastActivatedTick", "isCloaked",
                                "isMinimized", "workspaceName", "isFocused", "state"]
                            missingViewerFields := []
                            for _, field in viewerFields {
                                if (!sample.Has(field)) {
                                    missingViewerFields.Push(field)
                                }
                            }
                            if (missingViewerFields.Length = 0) {
                                Log("PASS: Viewer projection has all display fields")
                                TestPassed++
                            } else {
                                Log("FAIL: Viewer projection missing: " _ArrayJoin(missingViewerFields, ", "))
                                TestErrors++
                            }

                            ; Test that sort field (lastActivatedTick) is present for MRU sort
                            hasSortData := true
                            for _, item in items {
                                if (!item.Has("lastActivatedTick")) {
                                    hasSortData := false
                                    break
                                }
                            }
                            if (hasSortData) {
                                Log("PASS: All items have MRU sort field (lastActivatedTick)")
                                TestPassed++
                            } else {
                                Log("FAIL: Some items missing lastActivatedTick for MRU sort")
                                TestErrors++
                            }
                        } else {
                            Log("SKIP: No items to validate viewer fields")
                        }
                    } else {
                        Log("FAIL: Viewer response missing payload/items")
                        TestErrors++
                    }
                } catch as e {
                    Log("FAIL: Viewer response parse error: " e.Message)
                    TestErrors++
                }
            } else {
                Log("FAIL: Viewer timeout waiting for projection")
                TestErrors++
            }

            IPC_PipeClient_Close(viewerClient)
        } else {
            Log("FAIL: Viewer could not connect to store")
            TestErrors++
        }

        try {
            ProcessClose(viewerStorePid)
        }
    }

    ; --- Komorebi Integration Test ---
    Log("`n--- Komorebi Integration Test ---")

    ; Check if komorebic is available
    komorebicPath := KomorebicExe  ; Use configured path from config.ahk
    if (FileExist(komorebicPath)) {
        Log("PASS: komorebic.exe found")
        TestPassed++

        ; Get komorebi state
        tmpState := A_Temp "\komorebi_test_state.tmp"
        try FileDelete(tmpState)
        cmdLine := 'cmd.exe /c ""' komorebicPath '" state > "' tmpState '"" 2>&1'
        try {
            RunWait(cmdLine, , "Hide")
        }
        Sleep(200)  ; Give file time to write
        stateTxt := ""
        try stateTxt := FileRead(tmpState, "UTF-8")
        try FileDelete(tmpState)

        if (stateTxt != "" && InStr(stateTxt, '"monitors"')) {
            Log("PASS: komorebic state returned valid JSON")
            TestPassed++

            ; Count workspaces
            wsCount := 0
            posWs := 1
            while (p := RegExMatch(stateTxt, '"name"\s*:\s*"([^"]+)"', &mw, posWs)) {
                ; Skip monitor names (they have "device" nearby)
                if (!InStr(SubStr(stateTxt, Max(1, p - 100), 200), '"device"'))
                    wsCount++
                posWs := mw.Pos(0) + mw.Len(0)
            }
            Log("  Found " wsCount " workspace names in komorebi state")

            ; Count hwnds
            hwndCount := 0
            posH := 1
            while (p := RegExMatch(stateTxt, '"hwnd"\s*:\s*(\d+)', &mh, posH)) {
                hwndCount++
                posH := mh.Pos(0) + mh.Len(0)
            }
            Log("  Found " hwndCount " window hwnds in komorebi state")

            if (hwndCount > 0) {
                Log("PASS: Komorebi has managed windows")
                TestPassed++

                ; Test _KSub_FindWorkspaceByHwnd (include komorebi_sub for the function)
                ; Get first hwnd from state
                firstHwnd := 0
                if RegExMatch(stateTxt, '"hwnd"\s*:\s*(\d+)', &mFirst)
                    firstHwnd := Integer(mFirst[1])

                if (firstHwnd > 0) {
                    wsName := _KSub_FindWorkspaceByHwnd(stateTxt, firstHwnd)
                    if (wsName != "") {
                        Log("PASS: _KSub_FindWorkspaceByHwnd returned '" wsName "' for hwnd " firstHwnd)
                        TestPassed++
                    } else {
                        Log("FAIL: _KSub_FindWorkspaceByHwnd returned empty for hwnd " firstHwnd)
                        TestErrors++
                    }
                }
            } else {
                Log("SKIP: No windows managed by komorebi")
            }
        } else {
            Log("SKIP: komorebic state empty or invalid (komorebi may not be running)")
        }
    } else {
        Log("SKIP: komorebic.exe not found at " komorebicPath)
    }

    ; --- Workspace Data E2E Test ---
    Log("`n--- Workspace Data E2E Test ---")

    ; This test verifies workspace data flows from komorebi through the store to projections
    ; First, directly test that we can get workspace data from komorebic
    Log("  [WS E2E] Testing direct komorebic state fetch...")
    directTxt := _KSub_GetStateDirect()
    if (directTxt = "") {
        Log("  [WS E2E] WARNING: komorebic state returned empty")
    } else {
        ; Count windows with workspace data
        directHwnds := 0
        directPos := 1
        while (p := RegExMatch(directTxt, '"hwnd"\s*:\s*(\d+)', &dm, directPos)) {
            directHwnds++
            directPos := dm.Pos(0) + dm.Len(0)
        }
        Log("  [WS E2E] Direct komorebic state has " directHwnds " hwnds")

        ; Test lookup for a window
        if (directHwnds > 0 && RegExMatch(directTxt, '"hwnd"\s*:\s*(\d+)', &dm2)) {
            testHwnd := Integer(dm2[1])
            testWs := _KSub_FindWorkspaceByHwnd(directTxt, testHwnd)
            Log("  [WS E2E] Direct lookup hwnd " testHwnd " -> workspace '" testWs "'")
        }
    }

    ; Start a fresh store with komorebi producer enabled
    wsE2EPipe := "tabby_ws_e2e_" A_TickCount
    wsE2EPid := 0

    try {
        Run('"' A_AhkPath '" /ErrorStdOut "' storePath '" --pipe=' wsE2EPipe, , "Hide", &wsE2EPid)
    } catch as e {
        Log("SKIP: Could not start store for workspace E2E test: " e.Message)
        wsE2EPid := 0
    }

    if (wsE2EPid) {
        ; Wait for store to initialize and komorebi initial poll to run
        ; Initial poll happens at 1500ms after winenum populates at 1000ms
        ; Add extra time for komorebic state command
        Sleep(4000)

        global gWsE2EResponse := ""
        global gWsE2EReceived := false

        wsE2EClient := IPC_PipeClient_Connect(wsE2EPipe, Test_OnWsE2EMessage)

        if (wsE2EClient.hPipe) {
            Log("PASS: E2E test connected to store")
            TestPassed++

            ; Send hello
            helloMsg := { type: IPC_MSG_HELLO, clientId: "ws_e2e_test", wants: { deltas: false } }
            IPC_PipeClient_Send(wsE2EClient, JXON_Dump(helloMsg))

            ; Request projection with workspace data
            projMsg := { type: IPC_MSG_PROJECTION_REQUEST, projectionOpts: { sort: "Z", columns: "items", includeMinimized: true, includeCloaked: true } }
            IPC_PipeClient_Send(wsE2EClient, JXON_Dump(projMsg))

            ; Wait for response
            waitStart := A_TickCount
            while (!gWsE2EReceived && (A_TickCount - waitStart) < 5000) {
                Sleep(100)
            }

            if (gWsE2EReceived) {
                try {
                    respObj := JXON_Load(gWsE2EResponse)
                    if (respObj.Has("payload") && respObj["payload"].Has("items")) {
                        items := respObj["payload"]["items"]
                        Log("  E2E test received " items.Length " items")

                        ; Count items with workspace data
                        itemsWithWs := 0
                        itemsWithCloak := 0
                        for _, item in items {
                            wsName := item.Has("workspaceName") ? item["workspaceName"] : ""
                            isCloaked := item.Has("isCloaked") ? item["isCloaked"] : false
                            if (wsName != "")
                                itemsWithWs++
                            if (isCloaked)
                                itemsWithCloak++
                        }

                        Log("  Items with workspaceName: " itemsWithWs "/" items.Length)
                        Log("  Items with isCloaked=true: " itemsWithCloak "/" items.Length)

                        ; If komorebi is running and has windows, we should have workspace data
                        if (FileExist(komorebicPath) && itemsWithWs > 0) {
                            Log("PASS: Workspace data flows through to projection")
                            TestPassed++
                        } else if (!FileExist(komorebicPath)) {
                            Log("SKIP: Cannot verify workspace e2e without komorebi")
                        } else {
                            Log("WARN: No workspace data in projection (komorebi may have no managed windows)")
                        }

                        ; isCloaked field should always be present (from winenum_lite)
                        sampleHasCloaked := items.Length > 0 && items[1].Has("isCloaked")
                        if (sampleHasCloaked) {
                            Log("PASS: isCloaked field present in projection items")
                            TestPassed++
                        } else {
                            Log("FAIL: isCloaked field missing from projection items")
                            TestErrors++
                        }
                    } else {
                        Log("FAIL: E2E response missing payload/items")
                        TestErrors++
                    }
                } catch as e {
                    Log("FAIL: E2E response parse error: " e.Message)
                    TestErrors++
                }
            } else {
                Log("FAIL: E2E test timeout waiting for response")
                TestErrors++
            }

            IPC_PipeClient_Close(wsE2EClient)
        } else {
            Log("FAIL: E2E test could not connect to store")
            TestErrors++
        }

        try {
            ProcessClose(wsE2EPid)
        }
    }
}

; Summary
Log("`n=== Test Summary ===")
Log("Passed: " TestPassed)
Log("Failed: " TestErrors)
Log("Result: " (TestErrors = 0 ? "ALL TESTS PASSED" : "SOME TESTS FAILED"))

ExitApp(TestErrors > 0 ? 1 : 0)

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
        if (i > 1) {
            out .= sep
        }
        out .= v
    }
    return out
}
