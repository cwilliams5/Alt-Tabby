#Requires AutoHotkey v2.0

; WindowStore (v1) - minimal core for IPC + viewer.

global gWS_Store := Map()
global gWS_Rev := 0
global gWS_ScanId := 0
global gWS_Config := Map()
global gWS_Meta := Map()

; Work queues for pumps
global gWS_IconQueue := []         ; hwnds needing icons
global gWS_PidQueue := []          ; pids needing process info
global gWS_IconQueueSet := Map()   ; fast lookup for dedup
global gWS_PidQueueSet := Map()    ; fast lookup for dedup

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
            if (rec.presentNow) {
                rec.presentNow := false
                rec.present := false
                rec.missingSinceTick := now
                changed := true
            } else if (rec.missingSinceTick && (now - rec.missingSinceTick) >= ttl) {
                gWS_Store.Delete(hwnd)
                removed += 1
                changed := true
            }
        }
    }
    if (changed)
        gWS_Rev += 1
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
        if (rec is Map) {
            for k, v in rec
                row.%k% := v
        } else {
            continue
        }
        row.present := true
        row.presentNow := true
        row.lastSeenScanId := gWS_ScanId
        row.lastSeenTick := A_TickCount
        updated += 1

        ; Enqueue for enrichment if missing data
        _WS_EnqueueIfNeeded(row)
    }
    if (added || updated)
        gWS_Rev += 1
    return { added: added, updated: updated, rev: gWS_Rev }
}

WindowStore_UpdateFields(hwnd, patch, source := "") {
    global gWS_Store, gWS_Rev
    hwnd := hwnd + 0
    if (!gWS_Store.Has(hwnd))
        return { changed: false, rev: gWS_Rev }
    row := gWS_Store[hwnd]
    changed := false
    ; Handle both Map and plain object patches
    if (patch is Map) {
        for k, v in patch {
            if (!row.HasOwnProp(k) || row.%k% != v) {
                row.%k% := v
                changed := true
            }
        }
    } else if (IsObject(patch)) {
        for k in patch.OwnProps() {
            v := patch.%k%
            if (!row.HasOwnProp(k) || row.%k% != v) {
                row.%k% := v
                changed := true
            }
        }
    }
    if (changed)
        gWS_Rev += 1
    return { changed: changed, rev: gWS_Rev }
}

WindowStore_RemoveWindow(hwnds) {
    global gWS_Store, gWS_Rev
    removed := 0
    for _, h in hwnds {
        hwnd := h + 0
        if (gWS_Store.Has(hwnd)) {
            gWS_Store.Delete(hwnd)
            removed += 1
        }
    }
    if (removed)
        gWS_Rev += 1
    return { removed: removed, rev: gWS_Rev }
}

WindowStore_GetRev() {
    global gWS_Rev
    return gWS_Rev
}

WindowStore_GetByHwnd(hwnd) {
    global gWS_Store
    hwnd := hwnd + 0
    return gWS_Store.Has(hwnd) ? gWS_Store[hwnd] : ""
}

WindowStore_SetCurrentWorkspace(id, name := "") {
    global gWS_Meta, gWS_Rev
    changed := false
    if (gWS_Meta["currentWSId"] != id) {
        gWS_Meta["currentWSId"] := id
        changed := true
    }
    if (gWS_Meta["currentWSName"] != name) {
        gWS_Meta["currentWSName"] := name
        changed := true
    }
    if (changed)
        gWS_Rev += 1
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
    blacklistMode := _WS_GetOpt(opts, "blacklistMode", "exclude")
    columns := _WS_GetOpt(opts, "columns", "items")

    items := []
    for _, rec in gWS_Store {
        if (!rec.present)
            continue
        if (currentOnly && !rec.isOnCurrentWorkspace)
            continue
        if (!includeMin && rec.state = "WorkspaceMinimized")
            continue
        if (!includeCloaked && rec.state = "OtherWorkspace")
            continue
        if (blacklistMode = "exclude" && rec.isBlacklisted)
            continue
        if (blacklistMode = "only" && !rec.isBlacklisted)
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
        state: "WorkspaceHidden",
        altTabEligible: true,
        isBlacklisted: false,
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
        iconCooldownUntilTick: 0
    }
}

_WS_ToItem(rec) {
    return {
        hwnd: rec.hwnd,
        title: rec.title,
        class: rec.class,
        pid: rec.pid,
        state: rec.state,
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
    return (a.z < b.z) ? -1 : (a.z > b.z) ? 1 : 0
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
    ; MRU: most recently activated first (descending)
    return (a.lastActivatedTick > b.lastActivatedTick) ? -1 : (a.lastActivatedTick < b.lastActivatedTick) ? 1 : 0
}

; ============================================================
; Pump Queue Management
; ============================================================

; Enqueue window for enrichment if missing icon or process info
_WS_EnqueueIfNeeded(row) {
    global gWS_IconQueue, gWS_IconQueueSet, gWS_PidQueue, gWS_PidQueueSet
    now := A_TickCount

    ; Need icon?
    if (!row.iconHicon && row.present) {
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
    if (changed)
        gWS_Rev += 1
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

    if (!gWS_Store.Has(hwnd)) {
        gWS_Store[hwnd] := _WS_NewRecord(hwnd)
        gWS_Rev += 1
    }

    row := gWS_Store[hwnd]

    ; Merge hints
    if (IsObject(hints)) {
        if (hints is Map) {
            for k, v in hints
                row.%k% := v
        } else {
            for k in hints.OwnProps()
                row.%k% := hints.%k%
        }
    }

    ; Enqueue for enrichment
    _WS_EnqueueIfNeeded(row)
}
