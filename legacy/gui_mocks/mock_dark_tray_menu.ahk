#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
; Mock: Dark Tray Menu - Owner-Drawn vs SetPreferredAppMode
; ============================================================
; Two approaches for dark tray/context menus:
;
; APPROACH A: SetPreferredAppMode (uxtheme ordinal #135)
;   ~5 lines. Free dark menus for entire process. Stable 5+ years.
;   CONFIRMED WORKING. This is the community standard.
;
; APPROACH B: Owner-drawn (MF_OWNERDRAW + WM_DRAWITEM)
;   Full GDI control. Uses SetWindowLongPtrW to replace the
;   window procedure at the Win32 level, bypassing AHK's
;   message blocking during menu modal loops.
;
; APPROACH C: GUI-based popup menu
;   Borderless Gui window styled as a menu. Avoids all Win32
;   owner-draw limitations. Full visual control.
;
; Toggle between approaches using the demo GUI buttons.
; ============================================================

; --- Colors (GDI = BGR: 0x00BBGGRR) ---
global CLR_DM_BG     := 0x2C2C2C   ; Menu background
global CLR_DM_GUTTER := 0x363636   ; Left gutter (icon area)
global CLR_DM_SEL    := 0x4A4A4A   ; Selected/hover
global CLR_DM_TEXT   := 0xE8E8E8   ; Normal text
global CLR_DM_GRAY   := 0x808080   ; Disabled text
global CLR_DM_SEP    := 0x484848   ; Separator line
global CLR_DM_CHK    := 0xD47800   ; Checkmark (accent blue BGR)

; --- Owner-draw state ---
global gOD_Items    := Map()    ; dataId -> {text, isSep, hasSubmenu}
global gOD_NextId   := 1        ; Auto-increment for item data IDs
global gOD_MenuFont := 0        ; Cached GDI font
global gOD_ChkFont  := 0        ; Cached GDI font for checkmark

; --- Subclass state ---
global gOD_OrigWndProc := 0     ; Original window procedure (A_ScriptHwnd)
global gOD_WndProcCB   := 0     ; CallbackCreate result
global gOD_OrigGuiProc := 0     ; Original window procedure (demoGui.Hwnd)
global gOD_GuiProcCB   := 0     ; CallbackCreate result for gui

; --- Diagnostic log ---
global gOD_LogFile := A_Temp "\tabby_od_menu_diag.log"

_OD_Log(msg) {
    global gOD_LogFile
    try FileAppend(A_Now " | " msg "`n", gOD_LogFile)
}

; --- Struct offsets (x64, verified from working owner-draw controls mock) ---
; DRAWITEMSTRUCT (64 bytes):
;   0:CtlType(4) 4:CtlID(4) 8:itemID(4) 12:itemAction(4) 16:itemState(4)
;   [pad 4] 24:hwndItem(8) 32:hDC(8) 40:rcItem(L4,T4,R4,B4) 56:itemData(8)
;
; MEASUREITEMSTRUCT (32 bytes):
;   0:CtlType(4) 4:CtlID(4) 8:itemID(4) 12:itemWidth(4) 16:itemHeight(4)
;   [pad 4] 24:itemData(8)

; --- Uxtheme ---
_UxOrd(ordinal) {
    static hMod := DllCall("GetModuleHandle", "Str", "uxtheme", "Ptr")
    return DllCall("GetProcAddress", "Ptr", hMod, "Ptr", ordinal, "Ptr")
}

; ============================================================
; Approach A: SetPreferredAppMode
; ============================================================
; Mode: 0=Default, 1=AllowDark, 2=ForceDark, 3=ForceLight
ApplyAppMode(mode) {
    try {
        DllCall(_UxOrd(135), "Int", mode, "Int")
        DllCall(_UxOrd(136))   ; FlushMenuThemes
    }
}

; ============================================================
; Approach B: Owner-Drawn Menu via Raw Win32 WndProc Replace
; ============================================================
;
; WHY RAW WNDPROC REPLACEMENT:
; AHK marks scripts uninterruptible on WM_ENTERMENULOOP (0x211).
; This blocks OnMessage handlers for messages < 0x312.
; Both WM_MEASUREITEM (0x2C) and WM_DRAWITEM (0x2B) are < 0x312.
;
; By replacing the window procedure with SetWindowLongPtrW, our
; callback runs BEFORE AHK's window procedure. CallbackCreate
; with "F" (Fast) mode calls the function directly without
; creating a new AHK thread, bypassing interruptibility checks.
;
; The callback calls the original wndproc via CallWindowProcW
; for all messages we don't handle.

; --- Create the replacement window procedure for A_ScriptHwnd ---
_OD_InstallWndProc() {
    global gOD_OrigWndProc, gOD_WndProcCB
    if (gOD_WndProcCB)
        return   ; Already installed

    ; Create Fast callback (4 params: hWnd, uMsg, wParam, lParam)
    gOD_WndProcCB := CallbackCreate(_OD_WndProc, "F", 4)
    _OD_Log("Created WndProc callback: " gOD_WndProcCB)

    ; Get original window procedure
    gOD_OrigWndProc := DllCall("GetWindowLongPtrW", "Ptr", A_ScriptHwnd, "Int", -4, "Ptr")
    _OD_Log("Original A_ScriptHwnd WndProc: " gOD_OrigWndProc)

    ; Replace with ours
    result := DllCall("SetWindowLongPtrW", "Ptr", A_ScriptHwnd, "Int", -4, "Ptr", gOD_WndProcCB, "Ptr")
    _OD_Log("SetWindowLongPtrW result: " result " (should match original)")
}

_OD_RemoveWndProc() {
    global gOD_OrigWndProc, gOD_WndProcCB
    if (!gOD_WndProcCB)
        return
    DllCall("SetWindowLongPtrW", "Ptr", A_ScriptHwnd, "Int", -4, "Ptr", gOD_OrigWndProc, "Ptr")
    CallbackFree(gOD_WndProcCB)
    gOD_WndProcCB := 0
    gOD_OrigWndProc := 0
    _OD_Log("Removed A_ScriptHwnd WndProc subclass")
}

; --- Create replacement window procedure for demoGui ---
_OD_InstallGuiWndProc(guiHwnd) {
    global gOD_OrigGuiProc, gOD_GuiProcCB
    if (gOD_GuiProcCB)
        return

    gOD_GuiProcCB := CallbackCreate(_OD_GuiWndProc, "F", 4)
    gOD_OrigGuiProc := DllCall("GetWindowLongPtrW", "Ptr", guiHwnd, "Int", -4, "Ptr")
    DllCall("SetWindowLongPtrW", "Ptr", guiHwnd, "Int", -4, "Ptr", gOD_GuiProcCB, "Ptr")
    _OD_Log("Installed Gui WndProc subclass on hwnd " guiHwnd)
}

_OD_RemoveGuiWndProc(guiHwnd) {
    global gOD_OrigGuiProc, gOD_GuiProcCB
    if (!gOD_GuiProcCB)
        return
    DllCall("SetWindowLongPtrW", "Ptr", guiHwnd, "Int", -4, "Ptr", gOD_OrigGuiProc, "Ptr")
    CallbackFree(gOD_GuiProcCB)
    gOD_GuiProcCB := 0
    gOD_OrigGuiProc := 0
    _OD_Log("Removed Gui WndProc subclass")
}

; --- Window procedures ---
_OD_WndProc(hWnd, uMsg, wParam, lParam) {
    global gOD_OrigWndProc, gOD_Items

    ; WM_MEASUREITEM
    if (uMsg = 0x002C) {
        ctlType := NumGet(lParam, 0, "UInt")
        _OD_Log("WM_MEASUREITEM on ScriptHwnd | CtlType=" ctlType " items=" gOD_Items.Count)
        if (ctlType = 3 && gOD_Items.Count > 0) {
            _OD_DoMeasure(lParam)
            return 1
        }
    }

    ; WM_DRAWITEM
    if (uMsg = 0x002B) {
        ctlType := NumGet(lParam, 0, "UInt")
        _OD_Log("WM_DRAWITEM on ScriptHwnd | CtlType=" ctlType " items=" gOD_Items.Count)
        if (ctlType = 3 && gOD_Items.Count > 0) {
            _OD_DoDraw(lParam)
            return 1
        }
    }

    return DllCall("CallWindowProcW", "Ptr", gOD_OrigWndProc, "Ptr", hWnd, "UInt", uMsg, "UPtr", wParam, "Ptr", lParam, "Ptr")
}

_OD_GuiWndProc(hWnd, uMsg, wParam, lParam) {
    global gOD_OrigGuiProc, gOD_Items

    if (uMsg = 0x002C) {
        ctlType := NumGet(lParam, 0, "UInt")
        _OD_Log("WM_MEASUREITEM on GuiHwnd | CtlType=" ctlType " items=" gOD_Items.Count)
        if (ctlType = 3 && gOD_Items.Count > 0) {
            _OD_DoMeasure(lParam)
            return 1
        }
    }

    if (uMsg = 0x002B) {
        ctlType := NumGet(lParam, 0, "UInt")
        _OD_Log("WM_DRAWITEM on GuiHwnd | CtlType=" ctlType " items=" gOD_Items.Count)
        if (ctlType = 3 && gOD_Items.Count > 0) {
            _OD_DoDraw(lParam)
            return 1
        }
    }

    return DllCall("CallWindowProcW", "Ptr", gOD_OrigGuiProc, "Ptr", hWnd, "UInt", uMsg, "UPtr", wParam, "Ptr", lParam, "Ptr")
}

; --- Measure and Draw ---

_OD_DoMeasure(lParam) {
    global gOD_Items
    ; itemData at offset 24 (x64 padded), fallback 20 (x86)
    dataId := NumGet(lParam, 24, "UInt")
    if (!gOD_Items.Has(dataId))
        dataId := NumGet(lParam, 20, "UInt")

    isSep := gOD_Items.Has(dataId) && gOD_Items[dataId].isSep

    ; Always set dimensions (prevents skinny menu if lookup fails)
    NumPut("UInt", isSep ? 9 : 32, lParam, 16)   ; itemHeight
    NumPut("UInt", 240, lParam, 12)                ; itemWidth
    _OD_Log("  DoMeasure dataId=" dataId " isSep=" isSep " h=" (isSep ? 9 : 32))
}

_OD_DoDraw(lParam) {
    global gOD_Items

    ; --- Read DRAWITEMSTRUCT (x64 padded offsets) ---
    itemState := NumGet(lParam, 16, "UInt")
    hdc       := NumGet(lParam, 32, "Ptr")
    left      := NumGet(lParam, 40, "Int")
    top       := NumGet(lParam, 44, "Int")
    right     := NumGet(lParam, 48, "Int")
    bottom    := NumGet(lParam, 52, "Int")

    _OD_Log("  DoDraw hdc=" hdc " rect=" left "," top "," right "," bottom)

    if (!hdc)
        return

    ; itemData at offset 56 (x64 padded), fallback 52
    dataId := NumGet(lParam, 56, "UInt")
    if (!gOD_Items.Has(dataId))
        dataId := NumGet(lParam, 52, "UInt")

    ; Fallback for unknown items - still paint something visible
    if (!gOD_Items.Has(dataId))
        item := {text: "(item " NumGet(lParam, 8, "UInt") ")", isSep: false, hasSubmenu: false}
    else
        item := gOD_Items[dataId]

    isSelected := !!(itemState & 0x0001)   ; ODS_SELECTED
    isDisabled := !!(itemState & 0x0004)   ; ODS_GRAYED
    isChecked  := !!(itemState & 0x0008)   ; ODS_CHECKED

    ; --- Background ---
    bgClr := (isSelected && !isDisabled) ? CLR_DM_SEL : CLR_DM_BG
    hBr := DllCall("CreateSolidBrush", "UInt", bgClr, "Ptr")
    rc := Buffer(16)
    NumPut("Int", left, "Int", top, "Int", right, "Int", bottom, rc)
    DllCall("FillRect", "Ptr", hdc, "Ptr", rc, "Ptr", hBr)
    DllCall("DeleteObject", "Ptr", hBr)

    ; --- Separator ---
    if (item.isSep) {
        sepY := top + 4
        hPen := DllCall("CreatePen", "Int", 0, "Int", 1, "UInt", CLR_DM_SEP, "Ptr")
        old := DllCall("SelectObject", "Ptr", hdc, "Ptr", hPen, "Ptr")
        DllCall("MoveToEx", "Ptr", hdc, "Int", left + 1, "Int", sepY, "Ptr", 0)
        DllCall("LineTo", "Ptr", hdc, "Int", right - 1, "Int", sepY)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", old)
        DllCall("DeleteObject", "Ptr", hPen)
        return
    }

    ; --- Left gutter ---
    gutterW := 30
    if (!isSelected || isDisabled) {
        gutterBr := DllCall("CreateSolidBrush", "UInt", CLR_DM_GUTTER, "Ptr")
        gutterRc := Buffer(16)
        NumPut("Int", left, "Int", top, "Int", left + gutterW, "Int", bottom, gutterRc)
        DllCall("FillRect", "Ptr", hdc, "Ptr", gutterRc, "Ptr", gutterBr)
        DllCall("DeleteObject", "Ptr", gutterBr)
    }

    ; --- Checkmark ---
    if (isChecked) {
        _EnsureChkFont()
        oldF := DllCall("SelectObject", "Ptr", hdc, "Ptr", gOD_ChkFont, "Ptr")
        DllCall("SetBkMode", "Ptr", hdc, "Int", 1)   ; TRANSPARENT
        DllCall("SetTextColor", "Ptr", hdc, "UInt", CLR_DM_CHK)
        chkRc := Buffer(16)
        NumPut("Int", left + 2, "Int", top, "Int", left + gutterW - 2, "Int", bottom, chkRc)
        DllCall("DrawTextW", "Ptr", hdc, "Str", Chr(0x2713), "Int", 1,
            "Ptr", chkRc, "UInt", 0x0025)   ; DT_CENTER | DT_VCENTER | DT_SINGLELINE
        DllCall("SelectObject", "Ptr", hdc, "Ptr", oldF)
    }

    ; --- Text ---
    _EnsureMenuFont()
    oldFont := DllCall("SelectObject", "Ptr", hdc, "Ptr", gOD_MenuFont, "Ptr")
    DllCall("SetBkMode", "Ptr", hdc, "Int", 1)
    DllCall("SetTextColor", "Ptr", hdc, "UInt", isDisabled ? CLR_DM_GRAY : CLR_DM_TEXT)

    textRc := Buffer(16)
    NumPut("Int", left + gutterW + 4, "Int", top, "Int", right - 20, "Int", bottom, textRc)
    DllCall("DrawTextW", "Ptr", hdc, "Str", item.text, "Int", -1,
        "Ptr", textRc, "UInt", 0x0024)   ; DT_SINGLELINE | DT_VCENTER

    ; --- Submenu arrow ---
    if (item.hasSubmenu) {
        DllCall("SetTextColor", "Ptr", hdc, "UInt", isDisabled ? CLR_DM_GRAY : CLR_DM_TEXT)
        arrowRc := Buffer(16)
        NumPut("Int", right - 18, "Int", top, "Int", right - 4, "Int", bottom, arrowRc)
        DllCall("DrawTextW", "Ptr", hdc, "Str", Chr(0x25B8), "Int", 1,
            "Ptr", arrowRc, "UInt", 0x0025)   ; DT_CENTER | DT_VCENTER | DT_SINGLELINE
    }

    DllCall("SelectObject", "Ptr", hdc, "Ptr", oldFont)
}

_EnsureMenuFont() {
    global gOD_MenuFont
    if (gOD_MenuFont)
        return
    gOD_MenuFont := DllCall("CreateFontW",
        "Int", -14, "Int", 0, "Int", 0, "Int", 0,
        "Int", 400, "UInt", 0, "UInt", 0, "UInt", 0,
        "UInt", 1, "UInt", 0, "UInt", 0, "UInt", 5,
        "UInt", 0, "Str", "Segoe UI", "Ptr")
}

_EnsureChkFont() {
    global gOD_ChkFont
    if (gOD_ChkFont)
        return
    gOD_ChkFont := DllCall("CreateFontW",
        "Int", -16, "Int", 0, "Int", 0, "Int", 0,
        "Int", 400, "UInt", 0, "UInt", 0, "UInt", 0,
        "UInt", 1, "UInt", 0, "UInt", 0, "UInt", 5,
        "UInt", 0, "Str", "Segoe UI Symbol", "Ptr")
}

; ============================================================
; Convert/Restore AHK Tray Menu to Owner-Drawn
; ============================================================

; MENUITEMINFOW offsets (x64, 80 bytes total):
; 0:cbSize(4) 4:fMask(4) 8:fType(4) 12:fState(4) 16:wID(4)
; [pad 4] 24:hSubMenu(8) 32:hbmpChecked(8) 40:hbmpUnchecked(8)
; 48:dwItemData(8) 56:dwTypeData(8) 64:cch(4) [pad 4] 72:hbmpItem(8)

MakeTrayOwnerDrawn() {
    global gOD_Items, gOD_NextId
    ; Restore first if already converted (text lost once MFT_OWNERDRAW set)
    if (gOD_Items.Count > 0)
        _RestoreMenuFromOD(A_TrayMenu.Handle)
    gOD_Items := Map()
    gOD_NextId := 1
    _ConvertMenuToOD(A_TrayMenu.Handle)
    ; Replace A_ScriptHwnd's window procedure
    _OD_InstallWndProc()
    _OD_Log("MakeTrayOwnerDrawn complete, items=" gOD_Items.Count)
}

_ConvertMenuToOD(hMenu) {
    global gOD_Items, gOD_NextId
    count := DllCall("GetMenuItemCount", "Ptr", hMenu, "Int")
    if (count <= 0)
        return

    mii := Buffer(80, 0)
    textBuf := Buffer(512, 0)

    loop count {
        i := A_Index - 1

        ; Get current item info
        NumPut("UInt", 80, mii, 0)             ; cbSize
        NumPut("UInt", 0x0147, mii, 4)         ; MIIM_FTYPE|STATE|ID|SUBMENU|STRING
        NumPut("Ptr", textBuf.Ptr, mii, 56)    ; dwTypeData buffer
        NumPut("UInt", 255, mii, 64)           ; cch
        if (!DllCall("GetMenuItemInfoW", "Ptr", hMenu, "UInt", i, "Int", 1, "Ptr", mii))
            continue

        fType := NumGet(mii, 8, "UInt")
        hSub  := NumGet(mii, 24, "Ptr")
        text  := StrGet(textBuf, "UTF-16")
        isSep := !!(fType & 0x0800)

        ; Store item data with unique ID
        myId := gOD_NextId++
        gOD_Items[myId] := {text: text, isSep: isSep, hasSubmenu: hSub != 0}
        _OD_Log("  Item " i ": id=" myId " text='" text "' sep=" isSep " sub=" (hSub != 0))

        ; Set MFT_OWNERDRAW + dwItemData
        NumPut("UInt", 80, mii, 0)
        NumPut("UInt", 0x0120, mii, 4)         ; MIIM_FTYPE | MIIM_DATA
        NumPut("UInt", fType | 0x0100, mii, 8) ; add MFT_OWNERDRAW
        NumPut("UPtr", myId, mii, 48)          ; dwItemData = our ID
        DllCall("SetMenuItemInfoW", "Ptr", hMenu, "UInt", i, "Int", 1, "Ptr", mii)

        ; Recurse into submenus
        if (hSub)
            _ConvertMenuToOD(hSub)
    }
}

RestoreTrayNormal() {
    _RestoreMenuFromOD(A_TrayMenu.Handle)
    _OD_RemoveWndProc()
    global gOD_Items
    gOD_Items := Map()
}

_RestoreMenuFromOD(hMenu) {
    global gOD_Items
    count := DllCall("GetMenuItemCount", "Ptr", hMenu, "Int")
    if (count <= 0)
        return

    mii := Buffer(80, 0)
    loop count {
        i := A_Index - 1

        NumPut("UInt", 80, mii, 0)
        NumPut("UInt", 0x0124, mii, 4)   ; MIIM_FTYPE | MIIM_DATA | MIIM_SUBMENU
        if (!DllCall("GetMenuItemInfoW", "Ptr", hMenu, "UInt", i, "Int", 1, "Ptr", mii))
            continue

        fType  := NumGet(mii, 8, "UInt")
        hSub   := NumGet(mii, 24, "Ptr")
        dataId := NumGet(mii, 48, "UPtr")

        ; Clear MFT_OWNERDRAW
        newType := fType & ~0x0100

        if (gOD_Items.Has(dataId) && !gOD_Items[dataId].isSep) {
            ; Restore text
            text := gOD_Items[dataId].text
            NumPut("UInt", 80, mii, 0)
            NumPut("UInt", 0x0140, mii, 4)      ; MIIM_FTYPE | MIIM_STRING
            NumPut("UInt", newType, mii, 8)
            NumPut("Ptr", StrPtr(text), mii, 56) ; dwTypeData
            DllCall("SetMenuItemInfoW", "Ptr", hMenu, "UInt", i, "Int", 1, "Ptr", mii)
        } else {
            NumPut("UInt", 80, mii, 0)
            NumPut("UInt", 0x0100, mii, 4)       ; MIIM_FTYPE
            NumPut("UInt", newType, mii, 8)
            DllCall("SetMenuItemInfoW", "Ptr", hMenu, "UInt", i, "Int", 1, "Ptr", mii)
        }

        if (hSub)
            _RestoreMenuFromOD(hSub)
    }
}

; ============================================================
; Standalone Owner-Drawn Popup (button test)
; ============================================================

ShowPopupMenu(*) {
    ; Defer via timer to avoid re-entrancy with button handler
    SetTimer(_DoShowPopup, -1)
}

_DoShowPopup() {
    global gOD_Items, gOD_NextId, demoGui

    _OD_Log("=== ShowPopup START ===")

    ; Use high ID range for popup items (preserve tray items in low range)
    startId := 10000
    savedNextId := gOD_NextId
    gOD_NextId := startId

    hMenu := DllCall("CreatePopupMenu", "Ptr")

    _AddPopupItem(hMenu, 1001, "Dashboard...")
    _AddPopupItem(hMenu, 1002, "Config Editor...")
    _AddPopupSep(hMenu)
    _AddPopupItem(hMenu, 1003, "Check for Updates")
    _AddPopupItemDisabled(hMenu, 1004, "Disabled Item")
    _AddPopupSep(hMenu)
    _AddPopupItem(hMenu, 1005, "Checked Item")
    DllCall("CheckMenuItem", "Ptr", hMenu, "UInt", 1005, "UInt", 0x0008)

    ; Submenu
    hSub := DllCall("CreatePopupMenu", "Ptr")
    _AddPopupItem(hSub, 2001, "Sub Item 1")
    _AddPopupItem(hSub, 2002, "Sub Item 2")
    _AddPopupSep(hSub)
    _AddPopupItem(hSub, 2003, "Sub Item 3")

    myId := gOD_NextId++
    gOD_Items[myId] := {text: "Submenu Test", isSep: false, hasSubmenu: true}
    DllCall("AppendMenuW", "Ptr", hMenu, "UInt", 0x0110, "UPtr", hSub, "UPtr", myId)

    _AddPopupSep(hMenu)
    _AddPopupItem(hMenu, 1006, "Exit")

    ; Install wndproc replacement on demo GUI window
    _OD_InstallGuiWndProc(demoGui.Hwnd)
    _OD_Log("Items registered: " gOD_Items.Count " | GuiHwnd=" demoGui.Hwnd)

    ; Show at cursor
    pt := Buffer(8)
    DllCall("GetCursorPos", "Ptr", pt)
    x := NumGet(pt, 0, "Int"), y := NumGet(pt, 4, "Int")

    DllCall("SetForegroundWindow", "Ptr", demoGui.Hwnd)
    _OD_Log("Calling TrackPopupMenu...")
    cmd := DllCall("TrackPopupMenu", "Ptr", hMenu,
        "UInt", 0x0100, "Int", x, "Int", y,
        "Int", 0, "Ptr", demoGui.Hwnd, "Ptr", 0, "UInt")
    _OD_Log("TrackPopupMenu returned: " cmd)

    ; Post WM_NULL to properly close (TrackPopupMenu requirement)
    DllCall("PostMessageW", "Ptr", demoGui.Hwnd, "UInt", 0, "UPtr", 0, "Ptr", 0)

    DllCall("DestroyMenu", "Ptr", hMenu)

    ; Remove wndproc replacement
    _OD_RemoveGuiWndProc(demoGui.Hwnd)

    ; Clean up popup items (preserve tray items below startId)
    toDelete := []
    for id, _ in gOD_Items {
        if (id >= startId)
            toDelete.Push(id)
    }
    for _, id in toDelete
        gOD_Items.Delete(id)

    gOD_NextId := savedNextId

    if (cmd)
        UpdateStatus("Popup: item " cmd " clicked")
    _OD_Log("=== ShowPopup END ===")
}

_AddPopupItem(hMenu, cmdId, text) {
    global gOD_Items, gOD_NextId
    myId := gOD_NextId++
    gOD_Items[myId] := {text: text, isSep: false, hasSubmenu: false}
    DllCall("AppendMenuW", "Ptr", hMenu, "UInt", 0x0100, "UPtr", cmdId, "UPtr", myId)
}

_AddPopupItemDisabled(hMenu, cmdId, text) {
    global gOD_Items, gOD_NextId
    myId := gOD_NextId++
    gOD_Items[myId] := {text: text, isSep: false, hasSubmenu: false}
    DllCall("AppendMenuW", "Ptr", hMenu, "UInt", 0x0101, "UPtr", cmdId, "UPtr", myId)
}

_AddPopupSep(hMenu) {
    global gOD_Items, gOD_NextId
    myId := gOD_NextId++
    gOD_Items[myId] := {text: "", isSep: true, hasSubmenu: false}
    DllCall("AppendMenuW", "Ptr", hMenu, "UInt", 0x0900, "UPtr", 0, "UPtr", myId)
}

; ============================================================
; Approach C: GUI-Based Popup Menu
; ============================================================
; A borderless Gui window styled as a dark menu.
; No Win32 owner-draw needed - full AHK control.

global gGuiMenu := ""
global gGuiMenuItems := []

ShowGuiPopupMenu(*) {
    SetTimer(_DoShowGuiPopup, -1)
}

_DoShowGuiPopup() {
    global gGuiMenu, gGuiMenuItems, demoGui

    ; Close any existing menu
    if (gGuiMenu) {
        try gGuiMenu.Destroy()
        gGuiMenu := ""
    }

    items := []
    items.Push({text: "Dashboard...", enabled: true, checked: false, sep: false, id: 1})
    items.Push({text: "Config Editor...", enabled: true, checked: false, sep: false, id: 2})
    items.Push({text: "", enabled: true, checked: false, sep: true, id: 0})
    items.Push({text: "Check for Updates", enabled: true, checked: false, sep: false, id: 3})
    items.Push({text: "Disabled Item", enabled: false, checked: false, sep: false, id: 4})
    items.Push({text: "", enabled: true, checked: false, sep: true, id: 0})
    items.Push({text: "Checked Item", enabled: true, checked: true, sep: false, id: 5})
    items.Push({text: "", enabled: true, checked: false, sep: true, id: 0})
    items.Push({text: "Exit", enabled: true, checked: false, sep: false, id: 6})

    gGuiMenuItems := items

    ; Calculate dimensions
    itemH := 28
    sepH := 9
    menuW := 220
    gutterW := 28
    totalH := 4   ; top padding
    for _, item in items
        totalH += item.sep ? sepH : itemH
    totalH += 4    ; bottom padding

    ; Create borderless popup
    g := Gui("+ToolWindow -Caption +Border +AlwaysOnTop +Owner" demoGui.Hwnd)
    g.BackColor := "2C2C2C"
    g.MarginX := 0
    g.MarginY := 0

    ; Dark title bar (for the border)
    val := Buffer(4, 0)
    NumPut("Int", 1, val)
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", g.Hwnd, "Int", 20, "Ptr", val, "Int", 4, "Int")

    yPos := 2
    for idx, item in items {
        if (item.sep) {
            ; Separator: dark line
            g.SetFont("s1")
            sep := g.AddText("x0 y" (yPos + 3) " w" menuW " h1 +0x1000")  ; SS_ETCHEDHORZ
            yPos += sepH
        } else {
            ; Menu item: clickable text with gutter
            g.SetFont("s10", "Segoe UI")

            txtColor := item.enabled ? "E8E8E8" : "808080"
            g.SetFont("c" txtColor)

            ; Check mark
            prefix := item.checked ? Chr(0x2713) " " : "   "

            ctrl := g.AddText(
                "x0 y" yPos " w" menuW " h" itemH " +0x200",  ; SS_CENTERIMAGE (v-center)
                "  " prefix item.text)

            if (item.enabled) {
                ctrl.OnEvent("Click", _GuiMenuItem_Click.Bind(item.id, item.text))
            }

            yPos += itemH
        }
    }

    ; Show at cursor
    pt := Buffer(8)
    DllCall("GetCursorPos", "Ptr", pt)
    x := NumGet(pt, 0, "Int"), y := NumGet(pt, 4, "Int")

    g.Show("x" x " y" y " w" menuW " h" totalH " NoActivate")
    gGuiMenu := g

    ; Dismiss when clicking outside
    g.OnEvent("Close", (*) => _GuiMenu_Dismiss())

    ; Use timer to poll for mouse-outside-click dismissal
    SetTimer(_GuiMenu_CheckDismiss, 50)
}

_GuiMenuItem_Click(itemId, itemText, *) {
    global demoGui
    _GuiMenu_Dismiss()
    UpdateStatus("GUI Menu: '" itemText "' (id " itemId ") clicked")
}

_GuiMenu_Dismiss() {
    global gGuiMenu
    SetTimer(_GuiMenu_CheckDismiss, 0)
    if (gGuiMenu) {
        try gGuiMenu.Destroy()
        gGuiMenu := ""
    }
}

_GuiMenu_CheckDismiss() {
    global gGuiMenu
    if (!gGuiMenu)
        return SetTimer(_GuiMenu_CheckDismiss, 0)

    ; Check if mouse clicked outside
    if (GetKeyState("LButton", "P") || GetKeyState("RButton", "P")) {
        try {
            MouseGetPos(, , &winUnder)
            if (winUnder != gGuiMenu.Hwnd)
                _GuiMenu_Dismiss()
        }
    }

    ; Also dismiss on Escape
    if (GetKeyState("Escape", "P"))
        _GuiMenu_Dismiss()
}

; ============================================================
; Tray Menu Setup
; ============================================================

SetupTrayMenu() {
    tray := A_TrayMenu
    tray.Delete()

    tray.Add("Dark Tray Menu Demo", (*) => (demoGui.Show(), WinActivate(demoGui.Hwnd)))
    tray.Default := "Dark Tray Menu Demo"
    tray.Add()

    sub := Menu()
    sub.Add("Sub Item 1", (*) => ToolTip("Sub 1 clicked"))
    sub.Add("Sub Item 2", (*) => ToolTip("Sub 2 clicked"))
    sub.Add()
    sub.Add("Sub Item 3", (*) => ToolTip("Sub 3 clicked"))
    tray.Add("Submenu Test", sub)

    tray.Add()
    tray.Add("Toggle Check", ToggleCheckItem)
    tray.Add("Disabled Item", (*) => 0)
    tray.Disable("Disabled Item")
    tray.Add()
    tray.Add("Exit", (*) => ExitApp())
}

ToggleCheckItem(*) {
    static checked := false
    checked := !checked
    if (checked)
        A_TrayMenu.Check("Toggle Check")
    else
        A_TrayMenu.Uncheck("Toggle Check")
}

SetupTrayMenu()

; ============================================================
; Demo GUI
; ============================================================

global demoGui := Gui(, "Dark Tray Menu Demo")
demoGui.SetFont("s10", "Segoe UI")

demoGui.AddText("x20 y15 w460 +Wrap",
    "Compare approaches for dark tray/context menus.`n"
    "Right-click the tray icon to see the current mode.")

; -- Approach A --
demoGui.AddGroupBox("x20 y55 w460 h110", "Approach A: SetPreferredAppMode (Recommended)")
demoGui.AddText("x35 y75 w430 +Wrap",
    "Undocumented uxtheme ordinal #135. ~5 lines. Free dark mode "
    "for ALL menus (tray, context, popup). Stable 5+ years.")

btnADark := demoGui.AddButton("x35 y110 w135 h28", "Force Dark")
btnADark.OnEvent("Click", (*) => (
    RestoreTrayNormal(), ApplyAppMode(2), UpdateStatus("A: ForceDark")))

btnAAuto := demoGui.AddButton("x180 y110 w135 h28", "Follow System")
btnAAuto.OnEvent("Click", (*) => (
    RestoreTrayNormal(), ApplyAppMode(1), UpdateStatus("A: AllowDark")))

btnALight := demoGui.AddButton("x325 y110 w135 h28", "Default (Light)")
btnALight.OnEvent("Click", (*) => (
    RestoreTrayNormal(), ApplyAppMode(0), UpdateStatus("A: Default")))

; -- Approach B --
demoGui.AddGroupBox("x20 y175 w460 h130", "Approach B: Owner-Drawn (Win32 WndProc Replace)")
demoGui.AddText("x35 y195 w430 +Wrap",
    "MF_OWNERDRAW + WM_DRAWITEM via raw WndProc replacement. "
    "Full GDI control. Diagnostic log written to:`n"
    A_Temp "\tabby_od_menu_diag.log")

btnBOD := demoGui.AddButton("x35 y260 w200 h28", "Make Tray Owner-Drawn")
btnBOD.OnEvent("Click", (*) => (
    MakeTrayOwnerDrawn(), UpdateStatus("B: Tray is owner-drawn")))

btnBRestore := demoGui.AddButton("x245 y260 w200 h28", "Restore Normal Tray")
btnBRestore.OnEvent("Click", (*) => (
    RestoreTrayNormal(), ApplyAppMode(0), UpdateStatus("Restored to default")))

; -- Approach B test popup --
demoGui.AddGroupBox("x20 y315 w460 h55", "Test: Owner-Drawn Popup (Win32)")
btnPopup := demoGui.AddButton("x35 y335 w200 h28", "Show OD Popup at Cursor")
btnPopup.OnEvent("Click", ShowPopupMenu)

; -- Approach C --
demoGui.AddGroupBox("x20 y380 w460 h55", "Approach C: GUI-Based Popup (No Win32)")
btnGuiMenu := demoGui.AddButton("x35 y400 w200 h28", "Show GUI Menu at Cursor")
btnGuiMenu.OnEvent("Click", ShowGuiPopupMenu)

; -- Status --
demoGui.AddGroupBox("x20 y445 w460 h60", "Current State")
demoGui.AddText("x35 y465 w430 vStatusText", "Mode: Default (light menus)")
demoGui.AddText("x35 y483 w430 vNoteText +Wrap cGray",
    "Right-click tray to test. Check diag log for B callback debug info.")

demoGui.OnEvent("Close", (*) => ExitApp())
demoGui.Show("w500 h520")

; Clean up diag log on start
try FileDelete(gOD_LogFile)
_OD_Log("=== Mock started ===")
_OD_Log("A_ScriptHwnd=" A_ScriptHwnd " | demoGui.Hwnd=" demoGui.Hwnd)
_OD_Log("A_PtrSize=" A_PtrSize)

UpdateStatus(mode) {
    global demoGui
    demoGui["StatusText"].Text := "Mode: " mode
}
