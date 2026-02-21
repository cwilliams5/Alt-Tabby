#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Expected: file is included after window_list.ahk

; ============================================================
; WinEvent Hook - Event-driven window change detection
; ============================================================
; Alternative to winenum polling. Uses SetWinEventHook to receive
; notifications when windows change. More efficient than polling
; when system is mostly idle.
;
; Events tracked:
;   - Window create/destroy
;   - Window show/hide
;   - Foreground change
;   - Title change
;   - Minimize/restore
;   - Z-order change (via location change)
; ============================================================

; Configuration (set in WinEventHook_Start after ConfigLoader_Init)
global WinEventHook_DebounceMs := 0
global WinEventHook_BatchMs := 0

; State
global _WEH_Hooks := []                   ; Array of hook handles (split into narrow ranges)
global _WEH_CallbackObj := 0              ; Callback object - MUST be global to prevent GC
global _WEH_PendingHwnds := Map()         ; hwnd -> tick of last event
global _WEH_TimerOn := false
global _WEH_ShellWindow := 0
global _WEH_IdleTicks := 0                ; Counter for consecutive empty ticks
global _WEH_IdleThreshold := 10           ; Default, overridden from config in WinEventHook_Start()

; MRU tracking (replaces MRU_Lite when hook is active)
global gWEH_LastFocusHwnd := 0
global _WEH_PendingFocusHwnd := 0         ; Set by callback, processed by batch

; Z-order tracking: only events that change Z-order should trigger full winenum scan
; NAMECHANGE and LOCATIONCHANGE fire frequently but don't affect Z — skip them
global _WEH_PendingZNeeded := Map()       ; hwnd -> true if Z-affecting event received
global _WEH_MruFallbackActive := false   ; True when MRU_Lite is running as WEH backoff fallback

; Fast-path one-shot wrapper: calls ProcessBatch without killing the periodic timer.
; AHK v2 identifies timers by callback function — SetTimer(func, -1) replaces any
; existing timer for that function. Using _WEH_ProcessBatch directly for one-shots
; kills the periodic timer (SetTimer(_WEH_ProcessBatch, BatchMs)), leaving pending
; hwnds stranded until the next event. This wrapper has its own timer slot.
_WEH_FastPathBatch() {
    _WEH_ProcessBatch()
}

; Debug logging for focus events - controlled by DiagWinEventLog config flag
_WEH_DiagLog(msg) {
    global cfg, LOG_PATH_WINEVENT
    if (!cfg.DiagWinEventLog)
        return
    LogAppend(LOG_PATH_WINEVENT, msg)
}


