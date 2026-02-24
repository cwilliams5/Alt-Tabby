#Requires AutoHotkey v2.0
; ============================================================
; STATS ENGINE - Lifetime & session usage statistics
; ============================================================
; Runs in-process within the MainProcess (gui_main.ahk).
; Depends on: cfg (config_loader), STATS_INI_PATH (config_loader)
;
; Public API:
;   Stats_Init()              - Load stats from disk, set up session
;   Stats_FlushToDisk()       - Crash-safe persist to stats.ini (dirty-gated, pump offload)
;   Stats_ForceFlushToDisk()  - Direct write, bypass dirty/state/pump (shutdown path)
;   Stats_UpdatePeakWindows(count) - Update peak window counters
;   Stats_BumpLifetimeStat(key)    - Increment a lifetime counter
;   Stats_Accumulate(obj)     - Accumulate GUI delta counters
;   Stats_GetSnapshot()       - Build combined snapshot for dashboard
; ============================================================

global gStats_Lifetime := Map()   ; key -> integer, loaded from/flushed to stats.ini
global gStats_Session := Map()    ; key -> integer, this session only
global gStats_Dirty := false      ; Set by mutations, checked by flush to skip no-op writes

; Cumulative stat keys - GUI sends deltas for these via stats_update
global STATS_CUMULATIVE_KEYS := [
    "TotalAltTabs", "TotalQuickSwitches", "TotalTabSteps",
    "TotalCancellations", "TotalCrossWorkspace", "TotalWorkspaceToggles"
]

; Lifetime-only stat keys (not accumulated from GUI deltas)
global STATS_LIFETIME_ONLY_KEYS := [
    "TotalRunTimeSec", "TotalSessions",
    "TotalWindowUpdates", "TotalBlacklistSkips",
    "PeakWindowsInSession", "LongestSessionSec"
]

; All lifetime stat keys - derived from above to avoid duplication
global STATS_LIFETIME_KEYS := []
for _, k in STATS_LIFETIME_ONLY_KEYS
    STATS_LIFETIME_KEYS.Push(k)
for _, k in STATS_CUMULATIVE_KEYS
    STATS_LIFETIME_KEYS.Push(k)

; Logging callbacks - set by host process (e.g., gui_main)
global gStats_LogError := 0
global gStats_LogInfo := 0

; Wire logging callbacks (called by host process during init)
Stats_SetCallbacks(logError, logInfo) {
    global gStats_LogError, gStats_LogInfo
    gStats_LogError := logError
    gStats_LogInfo := logInfo
}

; ---------- Internal helpers ----------

_Stats_LogError(msg) {
    global gStats_LogError
    if (gStats_LogError)
        gStats_LogError(msg)
}

_Stats_LogInfo(msg) {
    global gStats_LogInfo
    if (gStats_LogInfo)
        gStats_LogInfo(msg)
}

; ---------- Public API ----------

