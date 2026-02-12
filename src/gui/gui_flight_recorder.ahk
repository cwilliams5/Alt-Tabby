#Requires AutoHotkey v2.0
; Alt-Tabby GUI - Flight Recorder
; Zero-cost in-memory ring buffer. Press F12 to dump last ~30s of events.
; Enable via [Diagnostics] FlightRecorder=true in config.ini
#Warn VarUnset, Off

; ========================= EVENT CODES =========================
; Numeric for zero-cost recording. Names resolved at dump time only.

; Interceptor events (1-9)
global FR_EV_ALT_DN           := 1   ; d1=sessionActive
global FR_EV_ALT_UP           := 2   ; d1=sessionActive d2=pressCount d3=tabPending d4=asyncPending
global FR_EV_TAB_DN           := 3   ; d1=sessionActive d2=altIsDown d3=tabPending d4=tabHeld
global FR_EV_TAB_UP           := 4   ; d1=tabHeld
global FR_EV_TAB_DECIDE       := 5   ; d1=altIsDown d2=altUpFlag
global FR_EV_TAB_DECIDE_INNER := 6   ; d1=isAltTab d2=altDownNow d3=altUpFlag d4=altRecent
global FR_EV_ESC              := 7   ; d1=sessionActive d2=pressCount
global FR_EV_BYPASS           := 8   ; d1=newState(1=on,0=off)

; State machine events (10-19)
global FR_EV_STATE            := 10  ; d1=newState (0=IDLE 1=ALT_PENDING 2=ACTIVE)
global FR_EV_FREEZE           := 11  ; d1=displayItemCount d2=sel
global FR_EV_GRACE_FIRE       := 12  ; d1=state(2=ACTIVE) d2=overlayVisible
global FR_EV_ACTIVATE_START   := 13  ; d1=hwnd d2=isOnCurrentWS
global FR_EV_ACTIVATE_RESULT  := 14  ; d1=hwnd d2=success d3=actualFgHwnd
global FR_EV_MRU_UPDATE       := 15  ; d1=hwnd d2=result(1=ok,0=notfound)
global FR_EV_BUFFER_PUSH      := 16  ; d1=evCode d2=bufferLen
global FR_EV_QUICK_SWITCH     := 17  ; d1=timeSinceTab
global FR_EV_PREWARM_SKIP     := 18  ; d1=mruAge

; IPC events (20-29)
global FR_EV_SNAPSHOT_REQ     := 20
global FR_EV_SNAPSHOT_RECV    := 21  ; d1=itemCount
global FR_EV_SNAPSHOT_SKIP    := 22  ; d1=reason (1=frozen 2=async 3=freshness)
global FR_EV_DELTA_RECV       := 23  ; d1=mruChanged d2=membershipChanged d3=focusHwnd

; Session events (30+)
global FR_EV_SESSION_START    := 30

; State code constants (for FR_EV_STATE d1)
global FR_ST_IDLE := 0
global FR_ST_ALT_PENDING := 1
global FR_ST_ACTIVE := 2

; ========================= RING BUFFER =========================

global gFR_Enabled := false
global gFR_Buffer := []
global gFR_Size := 2000
global gFR_Idx := 0
global gFR_Count := 0

; ========================= INIT =========================

FR_Init() {
    global cfg, gFR_Enabled, gFR_Buffer, gFR_Size, gFR_Idx, gFR_Count
    global FR_EV_SESSION_START

    if (!cfg.DiagFlightRecorder)
        return

    ; Pre-allocate ring buffer (reused on every record — zero GC pressure)
    gFR_Buffer := []
    gFR_Buffer.Length := gFR_Size
    Loop gFR_Size
        gFR_Buffer[A_Index] := [0, 0, 0, 0, 0, 0]
    gFR_Idx := 0
    gFR_Count := 0
    gFR_Enabled := true

    ; F12 hotkey: pass-through (apps still receive F12) + keyboard hook
    Hotkey("~$F12", (*) => FR_Dump())

    FR_Record(FR_EV_SESSION_START)
}

; ========================= RECORD (HOT PATH) =========================

