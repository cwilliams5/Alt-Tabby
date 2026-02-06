#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
; Prototype: Child-GUI Panels with Sidebar Navigation
;
; Key techniques:
;   - Viewport pattern: clipping container + oversized content panel
;   - Scroll = move content panel within viewport (single Move call)
;   - Controls never move relative to their parent (no DeferWindowPos)
;   - No WM_SETREDRAW needed (no individual control repositioning)
;   - Accumulated wheel delta processed via timer (no lost scrolls)
; ============================================================

#Include %A_ScriptDir%\..\..\src\shared\config_registry.ahk

; ---- Constants ----
global WM_MOUSEWHEEL := 0x020A
global WM_VSCROLL := 0x0115
global SB_VERT := 1
global SIF_ALL := 0x17
global SIDEBAR_W := 210
global CONTENT_X := SIDEBAR_W
global FOOTER_H := 48
global SCROLL_STEP := 60               ; pixels per wheel notch
global SETTING_PAD := 8
global DESC_LINE_H := 15
global LABEL_W := 180
global INPUT_X := 206

; ---- State ----
global gMainGui := ""
global gViewport := ""
global gSidebar := ""
global gPages := Map()
global gCurrentPage := ""
global gSections := []
global gFooterBtns := []

; Scroll accumulator - prevents lost wheel messages
global gScrollAccum := 0
global gScrollTimer := 0

; ---- Parse Registry ----
_ParseRegistry()
_ParseRegistry() {
    global gConfigRegistry, gSections
    curSection := ""
    curSubsection := ""
    for entry in gConfigRegistry {
        if (entry.HasOwnProp("type") && entry.type = "section") {
            curSection := {name: entry.name, desc: entry.desc,
                long: entry.HasOwnProp("long") ? entry.long : "",
                settings: [], subsections: []}
            curSubsection := ""
            gSections.Push(curSection)
        } else if (entry.HasOwnProp("type") && entry.type = "subsection") {
            curSubsection := {name: entry.name,
                desc: entry.HasOwnProp("desc") ? entry.desc : "",
                settings: []}
            if (curSection != "")
                curSection.subsections.Push(curSubsection)
        } else if (entry.HasOwnProp("s")) {
            setting := {s: entry.s, k: entry.k, g: entry.g, t: entry.t,
                default: entry.default, d: entry.d}
            if (entry.HasOwnProp("options"))
                setting.options := entry.options
            if (curSubsection != "" && curSubsection.HasOwnProp("name"))
                curSubsection.settings.Push(setting)
            else if (curSection != "")
                curSection.settings.Push(setting)
        }
    }
}

; ---- Build Main Window ----
_BuildMainGUI()
_BuildMainGUI() {
    global gMainGui, gViewport, gSidebar, gPages, gCurrentPage

    gMainGui := Gui("+Resize +MinSize750x450 +0x02000000", "Alt-Tabby Settings (Child-GUI Prototype)")
    gMainGui.BackColor := "16213e"
    gMainGui.MarginX := 0
    gMainGui.MarginY := 0
    gMainGui.SetFont("s9", "Segoe UI")

    gSidebar := gMainGui.AddListBox("x0 y0 w" SIDEBAR_W " h400 +0x100", [])
    gSidebar.SetFont("s10", "Segoe UI")
    items := []
    for section in gSections
        items.Push(section.desc)
    gSidebar.Add(items)
    gSidebar.OnEvent("Change", _OnSidebarChange)

    ; Viewport: clipping container for scrollable content.
    ; Child windows are automatically clipped to their parent's client area.
    ; WS_CLIPCHILDREN (0x02000000) prevents viewport bg from painting over page.
    ; WS_VSCROLL (0x00200000) puts the scrollbar on this container.
    gViewport := Gui("-Caption -Border +Parent" gMainGui.Hwnd " +0x02200000")
    gViewport.BackColor := "16213e"
    gViewport.MarginX := 0
    gViewport.MarginY := 0
    gViewport.Show("x" CONTENT_X " y0 w580 h500 NoActivate")

    btnSave := gMainGui.AddButton("x610 y460 w80 h30", "Save")
    btnCancel := gMainGui.AddButton("x520 y460 w80 h30", "Cancel")
    btnReset := gMainGui.AddButton("x" (CONTENT_X + 10) " y460 w120 h30", "Reset Defaults")
    gFooterBtns.Push(btnSave, btnCancel, btnReset)
    btnSave.OnEvent("Click", (*) => MsgBox("Would save to config.ini"))
    btnCancel.OnEvent("Click", (*) => gMainGui.Destroy())
    btnReset.OnEvent("Click", (*) => MsgBox("Would reset all to defaults"))

    for section in gSections
        _BuildPage(section)

    gMainGui.OnEvent("Size", _OnResize)
    gMainGui.OnEvent("Close", (*) => ExitApp())

    OnMessage(WM_MOUSEWHEEL, _OnMouseWheel)
    OnMessage(WM_VSCROLL, _OnVScroll)

    gMainGui.Show("w800 h550")

    if (gSections.Length > 0) {
        gSidebar.Value := 1
        _SwitchToPage(gSections[1].name)
    }
}

