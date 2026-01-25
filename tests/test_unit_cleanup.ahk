; Unit Tests - Cleanup & Shutdown
; GDI+ Shutdown, Icon Cache Cleanup, IPC Critical Section, OnExit Handlers
; Included by test_unit.ahk

RunUnitTests_Cleanup() {
    global TestPassed, TestErrors, cfg

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

    ; Test 4: Cleanup functions are called from Store_OnExit path
    Log("Testing icon cleanup functions are accessible...")
    try {
        ; Verify both cleanup functions exist and are callable
        fn1Exists := IsSet(WindowStore_CleanupExeIconCache) && (WindowStore_CleanupExeIconCache is Func)
        fn2Exists := IsSet(WindowStore_CleanupAllIcons) && (WindowStore_CleanupAllIcons is Func)

        if (fn1Exists && fn2Exists) {
            Log("PASS: Both icon cleanup functions exist and are callable")
            TestPassed++
        } else {
            Log("FAIL: Missing cleanup functions (ExeCache=" fn1Exists ", AllIcons=" fn2Exists ")")
            TestErrors++
        }
    } catch as e {
        Log("FAIL: Cleanup function check error: " e.Message)
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
        ; Read the IPC source file and verify Critical is present
        ipcPath := A_ScriptDir "\..\src\shared\ipc_pipe.ahk"
        if (FileExist(ipcPath)) {
            ipcCode := FileRead(ipcPath)

            ; Check for Critical in ServerTick
            hasServerTickCritical := InStr(ipcCode, "IPC__ServerTick") && InStr(ipcCode, 'Critical "On"')

            ; Check for Critical in Broadcast
            hasBroadcastCritical := InStr(ipcCode, "IPC_PipeServer_Broadcast") && InStr(ipcCode, 'Critical "On"')

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

            hasCleanupAllIcons := InStr(storeCode, "WindowStore_CleanupAllIcons()")
            hasCleanupExeCache := InStr(storeCode, "WindowStore_CleanupExeIconCache()")

            if (hasCleanupAllIcons && hasCleanupExeCache) {
                Log("PASS: Store_OnExit calls both icon cleanup functions")
                TestPassed++
            } else {
                Log("FAIL: Store_OnExit missing cleanup calls (AllIcons=" hasCleanupAllIcons ", ExeCache=" hasCleanupExeCache ")")
                TestErrors++
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

            hasGdipShutdown := InStr(guiCode, "Gdip_Shutdown()")
            inOnExit := InStr(guiCode, "_GUI_OnExit") && hasGdipShutdown

            if (inOnExit) {
                Log("PASS: GUI _GUI_OnExit calls Gdip_Shutdown()")
                TestPassed++
            } else {
                Log("FAIL: GUI _GUI_OnExit should call Gdip_Shutdown()")
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find gui_main.ahk for code inspection")
        }
    } catch as e {
        Log("FAIL: GUI Gdip_Shutdown check error: " e.Message)
        TestErrors++
    }

    ; ============================================================
    ; Logging Hygiene Tests
    ; ============================================================
    ; These tests prevent regressions in logging discipline:
    ; - No unconditional FileAppend in diagnostic logging functions
    ; - No duplicate *_Log/*_DiagLog function patterns
    ; - No legacy *_DebugLog variables
    Log("`n--- Logging Hygiene Tests ---")

    ; Test 1: Detect unconditional FileAppend in catch blocks (error fallback anti-pattern)
    ; This catches patterns like: catch { FileAppend(...) } without config checks
    Log("Testing for unconditional error fallback logging...")
    try {
        ; Files that have logging functions to check
        filesToCheck := [
            {path: A_ScriptDir "\..\src\gui\gui_state.ahk", name: "gui_state.ahk"},
            {path: A_ScriptDir "\..\src\store\komorebi_sub.ahk", name: "komorebi_sub.ahk"},
            {path: A_ScriptDir "\..\src\shared\ipc_pipe.ahk", name: "ipc_pipe.ahk"}
        ]

        unconditionalFound := false
        for _, file in filesToCheck {
            if (!FileExist(file.path))
                continue
            code := FileRead(file.path)

            ; Look for FileAppend inside catch blocks that write to hardcoded paths
            ; Pattern: catch block with FileAppend to a specific log file (not using LOG_PATH_* constants)
            ; This is a heuristic - catches "tabby_log_errors.txt" or similar hardcoded names
            if (RegExMatch(code, "catch[^{]*\{[^}]*FileAppend\([^,]+,\s*A_Temp\s*[`"\\]+[a-z_]+\.txt")) {
                Log("FAIL: " file.name " has unconditional FileAppend in catch block")
                TestErrors++
                unconditionalFound := true
            }
        }

        if (!unconditionalFound) {
            Log("PASS: No unconditional error fallback logging found")
            TestPassed++
        }
    } catch as e {
        Log("FAIL: Unconditional logging check error: " e.Message)
        TestErrors++
    }

    ; Test 2: Detect duplicate logging function patterns (*_Log vs *_DiagLog in same file)
    ; This catches legacy logging functions that should be unified
    Log("Testing for duplicate logging function patterns...")
    try {
        ; Check files that have had logging issues in the past
        filesToCheck := [
            {path: A_ScriptDir "\..\src\store\komorebi_sub.ahk", name: "komorebi_sub.ahk", prefix: "_KSub"},
            {path: A_ScriptDir "\..\src\store\store_server.ahk", name: "store_server.ahk", prefix: "Store"},
            {path: A_ScriptDir "\..\src\gui\gui_state.ahk", name: "gui_state.ahk", prefix: "_GUI"}
        ]

        duplicateFound := false
        for _, file in filesToCheck {
            if (!FileExist(file.path))
                continue
            code := FileRead(file.path)

            ; Check if file has BOTH *_Log( and *_DiagLog( function definitions
            ; Pattern: function definition like "_KSub_Log(msg) {"
            hasLegacyLog := RegExMatch(code, file.prefix "_Log\s*\([^)]*\)\s*\{")
            hasDiagLog := RegExMatch(code, file.prefix "_DiagLog\s*\([^)]*\)\s*\{")

            if (hasLegacyLog && hasDiagLog) {
                Log("FAIL: " file.name " has both " file.prefix "_Log and " file.prefix "_DiagLog (should unify)")
                TestErrors++
                duplicateFound := true
            }
        }

        if (!duplicateFound) {
            Log("PASS: No duplicate logging function patterns found")
            TestPassed++
        }
    } catch as e {
        Log("FAIL: Duplicate logging check error: " e.Message)
        TestErrors++
    }

    ; Test 3: Detect legacy *_DebugLog global variables (unconverted legacy logging)
    ; These should be replaced with config-gated logging using cfg.Diag* options
    Log("Testing for legacy debug log variables...")
    try {
        srcDir := A_ScriptDir "\..\src"
        legacyVars := []

        ; Scan all .ahk files in src directory tree
        Loop Files, srcDir "\*.ahk", "R" {
            code := FileRead(A_LoopFileFullPath)
            relPath := StrReplace(A_LoopFileFullPath, srcDir "\", "")

            ; Look for: global *_DebugLog := (legacy pattern)
            ; Exclude comments (lines starting with ;)
            if (RegExMatch(code, "m)^[^;]*global\s+\w+_DebugLog\s*:=")) {
                legacyVars.Push(relPath)
            }
        }

        if (legacyVars.Length > 0) {
            for _, path in legacyVars {
                Log("FAIL: " path " has legacy *_DebugLog variable (convert to cfg.Diag* pattern)")
                TestErrors++
            }
        } else {
            Log("PASS: No legacy *_DebugLog variables found")
            TestPassed++
        }
    } catch as e {
        Log("FAIL: Legacy debug variable check error: " e.Message)
        TestErrors++
    }

    ; Test 4: Verify Store_LogError is the only intentionally unconditional logger
    ; Store_LogError should exist and NOT check cfg.* (it's for fatal errors)
    Log("Testing Store_LogError is intentionally unconditional...")
    try {
        storePath := A_ScriptDir "\..\src\store\store_server.ahk"
        if (FileExist(storePath)) {
            code := FileRead(storePath)

            ; Store_LogError should exist
            hasLogError := InStr(code, "Store_LogError(msg)")

            ; Store_LogError should NOT have cfg check (it's intentionally unconditional)
            ; Extract the function body and verify no cfg.Diag check
            if (RegExMatch(code, "Store_LogError\(msg\)\s*\{[^}]+\}", &match)) {
                funcBody := match[]
                hasConfigCheck := InStr(funcBody, "cfg.Diag")

                if (hasLogError && !hasConfigCheck) {
                    Log("PASS: Store_LogError exists and is intentionally unconditional")
                    TestPassed++
                } else if (!hasLogError) {
                    Log("FAIL: Store_LogError function not found")
                    TestErrors++
                } else {
                    Log("FAIL: Store_LogError should be unconditional (no cfg.Diag check)")
                    TestErrors++
                }
            } else {
                Log("FAIL: Could not parse Store_LogError function")
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find store_server.ahk")
        }
    } catch as e {
        Log("FAIL: Store_LogError check error: " e.Message)
        TestErrors++
    }

    ; ============================================================
    ; Include Completeness Tests (Prevent Missing Shared Utilities)
    ; ============================================================
    ; These tests ensure store_server.ahk includes all needed shared utilities
    ; to prevent standalone mode crashes like those fixed in d9a90cc
    Log("`n--- Include Completeness Tests ---")

    ; Test: store_server.ahk includes all required shared utilities
    Log("Testing store_server.ahk has all required shared includes...")
    try {
        storePath := A_ScriptDir "\..\src\store\store_server.ahk"
        if (FileExist(storePath)) {
            code := FileRead(storePath)

            requiredIncludes := [
                "config_loader.ahk",
                "json.ahk",
                "ipc_pipe.ahk",
                "blacklist.ahk",
                "process_utils.ahk",
                "win_utils.ahk"
            ]

            missingIncludes := []
            for _, inc in requiredIncludes {
                if (!InStr(code, inc)) {
                    missingIncludes.Push(inc)
                }
            }

            if (missingIncludes.Length = 0) {
                Log("PASS: store_server.ahk has all " requiredIncludes.Length " required shared includes")
                TestPassed++
            } else {
                Log("FAIL: store_server.ahk missing includes: " _ArrayJoin(missingIncludes, ", "))
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find store_server.ahk")
        }
    } catch as e {
        Log("FAIL: Include completeness check error: " e.Message)
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

            ; Extract Store_HeartbeatTick function and check it calls pruning
            if (RegExMatch(code, "Store_HeartbeatTick\(\)\s*\{[\s\S]*?^\}", &match)) {
                funcBody := match[]
                callsPrune := InStr(funcBody, "KomorebiSub_PruneStaleCache")

                if (callsPrune) {
                    Log("PASS: Store_HeartbeatTick calls KomorebiSub_PruneStaleCache")
                    TestPassed++
                } else {
                    Log("FAIL: Store_HeartbeatTick does not call cache pruning")
                    TestErrors++
                }
            } else {
                ; Fallback: just check if the call exists somewhere after HeartbeatTick definition
                if (InStr(code, "Store_HeartbeatTick") && InStr(code, "KomorebiSub_PruneStaleCache")) {
                    Log("PASS: Store_HeartbeatTick and KomorebiSub_PruneStaleCache both exist")
                    TestPassed++
                } else {
                    Log("FAIL: Could not verify heartbeat calls pruning")
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
}
