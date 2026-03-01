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
global CEN_CONTENT_X := CEN_SIDEBAR_W + 1  ; +1 for sidebar border pixel
global CEN_FOOTER_H := 48
global CEN_SCROLL_STEP := 60               ; Default, overridden from cfg in ConfigEditorNative_Show
global CEN_SETTING_PAD := 8
global CEN_DESC_LINE_H := 15
global CEN_LABEL_W := 180
global CEN_INPUT_X := 206
global CEN_SEARCH_H := 44                  ; header bar height (title + search)
global CEN_EM_SETCUEBANNER := 0x1501       ; Edit control: set placeholder/cue text
global CEN_EM_SETMARGINS := 0xD3           ; Edit control: set left/right margins
global CEN_EC_LEFTMARGIN := 1              ; EM_SETMARGINS: set left margin
global CEN_EC_RIGHTMARGIN := 2             ; EM_SETMARGINS: set right margin

; ---- State (single Map) ----
global gCEN := Map()

_CEN_ResetState() {
    global gCEN
    gCEN := Map()
    gCEN["MainGui"] := 0
    gCEN["Viewport"] := 0
    gCEN["Sidebar"] := 0
    gCEN["Pages"] := Map()
    gCEN["CurrentPage"] := ""
    gCEN["Sections"] := []
    gCEN["FooterBtns"] := Map()
    gCEN["ChangeLabel"] := 0
    gCEN["Controls"] := Map()
    gCEN["OriginalValues"] := Map()
    gCEN["ScrollAccum"] := 0
    gCEN["ScrollTimer"] := 0
    gCEN["BoundWheelMsg"] := 0
    gCEN["BoundScrollMsg"] := 0
    gCEN["SavedChanges"] := false
    gCEN["LauncherHwnd"] := 0
    gCEN["ThemeEntry"] := 0
    gCEN["SearchEdit"] := 0
    gCEN["SearchText"] := ""
    gCEN["SearchTimer"] := 0
    gCEN["SettingGroups"] := Map()
    gCEN["FilteredIndices"] := []
    gCEN["FlatMode"] := false
    gCEN["FlatScrollPos"] := 0
    gCEN["FlatContentH"] := 0
    gCEN["ChangeCountTimer"] := 0
    gCEN["SepHeader"] := 0
    gCEN["SepSidebar"] := 0
    gCEN["SepFooter"] := 0
}

; ============================================================
; PUBLIC API
; ============================================================

; Run the native config editor
; launcherHwnd: HWND of launcher process for WM_COPYDATA restart signal (0 = standalone)
; Returns: true if changes were saved, false otherwise
CE_RunNative(launcherHwnd := 0) {
    global gCEN, gConfigLoaded

    _CEN_ResetState()

    gCEN["LauncherHwnd"] := launcherHwnd
    gCEN["SavedChanges"] := false

    ; Initialize config system if not already done
    if (!gConfigLoaded)
        ConfigLoader_Init()

    ; Load config-driven editor constants
    global CEN_SCROLL_STEP, cfg
    CEN_SCROLL_STEP := cfg.LauncherEditorScrollStep

    ; Parse registry into sections structure
    _CEN_ParseRegistry()

    ; Build and show the GUI
    _CEN_BuildMainGUI()

    ; Load current values from INI
    _CEN_LoadValues()

    ; Show first section
    if (gCEN["Sections"].Length > 0) {
        gCEN["Sidebar"].Value := 1
        _CEN_SwitchToPage(gCEN["Sections"][1].name)
    }

    ; Everything is built and populated — reveal
    GUI_AntiFlashReveal(gCEN["MainGui"], true)

    ; Block until GUI closes
    WinWaitClose(gCEN["MainGui"].Hwnd)

    return gCEN["SavedChanges"]
}

; ============================================================
; REGISTRY PARSING
; ============================================================

_CEN_ParseRegistry() {
    global gConfigRegistry, gCEN

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
            gCEN["Sections"].Push(curSection)
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
            if (entry.HasOwnProp("min")) {
                setting.min := entry.min
                setting.max := entry.max
            }
            if (entry.HasOwnProp("fmt"))
                setting.fmt := entry.fmt
            if (curSubsection != "" && curSubsection.HasOwnProp("name"))
                curSubsection.settings.Push(setting)
            else if (curSection != "")
                curSection.settings.Push(setting)
        }
    }
}

; Estimate display lines for a description, accounting for explicit \n breaks and word wrap
_CEN_CalcDescLines(text, charsPerLine) {
    lines := 0
    Loop Parse text, "`n"
        lines += Max(1, Ceil(StrLen(A_LoopField) / charsPerLine))
    return lines
}

; ============================================================
; GUI BUILDING
; ============================================================

_CEN_BuildMainGUI() {
    global gCEN
    global CEN_WM_MOUSEWHEEL, CEN_WM_VSCROLL, CEN_SIDEBAR_W, CEN_CONTENT_X, CEN_SEARCH_H
    global CEN_EM_SETCUEBANNER, CEN_EM_SETMARGINS, CEN_EC_LEFTMARGIN, CEN_EC_RIGHTMARGIN

    ; Create main window with theme + anti-flash (DWM cloaking)
    gCEN["MainGui"] := Gui("+Resize +MinSize750x450 +0x02000000", "Alt-Tabby Configuration")
    gCEN["MainGui"].MarginX := 0
    gCEN["MainGui"].MarginY := 0
    gCEN["MainGui"].SetFont("s9", "Segoe UI")
    global gTheme_Palette
    themeEntry := Theme_ApplyToGui(gCEN["MainGui"])
    gCEN["ThemeEntry"] := themeEntry
    Theme_OnChange(_CEN_OnThemeChange)
    ; Register swatch color handler AFTER theme (last registered runs first)
    OnMessage(0x0138, _CEN_OnSwatchCtlColor)  ; lint-ignore: onmessage-collision
    ; Register WM_NOTIFY for slider custom draw
    OnMessage(0x004E, _CEN_OnWmNotify)

    ; Frame bg: panelBg (lighter) for sidebar/header/footer; content area uses bg (darker)
    gCEN["MainGui"].BackColor := gTheme_Palette.panelBg
    Theme_MarkPanel(gCEN["MainGui"])

    ; Header bar: title left, search right
    hdrTitle := gCEN["MainGui"].AddText("x20 y12 w300 h24", "Alt-Tabby Settings")
    hdrTitle.SetFont("s14 bold", "Segoe UI")
    gCEN["SearchEdit"] := gCEN["MainGui"].AddEdit("x524 y10 w260 h24")
    Theme_ApplyToControl(gCEN["SearchEdit"], "Edit", themeEntry)
    DllCall("user32\SendMessageW", "Ptr", gCEN["SearchEdit"].Hwnd, "UInt", CEN_EM_SETCUEBANNER, "Ptr", 1, "WStr", "Search settings...")
    DllCall("user32\SendMessageW", "Ptr", gCEN["SearchEdit"].Hwnd, "UInt", CEN_EM_SETMARGINS, "Ptr", CEN_EC_LEFTMARGIN | CEN_EC_RIGHTMARGIN, "Ptr", (6 << 16) | 6)
    gCEN["SearchEdit"].OnEvent("Change", _CEN_OnSearchInput)

    ; Sidebar with section list (below header border)
    sidebarY := CEN_SEARCH_H + 1  ; +1 to leave room for header border
    gCEN["Sidebar"] := gCEN["MainGui"].AddListBox("x0 y" sidebarY " w" CEN_SIDEBAR_W " h400 +0x100", [])
    gCEN["Sidebar"].SetFont("s10", "Segoe UI")
    Theme_ApplyToControl(gCEN["Sidebar"], "ListBox", themeEntry)
    Theme_MarkSidebar(gCEN["Sidebar"])
    items := []
    gCEN["FilteredIndices"] := []
    for idx, section in gCEN["Sections"] {
        items.Push("   " section.desc)
        gCEN["FilteredIndices"].Push(idx)
    }
    gCEN["Sidebar"].Add(items)
    gCEN["Sidebar"].OnEvent("Change", _CEN_OnSidebarChange)

    ; Viewport: clipping container for scrollable content
    ; WS_CLIPCHILDREN (0x02000000) prevents viewport bg from painting over page
    ; WS_VSCROLL (0x00200000) puts the scrollbar on this container
    gCEN["Viewport"] := Gui("-Caption -Border +Parent" gCEN["MainGui"].Hwnd " +0x02200000")
    gCEN["Viewport"].BackColor := gTheme_Palette.bg
    gCEN["Viewport"].MarginX := 0
    gCEN["Viewport"].MarginY := 0
    Theme_ApplyToWindow(gCEN["Viewport"].Hwnd)
    viewportY := CEN_SEARCH_H + 1  ; +1 to leave room for header border
    gCEN["Viewport"].Show("x" CEN_CONTENT_X " y" viewportY " w580 h466 NoActivate")

    ; Border separators (1px child GUIs in gaps between zones)
    ; Positioned in 1px gaps so they're never covered by sibling controls
    borderColor := gTheme_Palette.border
    sepMiddleY := CEN_SEARCH_H + 1  ; sidebar/viewport start here
    gCEN["SepHeader"] := Gui("-Caption -Border +Parent" gCEN["MainGui"].Hwnd)
    gCEN["SepHeader"].BackColor := borderColor
    gCEN["SepHeader"].MarginX := 0
    gCEN["SepHeader"].MarginY := 0
    gCEN["SepHeader"].Show("x0 y" CEN_SEARCH_H " w800 h1 NoActivate")
    gCEN["SepSidebar"] := Gui("-Caption -Border +Parent" gCEN["MainGui"].Hwnd)
    gCEN["SepSidebar"].BackColor := borderColor
    gCEN["SepSidebar"].MarginX := 0
    gCEN["SepSidebar"].MarginY := 0
    gCEN["SepSidebar"].Show("x" CEN_SIDEBAR_W " y" sepMiddleY " w1 h400 NoActivate")
    gCEN["SepFooter"] := Gui("-Caption -Border +Parent" gCEN["MainGui"].Hwnd)
    gCEN["SepFooter"].BackColor := borderColor
    gCEN["SepFooter"].MarginX := 0
    gCEN["SepFooter"].MarginY := 0
    gCEN["SepFooter"].Show("x0 y501 w800 h1 NoActivate")

    ; Footer: change counter (left) + buttons (right)
    gCEN["ChangeLabel"] := gCEN["MainGui"].AddText("x16 y468 w300 h20 +0x200 c" Theme_GetAccentColor(), "")
    Theme_MarkAccent(gCEN["ChangeLabel"])
    btnReset := gCEN["MainGui"].AddButton("x490 y460 w120 h30", "Reset to Defaults")
    btnSave := gCEN["MainGui"].AddButton("x620 y460 w80 h30", "Save")
    btnCancel := gCEN["MainGui"].AddButton("x710 y460 w80 h30", "Cancel")
    gCEN["FooterBtns"]["Save"] := btnSave
    gCEN["FooterBtns"]["Cancel"] := btnCancel
    gCEN["FooterBtns"]["Reset"] := btnReset
    btnReset.OnEvent("Click", _CEN_OnResetDefaults)
    btnSave.OnEvent("Click", _CEN_OnSave)
    btnCancel.OnEvent("Click", _CEN_OnCancel)
    Theme_ApplyToControl(btnReset, "Button", themeEntry)
    Theme_ApplyToControl(btnSave, "Button", themeEntry)
    Theme_ApplyToControl(btnCancel, "Button", themeEntry)

    ; Build page for each section
    for section in gCEN["Sections"]
        _CEN_BuildPage(section)

    ; Event handlers
    gCEN["MainGui"].OnEvent("Size", _CEN_OnResize)
    gCEN["MainGui"].OnEvent("Close", _CEN_OnClose)

    ; Message handlers for scrolling
    gCEN["BoundWheelMsg"] := _CEN_OnMouseWheel
    OnMessage(CEN_WM_MOUSEWHEEL, gCEN["BoundWheelMsg"])  ; lint-ignore: onmessage-collision

    gCEN["BoundScrollMsg"] := _CEN_OnVScroll
    OnMessage(CEN_WM_VSCROLL, gCEN["BoundScrollMsg"])

    ; Change counter timer (updates title bar every 500ms)
    gCEN["ChangeCountTimer"] := 1
    SetTimer(_CEN_UpdateChangeCount, 500)

    GUI_AntiFlashPrepare(gCEN["MainGui"], gTheme_Palette.panelBg)
    gCEN["MainGui"].Show("w800 h550")
}

