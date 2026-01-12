#Requires AutoHotkey v2.0
;===============================================================================
; list.ahk  —  WindowStore (single source of truth)
; ------------------------------------------------------------------------------
; Purpose:
;   Centralized, in-memory store for window metadata. Everyone (winenum, MRU,
;   Komorebi, icon pump, AltLogic, GUI) reads/writes here instead of syncing
;   disparate structures. AltLogic owns session selection and just asks the
;   store for ordered projections.
;
; Design highlights:
;   - Batching: BeginBatch/EndBatch coalesce rev bumps (rev increments once per
;     meaningful change set). GetRev() exposes current global revision.
;   - Scans: BeginScan/EndScan provide the “seen this pass” bookkeeping.
;     EndScan hides missing windows immediately (present/presentNow=false) and
;     hard-removes after a grace period (MissingTTLms). Icons are destroyed on
;     hard removal; PID refcounts maintained.
;   - Upsert/Update/Ensure:
;       * UpsertWindow(records, source?) merges idempotently.
;       * UpdateFields(hwnd, patch, source?) applies partial updates.
;       * Ensure(hwnd, hints?, source?) guarantees a row exists. If unknown, it
;         calls the injected ByHwnd fetcher (set via SetFetchers), then merges
;         hints.
;   - Ownership (optional): you can enforce which module may write which fields.
;       * WindowStore_SetOwnershipPolicy(mode, allowed?) controls enforcement:
;           - "off"  : accept anything (today’s behavior).
;           - "warn" : accept everything but log when a non-owner writes a field.
;           - "strict": drop non-owned fields (with a warning).
;         Default policy (if you don’t set one): "off".
;   - Projections: GetProjection builds a filtered + sorted view (MRU/Z/etc).
;     It can return just hwnds (fast) or GUI-ready “items”.
;   - Meta: Set/GetCurrentWorkspace track the current workspace for projections.
;
; Threading:
;   AHK is single-threaded; store ops are lightweight. GUI should render from
;   cached projection and re-pull only when rev changes.
;
; Public API:
;   WindowStore_Init(config?)
;   WindowStore_BeginBatch()
;   WindowStore_EndBatch() -> {rev, changed}
;   WindowStore_BeginScan() -> scanId
;   WindowStore_EndScan(graceMs?) -> {hiddenNow, tombstoned, removed, rev}
;   WindowStore_SetFetchers({ByHwnd: Func})
;   WindowStore_SetOwnershipPolicy(mode := "off", allowedMap?)
;   WindowStore_Ensure(hwnd, hints := 0, source := "")
;   WindowStore_UpsertWindow(records, source := "") -> {added, updated, rev}
;   WindowStore_UpdateFields(hwnd, patch, source := "") -> {changed, rev}
;   WindowStore_RemoveWindow(hwnds) -> {removed, rev}
;   WindowStore_Has(hwnd) -> bool
;   WindowStore_GetByHwnd(hwnd) -> record?
;   WindowStore_GetProjection(opts?) -> {rev, hwnds, items?, meta}
;   WindowStore_GetIndexOf(hwnd, opts?) -> index? (1-based)
;   WindowStore_SetCurrentWorkspace(id, name?)
;   WindowStore_GetCurrentWorkspace() -> {id, name}
;
; GetProjection opts (defaults shown):
;   {
;     filter: {
;       presentOnly: true,
;       currentWorkspaceOnly: false,
;       blacklistMode: "exclude",   ; "exclude" | "include" | "only"
;       classes: [],                ; whitelist if provided
;       pids: []                    ; whitelist if provided
;     },
;     sort: "MRU",                  ; "MRU" | "Z" | "Title" | "Pid" | "ProcessName"
;     columns: "hwndsOnly"          ; "hwndsOnly" | "items"
;   }
;
; Record schema (per HWND): see _WS_NewRecord().
;===============================================================================

;============================== GLOBAL STATE ===================================

global gWS_Store            := Map()     ; hwnd (UInt) -> record (Object)
global gWS_Rev              := 0         ; global store revision (monotonic)
global gWS_Batching         := false     ; inside BeginBatch/EndBatch
global gWS_PendingRevBump   := false     ; accumulate rev bump during batch
global gWS_CurrentSweepId   := 0         ; 0 = no active sweep
global gWS_Config           := Map()     ; runtime config (MissingTTLms, etc.)

; --- Ownership enforcement (optional) ---
global gWS_OwnershipMode := "off"     ; "off" | "warn" | "strict"
; Map: source -> Map(set of allowed fields)
; e.g. gWS_AllowedFields["winenum"]["pid"] := true
global gWS_AllowedFields := Map()


; sensible defaults
gWS_Config["MissingTTLms"]        := 1200
gWS_Config["DefaultSort"]         := "MRU"
gWS_Config["NormalizeTitleMax"]   := 260    ; clamp super long titles
gWS_Config["TitleCollapseSpaces"] := true

