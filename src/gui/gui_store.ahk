#Requires AutoHotkey v2.0
; Alt-Tabby GUI - Store IPC
; Handles communication with WindowStore: messages, deltas, snapshots
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals/functions

; hwnd -> item reference Map for O(1) lookups (populated alongside gGUI_LiveItems)
global gGUI_LiveItemsMap := Map()

; ========================= STORE MESSAGE HANDLER =========================

GUI_OnStoreMessage(line, _hPipe := 0) {
    global gGUI_StoreConnected, gGUI_StoreRev, gGUI_LiveItems, gGUI_Sel, gGUI_LiveItemsMap
    global gGUI_OverlayVisible, gGUI_OverlayH, gGUI_FooterText, gGUI_ScrollTop, cfg
    global gGUI_Revealed  ; Used instead of gGUI_OverlayVisible for IPC repaint guards
    global gGUI_State, gGUI_DisplayItems, gGUI_ToggleBase  ; CRITICAL: All list state for updates
    global IPC_MSG_HELLO_ACK, IPC_MSG_SNAPSHOT, IPC_MSG_PROJECTION, IPC_MSG_DELTA
    global gGUI_LastLocalMRUTick  ; For skipping stale in-flight snapshots
    global gGUI_LastMsgTick  ; For health check timeout detection

    ; Track last message time for health check
    gGUI_LastMsgTick := A_TickCount

    obj := ""
    try {
        obj := JSON.Load(line)
    } catch as err {
        ; Log malformed JSON when diagnostics enabled (helps debug IPC issues)
        if (cfg.DiagEventLog) {
            preview := (StrLen(line) > 80) ? SubStr(line, 1, 80) "..." : line
            _GUI_LogEvent("JSON parse error: " err.Message " | content: " preview)
        }
        return
    }

    if (!IsObject(obj) || !obj.Has("type")) {
        return
    }

    type := obj["type"]

    if (type = IPC_MSG_HELLO_ACK) {
        gGUI_StoreConnected := true
        ; Extract store's hwnd for PostMessage pipe wake
        global gGUI_StoreWakeHwnd
        if (obj.Has("hwnd"))
            gGUI_StoreWakeHwnd := obj["hwnd"]
        if (obj.Has("rev")) {
            gGUI_StoreRev := obj["rev"]
        }
        return
    }

    if (type = IPC_MSG_SNAPSHOT || type = IPC_MSG_PROJECTION) {
        ; When in ACTIVE state, list behavior depends on FreezeWindowList config
        ; EXCEPTION: If awaiting a toggle-triggered projection (ServerSideWorkspaceFilter mode), accept it
        global gGUI_AwaitingToggleProjection, cfg, gGUI_PendingPhase
        isFrozen := cfg.FreezeWindowList
        isToggleResponse := IsSet(gGUI_AwaitingToggleProjection) && gGUI_AwaitingToggleProjection  ; lint-ignore: isset-with-default

        ; Even when frozen, track workspace changes (may trigger thaw via projection request)
        if (gGUI_State = "ACTIVE" && isFrozen && !isToggleResponse && obj.Has("payload"))
            GUI_UpdateCurrentWSFromPayload(obj["payload"])

        ; RACE FIX: Enter Critical before checking gGUI_PendingPhase to prevent
        ; a hotkey from starting async activation between the phase check and
        ; the array modifications below. Without this, a snapshot could be accepted
        ; when it should be rejected per the async guard's documented invariant.
        Critical "On"

        if (gGUI_State = "ACTIVE" && isFrozen && !isToggleResponse) {
            ; Frozen mode and not a toggle response: ignore incoming data
            if (obj.Has("rev")) {
                gGUI_StoreRev := obj["rev"]
            }
            return  ; lint-ignore: critical-section (AHK v2 auto-releases Critical on return)
        }

        ; ============================================================
        ; ASYNC ACTIVATION GUARD - DO NOT REMOVE
        ; ============================================================
        ; Skip snapshots while async cross-workspace activation is pending.
        ; During async activation (gGUI_PendingPhase != ""):
        ;   1. State is IDLE but we're still processing a switch
        ;   2. Events are being buffered for replay after activation
        ;   3. Incoming snapshots may contain filtered data (current WS only)
        ; If we accept the snapshot, gGUI_LiveItems gets corrupted with partial
        ; data, causing "only 1 window shown" on next Alt+Tab.
        ; Toggle responses are exempt (user explicitly requested refresh).
        ; ============================================================
        if (gGUI_PendingPhase != "" && !isToggleResponse) {
            if (cfg.DiagEventLog)
                _GUI_LogEvent("SNAPSHOT: skipped (async activation pending, phase=" gGUI_PendingPhase ")")
            if (obj.Has("rev")) {
                gGUI_StoreRev := obj["rev"]
            }
            return  ; lint-ignore: critical-section (AHK v2 auto-releases Critical on return)
        }

        ; Clear the toggle flag if it was set
        if (isToggleResponse) {
            gGUI_AwaitingToggleProjection := false
        }

        ; CRITICAL: Skip snapshot if local MRU was updated recently
        ; This prevents stale in-flight snapshots from overwriting fresh local MRU order
        ; Exception: toggle responses should always be applied (user explicitly requested)
        if (!IsSet(gGUI_LastLocalMRUTick))  ; lint-ignore: isset-with-default
            gGUI_LastLocalMRUTick := 0
        mruAge := A_TickCount - gGUI_LastLocalMRUTick
        global gCached_MRUFreshnessMs
        if (mruAge < gCached_MRUFreshnessMs && !isToggleResponse) {
            if (cfg.DiagEventLog)
                _GUI_LogEvent("SNAPSHOT: skipped (local MRU is fresh, age=" mruAge "ms)")
            if (obj.Has("rev")) {
                gGUI_StoreRev := obj["rev"]
            }
            return  ; lint-ignore: critical-section (AHK v2 auto-releases Critical on return)
        }

        if (obj.Has("payload") && obj["payload"].Has("items")) {
            ; Critical already held from above (phase check guard)
            ; Single-pass conversion: builds both items array and Map together
            converted := GUI_ConvertStoreItemsWithMap(obj["payload"]["items"])
            gGUI_LiveItems := converted.items
            gGUI_LiveItemsMap := converted.map
            ; Note: Icon cache pruning moved outside Critical section (see below)

            ; If in ACTIVE state (either !frozen or toggle response), update display
            if (gGUI_State = "ACTIVE" && (!isFrozen || isToggleResponse)) {
                gGUI_ToggleBase := gGUI_LiveItems

                ; For server-side filtered toggle responses (ServerSideWorkspaceFilter=true),
                ; the server already applied the currentWorkspaceOnly filter - don't re-filter
                if (isToggleResponse && cfg.ServerSideWorkspaceFilter) {
                    ; Server already filtered - copy items directly
                    gGUI_DisplayItems := []
                    for _, item in gGUI_ToggleBase {
                        gGUI_DisplayItems.Push(item)
                    }
                } else {
                    ; Client-side filter (local filtering mode)
                    gGUI_DisplayItems := GUI_FilterByWorkspaceMode(gGUI_ToggleBase)
                }
                ; NOTE: Do NOT update gGUI_LiveItems - it must stay unfiltered as the source of truth

                ; Reset selection for toggle response
                if (isToggleResponse) {
                    _GUI_ResetSelectionToMRU()
                }
            }

            ; Clamp selection based on state - use filtered list when ACTIVE
            displayItems := (gGUI_State = "ACTIVE") ? gGUI_DisplayItems : gGUI_LiveItems
            if (gGUI_Sel > displayItems.Length && displayItems.Length > 0) {
                gGUI_Sel := displayItems.Length
            }
            if (gGUI_Sel < 1 && displayItems.Length > 0) {
                gGUI_Sel := 1
            }

            ; NOTE: Critical "Off" here is SAFE (unlike gui_state.ahk) because:
            ;   1. gGUI_DisplayItems is already populated inside this Critical section
            ;   2. GUI_Repaint uses display items when ACTIVE, which won't be modified
            ;   3. If not ACTIVE, overlay isn't visible so repaint won't trigger
            ; Compare with gui_state.ahk where Critical was released BEFORE
            ; gGUI_DisplayItems was populated, causing race conditions.
            Critical "Off"

            ; LATENCY FIX: Pre-cache icon bitmaps OUTSIDE Critical section.
            ; _Gdip_CreateBitmapFromHICON_Alpha takes 0.5-2ms per icon via GDI+ DllCall.
            ; With 10-30 windows this blocked hotkeys for 5-60ms during snapshot processing.
            ; Safe: no new IPC arrives mid-callback, Gdip_DrawCachedIcon handles misses on-demand.
            if (gGUI_OverlayVisible) {
                ; Active overlay: only pre-cache viewport + scroll buffer for fast repaint
                visRows := GUI_GetVisibleRows()
                startIdx := Max(1, gGUI_ScrollTop + 1 - 3)
                endIdx := Min(gGUI_LiveItems.Length, gGUI_ScrollTop + visRows + 3)
                idx := startIdx
                while (idx <= endIdx) {
                    item := gGUI_LiveItems[idx]
                    if (item.iconHicon)
                        Gdip_PreCacheIcon(item.hwnd, item.iconHicon)
                    idx++
                }
            } else {
                ; Background: pre-cache everything while we have idle time
                for _, item in gGUI_LiveItems {
                    if (item.iconHicon)
                        Gdip_PreCacheIcon(item.hwnd, item.iconHicon)
                }
            }

            ; LATENCY FIX: Prune icon cache OUTSIDE Critical section.
            ; Gdip_PruneIconCache iterates the cache and calls GdipDisposeImage DllCalls
            ; which can take 2-5ms. gGUI_LiveItemsMap is stable after assignment above.
            Gdip_PruneIconCache(gGUI_LiveItemsMap)

            GUI_UpdateCurrentWSFromPayload(obj["payload"])

            ; NOTE: Removed explicit GUI_ResizeToRows() - GUI_Repaint handles resize
            ; internally. The separate resize called DwmFlush() before the paint,
            ; committing the new window size with stale overlay content.
            if (gGUI_Revealed && gGUI_OverlayH) {
                GUI_Repaint()
            }
        }
        if (obj.Has("rev")) {
            gGUI_StoreRev := obj["rev"]
        }
        return
    }

    if (type = IPC_MSG_DELTA) {
        ; When in ACTIVE state, list behavior depends on FreezeWindowList config
        global cfg
        isFrozen := cfg.FreezeWindowList

        ; Track workspace changes even when frozen (triggers thaw if workspace switched)
        if (obj.Has("payload"))
            GUI_UpdateCurrentWSFromPayload(obj["payload"])

        if (gGUI_State = "ACTIVE" && isFrozen) {
            ; Frozen mode: ignore deltas (workspace thaw already handled above)
            if (obj.Has("rev")) {
                gGUI_StoreRev := obj["rev"]
            }
            return
        }

        ; Apply delta incrementally to stay up-to-date
        if (obj.Has("payload")) {
            result := GUI_ApplyDelta(obj["payload"])

            if (gGUI_State = "ACTIVE" && !isFrozen) {
                if (result.mruChanged || result.membershipChanged) {
                    Critical "On"
                    gGUI_ToggleBase := gGUI_LiveItems
                    gGUI_DisplayItems := GUI_FilterByWorkspaceMode(gGUI_ToggleBase)
                    Critical "Off"
                }
                if (gGUI_Revealed && gGUI_OverlayH) {
                    if (result.mruChanged || result.membershipChanged || _GUI_AnyVisibleItemChanged(gGUI_DisplayItems, result.changedHwnds))
                        GUI_Repaint()
                }
            }
        }
        if (obj.Has("rev")) {
            gGUI_StoreRev := obj["rev"]
        }
        return
    }

    ; Handle workspace_change message (OnChange delta style)
    global IPC_MSG_WORKSPACE_CHANGE
    if (type = IPC_MSG_WORKSPACE_CHANGE) {
        if (obj.Has("payload"))
            GUI_UpdateCurrentWSFromPayload(obj["payload"])
        return
    }

    ; Unknown message type - log for debugging (could mask IPC bugs)
    if (cfg.DiagEventLog)
        _GUI_LogEvent("IPC: unknown message type: " type)
}

