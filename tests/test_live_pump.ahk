; Live Tests - Pump Connection, Enrichment & Restart
; Pump connection wait, enrichment round-trip, kill-restart, PUMP_FAILED signal
; Included by test_live.ahk
;
; ISOLATION: Copies AltTabby.exe to a worktree-scoped temp dir with a unique exe
; name, pipe name, and log prefix. This gives each worktree its own mutex
; (different InstallationId), process name, HWND file, and log files — safe for
; parallel multi-agent execution.
#Include test_utils.ahk

global PUMP_EXE_NAME := "AltTabby_pm_" WorktreeId ".exe"
global PUMP_HWND_FILE := A_Temp "\alttabby_pm_" WorktreeId "_hwnd.txt"
global PUMP_LOG_PREFIX := "pm_" WorktreeId

RunLiveTests_Pump() {
    global TestPassed, TestErrors
    global PUMP_EXE_NAME, PUMP_HWND_FILE, PUMP_LOG_PREFIX

    compiledExePath := A_ScriptDir "\..\release\AltTabby.exe"

    if (!FileExist(compiledExePath)) {
        Log("SKIP: Pump tests - AltTabby.exe not found")
        return
    }

    ; ============================================================
    ; Setup: create isolated copy and launch full system
    ; ============================================================
    Log("`n--- Pump Test Setup ---")

    ; Create isolated test environment (worktree-scoped for multi-agent safety)
    testDir := A_Temp "\alttabby_pump_" WorktreeId
    testExe := testDir "\" PUMP_EXE_NAME
    logPrefix := PUMP_LOG_PREFIX
    pipeName := "tabby_pump_pm_" WorktreeId

    ; Scoped log paths for polling (must match LogFilePrefix in config)
    pumpLogPath := A_Temp "\tabby_pump_" logPrefix ".log"
    storeLogPath := A_Temp "\tabby_store_error_" logPrefix ".log"
    launcherLogPath := A_Temp "\tabby_launcher_" logPrefix ".log"

    _Pump_Cleanup()  ; Clean previous runs

    DirCreate(testDir)
    FileCopy(compiledExePath, testExe, true)

    ; Write config.ini with wizard skip, diagnostics, and worktree-scoped isolation
    configContent := "[Setup]`nFirstRunCompleted=true`n[Diagnostics]`nPumpLog=true`nLauncherLog=true`nStoreLog=true`nLogFilePrefix=" logPrefix "`n[IPC]`nPumpPipeName=" pipeName "`n"
    FileAppend(configContent, testDir "\config.ini", "UTF-8")

    ; Launch
    launcherPid := 0
    if (!_Test_RunSilent('"' testExe '" --testing-mode', &launcherPid)) {
        Log("FAIL: Could not launch " PUMP_EXE_NAME)
        TestErrors++
        _Pump_Cleanup()
        return
    }

    ; Wait for 2 processes (launcher + gui). Pump is optional and may not spawn.
    processCount := 0
    spawnStart := A_TickCount
    loop {
        if ((A_TickCount - spawnStart) >= 5000)
            break
        processCount := _Test_CountProcesses(PUMP_EXE_NAME)
        if (processCount >= 2)
            break
        Sleep(50)
    }
    if (processCount < 2) {
        Log("FAIL: Only " processCount " process(es) of " PUMP_EXE_NAME ", need 2 (launcher + gui)")
        TestErrors++
        _Pump_Cleanup()
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
        if (FileExist(PUMP_HWND_FILE)) {
            try {
                content := Trim(FileRead(PUMP_HWND_FILE), " `t`r`n")
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
        Log("FAIL: Could not read launcher HWND from " PUMP_HWND_FILE)
        TestErrors++
        _Pump_Cleanup()
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
            candidate := _Pump_FindNonGuiChild(launcherPid, knownGuiPid)
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
        pumpPid := _Pump_FindNonGuiChild(launcherPid, knownGuiPid)
    }
    if (!pumpPid) {
        if (guiConnected)
            Log("FAIL: Pump not running, cannot test PUMP_FAILED signal")
            TestErrors++
    } else {
        Log("Pump PID before PUMP_FAILED signal: " pumpPid)
        response := _Pump_SendCommand(launcherHwnd, 8)  ; TABBY_CMD_PUMP_FAILED = 8
        if (response = 1) {
            Log("PASS: Launcher acknowledged PUMP_FAILED")
            TestPassed++

            ; Verify pump process restarted (new PID)
            newPumpPid := 0
            signalRestartStart := A_TickCount
            while ((A_TickCount - signalRestartStart) < 10000) {
                candidate := _Pump_FindNonGuiChild(launcherPid, knownGuiPid)
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

    ; Cleanup (kill processes — no graceful shutdown test needed here)
    _Pump_Cleanup()
}

; Kill all pump test processes and remove temp directory
_Pump_Cleanup() {
    global PUMP_EXE_NAME, PUMP_HWND_FILE, PUMP_LOG_PREFIX

    ; Kill processes by name (only pump copies, not other AltTabby.exe)
    for _, proc in _Test_EnumProcesses(PUMP_EXE_NAME) {
        try ProcessClose(proc.pid)
    }
    Sleep(50)

    try FileDelete(PUMP_HWND_FILE)

    ; Delete worktree-scoped logs and marker files from previous runs.
    ; Prevents false-positive detection from stale data.
    try FileDelete(A_Temp "\tabby_pump_" PUMP_LOG_PREFIX ".log")
    try FileDelete(A_Temp "\tabby_launcher_" PUMP_LOG_PREFIX ".log")
    try FileDelete(A_Temp "\tabby_store_error_" PUMP_LOG_PREFIX ".log")
    try FileDelete(A_Temp "\tabby_pump_ready_" PUMP_LOG_PREFIX ".txt")
    try FileDelete(A_Temp "\tabby_pump_enrich_" PUMP_LOG_PREFIX ".txt")

    ; Remove temp directory
    testDir := A_Temp "\alttabby_pump_" WorktreeId
    try DirDelete(testDir, true)
}

; Helper: find child of launcher that is NOT the known GUI PID
; Used when the launcher writes authoritative PIDs to the HWND file
; (GUI and pump are the same exe — can't distinguish by process name)
_Pump_FindNonGuiChild(launcherPid, guiPid) {
    global PUMP_EXE_NAME
    children := _Test_FindChildProcesses(launcherPid, PUMP_EXE_NAME)
    for _, child in children {
        if (child.pid != launcherPid && child.pid != guiPid)
            return child.pid
    }
    return 0
}

; Helper: send WM_COPYDATA command to launcher, return response
_Pump_SendCommand(launcherHwnd, commandId) {
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
