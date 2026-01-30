#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Expected: file is included after blacklist.ahk

; WindowStore (v1) - minimal core for IPC + viewer.

global gWS_Store := Map()
global gWS_Rev := 0
global gWS_ScanId := 0
global gWS_Config := Map()
global gWS_Meta := Map()

; Diagnostic: track what's causing rev bumps
global gWS_DiagChurn := Map()  ; field -> count of changes
global gWS_DiagSource := Map() ; source -> count of rev bumps

; Work queues for pumps
global gWS_IconQueue := []         ; hwnds needing icons
global gWS_PidQueue := []          ; pids needing process info
global gWS_ZQueue := []            ; hwnds needing Z-order (triggers winenum pump)
global gWS_IconQueueSet := Map()   ; fast lookup for dedup
global gWS_PidQueueSet := Map()    ; fast lookup for dedup
global gWS_ZQueueSet := Map()      ; fast lookup for dedup

; Caches
global gWS_ExeIconCache := Map()   ; exe path -> HICON (master copy)
global gWS_ProcNameCache := Map()  ; pid -> process name

gWS_Config["MissingTTLms"] := 1200  ; Default, overridden from cfg in WindowStore_Init()
gWS_Meta["currentWSId"] := ""
gWS_Meta["currentWSName"] := ""

; Safely snapshot Map keys for iteration (prevents modification during iteration)
; Returns an Array of keys. Caller can iterate safely after Critical section ends.
_WS_SnapshotMapKeys(mapObj) {
    Critical "On"
    keys := []
    for k, _ in mapObj
        keys.Push(k)
    Critical "Off"
    return keys
}

WindowStore_Init(config := 0) {
    global gWS_Config, cfg
    if IsObject(config) {
        for k, v in config
            gWS_Config[k] := v
    }
    ; Load TTL from config if available (ConfigLoader_Init sets cfg.WinEnumMissingWindowTTLMs)
    if (IsObject(cfg) && cfg.HasOwnProp("WinEnumMissingWindowTTLMs"))
        gWS_Config["MissingTTLms"] := cfg.WinEnumMissingWindowTTLMs
}

WindowStore_BeginScan() {
    global gWS_ScanId
    if (gWS_ScanId = 0x7FFFFFFF)
        gWS_ScanId := 0
    gWS_ScanId += 1
    return gWS_ScanId
}

WindowStore_EndScan(graceMs := "") {
    global gWS_Store, gWS_ScanId, gWS_Config, gWS_Rev
    now := A_TickCount
    ttl := (graceMs != "" ? graceMs + 0 : gWS_Config["MissingTTLms"] + 0)
    removed := 0
    changed := false

    ; RACE FIX: Snapshot keys to prevent iteration-during-modification
    hwnds := _WS_SnapshotMapKeys(gWS_Store)

    for _, hwnd in hwnds {
        if (!gWS_Store.Has(hwnd))
            continue  ; May have been removed by another producer
        rec := gWS_Store[hwnd]
        if (rec.lastSeenScanId != gWS_ScanId) {
            ; Skip windows that have workspace data from komorebi
            ; These are "present" from komorebi's perspective even if winenum doesn't see them
            if (rec.HasOwnProp("workspaceName") && rec.workspaceName != "") {
                ; Keep komorebi-managed windows present, preserve their Z value
                ; (Z reflects actual Windows Z-order which matters for alt-tab behavior)
                rec.lastSeenScanId := gWS_ScanId
                rec.presentNow := true
                rec.present := true
                continue
            }
            if (rec.presentNow) {
                rec.presentNow := false
                rec.present := false
                rec.missingSinceTick := now
                changed := true
            } else if (rec.missingSinceTick && (now - rec.missingSinceTick) >= ttl) {
                ; Verify window is actually gone before removing
                if (!DllCall("user32\IsWindow", "ptr", hwnd, "int")) {
                    ; Clean up icon pump tracking state before deleting (prevents HICON leak)
                    try IconPump_CleanupWindow(hwnd)
                    gWS_Store.Delete(hwnd)
                    removed += 1
                    changed := true
                } else {
                    ; Window still exists - reset presence, winenum will find it next scan
                    rec.presentNow := true
                    rec.present := true
                    rec.missingSinceTick := 0
                }
            }
        }
    }
    if (changed) {
        _WS_BumpRev("EndScan")
    }
    return { removed: removed, rev: gWS_Rev }
}