; Initialize and install the hook
WinEventHook_Start() {
    global _WEH_Hooks, _WEH_ShellWindow, _WEH_TimerOn, cfg
    global WinEventHook_DebounceMs, WinEventHook_BatchMs
    global _WEH_CallbackObj

    ; Fail fast if config not initialized (catches initialization order bugs)
    CL_AssertInitialized("WinEventHook_Start")

    ; Load config values on first start (ConfigLoader_Init has already run)
    if (WinEventHook_DebounceMs = 0) {
        global _WEH_IdleThreshold
        WinEventHook_DebounceMs := cfg.WinEventHookDebounceMs
        WinEventHook_BatchMs := cfg.WinEventHookBatchMs
        _WEH_IdleThreshold := cfg.WinEventHookIdleThreshold
    }

    ; Reset log for new session (before early-exit guard)
    if (cfg.DiagWinEventLog) {
        global LOG_PATH_WINEVENT
        LogInitSession(LOG_PATH_WINEVENT, "Alt-Tabby WinEvent Log")
    }

    if (_WEH_Hooks.Length > 0)
        return true  ; Already running

    _WEH_ShellWindow := DllCall("user32\GetShellWindow", "ptr")

    ; Create the callback - store globally to prevent GC (CRITICAL!)
    ; If stored in a local variable, the callback can be garbage collected while
    ; the hook is still active, causing crashes or silent failures.
    _WEH_CallbackObj := CallbackCreate(_WEH_WinEventProc, "F", 7)

    ; PERF: Split into 3 narrow hooks instead of one wide range (0x0003-0x800C).
    ; A single wide range dispatches thousands of irrelevant events per second
    ; (menus, dialogs, scroll, drag-drop, selections) that we immediately filter
    ; in the callback. Narrow ranges let Windows skip those events entirely —
    ; they never reach our callback at all.
    ;
    ; We need 10 event types across 3 clusters:
    ;   System:  FOREGROUND (0x0003)
    ;   System:  MINIMIZESTART (0x0016), MINIMIZEEND (0x0017)
    ;   Object:  CREATE-HIDE (0x8000-0x8003), FOCUS (0x8005),
    ;            LOCATIONCHANGE (0x800B), NAMECHANGE (0x800C)
    ;
    ; Gaps eliminated from dispatch:
    ;   0x0004-0x0015: menu, capture, movesize, dialog, scrolling, switch events
    ;   0x0018-0x7FFF: other system events
    ;   0x8004, 0x8006-0x800A: reorder, selection, state change
    ;     (these still reach hook 3 but are filtered by the cheap idObject != 0 check)
    hookRanges := [
        [0x0003, 0x0003],   ; EVENT_SYSTEM_FOREGROUND
        [0x0016, 0x0017],   ; EVENT_SYSTEM_MINIMIZESTART/END
        [0x8000, 0x800C]    ; Object events (CREATE through NAMECHANGE)
    ]

    for _, range in hookRanges {
        h := DllCall("user32\SetWinEventHook",
            "uint", range[1],       ; eventMin
            "uint", range[2],       ; eventMax
            "ptr", 0,               ; hmodWinEventProc (0 for out-of-context)
            "ptr", _WEH_CallbackObj, ; pfnWinEventProc
            "uint", 0,              ; idProcess (0 = all)
            "uint", 0,              ; idThread (0 = all)
            "uint", 0,              ; dwFlags (WINEVENT_OUTOFCONTEXT)
            "ptr")
        if (!h) {
            ; Cleanup on partial failure
            for _, existing in _WEH_Hooks
                DllCall("user32\UnhookWinEvent", "ptr", existing)
            _WEH_Hooks := []
            CallbackFree(_WEH_CallbackObj)
            _WEH_CallbackObj := 0
            return false
        }
        _WEH_Hooks.Push(h)
    }

    ; Start the batch processing timer
    _WEH_TimerOn := true
    SetTimer(_WEH_ProcessBatch, WinEventHook_BatchMs)

    return true
}

; Ensure the batch processing timer is running (wake from idle pause)
; Called by the callback when new events are queued
_WinEventHook_EnsureTimerRunning() {
    global _WEH_TimerOn, _WEH_IdleTicks, WinEventHook_BatchMs
    Pump_EnsureRunning(&_WEH_TimerOn, &_WEH_IdleTicks, WinEventHook_BatchMs, _WEH_ProcessBatch)
}

; Stop and uninstall the hook
WinEventHook_Stop() {
    global _WEH_Hooks, _WEH_TimerOn, _WEH_CallbackObj

    if (_WEH_TimerOn) {
        SetTimer(_WEH_ProcessBatch, 0)
        _WEH_TimerOn := false
    }

    for _, h in _WEH_Hooks
        DllCall("user32\UnhookWinEvent", "ptr", h)
    _WEH_Hooks := []

    ; Free the callback object to prevent memory leak
    if (_WEH_CallbackObj) {
        CallbackFree(_WEH_CallbackObj)
        _WEH_CallbackObj := 0
    }
}

; Query whether the WinEvent hook is currently installed and running
WinEventHook_IsRunning() {
    global _WEH_Hooks
    return _WEH_Hooks.Length > 0
}

