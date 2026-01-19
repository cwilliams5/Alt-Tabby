#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals

; ============================================================
; Config Editor - GUI for editing Alt-Tabby settings
; ============================================================
; Launch with: alt_tabby.ahk --config
; Or from tray menu: "Edit Config..."
;
; Uses gConfigRegistry from config_loader.ahk to dynamically
; build the UI. Supports bool (checkbox), int/float/string (edit).
; Shows section descriptions and subsection headers.
;
; Dynamically adds vertical scrollbars to tabs whose content
; exceeds the available viewport height.
; ============================================================

; Scroll pane not needed - scrolling handled directly with control movement
; and native Windows scrollbar APIs

global gCE_Gui := 0
global gCE_TabCtrl := 0               ; Tab control reference
global gCE_Controls := Map()          ; Map of globalName -> control
global gCE_OriginalValues := Map()    ; Map of globalName -> original value
global gCE_SectionHeights := Map()    ; Calculated height per section
global gCE_ScrollPanes := Map()       ; Map of sectionName -> {controls, contentHeight, viewportHeight, scrollPos}
global gCE_CurrentSection := ""       ; Currently visible section
global gCE_TabViewportH := 0          ; Available height inside tab content area
global gCE_BoundScrollMsg := 0        ; Bound scroll message handler
global gCE_BoundWheelMsg := 0         ; Bound mouse wheel handler
global gCE_HasChanges := false
global gCE_SavedChanges := false
global gCE_AutoRestart := false

; Scroll bar constants
global CE_SB_VERT := 1
global CE_SIF_RANGE := 0x1
global CE_SIF_PAGE := 0x2
global CE_SIF_POS := 0x4
global CE_SIF_ALL := 0x17
global CE_WM_VSCROLL := 0x115
global CE_WM_MOUSEWHEEL := 0x20A

; Scroll commands
global CE_SB_LINEUP := 0
global CE_SB_LINEDOWN := 1
global CE_SB_PAGEUP := 2
global CE_SB_PAGEDOWN := 3
global CE_SB_THUMBTRACK := 5

; ============================================================
; PUBLIC API
; ============================================================

; Run the config editor
; autoRestart: If true, caller will handle restart on save
; Returns: true if changes were saved, false otherwise
ConfigEditor_Run(autoRestart := false) {
    global gCE_Gui, gCE_SavedChanges, gCE_AutoRestart, gConfigLoaded

    gCE_AutoRestart := autoRestart
    gCE_SavedChanges := false

    ; Initialize config system if not already done
    if (!gConfigLoaded)
        ConfigLoader_Init()

    ; Create and show the GUI
    _CE_CreateGui()
    _CE_LoadValues()

    gCE_Gui.Show()

    ; Block until GUI closes
    WinWaitClose(gCE_Gui.Hwnd)

    return gCE_SavedChanges
}

; ============================================================
; GUI CREATION
; ============================================================

