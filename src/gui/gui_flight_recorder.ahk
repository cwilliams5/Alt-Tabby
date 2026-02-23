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
global FR_EV_ACTIVATE_RESULT  := 14  ; d1=hwnd d2=success(0=fail,1=ok,2=transitional) d3=actualFgHwnd
global FR_EV_MRU_UPDATE       := 15  ; d1=hwnd d2=result(1=ok,0=notfound)
global FR_EV_BUFFER_PUSH      := 16  ; d1=evCode d2=bufferLen
global FR_EV_QUICK_SWITCH     := 17  ; d1=timeSinceTab

; Data events (20-29)
global FR_EV_REFRESH          := 20  ; d1=itemCount — live items refreshed from WindowList
global FR_EV_ENRICH_REQ       := 22  ; d1=hwndCount — enrichment batch sent to pump
global FR_EV_ENRICH_RESP      := 23  ; d1=appliedCount — enrichment results applied
global FR_EV_WINDOW_ADD       := 24  ; d1=hwnd d2=storeCount — window added to WindowList
global FR_EV_WINDOW_REMOVE    := 25  ; d1=hwnd d2=storeCount — window removed from WindowList
global FR_EV_GHOST_PURGE      := 26  ; d1=removedCount — zombie windows purged by ValidateExistence
global FR_EV_BLACKLIST_PURGE  := 27  ; d1=removedCount — windows purged by PurgeBlacklisted
global FR_EV_COSMETIC_PATCH   := 28  ; d1=patchedCount d2=baseCount — title/icon/proc patched during ACTIVE
global FR_EV_SCAN_COMPLETE    := 29  ; d1=foundCount d2=storeCount — WinEnum full scan completed

; Session/lifecycle events (30-39)
global FR_EV_SESSION_START    := 30
global FR_EV_PRODUCER_INIT    := 31  ; d1=producerType(1=ksub,2=weh,3=pump) d2=success(0/1)
global FR_EV_ACTIVATE_GONE    := 32  ; d1=hwnd — target window closed before activation
global FR_EV_ACTIVATE_RETRY   := 33  ; d1=dead_hwnd d2=retry_hwnd d3=retry_success(0/1)

; Workspace events (40-49)
global FR_EV_WS_SWITCH        := 40  ; d1=0 — komorebi workspace changed (name in dump state)
global FR_EV_WS_TOGGLE        := 41  ; d1=newMode(1=all,2=current) d2=displayCount
global FR_EV_MON_TOGGLE       := 42  ; d1=newMode(1=all,2=current) d2=displayCount

; WinEvent hook events (50-59)
global FR_EV_FOCUS             := 50  ; d1=hwnd — focus changed to window in store
global FR_EV_FOCUS_SUPPRESS    := 51  ; d1=hwnd d2=remainingMs — focus blocked by MRU suppression
global FR_EV_KSUB_MRU_STALE   := 52  ; d1=ksubHwnd d2=actualFgHwnd — komorebi stale focus skipped

; Producer health events (60-69)
global FR_EV_PRODUCER_BACKOFF  := 60  ; d1=errCount d2=backoffMs — producer entering backoff
global FR_EV_PRODUCER_RECOVER  := 61  ; d1=errCount d2=backoffMs — producer recovered from backoff

; State code constants (for FR_EV_STATE d1)
global FR_ST_IDLE := 0
global FR_ST_ALT_PENDING := 1
global FR_ST_ACTIVE := 2

; ========================= RING BUFFER =========================

global gFR_Enabled := false
global gFR_DumpInProgress := false  ; Suppresses ALT_UP hide/activate during dump
global gFR_NoteResult := ""         ; Modal result for note dialog
global gFR_NoteSubmitted := false   ; true only when OK clicked (Cancel/Esc = abort dump)
global gFR_PendingDump := ""        ; Captured data passed from hotkey thread to timer thread
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

    ; Apply configurable buffer size (default 2000 from registry)
    gFR_Size := cfg.DiagFlightRecorderBufferSize

    ; Pre-allocate ring buffer (reused on every record — zero GC pressure)
    gFR_Buffer := []
    gFR_Buffer.Length := gFR_Size
    Loop gFR_Size
        gFR_Buffer[A_Index] := [0, 0, 0, 0, 0, 0]
    gFR_Idx := 0
    gFR_Count := 0
    gFR_Enabled := true

    ; Dump hotkey: pass-through + keyboard hook + wildcard (fire regardless of modifiers).
    ; Force * prefix so it works during Alt-Tab (Alt held) even if config has bare "F12".
    hk := cfg.DiagFlightRecorderHotkey
    if (SubStr(hk, 1, 1) != "*")
        hk := "*" hk
    Hotkey("~$" hk, (*) => _FR_Dump())

    FR_Record(FR_EV_SESSION_START)
}

