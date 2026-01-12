#Requires AutoHotkey v2.0

; ============================================================
; WinEnum Lite - Window enumeration producer for WindowStore
; ============================================================
; Features:
;   - Z-order enumeration via EnumWindows
;   - DWM cloaking detection (for virtual desktops/komorebi)
;   - Alt-Tab eligibility filtering
;   - Minimal overhead, no debug logging
; ============================================================

; Load dwmapi once at startup
DllCall("LoadLibrary", "str", "dwmapi.dll")

; Configuration
global WN_UseAltTabEligibility := true   ; Filter by Alt-Tab rules

; Shell window handle (cached)
global _WN_ShellWindow := 0

; Initialize the module
WinEnumLite_Init() {
    global _WN_ShellWindow
    _WN_ShellWindow := DllCall("user32\GetShellWindow", "ptr")
}

; Full scan - returns array of Maps suitable for WindowStore_UpsertWindow
WinEnumLite_ScanAll() {
    global _WN_ShellWindow, WN_UseAltTabEligibility

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

        rec := _WN_ProbeWindow(hwnd, 0)  ; Z will be set below for eligible windows

        if (!rec)
            continue

        ; Apply Alt-Tab eligibility filter
        if (WN_UseAltTabEligibility && !rec["altTabEligible"])
            continue

        ; Assign z-order only to eligible windows (keeps values low and meaningful)
        rec["z"] := z
        z += 1

        records.Push(rec)
    }

    return records
}

; Probe a single window - returns Map or empty string
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

    ; Determine window state
    state := "WorkspaceHidden"
    if (isCloaked)
        state := "OtherWorkspace"
    else if (isMin)
        state := "WorkspaceMinimized"
    else if (isVisible)
        state := "WorkspaceShowing"

    ; Check Alt-Tab eligibility
    eligible := _WN_IsAltTabEligible(hwnd, isVisible, isMin, isCloaked)

    ; Build record as Map (required by WindowStore)
    rec := Map()
    rec["hwnd"] := hwnd
    rec["title"] := title
    rec["class"] := class
    rec["pid"] := pid
    rec["state"] := state
    rec["z"] := zOrder
    rec["altTabEligible"] := eligible
    rec["isBlacklisted"] := false
    rec["isCloaked"] := isCloaked
    rec["isMinimized"] := isMin
    rec["isVisible"] := isVisible

    return rec
}

; Alt-Tab eligibility rules (matches Windows behavior)
_WN_IsAltTabEligible(hwnd, isVisible, isMin, isCloaked) {
    ; Get extended window style
    ex := DllCall("user32\GetWindowLongPtrW", "ptr", hwnd, "int", -20, "ptr")

    WS_EX_TOOLWINDOW := 0x00000080
    WS_EX_APPWINDOW := 0x00040000

    isTool := (ex & WS_EX_TOOLWINDOW) != 0
    isApp := (ex & WS_EX_APPWINDOW) != 0

    ; Get owner window
    owner := DllCall("user32\GetWindow", "ptr", hwnd, "uint", 4, "ptr")  ; GW_OWNER

    ; Tool windows are never Alt-Tab eligible
    if (isTool)
        return false

    ; Owned windows need WS_EX_APPWINDOW to be eligible
    if (owner != 0 && !isApp)
        return false

    ; Must be visible, minimized, or cloaked
    if !(isVisible || isMin || isCloaked)
        return false

    return true
}
