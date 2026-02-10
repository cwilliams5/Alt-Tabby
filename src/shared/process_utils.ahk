#Requires AutoHotkey v2.0

; ============================================================
; Process Utilities - Shared process-related helpers
; ============================================================
; Provides common process operations used by multiple modules:
;   - Process path resolution from PID
; ============================================================

; Windows API constants
global PROCESS_QUERY_LIMITED_INFORMATION := 0x1000  ; Keep here — moving to setup_utils causes unset-var crash in compiled store (icon_pump.ahk)
global STARTF_USESHOWWINDOW := 0x01
global STARTF_FORCEOFFFEEDBACK := 0x80
global CREATE_NO_WINDOW := 0x08000000

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

    static buf := Buffer(32767 * 2, 0)
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
; Exe Name List Builder
; ============================================================
; Builds a deduped array of exe names from:
;   1. Current exe (A_ScriptFullPath)
;   2. Optional target exe name (e.g., from update target path)
;   3. cfg.SetupExePath (installed location, may differ if user renamed)
; Used by ProcessUtils_KillAltTabby for force-kill phase.

ProcessUtils_BuildExeNameList(targetExeName := "") {
    global cfg

    exeNames := []
    seenNames := Map()

    ; 1. Current exe name
    currentName := ""
    SplitPath(A_ScriptFullPath, &currentName)
    if (currentName != "") {
        exeNames.Push(currentName)
        seenNames[StrLower(currentName)] := true
    }

    ; 2. Target exe name (for updates, passed by caller)
    if (targetExeName != "") {
        lowerTarget := StrLower(targetExeName)
        if (!seenNames.Has(lowerTarget)) {
            exeNames.Push(targetExeName)
            seenNames[lowerTarget] := true
        }
    }

    ; 3. Configured install path exe name (may be different if user renamed)
    if (IsSet(cfg) && cfg.HasOwnProp("SetupExePath") && cfg.SetupExePath != "") {  ; lint-ignore: isset-with-default
        configName := ""
        SplitPath(cfg.SetupExePath, &configName)
        if (configName != "") {
            lowerConfig := StrLower(configName)
            if (!seenNames.Has(lowerConfig)) {
                exeNames.Push(configName)
                seenNames[lowerConfig] := true
            }
        }
    }

    return exeNames
}

; ============================================================
; Process Kill Helpers
; ============================================================
; Consolidated functions for killing Alt-Tabby processes.
; Used by launcher (restart), update system, and mismatch handling.

; Kill all processes matching exeName except ourselves
; Uses taskkill as primary mechanism (immune to ProcessExist PID ordering),
; with ProcessClose loop as fallback for stragglers.
; Parameters:
;   exeName        - Process image name to kill (e.g., "AltTabby.exe")
;   maxAttempts    - Max retry attempts for ProcessClose fallback (default 10)
;   sleepMs        - Sleep between fallback attempts (default: TIMING_PROCESS_TERMINATE_WAIT)
;   offerElevation - If true and target is elevated, offer to elevate for kill (default false)
ProcessUtils_KillByNameExceptSelf(exeName, maxAttempts := 10, sleepMs := 0, offerElevation := false) {
    global APP_NAME
    ; Note: TIMING_* globals are defined in config_loader.ahk
    if (sleepMs = 0) {
        global TIMING_PROCESS_TERMINATE_WAIT
        sleepMs := TIMING_PROCESS_TERMINATE_WAIT
    }
    global TIMING_SETUP_SETTLE
    myPID := ProcessExist()

    ; Primary: taskkill (reliable for same-name processes)
    try RunWait('taskkill /F /IM "' exeName '" /FI "PID ne ' myPID '"',, "Hide")
    Sleep(TIMING_SETUP_SETTLE)

    ; Fallback: ProcessClose loop for any stragglers
    loop maxAttempts {
        pid := ProcessExist(exeName)
        if (!pid || pid = myPID)
            break
        try ProcessClose(pid)
        Sleep(sleepMs)
    }

    ; Check if any process still running (may be elevated)
    if (offerElevation)
        _PU_OfferElevatedKill(exeName)
}