WindowStore_UpsertWindow(records, source := "") {
    global gWS_Store, gWS_Rev, gWS_ScanId, gWS_DiagChurn
    if (!IsObject(records) || !(records is Array))
        return { added: 0, updated: 0, rev: gWS_Rev }
    added := 0
    updated := 0
    for _, rec in records {
        if (!IsObject(rec))
            continue
        hwnd := rec.Has("hwnd") ? (rec["hwnd"] + 0) : 0
        if (!hwnd)
            continue
        ; RACE FIX: Wrap check-then-insert in Critical to prevent multiple producers
        ; from racing on timer/hotkey interruption
        Critical "On"
        isNew := !gWS_Store.Has(hwnd)
        if (isNew) {
            gWS_Store[hwnd] := _WS_NewRecord(hwnd)
            added += 1
        }
        row := gWS_Store[hwnd]
        Critical "Off"

        ; If window has komorebi workspace data, don't let winenum overwrite state/isCloaked
        ; Komorebi is authoritative for workspace state
        hasKomorebiWs := row.HasOwnProp("workspaceName") && row.workspaceName != ""

        ; Track if any field actually changed
        rowChanged := false
        if (rec is Map) {
            for k, v in rec {
                ; Preserve komorebi workspace state if winenum tries to overwrite
                if (hasKomorebiWs && (k = "isCloaked" || k = "isOnCurrentWorkspace"))
                    continue
                ; Only update if value differs
                if (!row.HasOwnProp(k) || row.%k% != v) {
                    ; Diagnostic: track which fields trigger changes (skip for new records)
                    ; Use Critical to prevent race conditions on counter increment
                    if (!isNew) {
                        Critical "On"
                        gWS_DiagChurn[k] := (gWS_DiagChurn.Has(k) ? gWS_DiagChurn[k] : 0) + 1
                        Critical "Off"
                    }
                    row.%k% := v
                    rowChanged := true
                }
            }
        } else {
            continue
        }
        ; Update presence flags - check for changes
        if (!row.present) {
            row.present := true
            rowChanged := true
        }
        if (!row.presentNow) {
            row.presentNow := true
            rowChanged := true
        }
        ; Always update scan tracking (these don't trigger rev bump)
        row.lastSeenScanId := gWS_ScanId
        row.lastSeenTick := A_TickCount

        if (rowChanged)
            updated += 1

        ; Enqueue for enrichment if missing data
        _WS_EnqueueIfNeeded(row)
    }
    if (added || updated) {
        _WS_BumpRev("UpsertWindow")
    }
    return { added: added, updated: updated, rev: gWS_Rev }
}

; Fields that are internal tracking and should not bump rev when changed
global gWS_InternalFields := Map("iconCooldownUntilTick", true, "lastSeenScanId", true, "lastSeenTick", true, "missingSinceTick", true, "iconGaveUp", true, "iconMethod", true, "iconLastRefreshTick", true)

WindowStore_UpdateFields(hwnd, patch, source := "") {
    global gWS_Store, gWS_Rev, gWS_InternalFields
    hwnd := hwnd + 0
    if (!gWS_Store.Has(hwnd))
        return { changed: false, exists: false, rev: gWS_Rev }
    row := gWS_Store[hwnd]
    changed := false
    ; Handle both Map and plain object patches
    if (patch is Map) {
        for k, v in patch {
            if (!row.HasOwnProp(k) || row.%k% != v) {
                row.%k% := v
                ; Only count as "changed" if it's not an internal tracking field
                if (!gWS_InternalFields.Has(k))
                    changed := true
            }
        }
    } else if (IsObject(patch)) {
        for k in patch.OwnProps() {
            v := patch.%k%
            if (!row.HasOwnProp(k) || row.%k% != v) {
                row.%k% := v
                if (!gWS_InternalFields.Has(k))
                    changed := true
            }
        }
    }
    if (changed) {
        _WS_BumpRev("UpdateFields:" . source)
    }
    return { changed: changed, exists: true, rev: gWS_Rev }
}

WindowStore_RemoveWindow(hwnds, forceRemove := false) {
    global gWS_Store, gWS_Rev
    removed := 0
    for _, h in hwnds {
        hwnd := h + 0
        if (!gWS_Store.Has(hwnd))
            continue
        ; Verify window is actually gone before removing (unless forced)
        if (!forceRemove && DllCall("user32\IsWindow", "ptr", hwnd, "int"))
            continue  ; Window still exists, don't remove
        ; Clean up icon pump tracking state BEFORE deleting (destroys HICON, prevents leak)
        try IconPump_CleanupWindow(hwnd)
        gWS_Store.Delete(hwnd)
        removed += 1
    }
    if (removed) {
        _WS_BumpRev("RemoveWindow")
    }
    return { removed: removed, rev: gWS_Rev }
}

; ============================================================
; Existence Validation - Lightweight zombie detection
; ============================================================
; Iterates existing store entries and removes any that:
;   1. No longer exist (IsWindow returns false) - destroyed windows
;   2. Still exist but no longer eligible (IsWindowEligible returns false) - ghost windows
; This is O(n) where n is typically 10-30 windows - much lighter than full EnumWindows.
; Catches edge cases: process crashes without clean DESTROY events, remote desktop
; disconnections, windows that die during debounce period, and apps that REUSE HWNDs
; for hidden windows (like Outlook message windows).

WindowStore_ValidateExistence() {
    global gWS_Store, gWS_Rev

    ; RACE FIX: Snapshot keys to prevent iteration-during-modification
    hwnds := _WS_SnapshotMapKeys(gWS_Store)

    toRemove := []
    for _, hwnd in hwnds {
        if (!gWS_Store.Has(hwnd))
            continue  ; May have been removed by another producer

        ; Check 1: IsWindow returns false for truly destroyed windows
        if (!DllCall("user32\IsWindow", "ptr", hwnd, "int")) {
            toRemove.Push(hwnd)
            continue
        }

        ; Check 2: Window exists but may no longer be eligible (ghost window)
        ; This catches apps like Outlook that REUSE HWNDs - window becomes hidden/cloaked
        ; but HWND still exists. Without this check, ghost windows persist forever.
        ;
        ; SPECIAL CASE: Komorebi-managed windows on OTHER workspaces are cloaked but valid.
        ; We need to distinguish between:
        ;   A) Window on other workspace (cloaked by komorebi) → keep it
        ;   B) Ghost window (not visible, not cloaked) → remove it
        ;
        ; The key insight: komorebi CLOAKS windows to hide them. If a window is
        ; neither visible NOR cloaked, it's a ghost (like Outlook reused HWNDs).
        ; Windows native Alt-Tab uses this same logic.
        rec := gWS_Store[hwnd]

        ; Quick visibility check - if visible, definitely keep
        isVisible := DllCall("user32\IsWindowVisible", "ptr", hwnd, "int") != 0
        if (isVisible)
            continue

        ; Check DWM cloaking
        static cloakedBuf := Buffer(4, 0)  ; static: reused per-iteration, repopulated by DllCall
        hr := DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", 14, "ptr", cloakedBuf.Ptr, "uint", 4, "int")
        isCloaked := (hr = 0) && (NumGet(cloakedBuf, 0, "UInt") != 0)

        ; If cloaked, it's likely on another workspace - keep it
        if (isCloaked)
            continue

        ; Check if minimized
        isMin := DllCall("user32\IsIconic", "ptr", hwnd, "int") != 0
        if (isMin)
            continue

        ; Window is not visible, not cloaked, not minimized → it's a ghost
        ; This matches Windows native Alt-Tab behavior
        toRemove.Push(hwnd)
    }

    if (toRemove.Length = 0)
        return { removed: 0, rev: gWS_Rev }

    ; RACE FIX: Wrap deletes + rev bump in Critical to prevent IPC requests
    ; from seeing inconsistent state (deleted entries with stale rev)
    Critical "On"
    removed := 0
    for _, hwnd in toRemove {
        ; Clean up icon pump tracking state BEFORE deleting (destroys HICON, prevents leak)
        try IconPump_CleanupWindow(hwnd)
        gWS_Store.Delete(hwnd)
        removed += 1
    }

    if (removed > 0) {
        _WS_BumpRev("ValidateExistence")
    }
    Critical "Off"

    return { removed: removed, rev: gWS_Rev }
}

