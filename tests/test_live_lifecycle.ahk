; Live Tests - Process Lifecycle
; Pump restart, file watcher, and shutdown tests (2-process model: launcher + gui)
; Included by test_live.ahk
;
; ISOLATION: Copies AltTabby.exe to a worktree-scoped temp dir with a unique exe
; name, pipe name, and log prefix. This gives each worktree its own mutex
; (different InstallationId), process name, HWND file, and log files — safe for
; parallel multi-agent execution.
#Include test_utils.ahk

global LIFECYCLE_EXE_NAME := "AltTabby_lc_" WorktreeId ".exe"
global LIFECYCLE_HWND_FILE := A_Temp "\alttabby_lc_" WorktreeId "_hwnd.txt"
global LIFECYCLE_LOG_PREFIX := "lc_" WorktreeId

RunLiveTests_Lifecycle() {
    global TestPassed, TestErrors
    global LIFECYCLE_EXE_NAME, LIFECYCLE_HWND_FILE, LIFECYCLE_LOG_PREFIX

    compiledExePath := A_ScriptDir "\..\release\AltTabby.exe"

    if (!FileExist(compiledExePath)) {
        Log("SKIP: Lifecycle tests - AltTabby.exe not found")
        return
    }

    ; ============================================================
    ; Setup: create isolated copy and launch full system
    ; ============================================================
    Log("`n--- Lifecycle Test Setup ---")

    ; Create isolated test environment (worktree-scoped for multi-agent safety)
    testDir := A_Temp "\alttabby_lifecycle_" WorktreeId
    testExe := testDir "\" LIFECYCLE_EXE_NAME
    logPrefix := LIFECYCLE_LOG_PREFIX
    pipeName := "tabby_pump_lc_" WorktreeId

    ; Scoped log paths for polling (must match LogFilePrefix in config)
    pumpLogPath := A_Temp "\tabby_pump_" logPrefix ".log"
    storeLogPath := A_Temp "\tabby_store_error_" logPrefix ".log"
    launcherLogPath := A_Temp "\tabby_launcher_" logPrefix ".log"

    _Lifecycle_Cleanup()  ; Clean previous runs

    DirCreate(testDir)
    FileCopy(compiledExePath, testExe, true)

    ; Write config.ini with wizard skip, diagnostics, and worktree-scoped isolation
    configContent := "[Setup]`nFirstRunCompleted=true`n[Diagnostics]`nPumpLog=true`nLauncherLog=true`nStoreLog=true`nLogFilePrefix=" logPrefix "`n[IPC]`nPumpPipeName=" pipeName "`n"
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

    ; Wait for GUI to connect to pump (marker file written by GUIPump_Init in testing mode).
    ; Decoupled from diagnostic logging — polls a dedicated readiness signal file.
    ; GUIPump_Init has deferred retries (500+1000+2000ms delays, each with 2s connect timeout)
    ; so worst-case connection takes ~11.5s. Allow 15s to cover full retry window.
    connectStart := A_TickCount
    guiConnected := false
    pumpReadyPath := A_Temp "\tabby_pump_ready_" logPrefix ".txt"
    while ((A_TickCount - connectStart) < 15000) {
        if (FileExist(pumpReadyPath)) {
            try {
                content := Trim(FileRead(pumpReadyPath), " `t`r`n")
                if (content != "" && Integer(content) >= 1)
                    guiConnected := true
            }
        }
        if (guiConnected)
            break
        Sleep(50)
    }
    connectElapsed := A_TickCount - connectStart
    if (guiConnected)
        Log("Pump connection detected (" connectElapsed "ms)")
    else
        Log("WARNING: GUI did not signal pump connection within 15s")

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
        ; Poll enrichment marker file (written by _GUIPump_OnMessage in testing mode).
        ; GUI's initial WinEnum scan enqueues all windows for enrichment, so the
        ; pump should process at least one batch within a few seconds of connecting.
        enrichSeen := false
        enrichStart := A_TickCount
        enrichPath := A_Temp "\tabby_pump_enrich_" logPrefix ".txt"
        while ((A_TickCount - enrichStart) < 8000) {
            if (FileExist(enrichPath)) {
                try {
                    content := Trim(FileRead(enrichPath), " `t`r`n")
                    if (content != "" && Integer(content) >= 1)
                        enrichSeen := true
                }
            }
            if (enrichSeen)
                break
            Sleep(50)
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
        ; Wait for GUI to reconnect to restarted pump (poll marker file for count >= 2)
        reconnect1Start := A_TickCount
        reconnect1Ok := false
        while ((A_TickCount - reconnect1Start) < 6000) {
            if (FileExist(pumpReadyPath)) {
                try {
                    content := Trim(FileRead(pumpReadyPath), " `t`r`n")
                    if (content != "" && Integer(content) >= 2)
                        reconnect1Ok := true
                }
            }
            if (reconnect1Ok)
                break
            Sleep(50)
        }
        reconnect1Elapsed := A_TickCount - reconnect1Start
        if (reconnect1Ok)
            Log("Pump reconnect 1 detected (" reconnect1Elapsed "ms)")
        else
            Log("WARNING: GUI pump reconnect not detected after kill restart (" reconnect1Elapsed "ms, test may fail)")

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
        reconnect2Start := A_TickCount
        reconnect2Ok := false
        while ((A_TickCount - reconnect2Start) < 6000) {
            if (FileExist(pumpReadyPath)) {
                try {
                    content := Trim(FileRead(pumpReadyPath), " `t`r`n")
                    if (content != "" && Integer(content) >= 3)
                        reconnect2Ok := true
                }
            }
            if (reconnect2Ok)
                break
            Sleep(50)
        }
        reconnect2Elapsed := A_TickCount - reconnect2Start
        if (reconnect2Ok)
            Log("Pump reconnect 2 detected (" reconnect2Elapsed "ms)")
        else
            Log("WARNING: GUI pump reconnect not detected after PUMP_FAILED restart (" reconnect2Elapsed "ms)")
    } else {
        Sleep(500)  ; Brief settle when pump tests were skipped
    }

    ; Modify blacklist.txt on disk — the GUI file watcher should detect this
    blPath := testDir "\blacklist.txt"
    try FileAppend("; file watcher test " A_TickCount "`n", blPath, "UTF-8")

    ; Poll store log for watcher reload message
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

    ; Brief settle after blacklist watcher test
    Sleep(200)

    ; Use authoritative GUI PID from launcher (knownGuiPid is still valid — only pump changed)
    guiPidBefore := knownGuiPid
    if (!guiPidBefore || !ProcessExist(guiPidBefore)) {
        Log("FAIL: Could not find GUI process for config watcher test")
        TestErrors++
    } else {
        ; Modify config.ini on disk — the launcher file watcher should detect this
        ; and restart subprocesses (including GUI with new PID)
        configPath := testDir "\config.ini"
        try FileAppend("`n; file watcher test " A_TickCount "`n", configPath, "UTF-8")

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
    Sleep(200)
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
    global LIFECYCLE_EXE_NAME, LIFECYCLE_HWND_FILE, LIFECYCLE_LOG_PREFIX

    ; Kill processes by name (only lifecycle copies, not other AltTabby.exe)
    for _, proc in _Test_EnumProcesses(LIFECYCLE_EXE_NAME) {
        try ProcessClose(proc.pid)
    }
    Sleep(50)

    try FileDelete(LIFECYCLE_HWND_FILE)

    ; Delete worktree-scoped logs and marker files from previous runs.
    ; Prevents false-positive detection from stale data.
    try FileDelete(A_Temp "\tabby_pump_" LIFECYCLE_LOG_PREFIX ".log")
    try FileDelete(A_Temp "\tabby_launcher_" LIFECYCLE_LOG_PREFIX ".log")
    try FileDelete(A_Temp "\tabby_store_error_" LIFECYCLE_LOG_PREFIX ".log")
    try FileDelete(A_Temp "\tabby_pump_ready_" LIFECYCLE_LOG_PREFIX ".txt")
    try FileDelete(A_Temp "\tabby_pump_enrich_" LIFECYCLE_LOG_PREFIX ".txt")

    ; Remove temp directory
    testDir := A_Temp "\alttabby_lifecycle_" WorktreeId
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
