#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Expected: file is included after blacklist.ahk

; WindowStore (v1) - minimal core for IPC + viewer.

global WS_SCAN_ID_MAX := 0x7FFFFFFF

; Canonical list of fields copied from store records into projection items.
; Used by _WS_ToItem (projection) and WindowStore_BuildDelta (delta detection).
; hwnd is always included separately as the record key.
global PROJECTION_FIELDS := ["title", "class", "pid", "z", "lastActivatedTick",
    "isFocused", "isCloaked", "isMinimized", "workspaceName", "workspaceId",
    "isOnCurrentWorkspace", "processName", "iconHicon"]

global gWS_Store := Map()
global gWS_Rev := 0
global gWS_ScanId := 0
global gWS_Config := Map()
global gWS_Meta := Map()

; Two-level projection cache dirty tracking:
;   gWS_SortOrderDirty — set when sort/filter-affecting fields change (needs full rebuild)
;   gWS_ProjectionContentDirty — set when content-only fields change (can skip re-sort)
;   gWS_MRUBumpOnly — when true, sort-dirty was caused ONLY by MRU fields (lastActivatedTick/isFocused)
;     This enables Path 1.5: incremental move-to-front instead of full rebuild.
;     Reset to false if any non-MRU sort-affecting field changes in the same cycle.
global gWS_SortOrderDirty := true
global gWS_ProjectionContentDirty := true
global gWS_MRUBumpOnly := false
global gWS_ProjectionCache_Items := ""         ; Cached transformed items (result of _WS_ToItem)
global gWS_ProjectionCache_OptsKey := ""       ; Opts key used for cache validation
global gWS_ProjectionCache_SortedRecs := ""    ; Cached sorted record refs for Path 2 (content-only refresh)

; Mark store as needing re-sort and content update.
; mruOnly: true if ONLY MRU fields changed (enables incremental move-to-front in projection).
_WS_MarkDirty(mruOnly := false) {
    global gWS_SortOrderDirty, gWS_ProjectionContentDirty, gWS_MRUBumpOnly
    if (!gWS_SortOrderDirty)
        gWS_MRUBumpOnly := mruOnly
    else if (!mruOnly)
        gWS_MRUBumpOnly := false
    gWS_SortOrderDirty := true
    gWS_ProjectionContentDirty := true
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

; Fields that affect projection content only (not sort/filter) — trigger content refresh (Path 2)
; Fresh _WS_ToItem copies are created from live records, avoiding stale cache data.
; NOTE: "title" is promoted to sort-affecting when Title sort mode is active (see gWS_TitleSortActive).
global gWS_ContentOnlyFields := Map(
    "iconHicon", true, "title", true, "class", true,
    "pid", true, "workspaceName", true, "workspaceId", true,
    "isFocused", true)

; When true, "title" field changes trigger sort rebuild instead of content-only refresh.
; Set by GetProjection when any client uses sort="Title", cleared on next GetProjection
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

gWS_Config["MissingTTLms"] := 1200  ; Default, overridden from cfg in WindowStore_Init()
gWS_Meta["currentWSId"] := ""
gWS_Meta["currentWSName"] := ""

; Flag indicating workspace changed since last consumed - for OnChange delta style
global gWS_WorkspaceChangedFlag := false

; Delta tracking: hwnds with fields changed since last IPC push
; Key = hwnd, Value = true (presence in map = pending for delta)
global gWS_DeltaPendingHwnds := Map()

; Projection-level dirty tracking: hwnds with any projection-visible field change
; since the last GetProjection call. Unlike gWS_DeltaPendingHwnds (cleared per IPC push),
; this persists until projection cache is rebuilt. Used by Path 1.5 and Path 2 for
; selective _WS_ToItem refresh (only recreate items whose data actually changed).
global gWS_ProjectionDirtyHwnds := Map()

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
; markDelta: if true, marks hwnd dirty so removal appears in delta pushes.
; Caller MUST hold Critical when calling this function.
_WS_DeleteWindow(hwnd, markDelta := true) {
    global gWS_Store, gWS_DeltaPendingHwnds
    if (markDelta)
        gWS_DeltaPendingHwnds[hwnd] := true
    try IconPump_CleanupWindow(hwnd)
    gWS_Store.Delete(hwnd)
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
    global gWS_ScanId, WS_SCAN_ID_MAX
    if (gWS_ScanId = WS_SCAN_ID_MAX)
        gWS_ScanId := 0
    gWS_ScanId += 1
    return gWS_ScanId
}

WindowStore_EndScan(graceMs := "") {
    global gWS_Store, gWS_ScanId, gWS_Config, gWS_Rev, gWS_SortOrderDirty, gWS_ProjectionContentDirty, gWS_MRUBumpOnly
    now := A_TickCount
    ttl := (graceMs != "" ? graceMs + 0 : gWS_Config["MissingTTLms"] + 0)
    removed := 0
    changed := false

    ; RACE FIX: Snapshot keys to prevent iteration-during-modification
    hwnds := WS_SnapshotMapKeys(gWS_Store)

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
                    _WS_DeleteWindow(hwnd, false)
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
        _WS_MarkDirty()  ; Structural change (window removal)
        _WS_BumpRev("EndScan")
    }
    return { removed: removed, rev: gWS_Rev }
}

