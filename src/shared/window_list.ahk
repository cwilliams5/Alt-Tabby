#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Expected: included before store/pump files that define callbacks

; ============================================================
; WindowList - Core window data structure
; ============================================================
; Core data layer: Maps, upsert, remove, query, work queues, caches.
; No delta building, no IPC plumbing.

global WS_SCAN_ID_MAX := 0x7FFFFFFF

; Canonical list of fields copied from store records into display list items.
; Used by static analysis (check_batch_patterns) to verify _WS_ToItem stays in sync.
; hwnd is always included separately as the record key.
global DISPLAY_FIELDS := ["title", "class", "pid", "z", "lastActivatedTick",
    "isFocused", "isCloaked", "isMinimized", "workspaceName", "workspaceId",
    "isOnCurrentWorkspace", "processName", "iconHicon",
    "monitorHandle", "monitorLabel"]

global gWS_Store := Map()
global gWS_Rev := 0
global gWS_ScanId := 0
global gWS_Config := Map()
global gWS_Meta := Map()

; Display list cache state (owned exclusively by WL_GetDisplayList)
global gWS_DLCache_Items := ""         ; Cached transformed items (result of _WS_ToItem)
global gWS_DLCache_ItemsMap := Map()   ; Persistent hwnd→item Map (avoids O(n) rebuild per push cycle)
global gWS_DLCache_OptsKey := ""       ; Opts key used for cache validation
global gWS_DLCache_SortedRecs := ""    ; Cached sorted record refs for Path 2 (content-only refresh)

; Two-level display list cache dirty tracking:
;   gWS_SortOrderDirty — set when sort/filter-affecting fields change (needs full rebuild)
;   gWS_ContentDirty — set when content-only fields change (can skip re-sort)
;   gWS_MRUBumpOnly — when true, sort-dirty was caused ONLY by MRU fields (lastActivatedTick/isFocused)
;     This enables Path 1.5: incremental move-to-front instead of full rebuild.
;     Reset to false if any non-MRU sort-affecting field changes in the same cycle.
global gWS_SortOrderDirty := true
global gWS_ContentDirty := true
global gWS_MRUBumpOnly := false

; Mark store as needing re-sort and content update.
; mruOnly: true if ONLY MRU fields changed (enables incremental move-to-front in display list).
_WS_MarkDirty(mruOnly := false) {
    global gWS_SortOrderDirty, gWS_ContentDirty, gWS_MRUBumpOnly
    if (!gWS_SortOrderDirty)
        gWS_MRUBumpOnly := mruOnly
    else if (!mruOnly)
        gWS_MRUBumpOnly := false
    gWS_SortOrderDirty := true
    gWS_ContentDirty := true
}

; Fields that affect sort order or filter membership — trigger full cache rebuild (Path 3)
global gWS_SortAffectingFields := Map(
    "lastActivatedTick", true, "z", true,
    "isOnCurrentWorkspace", true, "isCloaked", true, "isMinimized", true,
    "processName", true)  ; processName affects ProcessName sort mode

; Subset of sort-affecting fields that only affect MRU order (not filtering/membership).
; When ONLY these fields change, Path 1.5 can do an incremental move-to-front
; instead of a full Path 3 rebuild.
global gWS_MRUOnlyFields := Map("lastActivatedTick", true)

; Fields that affect display list content only (not sort/filter) — trigger content refresh (Path 2)
; Fresh _WS_ToItem copies are created from live records, avoiding stale cache data.
; NOTE: "title" is promoted to sort-affecting when Title sort mode is active (see gWS_TitleSortActive).
global gWS_ContentOnlyFields := Map(
    "iconHicon", true, "title", true, "class", true,
    "pid", true, "workspaceName", true, "workspaceId", true,
    "isFocused", true, "monitorHandle", true, "monitorLabel", true)

; When true, "title" field changes trigger sort rebuild instead of content-only refresh.
; Set by WL_GetDisplayList when sort="Title" is used, cleared on next WL_GetDisplayList
; with a different sort mode. This ensures title changes update sort order correctly.
global gWS_TitleSortActive := false

; Diagnostic: track what's causing rev bumps
global gWS_DiagChurn := Map()  ; field -> count of changes
global gWS_DiagSource := Map() ; source -> count of rev bumps

; Work queues for pumps
global gWS_IconQueue := []         ; hwnds needing icons
global gWS_PidQueue := []          ; pids needing process info
global gWS_ZQueue := []            ; hwnds needing Z-order (triggers winenum pump)
global gWS_IconQueueDedup := Map()   ; hwnd -> true (prevents duplicate queue entries)
global gWS_PidQueueDedup := Map()    ; pid -> true (prevents duplicate queue entries)
global gWS_ZQueueDedup := Map()      ; hwnd -> true (prevents duplicate queue entries)

; Caches
global gWS_ExeIconCache := Map()   ; exe path -> HICON (master copy)
global gWS_ProcNameCache := Map()  ; pid -> { name: string, tick: A_TickCount }

gWS_Config["MissingTTLms"] := 1200  ; Default, overridden from cfg in WL_Init()
gWS_Meta["currentWSId"] := ""
gWS_Meta["currentWSName"] := ""

; Display-list-level dirty tracking: hwnds with any display-visible field change
; since the last WL_GetDisplayList call. Persists until display list cache is rebuilt.
; Used by Path 1.5 and Path 2 for
; selective _WS_ToItem refresh (only recreate items whose data actually changed).
global gWS_DirtyHwnds := Map()

; --- Producer → MainProcess notification callbacks ---
; Producers call these instead of directly touching GUI state.
; gui_main.ahk registers the implementations during init.
global gWS_OnStoreChanged := 0           ; fn(isStructural) — called by producers when store is modified
global gWS_OnWorkspaceChanged := 0       ; fn() — called by KomorebiSub when workspace changes

; Wire producer notification callbacks (called by gui_main during init)
WL_SetCallbacks(onStoreChanged, onWorkspaceChanged) {
    global gWS_OnStoreChanged, gWS_OnWorkspaceChanged
    gWS_OnStoreChanged := onStoreChanged
    gWS_OnWorkspaceChanged := onWorkspaceChanged
}

; Fields that are internal tracking and should not bump rev when changed
global gWS_InternalFields := Map("iconCooldownUntilTick", true, "lastSeenScanId", true, "lastSeenTick", true, "missingSinceTick", true, "iconGaveUp", true, "iconMethod", true, "iconLastRefreshTick", true)

