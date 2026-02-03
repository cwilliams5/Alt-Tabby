#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Expected: file is included after windowstore.ahk

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
global _WEH_Hook := 0
global _WEH_CallbackObj := 0              ; Callback object - MUST be global to prevent GC
global _WEH_PendingHwnds := Map()         ; hwnd -> tick of last event
global _WEH_TimerOn := false
global _WEH_ShellWindow := 0
global _WEH_IdleTicks := 0                ; Counter for consecutive empty ticks
global _WEH_IdleThreshold := 10           ; Default, overridden from config in WinEventHook_Start()

; MRU tracking (replaces MRU_Lite when hook is active)
global _WEH_LastFocusHwnd := 0
global _WEH_PendingFocusHwnd := 0         ; Set by callback, processed by batch

; Z-order tracking: only events that change Z-order should trigger full winenum scan
; NAMECHANGE and LOCATIONCHANGE fire frequently but don't affect Z — skip them
global _WEH_PendingZNeeded := Map()       ; hwnd -> true if Z-affecting event received

; Cosmetic buffer: throttle pushes for cosmetic-only batches (title changes)
global _WEH_LastCosmeticPushTick := 0     ; Tick of last push for cosmetic-only changes

; Debug logging for focus events - controlled by DiagWinEventLog config flag
_WEH_DiagLog(msg) {
    global cfg, LOG_PATH_WINEVENT
    if (!cfg.DiagWinEventLog)
        return
    LogAppend(LOG_PATH_WINEVENT, msg)
}

; Event constants
global WEH_EVENT_OBJECT_CREATE := 0x8000
global WEH_EVENT_OBJECT_DESTROY := 0x8001
global WEH_EVENT_OBJECT_SHOW := 0x8002
global WEH_EVENT_OBJECT_HIDE := 0x8003
global WEH_EVENT_OBJECT_FOCUS := 0x8005
global WEH_EVENT_OBJECT_LOCATIONCHANGE := 0x800B
global WEH_EVENT_OBJECT_NAMECHANGE := 0x800C
global WEH_EVENT_SYSTEM_FOREGROUND := 0x0003
global WEH_EVENT_SYSTEM_MINIMIZESTART := 0x0016
global WEH_EVENT_SYSTEM_MINIMIZEEND := 0x0017

; Initialize and install the hook
WinEventHook_Start() {
    global _WEH_Hook, _WEH_ShellWindow, _WEH_TimerOn, cfg
    global WinEventHook_DebounceMs, WinEventHook_BatchMs
    global _WEH_CallbackObj

    ; Load config values on first start (ConfigLoader_Init has already run)
    if (WinEventHook_DebounceMs = 0) {
        global _WEH_IdleThreshold
        WinEventHook_DebounceMs := cfg.WinEventHookDebounceMs
        WinEventHook_BatchMs := cfg.WinEventHookBatchMs
        _WEH_IdleThreshold := cfg.HasOwnProp("WinEventHookIdleThreshold") ? cfg.WinEventHookIdleThreshold : 10
    }

    ; Reset log for new session (before early-exit guard)
    if (cfg.DiagWinEventLog) {
        global LOG_PATH_WINEVENT
        LogInitSession(LOG_PATH_WINEVENT, "Alt-Tabby WinEvent Log")
    }

    if (_WEH_Hook)
        return  ; Already running

    _WEH_ShellWindow := DllCall("user32\GetShellWindow", "ptr")

    ; Hook range covers all events we care about
    ; EVENT_MIN = 0x0001, but we only need from SYSTEM_FOREGROUND to OBJECT_NAMECHANGE
    global WEH_EVENT_SYSTEM_FOREGROUND, WEH_EVENT_OBJECT_NAMECHANGE
    minEvent := WEH_EVENT_SYSTEM_FOREGROUND
    maxEvent := WEH_EVENT_OBJECT_NAMECHANGE

    ; Create the callback - store globally to prevent GC (CRITICAL!)
    ; If stored in a local variable, the callback can be garbage collected while
    ; the hook is still active, causing crashes or silent failures.
    _WEH_CallbackObj := CallbackCreate(_WEH_WinEventProc, "F", 7)

    ; Install out-of-context hook (WINEVENT_OUTOFCONTEXT = 0)
    ; This allows us to receive events from all processes
    _WEH_Hook := DllCall("user32\SetWinEventHook",
        "uint", minEvent,       ; eventMin
        "uint", maxEvent,       ; eventMax
        "ptr", 0,               ; hmodWinEventProc (0 for out-of-context)
        "ptr", _WEH_CallbackObj, ; pfnWinEventProc
        "uint", 0,              ; idProcess (0 = all)
        "uint", 0,              ; idThread (0 = all)
        "uint", 0,              ; dwFlags (WINEVENT_OUTOFCONTEXT)
        "ptr")

    if (!_WEH_Hook) {
        return false
    }

    ; Start the batch processing timer
    _WEH_TimerOn := true
    SetTimer(_WEH_ProcessBatch, WinEventHook_BatchMs)

    return true
}

