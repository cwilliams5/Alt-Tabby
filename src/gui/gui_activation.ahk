#Requires AutoHotkey v2.0
; Alt-Tabby GUI - Activation Engine
; Handles HOW to activate a chosen window: workspace switching, COM uncloaking,
; robust Win32 activation. Called from gui_state.ahk which decides WHAT to activate.
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals/functions

; ============================================================
; ASYNC CROSS-WORKSPACE ACTIVATION STATE
; ============================================================
; Single object for non-blocking workspace switch state.
; Reset atomically via gGUI_Pending := _GUI_NewPendingState().
; Phase progression: "" -> "polling" -> "waiting" -> "flushing" -> ""
global gGUI_Pending := _GUI_NewPendingState()
global gStats_CrossWorkspace := 0

_GUI_NewPendingState() {
    return {
        hwnd: 0,            ; Target hwnd
        wsName: "",          ; Target workspace name
        deadline: 0,         ; Polling deadline (when to give up)
        phase: "",           ; "polling", "waiting", "flushing", or ""
        waitUntil: 0,        ; End of post-switch wait
        shell: "",           ; WScript.Shell COM object (reused)
        tempFile: ""         ; Temp file for query results
    }
}

; COM interfaces for direct window uncloaking (mimic native Alt+Tab)
; These allow us to uncloak a single window without switching workspaces,
; letting komorebi's reconciliation handle the workspace switch after activation.
global gGUI_ImmersiveShell := 0          ; ImmersiveShell COM object
global gGUI_AppViewCollection := 0       ; IApplicationViewCollection interface

; ========================= ACTIVATION =========================