; ========================= RECORD (HOT PATH) =========================

FR_Record(ev, d1:=0, d2:=0, d3:=0, d4:=0) {
    global gFR_Enabled, gFR_Buffer, gFR_Idx, gFR_Size, gFR_Count
    if (!gFR_Enabled)
        return
    ; RACE FIX: Protect index increment + slot write from hotkey/timer interruption.
    ; FR_Record is called from both hotkey callbacks (interceptor) and timer callbacks
    ; (producers, async tick). Without Critical, a hotkey can interrupt mid-write causing
    ; two calls to write the same slot and double-increment gFR_Count.
    ; Critical auto-released on function return (no explicit "Off" needed).
    Critical "On"
    gFR_Idx := gFR_Idx >= gFR_Size ? 1 : gFR_Idx + 1
    b := gFR_Buffer[gFR_Idx]
    b[1] := QPC()
    b[2] := ev
    b[3] := d1
    b[4] := d2
    b[5] := d3
    b[6] := d4
    gFR_Count += 1
}

; ========================= DUMP (F12) =========================

_FR_Dump() {
    global gFR_Enabled, gFR_Buffer, gFR_Idx, gFR_Size, gFR_Count
    global gGUI_State, gGUI_LiveItems, gGUI_LiveItemsMap, gGUI_Sel, gGUI_DisplayItems
    global gGUI_PendingPhase, gGUI_CurrentWSName
    global gINT_SessionActive, gINT_BypassMode, gINT_AltIsDown, gINT_TabPending
    global gINT_PendingDecideArmed, gINT_AltUpDuringPending, gINT_PressCount, gINT_TabHeld
    global gGUI_OverlayVisible, gGUI_ScrollTop
    global gWS_Rev, gWS_Store, gWS_SortOrderDirty, gWS_ContentDirty, gWS_MRUBumpOnly
    global gWS_DirtyHwnds, gWS_IconQueue, gWS_PidQueue, gWS_ZQueue

    if (!gFR_Enabled || gFR_Count = 0)
        return

    ; Set flag IMMEDIATELY — before Critical section and hwnd resolution.
    ; ALT_UP checks this flag; if we delay, user releasing Alt during the
    ; ~50ms of state capture + hwnd resolution races past the check.
    global gFR_DumpInProgress
    gFR_DumpInProgress := true

    ; --- 1. Capture state atomically (inside Critical) ---
    Critical "On"
    dumpTick := QPC()
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
    snap.currentWS := gGUI_CurrentWSName

    ; Copy WindowList state (in-process — trivially cheap)
    snap.wsRev := gWS_Rev
    snap.wsStoreCount := gWS_Store.Count
    snap.wsSortDirty := gWS_SortOrderDirty
    snap.wsContentDirty := gWS_ContentDirty
    snap.wsMRUBumpOnly := gWS_MRUBumpOnly
    snap.wsDirtyCount := gWS_DirtyHwnds.Count
    snap.wsIconQueueLen := gWS_IconQueue.Length
    snap.wsPidQueueLen := gWS_PidQueue.Length
    snap.wsZQueueLen := gWS_ZQueue.Length

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

    ; --- 3. Defer dialog + file write to timer thread ---
    ; Hotkey pseudo-threads can't run modal GUI loops (WinWaitClose blocks but
    ; child control messages aren't dispatched). Defer to a timer thread where
    ; the message pump works normally — same context as ThemeMsgBox from tray menu.
    global gFR_PendingDump
    gFR_PendingDump := {snap: snap, entries: entries, evCount: evCount,
        itemsCopy: itemsCopy, dumpTick: dumpTick, fgHwnd: fgHwnd, hwndMap: hwndMap}
    SetTimer(_FR_DumpPhase2, -1)
}

