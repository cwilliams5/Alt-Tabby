; Live Tests - Process Lifecycle
; Pump restart, file watcher, and shutdown tests (2-process model: launcher + gui)
; Included by test_live.ahk
;
; ISOLATION: Copies AltTabby.exe to a temp dir as AltTabby_lifecycle.exe with
; its own config.ini (FirstRunCompleted=true). This gives it a unique mutex
; (different InstallationId from different dir) so it runs without conflicting
; with other parallel test suites that also launch AltTabby.exe.
#Include test_utils.ahk

global LIFECYCLE_EXE_NAME := "AltTabby_lifecycle.exe"
global LIFECYCLE_HWND_FILE := A_Temp "\alttabby_lifecycle_hwnd.txt"

RunLiveTests_Lifecycle() {
    global TestPassed, TestErrors
    global LIFECYCLE_EXE_NAME, LIFECYCLE_HWND_FILE

    compiledExePath := A_ScriptDir "\..\release\AltTabby.exe"

    if (!FileExist(compiledExePath)) {
        Log("SKIP: Lifecycle tests - AltTabby.exe not found")
        return
    }

    ; ============================================================
    ; Setup: create isolated copy and launch full system
    ; ============================================================
    Log("`n--- Lifecycle Test Setup ---")

    ; Create isolated test environment
    testDir := A_Temp "\alttabby_lifecycle_test"
    testExe := testDir "\" LIFECYCLE_EXE_NAME

    _Lifecycle_Cleanup()  ; Clean previous runs

    DirCreate(testDir)
    FileCopy(compiledExePath, testExe, true)

    ; Write config.ini with wizard skip (no store pipe needed — store is in-process)
    ; Enable pump diagnostics so we can see what GUIPump_Init does
    ; Use unique pipe name to avoid collision with execution test's AltTabby.exe (both default to tabby_pump_v1)
    configContent := "[Setup]`nFirstRunCompleted=true`n[Diagnostics]`nPumpLog=true`nLauncherLog=true`nStoreLog=true`n[IPC]`nPumpPipeName=tabby_pump_lifecycle`n"
    FileAppend(configContent, testDir "\config.ini", "UTF-8")

    ; Launch
    launcherPid := 0
    if (!_Test_RunSilent('"' testExe '" --testing-mode', &launcherPid)) {
        Log("FAIL: Could not launch " LIFECYCLE_EXE_NAME)
        TestErrors++
        _Lifecycle_Cleanup()
        return
    }

    ; Wait for 2 processes (launcher + gui). Pump is optional and may not spawn.
    processCount := 0
    spawnStart := A_TickCount
    loop {
        if ((A_TickCount - spawnStart) >= 5000)
            break
        processCount := _Test_CountProcesses(LIFECYCLE_EXE_NAME)
        if (processCount >= 2)
            break
        Sleep(50)
    }
    if (processCount < 2) {
        Log("FAIL: Only " processCount " process(es) of " LIFECYCLE_EXE_NAME ", need 2 (launcher + gui)")
        TestErrors++
        _Lifecycle_Cleanup()
        return
    }

    Log("PASS: " processCount " processes spawned (launcher + gui" (processCount > 2 ? " + pump" : "") ")")
    TestPassed++

    ; Read launcher HWND + child PIDs from temp file (launcher writes them in
    ; --testing-mode because CREATE_NO_WINDOW hides AHK's message window from
    ; WinGetList; child PIDs needed because GUI and pump are same exe)
    ; Format: line 1 = launcher HWND, line 2 = gui PID, line 3 = pump PID
    launcherHwnd := 0
    knownGuiPid := 0
    knownPumpPid := 0
    hwndStart := A_TickCount
    loop {
        if ((A_TickCount - hwndStart) >= 5000)
            break
        if (FileExist(LIFECYCLE_HWND_FILE)) {
            try {
                content := Trim(FileRead(LIFECYCLE_HWND_FILE), " `t`r`n")
                lines := StrSplit(content, "`n", "`r")
                if (lines.Length >= 1 && lines[1] != "")
                    launcherHwnd := Integer(Trim(lines[1]))
                if (lines.Length >= 2 && lines[2] != "" && lines[2] != "0")
                    knownGuiPid := Integer(Trim(lines[2]))
                if (lines.Length >= 3 && lines[3] != "" && lines[3] != "0")
                    knownPumpPid := Integer(Trim(lines[3]))
            }
        }
        if (launcherHwnd)
            break
        Sleep(50)
    }
    if (!launcherHwnd) {
        Log("FAIL: Could not read launcher HWND from " LIFECYCLE_HWND_FILE)
        TestErrors++
        _Lifecycle_Cleanup()
        return
    }
    if (knownGuiPid)
        Log("Launcher reported: gui PID=" knownGuiPid ", pump PID=" knownPumpPid)

    ; Wait for GUI to connect to pump (GUI logs "INIT: Connected" when pipe connect succeeds).
    ; Can't just Sleep — GUI init takes 2-5s depending on WinEnum scope.
    pumpLogPath := A_Temp "\tabby_pump.log"
    connectStart := A_TickCount
    guiConnected := false
    while ((A_TickCount - connectStart) < 8000) {
        if (FileExist(pumpLogPath)) {
            try {
                logContent := FileRead(pumpLogPath)
                if (InStr(logContent, "Connected to EnrichmentPump"))
                    guiConnected := true
            }
        }
        if (guiConnected)
            break
        Sleep(100)
    }
    if (!guiConnected)
        Log("WARNING: GUI did not log pump connection within 8s")

    ; ============================================================
    ; Test 1a: Pump enrichment round-trip
    ; ============================================================
    ; Verifies the pump actually processes enrichment requests (not just connects).
    ; Catches crashes like Map.Delete on missing key that abort _Pump_HandleEnrich
    ; before any response is built — resulting in zero icons.
    Log("`n--- Pump Enrichment Round-Trip Test ---")

    if (!guiConnected) {
        Log("FAIL: Pump not connected — enrichment test requires active pump")
        TestErrors++
    } else if (!knownPumpPid || !ProcessExist(knownPumpPid)) {
        Log("FAIL: Pump not running — enrichment test requires live pump process")
        TestErrors++
    } else {
        ; Poll pump log for HandleEnrich entry (pump logs each enrichment response).
        ; GUI's initial WinEnum scan enqueues all windows for enrichment, so the
        ; pump should process at least one batch within a few seconds of connecting.
        pumpLogPath := A_Temp "\tabby_pump.log"
        enrichSeen := false
        enrichStart := A_TickCount
        while ((A_TickCount - enrichStart) < 8000) {
            if (FileExist(pumpLogPath)) {
                try {
                    logContent := FileRead(pumpLogPath)
                    if (InStr(logContent, "HandleEnrich:"))
                        enrichSeen := true
                }
            }
            if (enrichSeen)
                break
            Sleep(100)
        }

        if (enrichSeen) {
            Log("PASS: Pump processed enrichment request (" (A_TickCount - enrichStart) "ms)")
            TestPassed++
        } else {
            Log("FAIL: No pump enrichment response within 8s (pump may be crashing on request processing)")
            TestErrors++
            if (FileExist(pumpLogPath)) {
                try {
                    pumpLog := FileRead(pumpLogPath)
                    Log("--- Pump Log (last 2000 chars) ---")
                    Log(SubStr(pumpLog, -2000))
                }
            }
        }
    }

    ; ============================================================
    ; Test 1b: Pump kill → auto-restart (end-to-end)
    ; ============================================================
    ; Tests the full cycle: kill pump → GUI detects pipe write failure
    ; → GUI sends PUMP_FAILED → launcher restarts pump → new PID appears.
    ; This is the real-world scenario (user kills pump, or it crashes).
    ; Kill immediately after GUI connects — initial WinEnum queue is still
    ; draining so collection timer is active and will hit pipe write failure.
    Log("`n--- Pump Kill Auto-Restart Test ---")

    ; Use authoritative pump PID from launcher (GUI and pump are same exe,
    ; can't distinguish by process name alone)
    pumpPid := knownPumpPid
    if (!guiConnected) {
        Log("FAIL: GUI not connected to pump — auto-restart requires active pipe connection")
        TestErrors++
    } else if (!pumpPid || !ProcessExist(pumpPid)) {
        Log("FAIL: Pump not running, cannot test pump kill auto-restart")
        TestErrors++
    } else {
        Log("Pump PID before kill: " pumpPid " (from launcher)")
        ProcessClose(pumpPid)

        ; Verify kill actually worked
        Sleep(100)
        if (ProcessExist(pumpPid))
            Log("WARNING: Pump process " pumpPid " still alive after ProcessClose!")
        else
            Log("Pump process " pumpPid " confirmed dead")

        newPumpPid := 0
        killRestartStart := A_TickCount
        while ((A_TickCount - killRestartStart) < 10000) {
            candidate := _Lifecycle_FindNonGuiChild(launcherPid, knownGuiPid)
            if (candidate && candidate != pumpPid) {
                newPumpPid := candidate
                break
            }
            Sleep(100)
        }

        if (newPumpPid) {
            Log("PASS: Pump auto-restarted after kill (old=" pumpPid ", new=" newPumpPid ") in " (A_TickCount - killRestartStart) "ms")
            TestPassed++
        } else {
            Log("FAIL: Pump did not auto-restart within 10s after kill")
            TestErrors++
            ; Dump diagnostic logs for debugging
            pumpLogPath := A_Temp "\tabby_pump.log"
            launcherLogPath := A_Temp "\tabby_launcher.log"
            if (FileExist(pumpLogPath)) {
                try {
                    pumpLog := FileRead(pumpLogPath)
                    Log("--- Pump Log (last 2000 chars) ---")
                    Log(SubStr(pumpLog, -2000))
                }
            } else {
                Log("(no pump log found at " pumpLogPath ")")
            }
            if (FileExist(launcherLogPath)) {
                try {
                    launcherLog := FileRead(launcherLogPath)
                    Log("--- Launcher Log (last 2000 chars) ---")
                    Log(SubStr(launcherLog, -2000))
                }
            } else {
                Log("(no launcher log found at " launcherLogPath ")")
            }
        }
    }

    ; ============================================================
    ; Test 2: PUMP_FAILED signal triggers pump restart
    ; ============================================================
    ; Tests the launcher-side contract: when GUI reports pump failure,
    ; launcher kills the old pump and starts a new one.
    ; (GUI-side detection is internal — pipe write failure or response
    ; timeout both call _GUIPump_HandleFailure which sends this signal.)
    Log("`n--- PUMP_FAILED Signal Test ---")

    if (!guiConnected) {
        Log("FAIL: GUI not connected to pump — PUMP_FAILED test requires active pipe connection")
        TestErrors++
        pumpPid := 0
    } else {
        ; Wait for GUI to reconnect to restarted pump (poll log instead of fixed sleep)
        if (!_Lifecycle_WaitForPumpReconnect(1))
            Log("WARNING: GUI pump reconnect not detected after kill restart (test may fail)")

        ; Find current pump PID (not knownPumpPid which is stale after Test 1 restarted it)
        ; Use knownGuiPid to exclude the GUI — it hasn't changed
        pumpPid := _Lifecycle_FindNonGuiChild(launcherPid, knownGuiPid)
    }
    if (!pumpPid) {
        if (guiConnected)
            Log("FAIL: Pump not running, cannot test PUMP_FAILED signal")
            TestErrors++
    } else {
        Log("Pump PID before PUMP_FAILED signal: " pumpPid)
        response := _Lifecycle_SendCommand(launcherHwnd, 8)  ; TABBY_CMD_PUMP_FAILED = 8
        if (response = 1) {
            Log("PASS: Launcher acknowledged PUMP_FAILED")
            TestPassed++

            ; Verify pump process restarted (new PID)
            newPumpPid := 0
            signalRestartStart := A_TickCount
            while ((A_TickCount - signalRestartStart) < 10000) {
                candidate := _Lifecycle_FindNonGuiChild(launcherPid, knownGuiPid)
                if (candidate && candidate != pumpPid) {
                    newPumpPid := candidate
                    break
                }
                Sleep(100)
            }

            if (newPumpPid) {
                Log("PASS: Pump restarted via PUMP_FAILED signal (old=" pumpPid ", new=" newPumpPid ") in " (A_TickCount - signalRestartStart) "ms")
                TestPassed++
            } else {
                Log("FAIL: Pump did not restart within 10s after PUMP_FAILED signal")
                TestErrors++
            }
        } else {
            Log("FAIL: PUMP_FAILED signal not acknowledged (response=" response ")")
            TestErrors++
        }
    }

    ; ============================================================
    ; Test 3: Blacklist file watcher (replaces RELOAD_BLACKLIST signal)
    ; ============================================================
    ; Tests that modifying blacklist.txt on disk triggers the GUI's
    ; file watcher to reload blacklist rules (Blacklist_Init + WL_PurgeBlacklisted).
    Log("`n--- Blacklist File Watcher Test ---")

    ; Wait for GUI to reconnect to pump restarted by PUMP_FAILED signal (if pump tests ran)
    if (guiConnected) {
        if (!_Lifecycle_WaitForPumpReconnect(2))
            Log("WARNING: GUI pump reconnect not detected after PUMP_FAILED restart")
    } else {
        Sleep(500)  ; Brief settle when pump tests were skipped
    }

    ; Modify blacklist.txt on disk — the GUI file watcher should detect this
    blPath := testDir "\blacklist.txt"
    try FileAppend("; file watcher test " A_TickCount "`n", blPath, "UTF-8")

    ; Poll store log for watcher reload message
    storeLogPath := A_Temp "\tabby_store_error.log"
    watchReloaded := false
    watchStart := A_TickCount
    while ((A_TickCount - watchStart) < 5000) {
        if (FileExist(storeLogPath)) {
            try {
                logContent := FileRead(storeLogPath)
                if (InStr(logContent, "WATCH: blacklist reloaded")) {
                    watchReloaded := true
                    break
                }
            }
        }
        Sleep(100)
    }

    if (watchReloaded) {
        Log("PASS: Blacklist file watcher detected change and reloaded (" (A_TickCount - watchStart) "ms)")
        TestPassed++
    } else {
        Log("FAIL: Blacklist file watcher did not detect change within 5s")
        TestErrors++
        if (FileExist(storeLogPath)) {
            try {
                storeLog := FileRead(storeLogPath)
                Log("--- Store Log (last 1000 chars) ---")
                Log(SubStr(storeLog, -1000))
            }
        }
    }

    ; ============================================================
    ; Test 4: Config file watcher (replaces RESTART_ALL signal)
    ; ============================================================
    ; Tests that modifying config.ini on disk triggers the launcher's
    ; file watcher to restart subprocesses.
    Log("`n--- Config File Watcher Test ---")

    ; Wait for system to settle after blacklist watcher test
    Sleep(500)

    ; Use authoritative GUI PID from launcher (knownGuiPid is still valid — only pump changed)
    guiPidBefore := knownGuiPid
    if (!guiPidBefore || !ProcessExist(guiPidBefore)) {
        Log("FAIL: Could not find GUI process for config watcher test")
        TestErrors++
    } else {
        ; Modify config.ini on disk — the launcher file watcher should detect this
        ; and restart subprocesses (including GUI with new PID)
        configPath := testDir "\config.ini"
        try {
            content := FileRead(configPath, "UTF-8")
            ; Append a comment to trigger file change without affecting settings
            FileDelete(configPath)
            FileAppend(content "`n; file watcher test " A_TickCount "`n", configPath, "UTF-8")
        }

        ; Wait for GUI process to restart (new PID)
        restartStart := A_TickCount
        newGuiPid := 0
        while ((A_TickCount - restartStart) < 12000) {
            candidate := _Lifecycle_FindGuiPid(launcherPid)
            if (candidate && candidate != guiPidBefore) {
                newGuiPid := candidate
                break
            }
            Sleep(100)
        }

        if (newGuiPid) {
            Log("PASS: Config file watcher triggered GUI restart (old=" guiPidBefore ", new=" newGuiPid ") in " (A_TickCount - restartStart) "ms")
            TestPassed++
        } else {
            Log("FAIL: Config file watcher did not trigger GUI restart within 12s")
            TestErrors++
            launcherLogPath := A_Temp "\tabby_launcher.log"
            if (FileExist(launcherLogPath)) {
                try {
                    launcherLog := FileRead(launcherLogPath)
                    Log("--- Launcher Log (last 1000 chars) ---")
                    Log(SubStr(launcherLog, -1000))
                }
            }
        }
    }

    ; ============================================================
    ; Test 5: Ordered WM_CLOSE shutdown (GUI exits, then launcher)
    ; ============================================================
    Log("`n--- Ordered Shutdown Test ---")

    ; Re-find GUI PID after potential restart
    Sleep(500)
    guiPid := _Lifecycle_FindGuiPid(launcherPid)

    if (!guiPid) {
        Log("FAIL: Could not find GUI pid for shutdown test")
        TestErrors++
    } else {
        Log("Shutdown test: launcher=" launcherPid " gui=" guiPid)

        ; Send WM_CLOSE to launcher to trigger graceful shutdown
        ; Use DllCall because AHK's PostMessage can't find hidden message windows
        preShutdownTick := A_TickCount
        DllCall("PostMessageW", "ptr", launcherHwnd, "uint", 0x0010, "ptr", 0, "ptr", 0)

        ; High-frequency poll both PIDs to detect exit order
        guiExitTick := 0
        launcherExitTick := 0
        shutdownTimeout := 9000  ; 3s GUI + 3s margin + 3s launcher

        loop {
            elapsed := A_TickCount - preShutdownTick
            if (elapsed >= shutdownTimeout)
                break

            if (!guiExitTick && !ProcessExist(guiPid))
                guiExitTick := A_TickCount
            if (!launcherExitTick && !ProcessExist(launcherPid))
                launcherExitTick := A_TickCount

            ; Both gone, done
            if (guiExitTick && launcherExitTick)
                break

            Sleep(20)
        }

        ; Assert: GUI exited
        if (guiExitTick) {
            Log("PASS: GUI process exited (" (guiExitTick - preShutdownTick) "ms after WM_CLOSE)")
            TestPassed++
        } else {
            Log("FAIL: GUI process did not exit within " shutdownTimeout "ms")
            TestErrors++
        }

        ; Assert: Launcher also exited
        if (launcherExitTick) {
            Log("PASS: Launcher exited after shutdown (" (launcherExitTick - preShutdownTick) "ms)")
            TestPassed++
        } else {
            ; Give it a bit more time
            launcherWait := A_TickCount
            while (A_TickCount - launcherWait < 2000) {
                if (!ProcessExist(launcherPid)) {
                    launcherExitTick := A_TickCount
                    break
                }
                Sleep(50)
            }
            if (launcherExitTick) {
                Log("PASS: Launcher exited after extended wait")
                TestPassed++
            } else {
                Log("FAIL: Launcher still alive 2s after GUI exited")
                TestErrors++
            }
        }
    }

    ; Cleanup (safety net - processes should already be gone after Test 5)
    _Lifecycle_Cleanup()
}

; Kill all lifecycle test processes and remove temp directory
_Lifecycle_Cleanup() {
    global LIFECYCLE_EXE_NAME, LIFECYCLE_HWND_FILE

    ; Kill processes by name (only lifecycle copies, not other AltTabby.exe)
    for _, proc in _Test_EnumProcesses(LIFECYCLE_EXE_NAME) {
        try ProcessClose(proc.pid)
    }
    Sleep(50)

    try FileDelete(LIFECYCLE_HWND_FILE)

    ; Delete stale pump/launcher logs from previous runs (shared %TEMP% files,
    ; not inside testDir). Prevents false-positive detection of "Connected" messages.
    try FileDelete(A_Temp "\tabby_pump.log")
    try FileDelete(A_Temp "\tabby_launcher.log")
    try FileDelete(A_Temp "\tabby_store_error.log")

    ; Remove temp directory
    testDir := A_Temp "\alttabby_lifecycle_test"
    try DirDelete(testDir, true)
}

; Helper: find GUI PID (child of launcher, not the launcher itself)
_Lifecycle_FindGuiPid(launcherPid) {
    global LIFECYCLE_EXE_NAME
    children := _Test_FindChildProcesses(launcherPid, LIFECYCLE_EXE_NAME)
    ; Return first child that isn't the launcher itself
    for _, child in children {
        if (child.pid != launcherPid)
            return child.pid
    }
    return 0
}

; Helper: find pump PID (child of launcher that isn't the GUI)
; CAUTION: _Lifecycle_FindGuiPid returns the first child which may be the pump
; (launcher launches pump before GUI). Use _Lifecycle_FindNonGuiChild with a
; known GUI PID for reliable pump identification.
_Lifecycle_FindPumpPid(launcherPid) {
    global LIFECYCLE_EXE_NAME
    guiPid := _Lifecycle_FindGuiPid(launcherPid)
    children := _Test_FindChildProcesses(launcherPid, LIFECYCLE_EXE_NAME)
    for _, child in children {
        if (child.pid != launcherPid && child.pid != guiPid)
            return child.pid
    }
    return 0
}

; Helper: find child of launcher that is NOT the known GUI PID
; Used when the launcher writes authoritative PIDs to the HWND file
; (GUI and pump are the same exe — can't distinguish by process name)
_Lifecycle_FindNonGuiChild(launcherPid, guiPid) {
    global LIFECYCLE_EXE_NAME
    children := _Test_FindChildProcesses(launcherPid, LIFECYCLE_EXE_NAME)
    for _, child in children {
        if (child.pid != launcherPid && child.pid != guiPid)
            return child.pid
    }
    return 0
}

; Helper: poll for GUI pump reconnection by counting RECONNECT entries in pump log.
; Returns true if a new RECONNECT appeared within timeoutMs.
_Lifecycle_WaitForPumpReconnect(expectedCount, timeoutMs := 6000) {
    pumpLogPath := A_Temp "\tabby_pump.log"
    pollStart := A_TickCount
    while ((A_TickCount - pollStart) < timeoutMs) {
        if (FileExist(pumpLogPath)) {
            try {
                logContent := FileRead(pumpLogPath)
                count := 0
                pos := 1
                while (pos := InStr(logContent, "RECONNECT: Success", , pos))
                    count++, pos++
                if (count >= expectedCount)
                    return true
            }
        }
        Sleep(100)
    }
    return false
}

; Helper: send WM_COPYDATA command with retry for transient busy states.
; After pump restarts, the GUI may be mid-reconnect when the next command arrives.
; Retries up to timeoutMs with 500ms gaps between attempts.
_Lifecycle_SendCommandWithRetry(launcherHwnd, commandId, timeoutMs := 8000) {
    retryStart := A_TickCount
    loop {
        response := _Lifecycle_SendCommand(launcherHwnd, commandId)
        if (response = 1)
            return response
        if ((A_TickCount - retryStart) >= timeoutMs)
            return response
        Sleep(500)
    }
}

; Helper: send WM_COPYDATA command to launcher, return response
_Lifecycle_SendCommand(launcherHwnd, commandId) {
    cds := Buffer(3 * A_PtrSize, 0)
    NumPut("uptr", commandId, cds, 0)
    NumPut("uint", 0, cds, A_PtrSize)
    NumPut("ptr", 0, cds, 2 * A_PtrSize)

    response := 0
    result := DllCall("user32\SendMessageTimeoutW"
        , "ptr", launcherHwnd
        , "uint", 0x4A
        , "ptr", A_ScriptHwnd
        , "ptr", cds.Ptr
        , "uint", 0x0002
        , "uint", 3000
        , "ptr*", &response
        , "ptr")

    return (result ? response : 0)
}
