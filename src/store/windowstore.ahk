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

gWS_Config["MissingTTLms"] := 1200
gWS_Meta["currentWSId"] := ""
gWS_Meta["currentWSName"] := ""

WindowStore_Init(config := 0) {
    global gWS_Config
    if IsObject(config) {
        for k, v in config
            gWS_Config[k] := v
    }
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
    for hwnd, rec in gWS_Store {
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
        gWS_Rev += 1
        _WS_DiagBump("EndScan")
    }
    return { removed: removed, rev: gWS_Rev }
}

WindowStore_UpsertWindow(records, source := "") {
    global gWS_Store, gWS_Rev, gWS_ScanId
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
        isNew := !gWS_Store.Has(hwnd)
        if (isNew) {
            gWS_Store[hwnd] := _WS_NewRecord(hwnd)
            added += 1
        }
        row := gWS_Store[hwnd]

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
                    if (!isNew) {
                        gWS_DiagChurn[k] := (gWS_DiagChurn.Has(k) ? gWS_DiagChurn[k] : 0) + 1
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
        gWS_Rev += 1
        _WS_DiagBump("UpsertWindow")
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
        gWS_Rev += 1
        _WS_DiagBump("UpdateFields:" . source)
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
        gWS_Store.Delete(hwnd)
        ; Clean up icon pump tracking state (prevents memory leak)
        try IconPump_CleanupWindow(hwnd)
        removed += 1
    }
    if (removed) {
        gWS_Rev += 1
        _WS_DiagBump("RemoveWindow")
    }
    return { removed: removed, rev: gWS_Rev }
}

; ============================================================
; Existence Validation - Lightweight zombie detection
; ============================================================
; Iterates existing store entries and removes any where IsWindow() returns false.
; This is O(n) where n is typically 10-30 windows - much lighter than full EnumWindows.
; Catches edge cases: process crashes without clean DESTROY events, remote desktop
; disconnections, windows that die during debounce period.

WindowStore_ValidateExistence() {
    global gWS_Store, gWS_Rev
    toRemove := []

    for hwnd, rec in gWS_Store {
        ; IsWindow returns false only for truly destroyed windows
        ; Cloaked/minimized windows still return true
        if (!DllCall("user32\IsWindow", "ptr", hwnd, "int")) {
            toRemove.Push(hwnd)
        }
    }

    if (toRemove.Length = 0)
        return { removed: 0, rev: gWS_Rev }

    removed := 0
    for _, hwnd in toRemove {
        gWS_Store.Delete(hwnd)
        ; Clean up icon pump tracking state
        try IconPump_CleanupWindow(hwnd)
        removed += 1
    }

    if (removed > 0) {
        gWS_Rev += 1
        _WS_DiagBump("ValidateExistence")
    }

    return { removed: removed, rev: gWS_Rev }
}

; Purge all windows from store that match the current blacklist
; Called after blacklist reload to remove newly-blacklisted windows
WindowStore_PurgeBlacklisted() {
    global gWS_Store, gWS_Rev
    removed := 0
    toRemove := []

    ; Collect hwnds that match blacklist (can't modify Map while iterating)
    for hwnd, rec in gWS_Store {
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
        gWS_Rev += 1
        _WS_DiagBump("PurgeBlacklisted")
    }

    return { removed: removed, rev: gWS_Rev }
}

WindowStore_GetRev() {
    global gWS_Rev
    return gWS_Rev
}

; Diagnostic: get and reset churn stats
WindowStore_GetChurnDiag(reset := true) {
    global gWS_DiagChurn, gWS_DiagSource
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
    return result
}

; Diagnostic: record a rev bump from a source
_WS_DiagBump(source) {
    global gWS_DiagSource
    gWS_DiagSource[source] := (gWS_DiagSource.Has(source) ? gWS_DiagSource[source] : 0) + 1
}

WindowStore_GetByHwnd(hwnd) {
    global gWS_Store
    hwnd := hwnd + 0
    return gWS_Store.Has(hwnd) ? gWS_Store[hwnd] : ""
}

WindowStore_SetCurrentWorkspace(id, name := "") {
    global gWS_Meta, gWS_Rev, gWS_Store
    changed := false
    if (gWS_Meta["currentWSId"] != id) {
        gWS_Meta["currentWSId"] := id
        changed := true
    }
    if (gWS_Meta["currentWSName"] != name) {
        gWS_Meta["currentWSName"] := name
        changed := true
    }
    if (changed) {
        ; Update isOnCurrentWorkspace for all windows based on new workspace
        ; Unmanaged windows (empty workspaceName) float across all workspaces, treat as "on current"
        for hwnd, rec in gWS_Store {
            newIsOnCurrent := (rec.workspaceName = name) || (rec.workspaceName = "")
            if (rec.isOnCurrentWorkspace != newIsOnCurrent)
                rec.isOnCurrentWorkspace := newIsOnCurrent
        }
        gWS_Rev += 1
        _WS_DiagBump("SetCurrentWorkspace")
    }
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

    items := []
    for _, rec in gWS_Store {
        if (!rec.present)
            continue
        if (currentOnly && !rec.isOnCurrentWorkspace)
            continue
        if (!includeMin && rec.isMinimized)
            continue
        if (!includeCloaked && rec.isCloaked)
            continue
        items.Push(rec)
    }

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
        iconHicon: rec.iconHicon,
        present: rec.present
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
_WS_EnqueueIfNeeded(row) {
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
            }
        }
    }

    ; Need process name?
    if (row.processName = "" && row.pid > 0 && row.present) {
        pid := row.pid + 0
        if (!gWS_PidQueueSet.Has(pid)) {
            gWS_PidQueue.Push(pid)
            gWS_PidQueueSet[pid] := true
        }
    }
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

    ; Enqueue for refresh
    if (!gWS_IconQueueSet.Has(hwnd)) {
        gWS_IconQueue.Push(hwnd)
        gWS_IconQueueSet[hwnd] := true
    }
    return true
}