Stats_Init() {
    global gStats_Lifetime, gStats_Session, STATS_LIFETIME_KEYS, STATS_INI_PATH, cfg
    global gStats_Dirty

    if (!cfg.StatsTrackingEnabled)
        return

    statsPath := STATS_INI_PATH

    ; --- Crash recovery ---
    bakExists := FileExist(statsPath ".bak")
    iniExists := FileExist(statsPath)

    if (bakExists && !iniExists) {
        ; Crash before any writes completed -- .bak is the last known good
        ; Validate .bak is parseable before restoring (guards against truncated disk writes)
        bakValid := false
        try {
            testVal := IniRead(statsPath ".bak", "Lifetime", "TotalSessions", "")
            bakValid := (testVal != "")
        }
        if (bakValid) {
            if (cfg.DiagStoreLog)
                _Stats_LogInfo("stats recovery: bak exists, ini missing — restoring from backup")
            try FileMove(statsPath ".bak", statsPath)
        } else {
            if (cfg.DiagStoreLog)
                _Stats_LogInfo("stats recovery: bak exists but unparseable — starting fresh")
            try FileDelete(statsPath ".bak")
        }
    } else if (bakExists && iniExists) {
        ; Crash during or after write -- check sentinel
        flushStatus := ""
        try flushStatus := IniRead(statsPath, "Lifetime", "_FlushStatus", "")
        if (flushStatus = "complete") {
            ; .ini write finished fully -- discard .bak
            if (cfg.DiagStoreLog)
                _Stats_LogInfo("stats recovery: flush was complete — discarding backup")
            try FileDelete(statsPath ".bak")
        } else {
            ; .ini is partial -- .bak has previous good state
            if (cfg.DiagStoreLog)
                _Stats_LogInfo("stats recovery: partial flush detected — restoring from backup")
            try FileDelete(statsPath)
            try FileMove(statsPath ".bak", statsPath)
        }
    } else if (cfg.DiagStoreLog) {
        if (iniExists)
            _Stats_LogInfo("stats init: clean startup, loading from " statsPath)
        else
            _Stats_LogInfo("stats init: no stats file, starting fresh")
    }

    ; --- Load lifetime stats from disk ---
    for _, key in STATS_LIFETIME_KEYS {
        val := 0
        if (FileExist(statsPath)) {
            try {
                raw := IniRead(statsPath, "Lifetime", key, "0")
                val := Integer(raw)
            } catch as e {
                if (cfg.DiagStoreLog)
                    _Stats_LogInfo("stats parse error for key=" key " raw=" SubStr(raw, 1, 50) ": " e.Message)
            }
        }
        gStats_Lifetime[key] := val
    }

    ; Increment session count
    gStats_Lifetime["TotalSessions"] := gStats_Lifetime.Get("TotalSessions", 0) + 1
    gStats_Dirty := true  ; Ensure first housekeeping flush saves TotalSessions

    ; Session tracking
    gStats_Session["startTick"] := A_TickCount
    gStats_Session["sessionStartTick"] := A_TickCount  ; Never reset — used for session runtime reporting
    gStats_Session["peakWindows"] := 0

    ; Save baseline for session activity reporting (current - baseline = this session)
    gStats_Session["baselineAltTabs"] := gStats_Lifetime.Get("TotalAltTabs", 0)
    gStats_Session["baselineQuickSwitches"] := gStats_Lifetime.Get("TotalQuickSwitches", 0)
    gStats_Session["baselineTabSteps"] := gStats_Lifetime.Get("TotalTabSteps", 0)
    gStats_Session["baselineCancellations"] := gStats_Lifetime.Get("TotalCancellations", 0)
    gStats_Session["baselineCrossWorkspace"] := gStats_Lifetime.Get("TotalCrossWorkspace", 0)
    gStats_Session["baselineWorkspaceToggles"] := gStats_Lifetime.Get("TotalWorkspaceToggles", 0)
    gStats_Session["baselineWindowUpdates"] := gStats_Lifetime.Get("TotalWindowUpdates", 0)
    gStats_Session["baselineBlacklistSkips"] := gStats_Lifetime.Get("TotalBlacklistSkips", 0)
}

Stats_FlushToDisk() {
    global gStats_Lifetime, gStats_Session, STATS_LIFETIME_KEYS, STATS_INI_PATH, cfg
    global gStats_Dirty, gGUI_State

    if (!cfg.StatsTrackingEnabled)
        return
    if (!gStats_Dirty)
        return
    if (gGUI_State = "ALT_PENDING" || gGUI_State = "ACTIVE")
        return  ; Defer to next housekeeping cycle

    statsPath := STATS_INI_PATH

    ; RACE FIX: Wrap in-memory stat mutations in Critical. Stats_FlushToDisk runs from
    ; HeartbeatTick timer and can be interrupted by Stats_Accumulate/Stats_GetSnapshot
    ; which also modify gStats_Lifetime/gStats_Session.
    Critical "On"
    ; Compute run time: existing lifetime + current session
    sessionSec := (A_TickCount - gStats_Session.Get("startTick", A_TickCount)) / 1000
    gStats_Lifetime["TotalRunTimeSec"] := gStats_Lifetime.Get("TotalRunTimeSec", 0) + Round(sessionSec)
    ; Reset session start so we don't double-count on next flush
    gStats_Session["startTick"] := A_TickCount

    ; Update longest session (use total session time, not just segment since last flush)
    totalSessionSec := (A_TickCount - gStats_Session.Get("sessionStartTick", A_TickCount)) / 1000
    if (totalSessionSec > gStats_Lifetime.Get("LongestSessionSec", 0))
        gStats_Lifetime["LongestSessionSec"] := Round(totalSessionSec)

    ; Build complete INI content as a single string (under Critical for consistent snapshot)
    content := "[Lifetime]`n"
    for _, key in STATS_LIFETIME_KEYS
        content .= key "=" gStats_Lifetime.Get(key, 0) "`n"
    content .= "_FlushStatus=complete`n"
    Critical "Off"

    ; Try pump offload first (pipe write ~10-15μs vs 10-75ms of IniWrite loop)
    if (_Stats_TrySendToPump(statsPath, content)) {
        gStats_Dirty := false
        return
    }

    ; Fallback: direct write (pump not connected or send failed)
    _Stats_DirectWrite(statsPath, content)
    gStats_Dirty := false
}