; Purge all windows from store that match the current blacklist
; Called after blacklist reload to remove newly-blacklisted windows
WindowStore_PurgeBlacklisted() {
    global gWS_Store, gWS_Rev
    removed := 0
    toRemove := []

    ; RACE FIX: Snapshot keys to prevent iteration-during-modification
    hwnds := _WS_SnapshotMapKeys(gWS_Store)

    ; Collect hwnds that match blacklist
    for _, hwnd in hwnds {
        if (!gWS_Store.Has(hwnd))
            continue  ; May have been removed by another producer
        rec := gWS_Store[hwnd]
        title := rec.HasOwnProp("title") ? rec.title : ""
        class := rec.HasOwnProp("class") ? rec.class : ""
        if (Blacklist_IsMatch(title, class)) {
            toRemove.Push(hwnd)
        }
    }

    ; Remove them
    for _, hwnd in toRemove {
        ; Clean up icon pump tracking state before deleting (prevents HICON leak)
        try IconPump_CleanupWindow(hwnd)
        gWS_Store.Delete(hwnd)
        removed += 1
    }

    if (removed) {
        _WS_BumpRev("PurgeBlacklisted")
    }

    return { removed: removed, rev: gWS_Rev }
}

WindowStore_GetRev() {
    global gWS_Rev
    return gWS_Rev
}

