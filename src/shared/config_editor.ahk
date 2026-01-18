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
; ============================================================

global gCE_Gui := 0
global gCE_Controls := Map()      ; Map of globalName -> control
global gCE_OriginalValues := Map() ; Map of globalName -> original value
global gCE_HasChanges := false
global gCE_SavedChanges := false
global gCE_AutoRestart := false

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
    global gCE_Gui, gCE_Controls, gConfigRegistry

    gCE_Controls := Map()

    gCE_Gui := Gui("+Resize +MinSize600x500", "Alt-Tabby Configuration")
    gCE_Gui.OnEvent("Close", _CE_OnClose)
    gCE_Gui.OnEvent("Size", _CE_OnSize)
    gCE_Gui.SetFont("s9", "Segoe UI")

    ; Get unique section names in order
    sections := _CE_GetSectionNames()

    ; Calculate tab height - use larger default for subsections
    tabHeight := 500

    ; Create tab control - positioned to leave room for buttons
    tabs := gCE_Gui.AddTab3("vTabs x10 y10 w680 h" tabHeight, sections)

    ; Build controls for each section
    for _, sectionName in sections {
        tabs.UseTab(sectionName)
        _CE_BuildSectionControls(sectionName)
    }

    tabs.UseTab()  ; Exit tab control

    ; Bottom buttons - positioned below tabs
    btnY := tabHeight + 25
    gCE_Gui.AddButton("vBtnSave w80 x500 y" btnY, "Save").OnEvent("Click", _CE_OnSave)
    gCE_Gui.AddButton("vBtnCancel w80 x590 y" btnY, "Cancel").OnEvent("Click", _CE_OnCancel)
}

_CE_GetSectionNames() {
    global gConfigRegistry

    ; Define order (matches config_loader.ahk)
    order := ["AltTab", "GUI", "IPC", "Tools", "Producers", "Filtering",
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

_CE_BuildSectionControls(sectionName) {
    global gCE_Gui, gCE_Controls, gConfigRegistry

    ; Start y after tab headers (2 rows of tabs = ~55px) + margin
    y := 60

    ; Find section's long description and show it
    for _, entry in gConfigRegistry {
        if (entry.HasOwnProp("type") && entry.type = "section" && entry.name = sectionName) {
            if (entry.HasOwnProp("long")) {
                gCE_Gui.SetFont("s9 italic", "Segoe UI")
                gCE_Gui.AddText("x20 y" y " w600 cGray", entry.long)
                gCE_Gui.SetFont("s9 norm", "Segoe UI")
                y += 25
            }
            break
        }
    }

    isFirst := true

    for _, entry in gConfigRegistry {
        ; Handle subsection headers
        if (entry.HasOwnProp("type") && entry.type = "subsection" && entry.section = sectionName) {
            ; Add spacing before subsection
            if (!isFirst)
                y += 12

            ; Subsection header (bold)
            gCE_Gui.SetFont("s9 bold", "Segoe UI")
            gCE_Gui.AddText("x20 y" y " w300", entry.name)
            gCE_Gui.SetFont("s9 norm", "Segoe UI")
            y += 18

            ; Subsection description (gray, italic)
            if (entry.HasOwnProp("desc")) {
                gCE_Gui.SetFont("s8 italic", "Segoe UI")
                gCE_Gui.AddText("x20 y" y " w600 cGray", entry.desc)
                gCE_Gui.SetFont("s9 norm", "Segoe UI")
                y += 16
            }

            isFirst := false
            continue
        }

        ; Skip non-settings (section headers, etc.)
        if (!entry.HasOwnProp("default"))
            continue

        ; Skip entries not in this section
        if (entry.s != sectionName)
            continue

        ; Add control based on type
        if (entry.t = "bool") {
            ; Checkbox for boolean
            ctrl := gCE_Gui.AddCheckbox("v" entry.g " x20 y" y, entry.k)
            ctrl.ToolTip := entry.d
            y += 22
        } else {
            ; Label + Edit for other types
            gCE_Gui.AddText("x20 y" y " w150", entry.k ":")
            ctrl := gCE_Gui.AddEdit("v" entry.g " x180 y" (y - 2) " w200")
            ctrl.ToolTip := entry.d
            y += 26
        }

        gCE_Controls[entry.g] := ctrl
        isFirst := false
    }
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
            ; Format for INI
            iniVal := _CE_FormatForIni(currentVal, entry.t)
            IniWrite(iniVal, gConfigIniPath, entry.s, entry.k)
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
        gCE_Gui.Destroy()
        return
    }

    changeCount := _CE_SaveToIni()
    gCE_SavedChanges := true

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

    gCE_Gui.Destroy()
}

_CE_OnClose(guiObj) {
    if (_CE_HasUnsavedChanges()) {
        result := MsgBox("You have unsaved changes. Save before closing?", "Alt-Tabby Configuration", "YesNoCancel Icon?")
        if (result = "Cancel")
            return true  ; Prevent close
        if (result = "Yes")
            _CE_OnSave()
        ; "No" falls through to close
    }
    return false  ; Allow close
}

_CE_OnSize(guiObj, minMax, width, height) {
    if (minMax = -1)  ; Minimized
        return

    ; Resize tab control - leave room for buttons at bottom
    try {
        guiObj["Tabs"].Move(, , width - 20, height - 60)
    }

    ; Move buttons to bottom right
    try {
        guiObj["BtnCancel"].Move(width - 100, height - 45)
        guiObj["BtnSave"].Move(width - 190, height - 45)
    }
}
