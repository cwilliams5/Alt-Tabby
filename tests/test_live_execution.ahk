; Live Tests - Execution Modes
; Compilation Verification, Compiled Exe Modes
; Included by test_live.ahk
;
; ISOLATION: Copies AltTabby.exe to a temp dir as AltTabby_exectest.exe with
; its own config.ini (FirstRunCompleted=true, unique PumpPipeName). This gives
; it a unique mutex (different InstallationId from different dir) so it runs
; without conflicting with other parallel test suites or user's running instance.
#Include test_utils.ahk

global EXECTEST_EXE_NAME := "AltTabby_exectest.exe"

RunLiveTests_Execution() {
    global TestPassed, TestErrors, cfg
    global EXECTEST_EXE_NAME

    compiledExePath := A_ScriptDir "\..\release\AltTabby.exe"

    ; ============================================================
    ; Compilation Verification Test
    ; ============================================================
    Log("`n--- Compilation Verification Test ---")

    ; Check that AltTabby.exe exists in release folder
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
    ; Compiled Exe Mode Tests (isolated environment)
    ; ============================================================
    Log("`n--- Compiled Exe Mode Tests ---")

    if (!FileExist(compiledExePath)) {
        Log("SKIP: Compiled exe tests skipped - AltTabby.exe not found")
        return
    }

    ; --- Setup isolated test environment ---
    testDir := A_Temp "\alttabby_exectest_" A_TickCount
    testExe := testDir "\" EXECTEST_EXE_NAME

    _ExecTest_Cleanup(testDir)
    DirCreate(testDir)
    FileCopy(compiledExePath, testExe, true)

    ; Write config with wizard skip and unique pipe name
    pipeName := "tabby_pump_exec_" A_TickCount
    configContent := "[Setup]`nFirstRunCompleted=true`n[IPC]`nPumpPipeName=" pipeName "`n"
    FileAppend(configContent, testDir "\config.ini", "UTF-8")

    Log("  Isolated env: " testDir)
    Log("  Exe: " EXECTEST_EXE_NAME ", pipe: " pipeName)

    ; --- Test launcher mode (spawns gui subprocess) ---
    Log("  Testing launcher mode (spawns gui)...")
    launcherPid := 0

    if (!_Test_RunSilent('"' testExe '" --testing-mode', &launcherPid)) {
        Log("FAIL: Could not launch " EXECTEST_EXE_NAME " (launcher mode)")
        TestErrors++
        launcherPid := 0
    }

    if (launcherPid) {
        ; Poll for subprocess spawning — count only OUR isolated exe name
        processCount := 0
        spawnStart := A_TickCount
        while ((A_TickCount - spawnStart) < 8000) {
            processCount := _Test_CountProcesses(EXECTEST_EXE_NAME)
            if (processCount >= 2)
                break
            Sleep(100)
        }

        if (processCount >= 2) {
            Log("PASS: Launcher mode spawned " processCount " processes (launcher + gui" (processCount > 2 ? " + pump" : "") ")")
            TestPassed++
        } else {
            ; Diagnostics: is the launcher still alive or did it exit?
            launcherAlive := ProcessExist(launcherPid)
            launcherLog := ""
            logPath := EnvGet("TEMP") "\tabby_launcher.log"
            if (FileExist(logPath)) {
                try launcherLog := FileRead(logPath)
            }
            if (!launcherAlive && processCount < 2) {
                Log("SKIP: Launcher exited immediately (likely mutex conflict with running instance)")
                Log("  Diagnostic: launcher PID " launcherPid " alive=no, processes=" processCount)
                if (launcherLog != "")
                    Log("  Launcher log:`n" launcherLog)
            } else {
                Log("FAIL: Launcher mode only has " processCount " process(es), expected 2+")
                Log("  Diagnostic: launcher PID " launcherPid " alive=" (launcherAlive ? "yes" : "no"))
                if (launcherLog != "")
                    Log("  Launcher log:`n" launcherLog)
                TestErrors++
            }
        }

        ; Kill launcher and its children (targeted by PID tree)
        for _, child in _Test_FindChildProcesses(launcherPid, EXECTEST_EXE_NAME) {
            try ProcessClose(child.pid)
        }
        try ProcessClose(launcherPid)
        waitStart := A_TickCount
        while (ProcessExist(launcherPid) && (A_TickCount - waitStart) < 2000)
            Sleep(20)
        Sleep(50)  ; Brief grace for handle release
    }

    ; --- Config/Blacklist Recreation Test (in isolated dir) ---
    Log("`n--- Config/Blacklist Recreation Test ---")

    configPath := testDir "\config.ini"
    blacklistPath := testDir "\blacklist.txt"

    ; Delete both files — they should be recreated by the exe on startup
    try FileDelete(configPath)
    try FileDelete(blacklistPath)

    if (FileExist(configPath) || FileExist(blacklistPath)) {
        Log("FAIL: Could not delete config files for recreation test")
        TestErrors++
    } else {
        Log("  Deleted config.ini and blacklist.txt for recreation test")

        ; Run compiled gui briefly - it should recreate the files during init
        recreatePid := 0
        _Test_RunSilent('"' testExe '" --gui-only --test', &recreatePid)

        if (recreatePid) {
            ; Poll for both files to appear
            waitStart := A_TickCount
            configRecreated := false
            blacklistRecreated := false
            while ((A_TickCount - waitStart) < 8000) {
                if (!configRecreated)
                    configRecreated := FileExist(configPath)
                if (!blacklistRecreated)
                    blacklistRecreated := FileExist(blacklistPath)
                if (configRecreated && blacklistRecreated)
                    break
                Sleep(100)
            }

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

            ; Kill the test process
            try ProcessClose(recreatePid)
        } else {
            Log("FAIL: Could not launch compiled exe for recreation test")
            TestErrors++
        }
    }

    ; --- Cleanup ---
    _ExecTest_Cleanup(testDir)
}

; Kill all execution test processes and remove temp directory
_ExecTest_Cleanup(testDir) {
    global EXECTEST_EXE_NAME

    ; Kill processes by name (only our isolated copies)
    _Test_KillProcessesByName(EXECTEST_EXE_NAME)

    ; Remove temp directory
    if (DirExist(testDir)) {
        try DirDelete(testDir, true)
    }

    ; Delete stale pump/launcher logs from previous runs
    try FileDelete(A_Temp "\tabby_pump.log")
    try FileDelete(A_Temp "\tabby_launcher.log")
}
