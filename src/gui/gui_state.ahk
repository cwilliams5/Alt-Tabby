#Requires AutoHotkey v2.0
; Alt-Tabby GUI - State Machine
; Handles state transitions: IDLE -> ALT_PENDING -> ACTIVE -> IDLE
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals/functions

; Timing constants (hardcoded - not user-configurable)
; These are internal implementation details that users shouldn't need to change.
; The main timing values (MRU freshness, WS poll timeout, prewarm wait) are in config.
global GUI_EVENT_BUFFER_MAX := 50           ; Max events to buffer during async

; ============================================================
; ASYNC CROSS-WORKSPACE ACTIVATION STATE
; ============================================================
; These 7 globals form a coherent state group for non-blocking workspace switches.
; IMPORTANT: Always use _GUI_ClearPendingState() to reset ALL of them together.
; Phase progression: "" -> "polling" -> "waiting" -> "flushing" -> ""
global gGUI_PendingHwnd := 0             ; Target hwnd
global gGUI_PendingWSName := ""          ; Target workspace name
global gGUI_PendingDeadline := 0         ; Polling deadline (when to give up)
global gGUI_PendingPhase := ""           ; "polling", "waiting", "flushing", or ""
global gGUI_PendingWaitUntil := 0        ; End of post-switch wait
global gGUI_PendingShell := ""           ; WScript.Shell COM object (reused)
global gGUI_PendingTempFile := ""        ; Temp file for query results

; COM interfaces for direct window uncloaking (mimic native Alt+Tab)
; These allow us to uncloak a single window without switching workspaces,
; letting komorebi's reconciliation handle the workspace switch after activation.
global gGUI_ImmersiveShell := 0          ; ImmersiveShell COM object
global gGUI_AppViewCollection := 0       ; IApplicationViewCollection interface