; Hook callback - called for each window event
; Keep this FAST - just queue the hwnd for later processing
; PERF: Event constants inlined in hot-path callback — by design.
; This callback fires hundreds of times per second; each `global` declaration
; costs a name lookup on every invocation (AHK v2 does NOT cache global
; references across calls). Inlining eliminates 10 global lookups per callback.
;
; Event constant map:
;   0x0003 = EVENT_SYSTEM_FOREGROUND
;   0x0016 = EVENT_SYSTEM_MINIMIZESTART
;   0x0017 = EVENT_SYSTEM_MINIMIZEEND
;   0x8000 = EVENT_OBJECT_CREATE
;   0x8001 = EVENT_OBJECT_DESTROY
;   0x8002 = EVENT_OBJECT_SHOW
;   0x8003 = EVENT_OBJECT_HIDE
;   0x8005 = EVENT_OBJECT_FOCUS
;   0x800B = EVENT_OBJECT_LOCATIONCHANGE
;   0x800C = EVENT_OBJECT_NAMECHANGE
_WEH_WinEventProc(hWinEventHook, event, hwnd, idObject, idChild, idEventThread, dwmsEventTime) { ; lint-ignore: dead-param
    global _WEH_PendingHwnds, _WEH_ShellWindow, _WEH_PendingFocusHwnd, _WEH_PendingZNeeded
    global cfg, gWS_Store

    try {  ; Error boundary: DllCall callback — unhandled throw = undefined Win32 behavior
    ; Only care about window-level events (idObject = OBJID_WINDOW = 0)
    if (idObject != 0)
        return

    ; Skip shell window
    if (hwnd = _WEH_ShellWindow)
        return

    ; Filter to relevant events (see constant map above)
    if (event != 0x8000 && event != 0x8001 && event != 0x8002 && event != 0x8003
        && event != 0x0003 && event != 0x800C && event != 0x0016 && event != 0x0017
        && event != 0x8005 && event != 0x800B)
        return

    ; RACE FIX: Protect Map writes from batch processor interruption
    ; The batch processor iterates _WEH_PendingHwnds - we must not modify it concurrently
    Critical "On"

    ; For destroy events, mark for removal
    if (event = 0x8001) {
        _WEH_PendingHwnds[hwnd] := -1  ; -1 = destroyed
        Critical "Off"
        SetTimer(_WEH_FastPathBatch, -1)
        _WinEventHook_EnsureTimerRunning()
        return
    }

    ; For hide events, mark for eligibility check (window may have become a ghost).
    ; Apps like Outlook reuse HWNDs — closing an email hides the HWND instead of
    ; destroying it. Without this, hidden windows linger in the store for up to 5s
    ; (until ValidateExistence catches them).
    if (event = 0x8003) {
        _WEH_PendingHwnds[hwnd] := -2  ; -2 = hidden, check eligibility in batch
        Critical "Off"
        SetTimer(_WEH_FastPathBatch, -1)
        _WinEventHook_EnsureTimerRunning()
        return
    }

    ; Filter cosmetic events for non-store windows.
    ; NAMECHANGE alone can't make a window eligible (CREATE/SHOW handles new windows).
    ; LOCATIONCHANGE doesn't affect any stored field (no position tracking).
    if (event = 0x800C || event = 0x800B) {
        if (!gWS_Store.Has(hwnd + 0)) {
            Critical "Off"
            return
        }
    }

    ; For focus/foreground events, capture for MRU update (processed in batch)
    if (event = 0x0003 || event = 0x8005) {
        ; LATENCY FIX: Don't call WinGetTitle here - it sends WM_GETTEXT which can
        ; block 10-50ms on slow windows. Let the batch processor handle title checks.
        ;
        ; Windows NOT in store: Batch processor's WinUtils_ProbeWindow will check
        ; eligibility (including empty title) before adding. System UI gets filtered there.
        ;
        ; Windows IN store: Allow focus update regardless of title - they passed
        ; eligibility when first added. Apps like Outlook may have empty title momentarily.
        ;
        ; The O(1) Map lookup is fast vs 10-50ms for WinGetTitle.
        if (cfg.DiagWinEventLog) {
            inStore := false
            try inStore := WL_GetByHwnd(hwnd) != 0
            if (!inStore) {
                ; Not in store yet - batch processor will check eligibility via WinUtils_ProbeWindow
                ; which filters system UI (empty title, not visible, etc.)
                _WEH_DiagLog("FOCUS EVENT (not in store): hwnd=" hwnd " (was " _WEH_PendingFocusHwnd ")")
            } else {
                _WEH_DiagLog("FOCUS EVENT (in store): hwnd=" hwnd " (was " _WEH_PendingFocusHwnd ")")
            }
        }

        _WEH_PendingFocusHwnd := hwnd
    }

    ; Queue for update
    _WEH_PendingHwnds[hwnd] := A_TickCount

    ; Flag Z-order enrichment only for events that change Z-order
    ; NAMECHANGE and LOCATIONCHANGE are frequent but don't affect Z — skip them
    if (event = 0x8000 || event = 0x8002
        || event = 0x0003 || event = 0x8005
        || event = 0x0016 || event = 0x0017) {
        _WEH_PendingZNeeded[hwnd] := true
    }

    Critical "Off"

    ; Fast-path: fire immediate batch for discrete events instead of waiting
    ; up to WinEventHook_BatchMs (default 100ms) for periodic timer.
    ; SetTimer(-1) fires on next message pump cycle (~1-5ms).
    ; Double-fire with periodic timer is harmless: ProcessBatch handles empty queues.
    ; SHOW is discrete (not noisy like NAMECHANGE/LOCATIONCHANGE) and may represent
    ; a window becoming eligible — process quickly for fresh Alt-Tab data.
    if (event = 0x0003 || event = 0x8005 || event = 0x8002)
        SetTimer(_WEH_FastPathBatch, -1)

    ; Wake timer if it was paused due to idle
    _WinEventHook_EnsureTimerRunning()
    } catch as e {
        Critical "Off"
        global LOG_PATH_STORE
        try LogAppend(LOG_PATH_STORE, "WEH_WinEventProc err=" e.Message " file=" e.File " line=" e.Line)
    }
}

