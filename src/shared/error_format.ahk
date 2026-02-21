#Requires AutoHotkey v2.0

; ============================================================
; Win32 Error Formatting
; ============================================================
; Converts Win32 error codes to human-readable strings.
; Used in diagnostic log messages throughout the codebase.

; Win32ErrorString(errCode) → "Access is denied." or "Error 5" as fallback
Win32ErrorString(err) {
    DllCall("FormatMessage", "uint", 0x1100, "ptr", 0, "uint", err, "uint", 0, "ptr*", &pstr := 0, "uint", 0, "ptr", 0)
    if (pstr) {
        msg := RTrim(StrGet(pstr), " `r`n")
        DllCall("LocalFree", "ptr", pstr)
        return msg
    }
    return "Error " err
}
