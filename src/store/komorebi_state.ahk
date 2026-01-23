#Requires AutoHotkey v2.0

; ============================================================
; Komorebi State Navigation Helpers
; ============================================================
; Functions for navigating the komorebi state JSON structure.
; Depends on JSON extraction functions from komorebi_json.ahk.
;
; Functions:
;   _KSub_GetMonitorsRing           - Get monitors ring object
;   _KSub_GetMonitorsArray          - Get array of monitor objects
;   _KSub_GetFocusedMonitorIndex    - Get focused monitor index
;   _KSub_GetWorkspacesRing         - Get workspaces ring from monitor
;   _KSub_GetWorkspacesArray        - Get array of workspace objects
;   _KSub_GetFocusedWorkspaceIndex  - Get focused workspace index
;   _KSub_GetWorkspaceNameByIndex   - Get workspace name by index
;   _KSub_FindWorkspaceByHwnd       - Find workspace containing hwnd
;   _KSub_GetFocusedHwndFromWorkspace - Get focused hwnd from named workspace
;   _KSub_GetFocusedHwnd            - Get currently focused hwnd
;   _KSub_FindContainerForHwnd      - Find container start position for hwnd
; ============================================================

_KSub_GetMonitorsRing(stateText) {
    return _KSub_ExtractObjectByKey(stateText, "monitors")
}

_KSub_GetMonitorsArray(stateText) {
    ring := _KSub_GetMonitorsRing(stateText)
    if (ring = "")
        return []
    elems := _KSub_ExtractArrayByKey(ring, "elements")
    return _KSub_ArrayTopLevelSplit(elems)
}

_KSub_GetFocusedMonitorIndex(stateText) {
    ring := _KSub_GetMonitorsRing(stateText)
    if (ring = "")
        return -1
    return _KSub_GetIntProp(ring, "focused")
}

_KSub_GetWorkspacesRing(monObjText) {
    return _KSub_ExtractObjectByKey(monObjText, "workspaces")
}

_KSub_GetWorkspacesArray(monObjText) {
    ring := _KSub_GetWorkspacesRing(monObjText)
    if (ring = "")
        return []
    elems := _KSub_ExtractArrayByKey(ring, "elements")
    return _KSub_ArrayTopLevelSplit(elems)
}

_KSub_GetFocusedWorkspaceIndex(monObjText) {
    ring := _KSub_GetWorkspacesRing(monObjText)
    if (ring = "") {
        _KSub_Log("  GetFocusedWorkspaceIndex: no ring found")
        return -1
    }
    focusedIdx := _KSub_GetIntProp(ring, "focused")
    _KSub_Log("  GetFocusedWorkspaceIndex: ring len=" StrLen(ring) " focused=" focusedIdx)
    return focusedIdx
}

_KSub_GetWorkspaceNameByIndex(monObjText, wsIdx) {
    wsArr := _KSub_GetWorkspacesArray(monObjText)
    if (wsIdx < 0 || wsIdx >= wsArr.Length)
        return ""
    wsObj := wsArr[wsIdx + 1]  ; AHK 1-based
    return _KSub_GetStringProp(wsObj, "name")
}

; Find workspace name for a given hwnd by scanning all workspaces
_KSub_FindWorkspaceByHwnd(stateText, hwnd) {
    if (!hwnd)
        return ""
    monitorsArr := _KSub_GetMonitorsArray(stateText)
    for mi, monObj in monitorsArr {
        wsArr := _KSub_GetWorkspacesArray(monObj)
        for wi, wsObj in wsArr {
            ; Quick search for "hwnd": <value> inside this workspace
            if RegExMatch(wsObj, '"hwnd"\s*:\s*' hwnd '\b') {
                return _KSub_GetStringProp(wsObj, "name")
            }
        }
    }
    return ""
}