_CE_CreateGui() {
    global gCE_Gui, gCE_TabCtrl, gCE_Controls, gConfigRegistry, gCE_SectionHeights
    global gCE_ScrollPanes, gCE_CurrentSection, gCE_TabViewportH

    gCE_Controls := Map()
    gCE_SectionHeights := Map()
    gCE_ScrollPanes := Map()

    ; Get unique section names in order
    sections := _CE_GetSectionNames()

    ; First pass: calculate content height for each section accurately
    maxHeight := 0
    for _, sectionName in sections {
        sectionHeight := _CE_CalcSectionHeight(sectionName)
        gCE_SectionHeights[sectionName] := sectionHeight
        if (sectionHeight > maxHeight)
            maxHeight := sectionHeight
    }

    ; Fixed window/tab dimensions
    tabHeight := 600
    windowHeight := tabHeight + 80  ; Room for buttons

    ; Create GUI - WS_CLIPCHILDREN helps with redraw
    gCE_Gui := Gui("+Resize +MinSize700x500 +0x02000000", "Alt-Tabby Configuration")
    gCE_Gui.OnEvent("Close", _CE_OnClose)
    gCE_Gui.OnEvent("Size", _CE_OnSize)
    gCE_Gui.SetFont("s9", "Segoe UI")

    ; Create tab control - positioned to leave room for buttons
    gCE_TabCtrl := gCE_Gui.AddTab3("vTabs x10 y10 w780 h" tabHeight, sections)
    gCE_TabCtrl.OnEvent("Change", _CE_OnTabChange)

    ; Tab content area height (tab is 600px, headers ~50px, margin ~10px)
    gCE_TabViewportH := tabHeight - 60

    ; Build controls for ALL sections directly in tabs
    ; Track controls per section for scrolling
    for _, sectionName in sections {
        gCE_TabCtrl.UseTab(sectionName)
        contentHeight := gCE_SectionHeights[sectionName]

        ; Build controls and get the list of controls created
        sectionCtrls := _CE_BuildSectionControls(sectionName, gCE_Gui, false)

        ; If this section needs scrolling, track it
        if (contentHeight > gCE_TabViewportH) {
            gCE_ScrollPanes[sectionName] := {
                controls: sectionCtrls,
                contentHeight: contentHeight,
                viewportHeight: gCE_TabViewportH,
                scrollPos: 0
            }
        }
    }

    gCE_TabCtrl.UseTab()  ; Exit tab control

    gCE_CurrentSection := sections[1]

    ; Register mouse wheel handler for scrolling
    gCE_BoundWheelMsg := _CE_OnMouseWheel
    OnMessage(CE_WM_MOUSEWHEEL, gCE_BoundWheelMsg)

    ; Register scrollbar message handler
    gCE_BoundScrollMsg := _CE_OnVScroll
    OnMessage(CE_WM_VSCROLL, gCE_BoundScrollMsg)

    ; Update scrollbar for initial section
    _CE_UpdateScrollBar()

    ; Bottom buttons - positioned below tabs
    btnY := tabHeight + 25
    gCE_Gui.AddButton("vBtnSave w80 x600 y" btnY, "Save").OnEvent("Click", _CE_OnSave)
    gCE_Gui.AddButton("vBtnCancel w80 x690 y" btnY, "Cancel").OnEvent("Click", _CE_OnCancel)

    ; Set initial window size
    gCE_Gui.Show("w800 h" windowHeight)
    gCE_Gui.Hide()  ; Will be shown by caller
}

; Calculate height needed for a section's content
; Returns the pure content height (not including tab header offset)
_CE_CalcSectionHeight(sectionName) {
    global gConfigRegistry
    y := 0  ; Pure content height, no offset

    ; Section description
    for _, entry in gConfigRegistry {
        if (entry.HasOwnProp("type") && entry.type = "section" && entry.name = sectionName) {
            if (entry.HasOwnProp("long")) {
                textLen := StrLen(entry.long)
                lineCount := Max(1, Ceil(textLen / 80))
                y += lineCount * 16 + 12
            }
            break
        }
    }

    ; Count items in this section
    for _, entry in gConfigRegistry {
        if (entry.HasOwnProp("type") && entry.type = "subsection" && entry.section = sectionName) {
            y += 12  ; Spacing
            y += 18  ; Header
            if (entry.HasOwnProp("desc")) {
                descLen := StrLen(entry.desc)
                descLines := Max(1, Ceil(descLen / 85))
                y += descLines * 14 + 6
            }
            continue
        }

        if (!entry.HasOwnProp("default") || entry.s != sectionName)
            continue

        if (entry.t = "bool")
            y += 22
        else
            y += 26
    }

    return y
}

_CE_GetSectionNames() {
    global gConfigRegistry

    ; Define order (matches config_loader.ahk)
    order := ["AltTab", "Launcher", "GUI", "IPC", "Tools", "Producers", "Filtering",
              "WinEventHook", "ZPump", "WinEnum", "MruLite",
              "IconPump", "ProcPump", "KomorebiSub",
              "Heartbeat", "Viewer", "Diagnostics", "Testing"]

    ; Filter to only sections that exist in registry
    result := []
    seen := Map()
    for _, entry in gConfigRegistry {
        if (entry.HasOwnProp("type") && entry.type = "section") {
            seen[entry.name] := true
        }
    }
    for _, s in order {
        if (seen.Has(s))
            result.Push(s)
    }
    return result
}