global gWS_ScanId           := 0               ; monotonic scan token
global gWS_Meta             := Map()           ; meta store (current WS, etc.)
gWS_Meta["currentWSId"]     := ""
gWS_Meta["currentWSName"]   := ""

; De-duped work queues (used by pumps outside the store)
global gWS_Q_Pid            := Map()           ; pid -> true (needs process name)
global gWS_Q_Icon           := Map()           ; hwnd -> true (needs icon)
global gWS_Q_WS             := Map()           ; hwnd -> true (needs workspace)

; PID->processName cache + refcounts (drop name when last ref is gone)
global gWS_ProcCache        := Map()           ; pid -> processName
global gWS_ProcRef          := Map()           ; pid -> refcount

; Optional EXE->HICON cache (we keep one master HICON per exe; callers CopyIcon)
global gWS_ExeIconCache     := Map()           ; exePath -> hicon

; Injected fetchers (set by winenum): { ByHwnd: Func }
global gWS_Fetch_ByHwnd     := 0               ; function object or 0

;=============================== PUBLIC API ====================================

WindowStore_Init(config := 0) {
    global gWS_Config, gWS_OwnershipMode, gWS_AllowedFields
    if IsObject(config) {
        for k, v in config
            gWS_Config[k] := v
        ; Optional ownership wiring via config:
        if (config.Has("OwnershipMode")) {
            m := StrLower(config["OwnershipMode"] . "")
            if (m != "off" && m != "warn" && m != "strict")
                m := "off"
            gWS_OwnershipMode := m
        }
        if (config.Has("OwnershipAllowed") && IsObject(config["OwnershipAllowed"])) {
            WindowStore_SetOwnershipPolicy(gWS_OwnershipMode, config["OwnershipAllowed"])
        }
    }
}

WindowStore_BeginBatch() {
    global gWS_Batching, gWS_PendingRevBump
    gWS_Batching := true
    gWS_PendingRevBump := false
}

WindowStore_EndBatch() {
    global gWS_Batching, gWS_PendingRevBump, gWS_Rev
    changed := false
    if (gWS_PendingRevBump) {
        gWS_Rev += 1
        changed := true
    }
    gWS_Batching := false
    gWS_PendingRevBump := false
    return { rev: gWS_Rev, changed: changed }
}

WindowStore_Has(hwnd) {
    global gWS_Store
    return gWS_Store.Has(hwnd + 0)
}

WindowStore_SetFetchers(fns) {
    ; fns example: { ByHwnd: Func("WinList_EnumerateByHwnd") }
    global gWS_Fetch_ByHwnd
    gWS_Fetch_ByHwnd := 0
    if (IsObject(fns) && fns.Has("ByHwnd") && (fns.ByHwnd is Func))
        gWS_Fetch_ByHwnd := fns.ByHwnd
}

WindowStore_Ensure(hwnd, hints := 0, source := "") {
    global gWS_Store, gWS_Fetch_ByHwnd
    hwnd := hwnd + 0
    if (gWS_Store.Has(hwnd)) {
        if (IsObject(hints)) {
            patch := _WS_FilterPatchByOwnership(hints, source)
            WindowStore_UpdateFields(hwnd, patch, source)
        }
        return { record: gWS_Store[hwnd], existed: true }
    }
    ; Try injected fetcher
    if (gWS_Fetch_ByHwnd) {
        fetched := ""
        try fetched := gWS_Fetch_ByHwnd.Call([hwnd], IsObject(hints) ? hints : Map())
        catch {}
        ; fetcher should Upsert into the store; if not, we'll create skeleton below
    }
    if (!gWS_Store.Has(hwnd)) {
        WindowStore_UpsertWindow([{ hwnd: hwnd }], "internal")
    }
    if (IsObject(hints)) {
        patch2 := _WS_FilterPatchByOwnership(hints, source)
        WindowStore_UpdateFields(hwnd, patch2, source)
    }
    return { record: gWS_Store[hwnd], existed: false }
}


WindowStore_BeginScan() {
    global gWS_ScanId
    if (gWS_ScanId = 0x7FFFFFFF)
        gWS_ScanId := 0
    gWS_ScanId += 1
    return gWS_ScanId
}

