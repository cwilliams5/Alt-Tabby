; Alt-Tabby GUI - Store IPC
; Handles communication with WindowStore: messages, deltas, snapshots
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals/functions

; hwnd -> item reference Map for O(1) lookups (populated alongside gGUI_Items)
global gGUI_ItemsMap := Map()

; ========================= STORE MESSAGE HANDLER =========================

GUI_OnStoreMessage(line, hPipe := 0) {
    global gGUI_StoreConnected, gGUI_StoreRev, gGUI_Items, gGUI_Sel, gGUI_ItemsMap
    global gGUI_OverlayVisible, gGUI_OverlayH, gGUI_FooterText
    global gGUI_State, gGUI_FrozenItems, gGUI_AllItems  ; CRITICAL: All list state for updates
    global IPC_MSG_HELLO_ACK, IPC_MSG_SNAPSHOT, IPC_MSG_PROJECTION, IPC_MSG_DELTA
    global gGUI_LastLocalMRUTick  ; For skipping stale in-flight snapshots
    global gGUI_LastMsgTick  ; For health check timeout detection

    ; Track last message time for health check
    gGUI_LastMsgTick := A_TickCount

    obj := ""
    try {
        obj := JXON_Load(line)
    } catch as err {
        ; Log malformed JSON when diagnostics enabled (helps debug IPC issues)
        preview := (StrLen(line) > 80) ? SubStr(line, 1, 80) "..." : line
        _GUI_LogEvent("JSON parse error: " err.Message " | content: " preview)
        return
    }

    if (!IsObject(obj) || !obj.Has("type")) {
        return
    }

    type := obj["type"]

    if (type = IPC_MSG_HELLO_ACK) {
        gGUI_StoreConnected := true
        if (obj.Has("rev")) {
            gGUI_StoreRev := obj["rev"]
        }
        return
    }

    if (type = IPC_MSG_SNAPSHOT || type = IPC_MSG_PROJECTION) {
        ; When in ACTIVE state, list behavior depends on FreezeWindowList config
        ; EXCEPTION: If awaiting a toggle-triggered projection (UseCurrentWSProjection mode), accept it
        global gGUI_AwaitingToggleProjection, cfg, gGUI_PendingPhase
        isFrozen := cfg.FreezeWindowList
        isToggleResponse := IsSet(gGUI_AwaitingToggleProjection) && gGUI_AwaitingToggleProjection

        if (gGUI_State = "ACTIVE" && isFrozen && !isToggleResponse) {
            ; Frozen mode and not a toggle response: ignore incoming data
            if (obj.Has("rev")) {
                gGUI_StoreRev := obj["rev"]
            }
            return
        }

        ; ============================================================
        ; ASYNC ACTIVATION GUARD - DO NOT REMOVE
        ; ============================================================
        ; Skip snapshots while async cross-workspace activation is pending.
        ; During async activation (gGUI_PendingPhase != ""):
        ;   1. State is IDLE but we're still processing a switch
        ;   2. Events are being buffered for replay after activation
        ;   3. Incoming snapshots may contain filtered data (current WS only)
        ; If we accept the snapshot, gGUI_Items gets corrupted with partial
        ; data, causing "only 1 window shown" on next Alt+Tab.
        ; Toggle responses are exempt (user explicitly requested refresh).
        ; ============================================================
        if (gGUI_PendingPhase != "" && !isToggleResponse) {
            _GUI_LogEvent("SNAPSHOT: skipped (async activation pending, phase=" gGUI_PendingPhase ")")
            if (obj.Has("rev")) {
                gGUI_StoreRev := obj["rev"]
            }
            return
        }

        ; Clear the toggle flag if it was set
        if (isToggleResponse) {
            gGUI_AwaitingToggleProjection := false
        }

        ; CRITICAL: Skip snapshot if local MRU was updated recently
        ; This prevents stale in-flight snapshots from overwriting fresh local MRU order
        ; Exception: toggle responses should always be applied (user explicitly requested)
        if (!IsSet(gGUI_LastLocalMRUTick))
            gGUI_LastLocalMRUTick := 0
        mruAge := A_TickCount - gGUI_LastLocalMRUTick
        mruFreshness := cfg.HasOwnProp("AltTabMRUFreshnessMs") ? cfg.AltTabMRUFreshnessMs : 300
        if (mruAge < mruFreshness && !isToggleResponse) {
            _GUI_LogEvent("SNAPSHOT: skipped (local MRU is fresh, age=" mruAge "ms)")
            if (obj.Has("rev")) {
                gGUI_StoreRev := obj["rev"]
            }
            return
        }

        if (obj.Has("payload") && obj["payload"].Has("items")) {
            ; RACE FIX: Protect array modifications from hotkey interruption
            ; Hotkeys (Alt/Tab) may access gGUI_Items during state transitions
            Critical "On"
            gGUI_Items := GUI_ConvertStoreItems(obj["payload"]["items"])
            gGUI_ItemsMap := GUI_RebuildItemsMap(gGUI_Items)

            ; If in ACTIVE state (either !frozen or toggle response), update display
            if (gGUI_State = "ACTIVE" && (!isFrozen || isToggleResponse)) {
                gGUI_AllItems := gGUI_Items

                ; For server-side filtered toggle responses (UseCurrentWSProjection=true),
                ; the server already applied the currentWorkspaceOnly filter - don't re-filter
                if (isToggleResponse && cfg.UseCurrentWSProjection) {
                    ; Server already filtered - copy items directly
                    gGUI_FrozenItems := []
                    for _, item in gGUI_AllItems {
                        gGUI_FrozenItems.Push(item)
                    }
                } else {
                    ; Client-side filter (local filtering mode)
                    gGUI_FrozenItems := GUI_FilterByWorkspaceMode(gGUI_AllItems)
                }
                ; NOTE: Do NOT update gGUI_Items - it must stay unfiltered as the source of truth

                ; Reset selection for toggle response
                if (isToggleResponse) {
                    _GUI_ResetSelectionToMRU()
                }
            }

            ; Clamp selection based on state - use filtered list when ACTIVE
            displayItems := (gGUI_State = "ACTIVE") ? gGUI_FrozenItems : gGUI_Items
            if (gGUI_Sel > displayItems.Length && displayItems.Length > 0) {
                gGUI_Sel := displayItems.Length
            }
            if (gGUI_Sel < 1 && displayItems.Length > 0) {
                gGUI_Sel := 1
            }

            ; NOTE: Critical "Off" here is SAFE (unlike gui_state.ahk) because:
            ;   1. gGUI_FrozenItems is already populated inside this Critical section
            ;   2. GUI_Repaint uses frozen items when ACTIVE, which won't be modified
            ;   3. If not ACTIVE, overlay isn't visible so repaint won't trigger
            ; Compare with gui_state.ahk where Critical was released BEFORE
            ; gGUI_FrozenItems was populated, causing race conditions.
            Critical "Off"

            GUI_UpdateCurrentWSFromPayload(obj["payload"])

            ; Resize and repaint OUTSIDE Critical (GDI+ can pump messages)
            if (isToggleResponse && gGUI_State = "ACTIVE") {
                rowsDesired := GUI_ComputeRowsToShow(gGUI_FrozenItems.Length)
                GUI_ResizeToRows(rowsDesired)
            }

            if (gGUI_OverlayVisible && gGUI_OverlayH) {
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

        if (gGUI_State = "ACTIVE" && isFrozen) {
            ; Frozen mode: ignore deltas
            if (obj.Has("rev")) {
                gGUI_StoreRev := obj["rev"]
            }
            return
        }

        ; Apply delta incrementally to stay up-to-date
        if (obj.Has("payload")) {
            GUI_UpdateCurrentWSFromPayload(obj["payload"])
            GUI_ApplyDelta(obj["payload"])

            ; If in ACTIVE state with FreezeWindowList=false, update live display
            if (gGUI_State = "ACTIVE" && !isFrozen) {
                gGUI_AllItems := gGUI_Items
                gGUI_FrozenItems := GUI_FilterByWorkspaceMode(gGUI_AllItems)
                ; NOTE: Do NOT update gGUI_Items - it must stay unfiltered as the source of truth
                if (gGUI_OverlayVisible && gGUI_OverlayH) {
                    GUI_Repaint()
                }
            }
        }
        if (obj.Has("rev")) {
            gGUI_StoreRev := obj["rev"]
        }
        return
    }

    ; Unknown message type - log for debugging (could mask IPC bugs)
    _GUI_LogEvent("IPC: unknown message type: " type)
}

; ========================= ITEM CONVERSION =========================

; Helper: Create GUI item object from store record (Map with lowercase keys)
; Used by both GUI_ConvertStoreItems and GUI_ApplyDelta for consistency
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

GUI_ConvertStoreItems(items) {
    result := []
    for _, item in items {
        hwnd := item.Has("hwnd") ? item["hwnd"] : 0
        result.Push(_GUI_CreateItemFromRecord(hwnd, item))
    }
    return result
}

; Rebuild hwnd -> item Map from items array (call after replacing gGUI_Items)
GUI_RebuildItemsMap(items) {
    m := Map()
    for _, item in items
        m[item.hwnd] := item
    return m
}

; ========================= DELTA APPLICATION =========================

GUI_ApplyDelta(payload) {
    global gGUI_Items, gGUI_Sel, gINT_BypassMode, gGUI_ItemsMap

    changed := false
    focusChangedToHwnd := 0  ; Track if any window received focus

    ; Debug: log delta arrival when in bypass mode
    if (gINT_BypassMode) {
        upsertCount := (payload.Has("upserts") && payload["upserts"].Length) ? payload["upserts"].Length : 0
        _GUI_LogEvent("DELTA IN BYPASS: " upsertCount " upserts")
    }

    ; CRITICAL: Protect array modifications from hotkey interruption
    ; Hotkeys (Alt/Tab) may access gGUI_Items during state transitions
    Critical "On"

    ; Handle removes - filter out items by hwnd using Set for O(1) lookup
    if (payload.Has("removes") && payload["removes"].Length) {
        ; Build set for O(1) lookup instead of O(n) inner loop
        removeSet := Map()
        for _, hwnd in payload["removes"]
            removeSet[hwnd] := true

        ; Single pass filter O(n) instead of O(n*m)
        newItems := []
        for _, item in gGUI_Items {
            if (!removeSet.Has(item.hwnd))
                newItems.Push(item)
        }
        if (newItems.Length != gGUI_Items.Length) {
            gGUI_Items := newItems
            gGUI_ItemsMap := GUI_RebuildItemsMap(gGUI_Items)
            changed := true
        }
    }

    ; Handle upserts - update existing or add new items using Map for O(1) lookup
    if (payload.Has("upserts") && payload["upserts"].Length) {
        for _, rec in payload["upserts"] {
            if (!IsObject(rec))
                continue
            hwnd := rec.Has("hwnd") ? rec["hwnd"] : 0
            if (!hwnd)
                continue

            ; O(1) lookup instead of O(n) scan
            if (gGUI_ItemsMap.Has(hwnd)) {
                ; Update existing item
                item := gGUI_ItemsMap[hwnd]
                if (rec.Has("title"))
                    item.Title := rec["title"]
                if (rec.Has("class"))
                    item.Class := rec["class"]
                if (rec.Has("pid"))
                    item.PID := "" rec["pid"]
                if (rec.Has("workspaceName"))
                    item.WS := rec["workspaceName"]
                if (rec.Has("isOnCurrentWorkspace"))
                    item.isOnCurrentWorkspace := rec["isOnCurrentWorkspace"]
                if (rec.Has("processName"))
                    item.processName := rec["processName"]
                if (rec.Has("iconHicon"))
                    item.iconHicon := rec["iconHicon"]
                if (rec.Has("lastActivatedTick"))
                    item.lastActivatedTick := rec["lastActivatedTick"]
                ; Track focus change (don't process here, just record it)
                if (rec.Has("isFocused") && rec["isFocused"]) {
                    _GUI_LogEvent("DELTA FOCUS: hwnd=" hwnd " isFocused=true (update)")
                    focusChangedToHwnd := hwnd
                }
                changed := true
            } else {
                ; Add new item using shared helper
                newItem := _GUI_CreateItemFromRecord(hwnd, rec)
                gGUI_Items.Push(newItem)
                gGUI_ItemsMap[hwnd] := newItem
                ; Track focus change for new item too
                if (rec.Has("isFocused") && rec["isFocused"]) {
                    _GUI_LogEvent("DELTA FOCUS: hwnd=" hwnd " isFocused=true (new)")
                    focusChangedToHwnd := hwnd
                }
                changed := true
            }
        }
    }

    ; Re-sort by MRU (lastActivatedTick descending) if anything changed
    ; NOTE: Sort stays inside Critical for correctness - hotkeys read gGUI_Items.
    ; Performance is fine: O(n) for nearly-sorted data (typical MRU case).
    if (changed && gGUI_Items.Length > 1) {
        GUI_SortItemsByMRU()
    }

    ; Clamp selection
    if (gGUI_Sel > gGUI_Items.Length && gGUI_Items.Length > 0) {
        gGUI_Sel := gGUI_Items.Length
    }
    if (gGUI_Sel < 1 && gGUI_Items.Length > 0) {
        gGUI_Sel := 1
    }

    ; End critical section before bypass check (which may do significant work)
    Critical "Off"

    ; AFTER all delta processing: check bypass state for newly focused window
    ; This runs ONCE per delta, not per upsert - minimizes blocking time
    if (focusChangedToHwnd) {
        shouldBypass := INT_ShouldBypassWindow(focusChangedToHwnd)
        _GUI_LogEvent("BYPASS CHECK: hwnd=" focusChangedToHwnd " shouldBypass=" shouldBypass)
        INT_SetBypassMode(shouldBypass)
    }
}

GUI_SortItemsByMRU() {
    global gGUI_Items

    ; Insertion sort by lastActivatedTick descending (higher = more recent = first)
    ; O(n) for nearly-sorted data (typical case - MRU order rarely changes much)
    ; O(n²) worst case, but still better than bubble sort in practice
    n := gGUI_Items.Length
    if (n <= 1)
        return

    loop n {
        i := A_Index
        if (i = 1)
            continue
        key := gGUI_Items[i]
        keyTick := key.lastActivatedTick
        j := i - 1
        ; Shift elements that are smaller (older) than key to the right
        while (j >= 1 && gGUI_Items[j].lastActivatedTick < keyTick) {
            gGUI_Items[j + 1] := gGUI_Items[j]
            j -= 1
        }
        gGUI_Items[j + 1] := key
    }
}

; ========================= SELECTION VALIDATION =========================

; Validates and clamps selection to current list bounds
; Prevents race conditions when deltas change list length while selection points to old index
; Returns the validated selection index (always valid, or 0 if list is empty)
GUI_GetValidatedSel() {
    global gGUI_Sel, gGUI_State, gGUI_FrozenItems, gGUI_Items

    ; Determine which list to use based on state
    displayItems := (gGUI_State = "ACTIVE") ? gGUI_FrozenItems : gGUI_Items

    ; Handle empty list
    if (displayItems.Length = 0)
        return 0

    ; Clamp selection to valid range
    if (gGUI_Sel < 1)
        gGUI_Sel := 1
    if (gGUI_Sel > displayItems.Length)
        gGUI_Sel := displayItems.Length

    return gGUI_Sel
}

; ========================= SNAPSHOT/PROJECTION REQUESTS =========================

GUI_RequestSnapshot() {
    global gGUI_StoreClient, IPC_MSG_SNAPSHOT_REQUEST
    if (!gGUI_StoreClient || !gGUI_StoreClient.hPipe) {
        return
    }
    req := { type: IPC_MSG_SNAPSHOT_REQUEST, projectionOpts: { sort: "MRU", columns: "items", includeCloaked: true } }
    IPC_PipeClient_Send(gGUI_StoreClient, JXON_Dump(req))
}

; Request projection with optional workspace filtering (for UseCurrentWSProjection mode)
GUI_RequestProjectionWithWSFilter(currentWSOnly := false) {
    global gGUI_StoreClient, gGUI_AwaitingToggleProjection, IPC_MSG_PROJECTION_REQUEST
    if (!gGUI_StoreClient || !gGUI_StoreClient.hPipe) {
        return
    }
    opts := { sort: "MRU", columns: "items", includeCloaked: true }
    if (currentWSOnly) {
        opts.currentWorkspaceOnly := true
    }
    req := { type: IPC_MSG_PROJECTION_REQUEST, projectionOpts: opts }
    gGUI_AwaitingToggleProjection := true  ; Flag to allow this response during ACTIVE state
    IPC_PipeClient_Send(gGUI_StoreClient, JXON_Dump(req))
}