; Build controls for a section
; targetGui: The GUI to add controls to
; isScrollPane: unused now, kept for compatibility
; Returns: Array of {ctrl, origY} for all controls created (for scrolling)
_CE_BuildSectionControls(sectionName, targetGui, isScrollPane := false) {
    global gCE_Controls, gConfigRegistry

    createdControls := []  ; Track controls for scrolling

    ; Start y position after tab headers (60px)
    y := 60
    xBase := 20

    ; Find section's long description and show it
    for _, entry in gConfigRegistry {
        if (entry.HasOwnProp("type") && entry.type = "section" && entry.name = sectionName) {
            if (entry.HasOwnProp("long")) {
                targetGui.SetFont("s9 italic", "Segoe UI")
                textLen := StrLen(entry.long)
                lineCount := Max(1, Ceil(textLen / 80))
                textHeight := lineCount * 16 + 4
                txtCtrl := targetGui.AddText("x" xBase " y" y " w600 h" textHeight " +Wrap cGray", entry.long)
                createdControls.Push({ctrl: txtCtrl, origY: y})
                targetGui.SetFont("s9 norm", "Segoe UI")
                y += textHeight + 8
            }
            break
        }
    }

    isFirst := true

    for _, entry in gConfigRegistry {
        ; Handle subsection headers
        if (entry.HasOwnProp("type") && entry.type = "subsection" && entry.section = sectionName) {
            if (!isFirst)
                y += 12

            targetGui.SetFont("s9 bold", "Segoe UI")
            hdrCtrl := targetGui.AddText("x" xBase " y" y " w300", entry.name)
            createdControls.Push({ctrl: hdrCtrl, origY: y})
            targetGui.SetFont("s9 norm", "Segoe UI")
            y += 18

            if (entry.HasOwnProp("desc")) {
                targetGui.SetFont("s8 italic", "Segoe UI")
                descLen := StrLen(entry.desc)
                descLines := Max(1, Ceil(descLen / 85))
                descHeight := descLines * 14 + 2
                descCtrl := targetGui.AddText("x" xBase " y" y " w600 h" descHeight " +Wrap cGray", entry.desc)
                createdControls.Push({ctrl: descCtrl, origY: y})
                targetGui.SetFont("s9 norm", "Segoe UI")
                y += descHeight + 4
            }

            isFirst := false
            continue
        }

        if (!entry.HasOwnProp("default"))
            continue
        if (entry.s != sectionName)
            continue

        if (entry.t = "bool") {
            ctrl := targetGui.AddCheckbox("v" entry.g " x" xBase " y" y, entry.k)
            ctrl.ToolTip := entry.d
            createdControls.Push({ctrl: ctrl, origY: y})
            y += 22
        } else {
            editX := xBase + 160
            lblCtrl := targetGui.AddText("x" xBase " y" y " w150", entry.k ":")
            createdControls.Push({ctrl: lblCtrl, origY: y})
            ctrl := targetGui.AddEdit("v" entry.g " x" editX " y" (y - 2) " w200")
            ctrl.ToolTip := entry.d
            createdControls.Push({ctrl: ctrl, origY: y - 2})
            y += 26
        }

        gCE_Controls[entry.g] := ctrl
        isFirst := false
    }

    return createdControls
}

; ============================================================
; SCROLLBAR MANAGEMENT
; ============================================================

; Update the scrollbar visibility and range for current section
_CE_UpdateScrollBar() {
    global gCE_Gui, gCE_ScrollPanes, gCE_CurrentSection, gCE_TabViewportH

    ; Check if current section needs scrolling
    if (!gCE_ScrollPanes.Has(gCE_CurrentSection)) {
        ; No scrolling needed - hide scrollbar
        DllCall("ShowScrollBar", "Ptr", gCE_Gui.Hwnd, "Int", CE_SB_VERT, "Int", false)
        return
    }

    pane := gCE_ScrollPanes[gCE_CurrentSection]

    ; Show scrollbar
    DllCall("ShowScrollBar", "Ptr", gCE_Gui.Hwnd, "Int", CE_SB_VERT, "Int", true)

    ; Create SCROLLINFO struct (28 bytes)
    scrollInfo := Buffer(28, 0)
    NumPut("UInt", 28, scrollInfo, 0)                                    ; cbSize
    NumPut("UInt", CE_SIF_RANGE | CE_SIF_PAGE | CE_SIF_POS, scrollInfo, 4)  ; fMask
    NumPut("Int", 0, scrollInfo, 8)                                      ; nMin
    NumPut("Int", pane.contentHeight, scrollInfo, 12)                    ; nMax
    NumPut("UInt", pane.viewportHeight, scrollInfo, 16)                  ; nPage
    NumPut("Int", pane.scrollPos, scrollInfo, 20)                        ; nPos

    DllCall("SetScrollInfo", "Ptr", gCE_Gui.Hwnd, "Int", CE_SB_VERT, "Ptr", scrollInfo, "Int", true)
}