WindowStore_EndScan(graceMs := "") {
    global gWS_Store, gWS_ScanId, gWS_Config
    now := _WS_Now()
    ttl := (graceMs != "" ? graceMs + 0 : (gWS_Config.Has("MissingTTLms") ? gWS_Config["MissingTTLms"] + 0 : 1200))

    hiddenNow := 0
    tombstoned := 0
    removed := 0
    changed := false

    ; pass 1: hide rows not seen this scan (presentNow=false), start tombstone
    for hwnd, rec in gWS_Store {
        if (rec.lastSeenScanId != gWS_ScanId) {
            if (rec.presentNow) {
                rec.presentNow := false
                rec.present := false
                changed := true
                hiddenNow += 1
            }
            if (rec.missingSinceTick = 0) {
                rec.missingSinceTick := now
                tombstoned += 1
                changed := true
            }
        } else {
            ; seen → ensure visible and clear tombstone marker
            if (!rec.presentNow || !rec.present) {
                rec.presentNow := true
                rec.present := true
                changed := true
            }
            if (rec.missingSinceTick) {
                rec.missingSinceTick := 0
                changed := true
            }
        }
    }

    ; pass 2: hard-remove beyond TTL
    doomed := []
    for hwnd, rec in gWS_Store {
        if (rec.missingSinceTick && (now - rec.missingSinceTick >= ttl))
            doomed.Push(hwnd)
    }
    if (doomed.Length) {
        tmp := WindowStore_RemoveWindow(doomed)
        removed += tmp.removed
        changed := changed || (tmp.removed > 0)
    }

    if (changed)
        _WS_RequestRevBump()

    ; clear current scan token
    gWS_ScanId := 0

    return { hiddenNow: hiddenNow, tombstoned: tombstoned, removed: removed, rev: WindowStore_GetRev() }
}

WindowStore_PopPidBatch(n := 32) {
    global gWS_Q_Pid
    out := []
    for pid, _ in gWS_Q_Pid {
        out.Push(pid + 0)
        gWS_Q_Pid.Delete(pid)
        if (out.Length >= n)
            break
    }
    return out
}

WindowStore_PopIconBatch(n := 32) {
    global gWS_Q_Icon, gWS_Store
    out := []
    for hwnd, _ in gWS_Q_Icon {
        hwnd := hwnd + 0
        out.Push(hwnd)
        gWS_Q_Icon.Delete(hwnd)
        if (gWS_Store.Has(hwnd)) {
            rec := gWS_Store[hwnd]
            ; Mark in-flight so a later tickle can re-enqueue (false→true transition).
            rec.needsIcon := false
        }
        if (out.Length >= n)
            break
    }
    return out
}


WindowStore_PopWSBatch(n := 32) {
    global gWS_Q_WS
    out := []
    for hwnd, _ in gWS_Q_WS {
        out.Push(hwnd + 0)
        gWS_Q_WS.Delete(hwnd)
        if (out.Length >= n)
            break
    }
    return out
}

WindowStore_SetCurrentWorkspace(id, name := "") {
    global gWS_Meta, gWS_Store
    prevId  := gWS_Meta["currentWSId"]
    prevNam := gWS_Meta["currentWSName"]

    gWS_Meta["currentWSId"]   := id . ""
    gWS_Meta["currentWSName"] := name . ""

    ; If rows already know their workspace, recompute isOnCurrentWorkspace
    changed := false
    for hwnd, rec in gWS_Store {
        known := (rec.workspaceId != "" || rec.workspaceName != "")
        wasOn := rec.isOnCurrentWorkspace
        nowOn := wasOn
        if (known) {
            if (rec.workspaceId != "")
                nowOn := (rec.workspaceId = gWS_Meta["currentWSId"])
            else
                nowOn := (rec.workspaceName = gWS_Meta["currentWSName"])
        } else {
            ; Unknown workspace → mark needsWS and enqueue
            rec.needsWS := true
            _WS_QueueWS(rec.hwnd)
        }
        if (nowOn != wasOn) {
            rec.isOnCurrentWorkspace := nowOn
            changed := true
        }
    }
    if (changed || id . "" != prevId . "" || name . "" != prevNam . "")
        _WS_RequestRevBump()
    return { id: gWS_Meta["currentWSId"], name: gWS_Meta["currentWSName"], rev: WindowStore_GetRev() }
}

WindowStore_GetCurrentWorkspace() {
    global gWS_Meta
    return { id: gWS_Meta["currentWSId"], name: gWS_Meta["currentWSName"] }
}

WindowStore_GetProcNameCached(pid) {
    global gWS_ProcCache
    return (pid > 0 && gWS_ProcCache.Has(pid)) ? (gWS_ProcCache[pid] . "") : ""
}

WindowStore_UpdateProcessName(pid, name) {
    ; Called by your proc-name pump once it resolves a name.
    global gWS_ProcCache, gWS_Store
    pid := pid + 0
    if (pid <= 0)
        return { updated: 0, rev: WindowStore_GetRev() }

    gWS_ProcCache[pid] := name . ""
    ; Fan-out to rows lacking a name
    updated := 0
    for hwnd, rec in gWS_Store {
        if (rec.pid = pid && rec.processName = "") {
            rec.processName := gWS_ProcCache[pid]
            updated += 1
            ; updating text should bump rev once; safe to set per-row then bump at end
        }
    }
    if (updated > 0)
        _WS_RequestRevBump()
    return { updated: updated, rev: WindowStore_GetRev() }
}

