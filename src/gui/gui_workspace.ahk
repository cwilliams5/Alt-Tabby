#Requires AutoHotkey v2.0
; Alt-Tabby GUI - Workspace Mode
; Handles workspace filtering and toggle between "all" and "current" modes
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals/functions

; ========================= FOOTER TEXT =========================

GUI_UpdateFooterText() {
    global gGUI_FooterText, gGUI_WorkspaceMode, gGUI_CurrentWSName

    if (gGUI_WorkspaceMode = "all") {
        gGUI_FooterText := "All Workspaces"
    } else {
        ; "current" mode
        wsName := (gGUI_CurrentWSName != "") ? gGUI_CurrentWSName : "Unknown"
        gGUI_FooterText := "Current (" wsName ")"
    }
}

; ========================= CURRENT WORKSPACE TRACKING =========================

GUI_UpdateCurrentWSFromPayload(payload) {
    global gGUI_CurrentWSName, gGUI_WorkspaceMode, gGUI_State, gGUI_Sel, gGUI_ScrollTop

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

        ; Reset selection to first item when workspace changes in "current" mode.
        ; The user's tab position was contextual to the old workspace — retaining it
        ; on the new workspace highlights an unrelated window or nothing at all
        ; (if the new workspace has fewer windows than the old selection index).
        if (gGUI_WorkspaceMode = "current" && gGUI_State = "ACTIVE") {
            gGUI_Sel := 1
            gGUI_ScrollTop := 0
        }
    }
}

; ========================= WORKSPACE TOGGLE =========================

GUI_ToggleWorkspaceMode() {
    global gGUI_WorkspaceMode, gGUI_State, gGUI_OverlayVisible, gGUI_FrozenItems, gGUI_AllItems, gGUI_Items, gGUI_Sel, gGUI_ScrollTop
    global cfg

    ; Toggle mode
    gGUI_WorkspaceMode := (gGUI_WorkspaceMode = "all") ? "current" : "all"
    GUI_UpdateFooterText()

    ; If GUI is visible and active, refresh the list
    if (gGUI_State = "ACTIVE" && gGUI_OverlayVisible) {
        ; Check if we should request from store or filter locally
        useServerFilter := cfg.UseCurrentWSProjection

        if (useServerFilter) {
            ; Request new projection from store with workspace filter
            ; Response will be handled by GUI_OnStoreMessage (gGUI_AwaitingToggleProjection flag)
            currentWSOnly := (gGUI_WorkspaceMode = "current")
            GUI_RequestProjectionWithWSFilter(currentWSOnly)
            ; Don't repaint yet - wait for response
        } else {
            ; Filter locally from cached items
            isFrozen := cfg.FreezeWindowList
            sourceItems := isFrozen ? gGUI_AllItems : gGUI_Items
            gGUI_FrozenItems := GUI_FilterByWorkspaceMode(sourceItems)
            ; NOTE: Do NOT update gGUI_Items - it must stay unfiltered as the source of truth

            ; Reset selection
            _GUI_ResetSelectionToMRU()

            ; Resize GUI if item count changed significantly
            rowsDesired := GUI_ComputeRowsToShow(gGUI_FrozenItems.Length)
            GUI_ResizeToRows(rowsDesired)
            GUI_Repaint()
        }
    }
}

; ========================= WORKSPACE FILTERING =========================

GUI_FilterByWorkspaceMode(items) {
    global gGUI_WorkspaceMode

    if (gGUI_WorkspaceMode = "all") {
        return items
    }

    ; "current" mode - only items on current workspace
    result := []
    for _, item in items {
        isOnCurrent := item.HasOwnProp("isOnCurrentWorkspace") ? item.isOnCurrentWorkspace : true
        if (isOnCurrent) {
            result.Push(item)
        }
    }
    return result
}

; ========================= WORKSPACE MODE SETTER =========================

GUI_SetWorkspaceMode(mode) {
    global gGUI_WorkspaceMode

    if (mode != "all" && mode != "current") {
        return
    }
    if (gGUI_WorkspaceMode = mode) {
        return
    }

    gGUI_WorkspaceMode := mode
    GUI_UpdateFooterText()

    ; Same logic as toggle - re-filter if visible
    global gGUI_State, gGUI_OverlayVisible, gGUI_FrozenItems, gGUI_Items
    if (gGUI_State = "ACTIVE" && gGUI_OverlayVisible) {
        gGUI_FrozenItems := GUI_FilterByWorkspaceMode(gGUI_Items)
        _GUI_ResetSelectionToMRU()
        GUI_Repaint()
    }
}
