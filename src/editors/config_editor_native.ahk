#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals

; ============================================================
; Config Editor Native - Sidebar + Viewport Pattern
; ============================================================
; Uses the viewport scroll pattern for smooth, artifact-free scrolling:
;   - Viewport GUI clips oversized page GUIs
;   - Scrolling moves entire page within viewport (single Move call)
;   - Controls never move relative to their parent
;   - Accumulated wheel delta prevents lost scroll messages
;
; Includes production logic:
;   - INI value loading/saving with format preservation
;   - WM_COPYDATA restart signal to launcher
;   - Change detection and close confirmation
; ============================================================

; ---- Constants ----
global CEN_WM_MOUSEWHEEL := 0x020A
global CEN_WM_VSCROLL := 0x0115
global CEN_SB_VERT := 1
global CEN_SIF_ALL := 0x17
global CEN_SIDEBAR_W := 210
global CEN_CONTENT_X := CEN_SIDEBAR_W
global CEN_FOOTER_H := 48
global CEN_SCROLL_STEP := 60               ; pixels per wheel notch
global CEN_SETTING_PAD := 8
global CEN_DESC_LINE_H := 15
global CEN_LABEL_W := 180
global CEN_INPUT_X := 206

; ---- State ----
global gCEN_MainGui := 0
global gCEN_Viewport := 0
global gCEN_Sidebar := 0
global gCEN_Pages := Map()
global gCEN_CurrentPage := ""
global gCEN_Sections := []
global gCEN_FooterBtns := []
global gCEN_Controls := Map()          ; Map of globalName -> {ctrl, type}
global gCEN_OriginalValues := Map()    ; Map of globalName -> original value

; Scroll accumulator - prevents lost wheel messages
global gCEN_ScrollAccum := 0
global gCEN_ScrollTimer := 0

; Message handler refs for cleanup
global gCEN_BoundWheelMsg := 0
global gCEN_BoundScrollMsg := 0

; Production state
global gCEN_SavedChanges := false
global gCEN_LauncherHwnd := 0

; ============================================================
; PUBLIC API
; ============================================================

; Run the native config editor
; launcherHwnd: HWND of launcher process for WM_COPYDATA restart signal (0 = standalone)
; Returns: true if changes were saved, false otherwise
_CE_RunNative(launcherHwnd := 0) {
    global gCEN_MainGui, gCEN_SavedChanges, gCEN_LauncherHwnd, gConfigLoaded
    global gCEN_Sections, gCEN_Pages, gCEN_Controls, gCEN_OriginalValues
    global gCEN_CurrentPage, gCEN_ScrollAccum, gCEN_ScrollTimer, gCEN_FooterBtns, gCEN_Sidebar

    gCEN_LauncherHwnd := launcherHwnd
    gCEN_SavedChanges := false

    ; Reset state for fresh invocation
    gCEN_Sections := []
    gCEN_Pages := Map()
    gCEN_Controls := Map()
    gCEN_OriginalValues := Map()
    gCEN_CurrentPage := ""
    gCEN_ScrollAccum := 0
    gCEN_ScrollTimer := 0
    gCEN_FooterBtns := []

    ; Initialize config system if not already done
    if (!gConfigLoaded)
        ConfigLoader_Init()

    ; Parse registry into sections structure
    _CEN_ParseRegistry()

    ; Build and show the GUI
    _CEN_BuildMainGUI()

    ; Load current values from INI
    _CEN_LoadValues()

    ; Show first section
    if (gCEN_Sections.Length > 0) {
        gCEN_Sidebar.Value := 1
        _CEN_SwitchToPage(gCEN_Sections[1].name)
    }

    ; Block until GUI closes
    WinWaitClose(gCEN_MainGui.Hwnd)

    return gCEN_SavedChanges
}

; ============================================================
; REGISTRY PARSING
; ============================================================

