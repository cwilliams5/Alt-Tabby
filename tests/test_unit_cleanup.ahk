; Unit Tests - Cleanup & Shutdown
; GDI+ Shutdown, Icon Cache Cleanup, IPC Critical Section, OnExit Handlers,
; Function References, Client Disconnect, Buffer Overflow, Workspace Cache,
; Idle Timer Pause, Hot Path Static Buffers
; Included by test_unit.ahk

RunUnitTests_Cleanup() {
    global TestPassed, TestErrors, cfg

    ; ============================================================
    ; LogTrim Log Rotation Tests
    ; ============================================================
    ; Verify LogTrim correctly trims large files, preserves tail content,
    ; and handles edge cases (under threshold, nonexistent, empty).
    Log("`n--- LogTrim Log Rotation Tests ---")

    ; Test 1: File under 100KB should not be modified
    Log("Testing LogTrim does not modify small file...")
    testLogPath := A_Temp "\tabby_logtrim_test_" A_TickCount ".log"
    try {
        smallContent := ""
        Loop 100 {
            smallContent .= "Log line " A_Index " - some padding text here`n"
        }
        FileAppend(smallContent, testLogPath, "UTF-8")
        sizeBefore := FileGetSize(testLogPath)

        LogTrim(testLogPath)

        sizeAfter := FileGetSize(testLogPath)
        if (sizeBefore = sizeAfter) {
            Log("PASS: LogTrim did not modify small file (" sizeBefore " bytes)")
            TestPassed++
        } else {
            Log("FAIL: LogTrim should not modify file under threshold (" sizeBefore " -> " sizeAfter ")")
            TestErrors++
        }
        try FileDelete(testLogPath)
    } catch as e {
        Log("FAIL: LogTrim small file test error: " e.Message)
        TestErrors++
        try FileDelete(testLogPath)
    }

    ; Test 2: File over 100KB should be trimmed to ~50KB
    Log("Testing LogTrim trims large file to ~50KB...")
    testLogPath := A_Temp "\tabby_logtrim_test_" A_TickCount ".log"
    try {
        ; Build a file > 102400 bytes (100KB). Each line is ~100 chars.
        ; 1200 lines * 100 chars = ~120KB (well over threshold)
        largeContent := ""
        Loop 1200 {
            largeContent .= "Line " Format("{:04d}", A_Index) " - " "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGH" "`n"
        }
        FileAppend(largeContent, testLogPath, "UTF-8")
        sizeBefore := FileGetSize(testLogPath)

        LogTrim(testLogPath)

        sizeAfter := FileGetSize(testLogPath)
        if (sizeAfter < sizeBefore && sizeAfter <= 60000) {
            Log("PASS: LogTrim trimmed file from " sizeBefore " to " sizeAfter " bytes")
            TestPassed++
        } else {
            Log("FAIL: LogTrim should trim to ~50KB (before=" sizeBefore ", after=" sizeAfter ")")
            TestErrors++
        }
        try FileDelete(testLogPath)
    } catch as e {
        Log("FAIL: LogTrim large file test error: " e.Message)
        TestErrors++
        try FileDelete(testLogPath)
    }

    ; Test 3: Non-existent file should not error
    Log("Testing LogTrim handles non-existent file...")
    try {
        LogTrim(A_Temp "\tabby_nonexistent_" A_TickCount ".log")
        Log("PASS: LogTrim did not error on non-existent file")
        TestPassed++
    } catch as e {
        Log("FAIL: LogTrim should not error on non-existent file: " e.Message)
        TestErrors++
    }

    ; Test 4: Empty file should not error
    Log("Testing LogTrim handles empty file...")
    testLogPath := A_Temp "\tabby_logtrim_empty_" A_TickCount ".log"
    try {
        FileAppend("", testLogPath, "UTF-8")
        LogTrim(testLogPath)
        sizeAfter := FileGetSize(testLogPath)
        if (sizeAfter <= 3) {  ; BOM may add a few bytes
            Log("PASS: LogTrim did not error on empty file (size=" sizeAfter ")")
            TestPassed++
        } else {
            Log("FAIL: LogTrim should not grow empty file (size=" sizeAfter ")")
            TestErrors++
        }
        try FileDelete(testLogPath)
    } catch as e {
        Log("FAIL: LogTrim empty file test error: " e.Message)
        TestErrors++
        try FileDelete(testLogPath)
    }

    ; Test 5: Trimmed file retains TAIL content (last lines preserved)
    Log("Testing LogTrim preserves tail content...")
    testLogPath := A_Temp "\tabby_logtrim_tail_" A_TickCount ".log"
    try {
        ; Generate > 102400 bytes. 1300 lines × ~100 chars = ~130KB
        largeContent := ""
        Loop 1300 {
            largeContent .= "Line " Format("{:04d}", A_Index) " PADDING-PADDING-PADDING-PADDING-PADDING-PADDING-PADDING-PADDING-PADDING-PAD`n"
        }
        FileAppend(largeContent, testLogPath, "UTF-8")
        sizeBefore := FileGetSize(testLogPath)

        if (sizeBefore <= 102400) {
            Log("SKIP: LogTrim tail test: content only " sizeBefore " bytes (need > 102400)")
        } else {
            LogTrim(testLogPath)

            trimmedContent := FileRead(testLogPath)
            ; Last line (1300) should be preserved since LogTrim keeps tail
            hasLastLine := InStr(trimmedContent, "Line 1300")
            ; First line should be gone (trimmed from head)
            hasFirstLine := InStr(trimmedContent, "Line 0001")
            if (hasLastLine && !hasFirstLine) {
                Log("PASS: LogTrim preserved tail (has Line 1300, no Line 0001)")
                TestPassed++
            } else {
                Log("FAIL: LogTrim should keep tail, remove head (last=" hasLastLine ", first=" hasFirstLine ", beforeSize=" sizeBefore ")")
                TestErrors++
            }
        }
        try FileDelete(testLogPath)
    } catch as e {
        Log("FAIL: LogTrim tail preservation test error: " e.Message)
        TestErrors++
        try FileDelete(testLogPath)
    }

    ; Test 6: File exactly at threshold (100KB = 102400 bytes) should NOT be trimmed
    Log("Testing LogTrim does not trim at exact threshold...")
    testLogPath := A_Temp "\tabby_logtrim_exact_" A_TickCount ".log"
    try {
        ; Build content close to exactly 102400 bytes
        exactContent := ""
        lineLen := 80  ; approximate bytes per line
        targetLines := 102400 // lineLen  ; ~1280 lines
        Loop targetLines {
            exactContent .= "X" Format("{:04d}", A_Index) " - " "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrs" "`n"
        }
        FileAppend(exactContent, testLogPath, "UTF-8")
        sizeBefore := FileGetSize(testLogPath)

        LogTrim(testLogPath)

        sizeAfter := FileGetSize(testLogPath)
        ; At exactly threshold or below, should not trim
        if (sizeBefore <= 102400 && sizeBefore = sizeAfter) {
            Log("PASS: LogTrim did not trim file at threshold (" sizeBefore " bytes)")
            TestPassed++
        } else if (sizeBefore > 102400 && sizeAfter < sizeBefore) {
            ; If our content happened to go slightly over, trimming is correct
            Log("PASS: LogTrim correctly trimmed file just over threshold (" sizeBefore " -> " sizeAfter ")")
            TestPassed++
        } else {
            Log("FAIL: LogTrim threshold behavior unexpected (before=" sizeBefore ", after=" sizeAfter ")")
            TestErrors++
        }
        try FileDelete(testLogPath)
    } catch as e {
        Log("FAIL: LogTrim threshold test error: " e.Message)
        TestErrors++
        try FileDelete(testLogPath)
    }

    ; ============================================================
    ; GDI+ Shutdown Tests (Code Inspection)
    ; ============================================================
    ; NOTE: These tests use code inspection (FileRead + InStr) rather than
    ; execution because gui_gdip.ahk requires an active graphics context
    ; (GDI+ token, device contexts, etc.) that cannot be safely initialized
    ; in a headless test environment.
    ;
    ; This approach verifies that:
    ; - Cleanup functions EXIST with proper patterns
    ; - Required DLL calls are present (GdiplusShutdown, GdipDeleteGraphics)
    ; - Global state is cleared to prevent resource leaks
    ;
    ; LIMITATIONS: Cannot verify functions execute correctly at runtime.
    ; Live testing (running the actual GUI) validates actual shutdown behavior.
    ; These are REGRESSION GUARDS - they catch accidental removal of cleanup code.
    Log("`n--- GDI+ Shutdown Tests ---")

    ; Test 1: Gdip_Shutdown function exists in source
    Log("Testing Gdip_Shutdown() function exists in gui_gdip.ahk...")
    try {
        gdipPath := A_ScriptDir "\..\src\gui\gui_gdip.ahk"
        if (FileExist(gdipPath)) {
            gdipCode := FileRead(gdipPath)

            hasFunctionDef := InStr(gdipCode, "Gdip_Shutdown()")
            hasTokenCleanup := InStr(gdipCode, "GdiplusShutdown")
            hasGraphicsCleanup := InStr(gdipCode, "GdipDeleteGraphics")

            if (hasFunctionDef && hasTokenCleanup && hasGraphicsCleanup) {
                Log("PASS: Gdip_Shutdown() exists with proper cleanup calls")
                TestPassed++
            } else {
                Log("FAIL: Gdip_Shutdown() missing or incomplete (def=" hasFunctionDef ", token=" hasTokenCleanup ", graphics=" hasGraphicsCleanup ")")
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find gui_gdip.ahk")
        }
    } catch as e {
        Log("FAIL: Gdip_Shutdown code inspection error: " e.Message)
        TestErrors++
    }

    ; Test 2: Gdip_Shutdown clears all GDI+ globals
    Log("Testing Gdip_Shutdown() clears all required globals...")
    try {
        gdipPath := A_ScriptDir "\..\src\gui\gui_gdip.ahk"
        if (FileExist(gdipPath)) {
            gdipCode := FileRead(gdipPath)

            ; Check that it clears all the key globals
            clearsToken := InStr(gdipCode, "gGdip_Token := 0")
            clearsG := InStr(gdipCode, "gGdip_G := 0")
            clearsHdc := InStr(gdipCode, "gGdip_BackHdc := 0")
            clearsHBM := InStr(gdipCode, "gGdip_BackHBM := 0")

            if (clearsToken && clearsG && clearsHdc && clearsHBM) {
                Log("PASS: Gdip_Shutdown() clears all GDI+ globals")
                TestPassed++
            } else {
                Log("FAIL: Gdip_Shutdown() should clear all globals (token=" clearsToken ", G=" clearsG ", Hdc=" clearsHdc ", HBM=" clearsHBM ")")
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find gui_gdip.ahk")
        }
    } catch as e {
        Log("FAIL: Gdip_Shutdown globals check error: " e.Message)
        TestErrors++
    }

    ; Test 3: Gdip_Shutdown calls Gdip_DisposeResources for brush/font cleanup
    Log("Testing Gdip_Shutdown() calls Gdip_DisposeResources()...")
    try {
        gdipPath := A_ScriptDir "\..\src\gui\gui_gdip.ahk"
        if (FileExist(gdipPath)) {
            gdipCode := FileRead(gdipPath)

            callsDispose := InStr(gdipCode, "Gdip_DisposeResources()")

            if (callsDispose) {
                Log("PASS: Gdip_Shutdown() calls Gdip_DisposeResources()")
                TestPassed++
            } else {
                Log("FAIL: Gdip_Shutdown() should call Gdip_DisposeResources()")
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find gui_gdip.ahk")
        }
    } catch as e {
        Log("FAIL: Gdip_DisposeResources check error: " e.Message)
        TestErrors++
    }

    ; ============================================================
    ; Icon Cache Cleanup Tests (Resource Leak Prevention)
    ; ============================================================
    Log("`n--- Icon Cache Cleanup Tests ---")

    ; Test 1: WindowStore_CleanupExeIconCache clears the cache
    Log("Testing WindowStore_CleanupExeIconCache()...")
    try {
        global gWS_ExeIconCache

        ; Add a test entry (use 0 as fake icon to avoid actual icon creation)
        testExePath := "C:\test\fake.exe"
        gWS_ExeIconCache[testExePath] := 0  ; 0 = no real icon, just testing map

        ; Verify it's in the cache
        beforeCount := gWS_ExeIconCache.Count
        hasTestEntry := gWS_ExeIconCache.Has(testExePath)

        if (!hasTestEntry) {
            Log("FAIL: Could not add test entry to icon cache")
            TestErrors++
        } else {
            ; Call cleanup
            WindowStore_CleanupExeIconCache()

            ; Verify cache is empty
            if (gWS_ExeIconCache.Count = 0) {
                Log("PASS: WindowStore_CleanupExeIconCache() clears all entries")
                TestPassed++
            } else {
                Log("FAIL: Cache should be empty after cleanup, has " gWS_ExeIconCache.Count " entries")
                TestErrors++
            }
        }
    } catch as e {
        Log("FAIL: WindowStore_CleanupExeIconCache() error: " e.Message)
        TestErrors++
    }

    ; Test 2: WindowStore_CleanupAllIcons zeros iconHicon in store records
    Log("Testing WindowStore_CleanupAllIcons()...")
    try {
        global gWS_Store

        ; Initialize store and add test window with fake icon
        WindowStore_Init()
        WindowStore_BeginScan()

        testHwnd := 44444
        testRec := Map()
        testRec["hwnd"] := testHwnd
        testRec["title"] := "Icon Cleanup Test Window"
        testRec["class"] := "TestClass"
        testRec["pid"] := 444
        testRec["isVisible"] := true
        testRec["isCloaked"] := false
        testRec["isMinimized"] := false
        testRec["z"] := 1
        testRec["iconHicon"] := 99999  ; Fake icon handle
        WindowStore_UpsertWindow([testRec], "test")
        WindowStore_EndScan()

        ; Verify icon is set
        if (!gWS_Store.Has(testHwnd) || gWS_Store[testHwnd].iconHicon != 99999) {
            Log("FAIL: Could not set up test window with icon")
            TestErrors++
        } else {
            ; Call actual production function
            ; Note: DestroyIcon on fake handles fails silently (returns 0) - safe to test
            WindowStore_CleanupAllIcons()

            ; Verify icon was cleared
            if (gWS_Store[testHwnd].iconHicon = 0) {
                Log("PASS: WindowStore_CleanupAllIcons() zeros iconHicon field")
                TestPassed++
            } else {
                Log("FAIL: iconHicon should be 0 after cleanup")
                TestErrors++
            }
        }

        ; Clean up test window
        WindowStore_RemoveWindow([testHwnd], true)
    } catch as e {
        Log("FAIL: WindowStore_CleanupAllIcons() error: " e.Message)
        TestErrors++
    }

    ; Test 3: Exe icon cache eviction at 100 entries
    Log("Testing exe icon cache LRU eviction at 100 entries...")
    try {
        global gWS_ExeIconCache

        ; Clear cache first
        gWS_ExeIconCache := Map()

        ; Add 100 entries directly (bypassing the function to set up initial state)
        Loop 100 {
            gWS_ExeIconCache["C:\test\app" A_Index ".exe"] := 0
        }

        if (gWS_ExeIconCache.Count != 100) {
            Log("FAIL: Could not populate cache with 100 entries")
            TestErrors++
        } else {
            ; Add 101st entry via the function (should evict one and add new)
            ; Note: We use a non-zero value because the function checks for valid hIcon
            WindowStore_ExeIconCachePut("C:\test\app_new.exe", 1)

            ; Should still be 100 (one evicted, one added)
            if (gWS_ExeIconCache.Count = 100) {
                Log("PASS: Cache eviction maintains 100 entry limit")
                TestPassed++

                ; Verify the new entry is present
                if (gWS_ExeIconCache.Has("C:\test\app_new.exe")) {
                    Log("PASS: New entry added after eviction")
                    TestPassed++
                } else {
                    Log("FAIL: New entry should be in cache after eviction")
                    TestErrors++
                }
            } else {
                Log("FAIL: Cache should have 100 entries, has " gWS_ExeIconCache.Count)
                TestErrors++
            }
        }

        ; Clean up
        gWS_ExeIconCache := Map()
    } catch as e {
        Log("FAIL: Cache eviction test error: " e.Message)
        TestErrors++
    }

    ; ============================================================
    ; IPC Critical Section Tests (Race Condition Prevention)
    ; ============================================================
    Log("`n--- IPC Critical Section Tests ---")

    ; Test 1: IPC_PipeServer_Broadcast handles empty client map
    Log("Testing IPC_PipeServer_Broadcast() with empty clients...")
    try {
        ; Create a mock server with no clients
        mockServer := {
            pipeName: "test_pipe",
            clients: Map(),
            pending: [],
            timerFn: 0,
            tickMs: 100,
            idleStreak: 0
        }

        ; Broadcast should return 0 and not crash
        result := IPC_PipeServer_Broadcast(mockServer, "test message")

        if (result = 0) {
            Log("PASS: Broadcast with empty clients returns 0")
            TestPassed++
        } else {
            Log("FAIL: Broadcast with empty clients should return 0, got " result)
            TestErrors++
        }
    } catch as e {
        Log("FAIL: Broadcast empty clients test error: " e.Message)
        TestErrors++
    }

    ; Test 2: IPC__ServerTick handles empty server gracefully
    Log("Testing IPC__ServerTick() with minimal server...")
    try {
        ; Create a minimal mock server
        mockServer := {
            pipeName: "test_tick_pipe",
            clients: Map(),
            pending: [],
            timerFn: 0,
            tickMs: 100,
            idleStreak: 0,
            onMessage: (line, hPipe) => 0
        }

        ; ServerTick should not crash with empty state
        IPC__ServerTick(mockServer)

        Log("PASS: IPC__ServerTick() handles empty server without crash")
        TestPassed++
    } catch as e {
        Log("FAIL: IPC__ServerTick() error: " e.Message)
        TestErrors++
    }

    ; Test 3: Verify Critical sections exist in IPC functions (code inspection)
    Log("Testing IPC functions have Critical sections (code check)...")
    try {
        ; Read the IPC source file and verify Critical is present within specific functions
        ipcPath := A_ScriptDir "\..\src\shared\ipc_pipe.ahk"
        if (FileExist(ipcPath)) {
            ipcCode := FileRead(ipcPath)

            ; Check for Critical in ServerTick function body
            serverTickBody := _Test_ExtractFuncBody(ipcCode, "IPC__ServerTick")
            hasServerTickCritical := InStr(serverTickBody, 'Critical "On"')

            ; Check for Critical in Broadcast function body
            broadcastBody := _Test_ExtractFuncBody(ipcCode, "IPC_PipeServer_Broadcast")
            hasBroadcastCritical := InStr(broadcastBody, 'Critical "On"')

            if (hasServerTickCritical && hasBroadcastCritical) {
                Log("PASS: IPC functions contain Critical sections")
                TestPassed++
            } else {
                Log("FAIL: IPC functions missing Critical sections (ServerTick=" hasServerTickCritical ", Broadcast=" hasBroadcastCritical ")")
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find ipc_pipe.ahk for code inspection")
        }
    } catch as e {
        Log("FAIL: IPC code inspection error: " e.Message)
        TestErrors++
    }

    ; ============================================================
    ; OnExit Handler Registration Tests
    ; ============================================================
    Log("`n--- OnExit Handler Registration Tests ---")

    ; Test 1: Viewer OnExit wrapper function exists
    Log("Testing _Viewer_OnExitWrapper() function exists...")
    try {
        ; Check if the function exists in the viewer module
        viewerPath := A_ScriptDir "\..\src\viewer\viewer.ahk"
        if (FileExist(viewerPath)) {
            viewerCode := FileRead(viewerPath)

            hasWrapper := InStr(viewerCode, "_Viewer_OnExitWrapper")
            hasOnExitReg := InStr(viewerCode, "OnExit(_Viewer_OnExitWrapper)")

            if (hasWrapper && hasOnExitReg) {
                Log("PASS: Viewer has _Viewer_OnExitWrapper and registers OnExit")
                TestPassed++
            } else {
                Log("FAIL: Viewer missing OnExit setup (wrapper=" hasWrapper ", registration=" hasOnExitReg ")")
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find viewer.ahk for code inspection")
        }
    } catch as e {
        Log("FAIL: Viewer OnExit check error: " e.Message)
        TestErrors++
    }

    ; Test 2: GUI OnExit handler exists
    Log("Testing GUI _GUI_OnExit() registration...")
    try {
        guiPath := A_ScriptDir "\..\src\gui\gui_main.ahk"
        if (FileExist(guiPath)) {
            guiCode := FileRead(guiPath)

            hasOnExit := InStr(guiCode, "_GUI_OnExit")
            hasRegistration := InStr(guiCode, "OnExit(_GUI_OnExit)")

            if (hasOnExit && hasRegistration) {
                Log("PASS: GUI has _GUI_OnExit and registers OnExit")
                TestPassed++
            } else {
                Log("FAIL: GUI missing OnExit setup (handler=" hasOnExit ", registration=" hasRegistration ")")
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find gui_main.ahk for code inspection")
        }
    } catch as e {
        Log("FAIL: GUI OnExit check error: " e.Message)
        TestErrors++
    }

    ; Test 3: Store OnExit handler calls icon cleanup
    Log("Testing Store_OnExit() calls icon cleanup...")
    try {
        storePath := A_ScriptDir "\..\src\store\store_server.ahk"
        if (FileExist(storePath)) {
            storeCode := FileRead(storePath)
            onExitBody := _Test_ExtractFuncBody(storeCode, "Store_OnExit")

            if (onExitBody = "") {
                Log("FAIL: Could not extract Store_OnExit function body")
                TestErrors++
            } else {
                hasCleanupAllIcons := InStr(onExitBody, "WindowStore_CleanupAllIcons()")
                hasCleanupExeCache := InStr(onExitBody, "WindowStore_CleanupExeIconCache()")

                if (hasCleanupAllIcons && hasCleanupExeCache) {
                    Log("PASS: Store_OnExit calls both icon cleanup functions")
                    TestPassed++
                } else {
                    Log("FAIL: Store_OnExit missing cleanup calls (AllIcons=" hasCleanupAllIcons ", ExeCache=" hasCleanupExeCache ")")
                    TestErrors++
                }
            }
        } else {
            Log("SKIP: Could not find store_server.ahk for code inspection")
        }
    } catch as e {
        Log("FAIL: Store OnExit check error: " e.Message)
        TestErrors++
    }

    ; Test 4: GUI calls Gdip_Shutdown in OnExit
    Log("Testing GUI _GUI_OnExit() calls Gdip_Shutdown()...")
    try {
        guiPath := A_ScriptDir "\..\src\gui\gui_main.ahk"
        if (FileExist(guiPath)) {
            guiCode := FileRead(guiPath)
            onExitBody := _Test_ExtractFuncBody(guiCode, "_GUI_OnExit")

            if (onExitBody = "") {
                Log("FAIL: Could not extract _GUI_OnExit function body")
                TestErrors++
            } else {
                hasGdipShutdown := InStr(onExitBody, "Gdip_Shutdown()")

                if (hasGdipShutdown) {
                    Log("PASS: GUI _GUI_OnExit calls Gdip_Shutdown()")
                    TestPassed++
                } else {
                    Log("FAIL: GUI _GUI_OnExit should call Gdip_Shutdown()")
                    TestErrors++
                }
            }
        } else {
            Log("SKIP: Could not find gui_main.ahk for code inspection")
        }
    } catch as e {
        Log("FAIL: GUI Gdip_Shutdown check error: " e.Message)
        TestErrors++
    }

    ; ============================================================
    ; Function Reference Validation Tests
    ; ============================================================
    ; Ensure called functions match defined functions (prevent typos)
    Log("`n--- Function Reference Validation Tests ---")

    ; Test: _KSub_* function calls match definitions
    Log("Testing komorebi function references match definitions...")
    try {
        ksubPath := A_ScriptDir "\..\src\store\komorebi_sub.ahk"
        kstatePath := A_ScriptDir "\..\src\store\komorebi_state.ahk"
        kjsonPath := A_ScriptDir "\..\src\store\komorebi_json.ahk"

        if (FileExist(ksubPath) && FileExist(kstatePath)) {
            ksubCode := FileRead(ksubPath)
            kstateCode := FileRead(kstatePath)
            kjsonCode := FileExist(kjsonPath) ? FileRead(kjsonPath) : ""
            allCode := ksubCode . kstateCode . kjsonCode

            ; Find all _KSub_* function definitions
            definedFuncs := Map()
            pos := 1
            while (pos := RegExMatch(allCode, "(_KSub_\w+)\s*\(", &m, pos)) {
                ; Check if this is a definition (has opening brace after params)
                afterMatch := SubStr(allCode, pos + StrLen(m[]), 200)
                if (RegExMatch(afterMatch, "^\s*[^)]*\)\s*\{")) {
                    definedFuncs[m[1]] := true
                }
                pos += StrLen(m[])
            }

            ; Check for undefined _KSub_* calls (specifically _KSub_Log which was a bug)
            undefinedCalls := []
            if (InStr(allCode, "_KSub_Log(") && !definedFuncs.Has("_KSub_Log")) {
                undefinedCalls.Push("_KSub_Log (should be _KSub_DiagLog)")
            }

            if (undefinedCalls.Length = 0) {
                Log("PASS: All _KSub_* function calls have matching definitions")
                TestPassed++
            } else {
                Log("FAIL: Undefined function calls found: " _ArrayJoin(undefinedCalls, ", "))
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find komorebi source files")
        }
    } catch as e {
        Log("FAIL: Function reference check error: " e.Message)
        TestErrors++
    }

    ; ============================================================
    ; Client Disconnect Cleanup Tests
    ; ============================================================
    Log("`n--- Client Disconnect Cleanup Tests ---")

    ; Test: IPC server supports onDisconnect callback
    Log("Testing IPC server has onDisconnect callback support...")
    try {
        ipcPath := A_ScriptDir "\..\src\shared\ipc_pipe.ahk"
        if (FileExist(ipcPath)) {
            code := FileRead(ipcPath)

            hasParam := InStr(code, "onDisconnectFn")
            hasCallback := InStr(code, "onDisconnect:")
            callsCallback := InStr(code, "server.onDisconnect")

            if (hasParam && hasCallback && callsCallback) {
                Log("PASS: IPC server has onDisconnect callback support")
                TestPassed++
            } else {
                Log("FAIL: IPC server missing disconnect callback (param=" hasParam ", field=" hasCallback ", call=" callsCallback ")")
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find ipc_pipe.ahk")
        }
    } catch as e {
        Log("FAIL: IPC disconnect callback check error: " e.Message)
        TestErrors++
    }

    ; Test: Store registers disconnect callback and cleans up Maps
    Log("Testing Store registers disconnect callback...")
    try {
        storePath := A_ScriptDir "\..\src\store\store_server.ahk"
        if (FileExist(storePath)) {
            code := FileRead(storePath)

            ; Check callback is passed to IPC_PipeServer_Start
            hasCallbackArg := InStr(code, "Store_OnClientDisconnect)")

            ; Check Store_OnClientDisconnect function exists and cleans all Maps
            hasFunction := InStr(code, "Store_OnClientDisconnect(hPipe)")
            cleansClientOpts := InStr(code, "gStore_ClientOpts.Delete(")
            cleansLastRev := InStr(code, "gStore_LastClientRev.Delete(")
            cleansLastProj := InStr(code, "gStore_LastClientProj.Delete(")
            cleansLastMeta := InStr(code, "gStore_LastClientMeta.Delete(")

            if (hasCallbackArg && hasFunction && cleansClientOpts && cleansLastRev && cleansLastProj && cleansLastMeta) {
                Log("PASS: Store registers disconnect callback and cleans all 4 client Maps")
                TestPassed++
            } else {
                Log("FAIL: Store disconnect cleanup incomplete (callback=" hasCallbackArg ", func=" hasFunction ", maps=" (cleansClientOpts && cleansLastRev && cleansLastProj && cleansLastMeta) ")")
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find store_server.ahk")
        }
    } catch as e {
        Log("FAIL: Store disconnect callback check error: " e.Message)
        TestErrors++
    }

    ; ============================================================
    ; Buffer Overflow Protection Tests
    ; ============================================================
    Log("`n--- Buffer Overflow Protection Tests ---")

    ; Test: Komorebi subscription has buffer overflow protection
    Log("Testing komorebi_sub.ahk has buffer overflow protection...")
    try {
        ksubPath := A_ScriptDir "\..\src\store\komorebi_sub.ahk"
        if (FileExist(ksubPath)) {
            code := FileRead(ksubPath)

            ; Check for buffer size limit (1MB = 1048576 or KSUB_BUFFER_MAX_BYTES constant)
            hasLimit := InStr(code, "1048576") || InStr(code, "KSUB_BUFFER_MAX_BYTES")
            hasOverflowCheck := InStr(code, "StrLen(_KSub_ReadBuffer)")
            resetsBuffer := InStr(code, '_KSub_ReadBuffer := ""')

            if (hasLimit && hasOverflowCheck && resetsBuffer) {
                Log("PASS: komorebi_sub.ahk has 1MB buffer overflow protection")
                TestPassed++
            } else {
                Log("FAIL: Buffer overflow protection incomplete (limit=" hasLimit ", check=" hasOverflowCheck ", reset=" resetsBuffer ")")
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find komorebi_sub.ahk")
        }
    } catch as e {
        Log("FAIL: Buffer overflow check error: " e.Message)
        TestErrors++
    }

    ; ============================================================
    ; Workspace Cache Pruning Tests
    ; ============================================================
    Log("`n--- Workspace Cache Pruning Tests ---")

    ; Test: KomorebiSub has cache pruning function
    Log("Testing komorebi_sub.ahk has cache pruning function...")
    try {
        ksubPath := A_ScriptDir "\..\src\store\komorebi_sub.ahk"
        if (FileExist(ksubPath)) {
            code := FileRead(ksubPath)

            hasPruneFunc := InStr(code, "KomorebiSub_PruneStaleCache()")
            checksAge := InStr(code, "_KSub_CacheMaxAgeMs")
            deletesStale := InStr(code, "_KSub_WorkspaceCache.Delete(")

            if (hasPruneFunc && checksAge && deletesStale) {
                Log("PASS: komorebi_sub.ahk has cache pruning function with TTL check")
                TestPassed++
            } else {
                Log("FAIL: Cache pruning incomplete (func=" hasPruneFunc ", age=" checksAge ", delete=" deletesStale ")")
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find komorebi_sub.ahk")
        }
    } catch as e {
        Log("FAIL: Cache pruning check error: " e.Message)
        TestErrors++
    }

    ; Test: Store heartbeat calls cache pruning
    Log("Testing store heartbeat calls cache pruning...")
    try {
        storePath := A_ScriptDir "\..\src\store\store_server.ahk"
        if (FileExist(storePath)) {
            code := FileRead(storePath)

            ; Extract Store_HeartbeatTick function body and check it calls pruning
            funcBody := _Test_ExtractFuncBody(code, "Store_HeartbeatTick")
            if (funcBody = "") {
                Log("FAIL: Could not extract Store_HeartbeatTick function body")
                TestErrors++
            } else {
                callsPrune := InStr(funcBody, "KomorebiSub_PruneStaleCache")

                if (callsPrune) {
                    Log("PASS: Store_HeartbeatTick calls KomorebiSub_PruneStaleCache")
                    TestPassed++
                } else {
                    Log("FAIL: Store_HeartbeatTick does not call cache pruning")
                    TestErrors++
                }
            }
        } else {
            Log("SKIP: Could not find store_server.ahk")
        }
    } catch as e {
        Log("FAIL: Heartbeat pruning check error: " e.Message)
        TestErrors++
    }

    ; ============================================================
    ; Idle Timer Pause Tests (CPU Churn Prevention)
    ; ============================================================
    Log("`n--- Idle Timer Pause Tests ---")

    ; Test: Icon pump has idle-pause pattern
    Log("Testing icon_pump.ahk has idle-pause pattern...")
    try {
        iconPath := A_ScriptDir "\..\src\store\icon_pump.ahk"
        if (FileExist(iconPath)) {
            code := FileRead(iconPath)

            hasIdleTicks := InStr(code, "_IP_IdleTicks")
            hasIdleThreshold := InStr(code, "_IP_IdleThreshold")
            pausesTimer := InStr(code, "SetTimer(_IP_Tick, 0)")
            hasEnsureRunning := InStr(code, "IconPump_EnsureRunning()")

            if (hasIdleTicks && hasIdleThreshold && pausesTimer && hasEnsureRunning) {
                Log("PASS: icon_pump.ahk has idle-pause pattern with EnsureRunning")
                TestPassed++
            } else {
                Log("FAIL: Icon pump idle-pause incomplete (ticks=" hasIdleTicks ", threshold=" hasIdleThreshold ", pause=" pausesTimer ", ensure=" hasEnsureRunning ")")
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find icon_pump.ahk")
        }
    } catch as e {
        Log("FAIL: Icon pump idle check error: " e.Message)
        TestErrors++
    }

    ; Test: Proc pump has idle-pause pattern
    Log("Testing proc_pump.ahk has idle-pause pattern...")
    try {
        procPath := A_ScriptDir "\..\src\store\proc_pump.ahk"
        if (FileExist(procPath)) {
            code := FileRead(procPath)

            hasIdleTicks := InStr(code, "_PP_IdleTicks")
            hasIdleThreshold := InStr(code, "_PP_IdleThreshold")
            pausesTimer := InStr(code, "SetTimer(_PP_Tick, 0)")
            hasEnsureRunning := InStr(code, "ProcPump_EnsureRunning()")

            if (hasIdleTicks && hasIdleThreshold && pausesTimer && hasEnsureRunning) {
                Log("PASS: proc_pump.ahk has idle-pause pattern with EnsureRunning")
                TestPassed++
            } else {
                Log("FAIL: Proc pump idle-pause incomplete (ticks=" hasIdleTicks ", threshold=" hasIdleThreshold ", pause=" pausesTimer ", ensure=" hasEnsureRunning ")")
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find proc_pump.ahk")
        }
    } catch as e {
        Log("FAIL: Proc pump idle check error: " e.Message)
        TestErrors++
    }

    ; Test: WinEvent hook has idle-pause pattern
    Log("Testing winevent_hook.ahk has idle-pause pattern...")
    try {
        wehPath := A_ScriptDir "\..\src\store\winevent_hook.ahk"
        if (FileExist(wehPath)) {
            code := FileRead(wehPath)

            hasIdleTicks := InStr(code, "_WEH_IdleTicks")
            hasIdleThreshold := InStr(code, "_WEH_IdleThreshold")
            pausesTimer := InStr(code, "SetTimer(_WEH_ProcessBatch, 0)")
            hasEnsureRunning := InStr(code, "WinEventHook_EnsureTimerRunning()")

            if (hasIdleTicks && hasIdleThreshold && pausesTimer && hasEnsureRunning) {
                Log("PASS: winevent_hook.ahk has idle-pause pattern with EnsureTimerRunning")
                TestPassed++
            } else {
                Log("FAIL: WinEvent hook idle-pause incomplete (ticks=" hasIdleTicks ", threshold=" hasIdleThreshold ", pause=" pausesTimer ", ensure=" hasEnsureRunning ")")
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find winevent_hook.ahk")
        }
    } catch as e {
        Log("FAIL: WinEvent hook idle check error: " e.Message)
        TestErrors++
    }

    ; Test: WindowStore wakes pumps when enqueuing work
    Log("Testing windowstore.ahk wakes pumps when enqueuing...")
    try {
        wsPath := A_ScriptDir "\..\src\store\windowstore.ahk"
        if (FileExist(wsPath)) {
            code := FileRead(wsPath)

            wakesIconPump := InStr(code, "IconPump_EnsureRunning()")
            wakesProcPump := InStr(code, "ProcPump_EnsureRunning()")

            if (wakesIconPump && wakesProcPump) {
                Log("PASS: windowstore.ahk wakes both pumps when enqueuing work")
                TestPassed++
            } else {
                Log("FAIL: WindowStore pump wake incomplete (icon=" wakesIconPump ", proc=" wakesProcPump ")")
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find windowstore.ahk")
        }
    } catch as e {
        Log("FAIL: WindowStore pump wake check error: " e.Message)
        TestErrors++
    }

    ; ============================================================
    ; Hot Path Static Buffer Tests (Code Inspection)
    ; ============================================================
    ; Verify frequently-called functions use static Buffers
    ; to prevent per-call allocation churn (regression guard)
    Log("`n--- Hot Path Static Buffer Tests ---")

    ; Test 1: Gdip_DrawText uses static buffer
    Log("Testing Gdip_DrawText uses static buffer...")
    try {
        gdipPath := A_ScriptDir "\..\src\gui\gui_gdip.ahk"
        if (FileExist(gdipPath)) {
            code := FileRead(gdipPath)
            if (RegExMatch(code, "Gdip_DrawText\([\s\S]*?static rf\s*:=\s*Buffer")) {
                Log("PASS: Gdip_DrawText uses static rf buffer")
                TestPassed++
            } else {
                Log("FAIL: Gdip_DrawText should use static rf buffer (hot path)")
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find gui_gdip.ahk")
        }
    } catch as e {
        Log("FAIL: Gdip_DrawText static buffer check error: " e.Message)
        TestErrors++
    }

    ; Test 2: Gdip_DrawCenteredText uses static buffer
    Log("Testing Gdip_DrawCenteredText uses static buffer...")
    try {
        gdipPath := A_ScriptDir "\..\src\gui\gui_gdip.ahk"
        if (FileExist(gdipPath)) {
            code := FileRead(gdipPath)
            if (RegExMatch(code, "Gdip_DrawCenteredText\([\s\S]*?static rf\s*:=\s*Buffer")) {
                Log("PASS: Gdip_DrawCenteredText uses static rf buffer")
                TestPassed++
            } else {
                Log("FAIL: Gdip_DrawCenteredText should use static rf buffer (hot path)")
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find gui_gdip.ahk")
        }
    } catch as e {
        Log("FAIL: Gdip_DrawCenteredText static buffer check error: " e.Message)
        TestErrors++
    }

    ; Test 3: GUI_Repaint uses static marshal buffers
    Log("Testing GUI_Repaint uses static marshal buffers...")
    try {
        paintPath := A_ScriptDir "\..\src\gui\gui_paint.ahk"
        if (FileExist(paintPath)) {
            code := FileRead(paintPath)
            if (InStr(code, "static bf := Buffer")) {
                Log("PASS: GUI_Repaint uses static bf buffer")
                TestPassed++
            } else {
                Log("FAIL: GUI_Repaint should use static bf buffer (hot path)")
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find gui_paint.ahk")
        }
    } catch as e {
        Log("FAIL: GUI_Repaint static buffer check error: " e.Message)
        TestErrors++
    }

    ; Test 4: GUI_RecalcHover uses static buffer
    Log("Testing GUI_RecalcHover uses static buffer...")
    try {
        inputPath := A_ScriptDir "\..\src\gui\gui_input.ahk"
        if (FileExist(inputPath)) {
            code := FileRead(inputPath)
            if (RegExMatch(code, "GUI_RecalcHover\([\s\S]*?static pt\s*:=\s*Buffer")) {
                Log("PASS: GUI_RecalcHover uses static pt buffer")
                TestPassed++
            } else {
                Log("FAIL: GUI_RecalcHover should use static pt buffer (hot path)")
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find gui_input.ahk")
        }
    } catch as e {
        Log("FAIL: GUI_RecalcHover static buffer check error: " e.Message)
        TestErrors++
    }
}