; Get the focused window hwnd from a SPECIFIC workspace by name
; Used for move events where we need to find the window on the SOURCE workspace
_KSub_GetFocusedHwndFromWorkspace(stateText, targetWsName) {
    if (targetWsName = "")
        return _KSub_GetFocusedHwnd(stateText)  ; Fallback to general lookup

    _KSub_DiagLog("    GetFocusedHwndFromWorkspace: looking for ws='" targetWsName "'")

    ; Search all monitors for the workspace with this name
    monitorsArr := _KSub_GetMonitorsArray(stateText)
    for mi, monObj in monitorsArr {
        wsArr := _KSub_GetWorkspacesArray(monObj)
        for wi, wsObj in wsArr {
            wsName := _KSub_GetStringProp(wsObj, "name")
            if (wsName = targetWsName) {
                _KSub_DiagLog("    Found workspace '" targetWsName "' at mon=" (mi-1) " ws=" (wi-1))

                ; Get focused container in this workspace
                containersRing := _KSub_ExtractObjectByKey(wsObj, "containers")
                if (containersRing != "") {
                    focusedContIdx := _KSub_GetIntProp(containersRing, "focused")
                    containersArr := _KSub_ExtractArrayByKey(containersRing, "elements")
                    if (containersArr != "") {
                        containers := _KSub_ArrayTopLevelSplit(containersArr)
                        if (focusedContIdx >= 0 && focusedContIdx < containers.Length) {
                            contObj := containers[focusedContIdx + 1]

                            ; Get focused window in this container
                            windowsRing := _KSub_ExtractObjectByKey(contObj, "windows")
                            if (windowsRing != "") {
                                focusedWinIdx := _KSub_GetIntProp(windowsRing, "focused")
                                windowsArr := _KSub_ExtractArrayByKey(windowsRing, "elements")
                                if (windowsArr != "") {
                                    windows := _KSub_ArrayTopLevelSplit(windowsArr)
                                    if (focusedWinIdx >= 0 && focusedWinIdx < windows.Length) {
                                        winObj := windows[focusedWinIdx + 1]
                                        hwnd := _KSub_GetIntProp(winObj, "hwnd")
                                        if (hwnd) {
                                            _KSub_DiagLog("    Found hwnd=" hwnd " via containers.windows")
                                            return hwnd
                                        }
                                    }
                                }
                            }

                            ; Fallback: container might have "window" directly
                            windowObj := _KSub_ExtractObjectByKey(contObj, "window")
                            if (windowObj != "") {
                                hwnd := _KSub_GetIntProp(windowObj, "hwnd")
                                if (hwnd) {
                                    _KSub_DiagLog("    Found hwnd=" hwnd " via container.window")
                                    return hwnd
                                }
                            }
                        }
                    }
                }

                ; Fallback: try monocle_container
                monocleObj := _KSub_ExtractObjectByKey(wsObj, "monocle_container")
                if (monocleObj != "") {
                    hwnd := _KSub_GetIntProp(monocleObj, "hwnd")
                    if (!hwnd) {
                        winObj := _KSub_ExtractObjectByKey(monocleObj, "window")
                        if (winObj != "")
                            hwnd := _KSub_GetIntProp(winObj, "hwnd")
                    }
                    if (hwnd) {
                        _KSub_DiagLog("    Found hwnd=" hwnd " via monocle_container")
                        return hwnd
                    }
                }

                _KSub_DiagLog("    Workspace found but no focused window")
                return 0
            }
        }
    }

    _KSub_DiagLog("    Workspace '" targetWsName "' not found in state")
    return 0
}