_CEN_ParseRegistry() {
    global gConfigRegistry, gCEN_Sections

    curSection := ""
    curSubsection := ""

    for entry in gConfigRegistry {
        if (entry.HasOwnProp("type") && entry.type = "section") {
            curSection := {
                name: entry.name,
                desc: entry.desc,
                long: entry.HasOwnProp("long") ? entry.long : "",
                settings: [],
                subsections: []
            }
            curSubsection := ""
            gCEN_Sections.Push(curSection)
        } else if (entry.HasOwnProp("type") && entry.type = "subsection") {
            curSubsection := {
                name: entry.name,
                desc: entry.HasOwnProp("desc") ? entry.desc : "",
                settings: []
            }
            if (curSection != "")
                curSection.subsections.Push(curSubsection)
        } else if (entry.HasOwnProp("s")) {
            setting := {
                s: entry.s,
                k: entry.k,
                g: entry.g,
                t: entry.t,
                default: entry.default,
                d: entry.d
            }
            if (entry.HasOwnProp("options"))
                setting.options := entry.options
            if (curSubsection != "" && curSubsection.HasOwnProp("name"))
                curSubsection.settings.Push(setting)
            else if (curSection != "")
                curSection.settings.Push(setting)
        }
    }
}

; ============================================================
; GUI BUILDING
; ============================================================

_CEN_BuildMainGUI() {
    global gCEN_MainGui, gCEN_Viewport, gCEN_Sidebar, gCEN_Pages, gCEN_Sections
    global gCEN_FooterBtns, gCEN_BoundWheelMsg, gCEN_BoundScrollMsg
    global CEN_WM_MOUSEWHEEL, CEN_WM_VSCROLL, CEN_SIDEBAR_W, CEN_CONTENT_X

    ; Create main window with dark theme
    gCEN_MainGui := Gui("+Resize +MinSize750x450 +0x02000000", "Alt-Tabby Configuration")
    gCEN_MainGui.BackColor := "16213e"
    gCEN_MainGui.MarginX := 0
    gCEN_MainGui.MarginY := 0
    gCEN_MainGui.SetFont("s9", "Segoe UI")

    ; Sidebar with section list
    gCEN_Sidebar := gCEN_MainGui.AddListBox("x0 y0 w" CEN_SIDEBAR_W " h400 +0x100", [])
    gCEN_Sidebar.SetFont("s10", "Segoe UI")
    items := []
    for section in gCEN_Sections
        items.Push(section.desc)
    gCEN_Sidebar.Add(items)
    gCEN_Sidebar.OnEvent("Change", _CEN_OnSidebarChange)

    ; Viewport: clipping container for scrollable content
    ; WS_CLIPCHILDREN (0x02000000) prevents viewport bg from painting over page
    ; WS_VSCROLL (0x00200000) puts the scrollbar on this container
    gCEN_Viewport := Gui("-Caption -Border +Parent" gCEN_MainGui.Hwnd " +0x02200000")
    gCEN_Viewport.BackColor := "16213e"
    gCEN_Viewport.MarginX := 0
    gCEN_Viewport.MarginY := 0
    gCEN_Viewport.Show("x" CEN_CONTENT_X " y0 w580 h500 NoActivate")

    ; Footer buttons
    btnSave := gCEN_MainGui.AddButton("x610 y460 w80 h30", "Save")
    btnCancel := gCEN_MainGui.AddButton("x520 y460 w80 h30", "Cancel")
    gCEN_FooterBtns.Push(btnSave, btnCancel)
    btnSave.OnEvent("Click", _CEN_OnSave)
    btnCancel.OnEvent("Click", _CEN_OnCancel)

    ; Build page for each section
    for section in gCEN_Sections
        _CEN_BuildPage(section)

    ; Event handlers
    gCEN_MainGui.OnEvent("Size", _CEN_OnResize)
    gCEN_MainGui.OnEvent("Close", _CEN_OnClose)

    ; Message handlers for scrolling
    gCEN_BoundWheelMsg := _CEN_OnMouseWheel
    OnMessage(CEN_WM_MOUSEWHEEL, gCEN_BoundWheelMsg)

    gCEN_BoundScrollMsg := _CEN_OnVScroll
    OnMessage(CEN_WM_VSCROLL, gCEN_BoundScrollMsg)

    ; Show window
    gCEN_MainGui.Show("w800 h550")
}