; Unified activation logic with cross-workspace support via komorebi
; For cross-workspace: ASYNC (non-blocking) to allow keyboard events during switch
; For same-workspace: SYNC (immediate) for speed
; Uses komorebi's activation pattern: SendInput → SetWindowPos → SetForegroundWindow
GUI_ActivateItem(item) {
    Profiler.Enter("GUI_ActivateItem") ; @profile
    global cfg
    global gGUI_Pending
    global gGUI_LiveItems, gGUI_CurrentWSName  ; Needed for same-workspace MRU update

    hwnd := item.hwnd
    if (!hwnd) {
        Profiler.Leave() ; @profile
        return false
    }

    ; Check if window is on a different workspace
    isOnCurrent := GUI_GetItemIsOnCurrent(item)
    wsName := item.HasOwnProp("workspaceName") ? item.workspaceName : ""

    global FR_EV_ACTIVATE_START, gFR_Enabled
    if (gFR_Enabled)
        FR_Record(FR_EV_ACTIVATE_START, hwnd, isOnCurrent)

    diagLog := cfg.DiagEventLog  ; PERF: cache config read

    ; DEBUG: Log all async activation conditions
    if (diagLog) {
        komorebicPath := cfg.HasOwnProp("KomorebicExe") ? cfg.KomorebicExe : "(not set)"
        komorebicExists := (komorebicPath != "(not set)" && FileExist(komorebicPath)) ? "yes" : "no"
        curWS := gGUI_CurrentWSName != "" ? gGUI_CurrentWSName : "(unknown)"
        GUI_LogEvent("ACTIVATE_COND: isOnCurrent=" isOnCurrent " wsName='" wsName "' curWS='" curWS "' komorebic='" komorebicPath "' exists=" komorebicExists)
    }

    ; === Cross-workspace activation ===
    if (!isOnCurrent && wsName != "") {
        global gStats_CrossWorkspace
        gStats_CrossWorkspace += 1

        crossMethod := cfg.KomorebiCrossWorkspaceMethod
        if (diagLog)
            GUI_LogEvent("CROSS-WS: method=" crossMethod " hwnd=" hwnd " ws='" wsName "'")

        ; MimicNative: Direct uncloak + activate via COM (like native Alt+Tab)
        ; Komorebi's reconciliation detects focus change and switches workspaces
        if (crossMethod = "MimicNative") {
            ; Returns: 0=failed, 1=uncloaked (need activate), 2=uncloaked+activated via SwitchTo
            uncloakResult := _GUI_UncloakWindow(hwnd)
            if (diagLog)
                GUI_LogEvent("CROSS-WS: MimicNative uncloakResult=" uncloakResult)

            if (uncloakResult = 2) {
                ; Full success - SwitchTo handled activation
                if (diagLog)
                    GUI_LogEvent("CROSS-WS: MimicNative success (SwitchTo)")
                ; Optional settle delay for slower systems
                if (cfg.KomorebiMimicNativeSettleMs > 0)
                    HiSleep(cfg.KomorebiMimicNativeSettleMs)
                _GUI_UpdateLocalMRU(hwnd)
                Profiler.Leave() ; @profile
                return true
            } else if (uncloakResult = 1) {
                ; Uncloaked but SwitchTo failed - use manual activation
                if (diagLog)
                    GUI_LogEvent("CROSS-WS: MimicNative partial (manual activate)")
                if (GUI_RobustActivate(hwnd))
                    _GUI_UpdateLocalMRU(hwnd)
                Profiler.Leave() ; @profile
                return true
            }
            ; uncloakResult = 0: COM failed entirely, fall through to SwitchActivate
            if (diagLog)
                GUI_LogEvent("CROSS-WS: MimicNative failed, falling back to SwitchActivate")
        }

        ; RevealMove: Uncloak window, focus it, then command komorebi to move it back
        ; This makes the window focused BEFORE the workspace switch, avoiding flash
        if (crossMethod = "RevealMove") {
            ; Step 1: Uncloak (we only need uncloaking, not SwitchTo)
            uncloakResult := _GUI_UncloakWindow(hwnd)
            if (diagLog)
                GUI_LogEvent("CROSS-WS: RevealMove uncloakResult=" uncloakResult)

            if (uncloakResult > 0) {
                ; Step 2: Focus the window (makes it the "focused window" for komorebic)
                ; Gate on success — if activation fails, komorebic move would target wrong window
                if (GUI_RobustActivate(hwnd)) {
                    if (diagLog)
                        GUI_LogEvent("CROSS-WS: RevealMove focused window")

                    ; Step 3: Command komorebi to move the focused window to its workspace
                    ; This switches to that workspace WITH our window already focused
                    try {
                        _GUI_KomorebiWorkspaceCmd("MoveToNamedWorkspace", "move-to-named-workspace", wsName)
                    } catch as e {
                        if (diagLog)
                            GUI_LogEvent("CROSS-WS: RevealMove move command failed: " e.Message)
                    }

                    _GUI_UpdateLocalMRU(hwnd)
                } else if (diagLog) {
                    GUI_LogEvent("CROSS-WS: RevealMove activation failed, skipping move")
                }
                Profiler.Leave() ; @profile
                return true
            }
            ; uncloakResult = 0: COM failed, fall through to SwitchActivate
            if (diagLog)
                GUI_LogEvent("CROSS-WS: RevealMove failed (COM), falling back to SwitchActivate")
        }

        ; SwitchActivate: Command komorebi to switch, poll for completion, then activate
        ; This path is used when: config=SwitchActivate OR MimicNative/RevealMove failed
        _GUI_StartSwitchActivate(hwnd, wsName)
        Profiler.Leave() ; @profile
        return true  ; Async path handles its own success/failure
    }

    ; === Same-workspace: SYNC activation (immediate, fast) ===
    ; CRITICAL: Only update MRU on successful activation — prevents phantom MRU
    ; corruption that causes "double failure" on next Alt+Tab
    result := GUI_RobustActivate(hwnd)
    if (result)
        _GUI_UpdateLocalMRU(hwnd)

    ; NOTE: Do NOT request snapshot here - it would overwrite our local MRU update
    ; with stale store data. The store will get the focus update via WinEventHook.

    ; CRITICAL: After activation, keyboard events may have been queued but not processed
    ; Use SetTimer -1 to let message pump run, then resync keyboard state
    SetTimer(_GUI_ResyncKeyboardState, -1)
    Profiler.Leave() ; @profile
    return result
}

; ========================= SWITCH-ACTIVATE METHOD =========================