; Event buffering during async activation (queue events, don't cancel)
global gGUI_EventBuffer := []            ; Queued events during async activation

; State machine timing
global gGUI_FirstTabTick := 0
global gGUI_TabCount := 0

; Session stats counters (sent to store as deltas)
global gStats_AltTabs := 0
global gStats_QuickSwitches := 0
global gStats_TabSteps := 0
global gStats_Cancellations := 0
global gStats_CrossWorkspace := 0
global gStats_LastSent := Map()  ; Tracks what was last sent for delta calculation


; ========================= DEBUG LOGGING =========================
; Controlled by cfg.DiagEventLog (config.ini [Diagnostics] EventLog=true)
; Log file: %TEMP%\tabby_events.log

GUI_LogEvent(msg) {
    global cfg, LOG_PATH_EVENTS
    if (!cfg.DiagEventLog)
        return
    try LogAppend(LOG_PATH_EVENTS, msg)
}

; Call at startup to mark new session
GUI_LogEventStartup() {
    global cfg, LOG_PATH_EVENTS
    if (!cfg.DiagEventLog)
        return
    try {
        LogInitSession(LOG_PATH_EVENTS, "Alt-Tabby Event Log")
    }
}

; ========================= EVENT NAME LOOKUP =========================

; Map for converting event codes to readable names (clearer than ternary chain)
global gGUI_EventNames := Map()

GUI_InitEventNames() {
    global gGUI_EventNames, TABBY_EV_ALT_DOWN, TABBY_EV_TAB_STEP, TABBY_EV_ALT_UP, TABBY_EV_ESCAPE
    gGUI_EventNames[TABBY_EV_ALT_DOWN] := "ALT_DN"
    gGUI_EventNames[TABBY_EV_TAB_STEP] := "TAB"
    gGUI_EventNames[TABBY_EV_ALT_UP] := "ALT_UP"
    gGUI_EventNames[TABBY_EV_ESCAPE] := "ESC"
}

_GUI_GetEventName(evCode) {
    global gGUI_EventNames
    return gGUI_EventNames.Has(evCode) ? gGUI_EventNames[evCode] : "?"
}

; ========================= STATE MACHINE EVENT HANDLER =========================

GUI_OnInterceptorEvent(evCode, flags, lParam) {
    ; CRITICAL: Prevent hotkey interrupts during state machine processing
    ; Without this, Alt_Up can interrupt Tab processing mid-function,
    ; resetting state to IDLE before Tab can set it to ACTIVE
    Critical "On"

    global gGUI_State, gGUI_FirstTabTick, gGUI_TabCount
    global gGUI_OverlayVisible, gGUI_LiveItems, gGUI_Sel, gGUI_DisplayItems, gGUI_ToggleBase, cfg
    global TABBY_EV_ALT_DOWN, TABBY_EV_TAB_STEP, TABBY_EV_ALT_UP, TABBY_EV_ESCAPE, TABBY_FLAG_SHIFT, GUI_EVENT_BUFFER_MAX, gGUI_ScrollTop
    global gGUI_PendingPhase, gGUI_EventBuffer, gGUI_LastLocalMRUTick, TIMING_IPC_FIRE_WAIT

    ; File-based debug logging (no performance impact from tooltips)
    if (cfg.DiagEventLog) {
        evName := _GUI_GetEventName(evCode)
        GUI_LogEvent("EVENT " evName " state=" gGUI_State " pending=" gGUI_PendingPhase " items=" gGUI_LiveItems.Length " buf=" gGUI_EventBuffer.Length)
    }

    ; If async activation is in progress, BUFFER events instead of processing
    ; This matches Windows native behavior: let first switch complete, then process next
    ; Exception: ESC cancels immediately
    if (gGUI_PendingPhase != "") {
        if (evCode = TABBY_EV_ESCAPE) {
            if (cfg.DiagEventLog)
                GUI_LogEvent("ESC during async - canceling")
            _GUI_CancelPendingActivation()
            gGUI_State := "IDLE"
            return  ; lint-ignore: critical-section
        }

        ; Overflow protection: check BEFORE push to prevent exceeding max
        ; Normal rapid Alt+Tab produces ~4-6 events max (ALT_DN, TAB, TAB, ALT_UP)
        ; 50 events = ~12 complete Alt+Tab sequences queued = clearly pathological
        ; Drop event and cancel pending activation to recover gracefully
        if (gGUI_EventBuffer.Length >= GUI_EVENT_BUFFER_MAX) {
            if (cfg.DiagEventLog)
                GUI_LogEvent("BUFFER OVERFLOW: " gGUI_EventBuffer.Length " events, dropping event and clearing")
            _GUI_CancelPendingActivation()
            gGUI_State := "IDLE"
            return  ; lint-ignore: critical-section
        }

        gGUI_EventBuffer.Push({ev: evCode, flags: flags, lParam: lParam})
        if (cfg.DiagEventLog)
            GUI_LogEvent("BUFFERING " _GUI_GetEventName(evCode) " (async pending, phase=" gGUI_PendingPhase ")")
        return  ; lint-ignore: critical-section
    }

    if (evCode = TABBY_EV_ALT_DOWN) {
        ; Alt pressed - enter ALT_PENDING state
        gGUI_State := "ALT_PENDING"
        gGUI_FirstTabTick := 0
        gGUI_TabCount := 0
        global gGUI_WSContextSwitch
        gGUI_WSContextSwitch := false

        ; Drop client to active polling on Alt keypress — ensures we're ready to
        ; read pending deltas or prewarm response, even if prewarm is skipped
        global gGUI_StoreClient, IPC_TICK_ACTIVE
        if (IsObject(gGUI_StoreClient) && gGUI_StoreClient.hPipe) {
            gGUI_StoreClient.idleStreak := 0
            IPC_SetClientTick(gGUI_StoreClient, IPC_TICK_ACTIVE)
        }

        ; Pre-warm: request snapshot now so data is ready when Tab pressed
        ; SKIP if we just did a local MRU update - our data is fresher than the store's
        ; (The store hasn't processed our focus change via WinEventHook yet)
        if (!IsSet(gGUI_LastLocalMRUTick))  ; lint-ignore: isset-with-default
            gGUI_LastLocalMRUTick := 0
        mruAge := A_TickCount - gGUI_LastLocalMRUTick
        if (cfg.AltTabPrewarmOnAlt) {
            global gCached_MRUFreshnessMs
            if (mruAge > gCached_MRUFreshnessMs) {
                GUI_RequestSnapshot()
            } else {
                if (cfg.DiagEventLog)
                    GUI_LogEvent("PREWARM: skipped (local MRU is fresh, age=" mruAge "ms)")
            }
        }
        return  ; lint-ignore: critical-section
    }

    if (evCode = TABBY_EV_TAB_STEP) {
        shiftHeld := (flags & TABBY_FLAG_SHIFT) != 0

        if (gGUI_State = "IDLE") {
            ; Tab without Alt (shouldn't happen normally, interceptor handles this)
            return  ; lint-ignore: critical-section
        }

        if (gGUI_State = "ALT_PENDING") {
            ; First Tab - freeze with current data and go to ACTIVE
            gGUI_FirstTabTick := A_TickCount
            gGUI_TabCount := 1
            gGUI_State := "ACTIVE"
            global gStats_AltTabs, gStats_TabSteps
            gStats_AltTabs += 1
            gStats_TabSteps += 1


            ; Freeze: save ALL items (for workspace toggle), then filter
            ; CRITICAL: Create shallow copy - assignment creates a reference which breaks freeze!
            gGUI_ToggleBase := []
            for _, item in gGUI_LiveItems {
                gGUI_ToggleBase.Push(item)
            }
            gGUI_DisplayItems := GUI_FilterByWorkspaceMode(gGUI_ToggleBase)

            ; DEBUG: Log workspace data of display items
            if (cfg.DiagEventLog) {
                GUI_LogEvent("FREEZE: " gGUI_DisplayItems.Length " items frozen")
                for i, item in gGUI_DisplayItems {
                    if (i > 5) {
                        GUI_LogEvent("  ... and " (gGUI_DisplayItems.Length - 5) " more")
                        break
                    }
                    ws := item.HasOwnProp("WS") ? item.WS : "(none)"
                    onCur := item.HasOwnProp("isOnCurrentWorkspace") ? item.isOnCurrentWorkspace : "(none)"
                    title := item.HasOwnProp("Title") ? SubStr(item.Title, 1, 25) : "?"
                    GUI_LogEvent("  [" i "] '" title "' ws='" ws "' onCur=" onCur)
                }
            }

            ; Selection: First Alt+Tab selects the PREVIOUS window (position 2 in 1-based MRU list)
            ; Position 1 = current window (we're already on it)
            ; Position 2 = previous window (what Alt+Tab should switch to)
            gGUI_Sel := 2
            if (gGUI_Sel > gGUI_DisplayItems.Length) {
                ; Only 1 window? Select it
                gGUI_Sel := 1
            }
            ; Pin selection at top (virtual scroll)
            gGUI_ScrollTop := gGUI_Sel - 1

            ; Start grace timer - show GUI after delay
            SetTimer(GUI_GraceTimerFired, -cfg.AltTabGraceMs)
            return  ; lint-ignore: critical-section
        }

        if (gGUI_State = "ACTIVE") {
            gGUI_TabCount += 1
            global gStats_TabSteps
            gStats_TabSteps += 1
            delta := shiftHeld ? -1 : 1
            GUI_MoveSelectionFrozen(delta)

            ; Recalculate hover based on current mouse position after scroll
            ; This ensures action buttons follow the mouse, not the row index
            GUI_RecalcHover()

            ; ============================================================
            ; CRITICAL MUST STAY ON DURING RENDERING - DO NOT CHANGE
            ; ============================================================
            ; A previous optimization tried releasing Critical "Off" here to
            ; improve keyboard responsiveness during GDI+ rendering (~16ms).
            ; This caused severe bugs:
            ;   1. Partial glass background draws (IPC interrupted mid-render)
            ;   2. Window mapping corruption (gGUI_LiveItems modified during render)
            ;   3. Stale projection data on quick re-open
            ; The ~16ms delay is acceptable - users won't notice, but they WILL
            ; notice corrupted UI. Keep Critical on through the entire handler.
            ; ============================================================

            ; If GUI not yet visible (still in grace period), show it now on 2nd Tab
            if (!gGUI_OverlayVisible && gGUI_TabCount > 1) {
                SetTimer(GUI_GraceTimerFired, 0)  ; Cancel grace timer
                GUI_ShowOverlayWithFrozen()
            } else if (gGUI_OverlayVisible) {
                GUI_Repaint()
            }
        }
        return  ; lint-ignore: critical-section
    }

    if (evCode = TABBY_EV_ALT_UP) {
        ; DEBUG: Show ALT_UP arrival (controlled by DiagAltTabTooltips config)
        if (cfg.DiagAltTabTooltips) {
            ToolTip("ALT_UP: state=" gGUI_State " visible=" gGUI_OverlayVisible, 100, 200, 3)
            SetTimer(() => ToolTip(,,,3), -2000)
        }

        if (gGUI_State = "ALT_PENDING") {
            ; Alt released without Tab - return to IDLE
            gGUI_State := "IDLE"
            return  ; lint-ignore: critical-section
        }

        if (gGUI_State = "ACTIVE") {
            SetTimer(GUI_GraceTimerFired, 0)  ; Cancel grace timer

            timeSinceTab := A_TickCount - gGUI_FirstTabTick

            if (!gGUI_OverlayVisible && timeSinceTab < cfg.AltTabQuickSwitchMs) {
                ; Quick switch: Alt+Tab released quickly, no GUI shown
                global gStats_QuickSwitches
                gStats_QuickSwitches += 1
                GUI_ActivateFromFrozen()
            } else if (gGUI_OverlayVisible) {
                ; Normal case: hide FIRST (feels snappy), then activate
                GUI_HideOverlay()
                GUI_ActivateFromFrozen()
            } else {
                ; Edge case: grace period expired but GUI not shown yet
                GUI_ActivateFromFrozen()
            }

            gGUI_DisplayItems := []
            gGUI_State := "IDLE"
            Stats_SendToStore()

            ; NOTE: Activation is now async (non-blocking) for cross-workspace switches.
            ; Keyboard events are processed normally between timer fires.
            ; No buffering needed - just request snapshot to resync after activation completes.
            ; The async timer will call GUI_RequestSnapshot() when done.
        }
        return  ; lint-ignore: critical-section
    }

    if (evCode = TABBY_EV_ESCAPE) {
        ; Cancel - hide without activating
        global gStats_Cancellations
        gStats_Cancellations += 1
        SetTimer(GUI_GraceTimerFired, 0)  ; Cancel grace timer
        if (gGUI_OverlayVisible) {
            GUI_HideOverlay()
        }
        gGUI_State := "IDLE"
        gGUI_DisplayItems := []
        Stats_SendToStore()

        ; Resync with store - we may have missed deltas during ACTIVE
        GUI_RequestSnapshot()
        return  ; lint-ignore: critical-section
    }
}

; ========================= GRACE TIMER =========================

GUI_GraceTimerFired() {
    ; RACE FIX: Prevent race with Alt_Up hotkey - timer can fire while
    ; GUI_OnInterceptorEvent is processing ALT_UP, causing inconsistent state
    Critical "On"
    global gGUI_State, gGUI_OverlayVisible

    ; Double-check state - may have changed between scheduling and firing
    if (gGUI_State = "ACTIVE" && !gGUI_OverlayVisible) {
        GUI_ShowOverlayWithFrozen()
    }
    Critical "Off"
}

; ========================= FROZEN STATE HELPERS =========================

; Reset selection to MRU position (1 or 2) and clamp to list bounds.
; After a workspace switch, sel=1 (focused window on NEW workspace is what you want).
; Otherwise, sel=2 (the "previous" window — standard Alt-Tab behavior).
; Parameters:
;   listRef - Optional reference to the list to use (default: gGUI_DisplayItems)
; Returns: The new selection index
GUI_ResetSelectionToMRU(listRef := "") {
    global gGUI_Sel, gGUI_ScrollTop, gGUI_DisplayItems, gGUI_WSContextSwitch
    items := (listRef != "") ? listRef : gGUI_DisplayItems

    ; After a workspace switch, the focused window on the new workspace is at position 1.
    ; Keep sel=1 for the entire overlay session so Ctrl toggles don't revert to sel=2.
    gGUI_Sel := gGUI_WSContextSwitch ? 1 : 2
    if (gGUI_Sel > items.Length) {
        gGUI_Sel := (items.Length > 0) ? 1 : 0
    }
    gGUI_ScrollTop := (gGUI_Sel > 0) ? gGUI_Sel - 1 : 0
    return gGUI_Sel
}

; Helper to abort a show sequence (hide windows and reset state flags).
; Called when state changes to non-ACTIVE during GUI_ShowOverlayWithFrozen.
_GUI_AbortShowSequence() {
    global gGUI_Overlay, gGUI_Base, gGUI_OverlayVisible, gGUI_Revealed
    try gGUI_Overlay.Hide()
    try gGUI_Base.Hide()
    gGUI_OverlayVisible := false
    gGUI_Revealed := false
}

GUI_ShowOverlayWithFrozen() {
    global gGUI_OverlayVisible, gGUI_Base, gGUI_BaseH, gGUI_Overlay, gGUI_OverlayH
    global gGUI_LiveItems, gGUI_DisplayItems, gGUI_Sel, gGUI_ScrollTop, gGUI_Revealed, cfg
    global gGUI_State
    global gPaint_LastPaintTick, gPaint_SessionPaintCount

    if (gGUI_OverlayVisible) {
        return
    }

    ; ===== TIMING: Show sequence start =====
    tShow_Start := A_TickCount
    idleDuration := (gPaint_LastPaintTick > 0) ? (A_TickCount - gPaint_LastPaintTick) : -1
    Paint_Log("ShowOverlay START (idle=" (idleDuration > 0 ? Round(idleDuration/1000, 1) "s" : "first") " frozen=" gGUI_DisplayItems.Length " items=" gGUI_LiveItems.Length ")")

    ; Set visible flag FIRST to prevent re-entrancy issues
    ; (Show/DwmFlush can pump messages, allowing hotkeys to fire mid-function)
    gGUI_OverlayVisible := true

    ; NOTE: Do NOT set gGUI_LiveItems := gGUI_DisplayItems here!
    ; gGUI_LiveItems must remain the unfiltered source of truth for cross-session consistency.
    ; Paint function correctly uses gGUI_DisplayItems when in ACTIVE state.

    ; ENFORCE: When ScrollKeepHighlightOnTop is true, selected item must be at top
    ; This catches any edge cases where scrollTop wasn't set correctly
    if (cfg.GUI_ScrollKeepHighlightOnTop && gGUI_DisplayItems.Length > 0) {
        gGUI_ScrollTop := gGUI_Sel - 1
    }

    gGUI_Revealed := false

    ; ===== TIMING: Resize + Repaint =====
    ; Both windows stay hidden during resize+paint. GUI_RevealBoth() (called from
    ; inside GUI_Repaint) shows both at the same DwmFlush, preventing any frame
    ; where the acrylic base is visible without the overlay window list.
    t1 := A_TickCount
    rowsDesired := GUI_ComputeRowsToShow(gGUI_DisplayItems.Length)
    GUI_ResizeToRows(rowsDesired)
    tShow_Resize := A_TickCount - t1

    t1 := A_TickCount
    GUI_Repaint()  ; Paint + RevealBoth (shows both windows atomically)
    tShow_Repaint := A_TickCount - t1

    ; RACE FIX: If Alt was released during paint/reveal, RevealBoth already hid
    ; both windows. Abort here to clean up flags and skip hover polling.
    if (gGUI_State != "ACTIVE") {
        Paint_Log("ShowOverlay ABORT after Repaint (state=" gGUI_State ")")
        _GUI_AbortShowSequence()
        return
    }

    ; Start hover polling (fallback for WM_MOUSELEAVE)
    GUI_StartHoverPolling()

    ; ===== TIMING: Log show sequence =====
    tShow_Total := A_TickCount - tShow_Start
    Paint_Log("ShowOverlay END: total=" tShow_Total "ms | resize=" tShow_Resize " repaint=" tShow_Repaint)
}

GUI_MoveSelectionFrozen(delta) {
    global gGUI_Sel, gGUI_DisplayItems, gGUI_ScrollTop

    if (gGUI_DisplayItems.Length = 0) {
        return
    }

    count := gGUI_DisplayItems.Length
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
    global gGUI_Sel, gGUI_DisplayItems, cfg

    if (cfg.DiagEventLog)
        GUI_LogEvent("ACTIVATE FROM FROZEN: sel=" gGUI_Sel " frozen=" gGUI_DisplayItems.Length)

    if (gGUI_Sel < 1 || gGUI_Sel > gGUI_DisplayItems.Length) {
        if (cfg.DiagEventLog)
            GUI_LogEvent("ACTIVATE FAILED: sel out of range!")
        return
    }

    item := gGUI_DisplayItems[gGUI_Sel]
    hwnd := item.hwnd

    ; Validate window still exists before activation (may have closed during overlay display)
    if (!DllCall("user32\IsWindow", "ptr", hwnd, "int")) {
        if (cfg.DiagEventLog)
            GUI_LogEvent("ACTIVATE SKIP: window gone hwnd=" hwnd " title=" (item.HasOwnProp("title") ? SubStr(item.title, 1, 30) : "?"))
        return
    }

    if (cfg.DiagEventLog) {
        title := item.HasOwnProp("title") ? SubStr(item.title, 1, 30) : "?"
        ws := item.HasOwnProp("WS") ? item.WS : "?"
        onCur := item.HasOwnProp("isOnCurrentWorkspace") ? item.isOnCurrentWorkspace : "?"
        GUI_LogEvent("ACTIVATE: '" title "' ws=" ws " onCurrent=" onCur)
    }

    GUI_ActivateItem(item)
}

; ========================= ACTIVATION =========================

; Unified activation logic with cross-workspace support via komorebi
; For cross-workspace: ASYNC (non-blocking) to allow keyboard events during switch
; For same-workspace: SYNC (immediate) for speed
; Uses komorebi's activation pattern: SendInput → SetWindowPos → SetForegroundWindow
GUI_ActivateItem(item) {
    global cfg
    global gGUI_PendingHwnd, gGUI_PendingWSName
    global gGUI_PendingDeadline, gGUI_PendingPhase, gGUI_PendingWaitUntil
    global gGUI_PendingShell, gGUI_PendingTempFile
    global gGUI_LiveItems, gGUI_LastLocalMRUTick, gGUI_CurrentWSName  ; Needed for same-workspace MRU update

    hwnd := item.hwnd
    if (!hwnd) {
        return
    }

    ; Check if window is on a different workspace
    isOnCurrent := item.HasOwnProp("isOnCurrentWorkspace") ? item.isOnCurrentWorkspace : true
    wsName := item.HasOwnProp("WS") ? item.WS : ""

    ; DEBUG: Log all async activation conditions
    if (cfg.DiagEventLog) {
        komorebicPath := cfg.HasOwnProp("KomorebicExe") ? cfg.KomorebicExe : "(not set)"
        komorebicExists := (komorebicPath != "(not set)" && FileExist(komorebicPath)) ? "yes" : "no"
        curWS := IsSet(gGUI_CurrentWSName) ? gGUI_CurrentWSName : "(unknown)"  ; lint-ignore: isset-with-default
        GUI_LogEvent("ACTIVATE_COND: isOnCurrent=" isOnCurrent " wsName='" wsName "' curWS='" curWS "' komorebic='" komorebicPath "' exists=" komorebicExists)
    }

    ; === Cross-workspace activation ===
    if (!isOnCurrent && wsName != "") {
        global gStats_CrossWorkspace
        gStats_CrossWorkspace += 1

        crossMethod := cfg.KomorebiCrossWorkspaceMethod
        if (cfg.DiagEventLog)
            GUI_LogEvent("CROSS-WS: method=" crossMethod " hwnd=" hwnd " ws='" wsName "'")

        ; MimicNative: Direct uncloak + activate via COM (like native Alt+Tab)
        ; Komorebi's reconciliation detects focus change and switches workspaces
        if (crossMethod = "MimicNative") {
            ; Returns: 0=failed, 1=uncloaked (need activate), 2=uncloaked+activated via SwitchTo
            uncloakResult := _GUI_UncloakWindow(hwnd)
            if (cfg.DiagEventLog)
                GUI_LogEvent("CROSS-WS: MimicNative uncloakResult=" uncloakResult)

            if (uncloakResult = 2) {
                ; Full success - SwitchTo handled activation
                if (cfg.DiagEventLog)
                    GUI_LogEvent("CROSS-WS: MimicNative success (SwitchTo)")
                ; Optional settle delay for slower systems
                if (cfg.KomorebiMimicNativeSettleMs > 0)
                    Sleep(cfg.KomorebiMimicNativeSettleMs)
                _GUI_UpdateLocalMRU(hwnd)
                return
            } else if (uncloakResult = 1) {
                ; Uncloaked but SwitchTo failed - use manual activation
                if (cfg.DiagEventLog)
                    GUI_LogEvent("CROSS-WS: MimicNative partial (manual activate)")
                if (_GUI_RobustActivate(hwnd))
                    _GUI_UpdateLocalMRU(hwnd)
                return
            }
            ; uncloakResult = 0: COM failed entirely, fall through to SwitchActivate
            if (cfg.DiagEventLog)
                GUI_LogEvent("CROSS-WS: MimicNative failed, falling back to SwitchActivate")
        }

        ; RevealMove: Uncloak window, focus it, then command komorebi to move it back
        ; This makes the window focused BEFORE the workspace switch, avoiding flash
        if (crossMethod = "RevealMove") {
            ; Step 1: Uncloak (we only need uncloaking, not SwitchTo)
            uncloakResult := _GUI_UncloakWindow(hwnd)
            if (cfg.DiagEventLog)
                GUI_LogEvent("CROSS-WS: RevealMove uncloakResult=" uncloakResult)

            if (uncloakResult > 0) {
                ; Step 2: Focus the window (makes it the "focused window" for komorebic)
                ; Gate on success — if activation fails, komorebic move would target wrong window
                if (_GUI_RobustActivate(hwnd)) {
                    if (cfg.DiagEventLog)
                        GUI_LogEvent("CROSS-WS: RevealMove focused window")

                    ; Step 3: Command komorebi to move the focused window to its workspace
                    ; This switches to that workspace WITH our window already focused
                    try {
                        _GUI_KomorebiWorkspaceCmd("MoveToNamedWorkspace", "move-to-named-workspace", wsName)
                    } catch as e {
                        if (cfg.DiagEventLog)
                            GUI_LogEvent("CROSS-WS: RevealMove move command failed: " e.Message)
                    }

                    _GUI_UpdateLocalMRU(hwnd)
                } else if (cfg.DiagEventLog) {
                    GUI_LogEvent("CROSS-WS: RevealMove activation failed, skipping move")
                }
                return
            }
            ; uncloakResult = 0: COM failed, fall through to SwitchActivate
            if (cfg.DiagEventLog)
                GUI_LogEvent("CROSS-WS: RevealMove failed (COM), falling back to SwitchActivate")
        }

        ; SwitchActivate: Command komorebi to switch, poll for completion, then activate
        ; This path is used when: config=SwitchActivate OR MimicNative/RevealMove failed
        _GUI_StartSwitchActivate(hwnd, wsName)
        return
    }

    ; === Same-workspace: SYNC activation (immediate, fast) ===
    ; CRITICAL: Only update MRU on successful activation — prevents phantom MRU
    ; corruption that causes "double failure" on next Alt+Tab
    if (_GUI_RobustActivate(hwnd))
        _GUI_UpdateLocalMRU(hwnd)

    ; NOTE: Do NOT request snapshot here - it would overwrite our local MRU update
    ; with stale store data. The store will get the focus update via WinEventHook.

    ; CRITICAL: After activation, keyboard events may have been queued but not processed
    ; Use SetTimer -1 to let message pump run, then resync keyboard state
    SetTimer(_GUI_ResyncKeyboardState, -1)
}

; ========================= SWITCH-ACTIVATE METHOD =========================

; Start the SwitchActivate cross-workspace method:
; 1. Command komorebi to switch workspaces
; 2. Start async polling timer to detect completion
; 3. Timer will activate window once switch completes
_GUI_StartSwitchActivate(hwnd, wsName) {
    global cfg
    global gGUI_PendingHwnd, gGUI_PendingWSName
    global gGUI_PendingDeadline, gGUI_PendingPhase, gGUI_PendingWaitUntil
    global gGUI_PendingShell, gGUI_PendingTempFile
    global gGUI_EventBuffer

    if (cfg.DiagEventLog)
        GUI_LogEvent("SWITCH-ACTIVATE: Starting for hwnd=" hwnd " ws='" wsName "'")

    ; Initialize pending state
    gGUI_PendingHwnd := hwnd
    gGUI_PendingWSName := wsName
    gGUI_PendingDeadline := A_TickCount + cfg.AltTabWSPollTimeoutMs
    gGUI_PendingWaitUntil := 0
    gGUI_EventBuffer := []

    ; Create WScript.Shell for async command execution (reuse if exists)
    if (!gGUI_PendingShell)
        gGUI_PendingShell := ComObject("WScript.Shell")

    ; Temp file for komorebic query output (PollKomorebic method)
    if (!gGUI_PendingTempFile)
        gGUI_PendingTempFile := A_Temp "\tabby_ws_query.txt"

    ; Trigger workspace switch (via socket or komorebic.exe)
    try {
        _GUI_KomorebiWorkspaceCmd("FocusNamedWorkspace", "focus-named-workspace", wsName)
    } catch as e {
        if (cfg.DiagEventLog)
            GUI_LogEvent("SWITCH-ACTIVATE ERROR: " e.Message)
        ; Fall back to direct activation attempt
        if (_GUI_RobustActivate(hwnd))
            _GUI_UpdateLocalMRU(hwnd)
        return
    }

    ; Start polling phase
    Critical "On"
    gGUI_PendingPhase := "polling"
    Critical "Off"

    ; Start async timer
    SetTimer(_GUI_AsyncActivationTick, cfg.AltTabAsyncActivationPollMs)
    if (cfg.DiagEventLog)
        GUI_LogEvent("SWITCH-ACTIVATE: Polling started")
}

; ========================= ASYNC ACTIVATION TIMER =========================

; Called every 15ms during cross-workspace activation
; Yields control between fires, allowing keyboard hook callbacks to run
_GUI_AsyncActivationTick() {
    global cfg
    global gGUI_PendingHwnd, gGUI_PendingWSName
    global gGUI_PendingDeadline, gGUI_PendingPhase, gGUI_PendingWaitUntil
    global gGUI_PendingShell, gGUI_PendingTempFile
    global gGUI_EventBuffer, TABBY_EV_ALT_DOWN, TABBY_EV_TAB_STEP, TABBY_FLAG_SHIFT
    global gGUI_LiveItems, gGUI_CurrentWSName, gGUI_LastLocalMRUTick

    ; RACE FIX: Ensure phase reads and transitions are atomic
    ; Phase can be read by interceptor to decide whether to buffer events
    Critical "On"

    ; Safety: if no pending activation, stop timer
    if (gGUI_PendingPhase = "") {
        SetTimer(_GUI_AsyncActivationTick, 0)
        Critical "Off"
        return
    }
    ; Read phase into local variable for consistent use throughout function
    phase := gGUI_PendingPhase
    Critical "Off"

    ; === CRITICAL: Detect missed Tab events ===
    ; During workspace switch, komorebic uses SendInput which briefly uninstalls
    ; all keyboard hooks in the system. This can cause Tab presses to be lost.
    ; If we see Alt+Tab physically held but no TAB event in buffer, synthesize one.
    ; BUT: Only synthesize if the interceptor is NOT in its decision window (gINT_TabPending).
    ; If TabPending is true, the interceptor will eventually send the Tab event itself.
    global gINT_TabPending
    if (phase = "polling" && GetKeyState("Alt", "P") && GetKeyState("Tab", "P") && !gINT_TabPending) {
        ; Protect buffer read+write with Critical to prevent interceptor interruption
        Critical "On"
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
            if (cfg.DiagEventLog)
                GUI_LogEvent("ASYNC: detected missed Tab press, synthesizing TAB_STEP")
            gGUI_EventBuffer.Push({ev: TABBY_EV_TAB_STEP, flags: shiftFlag, lParam: 0})
        }
        Critical "Off"
    }

    now := A_TickCount

    ; === PHASE 1: Poll for workspace switch completion ===
    if (phase = "polling") {
        ; Check if deadline exceeded
        if (now > gGUI_PendingDeadline) {
            ; Timeout - do activation anyway
            if (cfg.DiagEventLog)
                GUI_LogEvent("ASYNC TIMEOUT: workspace poll deadline exceeded for '" gGUI_PendingWSName "'")
            ; RACE FIX: Phase transition must be atomic
            Critical "On"
            gGUI_PendingPhase := "waiting"
            gGUI_PendingWaitUntil := now + cfg.AltTabWorkspaceSwitchSettleMs
            Critical "Off"
            return
        }

        ; Dispatch based on confirmation method
        switchComplete := false
        confirmMethod := cfg.KomorebiWorkspaceConfirmMethod

        if (confirmMethod = "PollCloak") {
            ; PollCloak: Check if target window is uncloaked via DwmGetWindowAttribute
            ; When komorebi switches workspaces, it uncloaks windows on the target workspace
            ; Sub-microsecond DllCall vs 50-100ms cmd.exe spawn
            ; DWMWA_CLOAKED = 14 (Windows constant)
            cloakVal := _GUI_IsCloaked(gGUI_PendingHwnd)
            isCloaked := (cloakVal > 0)
            if (!isCloaked) {
                switchComplete := true
                if (cfg.DiagEventLog)
                    GUI_LogEvent("ASYNC POLLCLOAK: window uncloaked, switch complete")
            }
        } else if (confirmMethod = "AwaitDelta") {
            ; AwaitDelta: Watch gGUI_CurrentWSName (updated by deltas via GUI_UpdateCurrentWSFromPayload)
            ; Zero spawning, zero DllCalls - but depends on IPC latency
            if (gGUI_CurrentWSName = gGUI_PendingWSName) {
                switchComplete := true
                if (cfg.DiagEventLog)
                    GUI_LogEvent("ASYNC AWAITDELTA: workspace name matches, switch complete")
            }
        } else {
            ; PollKomorebic (fallback): Poll via cmd.exe spawning
            ; Spawns cmd.exe /c komorebic query focused-workspace-name every tick
            ; Highest CPU but works on multi-monitor setups where PollCloak may not
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
                        switchComplete := true
                        if (cfg.DiagEventLog)
                            GUI_LogEvent("ASYNC POLLKOMOREBIC: workspace name matches, switch complete")
                    }
                }
            }
        }

        if (switchComplete) {
            ; Switch complete! Move to waiting phase
            ; RACE FIX: Phase transition must be atomic
            Critical "On"
            gGUI_PendingPhase := "waiting"
            gGUI_PendingWaitUntil := now + cfg.AltTabWorkspaceSwitchSettleMs
            Critical "Off"
            return
        }
        return  ; Keep polling
    }

    ; === PHASE 2: Wait for komorebi's post-switch focus logic ===
    if (phase = "waiting") {
        if (now < gGUI_PendingWaitUntil) {
            return  ; Keep waiting
        }

        ; Wait complete - do robust activation
        hwnd := gGUI_PendingHwnd
        if (cfg.DiagEventLog)
            GUI_LogEvent("ASYNC COMPLETE: activating hwnd " hwnd " (buf=" gGUI_EventBuffer.Length ")")
        try _GUI_RobustActivate(hwnd)

        ; Stop the async timer (unconditional - must run even if activation threw)
        SetTimer(_GUI_AsyncActivationTick, 0)

        ; CRITICAL: Update current workspace name IMMEDIATELY
        ; Don't wait for IPC - we know we just switched to gGUI_PendingWSName
        ; This ensures buffered Alt+Tab events use correct workspace data
        ; Also fixes stale freeze issue when FreezeWindowList=true
        if (gGUI_PendingWSName != "") {
            if (cfg.DiagEventLog)
                GUI_LogEvent("ASYNC: updating curWS from '" gGUI_CurrentWSName "' to '" gGUI_PendingWSName "'")
            ; RACE FIX: Protect workspace name and items iteration from GUI_ApplyDelta (IPC timer)
            Critical "On"
            gGUI_CurrentWSName := gGUI_PendingWSName

            ; Update isOnCurrentWorkspace flags in gGUI_LiveItems to match new workspace
            ; This ensures display lists have correct workspace data
            for item in gGUI_LiveItems {
                if (item.HasOwnProp("WS")) {
                    item.isOnCurrentWorkspace := (item.WS = gGUI_CurrentWSName)
                }
            }
            Critical "Off"
        }

        ; CRITICAL: Update MRU order - move activated window to position 1
        ; Don't wait for IPC - we know we just activated gGUI_PendingHwnd
        ; This ensures buffered Alt+Tab selects the PREVIOUS window, not the same one
        _GUI_UpdateLocalMRU(gGUI_PendingHwnd)

        ; CRITICAL: Do NOT clear gGUI_PendingPhase yet!
        ; If we clear it now, any pending Tab_Decide timers from the interceptor
        ; will send events that bypass the buffer, arriving out of order.
        ; Keep the phase set to "flushing" so events continue to be buffered
        ; until _GUI_ProcessEventBuffer completes.
        ; RACE FIX: Phase transition must be atomic
        Critical "On"
        gGUI_PendingPhase := "flushing"
        Critical "Off"

        ; NOTE: Do NOT request snapshot here - it would overwrite our local MRU update
        ; with stale store data. The store will get the focus update via WinEventHook.

        ; Process any buffered events (user did Alt+Tab during our async activation)
        ; This will clear gGUI_PendingPhase when done
        if (cfg.DiagEventLog)
            GUI_LogEvent("ASYNC: scheduling buffer processing")
        SetTimer(_GUI_ProcessEventBuffer, -1)
        return
    }
}