FR_Record(ev, d1:=0, d2:=0, d3:=0, d4:=0) {
    global gFR_Enabled, gFR_Buffer, gFR_Idx, gFR_Size, gFR_Count
    if (!gFR_Enabled)
        return
    gFR_Idx := Mod(gFR_Idx, gFR_Size) + 1
    b := gFR_Buffer[gFR_Idx]
    b[1] := A_TickCount
    b[2] := ev
    b[3] := d1
    b[4] := d2
    b[5] := d3
    b[6] := d4
    gFR_Count += 1
}

; ========================= DUMP (F12) =========================

FR_Dump() {
    global gFR_Enabled, gFR_Buffer, gFR_Idx, gFR_Size, gFR_Count
    global gGUI_State, gGUI_LiveItems, gGUI_LiveItemsMap, gGUI_Sel, gGUI_DisplayItems
    global gGUI_PendingPhase, gGUI_LastLocalMRUTick, gGUI_CurrentWSName
    global gINT_SessionActive, gINT_BypassMode, gINT_AltIsDown, gINT_TabPending
    global gINT_PendingDecideArmed, gINT_AltUpDuringPending, gINT_PressCount, gINT_TabHeld
    global gGUI_OverlayVisible, gGUI_ScrollTop, gCached_MRUFreshnessMs

    if (!gFR_Enabled || gFR_Count = 0)
        return

    ; --- 1. Capture state atomically (inside Critical) ---
    Critical "On"
    dumpTick := A_TickCount
    capturedIdx := gFR_Idx
    capturedCount := gFR_Count

    ; Copy global state
    snap := {}
    snap.state := gGUI_State
    snap.sessionActive := gINT_SessionActive
    snap.bypassMode := gINT_BypassMode
    snap.altIsDown := gINT_AltIsDown
    snap.tabPending := gINT_TabPending
    snap.tabHeld := gINT_TabHeld
    snap.pendingDecideArmed := gINT_PendingDecideArmed
    snap.altUpDuringPending := gINT_AltUpDuringPending
    snap.pressCount := gINT_PressCount
    snap.pendingPhase := gGUI_PendingPhase
    snap.overlayVisible := gGUI_OverlayVisible
    snap.sel := gGUI_Sel
    snap.scrollTop := gGUI_ScrollTop
    snap.lastMRUTick := gGUI_LastLocalMRUTick
    snap.mruAge := dumpTick - gGUI_LastLocalMRUTick
    snap.mruFreshnessMs := gCached_MRUFreshnessMs
    snap.currentWS := gGUI_CurrentWSName

    ; Copy live items (shallow — title/process are strings, safe to read later)
    itemsCopy := []
    for _, item in gGUI_LiveItems
        itemsCopy.Push(item)
    snap.liveItemCount := itemsCopy.Length
    snap.displayItemCount := gGUI_DisplayItems.Length

    ; Copy ring buffer entries (just references to pre-allocated arrays — fast)
    ; We read the values inside Critical so no concurrent FR_Record can overwrite mid-read
    entries := []
    evCount := Min(capturedCount, gFR_Size)
    Loop evCount {
        srcIdx := capturedIdx - (A_Index - 1)
        if (srcIdx < 1)
            srcIdx += gFR_Size
        b := gFR_Buffer[srcIdx]
        entries.Push([b[1], b[2], b[3], b[4], b[5], b[6]])
    }
    Critical "Off"

    ; --- 2. Resolve hwnds (outside Critical — Win32 calls take time) ---
    fgHwnd := DllCall("user32\GetForegroundWindow", "ptr")
    hwndMap := _FR_BuildHwndMap(entries, itemsCopy, fgHwnd)

    ; --- 3. Show InputBox for user note ---
    result := InputBox("What happened? (e.g. 'Alt-tabbing from Word to Outlook, nothing happened')"
        , "Alt-Tabby Flight Recorder", "w500 h110")
    note := (result.Result = "OK") ? result.Value : ""

    ; --- 4. Build and write dump file ---
    recorderDir := _FR_GetRecorderDir()
    if (!DirExist(recorderDir))
        DirCreate(recorderDir)

    timeStr := FormatTime(, "yyyyMMdd_HHmmss")
    fileName := "fr_" timeStr ".txt"
    filePath := recorderDir "\" fileName

    out := ""

    ; Header
    prettyTime := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    out .= "================================================================`n"
    out .= "  Alt-Tabby Flight Recorder Dump`n"
    out .= "  " prettyTime "  (tick " dumpTick ")`n"
    out .= "================================================================`n`n"

    if (note != "")
        out .= "USER NOTE: " note "`n`n"

    ; Global state snapshot
    out .= "--- GLOBAL STATE ---------------------------------------------------`n"
    out .= "GUI State               = " snap.state "`n"
    out .= "gINT_SessionActive      = " snap.sessionActive "`n"
    out .= "gINT_BypassMode         = " snap.bypassMode "`n"
    out .= "gINT_AltIsDown          = " snap.altIsDown "`n"
    out .= "gINT_TabPending         = " snap.tabPending "`n"
    out .= "gINT_TabHeld            = " snap.tabHeld "`n"
    out .= "gINT_PendingDecideArmed = " snap.pendingDecideArmed "`n"
    out .= "gINT_AltUpDuringPending = " snap.altUpDuringPending "`n"
    out .= "gINT_PressCount         = " snap.pressCount "`n"
    out .= "gGUI_PendingPhase       = " (snap.pendingPhase = "" ? '""' : snap.pendingPhase) "`n"
    out .= "gGUI_OverlayVisible     = " snap.overlayVisible "`n"
    out .= "gGUI_Sel                = " snap.sel "`n"
    out .= "gGUI_ScrollTop          = " snap.scrollTop "`n"
    out .= "gGUI_CurrentWSName      = " snap.currentWS "`n"
    out .= "LastLocalMRUTick        = " snap.lastMRUTick " (age=" snap.mruAge "ms, freshness=" snap.mruFreshnessMs "ms)`n"
    out .= "Foreground Window       = " _FR_HwndStr(fgHwnd, hwndMap) "`n"
    out .= "`n"

    ; Live items
    out .= "--- LIVE ITEMS (" snap.liveItemCount " windows, " snap.displayItemCount " displayed) ---`n"
    for i, item in itemsCopy {
        h := Format("0x{:08X}", item.hwnd)
        title := item.HasOwnProp("Title") ? SubStr(item.Title, 1, 40) : "?"
        proc := item.HasOwnProp("processName") ? item.processName : "?"
        ws := item.HasOwnProp("WS") ? item.WS : ""
        onCur := item.HasOwnProp("isOnCurrentWorkspace") ? item.isOnCurrentWorkspace : "?"
        out .= "  #" Format("{:02}", i) "  " h '  "' title '"  ' proc "  ws=" ws "  cur=" onCur "`n"
    }
    out .= "`n"

    ; Event trace
    out .= "--- EVENT TRACE (" evCount " events, newest first) ----------------------`n"
    out .= "  Offset     Event                Details`n"
    out .= "  ---------  -------------------  -------------------------------------`n"
    for _, entry in entries {
        tick := entry[1]
        ev := entry[2]
        d1 := entry[3]
        d2 := entry[4]
        d3 := entry[5]
        d4 := entry[6]

        ; Time offset from dump (negative = before dump)
        offsetMs := tick - dumpTick
        offsetSec := Abs(offsetMs) / 1000.0
        sign := offsetMs <= 0 ? "-" : "+"
        timeCol := Format("T{}{:07.3f}", sign, offsetSec)

        evName := _FR_GetEventName(ev)
        details := _FR_FormatDetails(ev, d1, d2, d3, d4, hwndMap)

        out .= "  " timeCol "  " Format("{:-20}", evName) " " details "`n"
    }

    try FileAppend(out, filePath)

    ; Tooltip confirmation
    ToolTip("Flight recorder saved: " fileName)
    SetTimer((*) => ToolTip(), -3000)
}