; Start the SwitchActivate cross-workspace method:
; 1. Command komorebi to switch workspaces
; 2. Start async polling timer to detect completion
; 3. Timer will activate window once switch completes
_GUI_StartSwitchActivate(hwnd, wsName) {
    Profiler.Enter("_GUI_StartSwitchActivate") ; @profile
    global cfg
    global gGUI_Pending
    global gGUI_EventBuffer

    if (cfg.DiagEventLog)
        GUI_LogEvent("SWITCH-ACTIVATE: Starting for hwnd=" hwnd " ws='" wsName "'")

    ; Initialize pending state
    gGUI_Pending.hwnd := hwnd
    gGUI_Pending.wsName := wsName
    gGUI_Pending.deadline := A_TickCount + cfg.AltTabWSPollTimeoutMs
    gGUI_Pending.waitUntil := 0
    gGUI_EventBuffer := []

    ; Create WScript.Shell for async command execution (reuse if exists)
    if (!gGUI_Pending.shell)
        gGUI_Pending.shell := ComObject("WScript.Shell")

    ; Temp file for komorebic query output (PollKomorebic method)
    if (!gGUI_Pending.tempFile)
        gGUI_Pending.tempFile := A_Temp "\tabby_ws_query.txt"

    ; Trigger workspace switch (via socket or komorebic.exe)
    try {
        _GUI_KomorebiWorkspaceCmd("FocusNamedWorkspace", "focus-named-workspace", wsName)
    } catch as e {
        if (cfg.DiagEventLog)
            GUI_LogEvent("SWITCH-ACTIVATE ERROR: " e.Message)
        ; Fall back to direct activation attempt
        if (GUI_RobustActivate(hwnd))
            _GUI_UpdateLocalMRU(hwnd)
        Profiler.Leave() ; @profile
        return
    }

    ; Start polling phase
    Critical "On"
    gGUI_Pending.phase := "polling"
    Critical "Off"

    ; Start async timer
    SetTimer(_GUI_AsyncActivationTick, cfg.AltTabAsyncActivationPollMs)
    if (cfg.DiagEventLog)
        GUI_LogEvent("SWITCH-ACTIVATE: Polling started")
    Profiler.Leave() ; @profile
}

; ========================= ASYNC ACTIVATION TIMER =========================

