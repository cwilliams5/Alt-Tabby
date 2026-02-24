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

; Win32 window constants
global GWL_STYLE := -16
global GW_OWNER := 4

; DWM cloaking attribute constant
global DWMWA_CLOAKED := 14

; Monitor handle → label cache (invalidated on WM_DISPLAYCHANGE)
global gWin_MonitorLabelCache := Map()

; Probe a single window - returns Map or empty string
; Parameters:
;   hwnd           - Window handle to probe
;   zOrder         - Z-order value to include in record (default 0)
;   checkExists    - Check if window still exists first (default false)
;   checkEligible  - Check Alt-Tab eligibility via Blacklist_IsWindowEligible (default false)
; Returns: Map with window properties or empty string on failure/ineligible
WinUtils_ProbeWindow(hwnd, zOrder := 0, checkExists := false, checkEligible := false) {
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
        ; Fetch vis/min/cloak via shared probe (DRY with blacklist.ahk)
        BL_ProbeVisMinCloak(hwnd, &isVisible, &isMin, &isCloaked)
    }

    ; Build record as Map (required by WindowList)
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

    ; Stamp monitor identity for store-level tracking
    hMon := Win_GetMonitorHandle(hwnd)
    rec["monitorHandle"] := hMon
    rec["monitorLabel"] := Win_GetMonitorLabel(hMon)

    return rec
}

; Get monitor handle for a window (for monitor identity comparison)
; MONITOR_DEFAULTTONEAREST = 2
Win_GetMonitorHandle(hWnd) {
    return DllCall("user32\MonitorFromWindow", "ptr", hWnd, "uint", 2, "ptr")
}

; Register WM_DISPLAYCHANGE handler to invalidate monitor label cache
; when monitor topology changes (connect/disconnect/resolution change).
; Call from _GUI_Main_Init alongside other init functions.
Win_InitMonitorCache() {
    OnMessage(0x007E, _Win_OnDisplayChange)  ; WM_DISPLAYCHANGE
}

; Get monitor index (1-based) from monitor handle for display purposes
; Returns "Mon N" where N is the monitor number, or "" on failure
; Uses lazy-fill cache: first call enumerates all monitors, subsequent calls
; are O(1) Map lookups. Cache invalidated on WM_DISPLAYCHANGE.
Win_GetMonitorLabel(hMon) {
    global gWin_MonitorLabelCache
    if (!hMon)
        return ""
    if (gWin_MonitorLabelCache.Has(hMon))
        return gWin_MonitorLabelCache[hMon]
    _Win_RebuildMonitorCache()
    return gWin_MonitorLabelCache.Get(hMon, "")
}

; Rebuild the full monitor handle → label cache.
; Enumerates all monitors once, populating every entry.
; Uses static Buffer to avoid per-call allocation.
_Win_RebuildMonitorCache() {
    global gWin_MonitorLabelCache
    static rc := Buffer(16, 0)
    gWin_MonitorLabelCache := Map()
    count := MonitorGetCount()
    loop count {
        mL := 0, mT := 0, mR := 0, mB := 0
        MonitorGet(A_Index, &mL, &mT, &mR, &mB)
        NumPut("Int", mL, rc, 0)
        NumPut("Int", mT, rc, 4)
        NumPut("Int", mR, rc, 8)
        NumPut("Int", mB, rc, 12)
        hMon := DllCall("user32\MonitorFromRect", "ptr", rc.Ptr, "uint", 2, "ptr")
        if (hMon)
            gWin_MonitorLabelCache[hMon] := "Mon " A_Index
    }
}

; WM_DISPLAYCHANGE handler — clear cache so next lookup triggers rebuild
_Win_OnDisplayChange(wParam, lParam, msg, hwnd) { ; lint-ignore: dead-param
    global gWin_MonitorLabelCache
    gWin_MonitorLabelCache := Map()
}