WindowStore_ExeIconCachePut(exePath, hIcon) {
    ; Store/replace the master icon for an exe. We own the previous and will destroy it.
    global gWS_ExeIconCache
    key := exePath . ""
    if (key = "")
        return
    if (gWS_ExeIconCache.Has(key)) {
        old := gWS_ExeIconCache[key]
        if (old)
            try DllCall("user32\DestroyIcon", "ptr", old)
    }
    gWS_ExeIconCache[key] := hIcon + 0
}

WindowStore_GetExeIconCopy(exePath) {
    ; Returns a CopyIcon() of the master (caller owns/destroys). 0 if none.
    global gWS_ExeIconCache
    key := exePath . ""
    if (key = "" || !gWS_ExeIconCache.Has(key))
        return 0
    master := gWS_ExeIconCache[key]
    if (!master)
        return 0
    return DllCall("user32\CopyIcon", "ptr", master, "ptr")
}

WindowStore_ClearExeIconCache() {
    global gWS_ExeIconCache
    for k, h in gWS_ExeIconCache {
        if (h)
            try DllCall("user32\DestroyIcon", "ptr", h)
    }
    gWS_ExeIconCache := Map()
}


WindowStore_UpsertWindow(records, source := "") {
    global gWS_Store, gWS_ScanId
    if !IsObject(records)
        records := [records]

    now := _WS_Now()
    added := 0, updated := 0
    changed := false

    for _, rawPatch in records {
        if (!IsObject(rawPatch) || !rawPatch.Has("hwnd"))
            continue
        hwnd := rawPatch.hwnd + 0

        ; Apply ownership filter before merge
        patch := _WS_FilterPatchByOwnership(rawPatch, source)

        rec := gWS_Store.Has(hwnd) ? gWS_Store[hwnd] : 0
        if (!rec) {
            rec := _WS_NewRecord(hwnd)
            gWS_Store[hwnd] := rec
            added += 1
            changed := true
        }

        oldPid := rec.pid
        if (_WS_MergeInto(rec, patch)) {
            updated += 1
            changed := true
        }

        ; pid refcount maintenance (after merge)
        if (rec.pid != oldPid)
            _WS_AdjustPidRefs(oldPid, rec.pid)

        ; mark seen in current scan (if any)
        if (gWS_ScanId > 0) {
            rec.lastSeenScanId := gWS_ScanId
        }
        rec.lastSeenTick := now
        rec.present      := true
        rec.presentNow   := true
        rec.missingSinceTick := 0

        ; recompute needs + enqueue if newly needed
        _WS_RefreshNeeds(rec)
    }

    if (changed)
        _WS_RequestRevBump()

    return { added: added, updated: updated, rev: WindowStore_GetRev() }
}



WindowStore_UpdateFields(hwnd, patch, source := "") {
    global gWS_Store
    if (!gWS_Store.Has(hwnd))
        return { changed: false, rev: WindowStore_GetRev() }

    ; Apply ownership filter
    filtered := _WS_FilterPatchByOwnership(patch, source)

    rec := gWS_Store[hwnd]
    oldPid := rec.pid
    changed := _WS_MergeInto(rec, filtered)

    if (rec.pid != oldPid)
        _WS_AdjustPidRefs(oldPid, rec.pid)

    _WS_RefreshNeeds(rec)

    if (changed)
        _WS_RequestRevBump()
    return { changed: changed, rev: WindowStore_GetRev() }
}



WindowStore_RemoveWindow(hwnds) {
    global gWS_Store, gWS_Q_Icon, gWS_Q_WS
    if !IsObject(hwnds)
        hwnds := [hwnds]

    removed := 0
    for _, h in hwnds {
        hwnd := h + 0
        if (!gWS_Store.Has(hwnd))
            continue
        rec := gWS_Store[hwnd]

        ; pid refcount + optional cache drop
        _WS_AdjustPidRefs(rec.pid, 0)

        ; cleanup icon
        if (rec.iconHicon) {
            try DllCall("user32\DestroyIcon", "ptr", rec.iconHicon)
        }

        ; remove from queues if present
        if (gWS_Q_Icon.Has(hwnd))
            gWS_Q_Icon.Delete(hwnd)
        if (gWS_Q_WS.Has(hwnd))
            gWS_Q_WS.Delete(hwnd)

        gWS_Store.Delete(hwnd)
        removed += 1
    }
    if (removed > 0)
        _WS_RequestRevBump()
    return { removed: removed, rev: WindowStore_GetRev() }
}


WindowStore_GetRev() {
    global gWS_Rev
    return gWS_Rev
}

WindowStore_GetByHwnd(hwnd) {
    global gWS_Store
    return gWS_Store.Has(hwnd) ? gWS_Store[hwnd] : 0
}

