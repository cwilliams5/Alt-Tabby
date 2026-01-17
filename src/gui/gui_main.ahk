#Requires AutoHotkey v2.0
#SingleInstance Force
#UseHook true
InstallKeybdHook(true)

; Alt-Tabby GUI - Integrated with WindowStore and Interceptor (hooks built-in)
; Use an inert mask key so Alt taps don't focus menus
A_MenuMaskKey := "vkE8"

#Include %A_ScriptDir%\..\shared\config.ahk
#Include %A_ScriptDir%\..\shared\json.ahk
#Include %A_ScriptDir%\..\shared\ipc_pipe.ahk
#Include %A_ScriptDir%\..\interceptor\interceptor_ipc.ahk
#Include %A_ScriptDir%\gui_config.ahk
#Include %A_ScriptDir%\gui_gdip.ahk
#Include %A_ScriptDir%\gui_win.ahk

; ========================= GLOBAL STATE =========================

global gGUI_Revealed := false
global gGUI_HoverRow := 0
global gGUI_HoverBtn := ""
global gGUI_FooterText := "All Windows"

global gGUI_StoreClient := 0
global gGUI_StoreConnected := false
global gGUI_StoreRev := -1

global gGUI_OverlayVisible := false
global gGUI_Base := 0
global gGUI_Overlay := 0
global gGUI_BaseH := 0
global gGUI_OverlayH := 0
global gGUI_Items := []
global gGUI_Sel := 1
global gGUI_ScrollTop := 0
global gGUI_LastRowsDesired := -1

; State machine: IDLE -> ALT_PENDING -> ACTIVE
; IDLE: Normal state, receiving/applying deltas, cache fresh
; ALT_PENDING: Alt held, optional pre-warm, still receiving deltas
; ACTIVE: List FROZEN on first Tab, ignores all updates, Tab cycles selection
global gGUI_State := "IDLE"
global gGUI_AltDownTick := 0
global gGUI_FirstTabTick := 0
global gGUI_TabCount := 0
global gGUI_FrozenItems := []  ; Snapshot of items when locking in

; ========================= INTERCEPTOR STATE (built-in hooks) =========================
; These variables track the keyboard hook state (previously in interceptor.ahk)
global gINT_DecisionMs := 24          ; Tab decision window
global gINT_LastAltLeewayMs := 60     ; Alt timing tolerance
global gINT_DisableInProcesses := []
global gINT_DisableInFullscreen := true

global gINT_SessionActive := false
global gINT_TabHeld := false
global gINT_PressCount := 0
global gINT_LastAltDown := -999999
global gINT_AltIsDown := false        ; Track Alt state via hotkey handlers

; Deferred-Tab decision state
global gINT_TabPending := false
global gINT_TabUpSeen := false
global gINT_PendingShift := false
global gINT_PendingDecideArmed := false
global gINT_AltUpDuringPending := false  ; Track if Alt released before Tab_Decide

; ========================= INITIALIZATION =========================

GUI_Main_Init() {
    global gGUI_StoreClient, StorePipeName

    Win_InitDpiAwareness()
    Gdip_Startup()

    ; Set up interceptor keyboard hooks (built-in, no IPC)
    INT_SetupHotkeys()

    ; Connect to WindowStore
    gGUI_StoreClient := IPC_PipeClient_Connect(StorePipeName, GUI_OnStoreMessage)
    if (gGUI_StoreClient.hPipe) {
        ; Request deltas so we stay up to date like the viewer
        hello := { type: IPC_MSG_HELLO, wants: { deltas: true }, projectionOpts: { sort: "MRU", columns: "items" } }
        IPC_PipeClient_Send(gGUI_StoreClient, JXON_Dump(hello))
    }
}

; ========================= INTERCEPTOR HOOKS (built-in) =========================

INT_SetupHotkeys() {
    ; Alt hooks (pass-through, just observe)
    Hotkey("~*Alt", INT_Alt_Down)
    Hotkey("~*Alt Up", INT_Alt_Up)

    ; Tab hooks (intercept for decision)
    Hotkey("$*Tab", INT_Tab_Down)
    Hotkey("$*Tab Up", INT_Tab_Up)

    ; Escape hook
    Hotkey("$*Escape", INT_Escape_Down)

    ; Exit hotkey
    Hotkey("$*!F12", (*) => ExitApp())
}

INT_Alt_Down(*) {
    global gINT_LastAltDown, gINT_AltIsDown, TABBY_EV_ALT_DOWN
    gINT_AltIsDown := true
    gINT_LastAltDown := A_TickCount

    ; Mask key to prevent menu focus
    try Send("{Blind}{vkE8}")

    ; Notify GUI handler directly (no IPC)
    GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
}

INT_Alt_Up(*) {
    global gINT_SessionActive, gINT_PressCount, gINT_TabHeld, gINT_TabPending
    global gINT_AltUpDuringPending, gINT_AltIsDown, TABBY_EV_ALT_UP

    gINT_AltIsDown := false

    ; If Tab decision is pending, mark that Alt was released
    if (gINT_TabPending) {
        gINT_AltUpDuringPending := true
        ; Don't send ALT_UP here - Tab_Decide will handle it
    } else if (gINT_SessionActive && gINT_PressCount >= 1) {
        ; Session was active, send ALT_UP directly
        GUI_OnInterceptorEvent(TABBY_EV_ALT_UP, 0, 0)
    }
    ; else: No active session, ignore

    gINT_SessionActive := false
    gINT_PressCount := 0
    gINT_TabHeld := false
}

INT_Tab_Down(*) {
    global gINT_TabPending, gINT_TabHeld, gINT_PendingShift, gINT_TabUpSeen
    global gINT_PendingDecideArmed, gINT_DecisionMs, gINT_AltUpDuringPending

    if (INT_ShouldBypass()) {
        Send(GetKeyState("Shift", "P") ? "+{Tab}" : "{Tab}")
        return
    }

    ; Already pending, or held from Alt+Tab step - block key repeat
    if (gINT_TabPending || gINT_TabHeld)
        return

    ; Swallow Tab briefly and decide if this is Alt+Tab
    gINT_TabPending := true
    gINT_PendingShift := GetKeyState("Shift", "P")
    gINT_TabUpSeen := false
    gINT_PendingDecideArmed := true
    gINT_AltUpDuringPending := false
    SetTimer(INT_Tab_Decide, -gINT_DecisionMs)
}

INT_Tab_Up(*) {
    global gINT_TabHeld, gINT_TabPending, gINT_TabUpSeen

    if (gINT_TabHeld) {
        ; Released from Alt+Tab step
        gINT_TabHeld := false
        return
    }
    ; If still deciding, remember Tab went up
    if (gINT_TabPending)
        gINT_TabUpSeen := true
}

INT_Tab_Decide() {
    global gINT_PendingDecideArmed
    if (!gINT_PendingDecideArmed)
        return
    gINT_PendingDecideArmed := false
    ; Small delay to let Alt_Up run first if it's pending
    SetTimer(INT_Tab_Decide_Inner, -1)
}

INT_Tab_Decide_Inner() {
    global gINT_TabPending, gINT_TabUpSeen, gINT_PendingShift, gINT_AltUpDuringPending
    global gINT_LastAltDown, gINT_LastAltLeewayMs, gINT_AltIsDown
    global gINT_SessionActive, gINT_PressCount, gINT_TabHeld
    global TABBY_EV_TAB_STEP, TABBY_EV_ALT_UP, TABBY_FLAG_SHIFT

    ; Capture state NOW (before any potential message pumping)
    altDownNow := gINT_AltIsDown
    altUpFlag := gINT_AltUpDuringPending
    altRecent := (A_TickCount - gINT_LastAltDown) <= gINT_LastAltLeewayMs
    isAltTab := altDownNow || altRecent || altUpFlag

    if (isAltTab) {
        ; This is an Alt+Tab press
        gINT_TabPending := false

        if (!gINT_SessionActive) {
            gINT_SessionActive := true
            gINT_PressCount := 0
        }
        gINT_PressCount += 1

        ; Send TAB_STEP directly to GUI handler
        shiftFlag := gINT_PendingShift ? TABBY_FLAG_SHIFT : 0
        GUI_OnInterceptorEvent(TABBY_EV_TAB_STEP, shiftFlag, 0)

        ; Track Tab held state
        gINT_TabHeld := !gINT_TabUpSeen

        ; CRITICAL: If Alt was released during decision window, send ALT_UP now
        if (!altDownNow || altUpFlag) {
            GUI_OnInterceptorEvent(TABBY_EV_ALT_UP, 0, 0)
            gINT_SessionActive := false
            gINT_PressCount := 0
            gINT_TabHeld := false
            gINT_AltUpDuringPending := false
        }
    } else {
        ; Not Alt+Tab - replay normal Tab
        gINT_TabPending := false
        Send(gINT_PendingShift ? "+{Tab}" : "{Tab}")
    }
}