; Force-flush stats directly to disk (bypass dirty flag, state gate, and pump offload).
; Used during shutdown when the pump may be unavailable.
Stats_ForceFlushToDisk() {
    global gStats_Lifetime, gStats_Session, STATS_LIFETIME_KEYS, STATS_INI_PATH, cfg
    global gStats_Dirty

    if (!cfg.StatsTrackingEnabled)
        return

    ; Compute time stats (same as regular flush)
    Critical "On"
    sessionSec := (A_TickCount - gStats_Session.Get("startTick", A_TickCount)) / 1000
    gStats_Lifetime["TotalRunTimeSec"] := gStats_Lifetime.Get("TotalRunTimeSec", 0) + Round(sessionSec)
    gStats_Session["startTick"] := A_TickCount

    totalSessionSec := (A_TickCount - gStats_Session.Get("sessionStartTick", A_TickCount)) / 1000
    if (totalSessionSec > gStats_Lifetime.Get("LongestSessionSec", 0))
        gStats_Lifetime["LongestSessionSec"] := Round(totalSessionSec)

    content := "[Lifetime]`n"
    for _, key in STATS_LIFETIME_KEYS
        content .= key "=" gStats_Lifetime.Get(key, 0) "`n"
    content .= "_FlushStatus=complete`n"
    Critical "Off"

    _Stats_DirectWrite(STATS_INI_PATH, content)
    gStats_Dirty := false
}

; Try to offload stats write to enrichment pump via IPC.
; Returns true if message was sent successfully, false if pump unavailable.
_Stats_TrySendToPump(statsPath, content) {
    global IPC_MSG_STATS_FLUSH
    if (!GUIPump_IsConnected())
        return false
    request := Map("type", IPC_MSG_STATS_FLUSH, "path", statsPath, "content", content)
    requestJson := JSON.Dump(request)
    return GUIPump_SendRaw(requestJson)
}

; Direct file write fallback — single FileAppend instead of 13 IniWrite calls.
; Uses atomic temp+rename pattern for crash safety.
_Stats_DirectWrite(statsPath, content) {
    try {
        ; Backup existing file (crash safety)
        if (FileExist(statsPath))
            try FileCopy(statsPath, statsPath ".bak", true)
        ; Atomic write: write to temp, then rename
        ; UTF-8-RAW = no BOM (BOM breaks IniRead/GetPrivateProfileString)
        tmpPath := statsPath ".tmp"
        try FileDelete(tmpPath)
        FileAppend(content, tmpPath, "UTF-8-RAW")
        FileMove(tmpPath, statsPath, true)
        ; Success — remove backup
        try FileDelete(statsPath ".bak")
    } catch as e {
        _Stats_LogError("stats flush failed: " e.Message)
    }
}