; Check if a process is running elevated (has admin privileges)
; Parameters:
;   pid - Process ID to check
; Returns: true if elevated, false otherwise
ProcessUtils_IsElevated(pid) {
    global PROCESS_QUERY_LIMITED_INFORMATION

    hProcess := DllCall("kernel32\OpenProcess", "uint", PROCESS_QUERY_LIMITED_INFORMATION, "int", 0, "uint", pid, "ptr")
    if (!hProcess)
        return false  ; Can't open process - assume not elevated or doesn't exist

    hToken := 0
    if (!DllCall("advapi32\OpenProcessToken", "ptr", hProcess, "uint", 0x0008, "ptr*", &hToken)) {  ; TOKEN_QUERY = 0x0008
        DllCall("kernel32\CloseHandle", "ptr", hProcess)
        return false
    }

    ; Query TokenElevation
    elevation := 0
    returnLength := 0
    DllCall("advapi32\GetTokenInformation",
        "ptr", hToken,
        "int", 20,  ; TokenElevation
        "ptr*", &elevation,
        "uint", 4,
        "uint*", &returnLength)

    DllCall("kernel32\CloseHandle", "ptr", hToken)
    DllCall("kernel32\CloseHandle", "ptr", hProcess)

    return (elevation != 0)
}

; Kill all Alt-Tabby processes except ourselves
; Iterates over exe names from ProcessUtils_BuildExeNameList().
; Parameters:
;   targetExeName - Optional extra exe name to include (for updates targeting different name)
ProcessUtils_KillAllAltTabbyExceptSelf(targetExeName := "") {
    for exeName in ProcessUtils_BuildExeNameList(targetExeName) {
        ProcessUtils_KillByNameExceptSelf(exeName)
    }
}

; ============================================================
; Unified Process Termination
; ============================================================
; Single entry point for all Alt-Tabby process killing.
;
; Behavior:
;   1. Hard-kill editors (if provided)
;   2. Graceful shutdown known PIDs in order: GUI→Store (if pids provided)
;   3. Force sweep by process name (if force=true)
;
; Graceful always happens when PIDs are available — no caller with PIDs
; should ever skip it. Force is the orthogonal axis: update/conflict flows
; need it to release file locks and catch unknown processes. Normal exit
; flows skip it to avoid killing other installations.
;
; Options object:
;   pids            - Optional {gui: pid, store: pid, viewer: pid} for graceful shutdown
;   force           - Kill all AltTabby processes by name after graceful (default false)
;   targetExeName   - Optional extra exe name for force-kill name matching
;   offerElevation  - If true, offer UAC elevation for elevated stragglers (default false)
;   editors         - Optional {config: pid, blacklist: pid} to hard-kill editor processes

ProcessUtils_KillAltTabby(opts := "") {
    if (opts = "")
        opts := {}
    force := opts.HasOwnProp("force") ? opts.force : false
    targetExeName := opts.HasOwnProp("targetExeName") ? opts.targetExeName : ""
    offerElevation := opts.HasOwnProp("offerElevation") ? opts.offerElevation : false

    ; Hard-kill editors (not part of graceful ordering — editors survive restarts)
    if (opts.HasOwnProp("editors")) {
        ed := opts.editors
        if (ed.HasOwnProp("config") && ed.config && ProcessExist(ed.config))
            try ProcessClose(ed.config)
        if (ed.HasOwnProp("blacklist") && ed.blacklist && ProcessExist(ed.blacklist))
            try ProcessClose(ed.blacklist)
    }

    ; Graceful phase: ordered WM_CLOSE to known PIDs
    if (opts.HasOwnProp("pids"))
        _PU_GracefulShutdownByPid(opts.pids)

    ; Force phase: kill all AltTabby processes by name
    if (force) {
        ProcessUtils_KillAllAltTabbyExceptSelf(targetExeName)
        if (offerElevation) {
            for exeName in ProcessUtils_BuildExeNameList(targetExeName) {
                _PU_OfferElevatedKill(exeName)
            }
        }
    }
}

