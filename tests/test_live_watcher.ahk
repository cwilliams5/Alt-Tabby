; Live Tests - File Watchers & Shutdown
; Blacklist watcher, config watcher, and ordered shutdown tests
; Included by test_live.ahk
;
; ISOLATION: Copies AltTabby.exe to a worktree-scoped temp dir with a unique exe
; name, pipe name, and log prefix. This gives each worktree its own mutex
; (different InstallationId), process name, HWND file, and log files — safe for
; parallel multi-agent execution.
#Include test_utils.ahk

global WATCHER_EXE_NAME := "AltTabby_wt_" WorktreeId ".exe"
global WATCHER_HWND_FILE := A_Temp "\alttabby_wt_" WorktreeId "_hwnd.txt"
global WATCHER_LOG_PREFIX := "wt_" WorktreeId

RunLiveTests_Watcher() {
    global TestPassed, TestErrors
    global WATCHER_EXE_NAME, WATCHER_HWND_FILE, WATCHER_LOG_PREFIX

    compiledExePath := A_ScriptDir "\..\release\AltTabby.exe"

    if (!FileExist(compiledExePath)) {
        Log("SKIP: Watcher tests - AltTabby.exe not found")
        return
    }

    ; ============================================================
    ; Setup: create isolated copy and launch full system
    ; ============================================================
    Log("`n--- Watcher Test Setup ---")

    ; Create isolated test environment (worktree-scoped for multi-agent safety)
    testDir := A_Temp "\alttabby_watcher_" WorktreeId
    testExe := testDir "\" WATCHER_EXE_NAME
    logPrefix := WATCHER_LOG_PREFIX
    pipeName := "tabby_pump_wt_" WorktreeId

    ; Scoped log paths for polling (must match LogFilePrefix in config)
    storeLogPath := A_Temp "\tabby_store_error_" logPrefix ".log"
    launcherLogPath := A_Temp "\tabby_launcher_" logPrefix ".log"

    _Watcher_Cleanup()  ; Clean previous runs

    DirCreate(testDir)
    FileCopy(compiledExePath, testExe, true)

    ; Write config.ini with wizard skip, diagnostics, and worktree-scoped isolation
    ; No PumpLog — watcher tests don't exercise pump
    configContent := "[Setup]`nFirstRunCompleted=true`n[Diagnostics]`nLauncherLog=true`nStoreLog=true`nLogFilePrefix=" logPrefix "`n[IPC]`nPumpPipeName=" pipeName "`n"
    FileAppend(configContent, testDir "\config.ini", "UTF-8")

    ; Launch
    launcherPid := 0
    if (!_Test_RunSilent('"' testExe '" --testing-mode', &launcherPid)) {
        Log("FAIL: Could not launch " WATCHER_EXE_NAME)
        TestErrors++
        _Watcher_Cleanup()
        return
    }

    ; Wait for 2 processes (launcher + gui). Skip pump connection wait.
    processCount := 0
    spawnStart := A_TickCount
    loop {
        if ((A_TickCount - spawnStart) >= 5000)
            break
        processCount := _Test_CountProcesses(WATCHER_EXE_NAME)
        if (processCount >= 2)
            break
        Sleep(50)
    }
    if (processCount < 2) {
        Log("FAIL: Only " processCount " process(es) of " WATCHER_EXE_NAME ", need 2 (launcher + gui)")
        TestErrors++
        _Watcher_Cleanup()
        return
    }

    Log("PASS: " processCount " processes spawned (launcher + gui" (processCount > 2 ? " + pump" : "") ")")
    TestPassed++

    ; Read launcher HWND + child PIDs from temp file
    ; Format: line 1 = launcher HWND, line 2 = gui PID, line 3 = pump PID
    launcherHwnd := 0
    knownGuiPid := 0
    hwndStart := A_TickCount
    loop {
        if ((A_TickCount - hwndStart) >= 5000)
            break
        if (FileExist(WATCHER_HWND_FILE)) {
            try {
                content := Trim(FileRead(WATCHER_HWND_FILE), " `t`r`n")
                lines := StrSplit(content, "`n", "`r")
                if (lines.Length >= 1 && lines[1] != "")
                    launcherHwnd := Integer(Trim(lines[1]))
                if (lines.Length >= 2 && lines[2] != "" && lines[2] != "0")
                    knownGuiPid := Integer(Trim(lines[2]))
            }
        }
        if (launcherHwnd)
            break
        Sleep(50)
    }
    if (!launcherHwnd) {
        Log("FAIL: Could not read launcher HWND from " WATCHER_HWND_FILE)
        TestErrors++
        _Watcher_Cleanup()
        return
    }
    if (knownGuiPid)
        Log("Launcher reported: gui PID=" knownGuiPid)

    ; Wait for GUI to finish init — file watchers must be active before we touch
    ; blacklist.txt. Poll store log as readiness signal: producers start AFTER file
    ; watcher init (gui_main.ahk line ~135 vs ~150+), so store log activity means
    ; file watchers are already set up.
    settleStart := A_TickCount
    settleReady := false
    while ((A_TickCount - settleStart) < 8000) {
        if (FileExist(storeLogPath)) {
            settleReady := true
            break
        }
        Sleep(100)
    }
    Log("GUI ready: " (settleReady ? "yes" : "no") " (" (A_TickCount - settleStart) "ms)")

    ; ============================================================
    ; Test 3: Blacklist file watcher (replaces RELOAD_BLACKLIST signal)
    ; ============================================================
    ; Tests that modifying blacklist.txt on disk triggers the GUI's
    ; file watcher to reload blacklist rules (Blacklist_Init + WL_PurgeBlacklisted).
    Log("`n--- Blacklist File Watcher Test ---")

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

    ; Use authoritative GUI PID from launcher
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
            candidate := _Watcher_FindGuiPid(launcherPid)
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
    guiPid := _Watcher_FindGuiPid(launcherPid)

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
    _Watcher_Cleanup()
}

; Kill all watcher test processes and remove temp directory
_Watcher_Cleanup() {
    global WATCHER_EXE_NAME, WATCHER_HWND_FILE, WATCHER_LOG_PREFIX

    ; Kill processes by name (only watcher copies, not other AltTabby.exe)
    for _, proc in _Test_EnumProcesses(WATCHER_EXE_NAME) {
        try ProcessClose(proc.pid)
    }
    Sleep(50)

    try FileDelete(WATCHER_HWND_FILE)

    ; Delete worktree-scoped logs and marker files from previous runs.
    ; Prevents false-positive detection from stale data.
    try FileDelete(A_Temp "\tabby_launcher_" WATCHER_LOG_PREFIX ".log")
    try FileDelete(A_Temp "\tabby_store_error_" WATCHER_LOG_PREFIX ".log")

    ; Remove temp directory
    testDir := A_Temp "\alttabby_watcher_" WorktreeId
    try DirDelete(testDir, true)
}

; Helper: find GUI PID (child of launcher, not the launcher itself)
_Watcher_FindGuiPid(launcherPid) {
    global WATCHER_EXE_NAME
    children := _Test_FindChildProcesses(launcherPid, WATCHER_EXE_NAME)
    ; Return first child that isn't the launcher itself
    for _, child in children {
        if (child.pid != launcherPid)
            return child.pid
    }
    return 0
}

; Helper: send WM_COPYDATA command to launcher, return response
_Watcher_SendCommand(launcherHwnd, commandId) {
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