; Pop batch of hwnds needing icons
WindowStore_PopIconBatch(count := 16) {
    global gWS_IconQueue, gWS_IconQueueSet
    batch := []
    while (gWS_IconQueue.Length > 0 && batch.Length < count) {
        hwnd := gWS_IconQueue.RemoveAt(1)
        gWS_IconQueueSet.Delete(hwnd)
        batch.Push(hwnd)
    }
    return batch
}

; Pop batch of pids needing process info
WindowStore_PopPidBatch(count := 16) {
    global gWS_PidQueue, gWS_PidQueueSet
    batch := []
    while (gWS_PidQueue.Length > 0 && batch.Length < count) {
        pid := gWS_PidQueue.RemoveAt(1)
        gWS_PidQueueSet.Delete(pid)
        batch.Push(pid)
    }
    return batch
}

; ============================================================
; Z-Order Queue (triggers winenum pump)
; ============================================================

; Enqueue a window that needs Z-order (called by partial producers like winevent_hook)
WindowStore_EnqueueForZ(hwnd) {
    global gWS_ZQueue, gWS_ZQueueSet
    hwnd := hwnd + 0
    if (!hwnd || gWS_ZQueueSet.Has(hwnd))
        return
    gWS_ZQueue.Push(hwnd)
    gWS_ZQueueSet[hwnd] := true
}

; Check if any windows need Z-order enrichment
WindowStore_HasPendingZ() {
    global gWS_ZQueue
    return gWS_ZQueue.Length > 0
}

; Get count of pending Z requests
WindowStore_PendingZCount() {
    global gWS_ZQueue
    return gWS_ZQueue.Length
}

; Clear the Z queue (called after a full winenum scan)
WindowStore_ClearZQueue() {
    global gWS_ZQueue, gWS_ZQueueSet
    gWS_ZQueue := []
    gWS_ZQueueSet := Map()
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
    global gWS_Store, gWS_Rev, gWS_ProcNameCache
    pid := pid + 0
    if (pid <= 0 || name = "")
        return

    ; Cache it
    gWS_ProcNameCache[pid] := name

    ; Update all matching rows
    changed := false
    for hwnd, rec in gWS_Store {
        if (rec.pid = pid && rec.processName != name) {
            rec.processName := name
            changed := true
        }
    }
    if (changed) {
        gWS_Rev += 1
        _WS_DiagBump("UpdateProcessName")
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
WindowStore_ExeIconCachePut(exePath, hIcon) {
    global gWS_ExeIconCache
    if (hIcon)
        gWS_ExeIconCache[exePath] := hIcon
}

; ============================================================
; Ensure API (for producers that add partial data)
; ============================================================

; Ensure a window exists in store, merge hints, enqueue for enrichment
WindowStore_Ensure(hwnd, hints := 0, source := "") {
    global gWS_Store, gWS_Rev
    hwnd := hwnd + 0
    if (!hwnd)
        return

    isNew := !gWS_Store.Has(hwnd)
    if (isNew) {
        gWS_Store[hwnd] := _WS_NewRecord(hwnd)
    }

    row := gWS_Store[hwnd]
    changed := isNew

    ; Merge hints - only update if value differs
    if (IsObject(hints)) {
        if (hints is Map) {
            for k, v in hints {
                if (!row.HasOwnProp(k) || row.%k% != v) {
                    row.%k% := v
                    changed := true
                }
            }
        } else {
            for k in hints.OwnProps() {
                v := hints.%k%
                if (!row.HasOwnProp(k) || row.%k% != v) {
                    row.%k% := v
                    changed := true
                }
            }
        }
    }

    if (changed) {
        gWS_Rev += 1
        _WS_DiagBump("Ensure:" . source)
    }

    ; Enqueue for enrichment
    _WS_EnqueueIfNeeded(row)
}
