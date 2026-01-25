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
global _WEH_LastProcessTick := 0
global _WEH_TimerOn := false
global _WEH_ShellWindow := 0
global _WEH_IdleTicks := 0                ; Counter for consecutive empty ticks
global _WEH_IdleThreshold := 10           ; Default, overridden from config in WinEventHook_Start()

; MRU tracking (replaces MRU_Lite when hook is active)
global _WEH_LastFocusHwnd := 0
global _WEH_PendingFocusHwnd := 0         ; Set by callback, processed by batch

; Debug logging for focus events - controlled by DiagWinEventLog config flag
_WEH_DiagLog(msg) {
    global cfg, LOG_PATH_WINEVENT
    if (!cfg.DiagWinEventLog)
        return
    try FileAppend(GetLogTimestamp() " " msg "`n", LOG_PATH_WINEVENT, "UTF-8")
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

    ; Load config values on first start (ConfigLoader_Init has already run)
    if (WinEventHook_DebounceMs = 0) {
        global _WEH_IdleThreshold
        WinEventHook_DebounceMs := cfg.WinEventHookDebounceMs
        WinEventHook_BatchMs := cfg.WinEventHookBatchMs
        _WEH_IdleThreshold := cfg.HasOwnProp("WinEventHookIdleThreshold") ? cfg.WinEventHookIdleThreshold : 10
    }

    if (_WEH_Hook)
        return  ; Already running

    _WEH_ShellWindow := DllCall("user32\GetShellWindow", "ptr")

    ; Hook range covers all events we care about
    ; EVENT_MIN = 0x0001, but we only need from SYSTEM_FOREGROUND to OBJECT_NAMECHANGE
    minEvent := 0x0003  ; EVENT_SYSTEM_FOREGROUND
    maxEvent := 0x800C  ; EVENT_OBJECT_NAMECHANGE

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
    global _WEH_PendingHwnds, _WEH_ShellWindow, _WEH_PendingFocusHwnd
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
        ; Get window title to filter system UI
        title := ""
        try title := WinGetTitle("ahk_id " hwnd)

        ; CRITICAL: Skip windows with empty titles - these are system UI like Task Switching
        ; that briefly get focus during Alt+Tab and would overwrite the real target window
        if (title = "") {
            _WEH_DiagLog("FOCUS SKIP (no title): hwnd=" hwnd " (keeping " _WEH_PendingFocusHwnd ")")
            Critical "Off"
            return
        }

        oldPending := _WEH_PendingFocusHwnd
        _WEH_PendingFocusHwnd := hwnd
        _WEH_DiagLog("FOCUS EVENT: hwnd=" hwnd " title='" SubStr(title, 1, 25) "' (was " oldPending ")")
    }

    ; Queue for update
    _WEH_PendingHwnds[hwnd] := A_TickCount

    Critical "Off"

    ; Wake timer if it was paused due to idle
    WinEventHook_EnsureTimerRunning()
}

; Process queued events in batches
_WEH_ProcessBatch() {
    global _WEH_PendingHwnds, _WEH_LastProcessTick, WinEventHook_DebounceMs
    global _WEH_LastFocusHwnd, _WEH_PendingFocusHwnd
    global _WEH_IdleTicks, _WEH_IdleThreshold, _WEH_TimerOn, WinEventHook_BatchMs

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
    if (_WEH_PendingFocusHwnd && _WEH_PendingFocusHwnd != _WEH_LastFocusHwnd) {
        newFocus := _WEH_PendingFocusHwnd
        _WEH_PendingFocusHwnd := 0  ; Clear pending

        ; Debug: log the focus transition (always log hwnd, title may fail)
        oldTitle := ""
        newTitle := ""
        try oldTitle := _WEH_LastFocusHwnd ? WinGetTitle("ahk_id " _WEH_LastFocusHwnd) : "(none)"
        try newTitle := WinGetTitle("ahk_id " newFocus)
        _WEH_DiagLog("BATCH PROCESS: " _WEH_LastFocusHwnd " '" SubStr(oldTitle, 1, 15) "' -> " newFocus " '" SubStr(newTitle, 1, 15) "'")

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

            ; Enqueue icon refresh check (throttled) - allows updating window icons that change
            ; (e.g., browser favicons) when the window gains focus
            try WindowStore_EnqueueIconRefresh(newFocus)
        } else {
            _WEH_DiagLog("  IGNORED: window not in store (system UI?)")
        }
    } else if (_WEH_PendingFocusHwnd && _WEH_PendingFocusHwnd = _WEH_LastFocusHwnd) {
        ; Same hwnd - log why we're skipping
        _WEH_DiagLog("FOCUS SKIP: same hwnd " _WEH_PendingFocusHwnd)
        _WEH_PendingFocusHwnd := 0
    }
    Critical "Off"

    if (_WEH_PendingHwnds.Count = 0)
        return

    now := A_TickCount

    ; Collect hwnds ready to process (past debounce period)
    toProcess := []
    toRemove := []
    destroyed := []

    for hwnd, tick in _WEH_PendingHwnds {
        if (tick = -1) {
            ; Destroyed window
            destroyed.Push(hwnd)
            toRemove.Push(hwnd)
        } else if ((now - tick) >= WinEventHook_DebounceMs) {
            ; Ready to process
            toProcess.Push(hwnd)
            toRemove.Push(hwnd)
        }
    }

    ; Remove processed items from pending
    for _, hwnd in toRemove {
        _WEH_PendingHwnds.Delete(hwnd)
    }

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
            ; Enqueue for Z-order enrichment (triggers winenum pump)
            for _, rec in records {
                WindowStore_EnqueueForZ(rec["hwnd"])
            }
        }
    }

    _WEH_LastProcessTick := now
}

; Probe a single window - returns Map or empty string
; Uses shared WinUtils_ProbeWindow with exists and eligibility checks
_WEH_ProbeWindow(hwnd) {
    return WinUtils_ProbeWindow(hwnd, 0, true, true)  ; checkExists=true, checkEligible=true
}

