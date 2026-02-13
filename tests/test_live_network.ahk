; Live Tests - Network / I/O-bound Integration
; GitHub API, Workspace Data E2E, Store Liveness
; Included by test_live.ahk
#Include test_utils.ahk

RunLiveTests_Network() {
    global TestPassed, TestErrors, cfg
    global gWsE2EResponse, gWsE2EReceived
    global gHbTestHeartbeats, gHbTestLastRev, gHbTestReceived
    global IPC_MSG_HELLO, IPC_MSG_PROJECTION_REQUEST
    global IPC_MSG_SNAPSHOT, IPC_MSG_SNAPSHOT_REQUEST
    global DoInvasiveTests

    storePath := A_ScriptDir "\..\src\store\store_server.ahk"

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
            for _, monObj in KSub_GetMonitorsArray(directObj) {
                for _, wsObj in KSub_GetWorkspacesArray(monObj) {
                    if !(wsObj is Map) || !wsObj.Has("containers")
                        continue
                    for _, cont in KSafe_Elements(wsObj["containers"]) {
                        if !(cont is Map)
                            continue
                        if (cont.Has("windows")) {
                            for _, win in KSafe_Elements(cont["windows"]) {
                                if (win is Map && win.Has("hwnd")) {
                                    directHwnds++
                                    if (!firstTestHwnd)
                                        firstTestHwnd := KSafe_Int(win, "hwnd")
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
            testWs := KSub_FindWorkspaceByHwnd(directObj, firstTestHwnd)
            Log("  [WS E2E] Direct lookup hwnd " firstTestHwnd " -> workspace '" testWs "'")
        }
    }

    ; Start a fresh store with komorebi producer enabled
    wsE2EPipe := "tabby_ws_e2e_" A_TickCount
    wsE2EPid := 0

    if (_Test_RunSilent('"' A_AhkPath '" /ErrorStdOut "' storePath '" --test --pipe=' wsE2EPipe, &wsE2EPid)) {
        Log("  [WS E2E] Store launched (PID=" wsE2EPid ", pipe=" wsE2EPipe ")")
    } else {
        Log("SKIP: Could not start store for workspace E2E test")
        wsE2EPid := 0
    }

    if (wsE2EPid) {
        ; Wait for store pipe to become available
        ; Use 5s timeout to handle parallel test load
        if (!WaitForStorePipe(wsE2EPipe, 5000)) {
            ; Check if process is still alive
            stillAlive := ProcessExist(wsE2EPid)
            Log("FAIL: WS E2E store pipe not ready within timeout (process " (stillAlive ? "alive" : "dead") ")")
            TestErrors++
            try ProcessClose(wsE2EPid)
            wsE2EPid := 0
        }
    }

    if (wsE2EPid) {
        wsE2EClient := IPC_PipeClient_Connect(wsE2EPipe, Test_OnWsE2EMessage)

        if (wsE2EClient.hPipe) {
            Log("PASS: E2E test connected to store")
            TestPassed++

            ; Send hello
            helloMsg := { type: IPC_MSG_HELLO, clientId: "ws_e2e_test", wants: { deltas: false } }
            IPC_PipeClient_Send(wsE2EClient, JSON.Dump(helloMsg))

            ; Poll for workspace data instead of fixed 1500ms sleep.
            ; Komorebi initial poll completes asynchronously after store starts.
            ; Exit early as soon as workspace data appears in projection.
            projMsg := { type: IPC_MSG_PROJECTION_REQUEST, projectionOpts: { sort: "Z", columns: "items", includeMinimized: true, includeCloaked: true } }
            pollStart := A_TickCount
            wsDataReady := false

            while (!wsDataReady && (A_TickCount - pollStart) < 5000) {
                gWsE2EResponse := ""
                gWsE2EReceived := false
                IPC_PipeClient_Send(wsE2EClient, JSON.Dump(projMsg))

                waitStart := A_TickCount
                while (!gWsE2EReceived && (A_TickCount - waitStart) < 1000)
                    Sleep(50)

                if (gWsE2EReceived) {
                    try {
                        checkObj := JSON.Load(gWsE2EResponse)
                        if (checkObj.Has("payload") && checkObj["payload"].Has("items")) {
                            checkItems := checkObj["payload"]["items"]
                            for _, item in checkItems {
                                if (item.Has("workspaceName") && item["workspaceName"] != "") {
                                    wsDataReady := true
                                    break
                                }
                            }
                        }
                    }
                }

                if (!wsDataReady)
                    Sleep(200)
            }

            komorebicPath := cfg.KomorebicExe

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

                        ; ============================================================
                        ; Workspace Switching Test (Part 2 of Workspace E2E)
                        ; ============================================================
                        ; Tests that store tracks workspace switches and preserves data
                        ; across workspaces. This is critical for cross-workspace activation.
                        ; INVASIVE: Actually switches workspaces, so gated behind --invasive flag.
                        if (!DoInvasiveTests) {
                            Log("SKIP: Workspace switching test (requires --invasive flag)")
                        } else if (FileExist(komorebicPath) && itemsWithWs >= 2) {
                            Log("`n--- Workspace Switching Test ---")

                            ; Build workspace -> windows map from current projection
                            wsWindows := Map()
                            for _, item in items {
                                wsName := item.Has("workspaceName") ? item["workspaceName"] : ""
                                if (wsName != "") {
                                    if (!wsWindows.Has(wsName))
                                        wsWindows[wsName] := 0
                                    wsWindows[wsName]++
                                }
                            }

                            ; Request projection with meta to get currentWSName
                            metaProjMsg := { type: IPC_MSG_PROJECTION_REQUEST, projectionOpts: { sort: "Z", columns: "items,meta", includeMinimized: true, includeCloaked: true } }
                            gWsE2EResponse := ""
                            gWsE2EReceived := false
                            IPC_PipeClient_Send(wsE2EClient, JSON.Dump(metaProjMsg))

                            waitStart := A_TickCount
                            while (!gWsE2EReceived && (A_TickCount - waitStart) < 2000)
                                Sleep(50)

                            if (gWsE2EReceived) {
                                try {
                                    metaRespObj := JSON.Load(gWsE2EResponse)
                                    currentWSName := ""
                                    if (metaRespObj.Has("payload") && metaRespObj["payload"].Has("meta"))
                                        currentWSName := metaRespObj["payload"]["meta"].Has("currentWSName") ? metaRespObj["payload"]["meta"]["currentWSName"] : ""

                                    ; Find a different workspace with windows to switch to
                                    targetWS := ""
                                    for ws, cnt in wsWindows {
                                        if (ws != currentWSName && cnt > 0) {
                                            targetWS := ws
                                            break
                                        }
                                    }

                                    if (currentWSName = "" || targetWS = "") {
                                        Log("SKIP: Cannot test workspace switching (currentWS='" currentWSName "', no target workspace available)")
                                    } else {
                                        Log("  Current workspace: '" currentWSName "', switching to: '" targetWS "'")

                                        ; Use komorebic to switch workspace
                                        switchCmd := 'cmd.exe /c ""' komorebicPath '" focus-named-workspace ' targetWS '"'
                                        _Test_RunWaitSilent(switchCmd)

                                        ; Poll for store to reflect workspace switch (adaptive, not fixed sleep)
                                        switchPollStart := A_TickCount
                                        switchedOk := false
                                        newWSName := ""

                                        while (!switchedOk && (A_TickCount - switchPollStart) < 5000) {
                                            gWsE2EResponse := ""
                                            gWsE2EReceived := false
                                            IPC_PipeClient_Send(wsE2EClient, JSON.Dump(metaProjMsg))

                                            waitStart := A_TickCount
                                            while (!gWsE2EReceived && (A_TickCount - waitStart) < 1000)
                                                Sleep(50)

                                            if (gWsE2EReceived) {
                                                try {
                                                    switchRespObj := JSON.Load(gWsE2EResponse)
                                                    if (switchRespObj.Has("payload") && switchRespObj["payload"].Has("meta")) {
                                                        newWSName := switchRespObj["payload"]["meta"].Has("currentWSName") ? switchRespObj["payload"]["meta"]["currentWSName"] : ""
                                                        if (newWSName = targetWS)
                                                            switchedOk := true
                                                    }
                                                }
                                            }

                                            if (!switchedOk)
                                                Sleep(200)
                                        }

                                        if (switchedOk) {
                                            Log("PASS: Store tracked workspace switch ('" currentWSName "' -> '" newWSName "')")
                                            TestPassed++

                                            ; Verify original workspace data persists
                                            try {
                                                switchRespObj := JSON.Load(gWsE2EResponse)
                                                switchItems := switchRespObj["payload"]["items"]
                                                originalWsCount := 0
                                                for _, item in switchItems {
                                                    wsName := item.Has("workspaceName") ? item["workspaceName"] : ""
                                                    if (wsName = currentWSName)
                                                        originalWsCount++
                                                }
                                                if (originalWsCount > 0) {
                                                    Log("PASS: Original workspace '" currentWSName "' data preserved (" originalWsCount " windows)")
                                                    TestPassed++
                                                } else {
                                                    Log("FAIL: Original workspace '" currentWSName "' data lost after switch")
                                                    TestErrors++
                                                }
                                            }
                                        } else {
                                            Log("FAIL: Store did not track workspace switch within timeout (expected '" targetWS "', got '" newWSName "')")
                                            TestErrors++
                                        }

                                        ; Switch back to original workspace
                                        Log("  Switching back to '" currentWSName "'...")
                                        switchBackCmd := 'cmd.exe /c ""' komorebicPath '" focus-named-workspace ' currentWSName '"'
                                        _Test_RunWaitSilent(switchBackCmd)
                                        Sleep(500)  ; Brief wait for switch to complete
                                    }
                                } catch as e {
                                    Log("SKIP: Workspace switching test parse error: " e.Message)
                                }
                            } else {
                                Log("SKIP: Workspace switching test - no meta response")
                            }
                        } else if (!FileExist(komorebicPath)) {
                            ; Already logged skip above
                        } else {
                            Log("SKIP: Workspace switching test (need >= 2 workspaces with windows, have " itemsWithWs ")")
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
    ; Store Liveness Test
    ; ============================================================
    ; Tests the store's liveness contract: a connected client receives periodic
    ; messages within the heartbeat interval. The store may send heartbeats,
    ; deltas, or snapshots — any message type proves liveness. When the store
    ; is actively pushing deltas (e.g., window events), heartbeat messages are
    ; suppressed by design (Store_HeartbeatTick skips when gStore_LastSendTick
    ; is recent). This test validates the contract, not the mechanism.
    Log("`n--- Store Liveness Test ---")

    ; Start a store with fast heartbeat interval (1s instead of default 5s)
    hbTestPipe := "tabby_hb_test_" A_TickCount
    hbTestPid := 0

    if (_Test_RunSilent('"' A_AhkPath '" /ErrorStdOut "' storePath '" --test --pipe=' hbTestPipe ' --heartbeat-ms=1000', &hbTestPid)) {
        Log("  [HB] Store launched (PID=" hbTestPid ", pipe=" hbTestPipe ", heartbeat=1000ms)")
    } else {
        Log("SKIP: Could not start store for liveness test")
        hbTestPid := 0
    }

    if (hbTestPid) {
        ; Wait for store pipe to become available
        ; Use 5s timeout to handle parallel test load
        if (!WaitForStorePipe(hbTestPipe, 5000)) {
            stillAlive := ProcessExist(hbTestPid)
            Log("FAIL: Liveness store pipe not ready within timeout (process " (stillAlive ? "alive" : "dead") ")")
            TestErrors++
            try ProcessClose(hbTestPid)
            hbTestPid := 0
        }
    }

    if (hbTestPid) {
        gHbTestHeartbeats := 0
        gHbTestLastRev := -1
        gHbTestReceived := false
        global gHbTestLivenessCount := 0

        hbClient := IPC_PipeClient_Connect(hbTestPipe, Test_OnHeartbeatMessage)

        if (hbClient.hPipe) {
            Log("PASS: Liveness test connected to store")
            TestPassed++

            ; Send hello to register as client
            helloMsg := { type: IPC_MSG_HELLO, clientId: "hb_test", wants: { deltas: true } }
            IPC_PipeClient_Send(hbClient, JSON.Dump(helloMsg))

            ; Wait for liveness messages. Any message type counts (heartbeat, delta,
            ; snapshot). On an active desktop, proactive WEH pushes may suppress
            ; heartbeats entirely — deltas serve the same liveness purpose.
            hbTimeoutMs := 15000
            Log("  Waiting for liveness messages (timeout=" hbTimeoutMs "ms)...")
            waitStart := A_TickCount
            while (gHbTestLivenessCount < 2 && (A_TickCount - waitStart) < hbTimeoutMs) {
                Sleep(100)
            }

            if (gHbTestLivenessCount >= 2) {
                Log("PASS: Received " gHbTestLivenessCount " liveness messages (" gHbTestHeartbeats " heartbeats, " (gHbTestLivenessCount - gHbTestHeartbeats) " deltas/other)")
                TestPassed++

                ; If heartbeat messages were received, verify they contain rev
                if (gHbTestHeartbeats > 0 && gHbTestLastRev >= 0) {
                    Log("PASS: Heartbeat contains rev field (rev=" gHbTestLastRev ")")
                    TestPassed++
                } else if (gHbTestHeartbeats > 0) {
                    Log("FAIL: Heartbeat missing rev field")
                    TestErrors++
                } else {
                    ; No heartbeats — deltas suppressed them. That's fine, still alive.
                    Log("  (No heartbeat messages — deltas provided liveness)")
                }
            } else {
                Log("FAIL: No liveness messages received within timeout (got " gHbTestLivenessCount ")")
                TestErrors++
            }

            IPC_PipeClient_Close(hbClient)
        } else {
            Log("FAIL: Could not connect to store for liveness test")
            TestErrors++
        }

        try {
            ProcessClose(hbTestPid)
        }
    }

}
