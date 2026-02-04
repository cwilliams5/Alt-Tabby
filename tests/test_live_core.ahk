; Live Tests - Core Integration
; Compile, IPC, Store, Viewer, Komorebi, Producer State
; Included by test_live.ahk
#Include test_utils.ahk

RunLiveTests_Core() {
    global TestPassed, TestErrors, cfg
    global gRealStoreResponse, gRealStoreReceived
    global gViewerTestResponse, gViewerTestReceived
    global gProdTestProducers, gProdTestReceived
    global testServer, gTestClient, gTestResponse, gTestResponseReceived
    global IPC_MSG_HELLO, IPC_MSG_PROJECTION_REQUEST, IPC_MSG_SNAPSHOT_REQUEST
    global IPC_MSG_PROJECTION, IPC_MSG_SNAPSHOT, IPC_MSG_RELOAD_BLACKLIST
    global IPC_MSG_PRODUCER_STATUS_REQUEST

    storePath := A_ScriptDir "\..\src\store\store_server.ahk"
    compileBat := A_ScriptDir "\..\compile.bat"
    compiledExePath := A_ScriptDir "\..\release\AltTabby.exe"

    ; ============================================================
    ; Compile Binary Check (compilation handled by test.ps1)
    ; ============================================================
    Log("`n--- Compile Binary Check ---")
    if (!FileExist(compiledExePath)) {
        Log("SKIP: AltTabby.exe not found in release folder")
    } else {
        Log("PASS: AltTabby.exe exists in release folder")
        TestPassed++
    }

    ; ============================================================
    ; Live Integration Tests (WinEnumLite, WindowStore pipeline)
    ; ============================================================
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

    ; ============================================================
    ; IPC Integration Tests (server/client)
    ; ============================================================
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
        Sleep(50)

        ; Send projection request
        reqMsg := { type: IPC_MSG_PROJECTION_REQUEST, projectionOpts: { sort: "Z", columns: "items" } }
        IPC_PipeClient_Send(gTestClient, JSON.Dump(reqMsg))

        ; Wait for response (with timeout)
        waitStart := A_TickCount
        while (!gTestResponseReceived && (A_TickCount - waitStart) < 3000) {
            Sleep(50)
        }

        if (gTestResponseReceived) {
            try {
                respObj := JSON.Load(gTestResponse)
                hasItems := respObj.Has("payload") && respObj["payload"].Has("items")
                AssertTrue(hasItems, "IPC response contains items array")
                if (hasItems) {
                    items := respObj["payload"]["items"]
                    itemCount := items.Length
                    Log("  IPC received " itemCount " items from store")

                    ; Validate projection includes required fields
                    if (itemCount > 0) {
                        sample := items[1]
                        requiredFields := ["hwnd", "title", "class", "pid", "z",
                            "lastActivatedTick", "isFocused", "isCloaked", "isMinimized",
                            "isOnCurrentWorkspace", "workspaceName", "processName"]
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
                            Log("FAIL: Projection missing fields: " _JoinArray(missingFields, ", "))
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

    ; ============================================================
    ; Shared Store for Real Store + Viewer + Producer State tests
    ; ============================================================
    ; These three tests are read-only (connect, query, verify, disconnect)
    ; so they safely share a single store instance.
    sharedStorePipe := "tabby_shared_test_" A_TickCount
    sharedStorePid := 0

    if (!_Test_RunSilent('"' A_AhkPath '" /ErrorStdOut "' storePath '" --test --pipe=' sharedStorePipe, &sharedStorePid)) {
        Log("SKIP: Could not start shared store_server")
        sharedStorePid := 0
    }

    if (sharedStorePid) {
        if (!WaitForStorePipe(sharedStorePipe, 3000)) {
            Log("FAIL: Shared store pipe not ready within timeout")
            TestErrors++
            try ProcessClose(sharedStorePid)
            sharedStorePid := 0
        }
    }

    ; ============================================================
    ; Real Store Integration Test (uses shared store)
    ; ============================================================
    Log("`n--- Real Store Integration Test ---")

    if (sharedStorePid) {
        ; Connect as a client (like the viewer does)
        gRealStoreResponse := ""
        gRealStoreReceived := false
        realClient := IPC_PipeClient_Connect(sharedStorePipe, Test_OnRealStoreMessage)

        if (realClient.hPipe) {
            Log("PASS: Connected to real store_server")
            TestPassed++

            ; Send hello like the viewer does
            helloMsg := { type: IPC_MSG_HELLO, clientId: "test", wants: { deltas: true } }
            IPC_PipeClient_Send(realClient, JSON.Dump(helloMsg))

            ; Send projection request
            projMsg := { type: IPC_MSG_PROJECTION_REQUEST, projectionOpts: { sort: "Z", columns: "items" } }
            IPC_PipeClient_Send(realClient, JSON.Dump(projMsg))

            ; Wait for response
            waitStart := A_TickCount
            while (!gRealStoreReceived && (A_TickCount - waitStart) < 5000) {
                Sleep(100)
            }

            if (gRealStoreReceived) {
                Log("PASS: Received response from real store")
                TestPassed++
                try {
                    respObj := JSON.Load(gRealStoreResponse)
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
    }

    ; ============================================================
    ; Headless Viewer Simulation Test (uses shared store)
    ; ============================================================
    Log("`n--- Headless Viewer Simulation Test ---")

    if (sharedStorePid) {
        gViewerTestResponse := ""
        gViewerTestReceived := false
        viewerClient := IPC_PipeClient_Connect(sharedStorePipe, Test_OnViewerMessage)

        if (viewerClient.hPipe) {
            Log("PASS: Viewer connected to store")
            TestPassed++

            ; Send hello like real viewer
            helloMsg := { type: IPC_MSG_HELLO, clientId: "test_viewer", wants: { deltas: true } }
            IPC_PipeClient_Send(viewerClient, JSON.Dump(helloMsg))

            ; Send projection request with MRU sort
            projMsg := { type: IPC_MSG_PROJECTION_REQUEST, projectionOpts: { sort: "MRU", columns: "items" } }
            IPC_PipeClient_Send(viewerClient, JSON.Dump(projMsg))

            ; Wait for response
            waitStart := A_TickCount
            while (!gViewerTestReceived && (A_TickCount - waitStart) < 5000) {
                Sleep(100)
            }

            if (gViewerTestReceived) {
                Log("PASS: Viewer received projection response")
                TestPassed++

                try {
                    respObj := JSON.Load(gViewerTestResponse)
                    if (respObj.Has("payload") && respObj["payload"].Has("items")) {
                        items := respObj["payload"]["items"]
                        if (items.Length > 0) {
                            ; Validate critical fields for viewer display
                            sample := items[1]
                            viewerFields := ["hwnd", "title", "z", "lastActivatedTick", "isCloaked",
                                "isMinimized", "isOnCurrentWorkspace", "workspaceName", "isFocused"]
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
                                Log("FAIL: Viewer projection missing: " _JoinArray(missingViewerFields, ", "))
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
    }

    ; ============================================================
    ; Producer State E2E Test (uses shared store)
    ; ============================================================
    Log("`n--- Producer State E2E Test ---")

    if (sharedStorePid) {
        gProdTestProducers := ""
        gProdTestReceived := false

        prodClient := IPC_PipeClient_Connect(sharedStorePipe, Test_OnProducerStateMessage)

        if (prodClient.hPipe) {
            Log("PASS: Producer state test connected to store")
            TestPassed++

            ; Send producer_status_request (new IPC message type)
            statusReqMsg := { type: IPC_MSG_PRODUCER_STATUS_REQUEST }
            IPC_PipeClient_Send(prodClient, JSON.Dump(statusReqMsg))

            ; Wait for producer_status response
            waitStart := A_TickCount
            while (!gProdTestReceived && (A_TickCount - waitStart) < 5000) {
                Sleep(100)
            }

            if (gProdTestReceived && IsObject(gProdTestProducers)) {
                Log("PASS: Received producer_status response")
                TestPassed++

                producers := gProdTestProducers

                ; Check that wineventHook state exists and is valid
                wehState := ""
                if (producers is Map && producers.Has("wineventHook")) {
                    wehState := producers["wineventHook"]
                } else if (IsObject(producers)) {
                    try wehState := producers.wineventHook
                }

                if (wehState = "running" || wehState = "failed" || wehState = "disabled") {
                    Log("PASS: wineventHook state is valid (" wehState ")")
                    TestPassed++
                } else {
                    Log("FAIL: wineventHook state invalid or missing (got: " wehState ")")
                    TestErrors++
                }

                ; Count how many producers are reported
                prodCount := 0
                expectedProducers := ["wineventHook", "mruLite", "komorebiSub", "komorebiLite", "iconPump", "procPump"]
                for _, pname in expectedProducers {
                    pstate := ""
                    if (producers is Map && producers.Has(pname)) {
                        pstate := producers[pname]
                    } else if (IsObject(producers)) {
                        try pstate := producers.%pname%
                    }
                    if (pstate != "")
                        prodCount++
                }

                if (prodCount >= 4) {
                    Log("PASS: Found " prodCount " producer states via IPC")
                    TestPassed++
                } else {
                    Log("FAIL: Expected at least 4 producer states, got " prodCount)
                    TestErrors++
                }
            } else {
                Log("FAIL: Did not receive producer_status response")
                TestErrors++
            }

            IPC_PipeClient_Close(prodClient)
        } else {
            Log("FAIL: Could not connect to store for producer state test")
            TestErrors++
        }
    }

    ; Kill the shared store (done with Real Store, Viewer, and Producer State tests)
    if (sharedStorePid) {
        try ProcessClose(sharedStorePid)
        Sleep(200)  ; Allow process cleanup before launching new stores
    }

    ; ============================================================
    ; Komorebi Integration Test
    ; ============================================================
    Log("`n--- Komorebi Integration Test ---")

    ; Check if komorebic is available
    komorebicPath := cfg.KomorebicExe  ; Use configured path from cfg object
    if (FileExist(komorebicPath)) {
        Log("PASS: komorebic.exe found")
        TestPassed++

        ; Get komorebi state
        tmpState := A_Temp "\komorebi_test_state.tmp"
        try FileDelete(tmpState)
        cmdLine := 'cmd.exe /c ""' komorebicPath '" state > "' tmpState '"" 2>&1'
        _Test_RunWaitSilent(cmdLine)
        Sleep(200)  ; Give file time to write
        stateTxt := ""
        try stateTxt := FileRead(tmpState, "UTF-8")
        try FileDelete(tmpState)

        if (stateTxt != "" && InStr(stateTxt, '"monitors"')) {
            Log("PASS: komorebic state returned valid JSON")
            TestPassed++

            ; Parse state JSON with cJson
            stateObj := ""
            try stateObj := JSON.Load(stateTxt)
            if !(stateObj is Map) {
                Log("FAIL: Could not parse komorebic state JSON")
                TestErrors++
            } else {
                ; Count workspaces and hwnds from parsed structure
                wsCount := 0
                hwndCount := 0
                firstHwnd := 0
                monitorsArr := _KSub_GetMonitorsArray(stateObj)
                for _, monObj in monitorsArr {
                    for _, wsObj in _KSub_GetWorkspacesArray(monObj) {
                        wsName := _KSafe_Str(wsObj, "name")
                        if (wsName != "")
                            wsCount++
                        ; Count hwnds in containers
                        if (wsObj is Map && wsObj.Has("containers")) {
                            for _, cont in _KSafe_Elements(wsObj["containers"]) {
                                if !(cont is Map)
                                    continue
                                if (cont.Has("windows")) {
                                    for _, win in _KSafe_Elements(cont["windows"]) {
                                        if (win is Map && win.Has("hwnd")) {
                                            hwndCount++
                                            if (!firstHwnd)
                                                firstHwnd := _KSafe_Int(win, "hwnd")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                Log("  Found " wsCount " workspace names in komorebi state")
                Log("  Found " hwndCount " window hwnds in komorebi state")

                if (hwndCount > 0) {
                    Log("PASS: Komorebi has managed windows")
                    TestPassed++

                    ; Test _KSub_FindWorkspaceByHwnd with parsed state
                    if (firstHwnd > 0) {
                        wsName := _KSub_FindWorkspaceByHwnd(stateObj, firstHwnd)
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
            }
        } else {
            Log("SKIP: komorebic state empty or invalid (komorebi may not be running)")
        }
    } else {
        Log("SKIP: komorebic.exe not found at " komorebicPath)
    }

}
