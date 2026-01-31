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

    ; Cleanup
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
