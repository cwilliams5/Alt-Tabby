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
