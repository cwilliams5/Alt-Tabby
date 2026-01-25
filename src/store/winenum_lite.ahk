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
WinEnumLite_Init() {
    global _WN_ShellWindow
    _WN_ShellWindow := DllCall("user32\GetShellWindow", "ptr")
}

; Full scan - returns array of Maps suitable for WindowStore_UpsertWindow
WinEnumLite_ScanAll() {
    global _WN_ShellWindow

    if (!_WN_ShellWindow)
        WinEnumLite_Init()

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

        ; Use centralized eligibility check (Alt-Tab rules + blacklist)
        if (!Blacklist_IsWindowEligible(hwnd))
            continue

        rec := _WN_ProbeWindow(hwnd, z)
        if (!rec)
            continue

        z += 1
        records.Push(rec)
    }

    return records
}

; Probe a single window - returns Map or empty string
; NOTE: Eligibility check should be done before calling this (via Blacklist_IsWindowEligible)
; Uses shared WinUtils_ProbeWindow
_WN_ProbeWindow(hwnd, zOrder := 0) {
    return WinUtils_ProbeWindow(hwnd, zOrder, false, false)  ; No exists/eligibility check (caller handles)
}