; ========================= DUMP HELPERS =========================

_FR_GetRecorderDir() {
    if (A_IsCompiled)
        return A_ScriptDir "\recorder"
    return A_ScriptDir "\..\..\recorder"
}

_FR_BuildHwndMap(entries, itemsCopy, fgHwnd) {
    global FR_EV_ACTIVATE_START, FR_EV_ACTIVATE_RESULT, FR_EV_MRU_UPDATE, FR_EV_DELTA_RECV
    ; Collect all unique hwnds from entries + items + foreground
    hwnds := Map()
    for _, entry in entries {
        ev := entry[2]
        ; Events that carry hwnds in d1
        if (ev = FR_EV_ACTIVATE_START || ev = FR_EV_ACTIVATE_RESULT
            || ev = FR_EV_MRU_UPDATE) {
            h := entry[3]
            if (h)
                hwnds[h] := true
        }
        ; ACTIVATE_RESULT also has actualFg in d3
        if (ev = FR_EV_ACTIVATE_RESULT) {
            h := entry[5]
            if (h)
                hwnds[h] := true
        }
        ; DELTA_RECV has focusHwnd in d3
        if (ev = FR_EV_DELTA_RECV) {
            h := entry[5]
            if (h)
                hwnds[h] := true
        }
    }
    if (fgHwnd)
        hwnds[fgHwnd] := true

    ; Build resolution map: hwnd → "title (process)"
    ; First pass: resolve from live items (guaranteed accurate)
    resolved := Map()
    for _, item in itemsCopy {
        if (hwnds.Has(item.hwnd)) {
            title := item.HasOwnProp("Title") ? SubStr(item.Title, 1, 30) : ""
            proc := item.HasOwnProp("processName") ? item.processName : ""
            if (title != "" || proc != "")
                resolved[item.hwnd] := title (proc != "" ? " (" proc ")" : "")
        }
    }

    ; Second pass: try Win32 for any unresolved hwnds
    for h, _ in hwnds {
        if (resolved.Has(h))
            continue
        title := ""
        proc := ""
        try title := WinGetTitle(h)
        try proc := WinGetProcessName(h)
        if (title != "" || proc != "")
            resolved[h] := SubStr(title, 1, 30) (proc != "" ? " (" proc ")" : "")
        else
            resolved[h] := "(gone)"
    }

    return resolved
}

