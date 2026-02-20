; Test Utilities - Logging, assertions, and shared helpers
; Included by run_tests.ahk

; --- Test Helpers ---

Log(msg) {
    global TestLogPath
    FileAppend(msg "`n", TestLogPath, "UTF-8")
}

AssertEq(actual, expected, name) {
    global TestErrors, TestPassed
    if (actual = expected) {
        Log("PASS: " name)
        TestPassed++
    } else {
        Log("FAIL: " name " - expected '" expected "', got '" actual "'")
        TestErrors++
    }
}

AssertTrue(condition, name) {
    global TestErrors, TestPassed
    if (condition) {
        Log("PASS: " name)
        TestPassed++
    } else {
        Log("FAIL: " name)
        TestErrors++
    }
}

; --- Temp Directory Helper ---
; Creates a temp directory, runs testFn(dir), and guarantees cleanup.
; prefix: unique name prefix for the temp dir
; testFn: callback that receives the temp dir path
_Test_WithTempDir(prefix, testFn) {
    dir := A_Temp "\" prefix "_" A_TickCount
    DirCreate(dir)
    try testFn(dir)
    finally {
        try DirDelete(dir, true)
    }
}

; --- Process Launch Helpers ---
; Windows shows the "app starting" cursor (pointer+hourglass) whenever a new
; process is launched via Run(). These helpers use CreateProcessW with
; STARTF_FORCEOFFFEEDBACK (0x80) to suppress that cursor change during tests.

; Prepare CreateProcessW buffers: writable command line, STARTUPINFOW, PROCESS_INFORMATION.
; Returns object with {cmdBuf, si, pi} ready for DllCall("CreateProcessW", ...).
_Test_PrepareCreateProcessBuffers(cmdLine) {
    cmdBuf := Buffer((StrLen(cmdLine) + 1) * 2)
    StrPut(cmdLine, cmdBuf, "UTF-16")

    ; STARTUPINFOW (104 bytes on 64-bit)
    si := Buffer(104, 0)
    NumPut("UInt", 104, si, 0)    ; cb = sizeof(STARTUPINFOW)
    NumPut("UInt", 0x81, si, 60)  ; dwFlags: STARTF_USESHOWWINDOW | STARTF_FORCEOFFFEEDBACK
    ; wShowWindow at offset 64 = 0 (SW_HIDE) from zero-init

    ; PROCESS_INFORMATION (24 bytes on 64-bit)
    pi := Buffer(24, 0)

    return {cmdBuf: cmdBuf, si: si, pi: pi}
}

; Launch a process hidden with CREATE_NO_WINDOW. Returns true/false.
; Caller must use bufs.pi to extract handles/PID afterward.
_Test_LaunchProcess(bufs, workDir := "") {
    wdPtr := 0
    if (workDir != "") {
        wdBuf := Buffer((StrLen(workDir) + 1) * 2)
        StrPut(workDir, wdBuf, "UTF-16")
        wdPtr := wdBuf.Ptr
    }
    return DllCall("CreateProcessW",
        "Ptr", 0, "Ptr", bufs.cmdBuf,
        "Ptr", 0, "Ptr", 0,
        "Int", 0,
        "UInt", 0x08000000,
        "Ptr", 0, "Ptr", wdPtr,
        "Ptr", bufs.si, "Ptr", bufs.pi,
        "Int")
}

; Launch a process hidden without cursor feedback.
; Returns true on success. Sets outPid to the new process ID.
_Test_RunSilent(cmdLine, &outPid := 0) {
    outPid := 0

    bufs := _Test_PrepareCreateProcessBuffers(cmdLine)

    result := _Test_LaunchProcess(bufs)

    if (result) {
        outPid := NumGet(bufs.pi, 16, "UInt")                     ; dwProcessId
        DllCall("CloseHandle", "Ptr", NumGet(bufs.pi, 0, "Ptr"))  ; hProcess
        DllCall("CloseHandle", "Ptr", NumGet(bufs.pi, 8, "Ptr"))  ; hThread
    }

    return result
}