; Process buffered events after async activation completes
; Called via SetTimer -1 after async complete, with gGUI_PendingPhase="flushing"
_GUI_ProcessEventBuffer() {
    global gGUI_EventBuffer, gGUI_LiveItems, gGUI_PendingPhase, TABBY_EV_ALT_DOWN, TABBY_EV_TAB_STEP, TABBY_EV_ALT_UP, cfg

    ; Validate we're in flushing phase - prevents stale timers from processing
    if (gGUI_PendingPhase != "flushing") {
        if (cfg.DiagEventLog)
            GUI_LogEvent("BUFFER SKIP: not in flushing phase (phase=" gGUI_PendingPhase ")")
        return
    }

    if (cfg.DiagEventLog)
        GUI_LogEvent("BUFFER PROCESS: " gGUI_EventBuffer.Length " events, items=" gGUI_LiveItems.Length)

    ; Process all buffered events in order
    ; CRITICAL: Swap+phase-clear must be atomic to prevent race condition
    ; where new events arrive after phase clear but before buffer swap
    ; PERF: Swap pattern avoids Clone() allocation - just reassign references
    Critical "On"
    events := gGUI_EventBuffer
    gGUI_EventBuffer := []
    _GUI_ClearPendingState()  ; Clear phase AFTER swap to prevent out-of-order events
    Critical "Off"

    if (events.Length = 0) {
        ; No buffered events - just resync keyboard state
        if (cfg.DiagEventLog)
            GUI_LogEvent("BUFFER: empty, resyncing keyboard state")
        _GUI_ResyncKeyboardState()
        return
    }

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
        if (cfg.DiagEventLog)
            GUI_LogEvent("BUFFER: detected lost Tab (ALT_DN+ALT_UP without TAB), synthesizing TAB_STEP")
        events.InsertAt(altDnIdx + 1, {ev: TABBY_EV_TAB_STEP, flags: 0, lParam: 0})
    }

    if (cfg.DiagEventLog)
        GUI_LogEvent("BUFFER: processing " events.Length " events now")
    for ev in events {
        GUI_OnInterceptorEvent(ev.ev, ev.flags, ev.lParam)
    }
    if (cfg.DiagEventLog)
        GUI_LogEvent("BUFFER: done processing")
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
    global gGUI_PendingHwnd, gGUI_PendingWSName
    global gGUI_PendingDeadline, gGUI_PendingPhase, gGUI_PendingWaitUntil
    global gGUI_PendingTempFile, gGUI_PendingShell

    ; Clean up temp file
    try FileDelete(gGUI_PendingTempFile)

    ; Release COM object to prevent memory leak
    ; In AHK v2, setting to "" releases the COM reference
    gGUI_PendingShell := ""

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