_FR_HwndStr(hwnd, hwndMap) {
    h := Format("0x{:08X}", hwnd)
    if (hwndMap.Has(hwnd))
        return h "  " hwndMap[hwnd]
    return h
}

_FR_GetEventName(ev) {
    global FR_EV_ALT_DN, FR_EV_ALT_UP, FR_EV_TAB_DN, FR_EV_TAB_UP
    global FR_EV_TAB_DECIDE, FR_EV_TAB_DECIDE_INNER, FR_EV_ESC, FR_EV_BYPASS
    global FR_EV_STATE, FR_EV_FREEZE, FR_EV_GRACE_FIRE
    global FR_EV_ACTIVATE_START, FR_EV_ACTIVATE_RESULT, FR_EV_MRU_UPDATE
    global FR_EV_BUFFER_PUSH, FR_EV_QUICK_SWITCH, FR_EV_PREWARM_SKIP
    global FR_EV_SNAPSHOT_REQ, FR_EV_SNAPSHOT_RECV, FR_EV_SNAPSHOT_SKIP
    global FR_EV_DELTA_RECV, FR_EV_SESSION_START

    switch ev {
        case FR_EV_ALT_DN:           return "ALT_DN"
        case FR_EV_ALT_UP:           return "ALT_UP"
        case FR_EV_TAB_DN:           return "TAB_DN"
        case FR_EV_TAB_UP:           return "TAB_UP"
        case FR_EV_TAB_DECIDE:       return "TAB_DECIDE"
        case FR_EV_TAB_DECIDE_INNER: return "TAB_DECIDE_INNER"
        case FR_EV_ESC:              return "ESC"
        case FR_EV_BYPASS:           return "BYPASS"
        case FR_EV_STATE:            return "STATE"
        case FR_EV_FREEZE:           return "FREEZE"
        case FR_EV_GRACE_FIRE:       return "GRACE_FIRE"
        case FR_EV_ACTIVATE_START:   return "ACTIVATE_START"
        case FR_EV_ACTIVATE_RESULT:  return "ACTIVATE_RESULT"
        case FR_EV_MRU_UPDATE:       return "MRU_UPDATE"
        case FR_EV_BUFFER_PUSH:      return "BUFFER_PUSH"
        case FR_EV_QUICK_SWITCH:     return "QUICK_SWITCH"
        case FR_EV_PREWARM_SKIP:     return "PREWARM_SKIP"
        case FR_EV_SNAPSHOT_REQ:     return "SNAPSHOT_REQ"
        case FR_EV_SNAPSHOT_RECV:    return "SNAPSHOT_RECV"
        case FR_EV_SNAPSHOT_SKIP:    return "SNAPSHOT_SKIP"
        case FR_EV_DELTA_RECV:       return "DELTA_RECV"
        case FR_EV_SESSION_START:    return "SESSION_START"
        default:                     return "UNKNOWN(" ev ")"
    }
}

