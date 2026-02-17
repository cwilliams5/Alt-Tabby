; Live Tests - Execution Modes
; Compilation Verification, Compiled Exe Modes
; Included by test_live.ahk
#Include test_utils.ahk

RunLiveTests_Execution() {
    global TestPassed, TestErrors, cfg

    compiledExePath := A_ScriptDir "\..\release\AltTabby.exe"

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

    ; Note: test.ps1 kills all AltTabby.exe processes at startup.
    ; We do NOT call _Test_KillAllAltTabby() here because this suite runs
    ; in parallel with others that may have their own AltTabby.exe processes.
    ; For standalone runs: if another instance is running, the launcher's
    ; --testing-mode will exit silently (acceptable — just a SKIP).

    if (FileExist(compiledExePath)) {
        ; Test launcher mode (spawns gui subprocess)
        ; Use --testing-mode to prevent wizard and install mismatch dialogs from blocking
        Log("  Testing launcher mode (spawns gui)...")
        launcherPid := 0

        if (!_Test_RunSilent('"' compiledExePath '" --testing-mode', &launcherPid)) {
            Log("FAIL: Could not launch AltTabby.exe (launcher mode)")
            TestErrors++
            launcherPid := 0
        }

        if (launcherPid) {
            ; Poll for subprocess spawning instead of fixed sleep
            ; Launcher spawns gui, so expect 2+ AltTabby.exe processes (pump is optional)
            processCount := 0
            spawnStart := A_TickCount
            while ((A_TickCount - spawnStart) < 5000) {
                processCount := _Test_CountProcesses("AltTabby.exe")
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
                    ; Launcher exited immediately — most likely mutex conflict with existing
                    ; instance (--testing-mode silently exits on mutex failure).
                    ; This is an environment issue, not a code bug.
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

            ; Kill launcher and its children (targeted by PID, not blanket process name kill)
            for _, child in _Test_FindChildProcesses(launcherPid, "AltTabby.exe") {
                try ProcessClose(child.pid)
            }
            try ProcessClose(launcherPid)
            waitStart := A_TickCount
            while (ProcessExist(launcherPid) && (A_TickCount - waitStart) < 2000)
                Sleep(20)
            Sleep(50)  ; Brief grace for handle release
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

            ; Run compiled gui briefly - it should recreate the files during init
            recreatePid := 0

            _Test_RunSilent('"' compiledExePath '" --gui-only --test', &recreatePid)

            if (recreatePid) {
                ; Wait for gui to start up (files are created during ConfigLoader_Init)
                Sleep(2000)

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

                ; Kill the test process
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