INT_Escape_Down(*) {
    global gINT_SessionActive, gINT_PressCount, gINT_TabHeld, TABBY_EV_ESCAPE

    ; Only consume Escape if in active Alt+Tab session
    if (!gINT_SessionActive || gINT_PressCount < 1) {
        Send("{Escape}")
        return
    }

    ; Notify GUI to cancel
    GUI_OnInterceptorEvent(TABBY_EV_ESCAPE, 0, 0)

    ; Reset session state
    gINT_SessionActive := false
    gINT_PressCount := 0
    gINT_TabHeld := false
}

INT_ShouldBypass() {
    global gINT_DisableInProcesses, gINT_DisableInFullscreen

    exename := ""
    try exename := WinGetProcessName("A")
    if (exename) {
        lex := StrLower(exename)
        for _, nm in gINT_DisableInProcesses {
            if (StrLower(nm) = lex)
                return true
        }
    }
    return gINT_DisableInFullscreen && INT_IsFullscreen("A")
}

INT_IsFullscreen(win := "A") {
    local x := 0, y := 0, w := 0, h := 0
    try WinGetPos(&x, &y, &w, &h, win)
    return (w >= A_ScreenWidth * 0.99 && h >= A_ScreenHeight * 0.99 && x <= 5 && y <= 5)
}

; ========================= GUI EVENT HANDLERS =========================