WindowStore_UpsertWindow(records, source := "") {
    global cfg, gWS_Store, gWS_Rev, gWS_ScanId, gWS_DiagChurn, gWS_SortOrderDirty, gWS_ProjectionContentDirty
    global gWS_SortAffectingFields, gWS_ContentOnlyFields, gWS_InternalFields, gWS_DeltaPendingHwnds, gWS_MRUBumpOnly
    if (!IsObject(records) || !(records is Array))
        return { added: 0, updated: 0, rev: gWS_Rev }
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
        hwnd := rec.Has("hwnd") ? (rec["hwnd"] + 0) : 0
        if (!hwnd)
            continue  ; lint-ignore: critical-section
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
                gWS_DeltaPendingHwnds[hwnd] := true
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
                            gWS_DiagChurn[k] := (gWS_DiagChurn.Has(k) ? gWS_DiagChurn[k] : 0) + 1
                        row.%k% := v
                        rowChanged := true
                        ; Mark dirty for delta tracking (new records or non-internal field changes)
                        if (isNew || !gWS_InternalFields.Has(k))
                            gWS_DeltaPendingHwnds[hwnd] := true
                        if (gWS_SortAffectingFields.Has(k))
                            sortDirty := true
                        else if (gWS_ContentOnlyFields.Has(k))
                            contentDirty := true
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
        gWS_ProjectionContentDirty := true
    }
    if (added || updated) {
        _WS_BumpRev("UpsertWindow:" . source)
    }
    ; RACE FIX: Update peak windows inside Critical - producers can interrupt after release
    if (added > 0) {
        global gStats_Session, gStats_Lifetime
        if (IsObject(gStats_Session) && gWS_Store.Count > gStats_Session.Get("peakWindows", 0)) {
            gStats_Session["peakWindows"] := gWS_Store.Count
            if (IsObject(gStats_Lifetime) && gWS_Store.Count > gStats_Lifetime.Get("PeakWindowsInSession", 0))
                gStats_Lifetime["PeakWindowsInSession"] := gWS_Store.Count
        }
    }
    Critical "Off"

    ; Enqueue for enrichment OUTSIDE Critical (queue operations have their own Critical)
    for _, row in rowsToEnqueue
        _WS_EnqueueIfNeeded(row)

    return { added: added, updated: updated, rev: gWS_Rev }
}

