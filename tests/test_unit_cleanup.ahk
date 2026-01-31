; Unit Tests - Cleanup & Shutdown
; LogTrim, Icon Cache Cleanup, IPC Critical Section
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
        ; Build a file > 102400 bytes (100KB). ~120KB target.
        ; Build a small chunk then double it to avoid O(n²) concatenation.
        chunk := ""
        Loop 40 {
            chunk .= "Line " Format("{:04d}", A_Index) " - " "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGH" "`n"
        }
        largeContent := chunk
        Loop 5 {
            largeContent .= largeContent
        }
        largeContent := SubStr(largeContent, 1, 120000)
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
        ; Generate > 102400 bytes. ~130KB target.
        ; Build bulk via doubling, then prepend/append unique markers.
        chunk := ""
        Loop 40 {
            chunk .= "Line " Format("{:04d}", A_Index) " PADDING-PADDING-PADDING-PADDING-PADDING-PADDING-PADDING-PADDING-PADDING-PAD`n"
        }
        bulk := chunk
        Loop 5 {
            bulk .= bulk
        }
        ; Prepend unique head marker, append unique tail marker
        largeContent := "HEAD_MARKER_UNIQUE_12345`n" SubStr(bulk, 1, 128000) "TAIL_MARKER_UNIQUE_67890`n"
        FileAppend(largeContent, testLogPath, "UTF-8")
        sizeBefore := FileGetSize(testLogPath)

        if (sizeBefore <= 102400) {
            Log("SKIP: LogTrim tail test: content only " sizeBefore " bytes (need > 102400)")
        } else {
            LogTrim(testLogPath)

            trimmedContent := FileRead(testLogPath)
            ; Tail marker should be preserved since LogTrim keeps tail
            hasTail := InStr(trimmedContent, "TAIL_MARKER_UNIQUE_67890")
            ; Head marker should be gone (trimmed from head)
            hasHead := InStr(trimmedContent, "HEAD_MARKER_UNIQUE_12345")
            if (hasTail && !hasHead) {
                Log("PASS: LogTrim preserved tail (has tail marker, no head marker)")
                TestPassed++
            } else {
                Log("FAIL: LogTrim should keep tail, remove head (tail=" hasTail ", head=" hasHead ", beforeSize=" sizeBefore ")")
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
        ; Build a small chunk then double to avoid O(n²) concatenation.
        chunk := ""
        Loop 40 {
            chunk .= "X" Format("{:04d}", A_Index) " - " "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrs" "`n"
        }
        exactContent := chunk
        Loop 5 {
            exactContent .= exactContent
        }
        exactContent := SubStr(exactContent, 1, 102400)
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
}