; Process queued events in batches
_WEH_ProcessBatch() {
    global _WEH_PendingHwnds, WinEventHook_DebounceMs, _WEH_PendingZNeeded
    global gWEH_LastFocusHwnd, _WEH_PendingFocusHwnd
    global _WEH_IdleTicks, _WEH_IdleThreshold, _WEH_TimerOn, WinEventHook_BatchMs
    global cfg, gWS_Meta, gKSub_MruSuppressUntilTick, gWS_Store, gWS_OnStoreChanged
    global FR_EV_FOCUS, FR_EV_FOCUS_SUPPRESS, FR_EV_PRODUCER_RECOVER, gFR_Enabled
    global LOG_PATH_STORE
    static _errCount := 0  ; Error boundary: consecutive error tracking
    static _backoffUntil := 0  ; Tick-based cooldown for exponential backoff
    if (A_TickCount < _backoffUntil)
        return
    try {

    ; Check for idle condition first (no pending focus and no pending hwnds)
    if (!_WEH_PendingFocusHwnd && _WEH_PendingHwnds.Count = 0) {
        Pump_HandleIdle(&_WEH_IdleTicks, _WEH_IdleThreshold, &_WEH_TimerOn, _WEH_ProcessBatch, _WEH_DiagLog)
        return
    }
    _WEH_IdleTicks := 0  ; Reset idle counter when we have work

    ; Capture diagnostic info BEFORE Critical to avoid blocking on WinGetTitle
    ; (WinGetTitle sends a window message that can block on hung windows)
    diagOldTitle := ""
    diagNewTitle := ""
    diagOldHwnd := gWEH_LastFocusHwnd
    diagNewHwnd := _WEH_PendingFocusHwnd
    if (cfg.DiagWinEventLog && diagNewHwnd && diagNewHwnd != diagOldHwnd) {
        try diagOldTitle := diagOldHwnd ? WinGetTitle("ahk_id " diagOldHwnd) : "(none)"
        try diagNewTitle := WinGetTitle("ahk_id " diagNewHwnd)
    }

    ; Process MRU focus changes first (no debounce needed)
    ; Wrap in Critical to prevent race conditions where old window retains isFocused:true
    ; if removed during focus transition
    pendingProbeHwnd := 0  ; Set inside Critical if probe needed outside
    pendingPrevFocus := 0  ; Previous focus hwnd to clear if probe succeeds
    focusProcessed := false ; Track if focus was updated (for immediate push below)
    Critical "On"
    ; Suppress focus processing during komorebi workspace switch.
    ; Between FocusWorkspaceNumber and FocusChange (~1s), Windows fires
    ; EVENT_SYSTEM_FOREGROUND for old/intermediate windows. Processing them:
    ; 1) gives the wrong window a newer MRU tick, causing visible item "jiggle"
    ; 2) triggers WS MISMATCH correction (line ~307) that flips workspace back and forth
    if (_WEH_PendingFocusHwnd && gKSub_MruSuppressUntilTick > 0 && A_TickCount < gKSub_MruSuppressUntilTick) {
        if (cfg.DiagWinEventLog)
            _WEH_DiagLog("FOCUS SUPPRESSED (ws switch): hwnd=" _WEH_PendingFocusHwnd)
        if (gFR_Enabled)
            FR_Record(FR_EV_FOCUS_SUPPRESS, _WEH_PendingFocusHwnd, gKSub_MruSuppressUntilTick - A_TickCount)
        _WEH_PendingFocusHwnd := 0
    }
    if (_WEH_PendingFocusHwnd && _WEH_PendingFocusHwnd != gWEH_LastFocusHwnd) {
        newFocus := _WEH_PendingFocusHwnd
        _WEH_PendingFocusHwnd := 0  ; Clear pending

        ; Debug: log the focus transition (using titles captured before Critical)
        if (cfg.DiagWinEventLog && diagNewHwnd = newFocus) {
            _WEH_DiagLog("BATCH PROCESS: " diagOldHwnd " '" SubStr(diagOldTitle, 1, 15) "' -> " newFocus " '" SubStr(diagNewTitle, 1, 15) "'")
        }

        ; Check if the new focus window is in our store
        inStore := gWS_Store.Has(newFocus + 0)
        if (cfg.DiagWinEventLog)
            _WEH_DiagLog("  inStore=" (inStore ? 1 : 0))

        ; CRITICAL: Only update gWEH_LastFocusHwnd if the window is actually in our store
        ; This prevents system UI windows (like Alt+Tab switcher) from poisoning our focus tracking
        if (inStore) {
            ; Read workspace before batch (workspaceName not modified by focus batch)
            focusedRec := gWS_Store[newFocus + 0]

            ; Batch old+new focus into a single rev bump + MarkDirty call
            patches := Map()
            patches[newFocus] := { lastActivatedTick: A_TickCount, isFocused: true }
            if (gWEH_LastFocusHwnd && gWEH_LastFocusHwnd != newFocus)
                patches[gWEH_LastFocusHwnd] := { isFocused: false }
            WL_BatchUpdateFields(patches, "winevent_mru")  ; lint-ignore: critical-leak
            Critical "On"  ; Re-enter: BatchUpdateFields' Critical "Off" clears thread-level state

            gWEH_LastFocusHwnd := newFocus
            if (gFR_Enabled)
                FR_Record(FR_EV_FOCUS, newFocus)
            focusProcessed := true

            ; Safety net: detect missed komorebi workspace switch.
            ; If focused window's workspaceName differs from current, komorebi must have
            ; switched workspaces but we missed the event (reconnect, pipe overflow, etc.)
            ; focusedRec read before batch — workspaceName is unaffected by focus updates
            if (focusedRec.HasOwnProp("workspaceName") && focusedRec.workspaceName != ""
                && focusedRec.workspaceName != gWS_Meta["currentWSName"] && gWS_Meta["currentWSName"] != "") {
                if (cfg.DiagWinEventLog)
                    _WEH_DiagLog("  WS MISMATCH: focused window on '" focusedRec.workspaceName "' but CurWS='" gWS_Meta["currentWSName"] "' — correcting")
                WL_SetCurrentWorkspace("", focusedRec.workspaceName)
            }

            ; Enqueue icon refresh check (throttled) - allows updating window icons that change
            ; (e.g., browser favicons) when the window gains focus
            WL_EnqueueIconRefresh(newFocus)  ; lint-ignore: critical-leak
        } else {
            ; Window not in store yet - defer probe to OUTSIDE Critical section.
            ; WinUtils_ProbeWindow sends window messages (WinGetTitle, WinGetClass, WinGetPID)
            ; that can block 10-50ms on slow windows (Electron, Chrome). Holding Critical
            ; during that time freezes the entire store message pump.
            if (cfg.DiagWinEventLog)
                _WEH_DiagLog("  NOT IN STORE: deferring probe outside Critical...")
            pendingProbeHwnd := newFocus
            pendingPrevFocus := gWEH_LastFocusHwnd
        }
    } else if (_WEH_PendingFocusHwnd && _WEH_PendingFocusHwnd = gWEH_LastFocusHwnd) {
        ; Same hwnd - log why we're skipping
        if (cfg.DiagWinEventLog)
            _WEH_DiagLog("FOCUS SKIP: same hwnd " _WEH_PendingFocusHwnd)
        _WEH_PendingFocusHwnd := 0
    }
    Critical "Off"

    ; Deferred probe: runs OUTSIDE Critical so window messages don't block the message pump.
    ; WL_UpsertWindow has its own internal Critical for store mutation.
    if (pendingProbeHwnd) {
        ; Single call: checkEligible=true does Alt-Tab + blacklist checks AND probes
        ; window properties in one pass, avoiding redundant WinGetTitle/WinGetClass/DllCalls
        probe := WinUtils_ProbeWindow(pendingProbeHwnd, 0, false, true)
        probeTitle := (probe && probe.Has("title")) ? probe["title"] : ""
        if (probe && probeTitle != "") {
            probe["lastActivatedTick"] := A_TickCount
            probe["isFocused"] := true
            probe["present"] := true
            probe["presentNow"] := true

            ; Re-check: if a newer focus event arrived during probe, skip the upsert.
            ; _WEH_PendingFocusHwnd is set by the callback and means a newer focus superseded us.
            Critical "On"
            superseded := (_WEH_PendingFocusHwnd != 0 && _WEH_PendingFocusHwnd != pendingProbeHwnd)
            Critical "Off"
            if (!superseded) {
                WL_UpsertWindow([probe], "winevent_focus_add")
                if (cfg.DiagWinEventLog)
                    _WEH_DiagLog("  ADDED TO STORE: '" SubStr(probeTitle, 1, 30) "' with MRU tick")

                ; Clear focus on previous window
                Critical "On"
                if (pendingPrevFocus && pendingPrevFocus != pendingProbeHwnd) {
                    WL_UpdateFields(pendingPrevFocus, { isFocused: false }, "winevent_mru")
                }
                gWEH_LastFocusHwnd := pendingProbeHwnd
                Critical "Off"
                focusProcessed := true
            } else {
                if (cfg.DiagWinEventLog)
                    _WEH_DiagLog("  PROBE SUPERSEDED: newer focus " _WEH_PendingFocusHwnd " arrived during probe")
            }
        } else {
            if (cfg.DiagWinEventLog)
                _WEH_DiagLog("  NOT ELIGIBLE or probe failed (system UI or blacklisted)")
        }
    }

    ; Push focus/MRU changes immediately — don't wait for pending hwnds to pass debounce.
    ; When a fast-path batch fires (e.g., FOREGROUND), the focus UpdateFields above bumps
    ; the store rev, but the push at the bottom of this function is gated by hasRecords
    ; (which requires pending hwnds to pass the 50ms debounce). Since the FOREGROUND event
    ; itself queued an entry in _WEH_PendingHwnds, the Count=0 early-exit below is bypassed.
    ; Without this push, the GUI sees the new window with lastActivatedTick=0 (wrong MRU).
    if (focusProcessed && gWS_OnStoreChanged)
        gWS_OnStoreChanged()

    if (_WEH_PendingHwnds.Count = 0)
        return

    now := A_TickCount

    ; RACE FIX: Snapshot map entries atomically to prevent callback interruption
    ; (callback _WEH_WinEventProc modifies _WEH_PendingHwnds with Critical)
    ; PERF: Static parallel arrays avoid per-batch object allocation.
    ; .Length := 0 resets without dealloc; Push reuses existing capacity.
    Critical "On"
    static snapHwnds := [], snapTicks := []  ; lint-ignore: static-in-timer
    snapHwnds.Length := 0
    snapTicks.Length := 0
    for hwnd, tick in _WEH_PendingHwnds {
        snapHwnds.Push(hwnd)
        snapTicks.Push(tick)
    }
    Critical "Off"

    ; Collect hwnds ready to process (past debounce period)
    toProcess := []
    toRemove := []
    destroyed := []
    hidden := []

    idx := 1
    while (idx <= snapHwnds.Length) {
        h := snapHwnds[idx], t := snapTicks[idx]
        if (t = -1) {
            ; Destroyed window
            destroyed.Push(h)
            toRemove.Push(h)
        } else if (t = -2) {
            ; Hidden window — check eligibility, remove if ghost
            hidden.Push(h)
            toRemove.Push(h)
        } else if ((now - t) >= WinEventHook_DebounceMs) {
            ; Ready to process
            toProcess.Push(h)
            toRemove.Push(h)
        }
        idx++
    }

    ; RACE FIX: Snapshot Z flags before cleanup (needed for conditional enqueue below)
    ; Then remove processed items atomically
    Critical "On"
    zSnapshot := Map()
    for _, hwnd in toProcess {
        if (_WEH_PendingZNeeded.Has(hwnd))
            zSnapshot[hwnd] := true
    }
    for _, hwnd in toRemove {
        _WEH_PendingHwnds.Delete(hwnd)
        if (_WEH_PendingZNeeded.Has(hwnd))
            _WEH_PendingZNeeded.Delete(hwnd)
    }
    Critical "Off"

    ; Handle destroyed windows
    if (destroyed.Length > 0) {
        WL_RemoveWindow(destroyed, true)  ; forceRemove=true - trust the OS
    }

    ; Handle hidden windows — probe and remove if no longer eligible.
    ; Apps like Outlook HIDE windows instead of destroying them when closing
    ; sub-windows (emails, etc.). Without this, ghosts linger until ValidateExistence.
    hiddenRemoved := []
    if (hidden.Length > 0) {
        for _, hwnd in hidden {
            rec := _WEH_ProbeWindow(hwnd)
            if (!rec) {
                ; Not eligible (hidden, no title, etc.) — remove from store
                hiddenRemoved.Push(hwnd)
            }
            ; If still eligible, window got a transient HIDE — leave it alone
        }
        if (hiddenRemoved.Length > 0)
            WL_RemoveWindow(hiddenRemoved, true)
    }

    ; Probe and update changed windows
    ; NOTE: Do NOT call BeginScan/EndScan here - that's for full scans only.
    ; Partial producers should just upsert without affecting other windows' presence.
    ;
    ; PERF: Split into two paths to avoid redundant cross-process calls.
    ; In-store windows: lightweight update (title + vis/min/cloak only — class/PID are immutable).
    ; New windows: full probe (WinGetTitle + WinGetClass + WinGetPID + eligibility check).
    if (toProcess.Length > 0) {
        newRecords := []
        updatedHwnds := []
        ineligibleHwnds := []
        for _, hwnd in toProcess {
            if (gWS_Store.Has(hwnd + 0)) {
                ; Lightweight path: window already in store — skip immutable fields
                result := _WEH_UpdateExisting(hwnd)
                if (result = -1)
                    ineligibleHwnds.Push(hwnd)
                else if (result)
                    updatedHwnds.Push(hwnd)
            } else {
                ; Full probe path: new window needs all fields
                rec := _WEH_ProbeWindow(hwnd)
                if (rec)
                    newRecords.Push(rec)
            }
        }
        ; Remove windows that became ineligible (ghost windows, title cleared, etc.)
        if (ineligibleHwnds.Length > 0)
            WL_RemoveWindow(ineligibleHwnds, true)
        ; Upsert new windows (full record)
        if (newRecords.Length > 0)
            WL_UpsertWindow(newRecords, "winevent_hook")
        ; Enqueue Z-order and icon refresh for all processed hwnds
        allProcessed := []
        for _, rec in newRecords
            allProcessed.Push(rec["hwnd"])
        for _, hwnd in updatedHwnds
            allProcessed.Push(hwnd)
        if (allProcessed.Length > 0) {
            ; Only enqueue Z-order enrichment for events that change Z-order
            ; (CREATE, SHOW, FOREGROUND, FOCUS, MINIMIZE, RESTORE)
            ; Skips NAMECHANGE and LOCATIONCHANGE which fire frequently but don't affect Z
            for _, hwnd in allProcessed {
                if (zSnapshot.Has(hwnd))
                    WL_EnqueueForZ(hwnd)
            }
            ; Enqueue icon refresh for title-change events (NAMECHANGE, not Z-affecting).
            ; Icons often change when titles change (browser tab switch, app state change).
            ; Per-window throttle (IconPumpRefreshThrottleMs) prevents spam.
            if (cfg.IconRefreshOnTitleChange) {
                for _, hwnd in allProcessed {
                    if (!zSnapshot.Has(hwnd))
                        WL_EnqueueIconRefresh(hwnd)
                }
            }
        }
    }

    ; Proactive push: broadcast to clients when WEH changes bumped the rev.
    ; Without this, focus/title/destroy changes only reach the GUI via the Z-pump
    ; (~220ms) or the next Alt-press prewarm — adding significant latency.
    ; Structural changes (destroy, Z-affecting events) push immediately.
    ; Cosmetic-only changes (title/location) are throttled to avoid push floods
    ; from apps with animated titles (e.g., terminal spinners).
    hasRecords := (toProcess.Length > 0 && IsSet(records) && records.Length > 0)
    if (destroyed.Length > 0 || hiddenRemoved.Length > 0 || hasRecords) {
        isStructural := destroyed.Length > 0 || hiddenRemoved.Length > 0 || zSnapshot.Count > 0
        if (gWS_OnStoreChanged)
            gWS_OnStoreChanged(isStructural)
    }
    ; Recovery: if we were in backoff and succeeded, log recovery + stop MRU fallback
    if (_backoffUntil) {
        prevBackoff := _backoffUntil - A_TickCount  ; negative = how far past backoff we are
        if (gFR_Enabled)
            FR_Record(FR_EV_PRODUCER_RECOVER, _errCount, Abs(prevBackoff))
        try LogAppend(LOG_PATH_STORE, "WEH_ProcessBatch RECOVERED after " _errCount " consecutive errors")
        ; Stop MRU_Lite fallback if it was activated during our backoff
        _WEH_StopMruFallback()
    }
    _errCount := 0
    _backoffUntil := 0
    } catch as e {
        backoffMs := HandleTimerError(e, &_errCount, &_backoffUntil, LOG_PATH_STORE, "WEH_ProcessBatch")
        ; WEH-specific: enable MRU_Lite as runtime fallback during backoff
        if (backoffMs > 0)
            _WEH_StartMruFallback()
    }
}