; Ensure the batch processing timer is running (wake from idle pause)
; Called by the callback when new events are queued
WinEventHook_EnsureTimerRunning() {
    global _WEH_TimerOn, _WEH_IdleTicks, WinEventHook_BatchMs
    Pump_EnsureRunning(&_WEH_TimerOn, &_WEH_IdleTicks, WinEventHook_BatchMs, _WEH_ProcessBatch)
}

; Stop and uninstall the hook
WinEventHook_Stop() {
    global _WEH_Hook, _WEH_TimerOn, _WEH_CallbackObj

    if (_WEH_TimerOn) {
        SetTimer(_WEH_ProcessBatch, 0)
        _WEH_TimerOn := false
    }

    if (_WEH_Hook) {
        DllCall("user32\UnhookWinEvent", "ptr", _WEH_Hook)
        _WEH_Hook := 0
    }

    ; Free the callback object to prevent memory leak
    if (_WEH_CallbackObj) {
        CallbackFree(_WEH_CallbackObj)
        _WEH_CallbackObj := 0
    }
}

; Hook callback - called for each window event
; Keep this FAST - just queue the hwnd for later processing
_WEH_WinEventProc(hWinEventHook, event, hwnd, idObject, idChild, idEventThread, dwmsEventTime) {
    global _WEH_PendingHwnds, _WEH_ShellWindow, _WEH_PendingFocusHwnd, _WEH_PendingZNeeded
    global WEH_EVENT_OBJECT_CREATE, WEH_EVENT_OBJECT_DESTROY, WEH_EVENT_OBJECT_SHOW
    global WEH_EVENT_OBJECT_HIDE, WEH_EVENT_SYSTEM_FOREGROUND, WEH_EVENT_OBJECT_NAMECHANGE
    global WEH_EVENT_SYSTEM_MINIMIZESTART, WEH_EVENT_SYSTEM_MINIMIZEEND, WEH_EVENT_OBJECT_FOCUS
    global WEH_EVENT_OBJECT_LOCATIONCHANGE

    ; Only care about window-level events (idObject = OBJID_WINDOW = 0)
    if (idObject != 0)
        return

    ; Skip shell window
    if (hwnd = _WEH_ShellWindow)
        return

    ; Filter to relevant events
    if (event != WEH_EVENT_OBJECT_CREATE
        && event != WEH_EVENT_OBJECT_DESTROY
        && event != WEH_EVENT_OBJECT_SHOW
        && event != WEH_EVENT_OBJECT_HIDE
        && event != WEH_EVENT_SYSTEM_FOREGROUND
        && event != WEH_EVENT_OBJECT_NAMECHANGE
        && event != WEH_EVENT_SYSTEM_MINIMIZESTART
        && event != WEH_EVENT_SYSTEM_MINIMIZEEND
        && event != WEH_EVENT_OBJECT_FOCUS
        && event != WEH_EVENT_OBJECT_LOCATIONCHANGE)
        return

    ; RACE FIX: Protect Map writes from batch processor interruption
    ; The batch processor iterates _WEH_PendingHwnds - we must not modify it concurrently
    Critical "On"

    ; For destroy events, mark for removal
    if (event = WEH_EVENT_OBJECT_DESTROY) {
        _WEH_PendingHwnds[hwnd] := -1  ; -1 = destroyed
        Critical "Off"
        return
    }

    ; For focus/foreground events, capture for MRU update (processed in batch)
    if (event = WEH_EVENT_SYSTEM_FOREGROUND || event = WEH_EVENT_OBJECT_FOCUS) {
        ; Skip hung windows - WinGetTitle sends messages that block up to 5s
        try {
            if (DllCall("user32\IsHungAppWindow", "ptr", hwnd, "int")) {
                Critical "Off"
                return
            }
        }

        ; Get window title to filter system UI
        title := ""
        try title := WinGetTitle("ahk_id " hwnd)

        ; CRITICAL: Skip windows with empty titles UNLESS they're already in our store.
        ; Empty title filter catches system UI like Task Switching that briefly get focus.
        ; But apps like Outlook may have windows with no title momentarily - if we already
        ; know about them (in store), we should still update their MRU.
        if (title = "") {
            ; Check if window is in store - if so, allow focus update
            inStore := false
            try inStore := WindowStore_GetByHwnd(hwnd) != 0
            if (!inStore) {
                _WEH_DiagLog("FOCUS SKIP (no title, not in store): hwnd=" hwnd " (keeping " _WEH_PendingFocusHwnd ")")
                Critical "Off"
                return
            }
            _WEH_DiagLog("FOCUS EVENT (no title but IN STORE): hwnd=" hwnd " (was " _WEH_PendingFocusHwnd ")")
        } else {
            _WEH_DiagLog("FOCUS EVENT: hwnd=" hwnd " title='" SubStr(title, 1, 25) "' (was " _WEH_PendingFocusHwnd ")")
        }

        _WEH_PendingFocusHwnd := hwnd
    }

    ; Queue for update
    _WEH_PendingHwnds[hwnd] := A_TickCount

    ; Flag Z-order enrichment only for events that change Z-order
    ; NAMECHANGE and LOCATIONCHANGE are frequent but don't affect Z — skip them
    if (event = WEH_EVENT_OBJECT_CREATE
        || event = WEH_EVENT_OBJECT_SHOW
        || event = WEH_EVENT_SYSTEM_FOREGROUND
        || event = WEH_EVENT_OBJECT_FOCUS
        || event = WEH_EVENT_SYSTEM_MINIMIZESTART
        || event = WEH_EVENT_SYSTEM_MINIMIZEEND) {
        _WEH_PendingZNeeded[hwnd] := true
    }

    Critical "Off"

    ; Fast-path: fire immediate batch for focus events instead of waiting
    ; up to WinEventHook_BatchMs (default 100ms) for periodic timer.
    ; SetTimer(-1) fires on next message pump cycle (~1-5ms).
    ; Double-fire with periodic timer is harmless: ProcessBatch handles empty queues.
    if (event = WEH_EVENT_SYSTEM_FOREGROUND || event = WEH_EVENT_OBJECT_FOCUS)
        SetTimer(_WEH_ProcessBatch, -1)

    ; Wake timer if it was paused due to idle
    WinEventHook_EnsureTimerRunning()
}