; ========================= ITEM CONVERSION =========================

; Helper: Create GUI item object from store record (Map with lowercase keys)
; Used by GUI_ConvertStoreItemsWithMap and GUI_ApplyDelta for consistency
_GUI_CreateItemFromRecord(hwnd, rec) {
    return {
        hwnd: hwnd,
        Title: rec.Has("title") ? rec["title"] : "",
        Class: rec.Has("class") ? rec["class"] : "",
        hwndHex: Format("0x{:X}", hwnd),
        PID: rec.Has("pid") ? "" rec["pid"] : "",
        WS: rec.Has("workspaceName") ? rec["workspaceName"] : "",
        isOnCurrentWorkspace: rec.Has("isOnCurrentWorkspace") ? rec["isOnCurrentWorkspace"] : true,
        processName: rec.Has("processName") ? rec["processName"] : "",
        iconHicon: rec.Has("iconHicon") ? rec["iconHicon"] : 0,
        lastActivatedTick: rec.Has("lastActivatedTick") ? rec["lastActivatedTick"] : 0
    }
}

; Single-pass conversion returning both items array and hwnd->item Map
; Eliminates redundant O(n) iteration vs calling ConvertStoreItems + RebuildItemsMap separately
; Icon pre-caching is done separately outside Critical (see GUI_HandleSnapshot).
GUI_ConvertStoreItemsWithMap(items) {
    result := []
    resultMap := Map()
    for _, item in items {
        hwnd := item.Has("hwnd") ? item["hwnd"] : 0
        converted := _GUI_CreateItemFromRecord(hwnd, item)
        result.Push(converted)
        resultMap[hwnd] := converted
    }
    return { items: result, map: resultMap }
}