WindowStore_GetProjection(opts := 0) {
    ; Returns {rev, hwnds, items?, meta}
    global gWS_Config
    if (!IsObject(opts))
        opts := Map()

    filter := _WS_DefaultFilter()
    if (opts.Has("filter") && IsObject(opts.filter))
        filter := _WS_MergeFilter(filter, opts.filter)

    sortKey := opts.Has("sort") ? _WS_ValidateSort(opts.sort) : (gWS_Config["DefaultSort"] . "")
    cols    := opts.Has("columns") ? _WS_ValidateColumns(opts.columns) : "hwndsOnly"

    ; Build filtered list of records (presentOnly by default, etc).
    recs := _WS_FilterRecords(filter)

    ; Sort in-place per sortKey.
    _WS_SortRecords(recs, sortKey)

    ; Build outputs.
    hwnds := []
    for _, r in recs
        hwnds.Push(r.hwnd)

    out := { rev: WindowStore_GetRev(), hwnds: hwnds, meta: {
        count: _WS_TotalCount(), filteredCount: hwnds.Length, sortKey: sortKey
    }}

    if (cols = "items") {
        items := []
        total := recs.Length
        i := 1
        while (i <= total) {
            items.Push(_WS_ToGuiItem(recs[i], i, total))
            i += 1
        }
        out.items := items
    }
    return out
}

WindowStore_GetIndexOf(hwnd, opts := 0) {
    ; 1-based index of hwnd in the projection defined by opts; 0 if not present.
    proj := WindowStore_GetProjection(opts)
    i := 1
    while (i <= proj.hwnds.Length) {
        if (proj.hwnds[i] = hwnd)
            return i
        i += 1
    }
    return 0
}

;============================= INTERNAL HELPERS ================================

_WS_QueuePid(pid) {
    global gWS_Q_Pid
    if (pid > 0 && !gWS_Q_Pid.Has(pid))
        gWS_Q_Pid[pid] := true
}

_WS_QueueIcon(hwnd) {
    global gWS_Q_Icon
    if (hwnd > 0 && !gWS_Q_Icon.Has(hwnd))
        gWS_Q_Icon[hwnd] := true
}

_WS_QueueWS(hwnd) {
    global gWS_Q_WS
    if (hwnd > 0 && !gWS_Q_WS.Has(hwnd))
        gWS_Q_WS[hwnd] := true
}

_WS_RefreshNeeds(rec) {
    now := _WS_Now()

    ; --- Process name need ---
    needProc := (rec.pid > 0 && rec.processName = "")
    if (needProc && !rec.needsProcName)
        _WS_QueuePid(rec.pid)
    rec.needsProcName := needProc

    ; --- Workspace need ---
    needWS := (rec.workspaceId = "" && rec.workspaceName = "")
    if (needWS && !rec.needsWS)
        _WS_QueueWS(rec.hwnd)
    rec.needsWS := needWS

    ; --- Icon need (with cooldown + in-flight semantics) ---
    if (rec.iconHicon = 0) {
        canEnqueue := (rec.iconCooldownUntilTick = 0 || now >= rec.iconCooldownUntilTick)
        if (!rec.needsIcon && canEnqueue) {
            _WS_QueueIcon(rec.hwnd)  ; will be marked in-flight on pop
            rec.needsIcon := true
        } else {
            ; Either still cooling down or already in-flight; keep false so a future
            ; tickle after cooldown can re-enqueue.
            if (!canEnqueue)
                rec.needsIcon := false
        }
    } else {
        rec.needsIcon := false
    }
}

WindowStore_RequestIcon(hwnd) {
    global gWS_Store
    hwnd := hwnd + 0
    if (!gWS_Store.Has(hwnd))
        return false
    rec := gWS_Store[hwnd]
    rec.iconCooldownUntilTick := 0
    if (!rec.needsIcon) {
        _WS_QueueIcon(hwnd)
        rec.needsIcon := true
    }
    return true
}


_WS_AdjustPidRefs(oldPid, newPid) {
    global gWS_ProcRef, gWS_ProcCache
    if (oldPid = newPid)
        return
    if (oldPid > 0 && gWS_ProcRef.Has(oldPid)) {
        gWS_ProcRef[oldPid] -= 1
        if (gWS_ProcRef[oldPid] <= 0) {
            gWS_ProcRef.Delete(oldPid)
            ; Optional: drop cached name when last ref leaves
            if (gWS_ProcCache.Has(oldPid))
                gWS_ProcCache.Delete(oldPid)
        }
    }
    if (newPid > 0) {
        if (!gWS_ProcRef.Has(newPid))
            gWS_ProcRef[newPid] := 0
        gWS_ProcRef[newPid] += 1
    }
}

_WS_RequestRevBump() {
    global gWS_Batching, gWS_PendingRevBump, gWS_Rev
    if (gWS_Batching) {
        gWS_PendingRevBump := true
    } else {
        gWS_Rev += 1
    }
}

_WS_Now() {
    return A_TickCount + 0
}

_WS_Basename(path) {
    if (!path)
        return ""
    SplitPath(path, &fname)
    return fname
}