; Process queued events in batches
_WEH_ProcessBatch() {
    global _WEH_PendingHwnds, WinEventHook_DebounceMs, _WEH_PendingZNeeded
    global _WEH_LastFocusHwnd, _WEH_PendingFocusHwnd
    global _WEH_IdleTicks, _WEH_IdleThreshold, _WEH_TimerOn, WinEventHook_BatchMs
    global cfg, gWS_Meta, gKSub_MruSuppressUntilTick

    ; Check for idle condition first (no pending focus and no pending hwnds)
    if (!_WEH_PendingFocusHwnd && _WEH_PendingHwnds.Count = 0) {
        Pump_HandleIdle(&_WEH_IdleTicks, _WEH_IdleThreshold, &_WEH_TimerOn, _WEH_ProcessBatch, _WEH_DiagLog)
        return
    }
    _WEH_IdleTicks := 0  ; Reset idle counter when we have work

    ; Process MRU focus changes first (no debounce needed)
    ; Wrap in Critical to prevent race conditions where old window retains isFocused:true
    ; if removed during focus transition
    Critical "On"
    ; Suppress focus processing during komorebi workspace switch.
    ; Between FocusWorkspaceNumber and FocusChange (~1s), Windows fires
    ; EVENT_SYSTEM_FOREGROUND for old/intermediate windows. Processing them:
    ; 1) gives the wrong window a newer MRU tick, causing visible item "jiggle"
    ; 2) triggers WS MISMATCH correction (line ~307) that flips workspace back and forth
    if (_WEH_PendingFocusHwnd && gKSub_MruSuppressUntilTick > 0 && A_TickCount < gKSub_MruSuppressUntilTick) {
        _WEH_DiagLog("FOCUS SUPPRESSED (ws switch): hwnd=" _WEH_PendingFocusHwnd)
        _WEH_PendingFocusHwnd := 0
    }
    if (_WEH_PendingFocusHwnd && _WEH_PendingFocusHwnd != _WEH_LastFocusHwnd) {
        newFocus := _WEH_PendingFocusHwnd
        _WEH_PendingFocusHwnd := 0  ; Clear pending

        ; Debug: log the focus transition (only fetch titles when diagnostics enabled)
        if (cfg.DiagWinEventLog) {
            oldTitle := ""
            newTitle := ""
            try oldTitle := _WEH_LastFocusHwnd ? WinGetTitle("ahk_id " _WEH_LastFocusHwnd) : "(none)"
            try newTitle := WinGetTitle("ahk_id " newFocus)
            _WEH_DiagLog("BATCH PROCESS: " _WEH_LastFocusHwnd " '" SubStr(oldTitle, 1, 15) "' -> " newFocus " '" SubStr(newTitle, 1, 15) "'")
        }

        ; Try to update the new window first - this tells us if it's in our store
        result := { changed: false, exists: false }
        try result := WindowStore_UpdateFields(newFocus, { lastActivatedTick: A_TickCount, isFocused: true }, "winevent_mru")
        _WEH_DiagLog("  UpdateFields result: exists=" (result.exists ? 1 : 0) " changed=" (result.changed ? 1 : 0))

        ; CRITICAL: Only update _WEH_LastFocusHwnd if the window is actually in our store
        ; This prevents system UI windows (like Alt+Tab switcher) from poisoning our focus tracking
        if (result.exists) {
            ; Clear focus on previous window (only if we're actually switching to a tracked window)
            if (_WEH_LastFocusHwnd && _WEH_LastFocusHwnd != newFocus) {
                try WindowStore_UpdateFields(_WEH_LastFocusHwnd, { isFocused: false }, "winevent_mru")
            }
            _WEH_LastFocusHwnd := newFocus

            ; Safety net: detect missed komorebi workspace switch.
            ; If focused window's workspaceName differs from current, komorebi must have
            ; switched workspaces but we missed the event (reconnect, pipe overflow, etc.)
            try {
                focusedRec := WindowStore_GetByHwnd(newFocus)
                if (focusedRec && focusedRec.HasOwnProp("workspaceName") && focusedRec.workspaceName != ""
                    && focusedRec.workspaceName != gWS_Meta["currentWSName"] && gWS_Meta["currentWSName"] != "") {
                    _WEH_DiagLog("  WS MISMATCH: focused window on '" focusedRec.workspaceName "' but CurWS='" gWS_Meta["currentWSName"] "' — correcting")
                    WindowStore_SetCurrentWorkspace("", focusedRec.workspaceName)
                }
            }

            ; Enqueue icon refresh check (throttled) - allows updating window icons that change
            ; (e.g., browser favicons) when the window gains focus
            try WindowStore_EnqueueIconRefresh(newFocus)
        } else {
            ; Window not in store yet - check if it's eligible and add it with focus data
            ; This fixes the race condition where focus event arrives before WinEnum discovers the window
            ; Without this fix, newly opened windows appear at BOTTOM of MRU list (lastActivatedTick=0)
            _WEH_DiagLog("  NOT IN STORE: checking eligibility...")
            ; Single call: checkEligible=true does Alt-Tab + blacklist checks AND probes
            ; window properties in one pass, avoiding redundant WinGetTitle/WinGetClass/DllCalls
            probe := WinUtils_ProbeWindow(newFocus, 0, false, true)
            probeTitle := (probe && probe.Has("title")) ? probe["title"] : ""
            if (probe && probeTitle != "") {
                probe["lastActivatedTick"] := A_TickCount
                probe["isFocused"] := true
                probe["present"] := true
                probe["presentNow"] := true
                try WindowStore_UpsertWindow([probe], "winevent_focus_add")
                _WEH_DiagLog("  ADDED TO STORE: '" SubStr(probeTitle, 1, 30) "' with MRU tick")

                ; Clear focus on previous window
                if (_WEH_LastFocusHwnd && _WEH_LastFocusHwnd != newFocus) {
                    try WindowStore_UpdateFields(_WEH_LastFocusHwnd, { isFocused: false }, "winevent_mru")
                }
                _WEH_LastFocusHwnd := newFocus
            } else {
                _WEH_DiagLog("  NOT ELIGIBLE or probe failed (system UI or blacklisted)")
            }
        }
    } else if (_WEH_PendingFocusHwnd && _WEH_PendingFocusHwnd = _WEH_LastFocusHwnd) {
        ; Same hwnd - log why we're skipping
        _WEH_DiagLog("FOCUS SKIP: same hwnd " _WEH_PendingFocusHwnd)
        _WEH_PendingFocusHwnd := 0
    }
    Critical "Off"

    if (_WEH_PendingHwnds.Count = 0) {
        ; Focus-only path: push if focus change bumped rev (no structural changes pending)
        _WEH_PushIfRevChanged()
        return
    }

    now := A_TickCount

    ; RACE FIX: Snapshot map entries atomically to prevent callback interruption
    ; (callback _WEH_WinEventProc modifies _WEH_PendingHwnds with Critical)
    Critical "On"
    entries := []
    for hwnd, tick in _WEH_PendingHwnds
        entries.Push({hwnd: hwnd, tick: tick})
    Critical "Off"

    ; Collect hwnds ready to process (past debounce period)
    toProcess := []
    toRemove := []
    destroyed := []

    for _, entry in entries {
        if (entry.tick = -1) {
            ; Destroyed window
            destroyed.Push(entry.hwnd)
            toRemove.Push(entry.hwnd)
        } else if ((now - entry.tick) >= WinEventHook_DebounceMs) {
            ; Ready to process
            toProcess.Push(entry.hwnd)
            toRemove.Push(entry.hwnd)
        }
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
        WindowStore_RemoveWindow(destroyed, true)  ; forceRemove=true - trust the OS
    }

    ; Probe and update changed windows
    ; NOTE: Do NOT call BeginScan/EndScan here - that's for full scans only.
    ; Partial producers should just upsert without affecting other windows' presence.
    if (toProcess.Length > 0) {
        records := []
        for _, hwnd in toProcess {
            rec := _WEH_ProbeWindow(hwnd)
            if (rec)
                records.Push(rec)
        }
        if (records.Length > 0) {
            WindowStore_UpsertWindow(records, "winevent_hook")
            ; Only enqueue Z-order enrichment for events that change Z-order
            ; (CREATE, SHOW, FOREGROUND, FOCUS, MINIMIZE, RESTORE)
            ; Skips NAMECHANGE and LOCATIONCHANGE which fire frequently but don't affect Z
            for _, rec in records {
                if (zSnapshot.Has(rec["hwnd"]))
                    WindowStore_EnqueueForZ(rec["hwnd"])
            }
        }
    }

    ; Proactive push: broadcast to clients when WEH changes bumped the rev.
    ; Without this, focus/title/destroy changes only reach the GUI via the Z-pump
    ; (~220ms) or the next Alt-press prewarm — adding significant latency.
    ; Structural changes (destroy, Z-affecting events) push immediately.
    ; Cosmetic-only changes (title/location) are throttled to avoid push floods
    ; from apps with animated titles (e.g., terminal spinners).
    hasRecords := (toProcess.Length > 0 && IsSet(records) && records.Length > 0)  ; lint-ignore: isset-with-default
    if (destroyed.Length > 0 || hasRecords) {
        isStructural := destroyed.Length > 0 || zSnapshot.Count > 0
        _WEH_PushIfRevChanged(isStructural)
    }
}