; Get the focused window hwnd from komorebi state
; Must navigate: focused monitor -> focused workspace -> focused container -> focused window
_KSub_GetFocusedHwnd(stateText) {
    ; Navigate through the state hierarchy to find the truly focused window
    ; 1. Get focused monitor
    focusedMonIdx := _KSub_GetFocusedMonitorIndex(stateText)
    monitorsArr := _KSub_GetMonitorsArray(stateText)

    if (focusedMonIdx >= 0 && focusedMonIdx < monitorsArr.Length) {
        monObj := monitorsArr[focusedMonIdx + 1]  ; AHK 1-based

        ; 2. Get focused workspace on this monitor
        focusedWsIdx := _KSub_GetFocusedWorkspaceIndex(monObj)
        wsArr := _KSub_GetWorkspacesArray(monObj)

        if (focusedWsIdx >= 0 && focusedWsIdx < wsArr.Length) {
            wsObj := wsArr[focusedWsIdx + 1]  ; AHK 1-based

            ; 3. Get focused container in this workspace
            containersRing := _KSub_ExtractObjectByKey(wsObj, "containers")
            if (containersRing != "") {
                focusedContIdx := _KSub_GetIntProp(containersRing, "focused")
                containersArr := _KSub_ExtractArrayByKey(containersRing, "elements")
                if (containersArr != "") {
                    containers := _KSub_ArrayTopLevelSplit(containersArr)
                    if (focusedContIdx >= 0 && focusedContIdx < containers.Length) {
                        contObj := containers[focusedContIdx + 1]

                        ; 4. Get focused window in this container
                        windowsRing := _KSub_ExtractObjectByKey(contObj, "windows")
                        if (windowsRing != "") {
                            focusedWinIdx := _KSub_GetIntProp(windowsRing, "focused")
                            windowsArr := _KSub_ExtractArrayByKey(windowsRing, "elements")
                            if (windowsArr != "") {
                                windows := _KSub_ArrayTopLevelSplit(windowsArr)
                                if (focusedWinIdx >= 0 && focusedWinIdx < windows.Length) {
                                    winObj := windows[focusedWinIdx + 1]
                                    hwnd := _KSub_GetIntProp(winObj, "hwnd")
                                    if (hwnd) {
                                        _KSub_DiagLog("    GetFocusedHwnd: found via hierarchy hwnd=" hwnd)
                                        return hwnd
                                    }
                                }
                            }
                        }

                        ; Fallback: container might have "window" directly (single window container)
                        windowObj := _KSub_ExtractObjectByKey(contObj, "window")
                        if (windowObj != "") {
                            hwnd := _KSub_GetIntProp(windowObj, "hwnd")
                            if (hwnd) {
                                _KSub_DiagLog("    GetFocusedHwnd: found via container.window hwnd=" hwnd)
                                return hwnd
                            }
                        }
                    }
                }
            }

            ; Fallback: try workspace's monocle_container
            monocleObj := _KSub_ExtractObjectByKey(wsObj, "monocle_container")
            if (monocleObj != "") {
                hwnd := _KSub_GetIntProp(monocleObj, "hwnd")
                if (!hwnd) {
                    ; Try nested window object
                    winObj := _KSub_ExtractObjectByKey(monocleObj, "window")
                    if (winObj != "")
                        hwnd := _KSub_GetIntProp(winObj, "hwnd")
                }
                if (hwnd) {
                    _KSub_DiagLog("    GetFocusedHwnd: found via monocle_container hwnd=" hwnd)
                    return hwnd
                }
            }
        }
    }

    ; Last resort fallbacks (some komorebi builds have these at top level):
    m := 0
    if RegExMatch(stateText, '(?s)"focused_window"\s*:\s*\{[^}]*"hwnd"\s*:\s*(\d+)', &m) {
        _KSub_DiagLog("    GetFocusedHwnd: found via focused_window fallback hwnd=" m[1])
        return Integer(m[1])
    }
    if RegExMatch(stateText, '(?s)"focused_hwnd"\s*:\s*(\d+)', &m) {
        _KSub_DiagLog("    GetFocusedHwnd: found via focused_hwnd fallback hwnd=" m[1])
        return Integer(m[1])
    }
    if RegExMatch(stateText, '(?s)"last_focused_window"\s*:\s*\{[^}]*"hwnd"\s*:\s*(\d+)', &m) {
        _KSub_DiagLog("    GetFocusedHwnd: found via last_focused_window fallback hwnd=" m[1])
        return Integer(m[1])
    }

    _KSub_DiagLog("    GetFocusedHwnd: could not find focused hwnd")
    return 0
}

; Find the start of a container object containing the given hwnd
_KSub_FindContainerForHwnd(containersText, hwnd) {
    ; Find "hwnd": <hwnd> in the text
    pat := '"hwnd"\s*:\s*' hwnd '\b'
    if !RegExMatch(containersText, pat, &m)
        return 0

    ; Scan backwards to find the enclosing '{'
    pos := m.Pos(0)
    depth := 0
    i := pos
    while (i > 1) {
        ch := SubStr(containersText, i, 1)
        if (ch = "}") {
            depth++
        } else if (ch = "{") {
            if (depth = 0)
                return i
            depth--
        }
        i--
    }
    return 0
}
