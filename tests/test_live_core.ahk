; Live Tests - Core Integration
; Compile, GitHub API, IPC, Store, Viewer, Komorebi, Workspace E2E, Heartbeat, Producer State
; Included by test_live.ahk

RunLiveTests_Core() {
    global TestPassed, TestErrors, cfg
    global gRealStoreResponse, gRealStoreReceived
    global gViewerTestResponse, gViewerTestReceived, gViewerTestHelloAck
    global gWsE2EResponse, gWsE2EReceived
    global gHbTestHeartbeats, gHbTestLastRev, gHbTestReceived
    global gProdTestProducers, gProdTestReceived
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

    ; Kill any running AltTabby processes before compilation
    ; This prevents "file in use" errors and avoids single-instance dialog
    _Test_KillAllAltTabby()

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
    ; Real Store Integration Test
    ; ============================================================
    Log("`n--- Real Store Integration Test ---")

    ; Start the real store_server process
    testStorePipe := "tabby_test_store_" A_TickCount
    storeArgs := '/ErrorStdOut "' storePath '" --test --pipe=' testStorePipe
    storePid := 0

    try {
        Run('"' A_AhkPath '" ' storeArgs, , "Hide", &storePid)
    } catch {
        Log("SKIP: Could not start store_server")
        storePid := 0
    }

    if (storePid) {
        ; Wait for store pipe to become available (adaptive)
        if (!WaitForStorePipe(testStorePipe, 3000)) {
            Log("FAIL: Store pipe not ready within timeout")
            TestErrors++
            try ProcessClose(storePid)
            storePid := 0
        }
    }

    if (storePid) {
        ; Connect as a client (like the viewer does)
        gRealStoreResponse := ""
        gRealStoreReceived := false
        realClient := IPC_PipeClient_Connect(testStorePipe, Test_OnRealStoreMessage)

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
        Run('"' A_AhkPath '" /ErrorStdOut "' storePath '" --test --pipe=' viewerStorePipe, , "Hide", &viewerStorePid)
    } catch as e {
        Log("SKIP: Could not start store for viewer test: " e.Message)
        viewerStorePid := 0
    }

    if (viewerStorePid) {
        ; Wait for store pipe to become available (adaptive)
        if (!WaitForStorePipe(viewerStorePipe, 3000)) {
            Log("FAIL: Viewer store pipe not ready within timeout")
            TestErrors++
            try ProcessClose(viewerStorePid)
            viewerStorePid := 0
        }
    }

    if (viewerStorePid) {
        gViewerTestResponse := ""
        gViewerTestReceived := false
        gViewerTestHelloAck := false

        viewerClient := IPC_PipeClient_Connect(viewerStorePipe, Test_OnViewerMessage)

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
        ; Parse and count windows from parsed structure
        directObj := ""
        try directObj := JSON.Load(directTxt)
        directHwnds := 0
        firstTestHwnd := 0
        if (directObj is Map) {
            for _, monObj in _KSub_GetMonitorsArray(directObj) {
                for _, wsObj in _KSub_GetWorkspacesArray(monObj) {
                    if !(wsObj is Map) || !wsObj.Has("containers")
                        continue
                    for _, cont in _KSafe_Elements(wsObj["containers"]) {
                        if !(cont is Map)
                            continue
                        if (cont.Has("windows")) {
                            for _, win in _KSafe_Elements(cont["windows"]) {
                                if (win is Map && win.Has("hwnd")) {
                                    directHwnds++
                                    if (!firstTestHwnd)
                                        firstTestHwnd := _KSafe_Int(win, "hwnd")
                                }
                            }
                        }
                    }
                }
            }
        }
        Log("  [WS E2E] Direct komorebic state has " directHwnds " hwnds")

        ; Test lookup for a window
        if (directHwnds > 0 && firstTestHwnd > 0) {
            testWs := _KSub_FindWorkspaceByHwnd(directObj, firstTestHwnd)
            Log("  [WS E2E] Direct lookup hwnd " firstTestHwnd " -> workspace '" testWs "'")
        }
    }

    ; Start a fresh store with komorebi producer enabled
    wsE2EPipe := "tabby_ws_e2e_" A_TickCount
    wsE2EPid := 0

    try {
        Run('"' A_AhkPath '" /ErrorStdOut "' storePath '" --test --pipe=' wsE2EPipe, , "Hide", &wsE2EPid)
    } catch as e {
        Log("SKIP: Could not start store for workspace E2E test: " e.Message)
        wsE2EPid := 0
    }

    if (wsE2EPid) {
        ; Wait for store pipe to become available (adaptive)
        if (!WaitForStorePipe(wsE2EPipe, 3000)) {
            Log("FAIL: WS E2E store pipe not ready within timeout")
            TestErrors++
            try ProcessClose(wsE2EPid)
            wsE2EPid := 0
        }
    }

    if (wsE2EPid) {
        ; Additional wait for komorebi initial poll to complete
        ; Initial poll happens after winenum populates
        Sleep(2000)

        gWsE2EResponse := ""
        gWsE2EReceived := false

        wsE2EClient := IPC_PipeClient_Connect(wsE2EPipe, Test_OnWsE2EMessage)

        if (wsE2EClient.hPipe) {
            Log("PASS: E2E test connected to store")
            TestPassed++

            ; Send hello
            helloMsg := { type: IPC_MSG_HELLO, clientId: "ws_e2e_test", wants: { deltas: false } }
            IPC_PipeClient_Send(wsE2EClient, JSON.Dump(helloMsg))

            ; Request projection with workspace data
            projMsg := { type: IPC_MSG_PROJECTION_REQUEST, projectionOpts: { sort: "Z", columns: "items", includeMinimized: true, includeCloaked: true } }
            IPC_PipeClient_Send(wsE2EClient, JSON.Dump(projMsg))

            ; Wait for response
            waitStart := A_TickCount
            while (!gWsE2EReceived && (A_TickCount - waitStart) < 5000) {
                Sleep(100)
            }

            if (gWsE2EReceived) {
                try {
                    respObj := JSON.Load(gWsE2EResponse)
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
        Run('"' A_AhkPath '" /ErrorStdOut "' storePath '" --test --pipe=' hbTestPipe, , "Hide", &hbTestPid)
    } catch as e {
        Log("SKIP: Could not start store for heartbeat test: " e.Message)
        hbTestPid := 0
    }

    if (hbTestPid) {
        ; Wait for store pipe to become available (adaptive)
        if (!WaitForStorePipe(hbTestPipe, 3000)) {
            Log("FAIL: Heartbeat store pipe not ready within timeout")
            TestErrors++
            try ProcessClose(hbTestPid)
            hbTestPid := 0
        }
    }

    if (hbTestPid) {
        gHbTestHeartbeats := 0
        gHbTestLastRev := -1
        gHbTestReceived := false

        hbClient := IPC_PipeClient_Connect(hbTestPipe, Test_OnHeartbeatMessage)

        if (hbClient.hPipe) {
            Log("PASS: Heartbeat test connected to store")
            TestPassed++

            ; Send hello to register as client
            helloMsg := { type: IPC_MSG_HELLO, clientId: "hb_test", wants: { deltas: true } }
            IPC_PipeClient_Send(hbClient, JSON.Dump(helloMsg))

            ; Wait for heartbeats. Store suppresses heartbeats when recent messages were sent,
            ; so first heartbeat after hello snapshot can take up to 2x interval in worst case.
            ; Use 2x heartbeat interval + 5s buffer for reliable test timing.
            hbTimeoutMs := (cfg.StoreHeartbeatIntervalMs * 2) + 5000
            Log("  Waiting for heartbeat messages (timeout=" hbTimeoutMs "ms)...")
            waitStart := A_TickCount
            while (gHbTestHeartbeats < 2 && (A_TickCount - waitStart) < hbTimeoutMs) {
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
        Run('"' A_AhkPath '" /ErrorStdOut "' storePath '" --test --pipe=' prodTestPipe, , "Hide", &prodTestPid)
    } catch as e {
        Log("SKIP: Could not start store for producer state test: " e.Message)
        prodTestPid := 0
    }

    if (prodTestPid) {
        ; Wait for store pipe to become available (adaptive)
        if (!WaitForStorePipe(prodTestPipe, 3000)) {
            Log("FAIL: Producer state store pipe not ready within timeout")
            TestErrors++
            try ProcessClose(prodTestPid)
            prodTestPid := 0
        }
    }

    if (prodTestPid) {
        gProdTestProducers := ""
        gProdTestReceived := false

        prodClient := IPC_PipeClient_Connect(prodTestPipe, Test_OnProducerStateMessage)

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

        try {
            ProcessClose(prodTestPid)
        }
    }
}
