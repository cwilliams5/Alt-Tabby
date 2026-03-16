#Requires AutoHotkey v2.0
; Alt-Tabby GUI - State Machine
; Handles state transitions: IDLE -> ALT_PENDING -> ACTIVE -> IDLE
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals/functions
#Include %A_LineFile%\..\..\shared\error_format.ahk

; State machine: IDLE -> ALT_PENDING -> ACTIVE
; IDLE: Normal state, receiving/applying deltas, cache fresh
; ALT_PENDING: Alt held, optional pre-warm, still receiving deltas
; ACTIVE: List FROZEN on first Tab, ignores all updates, Tab cycles selection
global gGUI_State := "IDLE"

global gGUI_CurrentWSName := ""       ; Cached from gWS_Meta (updated by workspace flip callback)
global gGUI_WSContextSwitch := false  ; True if workspace changed during this overlay session (sel=1 sticky)
global gGUI_ToggleBase := []     ; Snapshot for workspace toggle (Ctrl key support)
global gGUI_DisplayItems := []   ; Items being rendered (may be filtered by workspace mode)

; Timing constants (hardcoded - not user-configurable)
; These are internal implementation details that users shouldn't need to change.
; The main timing values (MRU freshness, WS poll timeout, prewarm wait) are in config.
global GUI_EVENT_BUFFER_MAX := 50           ; Max events to buffer during async

