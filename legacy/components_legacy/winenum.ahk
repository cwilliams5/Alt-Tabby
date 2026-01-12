#Requires AutoHotkey v2.0
; =============================================================================
; winenum.ahk — fast Z-order enumeration with DWM cloaking info
; - Drives WindowStore sweeps (BeginScan/EndScan) so presence + TTL are consistent
; - Feeds ONLY base window facts to the store (title/class/pid/state/z/visibility)
; - Optional: mirror blacklisted/alt-tab-ineligible rows into store if enabled
; - Optional: fetch process name (off by default; proc_pump should handle it)
; - Adds single/batch enumerate-by-hwnd with hints
; - Provides a registration helper so WindowStore.Ensure() can call back here
; =============================================================================

; ----------------------------- Config toggles -------------------------------

; If true: when a window hits any blacklist or is alt-tab ineligible, still Upsert
; to the store with isBlacklisted=true (and altTabEligible=false). Default OFF.
global WN_RecordBlacklistInStore := false

; If true: fetch process name immediately (cost: OpenProcess + QueryFullProcessImageName)
; Default OFF; we prefer proc_pump to handle this.
global WN_FetchProcessName := false

; If true: apply Alt-Tab eligibility filter (WS_EX_TOOLWINDOW, owner-window, etc.)
; Default TRUE (matches old behavior)
if !IsSet(UseAltTabEligibility)
    global UseAltTabEligibility := true

; ----------------------------- Module state ---------------------------------
global _WN_all := []                 ; legacy return list
global _WN_zCounter := 0
global _WN_shell := 0

; debug buffer + throttle
global _WN_logbuf := ""
global _WN_traceLeft := 0
global _WN_traceDeadline := 0

; ------------------------------ Public API ----------------------------------

; Call once during init so WindowStore.Ensure() can delegate enumerate-by-hwnd.
; Expects WindowStore_SetFetchers({ EnumerateByHwnd: <Func> }) to exist in list.ahk.
WinEnum_RegisterWithStore() {
    try {
        if (IsSet(WindowStore_SetFetchers) && (WindowStore_SetFetchers is Func)) {
            ; Store expects a "ByHwnd" fetcher with (hwndsArray, hintsMap) signature.
            WindowStore_SetFetchers(Map("ByHwnd", WinEnum_Fetch_ByHwnd))
        }
    } catch {
        ; non-fatal
    }
}

; Begin a scan/sweep (wraps WindowStore_BeginSweep with a fresh token).
; Returns the scanId you must pass to EndScan.
WinEnum_BeginScan() {
    ; matches list.ahk -> WindowStore_BeginScan() (no args; returns a token)
    scanId := 0
    try scanId := WindowStore_BeginScan()
    catch {
        ; store may not be loaded yet, keep going
    }
    return scanId
}

; End a scan/sweep (wraps WindowStore_EndSweep) and returns its summary.
WinEnum_EndScan() {
    ; matches list.ahk -> WindowStore_EndScan(graceMs?) (no token needed)
    summary := ""
    try summary := WindowStore_EndScan()
    catch {
        ; ignore
    }
    return summary
}

; Fetcher used by WindowStore.Ensure(): signature (hwndsArray, hintsMap)
; - Ignores hints here (ownership lives with the Ensure() caller).
; - Upserts only base facts with source="winenum".
WinEnum_Fetch_ByHwnd(hwnds, hints := "") {
    if (!IsObject(hwnds))
        hwnds := [hwnds]

    toStore := []
    for _, h in hwnds {
        hwnd := h + 0
        if (!hwnd)
            continue
        rec := _WN_ProbeOne(hwnd)
        if (rec.Has("forStore"))
            toStore.Push(rec.forStore)
    }
    if (toStore.Length) {
        try WindowStore_UpsertWindow(toStore, "winenum")
        catch {
            ; swallow—store may not be ready during early init
        }
    }
}