; Safely snapshot Map keys for iteration (prevents modification during iteration)
; Returns an Array of keys. Caller can iterate safely after Critical section ends.
WS_SnapshotMapKeys(mapObj) {
    Critical "On"
    keys := []
    for k, _ in mapObj
        keys.Push(k)
    Critical "Off"
    return keys
}

; Helper to delete a window from the store with proper icon cleanup.
; Caller MUST hold Critical when calling this function.
_WS_DeleteWindow(hwnd) {
    global gWS_Store, gWS_DLCache_ItemsMap
    try IconPump_CleanupWindow(hwnd)
    gWS_Store.Delete(hwnd)
    ; Prune stale entry from display list cache to prevent unbounded growth
    ; between Path 3 rebuilds (Path 1.5 MRU move-to-front preserves the map)
    try gWS_DLCache_ItemsMap.Delete(hwnd)
}

WL_Init(config := 0) {
    global gWS_Config, cfg
    if IsObject(config) {
        for k, v in config
            gWS_Config[k] := v
    }
    ; Load TTL from config if available (ConfigLoader_Init sets cfg.WinEnumMissingWindowTTLMs)
    if (IsObject(cfg) && cfg.HasOwnProp("WinEnumMissingWindowTTLMs"))
        gWS_Config["MissingTTLms"] := cfg.WinEnumMissingWindowTTLMs
}

WL_BeginScan() {
    global gWS_ScanId, WS_SCAN_ID_MAX
    if (gWS_ScanId = WS_SCAN_ID_MAX)
        gWS_ScanId := 0
    gWS_ScanId += 1
    return gWS_ScanId
}

WL_EndScan(graceMs := "") {
    Profiler.Enter("WL_EndScan") ; @profile
    global gWS_Store, gWS_ScanId, gWS_Config, gWS_Rev, gWS_SortOrderDirty, gWS_ContentDirty, gWS_MRUBumpOnly
    now := A_TickCount
    ttl := (graceMs != "" ? graceMs + 0 : gWS_Config["MissingTTLms"] + 0)

    ; RACE FIX: Snapshot keys to prevent iteration-during-modification
    hwnds := WS_SnapshotMapKeys(gWS_Store)

    ; Phase 1: Classify windows (reads + DllCalls, no Critical needed)
    ; Matches two-phase pattern from WL_ValidateExistence / WL_PurgeBlacklisted
    toRemove := []
    toMarkMissing := []
    komorebiKeep := []
    for _, hwnd in hwnds {
        if (!gWS_Store.Has(hwnd))
            continue  ; May have been removed by another producer
        rec := gWS_Store[hwnd]
        if (rec.lastSeenScanId != gWS_ScanId) {
            ; Komorebi-managed windows are "present" even if winenum doesn't see them
            if (rec.HasOwnProp("workspaceName") && rec.workspaceName != "") {
                komorebiKeep.Push(hwnd)
                continue
            }
            if (rec.presentNow) {
                toMarkMissing.Push(hwnd)
            } else if (rec.missingSinceTick && (now - rec.missingSinceTick) >= ttl) {
                if (!DllCall("user32\IsWindow", "ptr", hwnd, "int"))
                    toRemove.Push(hwnd)
                ; else: window still exists — reset in Phase 2
            }
        }
    }

    ; Phase 2: Apply mutations under Critical (_WS_DeleteWindow contract requires it)
    Critical "On"
    removed := 0
    changed := false

    ; Mark komorebi windows as present, preserve their Z value
    for _, hwnd in komorebiKeep {
        if (!gWS_Store.Has(hwnd))
            continue  ; lint-ignore: critical-section
        rec := gWS_Store[hwnd]
        rec.lastSeenScanId := gWS_ScanId
        rec.presentNow := true
        rec.present := true
    }

    ; Mark missing windows (first miss starts the TTL clock)
    for _, hwnd in toMarkMissing {
        if (!gWS_Store.Has(hwnd))
            continue  ; lint-ignore: critical-section
        rec := gWS_Store[hwnd]
        if (rec.presentNow) {
            rec.presentNow := false
            rec.present := false
            rec.missingSinceTick := now
            changed := true
        }
    }

    ; Remove dead windows (re-check IsWindow in case window reappeared between phases)
    for _, hwnd in toRemove {
        if (!gWS_Store.Has(hwnd))
            continue  ; lint-ignore: critical-section
        if (!DllCall("user32\IsWindow", "ptr", hwnd, "int")) {
            _WS_DeleteWindow(hwnd)
            removed += 1
            changed := true
        } else {
            ; Window reappeared — reset presence, winenum will find it next scan
            rec := gWS_Store[hwnd]
            rec.presentNow := true
            rec.present := true
            rec.missingSinceTick := 0
        }
    }

    if (changed) {
        _WS_MarkDirty()  ; Structural change (window removal)
        _WS_BumpRev("EndScan")
    }
    Critical "Off"
    Profiler.Leave() ; @profile
    return { removed: removed, rev: gWS_Rev }
}

