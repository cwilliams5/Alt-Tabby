; Alt-Tabby GUI - State Machine
; Handles state transitions: IDLE -> ALT_PENDING -> ACTIVE -> IDLE
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals/functions

; Async cross-workspace activation state (non-blocking to allow keyboard events)
global gGUI_PendingItem := ""            ; Item object being activated (or empty)
global gGUI_PendingHwnd := 0             ; Target hwnd
global gGUI_PendingWSName := ""          ; Target workspace name
global gGUI_PendingDeadline := 0         ; Polling deadline (when to give up)
global gGUI_PendingPhase := ""           ; "polling" or "waiting"
global gGUI_PendingWaitUntil := 0        ; End of post-switch wait
global gGUI_PendingShell := ""           ; WScript.Shell COM object (reused)
global gGUI_PendingTempFile := ""        ; Temp file for query results

; Event buffering during async activation (queue events, don't cancel)
global gGUI_EventBuffer := []            ; Queued events during async activation

; ========================= DEBUG LOGGING =========================
; Controlled by cfg.DiagEventLog (config.ini [Diagnostics] EventLog=true)
; Log file: %TEMP%\tabby_events.log

_GUI_LogEvent(msg) {
    global cfg
    if (!cfg.DiagEventLog)
        return
    try {
        logFile := A_Temp "\tabby_events.log"
        ts := FormatTime(, "HH:mm:ss") "." SubStr("000" Mod(A_TickCount, 1000), -2)
        FileAppend(ts " " msg "`n", logFile, "UTF-8")
    } catch as e {
        ; Log errors to separate file so we can see what's failing
        try FileAppend("LOG_ERROR: " e.Message " | " msg "`n", A_Temp "\tabby_log_errors.txt", "UTF-8")
    }
}

; Call at startup to mark new session
_GUI_LogEventStartup() {
    global cfg
    if (!cfg.DiagEventLog)
        return
    try {
        logFile := A_Temp "\tabby_events.log"
        ; Clear old log and start fresh
        FileDelete(logFile)
        FileAppend("=== Alt-Tabby Event Log - " FormatTime(, "yyyy-MM-dd HH:mm:ss") " ===`n", logFile, "UTF-8")
        FileAppend("Log file: " logFile "`n`n", logFile, "UTF-8")
    }
}

; ========================= STATE MACHINE EVENT HANDLER =========================

GUI_OnInterceptorEvent(evCode, flags, lParam) {
    ; CRITICAL: Prevent hotkey interrupts during state machine processing
    ; Without this, Alt_Up can interrupt Tab processing mid-function,
    ; resetting state to IDLE before Tab can set it to ACTIVE
    Critical "On"

    global gGUI_State, gGUI_AltDownTick, gGUI_FirstTabTick, gGUI_TabCount
    global gGUI_OverlayVisible, gGUI_Items, gGUI_Sel, gGUI_FrozenItems, gGUI_AllItems, cfg
    global TABBY_EV_ALT_DOWN, TABBY_EV_TAB_STEP, TABBY_EV_ALT_UP, TABBY_EV_ESCAPE, TABBY_FLAG_SHIFT
    global gGUI_PendingPhase, gGUI_EventBuffer, gGUI_LastLocalMRUTick

    ; Get event name for logging
    evName := evCode = TABBY_EV_ALT_DOWN ? "ALT_DN" : evCode = TABBY_EV_TAB_STEP ? "TAB" : evCode = TABBY_EV_ALT_UP ? "ALT_UP" : evCode = TABBY_EV_ESCAPE ? "ESC" : "?"

    ; File-based debug logging (no performance impact from tooltips)
    _GUI_LogEvent("EVENT " evName " state=" gGUI_State " pending=" gGUI_PendingPhase " items=" gGUI_Items.Length " buf=" gGUI_EventBuffer.Length)

    ; If async activation is in progress, BUFFER events instead of processing
    ; This matches Windows native behavior: let first switch complete, then process next
    ; Exception: ESC cancels immediately
    if (gGUI_PendingPhase != "") {
        if (evCode = TABBY_EV_ESCAPE) {
            _GUI_LogEvent("ESC during async - canceling")
            _GUI_CancelPendingActivation()
            gGUI_State := "IDLE"
            return
        }
        _GUI_LogEvent("BUFFERING " evName " (async pending, phase=" gGUI_PendingPhase ")")
        gGUI_EventBuffer.Push({ev: evCode, flags: flags, lParam: lParam})
        return
    }

    if (evCode = TABBY_EV_ALT_DOWN) {
        ; Alt pressed - enter ALT_PENDING state
        gGUI_State := "ALT_PENDING"
        gGUI_AltDownTick := A_TickCount
        gGUI_FirstTabTick := 0
        gGUI_TabCount := 0

        ; Pre-warm: request snapshot now so data is ready when Tab pressed
        ; SKIP if we just did a local MRU update - our data is fresher than the store's
        ; (The store hasn't processed our focus change via WinEventHook yet)
        if (!IsSet(gGUI_LastLocalMRUTick))
            gGUI_LastLocalMRUTick := 0
        mruAge := A_TickCount - gGUI_LastLocalMRUTick
        if (cfg.AltTabPrewarmOnAlt) {
            if (mruAge > 300) {
                GUI_RequestSnapshot()
            } else {
                _GUI_LogEvent("PREWARM: skipped (local MRU is fresh, age=" mruAge "ms)")
            }
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
            ; First Tab - freeze with current data and go to ACTIVE
            gGUI_FirstTabTick := A_TickCount
            gGUI_TabCount := 1
            gGUI_State := "ACTIVE"

            ; SAFETY: If gGUI_Items is empty and prewarm was requested, wait briefly for data
            ; This handles the race where Tab is pressed before prewarm response arrives
            if (gGUI_Items.Length = 0 && cfg.AltTabPrewarmOnAlt) {
                waitStart := A_TickCount
                while (gGUI_Items.Length = 0 && (A_TickCount - waitStart) < 50) {
                    Sleep(10)  ; Allow IPC timer to fire and process incoming messages
                }
            }

            ; Freeze: save ALL items (for workspace toggle), then filter
            gGUI_AllItems := gGUI_Items
            gGUI_FrozenItems := GUI_FilterByWorkspaceMode(gGUI_AllItems)

            ; DEBUG: Log workspace data of frozen items
            _GUI_LogEvent("FREEZE: " gGUI_FrozenItems.Length " items frozen")
            for i, item in gGUI_FrozenItems {
                if (i > 5) {
                    _GUI_LogEvent("  ... and " (gGUI_FrozenItems.Length - 5) " more")
                    break
                }
                ws := item.HasOwnProp("WS") ? item.WS : "(none)"
                onCur := item.HasOwnProp("isOnCurrentWorkspace") ? item.isOnCurrentWorkspace : "(none)"
                title := item.HasOwnProp("Title") ? SubStr(item.Title, 1, 25) : "?"
                _GUI_LogEvent("  [" i "] '" title "' ws='" ws "' onCur=" onCur)
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
            SetTimer(GUI_GraceTimerFired, -cfg.AltTabGraceMs)
            return
        }

        if (gGUI_State = "ACTIVE") {
            gGUI_TabCount += 1
            delta := shiftHeld ? -1 : 1
            GUI_MoveSelectionFrozen(delta)

            ; Recalculate hover based on current mouse position after scroll
            ; This ensures action buttons follow the mouse, not the row index
            GUI_RecalcHover()

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
        ; DEBUG: Show ALT_UP arrival (controlled by DebugAltTabTooltips config)
        if (cfg.DebugAltTabTooltips) {
            ToolTip("ALT_UP: state=" gGUI_State " visible=" gGUI_OverlayVisible, 100, 200, 3)
            SetTimer(() => ToolTip(,,,3), -2000)
        }

        if (gGUI_State = "ALT_PENDING") {
            ; Alt released without Tab - return to IDLE
            gGUI_State := "IDLE"
            return
        }

        if (gGUI_State = "ACTIVE") {
            SetTimer(GUI_GraceTimerFired, 0)  ; Cancel grace timer

            timeSinceTab := A_TickCount - gGUI_FirstTabTick

            if (!gGUI_OverlayVisible && timeSinceTab < cfg.AltTabQuickSwitchMs) {
                ; Quick switch: Alt+Tab released quickly, no GUI shown
                GUI_ActivateFromFrozen()
            } else if (gGUI_OverlayVisible) {
                ; Normal case: hide FIRST (feels snappy), then activate
                GUI_HideOverlay()
                GUI_ActivateFromFrozen()
            } else {
                ; Edge case: grace period expired but GUI not shown yet
                GUI_ActivateFromFrozen()
            }

            gGUI_FrozenItems := []
            gGUI_State := "IDLE"

            ; NOTE: Activation is now async (non-blocking) for cross-workspace switches.
            ; Keyboard events are processed normally between timer fires.
            ; No buffering needed - just request snapshot to resync after activation completes.
            ; The async timer will call GUI_RequestSnapshot() when done.
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

; ========================= GRACE TIMER =========================

GUI_GraceTimerFired() {
    global gGUI_State, gGUI_OverlayVisible

    if (gGUI_State = "ACTIVE" && !gGUI_OverlayVisible) {
        GUI_ShowOverlayWithFrozen()
    }
}

; ========================= FROZEN STATE HELPERS =========================

GUI_ShowOverlayWithFrozen() {
    global gGUI_OverlayVisible, gGUI_Base, gGUI_BaseH, gGUI_Overlay, gGUI_OverlayH
    global gGUI_Items, gGUI_FrozenItems, gGUI_Sel, gGUI_ScrollTop, gGUI_Revealed, cfg
    global gGUI_State

    if (gGUI_OverlayVisible) {
        return
    }

    ; Set visible flag FIRST to prevent re-entrancy issues
    ; (Show/DwmFlush can pump messages, allowing hotkeys to fire mid-function)
    gGUI_OverlayVisible := true

    ; NOTE: Do NOT set gGUI_Items := gGUI_FrozenItems here!
    ; gGUI_Items must remain the unfiltered source of truth for cross-session consistency.
    ; Paint function correctly uses gGUI_FrozenItems when in ACTIVE state.

    ; ENFORCE: When ScrollKeepHighlightOnTop is true, selected item must be at top
    ; This catches any edge cases where scrollTop wasn't set correctly
    if (cfg.GUI_ScrollKeepHighlightOnTop && gGUI_FrozenItems.Length > 0) {
        gGUI_ScrollTop := gGUI_Sel - 1
    }

    gGUI_Revealed := false

    try {
        gGUI_Base.Show("NA")
    }

    ; RACE FIX: Check if Alt was released during Show (which pumps messages)
    ; If state changed to IDLE, ALT_UP already called HideOverlay - abort show sequence
    if (gGUI_State != "ACTIVE") {
        return
    }

    rowsDesired := GUI_ComputeRowsToShow(gGUI_FrozenItems.Length)
    GUI_ResizeToRows(rowsDesired)
    GUI_Repaint()  ; Paint with correct sel/scroll from the start

    ; RACE FIX: Check again after paint operations (GDI+ can pump messages)
    if (gGUI_State != "ACTIVE") {
        return
    }

    try {
        gGUI_Overlay.Show("NA")
    }

    ; RACE FIX: Final check before DwmFlush
    if (gGUI_State != "ACTIVE") {
        return
    }

    Win_DwmFlush()

    ; Start hover polling (fallback for WM_MOUSELEAVE)
    GUI_StartHoverPolling()
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
    global gGUI_Sel, gGUI_FrozenItems, cfg

    _GUI_LogEvent("ACTIVATE FROM FROZEN: sel=" gGUI_Sel " frozen=" gGUI_FrozenItems.Length)

    if (gGUI_Sel < 1 || gGUI_Sel > gGUI_FrozenItems.Length) {
        _GUI_LogEvent("ACTIVATE FAILED: sel out of range!")
        return
    }

    item := gGUI_FrozenItems[gGUI_Sel]
    title := item.HasOwnProp("title") ? SubStr(item.title, 1, 30) : "?"
    ws := item.HasOwnProp("WS") ? item.WS : "?"
    onCur := item.HasOwnProp("isOnCurrentWorkspace") ? item.isOnCurrentWorkspace : "?"
    _GUI_LogEvent("ACTIVATE: '" title "' ws=" ws " onCurrent=" onCur)

    GUI_ActivateItem(item)
}

; ========================= ACTIVATION =========================

GUI_ActivateSelected() {
    global gGUI_Items, gGUI_Sel
    if (gGUI_Sel < 1 || gGUI_Sel > gGUI_Items.Length) {
        return
    }
    item := gGUI_Items[gGUI_Sel]
    GUI_ActivateItem(item)
}

; Unified activation logic with cross-workspace support via komorebi
; For cross-workspace: ASYNC (non-blocking) to allow keyboard events during switch
; For same-workspace: SYNC (immediate) for speed
; Uses komorebi's activation pattern: SendInput → SetWindowPos → SetForegroundWindow
GUI_ActivateItem(item) {
    global cfg
    global gGUI_PendingItem, gGUI_PendingHwnd, gGUI_PendingWSName
    global gGUI_PendingDeadline, gGUI_PendingPhase, gGUI_PendingWaitUntil
    global gGUI_PendingShell, gGUI_PendingTempFile
    global gGUI_Items, gGUI_LastLocalMRUTick  ; Needed for same-workspace MRU update

    hwnd := item.hwnd
    if (!hwnd) {
        return
    }

    ; Check if window is on a different workspace
    isOnCurrent := item.HasOwnProp("isOnCurrentWorkspace") ? item.isOnCurrentWorkspace : true
    wsName := item.HasOwnProp("WS") ? item.WS : ""

    ; DEBUG: Log all async activation conditions
    global gGUI_CurrentWSName
    komorebicPath := cfg.HasOwnProp("KomorebicExe") ? cfg.KomorebicExe : "(not set)"
    komorebicExists := (komorebicPath != "(not set)" && FileExist(komorebicPath)) ? "yes" : "no"
    curWS := IsSet(gGUI_CurrentWSName) ? gGUI_CurrentWSName : "(unknown)"
    _GUI_LogEvent("ACTIVATE_COND: isOnCurrent=" isOnCurrent " wsName='" wsName "' curWS='" curWS "' komorebic='" komorebicPath "' exists=" komorebicExists)

    ; === Cross-workspace: ASYNC activation (non-blocking) ===
    if (!isOnCurrent && wsName != "" && cfg.KomorebicExe != "" && FileExist(cfg.KomorebicExe)) {
        _GUI_LogEvent("ASYNC START: switching to workspace '" wsName "' for hwnd " hwnd)

        ; Start workspace switch
        try {
            cmd := '"' cfg.KomorebicExe '" focus-named-workspace "' wsName '"'
            Run(cmd, , "Hide")
        }

        ; Set up async state
        gGUI_PendingItem := item
        gGUI_PendingHwnd := hwnd
        gGUI_PendingWSName := wsName
        gGUI_PendingDeadline := A_TickCount + 200  ; Max 200ms to poll
        gGUI_PendingPhase := "polling"
        gGUI_PendingWaitUntil := 0
        gGUI_PendingTempFile := A_Temp "\tabby_ws_query_" A_TickCount ".tmp"

        ; Create WScript.Shell once (reuse for all polls)
        if (gGUI_PendingShell = "")
            gGUI_PendingShell := ComObject("WScript.Shell")

        ; Start async timer - fires every 15ms, yields control between fires
        SetTimer(_GUI_AsyncActivationTick, 15)
        return  ; Return immediately - keyboard events can now be processed!
    }

    ; === Same-workspace: SYNC activation (immediate, fast) ===
    _GUI_RobustActivate(hwnd)

    ; CRITICAL: Update MRU order locally for rapid Alt+Tab support
    ; Without this, a quick second Alt+Tab sees stale MRU and may select wrong window
    ; (Same fix as in ASYNC COMPLETE for cross-workspace)
    _GUI_LogEvent("MRU UPDATE: searching for hwnd " hwnd " in " gGUI_Items.Length " items")
    for i, itm in gGUI_Items {
        if (itm.hwnd = hwnd) {
            itm.lastActivatedTick := A_TickCount
            _GUI_LogEvent("MRU UPDATE: found at position " i ", moving to position 1")
            if (i > 1) {
                gGUI_Items.RemoveAt(i)
                gGUI_Items.InsertAt(1, itm)
            }
            gGUI_LastLocalMRUTick := A_TickCount  ; Track for prewarm suppression
            break
        }
    }

    ; NOTE: Do NOT request snapshot here - it would overwrite our local MRU update
    ; with stale store data. The store will get the focus update via WinEventHook.

    ; CRITICAL: After activation, keyboard events may have been queued but not processed
    ; Use SetTimer -1 to let message pump run, then resync keyboard state
    SetTimer(_GUI_ResyncKeyboardState, -1)
}

; ========================= ASYNC ACTIVATION TIMER =========================

; Called every 15ms during cross-workspace activation
; Yields control between fires, allowing keyboard hook callbacks to run
_GUI_AsyncActivationTick() {
    global cfg
    global gGUI_PendingItem, gGUI_PendingHwnd, gGUI_PendingWSName
    global gGUI_PendingDeadline, gGUI_PendingPhase, gGUI_PendingWaitUntil
    global gGUI_PendingShell, gGUI_PendingTempFile
    global gGUI_EventBuffer, TABBY_EV_ALT_DOWN, TABBY_EV_TAB_STEP, TABBY_FLAG_SHIFT
    global gGUI_Items, gGUI_CurrentWSName, gGUI_LastLocalMRUTick

    ; Safety: if no pending activation, stop timer
    if (gGUI_PendingPhase = "") {
        SetTimer(_GUI_AsyncActivationTick, 0)
        return
    }

    ; === CRITICAL: Detect missed Tab events ===
    ; During workspace switch, komorebic uses SendInput which briefly uninstalls
    ; all keyboard hooks in the system. This can cause Tab presses to be lost.
    ; If we see Alt+Tab physically held but no TAB event in buffer, synthesize one.
    if (gGUI_PendingPhase = "polling" && GetKeyState("Alt", "P") && GetKeyState("Tab", "P")) {
        hasAltDn := false
        hasTab := false
        for ev in gGUI_EventBuffer {
            if (ev.ev = TABBY_EV_ALT_DOWN)
                hasAltDn := true
            if (ev.ev = TABBY_EV_TAB_STEP)
                hasTab := true
        }
        if (hasAltDn && !hasTab) {
            shiftFlag := GetKeyState("Shift", "P") ? TABBY_FLAG_SHIFT : 0
            _GUI_LogEvent("ASYNC: detected missed Tab press, synthesizing TAB_STEP")
            gGUI_EventBuffer.Push({ev: TABBY_EV_TAB_STEP, flags: shiftFlag, lParam: 0})
        }
    }

    now := A_TickCount

    ; === PHASE 1: Poll for workspace switch completion ===
    if (gGUI_PendingPhase = "polling") {
        ; Check if deadline exceeded
        if (now > gGUI_PendingDeadline) {
            ; Timeout - do activation anyway
            gGUI_PendingPhase := "waiting"
            gGUI_PendingWaitUntil := now + 75  ; Still wait 75ms for komorebi
            return
        }

        ; Poll current workspace (non-blocking: Run with wait=false, check file next tick)
        try {
            try FileDelete(gGUI_PendingTempFile)
            queryCmd := 'cmd.exe /c "' cfg.KomorebicExe '" query focused-workspace-name > "' gGUI_PendingTempFile '"'
            ; Run hidden, DON'T wait (false) - let it run async
            gGUI_PendingShell.Run(queryCmd, 0, false)
        }

        ; Check if switch completed (file from PREVIOUS tick)
        if (FileExist(gGUI_PendingTempFile)) {
            try {
                result := Trim(FileRead(gGUI_PendingTempFile))
                if (result = gGUI_PendingWSName) {
                    ; Switch complete! Move to waiting phase
                    gGUI_PendingPhase := "waiting"
                    gGUI_PendingWaitUntil := now + 75  ; Wait 75ms for komorebi to finish
                    return
                }
            }
        }
        return  ; Keep polling
    }

    ; === PHASE 2: Wait for komorebi's post-switch focus logic ===
    if (gGUI_PendingPhase = "waiting") {
        if (now < gGUI_PendingWaitUntil) {
            return  ; Keep waiting
        }

        ; Wait complete - do robust activation
        hwnd := gGUI_PendingHwnd
        _GUI_LogEvent("ASYNC COMPLETE: activating hwnd " hwnd " (buf=" gGUI_EventBuffer.Length ")")
        _GUI_RobustActivate(hwnd)

        ; Stop the async timer
        SetTimer(_GUI_AsyncActivationTick, 0)

        ; CRITICAL: Update current workspace name IMMEDIATELY
        ; Don't wait for IPC - we know we just switched to gGUI_PendingWSName
        ; This ensures buffered Alt+Tab events use correct workspace data
        ; Also fixes stale freeze issue when FreezeWindowList=true
        if (gGUI_PendingWSName != "") {
            _GUI_LogEvent("ASYNC: updating curWS from '" gGUI_CurrentWSName "' to '" gGUI_PendingWSName "'")
            gGUI_CurrentWSName := gGUI_PendingWSName

            ; Update isOnCurrentWorkspace flags in gGUI_Items to match new workspace
            ; This ensures frozen lists have correct workspace data
            for item in gGUI_Items {
                if (item.HasOwnProp("WS")) {
                    item.isOnCurrentWorkspace := (item.WS = gGUI_CurrentWSName)
                }
            }
        }

        ; CRITICAL: Update MRU order - move activated window to position 1
        ; Don't wait for IPC - we know we just activated gGUI_PendingHwnd
        ; This ensures buffered Alt+Tab selects the PREVIOUS window, not the same one
        activatedHwnd := gGUI_PendingHwnd
        for i, item in gGUI_Items {
            if (item.hwnd = activatedHwnd) {
                ; Update lastActivatedTick to make this window most recent
                item.lastActivatedTick := A_TickCount
                ; Move to front of array
                if (i > 1) {
                    gGUI_Items.RemoveAt(i)
                    gGUI_Items.InsertAt(1, item)
                }
                gGUI_LastLocalMRUTick := A_TickCount  ; Track for prewarm suppression
                _GUI_LogEvent("ASYNC: moved hwnd " activatedHwnd " to MRU position 1")
                break
            }
        }

        ; CRITICAL: Do NOT clear gGUI_PendingPhase yet!
        ; If we clear it now, any pending Tab_Decide timers from the interceptor
        ; will send events that bypass the buffer, arriving out of order.
        ; Keep the phase set to "flushing" so events continue to be buffered
        ; until _GUI_ProcessEventBuffer completes.
        gGUI_PendingPhase := "flushing"

        ; NOTE: Do NOT request snapshot here - it would overwrite our local MRU update
        ; with stale store data. The store will get the focus update via WinEventHook.

        ; Process any buffered events (user did Alt+Tab during our async activation)
        ; This will clear gGUI_PendingPhase when done
        _GUI_LogEvent("ASYNC: scheduling buffer processing")
        SetTimer(_GUI_ProcessEventBuffer, -1)
        return
    }
}

; Process buffered events after async activation completes
; Called via SetTimer -1 after async complete, with gGUI_PendingPhase="flushing"
_GUI_ProcessEventBuffer() {
    global gGUI_EventBuffer, gGUI_Items, gGUI_PendingPhase

    ; CRITICAL: Wait a bit for any pending interceptor timers (Tab_Decide etc) to fire
    ; and get buffered. The interceptor has a 5ms delay in Tab_Decide, plus up to 24ms
    ; for the decision timer itself. We wait 30ms to be safe.
    static waitCount := 0
    if (waitCount < 3) {  ; Wait up to 30ms (3 x 10ms)
        waitCount++
        _GUI_LogEvent("BUFFER WAIT: " waitCount " (buf=" gGUI_EventBuffer.Length ")")
        SetTimer(_GUI_ProcessEventBuffer, -10)
        return
    }
    waitCount := 0  ; Reset for next time

    _GUI_LogEvent("BUFFER PROCESS: " gGUI_EventBuffer.Length " events, items=" gGUI_Items.Length)

    ; Clear pending phase NOW - we've waited for interceptor timers
    _GUI_ClearPendingState()

    if (gGUI_EventBuffer.Length = 0) {
        ; No buffered events - just resync keyboard state
        _GUI_LogEvent("BUFFER: empty, resyncing keyboard state")
        _GUI_ResyncKeyboardState()
        return
    }

    ; Process all buffered events in order
    events := gGUI_EventBuffer.Clone()
    gGUI_EventBuffer := []

    ; === Detect and fix lost Tab events ===
    ; Pattern: ALT_DN + ALT_UP without TAB in between suggests Tab was lost
    ; during komorebic's SendInput (which briefly uninstalls keyboard hooks)
    ; If we see this pattern, synthesize a TAB event
    hasAltDn := false
    hasTab := false
    hasAltUp := false
    altDnIdx := 0
    for i, ev in events {
        if (ev.ev = TABBY_EV_ALT_DOWN) {
            hasAltDn := true
            altDnIdx := i
        }
        if (ev.ev = TABBY_EV_TAB_STEP)
            hasTab := true
        if (ev.ev = TABBY_EV_ALT_UP)
            hasAltUp := true
    }
    if (hasAltDn && hasAltUp && !hasTab) {
        ; Lost Tab detected! Insert synthetic TAB after ALT_DN
        _GUI_LogEvent("BUFFER: detected lost Tab (ALT_DN+ALT_UP without TAB), synthesizing TAB_STEP")
        events.InsertAt(altDnIdx + 1, {ev: TABBY_EV_TAB_STEP, flags: 0, lParam: 0})
    }

    _GUI_LogEvent("BUFFER: processing " events.Length " events now")
    for ev in events {
        GUI_OnInterceptorEvent(ev.ev, ev.flags, ev.lParam)
    }
    _GUI_LogEvent("BUFFER: done processing")
}

; Cancel pending async activation (e.g., on ESC)
_GUI_CancelPendingActivation() {
    global gGUI_PendingPhase, gGUI_EventBuffer
    if (gGUI_PendingPhase != "") {
        _GUI_ClearPendingState()
        SetTimer(_GUI_AsyncActivationTick, 0)
        gGUI_EventBuffer := []  ; Clear any buffered events
        GUI_RequestSnapshot()
    }
}

; Clear all pending activation state
_GUI_ClearPendingState() {
    global gGUI_PendingItem, gGUI_PendingHwnd, gGUI_PendingWSName
    global gGUI_PendingDeadline, gGUI_PendingPhase, gGUI_PendingWaitUntil
    global gGUI_PendingTempFile

    ; Clean up temp file
    try FileDelete(gGUI_PendingTempFile)

    gGUI_PendingItem := ""
    gGUI_PendingHwnd := 0
    gGUI_PendingWSName := ""
    gGUI_PendingDeadline := 0
    gGUI_PendingPhase := ""
    gGUI_PendingWaitUntil := 0
    gGUI_PendingTempFile := ""
}

; ========================= KEYBOARD STATE RESYNC =========================

; Called via SetTimer -1 after activation to catch up with keyboard state
; This handles the case where user does rapid Alt+Tab sequences faster than
; the activation can complete - we need to detect if Alt is still held
_GUI_ResyncKeyboardState() {
    global gGUI_State, cfg
    global TABBY_EV_ALT_DOWN

    ; If we're already in a non-IDLE state, interceptor is handling things
    if (gGUI_State != "IDLE")
        return

    ; Check if Alt is physically held right now
    if (GetKeyState("Alt", "P")) {
        ; Alt is held but we're in IDLE - user started new Alt+Tab during activation
        ; Synthesize ALT_DOWN to get state machine in sync
        GUI_OnInterceptorEvent(TABBY_EV_ALT_DOWN, 0, 0)
    }
}

; ========================= ROBUST WINDOW ACTIVATION =========================

; Robust window activation using komorebi's pattern from windows_api.rs
; SendInput trick → SetWindowPos → SetForegroundWindow
_GUI_RobustActivate(hwnd) {
    ; NOTE: Do NOT manually uncloak windows - this interferes with komorebi's
    ; workspace management and can pull windows to the wrong workspace.
    ; Komorebi handles uncloaking when switching workspaces.

    try {
        if (WinExist("ahk_id " hwnd)) {
            ; Restore if minimized
            if (DllCall("user32\IsIconic", "ptr", hwnd, "int"))
                DllCall("user32\ShowWindow", "ptr", hwnd, "int", 9)  ; SW_RESTORE

            ; Send dummy mouse input to bypass foreground lock (komorebi's trick)
            ; This satisfies Windows' requirement that the process has received recent input
            inputSize := 40  ; sizeof(INPUT) on 64-bit
            input := Buffer(inputSize, 0)
            NumPut("uint", 0, input, 0)  ; type = INPUT_MOUSE
            DllCall("user32\SendInput", "uint", 1, "ptr", input, "int", inputSize)

            ; Bring window to top with SWP_SHOWWINDOW
            ; Flags: SWP_NOMOVE (0x0002) | SWP_NOSIZE (0x0001) | SWP_SHOWWINDOW (0x0040) | SWP_ASYNCWINDOWPOS (0x4000)
            DllCall("user32\SetWindowPos", "ptr", hwnd, "ptr", -1  ; HWND_TOP = 0, but -1 = HWND_TOPMOST works better
                , "int", 0, "int", 0, "int", 0, "int", 0
                , "uint", 0x0043 | 0x4000)  ; SWP_NOSIZE|SWP_NOMOVE|SWP_SHOWWINDOW|SWP_ASYNCWINDOWPOS

            ; Reset to non-topmost (we just want it on top temporarily, not always-on-top)
            DllCall("user32\SetWindowPos", "ptr", hwnd, "ptr", -2  ; HWND_NOTOPMOST
                , "int", 0, "int", 0, "int", 0, "int", 0
                , "uint", 0x0003 | 0x4000)  ; SWP_NOSIZE|SWP_NOMOVE|SWP_ASYNCWINDOWPOS

            ; Now SetForegroundWindow should work
            DllCall("user32\SetForegroundWindow", "ptr", hwnd)
        }
    }
}
