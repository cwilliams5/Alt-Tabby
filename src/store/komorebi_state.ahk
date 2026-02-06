#Requires AutoHotkey v2.0

; ============================================================
; Komorebi State Navigation Helpers
; ============================================================
; Functions for navigating parsed komorebi state (Map/Array objects).
; All functions accept pre-parsed objects from cJson, NOT raw strings.
;
; Ring pattern: { "elements": [...], "focused": N }
; Used by monitors, workspaces, containers, and windows.
;
; Functions:
;   _KSafe_Elements                 - Get ring elements safely
;   _KSafe_Focused                  - Get ring focused index safely
;   _KSafe_Str                      - Get string property safely
;   _KSafe_Int                      - Get int property safely
;   _KSub_GetMonitorsRing           - Get monitors ring object
;   _KSub_GetMonitorsArray          - Get array of monitor objects
;   _KSub_GetFocusedMonitorIndex    - Get focused monitor index
;   _KSub_GetWorkspacesRing         - Get workspaces ring from monitor
;   _KSub_GetWorkspacesArray        - Get array of workspace objects
;   _KSub_GetFocusedWorkspaceIndex  - Get focused workspace index
;   _KSub_GetWorkspaceNameByIndex   - Get workspace name by index
;   _KSub_FindWorkspaceByHwnd       - Find workspace containing hwnd
;   _KSub_GetFocusedHwnd            - Get currently focused hwnd
; ============================================================

; ========================= SAFE NAVIGATION HELPERS =========================

; Get ring elements safely (returns empty array on failure)
_KSafe_Elements(ring) {
    if (ring is Map && ring.Has("elements")) {
        el := ring["elements"]
        if (el is Array)
            return el
    }
    return []
}

; Get ring focused index safely (returns -1 on failure)
_KSafe_Focused(ring) {
    if (ring is Map && ring.Has("focused"))
        return ring["focused"]
    return -1
}

; Get string property safely (returns "" on failure)
_KSafe_Str(obj, key) {
    if (obj is Map && obj.Has(key)) {
        val := obj[key]
        if (val is String)
            return val
        return String(val)
    }
    return ""
}

; Get int property safely (returns 0 on failure)
_KSafe_Int(obj, key) {
    if (obj is Map && obj.Has(key)) {
        val := obj[key]
        if (val is Integer)
            return val
        try return Integer(val)
    }
    return 0
}

; ========================= RING ACCESSORS =========================

_KSub_GetMonitorsRing(stateObj) {
    if (stateObj is Map && stateObj.Has("monitors"))
        return stateObj["monitors"]
    return ""
}

_KSub_GetMonitorsArray(stateObj) {
    ring := _KSub_GetMonitorsRing(stateObj)
    return _KSafe_Elements(ring)
}

_KSub_GetFocusedMonitorIndex(stateObj) {
    ring := _KSub_GetMonitorsRing(stateObj)
    return _KSafe_Focused(ring)
}

_KSub_GetWorkspacesRing(monObj) {
    if (monObj is Map && monObj.Has("workspaces"))
        return monObj["workspaces"]
    return ""
}

_KSub_GetWorkspacesArray(monObj) {
    ring := _KSub_GetWorkspacesRing(monObj)
    return _KSafe_Elements(ring)
}

_KSub_GetFocusedWorkspaceIndex(monObj) {
    ring := _KSub_GetWorkspacesRing(monObj)
    if (ring = "") {
        _KSub_DiagLog("  GetFocusedWorkspaceIndex: no ring found")
        return -1
    }
    focusedIdx := _KSafe_Focused(ring)
    _KSub_DiagLog("  GetFocusedWorkspaceIndex: focused=" focusedIdx)
    return focusedIdx
}

_KSub_GetWorkspaceNameByIndex(monObj, wsIdx) {
    wsArr := _KSub_GetWorkspacesArray(monObj)
    if (wsIdx < 0 || wsIdx >= wsArr.Length)
        return ""
    wsObj := wsArr[wsIdx + 1]  ; AHK 1-based
    return _KSafe_Str(wsObj, "name")
}

; ========================= HWND LOOKUP =========================

; Find workspace name for a given hwnd by scanning all workspaces
_KSub_FindWorkspaceByHwnd(stateObj, hwnd) {
    if (!hwnd)
        return ""
    monitorsArr := _KSub_GetMonitorsArray(stateObj)
    for mi, monObj in monitorsArr {
        wsArr := _KSub_GetWorkspacesArray(monObj)
        for wi, wsObj in wsArr {
            wsName := _KSafe_Str(wsObj, "name")
            if (wsName = "")
                continue
            ; Scan all containers -> windows for this hwnd
            if (_KSub_WorkspaceHasHwnd(wsObj, hwnd))
                return wsName
        }
    }
    return ""
}