; Event buffering during async activation (queue events, don't cancel)
global ACTIVE_WATCHDOG_MS := 500           ; Must be < Windows LowLevelHooksTimeout (~600ms). Safety net for #303.
global gGUI_EventBuffer := []            ; Queued events during async activation

; Guard flag: true while _GUI_GraceTimerFired is executing.
; Prevents SetTimer(_GUI_GraceTimerFired, 0) from being called during the callback,
; which corrupts AHK v2's internal timer state and permanently breaks future scheduling.
; The one-shot timer auto-deletes after firing, so cancellation is redundant inside.
global gGUI_InGraceCallback := false

; State machine timing
global gGUI_FirstTabTick := 0
global gGUI_TabCount := 0

; Session stats counters (accumulated into lifetime stats)
global gStats_AltTabs := 0
global gStats_QuickSwitches := 0
global gStats_TabSteps := 0
global gStats_Cancellations := 0
; gStats_CrossWorkspace declared in gui_activation.ahk (sole writer)
global gStats_LastSent := Map()  ; Tracks what was last sent for delta calculation


; Force-reset state machine to IDLE and clear display items.
; Used by flight recorder dump to cleanly exit frozen state.
; Does NOT hide overlay — caller controls ordering between reset and hide.
GUI_ForceReset() {
    global gGUI_State, gGUI_DisplayItems
    gGUI_DisplayItems := []
    gGUI_State := "IDLE"
    _GUI_StopActiveWatchdog()  ; #303
}

; ========================= DEBUG LOGGING =========================
; Controlled by cfg.DiagEventLog (config.ini [Diagnostics] EventLog=true)
; Log file: %TEMP%\tabby_events.log

; Buffer log messages and flush via deferred timer so FileAppend I/O
; never runs inside Critical sections (state machine handler, etc.)
global _GST_LogBuf := []
global _GST_LogFlushScheduled := false

GUI_LogEvent(msg) {
    global cfg, _GST_LogBuf, _GST_LogFlushScheduled
    if (!cfg.DiagEventLog)
        return
    _GST_LogBuf.Push(GetLogTimestamp() " " msg)
    if (!_GST_LogFlushScheduled) {
        _GST_LogFlushScheduled := true
        SetTimer(_GST_FlushLogBuffer, -1)
    }
}

_GST_FlushLogBuffer() {
    global _GST_LogBuf, _GST_LogFlushScheduled, LOG_PATH_EVENTS
    _GST_LogFlushScheduled := false
    if (_GST_LogBuf.Length = 0)
        return
    buf := _GST_LogBuf
    _GST_LogBuf := []
    combined := ""
    for _, line in buf
        combined .= line "`n"
    try FileAppend(combined, LOG_PATH_EVENTS, "UTF-8")
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
    return gGUI_EventNames.Get(evCode, "?")
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
    global gGUI_Pending, gGUI_EventBuffer, gAnim_HidePending, gGUI_InGraceCallback
    global FR_EV_STATE, FR_EV_FREEZE, FR_EV_BUFFER_PUSH, FR_EV_QUICK_SWITCH, gFR_Enabled
    global FR_ST_IDLE, FR_ST_ALT_PENDING, FR_ST_ACTIVE

    Profiler.Enter("GUI_OnInterceptorEvent") ; @profile

    ; Flight recorder dump in progress — freeze state machine completely.
    ; The interceptor layer still tracks key state (gINT_AltIsDown etc.),
    ; but the state machine ignores all events until _FR_Dump cleanup runs.
    global gFR_DumpInProgress
    if (gFR_DumpInProgress) {
        Profiler.Leave() ; @profile
        return
    }

    ; File-based debug logging (no performance impact from tooltips)
    diagLog := cfg.DiagEventLog  ; PERF: cache config read
    if (diagLog)
        evName := _GUI_GetEventName(evCode)
    if (diagLog)
        GUI_LogEvent("EVENT " evName " state=" gGUI_State " pending=" gGUI_Pending.phase " items=" gGUI_LiveItems.Length " buf=" gGUI_EventBuffer.Length)

    ; If async activation is in progress, BUFFER events instead of processing
    ; This matches Windows native behavior: let first switch complete, then process next
    ; Exception: ESC cancels immediately
    if (gGUI_Pending.phase != "") {
        if (evCode = TABBY_EV_ESCAPE) {
            if (diagLog)
                GUI_LogEvent("ESC during async - canceling")
            GUI_CancelPendingActivation()
            if (gFR_Enabled)
                FR_Record(FR_EV_STATE, FR_ST_IDLE)
            gGUI_State := "IDLE"
            Profiler.Leave() ; @profile
            return
        }

        ; Overflow protection: check BEFORE push to prevent exceeding max
        ; Normal rapid Alt+Tab produces ~4-6 events max (ALT_DN, TAB, TAB, ALT_UP)
        ; 50 events = ~12 complete Alt+Tab sequences queued = clearly pathological
        ; Drop event and cancel pending activation to recover gracefully
        if (gGUI_EventBuffer.Length >= GUI_EVENT_BUFFER_MAX) {
            if (diagLog)
                GUI_LogEvent("BUFFER OVERFLOW: " gGUI_EventBuffer.Length " events, dropping event and clearing")
            GUI_CancelPendingActivation()
            _GUI_StopActiveWatchdog()  ; #303
            if (gFR_Enabled)
                FR_Record(FR_EV_STATE, FR_ST_IDLE)
            gGUI_State := "IDLE"
            Profiler.Leave() ; @profile
            return
        }

        gGUI_EventBuffer.Push({ev: evCode, flags: flags, lParam: lParam})
        if (gFR_Enabled)
            FR_Record(FR_EV_BUFFER_PUSH, evCode, gGUI_EventBuffer.Length)
        if (diagLog)
            GUI_LogEvent("BUFFERING " evName " (async pending, phase=" gGUI_Pending.phase ")")
        Profiler.Leave() ; @profile
        return
    }

    if (evCode = TABBY_EV_ALT_DOWN) {
        ; NOTE: Do NOT force-complete a pending hide-fade here.  Alt key
        ; repeats fire ALT_DOWN while the user holds Alt after a click-
        ; activate, which would kill the fade before the frame loop can
        ; render a single frame.  Instead, _GUI_ShowOverlayWithFrozen()
        ; force-completes the hide just before re-showing the overlay.

        ; Alt pressed - enter ALT_PENDING state
        if (gFR_Enabled)
            FR_Record(FR_EV_STATE, FR_ST_ALT_PENDING)
        gGUI_State := "ALT_PENDING"
        gGUI_FirstTabTick := 0
        gGUI_TabCount := 0
        global gGUI_WSContextSwitch
        gGUI_WSContextSwitch := false

        ; Pre-warm: refresh display list and icon cache before Tab arrives.
        GUI_RefreshLiveItems()  ; lint-ignore: critical-leak
        Profiler.Leave() ; @profile
        return
    }

    if (evCode = TABBY_EV_TAB_STEP) {
        shiftHeld := (flags & TABBY_FLAG_SHIFT) != 0

        if (gGUI_State = "IDLE") {
            ; Tab without Alt (shouldn't happen normally, interceptor handles this)
            Profiler.Leave() ; @profile
            return
        }

        if (gGUI_State = "ALT_PENDING") {
            ; First Tab - freeze with current data and go to ACTIVE
            gGUI_FirstTabTick := A_TickCount
            gGUI_TabCount := 1
            if (gFR_Enabled)
                FR_Record(FR_EV_STATE, FR_ST_ACTIVE)
            gGUI_State := "ACTIVE"
            global gStats_AltTabs, gStats_TabSteps
            gStats_AltTabs += 1
            gStats_TabSteps += 1


            ; Force-complete any pending hide-fade BEFORE populating display items.
            ; Without this, the frame loop can complete the hide-fade between FREEZE
            ; and the grace timer, calling _Anim_DoActualHide() which wipes
            ; gGUI_DisplayItems — destroying this session's frozen list.
            if (gAnim_HidePending)
                Anim_ForceCompleteHide()

            ; Freeze: save ALL items (for workspace/monitor toggle), then filter
            ; Shallow copy — same item refs, independent array container
            gGUI_ToggleBase := gGUI_LiveItems.Clone()
            GUI_CaptureOverlayMonitor()
            gGUI_DisplayItems := _GUI_FilterDisplayItems(gGUI_ToggleBase)

            ; DEBUG: Log workspace data of display items
            if (diagLog) {
                GUI_LogEvent("FREEZE: " gGUI_DisplayItems.Length " items frozen")
                for i, item in gGUI_DisplayItems {
                    if (i > 5) {
                        GUI_LogEvent("  ... and " (gGUI_DisplayItems.Length - 5) " more")
                        break
                    }
                    ws := GUI_GetItemWSName(item)
                    onCur := GUI_GetItemIsOnCurrent(item)
                    title := item.HasOwnProp("title") ? SubStr(item.title, 1, 25) : "?"
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
            if (gFR_Enabled)
                FR_Record(FR_EV_FREEZE, gGUI_DisplayItems.Length, gGUI_Sel)

            ; Start grace timer - show GUI after delay
            SetTimer(_GUI_GraceTimerFired, -cfg.AltTabGraceMs)
            ; #303: Start watchdog to detect stuck ACTIVE state
            _GUI_StartActiveWatchdog()
            Profiler.Leave() ; @profile
            return
        }

        if (gGUI_State = "ACTIVE") {
            gGUI_TabCount += 1
            gStats_TabSteps += 1
            delta := shiftHeld ? -1 : 1
            _GUI_MoveSelectionFrozen(delta)

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
            ;   3. Stale display list data on quick re-open
            ; The ~16ms delay is acceptable - users won't notice, but they WILL
            ; notice corrupted UI. Keep Critical on through the entire handler.
            ; ============================================================

            ; If GUI not yet visible (still in grace period), show it now on 2nd Tab
            if (!gGUI_OverlayVisible && gGUI_TabCount > 1) {
                if (!gGUI_InGraceCallback)  ; Skip if inside grace callback (one-shot auto-deleted)
                    SetTimer(_GUI_GraceTimerFired, 0)  ; Cancel grace timer
                _GUI_ShowOverlayWithFrozen()  ; lint-ignore: critical-heavy — hotkey handler, Critical required (#303 mitigations: 3 RACE FIX abort points)
            } else if (gGUI_OverlayVisible) {
                ; When animation frame loop is running, it will paint the next frame
                ; with the updated selection (tween already started by MoveSelectionFrozen).
                ; Skip redundant synchronous repaint to avoid double-painting.
                if (cfg.PerfAnimationType = "None")
                    GUI_Repaint()  ; lint-ignore: critical-heavy — hotkey handler, Critical required
            }
        }
        Profiler.Leave() ; @profile
        return
    }

    if (evCode = TABBY_EV_ALT_UP) {
        ; DEBUG: Show ALT_UP arrival (controlled by DiagAltTabTooltips config)
        if (cfg.DiagAltTabTooltips) {
            ToolTip("ALT_UP: state=" gGUI_State " visible=" gGUI_OverlayVisible, 100, 200, 3)
            static _ttClear3 := () => ToolTip(,,,3)  ; PERF: avoid closure alloc per ALT_UP
            SetTimer(_ttClear3, -2000)
        }

        if (gGUI_State = "ALT_PENDING") {
            ; Alt released without Tab - return to IDLE
            if (gFR_Enabled)
                FR_Record(FR_EV_STATE, FR_ST_IDLE)
            gGUI_State := "IDLE"
            Profiler.Leave() ; @profile
            return
        }

        if (gGUI_State = "ACTIVE") {
            if (!gGUI_InGraceCallback)  ; Skip if inside grace callback (one-shot auto-deleted)
                SetTimer(_GUI_GraceTimerFired, 0)  ; Cancel grace timer
            _GUI_StopActiveWatchdog()  ; #303

            timeSinceTab := A_TickCount - gGUI_FirstTabTick

            if (!gGUI_OverlayVisible && timeSinceTab < cfg.AltTabQuickSwitchMs) {
                ; Quick switch: Alt+Tab released quickly, no GUI shown
                if (gFR_Enabled)
                    FR_Record(FR_EV_QUICK_SWITCH, timeSinceTab)
                global gStats_QuickSwitches
                gStats_QuickSwitches += 1
                _GUI_ActivateFromFrozen()
            } else if (gGUI_OverlayVisible) {
                ; Normal case: hide FIRST (feels snappy), then activate
                GUI_HideOverlay()  ; lint-ignore: critical-heavy — hotkey handler, Critical required
                _GUI_ActivateFromFrozen()
            } else {
                ; Edge case: grace period expired but GUI not shown yet
                _GUI_ActivateFromFrozen()
            }

            ; Defer clearing display items during animated hide-fade: the frame
            ; loop still paints the fading overlay using the frozen list.
            ; _Anim_DoActualHide() clears them when the fade completes.
            if (!gAnim_HidePending)
                gGUI_DisplayItems := []
            if (gFR_Enabled)
                FR_Record(FR_EV_STATE, FR_ST_IDLE)
            gGUI_State := "IDLE"
            Stats_AccumulateSession()

            ; #178: Probe for pump connection — retries may have been starved during ACTIVE.
            ; Non-blocking (timeout=0): single CreateFileW, no cooperative threading risk.
            GUIPump_ProbeConnect()

            ; NOTE: Activation is now async (non-blocking) for cross-workspace switches.
            ; Keyboard events are processed normally between timer fires.
        }
        Profiler.Leave() ; @profile
        return
    }

    if (evCode = TABBY_EV_ESCAPE) {
        ; Cancel - hide without activating
        global gStats_Cancellations
        gStats_Cancellations += 1
        GUI_DismissOverlay()
        Profiler.Leave() ; @profile
        return
    }
    Profiler.Leave() ; @profile
}

; ========================= GRACE TIMER =========================

_GUI_GraceTimerFired() {
    Profiler.Enter("_GUI_GraceTimerFired") ; @profile
    ; Hold Critical only for the atomic state check — NOT for the heavy D2D paint.
    ; Previous: Critical covered the entire show+paint sequence. D2D COM calls pump
    ; the STA message loop; if that exceeds Windows' LowLevelHooksTimeout (~300ms),
    ; Windows silently drops ALT_UP from the keyboard hook. (#303)
    ; Now: release Critical before _GUI_ShowOverlayWithFrozen, which has its own
    ; RACE FIX abort points (lines 676, 696, 725) that detect state changes.
    Critical "On"
    global gGUI_State, gGUI_OverlayVisible, gINT_AltIsDown
    global FR_EV_GRACE_FIRE, FR_ST_ACTIVE, gFR_Enabled
    if (gFR_Enabled)
        FR_Record(FR_EV_GRACE_FIRE, (gGUI_State = "ACTIVE" ? FR_ST_ACTIVE : 0), gGUI_OverlayVisible)

    ; Double-check state — may have changed between scheduling and firing
    if (gGUI_State = "ACTIVE" && !gGUI_OverlayVisible) {
        ; Layer 2 (#303): Check physical Alt state before committing to expensive
        ; first paint. If Alt is already physically up but gINT_AltIsDown is still
        ; true, the ALT_UP callback was lost — skip paint and recover immediately.
        ; CRITICAL: Defer recovery to a fresh timer thread. Running the full recovery
        ; chain (INT_RecoverLostAltUp → GUI_OnInterceptorEvent → activation) inside
        ; a one-shot timer callback corrupts AHK v2's timer dispatch for this function,
        ; permanently preventing future SetTimer(_GUI_GraceTimerFired) from working.
        if (gINT_AltIsDown && !INT_IsAltPhysicallyDown()) {
            Critical "Off"
            SetTimer(INT_RecoverLostAltUp.Bind(1), -1)  ; Deferred to fresh thread
            Profiler.Leave() ; @profile
            return
        }
        ; Layer 1 (#303): Release Critical before heavy D2D work so AHK's keyboard
        ; hook handler can return to Windows within LowLevelHooksTimeout, preventing
        ; hook removal. ALT_UP fires as a new AHK thread; race fix checks detect it.
        Critical "Off"
        _GUI_ShowOverlayWithFrozen()
        Profiler.Leave() ; @profile
        return
    }
    Critical "Off"
    Profiler.Leave() ; @profile
}

; ========================= ACTIVE-STATE WATCHDOG (#303) =========================
; Safety net: polls physical Alt key state every 500ms while in ACTIVE state.
; If Alt is physically up but gINT_AltIsDown is stuck true (hook was dropped by
; Windows LowLevelHooksTimeout), synthesizes the missing ALT_UP event.
; Catches ANY cause of stuck ACTIVE state, not just the grace timer path.

_GUI_StartActiveWatchdog() {
    global ACTIVE_WATCHDOG_MS
    SetTimer(_GUI_ActiveWatchdog, ACTIVE_WATCHDOG_MS)
}

_GUI_StopActiveWatchdog() {
    SetTimer(_GUI_ActiveWatchdog, 0)
}

_GUI_ActiveWatchdog() {
    Critical "On"
    global gGUI_State, gINT_AltIsDown
    if (gGUI_State != "ACTIVE") {
        _GUI_StopActiveWatchdog()
        Critical "Off"
        return
    }
    if (gINT_AltIsDown && !INT_IsAltPhysicallyDown()) {
        _GUI_StopActiveWatchdog()
        Critical "Off"
        INT_RecoverLostAltUp(4)  ; layer=4 (watchdog)
        return
    }
    Critical "Off"
}

; ========================= WORKSPACE FLIP CALLBACK =========================

; Called by KomorebiSub (via gWS_OnWorkspaceChanged) when workspace changes.
GUI_OnWorkspaceFlips() {
    Profiler.Enter("GUI_OnWorkspaceFlips") ; @profile
    global gGUI_CurrentWSName, gWS_Meta, cfg

    ; Error boundary: same rationale as _GUI_OnProducerRevChanged in gui_main.
    try {
        ; Read workspace name directly from gWS_Meta (in-process, no IPC)
        wsName := ""
        if (IsObject(gWS_Meta)) {
            Critical "On"
            wsName := gWS_Meta.Get("currentWSName", "")

            if (wsName != "" && wsName != gGUI_CurrentWSName) {
                gGUI_CurrentWSName := wsName
                GUI_UpdateFooterText()
                _GUI_HandleWorkspaceSwitch()
            }
            Critical "Off"
        }
    } catch as e {
        Critical "Off"  ; Ensure Critical is released on error (AHK v2 auto-releases on return, but be explicit)
        global LOG_PATH_STORE
        try LogAppend(LOG_PATH_STORE, "workspace_flip_callback err=" e.Message " file=" e.File " line=" e.Line)
    }
    Profiler.Leave() ; @profile
}

; ========================= OVERLAY DISMISS =========================

; Dismiss overlay and return to IDLE — shared by ESC, empty-list eviction, etc.
; Hides overlay, restores focus if StealFocus, clears display items, flushes stats.
; Caller may hold Critical (RefreshLiveItems manages its own).
GUI_DismissOverlay() {
    global gGUI_State, gGUI_OverlayVisible, gGUI_DisplayItems
    global gGUI_StealFocus, gGUI_FocusBeforeShow
    global gFR_Enabled, FR_EV_STATE, FR_ST_IDLE

    SetTimer(_GUI_GraceTimerFired, 0)  ; Cancel grace timer
    _GUI_StopActiveWatchdog()  ; #303
    if (gGUI_OverlayVisible) {
        GUI_HideOverlay()
        if (gGUI_StealFocus && gGUI_FocusBeforeShow) {
            GUI_RobustActivate(gGUI_FocusBeforeShow)
            gGUI_FocusBeforeShow := 0
        }
    }
    if (gFR_Enabled)
        FR_Record(FR_EV_STATE, FR_ST_IDLE)
    gGUI_State := "IDLE"
    gGUI_DisplayItems := []
    Stats_AccumulateSession()
    GUIPump_ProbeConnect()
    GUI_RefreshLiveItems()  ; lint-ignore: critical-leak
}

; ========================= FROZEN STATE HELPERS =========================

; Handle workspace context switch during ACTIVE state.
; Resets selection to top, marks sticky context switch, and requests fresh
; display list when frozen. Caller must hold Critical "On".
_GUI_HandleWorkspaceSwitch() {
    Profiler.Enter("_GUI_HandleWorkspaceSwitch") ; @profile
    global gGUI_State, gGUI_Sel, gGUI_ScrollTop, gGUI_WSContextSwitch
    global gGUI_CurrentWSName, gGUI_ToggleBase, gGUI_DisplayItems, gGUI_OverlayVisible
    global cfg, gGUI_WorkspaceMode, WS_MODE_CURRENT
    if (gGUI_State != "ACTIVE") {
        Profiler.Leave() ; @profile
        return
    }
    gGUI_WSContextSwitch := true
    ; Clear stale hover — row indices from the old layout are meaningless after
    ; refilter changes the item list (hover icons would flash at wrong row).
    GUI_ClearHoverState()

    ; #178: Frozen items ARE store record refs — workspace data is already correct.
    ; WL_SetCurrentWorkspace flipped isOnCurrentWorkspace on the actual records.
    ; For MOVE events: ProcessFullState + post-fix already updated workspace fields.
    ; Just re-filter to show the right windows.

    ; Re-filter display items and select foreground window
    _GUI_RefilterForWorkspaceChange()

    ; Repaint if overlay is visible.  GUI_Repaint handles resize internally
    ; with deferred SetWindowPos (right before ULW) so DWM can't present a
    ; frame with the resized acrylic base but stale overlay content.
    if (gGUI_OverlayVisible) {
        GUI_Repaint()
        GUI_RefreshBackdrop()  ; Force DWM to re-sample acrylic for new workspace (#235)
    }
    Profiler.Leave() ; @profile
}

; Combined workspace + monitor filter in a single pass.
; Returns items unchanged when both filters are ALL (fast path, no allocation).
; When filtering is active, avoids the intermediate throwaway array that two
; sequential filter calls would create.
_GUI_FilterDisplayItems(items) {
    Profiler.Enter("_GUI_FilterDisplayItems") ; @profile
    global gGUI_WorkspaceMode, WS_MODE_ALL
    global gGUI_MonitorMode, MON_MODE_ALL, gGUI_OverlayMonitorHandle

    wsAll := (gGUI_WorkspaceMode = WS_MODE_ALL)
    monAll := (gGUI_MonitorMode = MON_MODE_ALL) || !gGUI_OverlayMonitorHandle
    if (wsAll && monAll) {
        Profiler.Leave() ; @profile
        return items
    }
    result := []
    result.Capacity := items.Length
    for _, item in items {
        if (!wsAll && !(item.HasOwnProp("isOnCurrentWorkspace") ? item.isOnCurrentWorkspace : true))
            continue
        if (!monAll && item.monitorHandle != gGUI_OverlayMonitorHandle)
            continue
        result.Push(item)
    }
    Profiler.Leave() ; @profile
    return result
}

; Re-filter display items for a workspace change (window moved or workspace switched).
; Resets scroll/selection and tries to select the foreground window, since a workspace
; change is a context switch — the moved/focused window is what the user wants.
_GUI_RefilterForWorkspaceChange() {
    global gGUI_DisplayItems, gGUI_Sel, gGUI_ScrollTop, gGUI_ToggleBase
    Profiler.Enter("_GUI_RefilterForWorkspaceChange") ; @profile
    gGUI_DisplayItems := _GUI_FilterDisplayItems(gGUI_ToggleBase)
    gGUI_ScrollTop := 0
    gGUI_Sel := 1
    fgHwnd := DllCall("GetForegroundWindow", "Ptr")
    if (fgHwnd) {
        for idx, item in gGUI_DisplayItems {
            if (item.hwnd = fgHwnd) {
                gGUI_Sel := idx
                break
            }
        }
    }
    GUI_ClampSelection(gGUI_DisplayItems)
    Profiler.Leave() ; @profile
}

; Re-filter display items after workspace mode toggle.
; Unlike _GUI_RefilterForWorkspaceChange (which selects foreground window),
; this preserves MRU-based selection since the user is browsing, not switching.
GUI_ApplyWorkspaceFilter() {
    _GUI_ApplyFilter("GUI_ApplyWorkspaceFilter")
}

; Re-filter display items after monitor mode toggle.
; Same pattern as ApplyWorkspaceFilter — preserves MRU selection.
GUI_ApplyMonitorFilter() {
    _GUI_ApplyFilter("GUI_ApplyMonitorFilter")
}

; Shared filter-and-repaint logic for workspace/monitor toggles.
; RACE FIX: Keep Critical through repaint — a hotkey can interrupt between filter and
; repaint, reassigning gGUI_DisplayItems via GUI_OnInterceptorEvent. Follows the
; keyboard-hooks rule: "keep Critical during render" (corrupted GUI > keyboard lag).
_GUI_ApplyFilter(label) {
    Profiler.Enter(label) ; @profile
    global gGUI_DisplayItems, gGUI_ToggleBase
    Critical "On"
    gGUI_DisplayItems := _GUI_FilterDisplayItems(gGUI_ToggleBase)
    _GUI_ResetSelectionToMRU()
    GUI_ClearHoverState()  ; Row indices are stale after refilter
    ; Let GUI_Repaint handle resize atomically — it paints at the new dimensions
    ; first, then SetClip + SetWindowPos + Commit in one DComp batch. Calling
    ; GUI_ResizeToRows separately causes a stale frame (old content at new size).
    GUI_Repaint()  ; lint-ignore: critical-heavy — filter apply, Critical needed for atomic resize+paint
    Critical "Off"
    Profiler.Leave() ; @profile
}

; Reset selection to MRU position (1 or 2) and clamp to list bounds.
; After a workspace switch, sel=1 (focused window on NEW workspace is what you want).
; Otherwise, sel=2 (the "previous" window — standard Alt-Tab behavior).
; Parameters:
;   listRef - Optional reference to the list to use (default: gGUI_DisplayItems)
; Returns: The new selection index
_GUI_ResetSelectionToMRU(listRef := "") {
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
; Called when state changes to non-ACTIVE during _GUI_ShowOverlayWithFrozen.
_GUI_AbortShowSequence() {
    global gGUI_Overlay, gGUI_Base, gGUI_OverlayVisible, gGUI_Revealed
    try gGUI_Overlay.Hide()
    try gGUI_Base.Hide()
    gGUI_OverlayVisible := false
    gGUI_Revealed := false
}

_GUI_ShowOverlayWithFrozen() {
    Profiler.Enter("_GUI_ShowOverlayWithFrozen") ; @profile
    global gGUI_OverlayVisible, gGUI_Base, gGUI_BaseH, gGUI_Overlay, gGUI_OverlayH
    global gGUI_LiveItems, gGUI_DisplayItems, gGUI_Sel, gGUI_ScrollTop, gGUI_Revealed, cfg
    global gGUI_State, gGUI_StealFocus, gGUI_FocusBeforeShow
    global gPaint_LastPaintTick, gPaint_SessionPaintCount
    global gINT_AltIsDown  ; #303: Layer 3 physical Alt checks at STA pump points

    ; If a hide-fade is still running from a previous click-activate,
    ; complete it now so gGUI_OverlayVisible becomes false and we can
    ; proceed with the new show sequence.
    global gAnim_HidePending
    if (gAnim_HidePending)
        Anim_ForceCompleteHide()

    if (gGUI_OverlayVisible) {
        Profiler.Leave() ; @profile
        return
    }

    ; ===== TIMING: Show sequence start =====
    tShow_Start := QPC()
    idleDuration := (gPaint_LastPaintTick > 0) ? (A_TickCount - gPaint_LastPaintTick) : -1
    if (cfg.DiagPaintTimingLog)
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

    ; Prepare show-fade animation: set alpha=0 so window is invisible until
    ; the tween drives it up.  DO NOT start the tween timer yet — SetWindowPos
    ; and ShowWindow below pump the STA message loop, which would dispatch the
    ; animation timer and trigger a GUI_Repaint before the D2D render target is
    ; resized.  That nested paint either renders at the old RT size (stretched)
    ; or blocks on shader compilation and holds the reentrancy guard (blank).
    ; The tween starts after resize + show + reveal, right before the first paint.
    Anim_PrepareShowFade(cfg.PerfAnimationType != "None")

    ; ===== TIMING: Resize =====
    t1 := QPC()
    rowsDesired := GUI_ComputeRowsToShow(gGUI_DisplayItems.Length)
    GUI_ResizeToRows(rowsDesired, true)  ; skipFlush — we flush after paint
    global gGUI_LastRowsDesired
    gGUI_LastRowsDesired := rowsDesired  ; Sync so first paint skips unnecessary pre-render
    tShow_Resize := QPC() - t1

    ; ===== Show window BEFORE painting =====
    ; With SwapChain + DComp, Present() works for hidden windows (commits to the
    ; swap chain buffer). We still Show first so the DComp visual tree is active
    ; when the first frame is presented.  The D2D surface was cleared on hide,
    ; so the first visible frame is just the acrylic backdrop (no stale content).
    ; Window is NOT WS_EX_LAYERED, so DWM recomputes acrylic blur fresh on Show.

    ; RACE FIX: abort if state changed during resize (pumps messages)
    if (gGUI_State != "ACTIVE") {
        if (cfg.DiagPaintTimingLog)
            Paint_Log("ShowOverlay ABORT before Show (state=" gGUI_State ")")
        _GUI_AbortShowSequence()
        Profiler.Leave() ; @profile
        return
    }
    ; Layer 3 (#303): detect lost ALT_UP via physical key state after resize
    if (gINT_AltIsDown && !INT_IsAltPhysicallyDown()) {
        if (cfg.DiagPaintTimingLog)
            Paint_Log("ShowOverlay ABORT: Alt physically up (post-resize)")
        _GUI_AbortShowSequence()
        SetTimer(INT_RecoverLostAltUp.Bind(3), -1)  ; Deferred — see Layer 2 comment
        Profiler.Leave() ; @profile
        return
    }

    try {
        if (gGUI_StealFocus) {
            gGUI_FocusBeforeShow := DllCall("user32\GetForegroundWindow", "ptr")
            ; Raw ShowWindow bypasses AHK's caption-aware size adjustment (WS_CAPTION grows the window)
            DllCall("user32\ShowWindow", "ptr", gGUI_BaseH, "int", 5)  ; SW_SHOW
            DllCall("user32\SetForegroundWindow", "ptr", gGUI_BaseH)
        } else {
            gGUI_Base.Show("NA")
        }
    }

    ; RACE FIX: Show pumps messages — check if Alt was released
    if (gGUI_State != "ACTIVE") {
        try gGUI_Base.Hide()
        if (cfg.DiagPaintTimingLog)
            Paint_Log("ShowOverlay ABORT after Show (state=" gGUI_State ")")
        _GUI_AbortShowSequence()
        Profiler.Leave() ; @profile
        return
    }
    ; Layer 3 (#303): detect lost ALT_UP via physical key state after Show
    if (gINT_AltIsDown && !INT_IsAltPhysicallyDown()) {
        try gGUI_Base.Hide()
        if (cfg.DiagPaintTimingLog)
            Paint_Log("ShowOverlay ABORT: Alt physically up (post-Show)")
        _GUI_AbortShowSequence()
        SetTimer(INT_RecoverLostAltUp.Bind(3), -1)  ; Deferred — see Layer 2 comment
        Profiler.Leave() ; @profile
        return
    }

    gGUI_Revealed := true

    ; Paint FIRST while window is invisible (alpha=0).
    ; The first paint can take 1-2s on fresh launch (lazy D2D resource creation,
    ; GPU effect compilation).  If the animation tween started before this paint,
    ; the frame loop would drive alpha > 0 during STA pumps inside PaintOverlay,
    ; showing the acrylic backdrop with no D2D content (blank overlay).
    ; By painting before starting the tween, the window stays invisible until
    ; content is rendered.
    ; ===== TIMING: Paint on visible window (Present works) =====
    t1 := QPC()
    GUI_Repaint()
    tShow_Repaint := QPC() - t1

    ; NOW start the show-fade tween — first paint is done, content is rendered.
    ; Animation timer can safely call GUI_Repaint from here on.
    if (cfg.PerfAnimationType != "None")
        Anim_StartTween("showFade", 0.0, 1.0, 90, Anim_EaseOutQuad)

    ; RACE FIX: If Alt was released during paint, hide and abort.
    if (gGUI_State != "ACTIVE") {
        try gGUI_Base.Hide()
        if (cfg.DiagPaintTimingLog)
            Paint_Log("ShowOverlay ABORT after Repaint (state=" gGUI_State ")")
        _GUI_AbortShowSequence()
        Profiler.Leave() ; @profile
        return
    }
    ; Layer 3 (#303): detect lost ALT_UP via physical key state after Repaint
    if (gINT_AltIsDown && !INT_IsAltPhysicallyDown()) {
        try gGUI_Base.Hide()
        if (cfg.DiagPaintTimingLog)
            Paint_Log("ShowOverlay ABORT: Alt physically up (post-Repaint)")
        _GUI_AbortShowSequence()
        SetTimer(INT_RecoverLostAltUp.Bind(3), -1)  ; Deferred — see Layer 2 comment
        Profiler.Leave() ; @profile
        return
    }

    ; PERF: DwmFlush removed — Present(0,0) already submitted the frame to the swap chain,
    ; and Anim_StartTween handles the fade-in. DwmFlush was adding 0-16ms vsync wait.

    ; Start hover polling (fallback for WM_MOUSELEAVE)
    GUI_StartHoverPolling()

    ; ===== TIMING: Log show sequence =====
    tShow_Total := QPC() - tShow_Start
    if (cfg.DiagPaintTimingLog)
        Paint_Log("ShowOverlay END: total=" Round(tShow_Total, 2) "ms | resize=" Round(tShow_Resize, 2) " repaint=" Round(tShow_Repaint, 2))
    Profiler.Leave() ; @profile
}

_GUI_MoveSelectionFrozen(delta) {
    Profiler.Enter("_GUI_MoveSelectionFrozen") ; @profile
    global gGUI_Sel, gGUI_DisplayItems, gGUI_ScrollTop, cfg
    global gFX_GPUReady

    if (gGUI_DisplayItems.Length = 0) {
        Profiler.Leave() ; @profile
        return
    }

    count := gGUI_DisplayItems.Length
    prevSel := gGUI_Sel  ; Capture BEFORE changing selection (for animation)

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

    ; Start selection slide animation (if enabled)
    if (cfg.PerfAnimationType != "None" || FX_HasActiveShaders()) {
        Anim_StartSelectionSlide(prevSel, gGUI_Sel, count)
        ; Start selection entrance tween for shader-based selection effects
        global gFX_SelectionEffect
        if (gFX_SelectionEffect.key != "")
            Anim_StartTween("fx_sel_entrance", 0.0, 1.0, 200, Anim_EaseOutCubic)
    }
    Profiler.Leave() ; @profile
}

_GUI_ActivateFromFrozen() {
    Profiler.Enter("_GUI_ActivateFromFrozen") ; @profile
    global gGUI_Sel, gGUI_DisplayItems, cfg
    global FR_EV_ACTIVATE_GONE, FR_EV_ACTIVATE_RETRY, gFR_Enabled

    diagLog := cfg.DiagEventLog  ; PERF: cache config read

    if (diagLog)
        GUI_LogEvent("ACTIVATE FROM FROZEN: sel=" gGUI_Sel " frozen=" gGUI_DisplayItems.Length)

    if (gGUI_Sel < 1 || gGUI_Sel > gGUI_DisplayItems.Length) {
        if (diagLog)
            GUI_LogEvent("ACTIVATE FAILED: sel out of range!")
        Profiler.Leave() ; @profile
        return
    }

    ; --- No retry: original behavior ---
    if (!cfg.AltTabActivationRetry) {
        item := gGUI_DisplayItems[gGUI_Sel]
        hwnd := item.hwnd
        if (!DllCall("user32\IsWindow", "ptr", hwnd, "int")) {
            if (gFR_Enabled)
                FR_Record(FR_EV_ACTIVATE_GONE, hwnd)
            if (diagLog)
                GUI_LogEvent("ACTIVATE SKIP: window gone hwnd=" hwnd " title=" (item.HasOwnProp("title") ? SubStr(item.title, 1, 30) : "?"))
            Profiler.Leave() ; @profile
            return
        }
        if (diagLog) {
            title := item.HasOwnProp("title") ? SubStr(item.title, 1, 30) : "?"
            GUI_LogEvent("ACTIVATE: '" title "' ws=" GUI_GetItemWSName(item) " onCurrent=" GUI_GetItemIsOnCurrent(item))
        }
        GUI_ActivateItem(item)
        Profiler.Leave() ; @profile
        return
    }

    ; --- Retry loop: walk display list for a live window ---
    startSel := gGUI_Sel
    listLen := gGUI_DisplayItems.Length
    maxAttempts := (cfg.AltTabActivationRetryDepth > 0)
        ? Min(cfg.AltTabActivationRetryDepth, listLen)
        : listLen
    originalHwnd := gGUI_DisplayItems[gGUI_Sel].hwnd

    loop maxAttempts {
        item := gGUI_DisplayItems[gGUI_Sel]
        hwnd := item.hwnd

        if (!DllCall("user32\IsWindow", "ptr", hwnd, "int")) {
            ; Window gone — record and try next
            if (gFR_Enabled)
                FR_Record(FR_EV_ACTIVATE_GONE, hwnd)
            if (diagLog)
                GUI_LogEvent("ACTIVATE RETRY: window gone hwnd=" hwnd " title=" (item.HasOwnProp("title") ? SubStr(item.title, 1, 30) : "?"))

            nextSel := _GUI_NextValidSel(gGUI_Sel, listLen, startSel)
            if (nextSel = 0) {
                if (diagLog)
                    GUI_LogEvent("ACTIVATE RETRY: exhausted all windows")
                Profiler.Leave() ; @profile
                return
            }
            gGUI_Sel := nextSel
            continue
        }

        ; Live window found
        if (diagLog) {
            title := item.HasOwnProp("title") ? SubStr(item.title, 1, 30) : "?"
            isRetry := (gGUI_Sel != startSel) ? " (retry)" : ""
            GUI_LogEvent("ACTIVATE: '" title "' ws=" GUI_GetItemWSName(item) " onCurrent=" GUI_GetItemIsOnCurrent(item) isRetry)
        }

        success := GUI_ActivateItem(item)

        ; Post-activation check: if activation failed AND window is now dead, retry next
        if (!success && !DllCall("user32\IsWindow", "ptr", hwnd, "int")) {
            if (diagLog)
                GUI_LogEvent("ACTIVATE RETRY: window died during activation hwnd=" hwnd)
            nextSel := _GUI_NextValidSel(gGUI_Sel, listLen, startSel)
            if (nextSel = 0) {
                Profiler.Leave() ; @profile
                return
            }
            gGUI_Sel := nextSel
            continue
        }

        ; Record retry event if we moved past the original selection
        if (gGUI_Sel != startSel) {
            if (gFR_Enabled)
                FR_Record(FR_EV_ACTIVATE_RETRY, originalHwnd, hwnd, success ? 1 : 0)
        }
        Profiler.Leave() ; @profile
        return
    }

    if (diagLog)
        GUI_LogEvent("ACTIVATE RETRY: reached max depth " maxAttempts)
    Profiler.Leave() ; @profile
}

; Advance sel to next index, wrapping around, skipping startSel.
; Returns 0 if wrapped back to startSel (no candidates).
_GUI_NextValidSel(currentSel, listLen, startSel) {
    nextSel := (currentSel >= listLen) ? 1 : currentSel + 1
    return (nextSel = startSel) ? 0 : nextSel
}

; ========================= STATS ACCUMULATION =========================

; Accumulate session stats into lifetime counters
; Called at session end (IDLE transition) and on exit
Stats_AccumulateSession() {
    global gStats_AltTabs, gStats_QuickSwitches, gStats_TabSteps
    global gStats_Cancellations, gStats_CrossWorkspace, gStats_WorkspaceToggles
    global gStats_MonitorToggles
    global gStats_LastSent

    ; Calculate deltas since last send
    dAltTabs := gStats_AltTabs - gStats_LastSent.Get("AltTabs", 0)
    dQuick := gStats_QuickSwitches - gStats_LastSent.Get("QuickSwitches", 0)
    dTabs := gStats_TabSteps - gStats_LastSent.Get("TabSteps", 0)
    dCancels := gStats_Cancellations - gStats_LastSent.Get("Cancellations", 0)
    dCrossWS := gStats_CrossWorkspace - gStats_LastSent.Get("CrossWorkspace", 0)
    dToggles := gStats_WorkspaceToggles - gStats_LastSent.Get("WorkspaceToggles", 0)
    dMonToggles := gStats_MonitorToggles - gStats_LastSent.Get("MonitorToggles", 0)

    ; Skip if nothing to send
    if (dAltTabs = 0 && dQuick = 0 && dTabs = 0 && dCancels = 0 && dCrossWS = 0 && dToggles = 0 && dMonToggles = 0)
        return

    ; Accumulate directly into lifetime stats (in-process, no IPC)
    msg := Map()
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
    if (dMonToggles > 0)
        msg["TotalMonitorToggles"] := dMonToggles

    Stats_Accumulate(msg)

    ; Record what was sent
    gStats_LastSent["AltTabs"] := gStats_AltTabs
    gStats_LastSent["QuickSwitches"] := gStats_QuickSwitches
    gStats_LastSent["TabSteps"] := gStats_TabSteps
    gStats_LastSent["Cancellations"] := gStats_Cancellations
    gStats_LastSent["CrossWorkspace"] := gStats_CrossWorkspace
    gStats_LastSent["WorkspaceToggles"] := gStats_WorkspaceToggles
    gStats_LastSent["MonitorToggles"] := gStats_MonitorToggles
}