; Diagnostic: get and reset churn stats
; RACE FIX: Wrap in Critical - iteration + reset must be atomic
; (_WS_BumpRev modifies gWS_DiagSource with its own Critical section)
WindowStore_GetChurnDiag(reset := true) {
    global gWS_DiagChurn, gWS_DiagSource
    Critical "On"
    result := Map()
    result["fields"] := Map()
    result["sources"] := Map()
    for k, v in gWS_DiagChurn
        result["fields"][k] := v
    for k, v in gWS_DiagSource
        result["sources"][k] := v
    if (reset) {
        gWS_DiagChurn := Map()
        gWS_DiagSource := Map()
    }
    Critical "Off"
    return result
}

; Diagnostic: record a rev bump from a source
_WS_DiagBump(source) {
    global gWS_DiagSource
    gWS_DiagSource[source] := (gWS_DiagSource.Has(source) ? gWS_DiagSource[source] : 0) + 1
}

; Atomic revision bump - prevents race conditions when multiple producers bump rev
; Wraps increment in Critical to prevent interruption by timers/hotkeys
_WS_BumpRev(source) {
    Critical "On"
    global gWS_Rev
    gWS_Rev += 1
    _WS_DiagBump(source)
    Critical "Off"
}

WindowStore_GetByHwnd(hwnd) {
    global gWS_Store
    hwnd := hwnd + 0
    return gWS_Store.Has(hwnd) ? gWS_Store[hwnd] : ""
}

WindowStore_SetCurrentWorkspace(id, name := "") {
    global gWS_Meta, gWS_Rev, gWS_Store
    ; Always update meta (lightweight, no rev bump)
    gWS_Meta["currentWSId"] := id

    ; Only recalculate window state if workspace NAME changed
    ; ID is metadata only — GUI cares about name for filtering
    if (gWS_Meta["currentWSName"] = name)
        return

    gWS_Meta["currentWSName"] := name

    ; RACE FIX: Wrap iteration in Critical to prevent timer/hotkey interruption
    Critical "On"
    ; Update isOnCurrentWorkspace for all windows based on new workspace
    ; Unmanaged windows (empty workspaceName) float across all workspaces, treat as "on current"
    anyFlipped := false
    for hwnd, rec in gWS_Store {
        newIsOnCurrent := (rec.workspaceName = name) || (rec.workspaceName = "")
        if (rec.isOnCurrentWorkspace != newIsOnCurrent) {
            rec.isOnCurrentWorkspace := newIsOnCurrent
            anyFlipped := true
        }
    }
    Critical "Off"
    ; Only bump rev if at least one window's state actually changed
    if (anyFlipped)
        _WS_BumpRev("SetCurrentWorkspace")
}

WindowStore_GetCurrentWorkspace() {
    global gWS_Meta
    return { id: gWS_Meta["currentWSId"], name: gWS_Meta["currentWSName"] }
}