; Check if a workspace contains a window with the given hwnd
_KSub_WorkspaceHasHwnd(wsObj, hwnd) {
    if !(wsObj is Map)
        return false

    ; Check containers ring
    if (wsObj.Has("containers")) {
        containers := wsObj["containers"]
        for _, cont in _KSafe_Elements(containers) {
            if !(cont is Map)
                continue
            if (cont.Has("windows")) {
                for _, win in _KSafe_Elements(cont["windows"]) {
                    if (win is Map && win.Has("hwnd") && win["hwnd"] = hwnd)
                        return true
                }
            }
            ; Single window container
            if (cont.Has("window")) {
                winObj := cont["window"]
                if (winObj is Map && winObj.Has("hwnd") && winObj["hwnd"] = hwnd)
                    return true
            }
        }
    }

    ; Check monocle_container
    if (wsObj.Has("monocle_container")) {
        mono := wsObj["monocle_container"]
        if (mono is Map) {
            if (mono.Has("hwnd") && mono["hwnd"] = hwnd)
                return true
            if (mono.Has("window")) {
                winObj := mono["window"]
                if (winObj is Map && winObj.Has("hwnd") && winObj["hwnd"] = hwnd)
                    return true
            }
            ; Monocle may have windows ring
            if (mono.Has("windows")) {
                for _, win in _KSafe_Elements(mono["windows"]) {
                    if (win is Map && win.Has("hwnd") && win["hwnd"] = hwnd)
                        return true
                }
            }
        }
    }

    return false
}

; Get the focused window hwnd from komorebi state
; Must navigate: focused monitor -> focused workspace -> focused container -> focused window
_KSub_GetFocusedHwnd(stateObj) {
    ; 1. Get focused monitor
    focusedMonIdx := _KSub_GetFocusedMonitorIndex(stateObj)
    monitorsArr := _KSub_GetMonitorsArray(stateObj)

    if (focusedMonIdx >= 0 && focusedMonIdx < monitorsArr.Length) {
        monObj := monitorsArr[focusedMonIdx + 1]  ; AHK 1-based

        ; 2. Get focused workspace on this monitor
        focusedWsIdx := _KSub_GetFocusedWorkspaceIndex(monObj)
        wsArr := _KSub_GetWorkspacesArray(monObj)

        if (focusedWsIdx >= 0 && focusedWsIdx < wsArr.Length) {
            wsObj := wsArr[focusedWsIdx + 1]

            ; 3. Get focused container in this workspace
            if (wsObj is Map && wsObj.Has("containers")) {
                containersRing := wsObj["containers"]
                contArr := _KSafe_Elements(containersRing)
                focusedContIdx := _KSafe_Focused(containersRing)

                if (focusedContIdx >= 0 && focusedContIdx < contArr.Length) {
                    contObj := contArr[focusedContIdx + 1]

                    ; 4. Get focused window in this container
                    if (contObj is Map && contObj.Has("windows")) {
                        windowsRing := contObj["windows"]
                        winArr := _KSafe_Elements(windowsRing)
                        focusedWinIdx := _KSafe_Focused(windowsRing)

                        if (focusedWinIdx >= 0 && focusedWinIdx < winArr.Length) {
                            winObj := winArr[focusedWinIdx + 1]
                            hwnd := _KSafe_Int(winObj, "hwnd")
                            if (hwnd) {
                                _KSub_DiagLog("    GetFocusedHwnd: found via hierarchy hwnd=" hwnd)
                                return hwnd
                            }
                        }
                    }

                    ; Fallback: container might have "window" directly
                    if (contObj is Map && contObj.Has("window")) {
                        winObj := contObj["window"]
                        hwnd := _KSafe_Int(winObj, "hwnd")
                        if (hwnd) {
                            _KSub_DiagLog("    GetFocusedHwnd: found via container.window hwnd=" hwnd)
                            return hwnd
                        }
                    }
                }
            }

            ; Fallback: try workspace's monocle_container
            if (wsObj is Map && wsObj.Has("monocle_container")) {
                monocleObj := wsObj["monocle_container"]
                if (monocleObj is Map) {
                    hwnd := _KSafe_Int(monocleObj, "hwnd")
                    if (!hwnd && monocleObj.Has("window")) {
                        winObj := monocleObj["window"]
                        hwnd := _KSafe_Int(winObj, "hwnd")
                    }
                    if (hwnd) {
                        _KSub_DiagLog("    GetFocusedHwnd: found via monocle_container hwnd=" hwnd)
                        return hwnd
                    }
                }
            }
        }
    }

    ; Last resort fallbacks (some komorebi builds have these at top level)
    if (stateObj is Map) {
        if (stateObj.Has("focused_window")) {
            fw := stateObj["focused_window"]
            if (fw is Map) {
                hwnd := _KSafe_Int(fw, "hwnd")
                if (hwnd) {
                    _KSub_DiagLog("    GetFocusedHwnd: found via focused_window fallback hwnd=" hwnd)
                    return hwnd
                }
            }
        }
        if (stateObj.Has("focused_hwnd")) {
            hwnd := _KSafe_Int(stateObj, "focused_hwnd")
            if (hwnd) {
                _KSub_DiagLog("    GetFocusedHwnd: found via focused_hwnd fallback hwnd=" hwnd)
                return hwnd
            }
        }
        if (stateObj.Has("last_focused_window")) {
            lfw := stateObj["last_focused_window"]
            if (lfw is Map) {
                hwnd := _KSafe_Int(lfw, "hwnd")
                if (hwnd) {
                    _KSub_DiagLog("    GetFocusedHwnd: found via last_focused_window fallback hwnd=" hwnd)
                    return hwnd
                }
            }
        }
    }

    _KSub_DiagLog("    GetFocusedHwnd: could not find focused hwnd")
    return 0
}

