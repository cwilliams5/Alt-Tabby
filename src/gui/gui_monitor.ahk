#Requires AutoHotkey v2.0
; Alt-Tabby GUI - Monitor Mode
; Handles monitor filtering and toggle between "all" and "current" modes
; Mirrors gui_workspace.ahk pattern for consistency
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals/functions

; Monitor mode constants
global MON_MODE_ALL := "all"
global MON_MODE_CURRENT := "current"

; Monitor state
global gGUI_MonitorMode := MON_MODE_ALL
global gGUI_OverlayMonitorHandle := 0  ; hMonitor of the overlay's target monitor
global gStats_MonitorToggles := 0

; ========================= MONITOR TOGGLE =========================

GUI_ToggleMonitorMode() {
    global gGUI_MonitorMode, gGUI_State, gGUI_OverlayVisible, gGUI_DisplayItems
    global gStats_MonitorToggles, MON_MODE_ALL, MON_MODE_CURRENT
    global FR_EV_MON_TOGGLE, gFR_Enabled

    ; RACE FIX: Protect counter increment and mode toggle atomically
    Critical "On"
    gStats_MonitorToggles += 1
    gGUI_MonitorMode := (gGUI_MonitorMode = MON_MODE_ALL) ? MON_MODE_CURRENT : MON_MODE_ALL
    Critical "Off"
    if (gFR_Enabled)
        FR_Record(FR_EV_MON_TOGGLE, (gGUI_MonitorMode = MON_MODE_ALL) ? 1 : 2, gGUI_DisplayItems.Length)

    GUI_UpdateFooterText()

    ; If GUI is visible and active, re-filter from cached items
    if (gGUI_State = "ACTIVE" && gGUI_OverlayVisible)
        GUI_ApplyMonitorFilter()
}

; ========================= MONITOR FILTERING =========================

; Predicate: does this item pass the current monitor filter?
; Used by GUI_FilterDisplayItems() for single-pass filtering.
; Caller must check mode/handle guards before calling this.
GUI_MonitorItemPasses(item) {
    global gGUI_OverlayMonitorHandle
    return (item.monitorHandle = gGUI_OverlayMonitorHandle)
}

; ========================= MONITOR MODE INIT =========================

; Initialize monitor mode from config default
GUI_InitMonitorMode() {
    global gGUI_MonitorMode, cfg, MON_MODE_ALL, MON_MODE_CURRENT
    if (cfg.GUI_MonitorFilterDefault = "Current")
        gGUI_MonitorMode := MON_MODE_CURRENT
    else
        gGUI_MonitorMode := MON_MODE_ALL
}

; Capture the overlay's target monitor handle (call at overlay show time)
GUI_CaptureOverlayMonitor() {
    global gGUI_OverlayMonitorHandle
    targetHwnd := GUI_GetTargetMonitorHwnd()
    gGUI_OverlayMonitorHandle := Win_GetMonitorHandle(targetHwnd)
}

; Get monitor label for the overlay's current monitor
GUI_GetOverlayMonitorLabel() {
    global gGUI_OverlayMonitorHandle
    return Win_GetMonitorLabel(gGUI_OverlayMonitorHandle)
}

; GUI_StampMonitorLabels removed — monitorLabel is now a store field stamped by producers