; Update just the scroll position (after scrolling)
_CE_UpdateScrollPos() {
    global gCE_Gui, gCE_ScrollPanes, gCE_CurrentSection

    if (!gCE_ScrollPanes.Has(gCE_CurrentSection))
        return

    pane := gCE_ScrollPanes[gCE_CurrentSection]

    scrollInfo := Buffer(28, 0)
    NumPut("UInt", 28, scrollInfo, 0)           ; cbSize
    NumPut("UInt", CE_SIF_POS, scrollInfo, 4)   ; fMask
    NumPut("Int", pane.scrollPos, scrollInfo, 20)  ; nPos

    DllCall("SetScrollInfo", "Ptr", gCE_Gui.Hwnd, "Int", CE_SB_VERT, "Ptr", scrollInfo, "Int", true)
}

; ============================================================
; VALUE LOADING/SAVING
; ============================================================

_CE_LoadValues() {
    global gCE_Controls, gCE_OriginalValues, gConfigRegistry, gConfigIniPath

    gCE_OriginalValues := Map()

    for _, entry in gConfigRegistry {
        ; Skip non-settings
        if (!entry.HasOwnProp("default"))
            continue

        if (!gCE_Controls.Has(entry.g))
            continue

        ctrl := gCE_Controls[entry.g]

        ; Read from INI, fall back to default
        iniVal := IniRead(gConfigIniPath, entry.s, entry.k, "")
        if (iniVal = "") {
            ; Use default from registry
            val := entry.default
        } else {
            ; Parse INI value
            val := _CE_ParseValue(iniVal, entry.t)
        }

        ; Set control value
        _CE_SetControlValue(ctrl, val, entry.t)

        ; Store original for change detection
        gCE_OriginalValues[entry.g] := val
    }
}

_CE_ParseValue(iniVal, type) {
    switch type {
        case "bool":
            return (iniVal = "true" || iniVal = "1" || iniVal = "yes")
        case "int":
            if (SubStr(iniVal, 1, 2) = "0x")
                return Integer(iniVal)
            return Integer(iniVal)
        case "float":
            return Float(iniVal)
        default:
            return iniVal
    }
}

_CE_SetControlValue(ctrl, val, type) {
    if (type = "bool") {
        ctrl.Value := val ? 1 : 0
    } else {
        ctrl.Value := String(val)
    }
}

_CE_GetControlValue(ctrl, type) {
    if (type = "bool") {
        return ctrl.Value ? true : false
    } else if (type = "int") {
        try {
            txt := ctrl.Value
            if (SubStr(txt, 1, 2) = "0x")
                return Integer(txt)
            return Integer(txt)
        } catch {
            return 0
        }
    } else if (type = "float") {
        try {
            return Float(ctrl.Value)
        } catch {
            return 0.0
        }
    }
    return ctrl.Value
}

_CE_HasUnsavedChanges() {
    global gCE_Controls, gCE_OriginalValues, gConfigRegistry

    for _, entry in gConfigRegistry {
        ; Skip non-settings
        if (!entry.HasOwnProp("default"))
            continue

        if (!gCE_Controls.Has(entry.g))
            continue

        ctrl := gCE_Controls[entry.g]
        currentVal := _CE_GetControlValue(ctrl, entry.t)
        originalVal := gCE_OriginalValues[entry.g]

        if (currentVal != originalVal)
            return true
    }
    return false
}

