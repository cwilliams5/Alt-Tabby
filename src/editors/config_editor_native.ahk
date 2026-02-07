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
global CEN_SCROLL_STEP := 60               ; pixels per wheel notch
global CEN_SETTING_PAD := 8
global CEN_DESC_LINE_H := 15
global CEN_LABEL_W := 180
global CEN_INPUT_X := 206
global CEN_SEARCH_H := 44                  ; header bar height (title + search)

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

; Theme tracking entry for config editor
global gCEN_ThemeEntry := 0

; Search state
global gCEN_SearchEdit := 0
global gCEN_SearchText := ""
global gCEN_SearchTimer := 0
global gCEN_SettingGroups := Map()      ; globalName -> {pageKey, searchText, subIdx}
global gCEN_FilteredIndices := []       ; sidebar indices matching search

; Flat search mode (stacked pages)
global gCEN_FlatMode := false
global gCEN_FlatScrollPos := 0
global gCEN_FlatContentH := 0

; Change counter timer
global gCEN_ChangeCountTimer := 0

; Border separators (child GUIs for 1px lines between zones)
global gCEN_SepHeader := 0
global gCEN_SepSidebar := 0
global gCEN_SepFooter := 0

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
    global gCEN_SearchText, gCEN_SearchTimer, gCEN_SettingGroups, gCEN_FilteredIndices, gCEN_ChangeCountTimer
    global gCEN_FlatMode, gCEN_FlatScrollPos, gCEN_FlatContentH
    global gCEN_SepHeader, gCEN_SepSidebar, gCEN_SepFooter

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
    gCEN_SearchText := ""
    gCEN_SearchTimer := 0
    gCEN_SettingGroups := Map()
    gCEN_FilteredIndices := []
    gCEN_FlatMode := false
    gCEN_FlatScrollPos := 0
    gCEN_FlatContentH := 0
    gCEN_ChangeCountTimer := 0
    gCEN_SepHeader := 0
    gCEN_SepSidebar := 0
    gCEN_SepFooter := 0

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

    ; Everything is built and populated — reveal
    _GUI_AntiFlashReveal(gCEN_MainGui, true)

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

; ============================================================
; GUI BUILDING
; ============================================================

