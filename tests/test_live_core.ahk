; Live Tests - Core Integration
; In-process WindowList pipeline, Producer State, Komorebi
; Included by test_live.ahk
#Include test_utils.ahk

RunLiveTests_Core() {
    global TestPassed, TestErrors, cfg

    ; ============================================================
    ; Live Integration Tests (WinEnumLite, WindowList pipeline)
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
    WL_Init()
    WL_BeginScan()
    WL_UpsertWindow(realWindows, "winenum_lite")
    WL_EndScan()

    proj := WL_GetDisplayList({ sort: "Z" })
    AssertTrue(proj.items.Length > 0, "Full pipeline produces display list (" proj.items.Length " items)")

    ; ============================================================
    ; DisplayList Fields Validation (in-process, real windows)
    ; ============================================================
    Log("`n--- DisplayList Fields Validation ---")

    if (proj.items.Length > 0) {
        sample := proj.items[1]
        requiredFields := ["hwnd", "title", "class", "pid", "z",
            "lastActivatedTick", "isFocused", "isCloaked", "isMinimized",
            "isOnCurrentWorkspace", "workspaceName", "processName"]
        missingFields := []
        for _, field in requiredFields {
            if (!sample.HasOwnProp(field)) {
                missingFields.Push(field)
            }
        }
        if (missingFields.Length = 0) {
            Log("PASS: DisplayList contains all required fields")
            TestPassed++
        } else {
            Log("FAIL: DisplayList missing fields: " _JoinArray(missingFields, ", "))
            TestErrors++
        }

        ; Validate field types
        if (IsInteger(sample.hwnd) && IsInteger(sample.pid)) {
            Log("PASS: hwnd and pid are integers")
            TestPassed++
        } else {
            Log("FAIL: hwnd or pid not integer (hwnd=" Type(sample.hwnd) ", pid=" Type(sample.pid) ")")
            TestErrors++
        }

        ; Validate all items have MRU sort field
        hasSortData := true
        for _, item in proj.items {
            if (!item.HasOwnProp("lastActivatedTick")) {
                hasSortData := false
                break
            }
        }
        if (hasSortData) {
            Log("PASS: All items have MRU sort field (lastActivatedTick)")
            TestPassed++
        } else {
            Log("FAIL: Some items missing lastActivatedTick")
            TestErrors++
        }
    }

    ; ============================================================
    ; MRU Sort Order Test (in-process)
    ; ============================================================
    Log("`n--- MRU Sort Order Test ---")

    mruProj := WL_GetDisplayList({ sort: "MRU" })
    if (mruProj.items.Length >= 2) {
        first := mruProj.items[1]
        second := mruProj.items[2]
        firstTick := first.lastActivatedTick
        secondTick := second.lastActivatedTick
        if (firstTick >= secondTick) {
            Log("PASS: MRU sort order correct (first=" firstTick ", second=" secondTick ")")
            TestPassed++
        } else {
            Log("FAIL: MRU sort order wrong (first=" firstTick " < second=" secondTick ")")
            TestErrors++
        }
    } else {
        Log("SKIP: MRU sort check needs >= 2 items, got " mruProj.items.Length)
    }

    ; ============================================================
    ; Producer State In-Process Test
    ; ============================================================
    Log("`n--- Producer State In-Process Test ---")

    ; Get display list with meta to check producer states
    metaProj := WL_GetDisplayList({ sort: "Z", columns: "items,meta" })
    if (metaProj.HasOwnProp("meta") && metaProj.meta.HasOwnProp("producers")) {
        producers := metaProj.meta.producers
        Log("PASS: DisplayList meta contains producer states")
        TestPassed++

        ; Check expected producer fields exist
        expectedProducers := ["wineventHook", "mruLite", "komorebiSub", "komorebiLite", "iconPump", "procPump"]
        prodCount := 0
        for _, pname in expectedProducers {
            pstate := ""
            try pstate := producers.%pname%
            if (pstate != "")
                prodCount++
        }

        if (prodCount >= 4) {
            Log("PASS: Found " prodCount " producer states in meta")
            TestPassed++
        } else {
            Log("FAIL: Expected at least 4 producer states, got " prodCount)
            TestErrors++
        }

        ; wineventHook should have a valid state (we set it in WL_Init)
        wehState := ""
        try wehState := producers.wineventHook
        if (wehState = "running" || wehState = "failed" || wehState = "disabled") {
            Log("PASS: wineventHook state is valid (" wehState ")")
            TestPassed++
        } else {
            Log("FAIL: wineventHook state invalid or missing (got: '" wehState "')")
            TestErrors++
        }
    } else {
        Log("SKIP: DisplayList meta does not contain producer states (meta may not be populated in test mode)")
    }

    ; ============================================================
    ; ValidateExistence with Real Windows
    ; ============================================================
    Log("`n--- ValidateExistence Real Window Test ---")

    ; Add a fake HWND alongside real windows, then validate should remove it
    global gWS_Store
    fakeHwnd := 0xDEAD0001
    gWS_Store[fakeHwnd] := Map(
        "hwnd", fakeHwnd, "title", "FakeWindow", "class", "FakeClass",
        "pid", 0, "z", 999, "lastActivatedTick", 0, "isFocused", false,
        "isCloaked", false, "isMinimized", false, "isOnCurrentWorkspace", true,
        "workspaceName", "", "processName", "", "iconHicon", 0
    )
    prevCount := 0
    for _ in gWS_Store
        prevCount++

    result := WL_ValidateExistence()

    afterCount := 0
    for _ in gWS_Store
        afterCount++

    if (!gWS_Store.Has(fakeHwnd)) {
        Log("PASS: ValidateExistence removed fake HWND (before=" prevCount ", after=" afterCount ")")
        TestPassed++
    } else {
        Log("FAIL: ValidateExistence did not remove fake HWND")
        TestErrors++
        gWS_Store.Delete(fakeHwnd)
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
                monitorsArr := KSub_GetMonitorsArray(stateObj)
                for _, monObj in monitorsArr {
                    for _, wsObj in KSub_GetWorkspacesArray(monObj) {
                        wsName := KSafe_Str(wsObj, "name")
                        if (wsName != "")
                            wsCount++
                        ; Count hwnds in containers
                        if (wsObj is Map && wsObj.Has("containers")) {
                            for _, cont in KSafe_Elements(wsObj["containers"]) {
                                if !(cont is Map)
                                    continue
                                if (cont.Has("windows")) {
                                    for _, win in KSafe_Elements(cont["windows"]) {
                                        if (win is Map && win.Has("hwnd")) {
                                            hwndCount++
                                            if (!firstHwnd)
                                                firstHwnd := KSafe_Int(win, "hwnd")
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

                    ; Test KSub_FindWorkspaceByHwnd with parsed state
                    if (firstHwnd > 0) {
                        wsName := KSub_FindWorkspaceByHwnd(stateObj, firstHwnd)
                        if (wsName != "") {
                            Log("PASS: KSub_FindWorkspaceByHwnd returned '" wsName "' for hwnd " firstHwnd)
                            TestPassed++
                        } else {
                            Log("FAIL: KSub_FindWorkspaceByHwnd returned empty for hwnd " firstHwnd)
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
    ; OVERLAPPED Async I/O Tests
    ; ============================================================
    Log("`n--- OVERLAPPED Async I/O Tests ---")

    ; Test 1: OVERLAPPED library loads and MCode initializes correctly
    ; Create a test pipe and verify BindIoCompletionCallback works
    _Test_OverlappedLibrary()

    ; Test 2: Async subscription lifecycle (requires komorebi)
    if (FileExist(cfg.KomorebicExe))
        _Test_AsyncSubscriptionLifecycle()
    else
        Log("SKIP: Async subscription lifecycle (komorebic.exe not found)")

}

; Test that the OVERLAPPED library loads, creates MCode, and binds to a pipe handle.
; Does NOT require komorebi — uses a standalone test pipe.
_Test_OverlappedLibrary() {
    global TestPassed, TestErrors

    ; Create a test pipe with FILE_FLAG_OVERLAPPED
    PIPE_ACCESS_DUPLEX := 0x00000003
    FILE_FLAG_OVERLAPPED := 0x40000000
    PIPE_TYPE_BYTE := 0x00000000
    pipeName := "\\.\pipe\tabby_test_overlapped_" A_TickCount
    hPipe := DllCall("CreateNamedPipeW"
        , "str", pipeName
        , "uint", PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED
        , "uint", PIPE_TYPE_BYTE
        , "uint", 1, "uint", 4096, "uint", 4096, "uint", 0, "ptr", 0
        , "ptr")

    if (hPipe = 0 || hPipe = -1) {
        Log("FAIL: OVERLAPPED test pipe creation failed (err=" DllCall("GetLastError", "uint") ")")
        TestErrors++
        return
    }
    Log("PASS: Test pipe created for OVERLAPPED test")
    TestPassed++

    ; Test: OVERLAPPED class instantiation
    overObj := 0
    try {
        overObj := OVERLAPPED((this, err, bytes) => 0)
        Log("PASS: OVERLAPPED class instantiated")
        TestPassed++
    } catch as e {
        Log("FAIL: OVERLAPPED class instantiation failed: " e.Message)
        TestErrors++
        DllCall("CloseHandle", "ptr", hPipe)
        return
    }

    ; Test: EnableIoCompletionCallback (binds MCode trampoline)
    try {
        OVERLAPPED.EnableIoCompletionCallback(hPipe)
        Log("PASS: EnableIoCompletionCallback succeeded (MCode loaded)")
        TestPassed++
    } catch as e {
        Log("FAIL: EnableIoCompletionCallback failed: " e.Message)
        TestErrors++
    }

    ; Test: OVERLAPPED properties accessible
    try {
        ev := overObj.hEvent
        pend := overObj.Pending
        AssertTrue(ev != 0, "OVERLAPPED.hEvent is non-zero")
        AssertTrue(pend = 0, "OVERLAPPED.Pending is 0 before I/O")
    } catch as e {
        Log("FAIL: OVERLAPPED property access: " e.Message)
        TestErrors++
    }

    ; Cleanup
    try overObj.SafeDelete(hPipe)
    try DllCall("CloseHandle", "ptr", hPipe)
}

; Test async subscription lifecycle: init → connect → async mode → stop.
; Requires komorebi running.
_Test_AsyncSubscriptionLifecycle() {
    global TestPassed, TestErrors, cfg
    global _KSub_AsyncMode, _KSub_Connected, _KSub_ReadPending, _KSub_hPipe

    Log("`n  --- Async Subscription Lifecycle ---")

    ; Initialize subscription (creates pipe, launches subscriber, tries async)
    try {
        result := KomorebiSub_Init()
        if (!result) {
            Log("SKIP: KomorebiSub_Init returned false (komorebi may not be running)")
            return
        }
        Log("PASS: KomorebiSub_Init succeeded")
        TestPassed++
    } catch as e {
        Log("FAIL: KomorebiSub_Init threw: " e.Message)
        TestErrors++
        return
    }

    ; Wait for connection (komorebic subscribe-pipe takes a moment)
    connected := false
    deadline := A_TickCount + 3000
    while (A_TickCount < deadline) {
        if (_KSub_Connected) {
            connected := true
            break
        }
        Sleep(50)
    }

    if (connected) {
        Log("PASS: Komorebi subscription connected")
        TestPassed++

        ; Verify async mode is active (OVERLAPPED bound)
        if (_KSub_AsyncMode) {
            Log("PASS: Async I/O mode active (_KSub_AsyncMode=true)")
            TestPassed++
        } else {
            ; Not a failure — async may not be available, legacy poll is fine
            Log("WARN: Async mode not active, legacy polling in use")
        }

        ; Verify a read is pending (async ReadFile issued)
        if (_KSub_AsyncMode && _KSub_ReadPending) {
            Log("PASS: Async read is pending (_KSub_ReadPending=true)")
            TestPassed++
        } else if (_KSub_AsyncMode) {
            Log("WARN: Async mode active but no read pending")
        }

        ; Verify pipe handle is valid
        AssertTrue(_KSub_hPipe != 0, "Pipe handle is non-zero while connected")
    } else {
        Log("SKIP: Connection timed out (komorebi may not be running or pipe busy)")
    }

    ; Stop subscription — verify clean shutdown
    KomorebiSub_Stop()
    AssertTrue(_KSub_AsyncMode = false, "AsyncMode is false after Stop")
    AssertTrue(_KSub_ReadPending = false, "ReadPending is false after Stop")
    AssertTrue(_KSub_hPipe = 0, "Pipe handle is 0 after Stop")
    Log("PASS: KomorebiSub_Stop cleanup verified")
    TestPassed++
}