_FR_StateName(code) {
    global FR_ST_IDLE, FR_ST_ALT_PENDING, FR_ST_ACTIVE
    switch code {
        case FR_ST_IDLE:        return "IDLE"
        case FR_ST_ALT_PENDING: return "ALT_PENDING"
        case FR_ST_ACTIVE:      return "ACTIVE"
        default:                return "?(" code ")"
    }
}

_FR_SkipReason(code) {
    switch code {
        case 1: return "frozen"
        case 2: return "async_pending"
        case 3: return "mru_fresh"
        default: return "?(" code ")"
    }
}

_FR_FormatDetails(ev, d1, d2, d3, d4, hwndMap) {
    global FR_EV_ALT_DN, FR_EV_ALT_UP, FR_EV_TAB_DN, FR_EV_TAB_UP
    global FR_EV_TAB_DECIDE, FR_EV_TAB_DECIDE_INNER, FR_EV_ESC, FR_EV_BYPASS
    global FR_EV_STATE, FR_EV_FREEZE, FR_EV_GRACE_FIRE
    global FR_EV_ACTIVATE_START, FR_EV_ACTIVATE_RESULT, FR_EV_MRU_UPDATE
    global FR_EV_BUFFER_PUSH, FR_EV_QUICK_SWITCH, FR_EV_PREWARM_SKIP
    global FR_EV_SNAPSHOT_REQ, FR_EV_SNAPSHOT_RECV, FR_EV_SNAPSHOT_SKIP
    global FR_EV_DELTA_RECV, FR_EV_SESSION_START

    switch ev {
        case FR_EV_ALT_DN:
            return "session=" d1
        case FR_EV_ALT_UP:
            return "session=" d1 "  presses=" d2 "  tabPending=" d3 "  async=" d4
        case FR_EV_TAB_DN:
            return "session=" d1 "  altDown=" d2 "  pending=" d3 "  held=" d4
        case FR_EV_TAB_UP:
            return "held=" d1
        case FR_EV_TAB_DECIDE:
            return "altDown=" d1 "  altUpFlag=" d2
        case FR_EV_TAB_DECIDE_INNER:
            return "isAltTab=" d1 "  altDown=" d2 "  altUpFlag=" d3 "  altRecent=" d4
        case FR_EV_ESC:
            return "session=" d1 "  presses=" d2
        case FR_EV_BYPASS:
            return (d1 ? "ON" : "OFF")
        case FR_EV_STATE:
            return "-> " _FR_StateName(d1)
        case FR_EV_FREEZE:
            return "items=" d1 "  sel=" d2
        case FR_EV_GRACE_FIRE:
            return "state=" _FR_StateName(d1) "  visible=" d2
        case FR_EV_ACTIVATE_START:
            return _FR_HwndStr(d1, hwndMap) "  onCurrentWS=" d2
        case FR_EV_ACTIVATE_RESULT:
            return _FR_HwndStr(d1, hwndMap) "  success=" d2 "  fg=" _FR_HwndStr(d3, hwndMap)
        case FR_EV_MRU_UPDATE:
            return _FR_HwndStr(d1, hwndMap) "  result=" d2
        case FR_EV_BUFFER_PUSH:
            evName := _FR_GetEventName(d1)
            return "event=" evName "  bufLen=" d2
        case FR_EV_QUICK_SWITCH:
            return "timeSinceTab=" d1 "ms"
        case FR_EV_PREWARM_SKIP:
            return "mruAge=" d1 "ms"
        case FR_EV_SNAPSHOT_REQ:
            return ""
        case FR_EV_SNAPSHOT_RECV:
            return "items=" d1
        case FR_EV_SNAPSHOT_SKIP:
            return "reason=" _FR_SkipReason(d1)
        case FR_EV_DELTA_RECV:
            return "mruChanged=" d1 "  memberChanged=" d2 "  focusHwnd=" _FR_HwndStr(d3, hwndMap)
        case FR_EV_SESSION_START:
            return ""
        default:
            return "d1=" d1 " d2=" d2 " d3=" d3 " d4=" d4
    }
}
