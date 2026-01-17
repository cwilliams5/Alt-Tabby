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

; Load dwmapi once at startup
DllCall("LoadLibrary", "str", "dwmapi.dll")

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
_WN_ProbeWindow(hwnd, zOrder := 0) {
    ; Get basic window info
    title := ""
    class := ""
    pid := 0

    try {
        title := WinGetTitle("ahk_id " hwnd)
        class := WinGetClass("ahk_id " hwnd)
        pid := WinGetPID("ahk_id " hwnd)
    } catch {
        return ""
    }

    ; Skip windows with no title (usually not user-facing)
    if (title = "")
        return ""

    ; Visibility state
    isVisible := DllCall("user32\IsWindowVisible", "ptr", hwnd, "int") != 0
    isMin := DllCall("user32\IsIconic", "ptr", hwnd, "int") != 0

    ; DWM cloaking detection (for virtual desktops, komorebi, etc.)
    cloakedBuf := Buffer(4, 0)
    hr := DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", 14, "ptr", cloakedBuf.Ptr, "uint", 4, "int")
    isCloaked := (hr = 0) && (NumGet(cloakedBuf, 0, "UInt") != 0)

    ; Build record as Map (required by WindowStore)
    rec := Map()
    rec["hwnd"] := hwnd
    rec["title"] := title
    rec["class"] := class
    rec["pid"] := pid
    rec["z"] := zOrder
    rec["altTabEligible"] := true  ; Already checked by caller
    rec["isCloaked"] := isCloaked
    rec["isMinimized"] := isMin
    rec["isVisible"] := isVisible

    return rec
}
