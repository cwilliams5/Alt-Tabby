#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Expected: file is included after blacklist.ahk

; ============================================================
; WinEnum Lite - Window enumeration producer for WindowStore
; ============================================================
; Features:
;   - Z-order enumeration via EnumWindows
;   - DWM cloaking detection (for virtual desktops/komorebi)
;   - Alt-Tab eligibility filtering
;   - Blacklist filtering (title, class, pairs)
;   - Minimal overhead, no debug logging
; ============================================================

; Shell window handle (cached)
global _WN_ShellWindow := 0

; Initialize the module
_WinEnumLite_Init() {
    global _WN_ShellWindow
    _WN_ShellWindow := DllCall("user32\GetShellWindow", "ptr")
}

; Full scan - returns array of Maps suitable for WindowStore_UpsertWindow
WinEnumLite_ScanAll() {
    global _WN_ShellWindow

    if (!_WN_ShellWindow)
        _WinEnumLite_Init()

    records := []
    z := 0  ; Z-order counter for eligible windows only

    ; Enable detection of hidden windows (includes komorebi-cloaked windows)
    prevDetect := A_DetectHiddenWindows
    DetectHiddenWindows(true)
    list := WinGetList()
    DetectHiddenWindows(prevDetect)

    for _, hwnd in list {
        ; Skip shell window
        if (hwnd = _WN_ShellWindow)
            continue

        ; Single call: checkEligible=true does Alt-Tab + blacklist checks AND probes
        ; window properties in one pass, avoiding redundant WinGetTitle/WinGetClass/DllCalls
        rec := WinUtils_ProbeWindow(hwnd, z, false, true)
        if (!rec)
            continue

        z += 1
        records.Push(rec)
    }

    return records
}