; Called every 15ms during cross-workspace activation
; Yields control between fires, allowing keyboard hook callbacks to run
_GUI_AsyncActivationTick() {
    global cfg
    global gGUI_Pending
    global gGUI_EventBuffer, TABBY_EV_ALT_DOWN, TABBY_EV_TAB_STEP, TABBY_FLAG_SHIFT
    global gGUI_LiveItems, gGUI_CurrentWSName

    Profiler.Enter("_GUI_AsyncActivationTick") ; @profile
    diagLog := cfg.DiagEventLog  ; PERF: cache config read

    ; RACE FIX: Ensure phase reads and transitions are atomic
    ; Phase can be read by interceptor to decide whether to buffer events
    Critical "On"

    ; Safety: if no pending activation, stop timer
    if (gGUI_Pending.phase = "") {
        SetTimer(_GUI_AsyncActivationTick, 0)
        Critical "Off"
        Profiler.Leave() ; @profile
        return
    }
    ; Read phase into local variable for consistent use throughout function
    phase := gGUI_Pending.phase
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
            if (hasAltDn && hasTab)
                break
        }
        if (hasAltDn && !hasTab) {
            shiftFlag := GetKeyState("Shift", "P") ? TABBY_FLAG_SHIFT : 0
            if (diagLog)
                GUI_LogEvent("ASYNC: detected missed Tab press, synthesizing TAB_STEP")
            gGUI_EventBuffer.Push({ev: TABBY_EV_TAB_STEP, flags: shiftFlag, lParam: 0})
        }
        Critical "Off"
    }

    now := A_TickCount

    ; === PHASE 1: Poll for workspace switch completion ===
    if (phase = "polling") {
        ; Check if deadline exceeded
        if (now > gGUI_Pending.deadline) {
            ; Timeout - do activation anyway
            if (diagLog)
                GUI_LogEvent("ASYNC TIMEOUT: workspace poll deadline exceeded for '" gGUI_Pending.wsName "'")
            ; RACE FIX: Phase transition must be atomic. Re-check phase hasn't been
            ; cleared by GUI_CancelPendingActivation (ESC during this tick).
            Critical "On"
            if (gGUI_Pending.phase = "") {
                Critical "Off"
                Profiler.Leave() ; @profile
                return  ; Cancelled while running — don't resurrect
            }
            gGUI_Pending.phase := "waiting"
            gGUI_Pending.waitUntil := now + cfg.AltTabWorkspaceSwitchSettleMs
            Critical "Off"
            Profiler.Leave() ; @profile
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
            cloakVal := _GUI_IsCloaked(gGUI_Pending.hwnd)
            isCloaked := (cloakVal > 0)
            if (!isCloaked) {
                switchComplete := true
                if (diagLog)
                    GUI_LogEvent("ASYNC POLLCLOAK: window uncloaked, switch complete")
            }
        } else if (confirmMethod = "AwaitDelta") {
            ; AwaitDelta: Watch gGUI_CurrentWSName (updated by heartbeat via direct gWS_Meta read in gui_main)
            ; Zero spawning, zero DllCalls - but depends on heartbeat latency
            if (gGUI_CurrentWSName = gGUI_Pending.wsName) {
                switchComplete := true
                if (diagLog)
                    GUI_LogEvent("ASYNC AWAITDELTA: workspace name matches, switch complete")
            }
        } else {
            ; PollKomorebic (fallback): Poll via cmd.exe spawning
            ; Spawns cmd.exe /c komorebic query focused-workspace-name every tick
            ; Highest CPU but works on multi-monitor setups where PollCloak may not
            try {
                try FileDelete(gGUI_Pending.tempFile)
                queryCmd := 'cmd.exe /c "' cfg.KomorebicExe '" query focused-workspace-name > "' gGUI_Pending.tempFile '"'
                ; Run hidden, DON'T wait (false) - let it run async
                gGUI_Pending.shell.Run(queryCmd, 0, false)
            }

            ; Check if switch completed (file from PREVIOUS tick)
            if (FileExist(gGUI_Pending.tempFile)) {
                try {
                    result := Trim(FileRead(gGUI_Pending.tempFile))
                    if (result = gGUI_Pending.wsName) {
                        switchComplete := true
                        if (diagLog)
                            GUI_LogEvent("ASYNC POLLKOMOREBIC: workspace name matches, switch complete")
                    }
                }
            }
        }

        if (switchComplete) {
            ; Switch complete! Move to waiting phase
            ; RACE FIX: Phase transition must be atomic. Re-check phase hasn't been
            ; cleared by GUI_CancelPendingActivation (ESC during this tick).
            Critical "On"
            if (gGUI_Pending.phase = "") {
                Critical "Off"
                Profiler.Leave() ; @profile
                return  ; Cancelled while running — don't resurrect
            }
            gGUI_Pending.phase := "waiting"
            gGUI_Pending.waitUntil := now + cfg.AltTabWorkspaceSwitchSettleMs
            Critical "Off"
            Profiler.Leave() ; @profile
            return
        }
        Profiler.Leave() ; @profile
        return  ; Keep polling
    }

    ; === PHASE 2: Wait for komorebi's post-switch focus logic ===
    if (phase = "waiting") {
        if (now < gGUI_Pending.waitUntil) {
            Profiler.Leave() ; @profile
            return  ; Keep waiting
        }

        ; Wait complete - do robust activation
        hwnd := gGUI_Pending.hwnd
        if (diagLog)
            GUI_LogEvent("ASYNC COMPLETE: activating hwnd " hwnd " (buf=" gGUI_EventBuffer.Length ")")
        try GUI_RobustActivate(hwnd)

        ; Stop the async timer (unconditional - must run even if activation threw)
        SetTimer(_GUI_AsyncActivationTick, 0)

        ; CRITICAL: Update current workspace name IMMEDIATELY
        ; Don't wait for IPC - we know we just switched to gGUI_Pending.wsName
        ; This ensures buffered Alt+Tab events use correct workspace data
        ; Also fixes stale workspace data when buffered events replay
        if (gGUI_Pending.wsName != "") {
            if (diagLog)
                GUI_LogEvent("ASYNC: updating curWS from '" gGUI_CurrentWSName "' to '" gGUI_Pending.wsName "'")
            ; RACE FIX: Protect workspace name and items iteration from producer timer callbacks
            Critical "On"
            gGUI_CurrentWSName := gGUI_Pending.wsName

            ; isOnCurrentWorkspace flags are already correct on store records —
            ; WL_SetCurrentWorkspace (called by komorebi producer) flips them.
            Critical "Off"
        }

        ; CRITICAL: Update MRU order - move activated window to position 1
        ; Don't wait for IPC - we know we just activated gGUI_Pending.hwnd
        ; This ensures buffered Alt+Tab selects the PREVIOUS window, not the same one
        _GUI_UpdateLocalMRU(gGUI_Pending.hwnd)

        ; CRITICAL: Do NOT clear gGUI_Pending.phase yet!
        ; If we clear it now, any pending Tab_Decide timers from the interceptor
        ; will send events that bypass the buffer, arriving out of order.
        ; Keep the phase set to "flushing" so events continue to be buffered
        ; until _GUI_ProcessEventBuffer completes.
        ; RACE FIX: Phase transition must be atomic. Re-check phase hasn't been
        ; cleared by GUI_CancelPendingActivation (ESC during this tick).
        Critical "On"
        if (gGUI_Pending.phase = "") {
            Critical "Off"
            Profiler.Leave() ; @profile
            return  ; Cancelled while running — don't resurrect
        }
        gGUI_Pending.phase := "flushing"
        Critical "Off"

        ; NOTE: Do NOT request snapshot here - it would overwrite our local MRU update
        ; with stale store data. The store will get the focus update via WinEventHook.

        ; Process any buffered events (user did Alt+Tab during our async activation)
        ; This will clear gGUI_Pending.phase when done
        if (diagLog)
            GUI_LogEvent("ASYNC: scheduling buffer processing")
        SetTimer(_GUI_ProcessEventBuffer, -1)
        Profiler.Leave() ; @profile
        return
    }
    Profiler.Leave() ; @profile
}