; WEH-specific: activate MRU_Lite as runtime fallback when WEH enters backoff
_WEH_StartMruFallback() {
    global _WEH_MruFallbackActive, LOG_PATH_STORE
    if (!_WEH_MruFallbackActive) {
        _WEH_MruFallbackActive := true
        try {
            MRU_Lite_Init()
            try LogAppend(LOG_PATH_STORE, "WEH_ProcessBatch: MRU_Lite fallback ACTIVATED during backoff")
        } catch as e {
            try LogAppend(LOG_PATH_STORE, "WEH_ProcessBatch: MRU_Lite fallback FAILED: " e.Message)
        }
    }
}

; Stop MRU_Lite fallback when WEH recovers
_WEH_StopMruFallback() {
    global _WEH_MruFallbackActive, LOG_PATH_STORE
    if (_WEH_MruFallbackActive) {
        _WEH_MruFallbackActive := false
        try SetTimer(MRU_Lite_Tick, 0)
        try LogAppend(LOG_PATH_STORE, "WEH_ProcessBatch: MRU_Lite fallback STOPPED (WEH recovered)")
    }
}

; Probe a single window - returns Map or empty string
; Uses shared WinUtils_ProbeWindow with exists and eligibility checks
_WEH_ProbeWindow(hwnd) {
    return WinUtils_ProbeWindow(hwnd, 0, true, true)  ; checkExists=true, checkEligible=true
}