; ========================= DELTA APPLICATION =========================

GUI_ApplyDelta(payload) {
    global gGUI_LiveItems, gGUI_Sel, gINT_BypassMode, gGUI_LiveItemsMap, cfg
    global gGUI_OverlayVisible, gGUI_ScrollTop

    mruChanged := false      ; Track if sort-relevant fields changed (MRU order or item count)
    membershipChanged := false  ; Track if workspace membership changed (isOnCurrentWorkspace flipped)
    changedHwnds := Map()    ; Track which hwnds were affected (for viewport-based repaint)
    focusChangedToHwnd := 0  ; Track if any window received focus
    needsIconPrune := false  ; Track if icon cache should be pruned (after removes)
    iconsToPrecache := []    ; Collect icon pre-cache work for outside Critical

    ; Debug: log delta arrival when in bypass mode
    if (gINT_BypassMode && cfg.DiagEventLog) {
        upsertCount := (payload.Has("upserts") && payload["upserts"].Length) ? payload["upserts"].Length : 0
        _GUI_LogEvent("DELTA IN BYPASS: " upsertCount " upserts")
    }

    ; CRITICAL: Protect array modifications from hotkey interruption
    ; Hotkeys (Alt/Tab) may access gGUI_LiveItems during state transitions
    Critical "On"

    ; Handle removes - filter out items by hwnd using Set for O(1) lookup
    if (payload.Has("removes") && payload["removes"].Length) {
        ; Build set for O(1) lookup instead of O(n) inner loop
        removeSet := Map()
        for _, hwnd in payload["removes"] {
            removeSet[hwnd] := true
            changedHwnds[hwnd] := true
            Gdip_InvalidateIconCache(hwnd)
        }

        ; Single pass filter O(n) instead of O(n*m)
        newItems := []
        for _, item in gGUI_LiveItems {
            if (!removeSet.Has(item.hwnd))
                newItems.Push(item)
        }
        if (newItems.Length != gGUI_LiveItems.Length) {
            gGUI_LiveItems := newItems
            ; Incremental map update: delete removed hwnds instead of rebuilding O(n)
            for _, hwnd in payload["removes"] {
                if (gGUI_LiveItemsMap.Has(hwnd))
                    gGUI_LiveItemsMap.Delete(hwnd)
            }
            ; Prune icon cache for removed windows (outside Critical below)
            needsIconPrune := true
            mruChanged := true  ; Item count changed, layout affected
        }
    }

    ; Handle upserts - update existing or add new items using Map for O(1) lookup
    if (payload.Has("upserts") && payload["upserts"].Length) {
        for _, rec in payload["upserts"] {
            if (!IsObject(rec))
                continue  ; lint-ignore: critical-section
            hwnd := rec.Has("hwnd") ? rec["hwnd"] : 0
            if (!hwnd)
                continue  ; lint-ignore: critical-section

            changedHwnds[hwnd] := true

            ; O(1) lookup instead of O(n) scan
            if (gGUI_LiveItemsMap.Has(hwnd)) {
                ; Update existing item
                item := gGUI_LiveItemsMap[hwnd]
                if (rec.Has("title"))
                    item.Title := rec["title"]
                if (rec.Has("class"))
                    item.Class := rec["class"]
                if (rec.Has("pid"))
                    item.PID := "" rec["pid"]
                if (rec.Has("workspaceName"))
                    item.WS := rec["workspaceName"]
                if (rec.Has("isOnCurrentWorkspace")) {
                    newVal := rec["isOnCurrentWorkspace"]
                    if (item.isOnCurrentWorkspace != newVal) {
                        item.isOnCurrentWorkspace := newVal
                        membershipChanged := true
                    }
                }
                if (rec.Has("processName"))
                    item.processName := rec["processName"]
                if (rec.Has("iconHicon")) {
                    item.iconHicon := rec["iconHicon"]
                    ; Defer GDI+ pre-cache to outside Critical (0.5-2ms per icon DllCall)
                    iconsToPrecache.Push({hwnd: hwnd, hicon: item.iconHicon})
                }
                if (rec.Has("lastActivatedTick")) {
                    newTick := rec["lastActivatedTick"]
                    if (item.lastActivatedTick != newTick) {
                        item.lastActivatedTick := newTick
                        mruChanged := true
                    }
                }
                ; Track focus change (don't process here, just record it)
                if (rec.Has("isFocused") && rec["isFocused"]) {
                    if (cfg.DiagEventLog)
                        _GUI_LogEvent("DELTA FOCUS: hwnd=" hwnd " isFocused=true (update)")
                    focusChangedToHwnd := hwnd
                    mruChanged := true
                }
            } else {
                ; Add new item using shared helper
                newItem := _GUI_CreateItemFromRecord(hwnd, rec)
                gGUI_LiveItems.Push(newItem)
                gGUI_LiveItemsMap[hwnd] := newItem
                ; Defer GDI+ pre-cache to outside Critical (0.5-2ms per icon DllCall)
                if (newItem.iconHicon)
                    iconsToPrecache.Push({hwnd: hwnd, hicon: newItem.iconHicon})
                ; Track focus change for new item too
                if (rec.Has("isFocused") && rec["isFocused"]) {
                    if (cfg.DiagEventLog)
                        _GUI_LogEvent("DELTA FOCUS: hwnd=" hwnd " isFocused=true (new)")
                    focusChangedToHwnd := hwnd
                }
                mruChanged := true  ; New item added, layout affected
            }
        }
    }

    ; Only sort when MRU-relevant fields changed (lastActivatedTick, isFocused, items added/removed).
    ; Skip sort for cosmetic-only updates (icon, processName, title) — saves O(n) per delta.
    if (mruChanged && gGUI_LiveItems.Length > 1) {
        GUI_SortItemsByMRU()
    }

    ; Clamp selection
    if (gGUI_Sel > gGUI_LiveItems.Length && gGUI_LiveItems.Length > 0) {
        gGUI_Sel := gGUI_LiveItems.Length
    }
    if (gGUI_Sel < 1 && gGUI_LiveItems.Length > 0) {
        gGUI_Sel := 1
    }

    ; End critical section before bypass check (which may do significant work)
    Critical "Off"

    ; LATENCY FIX: Pre-cache icon bitmaps OUTSIDE Critical section.
    ; Deferred from upsert loop to avoid blocking hotkeys during GDI+ DllCalls.
    if (iconsToPrecache.Length > 0) {
        if (gGUI_OverlayVisible) {
            ; Active overlay: only pre-cache icons within viewport range
            visRows := GUI_GetVisibleRows()
            vpStart := Max(1, gGUI_ScrollTop + 1 - 3)
            vpEnd := Min(gGUI_LiveItems.Length, gGUI_ScrollTop + visRows + 3)
            for _, ic in iconsToPrecache {
                idx := 0
                for i, liveItem in gGUI_LiveItems {
                    if (liveItem.hwnd = ic.hwnd) {
                        idx := i
                        break
                    }
                }
                if (idx >= vpStart && idx <= vpEnd)
                    Gdip_PreCacheIcon(ic.hwnd, ic.hicon)
            }
        } else {
            ; Background: pre-cache all new icons
            for _, ic in iconsToPrecache
                Gdip_PreCacheIcon(ic.hwnd, ic.hicon)
        }
    }

    ; Prune orphaned icon cache entries for removed windows (outside Critical
    ; because GdipDisposeImage DllCalls can take 2-5ms)
    if (needsIconPrune)
        Gdip_PruneIconCache(gGUI_LiveItemsMap)

    ; AFTER all delta processing: check bypass state for newly focused window
    ; This runs ONCE per delta, not per upsert - minimizes blocking time
    if (focusChangedToHwnd) {
        shouldBypass := INT_ShouldBypassWindow(focusChangedToHwnd)
        if (cfg.DiagEventLog)
            _GUI_LogEvent("BYPASS CHECK: hwnd=" focusChangedToHwnd " shouldBypass=" shouldBypass)
        INT_SetBypassMode(shouldBypass)
    }

    return { mruChanged: mruChanged, membershipChanged: membershipChanged, changedHwnds: changedHwnds }
}

GUI_SortItemsByMRU() {
    global gGUI_LiveItems

    ; Insertion sort by lastActivatedTick descending (higher = more recent = first)
    ; O(n) for nearly-sorted data (typical case - MRU order rarely changes much)
    ; O(n²) worst case, but still better than bubble sort in practice
    n := gGUI_LiveItems.Length
    if (n <= 1)
        return

    loop n {
        i := A_Index
        if (i = 1)
            continue
        key := gGUI_LiveItems[i]
        keyTick := key.lastActivatedTick
        j := i - 1
        ; Shift elements that are smaller (older) than key to the right
        while (j >= 1 && gGUI_LiveItems[j].lastActivatedTick < keyTick) {
            gGUI_LiveItems[j + 1] := gGUI_LiveItems[j]
            j -= 1
        }
        gGUI_LiveItems[j + 1] := key
    }
}

; ========================= VIEWPORT CHANGE DETECTION =========================

; Check if any of the changed hwnds are in the currently visible viewport.
; Used to skip expensive GDI+ repaints when only off-screen items changed
; (e.g., background icon/processName resolution for non-visible windows).
_GUI_AnyVisibleItemChanged(displayItems, changedHwnds) {
    global gGUI_ScrollTop
    if (changedHwnds.Count = 0 || displayItems.Length = 0)
        return false
    vis := GUI_GetVisibleRows()
    if (vis <= 0)
        return false
    startIdx := gGUI_ScrollTop + 1
    endIdx := gGUI_ScrollTop + vis
    if (endIdx > displayItems.Length)
        endIdx := displayItems.Length
    idx := startIdx
    while (idx <= endIdx) {
        if (changedHwnds.Has(displayItems[idx].hwnd))
            return true
        idx++
    }
    return false
}

; ========================= SNAPSHOT/PROJECTION REQUESTS =========================

GUI_RequestSnapshot() {
    global gGUI_StoreClient, IPC_MSG_SNAPSHOT_REQUEST, IPC_TICK_ACTIVE, gGUI_StoreWakeHwnd
    if (!gGUI_StoreClient || !gGUI_StoreClient.hPipe) {
        return
    }
    ; PERF: Cache the JSON string — same request shape every time, avoids JSON.Dump per Alt press
    static cachedJson := ""
    if (cachedJson = "") {
        cachedJson := JSON.Dump({ type: IPC_MSG_SNAPSHOT_REQUEST,
            projectionOpts: { sort: "MRU", columns: "items", includeCloaked: true } })
    }
    IPC_PipeClient_Send(gGUI_StoreClient, cachedJson, gGUI_StoreWakeHwnd)
    ; Drop to active polling so the response is read within ~15ms instead of up to 100ms
    gGUI_StoreClient.idleStreak := 0
    _IPC_SetClientTick(gGUI_StoreClient, IPC_TICK_ACTIVE)
}

; Request projection with optional workspace filtering (for ServerSideWorkspaceFilter mode)
GUI_RequestProjectionWithWSFilter(currentWSOnly := false) {
    global gGUI_StoreClient, gGUI_AwaitingToggleProjection, IPC_MSG_PROJECTION_REQUEST, gGUI_StoreWakeHwnd
    if (!gGUI_StoreClient || !gGUI_StoreClient.hPipe) {
        return
    }
    ; PERF: Cache the two JSON variants — avoids JSON.Dump on every workspace toggle
    static cachedJsonAll := ""
    static cachedJsonCurrentOnly := ""
    if (cachedJsonAll = "") {
        cachedJsonAll := JSON.Dump({ type: IPC_MSG_PROJECTION_REQUEST,
            projectionOpts: { sort: "MRU", columns: "items", includeCloaked: true } })
        cachedJsonCurrentOnly := JSON.Dump({ type: IPC_MSG_PROJECTION_REQUEST,
            projectionOpts: { sort: "MRU", columns: "items", includeCloaked: true, currentWorkspaceOnly: true } })
    }
    gGUI_AwaitingToggleProjection := true  ; Flag to allow this response during ACTIVE state
    IPC_PipeClient_Send(gGUI_StoreClient, currentWSOnly ? cachedJsonCurrentOnly : cachedJsonAll, gGUI_StoreWakeHwnd)
    ; Drop to active polling so the response is read within ~15ms instead of up to 100ms
    global IPC_TICK_ACTIVE
    gGUI_StoreClient.idleStreak := 0
    _IPC_SetClientTick(gGUI_StoreClient, IPC_TICK_ACTIVE)
}
