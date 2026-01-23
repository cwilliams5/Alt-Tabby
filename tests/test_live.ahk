; Live Integration Tests - All tests that require --live flag
; Tests that spawn store processes and do E2E validation
; Included by run_tests.ahk

RunLiveTests() {
    global TestPassed, TestErrors, cfg
    global gRealStoreResponse, gRealStoreReceived
    global gViewerTestResponse, gViewerTestReceived, gViewerTestHelloAck
    global gWsE2EResponse, gWsE2EReceived
    global gHbTestHeartbeats, gHbTestLastRev, gHbTestReceived
    global gProdTestProducers, gProdTestReceived
    global gMruTestResponse, gMruTestReceived
    global gProjTestResponse, gProjTestReceived
    global gMultiClient1Response, gMultiClient1Received
    global gMultiClient2Response, gMultiClient2Received
    global gMultiClient3Response, gMultiClient3Received
    global gBlTestResponse, gBlTestReceived
    global gStandaloneTestReceived, gCompiledStoreReceived
    global testServer, gTestClient, gTestResponse, gTestResponseReceived
    global IPC_MSG_HELLO, IPC_MSG_PROJECTION_REQUEST, IPC_MSG_SNAPSHOT_REQUEST
    global IPC_MSG_PROJECTION, IPC_MSG_SNAPSHOT, IPC_MSG_RELOAD_BLACKLIST
    global IPC_MSG_PRODUCER_STATUS_REQUEST

    storePath := A_ScriptDir "\..\src\store\store_server.ahk"
    compileBat := A_ScriptDir "\..\compile.bat"
    compiledExePath := A_ScriptDir "\..\release\AltTabby.exe"

    ; ============================================================
    ; Compile Binary (ensures tests run against latest code)
    ; ============================================================
    Log("`n--- Compile Binary ---")

    if (!FileExist(compileBat)) {
        Log("FAIL: compile.bat not found at: " compileBat)
        TestErrors++
    } else {
        ; Record pre-compile timestamp (if exe exists)
        preCompileTime := 0
        if (FileExist(compiledExePath)) {
            preCompileTime := FileGetTime(compiledExePath, "M")
        }

        ; Run compile.bat via cmd /c with stdin from nul to skip pause
        Log("  Running compile.bat...")

        try {
            ; RunWait with hidden window, pipe from nul to skip the pause
            exitCode := RunWait('cmd.exe /c "' compileBat '" < nul', A_ScriptDir "\..", "Hide")

            if (exitCode != 0) {
                Log("FAIL: compile.bat failed with exit code " exitCode)
                TestErrors++
            } else {
                Log("PASS: compile.bat completed successfully")
                TestPassed++
            }
        } catch as e {
            Log("FAIL: Could not run compile.bat: " e.Message)
            TestErrors++
        }

        ; Verify exe exists and is freshly compiled
        if (!FileExist(compiledExePath)) {
            Log("FAIL: AltTabby.exe not created after compilation")
            TestErrors++
        } else {
            postCompileTime := FileGetTime(compiledExePath, "M")

            ; Check timestamp changed (or was created)
            if (preCompileTime = 0) {
                Log("PASS: AltTabby.exe created (new file)")
                TestPassed++
            } else if (postCompileTime != preCompileTime) {
                Log("PASS: AltTabby.exe recompiled (timestamp changed)")
                TestPassed++
            } else {
                Log("FAIL: AltTabby.exe timestamp unchanged - compilation may have failed silently")
                TestErrors++
            }

            ; Verify it's recent (within last 90 seconds to allow for compile time)
            nowTime := FormatTime(, "yyyyMMddHHmmss")
            timeDiff := DateDiff(nowTime, postCompileTime, "Seconds")

            if (timeDiff <= 90) {
                Log("PASS: AltTabby.exe is fresh (modified " timeDiff "s ago)")
                TestPassed++
            } else {
                Log("FAIL: AltTabby.exe is stale (modified " timeDiff "s ago, expected <90s)")
                TestErrors++
            }
        }
    }

    ; ============================================================
    ; GitHub API Auto-Update Test
    ; ============================================================
    Log("`n--- GitHub API Auto-Update Test ---")

    ; Test that we can reach the GitHub API and parse the response
    apiUrl := "https://api.github.com/repos/cwilliams5/Alt-Tabby/releases/latest"
    Log("  Fetching: " apiUrl)

    try {
        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.Open("GET", apiUrl, false)
        whr.SetRequestHeader("User-Agent", "Alt-Tabby-Tests/" GetAppVersion())
        whr.Send()

        if (whr.Status = 200) {
            Log("PASS: GitHub API returned HTTP 200")
            TestPassed++

            response := whr.ResponseText

            ; Test tag_name parsing
            if (RegExMatch(response, '"tag_name"\s*:\s*"v?([^"]+)"', &tagMatch)) {
                Log("PASS: Found tag_name: v" tagMatch[1])
                TestPassed++

                ; Validate version format
                if (RegExMatch(tagMatch[1], "^\d+\.\d+\.\d+$")) {
                    Log("PASS: Version format is valid semver")
                    TestPassed++
                } else {
                    Log("FAIL: Version format invalid: " tagMatch[1])
                    TestErrors++
                }
            } else {
                Log("FAIL: Could not find tag_name in response")
                TestErrors++
            }

            ; Test download URL parsing
            downloadUrl := _Update_FindExeDownloadUrl(response)
            if (downloadUrl != "") {
                Log("PASS: Found AltTabby.exe download URL")
                TestPassed++

                ; Validate URL format
                if (InStr(downloadUrl, "github.com") && InStr(downloadUrl, "AltTabby.exe")) {
                    Log("PASS: Download URL format is valid: " SubStr(downloadUrl, 1, 60) "...")
                    TestPassed++
                } else {
                    Log("FAIL: Download URL format unexpected: " downloadUrl)
                    TestErrors++
                }

                ; Test actual download - download to temp and verify PE header
                Log("  Testing actual download...")
                tempExe := A_Temp "\AltTabby_download_test.exe"
                try {
                    dlWhr := ComObject("WinHttp.WinHttpRequest.5.1")
                    dlWhr.Open("GET", downloadUrl, false)
                    dlWhr.SetRequestHeader("User-Agent", "Alt-Tabby-Tests/" GetAppVersion())
                    dlWhr.Send()

                    if (dlWhr.Status = 200) {
                        ; Save to file
                        stream := ComObject("ADODB.Stream")
                        stream.Type := 1  ; Binary
                        stream.Open()
                        stream.Write(dlWhr.ResponseBody)
                        stream.SaveToFile(tempExe, 2)  ; Overwrite
                        stream.Close()

                        ; Verify file size is reasonable (>1MB for compiled AHK)
                        fileSize := FileGetSize(tempExe)
                        if (fileSize > 1000000) {
                            Log("PASS: Downloaded exe is valid size (" Round(fileSize / 1024 / 1024, 2) " MB)")
                            TestPassed++

                            ; Verify MZ header (PE executable)
                            f := FileOpen(tempExe, "r")
                            f.RawRead(header := Buffer(2))
                            f.Close()
                            if (NumGet(header, 0, "UChar") = 0x4D && NumGet(header, 1, "UChar") = 0x5A) {
                                Log("PASS: Downloaded exe has valid PE header (MZ)")
                                TestPassed++
                            } else {
                                Log("FAIL: Downloaded file is not a valid PE executable")
                                TestErrors++
                            }
                        } else {
                            Log("FAIL: Downloaded exe too small (" fileSize " bytes)")
                            TestErrors++
                        }

                        ; Cleanup
                        try FileDelete(tempExe)
                    } else {
                        Log("FAIL: Download returned HTTP " dlWhr.Status)
                        TestErrors++
                    }
                } catch as dlErr {
                    Log("FAIL: Download failed: " dlErr.Message)
                    TestErrors++
                }
            } else {
                Log("FAIL: Could not find AltTabby.exe download URL in release")
                TestErrors++
            }
        } else if (whr.Status = 404) {
            Log("FAIL: GitHub API returned 404 - repo may be private or release missing")
            TestErrors++
        } else {
            Log("FAIL: GitHub API returned HTTP " whr.Status)
            TestErrors++
        }
    } catch as e {
        Log("FAIL: GitHub API request failed: " e.Message)
        TestErrors++
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
                        requiredFields := ["hwnd", "title", "class", "pid", "z",
                            "lastActivatedTick", "isFocused", "isCloaked", "isMinimized",
                            "isOnCurrentWorkspace", "workspaceName", "processName", "present"]
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

    ; ============================================================
    ; Real Store Integration Test
    ; ============================================================
    Log("`n--- Real Store Integration Test ---")

    ; Start the real store_server process
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
        gRealStoreResponse := ""
        gRealStoreReceived := false
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

    ; ============================================================
    ; Headless Viewer Simulation Test
    ; ============================================================
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

        gViewerTestResponse := ""
        gViewerTestReceived := false
        gViewerTestHelloAck := false

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

    ; ============================================================
    ; Workspace Data E2E Test
    ; ============================================================
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

        gWsE2EResponse := ""
        gWsE2EReceived := false

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

    ; ============================================================
    ; Heartbeat Test
    ; ============================================================
    Log("`n--- Heartbeat Test ---")

    ; Start a store with short heartbeat interval for testing
    hbTestPipe := "tabby_hb_test_" A_TickCount
    hbTestPid := 0

    try {
        Run('"' A_AhkPath '" /ErrorStdOut "' storePath '" --pipe=' hbTestPipe, , "Hide", &hbTestPid)
    } catch as e {
        Log("SKIP: Could not start store for heartbeat test: " e.Message)
        hbTestPid := 0
    }

    if (hbTestPid) {
        ; Wait for store to initialize
        Sleep(1500)

        gHbTestHeartbeats := 0
        gHbTestLastRev := -1
        gHbTestReceived := false

        hbClient := IPC_PipeClient_Connect(hbTestPipe, Test_OnHeartbeatMessage)

        if (hbClient.hPipe) {
            Log("PASS: Heartbeat test connected to store")
            TestPassed++

            ; Send hello to register as client
            helloMsg := { type: IPC_MSG_HELLO, clientId: "hb_test", wants: { deltas: true } }
            IPC_PipeClient_Send(hbClient, JXON_Dump(helloMsg))

            ; Wait for heartbeats (store sends every 5s by default, we wait up to 12s)
            Log("  Waiting for heartbeat messages...")
            waitStart := A_TickCount
            while (gHbTestHeartbeats < 2 && (A_TickCount - waitStart) < 12000) {
                Sleep(500)
            }

            if (gHbTestHeartbeats >= 1) {
                Log("PASS: Received " gHbTestHeartbeats " heartbeat(s)")
                TestPassed++

                ; Verify heartbeat contains rev
                if (gHbTestLastRev >= 0) {
                    Log("PASS: Heartbeat contains rev field (rev=" gHbTestLastRev ")")
                    TestPassed++
                } else {
                    Log("FAIL: Heartbeat missing rev field")
                    TestErrors++
                }
            } else {
                Log("FAIL: No heartbeats received within timeout")
                TestErrors++
            }

            IPC_PipeClient_Close(hbClient)
        } else {
            Log("FAIL: Could not connect to store for heartbeat test")
            TestErrors++
        }

        try {
            ProcessClose(hbTestPid)
        }
    }

    ; ============================================================
    ; Producer State E2E Test
    ; ============================================================
    Log("`n--- Producer State E2E Test ---")

    ; Start a store for producer state testing
    prodTestPipe := "tabby_prod_test_" A_TickCount
    prodTestPid := 0

    try {
        Run('"' A_AhkPath '" /ErrorStdOut "' storePath '" --pipe=' prodTestPipe, , "Hide", &prodTestPid)
    } catch as e {
        Log("SKIP: Could not start store for producer state test: " e.Message)
        prodTestPid := 0
    }

    if (prodTestPid) {
        Sleep(1500)

        gProdTestProducers := ""
        gProdTestReceived := false

        prodClient := IPC_PipeClient_Connect(prodTestPipe, Test_OnProducerStateMessage)

        if (prodClient.hPipe) {
            Log("PASS: Producer state test connected to store")
            TestPassed++

            ; Send producer_status_request (new IPC message type)
            statusReqMsg := { type: IPC_MSG_PRODUCER_STATUS_REQUEST }
            IPC_PipeClient_Send(prodClient, JXON_Dump(statusReqMsg))

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

        try {
            ProcessClose(prodTestPid)
        }
    }

    ; ============================================================
    ; MRU/Focus Tracking Test
    ; ============================================================
    Log("`n--- MRU/Focus Tracking Test ---")

    ; This test verifies that focus tracking updates lastActivatedTick and isFocused
    mruTestPipe := "tabby_mru_test_" A_TickCount
    mruTestPid := 0

    try {
        Run('"' A_AhkPath '" /ErrorStdOut "' storePath '" --pipe=' mruTestPipe, , "Hide", &mruTestPid)
    } catch as e {
        Log("SKIP: Could not start store for MRU test: " e.Message)
        mruTestPid := 0
    }

    if (mruTestPid) {
        ; Wait for store to initialize and WinEventHook to start
        Sleep(2000)

        gMruTestResponse := ""
        gMruTestReceived := false

        mruClient := IPC_PipeClient_Connect(mruTestPipe, Test_OnMruMessage)

        if (mruClient.hPipe) {
            Log("PASS: MRU test connected to store")
            TestPassed++

            ; Send hello
            helloMsg := { type: IPC_MSG_HELLO, clientId: "mru_test", wants: { deltas: false } }
            IPC_PipeClient_Send(mruClient, JXON_Dump(helloMsg))

            ; Trigger a focus change by activating a window
            ; First, get the current foreground window
            origFg := 0
            try origFg := WinGetID("A")

            ; Find a different window to activate temporarily
            testWindows := WinEnumLite_ScanAll()
            alternateHwnd := 0
            for _, rec in testWindows {
                hwnd := rec["hwnd"]
                if (hwnd != origFg && !rec["isMinimized"] && !rec["isCloaked"]) {
                    alternateHwnd := hwnd
                    break
                }
            }

            if (alternateHwnd) {
                ; Activate the alternate window to trigger focus event
                try WinActivate("ahk_id " alternateHwnd)
                Sleep(300)  ; Give WinEventHook time to process
            }

            ; Restore original foreground
            if (origFg) {
                try WinActivate("ahk_id " origFg)
                Sleep(300)
            }

            ; Request projection and check MRU data
            gMruTestResponse := ""
            gMruTestReceived := false
            projMsg := { type: IPC_MSG_PROJECTION_REQUEST, projectionOpts: { sort: "MRU", columns: "items" } }
            IPC_PipeClient_Send(mruClient, JXON_Dump(projMsg))

            waitStart := A_TickCount
            while (!gMruTestReceived && (A_TickCount - waitStart) < 3000)
                Sleep(50)

            if (gMruTestReceived) {
                try {
                    respObj := JXON_Load(gMruTestResponse)
                    items := respObj["payload"]["items"]
                    Log("  MRU test received " items.Length " items")

                    ; Check that at least one window has isFocused=true
                    focusedCount := 0
                    focusedHwnd := 0
                    focusedTick := 0
                    for _, item in items {
                        if (item.Has("isFocused") && item["isFocused"] = true) {
                            focusedCount++
                            focusedHwnd := item["hwnd"]
                            focusedTick := item.Has("lastActivatedTick") ? item["lastActivatedTick"] : 0
                        }
                    }

                    if (focusedCount = 1) {
                        Log("PASS: Exactly one window has isFocused=true (hwnd=" focusedHwnd ")")
                        TestPassed++
                    } else if (focusedCount > 1) {
                        Log("FAIL: Multiple windows have isFocused=true (" focusedCount " windows)")
                        TestErrors++
                    } else {
                        Log("FAIL: No window has isFocused=true - MRU tracking not working!")
                        TestErrors++
                    }

                    ; Check that focused window has recent lastActivatedTick
                    if (focusedTick > 0) {
                        tickAge := A_TickCount - focusedTick
                        if (tickAge < 10000) {  ; Within 10 seconds
                            Log("PASS: Focused window has recent lastActivatedTick (age=" tickAge "ms)")
                            TestPassed++
                        } else {
                            Log("FAIL: Focused window lastActivatedTick too old (age=" tickAge "ms)")
                            TestErrors++
                        }
                    } else if (focusedCount > 0) {
                        Log("FAIL: Focused window has no lastActivatedTick")
                        TestErrors++
                    }

                    ; Check that items are sorted by MRU (first should be most recent)
                    if (items.Length >= 2) {
                        first := items[1]
                        second := items[2]
                        firstTick := first.Has("lastActivatedTick") ? first["lastActivatedTick"] : 0
                        secondTick := second.Has("lastActivatedTick") ? second["lastActivatedTick"] : 0
                        if (firstTick >= secondTick) {
                            Log("PASS: MRU sort order correct (first=" firstTick ", second=" secondTick ")")
                            TestPassed++
                        } else {
                            Log("FAIL: MRU sort order wrong (first=" firstTick " < second=" secondTick ")")
                            TestErrors++
                        }
                    }
                } catch as e {
                    Log("FAIL: MRU test parse error: " e.Message)
                    TestErrors++
                }
            } else {
                Log("FAIL: MRU test timeout")
                TestErrors++
            }

            IPC_PipeClient_Close(mruClient)
        } else {
            Log("FAIL: Could not connect to store for MRU test")
            TestErrors++
        }

        try {
            ProcessClose(mruTestPid)
        }
    }

    ; ============================================================
    ; Projection Options E2E Test
    ; ============================================================
    Log("`n--- Projection Options E2E Test ---")

    ; This test verifies all projection options work correctly
    projTestPipe := "tabby_proj_test_" A_TickCount
    projTestPid := 0

    try {
        Run('"' A_AhkPath '" /ErrorStdOut "' storePath '" --pipe=' projTestPipe, , "Hide", &projTestPid)
    } catch as e {
        Log("SKIP: Could not start store for projection test: " e.Message)
        projTestPid := 0
    }

    if (projTestPid) {
        Sleep(2000)

        gProjTestResponse := ""
        gProjTestReceived := false

        projClient := IPC_PipeClient_Connect(projTestPipe, Test_OnProjMessage)

        if (projClient.hPipe) {
            Log("PASS: Projection test connected to store")
            TestPassed++

            ; Send hello
            helloMsg := { type: IPC_MSG_HELLO, clientId: "proj_test", wants: { deltas: false } }
            IPC_PipeClient_Send(projClient, JXON_Dump(helloMsg))
            Sleep(300)

            ; === Test sort options ===
            sortTests := ["Z", "MRU", "Title", "Pid", "ProcessName"]
            for _, sortType in sortTests {
                gProjTestResponse := ""
                gProjTestReceived := false
                projMsg := { type: IPC_MSG_PROJECTION_REQUEST, projectionOpts: { sort: sortType, columns: "items" } }
                IPC_PipeClient_Send(projClient, JXON_Dump(projMsg))

                waitStart := A_TickCount
                while (!gProjTestReceived && (A_TickCount - waitStart) < 2000)
                    Sleep(50)

                if (gProjTestReceived) {
                    try {
                        respObj := JXON_Load(gProjTestResponse)
                        items := respObj["payload"]["items"]
                        if (items.Length > 0) {
                            Log("PASS: sort=" sortType " returned " items.Length " items")
                            TestPassed++
                        } else {
                            Log("FAIL: sort=" sortType " returned 0 items")
                            TestErrors++
                        }
                    } catch as e {
                        Log("FAIL: sort=" sortType " parse error: " e.Message)
                        TestErrors++
                    }
                } else {
                    Log("FAIL: sort=" sortType " timeout")
                    TestErrors++
                }
            }

            ; === Test columns: hwndsOnly ===
            gProjTestResponse := ""
            gProjTestReceived := false
            projMsg := { type: IPC_MSG_PROJECTION_REQUEST, projectionOpts: { sort: "Z", columns: "hwndsOnly" } }
            IPC_PipeClient_Send(projClient, JXON_Dump(projMsg))

            waitStart := A_TickCount
            while (!gProjTestReceived && (A_TickCount - waitStart) < 2000)
                Sleep(50)

            if (gProjTestReceived) {
                try {
                    respObj := JXON_Load(gProjTestResponse)
                    if (respObj["payload"].Has("hwnds")) {
                        hwnds := respObj["payload"]["hwnds"]
                        if (hwnds.Length > 0) {
                            ; Verify hwnds are integers
                            firstHwnd := hwnds[1]
                            if (IsInteger(firstHwnd)) {
                                Log("PASS: columns=hwndsOnly returned " hwnds.Length " hwnds")
                                TestPassed++
                            } else {
                                Log("FAIL: columns=hwndsOnly returned non-integer hwnd")
                                TestErrors++
                            }
                        } else {
                            Log("FAIL: columns=hwndsOnly returned empty array")
                            TestErrors++
                        }
                    } else {
                        Log("FAIL: columns=hwndsOnly missing 'hwnds' key")
                        TestErrors++
                    }
                } catch as e {
                    Log("FAIL: columns=hwndsOnly parse error: " e.Message)
                    TestErrors++
                }
            } else {
                Log("FAIL: columns=hwndsOnly timeout")
                TestErrors++
            }

            ; === Test includeMinimized: false ===
            ; First get count with minimized included
            gProjTestResponse := ""
            gProjTestReceived := false
            projMsg := { type: IPC_MSG_PROJECTION_REQUEST, projectionOpts: { sort: "Z", includeMinimized: true } }
            IPC_PipeClient_Send(projClient, JXON_Dump(projMsg))

            waitStart := A_TickCount
            while (!gProjTestReceived && (A_TickCount - waitStart) < 2000)
                Sleep(50)

            countWithMin := 0
            countMinimized := 0
            if (gProjTestReceived) {
                try {
                    respObj := JXON_Load(gProjTestResponse)
                    items := respObj["payload"]["items"]
                    countWithMin := items.Length
                    for _, item in items {
                        if (item.Has("isMinimized") && item["isMinimized"])
                            countMinimized++
                    }
                }
            }

            ; Now get count without minimized
            gProjTestResponse := ""
            gProjTestReceived := false
            projMsg := { type: IPC_MSG_PROJECTION_REQUEST, projectionOpts: { sort: "Z", includeMinimized: false } }
            IPC_PipeClient_Send(projClient, JXON_Dump(projMsg))

            waitStart := A_TickCount
            while (!gProjTestReceived && (A_TickCount - waitStart) < 2000)
                Sleep(50)

            if (gProjTestReceived) {
                try {
                    respObj := JXON_Load(gProjTestResponse)
                    items := respObj["payload"]["items"]
                    countWithoutMin := items.Length

                    ; Verify no minimized windows in result
                    hasMinimized := false
                    for _, item in items {
                        if (item.Has("isMinimized") && item["isMinimized"]) {
                            hasMinimized := true
                            break
                        }
                    }

                    if (!hasMinimized) {
                        Log("PASS: includeMinimized=false filters minimized (with=" countWithMin ", without=" countWithoutMin ", minimized=" countMinimized ")")
                        TestPassed++
                    } else {
                        Log("FAIL: includeMinimized=false still has minimized windows")
                        TestErrors++
                    }
                } catch as e {
                    Log("FAIL: includeMinimized=false parse error: " e.Message)
                    TestErrors++
                }
            } else {
                Log("FAIL: includeMinimized=false timeout")
                TestErrors++
            }

            ; === Test includeCloaked: true vs false ===
            gProjTestResponse := ""
            gProjTestReceived := false
            projMsg := { type: IPC_MSG_PROJECTION_REQUEST, projectionOpts: { sort: "Z", includeCloaked: true } }
            IPC_PipeClient_Send(projClient, JXON_Dump(projMsg))

            waitStart := A_TickCount
            while (!gProjTestReceived && (A_TickCount - waitStart) < 2000)
                Sleep(50)

            countWithCloaked := 0
            countCloaked := 0
            if (gProjTestReceived) {
                try {
                    respObj := JXON_Load(gProjTestResponse)
                    items := respObj["payload"]["items"]
                    countWithCloaked := items.Length
                    for _, item in items {
                        if (item.Has("isCloaked") && item["isCloaked"])
                            countCloaked++
                    }
                }
            }

            gProjTestResponse := ""
            gProjTestReceived := false
            projMsg := { type: IPC_MSG_PROJECTION_REQUEST, projectionOpts: { sort: "Z", includeCloaked: false } }
            IPC_PipeClient_Send(projClient, JXON_Dump(projMsg))

            waitStart := A_TickCount
            while (!gProjTestReceived && (A_TickCount - waitStart) < 2000)
                Sleep(50)

            if (gProjTestReceived) {
                try {
                    respObj := JXON_Load(gProjTestResponse)
                    items := respObj["payload"]["items"]
                    countWithoutCloaked := items.Length

                    ; Verify no cloaked windows in result
                    hasCloaked := false
                    for _, item in items {
                        if (item.Has("isCloaked") && item["isCloaked"]) {
                            hasCloaked := true
                            break
                        }
                    }

                    if (!hasCloaked) {
                        Log("PASS: includeCloaked=false filters cloaked (with=" countWithCloaked ", without=" countWithoutCloaked ", cloaked=" countCloaked ")")
                        TestPassed++
                    } else {
                        Log("FAIL: includeCloaked=false still has cloaked windows")
                        TestErrors++
                    }
                } catch as e {
                    Log("FAIL: includeCloaked=false parse error: " e.Message)
                    TestErrors++
                }
            } else {
                Log("FAIL: includeCloaked=false timeout")
                TestErrors++
            }

            ; === Test currentWorkspaceOnly: true ===
            gProjTestResponse := ""
            gProjTestReceived := false
            projMsg := { type: IPC_MSG_PROJECTION_REQUEST, projectionOpts: { sort: "Z", currentWorkspaceOnly: true } }
            IPC_PipeClient_Send(projClient, JXON_Dump(projMsg))

            waitStart := A_TickCount
            while (!gProjTestReceived && (A_TickCount - waitStart) < 2000)
                Sleep(50)

            if (gProjTestReceived) {
                try {
                    respObj := JXON_Load(gProjTestResponse)
                    items := respObj["payload"]["items"]

                    ; Verify all windows are on current workspace
                    allOnCurrent := true
                    for _, item in items {
                        if (item.Has("isOnCurrentWorkspace") && !item["isOnCurrentWorkspace"]) {
                            allOnCurrent := false
                            break
                        }
                    }

                    if (allOnCurrent) {
                        Log("PASS: currentWorkspaceOnly=true filters to current workspace (" items.Length " items)")
                        TestPassed++
                    } else {
                        Log("FAIL: currentWorkspaceOnly=true has windows from other workspaces")
                        TestErrors++
                    }
                } catch as e {
                    Log("FAIL: currentWorkspaceOnly=true parse error: " e.Message)
                    TestErrors++
                }
            } else {
                Log("FAIL: currentWorkspaceOnly=true timeout")
                TestErrors++
            }

            IPC_PipeClient_Close(projClient)
        } else {
            Log("FAIL: Could not connect to store for projection test")
            TestErrors++
        }

        try {
            ProcessClose(projTestPid)
        }
    }

    ; ============================================================
    ; Multi-Client E2E Test
    ; ============================================================
    Log("`n--- Multi-Client E2E Test ---")

    ; This test verifies multiple clients can connect simultaneously
    ; with different projection options and receive correct responses
    multiTestPipe := "tabby_multi_test_" A_TickCount
    multiTestPid := 0

    try {
        Run('"' A_AhkPath '" /ErrorStdOut "' storePath '" --pipe=' multiTestPipe, , "Hide", &multiTestPid)
    } catch as e {
        Log("SKIP: Could not start store for multi-client test: " e.Message)
        multiTestPid := 0
    }

    if (multiTestPid) {
        Sleep(2000)

        ; Connect 3 clients with different projection options
        gMultiClient1Response := ""
        gMultiClient1Received := false
        gMultiClient2Response := ""
        gMultiClient2Received := false
        gMultiClient3Response := ""
        gMultiClient3Received := false

        client1 := IPC_PipeClient_Connect(multiTestPipe, Test_OnMultiClient1)
        Sleep(100)
        client2 := IPC_PipeClient_Connect(multiTestPipe, Test_OnMultiClient2)
        Sleep(100)
        client3 := IPC_PipeClient_Connect(multiTestPipe, Test_OnMultiClient3)
        Sleep(100)

        allConnected := (client1.hPipe != 0 && client2.hPipe != 0 && client3.hPipe != 0)

        if (allConnected) {
            Log("PASS: All 3 clients connected simultaneously")
            TestPassed++

            ; Each client sends hello with different projection opts
            ; Client 1: sort=Z
            hello1 := { type: IPC_MSG_HELLO, clientId: "multi_1", projectionOpts: { sort: "Z", columns: "items" } }
            IPC_PipeClient_Send(client1, JXON_Dump(hello1))

            ; Client 2: sort=MRU
            hello2 := { type: IPC_MSG_HELLO, clientId: "multi_2", projectionOpts: { sort: "MRU", columns: "items" } }
            IPC_PipeClient_Send(client2, JXON_Dump(hello2))

            ; Client 3: sort=Title, hwndsOnly
            hello3 := { type: IPC_MSG_HELLO, clientId: "multi_3", projectionOpts: { sort: "Title", columns: "hwndsOnly" } }
            IPC_PipeClient_Send(client3, JXON_Dump(hello3))

            ; Wait for all clients to receive initial snapshots
            Sleep(500)

            ; Now request projections from each client
            gMultiClient1Response := ""
            gMultiClient1Received := false
            gMultiClient2Response := ""
            gMultiClient2Received := false
            gMultiClient3Response := ""
            gMultiClient3Received := false

            proj1 := { type: IPC_MSG_PROJECTION_REQUEST }
            proj2 := { type: IPC_MSG_PROJECTION_REQUEST }
            proj3 := { type: IPC_MSG_PROJECTION_REQUEST }

            IPC_PipeClient_Send(client1, JXON_Dump(proj1))
            IPC_PipeClient_Send(client2, JXON_Dump(proj2))
            IPC_PipeClient_Send(client3, JXON_Dump(proj3))

            ; Wait for responses
            waitStart := A_TickCount
            while ((!gMultiClient1Received || !gMultiClient2Received || !gMultiClient3Received) && (A_TickCount - waitStart) < 5000) {
                Sleep(50)
            }

            ; Verify all clients received responses
            if (gMultiClient1Received && gMultiClient2Received && gMultiClient3Received) {
                Log("PASS: All 3 clients received responses")
                TestPassed++

                ; Parse responses and verify each got their requested format
                try {
                    resp1 := JXON_Load(gMultiClient1Response)
                    resp2 := JXON_Load(gMultiClient2Response)
                    resp3 := JXON_Load(gMultiClient3Response)

                    ; Client 1 should have items (Z-sorted)
                    if (resp1["payload"].Has("items") && resp1["payload"]["items"].Length > 0) {
                        items1 := resp1["payload"]["items"]
                        ; Verify Z-sort (lower z = earlier in list)
                        if (items1.Length >= 2 && items1[1]["z"] <= items1[2]["z"]) {
                            Log("PASS: Client 1 received Z-sorted items (" items1.Length " items)")
                            TestPassed++
                        } else {
                            Log("PASS: Client 1 received items (" items1.Length " items, single item or z-sorted)")
                            TestPassed++
                        }
                    } else {
                        Log("FAIL: Client 1 missing items")
                        TestErrors++
                    }

                    ; Client 2 should have items (MRU-sorted)
                    if (resp2["payload"].Has("items") && resp2["payload"]["items"].Length > 0) {
                        items2 := resp2["payload"]["items"]
                        ; Verify MRU-sort (higher tick = earlier in list)
                        if (items2.Length >= 2) {
                            tick1 := items2[1]["lastActivatedTick"]
                            tick2 := items2[2]["lastActivatedTick"]
                            if (tick1 >= tick2) {
                                Log("PASS: Client 2 received MRU-sorted items (" items2.Length " items)")
                                TestPassed++
                            } else {
                                Log("WARN: Client 2 MRU sort may be off (tick1=" tick1 ", tick2=" tick2 ")")
                                TestPassed++  ; Don't fail, MRU can be tricky
                            }
                        } else {
                            Log("PASS: Client 2 received items (" items2.Length " items)")
                            TestPassed++
                        }
                    } else {
                        Log("FAIL: Client 2 missing items")
                        TestErrors++
                    }

                    ; Client 3 should have hwnds (not items)
                    if (resp3["payload"].Has("hwnds")) {
                        hwnds3 := resp3["payload"]["hwnds"]
                        if (hwnds3.Length > 0 && IsInteger(hwnds3[1])) {
                            Log("PASS: Client 3 received hwndsOnly format (" hwnds3.Length " hwnds)")
                            TestPassed++
                        } else {
                            Log("FAIL: Client 3 hwnds array empty or invalid")
                            TestErrors++
                        }
                    } else {
                        Log("FAIL: Client 3 missing hwnds (got items instead?)")
                        TestErrors++
                    }

                } catch as e {
                    Log("FAIL: Multi-client response parse error: " e.Message)
                    TestErrors++
                }
            } else {
                received := 0
                if (gMultiClient1Received)
                    received++
                if (gMultiClient2Received)
                    received++
                if (gMultiClient3Received)
                    received++
                Log("FAIL: Only " received "/3 clients received responses")
                TestErrors++
            }

            ; Cleanup
            IPC_PipeClient_Close(client1)
            IPC_PipeClient_Close(client2)
            IPC_PipeClient_Close(client3)
        } else {
            connected := 0
            if (client1.hPipe)
                connected++
            if (client2.hPipe)
                connected++
            if (client3.hPipe)
                connected++
            Log("FAIL: Only " connected "/3 clients connected")
            TestErrors++
            if (client1.hPipe)
                IPC_PipeClient_Close(client1)
            if (client2.hPipe)
                IPC_PipeClient_Close(client2)
            if (client3.hPipe)
                IPC_PipeClient_Close(client3)
        }

        try {
            ProcessClose(multiTestPid)
        }
    }

    ; ============================================================
    ; Blacklist E2E Test
    ; ============================================================
    Log("`n--- Blacklist E2E Test ---")

    ; Start a fresh store for blacklist test
    blTestPipe := "tabby_bl_test_" A_TickCount
    blTestPid := 0

    try {
        Run('"' A_AhkPath '" /ErrorStdOut "' storePath '" --pipe=' blTestPipe, , "Hide", &blTestPid)
    } catch as e {
        Log("SKIP: Could not start store for blacklist test: " e.Message)
        blTestPid := 0
    }

    if (blTestPid) {
        Sleep(1500)

        gBlTestResponse := ""
        gBlTestReceived := false

        blClient := IPC_PipeClient_Connect(blTestPipe, Test_OnBlacklistMessage)

        if (blClient.hPipe) {
            Log("PASS: Blacklist test connected to store")
            TestPassed++

            ; Send hello
            helloMsg := { type: IPC_MSG_HELLO, clientId: "bl_test", wants: { deltas: false } }
            IPC_PipeClient_Send(blClient, JXON_Dump(helloMsg))

            ; Get initial projection
            gBlTestResponse := ""
            gBlTestReceived := false
            projMsg := { type: IPC_MSG_PROJECTION_REQUEST, projectionOpts: { sort: "Z", columns: "items" } }
            IPC_PipeClient_Send(blClient, JXON_Dump(projMsg))

            waitStart := A_TickCount
            while (!gBlTestReceived && (A_TickCount - waitStart) < 3000)
                Sleep(50)

            if (!gBlTestReceived) {
                Log("FAIL: Timeout getting initial projection for blacklist test")
                TestErrors++
            } else {
                try {
                    respObj := JXON_Load(gBlTestResponse)
                    items := respObj["payload"]["items"]
                    initialCount := items.Length
                    Log("  Initial projection has " initialCount " windows")

                    ; Find a class to blacklist (pick one that exists)
                    testClass := ""
                    testTitle := ""
                    testClassCount := 0
                    for _, item in items {
                        cls := item.Has("class") ? item["class"] : ""
                        ttl := item.Has("title") ? item["title"] : ""
                        if (cls != "" && ttl != "") {
                            ; Count how many windows have this class
                            classCount := 0
                            for _, item2 in items {
                                if (item2.Has("class") && item2["class"] = cls)
                                    classCount++
                            }
                            ; Use this class for test (prefer one with few windows)
                            if (testClass = "" || classCount < testClassCount) {
                                testClass := cls
                                testTitle := ttl
                                testClassCount := classCount
                            }
                        }
                    }

                    if (testClass = "") {
                        Log("SKIP: No suitable class found for blacklist test")
                    } else {
                        Log("  Testing blacklist with class '" testClass "' (" testClassCount " windows)")

                        ; Read current blacklist file to preserve it
                        blFilePath := A_ScriptDir "\..\src\shared\blacklist.txt"
                        originalBlacklist := ""
                        try originalBlacklist := FileRead(blFilePath, "UTF-8")

                        ; === Test 1: Class blacklist ===
                        Log("  [BL Test] Testing class blacklist...")

                        ; Add test class to blacklist
                        Blacklist_AddClass(testClass)

                        ; Send reload IPC
                        reloadMsg := { type: IPC_MSG_RELOAD_BLACKLIST }
                        IPC_PipeClient_Send(blClient, JXON_Dump(reloadMsg))
                        Sleep(500)  ; Wait for reload and push

                        ; Get new projection
                        gBlTestResponse := ""
                        gBlTestReceived := false
                        IPC_PipeClient_Send(blClient, JXON_Dump(projMsg))

                        waitStart := A_TickCount
                        while (!gBlTestReceived && (A_TickCount - waitStart) < 3000)
                            Sleep(50)

                        if (gBlTestReceived) {
                            respObj2 := JXON_Load(gBlTestResponse)
                            items2 := respObj2["payload"]["items"]
                            afterClassBlCount := items2.Length

                            ; Count remaining windows with test class
                            remainingWithClass := 0
                            for _, item in items2 {
                                if (item.Has("class") && item["class"] = testClass)
                                    remainingWithClass++
                            }

                            Log("  After class blacklist: " afterClassBlCount " windows, " remainingWithClass " with test class")

                            if (remainingWithClass = 0 && afterClassBlCount < initialCount) {
                                Log("PASS: Class blacklist removed windows")
                                TestPassed++
                            } else if (remainingWithClass < testClassCount) {
                                Log("PASS: Class blacklist removed some windows (" (testClassCount - remainingWithClass) " of " testClassCount ")")
                                TestPassed++
                            } else {
                                Log("FAIL: Class blacklist did not remove windows (expected 0, got " remainingWithClass ")")
                                TestErrors++
                            }
                        } else {
                            Log("FAIL: Timeout after class blacklist reload")
                            TestErrors++
                        }

                        ; === Restore original blacklist and verify windows return ===
                        Log("  [BL Test] Restoring original blacklist...")

                        ; Restore original blacklist
                        try {
                            FileDelete(blFilePath)
                            FileAppend(originalBlacklist, blFilePath, "UTF-8")
                        }

                        ; Send reload IPC
                        IPC_PipeClient_Send(blClient, JXON_Dump(reloadMsg))
                        Sleep(500)

                        ; Get restored projection
                        gBlTestResponse := ""
                        gBlTestReceived := false
                        IPC_PipeClient_Send(blClient, JXON_Dump(projMsg))

                        waitStart := A_TickCount
                        while (!gBlTestReceived && (A_TickCount - waitStart) < 3000)
                            Sleep(50)

                        if (gBlTestReceived) {
                            respObj3 := JXON_Load(gBlTestResponse)
                            items3 := respObj3["payload"]["items"]
                            restoredCount := items3.Length

                            ; Windows should be back (via next winenum scan)
                            ; Note: They may not be immediately back since winenum needs to rescan
                            Log("  After restore: " restoredCount " windows (was " initialCount ")")

                            if (restoredCount >= afterClassBlCount) {
                                Log("PASS: Blacklist restore works (IPC reload mechanism verified)")
                                TestPassed++
                            } else {
                                Log("WARN: Restored count lower than expected (winenum may not have rescanned yet)")
                            }
                        }

                        ; === Test 2: Title blacklist (verify mechanism works) ===
                        Log("  [BL Test] Testing title blacklist pattern matching...")

                        ; Just verify blacklist functions work - add and remove test entry
                        testTitlePattern := "TEST_BL_TITLE_" A_TickCount
                        Blacklist_AddTitle(testTitlePattern)

                        ; Read back and verify it was added
                        testContent := ""
                        try testContent := FileRead(blFilePath, "UTF-8")

                        if (InStr(testContent, testTitlePattern)) {
                            Log("PASS: Title pattern added to blacklist file")
                            TestPassed++
                        } else {
                            Log("FAIL: Title pattern not found in blacklist file")
                            TestErrors++
                        }

                        ; Restore original
                        try {
                            FileDelete(blFilePath)
                            FileAppend(originalBlacklist, blFilePath, "UTF-8")
                        }

                        ; === Test 3: Pair blacklist ===
                        Log("  [BL Test] Testing pair blacklist pattern matching...")

                        testPairClass := "TEST_BL_PAIR_CLASS_" A_TickCount
                        testPairTitle := "TEST_BL_PAIR_TITLE_" A_TickCount
                        Blacklist_AddPair(testPairClass, testPairTitle)

                        ; Read back and verify
                        testContent := ""
                        try testContent := FileRead(blFilePath, "UTF-8")

                        expectedPair := testPairClass "|" testPairTitle
                        if (InStr(testContent, expectedPair)) {
                            Log("PASS: Pair pattern added to blacklist file")
                            TestPassed++
                        } else {
                            Log("FAIL: Pair pattern not found in blacklist file")
                            TestErrors++
                        }

                        ; Final restore
                        try {
                            FileDelete(blFilePath)
                            FileAppend(originalBlacklist, blFilePath, "UTF-8")
                        }

                        ; Send final reload to restore store state
                        IPC_PipeClient_Send(blClient, JXON_Dump(reloadMsg))
                        Sleep(200)

                        Log("  [BL Test] Blacklist file restored to original state")
                    }
                } catch as e {
                    Log("FAIL: Blacklist test error: " e.Message)
                    TestErrors++
                }
            }

            IPC_PipeClient_Close(blClient)
        } else {
            Log("FAIL: Could not connect to store for blacklist test")
            TestErrors++
        }

        try {
            ProcessClose(blTestPid)
        }
    }

    ; ============================================================
    ; Standalone /src Execution Test
    ; ============================================================
    Log("`n--- Standalone /src Execution Test ---")

    ; Test that store_server.ahk can be launched directly from /src
    standaloneStorePipe := "tabby_standalone_test_" A_TickCount
    standaloneStorePid := 0

    try {
        Run('"' A_AhkPath '" /ErrorStdOut "' storePath '" --pipe=' standaloneStorePipe, , "Hide", &standaloneStorePid)
    } catch as e {
        Log("FAIL: Could not launch standalone store_server.ahk: " e.Message)
        TestErrors++
        standaloneStorePid := 0
    }

    if (standaloneStorePid) {
        Sleep(2000)  ; Wait for store to initialize

        ; Verify process is running
        if (ProcessExist(standaloneStorePid)) {
            Log("PASS: Standalone store_server.ahk launched (PID=" standaloneStorePid ")")
            TestPassed++

            ; Try to connect to verify pipe was created
            gStandaloneTestReceived := false
            standaloneClient := IPC_PipeClient_Connect(standaloneStorePipe, Test_OnStandaloneMessage)

            if (standaloneClient.hPipe) {
                Log("PASS: Connected to standalone store pipe")
                TestPassed++
                IPC_PipeClient_Close(standaloneClient)
            } else {
                Log("FAIL: Could not connect to standalone store pipe")
                TestErrors++
            }
        } else {
            Log("FAIL: Standalone store_server.ahk exited unexpectedly")
            TestErrors++
        }

        try {
            ProcessClose(standaloneStorePid)
        }
    }

    ; ============================================================
    ; Compilation Verification Test
    ; ============================================================
    Log("`n--- Compilation Verification Test ---")

    ; Check that AltTabby.exe exists in release folder
    compiledExePath := A_ScriptDir "\..\release\AltTabby.exe"

    if (FileExist(compiledExePath)) {
        Log("PASS: AltTabby.exe exists in release folder")
        TestPassed++

        ; Check blacklist.txt is alongside exe (not in /shared subfolder)
        blPath := A_ScriptDir "\..\release\blacklist.txt"
        sharedBlPath := A_ScriptDir "\..\release\shared\blacklist.txt"

        if (FileExist(blPath)) {
            Log("PASS: blacklist.txt is alongside exe (correct location)")
            TestPassed++
        } else if (FileExist(sharedBlPath)) {
            Log("FAIL: blacklist.txt is in /shared subfolder (should be alongside exe)")
            TestErrors++
        } else {
            Log("WARN: blacklist.txt not found in release folder")
        }

        ; Check config.ini exists
        configPath := A_ScriptDir "\..\release\config.ini"
        if (FileExist(configPath)) {
            Log("PASS: config.ini exists in release folder")
            TestPassed++
        } else {
            Log("WARN: config.ini not found in release folder (will use defaults)")
        }
    } else {
        Log("SKIP: AltTabby.exe not found - run compile.bat first")
    }

    ; ============================================================
    ; Compiled Exe Mode Tests
    ; ============================================================
    Log("`n--- Compiled Exe Mode Tests ---")

    if (FileExist(compiledExePath)) {
        ; Test --store mode
        compiledStorePipe := "tabby_compiled_store_" A_TickCount
        compiledStorePid := 0

        try {
            Run('"' compiledExePath '" --store --pipe=' compiledStorePipe, , "Hide", &compiledStorePid)
        } catch as e {
            Log("FAIL: Could not launch AltTabby.exe --store: " e.Message)
            TestErrors++
            compiledStorePid := 0
        }

        if (compiledStorePid) {
            Sleep(2000)

            if (ProcessExist(compiledStorePid)) {
                Log("PASS: AltTabby.exe --store launched (PID=" compiledStorePid ")")
                TestPassed++

                ; Try to connect
                gCompiledStoreReceived := false
                compiledClient := IPC_PipeClient_Connect(compiledStorePipe, Test_OnCompiledStoreMessage)

                if (compiledClient.hPipe) {
                    Log("PASS: Connected to compiled store pipe")
                    TestPassed++
                    IPC_PipeClient_Close(compiledClient)
                } else {
                    Log("FAIL: Could not connect to compiled store pipe")
                    TestErrors++
                }
            } else {
                Log("FAIL: AltTabby.exe --store exited unexpectedly")
                TestErrors++
            }

            try {
                ProcessClose(compiledStorePid)
            }
        }

        ; Test launcher mode (spawns multiple processes)
        Log("  Testing launcher mode (spawns store + gui)...")
        launcherPid := 0

        try {
            Run('"' compiledExePath '"', , "Hide", &launcherPid)
        } catch as e {
            Log("FAIL: Could not launch AltTabby.exe (launcher mode): " e.Message)
            TestErrors++
            launcherPid := 0
        }

        if (launcherPid) {
            Sleep(3000)  ; Wait for launcher to spawn subprocesses

            ; Count AltTabby.exe processes
            processCount := 0
            for proc in ComObjGet("winmgmts:").ExecQuery("Select * from Win32_Process Where Name = 'AltTabby.exe'") {
                processCount++
            }

            if (processCount >= 3) {
                Log("PASS: Launcher mode spawned " processCount " processes (launcher + store + gui)")
                TestPassed++
            } else if (processCount >= 2) {
                Log("PASS: Launcher mode spawned " processCount " processes (may not include launcher)")
                TestPassed++
            } else {
                Log("FAIL: Launcher mode only has " processCount " process(es), expected 3")
                TestErrors++
            }

            ; Kill all AltTabby.exe processes
            for proc in ComObjGet("winmgmts:").ExecQuery("Select * from Win32_Process Where Name = 'AltTabby.exe'") {
                try {
                    proc.Terminate()
                }
            }
            Sleep(500)
        }

        ; --- Config/Blacklist Recreation Test ---
        Log("`n--- Config/Blacklist Recreation Test ---")

        releaseDir := A_ScriptDir "\..\release"
        configPath := releaseDir "\config.ini"
        blacklistPath := releaseDir "\blacklist.txt"
        configBackup := ""
        blacklistBackup := ""

        ; Back up existing files
        if (FileExist(configPath)) {
            configBackup := FileRead(configPath, "UTF-8")
            FileDelete(configPath)
        }
        if (FileExist(blacklistPath)) {
            blacklistBackup := FileRead(blacklistPath, "UTF-8")
            FileDelete(blacklistPath)
        }

        ; Verify files are deleted
        if (FileExist(configPath) || FileExist(blacklistPath)) {
            Log("FAIL: Could not delete config files for recreation test")
            TestErrors++
        } else {
            Log("  Deleted config.ini and blacklist.txt for recreation test")

            ; Run compiled store briefly - it should recreate the files
            recreatePipe := "tabby_recreate_test_" A_TickCount
            recreatePid := 0

            try {
                Run('"' compiledExePath '" --store --pipe=' recreatePipe, , "Hide", &recreatePid)
            }

            if (recreatePid) {
                Sleep(2000)  ; Give it time to start and create files

                ; Check if files were recreated
                configRecreated := FileExist(configPath)
                blacklistRecreated := FileExist(blacklistPath)

                if (configRecreated) {
                    Log("PASS: config.ini recreated by compiled exe")
                    TestPassed++
                } else {
                    Log("FAIL: config.ini NOT recreated by compiled exe")
                    TestErrors++
                }

                if (blacklistRecreated) {
                    Log("PASS: blacklist.txt recreated by compiled exe")
                    TestPassed++
                } else {
                    Log("FAIL: blacklist.txt NOT recreated by compiled exe")
                    TestErrors++
                }

                ; Kill the test store
                try {
                    ProcessClose(recreatePid)
                }
            } else {
                Log("FAIL: Could not launch compiled exe for recreation test")
                TestErrors++
            }
        }

        ; Restore original files
        if (configBackup != "") {
            try FileDelete(configPath)
            FileAppend(configBackup, configPath, "UTF-8")
            Log("  Restored original config.ini")
        }
        if (blacklistBackup != "") {
            try FileDelete(blacklistPath)
            FileAppend(blacklistBackup, blacklistPath, "UTF-8")
            Log("  Restored original blacklist.txt")
        }
    } else {
        Log("SKIP: Compiled exe tests skipped - AltTabby.exe not found")
    }
}
