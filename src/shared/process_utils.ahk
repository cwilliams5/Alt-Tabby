#Requires AutoHotkey v2.0

; ============================================================
; Process Utilities - Shared process-related helpers
; ============================================================
; Provides common process operations used by multiple modules:
;   - Process path resolution from PID
; ============================================================

; Windows API constant
global PROCESS_QUERY_LIMITED_INFORMATION := 0x1000

; Get full process path from PID
; Parameters:
;   pid     - Process ID to query
;   logFunc - Optional callback function(msg) for error logging
; Returns: Full path string or empty string on failure
ProcessUtils_GetPath(pid, logFunc := "") {
    global PROCESS_QUERY_LIMITED_INFORMATION

    hProc := DllCall("kernel32\OpenProcess", "uint", PROCESS_QUERY_LIMITED_INFORMATION, "int", 0, "uint", pid, "ptr")
    if (!hProc) {
        if (logFunc != "") {
            gle := DllCall("kernel32\GetLastError", "uint")
            logFunc("OpenProcess FAILED pid=" pid " err=" gle)
        }
        return ""
    }

    buf := Buffer(32767 * 2, 0)
    cch := 32767
    ok := DllCall("kernel32\QueryFullProcessImageNameW", "ptr", hProc, "uint", 0, "ptr", buf.Ptr, "uint*", &cch, "int")
    DllCall("kernel32\CloseHandle", "ptr", hProc)

    if (!ok) {
        if (logFunc != "") {
            gle := DllCall("kernel32\GetLastError", "uint")
            logFunc("QueryFullProcessImageNameW FAILED pid=" pid " err=" gle)
        }
        return ""
    }

    return StrGet(buf.Ptr, "UTF-16")
}

; Extract filename from path
; Parameters:
;   path - Full file path
; Returns: Filename portion or empty string
ProcessUtils_Basename(path) {
    if (path = "")
        return ""
    SplitPath(path, &fn)
    return fn
}

; ============================================================
; Cursor Feedback Suppression Helpers
; ============================================================
; During test runs, Windows shows "app starting" cursor (hourglass+pointer)
; whenever a GUI process is launched via Run(). These helpers use CreateProcessW
; with STARTF_FORCEOFFFEEDBACK (0x80) to suppress that in test mode.
; In normal mode, they fall back to standard Run()/RunWait().

; Check if any test mode flag is active (store --test or alt_tabby --testing-mode)
_PU_IsTestMode() {
    global gStore_TestMode, g_TestingMode
    return (IsSet(gStore_TestMode) && gStore_TestMode) || (IsSet(g_TestingMode) && g_TestingMode)
}

; Run a command hidden (no window). Suppresses cursor feedback in test mode.
; Returns PID (0 on failure).
ProcessUtils_RunHidden(cmdLine) {
    if (_PU_IsTestMode()) {
        pid := 0
        _PU_CreateProcess(cmdLine, 0x81, 0x08000000, &pid)
        return pid
    }
    try return Run(cmdLine, , "Hide")
    return 0
}

; RunWait a command hidden. Suppresses cursor feedback in test mode.
; Returns exit code (-1 on failure).
ProcessUtils_RunWaitHidden(cmdLine, workDir := "") {
    if (_PU_IsTestMode())
        return _PU_CreateProcessWait(cmdLine, 0x81, 0x08000000, workDir)
    try return RunWait(cmdLine, workDir != "" ? workDir : unset, "Hide")
    return -1
}

; Run a command (visible). Suppresses cursor feedback in test mode.
; Sets &outPid to new process ID. Returns PID (0 on failure).
ProcessUtils_Run(cmdLine, &outPid := 0) {
    outPid := 0
    if (_PU_IsTestMode()) {
        _PU_CreateProcess(cmdLine, 0x80, 0, &outPid)
        return outPid
    }
    try Run(cmdLine, , , &outPid)
    return outPid
}

; Internal: CreateProcessW with custom STARTUPINFO flags
_PU_CreateProcess(cmdLine, siFlags, creationFlags, &outPid := 0) {
    outPid := 0
    cmdBuf := Buffer((StrLen(cmdLine) + 1) * 2)
    StrPut(cmdLine, cmdBuf, "UTF-16")
    si := Buffer(104, 0)
    NumPut("UInt", 104, si, 0)      ; cb
    NumPut("UInt", siFlags, si, 60) ; dwFlags
    pi := Buffer(24, 0)
    result := DllCall("CreateProcessW",
        "Ptr", 0, "Ptr", cmdBuf,
        "Ptr", 0, "Ptr", 0,
        "Int", 0, "UInt", creationFlags,
        "Ptr", 0, "Ptr", 0,
        "Ptr", si, "Ptr", pi, "Int")
    if (result) {
        outPid := NumGet(pi, 16, "UInt")
        DllCall("CloseHandle", "Ptr", NumGet(pi, 0, "Ptr"))
        DllCall("CloseHandle", "Ptr", NumGet(pi, 8, "Ptr"))
    }
    return result
}

; Internal: CreateProcessW + wait for exit
_PU_CreateProcessWait(cmdLine, siFlags, creationFlags, workDir := "") {
    cmdBuf := Buffer((StrLen(cmdLine) + 1) * 2)
    StrPut(cmdLine, cmdBuf, "UTF-16")
    si := Buffer(104, 0)
    NumPut("UInt", 104, si, 0)
    NumPut("UInt", siFlags, si, 60)
    pi := Buffer(24, 0)
    wdBuf := 0
    wdPtr := 0
    if (workDir != "") {
        wdBuf := Buffer((StrLen(workDir) + 1) * 2)
        StrPut(workDir, wdBuf, "UTF-16")
        wdPtr := wdBuf.Ptr
    }
    result := DllCall("CreateProcessW",
        "Ptr", 0, "Ptr", cmdBuf,
        "Ptr", 0, "Ptr", 0,
        "Int", 0, "UInt", creationFlags,
        "Ptr", 0, "Ptr", wdPtr,
        "Ptr", si, "Ptr", pi, "Int")
    if (!result)
        return -1
    hProcess := NumGet(pi, 0, "Ptr")
    DllCall("CloseHandle", "Ptr", NumGet(pi, 8, "Ptr"))
    DllCall("WaitForSingleObject", "Ptr", hProcess, "UInt", 0xFFFFFFFF)
    exitCode := 0
    DllCall("GetExitCodeProcess", "Ptr", hProcess, "UInt*", &exitCode)
    DllCall("CloseHandle", "Ptr", hProcess)
    return exitCode
}