_CEN_BuildPage(section) {
    global gCEN
    global CEN_SETTING_PAD, CEN_DESC_LINE_H, CEN_LABEL_W, CEN_INPUT_X

    ; Page GUI: child of viewport, sized to FULL content height
    ; Controls are placed at fixed positions - they never move
    ; Scrolling moves the entire page within the viewport
    global gTheme_Palette
    pageGui := Gui("-Caption -Border +Parent" gCEN["Viewport"].Hwnd " +0x02000000")
    pageGui.BackColor := gTheme_Palette.bg
    pageGui.MarginX := 0
    pageGui.MarginY := 0
    pageGui.SetFont("s9 c" gTheme_Palette.text, "Segoe UI")

    controls := []
    blocks := []      ; block-based tracking for search reflow
    y := 12
    contentW := 560

    ; Header block (section title + long desc) - always visible during search
    headerCtrls := []

    ; Section title (+0x80 = SS_NOPREFIX, prevents & from becoming accelerator)
    c := pageGui.AddText("x16 y" y " w" contentW " h26 +0x80 c" gTheme_Palette.text, section.desc)
    c.SetFont("s15 bold", "Segoe UI")
    controls.Push({ctrl: c, origY: y, origX: 16})
    headerCtrls.Push({ctrl: c, origY: y, origX: 16})
    y += 30

    ; Section long description (accent color to match WebView editor)
    if (section.long != "") {
        lines := _CEN_CalcDescLines(section.long, 70)
        h := Max(18, lines * CEN_DESC_LINE_H)
        c := pageGui.AddText("x16 y" y " w" contentW " h" h " c" gTheme_Palette.accent " +Wrap", section.long)
        c.SetFont("s8", "Segoe UI")
        Theme_MarkAccent(c)
        controls.Push({ctrl: c, origY: y, origX: 16})
        headerCtrls.Push({ctrl: c, origY: y, origX: 16})
        y += h + 8
    }

    blocks.Push({kind: "header", startY: 12, ctrls: headerCtrls})

    ; Section-level settings (subIdx = 0)
    y := _CEN_AddSettings(pageGui, section.settings, controls, blocks, y, contentW, section.name, 0)

    ; Subsections
    subIdx := 0
    for sub in section.subsections {
        subIdx++
        subStart := y
        subCtrls := []

        y += 16
        ; Separator line
        c := pageGui.AddText("x16 y" y " w" contentW " h1 +0x10")
        controls.Push({ctrl: c, origY: y, origX: 16})
        subCtrls.Push({ctrl: c, origY: y, origX: 16})
        y += 6
        ; Subsection title (+0x80 = SS_NOPREFIX)
        c := pageGui.AddText("x16 y" y " w" contentW " h20 +0x80 c" gTheme_Palette.text, sub.name)
        c.SetFont("s10 bold", "Segoe UI")
        controls.Push({ctrl: c, origY: y, origX: 16})
        subCtrls.Push({ctrl: c, origY: y, origX: 16})
        y += 22

        ; Subsection description
        if (sub.desc != "") {
            lines := _CEN_CalcDescLines(sub.desc, 75)
            h := Max(16, lines * CEN_DESC_LINE_H)
            c := pageGui.AddText("x20 y" y " w" (contentW - 8) " h" h " c" Theme_GetMutedColor() " +Wrap", sub.desc)
            c.SetFont("s8 italic", "Segoe UI")
            Theme_MarkMuted(c)
            controls.Push({ctrl: c, origY: y, origX: 20})
            subCtrls.Push({ctrl: c, origY: y, origX: 20})
            y += h + 4
        }

        blocks.Push({kind: "subsection", startY: subStart, ctrls: subCtrls, subIdx: subIdx})

        ; Subsection settings
        y := _CEN_AddSettings(pageGui, sub.settings, controls, blocks, y, contentW, section.name, subIdx)
    }

    y += 24

    ; Compute endY for each block from the next block's startY
    for i, block in blocks {
        if (i < blocks.Length)
            block.endY := blocks[i + 1].startY
        else
            block.endY := y
    }

    ; Store page info
    page := {gui: pageGui, controls: controls, blocks: blocks, contentH: y, origContentH: y, scrollPos: 0}
    gCEN["Pages"][section.name] := page

    ; Size to FULL content height. Viewport clips the visible portion.
    pageGui.Show("x0 y0 w580 h" y " NoActivate Hide")
}