_WS_NormalizeTitle(s) {
    global gWS_Config
    if (s = "")
        return ""
    out := s . ""
    ; Replace CR/LF/tabs with spaces
    out := StrReplace(out, "`r", " ")
    out := StrReplace(out, "`n", " ")
    out := StrReplace(out, "`t", " ")
    if gWS_Config["TitleCollapseSpaces"] {
        ; collapse runs of spaces
        while InStr(out, "  ")
            out := StrReplace(out, "  ", " ")
    }
    out := Trim(out, " `t")
    max := gWS_Config["NormalizeTitleMax"] + 0
    if (max > 0 && StrLen(out) > max)
        out := SubStr(out, 1, max)
    return out
}

_WS_StateCanonical(s) {
    if (!s)
        return "Unknown"
    t := StrLower(Trim(s))
    if (t = "workspaceshowing")    {
      return "WorkspaceShowing"
    }
    if (t = "workspaceminimized")  {
      return "WorkspaceMinimized"
    }
    if (t = "workspacehidden")     {
      return "WorkspaceHidden"
    }
    if (t = "otherworkspace")      {
      return "OtherWorkspace"
    }
    return "Unknown"
}

_WS_NewRecord(hwnd) {
    now := _WS_Now()
    return {
        ; Identity / process
        hwnd: hwnd + 0,
        pid: 0,
        class: "",
        exePath: "",
        processName: "",

        ; Titles
        titleRaw: "",
        title: "",

        ; State
        state: "Unknown",
        zOrder: 0,
        isVisible: false,
        isMinimized: false,
        isOnCurrentWorkspace: false,
        isFocused: false,
        isBlacklisted: false,

        ; Workspace
        workspaceId: "",
        workspaceName: "",

        ; MRU / activity
        lastActivatedTick: 0,
        totalActiveMs: 0,
        mruRank: 0,

        ; Icons
        iconHicon: 0,
        iconKey: "",
        ; Pump control
        needsIcon: false,
        iconCooldownUntilTick: 0,

        ; Sweep / lifecycle
        present: true,
        presentNow: true,
        lastSeenScanId: 0,
        lastSeenSweep: 0,
        lastSeenTick: now,
        missingSinceTick: 0,
        firstSeenTick: now,

        ; Needs flags (other)
        needsProcName: false,
        needsWS: false,

        ; Record bookkeeping
        rev: 0
    }
}


WindowStore_SetOwnershipPolicy(mode := "off", allowedMap := 0) {
    global gWS_OwnershipMode, gWS_AllowedFields

    m := StrLower(mode . "")
    if (m != "off" && m != "warn" && m != "strict")
        m := "off"
    gWS_OwnershipMode := m

    ; Build defaults if not provided
    if (!IsObject(allowedMap)) {
        allowedMap := Map()
        allowedMap["winenum"] := _WS_MakeKeySet([
            "pid","class","title","titleRaw","state","zOrder",
            "isVisible","isMinimized","isBlacklisted",
            "present","presentNow","lastSeenScanId","lastSeenTick",
            ; optional extras some enumerators may send:
            "isCloaked","altTabEligible"
        ])
        allowedMap["mru"] := _WS_MakeKeySet([
            "lastActivatedTick","isFocused","totalActiveMs","mruRank"
        ])
        allowedMap["komorebi"] := _WS_MakeKeySet([
            "workspaceId","workspaceName","isOnCurrentWorkspace"
        ])
        allowedMap["icon"] := _WS_MakeKeySet([
            "iconHicon","iconKey"
        ])
        allowedMap["proc"] := _WS_MakeKeySet([
            "processName","exePath"
        ])
        ; You can add more sources later (e.g., "gui", "rules", etc.)
    }

    ; Normalize to Map(source -> Map(key -> true))
    tmp := Map()
    for src, set in allowedMap {
        if IsObject(set) {
            tmp[src] := _WS_MakeKeySet(set)
        }
    }
    gWS_AllowedFields := tmp
}

_WS_MakeKeySet(arr) {
    ; arr can be an Array or any iterable of strings
    s := Map()
    for _, k in arr {
        if (k != "")
            s[k . ""] := true
    }
    return s
}

_WS_OwnerAllowed(source, key) {
    global gWS_AllowedFields
    src := source . ""
    if (src = "" || !gWS_AllowedFields.Has(src))
        return false
    set := gWS_AllowedFields[src]
    return set.Has(key . "")
}

_WS_LogOwnerViolation(source, key, mode) {
    ; Keep logging light; can be improved to buffered log if needed.
    OutputDebug "WindowStore Ownership [" mode "]: source='" source "' cannot set field '" key "'"
}

_WS_FilterPatchByOwnership(patch, source) {
    global gWS_OwnershipMode
    if (!IsObject(patch))
        return patch
    mode := gWS_OwnershipMode
    if (mode = "off" || source = "")
        return patch

    if (mode = "warn") {
        for k, _ in patch {
            if !_WS_OwnerAllowed(source, k) {
                _WS_LogOwnerViolation(source, k, mode)
            }
        }
        return patch  ; accept all
    }

    ; strict: drop non-owned fields
    filtered := {}
    for k, v in patch {
        if _WS_OwnerAllowed(source, k) {
            filtered.%k% := v
        } else {
            _WS_LogOwnerViolation(source, k, mode)
        }
    }
    return filtered
}