; ---- Build Page ----
_BuildPage(section) {
    global gViewport, gPages

    ; Page GUI: child of viewport, sized to FULL content height.
    ; Controls are placed at fixed positions - they never move.
    ; Scrolling moves the entire page within the viewport.
    pageGui := Gui("-Caption -Border +Parent" gViewport.Hwnd " +0x02000000")
    pageGui.BackColor := "16213e"
    pageGui.MarginX := 0
    pageGui.MarginY := 0
    pageGui.SetFont("s9", "Segoe UI")

    controls := []
    y := 12
    contentW := 560

    c := pageGui.AddText("x16 y" y " w" contentW " h26 cDDDDDD", section.desc)
    c.SetFont("s15 bold", "Segoe UI")
    controls.Push({ctrl: c, origY: y, origX: 16})
    y += 30

    if (section.long != "") {
        lines := Ceil(StrLen(section.long) / 70)
        h := Max(18, lines * DESC_LINE_H)
        c := pageGui.AddText("x16 y" y " w" contentW " h" h " c7788AA", section.long)
        c.SetFont("s8", "Segoe UI")
        controls.Push({ctrl: c, origY: y, origX: 16})
        y += h + 8
    }

    y := _AddSettings(pageGui, section.settings, controls, y, contentW)

    for sub in section.subsections {
        y += 16
        c := pageGui.AddText("x16 y" y " w" contentW " h1 +0x10")
        controls.Push({ctrl: c, origY: y, origX: 16})
        y += 6
        c := pageGui.AddText("x16 y" y " w" contentW " h20 cAAAACC", sub.name)
        c.SetFont("s10 bold", "Segoe UI")
        controls.Push({ctrl: c, origY: y, origX: 16})
        y += 22

        if (sub.desc != "") {
            lines := Ceil(StrLen(sub.desc) / 75)
            h := Max(16, lines * DESC_LINE_H)
            c := pageGui.AddText("x20 y" y " w" (contentW - 8) " h" h " c667799", sub.desc)
            c.SetFont("s8 italic", "Segoe UI")
            controls.Push({ctrl: c, origY: y, origX: 20})
            y += h + 4
        }

        y := _AddSettings(pageGui, sub.settings, controls, y, contentW)
    }

    y += 24

    page := {gui: pageGui, controls: controls, contentH: y, scrollPos: 0}
    gPages[section.name] := page

    ; Size to FULL content height. Viewport clips the visible portion.
    pageGui.Show("x0 y0 w580 h" y " NoActivate Hide")
}

