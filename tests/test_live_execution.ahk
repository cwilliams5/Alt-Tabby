; Live Tests - Execution Modes
; Standalone /src, Compilation Verification, Compiled Exe Modes
; Included by test_live.ahk

RunLiveTests_Execution() {
    global TestPassed, TestErrors, cfg
    global gStandaloneTestReceived, gCompiledStoreReceived
    global IPC_MSG_HELLO

    storePath := A_ScriptDir "\..\src\store\store_server.ahk"
    compiledExePath := A_ScriptDir "\..\release\AltTabby.exe"

    ; ============================================================
    ; Standalone /src Execution Test
    ; ============================================================
    Log("`n--- Standalone /src Execution Test ---")

    ; Test that store_server.ahk can be launched directly from /src
    standaloneStorePipe := "tabby_standalone_test_" A_TickCount
    standaloneStorePid := 0

    if (!_Test_RunSilent('"' A_AhkPath '" /ErrorStdOut "' storePath '" --test --pipe=' standaloneStorePipe, &standaloneStorePid)) {
        Log("FAIL: Could not launch standalone store_server.ahk")
        TestErrors++
        standaloneStorePid := 0
    }

    if (standaloneStorePid) {
        ; Wait for store pipe to become available (adaptive)
        if (!WaitForStorePipe(standaloneStorePipe, 3000)) {
            Log("FAIL: Standalone store pipe not ready within timeout")
            TestErrors++
            try ProcessClose(standaloneStorePid)
            standaloneStorePid := 0
        }
    }

    if (standaloneStorePid) {
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

    ; Kill any running AltTabby processes before launching compiled exe
    ; This prevents single-instance dialog from blocking tests
    _Test_KillAllAltTabby()

    if (FileExist(compiledExePath)) {
        ; Test --store mode
        compiledStorePipe := "tabby_compiled_store_" A_TickCount
        compiledStorePid := 0

        if (!_Test_RunSilent('"' compiledExePath '" --store --test --pipe=' compiledStorePipe, &compiledStorePid)) {
            Log("FAIL: Could not launch AltTabby.exe --store")
            TestErrors++
            compiledStorePid := 0
        }

        if (compiledStorePid) {
            ; Wait for store pipe to become available (adaptive)
            if (!WaitForStorePipe(compiledStorePipe, 3000)) {
                Log("FAIL: Compiled store pipe not ready within timeout")
                TestErrors++
                try ProcessClose(compiledStorePid)
                compiledStorePid := 0
            }
        }

        if (compiledStorePid) {
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
        ; Use --testing-mode to prevent wizard and install mismatch dialogs from blocking
        Log("  Testing launcher mode (spawns store + gui)...")
        launcherPid := 0

        if (!_Test_RunSilent('"' compiledExePath '" --testing-mode', &launcherPid)) {
            Log("FAIL: Could not launch AltTabby.exe (launcher mode)")
            TestErrors++
            launcherPid := 0
        }

        if (launcherPid) {
            ; Poll for subprocess spawning instead of fixed sleep
            ; Launcher spawns store + gui, so expect 3+ AltTabby.exe processes
            processCount := 0
            spawnStart := A_TickCount
            while ((A_TickCount - spawnStart) < 5000) {
                processCount := 0
                for proc in ComObjGet("winmgmts:").ExecQuery("Select * from Win32_Process Where Name = 'AltTabby.exe'") {
                    processCount++
                }
                if (processCount >= 3)
                    break
                Sleep(200)
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
            Sleep(200)
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

            _Test_RunSilent('"' compiledExePath '" --store --test --pipe=' recreatePipe, &recreatePid)

            if (recreatePid) {
                ; Wait for store pipe to become available (adaptive)
                ; Files are created during init, so pipe ready = files created
                if (!WaitForStorePipe(recreatePipe, 3000)) {
                    Log("WARN: Recreation test store pipe not ready, checking files anyway")
                }

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
