; Live Tests - Process Lifecycle
; Launcher WM_COPYDATA control signal tests
; Included by test_live.ahk
;
; ISOLATION: Copies AltTabby.exe to a temp dir as AltTabby_lifecycle.exe with
; its own config.ini (unique pipe name, FirstRunCompleted=true). This gives
; it a unique mutex (different InstallationId from different dir) and unique
; store pipe, so it runs without conflicting with other parallel test suites
; that also launch AltTabby.exe.

global LIFECYCLE_EXE_NAME := "AltTabby_lifecycle.exe"
global LIFECYCLE_PIPE_NAME := "tabby_store_lifecycle"
global LIFECYCLE_HWND_FILE := A_Temp "\alttabby_lifecycle_hwnd.txt"

RunLiveTests_Lifecycle() {
    global TestPassed, TestErrors
    global LIFECYCLE_EXE_NAME, LIFECYCLE_PIPE_NAME, LIFECYCLE_HWND_FILE

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

    ; Write config.ini with unique pipe name and wizard skip
    configContent := "[Setup]`nFirstRunCompleted=true`n`n[IPC]`nStorePipeName=" LIFECYCLE_PIPE_NAME "`n"
    FileAppend(configContent, testDir "\config.ini", "UTF-8")

    ; Launch
    launcherPid := 0
    if (!_Test_RunSilent('"' testExe '" --testing-mode', &launcherPid)) {
        Log("FAIL: Could not launch " LIFECYCLE_EXE_NAME)
        TestErrors++
        _Lifecycle_Cleanup()
        return
    }

    ; Wait for 3 processes (launcher + store + gui)
    processCount := 0
    spawnStart := A_TickCount
    loop {
        if ((A_TickCount - spawnStart) >= 5000)
            break
        processCount := 0
        for proc in ComObjGet("winmgmts:").ExecQuery(
            "Select * from Win32_Process Where Name = '" LIFECYCLE_EXE_NAME "'")
            processCount++
        if (processCount >= 3)
            break
        Sleep(200)
    }
    if (processCount < 3) {
        Log("SKIP: Only " processCount " process(es) of " LIFECYCLE_EXE_NAME ", need 3")
        _Lifecycle_Cleanup()
        return
    }

    ; Read launcher HWND from temp file (launcher writes it in --testing-mode
    ; because CREATE_NO_WINDOW hides AHK's message window from WinGetList)
    launcherHwnd := 0
    hwndStart := A_TickCount
    loop {
        if ((A_TickCount - hwndStart) >= 5000)
            break
        if (FileExist(LIFECYCLE_HWND_FILE)) {
            try {
                hwndStr := Trim(FileRead(LIFECYCLE_HWND_FILE), " `t`r`n")
                if (hwndStr != "")
                    launcherHwnd := Integer(hwndStr)
            }
        }
        if (launcherHwnd)
            break
        Sleep(200)
    }
    if (!launcherHwnd) {
        Log("FAIL: Could not read launcher HWND from " LIFECYCLE_HWND_FILE)
        TestErrors++
        _Lifecycle_Cleanup()
        return
    }

    if (!WaitForStorePipe(LIFECYCLE_PIPE_NAME, 3000)) {
        Log("FAIL: Store pipe '" LIFECYCLE_PIPE_NAME "' not ready")
        TestErrors++
        _Lifecycle_Cleanup()
        return
    }

    ; ============================================================
    ; Test 1: RESTART_STORE signal
    ; ============================================================
    Log("`n--- RESTART_STORE Signal Test ---")

    ; Find and kill store process
    storePid := _Lifecycle_FindStorePid(launcherPid)
    if (!storePid) {
        Log("FAIL: Could not identify store process")
        TestErrors++
    } else {
        try ProcessClose(storePid)
        Sleep(500)

        response := _Lifecycle_SendCommand(launcherHwnd, 1)  ; RESTART_STORE
        if (response = 1) {
            Log("PASS: Launcher acknowledged RESTART_STORE")
            TestPassed++
            if (WaitForStorePipe(LIFECYCLE_PIPE_NAME, 5000)) {
                Log("PASS: Store pipe available after restart")
                TestPassed++
            } else {
                Log("FAIL: Store pipe not available after restart (5s)")
                TestErrors++
            }
        } else {
            Log("FAIL: RESTART_STORE signal failed (response=" response ")")
            TestErrors++
        }
    }

    ; ============================================================
    ; Test 2: RESTART_ALL signal (config editor path)
    ; ============================================================
    Log("`n--- RESTART_ALL Signal Test ---")

    ; Wait for system to stabilize after first test
    Sleep(1000)
    if (!WaitForStorePipe(LIFECYCLE_PIPE_NAME, 3000)) {
        Log("SKIP: Store not available for RESTART_ALL test")
    } else {
        response := _Lifecycle_SendCommand(launcherHwnd, 2)  ; RESTART_ALL
        if (response = 1) {
            Log("PASS: Launcher acknowledged RESTART_ALL")
            TestPassed++
            ; Wait for processes to restart and store pipe to come back
            if (WaitForStorePipe(LIFECYCLE_PIPE_NAME, 5000)) {
                Log("PASS: Store pipe available after RESTART_ALL")
                TestPassed++
            } else {
                Log("FAIL: Store pipe not available after RESTART_ALL (5s)")
                TestErrors++
            }
        } else {
            Log("FAIL: RESTART_ALL signal failed (response=" response ")")
            TestErrors++
        }
    }

    ; ============================================================
    ; Test 3: Ordered WM_CLOSE shutdown (GUI exits before Store)
    ; ============================================================
    Log("`n--- Ordered Shutdown Test ---")

    ; Wait for system to stabilize after RESTART_ALL
    Sleep(1000)
    if (!WaitForStorePipe(LIFECYCLE_PIPE_NAME, 3000)) {
        Log("SKIP: Store not available for shutdown order test")
    } else {
        guiPid := _Lifecycle_FindGuiPid(launcherPid)
        storePid := _Lifecycle_FindStorePid(launcherPid)

        if (!guiPid || !storePid) {
            Log("SKIP: Could not find GUI pid (" guiPid ") or Store pid (" storePid ") for shutdown test")
        } else {
            Log("Shutdown test: launcher=" launcherPid " gui=" guiPid " store=" storePid)

            ; Record wall-clock time before shutdown to verify stats flush
            preShutdownTime := A_Now

            ; Send WM_CLOSE to launcher to trigger _GracefulShutdown
            ; Use DllCall because AHK's PostMessage can't find hidden message windows
            preShutdownTick := A_TickCount
            DllCall("PostMessageW", "ptr", launcherHwnd, "uint", 0x0010, "ptr", 0, "ptr", 0)

            ; High-frequency poll both PIDs to detect exit order
            guiExitTick := 0
            storeExitTick := 0
            shutdownTimeout := 12000  ; 3s GUI + 5s Store + 4s margin

            loop {
                elapsed := A_TickCount - preShutdownTick
                if (elapsed >= shutdownTimeout)
                    break

                if (!guiExitTick && !ProcessExist(guiPid))
                    guiExitTick := A_TickCount
                if (!storeExitTick && !ProcessExist(storePid))
                    storeExitTick := A_TickCount

                ; Both gone, done
                if (guiExitTick && storeExitTick)
                    break

                Sleep(20)
            }

            ; Assert: GUI and Store both exited
            if (guiExitTick && storeExitTick) {
                ; Assert: GUI exited before or same tick as Store
                if (guiExitTick <= storeExitTick) {
                    Log("PASS: Shutdown order correct - GUI exited before Store (gui=" (guiExitTick - preShutdownTick) "ms, store=" (storeExitTick - preShutdownTick) "ms)")
                    TestPassed++
                } else {
                    Log("FAIL: Shutdown order wrong - Store exited before GUI (gui=" (guiExitTick - preShutdownTick) "ms, store=" (storeExitTick - preShutdownTick) "ms)")
                    TestErrors++
                }
            } else {
                if (!guiExitTick) {
                    Log("FAIL: GUI process did not exit within " shutdownTimeout "ms")
                    TestErrors++
                }
                if (!storeExitTick) {
                    Log("FAIL: Store process did not exit within " shutdownTimeout "ms")
                    TestErrors++
                }
            }

            ; Assert: Launcher also exited (give it a moment after store dies)
            launcherGone := false
            launcherWait := A_TickCount
            while (A_TickCount - launcherWait < 3000) {
                if (!ProcessExist(launcherPid)) {
                    launcherGone := true
                    break
                }
                Sleep(50)
            }
            if (launcherGone) {
                Log("PASS: Launcher exited after shutdown")
                TestPassed++
            } else {
                Log("FAIL: Launcher still alive 3s after store exited")
                TestErrors++
            }

            ; Assert: stats.ini was flushed during graceful shutdown
            statsPath := testDir "\stats.ini"
            if (FileExist(statsPath)) {
                statsModTime := FileGetTime(statsPath, "M")
                if (statsModTime >= preShutdownTime) {
                    Log("PASS: stats.ini flushed during shutdown (modified=" statsModTime ")")
                    TestPassed++
                } else {
                    Log("FAIL: stats.ini exists but was not updated during shutdown (modified=" statsModTime ", shutdown started=" preShutdownTime ")")
                    TestErrors++
                }
            } else {
                Log("FAIL: stats.ini not found after graceful shutdown")
                TestErrors++
            }
        }
    }

    ; Cleanup (safety net - processes should already be gone after Test 3)
    _Lifecycle_Cleanup()
}

; Kill all lifecycle test processes and remove temp directory
_Lifecycle_Cleanup() {
    global LIFECYCLE_EXE_NAME, LIFECYCLE_HWND_FILE

    ; Kill processes by name (only lifecycle copies, not other AltTabby.exe)
    for proc in ComObjGet("winmgmts:").ExecQuery(
        "Select * from Win32_Process Where Name = '" LIFECYCLE_EXE_NAME "'") {
        try proc.Terminate()
    }
    Sleep(200)

    try FileDelete(LIFECYCLE_HWND_FILE)

    ; Remove temp directory
    testDir := A_Temp "\alttabby_lifecycle_test"
    try DirDelete(testDir, true)
}

; Helper: find GUI PID by WMI (--gui-only in command line, not launcher)
_Lifecycle_FindGuiPid(launcherPid) {
    global LIFECYCLE_EXE_NAME
    for proc in ComObjGet("winmgmts:").ExecQuery(
        "Select ProcessId, CommandLine from Win32_Process Where Name = '" LIFECYCLE_EXE_NAME "'") {
        pid := proc.ProcessId
        cmdLine := ""
        try cmdLine := proc.CommandLine
        if (pid != launcherPid && InStr(cmdLine, "--gui-only"))
            return pid
    }
    return 0
}

; Helper: find store PID by WMI (--store in command line, not launcher)
_Lifecycle_FindStorePid(launcherPid) {
    global LIFECYCLE_EXE_NAME
    for proc in ComObjGet("winmgmts:").ExecQuery(
        "Select ProcessId, CommandLine from Win32_Process Where Name = '" LIFECYCLE_EXE_NAME "'") {
        pid := proc.ProcessId
        cmdLine := ""
        try cmdLine := proc.CommandLine
        if (pid != launcherPid && InStr(cmdLine, "--store"))
            return pid
    }
    return 0
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