_CE_SaveToIni() {
    global gCE_Controls, gCE_OriginalValues, gConfigRegistry, gConfigIniPath

    changeCount := 0

    for _, entry in gConfigRegistry {
        ; Skip non-settings
        if (!entry.HasOwnProp("default"))
            continue

        if (!gCE_Controls.Has(entry.g))
            continue

        ctrl := gCE_Controls[entry.g]
        currentVal := _CE_GetControlValue(ctrl, entry.t)
        originalVal := gCE_OriginalValues[entry.g]

        ; Only write changed values
        if (currentVal != originalVal) {
            ; Use format-preserving write - passes default so it can comment/uncomment
            _CL_WriteIniPreserveFormat(gConfigIniPath, entry.s, entry.k, currentVal, entry.default, entry.t)
            changeCount++
        }
    }

    return changeCount
}

_CE_FormatForIni(val, type) {
    if (type = "bool")
        return val ? "true" : "false"
    if (type = "int" && IsInteger(val) && val >= 0x100)
        return Format("0x{:X}", val)  ; Hex for colors
    return String(val)
}

; ============================================================
; EVENT HANDLERS
; ============================================================

_CE_OnSave(*) {
    global gCE_Gui, gCE_SavedChanges, gCE_AutoRestart

    if (!_CE_HasUnsavedChanges()) {
        _CE_Cleanup()
        gCE_Gui.Destroy()
        return
    }

    changeCount := _CE_SaveToIni()
    gCE_SavedChanges := true

    _CE_Cleanup()
    gCE_Gui.Destroy()

    ; Show message if standalone mode
    if (!gCE_AutoRestart) {
        MsgBox("Settings saved (" changeCount " changes). Restart Alt-Tabby to apply changes.", "Alt-Tabby Configuration", "OK Icon!")
    }
}

_CE_OnCancel(*) {
    global gCE_Gui

    if (_CE_HasUnsavedChanges()) {
        result := MsgBox("You have unsaved changes. Discard them?", "Alt-Tabby Configuration", "YesNo Icon?")
        if (result = "No")
            return
    }

    _CE_Cleanup()
    gCE_Gui.Destroy()
}

_CE_OnClose(guiObj) {
    if (_CE_HasUnsavedChanges()) {
        result := MsgBox("You have unsaved changes. Save before closing?", "Alt-Tabby Configuration", "YesNoCancel Icon?")
        if (result = "Cancel")
            return true  ; Prevent close
        if (result = "Yes") {
            _CE_OnSave()
            return false
        }
        ; "No" falls through to close
    }
    _CE_Cleanup()
    return false  ; Allow close
}

_CE_OnSize(guiObj, minMax, width, height) {
    global gCE_TabViewportH, gCE_ScrollPanes, gCE_CurrentSection

    if (minMax = -1)  ; Minimized
        return

    ; Resize tab control - leave room for buttons at bottom
    try {
        guiObj["Tabs"].Move(, , width - 20, height - 70)
        ; Update viewport height for scrolling calculations
        gCE_TabViewportH := height - 70 - 60  ; tab height minus headers

        ; Update scroll ranges for all panes
        for sectionName, pane in gCE_ScrollPanes {
            pane.viewportHeight := gCE_TabViewportH
        }

        ; Update scrollbar for current section
        _CE_UpdateScrollBar()
    }

    ; Move buttons to bottom right
    try {
        guiObj["BtnCancel"].Move(width - 110, height - 50)
        guiObj["BtnSave"].Move(width - 200, height - 50)
    }
}

; Handle tab change - reset scroll position when switching tabs
_CE_OnTabChange(ctrl, *) {
    global gCE_Gui, gCE_ScrollPanes, gCE_CurrentSection

    sections := _CE_GetSectionNames()
    newSection := sections[ctrl.Value]

    if (newSection = gCE_CurrentSection)
        return

    ; Reset scroll position for the tab we're leaving
    if (gCE_ScrollPanes.Has(gCE_CurrentSection)) {
        pane := gCE_ScrollPanes[gCE_CurrentSection]
        if (pane.scrollPos != 0) {
            ; Move controls back to original positions
            for item in pane.controls {
                try item.ctrl.Move(unset, item.origY, unset, unset)
            }
            pane.scrollPos := 0
        }
    }

    gCE_CurrentSection := newSection

    ; Update scrollbar for new section
    _CE_UpdateScrollBar()

    ; Force redraw to show new tab's content correctly
    DllCall("RedrawWindow", "Ptr", gCE_Gui.Hwnd, "Ptr", 0, "Ptr", 0,
            "UInt", 0x0001 | 0x0100 | 0x0080)  ; RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN
}