; Full desktop enumeration.
; - Drives a store sweep (BeginScan/EndScan).
; - Batches Upsert to the store; also returns legacy array for back-compat.
; REPLACE the whole function
WinList_EnumerateAll() {
    global _WN_all, _WN_zCounter, _WN_shell
    global _WN_logbuf, _WN_traceLeft, _WN_traceDeadline
    global WN_RecordBlacklistInStore

    dbg       := (IsSet(DebugBlacklist) && DebugBlacklist)
    maxLines  := IsSet(DebugMaxLinesPerSession) ? DebugMaxLinesPerSession : 200
    maxMillis := IsSet(DebugMaxDurationMs)      ? DebugMaxDurationMs      : 200

    DllCall("LoadLibrary", "str", "dwmapi.dll")
    _WN_shell := DllCall("user32\GetShellWindow", "ptr")
    _WN_zCounter := 0
    _WN_all := []
    toStore := []

    ; start sweep + batch
    WinEnum_BeginScan()
    try WindowStore_BeginBatch()

    ; prepare debug budget
    if (dbg) {
        _WN_logbuf := ""
        _WN_traceLeft := maxLines
        _WN_traceDeadline := A_TickCount + maxMillis
        _WN_Log("=== WinList_EnumerateAll (begin) ===")
    } else {
        _WN_logbuf := ""
        _WN_traceLeft := 0
        _WN_traceDeadline := 0
    }

    enumCb := (hWnd, lParam) => _WN_EnumProc_ForAll(hWnd, &toStore)
    cb := CallbackCreate(enumCb, "Fast", 2)
    DllCall("user32\EnumWindows", "ptr", cb, "ptr", 0, "int")
    CallbackFree(cb)

    ; feed the store in one Upsert batch
    if (toStore.Length) {
        try WindowStore_UpsertWindow(toStore, "winenum")
        catch as e {
            _WN_Log("WindowStore_UpsertWindow(toStore) failed: " e.Message)
        }
    }

    ; end batch + sweep
    try WindowStore_EndBatch()
    summary := WinEnum_EndScan()

    if (dbg) {
        _WN_Log("=== WinList_EnumerateAll (end) ===")
        if (IsObject(summary))
            _WN_Log("hiddenNow=" summary.hiddenNow " tombstoned=" summary.tombstoned " removed=" summary.removed)
        _WN_FlushLog()
    }

    return _WN_all
}

; Single-window probe (accepts hints).
; - If hwnd is eligible/non-blacklisted, Upsert base facts (+hints) and return legacy row.
; - If blacklisted/ineligible, optionally mirror into store (flagged) when WN_RecordBlacklistInStore=true.
; hints: Map of fields to merge (e.g., { workspaceId: "2", workspaceName: "dev" }).
WinList_EnumerateByHwnd(hwnd, hints := "") {
    if (!hwnd)
        return {}
    rec := _WN_ProbeOne(hwnd)

    ; upsert only base facts with winenum source
    if (rec.Has("forStore")) {
        try WindowStore_UpsertWindow([rec.forStore], "winenum")
        catch as e {
            _WN_Log("WindowStore_UpsertWindow([one]) failed: " e.Message)
        }
    }
    return rec.Has("forList") ? rec.forList : {}
}


; Batch variant: input is an array of { hwnd, hints? }.
; Returns an array of legacy rows (like WinList_EnumerateAll()).
WinList_EnumerateByHwndMany(items) {
    if (!IsObject(items) || items.Length = 0)
        return []
    toStore := []
    legacy := []

    try WindowStore_BeginBatch()
    for _, it in items {
        hwnd := 0
        if (IsObject(it) && it.Has("hwnd"))
            hwnd := it.hwnd + 0
        else
            hwnd := it + 0
        if (!hwnd)
            continue

        rec := _WN_ProbeOne(hwnd)
        if (rec.Has("forStore"))
            toStore.Push(rec.forStore)
        if (rec.Has("forList"))
            legacy.Push(rec.forList)
    }

    if (toStore.Length) {
        try WindowStore_UpsertWindow(toStore, "winenum")
        catch as e {
            _WN_Log("WindowStore_UpsertWindow(batch one) failed: " e.Message)
        }
    }
    try WindowStore_EndBatch()
    return legacy
}


; ---------------------------- Enumeration core ------------------------------

_WN_EnumProc_ForAll(hWnd, &toStore) {
    global _WN_all, _WN_zCounter, _WN_shell
    if (hWnd = 0)
        return 1
    if (hWnd = _WN_shell) {
        _WN_zCounter += 1
        return 1
    }
    rec := _WN_ProbeOne(hWnd)
    if (rec.Has("forStore"))
        toStore.Push(rec.forStore)
    if (rec.Has("forList"))
        _WN_all.Push(rec.forList)
    _WN_zCounter += 1
    return 1
}

