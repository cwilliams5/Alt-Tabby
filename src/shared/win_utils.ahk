#Requires AutoHotkey v2.0

; ============================================================
; Window Utilities - Shared window probing helpers
; ============================================================
; Provides common window operations used by multiple modules:
;   - Window probing (title, class, pid, visibility, cloaking)
;   - DWM cloaking detection
; ============================================================

; Load dwmapi once at startup (safe to call multiple times)
DllCall("LoadLibrary", "str", "dwmapi.dll")

; DWM cloaking attribute constant
global DWMWA_CLOAKED := 14

; Probe a single window - returns Map or empty string
; Parameters:
;   hwnd           - Window handle to probe
;   zOrder         - Z-order value to include in record (default 0)
;   checkExists    - Check if window still exists first (default false)
;   checkEligible  - Check Alt-Tab eligibility via Blacklist_IsWindowEligible (default false)
; Returns: Map with window properties or empty string on failure/ineligible
WinUtils_ProbeWindow(hwnd, zOrder := 0, checkExists := false, checkEligible := false) {
    ; Static buffer for DWM cloaking - avoid allocation per call
    static cloakedBuf := Buffer(4, 0)

    ; Optional: Check window still exists
    if (checkExists) {
        try {
            if (!DllCall("user32\IsWindow", "ptr", hwnd, "int"))
                return ""
        } catch {
            return ""
        }
    }

    ; Optional: Use centralized eligibility check (Alt-Tab rules + blacklist)
    if (checkEligible) {
        if (!Blacklist_IsWindowEligible(hwnd))
            return ""
    }

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
    global DWMWA_CLOAKED
    hr := DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", DWMWA_CLOAKED, "ptr", cloakedBuf.Ptr, "uint", 4, "int")
    isCloaked := (hr = 0) && (NumGet(cloakedBuf, 0, "UInt") != 0)

    ; Build record as Map (required by WindowStore)
    rec := Map()
    rec["hwnd"] := hwnd
    rec["title"] := title
    rec["class"] := class
    rec["pid"] := pid
    rec["z"] := zOrder
    rec["altTabEligible"] := true  ; Caller ensures eligibility if needed
    rec["isCloaked"] := isCloaked
    rec["isMinimized"] := isMin
    rec["isVisible"] := isVisible

    return rec
}

; Check if a window is DWM-cloaked (hidden by virtual desktop, komorebi, etc.)
; Parameters:
;   hwnd - Window handle to check
; Returns: true if cloaked, false otherwise
WinUtils_IsCloaked(hwnd) {
    static cloakedBuf := Buffer(4, 0)
    global DWMWA_CLOAKED

    hr := DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", DWMWA_CLOAKED, "ptr", cloakedBuf.Ptr, "uint", 4, "int")
    return (hr = 0) && (NumGet(cloakedBuf, 0, "UInt") != 0)
}