; Process buffered events after async activation completes
; Called via SetTimer -1 after async complete, with gGUI_Pending.phase="flushing"
_GUI_ProcessEventBuffer() {
    Profiler.Enter("_GUI_ProcessEventBuffer") ; @profile
    global gGUI_EventBuffer, gGUI_LiveItems, gGUI_Pending, TABBY_EV_ALT_DOWN, TABBY_EV_TAB_STEP, TABBY_EV_ALT_UP, cfg

    diagLog := cfg.DiagEventLog  ; PERF: cache config read

    ; Validate we're in flushing phase - prevents stale timers from processing
    if (gGUI_Pending.phase != "flushing") {
        if (diagLog)
            GUI_LogEvent("BUFFER SKIP: not in flushing phase (phase=" gGUI_Pending.phase ")")
        Profiler.Leave() ; @profile
        return
    }

    if (diagLog)
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
        if (diagLog)
            GUI_LogEvent("BUFFER: empty, resyncing keyboard state")
        _GUI_ResyncKeyboardState()
        Profiler.Leave() ; @profile
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
        if (diagLog)
            GUI_LogEvent("BUFFER: detected lost Tab (ALT_DN+ALT_UP without TAB), synthesizing TAB_STEP")
        events.InsertAt(altDnIdx + 1, {ev: TABBY_EV_TAB_STEP, flags: 0, lParam: 0})
    }

    if (diagLog)
        GUI_LogEvent("BUFFER: processing " events.Length " events now")
    for ev in events {
        GUI_OnInterceptorEvent(ev.ev, ev.flags, ev.lParam)
    }
    if (diagLog)
        GUI_LogEvent("BUFFER: done processing")
    Profiler.Leave() ; @profile
}

; Cancel pending async activation (e.g., on ESC)
GUI_CancelPendingActivation() {
    global gGUI_Pending, gGUI_EventBuffer
    if (gGUI_Pending.phase != "") {
        _GUI_ClearPendingState()
        SetTimer(_GUI_AsyncActivationTick, 0)
        gGUI_EventBuffer := []  ; Clear any buffered events
        GUI_RefreshLiveItems()
    }
}