_CEN_AddSettings(pageGui, settings, controls, blocks, y, contentW, sectionName, subIdx) {
    global gCEN, gTheme_Palette, gCEN_SwatchHwnds, gCEN_SwatchSubclassPtr, gCEN_SliderHwnds, gCEN_SliderSubclassPtr
    global CEN_SETTING_PAD, CEN_DESC_LINE_H, CEN_LABEL_W, CEN_INPUT_X
    global CEN_EM_SETMARGINS, CEN_EC_LEFTMARGIN, CEN_EC_RIGHTMARGIN

    mutedColor := Theme_GetMutedColor()

    for setting in settings {
        startY := y
        settingCtrls := []

        y += CEN_SETTING_PAD

        descLines := _CEN_CalcDescLines(setting.d, 70)
        descH := Max(CEN_DESC_LINE_H, descLines * CEN_DESC_LINE_H)

        if (setting.t = "bool") {
            cb := pageGui.AddCheckbox("x24 y" y " w" contentW " h20 c" gTheme_Palette.text, setting.k)
            cb.SetFont("s9 bold", "Segoe UI")
            controls.Push({ctrl: cb, origY: y, origX: 24})
            settingCtrls.Push({ctrl: cb, origY: y, origX: 24})
            gCEN["Controls"][setting.g] := {ctrl: cb, type: "bool"}
            Theme_ApplyToControl(cb, "Checkbox", gCEN["ThemeEntry"])
            y += 22
            dc := pageGui.AddText("x40 y" y " w" (contentW - 24) " h" descH " c" mutedColor " +Wrap", setting.d)
            dc.SetFont("s8", "Segoe UI")
            Theme_MarkMuted(dc)
            controls.Push({ctrl: dc, origY: y, origX: 40})
            settingCtrls.Push({ctrl: dc, origY: y, origX: 40})
            y += descH + 4

        } else if (setting.t = "enum") {
            lbl := pageGui.AddText("x24 y" y " w" CEN_LABEL_W " h20 +0x200 c" gTheme_Palette.text, setting.k)
            lbl.SetFont("s9 bold", "Segoe UI")
            controls.Push({ctrl: lbl, origY: y, origX: 24})
            settingCtrls.Push({ctrl: lbl, origY: y, origX: 24})
            optList := []
            if (setting.HasOwnProp("options"))
                for opt in setting.options
                    optList.Push(opt)
            dd := pageGui.AddDropDownList("x" CEN_INPUT_X " y" y " w200", optList)
            controls.Push({ctrl: dd, origY: y, origX: CEN_INPUT_X})
            settingCtrls.Push({ctrl: dd, origY: y, origX: CEN_INPUT_X})
            gCEN["Controls"][setting.g] := {ctrl: dd, type: "enum"}
            Theme_ApplyToControl(dd, "DDL", gCEN["ThemeEntry"])
            y += 26
            dc := pageGui.AddText("x24 y" y " w" contentW " h" descH " c" mutedColor " +Wrap", setting.d)
            dc.SetFont("s8", "Segoe UI")
            Theme_MarkMuted(dc)
            controls.Push({ctrl: dc, origY: y, origX: 24})
            settingCtrls.Push({ctrl: dc, origY: y, origX: 24})
            y += descH + 4

        } else if (setting.HasOwnProp("dynamicOptions") && setting.dynamicOptions = "SHADER_KEYS") {
            global SHADER_KEYS, SHADER_NAMES ; lint-ignore: phantom-global
            lbl := pageGui.AddText("x24 y" y " w" CEN_LABEL_W " h20 +0x200 c" gTheme_Palette.text, setting.k)
            lbl.SetFont("s9 bold", "Segoe UI")
            controls.Push({ctrl: lbl, origY: y, origX: 24})
            settingCtrls.Push({ctrl: lbl, origY: y, origX: 24})
            ; Build display-name list from SHADER_NAMES (skip index 1 = "None")
            optList := []
            optKeys := []
            Loop SHADER_KEYS.Length {
                if (SHADER_KEYS[A_Index] != "") {
                    optList.Push(SHADER_NAMES[A_Index])
                    optKeys.Push(SHADER_KEYS[A_Index])
                }
            }
            dd := pageGui.AddDropDownList("x" CEN_INPUT_X " y" y " w200", optList)
            controls.Push({ctrl: dd, origY: y, origX: CEN_INPUT_X})
            settingCtrls.Push({ctrl: dd, origY: y, origX: CEN_INPUT_X})
            gCEN["Controls"][setting.g] := {ctrl: dd, type: "dynamicEnum", keys: optKeys, labels: optList}
            Theme_ApplyToControl(dd, "DDL", gCEN["ThemeEntry"])
            y += 26
            dc := pageGui.AddText("x24 y" y " w" contentW " h" descH " c" mutedColor " +Wrap", setting.d)
            dc.SetFont("s8", "Segoe UI")
            Theme_MarkMuted(dc)
            controls.Push({ctrl: dc, origY: y, origX: 24})
            settingCtrls.Push({ctrl: dc, origY: y, origX: 24})
            y += descH + 4

        } else {
            lbl := pageGui.AddText("x24 y" y " w" CEN_LABEL_W " h20 +0x200 c" gTheme_Palette.text, setting.k)
            lbl.SetFont("s9 bold", "Segoe UI")
            controls.Push({ctrl: lbl, origY: y, origX: 24})
            settingCtrls.Push({ctrl: lbl, origY: y, origX: 24})

            isHex := setting.HasOwnProp("fmt") && setting.fmt = "hex"
            hasRange := setting.HasOwnProp("min")
            useUpDown := hasRange && setting.t = "int" && !isHex

            if (useUpDown) {
                ; Integer with range, not hex -> Slider + Edit + UpDown + range label
                sliderX := CEN_INPUT_X
                slider := pageGui.AddSlider("x" sliderX " y" y " w120 h24 +0x10 Range" setting.min "-" setting.max)
                controls.Push({ctrl: slider, origY: y, origX: sliderX})
                settingCtrls.Push({ctrl: slider, origY: y, origX: sliderX})
                Theme_ApplyToControl(slider, "Slider", gCEN["ThemeEntry"])
                gCEN_SliderHwnds[slider.Hwnd] := true
                DllCall("uxtheme\SetWindowTheme", "Ptr", slider.Hwnd, "Str", "", "Ptr", 0)
                DllCall("comctl32\SetWindowSubclass", "Ptr", slider.Hwnd, "Ptr", gCEN_SliderSubclassPtr, "UPtr", slider.Hwnd, "UPtr", 0)
                editX := sliderX + 126
                ed := pageGui.AddEdit("x" editX " y" y " w80 Number")
                controls.Push({ctrl: ed, origY: y, origX: editX})
                settingCtrls.Push({ctrl: ed, origY: y, origX: editX})
                ud := pageGui.AddUpDown("Range" setting.min "-" setting.max)
                controls.Push({ctrl: ud, origY: y, origX: editX})
                settingCtrls.Push({ctrl: ud, origY: y, origX: editX})
                Theme_ApplyToControl(ed, "Edit", gCEN["ThemeEntry"])
                Theme_ApplyToControl(ud, "UpDown", gCEN["ThemeEntry"])
                DllCall("user32\SendMessageW", "Ptr", ed.Hwnd, "UInt", CEN_EM_SETMARGINS, "Ptr", CEN_EC_LEFTMARGIN | CEN_EC_RIGHTMARGIN, "Ptr", (6 << 16) | 6)
                rangeX := editX + 86
                rc := pageGui.AddText("x" rangeX " y" (y + 3) " w120 h16 c" mutedColor, setting.min " - " setting.max)
                rc.SetFont("s7 italic", "Segoe UI")
                Theme_MarkMuted(rc)
                controls.Push({ctrl: rc, origY: y, origX: rangeX})
                settingCtrls.Push({ctrl: rc, origY: y, origX: rangeX})
                ; Sync slider <-> edit with guard to prevent infinite loop
                syncGuard := {v: false}
                boundSliderSync := _CEN_MakeSliderSyncHandler(ed, syncGuard)
                boundEditSync := _CEN_MakeEditSyncHandler(slider, syncGuard)
                slider.OnEvent("Change", boundSliderSync)
                ed.OnEvent("Change", boundEditSync)
                ctrlInfo := {ctrl: ed, type: setting.t, slider: slider}
                gCEN["Controls"][setting.g] := ctrlInfo
            } else {
                ; Float, hex, string, or no range -> plain Edit
                ed := pageGui.AddEdit("x" CEN_INPUT_X " y" y " w200")
                controls.Push({ctrl: ed, origY: y, origX: CEN_INPUT_X})
                settingCtrls.Push({ctrl: ed, origY: y, origX: CEN_INPUT_X})
                ctrlInfo := {ctrl: ed, type: setting.t}
                if (isHex)
                    ctrlInfo.fmt := "hex"
                gCEN["Controls"][setting.g] := ctrlInfo
                Theme_ApplyToControl(ed, "Edit", gCEN["ThemeEntry"])
                DllCall("user32\SendMessageW", "Ptr", ed.Hwnd, "UInt", CEN_EM_SETMARGINS, "Ptr", CEN_EC_LEFTMARGIN | CEN_EC_RIGHTMARGIN, "Ptr", (6 << 16) | 6)

                ; Clamp-on-blur for float/hex with range
                if (hasRange && (setting.t = "float" || isHex)) {
                    boundClamp := _CEN_MakeClampHandler(setting.g, setting.min, setting.max)
                    ed.OnEvent("LoseFocus", boundClamp)
                }

                ; Color swatch for hex fields with color component (max > 0xFF)
                if (isHex && setting.HasOwnProp("max") && setting.max > 0xFF) {
                    swatchX := CEN_INPUT_X + 206
                    ; Text control with subclass WM_PAINT for checkerboard+alpha
                    sw := pageGui.AddText("x" swatchX " y" y " w28 h22 +0x100", "")
                    ; +0x100 = SS_NOTIFY (enables Click)
                    gCEN_SwatchHwnds[sw.Hwnd] := true
                    DllCall("comctl32\SetWindowSubclass", "Ptr", sw.Hwnd, "Ptr", gCEN_SwatchSubclassPtr, "UPtr", sw.Hwnd, "UPtr", 0)
                    controls.Push({ctrl: sw, origY: y, origX: swatchX})
                    settingCtrls.Push({ctrl: sw, origY: y, origX: swatchX})
                    ctrlInfo.swatch := sw
                    ctrlInfo.isARGB := (setting.max > 0xFFFFFF)
                    ctrlInfo.hexSyncGuard := {v: false}
                    sw.OnEvent("Click", _CEN_MakeColorPickHandler(setting.g))
                    ed.OnEvent("Change", _CEN_MakeHexChangeHandler(setting.g))

                    ; Alpha slider for ARGB fields (max > 0xFFFFFF)
                    if (setting.max > 0xFFFFFF) {
                        alphaX := swatchX + 34
                        alphaSlider := pageGui.AddSlider("x" alphaX " y" y " w70 h24 +0x10 Range0-100")
                        controls.Push({ctrl: alphaSlider, origY: y, origX: alphaX})
                        settingCtrls.Push({ctrl: alphaSlider, origY: y, origX: alphaX})
                        Theme_ApplyToControl(alphaSlider, "Slider", gCEN["ThemeEntry"])
                        gCEN_SliderHwnds[alphaSlider.Hwnd] := true
                        DllCall("uxtheme\SetWindowTheme", "Ptr", alphaSlider.Hwnd, "Str", "", "Ptr", 0)
                        DllCall("comctl32\SetWindowSubclass", "Ptr", alphaSlider.Hwnd, "Ptr", gCEN_SliderSubclassPtr, "UPtr", alphaSlider.Hwnd, "UPtr", 0)
                        alphaLblX := alphaX + 74
                        alphaLbl := pageGui.AddText("x" alphaLblX " y" (y + 3) " w36 h16 c" mutedColor, "100%")
                        alphaLbl.SetFont("s7", "Segoe UI")
                        Theme_MarkMuted(alphaLbl)
                        controls.Push({ctrl: alphaLbl, origY: y + 3, origX: alphaLblX})
                        settingCtrls.Push({ctrl: alphaLbl, origY: y + 3, origX: alphaLblX})
                        ctrlInfo.alphaSlider := alphaSlider
                        ctrlInfo.alphaLabel := alphaLbl
                        alphaSlider.OnEvent("Change", _CEN_MakeAlphaSliderHandler(setting.g))
                    }
                }
            }

            y += 26
            dc := pageGui.AddText("x24 y" y " w" contentW " h" descH " c" mutedColor " +Wrap", setting.d)
            dc.SetFont("s8", "Segoe UI")
            Theme_MarkMuted(dc)
            controls.Push({ctrl: dc, origY: y, origX: 24})
            settingCtrls.Push({ctrl: dc, origY: y, origX: 24})
            y += descH

            ; Range hint for float/hex (UpDown shows its own range natively)
            ; Skip for hex fields with color swatch — the swatch+picker replaces the label
            hasSwatch := isHex && setting.HasOwnProp("max") && setting.max > 0xFF
            if (hasRange && !useUpDown && !hasSwatch) {
                if (isHex)
                    rangeText := Format("Range: 0x{:X} - 0x{:X}", setting.min, setting.max)
                else if (setting.t = "float")
                    rangeText := Format("Range: {:.2f} - {:.2f}", setting.min, setting.max)
                else
                    rangeText := ""
                if (rangeText != "") {
                    rc := pageGui.AddText("x40 y" y " w" (contentW - 24) " h14 c" mutedColor, rangeText)
                    rc.SetFont("s7 italic", "Segoe UI")
                    Theme_MarkMuted(rc)
                    controls.Push({ctrl: rc, origY: y, origX: 40})
                    settingCtrls.Push({ctrl: rc, origY: y, origX: 40})
                    y += 16
                }
            }
            y += 4
        }

        ; Track this setting's controls as a block for search reflow
        blocks.Push({kind: "setting", startY: startY, ctrls: settingCtrls, globalName: setting.g, subIdx: subIdx})
        gCEN["SettingGroups"][setting.g] := {pageKey: sectionName, searchText: StrLower(setting.k " " setting.g " " setting.d), subIdx: subIdx}
    }
    return y
}