; Merge patch object into rec. Returns true if any meaningful field changed.
_WS_MergeInto(rec, patch) {
    changed := false

    ; Identity / process
    if (patch.Has("pid"))           changed := changed || _WS_AssignIfDiff(rec, "pid", patch.pid + 0)
    if (patch.Has("class"))         changed := changed || _WS_AssignIfDiff(rec, "class", patch.class . "")
    if (patch.Has("exePath")) {
        path := patch.exePath . ""
        pname := _WS_Basename(path)
        changed := changed || _WS_AssignIfDiff(rec, "exePath", path)
        if (pname != "" && rec.processName != pname)
            rec.processName := pname, changed := true
    }
    if (patch.Has("processName"))   changed := changed || _WS_AssignIfDiff(rec, "processName", patch.processName . "")

    ; Titles
    if (patch.Has("titleRaw")) {
        raw := patch.titleRaw . ""
        norm := _WS_NormalizeTitle(raw)
        if (rec.titleRaw != raw)  rec.titleRaw := raw, changed := true
        if (rec.title    != norm) rec.title    := norm, changed := true
    } else if (patch.Has("title")) {
        norm := _WS_NormalizeTitle(patch.title . "")
        if (rec.title != norm) rec.title := norm, changed := true
    }

    ; State
    if (patch.Has("state"))                 changed := changed || _WS_AssignIfDiff(rec, "state", _WS_StateCanonical(patch.state))
    if (patch.Has("zOrder"))                changed := changed || _WS_AssignIfDiff(rec, "zOrder", patch.zOrder + 0)
    if (patch.Has("isVisible"))             changed := changed || _WS_AssignIfDiff(rec, "isVisible", !!patch.isVisible)
    if (patch.Has("isMinimized"))           changed := changed || _WS_AssignIfDiff(rec, "isMinimized", !!patch.isMinimized)
    if (patch.Has("isOnCurrentWorkspace"))  changed := changed || _WS_AssignIfDiff(rec, "isOnCurrentWorkspace", !!patch.isOnCurrentWorkspace)
    if (patch.Has("isFocused"))             changed := changed || _WS_AssignIfDiff(rec, "isFocused", !!patch.isFocused)
    if (patch.Has("isBlacklisted"))         changed := changed || _WS_AssignIfDiff(rec, "isBlacklisted", !!patch.isBlacklisted)

    ; Workspace
    if (patch.Has("workspaceId"))           changed := changed || _WS_AssignIfDiff(rec, "workspaceId", patch.workspaceId)
    if (patch.Has("workspaceName"))         changed := changed || _WS_AssignIfDiff(rec, "workspaceName", patch.workspaceName . "")

    ; MRU / activity
    if (patch.Has("lastActivatedTick")) {
        t := patch.lastActivatedTick + 0
        if (t != rec.lastActivatedTick)
            rec.lastActivatedTick := t, changed := true
    }
    if (patch.Has("totalActiveMs"))         changed := changed || _WS_AssignIfDiff(rec, "totalActiveMs", patch.totalActiveMs + 0)
    if (patch.Has("mruRank"))               changed := changed || _WS_AssignIfDiff(rec, "mruRank", patch.mruRank + 0)

    ; Icons
    if (patch.Has("iconHicon")) {
        newH := patch.iconHicon + 0
        if (newH != rec.iconHicon) {
            if (rec.iconHicon)
                try DllCall("user32\DestroyIcon", "ptr", rec.iconHicon)
            rec.iconHicon := newH, changed := true
        }
    }
    if (patch.Has("iconKey"))               changed := changed || _WS_AssignIfDiff(rec, "iconKey", patch.iconKey . "")
    if (patch.Has("iconCooldownUntilTick")) changed := changed || _WS_AssignIfDiff(rec, "iconCooldownUntilTick", patch.iconCooldownUntilTick + 0)

    return changed
}


_WS_AssignIfDiff(rec, key, val) {
    if (!rec.Has(key) || rec.%key% != val) {
        rec.%key% := val
        return true
    }
    return false
}

_WS_DefaultFilter() {
    return {
        presentOnly: true,
        currentWorkspaceOnly: false,
        blacklistMode: "exclude",
        classes: [],
        pids: []
    }
}

_WS_MergeFilter(base, override) {
    out := Map()
    ; copy base first
    for k, v in base
        out[k] := v
    ; overlay any provided keys
    for k, v in override
        out[k] := v
    ; normalize values
    out.presentOnly := !!out.presentOnly
    out.currentWorkspaceOnly := !!out.currentWorkspaceOnly
    bm := StrLower(out.blacklistMode . "")
    if (bm != "include" && bm != "only")
        bm := "exclude"
    out.blacklistMode := bm
    if !IsObject(out.classes) out.classes := []
    if !IsObject(out.pids)    out.pids := []
    return out
}

