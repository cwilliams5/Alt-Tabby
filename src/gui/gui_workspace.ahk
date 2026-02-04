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
    global gGUI_CurrentWSName, gGUI_WorkspaceMode, gGUI_State, gGUI_Sel, gGUI_ScrollTop, gGUI_WSContextSwitch, cfg

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

        ; Reset selection to first item when workspace changes during ACTIVE state.
        ; A workspace switch is a context switch: position 1 is the focused window
        ; on the NEW workspace, not "the window you're already on".  Keeping sel=2
        ; (the default from _GUI_ResetSelectionToMRU) would highlight the focused
        ; window from the OLD workspace — wrong after any workspace switch.
        ; Applies in both "current" and "all" mode (the context switch is the same).
        ; RACE FIX: Wrap in Critical to prevent a hotkey (Tab/Ctrl) from modifying
        ; gGUI_Sel between the state check and the assignment.
        Critical "On"
        if (gGUI_State = "ACTIVE") {
            gGUI_Sel := 1
            gGUI_ScrollTop := 0
            gGUI_WSContextSwitch := true  ; Sticky for this overlay session

            ; When frozen, the normal snapshot/delta paths are blocked.
            ; Request a fresh projection that bypasses the freeze gate
            ; (reuses the toggle-response mechanism).
            if (cfg.FreezeWindowList) {
                currentWSOnly := (gGUI_WorkspaceMode = "current")
                GUI_RequestProjectionWithWSFilter(currentWSOnly)
            }
        }
        Critical "Off"
    }
}

; ========================= WORKSPACE TOGGLE =========================

GUI_ToggleWorkspaceMode() {
    global gGUI_WorkspaceMode, gGUI_State, gGUI_OverlayVisible, gGUI_FrozenItems, gGUI_AllItems, gGUI_Items, gGUI_Sel, gGUI_ScrollTop
    global cfg, gStats_WorkspaceToggles

    ; RACE FIX: Protect counter increment - callers may not have Critical
    Critical "On"
    gStats_WorkspaceToggles += 1
    Critical "Off"

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
            ; Critical required: GUI_OnClick releases Critical before calling us,
            ; so an IPC timer could modify gGUI_Items/gGUI_AllItems mid-filter.
            Critical "On"
            isFrozen := cfg.FreezeWindowList
            sourceItems := isFrozen ? gGUI_AllItems : gGUI_Items
            gGUI_FrozenItems := GUI_FilterByWorkspaceMode(sourceItems)
            Critical "Off"
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