; Probe one HWND → apply filters and build:
; - forStore: minimal canonical patch for WindowStore (only known fields)
; - forList : legacy overlay record
_WN_ProbeOne(hWnd) {
    global _WN_zCounter, WN_RecordBlacklistInStore, WN_FetchProcessName, UseAltTabEligibility
    global BlacklistTitle, BlacklistClass, BlacklistPair

    out := {}

    cls := _GetClass(hWnd)
    ttl := _GetTitle(hWnd)

    ; HARD FILTER: skip known GDI+ helper windows
    if (_IsGdiPlusHelper(ttl, cls)) {
        _Trace("Skip GDI+ helper", ttl, cls)
        return out
    }

    ; Early blacklist checks
    isBList := false
    if (MatchAny(cls, BlacklistClass)) {
        _Trace("Hit Class list", ttl, cls), isBList := true
    } else if (!ttl) {
        ; Blank title: drop (match old behavior)
        return out
    } else if (MatchAny(ttl, BlacklistTitle)) {
        _Trace("Hit Title list", ttl, cls), isBList := true
    } else if (MatchPairs(ttl, cls, BlacklistPair)) {
        _Trace("Hit Pair list", ttl, cls), isBList := true
    }

    ; Visibility / minimized / cloaked
    isVisible := !!DllCall("user32\IsWindowVisible", "ptr", hWnd, "int")
    isMin     := !!DllCall("user32\IsIconic",        "ptr", hWnd, "int")

    cloakedBuf := Buffer(4, 0)
    hr := DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hWnd, "uint", 14, "ptr", cloakedBuf.Ptr, "uint", 4, "int")
    isCloaked := (hr = 0) && (NumGet(cloakedBuf, 0, "UInt") != 0)

    state := "WorkspaceHidden"
    if (isCloaked)
        state := "OtherWorkspace"
    else if (isMin)
        state := "WorkspaceMinimized"
    else if (isVisible)
        state := "WorkspaceShowing"

    ; Alt-Tab eligibility (if toggled on)
    eligible := _IsAltTabEligible(hWnd, isVisible, isMin, isCloaked)
    if (UseAltTabEligibility && !eligible) {
        _Trace("Ineligible (Alt-Tab rules)", ttl, cls)
        if (WN_RecordBlacklistInStore) {
            pid := _GetPid(hWnd)
            ; prefer letting proc_pump fill processName later
            out.forStore := _WN_MakeStorePatch(hWnd, pid, cls, ttl, state, _WN_zCounter
                , isVisible, isMin, true, false)
        }
        return out
    }

    ; If blacklisted: either mirror to store (flagged) or drop
    if (isBList) {
        if (WN_RecordBlacklistInStore) {
            pid := _GetPid(hWnd)
            out.forStore := _WN_MakeStorePatch(hWnd, pid, cls, ttl, state, _WN_zCounter
                , isVisible, isMin, true, false)
        }
        return out
    }

    ; Eligible path
    pid := _GetPid(hWnd)

    ; Store patch (only fields recognized by WindowStore)
    patch := _WN_MakeStorePatch(hWnd, pid, cls, ttl, state, _WN_zCounter
        , isVisible, isMin, false, true)

    ; (Optionally attach processName for immediate UI—discouraged by default)
    if (WN_FetchProcessName && pid) {
        pname := _GetProcessName(pid)
        if (pname != "")
            patch.processName := pname
    }

    out.forStore := patch
    out.forList  := { Hwnd: hWnd, Title: ttl, Class: cls, Pid: pid, State: state, ZOrder: _WN_zCounter }
    return out
}

; Build a WindowStore patch with only known fields (store will normalize titles).
_WN_MakeStorePatch(hWnd, pid, cls, ttl, state, zOrder
    , isVisible, isMinimized, isBlacklisted, presentNow) {
    return {
        hwnd: hWnd,
        pid: pid,
        class: cls,
        title: ttl,
        state: state,
        zOrder: zOrder,
        isVisible: isVisible,
        isMinimized: isMinimized,
        isBlacklisted: isBlacklisted,
        ; present/lastSeen are handled by sweep + Upsert in the store;
        ; we still pass some friendly hints the store ignores gracefully:
        presentNow: presentNow,
        lastSeenTick: A_TickCount,
        source: "winenum"
    }
}