; Update peak window count in session and lifetime stats.
; Called from WL_UpsertWindow/EndScan after adding windows.
; NOTE: Callers hold Critical — do NOT add Critical "Off" here (leaks caller's state).
Stats_UpdatePeakWindows(count) {
    global gStats_Session, gStats_Lifetime, gStats_Dirty
    if (IsObject(gStats_Session) && count > gStats_Session.Get("peakWindows", 0)) {
        gStats_Session["peakWindows"] := count
        if (IsObject(gStats_Lifetime) && count > gStats_Lifetime.Get("PeakWindowsInSession", 0)) {
            gStats_Lifetime["PeakWindowsInSession"] := count
            gStats_Dirty := true
        }
    }
}

; Increment a lifetime stat counter by 1.
; Called from hot paths (e.g., blacklist skip counting) to centralize stats mutation.
Stats_BumpLifetimeStat(key) {
    global gStats_Lifetime, gStats_Dirty
    ; NOTE: += 1 is non-atomic but Critical is not used here because _WS_BumpRev
    ; calls this inside its own Critical section — adding Critical "Off" here would
    ; leak the caller's Critical state. Blacklist callers are unprotected but losing
    ; a rare cosmetic stat increment is acceptable (VERY LOW impact).
    if (IsObject(gStats_Lifetime) && gStats_Lifetime.Has(key)) {
        gStats_Lifetime[key] += 1
        gStats_Dirty := true
    }
}

; Accumulate GUI session stats into lifetime (GUI sends deltas since last send).
; Returns nothing. Called from IPC stats_update handler.
Stats_Accumulate(obj) {
    global gStats_Lifetime, STATS_CUMULATIVE_KEYS, gStats_Dirty
    ; RACE FIX: Protect gStats_Lifetime from concurrent Stats_FlushToDisk (heartbeat timer)
    Critical "On"
    for _, key in STATS_CUMULATIVE_KEYS {
        if (obj.Has(key))
            gStats_Lifetime[key] := gStats_Lifetime.Get(key, 0) + obj[key]
    }
    Critical "Off"
    gStats_Dirty := true
}

; Build response combining lifetime + session stats + derived values.
; Returns a plain object suitable for JSON serialization.
Stats_GetSnapshot() {
    global gStats_Lifetime, gStats_Session
    ; RACE FIX: Protect gStats_Lifetime/gStats_Session reads from Stats_FlushToDisk (heartbeat timer)
    Critical "On"
    snap := {}

    ; Copy all lifetime stats
    for key, val in gStats_Lifetime
        snap.%key% := val

    ; Add current session info (use sessionStartTick which never resets, unlike startTick)
    sessionSec := Round((A_TickCount - gStats_Session.Get("sessionStartTick", A_TickCount)) / 1000)
    snap.SessionRunTimeSec := sessionSec
    snap.SessionPeakWindows := gStats_Session.Get("peakWindows", 0)

    ; Session activity deltas (current lifetime - baseline at launch)
    ltAltTabs := gStats_Lifetime.Get("TotalAltTabs", 0)
    ltQuick := gStats_Lifetime.Get("TotalQuickSwitches", 0)
    ltTabs := gStats_Lifetime.Get("TotalTabSteps", 0)
    ltCancels := gStats_Lifetime.Get("TotalCancellations", 0)
    ltCrossWS := gStats_Lifetime.Get("TotalCrossWorkspace", 0)
    ltWSToggles := gStats_Lifetime.Get("TotalWorkspaceToggles", 0)
    ltWinUpdates := gStats_Lifetime.Get("TotalWindowUpdates", 0)
    ltBLSkips := gStats_Lifetime.Get("TotalBlacklistSkips", 0)
    snap.SessionAltTabs := ltAltTabs - gStats_Session.Get("baselineAltTabs", 0)
    snap.SessionQuickSwitches := ltQuick - gStats_Session.Get("baselineQuickSwitches", 0)
    snap.SessionTabSteps := ltTabs - gStats_Session.Get("baselineTabSteps", 0)
    snap.SessionCancellations := ltCancels - gStats_Session.Get("baselineCancellations", 0)
    snap.SessionCrossWorkspace := ltCrossWS - gStats_Session.Get("baselineCrossWorkspace", 0)
    snap.SessionWorkspaceToggles := ltWSToggles - gStats_Session.Get("baselineWorkspaceToggles", 0)
    snap.SessionWindowUpdates := ltWinUpdates - gStats_Session.Get("baselineWindowUpdates", 0)
    snap.SessionBlacklistSkips := ltBLSkips - gStats_Session.Get("baselineBlacklistSkips", 0)

    ; Derived stats (compute here so dashboard just displays)
    totalRunSec := gStats_Lifetime.Get("TotalRunTimeSec", 0) + sessionSec
    totalActivations := ltAltTabs + ltQuick
    snap.DerivedAvgAltTabsPerHour := (totalRunSec > 0) ? Round(ltAltTabs / (totalRunSec / 3600), 1) : 0
    snap.DerivedQuickSwitchPct := (totalActivations > 0) ? Round(ltQuick / totalActivations * 100, 1) : 0
    snap.DerivedCancelRate := (ltAltTabs + ltCancels > 0) ? Round(ltCancels / (ltAltTabs + ltCancels) * 100, 1) : 0
    snap.DerivedAvgTabsPerSwitch := (ltAltTabs > 0) ? Round(ltTabs / ltAltTabs, 1) : 0
    Critical "Off"

    return snap
}