; Phase 2: dialog + file write, runs in a timer thread (clean message pump).
_FR_DumpPhase2() {
    global gFR_PendingDump, gFR_DumpInProgress, gFR_NoteSubmitted
    d := gFR_PendingDump
    gFR_PendingDump := ""

    snap := d.snap
    entries := d.entries
    evCount := d.evCount
    itemsCopy := d.itemsCopy
    dumpTick := d.dumpTick
    fgHwnd := d.fgHwnd
    hwndMap := d.hwndMap

    ; Show note dialog (overlay stays open so user can describe what they see)
    SetTimer(_FR_FocusInputBox, -50)
    note := _FR_ShowNoteDialog()

    ; Clean up: reset state machine (was frozen during dump) and hide overlay.
    ; Order matters: set IDLE before clearing flag so any paint triggered by
    ; hide sees IDLE state. Clear flag before hide so hide isn't blocked.
    GUI_ForceReset()
    gFR_DumpInProgress := false
    ; Always hide — grace timer may have shown overlay during dump even if
    ; it was not visible at capture time. GUI_HideOverlay() is a no-op when
    ; gGUI_OverlayVisible is already false.
    GUI_HideOverlay()

    ; User cancelled — skip file write
    if (!gFR_NoteSubmitted)
        return

    ; --- Build and write dump file ---
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
    out .= "Foreground Window       = " _FR_HwndStr(fgHwnd, hwndMap) "`n"
    out .= "`n"

    ; WindowList state
    out .= "--- WINDOW LIST STATE ----------------------------------------------`n"
    out .= "gWS_Rev                 = " snap.wsRev "`n"
    out .= "gWS_Store.Count         = " snap.wsStoreCount "`n"
    out .= "SortOrderDirty          = " snap.wsSortDirty "`n"
    out .= "ContentDirty            = " snap.wsContentDirty "`n"
    out .= "MRUBumpOnly             = " snap.wsMRUBumpOnly "`n"
    out .= "DirtyHwnds.Count        = " snap.wsDirtyCount "`n"
    out .= "IconQueue.Length         = " snap.wsIconQueueLen "`n"
    out .= "PidQueue.Length          = " snap.wsPidQueueLen "`n"
    out .= "ZQueue.Length            = " snap.wsZQueueLen "`n"
    out .= "`n"

    ; Live items
    out .= "--- LIVE ITEMS (" snap.liveItemCount " windows, " snap.displayItemCount " displayed) ---`n"
    for i, item in itemsCopy {
        h := Format("0x{:08X}", item.hwnd)
        title := item.HasOwnProp("title") ? SubStr(item.title, 1, 40) : "?"
        proc := item.HasOwnProp("processName") ? item.processName : "?"
        ws := GUI_GetItemWSName(item)
        onCur := GUI_GetItemIsOnCurrent(item)
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
        timeCol := Format("T{}{:010.3f}", sign, offsetSec)

        evName := _FR_GetEventName(ev)
        details := _FR_FormatDetails(ev, d1, d2, d3, d4, hwndMap)

        out .= "  " timeCol "  " Format("{:-20}", evName) " " details "`n"
    }

    try FileAppend(out, filePath, "UTF-8")

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
    global FR_EV_ACTIVATE_START, FR_EV_ACTIVATE_RESULT, FR_EV_MRU_UPDATE
    global FR_EV_WINDOW_ADD, FR_EV_WINDOW_REMOVE
    global FR_EV_ACTIVATE_GONE, FR_EV_FOCUS, FR_EV_FOCUS_SUPPRESS
    global FR_EV_KSUB_MRU_STALE
    ; Collect all unique hwnds from entries + items + foreground
    hwnds := Map()
    for _, entry in entries {
        ev := entry[2]
        ; Events that carry hwnds in d1
        if (ev = FR_EV_ACTIVATE_START || ev = FR_EV_ACTIVATE_RESULT
            || ev = FR_EV_MRU_UPDATE
            || ev = FR_EV_WINDOW_ADD || ev = FR_EV_WINDOW_REMOVE
            || ev = FR_EV_ACTIVATE_GONE || ev = FR_EV_FOCUS || ev = FR_EV_FOCUS_SUPPRESS
            || ev = FR_EV_KSUB_MRU_STALE) {
            h := entry[3]
            if (h)
                hwnds[h] := true
        }
        ; ACTIVATE_RESULT has actualFg in d3 (entry[5])
        if (ev = FR_EV_ACTIVATE_RESULT) {
            h := entry[5]
            if (h)
                hwnds[h] := true
        }
        ; KSUB_MRU_STALE has actualFg in d2 (entry[4])
        if (ev = FR_EV_KSUB_MRU_STALE) {
            h := entry[4]
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
            title := item.HasOwnProp("title") ? SubStr(item.title, 1, 30) : ""
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
    global FR_EV_BUFFER_PUSH, FR_EV_QUICK_SWITCH
    global FR_EV_REFRESH, FR_EV_COSMETIC_PATCH, FR_EV_SCAN_COMPLETE
    global FR_EV_ENRICH_REQ, FR_EV_ENRICH_RESP
    global FR_EV_WINDOW_ADD, FR_EV_WINDOW_REMOVE
    global FR_EV_GHOST_PURGE, FR_EV_BLACKLIST_PURGE
    global FR_EV_SESSION_START, FR_EV_PRODUCER_INIT, FR_EV_ACTIVATE_GONE
    global FR_EV_ACTIVATE_RETRY
    global FR_EV_WS_SWITCH, FR_EV_WS_TOGGLE, FR_EV_MON_TOGGLE
    global FR_EV_FOCUS, FR_EV_FOCUS_SUPPRESS
    global FR_EV_KSUB_MRU_STALE
    global FR_EV_PRODUCER_BACKOFF, FR_EV_PRODUCER_RECOVER

    switch ev {
        case FR_EV_ALT_DN:            return "ALT_DN"
        case FR_EV_ALT_UP:            return "ALT_UP"
        case FR_EV_TAB_DN:            return "TAB_DN"
        case FR_EV_TAB_UP:            return "TAB_UP"
        case FR_EV_TAB_DECIDE:        return "TAB_DECIDE"
        case FR_EV_TAB_DECIDE_INNER:  return "TAB_DECIDE_INNER"
        case FR_EV_ESC:               return "ESC"
        case FR_EV_BYPASS:            return "BYPASS"
        case FR_EV_STATE:             return "STATE"
        case FR_EV_FREEZE:            return "FREEZE"
        case FR_EV_GRACE_FIRE:        return "GRACE_FIRE"
        case FR_EV_ACTIVATE_START:    return "ACTIVATE_START"
        case FR_EV_ACTIVATE_RESULT:   return "ACTIVATE_RESULT"
        case FR_EV_MRU_UPDATE:        return "MRU_UPDATE"
        case FR_EV_BUFFER_PUSH:       return "BUFFER_PUSH"
        case FR_EV_QUICK_SWITCH:      return "QUICK_SWITCH"
        case FR_EV_REFRESH:           return "REFRESH"
        case FR_EV_ENRICH_REQ:        return "ENRICH_REQ"
        case FR_EV_ENRICH_RESP:       return "ENRICH_RESP"
        case FR_EV_WINDOW_ADD:        return "WINDOW_ADD"
        case FR_EV_WINDOW_REMOVE:     return "WINDOW_REMOVE"
        case FR_EV_GHOST_PURGE:       return "GHOST_PURGE"
        case FR_EV_BLACKLIST_PURGE:   return "BLACKLIST_PURGE"
        case FR_EV_COSMETIC_PATCH:    return "COSMETIC_PATCH"
        case FR_EV_SCAN_COMPLETE:     return "SCAN_COMPLETE"
        case FR_EV_SESSION_START:     return "SESSION_START"
        case FR_EV_PRODUCER_INIT:     return "PRODUCER_INIT"
        case FR_EV_ACTIVATE_GONE:     return "ACTIVATE_GONE"
        case FR_EV_ACTIVATE_RETRY:    return "ACTIVATE_RETRY"
        case FR_EV_WS_SWITCH:         return "WS_SWITCH"
        case FR_EV_WS_TOGGLE:         return "WS_TOGGLE"
        case FR_EV_MON_TOGGLE:        return "MON_TOGGLE"
        case FR_EV_FOCUS:             return "FOCUS"
        case FR_EV_FOCUS_SUPPRESS:    return "FOCUS_SUPPRESS"
        case FR_EV_KSUB_MRU_STALE:   return "KSUB_MRU_STALE"
        case FR_EV_PRODUCER_BACKOFF:  return "PRODUCER_BACKOFF"
        case FR_EV_PRODUCER_RECOVER:  return "PRODUCER_RECOVER"
        default:                      return "UNKNOWN(" ev ")"
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


_FR_FormatDetails(ev, d1, d2, d3, d4, hwndMap) {
    global FR_EV_ALT_DN, FR_EV_ALT_UP, FR_EV_TAB_DN, FR_EV_TAB_UP
    global FR_EV_TAB_DECIDE, FR_EV_TAB_DECIDE_INNER, FR_EV_ESC, FR_EV_BYPASS
    global FR_EV_STATE, FR_EV_FREEZE, FR_EV_GRACE_FIRE
    global FR_EV_ACTIVATE_START, FR_EV_ACTIVATE_RESULT, FR_EV_MRU_UPDATE
    global FR_EV_BUFFER_PUSH, FR_EV_QUICK_SWITCH
    global FR_EV_REFRESH, FR_EV_COSMETIC_PATCH, FR_EV_SCAN_COMPLETE
    global FR_EV_ENRICH_REQ, FR_EV_ENRICH_RESP
    global FR_EV_WINDOW_ADD, FR_EV_WINDOW_REMOVE
    global FR_EV_GHOST_PURGE, FR_EV_BLACKLIST_PURGE
    global FR_EV_SESSION_START, FR_EV_PRODUCER_INIT, FR_EV_ACTIVATE_GONE
    global FR_EV_ACTIVATE_RETRY
    global FR_EV_WS_SWITCH, FR_EV_WS_TOGGLE, FR_EV_MON_TOGGLE
    global FR_EV_FOCUS, FR_EV_FOCUS_SUPPRESS
    global FR_EV_KSUB_MRU_STALE
    global FR_EV_PRODUCER_BACKOFF, FR_EV_PRODUCER_RECOVER

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
            successStr := (d2 = 2) ? "2(transitional)" : String(d2)
            return _FR_HwndStr(d1, hwndMap) "  success=" successStr "  fg=" _FR_HwndStr(d3, hwndMap)
        case FR_EV_MRU_UPDATE:
            return _FR_HwndStr(d1, hwndMap) "  result=" d2
        case FR_EV_BUFFER_PUSH:
            evName := _FR_GetEventName(d1)
            return "event=" evName "  bufLen=" d2
        case FR_EV_QUICK_SWITCH:
            return "timeSinceTab=" d1 "ms"
        case FR_EV_REFRESH:
            return "items=" d1
        case FR_EV_ENRICH_REQ:
            return "hwnds=" d1
        case FR_EV_ENRICH_RESP:
            return "applied=" d1
        case FR_EV_WINDOW_ADD:
            return _FR_HwndStr(d1, hwndMap) "  storeCount=" d2
        case FR_EV_WINDOW_REMOVE:
            return _FR_HwndStr(d1, hwndMap) "  storeCount=" d2
        case FR_EV_GHOST_PURGE:
            return "removed=" d1
        case FR_EV_BLACKLIST_PURGE:
            return "removed=" d1
        case FR_EV_COSMETIC_PATCH:
            return "patched=" d1 "  baseCount=" d2
        case FR_EV_SCAN_COMPLETE:
            return "found=" d1 "  storeCount=" d2
        case FR_EV_SESSION_START:
            return ""
        case FR_EV_PRODUCER_INIT:
            prodName := (d1 = 1) ? "KomorebiSub" : (d1 = 2) ? "WinEventHook" : (d1 = 3) ? "Pump" : "?(" d1 ")"
            return prodName "  ok=" d2
        case FR_EV_ACTIVATE_GONE:
            return _FR_HwndStr(d1, hwndMap)
        case FR_EV_ACTIVATE_RETRY:
            return "dead=" _FR_HwndStr(d1, hwndMap) "  retry=" _FR_HwndStr(d2, hwndMap) "  ok=" d3
        case FR_EV_WS_SWITCH:
            return ""
        case FR_EV_WS_TOGGLE:
            modeStr := (d1 = 1) ? "all" : (d1 = 2) ? "current" : "?(" d1 ")"
            return "mode=" modeStr "  displayCount=" d2
        case FR_EV_MON_TOGGLE:
            modeStr := (d1 = 1) ? "all" : (d1 = 2) ? "current" : "?(" d1 ")"
            return "mode=" modeStr "  displayCount=" d2
        case FR_EV_FOCUS:
            return _FR_HwndStr(d1, hwndMap)
        case FR_EV_FOCUS_SUPPRESS:
            return _FR_HwndStr(d1, hwndMap) "  remainMs=" d2
        case FR_EV_KSUB_MRU_STALE:
            return "ksub=" _FR_HwndStr(d1, hwndMap) "  fg=" _FR_HwndStr(d2, hwndMap)
        case FR_EV_PRODUCER_BACKOFF:
            return "errCount=" d1 "  backoffMs=" d2
        case FR_EV_PRODUCER_RECOVER:
            return "errCount=" d1 "  wasBackoffMs=" d2
        default:
            return "d1=" d1 " d2=" d2 " d3=" d3 " d4=" d4
    }
}

; Themed modal dialog for user note — replaces native InputBox().
; Sets gFR_NoteSubmitted=true + gFR_NoteResult=text on OK.
; Cancel/Escape leave gFR_NoteSubmitted=false (caller skips file write).
; Follows the exact ThemeMsgBox pattern (OnEvent + WinWaitClose).
_FR_ShowNoteDialog() {
    global gFR_NoteResult, gFR_NoteSubmitted
    gFR_NoteResult := ""
    gFR_NoteSubmitted := false

    noteGui := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox", "Alt-Tabby Flight Recorder")
    GUI_AntiFlashPrepare(noteGui, Theme_GetBgColor())
    noteGui.MarginX := 24
    noteGui.MarginY := 16
    noteGui.SetFont("s10", "Segoe UI")
    themeEntry := Theme_ApplyToGui(noteGui)

    contentW := 440
    accentColor := Theme_GetAccentColor()

    ; Prompt label
    hdr := noteGui.AddText("w" contentW " +Wrap c" accentColor,
        "What happened? (e.g. 'Alt-tabbing from Word to Outlook, nothing happened')")
    Theme_MarkAccent(hdr)

    ; Multi-line edit for user note
    edit := noteGui.AddEdit("w" contentW " h80 +Multi")
    Theme_ApplyToControl(edit, "Edit", themeEntry)

    ; Buttons — right-aligned, OK then Cancel (matches ThemeMsgBox)
    btnW := 100
    btnH := 30
    btnGap := 8
    totalBtnW := 2 * btnW + btnGap
    btnStartX := 24 + contentW - totalBtnW

    btnOK := noteGui.AddButton("x" btnStartX " y+24 w" btnW " h" btnH " +Default", "OK")
    btnOK.OnEvent("Click", _FR_NoteBtnClick.Bind("OK", noteGui, edit))
    Theme_ApplyToControl(btnOK, "Button", themeEntry)

    btnCancel := noteGui.AddButton("x+" btnGap " yp w" btnW " h" btnH, "Cancel")
    btnCancel.OnEvent("Click", _FR_NoteBtnClick.Bind("Cancel", noteGui, edit))
    Theme_ApplyToControl(btnCancel, "Button", themeEntry)

    noteGui.OnEvent("Escape", (*) => (Theme_UntrackGui(noteGui), noteGui.Destroy()))
    noteGui.OnEvent("Close", (*) => (Theme_UntrackGui(noteGui), noteGui.Destroy()))

    noteGui.Show("w488 Center")
    GUI_AntiFlashReveal(noteGui, true)
    WinWaitClose(noteGui.Hwnd)

    return gFR_NoteResult
}

_FR_NoteBtnClick(action, gui, edit, *) {
    global gFR_NoteResult, gFR_NoteSubmitted
    if (action = "OK") {
        gFR_NoteSubmitted := true
        gFR_NoteResult := edit.Value
    }
    Theme_UntrackGui(gui)
    gui.Destroy()
}

; Keep the InputBox always-on-top — user is reporting a critical issue that just occurred.
; Also ensures visibility early after launch when AHK has no foreground window history.
_FR_FocusInputBox() {
    try {
        if WinExist("Alt-Tabby Flight Recorder") {
            WinSetAlwaysOnTop(true, "Alt-Tabby Flight Recorder")
            WinActivate("Alt-Tabby Flight Recorder")
        }
    }
}
