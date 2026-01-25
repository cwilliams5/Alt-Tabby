; Alt-Tabby GUI - Store IPC
; Handles communication with WindowStore: messages, deltas, snapshots
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals/functions

; ========================= STORE MESSAGE HANDLER =========================

GUI_OnStoreMessage(line, hPipe := 0) {
    global gGUI_StoreConnected, gGUI_StoreRev, gGUI_Items, gGUI_Sel
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
        global gGUI_AwaitingToggleProjection, cfg
        isFrozen := cfg.FreezeWindowList
        isToggleResponse := IsSet(gGUI_AwaitingToggleProjection) && gGUI_AwaitingToggleProjection

        if (gGUI_State = "ACTIVE" && isFrozen && !isToggleResponse) {
            ; Frozen mode and not a toggle response: ignore incoming data
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
        if (mruAge < 300 && !isToggleResponse) {
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
                    gGUI_Sel := 2
                    if (gGUI_Sel > gGUI_FrozenItems.Length) {
                        gGUI_Sel := (gGUI_FrozenItems.Length > 0) ? 1 : 0
                    }
                    gGUI_ScrollTop := (gGUI_Sel > 0) ? gGUI_Sel - 1 : 0
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
}

; ========================= ITEM CONVERSION =========================

GUI_ConvertStoreItems(items) {
    result := []
    for _, item in items {
        hwnd := item.Has("hwnd") ? item["hwnd"] : 0
        result.Push({
            hwnd: hwnd,
            Title: item.Has("title") ? item["title"] : "",
            Class: item.Has("class") ? item["class"] : "",
            HWND: Format("0x{:X}", hwnd),
            PID: item.Has("pid") ? "" item["pid"] : "",
            WS: item.Has("workspaceName") ? item["workspaceName"] : "",
            isOnCurrentWorkspace: item.Has("isOnCurrentWorkspace") ? item["isOnCurrentWorkspace"] : true,
            processName: item.Has("processName") ? item["processName"] : "",
            iconHicon: item.Has("iconHicon") ? item["iconHicon"] : 0,
            lastActivatedTick: item.Has("lastActivatedTick") ? item["lastActivatedTick"] : 0
        })
    }
    return result
}

; ========================= DELTA APPLICATION =========================

GUI_ApplyDelta(payload) {
    global gGUI_Items, gGUI_Sel, gINT_BypassMode

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

    ; Handle removes - filter out items by hwnd
    if (payload.Has("removes") && payload["removes"].Length) {
        newItems := []
        for _, item in gGUI_Items {
            isRemoved := false
            for _, hwnd in payload["removes"] {
                if (item.hwnd = hwnd) {
                    isRemoved := true
                    break
                }
            }
            if (!isRemoved) {
                newItems.Push(item)
            }
        }
        if (newItems.Length != gGUI_Items.Length) {
            gGUI_Items := newItems
            changed := true
        }
    }

    ; Handle upserts - update existing or add new items
    if (payload.Has("upserts") && payload["upserts"].Length) {
        for _, rec in payload["upserts"] {
            if (!IsObject(rec)) {
                continue
            }
            hwnd := rec.Has("hwnd") ? rec["hwnd"] : 0
            if (!hwnd) {
                continue
            }

            ; Find existing item by hwnd
            found := false
            for i, item in gGUI_Items {
                if (item.hwnd = hwnd) {
                    ; Update existing item
                    if (rec.Has("title")) {
                        item.Title := rec["title"]
                    }
                    if (rec.Has("class")) {
                        item.Class := rec["class"]
                    }
                    if (rec.Has("pid")) {
                        item.PID := "" rec["pid"]
                    }
                    if (rec.Has("workspaceName")) {
                        item.WS := rec["workspaceName"]
                    }
                    if (rec.Has("isOnCurrentWorkspace")) {
                        item.isOnCurrentWorkspace := rec["isOnCurrentWorkspace"]
                    }
                    if (rec.Has("processName")) {
                        item.processName := rec["processName"]
                    }
                    if (rec.Has("iconHicon")) {
                        item.iconHicon := rec["iconHicon"]
                    }
                    if (rec.Has("lastActivatedTick")) {
                        item.lastActivatedTick := rec["lastActivatedTick"]
                    }
                    ; Track focus change (don't process here, just record it)
                    if (rec.Has("isFocused") && rec["isFocused"]) {
                        _GUI_LogEvent("DELTA FOCUS: hwnd=" hwnd " isFocused=true (update)")
                        focusChangedToHwnd := hwnd
                    }
                    found := true
                    changed := true
                    break
                }
            }

            ; Add new item if not found
            if (!found) {
                gGUI_Items.Push({
                    hwnd: hwnd,
                    Title: rec.Has("title") ? rec["title"] : "",
                    Class: rec.Has("class") ? rec["class"] : "",
                    HWND: Format("0x{:X}", hwnd),
                    PID: rec.Has("pid") ? "" rec["pid"] : "",
                    WS: rec.Has("workspaceName") ? rec["workspaceName"] : "",
                    isOnCurrentWorkspace: rec.Has("isOnCurrentWorkspace") ? rec["isOnCurrentWorkspace"] : true,
                    processName: rec.Has("processName") ? rec["processName"] : "",
                    iconHicon: rec.Has("iconHicon") ? rec["iconHicon"] : 0,
                    lastActivatedTick: rec.Has("lastActivatedTick") ? rec["lastActivatedTick"] : 0
                })
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

    ; Simple bubble sort by lastActivatedTick descending (higher = more recent = first)
    n := gGUI_Items.Length
    loop n - 1 {
        i := A_Index
        loop n - i {
            j := A_Index
            if (gGUI_Items[j].lastActivatedTick < gGUI_Items[j + 1].lastActivatedTick) {
                ; Swap
                temp := gGUI_Items[j]
                gGUI_Items[j] := gGUI_Items[j + 1]
                gGUI_Items[j + 1] := temp
            }
        }
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
