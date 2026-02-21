#Requires AutoHotkey v2.0
; ============================================================
; STATS ENGINE - Lifetime & session usage statistics
; ============================================================
; Runs in-process within the MainProcess (gui_main.ahk).
; Depends on: cfg (config_loader), STATS_INI_PATH (config_loader)
;
; Public API:
;   Stats_Init()              - Load stats from disk, set up session
;   Stats_FlushToDisk()       - Crash-safe persist to stats.ini
;   Stats_UpdatePeakWindows(count) - Update peak window counters
;   Stats_BumpLifetimeStat(key)    - Increment a lifetime counter
;   Stats_Accumulate(obj)     - Accumulate GUI delta counters
;   Stats_GetSnapshot()       - Build combined snapshot for dashboard
; ============================================================

global gStats_Lifetime := Map()   ; key -> integer, loaded from/flushed to stats.ini
global gStats_Session := Map()    ; key -> integer, this session only

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

    if (!cfg.StatsTrackingEnabled)
        return

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
    Critical "Off"

    ; File I/O below runs outside Critical (safe: TotalRunTimeSec/LongestSessionSec only written here)

    ; Crash protection: backup existing file
    if (FileExist(statsPath))
        try FileCopy(statsPath, statsPath ".bak", true)

    ; Remove sentinel from previous flush (will be re-written as last key)
    try IniDelete(statsPath, "Lifetime", "_FlushStatus")

    ; Write all stats
    try {
        for _, key in STATS_LIFETIME_KEYS {
            IniWrite(gStats_Lifetime.Get(key, 0), statsPath, "Lifetime", key)
        }

        ; Sentinel: MUST be last write
        IniWrite("complete", statsPath, "Lifetime", "_FlushStatus")

        ; Success -- remove backup
        try FileDelete(statsPath ".bak")
    } catch as e {
        _Stats_LogError("stats flush failed: " e.Message)
    }
}

; Update peak window count in session and lifetime stats.
; Called from WL_UpsertWindow/EndScan after adding windows.
; NOTE: Callers hold Critical — do NOT add Critical "Off" here (leaks caller's state).
Stats_UpdatePeakWindows(count) {
    global gStats_Session, gStats_Lifetime
    if (IsObject(gStats_Session) && count > gStats_Session.Get("peakWindows", 0)) {
        gStats_Session["peakWindows"] := count
        if (IsObject(gStats_Lifetime) && count > gStats_Lifetime.Get("PeakWindowsInSession", 0))
            gStats_Lifetime["PeakWindowsInSession"] := count
    }
}

; Increment a lifetime stat counter by 1.
; Called from hot paths (e.g., blacklist skip counting) to centralize stats mutation.
Stats_BumpLifetimeStat(key) {
    global gStats_Lifetime
    ; NOTE: += 1 is non-atomic but Critical is not used here because _WS_BumpRev
    ; calls this inside its own Critical section — adding Critical "Off" here would
    ; leak the caller's Critical state. Blacklist callers are unprotected but losing
    ; a rare cosmetic stat increment is acceptable (VERY LOW impact).
    if (IsObject(gStats_Lifetime) && gStats_Lifetime.Has(key))
        gStats_Lifetime[key] += 1
}

; Accumulate GUI session stats into lifetime (GUI sends deltas since last send).
; Returns nothing. Called from IPC stats_update handler.
Stats_Accumulate(obj) {
    global gStats_Lifetime, STATS_CUMULATIVE_KEYS
    ; RACE FIX: Protect gStats_Lifetime from concurrent Stats_FlushToDisk (heartbeat timer)
    Critical "On"
    for _, key in STATS_CUMULATIVE_KEYS {
        if (obj.Has(key))
            gStats_Lifetime[key] := gStats_Lifetime.Get(key, 0) + obj[key]
    }
    Critical "Off"
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
    snap.SessionAltTabs := gStats_Lifetime.Get("TotalAltTabs", 0) - gStats_Session.Get("baselineAltTabs", 0)
    snap.SessionQuickSwitches := gStats_Lifetime.Get("TotalQuickSwitches", 0) - gStats_Session.Get("baselineQuickSwitches", 0)
    snap.SessionTabSteps := gStats_Lifetime.Get("TotalTabSteps", 0) - gStats_Session.Get("baselineTabSteps", 0)
    snap.SessionCancellations := gStats_Lifetime.Get("TotalCancellations", 0) - gStats_Session.Get("baselineCancellations", 0)
    snap.SessionCrossWorkspace := gStats_Lifetime.Get("TotalCrossWorkspace", 0) - gStats_Session.Get("baselineCrossWorkspace", 0)
    snap.SessionWorkspaceToggles := gStats_Lifetime.Get("TotalWorkspaceToggles", 0) - gStats_Session.Get("baselineWorkspaceToggles", 0)
    snap.SessionWindowUpdates := gStats_Lifetime.Get("TotalWindowUpdates", 0) - gStats_Session.Get("baselineWindowUpdates", 0)
    snap.SessionBlacklistSkips := gStats_Lifetime.Get("TotalBlacklistSkips", 0) - gStats_Session.Get("baselineBlacklistSkips", 0)

    ; Derived stats (compute here so dashboard just displays)
    totalRunSec := gStats_Lifetime.Get("TotalRunTimeSec", 0) + sessionSec
    totalAltTabs := gStats_Lifetime.Get("TotalAltTabs", 0)
    totalQuick := gStats_Lifetime.Get("TotalQuickSwitches", 0)
    totalCancels := gStats_Lifetime.Get("TotalCancellations", 0)
    totalTabs := gStats_Lifetime.Get("TotalTabSteps", 0)
    totalActivations := totalAltTabs + totalQuick

    snap.DerivedAvgAltTabsPerHour := (totalRunSec > 0) ? Round(totalAltTabs / (totalRunSec / 3600), 1) : 0
    snap.DerivedQuickSwitchPct := (totalActivations > 0) ? Round(totalQuick / totalActivations * 100, 1) : 0
    snap.DerivedCancelRate := (totalAltTabs + totalCancels > 0) ? Round(totalCancels / (totalAltTabs + totalCancels) * 100, 1) : 0
    snap.DerivedAvgTabsPerSwitch := (totalAltTabs > 0) ? Round(totalTabs / totalAltTabs, 1) : 0
    Critical "Off"

    return snap
}
