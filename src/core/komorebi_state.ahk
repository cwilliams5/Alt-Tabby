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
;   KSafe_Elements                 - Get ring elements safely
;   _KSafe_Focused                  - Get ring focused index safely
;   KSafe_Str                      - Get string property safely
;   KSafe_Int                      - Get int property safely
;   _KSub_GetMonitorsRing           - Get monitors ring object
;   KSub_GetMonitorsArray          - Get array of monitor objects
;   KSub_GetFocusedMonitorIndex    - Get focused monitor index
;   _KSub_GetWorkspacesRing         - Get workspaces ring from monitor
;   KSub_GetWorkspacesArray        - Get array of workspace objects
;   KSub_GetFocusedWorkspaceIndex  - Get focused workspace index
;   KSub_GetWorkspaceNameByIndex   - Get workspace name by index
;   KSub_FindWorkspaceByHwnd       - Find workspace containing hwnd
;   _KSub_GetFocusedHwndFromWsObj    - Get focused hwnd from workspace obj
; ============================================================

; ========================= SAFE NAVIGATION HELPERS =========================

; Get ring elements safely (returns empty array on failure)
KSafe_Elements(ring) {
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
KSafe_Str(obj, key) {
    if (obj is Map && obj.Has(key)) {
        val := obj[key]
        if (val is String)
            return val
        return String(val)
    }
    return ""
}

; Get int property safely (returns 0 on failure)
KSafe_Int(obj, key) {
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

KSub_GetMonitorsArray(stateObj) {
    ring := _KSub_GetMonitorsRing(stateObj)
    return KSafe_Elements(ring)
}

KSub_GetFocusedMonitorIndex(stateObj) {
    ring := _KSub_GetMonitorsRing(stateObj)
    return _KSafe_Focused(ring)
}

_KSub_GetWorkspacesRing(monObj) {
    if (monObj is Map && monObj.Has("workspaces"))
        return monObj["workspaces"]
    return ""
}

KSub_GetWorkspacesArray(monObj) {
    ring := _KSub_GetWorkspacesRing(monObj)
    return KSafe_Elements(ring)
}

KSub_GetFocusedWorkspaceIndex(monObj) {
    global cfg
    ring := _KSub_GetWorkspacesRing(monObj)
    if (ring = "") {
        if (cfg.DiagKomorebiLog)
            KSub_DiagLog("  GetFocusedWorkspaceIndex: no ring found")
        return -1
    }
    focusedIdx := _KSafe_Focused(ring)
    if (cfg.DiagKomorebiLog)
        KSub_DiagLog("  GetFocusedWorkspaceIndex: focused=" focusedIdx)
    return focusedIdx
}

KSub_GetWorkspaceNameByIndex(monObj, wsIdx) {
    wsArr := KSub_GetWorkspacesArray(monObj)
    if (wsIdx < 0 || wsIdx >= wsArr.Length)
        return ""
    wsObj := wsArr[wsIdx + 1]  ; AHK 1-based
    return KSafe_Str(wsObj, "name")
}

; ========================= HWND LOOKUP =========================

; Find workspace name for a given hwnd by scanning all workspaces
KSub_FindWorkspaceByHwnd(stateObj, hwnd) {
    if (!hwnd)
        return ""
    monitorsArr := KSub_GetMonitorsArray(stateObj)
    for mi, monObj in monitorsArr {
        wsArr := KSub_GetWorkspacesArray(monObj)
        for wi, wsObj in wsArr {
            wsName := KSafe_Str(wsObj, "name")
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
        for _, cont in KSafe_Elements(containers) {
            if !(cont is Map)
                continue
            if (cont.Has("windows")) {
                for _, win in KSafe_Elements(cont["windows"]) {
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
                for _, win in KSafe_Elements(mono["windows"]) {
                    if (win is Map && win.Has("hwnd") && win["hwnd"] = hwnd)
                        return true
                }
            }
        }
    }

    return false
}

; Get focused hwnd from a single workspace object.
; Navigates: focused container → focused window.
_KSub_GetFocusedHwndFromWsObj(wsObj) {
    if !(wsObj is Map)
        return 0

    if (wsObj.Has("containers")) {
        containersRing := wsObj["containers"]
        contArr := KSafe_Elements(containersRing)
        focusedContIdx := _KSafe_Focused(containersRing)
        if (focusedContIdx >= 0 && focusedContIdx < contArr.Length) {
            contObj := contArr[focusedContIdx + 1]
            if (contObj is Map && contObj.Has("windows")) {
                windowsRing := contObj["windows"]
                winArr := KSafe_Elements(windowsRing)
                focusedWinIdx := _KSafe_Focused(windowsRing)
                if (focusedWinIdx >= 0 && focusedWinIdx < winArr.Length)
                    return KSafe_Int(winArr[focusedWinIdx + 1], "hwnd")
            }
            if (contObj is Map && contObj.Has("window"))
                return KSafe_Int(contObj["window"], "hwnd")
        }
    }

    if (wsObj.Has("monocle_container")) {
        mono := wsObj["monocle_container"]
        if (mono is Map) {
            if (mono.Has("windows")) {
                windowsRing := mono["windows"]
                winArr := KSafe_Elements(windowsRing)
                focusedWinIdx := _KSafe_Focused(windowsRing)
                if (focusedWinIdx >= 0 && focusedWinIdx < winArr.Length)
                    return KSafe_Int(winArr[focusedWinIdx + 1], "hwnd")
            }
            if (mono.Has("window"))
                return KSafe_Int(mono["window"], "hwnd")
        }
    }
    return 0
}

; Cache focused hwnd for ALL workspaces from a reliable state snapshot.
; Call this only when the state is known to be consistent (skipWorkspaceUpdate=false).
; Returns nothing — populates the provided Map (wsName -> hwnd).
KSub_CacheFocusedHwnds(stateObj, cache, monitorsArr := 0) {
    if (!IsObject(monitorsArr))
        monitorsArr := KSub_GetMonitorsArray(stateObj)
    for _, monObj in monitorsArr {
        wsArr := KSub_GetWorkspacesArray(monObj)
        for _, wsObj in wsArr {
            wsN := KSafe_Str(wsObj, "name")
            if (wsN = "")
                continue
            fh := _KSub_GetFocusedHwndFromWsObj(wsObj)
            if (fh)
                cache[wsN] := fh
        }
    }
}