WL_UpsertWindow(records, source := "") {
    Profiler.Enter("WL_UpsertWindow") ; @profile
    global cfg, gWS_Store, gWS_Rev, gWS_ScanId, gWS_DiagChurn, gWS_SortOrderDirty, gWS_ContentDirty
    global gWS_SortAffectingFields, gWS_ContentOnlyFields, gWS_InternalFields, gWS_MRUBumpOnly, FR_EV_WINDOW_ADD, gFR_Enabled
    global gWS_DirtyHwnds
    if (!IsObject(records) || !(records is Array)) {
        Profiler.Leave() ; @profile
        return { added: 0, updated: 0, rev: gWS_Rev }
    }
    added := 0
    updated := 0
    sortDirty := false
    contentDirty := false
    ; Collect rows needing enrichment (enqueued after Critical section ends)
    rowsToEnqueue := []

    ; LATENCY FIX: Single Critical section for entire batch (was per-record).
    ; For 30 windows this saves ~58 Critical enter/exit transitions (~1-2ms).
    ; This matches the BatchUpdateFields pattern which already uses single-section.
    ; Enrichment enqueue happens AFTER Critical ends (accesses different queues).
    Critical "On"
    for _, rec in records {
        if (!IsObject(rec))
            continue  ; lint-ignore: critical-section
        hwnd := rec.Get("hwnd", 0) + 0
        if (!hwnd)
            continue  ; lint-ignore: critical-section
        isNew := !gWS_Store.Has(hwnd)
        if (isNew) {
            gWS_Store[hwnd] := _WS_NewRecord(hwnd)
            added += 1
            if (gFR_Enabled)
                FR_Record(FR_EV_WINDOW_ADD, hwnd, gWS_Store.Count)
        }
        row := gWS_Store[hwnd]

        ; If window has komorebi workspace data, don't let winenum overwrite state/isCloaked
        ; Komorebi is authoritative for workspace state
        hasKomorebiWs := row.HasOwnProp("workspaceName") && row.workspaceName != ""

        ; Track if any field actually changed
        rowChanged := false
        if (rec is Map) {
            if (isNew) {
                ; New record — all fields are different from defaults by definition.
                ; Skip per-field HasOwnProp/!= checks. Just assign and mark dirty.
                for k, v in rec {
                    ; Guard kept even for new records: hasKomorebiWs is always false here
                    ; (workspaceName starts as "") but guards against future call ordering
                    ; changes where a record could be pre-populated before UpsertWindow.
                    if (hasKomorebiWs && (k = "isCloaked" || k = "isOnCurrentWorkspace"))
                        continue  ; lint-ignore: critical-section
                    row.%k% := v
                }
                rowChanged := true
                sortDirty := true  ; New record always affects sort (membership change)
            } else {
                ; Existing record — check each field for actual changes
                for k, v in rec {
                    ; Preserve komorebi workspace state if winenum tries to overwrite
                    if (hasKomorebiWs && (k = "isCloaked" || k = "isOnCurrentWorkspace"))
                        continue  ; lint-ignore: critical-section
                    ; Only update if value differs
                    if (!row.HasOwnProp(k) || row.%k% != v) {
                        ; Diagnostic: track which fields trigger changes (skip for new records)
                        if (!isNew && cfg.DiagChurnLog)
                            gWS_DiagChurn[k] := gWS_DiagChurn.Get(k, 0) + 1
                        row.%k% := v
                        rowChanged := true
                        ; Mark dirty for delta tracking (new records or non-internal field changes)
                        if (gWS_SortAffectingFields.Has(k))
                            sortDirty := true
                        else if (gWS_ContentOnlyFields.Has(k))
                            contentDirty := true
                        ; Mark hwnd dirty for cosmetic patch during ACTIVE state
                        if (!gWS_InternalFields.Has(k))
                            gWS_DirtyHwnds[hwnd] := true
                    }
                }
            }
        } else {
            continue  ; lint-ignore: critical-section (skip non-Map records)
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

        ; Collect for enrichment (enqueued after Critical ends)
        rowsToEnqueue.Push(row)
    }
    if (added || sortDirty) {
        _WS_MarkDirty()  ; Structural change (new windows or sort-affecting fields via upsert)
    } else if (contentDirty) {
        gWS_ContentDirty := true
    }
    if (added || updated) {
        _WS_BumpRev("UpsertWindow:" . source)
    }
    ; RACE FIX: Update peak windows inside Critical - producers can interrupt after release
    if (added > 0)
        Stats_UpdatePeakWindows(gWS_Store.Count)
    Critical "Off"

    ; Enqueue for enrichment OUTSIDE Critical (queue operations have their own Critical)
    for _, row in rowsToEnqueue
        _WS_EnqueueIfNeeded(row)

    Profiler.Leave() ; @profile
    return { added: added, updated: updated, rev: gWS_Rev }
}

; Helper to apply a patch (Map or plain Object) to a store row
; Sets row.%k% := v for each field in patch, tracks changed/projDirty flags
; Normalizes Map patches to Object at entry to eliminate duplicate code branches.
; Parameters:
;   row - Store record to update
;   patch - Map or Object with field:value pairs
;   hwnd - Window handle (for dirty tracking)
; Returns: { changed: bool, sortDirty: bool, contentDirty: bool, mruOnly: bool }
;   mruOnly: true when sortDirty was caused ONLY by MRU fields (lastActivatedTick)
_WS_ApplyPatch(row, patch, hwnd) {
    global gWS_InternalFields, gWS_SortAffectingFields, gWS_ContentOnlyFields
    global gWS_MRUOnlyFields, gWS_DirtyHwnds
    global gWS_TitleSortActive
    changed := false
    sortDirty := false
    contentDirty := false
    mruOnly := true  ; Assume MRU-only until a non-MRU sort field changes

    ; Iterate patch fields: Map uses for k,v; Object uses OwnProps().
    ; Direct iteration avoids allocating a temporary Object copy for Map patches.
    if (patch is Map) {
        for k, v in patch {
            if (!row.HasOwnProp(k) || row.%k% != v) {
                row.%k% := v
                if (!gWS_InternalFields.Has(k)) {
                    changed := true
                    gWS_DirtyHwnds[hwnd] := true
                }
                if (gWS_SortAffectingFields.Has(k)) {
                    sortDirty := true
                    if (!gWS_MRUOnlyFields.Has(k))
                        mruOnly := false
                } else if (k = "title" && gWS_TitleSortActive) {
                    sortDirty := true
                    mruOnly := false
                } else if (!contentDirty && gWS_ContentOnlyFields.Has(k)) {
                    contentDirty := true
                }
            }
        }
    } else if (IsObject(patch)) {
        for k in patch.OwnProps() {
            v := patch.%k%
            if (!row.HasOwnProp(k) || row.%k% != v) {
                row.%k% := v
                if (!gWS_InternalFields.Has(k)) {
                    changed := true
                    gWS_DirtyHwnds[hwnd] := true
                }
                if (gWS_SortAffectingFields.Has(k)) {
                    sortDirty := true
                    if (!gWS_MRUOnlyFields.Has(k))
                        mruOnly := false
                } else if (k = "title" && gWS_TitleSortActive) {
                    sortDirty := true
                    mruOnly := false
                } else if (!contentDirty && gWS_ContentOnlyFields.Has(k)) {
                    contentDirty := true
                }
            }
        }
    }
    ; mruOnly is meaningful only when sortDirty is true
    if (!sortDirty)
        mruOnly := false
    return { changed: changed, sortDirty: sortDirty, contentDirty: contentDirty, mruOnly: mruOnly }
}

WL_UpdateFields(hwnd, patch, source := "", returnRow := false) {
    global gWS_Store, gWS_Rev, gWS_SortOrderDirty, gWS_ContentDirty
    global gWS_MRUBumpOnly
    ; RACE FIX: Wrap body in Critical to prevent two producers from interleaving
    ; check-then-set on the same hwnd's fields (timer/hotkey interruption)
    Critical "On"
    hwnd := hwnd + 0
    if (!gWS_Store.Has(hwnd))
        return { changed: false, exists: false, rev: gWS_Rev }  ; lint-ignore: critical-section (AHK v2 auto-releases Critical on return)
    row := gWS_Store[hwnd]

    ; Apply patch using shared helper
    result := _WS_ApplyPatch(row, patch, hwnd)
    changed := result.changed

    if (result.sortDirty) {
        _WS_MarkDirty(result.mruOnly)
    } else if (result.contentDirty) {
        gWS_ContentDirty := true
    }
    if (changed) {
        _WS_BumpRev("UpdateFields:" . source)
    }
    ; Return row when requested to avoid redundant GetByHwnd lookups
    if (returnRow)
        return { changed: changed, exists: true, rev: gWS_Rev, row: row }  ; lint-ignore: critical-section
    return { changed: changed, exists: true, rev: gWS_Rev }  ; lint-ignore: critical-section (AHK v2 auto-releases Critical on return)
}

; Batch update multiple windows with a single rev bump
; patches: Map of hwnd -> patch (object with field: value)
; Returns: { changed: count, rev: gWS_Rev }
; Use this for bulk operations like workspace switches to minimize Critical section overhead
WL_BatchUpdateFields(patches, source := "") {
    Profiler.Enter("WL_BatchUpdateFields") ; @profile
    global gWS_Store, gWS_Rev, gWS_SortOrderDirty, gWS_ContentDirty
    global gWS_MRUBumpOnly

    Critical "On"
    changedCount := 0
    sortDirty := false
    contentDirty := false
    batchMruOnly := true  ; Tracks MRU-only across all patches in this batch

    for hwnd, patch in patches {
        hwnd := hwnd + 0
        if (!gWS_Store.Has(hwnd))
            continue  ; lint-ignore: critical-section
        row := gWS_Store[hwnd]

        ; Apply patch using shared helper
        result := _WS_ApplyPatch(row, patch, hwnd)
        if (result.changed)
            changedCount++
        if (result.sortDirty) {
            sortDirty := true
            if (!result.mruOnly)
                batchMruOnly := false
        } else if (result.contentDirty) {
            contentDirty := true
        }
    }

    if (sortDirty) {
        _WS_MarkDirty(batchMruOnly)
    } else if (contentDirty) {
        gWS_ContentDirty := true
    }
    if (changedCount > 0)
        _WS_BumpRev("BatchUpdateFields:" . source)

    Critical "Off"
    Profiler.Leave() ; @profile
    return { changed: changedCount, rev: gWS_Rev }
}

WL_RemoveWindow(hwnds, forceRemove := false) {
    global gWS_Store, gWS_Rev, gWS_SortOrderDirty, gWS_ContentDirty, gWS_MRUBumpOnly, FR_EV_WINDOW_REMOVE, gFR_Enabled
    removed := 0
    ; RACE FIX: Wrap delete loop + rev bump in Critical to prevent IPC requests
    ; from seeing inconsistent state (consistent with ValidateExistence/PurgeBlacklisted)
    Critical "On"
    for _, h in hwnds {
        hwnd := h + 0
        if (!gWS_Store.Has(hwnd))
            continue  ; lint-ignore: critical-section
        ; Verify window is actually gone before removing (unless forced)
        if (!forceRemove && DllCall("user32\IsWindow", "ptr", hwnd, "int"))
            continue  ; lint-ignore: critical-section
        _WS_DeleteWindow(hwnd)
        removed += 1
        if (gFR_Enabled)
            FR_Record(FR_EV_WINDOW_REMOVE, hwnd, gWS_Store.Count)
    }
    if (removed) {
        _WS_MarkDirty()  ; Structural change (window removal)
        _WS_BumpRev("RemoveWindow")
    }
    Critical "Off"
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

WL_ValidateExistence() {
    Profiler.Enter("WL_ValidateExistence") ; @profile
    global gWS_Store, gWS_Rev, gWS_SortOrderDirty, gWS_ContentDirty, gWS_MRUBumpOnly, FR_EV_GHOST_PURGE, gFR_Enabled

    ; RACE FIX: Snapshot keys to prevent iteration-during-modification
    hwnds := WS_SnapshotMapKeys(gWS_Store)

    toRemove := []
    for _, hwnd in hwnds {
        if (!gWS_Store.Has(hwnd))
            continue  ; May have been removed by another producer

        ; Check 1: IsWindow returns false for truly destroyed windows
        if (!DllCall("user32\IsWindow", "ptr", hwnd, "int")) {
            toRemove.Push(hwnd)
            continue
        }

        ; Check 1.5: Skip hung windows - subsequent DllCalls (IsWindowVisible, IsIconic)
        ; send window messages that can block 10-50ms on hung windows
        try {
            if (DllCall("user32\IsHungAppWindow", "ptr", hwnd, "int"))
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
        ; Quick visibility check - if visible, definitely keep
        isVisible := DllCall("user32\IsWindowVisible", "ptr", hwnd, "int") != 0
        if (isVisible)
            continue

        ; Check DWM cloaking
        global DWMWA_CLOAKED
        static cloakedBuf := Buffer(4, 0)  ; static: reused per-iteration, repopulated by DllCall
        hr := DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", DWMWA_CLOAKED, "ptr", cloakedBuf.Ptr, "uint", 4, "int")
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

    if (toRemove.Length = 0) {
        Profiler.Leave() ; @profile
        return { removed: 0, rev: gWS_Rev }
    }

    ; RACE FIX: Wrap deletes + rev bump in Critical to prevent IPC requests
    ; from seeing inconsistent state (deleted entries with stale rev)
    Critical "On"
    removed := 0
    for _, hwnd in toRemove {
        _WS_DeleteWindow(hwnd)
        removed += 1
    }

    if (removed > 0) {
        _WS_MarkDirty()  ; Structural change (window removal)
        _WS_BumpRev("ValidateExistence")
        if (gFR_Enabled)
            FR_Record(FR_EV_GHOST_PURGE, removed)
    }
    Critical "Off"

    Profiler.Leave() ; @profile
    return { removed: removed, rev: gWS_Rev }
}

; Purge all windows from store that match the current blacklist
; Called after blacklist reload to remove newly-blacklisted windows
WL_PurgeBlacklisted() {
    global gWS_Store, gWS_Rev, gWS_SortOrderDirty, gWS_ContentDirty, gWS_MRUBumpOnly, FR_EV_BLACKLIST_PURGE, gFR_Enabled
    removed := 0
    toRemove := []

    ; RACE FIX: Snapshot keys to prevent iteration-during-modification
    hwnds := WS_SnapshotMapKeys(gWS_Store)

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

    ; RACE FIX: Wrap deletes + rev bump in Critical to prevent IPC requests
    ; from seeing deleted entries with stale rev (consistent with ValidateExistence)
    Critical "On"
    for _, hwnd in toRemove {
        _WS_DeleteWindow(hwnd)
        removed += 1
    }

    if (removed) {
        _WS_MarkDirty()  ; Structural change (blacklist purge)
        _WS_BumpRev("PurgeBlacklisted")
        if (gFR_Enabled)
            FR_Record(FR_EV_BLACKLIST_PURGE, removed)
    }
    return { removed: removed, rev: gWS_Rev }  ; lint-ignore: critical-section (AHK v2 auto-releases Critical on return)
}

_WL_GetRev() {
    global gWS_Rev
    return gWS_Rev
}

; Diagnostic: get and reset churn stats
; RACE FIX: Wrap in Critical - iteration + reset must be atomic
; (_WS_BumpRev modifies gWS_DiagSource with its own Critical section)

; Diagnostic: record a rev bump from a source
_WS_DiagBump(source) {
    global gWS_DiagSource
    gWS_DiagSource[source] := gWS_DiagSource.Get(source, 0) + 1
}

; Flush churn diagnostic maps to the store error log and reset.
; Called from _GUI_Housekeeping when DiagChurnLog is enabled.
WL_FlushChurnLog() {
    global gWS_DiagChurn, gWS_DiagSource, cfg, LOG_PATH_STORE
    if (!cfg.DiagChurnLog)
        return

    ; Snapshot and reset under Critical to avoid race with _WS_BumpRev / UpsertWindow
    Critical "On"
    if (gWS_DiagChurn.Count = 0 && gWS_DiagSource.Count = 0) {
        Critical "Off"
        return
    }

    churnSnap := Map()
    for k, v in gWS_DiagChurn
        churnSnap[k] := v
    sourceSnap := Map()
    for k, v in gWS_DiagSource
        sourceSnap[k] := v

    gWS_DiagChurn := Map()
    gWS_DiagSource := Map()
    Critical "Off"

    ; Build summary outside Critical
    msg := "churn_summary fields:"
    for k, v in churnSnap
        msg .= " " k "=" v
    msg .= " | sources:"
    for k, v in sourceSnap
        msg .= " " k "=" v

    try LogAppend(LOG_PATH_STORE, msg)
}

; Atomic revision bump - prevents race conditions when multiple producers bump rev
; NOTE: No Critical "Off" — callers hold Critical and "Off" here would leak their state.
; Critical "On" is kept for the rare caller without Critical (e.g., EndScan).
_WS_BumpRev(source) {
    Critical "On"
    global cfg, gWS_Rev
    gWS_Rev += 1
    Stats_BumpLifetimeStat("TotalWindowUpdates")
    if (cfg.DiagChurnLog)
        _WS_DiagBump(source)
}

WL_GetByHwnd(hwnd) {
    global gWS_Store
    hwnd := hwnd + 0
    return gWS_Store.Get(hwnd, "")
}

WL_IsOnCurrentWorkspace(workspaceName, currentWSName) {
    return (workspaceName = currentWSName) || (workspaceName = "")
}

WL_SetCurrentWorkspace(id, name := "") {
    global gWS_Meta, gWS_Rev, gWS_Store, gWS_SortOrderDirty, gWS_ContentDirty, gWS_MRUBumpOnly
    global gWS_OnWorkspaceChanged
    ; RACE FIX: Wrap entire body in Critical — meta writes (currentWSId, currentWSName)
    ; and the iteration loop must be atomic so a timer can't observe stale meta values
    ; between the name comparison (line below) and the name write.
    ; _WS_BumpRev has its own internal Critical; nesting is fine in AHK v2.
    Critical "On"
    ; Always update meta (lightweight, no rev bump)
    gWS_Meta["currentWSId"] := id

    ; Only recalculate window state if workspace NAME changed
    ; ID is metadata only — GUI cares about name for filtering
    if (gWS_Meta["currentWSName"] = name)
        return false  ; lint-ignore: critical-section

    gWS_Meta["currentWSName"] := name

    ; Update isOnCurrentWorkspace for all windows based on new workspace
    ; Unmanaged windows (empty workspaceName) float across all workspaces, treat as "on current"
    anyFlipped := false
    for _, rec in gWS_Store {
        newIsOnCurrent := WL_IsOnCurrentWorkspace(rec.workspaceName, name)
        if (rec.isOnCurrentWorkspace != newIsOnCurrent) {
            rec.isOnCurrentWorkspace := newIsOnCurrent
            anyFlipped := true
        }
    }
    ; Only bump rev if at least one window's state actually changed
    if (anyFlipped) {
        _WS_MarkDirty()  ; Filter-affecting change (workspace switch)
        _WS_BumpRev("SetCurrentWorkspace")
    }

    ; Notify GUI of workspace change (callback may do GUI work — Critical is fine,
    ; keyboard-hooks rule: keep Critical during render).
    ; Centralized here so ALL callers (KomorebiSub events, ProcessFullState init,
    ; KomorebiLite polling, self-healing) automatically fire the callback.
    if (gWS_OnWorkspaceChanged)
        gWS_OnWorkspaceChanged()  ; lint-ignore: critical-leak

    return anyFlipped  ; lint-ignore: critical-section
}


; Helper to get option from Map or plain Object
_WS_GetOpt(opts, key, default) {
    if (!IsObject(opts))
        return default
    if (opts is Map)
        return opts.Get(key, default)
    ; Plain object - use HasOwnProp
    return opts.HasOwnProp(key) ? opts.%key% : default
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
        iconMethod: "",           ; IP_METHOD_WM_GETICON, IP_METHOD_UWP, IP_METHOD_EXE, or "" (none yet)
        iconLastRefreshTick: 0,   ; When we last checked WM_GETICON (for refresh throttle)
        monitorHandle: 0,
        monitorLabel: ""
    }
}

; PERF: Hardcoded fields avoid dynamic %field% string-to-property-slot resolution per call.
; Must stay in sync with DISPLAY_FIELDS (top of file).
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
        monitorHandle: rec.monitorHandle,
        monitorLabel: rec.monitorLabel
    }
}

_WS_TrySort(arr, cmp) {
    QuickSort(arr, cmp)
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
    global gWS_IconQueue, gWS_IconQueueDedup, gWS_PidQueue, gWS_PidQueueDedup
    global IP_METHOD_WM_GETICON
    now := A_TickCount

    ; Determine if window needs icon work
    needsIconWork := false
    isVisible := !row.isCloaked && !row.isMinimized && row.isVisible

    if (!row.iconHicon && !row.iconGaveUp) {
        ; No icon yet - need one
        needsIconWork := true
    } else if (row.iconHicon && row.iconMethod != IP_METHOD_WM_GETICON && isVisible) {
        ; Has fallback icon (UWP/EXE), window is now visible - try to upgrade
        ; Throttle UPGRADE attempts: check iconLastRefreshTick (30s matches IconPumpRefreshThrottleMs)
        ; Without this, same window re-queued every upsert cycle during workspace switches
        global cfg
        throttleMs := cfg.IconPumpRefreshThrottleMs
        if (row.iconLastRefreshTick = 0 || (now - row.iconLastRefreshTick) >= throttleMs)
            needsIconWork := true
    }
    ; Note: refresh-on-focus is handled by WL_EnqueueIconRefresh, not here

    if (needsIconWork && row.present) {
        if (row.iconCooldownUntilTick = 0 || now >= row.iconCooldownUntilTick) {
            hwnd := row.hwnd + 0
            if (!gWS_IconQueueDedup.Has(hwnd)) {
                gWS_IconQueue.Push(hwnd)
                gWS_IconQueueDedup[hwnd] := true
                try IconPump_EnsureRunning()  ; Wake timer from idle pause
                try GUIPump_EnsureRunning()   ; Wake pump collection timer from idle pause
            }
        }
    }

    ; Need process name?
    if (row.processName = "" && row.pid > 0 && row.present) {
        pid := row.pid + 0
        if (!gWS_PidQueueDedup.Has(pid)) {
            gWS_PidQueue.Push(pid)
            gWS_PidQueueDedup[pid] := true
            try ProcPump_EnsureRunning()  ; Wake timer from idle pause
            try GUIPump_EnsureRunning()   ; Wake pump collection timer from idle pause
        }
    }
    Critical "Off"
}

; Enqueue window for icon refresh (called when window gains focus)
; This allows upgrading fallback icons or refreshing WM_GETICON icons that may have changed
WL_EnqueueIconRefresh(hwnd) {
    global gWS_Store, gWS_IconQueue, gWS_IconQueueDedup, cfg
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
    throttleMs := cfg.IconPumpRefreshThrottleMs
    if (row.iconLastRefreshTick > 0 && (now - row.iconLastRefreshTick) < throttleMs)
        return false

    ; RACE FIX: Wrap in Critical - check-then-insert must be atomic
    ; (same pattern as _WS_EnqueueIfNeeded and WL_PopIconBatch)
    Critical "On"
    if (!gWS_IconQueueDedup.Has(hwnd)) {
        gWS_IconQueue.Push(hwnd)
        gWS_IconQueueDedup[hwnd] := true
        try IconPump_EnsureRunning()  ; Wake timer from idle pause
        try GUIPump_EnsureRunning()   ; Wake pump collection timer from idle pause
    }
    Critical "Off"
    return true
}

; Pop batch of hwnds needing icons
; RACE FIX: Wrap in Critical - push operations use Critical, so pop must too
WL_PopIconBatch(count := 16) {
    Critical "On"
    global gWS_IconQueue, gWS_IconQueueDedup
    batch := []
    while (gWS_IconQueue.Length > 0 && batch.Length < count) {
        hwnd := gWS_IconQueue.Pop()
        gWS_IconQueueDedup.Delete(hwnd)
        batch.Push(hwnd)
    }
    Critical "Off"
    return batch
}

; Pop batch of pids needing process info
; RACE FIX: Wrap in Critical - push operations use Critical, so pop must too
WL_PopPidBatch(count := 16) {
    Critical "On"
    global gWS_PidQueue, gWS_PidQueueDedup
    batch := []
    while (gWS_PidQueue.Length > 0 && batch.Length < count) {
        pid := gWS_PidQueue.Pop()
        gWS_PidQueueDedup.Delete(pid)
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
WL_EnqueueForZ(hwnd) {
    Critical "On"
    global gWS_ZQueue, gWS_ZQueueDedup
    hwnd := hwnd + 0
    if (!hwnd || gWS_ZQueueDedup.Has(hwnd)) {
        Critical "Off"
        return
    }
    gWS_ZQueue.Push(hwnd)
    gWS_ZQueueDedup[hwnd] := true
    Critical "Off"
}

; Check if any windows need Z-order enrichment
; RACE FIX: Add Critical for consistency with EnqueueForZ/ClearZQueue
WL_HasPendingZ() {
    Critical "On"
    global gWS_ZQueue
    result := gWS_ZQueue.Length > 0
    Critical "Off"
    return result
}

; Clear the Z queue (called after a full winenum scan)
; Wrapped in Critical to prevent race with EnqueueForZ
WL_ClearZQueue() {
    Critical "On"
    global gWS_ZQueue, gWS_ZQueueDedup
    gWS_ZQueue := []
    gWS_ZQueueDedup := Map()
    Critical "Off"
}

; ============================================================
; Process Name Cache
; ============================================================

; Get cached process name for pid
; Returns name string if cached and fresh, empty string otherwise.
; Entries older than 60s are treated as stale and returned empty to force re-verification.
WL_GetProcNameCached(pid) {
    global gWS_ProcNameCache
    static CACHE_TTL := 60000  ; 60s before re-verification
    pid := pid + 0
    if (!gWS_ProcNameCache.Has(pid))
        return ""
    entry := gWS_ProcNameCache[pid]
    ; Fresh entry - return cached name
    if ((A_TickCount - entry.tick) < CACHE_TTL)
        return entry.name
    ; Stale entry - return empty to force re-verification by caller
    return ""
}

; Update process name for all windows with this pid
WL_UpdateProcessName(pid, name) {
    global gWS_Store, gWS_Rev, gWS_ProcNameCache, gWS_DirtyHwnds
    pid := pid + 0
    if (pid <= 0 || name = "")
        return

    ; No FIFO cap — cache grows with live PID count.
    ; WL_PruneProcNameCache() on heartbeat removes dead PIDs.
    gWS_ProcNameCache[pid] := { name: name, tick: A_TickCount }

    ; RACE FIX: Snapshot keys to prevent iteration-during-modification
    hwnds := WS_SnapshotMapKeys(gWS_Store)

    ; RACE FIX: Wrap record writes + rev bump in Critical to prevent interleaving
    ; with other store mutation paths (consistent with UpdateFields)
    Critical "On"
    ; Update all matching rows
    changed := false
    for _, hwnd in hwnds {
        if (!gWS_Store.Has(hwnd))
            continue  ; lint-ignore: critical-section
        rec := gWS_Store[hwnd]
        if (rec.pid = pid && rec.processName != name) {
            rec.processName := name
            gWS_DirtyHwnds[hwnd] := true
            changed := true
        }
    }
    if (changed) {
        _WS_BumpRev("UpdateProcessName")
    }
    Critical "Off"
}

; ============================================================
; Icon Cache
; ============================================================

; Get a COPY of cached icon for exe (caller owns the copy)
WL_GetExeIconCopy(exePath) {
    global gWS_ExeIconCache
    if (!gWS_ExeIconCache.Has(exePath))
        return 0
    master := gWS_ExeIconCache[exePath]
    if (!master)
        return 0
    return DllCall("user32\CopyIcon", "ptr", master, "ptr")
}

; Store master icon for exe (store owns it, don't destroy)
; No FIFO cap — cache grows with live exe count.
; WL_PruneExeIconCache() on heartbeat removes orphaned exe paths.
WL_ExeIconCachePut(exePath, hIcon) {
    global gWS_ExeIconCache
    if (!hIcon)
        return
    gWS_ExeIconCache[exePath] := hIcon
}

; Clean up all cached exe icons - call on shutdown
WL_CleanupExeIconCache() {
    global gWS_ExeIconCache
    for _, hIcon in gWS_ExeIconCache {
        if (hIcon)
            try DllCall("user32\DestroyIcon", "ptr", hIcon)
    }
    gWS_ExeIconCache := Map()
}

; Prune dead PIDs from process name cache (called from _GUI_Housekeeping)
; Returns the number of entries pruned
WL_PruneProcNameCache() {
    global gWS_ProcNameCache
    if (!IsObject(gWS_ProcNameCache) || gWS_ProcNameCache.Count = 0)
        return 0

    ; Snapshot keys to prevent iteration-during-modification
    pids := WS_SnapshotMapKeys(gWS_ProcNameCache)

    ; RACE FIX: Wrap delete loop in Critical to prevent interleaving with
    ; UpdateProcessName which inserts under Critical
    Critical "On"
    pruned := 0
    for _, pid in pids {
        if (!ProcessExist(pid)) {
            gWS_ProcNameCache.Delete(pid)
            pruned++
        }
    }
    Critical "Off"
    return pruned
}

; Prune orphaned exe paths from icon cache (called from _GUI_Housekeeping)
; Removes entries for exe paths not referenced by any live window in the store
WL_PruneExeIconCache() {
    global gWS_ExeIconCache, gWS_Store
    if (!IsObject(gWS_ExeIconCache) || gWS_ExeIconCache.Count = 0)
        return 0

    ; Collect live exe paths from store
    Critical "On"
    liveExePaths := Map()
    for _, rec in gWS_Store {
        if (rec.HasOwnProp("exePath") && rec.exePath != "")
            liveExePaths[rec.exePath] := true
    }
    Critical "Off"

    ; Snapshot cache keys to prevent iteration-during-modification
    cacheKeys := WS_SnapshotMapKeys(gWS_ExeIconCache)

    ; RACE FIX: Wrap delete loop in Critical to prevent interleaving with
    ; ExeIconCachePut which inserts under the same map
    Critical "On"
    pruned := 0
    for _, exePath in cacheKeys {
        if (!liveExePaths.Has(exePath)) {
            hIcon := gWS_ExeIconCache[exePath]
            if (hIcon)
                try DllCall("user32\DestroyIcon", "ptr", hIcon)
            gWS_ExeIconCache.Delete(exePath)
            pruned++
        }
    }
    Critical "Off"
    return pruned
}

; Find hwnds in the store that match any PID in the given set.
; pidSet: Map(pid → true)
; Returns: array of hwnds
WL_GetHwndsByPids(pidSet) {
    global gWS_Store
    Critical "On"
    result := []
    for hwnd, rec in gWS_Store {
        if (rec.present && pidSet.Has(rec.pid))
            result.Push(hwnd)
    }
    Critical "Off"
    return result
}

; Clean up all per-window icons in the store
; RACE FIX: Wrap in Critical to prevent WinEventHook from modifying map during iteration
WL_CleanupAllIcons() {
    global gWS_Store
    Critical "On"
    for _, rec in gWS_Store {
        if (rec.HasOwnProp("iconHicon") && rec.iconHicon) {
            try DllCall("user32\DestroyIcon", "ptr", rec.iconHicon)
            rec.iconHicon := 0
        }
    }
    Critical "Off"
}

; ============================================================
; DisplayList — Transform store records into sorted item arrays
; ============================================================
; Multi-path caching: cache hit (Path 1), MRU move-to-front (Path 1.5),
; content-only refresh (Path 2), full rebuild (Path 3).

WL_GetDisplayList(opts := 0) {
    Profiler.Enter("WL_GetDisplayList") ; @profile
    global gWS_Store, gWS_Meta, gWS_SortOrderDirty, gWS_ContentDirty
    global gWS_MRUBumpOnly, gWS_DirtyHwnds, gWS_TitleSortActive
    global gWS_DLCache_Items, gWS_DLCache_ItemsMap, gWS_DLCache_OptsKey, gWS_DLCache_SortedRecs
    sort := _WS_GetOpt(opts, "sort", "MRU")
    gWS_TitleSortActive := (sort = "Title")
    currentOnly := _WS_GetOpt(opts, "currentWorkspaceOnly", false)
    includeMin := _WS_GetOpt(opts, "includeMinimized", true)
    includeCloaked := _WS_GetOpt(opts, "includeCloaked", false)
    columns := _WS_GetOpt(opts, "columns", "items")

    optsKey := sort "|" currentOnly "|" includeMin "|" includeCloaked "|" columns

    ; --- Path 1: Both clean + cache valid → return cached items (fast path) ---
    ; RACE FIX: Wrap cache hit path in Critical to prevent producer from bumping rev + setting
    ; dirty flags between cache validation and return (would return stale rows with new rev)
    Critical "On"
    if (!gWS_SortOrderDirty && !gWS_ContentDirty
        && IsObject(gWS_DLCache_Items) && gWS_DLCache_OptsKey = optsKey) {
        result := { rev: _WL_GetRev(), items: gWS_DLCache_Items, itemsMap: gWS_DLCache_ItemsMap, meta: gWS_Meta, cachePath: "cache" }
        if (columns = "hwndsOnly") {
            hwnds := []
            for _, row in gWS_DLCache_Items
                hwnds.Push(row.hwnd)
            Critical "Off"
            Profiler.Leave() ; @profile
            return { rev: result.rev, hwnds: hwnds, meta: result.meta, cachePath: "cache" }
        }
        Critical "Off"
        Profiler.Leave() ; @profile
        return result
    }
    Critical "Off"

    ; --- Path 1.5: Sort dirty BUT only MRU fields changed → incremental move-to-front ---
    Critical "On"
    if (gWS_SortOrderDirty && gWS_MRUBumpOnly
        && sort = "MRU"
        && IsObject(gWS_DLCache_SortedRecs) && gWS_DLCache_OptsKey = optsKey) {
        sortedRecs := gWS_DLCache_SortedRecs
        valid := true
        ; Find the item with highest lastActivatedTick (the new MRU leader)
        bestIdx := 0
        bestTick := 0
        Loop sortedRecs.Length {
            rec := sortedRecs[A_Index]
            if (!rec.present) {
                valid := false
                break
            }
            if (rec.lastActivatedTick > bestTick) {
                bestIdx := A_Index
                bestTick := rec.lastActivatedTick
            }
        }
        if (valid) {
            ; Move the new leader to front if it's not already there
            if (bestIdx > 1) {
                movedRec := sortedRecs.RemoveAt(bestIdx)
                sortedRecs.InsertAt(1, movedRec)
            }
            ; Sort invariant check: verify first few items are in descending tick order.
            if (sortedRecs.Length >= 2) {
                Loop Min(sortedRecs.Length - 1, 3) {
                    if (sortedRecs[A_Index].lastActivatedTick < sortedRecs[A_Index + 1].lastActivatedTick) {
                        valid := false
                        break
                    }
                }
            }
        }
        if (valid) {
            ; Selective refresh: only recreate _WS_ToItem for dirty items.
            rows := []
            for _, rec in sortedRecs {
                if (gWS_DirtyHwnds.Has(rec.hwnd)) {
                    newItem := _WS_ToItem(rec)
                    rows.Push(newItem)
                    gWS_DLCache_ItemsMap[rec.hwnd] := newItem
                } else if (gWS_DLCache_ItemsMap.Has(rec.hwnd))
                    rows.Push(gWS_DLCache_ItemsMap[rec.hwnd])
                else {
                    newItem := _WS_ToItem(rec)
                    rows.Push(newItem)
                    gWS_DLCache_ItemsMap[rec.hwnd] := newItem
                }
            }
            gWS_SortOrderDirty := false
            gWS_ContentDirty := false
            gWS_MRUBumpOnly := false
            gWS_DirtyHwnds := Map()
            gWS_DLCache_Items := rows
            result := { rev: _WL_GetRev(), items: rows, itemsMap: gWS_DLCache_ItemsMap, meta: gWS_Meta, cachePath: "mru" }
            if (columns = "hwndsOnly") {
                hwnds := []
                for _, row in rows
                    hwnds.Push(row.hwnd)
                Critical "Off"
                Profiler.Leave() ; @profile
                return { rev: result.rev, hwnds: hwnds, meta: result.meta, cachePath: "mru" }
            }
            Critical "Off"
            Profiler.Leave() ; @profile
            return result
        }
        ; !valid: stale ref or sort invariant broken — fall through to Path 3
    }
    Critical "Off"

    ; --- Path 2: Sort order clean + content dirty → selective re-transform ---
    Critical "On"
    if (!gWS_SortOrderDirty && gWS_ContentDirty
        && IsObject(gWS_DLCache_SortedRecs)
        && IsObject(gWS_DLCache_Items)
        && gWS_DLCache_OptsKey = optsKey) {
        rows := []
        valid := true
        i := 0
        for _, rec in gWS_DLCache_SortedRecs {
            i++
            if (!rec.present) {
                valid := false
                break
            }
            if (gWS_DirtyHwnds.Has(rec.hwnd)) {
                newItem := _WS_ToItem(rec)
                rows.Push(newItem)
                gWS_DLCache_ItemsMap[rec.hwnd] := newItem
            } else
                rows.Push(gWS_DLCache_Items[i])
        }
        if (valid) {
            gWS_ContentDirty := false
            gWS_DirtyHwnds := Map()
            gWS_DLCache_Items := rows
            result := { rev: _WL_GetRev(), items: rows, itemsMap: gWS_DLCache_ItemsMap, meta: gWS_Meta, cachePath: "content" }
            if (columns = "hwndsOnly") {
                hwnds := []
                for _, row in rows
                    hwnds.Push(row.hwnd)
                Critical "Off"
                Profiler.Leave() ; @profile
                return { rev: result.rev, hwnds: hwnds, meta: result.meta, cachePath: "content" }
            }
            Critical "Off"
            Profiler.Leave() ; @profile
            return result
        }
        ; Stale ref detected — fall through to full rebuild
        gWS_SortOrderDirty := true
    }
    Critical "Off"

    ; --- Path 3: Sort order dirty → full rebuild (filter + sort + transform) ---
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

    ; Transform records to items ONCE, then cache the result
    rows := []
    itemsMap := Map()
    for _, rec in items {
        item := _WS_ToItem(rec)
        rows.Push(item)
        itemsMap[rec.hwnd] := item
    }

    ; RACE FIX: Update cache state atomically (matches Path 1/1.5/2 Critical pattern)
    ; Sort and transform stay outside Critical — at worst a producer modifies a field
    ; during sort causing slightly wrong order for one frame, which self-corrects.
    Critical "On"
    gWS_DLCache_SortedRecs := items
    gWS_DLCache_ItemsMap := itemsMap
    gWS_SortOrderDirty := false
    gWS_ContentDirty := false
    gWS_MRUBumpOnly := false
    gWS_DirtyHwnds := Map()
    gWS_DLCache_Items := rows
    gWS_DLCache_OptsKey := optsKey
    Critical "Off"

    if (columns = "hwndsOnly") {
        hwnds := []
        for _, row in rows
            hwnds.Push(row.hwnd)
        Profiler.Leave() ; @profile
        return { rev: _WL_GetRev(), hwnds: hwnds, meta: gWS_Meta, cachePath: "full" }
    }

    Profiler.Leave() ; @profile
    return { rev: _WL_GetRev(), items: rows, itemsMap: gWS_DLCache_ItemsMap, meta: gWS_Meta, cachePath: "full" }
}