_CEN_BuildMainGUI() {
    global gCEN_MainGui, gCEN_Viewport, gCEN_Sidebar, gCEN_Pages, gCEN_Sections
    global gCEN_FooterBtns, gCEN_BoundWheelMsg, gCEN_BoundScrollMsg
    global CEN_WM_MOUSEWHEEL, CEN_WM_VSCROLL, CEN_SIDEBAR_W, CEN_CONTENT_X, CEN_SEARCH_H
    global gCEN_SearchEdit, gCEN_FilteredIndices, gCEN_ChangeCountTimer

    ; Create main window with theme + anti-flash (DWM cloaking)
    gCEN_MainGui := Gui("+Resize +MinSize750x450 +0x02000000", "Alt-Tabby Configuration")
    gCEN_MainGui.MarginX := 0
    gCEN_MainGui.MarginY := 0
    gCEN_MainGui.SetFont("s9", "Segoe UI")
    global gTheme_Palette, gCEN_ThemeEntry
    themeEntry := Theme_ApplyToGui(gCEN_MainGui)
    gCEN_ThemeEntry := themeEntry
    Theme_OnChange(_CEN_OnThemeChange)

    ; Frame bg: panelBg (lighter) for sidebar/header/footer; content area uses bg (darker)
    gCEN_MainGui.BackColor := gTheme_Palette.panelBg
    Theme_MarkPanel(gCEN_MainGui)

    ; Header bar: title left, search right
    hdrTitle := gCEN_MainGui.AddText("x20 y12 w300 h24", "Alt-Tabby Settings")
    hdrTitle.SetFont("s14 bold", "Segoe UI")
    gCEN_SearchEdit := gCEN_MainGui.AddEdit("x524 y10 w260 h24")
    Theme_ApplyToControl(gCEN_SearchEdit, "Edit", themeEntry)
    DllCall("user32\SendMessageW", "Ptr", gCEN_SearchEdit.Hwnd, "UInt", 0x1501, "Ptr", 1, "WStr", "Search settings...")
    DllCall("user32\SendMessageW", "Ptr", gCEN_SearchEdit.Hwnd, "UInt", 0xD3, "Ptr", 3, "Ptr", (6 << 16) | 6)
    gCEN_SearchEdit.OnEvent("Change", _CEN_OnSearchInput)

    ; Sidebar with section list (below header border)
    sidebarY := CEN_SEARCH_H + 1  ; +1 to leave room for header border
    gCEN_Sidebar := gCEN_MainGui.AddListBox("x0 y" sidebarY " w" CEN_SIDEBAR_W " h400 +0x100", [])
    gCEN_Sidebar.SetFont("s10", "Segoe UI")
    Theme_ApplyToControl(gCEN_Sidebar, "ListBox", themeEntry)
    Theme_MarkSidebar(gCEN_Sidebar)
    items := []
    gCEN_FilteredIndices := []
    for idx, section in gCEN_Sections {
        items.Push("   " section.desc)
        gCEN_FilteredIndices.Push(idx)
    }
    gCEN_Sidebar.Add(items)
    gCEN_Sidebar.OnEvent("Change", _CEN_OnSidebarChange)

    ; Viewport: clipping container for scrollable content
    ; WS_CLIPCHILDREN (0x02000000) prevents viewport bg from painting over page
    ; WS_VSCROLL (0x00200000) puts the scrollbar on this container
    gCEN_Viewport := Gui("-Caption -Border +Parent" gCEN_MainGui.Hwnd " +0x02200000")
    gCEN_Viewport.BackColor := gTheme_Palette.bg
    gCEN_Viewport.MarginX := 0
    gCEN_Viewport.MarginY := 0
    Theme_ApplyToWindow(gCEN_Viewport.Hwnd)
    viewportY := CEN_SEARCH_H + 1  ; +1 to leave room for header border
    gCEN_Viewport.Show("x" CEN_CONTENT_X " y" viewportY " w580 h466 NoActivate")

    ; Border separators (1px child GUIs in gaps between zones)
    ; Positioned in 1px gaps so they're never covered by sibling controls
    global gCEN_SepHeader, gCEN_SepSidebar, gCEN_SepFooter
    borderColor := gTheme_Palette.border
    sepMiddleY := CEN_SEARCH_H + 1  ; sidebar/viewport start here
    gCEN_SepHeader := Gui("-Caption -Border +Parent" gCEN_MainGui.Hwnd)
    gCEN_SepHeader.BackColor := borderColor
    gCEN_SepHeader.MarginX := 0
    gCEN_SepHeader.MarginY := 0
    gCEN_SepHeader.Show("x0 y" CEN_SEARCH_H " w800 h1 NoActivate")
    gCEN_SepSidebar := Gui("-Caption -Border +Parent" gCEN_MainGui.Hwnd)
    gCEN_SepSidebar.BackColor := borderColor
    gCEN_SepSidebar.MarginX := 0
    gCEN_SepSidebar.MarginY := 0
    gCEN_SepSidebar.Show("x" CEN_SIDEBAR_W " y" sepMiddleY " w1 h400 NoActivate")
    gCEN_SepFooter := Gui("-Caption -Border +Parent" gCEN_MainGui.Hwnd)
    gCEN_SepFooter.BackColor := borderColor
    gCEN_SepFooter.MarginX := 0
    gCEN_SepFooter.MarginY := 0
    gCEN_SepFooter.Show("x0 y501 w800 h1 NoActivate")

    ; Footer buttons: right-aligned group (Reset, Save, Cancel)
    btnReset := gCEN_MainGui.AddButton("x490 y460 w120 h30", "Reset to Defaults")
    btnSave := gCEN_MainGui.AddButton("x620 y460 w80 h30", "Save")
    btnCancel := gCEN_MainGui.AddButton("x710 y460 w80 h30", "Cancel")
    gCEN_FooterBtns.Push(btnSave, btnCancel, btnReset)
    btnReset.OnEvent("Click", _CEN_OnResetDefaults)
    btnSave.OnEvent("Click", _CEN_OnSave)
    btnCancel.OnEvent("Click", _CEN_OnCancel)
    Theme_ApplyToControl(btnReset, "Button", themeEntry)
    Theme_ApplyToControl(btnSave, "Button", themeEntry)
    Theme_ApplyToControl(btnCancel, "Button", themeEntry)

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

    ; Change counter timer (updates title bar every 500ms)
    gCEN_ChangeCountTimer := 1
    SetTimer(_CEN_UpdateChangeCount, 500)

    _GUI_AntiFlashPrepare(gCEN_MainGui, gTheme_Palette.panelBg, true)
    gCEN_MainGui.Show("w800 h550")
}

