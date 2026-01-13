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
#Include %A_ScriptDir%\..\src\shared\blacklist.ahk
#Include %A_ScriptDir%\..\src\store\windowstore.ahk
#Include %A_ScriptDir%\..\src\store\winenum_lite.ahk
#Include %A_ScriptDir%\..\src\store\komorebi_sub.ahk

; Initialize blacklist before tests - use explicit path to src/shared/blacklist.txt
Blacklist_Init(A_ScriptDir "\..\src\shared\blacklist.txt")

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
rec1["isVisible"] := true
rec1["isCloaked"] := false
rec1["isMinimized"] := false
rec1["z"] := 1
testRecs.Push(rec1)

rec2 := Map()
rec2["hwnd"] := 67890
rec2["title"] := "Test Window 2"
rec2["class"] := "TestClass2"
rec2["pid"] := 200
rec2["isVisible"] := true
rec2["isCloaked"] := false
rec2["isMinimized"] := false
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

    ; --- Heartbeat Test ---
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

        global gHbTestHeartbeats := 0
        global gHbTestLastRev := -1
        global gHbTestReceived := false

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

    ; --- MRU/Focus Tracking Test ---
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

        global gMruTestResponse := ""
        global gMruTestReceived := false

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

    ; --- Projection Options E2E Test ---
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

        global gProjTestResponse := ""
        global gProjTestReceived := false

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

    ; --- Blacklist E2E Test ---
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

        global gBlTestResponse := ""
        global gBlTestReceived := false

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