; ============================================================
; VALUE LOADING/SAVING
; ============================================================

_CEN_LoadValues() {
    global gCEN, gConfigRegistry, gConfigIniPath

    gCEN["OriginalValues"] := Map()

    for _, entry in gConfigRegistry {
        if (!entry.HasOwnProp("default"))
            continue
        if (!gCEN["Controls"].Has(entry.g))
            continue

        ctrlInfo := gCEN["Controls"][entry.g]

        ; Read from INI, fall back to default
        iniVal := IniRead(gConfigIniPath, entry.s, entry.k, "")
        if (iniVal = "") {
            val := entry.default
        } else {
            val := CL_ParseValue(iniVal, entry.t)
        }

        ; Set control value
        _CEN_SetControlValue(ctrlInfo, val, entry.t)

        ; Store original for change detection
        gCEN["OriginalValues"][entry.g] := val
    }
}

_CEN_SetControlValue(ctrlInfo, val, type) {
    ; Guard to prevent Change handler loops
    if (ctrlInfo.HasOwnProp("hexSyncGuard"))
        ctrlInfo.hexSyncGuard.v := true

    if (type = "bool") {
        ctrlInfo.ctrl.Value := val ? 1 : 0
    } else if (ctrlInfo.type = "dynamicEnum") {
        ; Map key string to display label for dropdown selection
        chosen := false
        if (ctrlInfo.HasOwnProp("keys")) {
            Loop ctrlInfo.keys.Length {
                if (ctrlInfo.keys[A_Index] = val) {
                    try ctrlInfo.ctrl.Choose(A_Index)
                    chosen := true
                    break
                }
            }
        }
        if (!chosen)
            try ctrlInfo.ctrl.Choose(1)
    } else if (type = "enum") {
        try ctrlInfo.ctrl.Choose(String(val))
        catch
            try ctrlInfo.ctrl.Choose(1)
    } else if (ctrlInfo.HasOwnProp("fmt") && ctrlInfo.fmt = "hex") {
        ctrlInfo.ctrl.Value := Format("0x{:X}", val)
    } else if (type = "float") {
        ctrlInfo.ctrl.Value := Format("{:.6g}", val)
    } else {
        ctrlInfo.ctrl.Value := String(val)
    }
    if (ctrlInfo.HasOwnProp("slider"))
        try ctrlInfo.slider.Value := Integer(val)
    if (ctrlInfo.HasOwnProp("swatch")) {
        rgb := val & 0xFFFFFF
        swAlpha := (ctrlInfo.HasOwnProp("isARGB") && ctrlInfo.isARGB) ? ((val >> 24) & 0xFF) : 255
        _CEN_UpdateSwatchColor(ctrlInfo.swatch, rgb, swAlpha)
    }
    if (ctrlInfo.HasOwnProp("alphaSlider")) {
        alpha := (val >> 24) & 0xFF
        pct := Round(alpha / 255 * 100)
        try ctrlInfo.alphaSlider.Value := pct
        if (ctrlInfo.HasOwnProp("alphaLabel"))
            try ctrlInfo.alphaLabel.Value := pct "%"
    }

    if (ctrlInfo.HasOwnProp("hexSyncGuard"))
        ctrlInfo.hexSyncGuard.v := false
}

; Create a clamp-on-blur handler bound to a specific setting's range
_CEN_MakeClampHandler(globalName, minVal, maxVal) {
    return (ctrl, *) => _CEN_ClampOnBlur(globalName, minVal, maxVal)
}

; Create a handler that syncs slider value -> edit control
_CEN_MakeSliderSyncHandler(editCtrl, guard) {
    return (ctrl, *) => _CEN_SyncSliderToEdit(ctrl, editCtrl, guard)
}

_CEN_SyncSliderToEdit(sliderCtrl, editCtrl, guard) {
    if (guard.v)
        return
    guard.v := true
    try editCtrl.Value := sliderCtrl.Value
    guard.v := false
    ; Force full repaint so channel fill covers entire track (chunk-clicks only invalidate partial areas)
    DllCall("InvalidateRect", "Ptr", sliderCtrl.Hwnd, "Ptr", 0, "Int", 0)
}

; Create a handler that syncs edit value -> slider control
_CEN_MakeEditSyncHandler(sliderCtrl, guard) {
    return (ctrl, *) => _CEN_SyncEditToSlider(ctrl, sliderCtrl, guard)
}

_CEN_SyncEditToSlider(editCtrl, sliderCtrl, guard) {
    if (guard.v)
        return
    guard.v := true
    try sliderCtrl.Value := Integer(editCtrl.Value)
    guard.v := false
}

; ---- Slider Hover Fix ----
; DarkMode_Explorer slider thumbs have a nearly-black hover color.
; Use NM_CUSTOMDRAW to paint the thumb in accent colors on hover/press.

; WM_NOTIFY handler for slider NM_CUSTOMDRAW (same technique as mock_dark_controls.ahk)
_CEN_OnWmNotify(wParam, lParam, msg, hwnd) {  ; lint-ignore: mixed-returns (OnMessage: bare return = default handling) ; lint-ignore: dead-param
    global gCEN_SliderHwnds
    code := NumGet(lParam, 16, "Int")   ; NMHDR.code (offset 16 on x64: hwndFrom=8 + idFrom=8)
    if (code != -12)  ; NM_CUSTOMDRAW
        return
    hwndFrom := NumGet(lParam, 0, "Ptr")
    if (!gCEN_SliderHwnds.Has(hwndFrom))
        return
    return _CEN_DrawSlider(hwndFrom, lParam)
}

_CEN_DrawSlider(sliderHwnd, lParam) {
    global gTheme_Palette
    ; Use exact same offsets as working mock (hardcoded, verified on x64)
    stage := NumGet(lParam, 24, "UInt")

    if (stage = 0x01)   ; CDDS_PREPAINT
        return 0x20     ; CDRF_NOTIFYITEMDRAW

    if (stage != 0x10001) ; CDDS_ITEMPREPAINT
        return 0

    hdc   := NumGet(lParam, 32, "Ptr")
    left  := NumGet(lParam, 40, "Int")
    top   := NumGet(lParam, 44, "Int")
    right := NumGet(lParam, 48, "Int")
    bottom := NumGet(lParam, 52, "Int")
    part  := NumGet(lParam, 56, "UPtr")       ; TBCD_CHANNEL=3, TBCD_THUMB=2, TBCD_TICS=1
    itemState := NumGet(lParam, 64, "UInt")   ; CDIS_HOT=0x40, CDIS_SELECTED=0x01

    accentClr := Theme_ColorToInt(gTheme_Palette.accent)

    if (part = 3) {  ; TBCD_CHANNEL — two-tone fill aligned to actual thumb position
        ; Use TBM_GETTHUMBRECT for pixel-accurate fill
        thumbRect := Buffer(16)
        SendMessage(0x0419, 0, thumbRect.Ptr, sliderHwnd)  ; TBM_GETTHUMBRECT
        thumbCenter := (NumGet(thumbRect, 0, "Int") + NumGet(thumbRect, 8, "Int")) >> 1
        ; Clamp split point to channel bounds
        splitX := (thumbCenter < left) ? left : (thumbCenter > right) ? right : thumbCenter

        if (splitX > left) {
            fb := DllCall("CreateSolidBrush", "UInt", accentClr, "Ptr")
            frc := Buffer(16)
            NumPut("Int", left, "Int", top, "Int", splitX, "Int", bottom, frc)
            DllCall("FillRect", "Ptr", hdc, "Ptr", frc, "Ptr", fb)
            DllCall("DeleteObject", "Ptr", fb)
        }
        if (splitX < right) {
            gutterClr := Theme_IsDark() ? 0x4D4D4D : 0xCCCCCC
            eb := DllCall("CreateSolidBrush", "UInt", gutterClr, "Ptr")
            erc := Buffer(16)
            NumPut("Int", splitX, "Int", top, "Int", right, "Int", bottom, erc)
            DllCall("FillRect", "Ptr", hdc, "Ptr", erc, "Ptr", eb)
            DllCall("DeleteObject", "Ptr", eb)
        }
        return 0x04  ; CDRF_SKIPDEFAULT
    }

    if (part = 2) {  ; TBCD_THUMB — always custom-draw (normal, hover, pressed)
        if (itemState & 0x01)       ; CDIS_SELECTED (pressed)
            thumbClr := Theme_ColorToInt(gTheme_Palette.accentHover)
        else
            thumbClr := accentClr   ; Normal and hover = accent blue

        thumbBrush := DllCall("CreateSolidBrush", "UInt", thumbClr, "Ptr")
        thumbPen := DllCall("CreatePen", "Int", 0, "Int", 1, "UInt", thumbClr, "Ptr")
        old1 := DllCall("SelectObject", "Ptr", hdc, "Ptr", thumbPen, "Ptr")
        old2 := DllCall("SelectObject", "Ptr", hdc, "Ptr", thumbBrush, "Ptr")
        DllCall("Ellipse", "Ptr", hdc, "Int", left, "Int", top, "Int", right, "Int", bottom)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", old1, "Ptr")
        DllCall("SelectObject", "Ptr", hdc, "Ptr", old2, "Ptr")
        DllCall("DeleteObject", "Ptr", thumbPen)
        DllCall("DeleteObject", "Ptr", thumbBrush)
        return 0x04  ; CDRF_SKIPDEFAULT
    }

    return 0  ; CDRF_DODEFAULT for tics
}