; Clean up before destroying main GUI
_CE_Cleanup() {
    global gCE_ScrollPanes, gCE_BoundWheelMsg, gCE_BoundScrollMsg

    if (IsSet(gCE_BoundWheelMsg) && gCE_BoundWheelMsg) {
        OnMessage(CE_WM_MOUSEWHEEL, gCE_BoundWheelMsg, 0)
        gCE_BoundWheelMsg := 0
    }
    if (IsSet(gCE_BoundScrollMsg) && gCE_BoundScrollMsg) {
        OnMessage(CE_WM_VSCROLL, gCE_BoundScrollMsg, 0)
        gCE_BoundScrollMsg := 0
    }
    gCE_ScrollPanes := Map()
}

; Perform scrolling - moves controls and refreshes display
_CE_DoScroll(deltaPixels) {
    global gCE_Gui, gCE_ScrollPanes, gCE_CurrentSection

    if (!gCE_ScrollPanes.Has(gCE_CurrentSection))
        return

    pane := gCE_ScrollPanes[gCE_CurrentSection]

    oldPos := pane.scrollPos
    maxPos := pane.contentHeight - pane.viewportHeight
    if (maxPos < 0)
        maxPos := 0

    ; Calculate new position
    newPos := pane.scrollPos + deltaPixels
    newPos := Max(0, Min(maxPos, newPos))

    if (newPos = oldPos)
        return

    pane.scrollPos := newPos

    ; Move all controls in this section
    for item in pane.controls {
        try {
            newY := item.origY - pane.scrollPos
            item.ctrl.Move(unset, newY, unset, unset)
        }
    }

    ; Update scrollbar position
    _CE_UpdateScrollPos()

    ; Force full window redraw - slow but reliable
    DllCall("RedrawWindow", "Ptr", gCE_Gui.Hwnd, "Ptr", 0, "Ptr", 0,
            "UInt", 0x0001 | 0x0100 | 0x0080)  ; RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN
}

; Handle WM_VSCROLL - scrollbar interaction
_CE_OnVScroll(wParam, lParam, msg, hwnd) {
    global gCE_Gui, gCE_ScrollPanes, gCE_CurrentSection, gCE_TabViewportH

    ; Only handle for our window
    if (hwnd != gCE_Gui.Hwnd)
        return

    ; Only scroll if current section needs it
    if (!gCE_ScrollPanes.Has(gCE_CurrentSection))
        return

    pane := gCE_ScrollPanes[gCE_CurrentSection]
    scrollCmd := wParam & 0xFFFF

    deltaPixels := 0

    switch scrollCmd {
        case CE_SB_LINEUP:
            deltaPixels := -30
        case CE_SB_LINEDOWN:
            deltaPixels := 30
        case CE_SB_PAGEUP:
            deltaPixels := -gCE_TabViewportH
        case CE_SB_PAGEDOWN:
            deltaPixels := gCE_TabViewportH
        case CE_SB_THUMBTRACK:
            ; Get thumb position from high word
            newPos := (wParam >> 16) & 0xFFFF
            deltaPixels := newPos - pane.scrollPos
    }

    if (deltaPixels != 0)
        _CE_DoScroll(deltaPixels)

    return 0
}

; Handle mouse wheel - scroll by moving controls
_CE_OnMouseWheel(wParam, lParam, msg, hwnd) {
    global gCE_Gui, gCE_ScrollPanes, gCE_CurrentSection

    ; Only scroll if current section needs it
    if (!gCE_ScrollPanes.Has(gCE_CurrentSection))
        return

    ; Only handle if mouse is over our window
    MouseGetPos(, , &winHwnd)
    if (winHwnd != gCE_Gui.Hwnd)
        return

    ; Get wheel delta (positive = scroll up, negative = scroll down)
    delta := (wParam >> 16) & 0xFFFF
    if (delta > 0x7FFF)
        delta := delta - 0x10000

    ; Convert to scroll amount - 120 units per notch, 100px per notch
    scrollAmount := -delta / 120 * 100

    _CE_DoScroll(scrollAmount)

    return 0
}