_CEN_BuildPage(section) {
    global gCEN_Viewport, gCEN_Pages, gCEN_Controls
    global CEN_SETTING_PAD, CEN_DESC_LINE_H, CEN_LABEL_W, CEN_INPUT_X

    ; Page GUI: child of viewport, sized to FULL content height
    ; Controls are placed at fixed positions - they never move
    ; Scrolling moves the entire page within the viewport
    pageGui := Gui("-Caption -Border +Parent" gCEN_Viewport.Hwnd " +0x02000000")
    pageGui.BackColor := "16213e"
    pageGui.MarginX := 0
    pageGui.MarginY := 0
    pageGui.SetFont("s9", "Segoe UI")

    controls := []
    y := 12
    contentW := 560

    ; Section title
    c := pageGui.AddText("x16 y" y " w" contentW " h26 cDDDDDD", section.desc)
    c.SetFont("s15 bold", "Segoe UI")
    controls.Push({ctrl: c, origY: y, origX: 16})
    y += 30

    ; Section long description
    if (section.long != "") {
        lines := Ceil(StrLen(section.long) / 70)
        h := Max(18, lines * CEN_DESC_LINE_H)
        c := pageGui.AddText("x16 y" y " w" contentW " h" h " c7788AA +Wrap", section.long)
        c.SetFont("s8", "Segoe UI")
        controls.Push({ctrl: c, origY: y, origX: 16})
        y += h + 8
    }

    ; Section-level settings
    y := _CEN_AddSettings(pageGui, section.settings, controls, y, contentW)

    ; Subsections
    for sub in section.subsections {
        y += 16
        ; Separator line
        c := pageGui.AddText("x16 y" y " w" contentW " h1 +0x10")
        controls.Push({ctrl: c, origY: y, origX: 16})
        y += 6
        ; Subsection title
        c := pageGui.AddText("x16 y" y " w" contentW " h20 cAAAACC", sub.name)
        c.SetFont("s10 bold", "Segoe UI")
        controls.Push({ctrl: c, origY: y, origX: 16})
        y += 22

        ; Subsection description
        if (sub.desc != "") {
            lines := Ceil(StrLen(sub.desc) / 75)
            h := Max(16, lines * CEN_DESC_LINE_H)
            c := pageGui.AddText("x20 y" y " w" (contentW - 8) " h" h " c667799 +Wrap", sub.desc)
            c.SetFont("s8 italic", "Segoe UI")
            controls.Push({ctrl: c, origY: y, origX: 20})
            y += h + 4
        }

        ; Subsection settings
        y := _CEN_AddSettings(pageGui, sub.settings, controls, y, contentW)
    }

    y += 24

    ; Store page info
    page := {gui: pageGui, controls: controls, contentH: y, scrollPos: 0}
    gCEN_Pages[section.name] := page

    ; Size to FULL content height. Viewport clips the visible portion.
    pageGui.Show("x0 y0 w580 h" y " NoActivate Hide")
}