_AddSettings(pageGui, settings, controls, y, contentW) {
    for setting in settings {
        y += SETTING_PAD

        descLen := StrLen(setting.d)
        descLines := Ceil(descLen / 70)
        descH := Max(DESC_LINE_H, descLines * DESC_LINE_H)

        if (setting.t = "bool") {
            cb := pageGui.AddCheckbox("x24 y" y " w" contentW " h20 cCCCCDD", setting.k)
            cb.Value := setting.default
            controls.Push({ctrl: cb, origY: y, origX: 24})
            y += 22
            dc := pageGui.AddText("x40 y" y " w" (contentW - 24) " h" descH " c556677", setting.d)
            dc.SetFont("s8", "Segoe UI")
            controls.Push({ctrl: dc, origY: y, origX: 40})
            y += descH + 4
        } else if (setting.t = "enum") {
            lbl := pageGui.AddText("x24 y" y " w" LABEL_W " h20 +0x200 cBBBBCC", setting.k)
            controls.Push({ctrl: lbl, origY: y, origX: 24})
            optList := []
            if (setting.HasOwnProp("options"))
                for opt in setting.options
                    optList.Push(opt)
            dd := pageGui.AddDropDownList("x" INPUT_X " y" y " w200", optList)
            for i, opt in optList {
                if (opt = setting.default) {
                    dd.Value := i
                    break
                }
            }
            controls.Push({ctrl: dd, origY: y, origX: INPUT_X})
            y += 26
            dc := pageGui.AddText("x24 y" y " w" contentW " h" descH " c556677", setting.d)
            dc.SetFont("s8", "Segoe UI")
            controls.Push({ctrl: dc, origY: y, origX: 24})
            y += descH + 4
        } else {
            lbl := pageGui.AddText("x24 y" y " w" LABEL_W " h20 +0x200 cBBBBCC", setting.k)
            controls.Push({ctrl: lbl, origY: y, origX: 24})
            defVal := setting.default
            if (setting.t = "int" && IsNumber(defVal) && defVal > 255)
                defVal := Format("0x{:X}", defVal)
            ed := pageGui.AddEdit("x" INPUT_X " y" y " w200", String(defVal))
            controls.Push({ctrl: ed, origY: y, origX: INPUT_X})
            y += 26
            dc := pageGui.AddText("x24 y" y " w" contentW " h" descH " c556677", setting.d)
            dc.SetFont("s8", "Segoe UI")
            controls.Push({ctrl: dc, origY: y, origX: 24})
            y += descH + 4
        }
    }
    return y
}

; ---- Sidebar ----
_OnSidebarChange(ctrl, *) {
    global gSections
    idx := ctrl.Value
    if (idx < 1 || idx > gSections.Length)
        return
    _SwitchToPage(gSections[idx].name)
}

_SwitchToPage(name) {
    global gPages, gCurrentPage, gScrollAccum

    if (gCurrentPage != "" && gPages.Has(gCurrentPage))
        gPages[gCurrentPage].gui.Hide()

    gCurrentPage := name
    gScrollAccum := 0
    if (!gPages.Has(name))
        return

    page := gPages[name]
    page.scrollPos := 0
    page.gui.Move(0, 0)            ; reset to top of viewport
    _UpdateScrollBar(name)
    page.gui.Show("NoActivate")
}

; ============================================================
; SCROLL ENGINE
; ============================================================
; Viewport pattern: the page GUI is sized to its full content
; height and parented to a clipping viewport. Scrolling just
; moves the page: page.gui.Move(0, -scrollPos). One call.
; Controls never move relative to their parent, so there are
; no DeferWindowPos batches, no WM_SETREDRAW, no ghost artifacts.
;
; The accumulated wheel delta engine prevents lost scroll
; messages when the user spins the wheel faster than the
; message pump can drain.
; ============================================================

_OnMouseWheel(wParam, lParam, msg, hwnd) {
    global gCurrentPage, gPages, gMainGui, SIDEBAR_W
    global gScrollAccum, gScrollTimer
    if (gCurrentPage = "" || !gPages.Has(gCurrentPage))
        return

    ; Hit test: only scroll if cursor is right of sidebar
    pt := Buffer(8, 0)
    DllCall("GetCursorPos", "Ptr", pt)
    DllCall("ScreenToClient", "Ptr", gMainGui.Hwnd, "Ptr", pt)
    if (NumGet(pt, 0, "Int") < SIDEBAR_W)
        return

    ; Extract signed wheel delta
    raw := (wParam >> 16) & 0xFFFF
    if (raw > 0x7FFF)
        raw -= 0x10000

    ; Accumulate (negative = scroll down = positive offset)
    gScrollAccum -= raw

    ; Start drain timer if not running (10ms for fast response)
    if (!gScrollTimer) {
        gScrollTimer := 1
        SetTimer(_DrainScroll, -10)
    }

    return 0  ; consume
}