WindowStore_GetProjection(opts := 0) {
    global gWS_Store, gWS_Meta
    sort := _WS_GetOpt(opts, "sort", "MRU")
    currentOnly := _WS_GetOpt(opts, "currentWorkspaceOnly", false)
    includeMin := _WS_GetOpt(opts, "includeMinimized", true)
    includeCloaked := _WS_GetOpt(opts, "includeCloaked", false)
    columns := _WS_GetOpt(opts, "columns", "items")

    ; NOTE: Blacklist filtering happens at producer level (winenum, winevent, komorebi)
    ; so blacklisted windows never enter the store. No need to filter here.

    ; RACE FIX: Short Critical section around iteration to prevent concurrent modifications
    Critical "On"
    items := []
    for _, rec in gWS_Store {
        if (!rec.present)
            continue  ; lint-ignore: critical-section
        if (currentOnly && !rec.isOnCurrentWorkspace)
            continue  ; lint-ignore: critical-section
        if (!includeMin && rec.isMinimized)
            continue  ; lint-ignore: critical-section
        if (!includeCloaked && rec.isCloaked)
            continue  ; lint-ignore: critical-section
        items.Push(rec)
    }
    Critical "Off"

    if (sort = "Z") {
        _WS_TrySort(items, _WS_CmpZ)
    } else if (sort = "Title") {
        _WS_TrySort(items, _WS_CmpTitle)
    } else if (sort = "Pid") {
        _WS_TrySort(items, _WS_CmpPid)
    } else if (sort = "ProcessName") {
        _WS_TrySort(items, _WS_CmpProcessName)
    } else {
        _WS_TrySort(items, _WS_CmpMRU)
    }

    if (columns = "hwndsOnly") {
        hwnds := []
        for _, rec in items
            hwnds.Push(rec.hwnd)
        return { rev: WindowStore_GetRev(), hwnds: hwnds, meta: gWS_Meta }
    }

    rows := []
    for _, rec in items
        rows.Push(_WS_ToItem(rec))
    return { rev: WindowStore_GetRev(), items: rows, meta: gWS_Meta }
}

_WS_NewRecord(hwnd) {
    return {
        hwnd: hwnd,
        title: "",
        class: "",
        pid: 0,
        present: false,
        presentNow: false,
        missingSinceTick: 0,
        lastSeenScanId: 0,
        lastSeenTick: 0,
        altTabEligible: true,
        isCloaked: false,
        isMinimized: false,
        isVisible: false,
        z: 0,
        lastActivatedTick: 0,
        isFocused: false,
        workspaceId: "",
        workspaceName: "",
        isOnCurrentWorkspace: true,
        processName: "",
        exePath: "",
        iconHicon: 0,
        iconCooldownUntilTick: 0,
        iconGaveUp: false,
        iconMethod: "",           ; "wm_geticon", "uwp", "exe", or "" (none yet)
        iconLastRefreshTick: 0    ; When we last checked WM_GETICON (for refresh throttle)
    }
}

_WS_ToItem(rec) {
    return {
        hwnd: rec.hwnd,
        title: rec.title,
        class: rec.class,
        pid: rec.pid,
        z: rec.z,
        lastActivatedTick: rec.lastActivatedTick,
        isFocused: rec.isFocused,
        isCloaked: rec.isCloaked,
        isMinimized: rec.isMinimized,
        workspaceName: rec.workspaceName,
        workspaceId: rec.workspaceId,
        isOnCurrentWorkspace: rec.isOnCurrentWorkspace,
        processName: rec.processName,
        iconHicon: rec.iconHicon
    }
}

_WS_TrySort(arr, cmp) {
    if (!IsObject(arr) || !(arr is Array) || arr.Length <= 1)
        return
    if (arr.HasMethod("Sort")) {
        try {
            arr.Sort(cmp)
            return
        } catch {
        }
    }
    _WS_InsertionSort(arr, cmp)
}

_WS_InsertionSort(arr, cmp) {
    len := arr.Length
    Loop len {
        i := A_Index
        if (i = 1)
            continue
        key := arr[i]
        j := i - 1
        while (j >= 1 && cmp(arr[j], key) > 0) {
            arr[j + 1] := arr[j]
            j -= 1
        }
        arr[j + 1] := key
    }
}

; Helper to get option from Map or plain Object
_WS_GetOpt(opts, key, default) {
    if (!IsObject(opts))
        return default
    if (opts is Map)
        return opts.Has(key) ? opts[key] : default
    ; Plain object - use HasOwnProp
    return opts.HasOwnProp(key) ? opts.%key% : default
}

; Comparison functions for sorting
_WS_CmpZ(a, b) {
    ; Primary: Z-order (ascending, lower = closer to top)
    if (a.z != b.z)
        return (a.z < b.z) ? -1 : 1
    ; Tie-breaker: MRU (descending, higher tick = more recent = first)
    if (a.lastActivatedTick != b.lastActivatedTick)
        return (a.lastActivatedTick > b.lastActivatedTick) ? -1 : 1
    ; Final tie-breaker: hwnd for stability
    return (a.hwnd < b.hwnd) ? -1 : (a.hwnd > b.hwnd) ? 1 : 0
}

