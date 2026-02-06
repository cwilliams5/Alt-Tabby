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

    ; Skip hung windows - IsHungAppWindow is a fast kernel call that doesn't
    ; send window messages. WinGetTitle/WinGetClass send messages that block
    ; up to 5 seconds on hung windows, freezing the entire store thread.
    try {
        if (DllCall("user32\IsHungAppWindow", "ptr", hwnd, "int"))
            return ""
    }

    ; Get basic window info FIRST (needed for eligibility check)
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

    isVisible := false
    isMin := false
    isCloaked := false

    if (checkEligible) {
        ; Use Ex variant - gets vis/min/cloak as byproduct of eligibility check
        ; Avoids redundant DllCalls (IsWindowVisible, IsIconic, DwmGetWindowAttribute)
        if (!Blacklist_IsWindowEligibleEx(hwnd, title, class, &isVisible, &isMin, &isCloaked))
            return ""
    } else {
        ; Fetch vis/min/cloak directly
        isVisible := DllCall("user32\IsWindowVisible", "ptr", hwnd, "int") != 0
        isMin := DllCall("user32\IsIconic", "ptr", hwnd, "int") != 0
        global DWMWA_CLOAKED
        hr := DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", DWMWA_CLOAKED, "ptr", cloakedBuf.Ptr, "uint", 4, "int")
        isCloaked := (hr = 0) && (NumGet(cloakedBuf, 0, "UInt") != 0)
    }

    ; Build record as Map (required by WindowStore)
    rec := Map()
    rec["hwnd"] := hwnd
    rec["title"] := title
    rec["class"] := class
    rec["pid"] := pid
    ; Only include z when caller provided actual z-order data (> 0).
    ; WEH probes pass zOrder=0 which would overwrite valid z from winenum,
    ; causing unnecessary cache invalidation and z-order churn.
    if (zOrder > 0)
        rec["z"] := zOrder
    rec["isCloaked"] := isCloaked
    rec["isMinimized"] := isMin
    rec["isVisible"] := isVisible

    return rec
}

