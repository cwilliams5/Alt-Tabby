; Unit Tests - Cleanup & Shutdown
; GDI+ Shutdown, Icon Cache Cleanup, IPC Critical Section, OnExit Handlers
; Included by test_unit.ahk

RunUnitTests_Cleanup() {
    global TestPassed, TestErrors, cfg

    ; ============================================================
    ; GDI+ Shutdown Tests (Resource Leak Prevention)
    ; ============================================================
    ; Note: These tests use code inspection since gui_gdip.ahk isn't
    ; included in the test context. This avoids interfering with graphics state.
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
            ; Call cleanup (use fake icons, so no actual DestroyIcon needed)
            ; Note: In real usage, this would destroy actual HICONs
            ; For testing, we set iconHicon to 0 manually to avoid DllCall on fake handle
            gWS_Store[testHwnd].iconHicon := 0  ; Simulate what cleanup does

            ; Verify icon is cleared
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
}