_WS_CmpTitle(a, b) {
    return StrCompare(a.title, b.title, "Locale")
}

_WS_CmpPid(a, b) {
    return (a.pid < b.pid) ? -1 : (a.pid > b.pid) ? 1 : 0
}

_WS_CmpProcessName(a, b) {
    return StrCompare(a.processName, b.processName, "Locale")
}

_WS_CmpMRU(a, b) {
    ; Primary: MRU (descending, higher tick = more recent = first)
    if (a.lastActivatedTick != b.lastActivatedTick)
        return (a.lastActivatedTick > b.lastActivatedTick) ? -1 : 1
    ; Fallback for windows with no MRU data: use Z-order
    if (a.z != b.z)
        return (a.z < b.z) ? -1 : 1
    ; Final tie-breaker: hwnd for stability
    return (a.hwnd < b.hwnd) ? -1 : (a.hwnd > b.hwnd) ? 1 : 0
}

; ============================================================
; Pump Queue Management
; ============================================================

; Enqueue window for enrichment if missing icon or process info
; Wrapped in Critical to prevent race conditions in check-then-insert pattern
_WS_EnqueueIfNeeded(row) {
    Critical "On"
    global gWS_IconQueue, gWS_IconQueueSet, gWS_PidQueue, gWS_PidQueueSet
    now := A_TickCount

    ; Determine if window needs icon work
    needsIconWork := false
    isVisible := !row.isCloaked && !row.isMinimized && row.isVisible

    if (!row.iconHicon && !row.iconGaveUp) {
        ; No icon yet - need one
        needsIconWork := true
    } else if (row.iconHicon && row.iconMethod != "wm_geticon" && isVisible) {
        ; Has fallback icon (UWP/EXE), window is now visible - try to upgrade
        needsIconWork := true
    }
    ; Note: refresh-on-focus is handled by WindowStore_EnqueueIconRefresh, not here

    if (needsIconWork && row.present) {
        if (row.iconCooldownUntilTick = 0 || now >= row.iconCooldownUntilTick) {
            hwnd := row.hwnd + 0
            if (!gWS_IconQueueSet.Has(hwnd)) {
                gWS_IconQueue.Push(hwnd)
                gWS_IconQueueSet[hwnd] := true
                try IconPump_EnsureRunning()  ; Wake timer from idle pause
            }
        }
    }

    ; Need process name?
    if (row.processName = "" && row.pid > 0 && row.present) {
        pid := row.pid + 0
        if (!gWS_PidQueueSet.Has(pid)) {
            gWS_PidQueue.Push(pid)
            gWS_PidQueueSet[pid] := true
            try ProcPump_EnsureRunning()  ; Wake timer from idle pause
        }
    }
    Critical "Off"
}

; Enqueue window for icon refresh (called when window gains focus)
; This allows upgrading fallback icons or refreshing WM_GETICON icons that may have changed
WindowStore_EnqueueIconRefresh(hwnd) {
    global gWS_Store, gWS_IconQueue, gWS_IconQueueSet, cfg
    hwnd := hwnd + 0

    if (!gWS_Store.Has(hwnd))
        return false

    row := gWS_Store[hwnd]

    ; Don't refresh if no icon yet (normal enqueue handles that)
    if (!row.iconHicon)
        return false

    ; Don't refresh if window gave up and still has no good icon
    if (row.iconGaveUp && row.iconMethod = "")
        return false

    ; Check throttle - don't refresh too frequently
    now := A_TickCount
    throttleMs := cfg.HasOwnProp("IconPumpRefreshThrottleMs") ? cfg.IconPumpRefreshThrottleMs : 30000
    if (row.iconLastRefreshTick > 0 && (now - row.iconLastRefreshTick) < throttleMs)
        return false

    ; RACE FIX: Wrap in Critical - check-then-insert must be atomic
    ; (same pattern as _WS_EnqueueIfNeeded and WindowStore_PopIconBatch)
    Critical "On"
    if (!gWS_IconQueueSet.Has(hwnd)) {
        gWS_IconQueue.Push(hwnd)
        gWS_IconQueueSet[hwnd] := true
        try IconPump_EnsureRunning()  ; Wake timer from idle pause
    }
    Critical "Off"
    return true
}