; Fields that are internal tracking and should not bump rev when changed
global gWS_InternalFields := Map("iconCooldownUntilTick", true, "lastSeenScanId", true, "lastSeenTick", true, "missingSinceTick", true, "iconGaveUp", true, "iconMethod", true, "iconLastRefreshTick", true)

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
    global gWS_DeltaPendingHwnds, gWS_MRUOnlyFields, gWS_ProjectionDirtyHwnds
    global gWS_TitleSortActive
    changed := false
    sortDirty := false
    contentDirty := false
    mruOnly := true  ; Assume MRU-only until a non-MRU sort field changes

    ; Normalize: convert Map to Object at entry so we need only one iteration branch.
    ; Map.OwnProps() iterates property metadata (Count, CaseSense), not entries,
    ; so Map requires for k,v syntax. Converting once avoids maintaining two branches.
    if (patch is Map) {
        obj := {}
        for k, v in patch
            obj.%k% := v
        patch := obj
    }

    if (IsObject(patch)) {
        for k in patch.OwnProps() {
            v := patch.%k%
            if (!row.HasOwnProp(k) || row.%k% != v) {
                row.%k% := v
                if (!gWS_InternalFields.Has(k)) {
                    changed := true
                    gWS_DeltaPendingHwnds[hwnd] := true
                    gWS_ProjectionDirtyHwnds[hwnd] := true
                }
                if (gWS_SortAffectingFields.Has(k)) {
                    sortDirty := true
                    if (!gWS_MRUOnlyFields.Has(k))
                        mruOnly := false
                } else if (k = "title" && gWS_TitleSortActive) {
                    ; Title is normally content-only, but in Title sort mode it affects order
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

WindowStore_UpdateFields(hwnd, patch, source := "", returnRow := false) {
    global gWS_Store, gWS_Rev, gWS_SortOrderDirty, gWS_ProjectionContentDirty
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
        gWS_ProjectionContentDirty := true
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
WindowStore_BatchUpdateFields(patches, source := "") {
    global gWS_Store, gWS_Rev, gWS_SortOrderDirty, gWS_ProjectionContentDirty
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
        gWS_ProjectionContentDirty := true
    }
    if (changedCount > 0)
        _WS_BumpRev("BatchUpdateFields:" . source)

    Critical "Off"
    return { changed: changedCount, rev: gWS_Rev }
}

WindowStore_RemoveWindow(hwnds, forceRemove := false) {
    global gWS_Store, gWS_Rev, gWS_SortOrderDirty, gWS_ProjectionContentDirty, gWS_DeltaPendingHwnds, gWS_MRUBumpOnly
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

WindowStore_ValidateExistence() {
    global gWS_Store, gWS_Rev, gWS_SortOrderDirty, gWS_ProjectionContentDirty, gWS_DeltaPendingHwnds, gWS_MRUBumpOnly

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
        _WS_DeleteWindow(hwnd)
        removed += 1
    }

    if (removed > 0) {
        _WS_MarkDirty()  ; Structural change (window removal)
        _WS_BumpRev("ValidateExistence")
    }
    Critical "Off"

    return { removed: removed, rev: gWS_Rev }
}

; Purge all windows from store that match the current blacklist
; Called after blacklist reload to remove newly-blacklisted windows
WindowStore_PurgeBlacklisted() {
    global gWS_Store, gWS_Rev, gWS_SortOrderDirty, gWS_ProjectionContentDirty, gWS_MRUBumpOnly
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
        _WS_DeleteWindow(hwnd, false)
        removed += 1
    }

    if (removed) {
        _WS_MarkDirty()  ; Structural change (blacklist purge)
        _WS_BumpRev("PurgeBlacklisted")
    }
    return { removed: removed, rev: gWS_Rev }  ; lint-ignore: critical-section (AHK v2 auto-releases Critical on return)
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
    global cfg, gWS_Rev, gStats_Lifetime
    gWS_Rev += 1
    if (gStats_Lifetime.Has("TotalWindowUpdates"))
        gStats_Lifetime["TotalWindowUpdates"] += 1
    if (cfg.DiagChurnLog)
        _WS_DiagBump(source)
    Critical "Off"
}

WindowStore_GetByHwnd(hwnd) {
    global gWS_Store
    hwnd := hwnd + 0
    return gWS_Store.Has(hwnd) ? gWS_Store[hwnd] : ""
}

WindowStore_SetCurrentWorkspace(id, name := "") {
    global gWS_Meta, gWS_Rev, gWS_Store, gWS_SortOrderDirty, gWS_ProjectionContentDirty, gWS_WorkspaceChangedFlag, gWS_DeltaPendingHwnds, gWS_MRUBumpOnly
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
        return []  ; lint-ignore: critical-section

    gWS_Meta["currentWSName"] := name
    gWS_WorkspaceChangedFlag := true  ; Signal workspace change for OnChange delta style

    ; Update isOnCurrentWorkspace for all windows based on new workspace
    ; Unmanaged windows (empty workspaceName) float across all workspaces, treat as "on current"
    anyFlipped := false
    flipped := []  ; Full _WS_ToItem records for broadcast (SSF-safe: creates complete items on GUI side)
    for hwnd, rec in gWS_Store {
        newIsOnCurrent := (rec.workspaceName = name) || (rec.workspaceName = "")
        if (rec.isOnCurrentWorkspace != newIsOnCurrent) {
            rec.isOnCurrentWorkspace := newIsOnCurrent
            gWS_DeltaPendingHwnds[hwnd] := true  ; Mark dirty for delta tracking
            anyFlipped := true
            flipped.Push(_WS_ToItem(rec))
        }
    }
    ; Only bump rev if at least one window's state actually changed
    if (anyFlipped) {
        _WS_MarkDirty()  ; Filter-affecting change (workspace switch)
        _WS_BumpRev("SetCurrentWorkspace")
    }
    return flipped  ; lint-ignore: critical-section
}

WindowStore_GetCurrentWorkspace() {
    global gWS_Meta
    return { id: gWS_Meta["currentWSId"], name: gWS_Meta["currentWSName"] }
}

WindowStore_GetProjection(opts := 0) {
    global gWS_Store, gWS_Meta, gWS_SortOrderDirty, gWS_ProjectionContentDirty
    global gWS_MRUBumpOnly, gWS_ProjectionDirtyHwnds, gWS_TitleSortActive
    global gWS_ProjectionCache_Items, gWS_ProjectionCache_OptsKey, gWS_ProjectionCache_SortedRecs
    sort := WS_GetOpt(opts, "sort", "MRU")
    gWS_TitleSortActive := (sort = "Title")
    currentOnly := WS_GetOpt(opts, "currentWorkspaceOnly", false)
    includeMin := WS_GetOpt(opts, "includeMinimized", true)
    includeCloaked := WS_GetOpt(opts, "includeCloaked", false)
    columns := WS_GetOpt(opts, "columns", "items")

    optsKey := sort "|" currentOnly "|" includeMin "|" includeCloaked "|" columns

    ; --- Path 1: Both clean + cache valid → return cached items (fast path) ---
    ; RACE FIX: Wrap cache hit path in Critical to prevent producer from bumping rev + setting
    ; dirty flags between cache validation and return (would return stale rows with new rev)
    Critical "On"
    if (!gWS_SortOrderDirty && !gWS_ProjectionContentDirty
        && IsObject(gWS_ProjectionCache_Items) && gWS_ProjectionCache_OptsKey = optsKey) {
        result := { rev: WindowStore_GetRev(), items: gWS_ProjectionCache_Items, meta: gWS_Meta }
        if (columns = "hwndsOnly") {
            hwnds := []
            for _, row in gWS_ProjectionCache_Items
                hwnds.Push(row.hwnd)
            Critical "Off"
            return { rev: result.rev, hwnds: hwnds, meta: result.meta }
        }
        Critical "Off"
        return result
    }
    Critical "Off"

    ; --- Path 1.5: Sort dirty BUT only MRU fields changed → incremental move-to-front ---
    ; For MRU sort, a focus change only moves the focused item to position 1.
    ; Instead of full Path 3 rebuild (filter + sort + transform ALL items), we:
    ;   1. Find the item with highest lastActivatedTick in cached sorted records
    ;   2. Move it to position 1 (O(n) shift vs O(n log n) sort)
    ;   3. Re-transform all items via _WS_ToItem (same as Path 2)
    ; Saves: O(n) filter + O(n log n) sort. Keeps: O(n) transform (unavoidable, same as Path 2,
    ; because gWS_DeltaPendingHwnds is cleared by store_server before GetProjection runs).
    ; Preconditions: MRU sort, MRU-only dirty, valid cache, same optsKey
    Critical "On"
    if (gWS_SortOrderDirty && gWS_MRUBumpOnly
        && sort = "MRU"
        && IsObject(gWS_ProjectionCache_SortedRecs) && gWS_ProjectionCache_OptsKey = optsKey) {
        sortedRecs := gWS_ProjectionCache_SortedRecs
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
            ; If multiple ticks changed in one cycle, move-to-front alone isn't enough.
            ; Cost: O(3) — cheap safety net, falls through to Path 3 on failure.
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
            ; After RemoveAt/InsertAt, indices don't match cache — use hwnd lookup.
            static cachedByHwnd := Map()
            cachedByHwnd.Clear()
            for _, item in gWS_ProjectionCache_Items
                cachedByHwnd[item.hwnd] := item
            rows := []
            for _, rec in sortedRecs {
                if (gWS_ProjectionDirtyHwnds.Has(rec.hwnd))
                    rows.Push(_WS_ToItem(rec))
                else if (cachedByHwnd.Has(rec.hwnd))
                    rows.Push(cachedByHwnd[rec.hwnd])
                else
                    rows.Push(_WS_ToItem(rec))  ; Fallback: shouldn't happen
            }
            gWS_SortOrderDirty := false
            gWS_ProjectionContentDirty := false
            gWS_MRUBumpOnly := false
            gWS_ProjectionDirtyHwnds := Map()
            gWS_ProjectionCache_Items := rows
            result := { rev: WindowStore_GetRev(), items: rows, meta: gWS_Meta }
            if (columns = "hwndsOnly") {
                hwnds := []
                for _, row in rows
                    hwnds.Push(row.hwnd)
                Critical "Off"
                return { rev: result.rev, hwnds: hwnds, meta: result.meta }
            }
            Critical "Off"
            return result
        }
        ; !valid: stale ref or sort invariant broken — fall through to Path 3
    }
    Critical "Off"

    ; --- Path 2: Sort order clean + content dirty → selective re-transform ---
    ; Skips O(n) filter + O(n log n) sort. Only recreates _WS_ToItem for dirty items
    ; (tracked by gWS_ProjectionDirtyHwnds), reuses cached items for clean ones.
    ; gWS_ProjectionDirtyHwnds persists across IPC pushes (unlike gWS_DeltaPendingHwnds).
    Critical "On"
    if (!gWS_SortOrderDirty && gWS_ProjectionContentDirty
        && IsObject(gWS_ProjectionCache_SortedRecs)
        && IsObject(gWS_ProjectionCache_Items)
        && gWS_ProjectionCache_OptsKey = optsKey) {
        rows := []
        valid := true
        i := 0
        for _, rec in gWS_ProjectionCache_SortedRecs {
            i++
            if (!rec.present) {
                valid := false
                break
            }
            if (gWS_ProjectionDirtyHwnds.Has(rec.hwnd))
                rows.Push(_WS_ToItem(rec))
            else
                rows.Push(gWS_ProjectionCache_Items[i])
        }
        if (valid) {
            gWS_ProjectionContentDirty := false
            gWS_ProjectionDirtyHwnds := Map()
            gWS_ProjectionCache_Items := rows
            result := { rev: WindowStore_GetRev(), items: rows, meta: gWS_Meta }
            if (columns = "hwndsOnly") {
                hwnds := []
                for _, row in rows
                    hwnds.Push(row.hwnd)
                Critical "Off"
                return { rev: result.rev, hwnds: hwnds, meta: result.meta }
            }
            Critical "Off"
            return result
        }
        ; Stale ref detected — fall through to full rebuild
        gWS_SortOrderDirty := true
    }
    Critical "Off"

    ; --- Path 3: Sort order dirty → full rebuild (filter + sort + transform) ---
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

    ; Save sorted record REFS for Path 2 (content-only refresh next time)
    gWS_ProjectionCache_SortedRecs := items

    ; Transform records to items ONCE, then cache the result
    ; PERF: Avoids O(n) _WS_ToItem loop on every cache hit
    rows := []
    for _, rec in items
        rows.Push(_WS_ToItem(rec))

    ; Update projection cache with transformed rows
    gWS_SortOrderDirty := false
    gWS_ProjectionContentDirty := false
    gWS_MRUBumpOnly := false
    gWS_ProjectionDirtyHwnds := Map()
    gWS_ProjectionCache_Items := rows        ; Cache transformed rows
    gWS_ProjectionCache_OptsKey := optsKey

    if (columns = "hwndsOnly") {
        hwnds := []
        for _, row in rows
            hwnds.Push(row.hwnd)
        return { rev: WindowStore_GetRev(), hwnds: hwnds, meta: gWS_Meta }
    }

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

; PERF: Hardcoded fields avoid 13x dynamic %field% string-to-property-slot resolution per call.
; Must stay in sync with PROJECTION_FIELDS (windowstore.ahk top of file).
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
WS_GetOpt(opts, key, default) {
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
    global gWS_IconQueue, gWS_IconQueueDedup, gWS_PidQueue, gWS_PidQueueDedup
    now := A_TickCount

    ; Determine if window needs icon work
    needsIconWork := false
    isVisible := !row.isCloaked && !row.isMinimized && row.isVisible

    if (!row.iconHicon && !row.iconGaveUp) {
        ; No icon yet - need one
        needsIconWork := true
    } else if (row.iconHicon && row.iconMethod != "wm_geticon" && isVisible) {
        ; Has fallback icon (UWP/EXE), window is now visible - try to upgrade
        ; Throttle UPGRADE attempts: check iconLastRefreshTick (30s matches IconPumpRefreshThrottleMs)
        ; Without this, same window re-queued every upsert cycle during workspace switches
        global cfg
        throttleMs := cfg.IconPumpRefreshThrottleMs
        if (row.iconLastRefreshTick = 0 || (now - row.iconLastRefreshTick) >= throttleMs)
            needsIconWork := true
    }
    ; Note: refresh-on-focus is handled by WindowStore_EnqueueIconRefresh, not here

    if (needsIconWork && row.present) {
        if (row.iconCooldownUntilTick = 0 || now >= row.iconCooldownUntilTick) {
            hwnd := row.hwnd + 0
            if (!gWS_IconQueueDedup.Has(hwnd)) {
                gWS_IconQueue.Push(hwnd)
                gWS_IconQueueDedup[hwnd] := true
                try IconPump_EnsureRunning()  ; Wake timer from idle pause
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
        }
    }
    Critical "Off"
}

; Enqueue window for icon refresh (called when window gains focus)
; This allows upgrading fallback icons or refreshing WM_GETICON icons that may have changed
WindowStore_EnqueueIconRefresh(hwnd) {
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
    ; (same pattern as _WS_EnqueueIfNeeded and WindowStore_PopIconBatch)
    Critical "On"
    if (!gWS_IconQueueDedup.Has(hwnd)) {
        gWS_IconQueue.Push(hwnd)
        gWS_IconQueueDedup[hwnd] := true
        try IconPump_EnsureRunning()  ; Wake timer from idle pause
    }
    Critical "Off"
    return true
}

; Pop batch of hwnds needing icons
; RACE FIX: Wrap in Critical - push operations use Critical, so pop must too
WindowStore_PopIconBatch(count := 16) {
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
WindowStore_PopPidBatch(count := 16) {
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
WindowStore_EnqueueForZ(hwnd) {
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
WindowStore_GetProcNameCached(pid) {
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
WindowStore_UpdateProcessName(pid, name) {
    global gWS_Store, gWS_Rev, gWS_ProcNameCache
    pid := pid + 0
    if (pid <= 0 || name = "")
        return

    ; No FIFO cap — cache grows with live PID count.
    ; WindowStore_PruneProcNameCache() on heartbeat removes dead PIDs.
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
; No FIFO cap — cache grows with live exe count.
; WindowStore_PruneExeIconCache() on heartbeat removes orphaned exe paths.
WindowStore_ExeIconCachePut(exePath, hIcon) {
    global gWS_ExeIconCache
    if (!hIcon)
        return
    gWS_ExeIconCache[exePath] := hIcon
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

; Prune orphaned exe paths from icon cache (called from Store_HeartbeatTick)
; Removes entries for exe paths not referenced by any live window in the store
WindowStore_PruneExeIconCache() {
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

; Clean up all per-window icons in the store
; RACE FIX: Wrap in Critical to prevent WinEventHook from modifying map during iteration
WindowStore_CleanupAllIcons() {
    global gWS_Store
    Critical "On"
    for hwnd, rec in gWS_Store {
        if (rec.HasOwnProp("iconHicon") && rec.iconHicon) {
            try DllCall("user32\DestroyIcon", "ptr", rec.iconHicon)
            rec.iconHicon := 0
        }
    }
    Critical "Off"
}

; ============================================================
; Delta Building - Compute changes between projections
; ============================================================

; Build delta between previous and current projection items
; DESIGN: Sparse mode with periodic full-sync resync is intentional.
; The resync counter ensures client-side self-healing. Do not suggest going fully sparse.
; Parameters:
;   prevItems  - Array of previous projection items
;   nextItems  - Array of current projection items
;   sparse     - When true, emit only changed fields + hwnd (reduces JSON payload)
;                New records (hwnd not in prev) always emit full record regardless
;   dirtyHwnds - Map of dirty hwnds (from Store_PushToClients snapshot). When provided
;                with IPCUseDirtyTracking enabled, skips comparison for clean hwnds.
; Returns: { upserts: [], removes: [] }
WindowStore_BuildDelta(prevItems, nextItems, sparse := false, dirtyHwnds := 0) {
    global cfg, gWS_DeltaPendingHwnds, PROJECTION_FIELDS
    ; deltaFields is derived from PROJECTION_FIELDS — single source of truth for both
    ; projection items (_WS_ToItem) and delta detection. Using a loop avoids an AHK v2
    ; parser bug where bare method calls after many consecutive single-line if statements
    ; silently fail.
    deltaFields := PROJECTION_FIELDS

    ; Dirty tracking setup: use passed snapshot or fall back to global (for direct calls/tests)
    useDirtyTracking := cfg.IPCUseDirtyTracking
    dirtySet := IsObject(dirtyHwnds) ? dirtyHwnds : gWS_DeltaPendingHwnds

    ; PERF: Reuse static Maps instead of allocating new ones per call (O(2n) allocations avoided)
    ; Clear() is O(n) but avoids GC pressure from frequent Map allocations
    static prevMap := Map()
    static nextMap := Map()
    prevMap.Clear()
    for _, rec in prevItems
        prevMap[rec.hwnd] := rec
    nextMap.Clear()
    for _, rec in nextItems
        nextMap[rec.hwnd] := rec

    upserts := []
    removes := []

    ; Find new/changed items
    for hwnd, rec in nextMap {
        if (!prevMap.Has(hwnd)) {
            ; New record: always emit full record (even in sparse mode)
            upserts.Push(rec)
        } else {
            ; Dirty tracking: skip unchanged windows entirely
            if (useDirtyTracking && !dirtySet.Has(hwnd))
                continue

            old := prevMap[hwnd]
            if (sparse) {
                ; Sparse mode: single loop - detect changes AND build sparse record together
                sparseRec := {hwnd: hwnd}
                for _, field in deltaFields {
                    if (rec.%field% != old.%field%)
                        sparseRec.%field% := rec.%field%
                }
                ; Only push if any fields changed (sparseRec has more than just hwnd)
                if (ObjOwnPropCount(sparseRec) > 1)
                    upserts.Push(sparseRec)
            } else {
                ; Full mode: detect any change, push full record
                for _, field in deltaFields {
                    if (rec.%field% != old.%field%) {
                        upserts.Push(rec)
                        break
                    }
                }
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

; Check if meta changed (specifically currentWSName for workspace tracking)
; Moved here from store_server.ahk so tests can call it directly.
WindowStore_MetaChanged(prevMeta, nextMeta) {
    if (prevMeta = "")
        return true  ; No previous meta, consider it changed

    ; Compare workspace name - the critical field for workspace tracking
    prevWSName := ""
    nextWSName := ""

    if (IsObject(prevMeta)) {
        if (prevMeta is Map)
            prevWSName := prevMeta.Has("currentWSName") ? prevMeta["currentWSName"] : ""
        else
            try prevWSName := prevMeta.currentWSName
    }

    if (IsObject(nextMeta)) {
        if (nextMeta is Map)
            nextWSName := nextMeta.Has("currentWSName") ? nextMeta["currentWSName"] : ""
        else
            try nextWSName := nextMeta.currentWSName
    }

    return (prevWSName != nextWSName)
}

; Atomically read and clear the workspace changed flag
; Used by store_server for OnChange delta style to send workspace_change messages
WindowStore_ConsumeWorkspaceChangedFlag() {
    global gWS_WorkspaceChangedFlag
    Critical "On"
    result := gWS_WorkspaceChangedFlag
    gWS_WorkspaceChangedFlag := false
    Critical "Off"
    return result
}