; ========================= LOCAL MRU UPDATE =========================

; Update local MRU order - move activated window to position 1
; Called after successful activation to ensure rapid Alt+Tab sees correct order
; Parameters:
;   hwnd - Window handle that was activated
; Updates: gGUI_LiveItems array order, gGUI_LastLocalMRUTick
; NOTE: Callers hold Critical — do NOT call Critical "Off" here (leaks caller's Critical state)
_GUI_UpdateLocalMRU(hwnd) {
    Critical "On"  ; Harmless assertion — documents that Critical is required
    global gGUI_LiveItems, gGUI_LastLocalMRUTick, gGUI_LiveItemsMap, cfg

    ; O(1) miss detection: if hwnd not in Map, skip the O(n) linear scan
    if (!gGUI_LiveItemsMap.Has(hwnd)) {
        if (cfg.DiagEventLog)
            GUI_LogEvent("MRU UPDATE: hwnd " hwnd " not in map, skip scan")
        return false  ; lint-ignore: critical-section
    }

    if (cfg.DiagEventLog)
        GUI_LogEvent("MRU UPDATE: searching for hwnd " hwnd " in " gGUI_LiveItems.Length " items")
    for i, item in gGUI_LiveItems {
        if (item.hwnd = hwnd) {
            item.lastActivatedTick := A_TickCount
            if (cfg.DiagEventLog)
                GUI_LogEvent("MRU UPDATE: found at position " i ", moving to position 1")
            if (i > 1) {
                gGUI_LiveItems.RemoveAt(i)
                gGUI_LiveItems.InsertAt(1, item)
            }
            gGUI_LastLocalMRUTick := A_TickCount
            return true  ; lint-ignore: critical-section
        }
    }
    if (cfg.DiagEventLog)
        GUI_LogEvent("MRU UPDATE: hwnd " hwnd " not found in items")
    return false  ; lint-ignore: critical-section
}

; ========================= DIRECT WINDOW UNCLOAKING (COM) =========================
; Mimics native Alt+Tab: uncloak target window directly, then activate.
; Komorebi's reconciliation detects the focus change and switches workspaces to match.
; This avoids the "flash" where komorebi's default focused window appears briefly.

; Convert string GUID to binary CLSID structure
_GUI_StringToGUID(guidStr, buf) {
    ; Remove braces if present
    guidStr := StrReplace(guidStr, "{", "")
    guidStr := StrReplace(guidStr, "}", "")

    ; Parse GUID: XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
    parts := StrSplit(guidStr, "-")
    if (parts.Length != 5)
        return false

    ; Data1 (4 bytes, little-endian)
    NumPut("UInt", Integer("0x" parts[1]), buf, 0)
    ; Data2 (2 bytes)
    NumPut("UShort", Integer("0x" parts[2]), buf, 4)
    ; Data3 (2 bytes)
    NumPut("UShort", Integer("0x" parts[3]), buf, 6)
    ; Data4 (8 bytes, big-endian pairs)
    d4 := parts[4] parts[5]  ; Concatenate last two parts
    Loop 8 {
        NumPut("UChar", Integer("0x" SubStr(d4, (A_Index - 1) * 2 + 1, 2)), buf, 7 + A_Index)
    }
    return true
}

; Initialize COM interfaces for direct uncloaking
; Uses IServiceProvider::QueryService to get IApplicationViewCollection
; RACE FIX: Wrapped in Critical to prevent multiple hotkey callbacks from racing
_GUI_InitAppViewCollection() {
    Critical "On"  ; Prevent race between multiple hotkey callbacks
    global gGUI_ImmersiveShell, gGUI_AppViewCollection, cfg

    if (gGUI_AppViewCollection) {
        Critical "Off"
        return true  ; Already initialized
    }

    ; IApplicationViewCollection GUIDs for different Windows versions
    static appViewCollectionGuids := [
        "{1841C6D7-4F9D-42C0-AF41-8747538F10E5}",  ; Windows 10/11 common
        "{2C08ADF0-A386-4B35-9250-0FE183476FCC}",  ; Windows 11 newer builds
    ]

    try {
        ; Create ImmersiveShell
        if (cfg.DiagEventLog)
            GUI_LogEvent("COM: Creating ImmersiveShell...")
        gGUI_ImmersiveShell := ComObject("{C2F03A33-21F5-47FA-B4BB-156362A2F239}", "{00000000-0000-0000-C000-000000000046}")
        shellPtr := gGUI_ImmersiveShell.Ptr
        if (cfg.DiagEventLog)
            GUI_LogEvent("COM: ImmersiveShell ptr=" shellPtr)

        ; Get IServiceProvider via QueryInterface
        ; IServiceProvider IID: {6D5140C1-7436-11CE-8034-00AA006009FA}
        if (cfg.DiagEventLog)
            GUI_LogEvent("COM: Getting IServiceProvider...")
        static iidServiceProvider := Buffer(16)
        _GUI_StringToGUID("{6D5140C1-7436-11CE-8034-00AA006009FA}", iidServiceProvider)

        pServiceProvider := 0
        vtable := NumGet(shellPtr, "UPtr")
        queryInterface := NumGet(vtable, 0, "UPtr")  ; vtable[0] = QueryInterface
        hr := DllCall(queryInterface, "Ptr", shellPtr, "Ptr", iidServiceProvider.Ptr, "Ptr*", &pServiceProvider, "UInt")
        if (cfg.DiagEventLog)
            GUI_LogEvent("COM: QueryInterface(IServiceProvider) hr=" Format("0x{:08X}", hr) " ptr=" pServiceProvider)

        if (hr != 0 || !pServiceProvider) {
            if (cfg.DiagEventLog)
                GUI_LogEvent("COM: Failed to get IServiceProvider")
            Critical "Off"
            return false
        }

        ; Try each IApplicationViewCollection GUID via QueryService
        ; IServiceProvider vtable: [QI, AddRef, Release, QueryService]
        ; QueryService(REFGUID guidService, REFIID riid, void** ppv)
        spVtable := NumGet(pServiceProvider, "UPtr")
        queryService := NumGet(spVtable, 3 * A_PtrSize, "UPtr")  ; vtable[3]

        static guidBuf := Buffer(16)

        for guidStr in appViewCollectionGuids {
            if (cfg.DiagEventLog)
                GUI_LogEvent("COM: Trying QueryService with " guidStr)
            _GUI_StringToGUID(guidStr, guidBuf)

            pCollection := 0
            hr := DllCall(queryService, "Ptr", pServiceProvider, "Ptr", guidBuf.Ptr, "Ptr", guidBuf.Ptr, "Ptr*", &pCollection, "UInt")
            if (cfg.DiagEventLog)
                GUI_LogEvent("COM: QueryService hr=" Format("0x{:08X}", hr) " ptr=" pCollection)

            if (hr = 0 && pCollection) {
                gGUI_AppViewCollection := pCollection
                if (cfg.DiagEventLog)
                    GUI_LogEvent("COM: Success! IApplicationViewCollection=" pCollection)
                ; Release IServiceProvider (we're done with it)
                release := NumGet(spVtable, 2 * A_PtrSize, "UPtr")
                DllCall(release, "Ptr", pServiceProvider)
                Critical "Off"
                return true
            }
        }

        ; Release IServiceProvider
        release := NumGet(spVtable, 2 * A_PtrSize, "UPtr")
        DllCall(release, "Ptr", pServiceProvider)

        if (cfg.DiagEventLog)
            GUI_LogEvent("COM: All GUIDs failed")
        Critical "Off"
        return false
    } catch as e {
        if (cfg.DiagEventLog)
            GUI_LogEvent("COM INIT ERROR: " e.Message " | Extra: " (e.HasOwnProp("Extra") ? e.Extra : "none"))
        gGUI_ImmersiveShell := 0
        gGUI_AppViewCollection := 0
        Critical "Off"
        return false
    }
}

; Check if a window is cloaked via DWM
_GUI_IsCloaked(hwnd) {
    static cloakBuf := Buffer(4, 0)
    hr := DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", 14, "ptr", cloakBuf.Ptr, "uint", 4, "int")
    if (hr != 0)
        return -1  ; Error
    return NumGet(cloakBuf, 0, "UInt")
}

; Uncloak and activate a window via COM (MimicNative method)
; Uses IApplicationView::SetCloak to uncloak, then IApplicationView::SwitchTo to activate
; Returns: 0 = failed, 1 = uncloaked (need manual activate), 2 = uncloaked + activated via SwitchTo
_GUI_UncloakWindow(hwnd) {
    global cfg

    ; Check initial cloak state
    cloakBefore := _GUI_IsCloaked(hwnd)
    if (cfg.DiagEventLog)
        GUI_LogEvent("UNCLOAK: hwnd=" hwnd " cloakBefore=" cloakBefore)

    if (cloakBefore = 0) {
        if (cfg.DiagEventLog)
            GUI_LogEvent("UNCLOAK: Already uncloaked")
        return 1  ; Already visible, but need manual activate
    }

    ; Use COM interface: SetCloak to uncloak, SwitchTo to activate
    comResult := _GUI_TryComUncloak(hwnd)
    cloakAfter := _GUI_IsCloaked(hwnd)
    if (cfg.DiagEventLog)
        GUI_LogEvent("UNCLOAK: comResult=" comResult " cloakAfter=" cloakAfter)

    if (comResult = 2) {
        return 2  ; Full success - uncloaked + activated
    } else if (comResult = 1 && cloakAfter = 0) {
        return 1  ; Uncloaked but SwitchTo failed - need manual activate
    }

    if (cfg.DiagEventLog)
        GUI_LogEvent("UNCLOAK: COM failed")
    return 0
}

; Try COM-based uncloaking and activation
; Returns: 0 = failed, 1 = uncloak only, 2 = uncloak + SwitchTo succeeded
_GUI_TryComUncloak(hwnd) {
    global gGUI_AppViewCollection, cfg

    ; Try to initialize if not already done
    if (!gGUI_AppViewCollection && !_GUI_InitAppViewCollection())
        return 0

    viewVtable := 0
    try {
        ; IApplicationViewCollection vtable:
        ; [0-2] IUnknown, [3] GetViews, [4] GetViewsByZOrder, [5] GetViewsByAppUserModelId
        ; [6] GetViewForHwnd(HWND, IApplicationView**)
        collectionVtable := NumGet(gGUI_AppViewCollection, "UPtr")
        getViewForHwnd := NumGet(collectionVtable, 6 * A_PtrSize, "UPtr")

        pView := 0
        hr := DllCall(getViewForHwnd, "Ptr", gGUI_AppViewCollection, "Ptr", hwnd, "Ptr*", &pView, "UInt")
        if (cfg.DiagEventLog)
            GUI_LogEvent("COM: GetViewForHwnd hr=" Format("0x{:08X}", hr) " pView=" pView)

        if (hr != 0 || !pView) {
            if (cfg.DiagEventLog)
                GUI_LogEvent("COM: GetViewForHwnd failed")
            return 0
        }

        ; IApplicationView vtable:
        ; [0-2] IUnknown, [3-5] IInspectable
        ; [6] SetFocus, [7] SwitchTo, [8] TryInvokeBack, [9] GetThumbnailWindow
        ; [10] GetMonitor, [11] GetVisibility, [12] SetCloak(cloakType, flags)
        viewVtable := NumGet(pView, "UPtr")

        ; Step 1: SetCloak(1, 0) = uncloak
        setCloak := NumGet(viewVtable, 12 * A_PtrSize, "UPtr")
        hr := DllCall(setCloak, "Ptr", pView, "UInt", 1, "Int", 0, "UInt")
        if (cfg.DiagEventLog)
            GUI_LogEvent("COM: SetCloak(1,0) hr=" Format("0x{:08X}", hr))

        uncloakOk := (hr = 0)

        ; Step 2: Try SwitchTo - this is what native Alt+Tab likely uses
        ; SwitchTo activates the window through the shell's view system
        switchTo := NumGet(viewVtable, 7 * A_PtrSize, "UPtr")
        hr := DllCall(switchTo, "Ptr", pView, "UInt")
        if (cfg.DiagEventLog)
            GUI_LogEvent("COM: SwitchTo hr=" Format("0x{:08X}", hr))

        switchOk := (hr = 0)

        ; Release IApplicationView
        releaseView := NumGet(viewVtable, 2 * A_PtrSize, "UPtr")
        DllCall(releaseView, "Ptr", pView)

        if (uncloakOk && switchOk)
            return 2  ; Full success
        else if (uncloakOk)
            return 1  ; Uncloak worked, SwitchTo failed
        else
            return 0  ; Failed
    } catch as e {
        ; Release pView if it was acquired before the exception
        if (pView && viewVtable) {
            releaseView := NumGet(viewVtable, 2 * A_PtrSize, "UPtr")
            DllCall(releaseView, "Ptr", pView)
        }
        if (cfg.DiagEventLog)
            GUI_LogEvent("COM: Exception - " e.Message)
        return 0
    }
}

; ========================= KOMOREBI SOCKET COMMANDS =========================
; Send commands directly to komorebi's named pipe instead of spawning komorebic.exe.
; Much faster (no process spawn overhead), but experimental.

; Send a command to komorebi via its named pipe
; cmdType: Command type (e.g., "FocusNamedWorkspace", "MoveToNamedWorkspace")
; content: Command argument (e.g., workspace name)
; Returns: true on success, false on failure
_GUI_SendKomorebiSocketCmd(cmdType, content) {
    global cfg
    static GENERIC_WRITE := 0x40000000
    static OPEN_EXISTING := 3
    static INVALID_HANDLE := -1

    pipePath := "\\.\pipe\komorebi"

    ; Connect to komorebi's named pipe
    hPipe := DllCall("CreateFileW"
        , "str", pipePath
        , "uint", GENERIC_WRITE
        , "uint", 0          ; no sharing
        , "ptr", 0           ; default security
        , "uint", OPEN_EXISTING
        , "uint", 0          ; normal attributes
        , "ptr", 0           ; no template
        , "ptr")

    if (!hPipe || hPipe = INVALID_HANDLE) {
        if (cfg.DiagEventLog)
            GUI_LogEvent("SOCKET: Failed to connect to " pipePath " GLE=" DllCall("GetLastError", "uint"))
        return false
    }

    ; Build JSON command: {"type":"CmdType","content":"value"}
    ; Escape backslashes first, then quotes (order matters for correct JSON)
    safeContent := StrReplace(content, '\', '\\')
    safeContent := StrReplace(safeContent, '"', '\"')
    json := '{"type":"' cmdType '","content":"' safeContent '"}'

    ; Convert to UTF-8
    len := StrPut(json, "UTF-8") - 1
    buf := Buffer(len)
    StrPut(json, buf, "UTF-8")

    ; Write to pipe
    wrote := 0
    ok := DllCall("WriteFile", "ptr", hPipe, "ptr", buf.Ptr, "uint", len, "uint*", &wrote, "ptr", 0)

    ; Close pipe
    DllCall("CloseHandle", "ptr", hPipe)

    if (!ok || wrote != len) {
        if (cfg.DiagEventLog)
            GUI_LogEvent("SOCKET: Write failed for " cmdType " GLE=" DllCall("GetLastError", "uint"))
        return false
    }

    if (cfg.DiagEventLog)
        GUI_LogEvent("SOCKET: Sent " cmdType '("' content '") via pipe')
    return true
}

; Send a komorebi workspace command (focus or move).
; Uses socket if enabled, falls back to komorebic.exe CLI.
; socketCmd: Socket command type (e.g., "FocusNamedWorkspace")
; cliCmd: CLI subcommand (e.g., "focus-named-workspace")
; wsName: Target workspace name
_GUI_KomorebiWorkspaceCmd(socketCmd, cliCmd, wsName) {
    global cfg

    if (cfg.KomorebiUseSocket) {
        if (_GUI_SendKomorebiSocketCmd(socketCmd, wsName))
            return true
        if (cfg.DiagEventLog)
            GUI_LogEvent("SOCKET: " socketCmd " failed, falling back to komorebic.exe")
    }

    ; Fallback: spawn komorebic.exe
    cmd := '"' cfg.KomorebicExe '" ' cliCmd ' "' wsName '"'
    if (cfg.DiagEventLog)
        GUI_LogEvent("KOMOREBIC: Running " cmd)
    ProcessUtils_RunHidden(cmd)
    return true
}

; ========================= ROBUST WINDOW ACTIVATION =========================

; Robust window activation using komorebi's pattern from windows_api.rs
; SendInput trick → SetWindowPos → SetForegroundWindow
_GUI_RobustActivate(hwnd) {
    global SW_RESTORE, HWND_TOPMOST, HWND_NOTOPMOST, cfg
    global SWP_NOSIZE, SWP_NOMOVE, SWP_SHOWWINDOW

    ; NOTE: Do NOT manually uncloak windows - this interferes with komorebi's
    ; workspace management and can pull windows to the wrong workspace.
    ; Komorebi handles uncloaking when switching workspaces.

    try {
        if (WinExist("ahk_id " hwnd)) {
            ; Restore if minimized
            if (DllCall("user32\IsIconic", "ptr", hwnd, "int"))
                DllCall("user32\ShowWindow", "ptr", hwnd, "int", SW_RESTORE)

            ; Send dummy mouse input to bypass foreground lock (komorebi's trick)
            ; This satisfies Windows' requirement that the process has received recent input
            inputSize := 40  ; sizeof(INPUT) on 64-bit
            input := Buffer(inputSize, 0)
            NumPut("uint", 0, input, 0)  ; type = INPUT_MOUSE
            DllCall("user32\SendInput", "uint", 1, "ptr", input, "int", inputSize)

            ; Bring window to top with SWP_SHOWWINDOW (SYNC — no SWP_ASYNCWINDOWPOS)
            ; Sync positioning ensures the TOPMOST/NOTOPMOST foreground-lock bypass
            ; completes before SetForegroundWindow runs (~1ms, imperceptible)
            swpFlags := SWP_NOSIZE | SWP_NOMOVE | SWP_SHOWWINDOW
            DllCall("user32\SetWindowPos", "ptr", hwnd, "ptr", HWND_TOPMOST
                , "int", 0, "int", 0, "int", 0, "int", 0
                , "uint", swpFlags)

            ; Reset to non-topmost (we just want it on top temporarily, not always-on-top)
            DllCall("user32\SetWindowPos", "ptr", hwnd, "ptr", HWND_NOTOPMOST
                , "int", 0, "int", 0, "int", 0, "int", 0
                , "uint", SWP_NOSIZE | SWP_NOMOVE)

            ; Now SetForegroundWindow should work
            fgResult := DllCall("user32\SetForegroundWindow", "ptr", hwnd)

            ; VERIFY: Don't trust SetForegroundWindow return alone — it can return
            ; non-zero but still fail. Check the actual foreground window.
            actualFg := DllCall("user32\GetForegroundWindow", "ptr")
            if (actualFg = hwnd)
                return true

            if (cfg.DiagEventLog)
                GUI_LogEvent("ACTIVATE VERIFY FAILED: wanted=" hwnd " got=" actualFg " sfwResult=" fgResult)
            return false
        }
        if (cfg.DiagEventLog)
            GUI_LogEvent("ACTIVATE FAIL: window no longer exists, hwnd=" hwnd)
        return false
    } catch as e {
        if (cfg.DiagEventLog)
            GUI_LogEvent("ACTIVATE ERROR: " e.Message " for hwnd=" hwnd)
        return false
    }
}

; ========================= STATS SEND =========================

; Send accumulated session stats to store as deltas
; Called at session end (IDLE transition) and on exit
Stats_SendToStore() {
    global gGUI_StoreClient, gGUI_StoreConnected
    global gStats_AltTabs, gStats_QuickSwitches, gStats_TabSteps
    global gStats_Cancellations, gStats_CrossWorkspace, gStats_WorkspaceToggles
    global gStats_LastSent
    global IPC_MSG_STATS_UPDATE

    ; Calculate deltas since last send
    dAltTabs := gStats_AltTabs - gStats_LastSent.Get("AltTabs", 0)
    dQuick := gStats_QuickSwitches - gStats_LastSent.Get("QuickSwitches", 0)
    dTabs := gStats_TabSteps - gStats_LastSent.Get("TabSteps", 0)
    dCancels := gStats_Cancellations - gStats_LastSent.Get("Cancellations", 0)
    dCrossWS := gStats_CrossWorkspace - gStats_LastSent.Get("CrossWorkspace", 0)
    dToggles := gStats_WorkspaceToggles - gStats_LastSent.Get("WorkspaceToggles", 0)

    ; Skip if nothing to send
    if (dAltTabs = 0 && dQuick = 0 && dTabs = 0 && dCancels = 0 && dCrossWS = 0 && dToggles = 0)
        return

    msg := Map()
    msg["type"] := IPC_MSG_STATS_UPDATE
    if (dAltTabs > 0)
        msg["TotalAltTabs"] := dAltTabs
    if (dQuick > 0)
        msg["TotalQuickSwitches"] := dQuick
    if (dTabs > 0)
        msg["TotalTabSteps"] := dTabs
    if (dCancels > 0)
        msg["TotalCancellations"] := dCancels
    if (dCrossWS > 0)
        msg["TotalCrossWorkspace"] := dCrossWS
    if (dToggles > 0)
        msg["TotalWorkspaceToggles"] := dToggles

    ; Send to store (if connected)
    if (gGUI_StoreConnected && IsObject(gGUI_StoreClient)) {
        try {
            global gGUI_StoreWakeHwnd
            IPC_PipeClient_Send(gGUI_StoreClient, JSON.Dump(msg), gGUI_StoreWakeHwnd)
            ; Record what was sent
            gStats_LastSent["AltTabs"] := gStats_AltTabs
            gStats_LastSent["QuickSwitches"] := gStats_QuickSwitches
            gStats_LastSent["TabSteps"] := gStats_TabSteps
            gStats_LastSent["Cancellations"] := gStats_Cancellations
            gStats_LastSent["CrossWorkspace"] := gStats_CrossWorkspace
            gStats_LastSent["WorkspaceToggles"] := gStats_WorkspaceToggles
        }
        ; On failure, deltas accumulate and are retried next session end
    }
}