; Pop batch of hwnds needing icons
; RACE FIX: Wrap in Critical - push operations use Critical, so pop must too
WindowStore_PopIconBatch(count := 16) {
    Critical "On"
    global gWS_IconQueue, gWS_IconQueueSet
    batch := []
    while (gWS_IconQueue.Length > 0 && batch.Length < count) {
        hwnd := gWS_IconQueue.RemoveAt(1)
        gWS_IconQueueSet.Delete(hwnd)
        batch.Push(hwnd)
    }
    Critical "Off"
    return batch
}

; Pop batch of pids needing process info
; RACE FIX: Wrap in Critical - push operations use Critical, so pop must too
WindowStore_PopPidBatch(count := 16) {
    Critical "On"
    global gWS_PidQueue, gWS_PidQueueSet
    batch := []
    while (gWS_PidQueue.Length > 0 && batch.Length < count) {
        pid := gWS_PidQueue.RemoveAt(1)
        gWS_PidQueueSet.Delete(pid)
        batch.Push(pid)
    }
    Critical "Off"
    return batch
}

; ============================================================
; Z-Order Queue (triggers winenum pump)
; ============================================================

; Enqueue a window that needs Z-order (called by partial producers like winevent_hook)
; Wrapped in Critical to prevent race with ClearZQueue
WindowStore_EnqueueForZ(hwnd) {
    Critical "On"
    global gWS_ZQueue, gWS_ZQueueSet
    hwnd := hwnd + 0
    if (!hwnd || gWS_ZQueueSet.Has(hwnd)) {
        Critical "Off"
        return
    }
    gWS_ZQueue.Push(hwnd)
    gWS_ZQueueSet[hwnd] := true
    Critical "Off"
}

; Check if any windows need Z-order enrichment
; RACE FIX: Add Critical for consistency with EnqueueForZ/ClearZQueue
WindowStore_HasPendingZ() {
    Critical "On"
    global gWS_ZQueue
    result := gWS_ZQueue.Length > 0
    Critical "Off"
    return result
}

; Clear the Z queue (called after a full winenum scan)
; Wrapped in Critical to prevent race with EnqueueForZ
WindowStore_ClearZQueue() {
    Critical "On"
    global gWS_ZQueue, gWS_ZQueueSet
    gWS_ZQueue := []
    gWS_ZQueueSet := Map()
    Critical "Off"
}

; ============================================================
; Process Name Cache
; ============================================================

; Get cached process name for pid
WindowStore_GetProcNameCached(pid) {
    global gWS_ProcNameCache
    pid := pid + 0
    return gWS_ProcNameCache.Has(pid) ? gWS_ProcNameCache[pid] : ""
}

; Update process name for all windows with this pid
WindowStore_UpdateProcessName(pid, name) {
    global gWS_Store, gWS_Rev, gWS_ProcNameCache, cfg
    pid := pid + 0
    if (pid <= 0 || name = "")
        return

    ; FIFO eviction when at max (prevents unbounded memory growth)
    ; RACE FIX: Wrap in Critical - iteration + delete must be atomic (same as ExeIconCachePut)
    maxSize := cfg.HasOwnProp("ProcNameCacheMax") ? cfg.ProcNameCacheMax : 200
    Critical "On"
    if (gWS_ProcNameCache.Count >= maxSize) {
        ; Snapshot first entry to avoid modifying Map during iteration
        firstPid := 0
        for oldPid, _ in gWS_ProcNameCache {
            firstPid := oldPid
            break
        }
        if (firstPid)
            gWS_ProcNameCache.Delete(firstPid)
    }

    ; Cache it
    gWS_ProcNameCache[pid] := name
    Critical "Off"

    ; RACE FIX: Snapshot keys to prevent iteration-during-modification
    hwnds := _WS_SnapshotMapKeys(gWS_Store)

    ; Update all matching rows
    changed := false
    for _, hwnd in hwnds {
        if (!gWS_Store.Has(hwnd))
            continue  ; May have been removed by another producer
        rec := gWS_Store[hwnd]
        if (rec.pid = pid && rec.processName != name) {
            rec.processName := name
            changed := true
        }
    }
    if (changed) {
        _WS_BumpRev("UpdateProcessName")
    }
}

; ============================================================
; Icon Cache
; ============================================================