; ------------------------------ Helpers -------------------------------------

_GetTitle(hWnd) {
    buf := Buffer(512*2, 0)
    DllCall("user32\GetWindowTextW", "ptr", hWnd, "ptr", buf.Ptr, "int", 512, "int")
    s := StrGet(buf.Ptr, "UTF-16")
    return Trim(RegExReplace(s, "[\r\n\t]+", " "))
}

_GetClass(hWnd) {
    buf := Buffer(256*2, 0)
    DllCall("user32\GetClassNameW", "ptr", hWnd, "ptr", buf.Ptr, "int", 256, "int")
    return StrGet(buf.Ptr, "UTF-16")
}

_GetPid(hWnd) {
    pidBuf := Buffer(4, 0)
    DllCall("user32\GetWindowThreadProcessId", "ptr", hWnd, "ptr", pidBuf.Ptr, "uint")
    return NumGet(pidBuf, 0, "UInt")
}

_GetProcessName(pid) {
    if (!pid)
        return ""
    PROCESS_QUERY_LIMITED_INFORMATION := 0x1000
    hProc := DllCall("kernel32\OpenProcess","uint",PROCESS_QUERY_LIMITED_INFORMATION,"int",0,"uint",pid,"ptr")
    if (!hProc)
        return ""
    buf := Buffer(32767 * 2, 0), sz := 32767
    ok := DllCall("kernel32\QueryFullProcessImageNameW","ptr",hProc,"uint",0,"ptr",buf.Ptr,"uint*",sz,"int")
    DllCall("kernel32\CloseHandle","ptr",hProc)
    if (!ok)
        return ""
    full := StrGet(buf.Ptr, "UTF-16")
    SplitPath(full, &nameOnly)
    return nameOnly
}

_IsAltTabEligible(hWnd, isVisible, isMin, isCloaked) {
    ex := DllCall("user32\GetWindowLongPtrW", "ptr", hWnd, "int", -20, "ptr")
    WS_EX_TOOLWINDOW := 0x00000080
    WS_EX_APPWINDOW  := 0x00040000
    isTool := (ex & WS_EX_TOOLWINDOW) != 0
    isApp  := (ex & WS_EX_APPWINDOW)  != 0
    owner := DllCall("user32\GetWindow", "ptr", hWnd, "uint", 4, "ptr") ; GW_OWNER
    if (isTool)
        return false
    if !(owner = 0 || isApp)
        return false
    if !(isVisible || isMin || isCloaked)
        return false
    return true
}

; ---------- debug helpers (use your existing Normalize/Match) ----------------

_IsGdiPlusHelper(ttl, cls) {
    ttlN := NormalizeMatchText(ttl)
    clsN := NormalizeMatchText(cls)
    if (clsN != "GDI+Hook Window Class")
        return false
    return RegExMatch(ttlN, "^GDI\+Window \([^)]+\)$")
}

_Trace(tag, ttl, cls) {
    global _WN_traceLeft, _WN_traceDeadline
    dbg := (IsSet(DebugBlacklist) && DebugBlacklist)
    if !dbg
        return
    if (_WN_traceLeft <= 0 || (_WN_traceDeadline && A_TickCount > _WN_traceDeadline))
        return
    _WN_traceLeft -= 3
    _WN_Log("[" tag "]")
    _WN_Log("  Title: " ttl)
    _WN_Log("  Class: " cls)
}

_WN_Log(line) {
    global _WN_logbuf
    ts := FormatTime(, "yyyy-MM-dd HH:mm:ss.fff")
    _WN_logbuf .= ts "  " line "`r`n"
}

_WN_GetLogPath() {
    if (IsSet(DebugLogPath) && DebugLogPath)
        return DebugLogPath
    return A_ScriptDir "\tabby_debug.log"
}

_WN_FlushLog() {
    global _WN_logbuf
    if (_WN_logbuf = "")
        return
    path := _WN_GetLogPath()
    SplitPath path, , &dir
    if (dir != "")
        try DirCreate(dir)
    ok := false
    try {
        FileAppend(_WN_logbuf, path, "UTF-8")
        ok := true
    } catch {
        try {
            FileAppend(_WN_logbuf, A_Temp "\tabby_debug.log", "UTF-8")
            ok := true
        } catch {
            ; give up
        }
    }
    _WN_logbuf := ""
}