; Internal: Graceful shutdown of known PIDs in correct order
; Order: viewer (hard kill) → GUI (graceful, 3s) → Store (graceful, 5s)
; GUI must exit before Store so it can send final stats to still-alive store.
_PU_GracefulShutdownByPid(pids) {
    ; 1. Hard kill viewer (non-core, no ordering dependency)
    if (pids.HasOwnProp("viewer") && pids.viewer && ProcessExist(pids.viewer))
        ProcessClose(pids.viewer)

    prevDHW := A_DetectHiddenWindows
    DetectHiddenWindows(true)

    ; 2. Graceful GUI first (sends final stats to still-alive store)
    if (pids.HasOwnProp("gui") && pids.gui && ProcessExist(pids.gui)) {
        try PostMessage(0x0010, , , , "ahk_pid " pids.gui " ahk_class AutoHotkey")  ; WM_CLOSE
        deadline := A_TickCount + 3000
        while (ProcessExist(pids.gui) && A_TickCount < deadline)
            Sleep(10)
        if (ProcessExist(pids.gui))
            ProcessClose(pids.gui)
    }

    ; 3. Graceful Store second (flushes stats to disk)
    if (pids.HasOwnProp("store") && pids.store && ProcessExist(pids.store)) {
        try PostMessage(0x0010, , , , "ahk_pid " pids.store " ahk_class AutoHotkey")  ; WM_CLOSE
        deadline := A_TickCount + 5000
        while (ProcessExist(pids.store) && A_TickCount < deadline)
            Sleep(10)
        if (ProcessExist(pids.store))
            ProcessClose(pids.store)
    }

    DetectHiddenWindows(prevDHW)
}

; Internal: Offer UAC elevation to kill elevated straggler
_PU_OfferElevatedKill(exeName) {
    global APP_NAME, TIMING_SETUP_SETTLE
    if (A_IsAdmin)
        return
    myPID := ProcessExist()
    pid := ProcessExist(exeName)
    if (pid && pid != myPID && ProcessUtils_IsElevated(pid)) {
        result := ThemeMsgBox(
            "The running instance has administrator privileges.`n`n"
            "Elevate to close it?",
            APP_NAME,
            "YesNo Icon?"
        )
        if (result = "Yes") {
            try {
                Run('*RunAs taskkill /F /PID ' pid,, "Hide")
                Sleep(TIMING_SETUP_SETTLE)
            }
        }
    }
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
    return (IsSet(gStore_TestMode) && gStore_TestMode) || (IsSet(g_TestingMode) && g_TestingMode)  ; lint-ignore: isset-with-default
}

; Run a command hidden (no window). Suppresses cursor feedback in test mode.
; Returns PID (0 on failure).
ProcessUtils_RunHidden(cmdLine) {
    global STARTF_USESHOWWINDOW, STARTF_FORCEOFFFEEDBACK, CREATE_NO_WINDOW
    if (_PU_IsTestMode()) {
        pid := 0
        _PU_CreateProcess(cmdLine, STARTF_USESHOWWINDOW | STARTF_FORCEOFFFEEDBACK, CREATE_NO_WINDOW, &pid)
        return pid
    }
    try return Run(cmdLine, , "Hide")
    return 0
}

; RunWait a command hidden. Suppresses cursor feedback in test mode.
; Returns exit code (-1 on failure).
ProcessUtils_RunWaitHidden(cmdLine, workDir := "") {
    global STARTF_USESHOWWINDOW, STARTF_FORCEOFFFEEDBACK, CREATE_NO_WINDOW
    if (_PU_IsTestMode())
        return _PU_CreateProcessWait(cmdLine, STARTF_USESHOWWINDOW | STARTF_FORCEOFFFEEDBACK, CREATE_NO_WINDOW, workDir)
    try return RunWait(cmdLine, workDir != "" ? workDir : unset, "Hide")
    return -1
}

; Run a command (visible). Suppresses cursor feedback in test mode.
; Sets &outPid to new process ID. Returns PID (0 on failure).
ProcessUtils_Run(cmdLine, &outPid := 0) {
    global STARTF_FORCEOFFFEEDBACK
    outPid := 0
    if (_PU_IsTestMode()) {
        _PU_CreateProcess(cmdLine, STARTF_FORCEOFFFEEDBACK, 0, &outPid)
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