_CEN_BuildPage(section) {
    global gCEN_Viewport, gCEN_Pages, gCEN_Controls
    global CEN_SETTING_PAD, CEN_DESC_LINE_H, CEN_LABEL_W, CEN_INPUT_X

    ; Page GUI: child of viewport, sized to FULL content height
    ; Controls are placed at fixed positions - they never move
    ; Scrolling moves the entire page within the viewport
    global gTheme_Palette
    pageGui := Gui("-Caption -Border +Parent" gCEN_Viewport.Hwnd " +0x02000000")
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
        lines := Ceil(StrLen(section.long) / 70)
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
            lines := Ceil(StrLen(sub.desc) / 75)
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
    gCEN_Pages[section.name] := page

    ; Size to FULL content height. Viewport clips the visible portion.
    pageGui.Show("x0 y0 w580 h" y " NoActivate Hide")
}

_CEN_AddSettings(pageGui, settings, controls, blocks, y, contentW, sectionName, subIdx) {
    global gCEN_Controls, gCEN_ThemeEntry, gTheme_Palette, gCEN_SettingGroups
    global CEN_SETTING_PAD, CEN_DESC_LINE_H, CEN_LABEL_W, CEN_INPUT_X

    mutedColor := Theme_GetMutedColor()

    for setting in settings {
        startY := y
        settingCtrls := []

        y += CEN_SETTING_PAD

        descLen := StrLen(setting.d)
        descLines := Ceil(descLen / 70)
        descH := Max(CEN_DESC_LINE_H, descLines * CEN_DESC_LINE_H)

        if (setting.t = "bool") {
            cb := pageGui.AddCheckbox("x24 y" y " w" contentW " h20 c" gTheme_Palette.text, setting.k)
            cb.SetFont("s9 bold", "Segoe UI")
            controls.Push({ctrl: cb, origY: y, origX: 24})
            settingCtrls.Push({ctrl: cb, origY: y, origX: 24})
            gCEN_Controls[setting.g] := {ctrl: cb, type: "bool"}
            Theme_ApplyToControl(cb, "Checkbox", gCEN_ThemeEntry)
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
            gCEN_Controls[setting.g] := {ctrl: dd, type: "enum"}
            Theme_ApplyToControl(dd, "DDL", gCEN_ThemeEntry)
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
                Theme_ApplyToControl(slider, "Slider", gCEN_ThemeEntry)
                editX := sliderX + 126
                ed := pageGui.AddEdit("x" editX " y" y " w80 Number")
                controls.Push({ctrl: ed, origY: y, origX: editX})
                settingCtrls.Push({ctrl: ed, origY: y, origX: editX})
                ud := pageGui.AddUpDown("Range" setting.min "-" setting.max)
                controls.Push({ctrl: ud, origY: y, origX: editX})
                settingCtrls.Push({ctrl: ud, origY: y, origX: editX})
                Theme_ApplyToControl(ed, "Edit", gCEN_ThemeEntry)
                Theme_ApplyToControl(ud, "UpDown", gCEN_ThemeEntry)
                DllCall("user32\SendMessageW", "Ptr", ed.Hwnd, "UInt", 0xD3, "Ptr", 3, "Ptr", (6 << 16) | 6)
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
                gCEN_Controls[setting.g] := ctrlInfo
            } else {
                ; Float, hex, string, or no range -> plain Edit
                ed := pageGui.AddEdit("x" CEN_INPUT_X " y" y " w200")
                controls.Push({ctrl: ed, origY: y, origX: CEN_INPUT_X})
                settingCtrls.Push({ctrl: ed, origY: y, origX: CEN_INPUT_X})
                ctrlInfo := {ctrl: ed, type: setting.t}
                if (isHex)
                    ctrlInfo.fmt := "hex"
                gCEN_Controls[setting.g] := ctrlInfo
                Theme_ApplyToControl(ed, "Edit", gCEN_ThemeEntry)
                DllCall("user32\SendMessageW", "Ptr", ed.Hwnd, "UInt", 0xD3, "Ptr", 3, "Ptr", (6 << 16) | 6)

                ; Clamp-on-blur for float/hex with range
                if (hasRange && (setting.t = "float" || isHex)) {
                    boundClamp := _CEN_MakeClampHandler(setting.g, setting.min, setting.max)
                    ed.OnEvent("LoseFocus", boundClamp)
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
            if (hasRange && !useUpDown) {
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
        gCEN_SettingGroups[setting.g] := {pageKey: sectionName, searchText: StrLower(setting.k " " setting.g " " setting.d), subIdx: subIdx}
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
    } else if (ctrlInfo.HasOwnProp("fmt") && ctrlInfo.fmt = "hex") {
        ctrlInfo.ctrl.Value := Format("0x{:X}", val)
    } else if (type = "float") {
        ctrlInfo.ctrl.Value := Format("{:.6g}", val)
    } else {
        ctrlInfo.ctrl.Value := String(val)
    }
    if (ctrlInfo.HasOwnProp("slider"))
        try ctrlInfo.slider.Value := Integer(val)
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

_CEN_ClampOnBlur(globalName, minVal, maxVal) {
    global gCEN_Controls
    if (!gCEN_Controls.Has(globalName))
        return
    ctrlInfo := gCEN_Controls[globalName]
    val := _CEN_GetControlValue(ctrlInfo, ctrlInfo.type)
    if (val < minVal)
        val := minVal
    else if (val > maxVal)
        val := maxVal
    _CEN_SetControlValue(ctrlInfo, val, ctrlInfo.type)
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
    global gCEN_Sections, gCEN_FilteredIndices, gCEN_FlatMode
    idx := ctrl.Value
    if (idx < 1 || idx > gCEN_FilteredIndices.Length)
        return
    realIdx := gCEN_FilteredIndices[idx]
    if (realIdx < 1 || realIdx > gCEN_Sections.Length)
        return
    if (gCEN_FlatMode)
        _CEN_ScrollToFlatSection(gCEN_Sections[realIdx].name)
    else
        _CEN_SwitchToPage(gCEN_Sections[realIdx].name)
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
    global gCEN_FlatMode

    gCEN_ScrollTimer := 0

    if (gCEN_ScrollAccum = 0) {
        return
    }

    notches := gCEN_ScrollAccum / 120
    scrollPx := Round(notches * CEN_SCROLL_STEP)
    gCEN_ScrollAccum := 0

    if (scrollPx = 0)
        return

    if (gCEN_FlatMode) {
        _CEN_DoFlatScroll(scrollPx)
    } else {
        if (gCEN_CurrentPage = "" || !gCEN_Pages.Has(gCEN_CurrentPage))
            return
        page := gCEN_Pages[gCEN_CurrentPage]
        _CEN_DoScroll(page, scrollPx)
    }
    _CEN_UpdateScrollBar(gCEN_CurrentPage)
}

_CEN_OnVScroll(wParam, lParam, msg, hwnd) {
    global gCEN_CurrentPage, gCEN_Pages, gCEN_Viewport, CEN_SCROLL_STEP
    global gCEN_FlatMode, gCEN_FlatScrollPos, gCEN_FlatContentH

    if (hwnd != gCEN_Viewport.Hwnd)
        return

    viewH := _CEN_GetViewportHeight()

    if (gCEN_FlatMode) {
        scrollPos := gCEN_FlatScrollPos
        maxScroll := Max(0, gCEN_FlatContentH - viewH)
    } else {
        if (gCEN_CurrentPage = "" || !gCEN_Pages.Has(gCEN_CurrentPage))
            return
        page := gCEN_Pages[gCEN_CurrentPage]
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

    if (gCEN_FlatMode) {
        gCEN_FlatScrollPos := newPos
        _CEN_PositionFlatPages()
    } else {
        _CEN_DoScroll(page, newPos - page.scrollPos)
    }
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
    global gCEN_FlatMode, gCEN_FlatContentH, gCEN_FlatScrollPos

    viewH := _CEN_GetViewportHeight()

    if (gCEN_FlatMode) {
        contentH := gCEN_FlatContentH
        scrollPos := gCEN_FlatScrollPos
    } else {
        if (!gCEN_Pages.Has(sectionName))
            return
        page := gCEN_Pages[sectionName]
        contentH := page.contentH
        scrollPos := page.scrollPos
    }

    if (contentH <= viewH) {
        DllCall("ShowScrollBar", "Ptr", gCEN_Viewport.Hwnd, "Int", CEN_SB_VERT, "Int", 0)
        return
    }

    DllCall("ShowScrollBar", "Ptr", gCEN_Viewport.Hwnd, "Int", CEN_SB_VERT, "Int", 1)

    si := Buffer(28, 0)
    NumPut("UInt", 28, si, 0)
    NumPut("UInt", CEN_SIF_ALL, si, 4)
    NumPut("Int", 0, si, 8)
    NumPut("Int", contentH, si, 12)
    NumPut("UInt", viewH, si, 16)
    NumPut("Int", scrollPos, si, 20)

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
    global gCEN_SearchEdit, gCEN_SepHeader, gCEN_SepSidebar, gCEN_SepFooter
    global CEN_SIDEBAR_W, CEN_CONTENT_X, CEN_FOOTER_H, CEN_SEARCH_H

    if (minMax = -1)
        return

    ; Middle row starts 1px below header border, ends 1px above footer border
    middleY := CEN_SEARCH_H + 1
    viewportH := h - CEN_FOOTER_H - middleY - 1  ; -1 for footer border pixel
    gCEN_SearchEdit.Move(w - 276, 10, 260)
    gCEN_Sidebar.Move(0, middleY, CEN_SIDEBAR_W, viewportH)

    contentW := w - CEN_CONTENT_X
    gCEN_Viewport.Move(CEN_CONTENT_X, middleY, contentW, viewportH)

    ; Reposition border separators (in 1px gaps between zones)
    try gCEN_SepHeader.Move(0, CEN_SEARCH_H, w, 1)
    try gCEN_SepSidebar.Move(CEN_SIDEBAR_W, middleY, 1, viewportH)
    try gCEN_SepFooter.Move(0, h - CEN_FOOTER_H - 1, w, 1)

    ; Update page widths
    for name, page in gCEN_Pages
        page.gui.Move(0, , contentW)

    ; Move buttons: right-aligned group (Reset, Save, Cancel)
    btnY := h - CEN_FOOTER_H + 8
    if (gCEN_FooterBtns.Length >= 3) {
        gCEN_FooterBtns[2].Move(w - 100, btnY, 80, 30)       ; Cancel
        gCEN_FooterBtns[1].Move(w - 190, btnY, 80, 30)       ; Save
        gCEN_FooterBtns[3].Move(w - 320, btnY, 120, 30)      ; Reset
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
        ThemeMsgBox("Settings saved (" changeCount " changes). Restart Alt-Tabby to apply changes.",
            "Alt-Tabby Configuration", "OK Iconi")
    }
}

_CEN_OnCancel(*) {
    global gCEN_MainGui

    if (_CEN_HasUnsavedChanges()) {
        result := ThemeMsgBox("You have unsaved changes. Discard them?", "Alt-Tabby Configuration", "YesNo Icon?")
        if (result = "No")
            return
    }

    _CEN_Cleanup()
    gCEN_MainGui.Destroy()
}

_CEN_OnClose(guiObj) {
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
    global gCEN_MainGui, gCEN_Viewport, gCEN_Pages, gTheme_Palette
    global gCEN_SepHeader, gCEN_SepSidebar, gCEN_SepFooter
    ; Re-override main GUI bg (frame = panelBg, content = bg)
    try gCEN_MainGui.BackColor := gTheme_Palette.panelBg
    try {
        gCEN_Viewport.BackColor := gTheme_Palette.bg
        Theme_ApplyToWindow(gCEN_Viewport.Hwnd)
    }
    for name, page in gCEN_Pages {
        try page.gui.BackColor := gTheme_Palette.bg
    }
    ; Update border separator colors
    try gCEN_SepHeader.BackColor := gTheme_Palette.border
    try gCEN_SepSidebar.BackColor := gTheme_Palette.border
    try gCEN_SepFooter.BackColor := gTheme_Palette.border
}

_CEN_Cleanup() {
    global gCEN_BoundWheelMsg, gCEN_BoundScrollMsg
    global CEN_WM_MOUSEWHEEL, CEN_WM_VSCROLL
    global gCEN_Pages, gCEN_Viewport, gCEN_MainGui, gCEN_ThemeEntry
    global gCEN_ChangeCountTimer, gCEN_SearchTimer
    global gCEN_SepHeader, gCEN_SepSidebar, gCEN_SepFooter

    ; Stop timers
    if (gCEN_ChangeCountTimer) {
        SetTimer(_CEN_UpdateChangeCount, 0)
        gCEN_ChangeCountTimer := 0
    }
    if (gCEN_SearchTimer) {
        SetTimer(_CEN_DoSearch, 0)
        gCEN_SearchTimer := 0
    }

    ; Untrack GUI from theme system
    if (gCEN_MainGui) {
        try Theme_UntrackGui(gCEN_MainGui)
    }
    gCEN_ThemeEntry := 0

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

    ; Destroy border separators
    if (gCEN_SepHeader) {
        try gCEN_SepHeader.Destroy()
        gCEN_SepHeader := 0
    }
    if (gCEN_SepSidebar) {
        try gCEN_SepSidebar.Destroy()
        gCEN_SepSidebar := 0
    }
    if (gCEN_SepFooter) {
        try gCEN_SepFooter.Destroy()
        gCEN_SepFooter := 0
    }

    ; Destroy viewport
    if (gCEN_Viewport) {
        try gCEN_Viewport.Destroy()
        gCEN_Viewport := 0
    }
}

; ============================================================
; SEARCH
; ============================================================

_CEN_OnSearchInput(ctrl, *) {
    global gCEN_SearchTimer
    if (gCEN_SearchTimer)
        SetTimer(_CEN_DoSearch, 0)
    gCEN_SearchTimer := 1
    SetTimer(_CEN_DoSearch, -200)
}

_CEN_DoSearch() {
    global gCEN_SearchEdit, gCEN_SearchText, gCEN_SearchTimer
    gCEN_SearchTimer := 0
    newText := StrLower(Trim(gCEN_SearchEdit.Value))
    if (newText = gCEN_SearchText)
        return
    gCEN_SearchText := newText
    _CEN_ApplySearch()
}

_CEN_ApplySearch() {
    global gCEN_SearchText, gCEN_Sections, gCEN_Sidebar, gCEN_FilteredIndices
    global gCEN_Pages, gCEN_CurrentPage, gCEN_FlatMode, gCEN_FlatScrollPos, gCEN_FlatContentH
    global gCEN_SettingGroups

    searchText := gCEN_SearchText

    ; Reflow all pages (show/hide settings based on search)
    for name, page in gCEN_Pages
        _CEN_ReflowPage(page, name, searchText)

    ; Build filtered section indices (sections with matching settings)
    gCEN_FilteredIndices := []
    for idx, section in gCEN_Sections {
        if (searchText = "" || _CEN_SectionHasMatch(section.name, searchText))
            gCEN_FilteredIndices.Push(idx)
    }

    gCEN_Sidebar.Delete()

    if (searchText != "") {
        ; Search active: single "Search Results" label in sidebar
        matchCount := 0
        for _, group in gCEN_SettingGroups {
            if (InStr(group.searchText, searchText))
                matchCount++
        }
        if (matchCount > 0)
            gCEN_Sidebar.Add(["   Search Results (" matchCount ")"])
        else
            gCEN_Sidebar.Add(["   No results"])
        gCEN_Sidebar.Value := 1

        if (gCEN_FilteredIndices.Length > 0) {
            ; FLAT MODE: show all matching pages stacked
            gCEN_FlatMode := true
            gCEN_FlatScrollPos := 0
            for name, page in gCEN_Pages
                page.gui.Hide()
            totalH := 0
            for _, idx in gCEN_FilteredIndices {
                section := gCEN_Sections[idx]
                if (!gCEN_Pages.Has(section.name))
                    continue
                page := gCEN_Pages[section.name]
                page.gui.Show("NoActivate")
                totalH += page.contentH
            }
            gCEN_FlatContentH := totalH
            _CEN_PositionFlatPages()
        } else {
            if (gCEN_FlatMode) {
                gCEN_FlatMode := false
                for name, page in gCEN_Pages
                    page.gui.Hide()
            }
        }
    } else {
        ; No search: restore normal section sidebar
        items := []
        for _, idx in gCEN_FilteredIndices
            items.Push("   " gCEN_Sections[idx].desc)
        gCEN_Sidebar.Add(items)

        ; NORMAL MODE: single page view
        if (gCEN_FlatMode) {
            gCEN_FlatMode := false
            for name, page in gCEN_Pages
                page.gui.Hide()
        }
        if (gCEN_FilteredIndices.Length > 0) {
            selIdx := 1
            for i, realIdx in gCEN_FilteredIndices {
                if (gCEN_CurrentPage != "" && gCEN_Sections[realIdx].name = gCEN_CurrentPage) {
                    selIdx := i
                    break
                }
            }
            gCEN_Sidebar.Value := selIdx
            realIdx := gCEN_FilteredIndices[selIdx]
            _CEN_SwitchToPage(gCEN_Sections[realIdx].name)
        }
    }

    _CEN_UpdateScrollBar(gCEN_CurrentPage)
}

_CEN_SectionHasMatch(sectionName, searchText) {
    global gCEN_SettingGroups
    for globalName, group in gCEN_SettingGroups {
        if (group.pageKey = sectionName && InStr(group.searchText, searchText))
            return true
    }
    return false
}

_CEN_ReflowPage(page, sectionName, searchText) {
    global gCEN_SettingGroups

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
        if (!gCEN_SettingGroups.Has(block.globalName))
            continue
        group := gCEN_SettingGroups[block.globalName]
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
    global gCEN_FlatScrollPos, gCEN_FlatContentH
    global gCEN_FilteredIndices, gCEN_Sections, gCEN_Pages

    y := 0
    for _, idx in gCEN_FilteredIndices {
        section := gCEN_Sections[idx]
        if (!gCEN_Pages.Has(section.name))
            continue
        page := gCEN_Pages[section.name]
        page.gui.Move(0, y - gCEN_FlatScrollPos)
        y += page.contentH
    }
    gCEN_FlatContentH := y
}

; Scroll within flat mode
_CEN_DoFlatScroll(delta) {
    global gCEN_FlatScrollPos, gCEN_FlatContentH

    viewH := _CEN_GetViewportHeight()
    maxScroll := Max(0, gCEN_FlatContentH - viewH)
    newPos := Max(0, Min(maxScroll, gCEN_FlatScrollPos + delta))
    if (newPos = gCEN_FlatScrollPos)
        return
    gCEN_FlatScrollPos := newPos
    _CEN_PositionFlatPages()
}

; Scroll flat view to a specific section (sidebar click)
_CEN_ScrollToFlatSection(targetName) {
    global gCEN_FlatScrollPos, gCEN_FilteredIndices, gCEN_Sections, gCEN_Pages

    y := 0
    for _, idx in gCEN_FilteredIndices {
        section := gCEN_Sections[idx]
        if (section.name = targetName) {
            gCEN_FlatScrollPos := y
            _CEN_PositionFlatPages()
            _CEN_UpdateScrollBar("")
            return
        }
        if (gCEN_Pages.Has(section.name))
            y += gCEN_Pages[section.name].contentH
    }
}

; ============================================================
; RESET TO DEFAULTS
; ============================================================

_CEN_OnResetDefaults(*) {
    global gCEN_Controls, gConfigRegistry

    result := ThemeMsgBox("Reset all settings to their default values?`n`nChanges won't be saved until you click Save.", "Alt-Tabby Configuration", "YesNo Icon?")
    if (result = "No")
        return

    for _, entry in gConfigRegistry {
        if (!entry.HasOwnProp("default"))
            continue
        if (!gCEN_Controls.Has(entry.g))
            continue
        ctrlInfo := gCEN_Controls[entry.g]
        _CEN_SetControlValue(ctrlInfo, entry.default, entry.t)
    }
}

; ============================================================
; CHANGE COUNTER
; ============================================================

_CEN_UpdateChangeCount() {
    global gCEN_MainGui, gCEN_Controls, gCEN_OriginalValues, gConfigRegistry

    if (!gCEN_MainGui)
        return

    count := 0
    for _, entry in gConfigRegistry {
        if (!entry.HasOwnProp("default") || !gCEN_Controls.Has(entry.g))
            continue
        ctrlInfo := gCEN_Controls[entry.g]
        try {
            if (_CEN_GetControlValue(ctrlInfo, entry.t) != gCEN_OriginalValues[entry.g])
                count++
        }
    }

    title := "Alt-Tabby Configuration"
    if (count > 0)
        title .= " (" count " unsaved change" (count > 1 ? "s" : "") ")"
    try gCEN_MainGui.Title := title
}