GUI_OnInterceptorEvent(evCode, flags, lParam) {
    global gGUI_State, gGUI_AltDownTick, gGUI_FirstTabTick, gGUI_TabCount
    global gGUI_OverlayVisible, gGUI_Items, gGUI_Sel, gGUI_FrozenItems
    global AltTabGraceMs, AltTabPrewarmOnAlt, AltTabQuickSwitchMs
    global TABBY_EV_ALT_DOWN, TABBY_EV_TAB_STEP, TABBY_EV_ALT_UP, TABBY_EV_ESCAPE, TABBY_FLAG_SHIFT

    if (evCode = TABBY_EV_ALT_DOWN) {
        ; Alt pressed - enter ALT_PENDING state
        gGUI_State := "ALT_PENDING"
        gGUI_AltDownTick := A_TickCount
        gGUI_FirstTabTick := 0
        gGUI_TabCount := 0

        ; Pre-warm: request snapshot now so data is ready when Tab pressed
        if (AltTabPrewarmOnAlt) {
            GUI_RequestSnapshot()
        }
        return
    }

    if (evCode = TABBY_EV_TAB_STEP) {
        shiftHeld := (flags & TABBY_FLAG_SHIFT) != 0

        if (gGUI_State = "IDLE") {
            ; Tab without Alt (shouldn't happen normally, interceptor handles this)
            return
        }

        if (gGUI_State = "ALT_PENDING") {
            ; First Tab - freeze IMMEDIATELY with current data and go to ACTIVE
            gGUI_FirstTabTick := A_TickCount
            gGUI_TabCount := 1
            gGUI_State := "ACTIVE"

            ; Freeze the current items list NOW (whatever deltas have given us)
            gGUI_FrozenItems := []
            for _, item in gGUI_Items {
                gGUI_FrozenItems.Push(item)
            }

            ; Selection: First Alt+Tab selects the PREVIOUS window (position 2 in 1-based MRU list)
            ; Position 1 = current window (we're already on it)
            ; Position 2 = previous window (what Alt+Tab should switch to)
            gGUI_Sel := 2
            if (gGUI_Sel > gGUI_FrozenItems.Length) {
                ; Only 1 window? Select it
                gGUI_Sel := 1
            }
            ; Pin selection at top (virtual scroll)
            gGUI_ScrollTop := gGUI_Sel - 1

            ; Start grace timer - show GUI after delay
            SetTimer(GUI_GraceTimerFired, -AltTabGraceMs)
            return
        }

        if (gGUI_State = "ACTIVE") {
            gGUI_TabCount += 1
            delta := shiftHeld ? -1 : 1
            GUI_MoveSelectionFrozen(delta)

            ; If GUI not yet visible (still in grace period), show it now on 2nd Tab
            if (!gGUI_OverlayVisible && gGUI_TabCount > 1) {
                SetTimer(GUI_GraceTimerFired, 0)  ; Cancel grace timer
                GUI_ShowOverlayWithFrozen()
            } else if (gGUI_OverlayVisible) {
                GUI_Repaint()
            }
        }
        return
    }

    if (evCode = TABBY_EV_ALT_UP) {
        ; DEBUG: Show ALT_UP arrival
        ToolTip("ALT_UP: state=" gGUI_State " visible=" gGUI_OverlayVisible, 100, 200, 3)
        SetTimer(() => ToolTip(,,,3), -2000)

        if (gGUI_State = "ALT_PENDING") {
            ; Alt released without Tab - return to IDLE
            gGUI_State := "IDLE"
            return
        }

        if (gGUI_State = "ACTIVE") {
            SetTimer(GUI_GraceTimerFired, 0)  ; Cancel grace timer

            timeSinceTab := A_TickCount - gGUI_FirstTabTick

            if (!gGUI_OverlayVisible && timeSinceTab < AltTabQuickSwitchMs) {
                ; Quick switch: Alt+Tab released quickly, no GUI shown
                GUI_ActivateFromFrozen()
            } else if (gGUI_OverlayVisible) {
                ; Normal case: activate selected and hide
                GUI_ActivateFromFrozen()
                GUI_HideOverlay()
            } else {
                ; Edge case: grace period expired but GUI not shown yet
                GUI_ActivateFromFrozen()
            }

            gGUI_State := "IDLE"
            gGUI_FrozenItems := []

            ; Resync with store - we may have missed deltas during ACTIVE
            GUI_RequestSnapshot()
        }
        return
    }

    if (evCode = TABBY_EV_ESCAPE) {
        ; Cancel - hide without activating
        SetTimer(GUI_GraceTimerFired, 0)  ; Cancel grace timer
        if (gGUI_OverlayVisible) {
            GUI_HideOverlay()
        }
        gGUI_State := "IDLE"
        gGUI_FrozenItems := []

        ; Resync with store - we may have missed deltas during ACTIVE
        GUI_RequestSnapshot()
        return
    }
}

GUI_GraceTimerFired() {
    global gGUI_State, gGUI_OverlayVisible

    if (gGUI_State = "ACTIVE" && !gGUI_OverlayVisible) {
        GUI_ShowOverlayWithFrozen()
    }
}

GUI_ShowOverlayWithFrozen() {
    global gGUI_OverlayVisible, gGUI_Base, gGUI_BaseH, gGUI_Overlay, gGUI_OverlayH
    global gGUI_Items, gGUI_FrozenItems, gGUI_Sel, gGUI_ScrollTop, gGUI_Revealed

    if (gGUI_OverlayVisible) {
        return
    }

    ; Use frozen items for display
    gGUI_Items := gGUI_FrozenItems
    ; NOTE: gGUI_Sel and gGUI_ScrollTop are ALREADY set correctly - don't reset them!

    gGUI_Revealed := false

    try {
        gGUI_Base.Show("NA")
    }

    rowsDesired := GUI_ComputeRowsToShow(gGUI_Items.Length)
    GUI_ResizeToRows(rowsDesired)
    GUI_Repaint()  ; Paint with correct sel/scroll from the start

    try {
        gGUI_Overlay.Show("NA")
    }
    Win_DwmFlush()

    gGUI_OverlayVisible := true
}

GUI_MoveSelectionFrozen(delta) {
    global gGUI_Sel, gGUI_FrozenItems, gGUI_ScrollTop

    if (gGUI_FrozenItems.Length = 0) {
        return
    }

    count := gGUI_FrozenItems.Length
    newSel := gGUI_Sel + delta

    ; Wrap around
    if (newSel < 1) {
        newSel := count
    } else if (newSel > count) {
        newSel := 1
    }

    gGUI_Sel := newSel
    ; Pin selection at top row (virtual scroll - list moves, selection stays at top)
    gGUI_ScrollTop := gGUI_Sel - 1
}

GUI_ActivateFromFrozen() {
    global gGUI_Sel, gGUI_FrozenItems

    if (gGUI_Sel < 1 || gGUI_Sel > gGUI_FrozenItems.Length) {
        ToolTip("ACTIVATE: sel=" gGUI_Sel " OUT OF RANGE (len=" gGUI_FrozenItems.Length ")", 100, 150, 2)
        SetTimer(() => ToolTip(,,,2), -2000)
        return
    }

    item := gGUI_FrozenItems[gGUI_Sel]
    hwnd := item.hwnd

    ; DEBUG: Show what we're activating
    ToolTip("ACTIVATE sel=" gGUI_Sel ": " SubStr(item.Title, 1, 40), 100, 150, 2)
    SetTimer(() => ToolTip(,,,2), -2000)

    if (!hwnd) {
        return
    }

    try {
        if (WinExist("ahk_id " hwnd)) {
            if (DllCall("user32\IsIconic", "ptr", hwnd, "int")) {
                DllCall("user32\ShowWindow", "ptr", hwnd, "int", 9)  ; SW_RESTORE
            }
            DllCall("user32\SetForegroundWindow", "ptr", hwnd)
        }
    }
}

GUI_OnStoreMessage(line, hPipe := 0) {
    global gGUI_StoreConnected, gGUI_StoreRev, gGUI_Items, gGUI_Sel
    global gGUI_OverlayVisible, gGUI_OverlayH, gGUI_FooterText
    global gGUI_State  ; CRITICAL: Check state to avoid updating during ACTIVE
    global IPC_MSG_HELLO_ACK, IPC_MSG_SNAPSHOT, IPC_MSG_PROJECTION, IPC_MSG_DELTA

    obj := ""
    try {
        obj := JXON_Load(line)
    } catch {
        return
    }

    if (!IsObject(obj) || !obj.Has("type")) {
        return
    }

    type := obj["type"]

    if (type = IPC_MSG_HELLO_ACK) {
        gGUI_StoreConnected := true
        if (obj.Has("rev")) {
            gGUI_StoreRev := obj["rev"]
        }
        return
    }

    if (type = IPC_MSG_SNAPSHOT || type = IPC_MSG_PROJECTION) {
        ; CRITICAL: When in ACTIVE state, list is FROZEN - ignore incoming data!
        ; This prevents the GUI from showing different items than what gets activated.
        if (gGUI_State = "ACTIVE") {
            ; Still update rev for tracking, but don't touch items
            if (obj.Has("rev")) {
                gGUI_StoreRev := obj["rev"]
            }
            return
        }

        if (obj.Has("payload") && obj["payload"].Has("items")) {
            gGUI_Items := GUI_ConvertStoreItems(obj["payload"]["items"])
            if (gGUI_Sel > gGUI_Items.Length && gGUI_Items.Length > 0) {
                gGUI_Sel := gGUI_Items.Length
            }
            if (gGUI_Sel < 1 && gGUI_Items.Length > 0) {
                gGUI_Sel := 1
            }

            if (obj["payload"].Has("meta") && obj["payload"]["meta"].Has("currentWSName")) {
                wsName := obj["payload"]["meta"]["currentWSName"]
                if (wsName != "") {
                    gGUI_FooterText := wsName
                }
            }

            if (gGUI_OverlayVisible && gGUI_OverlayH) {
                GUI_Repaint()
            }
        }
        if (obj.Has("rev")) {
            gGUI_StoreRev := obj["rev"]
        }
        return
    }

    if (type = IPC_MSG_DELTA) {
        ; CRITICAL: When in ACTIVE state, list is FROZEN - ignore deltas!
        if (gGUI_State = "ACTIVE") {
            if (obj.Has("rev")) {
                gGUI_StoreRev := obj["rev"]
            }
            return
        }

        ; Apply delta incrementally to stay up-to-date
        if (obj.Has("payload")) {
            GUI_ApplyDelta(obj["payload"])
        }
        if (obj.Has("rev")) {
            gGUI_StoreRev := obj["rev"]
        }
        return
    }
}

GUI_ConvertStoreItems(items) {
    result := []
    for _, item in items {
        hwnd := item.Has("hwnd") ? item["hwnd"] : 0
        result.Push({
            hwnd: hwnd,
            Title: item.Has("title") ? item["title"] : "",
            Class: item.Has("class") ? item["class"] : "",
            HWND: Format("0x{:X}", hwnd),
            PID: item.Has("pid") ? "" item["pid"] : "",
            WS: item.Has("workspaceName") ? item["workspaceName"] : "",
            processName: item.Has("processName") ? item["processName"] : "",
            iconHicon: item.Has("iconHicon") ? item["iconHicon"] : 0,
            lastActivatedTick: item.Has("lastActivatedTick") ? item["lastActivatedTick"] : 0
        })
    }
    return result
}

GUI_ApplyDelta(payload) {
    global gGUI_Items, gGUI_Sel

    changed := false

    ; Handle removes - filter out items by hwnd
    if (payload.Has("removes") && payload["removes"].Length) {
        newItems := []
        for _, item in gGUI_Items {
            isRemoved := false
            for _, hwnd in payload["removes"] {
                if (item.hwnd = hwnd) {
                    isRemoved := true
                    break
                }
            }
            if (!isRemoved) {
                newItems.Push(item)
            }
        }
        if (newItems.Length != gGUI_Items.Length) {
            gGUI_Items := newItems
            changed := true
        }
    }

    ; Handle upserts - update existing or add new items
    if (payload.Has("upserts") && payload["upserts"].Length) {
        for _, rec in payload["upserts"] {
            if (!IsObject(rec)) {
                continue
            }
            hwnd := rec.Has("hwnd") ? rec["hwnd"] : 0
            if (!hwnd) {
                continue
            }

            ; Find existing item by hwnd
            found := false
            for i, item in gGUI_Items {
                if (item.hwnd = hwnd) {
                    ; Update existing item
                    if (rec.Has("title")) {
                        item.Title := rec["title"]
                    }
                    if (rec.Has("class")) {
                        item.Class := rec["class"]
                    }
                    if (rec.Has("pid")) {
                        item.PID := "" rec["pid"]
                    }
                    if (rec.Has("workspaceName")) {
                        item.WS := rec["workspaceName"]
                    }
                    if (rec.Has("processName")) {
                        item.processName := rec["processName"]
                    }
                    if (rec.Has("iconHicon")) {
                        item.iconHicon := rec["iconHicon"]
                    }
                    if (rec.Has("lastActivatedTick")) {
                        item.lastActivatedTick := rec["lastActivatedTick"]
                    }
                    found := true
                    changed := true
                    break
                }
            }

            ; Add new item if not found
            if (!found) {
                gGUI_Items.Push({
                    hwnd: hwnd,
                    Title: rec.Has("title") ? rec["title"] : "",
                    Class: rec.Has("class") ? rec["class"] : "",
                    HWND: Format("0x{:X}", hwnd),
                    PID: rec.Has("pid") ? "" rec["pid"] : "",
                    WS: rec.Has("workspaceName") ? rec["workspaceName"] : "",
                    processName: rec.Has("processName") ? rec["processName"] : "",
                    iconHicon: rec.Has("iconHicon") ? rec["iconHicon"] : 0,
                    lastActivatedTick: rec.Has("lastActivatedTick") ? rec["lastActivatedTick"] : 0
                })
                changed := true
            }
        }
    }

    ; Re-sort by MRU (lastActivatedTick descending) if anything changed
    if (changed && gGUI_Items.Length > 1) {
        GUI_SortItemsByMRU()
    }

    ; Clamp selection
    if (gGUI_Sel > gGUI_Items.Length && gGUI_Items.Length > 0) {
        gGUI_Sel := gGUI_Items.Length
    }
    if (gGUI_Sel < 1 && gGUI_Items.Length > 0) {
        gGUI_Sel := 1
    }
}

GUI_SortItemsByMRU() {
    global gGUI_Items

    ; Simple bubble sort by lastActivatedTick descending (higher = more recent = first)
    n := gGUI_Items.Length
    loop n - 1 {
        i := A_Index
        loop n - i {
            j := A_Index
            if (gGUI_Items[j].lastActivatedTick < gGUI_Items[j + 1].lastActivatedTick) {
                ; Swap
                temp := gGUI_Items[j]
                gGUI_Items[j] := gGUI_Items[j + 1]
                gGUI_Items[j + 1] := temp
            }
        }
    }
}

GUI_RequestSnapshot() {
    global gGUI_StoreClient
    if (!gGUI_StoreClient || !gGUI_StoreClient.hPipe) {
        return
    }
    req := { type: IPC_MSG_SNAPSHOT_REQUEST, projectionOpts: { sort: "MRU", columns: "items" } }
    IPC_PipeClient_Send(gGUI_StoreClient, JXON_Dump(req))
}

GUI_ActivateSelected() {
    global gGUI_Items, gGUI_Sel
    if (gGUI_Sel < 1 || gGUI_Sel > gGUI_Items.Length) {
        return
    }
    item := gGUI_Items[gGUI_Sel]
    hwnd := item.hwnd
    if (!hwnd) {
        return
    }

    try {
        if (WinExist("ahk_id " hwnd)) {
            if (DllCall("user32\IsIconic", "ptr", hwnd, "int")) {
                DllCall("user32\ShowWindow", "ptr", hwnd, "int", 9)
            }
            DllCall("user32\SetForegroundWindow", "ptr", hwnd)
        }
    }
}

; ========================= OVERLAY MANAGEMENT =========================

GUI_ShowOverlay() {
    global gGUI_OverlayVisible, gGUI_Base, gGUI_BaseH, gGUI_Overlay, gGUI_OverlayH
    global gGUI_Items, gGUI_Sel, gGUI_ScrollTop, gGUI_Revealed

    if (gGUI_OverlayVisible) {
        return
    }

    gGUI_Sel := 1
    gGUI_ScrollTop := 0
    gGUI_Revealed := false

    try {
        gGUI_Base.Show("NA")
    }

    rowsDesired := GUI_ComputeRowsToShow(gGUI_Items.Length)
    GUI_ResizeToRows(rowsDesired)
    GUI_Repaint()

    try {
        gGUI_Overlay.Show("NA")
    }
    Win_DwmFlush()

    gGUI_OverlayVisible := true
}

GUI_HideOverlay() {
    global gGUI_OverlayVisible, gGUI_Base, gGUI_Overlay, gGUI_Revealed

    if (!gGUI_OverlayVisible) {
        return
    }

    try {
        gGUI_Overlay.Hide()
    }
    try {
        gGUI_Base.Hide()
    }
    gGUI_OverlayVisible := false
    gGUI_Revealed := false
}

GUI_ComputeRowsToShow(count) {
    if (count >= GUI_RowsVisibleMax) {
        return GUI_RowsVisibleMax
    }
    if (count > GUI_RowsVisibleMin) {
        return count
    }
    return GUI_RowsVisibleMin
}

GUI_HeaderBlockDip() {
    if (GUI_ShowHeader) {
        return 32
    }
    return 0
}

GUI_FooterBlockDip() {
    if (GUI_ShowFooter) {
        return GUI_FooterGapTopPx + GUI_FooterHeightPx
    }
    return 0
}

GUI_GetVisibleRows() {
    global gGUI_OverlayH

    ox := 0
    oy := 0
    owPhys := 0
    ohPhys := 0
    Win_GetRectPhys(gGUI_OverlayH, &ox, &oy, &owPhys, &ohPhys)

    scale := Win_GetScaleForWindow(gGUI_OverlayH)
    ohDip := ohPhys / scale

    headerTopDip := GUI_MarginY + GUI_HeaderBlockDip()
    footerDip := GUI_FooterBlockDip()
    usableDip := ohDip - headerTopDip - GUI_MarginY - footerDip

    if (usableDip < GUI_RowHeight) {
        return 0
    }
    return Floor(usableDip / GUI_RowHeight)
}

; ========================= SELECTION =========================

GUI_MoveSelection(delta) {
    global gGUI_Sel, gGUI_Items, gGUI_ScrollTop, gGUI_OverlayH

    if (gGUI_Items.Length = 0 || delta = 0) {
        return
    }

    count := gGUI_Items.Length
    vis := GUI_GetVisibleRows()
    if (vis <= 0) {
        vis := 1
    }
    if (vis > count) {
        vis := count
    }

    if (GUI_ScrollKeepHighlightOnTop) {
        if (delta > 0) {
            gGUI_Sel := Win_Wrap1(gGUI_Sel + 1, count)
        } else {
            gGUI_Sel := Win_Wrap1(gGUI_Sel - 1, count)
        }
        gGUI_ScrollTop := gGUI_Sel - 1
    } else {
        top0 := gGUI_ScrollTop
        if (delta > 0) {
            gGUI_Sel := Win_Wrap1(gGUI_Sel + 1, count)
            sel0 := gGUI_Sel - 1
            pos := Win_Wrap0(sel0 - top0, count)
            if (pos >= vis || pos = vis - 1) {
                gGUI_ScrollTop := sel0 - (vis - 1)
            }
        } else {
            gGUI_Sel := Win_Wrap1(gGUI_Sel - 1, count)
            sel0 := gGUI_Sel - 1
            pos := Win_Wrap0(sel0 - top0, count)
            if (pos >= vis || pos = 0) {
                gGUI_ScrollTop := sel0
            }
        }
    }

    GUI_RecalcHover()
    GUI_Repaint()
}

GUI_RecalcHover() {
    global gGUI_OverlayH, gGUI_HoverRow, gGUI_HoverBtn

    if (!gGUI_OverlayH) {
        return false
    }

    pt := Buffer(8, 0)
    if (!DllCall("user32\GetCursorPos", "ptr", pt)) {
        return false
    }
    if (!DllCall("user32\ScreenToClient", "ptr", gGUI_OverlayH, "ptr", pt.Ptr)) {
        return false
    }

    x := NumGet(pt, 0, "Int")
    y := NumGet(pt, 4, "Int")

    act := ""
    idx := 0
    GUI_DetectActionAtPoint(x, y, &act, &idx)

    changed := (idx != gGUI_HoverRow || act != gGUI_HoverBtn)
    gGUI_HoverRow := idx
    gGUI_HoverBtn := act
    return changed
}

GUI_DetectActionAtPoint(xPhys, yPhys, &action, &idx1) {
    global gGUI_Items, gGUI_ScrollTop, gGUI_OverlayH

    action := ""
    idx1 := 0
    count := gGUI_Items.Length
    if (count <= 0) {
        return
    }

    scale := Win_GetScaleForWindow(gGUI_OverlayH)
    RowH := Round(GUI_RowHeight * scale)
    if (RowH < 1) {
        RowH := 1
    }
    My := Round(GUI_MarginY * scale)
    hdr := Round(GUI_HeaderBlockDip() * scale)
    topY := My + hdr

    if (yPhys < topY) {
        return
    }

    vis := GUI_GetVisibleRows()
    if (vis <= 0) {
        return
    }

    rel := yPhys - topY
    rowVis := Floor(rel / RowH) + 1
    if (rowVis < 1 || rowVis > vis) {
        return
    }

    idx0 := Win_Wrap0(gGUI_ScrollTop + (rowVis - 1), count)
    idx1 := idx0 + 1

    size := Round(GUI_ActionBtnSizePx * scale)
    if (size < 12) {
        size := 12
    }
    gap := Round(GUI_ActionBtnGapPx * scale)
    if (gap < 2) {
        gap := 2
    }
    marR := Round(GUI_MarginX * scale)

    ox := 0
    oy := 0
    ow := 0
    oh := 0
    Win_GetRectPhys(gGUI_OverlayH, &ox, &oy, &ow, &oh)

    btnX := ow - marR - size
    btnY := topY + (rowVis - 1) * RowH + (RowH - size) // 2

    if (GUI_ShowCloseButton && xPhys >= btnX && xPhys < btnX + size && yPhys >= btnY && yPhys < btnY + size) {
        action := "close"
        return
    }
    btnX := btnX - (size + gap)
    if (GUI_ShowKillButton && xPhys >= btnX && xPhys < btnX + size && yPhys >= btnY && yPhys < btnY + size) {
        action := "kill"
        return
    }
    btnX := btnX - (size + gap)
    if (GUI_ShowBlacklistButton && xPhys >= btnX && xPhys < btnX + size && yPhys >= btnY && yPhys < btnY + size) {
        action := "blacklist"
        return
    }
}

; ========================= PAINTING =========================

GUI_Repaint() {
    global gGUI_BaseH, gGUI_OverlayH, gGUI_Items, gGUI_Sel, gGUI_LastRowsDesired, gGUI_Revealed

    count := gGUI_Items.Length
    rowsDesired := GUI_ComputeRowsToShow(count)
    if (rowsDesired != gGUI_LastRowsDesired) {
        GUI_ResizeToRows(rowsDesired)
        gGUI_LastRowsDesired := rowsDesired
    }

    phX := 0
    phY := 0
    phW := 0
    phH := 0
    Win_GetRectPhys(gGUI_BaseH, &phX, &phY, &phW, &phH)

    scale := Win_GetScaleForWindow(gGUI_BaseH)
    gGdip_CurScale := scale

    Gdip_EnsureBackbuffer(phW, phH)
    GUI_PaintOverlay(gGUI_Items, gGUI_Sel, phW, phH, scale)

    ; BLENDFUNCTION
    bf := Buffer(4, 0)
    NumPut("UChar", 0x00, bf, 0)
    NumPut("UChar", 0x00, bf, 1)
    NumPut("UChar", 255, bf, 2)
    NumPut("UChar", 0x01, bf, 3)

    sz := Buffer(8, 0)
    ptDst := Buffer(8, 0)
    ptSrc := Buffer(8, 0)
    NumPut("Int", phW, sz, 0)
    NumPut("Int", phH, sz, 4)
    NumPut("Int", phX, ptDst, 0)
    NumPut("Int", phY, ptDst, 4)

    ; Ensure WS_EX_LAYERED
    ex := DllCall("user32\GetWindowLongPtrW", "ptr", gGUI_OverlayH, "int", -20, "ptr")
    if (!(ex & 0x80000)) {
        ex := ex | 0x80000
        DllCall("user32\SetWindowLongPtrW", "ptr", gGUI_OverlayH, "int", -20, "ptr", ex, "ptr")
    }

    hdcScreen := DllCall("user32\GetDC", "ptr", 0, "ptr")
    DllCall("user32\UpdateLayeredWindow", "ptr", gGUI_OverlayH, "ptr", hdcScreen, "ptr", ptDst.Ptr, "ptr", sz.Ptr, "ptr", gGdip_BackHdc, "ptr", ptSrc.Ptr, "int", 0, "ptr", bf.Ptr, "uint", 0x2, "int")
    DllCall("user32\ReleaseDC", "ptr", 0, "ptr", hdcScreen)

    GUI_RevealBoth()
}

GUI_RevealBoth() {
    global gGUI_Base, gGUI_BaseH, gGUI_Overlay, gGUI_Revealed

    if (gGUI_Revealed) {
        return
    }

    Win_ApplyRoundRegion(gGUI_BaseH, GUI_CornerRadiusPx)
    try {
        gGUI_Base.Show("NA")
    }
    try {
        gGUI_Overlay.Show("NA")
    }
    Win_DwmFlush()
    gGUI_Revealed := true
}

GUI_ResizeToRows(rowsToShow) {
    global gGUI_Base, gGUI_BaseH, gGUI_Overlay, gGUI_OverlayH

    xDip := 0
    yDip := 0
    wDip := 0
    hDip := 0
    GUI_GetWindowRect(&xDip, &yDip, &wDip, &hDip, rowsToShow, gGUI_BaseH)

    waL := 0
    waT := 0
    waR := 0
    waB := 0
    Win_GetWorkAreaFromHwnd(gGUI_BaseH, &waL, &waT, &waR, &waB)
    monScale := Win_GetMonitorScale(waL, waT, waR, waB)

    xPhys := Round(xDip * monScale)
    yPhys := Round(yDip * monScale)
    wPhys := Round(wDip * monScale)
    hPhys := Round(hDip * monScale)

    Win_SetPosPhys(gGUI_BaseH, xPhys, yPhys, wPhys, hPhys)
    Win_SetPosPhys(gGUI_OverlayH, xPhys, yPhys, wPhys, hPhys)
    Win_ApplyRoundRegion(gGUI_BaseH, GUI_CornerRadiusPx, wDip, hDip)
    Win_DwmFlush()
}

GUI_GetWindowRect(&x, &y, &w, &h, rowsToShow, hWnd) {
    waL := 0
    waT := 0
    waR := 0
    waB := 0
    Win_GetWorkAreaFromHwnd(hWnd, &waL, &waT, &waR, &waB)

    monScale := Win_GetMonitorScale(waL, waT, waR, waB)

    waW_dip := (waR - waL) / monScale
    waH_dip := (waB - waT) / monScale
    left_dip := waL / monScale
    top_dip := waT / monScale

    pct := GUI_ScreenWidthPct
    if (pct <= 0) {
        pct := 0.10
    }
    if (pct > 1.0) {
        pct := pct / 100.0
    }

    w := Round(waW_dip * pct)
    h := GUI_MarginY + GUI_HeaderBlockDip() + rowsToShow * GUI_RowHeight + GUI_FooterBlockDip() + GUI_MarginY

    x := Round(left_dip + (waW_dip - w) / 2)
    y := Round(top_dip + (waH_dip - h) / 2)
}

GUI_PaintOverlay(items, selIndex, wPhys, hPhys, scale) {
    global gGUI_ScrollTop, gGUI_HoverRow, gGUI_FooterText

    GUI_EnsureResources(scale)

    g := Gdip_EnsureGraphics()
    if (!g) {
        return
    }

    Gdip_Clear(g, 0x00000000)
    Gdip_FillRect(g, gGdip_Res["brHit"], 0, 0, wPhys, hPhys)

    scrollTop := gGUI_ScrollTop

    RowH := Round(GUI_RowHeight * scale)
    if (RowH < 1) {
        RowH := 1
    }
    Mx := Round(GUI_MarginX * scale)
    My := Round(GUI_MarginY * scale)
    ISize := Round(GUI_IconSize * scale)
    Rad := Round(GUI_RowRadius * scale)
    gapText := Round(12 * scale)
    gapCols := Round(10 * scale)
    hdrY4 := Round(4 * scale)
    hdrH28 := Round(28 * scale)
    iconLeftDip := Round(GUI_IconLeftMargin * scale)

    y := My
    leftX := Mx + iconLeftDip
    textX := leftX + ISize + gapText

    ; Right columns
    cols := []
    Col6W := Round(GUI_ColFixed6 * scale)
    Col5W := Round(GUI_ColFixed5 * scale)
    Col4W := Round(GUI_ColFixed4 * scale)
    Col3W := Round(GUI_ColFixed3 * scale)
    Col2W := Round(GUI_ColFixed2 * scale)

    rightX := wPhys - Mx
    if (Col6W > 0) {
        cx := rightX - Col6W
        cols.Push({name: GUI_Col6Name, w: Col6W, key: "Col6", x: cx})
        rightX := cx - gapCols
    }
    if (Col5W > 0) {
        cx := rightX - Col5W
        cols.Push({name: GUI_Col5Name, w: Col5W, key: "Col5", x: cx})
        rightX := cx - gapCols
    }
    if (Col4W > 0) {
        cx := rightX - Col4W
        cols.Push({name: GUI_Col4Name, w: Col4W, key: "WS", x: cx})
        rightX := cx - gapCols
    }
    if (Col3W > 0) {
        cx := rightX - Col3W
        cols.Push({name: GUI_Col3Name, w: Col3W, key: "PID", x: cx})
        rightX := cx - gapCols
    }
    if (Col2W > 0) {
        cx := rightX - Col2W
        cols.Push({name: GUI_Col2Name, w: Col2W, key: "HWND", x: cx})
        rightX := cx - gapCols
    }

    textW := (rightX - Round(16 * scale)) - textX
    if (textW < 0) {
        textW := 0
    }

    fmtLeft := gGdip_Res["fmtLeft"]

    ; Header
    if (GUI_ShowHeader) {
        hdrY := y + hdrY4
        Gdip_DrawText(g, "Title", textX, hdrY, textW, Round(20 * scale), gGdip_Res["brHdr"], gGdip_Res["fHdr"], fmtLeft)
        for _, col in cols {
            Gdip_DrawText(g, col.name, col.x, hdrY, col.w, Round(20 * scale), gGdip_Res["brHdr"], gGdip_Res["fHdr"], gGdip_Res["fmt"])
        }
        y := y + hdrH28
    }

    contentTopY := y
    count := items.Length

    footerH := 0
    footerGap := 0
    if (GUI_ShowFooter) {
        footerH := Round(GUI_FooterHeightPx * scale)
        footerGap := Round(GUI_FooterGapTopPx * scale)
    }
    availH := hPhys - My - contentTopY - footerH - footerGap
    if (availH < 0) {
        availH := 0
    }

    rowsCap := 0
    if (availH > 0) {
        rowsCap := Floor(availH / RowH)
    }
    rowsToDraw := count
    if (rowsToDraw > rowsCap) {
        rowsToDraw := rowsCap
    }

    ; Empty list
    if (count = 0) {
        rectX := Mx
        rectW := wPhys - 2 * Mx
        rectH := RowH
        rectY := contentTopY + Floor((availH - rectH) / 2)
        if (rectY < contentTopY) {
            rectY := contentTopY
        }
        Gdip_DrawCenteredText(g, GUI_EmptyListText, rectX, rectY, rectW, rectH, GUI_MainARGB, gGdip_Res["fMain"], gGdip_Res["fmtCenter"])
    } else if (rowsToDraw > 0) {
        start0 := Win_Wrap0(scrollTop, count)
        i := 0
        yRow := y

        while (i < rowsToDraw && (yRow + RowH <= contentTopY + availH)) {
            idx0 := Win_Wrap0(start0 + i, count)
            idx1 := idx0 + 1
            cur := items[idx1]
            isSel := (idx1 = selIndex)

            if (isSel) {
                Gdip_FillRoundRect(g, GUI_SelARGB, Mx - Round(4 * scale), yRow - Round(2 * scale), wPhys - 2 * Mx + Round(8 * scale), RowH, Rad)
            }

            ix := leftX
            iy := yRow + (RowH - ISize) // 2

            iconDrawn := false
            if (cur.HasOwnProp("iconHicon") && cur.iconHicon) {
                iconDrawn := Gdip_DrawIconFromHicon(g, cur.iconHicon, ix, iy, ISize)
            }
            if (!iconDrawn) {
                Gdip_FillEllipse(g, Gdip_ARGBFromIndex(idx1), ix, iy, ISize, ISize)
            }

            fMainUse := isSel ? gGdip_Res["fMainHi"] : gGdip_Res["fMain"]
            fSubUse := isSel ? gGdip_Res["fSubHi"] : gGdip_Res["fSub"]
            fColUse := isSel ? gGdip_Res["fColHi"] : gGdip_Res["fCol"]
            brMainUse := isSel ? gGdip_Res["brMainHi"] : gGdip_Res["brMain"]
            brSubUse := isSel ? gGdip_Res["brSubHi"] : gGdip_Res["brSub"]
            brColUse := isSel ? gGdip_Res["brColHi"] : gGdip_Res["brCol"]

            title := cur.HasOwnProp("Title") ? cur.Title : ""
            Gdip_DrawText(g, title, textX, yRow + Round(6 * scale), textW, Round(24 * scale), brMainUse, fMainUse, fmtLeft)

            sub := ""
            if (cur.HasOwnProp("processName") && cur.processName != "") {
                sub := cur.processName
            } else if (cur.HasOwnProp("Class")) {
                sub := "Class: " cur.Class
            }
            Gdip_DrawText(g, sub, textX, yRow + Round(28 * scale), textW, Round(18 * scale), brSubUse, fSubUse, fmtLeft)

            for _, col in cols {
                val := ""
                if (cur.HasOwnProp(col.key)) {
                    val := cur.%col.key%
                }
                Gdip_DrawText(g, val, col.x, yRow + Round(10 * scale), col.w, Round(20 * scale), brColUse, fColUse, gGdip_Res["fmt"])
            }

            if (idx1 = gGUI_HoverRow) {
                GUI_DrawActionButtons(g, wPhys, yRow, RowH, scale)
            }

            yRow := yRow + RowH
            i := i + 1
        }
    }

    ; Scrollbar
    if (count > rowsToDraw && rowsToDraw > 0) {
        GUI_DrawScrollbar(g, wPhys, contentTopY, rowsToDraw, RowH, scrollTop, count, scale)
    }

    ; Footer
    if (GUI_ShowFooter) {
        GUI_DrawFooter(g, wPhys, hPhys, scale)
    }
}

GUI_EnsureResources(scale) {
    global gGdip_Res, gGdip_ResScale

    if (Abs(gGdip_ResScale - scale) < 0.001 && gGdip_Res.Count) {
        return
    }

    Gdip_DisposeResources()
    Gdip_Startup()

    ; Brushes
    brushes := [
        ["brMain", GUI_MainARGB],
        ["brMainHi", GUI_MainARGBHi],
        ["brSub", GUI_SubARGB],
        ["brSubHi", GUI_SubARGBHi],
        ["brCol", GUI_ColARGB],
        ["brColHi", GUI_ColARGBHi],
        ["brHdr", GUI_HdrARGB],
        ["brHit", 0x01000000],
        ["brFooterText", GUI_FooterTextARGB]
    ]
    for _, b in brushes {
        br := 0
        DllCall("gdiplus\GdipCreateSolidFill", "int", b[2], "ptr*", &br)
        gGdip_Res[b[1]] := br
    }

    ; Fonts
    UnitPixel := 2

    fonts := [
        [GUI_MainFontName, GUI_MainFontSize, GUI_MainFontWeight, "ffMain", "fMain"],
        [GUI_MainFontNameHi, GUI_MainFontSizeHi, GUI_MainFontWeightHi, "ffMainHi", "fMainHi"],
        [GUI_SubFontName, GUI_SubFontSize, GUI_SubFontWeight, "ffSub", "fSub"],
        [GUI_SubFontNameHi, GUI_SubFontSizeHi, GUI_SubFontWeightHi, "ffSubHi", "fSubHi"],
        [GUI_ColFontName, GUI_ColFontSize, GUI_ColFontWeight, "ffCol", "fCol"],
        [GUI_ColFontNameHi, GUI_ColFontSizeHi, GUI_ColFontWeightHi, "ffColHi", "fColHi"],
        [GUI_HdrFontName, GUI_HdrFontSize, GUI_HdrFontWeight, "ffHdr", "fHdr"],
        [GUI_ActionFontName, GUI_ActionFontSize, GUI_ActionFontWeight, "ffAction", "fAction"],
        [GUI_FooterFontName, GUI_FooterFontSize, GUI_FooterFontWeight, "ffFooter", "fFooter"]
    ]
    for _, f in fonts {
        fam := 0
        font := 0
        style := Gdip_FontStyleFromWeight(f[3])
        DllCall("gdiplus\GdipCreateFontFamilyFromName", "wstr", f[1], "ptr", 0, "ptr*", &fam)
        DllCall("gdiplus\GdipCreateFont", "ptr", fam, "float", f[2] * scale, "int", style, "int", UnitPixel, "ptr*", &font)
        gGdip_Res[f[4]] := fam
        gGdip_Res[f[5]] := font
    }

    ; String formats
    StringAlignmentNear := 0
    StringAlignmentCenter := 1
    StringAlignmentFar := 2
    flags := 0x00001000 | 0x00004000

    formats := [
        ["fmt", StringAlignmentNear, StringAlignmentNear],
        ["fmtCenter", StringAlignmentCenter, StringAlignmentNear],
        ["fmtRight", StringAlignmentFar, StringAlignmentNear],
        ["fmtLeft", StringAlignmentNear, StringAlignmentNear],
        ["fmtLeftCol", StringAlignmentNear, StringAlignmentNear],
        ["fmtFooterLeft", StringAlignmentNear, StringAlignmentCenter],
        ["fmtFooterCenter", StringAlignmentCenter, StringAlignmentCenter],
        ["fmtFooterRight", StringAlignmentFar, StringAlignmentCenter]
    ]
    for _, fm in formats {
        fmt := 0
        DllCall("gdiplus\GdipCreateStringFormat", "int", 0, "ushort", 0, "ptr*", &fmt)
        DllCall("gdiplus\GdipSetStringFormatFlags", "ptr", fmt, "int", flags)
        DllCall("gdiplus\GdipSetStringFormatTrimming", "ptr", fmt, "int", 3)
        DllCall("gdiplus\GdipSetStringFormatAlign", "ptr", fmt, "int", fm[2])
        DllCall("gdiplus\GdipSetStringFormatLineAlign", "ptr", fmt, "int", fm[3])
        gGdip_Res[fm[1]] := fmt
    }

    gGdip_ResScale := scale
}

GUI_DrawActionButtons(g, wPhys, yRow, rowHPhys, scale) {
    global gGUI_HoverBtn

    size := Round(GUI_ActionBtnSizePx * scale)
    if (size < 12) {
        size := 12
    }
    gap := Round(GUI_ActionBtnGapPx * scale)
    if (gap < 2) {
        gap := 2
    }
    rad := Round(GUI_ActionBtnRadiusPx * scale)
    if (rad < 2) {
        rad := 2
    }
    marR := Round(GUI_MarginX * scale)

    btnX := wPhys - marR - size
    btnY := yRow + (rowHPhys - size) // 2

    if (GUI_ShowCloseButton) {
        hovered := (gGUI_HoverBtn = "close")
        bgCol := hovered ? GUI_CloseButtonBGHoverARGB : GUI_CloseButtonBGARGB
        txCol := hovered ? GUI_CloseButtonTextHoverARGB : GUI_CloseButtonTextARGB
        Gdip_FillRoundRect(g, bgCol, btnX, btnY, size, size, rad)
        if (GUI_CloseButtonBorderPx > 0) {
            Gdip_StrokeRoundRect(g, GUI_CloseButtonBorderARGB, btnX + 0.5, btnY + 0.5, size - 1, size - 1, rad, Round(GUI_CloseButtonBorderPx * scale))
        }
        Gdip_DrawCenteredText(g, GUI_CloseButtonGlyph, btnX, btnY, size, size, txCol, gGdip_Res["fAction"], gGdip_Res["fmtCenter"])
        btnX := btnX - (size + gap)
    }

    if (GUI_ShowKillButton) {
        hovered := (gGUI_HoverBtn = "kill")
        bgCol := hovered ? GUI_KillButtonBGHoverARGB : GUI_KillButtonBGARGB
        txCol := hovered ? GUI_KillButtonTextHoverARGB : GUI_KillButtonTextARGB
        Gdip_FillRoundRect(g, bgCol, btnX, btnY, size, size, rad)
        if (GUI_KillButtonBorderPx > 0) {
            Gdip_StrokeRoundRect(g, GUI_KillButtonBorderARGB, btnX + 0.5, btnY + 0.5, size - 1, size - 1, rad, Round(GUI_KillButtonBorderPx * scale))
        }
        Gdip_DrawCenteredText(g, GUI_KillButtonGlyph, btnX, btnY, size, size, txCol, gGdip_Res["fAction"], gGdip_Res["fmtCenter"])
        btnX := btnX - (size + gap)
    }

    if (GUI_ShowBlacklistButton) {
        hovered := (gGUI_HoverBtn = "blacklist")
        bgCol := hovered ? GUI_BlacklistButtonBGHoverARGB : GUI_BlacklistButtonBGARGB
        txCol := hovered ? GUI_BlacklistButtonTextHoverARGB : GUI_BlacklistButtonTextARGB
        Gdip_FillRoundRect(g, bgCol, btnX, btnY, size, size, rad)
        if (GUI_BlacklistButtonBorderPx > 0) {
            Gdip_StrokeRoundRect(g, GUI_BlacklistButtonBorderARGB, btnX + 0.5, btnY + 0.5, size - 1, size - 1, rad, Round(GUI_BlacklistButtonBorderPx * scale))
        }
        Gdip_DrawCenteredText(g, GUI_BlacklistButtonGlyph, btnX, btnY, size, size, txCol, gGdip_Res["fAction"], gGdip_Res["fmtCenter"])
    }
}

GUI_DrawScrollbar(g, wPhys, contentTopY, rowsDrawn, rowHPhys, scrollTop, count, scale) {
    if (!GUI_ScrollBarEnabled || count <= 0 || rowsDrawn <= 0 || rowHPhys <= 0) {
        return
    }

    trackH := rowsDrawn * rowHPhys
    if (trackH <= 0) {
        return
    }

    trackW := Round(GUI_ScrollBarWidthPx * scale)
    if (trackW < 2) {
        trackW := 2
    }
    marR := Round(GUI_ScrollBarMarginRightPx * scale)
    if (marR < 0) {
        marR := 0
    }

    x := wPhys - marR - trackW
    y := contentTopY
    r := trackW // 2

    thumbH := Floor(trackH * rowsDrawn / count)
    if (thumbH < 3) {
        thumbH := 3
    }

    start0 := Win_Wrap0(scrollTop, count)
    startRatio := start0 / count
    y1 := y + Floor(startRatio * trackH)
    y2 := y1 + thumbH
    yEnd := y + trackH

    if (GUI_ScrollBarGutterEnabled) {
        Gdip_FillRoundRect(g, GUI_ScrollBarGutterARGB, x, y, trackW, trackH, r)
    }

    if (y2 <= yEnd) {
        Gdip_FillRoundRect(g, GUI_ScrollBarThumbARGB, x, y1, trackW, thumbH, r)
    } else {
        h1 := yEnd - y1
        if (h1 > 0) {
            Gdip_FillRoundRect(g, GUI_ScrollBarThumbARGB, x, y1, trackW, h1, r)
        }
        h2 := y2 - yEnd
        if (h2 > 0) {
            Gdip_FillRoundRect(g, GUI_ScrollBarThumbARGB, x, y, trackW, h2, r)
        }
    }
}

GUI_DrawFooter(g, wPhys, hPhys, scale) {
    global gGUI_FooterText

    if (!GUI_ShowFooter) {
        return
    }

    fh := Round(GUI_FooterHeightPx * scale)
    if (fh < 1) {
        fh := 1
    }
    mx := Round(GUI_MarginX * scale)
    my := Round(GUI_MarginY * scale)

    fx := mx
    fy := hPhys - my - fh
    fw := wPhys - 2 * mx
    fr := Round(GUI_FooterBGRadius * scale)
    if (fr < 0) {
        fr := 0
    }

    Gdip_FillRoundRect(g, GUI_FooterBGARGB, fx, fy, fw, fh, fr)
    if (GUI_FooterBorderPx > 0) {
        Gdip_StrokeRoundRect(g, GUI_FooterBorderARGB, fx + 0.5, fy + 0.5, fw - 1, fh - 1, fr, Round(GUI_FooterBorderPx * scale))
    }

    pad := Round(GUI_FooterPaddingX * scale)
    if (pad < 0) {
        pad := 0
    }
    tx := fx + pad
    tw := fw - 2 * pad

    t := StrLower(Trim(GUI_FooterTextAlign))
    fmt := gGdip_Res["fmtFooterCenter"]
    if (t = "left") {
        fmt := gGdip_Res["fmtFooterLeft"]
    } else if (t = "right") {
        fmt := gGdip_Res["fmtFooterRight"]
    }

    rf := Buffer(16, 0)
    NumPut("Float", tx, rf, 0)
    NumPut("Float", fy, rf, 4)
    NumPut("Float", tw, rf, 8)
    NumPut("Float", fh, rf, 12)

    DllCall("gdiplus\GdipDrawString", "ptr", g, "wstr", gGUI_FooterText, "int", -1, "ptr", gGdip_Res["fFooter"], "ptr", rf.Ptr, "ptr", fmt, "ptr", gGdip_Res["brFooterText"])
}

; ========================= ACTIONS =========================

GUI_PerformAction(action, idx1 := 0) {
    global gGUI_Items, gGUI_Sel

    if (idx1 = 0) {
        idx1 := gGUI_Sel
    }
    if (idx1 < 1 || idx1 > gGUI_Items.Length) {
        return
    }

    cur := gGUI_Items[idx1]

    if (action = "close") {
        hwnd := cur.hwnd
        if (hwnd && WinExist("ahk_id " hwnd)) {
            PostMessage(0x0010, 0, 0, , "ahk_id " hwnd)
        }
        GUI_RemoveItemAt(idx1)
        return
    }

    if (action = "kill") {
        pid := cur.HasOwnProp("PID") ? cur.PID : ""
        ttl := cur.HasOwnProp("Title") ? cur.Title : "window"
        if (Win_ConfirmTopmost("Terminate process " pid " for '" ttl "'?", "Confirm")) {
            if (pid != "") {
                try {
                    ProcessClose(pid)
                }
            }
            GUI_RemoveItemAt(idx1)
        }
        return
    }

    if (action = "blacklist") {
        ttl := cur.HasOwnProp("Title") ? cur.Title : "window"
        cls := cur.HasOwnProp("Class") ? cur.Class : "?"
        if (Win_ConfirmTopmost("Blacklist '" ttl "' (class '" cls "')?", "Confirm")) {
            GUI_RemoveItemAt(idx1)
        }
        return
    }
}

GUI_RemoveItemAt(idx1) {
    global gGUI_Items, gGUI_Sel, gGUI_ScrollTop, gGUI_OverlayH

    if (idx1 < 1 || idx1 > gGUI_Items.Length) {
        return
    }
    gGUI_Items.RemoveAt(idx1)

    if (gGUI_Items.Length = 0) {
        gGUI_Sel := 1
        gGUI_ScrollTop := 0
    } else {
        if (gGUI_Sel > gGUI_Items.Length) {
            gGUI_Sel := gGUI_Items.Length
        }
    }

    GUI_RecalcHover()
    GUI_Repaint()
}

; ========================= MOUSE HANDLERS =========================

GUI_OnClick(x, y) {
    global gGUI_Items, gGUI_Sel, gGUI_OverlayH, gGUI_OverlayVisible, gGUI_ScrollTop

    ; Don't process clicks if overlay isn't visible
    if (!gGUI_OverlayVisible) {
        return
    }

    act := ""
    idx := 0
    GUI_DetectActionAtPoint(x, y, &act, &idx)
    if (act != "") {
        GUI_PerformAction(act, idx)
        return
    }

    count := gGUI_Items.Length
    if (count = 0) {
        return
    }

    scale := Win_GetScaleForWindow(gGUI_OverlayH)
    yDip := Round(y / scale)

    rowsTopDip := GUI_MarginY + GUI_HeaderBlockDip()
    if (yDip < rowsTopDip) {
        return
    }

    vis := GUI_GetVisibleRows()
    if (vis <= 0) {
        return
    }
    rowsDrawn := vis
    if (rowsDrawn > count) {
        rowsDrawn := count
    }

    idxVisible := ((yDip - rowsTopDip) // GUI_RowHeight) + 1
    if (idxVisible < 1) {
        idxVisible := 1
    }
    if (idxVisible > rowsDrawn) {
        return
    }

    top0 := gGUI_ScrollTop
    idx0 := Win_Wrap0(top0 + (idxVisible - 1), count)
    gGUI_Sel := idx0 + 1

    if (GUI_ScrollKeepHighlightOnTop) {
        gGUI_ScrollTop := gGUI_Sel - 1
    }

    GUI_Repaint()
}

GUI_OnMouseMove(wParam, lParam, msg, hwnd) {
    global gGUI_OverlayH, gGUI_OverlayVisible, gGUI_HoverRow, gGUI_HoverBtn, gGUI_Items, gGUI_Sel

    if (hwnd != gGUI_OverlayH) {
        return 0
    }

    ; Don't process mouse moves if overlay isn't visible
    if (!gGUI_OverlayVisible) {
        return 0
    }

    x := lParam & 0xFFFF
    y := (lParam >> 16) & 0xFFFF

    act := ""
    idx := 0
    GUI_DetectActionAtPoint(x, y, &act, &idx)

    prevRow := gGUI_HoverRow
    prevBtn := gGUI_HoverBtn
    gGUI_HoverRow := idx
    gGUI_HoverBtn := act

    if (gGUI_HoverRow != prevRow || gGUI_HoverBtn != prevBtn) {
        GUI_Repaint()
    }
    return 0
}

GUI_OnWheel(wParam, lParam) {
    global gGUI_OverlayVisible

    ; Don't process wheel if overlay isn't visible
    if (!gGUI_OverlayVisible) {
        return
    }

    delta := (wParam >> 16) & 0xFFFF
    if (delta >= 0x8000) {
        delta := delta - 0x10000
    }
    step := -1
    if (delta < 0) {
        step := 1
    }

    if (GUI_ScrollKeepHighlightOnTop) {
        GUI_MoveSelection(step)
    } else {
        GUI_ScrollBy(step)
    }
}

GUI_ScrollBy(step) {
    global gGUI_ScrollTop, gGUI_Items, gGUI_OverlayH, gGUI_Sel

    vis := GUI_GetVisibleRows()
    if (vis <= 0) {
        return
    }
    count := gGUI_Items.Length
    if (count <= 0) {
        return
    }

    visEff := vis
    if (visEff > count) {
        visEff := count
    }
    if (count <= visEff) {
        return
    }

    gGUI_ScrollTop := Win_Wrap0(gGUI_ScrollTop + step, count)
    GUI_RecalcHover()
    GUI_Repaint()
}

; ========================= WINDOW CREATION =========================

GUI_CreateBase() {
    global gGUI_Base, gGUI_BaseH, gGUI_Items

    opts := "+AlwaysOnTop -Caption"

    rowsDesired := GUI_ComputeRowsToShow(gGUI_Items.Length)

    left := 0
    top := 0
    right := 0
    bottom := 0
    MonitorGetWorkArea(0, &left, &top, &right, &bottom)
    waW_phys := right - left
    waH_phys := bottom - top

    monScale := Win_GetMonitorScale(left, top, right, bottom)

    pct := GUI_ScreenWidthPct
    if (pct <= 0) {
        pct := 0.10
    }
    if (pct > 1.0) {
        pct := pct / 100.0
    }

    waW_dip := waW_phys / monScale
    waH_dip := waH_phys / monScale
    left_dip := left / monScale
    top_dip := top / monScale

    winW := Round(waW_dip * pct)
    winH := GUI_MarginY + GUI_HeaderBlockDip() + rowsDesired * GUI_RowHeight + GUI_FooterBlockDip() + GUI_MarginY
    winX := Round(left_dip + (waW_dip - winW) / 2)
    winY := Round(top_dip + (waH_dip - winH) / 2)

    gGUI_Base := Gui(opts, "Alt-Tabby")
    gGUI_Base.Show("Hide w" winW " h" winH)
    gGUI_BaseH := gGUI_Base.Hwnd

    curX := 0
    curY := 0
    curW := 0
    curH := 0
    Win_GetRectPhys(gGUI_BaseH, &curX, &curY, &curW, &curH)

    waL := 0
    waT := 0
    waR := 0
    waB := 0
    Win_GetWorkAreaFromHwnd(gGUI_BaseH, &waL, &waT, &waR, &waB)
    waW := waR - waL
    waH := waB - waT

    tgtX := waL + (waW - curW) // 2
    tgtY := waT + (waH - curH) // 2
    Win_SetPosPhys(gGUI_BaseH, tgtX, tgtY, curW, curH)

    Win_EnableDarkTitleBar(gGUI_BaseH)
    Win_SetCornerPreference(gGUI_BaseH, 2)
    Win_ForceNoLayered(gGUI_BaseH)
    Win_ApplyRoundRegion(gGUI_BaseH, GUI_CornerRadiusPx, winW, winH)
    Win_ApplyAcrylic(gGUI_BaseH, GUI_AcrylicAlpha, GUI_AcrylicBaseRgb)
    Win_DwmFlush()
}

GUI_CreateOverlay() {
    global gGUI_Base, gGUI_BaseH, gGUI_Overlay, gGUI_OverlayH

    gGUI_Overlay := Gui("+AlwaysOnTop -Caption +ToolWindow +Owner" gGUI_BaseH)
    gGUI_Overlay.Show("Hide")
    gGUI_OverlayH := gGUI_Overlay.Hwnd

    ox := 0
    oy := 0
    ow := 0
    oh := 0
    Win_GetRectPhys(gGUI_BaseH, &ox, &oy, &ow, &oh)
    Win_SetPosPhys(gGUI_OverlayH, ox, oy, ow, oh)
}

; ========================= MAIN =========================

GUI_Main_Init()

; DPI change handler
OnMessage(0x02E0, (wParam, lParam, msg, hwnd) => (gGdip_ResScale := 0.0, 0))

; Create windows
GUI_CreateBase()
gGUI_Sel := 1
gGUI_ScrollTop := 0
GUI_CreateOverlay()

; Start hidden
gGUI_OverlayVisible := false
gGUI_Revealed := false

; Mouse handlers
OnMessage(0x0201, (wParam, lParam, msg, hwnd) => (hwnd = gGUI_OverlayH ? (GUI_OnClick(lParam & 0xFFFF, (lParam >> 16) & 0xFFFF), 0) : 0))
OnMessage(0x020A, (wParam, lParam, msg, hwnd) => (hwnd = gGUI_OverlayH ? (GUI_OnWheel(wParam, lParam), 0) : 0))
OnMessage(0x0200, (wParam, lParam, msg, hwnd) => (hwnd = gGUI_OverlayH ? GUI_OnMouseMove(wParam, lParam, msg, hwnd) : 0))

Persistent()