; ---- Color Swatch / Picker ----

; Static buffer for ChooseColorW custom colors (16 COLORREFs = 64 bytes)
global gCEN_CustomColors := Buffer(64, 0)

; Swatch state: subclass WM_PAINT draws checkerboard + AlphaBlend
global gCEN_SwatchHwnds := Map()   ; hwnd -> true
global gCEN_SwatchColors := Map()  ; hwnd -> colorRef (BGR)
global gCEN_SwatchAlphas := Map()  ; hwnd -> alpha 0-255

; Slider HWNDs for WM_NOTIFY custom draw
global gCEN_SliderHwnds := Map()  ; hwnd -> true

; Subclass callbacks
global gCEN_SliderSubclassPtr := CallbackCreate(_CEN_SliderSubclassProc, , 6)
global gCEN_SwatchSubclassPtr := CallbackCreate(_CEN_SwatchSubclassProc, , 6)

_CEN_SliderSubclassProc(hwnd, uMsg, wParam, lParam, uIdSubclass, dwRefData) { ; lint-ignore: dead-param
    global gCEN_SliderSubclassPtr, gTheme_Palette
    if (uMsg = 0x0014) {  ; WM_ERASEBKGND — fill with page bg instead of white
        rc := Buffer(16)
        DllCall("GetClientRect", "Ptr", hwnd, "Ptr", rc)
        hBrush := DllCall("CreateSolidBrush", "UInt", Theme_ColorToInt(gTheme_Palette.bg), "Ptr")
        DllCall("FillRect", "Ptr", wParam, "Ptr", rc, "Ptr", hBrush)
        DllCall("DeleteObject", "Ptr", hBrush)
        return 1
    }
    if (uMsg = 0x0082) {  ; WM_NCDESTROY — clean up subclass
        DllCall("comctl32\RemoveWindowSubclass", "Ptr", hwnd, "Ptr", gCEN_SliderSubclassPtr, "UPtr", uIdSubclass)
    }
    return DllCall("comctl32\DefSubclassProc", "Ptr", hwnd, "UInt", uMsg, "Ptr", wParam, "Ptr", lParam, "Ptr")
}

