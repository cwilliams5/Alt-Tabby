#Requires AutoHotkey v2.0
; Alt-Tabby GUI - Workspace Mode
; Handles workspace filtering and toggle between "all" and "current" modes
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals/functions

; Workspace mode constants
global WS_MODE_ALL := "all"
global WS_MODE_CURRENT := "current"

; Workspace state
global gGUI_WorkspaceMode := WS_MODE_ALL
global gGUI_FooterText := "All Windows"
global gStats_WorkspaceToggles := 0

; ========================= WORKSPACE PROPERTY HELPERS =========================

; Get workspace name for display/logging (returns "?" if unknown)
GUI_GetItemWSName(item) {
    return item.HasOwnProp("workspaceName") ? item.workspaceName : "?"
}

; Check if item is on current workspace (defaults to true if unknown)
GUI_GetItemIsOnCurrent(item) {
    return item.HasOwnProp("isOnCurrentWorkspace") ? item.isOnCurrentWorkspace : true
}

; ========================= FOOTER TEXT =========================

GUI_UpdateFooterText() {
    global gGUI_FooterText, gGUI_WorkspaceMode, gGUI_CurrentWSName, WS_MODE_ALL
    global gGUI_MonitorMode, MON_MODE_ALL

    ; Build workspace part
    wsPart := ""
    if (gGUI_WorkspaceMode = WS_MODE_ALL) {
        wsPart := "All Workspaces"
    } else {
        wsName := (gGUI_CurrentWSName != "") ? gGUI_CurrentWSName : "Unknown"
        wsPart := "Current (" wsName ")"
    }

    ; Build monitor part
    if (gGUI_MonitorMode != MON_MODE_ALL) {
        monLabel := GUI_GetOverlayMonitorLabel()
        monPart := monLabel ? monLabel : "Current Monitor"
        gGUI_FooterText := wsPart " · " monPart
    } else {
        gGUI_FooterText := wsPart
    }
}

; ========================= WORKSPACE TOGGLE =========================

GUI_ToggleWorkspaceMode() {
    global gGUI_WorkspaceMode, gGUI_State, gGUI_OverlayVisible, gGUI_DisplayItems
    global gStats_WorkspaceToggles, WS_MODE_ALL, WS_MODE_CURRENT, FR_EV_WS_TOGGLE, gFR_Enabled

    ; RACE FIX: Protect counter increment and mode toggle atomically -
    ; callers may not have Critical (GUI_OnClick releases it before calling us)
    Critical "On"
    gStats_WorkspaceToggles += 1
    gGUI_WorkspaceMode := (gGUI_WorkspaceMode = WS_MODE_ALL) ? WS_MODE_CURRENT : WS_MODE_ALL
    Critical "Off"
    if (gFR_Enabled)
        FR_Record(FR_EV_WS_TOGGLE, (gGUI_WorkspaceMode = WS_MODE_ALL) ? 1 : 2, gGUI_DisplayItems.Length)

    GUI_UpdateFooterText()

    ; If GUI is visible and active, re-filter from cached items
    if (gGUI_State = "ACTIVE" && gGUI_OverlayVisible)
        GUI_ApplyWorkspaceFilter()
}

; ========================= WORKSPACE FILTERING =========================

GUI_FilterByWorkspaceMode(items) {
    global gGUI_WorkspaceMode, WS_MODE_ALL

    if (gGUI_WorkspaceMode = WS_MODE_ALL) {
        return items
    }

    ; WS_MODE_CURRENT mode - only items on current workspace
    result := []
    for _, item in items {
        if (GUI_GetItemIsOnCurrent(item)) {
            result.Push(item)
        }
    }
    return result
}