; Clear all pending activation state (atomic object replacement)
_GUI_ClearPendingState() {
    global gGUI_Pending

    ; Clean up temp file
    try FileDelete(gGUI_Pending.tempFile)

    ; Release COM object to prevent memory leak
    ; In AHK v2, setting to "" releases the COM reference
    gGUI_Pending.shell := ""

    ; Atomic reset — impossible to forget a field
    gGUI_Pending := _GUI_NewPendingState()
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
; Updates: gGUI_LiveItems array order
; NOTE: Callers hold Critical — do NOT call Critical "Off" here (leaks caller's Critical state)
_GUI_UpdateLocalMRU(hwnd) {
    Profiler.Enter("_GUI_UpdateLocalMRU") ; @profile
    Critical "On"  ; Harmless assertion — documents that Critical is required
    global gGUI_LiveItems, gGUI_LiveItemsMap, cfg
    global FR_EV_MRU_UPDATE, gFR_Enabled

    diagLog := cfg.DiagEventLog  ; PERF: cache config read

    ; O(1) miss detection: if hwnd not in Map, skip the O(n) linear scan
    if (!gGUI_LiveItemsMap.Has(hwnd)) {
        if (gFR_Enabled)
            FR_Record(FR_EV_MRU_UPDATE, hwnd, 0)
        if (diagLog)
            GUI_LogEvent("MRU UPDATE: hwnd " hwnd " not in map, skip scan")
        Profiler.Leave() ; @profile
        return false
    }

    ; Get item directly from Map (O(1))
    item := gGUI_LiveItemsMap[hwnd]
    tick := A_TickCount

    ; Find index for move-to-front (still O(n) but with direct object identity check)
    idx := 0
    Loop gGUI_LiveItems.Length {
        if (gGUI_LiveItems[A_Index] == item) {
            idx := A_Index
            break
        }
    }
    if (idx > 1) {
        gGUI_LiveItems.RemoveAt(idx)
        gGUI_LiveItems.InsertAt(1, item)
    }
    if (diagLog)
        GUI_LogEvent("MRU UPDATE: hwnd " hwnd " at pos " idx ", moved to 1")

    ; Keep gWS_Store in sync with local MRU update
    WL_UpdateFields(hwnd, {lastActivatedTick: tick, isFocused: true}, "gui_activate")
    if (gFR_Enabled)
        FR_Record(FR_EV_MRU_UPDATE, hwnd, 1)
    Profiler.Leave() ; @profile
    return true
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

; Release COM objects allocated by _GUI_InitAppViewCollection / _GUI_StartSwitchActivate.
; Called from _GUI_OnExit to keep COM lifecycle in the declaring module.
GUI_ReleaseComObjects() {
    global gGUI_Pending, gGUI_ImmersiveShell, gGUI_AppViewCollection
    gGUI_Pending.shell := ""
    gGUI_ImmersiveShell := ""
    if (gGUI_AppViewCollection)
        ObjRelease(gGUI_AppViewCollection)
    gGUI_AppViewCollection := 0
}

; Check if a window is cloaked via DWM
_GUI_IsCloaked(hwnd) {
    global DWMWA_CLOAKED
    static cloakBuf := Buffer(4, 0)
    hr := DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", DWMWA_CLOAKED, "ptr", cloakBuf.Ptr, "uint", 4, "int")
    if (hr != 0)
        return -1  ; Error
    return NumGet(cloakBuf, 0, "UInt")
}

; Uncloak and activate a window via COM (MimicNative method)
; Uses IApplicationView::SetCloak to uncloak, then IApplicationView::SwitchTo to activate
; Returns: 0 = failed, 1 = uncloaked (need manual activate), 2 = uncloaked + activated via SwitchTo
_GUI_UncloakWindow(hwnd) {
    Profiler.Enter("_GUI_UncloakWindow") ; @profile
    global cfg

    ; Check initial cloak state
    cloakBefore := _GUI_IsCloaked(hwnd)
    if (cfg.DiagEventLog)
        GUI_LogEvent("UNCLOAK: hwnd=" hwnd " cloakBefore=" cloakBefore)

    if (cloakBefore = 0) {
        if (cfg.DiagEventLog)
            GUI_LogEvent("UNCLOAK: Already uncloaked")
        Profiler.Leave() ; @profile
        return 1  ; Already visible, but need manual activate
    }

    ; Use COM interface: SetCloak to uncloak, SwitchTo to activate
    comResult := _GUI_TryComUncloak(hwnd)
    cloakAfter := _GUI_IsCloaked(hwnd)
    if (cfg.DiagEventLog)
        GUI_LogEvent("UNCLOAK: comResult=" comResult " cloakAfter=" cloakAfter)

    if (comResult = 2) {
        Profiler.Leave() ; @profile
        return 2  ; Full success - uncloaked + activated
    } else if (comResult = 1 && cloakAfter = 0) {
        Profiler.Leave() ; @profile
        return 1  ; Uncloaked but SwitchTo failed - need manual activate
    }

    if (cfg.DiagEventLog)
        GUI_LogEvent("UNCLOAK: COM failed")
    Profiler.Leave() ; @profile
    return 0
}

; Try COM-based uncloaking and activation
; Returns: 0 = failed, 1 = uncloak only, 2 = uncloak + SwitchTo succeeded
_GUI_TryComUncloak(hwnd) {
    Profiler.Enter("_GUI_TryComUncloak") ; @profile
    global gGUI_AppViewCollection, cfg

    ; Try to initialize if not already done
    if (!gGUI_AppViewCollection && !_GUI_InitAppViewCollection()) {
        Profiler.Leave() ; @profile
        return 0
    }

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
            Profiler.Leave() ; @profile
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

        if (uncloakOk && switchOk) {
            Profiler.Leave() ; @profile
            return 2  ; Full success
        }
        else if (uncloakOk) {
            Profiler.Leave() ; @profile
            return 1  ; Uncloak worked, SwitchTo failed
        }
        else {
            Profiler.Leave() ; @profile
            return 0  ; Failed
        }
    } catch as e {
        ; Release pView if it was acquired before the exception
        if (pView && viewVtable) {
            releaseView := NumGet(viewVtable, 2 * A_PtrSize, "UPtr")
            DllCall(releaseView, "Ptr", pView)
        }
        if (cfg.DiagEventLog)
            GUI_LogEvent("COM: Exception - " e.Message)
        Profiler.Leave() ; @profile
        return 0
    }
    Profiler.Leave() ; @profile
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
        if (cfg.DiagEventLog) {
            gle := DllCall("GetLastError", "uint")
            GUI_LogEvent("SOCKET: Failed to connect to " pipePath " GLE=" gle " (" Win32ErrorString(gle) ")")
        }
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
        if (cfg.DiagEventLog) {
            gle := DllCall("GetLastError", "uint")
            GUI_LogEvent("SOCKET: Write failed for " cmdType " GLE=" gle " (" Win32ErrorString(gle) ")")
        }
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
    Profiler.Enter("_GUI_KomorebiWorkspaceCmd") ; @profile
    global cfg

    if (cfg.KomorebiUseSocket) {
        if (_GUI_SendKomorebiSocketCmd(socketCmd, wsName)) {
            Profiler.Leave() ; @profile
            return true
        }
        if (cfg.DiagEventLog)
            GUI_LogEvent("SOCKET: " socketCmd " failed, falling back to komorebic.exe")
    }

    ; Fallback: spawn komorebic.exe
    cmd := '"' cfg.KomorebicExe '" ' cliCmd ' "' wsName '"'
    if (cfg.DiagEventLog)
        GUI_LogEvent("KOMOREBIC: Running " cmd)
    ProcessUtils_RunHidden(cmd)
    Profiler.Leave() ; @profile
    return true
}

; ========================= ROBUST WINDOW ACTIVATION =========================

; Robust window activation using komorebi's pattern from windows_api.rs
; SendInput trick → SetWindowPos → SetForegroundWindow
GUI_RobustActivate(hwnd) {
    Profiler.Enter("GUI_RobustActivate") ; @profile
    global SW_RESTORE, HWND_TOP, HWND_TOPMOST, HWND_NOTOPMOST, cfg
    global SWP_NOSIZE, SWP_NOMOVE, SWP_SHOWWINDOW
    global gAnim_HidePending
    global FR_EV_ACTIVATE_RESULT, gFR_Enabled  ; PERF: consolidated — was declared 3× in branches

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
            static input := Buffer(40, 0)  ; PERF: static — zero-init INPUT_MOUSE struct reused
            DllCall("user32\SendInput", "uint", 1, "ptr", input, "int", 40)

            if (gAnim_HidePending) {
                ; During overlay fade-out: use HWND_TOP instead of the TOPMOST/NOTOPMOST
                ; dance.  The dance briefly pushes the target above our TOPMOST overlay,
                ; and if the cross-process SetWindowPos blocks long enough for DWM to
                ; compose a frame (Firefox, heavy apps) or Critical is off (mouse click),
                ; the overlay visibly disappears then reappears.  HWND_TOP brings the
                ; target to the front of the non-topmost band (below our overlay) without
                ; Z-order flicker.  SendInput already bypasses the foreground lock.
                DllCall("user32\SetWindowPos", "ptr", hwnd, "ptr", HWND_TOP
                    , "int", 0, "int", 0, "int", 0, "int", 0
                    , "uint", SWP_NOSIZE | SWP_NOMOVE | SWP_SHOWWINDOW)
            } else {
                ; Normal path (no overlay fade): full komorebi pattern for maximum
                ; activation reliability.  TOPMOST/NOTOPMOST is belt-and-suspenders
                ; with SendInput for edge cases across Windows versions.
                swpFlags := SWP_NOSIZE | SWP_NOMOVE | SWP_SHOWWINDOW
                DllCall("user32\SetWindowPos", "ptr", hwnd, "ptr", HWND_TOPMOST
                    , "int", 0, "int", 0, "int", 0, "int", 0
                    , "uint", swpFlags)
                DllCall("user32\SetWindowPos", "ptr", hwnd, "ptr", HWND_NOTOPMOST
                    , "int", 0, "int", 0, "int", 0, "int", 0
                    , "uint", SWP_NOSIZE | SWP_NOMOVE)
            }

            ; Now SetForegroundWindow should work
            fgResult := DllCall("user32\SetForegroundWindow", "ptr", hwnd)

            ; VERIFY: Don't trust SetForegroundWindow return alone — it can return
            ; non-zero but still fail. Check the actual foreground window.
            actualFg := DllCall("user32\GetForegroundWindow", "ptr")
            if (actualFg = hwnd) {
                if (gFR_Enabled)
                    FR_Record(FR_EV_ACTIVATE_RESULT, hwnd, 1, actualFg)
                Profiler.Leave() ; @profile
                return true
            }

            ; fg=0 is a documented transient state during activation transitions.
            ; Windows returns NULL while the foreground is changing — not a rejection.
            ; Treat as success for state machine; recorder preserves nuance (success=2).
            if (actualFg = 0) {
                if (gFR_Enabled)
                    FR_Record(FR_EV_ACTIVATE_RESULT, hwnd, 2, 0)
                Profiler.Leave() ; @profile
                return true
            }

            if (gFR_Enabled)
                FR_Record(FR_EV_ACTIVATE_RESULT, hwnd, 0, actualFg)
            if (cfg.DiagEventLog)
                GUI_LogEvent("ACTIVATE VERIFY FAILED: wanted=" hwnd " got=" actualFg " sfwResult=" fgResult)
            Profiler.Leave() ; @profile
            return false
        }
        if (gFR_Enabled)
            FR_Record(FR_EV_ACTIVATE_RESULT, hwnd, 0, 0)
        if (cfg.DiagEventLog)
            GUI_LogEvent("ACTIVATE FAIL: window no longer exists, hwnd=" hwnd)
        Profiler.Leave() ; @profile
        return false
    } catch as e {
        if (gFR_Enabled)
            FR_Record(FR_EV_ACTIVATE_RESULT, hwnd, 0, 0)
        if (cfg.DiagEventLog)
            GUI_LogEvent("ACTIVATE ERROR: " e.Message " for hwnd=" hwnd)
        Profiler.Leave() ; @profile
        return false
    }
}