; Get a COPY of cached icon for exe (caller owns the copy)
WindowStore_GetExeIconCopy(exePath) {
    global gWS_ExeIconCache
    if (!gWS_ExeIconCache.Has(exePath))
        return 0
    master := gWS_ExeIconCache[exePath]
    if (!master)
        return 0
    return DllCall("user32\CopyIcon", "ptr", master, "ptr")
}

; Store master icon for exe (store owns it, don't destroy)
; Cache limited to ExeIconCacheMax entries to prevent unbounded memory growth
WindowStore_ExeIconCachePut(exePath, hIcon) {
    global gWS_ExeIconCache, cfg
    if (!hIcon)
        return
    ; Use config if available, fallback to 100
    maxSize := cfg.HasOwnProp("ExeIconCacheMax") ? cfg.ExeIconCacheMax : 100
    ; RACE FIX: Wrap FIFO eviction in Critical - prevents concurrent modification
    ; during iteration (another producer calling ExeIconCachePut simultaneously)
    Critical "On"
    if (gWS_ExeIconCache.Count >= maxSize) {
        ; Snapshot first entry to avoid modifying Map during iteration
        firstPath := ""
        firstIcon := 0
        for oldPath, oldIcon in gWS_ExeIconCache {
            firstPath := oldPath
            firstIcon := oldIcon
            break
        }
        if (firstPath != "") {
            if (firstIcon)
                try DllCall("user32\DestroyIcon", "ptr", firstIcon)
            gWS_ExeIconCache.Delete(firstPath)
        }
    }
    gWS_ExeIconCache[exePath] := hIcon
    Critical "Off"
}

; Clean up all cached exe icons - call on shutdown
WindowStore_CleanupExeIconCache() {
    global gWS_ExeIconCache
    for exePath, hIcon in gWS_ExeIconCache {
        if (hIcon)
            try DllCall("user32\DestroyIcon", "ptr", hIcon)
    }
    gWS_ExeIconCache := Map()
}

; Prune dead PIDs from process name cache (called from Store_HeartbeatTick)
; Returns the number of entries pruned
WindowStore_PruneProcNameCache() {
    global gWS_ProcNameCache
    if (!IsObject(gWS_ProcNameCache) || gWS_ProcNameCache.Count = 0)
        return 0

    ; Snapshot keys to prevent iteration-during-modification
    pids := _WS_SnapshotMapKeys(gWS_ProcNameCache)

    pruned := 0
    for _, pid in pids {
        if (!ProcessExist(pid)) {
            gWS_ProcNameCache.Delete(pid)
            pruned++
        }
    }
    return pruned
}

; Clean up all per-window icons in the store
WindowStore_CleanupAllIcons() {
    global gWS_Store
    for hwnd, rec in gWS_Store {
        if (rec.HasOwnProp("iconHicon") && rec.iconHicon) {
            try DllCall("user32\DestroyIcon", "ptr", rec.iconHicon)
            rec.iconHicon := 0
        }
    }
}

; ============================================================
; Delta Building - Compute changes between projections
; ============================================================

; Build delta between previous and current projection items
; Parameters:
;   prevItems - Array of previous projection items
;   nextItems - Array of current projection items
; Returns: { upserts: [], removes: [] }
WindowStore_BuildDelta(prevItems, nextItems) {
    prevMap := Map()
    for _, rec in prevItems
        prevMap[rec.hwnd] := rec
    nextMap := Map()
    for _, rec in nextItems
        nextMap[rec.hwnd] := rec

    upserts := []
    removes := []

    ; Find new/changed items
    for hwnd, rec in nextMap {
        if (!prevMap.Has(hwnd)) {
            upserts.Push(rec)
        } else {
            old := prevMap[hwnd]
            ; Compare key fields that matter for display
            if (rec.title != old.title || rec.z != old.z
                || rec.pid != old.pid || rec.isFocused != old.isFocused
                || rec.workspaceName != old.workspaceName || rec.isCloaked != old.isCloaked
                || rec.isMinimized != old.isMinimized || rec.isOnCurrentWorkspace != old.isOnCurrentWorkspace
                || rec.processName != old.processName || rec.iconHicon != old.iconHicon) {
                upserts.Push(rec)
            }
        }
    }

    ; Find removed items
    for hwnd, _ in prevMap {
        if (!nextMap.Has(hwnd))
            removes.Push(hwnd)
    }

    return { upserts: upserts, removes: removes }
}