; Get focused hwnd from a single workspace object.
; Navigates: focused container → focused window.
_KSub_GetFocusedHwndFromWsObj(wsObj) {
    if !(wsObj is Map)
        return 0

    if (wsObj.Has("containers")) {
        containersRing := wsObj["containers"]
        contArr := _KSafe_Elements(containersRing)
        focusedContIdx := _KSafe_Focused(containersRing)
        if (focusedContIdx >= 0 && focusedContIdx < contArr.Length) {
            contObj := contArr[focusedContIdx + 1]
            if (contObj is Map && contObj.Has("windows")) {
                windowsRing := contObj["windows"]
                winArr := _KSafe_Elements(windowsRing)
                focusedWinIdx := _KSafe_Focused(windowsRing)
                if (focusedWinIdx >= 0 && focusedWinIdx < winArr.Length)
                    return _KSafe_Int(winArr[focusedWinIdx + 1], "hwnd")
            }
            if (contObj is Map && contObj.Has("window"))
                return _KSafe_Int(contObj["window"], "hwnd")
        }
    }

    if (wsObj.Has("monocle_container")) {
        mono := wsObj["monocle_container"]
        if (mono is Map) {
            if (mono.Has("windows")) {
                windowsRing := mono["windows"]
                winArr := _KSafe_Elements(windowsRing)
                focusedWinIdx := _KSafe_Focused(windowsRing)
                if (focusedWinIdx >= 0 && focusedWinIdx < winArr.Length)
                    return _KSafe_Int(winArr[focusedWinIdx + 1], "hwnd")
            }
            if (mono.Has("window"))
                return _KSafe_Int(mono["window"], "hwnd")
        }
    }
    return 0
}

; Get focused hwnd for a specific workspace by name.
; Searches all monitors/workspaces for the named workspace.
_KSub_GetFocusedHwndByWsName(stateObj, wsName) {
    if (wsName = "")
        return 0
    monitorsArr := _KSub_GetMonitorsArray(stateObj)
    for _, monObj in monitorsArr {
        wsArr := _KSub_GetWorkspacesArray(monObj)
        for _, wsObj in wsArr {
            if (_KSafe_Str(wsObj, "name") = wsName)
                return _KSub_GetFocusedHwndFromWsObj(wsObj)
        }
    }
    return 0
}

; Cache focused hwnd for ALL workspaces from a reliable state snapshot.
; Call this only when the state is known to be consistent (skipWorkspaceUpdate=false).
; Returns nothing — populates the provided Map (wsName -> hwnd).
_KSub_CacheFocusedHwnds(stateObj, cache, monitorsArr := 0) {
    if (!IsObject(monitorsArr))
        monitorsArr := _KSub_GetMonitorsArray(stateObj)
    for _, monObj in monitorsArr {
        wsArr := _KSub_GetWorkspacesArray(monObj)
        for _, wsObj in wsArr {
            wsN := _KSafe_Str(wsObj, "name")
            if (wsN = "")
                continue
            fh := _KSub_GetFocusedHwndFromWsObj(wsObj)
            if (fh)
                cache[wsN] := fh
        }
    }
}
