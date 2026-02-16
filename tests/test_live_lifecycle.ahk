; Live Tests - Process Lifecycle
; Launcher WM_COPYDATA control signal tests (2-process model: launcher + gui)
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
    configContent := "[Setup]`nFirstRunCompleted=true`n"
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
        processCount := 0
        for proc in ComObjGet("winmgmts:").ExecQuery(
            "Select * from Win32_Process Where Name = '" LIFECYCLE_EXE_NAME "'")
            processCount++
        if (processCount >= 2)
            break
        Sleep(50)
    }
    if (processCount < 2) {
        Log("SKIP: Only " processCount " process(es) of " LIFECYCLE_EXE_NAME ", need 2 (launcher + gui)")
        _Lifecycle_Cleanup()
        return
    }

    Log("PASS: " processCount " processes spawned (launcher + gui" (processCount > 2 ? " + pump" : "") ")")
    TestPassed++

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
        Sleep(50)
    }
    if (!launcherHwnd) {
        Log("FAIL: Could not read launcher HWND from " LIFECYCLE_HWND_FILE)
        TestErrors++
        _Lifecycle_Cleanup()
        return
    }

    ; Give GUI time to initialize (no store pipe to wait for — poll process count)
    Sleep(1000)

    ; ============================================================
    ; Test 1: RESTART_ALL signal (config editor path)
    ; ============================================================
    Log("`n--- RESTART_ALL Signal Test ---")

    guiPidBefore := _Lifecycle_FindGuiPid(launcherPid)
    if (!guiPidBefore) {
        Log("SKIP: Could not find GUI process for RESTART_ALL test")
    } else {
        response := _Lifecycle_SendCommand(launcherHwnd, 2)  ; RESTART_ALL
        if (response = 1) {
            Log("PASS: Launcher acknowledged RESTART_ALL")
            TestPassed++

            ; Wait for GUI process to restart (new PID)
            restartStart := A_TickCount
            newGuiPid := 0
            while ((A_TickCount - restartStart) < 8000) {
                candidate := _Lifecycle_FindGuiPid(launcherPid)
                if (candidate && candidate != guiPidBefore) {
                    newGuiPid := candidate
                    break
                }
                Sleep(100)
            }

            if (newGuiPid) {
                Log("PASS: GUI process restarted with new PID (old=" guiPidBefore ", new=" newGuiPid ")")
                TestPassed++
            } else {
                Log("FAIL: GUI process did not restart within timeout")
                TestErrors++
            }
        } else {
            Log("FAIL: RESTART_ALL signal failed (response=" response ")")
            TestErrors++
        }
    }

    ; ============================================================
    ; Test 2: Ordered WM_CLOSE shutdown (GUI exits, then launcher)
    ; ============================================================
    Log("`n--- Ordered Shutdown Test ---")

    ; Re-find GUI PID after potential restart
    Sleep(500)
    guiPid := _Lifecycle_FindGuiPid(launcherPid)

    if (!guiPid) {
        Log("SKIP: Could not find GUI pid for shutdown test")
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

    ; Cleanup (safety net - processes should already be gone after Test 2)
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
    Sleep(50)

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