_DrainScroll() {
    global gScrollAccum, gScrollTimer, gCurrentPage, gPages, SCROLL_STEP

    gScrollTimer := 0

    if (gCurrentPage = "" || !gPages.Has(gCurrentPage) || gScrollAccum = 0) {
        gScrollAccum := 0
        return
    }

    ; Convert accumulated raw delta to pixels
    ; Raw 120 = one notch. Accumulate allows fractional notches.
    notches := gScrollAccum / 120
    scrollPx := Round(notches * SCROLL_STEP)
    gScrollAccum := 0  ; drain all

    if (scrollPx = 0)
        return

    page := gPages[gCurrentPage]
    _DoScroll(page, scrollPx)
    _UpdateScrollBar(gCurrentPage)
}

_OnVScroll(wParam, lParam, msg, hwnd) {
    global gCurrentPage, gPages, gViewport, SCROLL_STEP
    if (gCurrentPage = "" || !gPages.Has(gCurrentPage))
        return
    ; Only handle scrollbar on our viewport
    if (hwnd != gViewport.Hwnd)
        return

    page := gPages[gCurrentPage]
    viewH := _GetViewportHeight()
    maxScroll := Max(0, page.contentH - viewH)
    scrollCode := wParam & 0xFFFF

    switch scrollCode {
        case 0: newPos := page.scrollPos - SCROLL_STEP
        case 1: newPos := page.scrollPos + SCROLL_STEP
        case 2: newPos := page.scrollPos - viewH
        case 3: newPos := page.scrollPos + viewH
        case 5: newPos := (wParam >> 16) & 0xFFFF
        default: return
    }

    newPos := Max(0, Min(maxScroll, newPos))
    if (newPos = page.scrollPos)
        return

    _DoScroll(page, newPos - page.scrollPos)
    _UpdateScrollBar(gCurrentPage)
}

_DoScroll(page, delta) {
    newPos := page.scrollPos + delta
    viewH := _GetViewportHeight()
    maxScroll := Max(0, page.contentH - viewH)
    newPos := Max(0, Min(maxScroll, newPos))

    if (newPos = page.scrollPos)
        return

    page.scrollPos := newPos
    _ApplyScroll(page, newPos)
}

_ApplyScroll(page, scrollPos) {
    ; Move the entire page within the viewport. One call.
    ; The viewport clips everything outside its client area.
    page.gui.Move(0, -scrollPos)
}

_UpdateScrollBar(sectionName) {
    global gPages, gViewport, SB_VERT, SIF_ALL
    if (!gPages.Has(sectionName))
        return

    page := gPages[sectionName]
    viewH := _GetViewportHeight()

    if (page.contentH <= viewH) {
        DllCall("ShowScrollBar", "Ptr", gViewport.Hwnd, "Int", SB_VERT, "Int", 0)
        return
    }

    DllCall("ShowScrollBar", "Ptr", gViewport.Hwnd, "Int", SB_VERT, "Int", 1)

    si := Buffer(28, 0)
    NumPut("UInt", 28, si, 0)
    NumPut("UInt", SIF_ALL, si, 4)
    NumPut("Int", 0, si, 8)
    NumPut("Int", page.contentH, si, 12)
    NumPut("UInt", viewH, si, 16)
    NumPut("Int", page.scrollPos, si, 20)

    DllCall("SetScrollInfo", "Ptr", gViewport.Hwnd, "Int", SB_VERT, "Ptr", si, "Int", 1)
}

_GetViewportHeight() {
    global gViewport
    gViewport.GetPos(,, &w, &h)
    return h
}

; ---- Resize ----
_OnResize(gui, minMax, w, h) {
    global gSidebar, gViewport, gPages, gCurrentPage, gFooterBtns
    global SIDEBAR_W, CONTENT_X, FOOTER_H

    if (minMax = -1)
        return

    viewportH := h - FOOTER_H
    gSidebar.Move(0, 0, SIDEBAR_W, viewportH)

    contentW := w - CONTENT_X
    gViewport.Move(CONTENT_X, 0, contentW, viewportH)

    ; Update page widths to match viewport (height stays at full contentH)
    for name, page in gPages
        page.gui.Move(0, , contentW)

    btnY := h - FOOTER_H + 8
    if (gFooterBtns.Length >= 3) {
        gFooterBtns[1].Move(w - 100, btnY, 80, 30)
        gFooterBtns[2].Move(w - 190, btnY, 80, 30)
        gFooterBtns[3].Move(CONTENT_X + 10, btnY, 120, 30)
    }

    if (gCurrentPage != "")
        _UpdateScrollBar(gCurrentPage)
}