; Lightweight update for windows already in the store.
; Skips immutable fields (class, PID) - only fetches title + vis/min/cloak.
; Returns: true if updated, false if skipped (hung/dead), -1 if ineligible (should remove)
_WEH_UpdateExisting(hwnd) {
    global gWS_Store
    ; Check window still exists
    try {
        if (!DllCall("user32\IsWindow", "ptr", hwnd, "int"))
            return -1
    } catch
        return false

    ; Skip hung windows — WinGetTitle sends WM_GETTEXT which blocks on hung apps
    try {
        if (DllCall("user32\IsHungAppWindow", "ptr", hwnd, "int"))
            return false
    }

    ; Fetch title (the only mutable text field)
    title := ""
    try
        title := WinGetTitle("ahk_id " hwnd)
    catch
        return false

    ; Re-check eligibility using stored class (immutable) + fresh title
    row := gWS_Store[hwnd + 0]
    class := row.class
    isVisible := false
    isMin := false
    isCloaked := false
    if (!Blacklist_IsWindowEligibleEx(hwnd, title, class, &isVisible, &isMin, &isCloaked))
        return -1

    ; Patch only the mutable fields
    patch := Map()
    patch["title"] := title
    patch["isCloaked"] := isCloaked
    patch["isMinimized"] := isMin
    patch["isVisible"] := isVisible
    WL_UpdateFields(hwnd, patch, "weh_update")
    return true
}