; Swatch subclass: WM_PAINT draws checkerboard + AlphaBlend overlay
_CEN_SwatchSubclassProc(hwnd, uMsg, wParam, lParam, uIdSubclass, dwRefData) { ; lint-ignore: dead-param
    global gCEN_SwatchSubclassPtr, gCEN_SwatchColors, gCEN_SwatchAlphas, gTheme_Palette

    if (uMsg = 0x000F) {  ; WM_PAINT
        ps := Buffer(72, 0)
        hdc := DllCall("BeginPaint", "Ptr", hwnd, "Ptr", ps, "Ptr")
        rc := Buffer(16)
        DllCall("GetClientRect", "Ptr", hwnd, "Ptr", rc)
        w := NumGet(rc, 8, "Int")
        h := NumGet(rc, 12, "Int")

        colorRef := gCEN_SwatchColors.Get(hwnd, 0)
        alpha := gCEN_SwatchAlphas.Get(hwnd, 255)

        ; Step 1: Draw checkerboard (visible through semi-transparent color)
        static CLR_CHECK1 := 0xC0C0C0, CLR_CHECK2 := 0x808080
        checkSize := 5
        hBr1 := DllCall("CreateSolidBrush", "UInt", CLR_CHECK1, "Ptr")
        hBr2 := DllCall("CreateSolidBrush", "UInt", CLR_CHECK2, "Ptr")
        cellRc := Buffer(16)
        row := 0
        cy := 0
        while (cy < h) {
            col := 0
            cx := 0
            while (cx < w) {
                x2 := (cx + checkSize < w) ? cx + checkSize : w
                y2 := (cy + checkSize < h) ? cy + checkSize : h
                NumPut("Int", cx, cellRc, 0)
                NumPut("Int", cy, cellRc, 4)
                NumPut("Int", x2, cellRc, 8)
                NumPut("Int", y2, cellRc, 12)
                DllCall("FillRect", "Ptr", hdc, "Ptr", cellRc, "Ptr", (Mod(row + col, 2) = 0) ? hBr1 : hBr2)
                cx += checkSize
                col++
            }
            cy += checkSize
            row++
        }
        DllCall("DeleteObject", "Ptr", hBr1)
        DllCall("DeleteObject", "Ptr", hBr2)

        ; Step 2: AlphaBlend the color overlay
        if (alpha > 0) {
            memDC := DllCall("CreateCompatibleDC", "Ptr", hdc, "Ptr")
            bmi := Buffer(44, 0)
            NumPut("UInt", 40, bmi, 0)
            NumPut("Int", w, bmi, 4)
            NumPut("Int", -h, bmi, 8)  ; top-down
            NumPut("UShort", 1, bmi, 12)
            NumPut("UShort", 32, bmi, 14)
            ppvBits := 0
            hBmp := DllCall("CreateDIBSection", "Ptr", memDC, "Ptr", bmi, "UInt", 0,
                "Ptr*", &ppvBits, "Ptr", 0, "UInt", 0, "Ptr")
            oldBmp := DllCall("SelectObject", "Ptr", memDC, "Ptr", hBmp, "Ptr")
            ; Premultiplied ARGB pixel (colorRef is BGR: 0x00BBGGRR)
            rr := colorRef & 0xFF
            gg := (colorRef >> 8) & 0xFF
            bb := (colorRef >> 16) & 0xFF
            pixel := (alpha << 24) | (((rr * alpha) // 255) << 16) | (((gg * alpha) // 255) << 8) | ((bb * alpha) // 255)
            totalPixels := w * h
            offset := 0
            loop totalPixels {
                NumPut("UInt", pixel, ppvBits + offset)
                offset += 4
            }
            ; BLENDFUNCTION: AC_SRC_OVER=0, flags=0, SCA=255, AC_SRC_ALPHA=1
            DllCall("msimg32\AlphaBlend", "Ptr", hdc, "Int", 0, "Int", 0, "Int", w, "Int", h,
                "Ptr", memDC, "Int", 0, "Int", 0, "Int", w, "Int", h, "UInt", (1 << 24) | (255 << 16))
            DllCall("SelectObject", "Ptr", memDC, "Ptr", oldBmp)
            DllCall("DeleteObject", "Ptr", hBmp)
            DllCall("DeleteDC", "Ptr", memDC)
        }

        ; Step 3: Border
        hPen := DllCall("CreatePen", "Int", 0, "Int", 1, "UInt", 0x555555, "Ptr")
        oldPen := DllCall("SelectObject", "Ptr", hdc, "Ptr", hPen, "Ptr")
        oldBr := DllCall("SelectObject", "Ptr", hdc, "Ptr", DllCall("GetStockObject", "Int", 5, "Ptr"), "Ptr")
        DllCall("Rectangle", "Ptr", hdc, "Int", 0, "Int", 0, "Int", w, "Int", h)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", oldPen)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", oldBr)
        DllCall("DeleteObject", "Ptr", hPen)

        DllCall("EndPaint", "Ptr", hwnd, "Ptr", ps)
        return 0
    }
    if (uMsg = 0x0014)  ; WM_ERASEBKGND
        return 1
    if (uMsg = 0x0082)  ; WM_NCDESTROY
        DllCall("comctl32\RemoveWindowSubclass", "Ptr", hwnd, "Ptr", gCEN_SwatchSubclassPtr, "UPtr", uIdSubclass)
    return DllCall("comctl32\DefSubclassProc", "Ptr", hwnd, "UInt", uMsg, "Ptr", wParam, "Ptr", lParam, "Ptr")
}

; Update swatch color + alpha and trigger repaint
_CEN_UpdateSwatchColor(swCtrl, rgb, alpha := 255) {
    global gCEN_SwatchColors, gCEN_SwatchAlphas
    hwnd := swCtrl.Hwnd
    gCEN_SwatchColors[hwnd] := Theme_RgbToColorRef(rgb)
    gCEN_SwatchAlphas[hwnd] := alpha
    DllCall("InvalidateRect", "Ptr", hwnd, "Ptr", 0, "Int", 0)
}

; WM_CTLCOLORSTATIC handler: swatches return nothing (subclass handles paint)
_CEN_OnSwatchCtlColor(wParam, lParam, msg, hwnd) { ; lint-ignore: dead-param
    global gCEN_SwatchHwnds
    if (!gCEN_SwatchHwnds.Has(lParam))
        return  ; Fall through to theme handler
    ; Swatch painting is handled by subclass WM_PAINT; skip theme handler
    return
}

; Open Win32 ChooseColor dialog. Returns RGB (0xRRGGBB) or -1 on cancel.
_CEN_OpenColorPicker(currentRGB, ownerHwnd := 0) {
    global gCEN_CustomColors
    colorRef := Theme_RgbToColorRef(currentRGB)

    ; CHOOSECOLOR struct: fixed layout DWORD + HWND + HWND + COLORREF + LPCOLORREF + DWORD + LPARAM + ptr + ptr
    cc := Buffer(A_PtrSize = 8 ? 72 : 36, 0)
    NumPut("UInt", cc.Size, cc, 0)                          ; lStructSize
    NumPut("Ptr", ownerHwnd, cc, A_PtrSize)                 ; hwndOwner
    ; hInstance = 0 (offset 2*A_PtrSize)
    off := 3 * A_PtrSize
    NumPut("UInt", colorRef, cc, off)                        ; rgbResult
    NumPut("Ptr", gCEN_CustomColors.Ptr, cc, off + A_PtrSize) ; lpCustColors
    ; Flags: CC_FULLOPEN (2) | CC_RGBINIT (1) = 3
    NumPut("UInt", 3, cc, off + 2 * A_PtrSize)              ; Flags

    result := DllCall("comdlg32\ChooseColorW", "Ptr", cc.Ptr, "Int")
    if (!result)
        return -1

    resultRef := NumGet(cc, off, "UInt")
    return Theme_ColorRefToRgb(resultRef)
}

; Create closure for swatch click -> color picker
_CEN_MakeColorPickHandler(globalName) {
    return (ctrl, *) => _CEN_OnSwatchClick(globalName)
}

_CEN_OnSwatchClick(globalName) {
    global gCEN
    if (!gCEN["Controls"].Has(globalName))
        return
    ctrlInfo := gCEN["Controls"][globalName]
    ; Get current value
    val := _CEN_GetControlValue(ctrlInfo, "int")
    currentRGB := val & 0xFFFFFF

    ownerHwnd := 0
    try ownerHwnd := gCEN["MainGui"].Hwnd

    newRGB := _CEN_OpenColorPicker(currentRGB, ownerHwnd)
    if (newRGB = -1)
        return

    ; Combine: preserve alpha for ARGB, replace RGB
    if (ctrlInfo.HasOwnProp("isARGB") && ctrlInfo.isARGB) {
        alpha := (val >> 24) & 0xFF
        newVal := (alpha << 24) | newRGB
    } else {
        newVal := newRGB
    }

    _CEN_SetControlValue(ctrlInfo, newVal, "int")
}

; Create closure for hex edit change -> swatch + alpha sync
_CEN_MakeHexChangeHandler(globalName) {
    return (ctrl, *) => _CEN_OnHexEditChange(globalName)
}

_CEN_OnHexEditChange(globalName) {
    global gCEN
    if (!gCEN["Controls"].Has(globalName))
        return
    ctrlInfo := gCEN["Controls"][globalName]
    if (ctrlInfo.HasOwnProp("hexSyncGuard") && ctrlInfo.hexSyncGuard.v)
        return
    val := _CEN_GetControlValue(ctrlInfo, "int")
    ; Update swatch color + alpha
    if (ctrlInfo.HasOwnProp("swatch")) {
        rgb := val & 0xFFFFFF
        swAlpha := (ctrlInfo.HasOwnProp("isARGB") && ctrlInfo.isARGB) ? ((val >> 24) & 0xFF) : 255
        _CEN_UpdateSwatchColor(ctrlInfo.swatch, rgb, swAlpha)
    }
    ; Update alpha slider
    if (ctrlInfo.HasOwnProp("alphaSlider")) {
        alpha := (val >> 24) & 0xFF
        pct := Round(alpha / 255 * 100)
        try ctrlInfo.alphaSlider.Value := pct
        if (ctrlInfo.HasOwnProp("alphaLabel"))
            try ctrlInfo.alphaLabel.Value := pct "%"
    }
}

; Create closure for alpha slider -> hex edit sync
_CEN_MakeAlphaSliderHandler(globalName) {
    return (ctrl, *) => _CEN_OnAlphaSliderChange(globalName)
}

_CEN_OnAlphaSliderChange(globalName) {
    global gCEN
    if (!gCEN["Controls"].Has(globalName))
        return
    ctrlInfo := gCEN["Controls"][globalName]
    if (!ctrlInfo.HasOwnProp("alphaSlider"))
        return
    pct := ctrlInfo.alphaSlider.Value
    alpha := Round(pct / 100 * 255)
    ; Read current value and replace alpha byte
    val := _CEN_GetControlValue(ctrlInfo, "int")
    rgb := val & 0xFFFFFF
    newVal := (alpha << 24) | rgb
    ; Set edit with guard to prevent loop
    ctrlInfo.hexSyncGuard.v := true
    ctrlInfo.ctrl.Value := Format("0x{:X}", newVal)
    ctrlInfo.hexSyncGuard.v := false
    ; Update alpha label
    if (ctrlInfo.HasOwnProp("alphaLabel"))
        try ctrlInfo.alphaLabel.Value := pct "%"
    ; Update swatch with new alpha
    if (ctrlInfo.HasOwnProp("swatch"))
        _CEN_UpdateSwatchColor(ctrlInfo.swatch, rgb, alpha)
    ; Force full repaint so channel fill covers entire track
    DllCall("InvalidateRect", "Ptr", ctrlInfo.alphaSlider.Hwnd, "Ptr", 0, "Int", 0)
}

_CEN_ClampOnBlur(globalName, minVal, maxVal) {
    global gCEN
    if (!gCEN["Controls"].Has(globalName))
        return
    ctrlInfo := gCEN["Controls"][globalName]
    val := _CEN_GetControlValue(ctrlInfo, ctrlInfo.type)
    if (val < minVal)
        val := minVal
    else if (val > maxVal)
        val := maxVal
    _CEN_SetControlValue(ctrlInfo, val, ctrlInfo.type)
}

_CEN_GetControlValue(ctrlInfo, type) {
    if (ctrlInfo.type = "dynamicEnum") {
        ; Map selected dropdown index back to registry key string
        idx := ctrlInfo.ctrl.Value
        if (idx >= 1 && idx <= ctrlInfo.keys.Length)
            return ctrlInfo.keys[idx]
        return ""
    } else if (type = "bool") {
        return ctrlInfo.ctrl.Value ? true : false
    } else if (type = "enum") {
        return ctrlInfo.ctrl.Text
    } else if (type = "int") {
        try {
            txt := String(ctrlInfo.ctrl.Value)
            ; Hex fields: ensure "0x" prefix so bare hex like "FF" parses correctly
            if (ctrlInfo.HasOwnProp("fmt") && ctrlInfo.fmt = "hex") {
                if (SubStr(txt, 1, 2) != "0x")
                    txt := "0x" txt
            }
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
    return _CEN_GetChangedValues().Count > 0
}

_CEN_SaveToIni() {
    return CL_SaveChanges(_CEN_GetChangedValues())  ; Returns {saved: N, failed: N}
}

; Collect all control values that differ from their original (loaded) values
_CEN_GetChangedValues() {
    global gCEN, gConfigRegistry

    changes := Map()
    for _, entry in gConfigRegistry {
        if (!entry.HasOwnProp("default"))
            continue
        if (!gCEN["Controls"].Has(entry.g))
            continue

        ctrlInfo := gCEN["Controls"][entry.g]
        currentVal := _CEN_GetControlValue(ctrlInfo, entry.t)
        originalVal := gCEN["OriginalValues"][entry.g]

        if (currentVal != originalVal)
            changes[entry.g] := currentVal
    }
    return changes
}

; ============================================================
; SIDEBAR NAVIGATION
; ============================================================

_CEN_OnSidebarChange(ctrl, *) {
    global gCEN
    idx := ctrl.Value
    if (idx < 1 || idx > gCEN["FilteredIndices"].Length)
        return
    realIdx := gCEN["FilteredIndices"][idx]
    if (realIdx < 1 || realIdx > gCEN["Sections"].Length)
        return
    if (gCEN["FlatMode"])
        _CEN_ScrollToFlatSection(gCEN["Sections"][realIdx].name)
    else
        _CEN_SwitchToPage(gCEN["Sections"][realIdx].name)
}

_CEN_SwitchToPage(name) {
    global gCEN

    if (gCEN["CurrentPage"] != "" && gCEN["Pages"].Has(gCEN["CurrentPage"]))
        gCEN["Pages"][gCEN["CurrentPage"]].gui.Hide()

    gCEN["CurrentPage"] := name
    gCEN["ScrollAccum"] := 0
    if (!gCEN["Pages"].Has(name))
        return

    page := gCEN["Pages"][name]
    page.scrollPos := 0
    page.gui.Move(0, 0)  ; reset to top of viewport
    _CEN_UpdateScrollBar(name)
    page.gui.Show("NoActivate")
}

; ============================================================
; SCROLL ENGINE
; ============================================================

_CEN_OnMouseWheel(wParam, lParam, msg, hwnd) {  ; lint-ignore: mixed-returns (OnMessage: bare return = default handling) ; lint-ignore: dead-param
    global gCEN
    global CEN_SIDEBAR_W

    if (gCEN["CurrentPage"] = "" || !gCEN["Pages"].Has(gCEN["CurrentPage"]))
        return

    ; Hit test: only scroll if cursor is right of sidebar
    pt := Buffer(8, 0)
    DllCall("GetCursorPos", "Ptr", pt)
    DllCall("ScreenToClient", "Ptr", gCEN["MainGui"].Hwnd, "Ptr", pt)
    if (NumGet(pt, 0, "Int") < CEN_SIDEBAR_W)
        return

    ; Extract signed wheel delta
    raw := (wParam >> 16) & 0xFFFF
    if (raw > 0x7FFF)
        raw -= 0x10000

    ; Accumulate (negative = scroll down = positive offset)
    gCEN["ScrollAccum"] -= raw

    ; Start drain timer if not running
    if (!gCEN["ScrollTimer"]) {
        gCEN["ScrollTimer"] := 1
        SetTimer(_CEN_DrainScroll, -10)
    }

    return 0
}

_CEN_DrainScroll() {
    global gCEN
    global CEN_SCROLL_STEP

    gCEN["ScrollTimer"] := 0

    if (gCEN["ScrollAccum"] = 0) {
        return
    }

    notches := gCEN["ScrollAccum"] / 120
    scrollPx := Round(notches * CEN_SCROLL_STEP)
    gCEN["ScrollAccum"] := 0

    if (scrollPx = 0)
        return

    if (gCEN["FlatMode"]) {
        _CEN_DoFlatScroll(scrollPx)
    } else {
        if (gCEN["CurrentPage"] = "" || !gCEN["Pages"].Has(gCEN["CurrentPage"]))
            return
        page := gCEN["Pages"][gCEN["CurrentPage"]]
        _CEN_DoScroll(page, scrollPx)
    }
    _CEN_UpdateScrollBar(gCEN["CurrentPage"])
}

_CEN_OnVScroll(wParam, lParam, msg, hwnd) { ; lint-ignore: dead-param
    global gCEN
    global CEN_SCROLL_STEP

    if (hwnd != gCEN["Viewport"].Hwnd)
        return

    viewH := _CEN_GetViewportHeight()

    if (gCEN["FlatMode"]) {
        scrollPos := gCEN["FlatScrollPos"]
        maxScroll := Max(0, gCEN["FlatContentH"] - viewH)
    } else {
        if (gCEN["CurrentPage"] = "" || !gCEN["Pages"].Has(gCEN["CurrentPage"]))
            return
        page := gCEN["Pages"][gCEN["CurrentPage"]]
        scrollPos := page.scrollPos
        maxScroll := Max(0, page.contentH - viewH)
    }

    scrollCode := wParam & 0xFFFF
    switch scrollCode {
        case 0: newPos := scrollPos - CEN_SCROLL_STEP
        case 1: newPos := scrollPos + CEN_SCROLL_STEP
        case 2: newPos := scrollPos - viewH
        case 3: newPos := scrollPos + viewH
        case 5: newPos := (wParam >> 16) & 0xFFFF
        default: return
    }

    newPos := Max(0, Min(maxScroll, newPos))
    if (newPos = scrollPos)
        return

    if (gCEN["FlatMode"]) {
        gCEN["FlatScrollPos"] := newPos
        _CEN_PositionFlatPages()
    } else {
        _CEN_DoScroll(page, newPos - page.scrollPos)
    }
    _CEN_UpdateScrollBar(gCEN["CurrentPage"])
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
    global gCEN
    global CEN_SB_VERT, CEN_SIF_ALL

    viewH := _CEN_GetViewportHeight()

    if (gCEN["FlatMode"]) {
        contentH := gCEN["FlatContentH"]
        scrollPos := gCEN["FlatScrollPos"]
    } else {
        if (!gCEN["Pages"].Has(sectionName))
            return
        page := gCEN["Pages"][sectionName]
        contentH := page.contentH
        scrollPos := page.scrollPos
    }

    if (contentH <= viewH) {
        DllCall("ShowScrollBar", "Ptr", gCEN["Viewport"].Hwnd, "Int", CEN_SB_VERT, "Int", 0)
        return
    }

    DllCall("ShowScrollBar", "Ptr", gCEN["Viewport"].Hwnd, "Int", CEN_SB_VERT, "Int", 1)

    si := Buffer(28, 0)
    NumPut("UInt", 28, si, 0)
    NumPut("UInt", CEN_SIF_ALL, si, 4)
    NumPut("Int", 0, si, 8)
    NumPut("Int", contentH, si, 12)
    NumPut("UInt", viewH, si, 16)
    NumPut("Int", scrollPos, si, 20)

    DllCall("SetScrollInfo", "Ptr", gCEN["Viewport"].Hwnd, "Int", CEN_SB_VERT, "Ptr", si, "Int", 1)
}

_CEN_GetViewportHeight() {
    global gCEN
    gCEN["Viewport"].GetPos(,, &w, &h)
    return h
}

; ============================================================
; EVENT HANDLERS
; ============================================================

_CEN_OnResize(gui, minMax, w, h) { ; lint-ignore: dead-param
    global gCEN
    global CEN_SIDEBAR_W, CEN_CONTENT_X, CEN_FOOTER_H, CEN_SEARCH_H

    if (minMax = -1)
        return

    ; Middle row starts 1px below header border, ends 1px above footer border
    middleY := CEN_SEARCH_H + 1
    viewportH := h - CEN_FOOTER_H - middleY - 1  ; -1 for footer border pixel
    gCEN["SearchEdit"].Move(w - 276, 10, 260)
    gCEN["Sidebar"].Move(0, middleY, CEN_SIDEBAR_W, viewportH)

    contentW := w - CEN_CONTENT_X
    gCEN["Viewport"].Move(CEN_CONTENT_X, middleY, contentW, viewportH)

    ; Reposition border separators (in 1px gaps between zones)
    try gCEN["SepHeader"].Move(0, CEN_SEARCH_H, w, 1)
    try gCEN["SepSidebar"].Move(CEN_SIDEBAR_W, middleY, 1, viewportH)
    try gCEN["SepFooter"].Move(0, h - CEN_FOOTER_H - 1, w, 1)

    ; Update page widths
    for _, page in gCEN["Pages"]
        page.gui.Move(0, , contentW)

    ; Move footer: change label (left) + buttons (right)
    btnY := h - CEN_FOOTER_H + 8
    if (gCEN["ChangeLabel"])
        gCEN["ChangeLabel"].Move(16, btnY + 5, 300, 20)
    if (gCEN["FooterBtns"].Count >= 3) {
        gCEN["FooterBtns"]["Cancel"].Move(w - 100, btnY, 80, 30)
        gCEN["FooterBtns"]["Save"].Move(w - 190, btnY, 80, 30)
        gCEN["FooterBtns"]["Reset"].Move(w - 320, btnY, 120, 30)
    }

    if (gCEN["CurrentPage"] != "")
        _CEN_UpdateScrollBar(gCEN["CurrentPage"])
}

_CEN_OnSave(*) {
    global gCEN

    if (!_CEN_HasUnsavedChanges()) {
        _CEN_Cleanup()
        gCEN["MainGui"].Destroy()
        return
    }

    result := _CEN_SaveToIni()

    ; Check for write failures before proceeding
    if (result.failed > 0) {
        if (result.saved = 0) {
            ThemeMsgBox("Could not save settings — the config file may be`n"
                "read-only, locked by another program, or on a full disk.`n`n"
                "No changes were written.",
                "Alt-Tabby Configuration", "Iconx")
            return  ; Don't close editor — let user retry or cancel
        }
        ThemeMsgBox(result.saved " setting(s) saved, but " result.failed " failed to write.`n`n"
            "The config file may be partially locked or the disk may be full.",
            "Alt-Tabby Configuration", "Icon!")
    }

    gCEN["SavedChanges"] := true

    _CEN_Cleanup()
    gCEN["MainGui"].Destroy()
}

_CEN_OnCancel(*) {
    global gCEN

    if (_CEN_HasUnsavedChanges()) {
        result := ThemeMsgBox("You have unsaved changes. Discard them?", "Alt-Tabby Configuration", "YesNo Icon?")
        if (result = "No")
            return
    }

    _CEN_Cleanup()
    gCEN["MainGui"].Destroy()
}

_CEN_OnClose(guiObj) { ; lint-ignore: dead-param
    if (_CEN_HasUnsavedChanges()) {
        result := ThemeMsgBox("You have unsaved changes. Save before closing?", "Alt-Tabby Configuration", "YesNoCancel Icon?")
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

_CEN_OnThemeChange() {
    global gCEN, gTheme_Palette
    ; Re-override main GUI bg (frame = panelBg, content = bg)
    try gCEN["MainGui"].BackColor := gTheme_Palette.panelBg
    try {
        gCEN["Viewport"].BackColor := gTheme_Palette.bg
        Theme_ApplyToWindow(gCEN["Viewport"].Hwnd)
    }
    for _, page in gCEN["Pages"] {
        try page.gui.BackColor := gTheme_Palette.bg
    }
    ; Update border separator colors
    try gCEN["SepHeader"].BackColor := gTheme_Palette.border
    try gCEN["SepSidebar"].BackColor := gTheme_Palette.border
    try gCEN["SepFooter"].BackColor := gTheme_Palette.border
}

_CEN_Cleanup() {
    global gCEN
    global CEN_WM_MOUSEWHEEL, CEN_WM_VSCROLL

    ; Stop timers
    if (gCEN["ChangeCountTimer"]) {
        SetTimer(_CEN_UpdateChangeCount, 0)
        gCEN["ChangeCountTimer"] := 0
    }
    if (gCEN["SearchTimer"]) {
        SetTimer(_CEN_DoSearch, 0)
        gCEN["SearchTimer"] := 0
    }

    ; Untrack GUI from theme system
    if (gCEN["MainGui"]) {
        try Theme_UntrackGui(gCEN["MainGui"])
    }
    gCEN["ThemeEntry"] := 0

    ; Clean up swatch/slider state and handlers
    global gCEN_SwatchHwnds, gCEN_SwatchColors, gCEN_SwatchAlphas, gCEN_SliderHwnds
    gCEN_SwatchHwnds := Map()
    gCEN_SwatchColors := Map()
    gCEN_SwatchAlphas := Map()
    gCEN_SliderHwnds := Map()
    OnMessage(0x0138, _CEN_OnSwatchCtlColor, 0)
    OnMessage(0x004E, _CEN_OnWmNotify, 0)

    ; Remove message handlers
    if (gCEN["BoundWheelMsg"]) {
        OnMessage(CEN_WM_MOUSEWHEEL, gCEN["BoundWheelMsg"], 0)
        gCEN["BoundWheelMsg"] := 0
    }
    if (gCEN["BoundScrollMsg"]) {
        OnMessage(CEN_WM_VSCROLL, gCEN["BoundScrollMsg"], 0)
        gCEN["BoundScrollMsg"] := 0
    }
    ; Destroy page GUIs
    for _, page in gCEN["Pages"] {
        try page.gui.Destroy()
    }
    gCEN["Pages"] := Map()

    ; Destroy border separators
    if (gCEN["SepHeader"]) {
        try gCEN["SepHeader"].Destroy()
        gCEN["SepHeader"] := 0
    }
    if (gCEN["SepSidebar"]) {
        try gCEN["SepSidebar"].Destroy()
        gCEN["SepSidebar"] := 0
    }
    if (gCEN["SepFooter"]) {
        try gCEN["SepFooter"].Destroy()
        gCEN["SepFooter"] := 0
    }

    ; Destroy viewport
    if (gCEN["Viewport"]) {
        try gCEN["Viewport"].Destroy()
        gCEN["Viewport"] := 0
    }
}

; ============================================================
; SEARCH
; ============================================================

_CEN_OnSearchInput(ctrl, *) { ; lint-ignore: dead-param
    global gCEN
    if (gCEN["SearchTimer"])
        SetTimer(_CEN_DoSearch, 0)
    gCEN["SearchTimer"] := 1
    SetTimer(_CEN_DoSearch, -200)
}

_CEN_DoSearch() {
    global gCEN
    gCEN["SearchTimer"] := 0
    newText := StrLower(Trim(gCEN["SearchEdit"].Value))
    if (newText = gCEN["SearchText"])
        return
    gCEN["SearchText"] := newText
    _CEN_ApplySearch()
}

_CEN_ApplySearch() {
    global gCEN

    searchText := gCEN["SearchText"]

    ; Reflow all pages (show/hide settings based on search)
    for name, page in gCEN["Pages"]
        _CEN_ReflowPage(page, searchText)

    ; Build filtered section indices (sections with matching settings)
    gCEN["FilteredIndices"] := []
    for idx, section in gCEN["Sections"] {
        if (searchText = "" || _CEN_SectionHasMatch(section.name, searchText))
            gCEN["FilteredIndices"].Push(idx)
    }

    gCEN["Sidebar"].Delete()

    if (searchText != "") {
        ; Search active: single "Search Results" label in sidebar
        matchCount := 0
        for _, group in gCEN["SettingGroups"] {
            if (InStr(group.searchText, searchText))
                matchCount++
        }
        if (matchCount > 0)
            gCEN["Sidebar"].Add(["   Search Results (" matchCount ")"])
        else
            gCEN["Sidebar"].Add(["   No results"])
        gCEN["Sidebar"].Value := 1

        if (gCEN["FilteredIndices"].Length > 0) {
            ; FLAT MODE: show all matching pages stacked
            gCEN["FlatMode"] := true
            gCEN["FlatScrollPos"] := 0
            for name, page in gCEN["Pages"]
                page.gui.Hide()
            totalH := 0
            for _, idx in gCEN["FilteredIndices"] {
                section := gCEN["Sections"][idx]
                if (!gCEN["Pages"].Has(section.name))
                    continue
                page := gCEN["Pages"][section.name]
                page.gui.Show("NoActivate")
                totalH += page.contentH
            }
            gCEN["FlatContentH"] := totalH
            _CEN_PositionFlatPages()
        } else {
            if (gCEN["FlatMode"]) {
                gCEN["FlatMode"] := false
                for name, page in gCEN["Pages"]
                    page.gui.Hide()
            }
        }
    } else {
        ; No search: restore normal section sidebar
        items := []
        for _, idx in gCEN["FilteredIndices"]
            items.Push("   " gCEN["Sections"][idx].desc)
        gCEN["Sidebar"].Add(items)

        ; NORMAL MODE: single page view
        if (gCEN["FlatMode"]) {
            gCEN["FlatMode"] := false
            for name, page in gCEN["Pages"]
                page.gui.Hide()
        }
        if (gCEN["FilteredIndices"].Length > 0) {
            selIdx := 1
            for i, realIdx in gCEN["FilteredIndices"] {
                if (gCEN["CurrentPage"] != "" && gCEN["Sections"][realIdx].name = gCEN["CurrentPage"]) {
                    selIdx := i
                    break
                }
            }
            gCEN["Sidebar"].Value := selIdx
            realIdx := gCEN["FilteredIndices"][selIdx]
            _CEN_SwitchToPage(gCEN["Sections"][realIdx].name)
        }
    }

    _CEN_UpdateScrollBar(gCEN["CurrentPage"])
}

_CEN_SectionHasMatch(sectionName, searchText) {
    global gCEN
    for _, group in gCEN["SettingGroups"] {
        if (group.pageKey = sectionName && InStr(group.searchText, searchText))
            return true
    }
    return false
}

_CEN_ReflowPage(page, searchText) {
    global gCEN

    if (searchText = "") {
        ; Restore all controls to original positions
        for block in page.blocks {
            for c in block.ctrls {
                c.ctrl.Move(c.origX, c.origY)
                c.ctrl.Visible := true
            }
        }
        page.contentH := page.origContentH
        page.gui.Move(, , , page.origContentH)
        return
    }

    ; Find matching settings and which subsections have matches
    matchSettings := Map()
    matchSubs := Map()
    for block in page.blocks {
        if (block.kind != "setting")
            continue
        if (!gCEN["SettingGroups"].Has(block.globalName))
            continue
        group := gCEN["SettingGroups"][block.globalName]
        if (InStr(group.searchText, searchText)) {
            matchSettings[block.globalName] := true
            if (block.subIdx > 0)
                matchSubs[block.subIdx] := true
        }
    }

    ; Reflow: hide non-matching blocks, shift visible blocks up
    offset := 0
    for block in page.blocks {
        visible := false
        if (block.kind = "header")
            visible := true
        else if (block.kind = "subsection")
            visible := matchSubs.Has(block.subIdx)
        else if (block.kind = "setting")
            visible := matchSettings.Has(block.globalName)

        if (visible) {
            for c in block.ctrls {
                c.ctrl.Move(c.origX, c.origY - offset)
                c.ctrl.Visible := true
            }
        } else {
            for c in block.ctrls
                c.ctrl.Visible := false
            offset += block.endY - block.startY
        }
    }

    page.contentH := page.origContentH - offset
    page.gui.Move(, , , Max(1, page.contentH))
}

; ============================================================
; FLAT MODE (stacked pages for search results)
; ============================================================

; Position all visible pages stacked vertically based on flat scroll position
_CEN_PositionFlatPages() {
    global gCEN

    y := 0
    for _, idx in gCEN["FilteredIndices"] {
        section := gCEN["Sections"][idx]
        if (!gCEN["Pages"].Has(section.name))
            continue
        page := gCEN["Pages"][section.name]
        page.gui.Move(0, y - gCEN["FlatScrollPos"])
        y += page.contentH
    }
    gCEN["FlatContentH"] := y
}

; Scroll within flat mode
_CEN_DoFlatScroll(delta) {
    global gCEN

    viewH := _CEN_GetViewportHeight()
    maxScroll := Max(0, gCEN["FlatContentH"] - viewH)
    newPos := Max(0, Min(maxScroll, gCEN["FlatScrollPos"] + delta))
    if (newPos = gCEN["FlatScrollPos"])
        return
    gCEN["FlatScrollPos"] := newPos
    _CEN_PositionFlatPages()
}

; Scroll flat view to a specific section (sidebar click)
_CEN_ScrollToFlatSection(targetName) {
    global gCEN

    y := 0
    for _, idx in gCEN["FilteredIndices"] {
        section := gCEN["Sections"][idx]
        if (section.name = targetName) {
            gCEN["FlatScrollPos"] := y
            _CEN_PositionFlatPages()
            _CEN_UpdateScrollBar("")
            return
        }
        if (gCEN["Pages"].Has(section.name))
            y += gCEN["Pages"][section.name].contentH
    }
}

; ============================================================
; RESET TO DEFAULTS
; ============================================================

_CEN_OnResetDefaults(*) {
    global gCEN, gConfigRegistry

    result := ThemeMsgBox("Reset all settings to their default values?`n`nChanges won't be saved until you click Save.", "Alt-Tabby Configuration", "YesNo Icon?")
    if (result = "No")
        return

    for _, entry in gConfigRegistry {
        if (!entry.HasOwnProp("default"))
            continue
        if (!gCEN["Controls"].Has(entry.g))
            continue
        ctrlInfo := gCEN["Controls"][entry.g]
        _CEN_SetControlValue(ctrlInfo, entry.default, entry.t)
    }
}

; ============================================================
; CHANGE COUNTER
; ============================================================

_CEN_UpdateChangeCount() {
    global gCEN, gConfigRegistry

    if (!gCEN["MainGui"])
        return

    count := 0
    for _, entry in gConfigRegistry {
        if (!entry.HasOwnProp("default") || !gCEN["Controls"].Has(entry.g))
            continue
        ctrlInfo := gCEN["Controls"][entry.g]
        try {
            if (_CEN_GetControlValue(ctrlInfo, entry.t) != gCEN["OriginalValues"][entry.g])
                count++
        }
    }

    if (gCEN["ChangeLabel"]) {
        labelText := (count > 0) ? count " unsaved change" (count > 1 ? "s" : "") : ""
        try gCEN["ChangeLabel"].Value := labelText
    }
}