_CEN_AddSettings(pageGui, settings, controls, y, contentW) {
    global gCEN_Controls
    global CEN_SETTING_PAD, CEN_DESC_LINE_H, CEN_LABEL_W, CEN_INPUT_X

    for setting in settings {
        y += CEN_SETTING_PAD

        descLen := StrLen(setting.d)
        descLines := Ceil(descLen / 70)
        descH := Max(CEN_DESC_LINE_H, descLines * CEN_DESC_LINE_H)

        if (setting.t = "bool") {
            cb := pageGui.AddCheckbox("x24 y" y " w" contentW " h20 cCCCCDD", setting.k)
            controls.Push({ctrl: cb, origY: y, origX: 24})
            gCEN_Controls[setting.g] := {ctrl: cb, type: "bool"}
            y += 22
            dc := pageGui.AddText("x40 y" y " w" (contentW - 24) " h" descH " c556677 +Wrap", setting.d)
            dc.SetFont("s8", "Segoe UI")
            controls.Push({ctrl: dc, origY: y, origX: 40})
            y += descH + 4

        } else if (setting.t = "enum") {
            lbl := pageGui.AddText("x24 y" y " w" CEN_LABEL_W " h20 +0x200 cBBBBCC", setting.k)
            controls.Push({ctrl: lbl, origY: y, origX: 24})
            optList := []
            if (setting.HasOwnProp("options"))
                for opt in setting.options
                    optList.Push(opt)
            dd := pageGui.AddDropDownList("x" CEN_INPUT_X " y" y " w200", optList)
            controls.Push({ctrl: dd, origY: y, origX: CEN_INPUT_X})
            gCEN_Controls[setting.g] := {ctrl: dd, type: "enum"}
            y += 26
            dc := pageGui.AddText("x24 y" y " w" contentW " h" descH " c556677 +Wrap", setting.d)
            dc.SetFont("s8", "Segoe UI")
            controls.Push({ctrl: dc, origY: y, origX: 24})
            y += descH + 4

        } else {
            lbl := pageGui.AddText("x24 y" y " w" CEN_LABEL_W " h20 +0x200 cBBBBCC", setting.k)
            controls.Push({ctrl: lbl, origY: y, origX: 24})
            ed := pageGui.AddEdit("x" CEN_INPUT_X " y" y " w200")
            controls.Push({ctrl: ed, origY: y, origX: CEN_INPUT_X})
            gCEN_Controls[setting.g] := {ctrl: ed, type: setting.t}
            y += 26
            dc := pageGui.AddText("x24 y" y " w" contentW " h" descH " c556677 +Wrap", setting.d)
            dc.SetFont("s8", "Segoe UI")
            controls.Push({ctrl: dc, origY: y, origX: 24})
            y += descH + 4
        }
    }
    return y
}

; ============================================================
; VALUE LOADING/SAVING
; ============================================================

_CEN_LoadValues() {
    global gCEN_Controls, gCEN_OriginalValues, gConfigRegistry, gConfigIniPath

    gCEN_OriginalValues := Map()

    for _, entry in gConfigRegistry {
        if (!entry.HasOwnProp("default"))
            continue
        if (!gCEN_Controls.Has(entry.g))
            continue

        ctrlInfo := gCEN_Controls[entry.g]

        ; Read from INI, fall back to default
        iniVal := IniRead(gConfigIniPath, entry.s, entry.k, "")
        if (iniVal = "") {
            val := entry.default
        } else {
            val := _CEN_ParseValue(iniVal, entry.t)
        }

        ; Set control value
        _CEN_SetControlValue(ctrlInfo, val, entry.t)

        ; Store original for change detection
        gCEN_OriginalValues[entry.g] := val
    }
}