_WS_ValidateSort(s) {
    t := StrUpper(Trim(s . ""))
    if (t = "MRU" || t = "Z" || t = "TITLE" || t = "PID" || t = "PROCESSNAME")
        return t
    return "MRU"
}

_WS_ValidateColumns(c) {
    t := StrLower(Trim(c . ""))
    if (t = "items")
        return "items"
    return "hwndsOnly"
}

_WS_FilterRecords(filter) {
    global gWS_Store
    recs := []
    for hwnd, rec in gWS_Store {
        if (filter.presentOnly && !rec.present)
            continue
        if (filter.currentWorkspaceOnly && !rec.isOnCurrentWorkspace)
            continue
        if (filter.blacklistMode = "exclude" && rec.isBlacklisted)
            continue
        if (filter.blacklistMode = "only" && !rec.isBlacklisted)
            continue
        if (filter.classes.Length) {
            keep := false
            for _, cls in filter.classes
                if (rec.class = (cls . "")) {
                    keep := true
                    break
                }
            if !keep
                continue
        }
        if (filter.pids.Length) {
            keep2 := false
            for _, p in filter.pids
                if (rec.pid = (p + 0)) {
                    keep2 := true
                    break
                }
            if !keep2
                continue
        }
        recs.Push(rec)
    }
    return recs
}

_WS_SortRecords(recs, sortKey) {
    ; In-place sort of an array of record objects.
    if (sortKey = "MRU") {
        recs.Sort((a, b) => _WS_CompareDesc(a.lastActivatedTick, b.lastActivatedTick, a, b))
        return
    }
    if (sortKey = "Z") {
        ; Lower Z-order at front (or reverse if your Z means “on top” is smaller).
        recs.Sort((a, b) => _WS_CompareAsc(a.zOrder, b.zOrder, a, b))
        return
    }
    if (sortKey = "TITLE") {
        recs.Sort((a, b) => _WS_CompareStrAsc(a.title, b.title, a, b))
        return
    }
    if (sortKey = "PID") {
        recs.Sort((a, b) => _WS_CompareAsc(a.pid, b.pid, a, b))
        return
    }
    if (sortKey = "PROCESSNAME") {
        recs.Sort((a, b) => _WS_CompareStrAsc(a.processName, b.processName, a, b))
        return
    }
    ; default fallback
    recs.Sort((a, b) => _WS_CompareDesc(a.lastActivatedTick, b.lastActivatedTick, a, b))
}

_WS_CompareAsc(x, y, a, b) {
    if (x < y)  {
      return -1
    }
    if (x > y)  {
      return 1
    }
    ; tie-breakers for stability
    if (a.hwnd < b.hwnd) {
      return -1
    }
    if (a.hwnd > b.hwnd) {
      return 1
    }
    return 0
}
_WS_CompareDesc(x, y, a, b) {
    if (x > y)  {
      return -1
    }
    if (x < y)  {
      return 1
    }
    if (a.hwnd < b.hwnd) {
      return -1
    }
    if (a.hwnd > b.hwnd) {
      return 1
    }
    return 0
}
_WS_CompareStrAsc(x, y, a, b) {
    sx := x . "", sy := y . ""
    c := StrCompare(sx, sy, true)  ; case-insensitive
    if (c < 0) {
      return -1
    }
    if (c > 0) {
      return 1
    }
    if (a.hwnd < b.hwnd) {
      return -1
    }
    if (a.hwnd > b.hwnd) {
      return 1
    }
    return 0
}

_WS_TotalCount() {
    global gWS_Store
    c := 0
    for _, _ in gWS_Store
        c += 1
    return c
}

; Convert a record to a “raw GUI item” expected by NewGUI__BuildRowModel in your newgui.ahk.
_WS_ToGuiItem(rec, idx, total) {
    ; Subtext comes from state (shortened later by GUI code if configured).
    wsName := rec.workspaceName ? rec.workspaceName : ""
    return {
        Title: rec.title != "" ? rec.title : (rec.processName != "" ? rec.processName : "(untitled)"),
        State: rec.state,
        Hwnd:  rec.hwnd,
        Pid:   rec.pid,
        ZOrder: rec.zOrder,
        Class: rec.class,
        Workspace: wsName,

        ; optional extras (GUI won’t break if unused)
        ProcessName: rec.processName,
        WorkspaceId: rec.workspaceId,
        IsBlacklisted: rec.isBlacklisted,
        IsVisible: rec.isVisible,
        IsMinimized: rec.isMinimized,
        IsOnCurrentWorkspace: rec.isOnCurrentWorkspace,
        IsFocused: rec.isFocused,

        ; icon handle is available if you wire GUI to read it; otherwise the
        ; existing icon pump caches via hwnd anyway.
        HICON: rec.iconHicon
    }
}
