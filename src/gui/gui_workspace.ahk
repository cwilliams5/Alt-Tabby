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

; ========================= FOOTER TEXT =========================

GUI_UpdateFooterText() {
    global gGUI_FooterText, gGUI_WorkspaceMode, gGUI_CurrentWSName, WS_MODE_ALL

    if (gGUI_WorkspaceMode = WS_MODE_ALL) {
        gGUI_FooterText := "All Workspaces"
    } else {
        ; WS_MODE_CURRENT mode
        wsName := (gGUI_CurrentWSName != "") ? gGUI_CurrentWSName : "Unknown"
        gGUI_FooterText := "Current (" wsName ")"
    }
}

; ========================= CURRENT WORKSPACE TRACKING =========================

GUI_UpdateCurrentWSFromPayload(payload) {
    global gGUI_CurrentWSName

    if (!payload.Has("meta"))
        return

    meta := payload["meta"]
    wsName := ""

    ; Handle both Map and Object types for meta
    if (meta is Map) {
        wsName := meta.Has("currentWSName") ? meta["currentWSName"] : ""
    } else if (IsObject(meta)) {
        try wsName := meta.currentWSName
    }

    if (wsName != "" && wsName != gGUI_CurrentWSName) {
        gGUI_CurrentWSName := wsName
        GUI_UpdateFooterText()

        ; Workspace switch is a context switch: reset selection to top,
        ; mark sticky, and request fresh display list if frozen.
        Critical "On"
        GUI_HandleWorkspaceSwitch()
        Critical "Off"
    }
}

; ========================= WORKSPACE TOGGLE =========================

GUI_ToggleWorkspaceMode() {
    global gGUI_WorkspaceMode, gGUI_State, gGUI_OverlayVisible, gGUI_DisplayItems, gGUI_ToggleBase
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

    ; If GUI is visible and active, filter locally from cached items
    if (gGUI_State = "ACTIVE" && gGUI_OverlayVisible) {
        Critical "On"
        sourceItems := gGUI_ToggleBase
        gGUI_DisplayItems := GUI_FilterByWorkspaceMode(sourceItems)
        Critical "Off"

        GUI_ResetSelectionToMRU()

        rowsDesired := GUI_ComputeRowsToShow(gGUI_DisplayItems.Length)
        GUI_ResizeToRows(rowsDesired)
        GUI_Repaint()
    }
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
        isOnCurrent := item.HasOwnProp("isOnCurrentWorkspace") ? item.isOnCurrentWorkspace : true
        if (isOnCurrent) {
            result.Push(item)
        }
    }
    return result
}