_CEN_ParseValue(iniVal, type) {
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

_CEN_SetControlValue(ctrlInfo, val, type) {
    if (type = "bool") {
        ctrlInfo.ctrl.Value := val ? 1 : 0
    } else if (type = "enum") {
        try ctrlInfo.ctrl.Choose(String(val))
        catch
            try ctrlInfo.ctrl.Choose(1)
    } else if (type = "int" && IsNumber(val) && val > 255) {
        ctrlInfo.ctrl.Value := Format("0x{:X}", val)
    } else {
        ctrlInfo.ctrl.Value := String(val)
    }
}

_CEN_GetControlValue(ctrlInfo, type) {
    if (type = "bool") {
        return ctrlInfo.ctrl.Value ? true : false
    } else if (type = "enum") {
        return ctrlInfo.ctrl.Text
    } else if (type = "int") {
        try {
            txt := ctrlInfo.ctrl.Value
            if (SubStr(txt, 1, 2) = "0x")
                return Integer(txt)
            return Integer(txt)
        } catch {
            return 0
        }
    } else if (type = "float") {
        try {
            return Float(ctrlInfo.ctrl.Value)
        } catch {
            return 0.0
        }
    }
    return ctrlInfo.ctrl.Value
}

_CEN_HasUnsavedChanges() {
    global gCEN_Controls, gCEN_OriginalValues, gConfigRegistry

    for _, entry in gConfigRegistry {
        if (!entry.HasOwnProp("default"))
            continue
        if (!gCEN_Controls.Has(entry.g))
            continue

        ctrlInfo := gCEN_Controls[entry.g]
        currentVal := _CEN_GetControlValue(ctrlInfo, entry.t)
        originalVal := gCEN_OriginalValues[entry.g]

        if (currentVal != originalVal)
            return true
    }
    return false
}

_CEN_SaveToIni() {
    global gCEN_Controls, gCEN_OriginalValues, gConfigRegistry, gConfigIniPath

    changeCount := 0

    for _, entry in gConfigRegistry {
        if (!entry.HasOwnProp("default"))
            continue
        if (!gCEN_Controls.Has(entry.g))
            continue

        ctrlInfo := gCEN_Controls[entry.g]
        currentVal := _CEN_GetControlValue(ctrlInfo, entry.t)
        originalVal := gCEN_OriginalValues[entry.g]

        if (currentVal != originalVal) {
            _CL_WriteIniPreserveFormat(gConfigIniPath, entry.s, entry.k, currentVal, entry.default, entry.t)
            changeCount++
        }
    }

    return changeCount
}

; ============================================================
; SIDEBAR NAVIGATION
; ============================================================

_CEN_OnSidebarChange(ctrl, *) {
    global gCEN_Sections
    idx := ctrl.Value
    if (idx < 1 || idx > gCEN_Sections.Length)
        return
    _CEN_SwitchToPage(gCEN_Sections[idx].name)
}

_CEN_SwitchToPage(name) {
    global gCEN_Pages, gCEN_CurrentPage, gCEN_ScrollAccum

    if (gCEN_CurrentPage != "" && gCEN_Pages.Has(gCEN_CurrentPage))
        gCEN_Pages[gCEN_CurrentPage].gui.Hide()

    gCEN_CurrentPage := name
    gCEN_ScrollAccum := 0
    if (!gCEN_Pages.Has(name))
        return

    page := gCEN_Pages[name]
    page.scrollPos := 0
    page.gui.Move(0, 0)  ; reset to top of viewport
    _CEN_UpdateScrollBar(name)
    page.gui.Show("NoActivate")
}

; ============================================================
; SCROLL ENGINE
; ============================================================

_CEN_OnMouseWheel(wParam, lParam, msg, hwnd) {
    global gCEN_CurrentPage, gCEN_Pages, gCEN_MainGui, CEN_SIDEBAR_W
    global gCEN_ScrollAccum, gCEN_ScrollTimer

    if (gCEN_CurrentPage = "" || !gCEN_Pages.Has(gCEN_CurrentPage))
        return

    ; Hit test: only scroll if cursor is right of sidebar
    pt := Buffer(8, 0)
    DllCall("GetCursorPos", "Ptr", pt)
    DllCall("ScreenToClient", "Ptr", gCEN_MainGui.Hwnd, "Ptr", pt)
    if (NumGet(pt, 0, "Int") < CEN_SIDEBAR_W)
        return

    ; Extract signed wheel delta
    raw := (wParam >> 16) & 0xFFFF
    if (raw > 0x7FFF)
        raw -= 0x10000

    ; Accumulate (negative = scroll down = positive offset)
    gCEN_ScrollAccum -= raw

    ; Start drain timer if not running
    if (!gCEN_ScrollTimer) {
        gCEN_ScrollTimer := 1
        SetTimer(_CEN_DrainScroll, -10)
    }

    return 0
}

_CEN_DrainScroll() {
    global gCEN_ScrollAccum, gCEN_ScrollTimer, gCEN_CurrentPage, gCEN_Pages, CEN_SCROLL_STEP

    gCEN_ScrollTimer := 0

    if (gCEN_CurrentPage = "" || !gCEN_Pages.Has(gCEN_CurrentPage) || gCEN_ScrollAccum = 0) {
        gCEN_ScrollAccum := 0
        return
    }

    notches := gCEN_ScrollAccum / 120
    scrollPx := Round(notches * CEN_SCROLL_STEP)
    gCEN_ScrollAccum := 0

    if (scrollPx = 0)
        return

    page := gCEN_Pages[gCEN_CurrentPage]
    _CEN_DoScroll(page, scrollPx)
    _CEN_UpdateScrollBar(gCEN_CurrentPage)
}

_CEN_OnVScroll(wParam, lParam, msg, hwnd) {
    global gCEN_CurrentPage, gCEN_Pages, gCEN_Viewport, CEN_SCROLL_STEP

    if (gCEN_CurrentPage = "" || !gCEN_Pages.Has(gCEN_CurrentPage))
        return
    if (hwnd != gCEN_Viewport.Hwnd)
        return

    page := gCEN_Pages[gCEN_CurrentPage]
    viewH := _CEN_GetViewportHeight()
    maxScroll := Max(0, page.contentH - viewH)
    scrollCode := wParam & 0xFFFF

    switch scrollCode {
        case 0: newPos := page.scrollPos - CEN_SCROLL_STEP
        case 1: newPos := page.scrollPos + CEN_SCROLL_STEP
        case 2: newPos := page.scrollPos - viewH
        case 3: newPos := page.scrollPos + viewH
        case 5: newPos := (wParam >> 16) & 0xFFFF
        default: return
    }

    newPos := Max(0, Min(maxScroll, newPos))
    if (newPos = page.scrollPos)
        return

    _CEN_DoScroll(page, newPos - page.scrollPos)
    _CEN_UpdateScrollBar(gCEN_CurrentPage)
}

_CEN_DoScroll(page, delta) {
    newPos := page.scrollPos + delta
    viewH := _CEN_GetViewportHeight()
    maxScroll := Max(0, page.contentH - viewH)
    newPos := Max(0, Min(maxScroll, newPos))

    if (newPos = page.scrollPos)
        return

    page.scrollPos := newPos
    ; Move the entire page within the viewport - one call
    page.gui.Move(0, -newPos)
}

_CEN_UpdateScrollBar(sectionName) {
    global gCEN_Pages, gCEN_Viewport, CEN_SB_VERT, CEN_SIF_ALL

    if (!gCEN_Pages.Has(sectionName))
        return

    page := gCEN_Pages[sectionName]
    viewH := _CEN_GetViewportHeight()

    if (page.contentH <= viewH) {
        DllCall("ShowScrollBar", "Ptr", gCEN_Viewport.Hwnd, "Int", CEN_SB_VERT, "Int", 0)
        return
    }

    DllCall("ShowScrollBar", "Ptr", gCEN_Viewport.Hwnd, "Int", CEN_SB_VERT, "Int", 1)

    si := Buffer(28, 0)
    NumPut("UInt", 28, si, 0)
    NumPut("UInt", CEN_SIF_ALL, si, 4)
    NumPut("Int", 0, si, 8)
    NumPut("Int", page.contentH, si, 12)
    NumPut("UInt", viewH, si, 16)
    NumPut("Int", page.scrollPos, si, 20)

    DllCall("SetScrollInfo", "Ptr", gCEN_Viewport.Hwnd, "Int", CEN_SB_VERT, "Ptr", si, "Int", 1)
}

_CEN_GetViewportHeight() {
    global gCEN_Viewport
    gCEN_Viewport.GetPos(,, &w, &h)
    return h
}

; ============================================================
; EVENT HANDLERS
; ============================================================

_CEN_OnResize(gui, minMax, w, h) {
    global gCEN_Sidebar, gCEN_Viewport, gCEN_Pages, gCEN_CurrentPage, gCEN_FooterBtns
    global CEN_SIDEBAR_W, CEN_CONTENT_X, CEN_FOOTER_H

    if (minMax = -1)
        return

    viewportH := h - CEN_FOOTER_H
    gCEN_Sidebar.Move(0, 0, CEN_SIDEBAR_W, viewportH)

    contentW := w - CEN_CONTENT_X
    gCEN_Viewport.Move(CEN_CONTENT_X, 0, contentW, viewportH)

    ; Update page widths
    for name, page in gCEN_Pages
        page.gui.Move(0, , contentW)

    ; Move buttons
    btnY := h - CEN_FOOTER_H + 8
    if (gCEN_FooterBtns.Length >= 2) {
        gCEN_FooterBtns[1].Move(w - 100, btnY, 80, 30)
        gCEN_FooterBtns[2].Move(w - 190, btnY, 80, 30)
    }

    if (gCEN_CurrentPage != "")
        _CEN_UpdateScrollBar(gCEN_CurrentPage)
}

_CEN_OnSave(*) {
    global gCEN_MainGui, gCEN_SavedChanges, gCEN_LauncherHwnd
    global TABBY_CMD_RESTART_ALL

    if (!_CEN_HasUnsavedChanges()) {
        _CEN_Cleanup()
        gCEN_MainGui.Destroy()
        return
    }

    changeCount := _CEN_SaveToIni()
    gCEN_SavedChanges := true

    _CEN_Cleanup()
    gCEN_MainGui.Destroy()

    ; Send restart signal to launcher
    if (gCEN_LauncherHwnd && DllCall("user32\IsWindow", "ptr", gCEN_LauncherHwnd)) {
        cds := Buffer(3 * A_PtrSize, 0)
        NumPut("uptr", TABBY_CMD_RESTART_ALL, cds, 0)
        NumPut("uint", 0, cds, A_PtrSize)
        NumPut("ptr", 0, cds, 2 * A_PtrSize)

        global WM_COPYDATA
        DllCall("user32\SendMessageTimeoutW"
            , "ptr", gCEN_LauncherHwnd
            , "uint", WM_COPYDATA
            , "ptr", A_ScriptHwnd
            , "ptr", cds.Ptr
            , "uint", 0x0002
            , "uint", 3000
            , "ptr*", &response := 0
            , "ptr")
    } else {
        MsgBox("Settings saved (" changeCount " changes). Restart Alt-Tabby to apply changes.",
            "Alt-Tabby Configuration", "OK Iconi")
    }
}

_CEN_OnCancel(*) {
    global gCEN_MainGui

    if (_CEN_HasUnsavedChanges()) {
        result := MsgBox("You have unsaved changes. Discard them?", "Alt-Tabby Configuration", "YesNo Icon?")
        if (result = "No")
            return
    }

    _CEN_Cleanup()
    gCEN_MainGui.Destroy()
}

_CEN_OnClose(guiObj) {
    if (_CEN_HasUnsavedChanges()) {
        result := MsgBox("You have unsaved changes. Save before closing?", "Alt-Tabby Configuration", "YesNoCancel Icon?")
        if (result = "Cancel")
            return true  ; Prevent close
        if (result = "Yes") {
            _CEN_OnSave()
            return false
        }
    }
    _CEN_Cleanup()
    return false
}

_CEN_Cleanup() {
    global gCEN_BoundWheelMsg, gCEN_BoundScrollMsg
    global CEN_WM_MOUSEWHEEL, CEN_WM_VSCROLL
    global gCEN_Pages, gCEN_Viewport

    ; Remove message handlers
    if (gCEN_BoundWheelMsg) {
        OnMessage(CEN_WM_MOUSEWHEEL, gCEN_BoundWheelMsg, 0)
        gCEN_BoundWheelMsg := 0
    }
    if (gCEN_BoundScrollMsg) {
        OnMessage(CEN_WM_VSCROLL, gCEN_BoundScrollMsg, 0)
        gCEN_BoundScrollMsg := 0
    }

    ; Destroy page GUIs
    for name, page in gCEN_Pages {
        try page.gui.Destroy()
    }
    gCEN_Pages := Map()

    ; Destroy viewport
    if (gCEN_Viewport) {
        try gCEN_Viewport.Destroy()
        gCEN_Viewport := 0
    }
}