; Launch a process hidden without cursor feedback and wait for it to exit.
; Returns the process exit code, or -1 on failure.
_Test_RunWaitSilent(cmdLine, workDir := "") {
    bufs := _Test_PrepareCreateProcessBuffers(cmdLine)

    result := _Test_LaunchProcess(bufs, workDir)

    if (!result)
        return -1

    hProcess := NumGet(bufs.pi, 0, "Ptr")
    DllCall("CloseHandle", "Ptr", NumGet(bufs.pi, 8, "Ptr"))  ; hThread

    DllCall("WaitForSingleObject", "Ptr", hProcess, "UInt", 0xFFFFFFFF)

    exitCode := 0
    DllCall("GetExitCodeProcess", "Ptr", hProcess, "UInt*", &exitCode)
    DllCall("CloseHandle", "Ptr", hProcess)

    return exitCode
}

; --- Shared Helper Functions ---

; Wait for a flag variable to become true
; Returns the flag value (true if set, false on timeout)
WaitForFlag(&flag, timeoutMs := 2000, pollMs := 20) {
    start := A_TickCount
    while (!flag && (A_TickCount - start) < timeoutMs)
        Sleep(pollMs)
    return flag
}

; Join array elements with a separator
_JoinArray(arr, sep) {
    result := ""
    for i, item in arr {
        if (i > 1)
            result .= sep
        result .= item
    }
    return result
}

; Repeat a string n times (O(n log n) doubling for large counts)
_RepeatStr(str, count) {
    if (count <= 0)
        return ""
    result := str
    n := 1
    while (n * 2 <= count) {
        result .= result
        n *= 2
    }
    if (n < count)
        result .= SubStr(result, 1, StrLen(str) * (count - n))
    return result
}

; Kill all running AltTabby.exe processes (blanket — use scoped variants for parallel safety)
_Test_KillAllAltTabby() {
    for _, proc in _Test_EnumProcesses("AltTabby.exe") {
        try ProcessClose(proc.pid)
    }
    ; Give processes time to fully exit
    Sleep(200)
}

; Kill AltTabby processes whose exe path starts with dirPath (worktree-safe)
_Test_KillAltTabbyInDir(dirPath) {
    for _, proc in _Test_EnumProcesses("AltTabby.exe") {
        try {
            procPath := ProcessGetPath(proc.pid)
            if (InStr(procPath, dirPath) = 1)
                ProcessClose(proc.pid)
        }
    }
    Sleep(200)
}

; Kill all processes matching a custom exe name (e.g. "AltTabby_exectest.exe")
_Test_KillProcessesByName(exeName) {
    for _, proc in _Test_EnumProcesses(exeName) {
        try ProcessClose(proc.pid)
    }
    Sleep(200)
}

; --- Process Enumeration via CreateToolhelp32Snapshot ---
; Returns array of {pid, parentPid, exeName} for processes matching exeFilter.
; If exeFilter is "", returns all processes. Uses Win32 Toolhelp API (no WMI/COM).
_Test_EnumProcesses(exeFilter := "") {
    results := []
    TH32CS_SNAPPROCESS := 0x2
    hSnap := DllCall("CreateToolhelp32Snapshot", "uint", TH32CS_SNAPPROCESS, "uint", 0, "ptr")
    if (hSnap = -1)
        return results

    peSize := 568  ; sizeof(PROCESSENTRY32W) on x64
    pe := Buffer(peSize, 0)
    NumPut("uint", peSize, pe, 0)

    if (DllCall("Process32FirstW", "ptr", hSnap, "ptr", pe)) {
        loop {
            exeName := StrGet(pe.Ptr + 44, "UTF-16")
            if (exeFilter = "" || exeName = exeFilter) {
                results.Push({
                    pid: NumGet(pe, 8, "uint"),
                    parentPid: NumGet(pe, 32, "uint"),
                    exeName: exeName
                })
            }
            NumPut("uint", peSize, pe, 0)
            if (!DllCall("Process32NextW", "ptr", hSnap, "ptr", pe))
                break
        }
    }
    DllCall("CloseHandle", "ptr", hSnap)
    return results
}

; Count processes matching exeFilter name
_Test_CountProcesses(exeFilter) {
    return _Test_EnumProcesses(exeFilter).Length
}

; Find child processes of parentPid matching exeFilter name
_Test_FindChildProcesses(parentPid, exeFilter := "") {
    results := []
    for _, proc in _Test_EnumProcesses(exeFilter) {
        if (proc.parentPid = parentPid)
            results.Push(proc)
    }
    return results
}