; Push to clients if the store rev has changed since the last broadcast.
; Called after focus, upsert, and destroy processing to ensure proactive delta delivery.
; Parameters:
;   isStructural - true for focus/create/destroy/Z-affecting changes (push immediately)
;                  false for cosmetic-only changes like title updates (throttled)
;                  Default true so the focus-only path at line 333 always pushes immediately.
_WEH_PushIfRevChanged(isStructural := true) {
    global gStore_LastBroadcastRev, _WEH_LastCosmeticPushTick, cfg
    ; RACE FIX: Wrap read-check-write-push in Critical to prevent two timers
    ; from both reading same old rev and both pushing (duplicate broadcast)
    Critical "On"
    rev := WindowStore_GetRev()
    if (rev = gStore_LastBroadcastRev) {
        Critical "Off"
        return
    }

    ; Cosmetic-only changes: throttle to avoid push floods from apps with
    ; animated titles (terminal spinners, progress bars, etc.)
    if (!isStructural) {
        elapsed := A_TickCount - _WEH_LastCosmeticPushTick
        if (elapsed < cfg.WinEventHookCosmeticBufferMs) {
            Critical "Off"
            return
        }
        _WEH_LastCosmeticPushTick := A_TickCount
    }

    gStore_LastBroadcastRev := rev
    try Store_PushToClients()
    Critical "Off"
}

; Probe a single window - returns Map or empty string
; Uses shared WinUtils_ProbeWindow with exists and eligibility checks
_WEH_ProbeWindow(hwnd) {
    return WinUtils_ProbeWindow(hwnd, 0, true, true)  ; checkExists=true, checkEligible=true
}

