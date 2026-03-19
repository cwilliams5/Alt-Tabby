#Requires AutoHotkey v2.0
; Alt-Tabby GUI - Data Layer
; Direct WindowList access for GUI data layer
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals/functions

; hwnd -> item reference Map for O(1) lookups (populated alongside gGUI_LiveItems)
global gGUI_LiveItemsMap := Map()
; _gGUI_LastCosmeticRepaintTick declared in gui_main.ahk (sole writer + reader)
global PRECACHE_TICK_MS := 50              ; Background icon pre-cache batch interval

; ========================= LIVE ITEMS REFRESH =========================

; Refresh gGUI_LiveItems from WindowList — synchronous, always returns fresh data.
GUI_RefreshLiveItems() {
    Profiler.Enter("GUI_RefreshLiveItems") ; @profile
    global gGUI_LiveItems, gGUI_LiveItemsMap
    global gGUI_Sel, gGUI_OverlayVisible, gGUI_ScrollTop, gGUI_Revealed, gGUI_BaseH
    global gGdip_IconCache, FR_EV_REFRESH, FR_EV_FG_GUARD, gFR_Enabled

    static dlOpts := { sort: "MRU", columns: "items", includeCloaked: true }
    proj := WL_GetDisplayList(dlOpts)

    ; Foreground guard: if the actual foreground window isn't in our display list,
    ; probe and add it at MRU #1 before freeze. Matches what Windows native Alt-Tab
    ; does — check GetForegroundWindow() at Alt-press time, not via event tracking.
    ; Common path: one DllCall + one Map.Has() (~1μs). Probe only on miss.
    fgHwnd := DllCall("GetForegroundWindow", "Ptr")
    if (fgHwnd && !proj.itemsMap.Has(fgHwnd)) {
        probe := WinUtils_ProbeWindow(fgHwnd, 0, false, true)
        if (probe) {
            probe["lastActivatedTick"] := A_TickCount
            probe["isFocused"] := true
            probe["present"] := true
            probe["presentNow"] := true
            WL_UpsertWindow([probe], "fg_guard_refresh")
            proj := WL_GetDisplayList(dlOpts)
            if (gFR_Enabled)
                FR_Record(FR_EV_FG_GUARD, fgHwnd)
        }
    }

    if (gFR_Enabled)
        FR_Record(FR_EV_REFRESH, proj.items.Length)
    Critical "On"
    gGUI_LiveItems := proj.items
    gGUI_LiveItemsMap := proj.itemsMap

    GUI_ClampSelection(gGUI_LiveItems)
    localItems := gGUI_LiveItems  ; Capture before releasing Critical (reentrant-safe)
    Critical "Off"

    ; Icon pre-caching outside Critical (uses localItems — safe if reentrant call replaces gGUI_LiveItems)
    if (gGUI_OverlayVisible) {
        visRows := GUI_GetVisibleRows()
        startIdx := Max(1, gGUI_ScrollTop + 1 - 3)
        endIdx := Min(localItems.Length, gGUI_ScrollTop + visRows + 3)
        idx := startIdx
        while (idx <= endIdx) {
            item := localItems[idx]
            if (item.iconHicon)
                Gdip_PreCacheIcon(item.hwnd, item.iconHicon)
            idx++
        }
    }
    ; Kick background pre-cache for remaining (non-visible) windows
    GUI_KickPreCache()

    ; Prune orphaned icon cache entries
    if (gGdip_IconCache.Count)
        Gdip_PruneIconCache(gGUI_LiveItemsMap)
    Profiler.Leave() ; @profile
}

; ========================= LIVE ITEM REMOVAL =========================

; Remove item at index from live items array and map.
; Caller must hold Critical. Returns remaining item count.
GUI_RemoveLiveItemAt(idx1) {
    global gGUI_LiveItems, gGUI_LiveItemsMap
    if (idx1 < 1 || idx1 > gGUI_LiveItems.Length)
        return gGUI_LiveItems.Length
    item := gGUI_LiveItems[idx1]
    gGUI_LiveItems.RemoveAt(idx1)
    if (item.HasOwnProp("hwnd") && gGUI_LiveItemsMap.Has(item.hwnd))
        gGUI_LiveItemsMap.Delete(item.hwnd)
    return gGUI_LiveItems.Length
}

; GUI_PatchCosmeticUpdates and _GUI_CosmeticLog removed (#178):
; Display items are now direct store record references — cosmetic data is always live.
; Repaint trigger moved to _GUI_OnProducerRevChanged (debounced GUI_Repaint).

; ========================= DISPLAY ITEM EVICTION (ACTIVE STATE) =========================
; #178 followup: Allow window destroys through frozen display list during ACTIVE.
; The freeze protects against noise (adds, reorders); a destroy is signal.
; Display list may shrink but never grow or reorder during ACTIVE.

; Evict item at index from frozen display list.
; Maintains hwnd-based selection tracking: destroyed above selection → index adjusts
; down to keep same hwnd selected. Destroyed IS selection → clamp to next.
; Caller must hold Critical. Returns remaining display item count.
GUI_EvictDisplayItem(idx1) {
    global gGUI_DisplayItems, gGUI_ToggleBase, gGUI_LiveItems, gGUI_LiveItemsMap
    global gGUI_Sel, gGUI_ScrollTop
    global gFR_Enabled, FR_EV_DISPLAY_EVICT

    if (idx1 < 1 || idx1 > gGUI_DisplayItems.Length)
        return gGUI_DisplayItems.Length

    item := gGUI_DisplayItems[idx1]
    hwnd := item.hwnd

    ; Capture selected hwnd before mutation
    selectedHwnd := 0
    if (gGUI_Sel >= 1 && gGUI_Sel <= gGUI_DisplayItems.Length)
        selectedHwnd := gGUI_DisplayItems[gGUI_Sel].hwnd
    wasSelected := (hwnd = selectedHwnd)

    ; Remove from display list
    gGUI_DisplayItems.RemoveAt(idx1)

    ; Remove from ToggleBase (may be same array ref when no filtering active)
    if (ObjPtr(gGUI_ToggleBase) != ObjPtr(gGUI_DisplayItems)) {
        i := gGUI_ToggleBase.Length
        while (i >= 1) {
            if (gGUI_ToggleBase[i].hwnd = hwnd) {
                gGUI_ToggleBase.RemoveAt(i)
                break
            }
            i--
        }
    }

    ; Remove from live items + map
    if (gGUI_LiveItemsMap.Has(hwnd)) {
        for j, liveItem in gGUI_LiveItems {
            if (liveItem.hwnd = hwnd) {
                gGUI_LiveItems.RemoveAt(j)
                break
            }
        }
        gGUI_LiveItemsMap.Delete(hwnd)
    }

    ; Adjust selection — track by hwnd
    remaining := gGUI_DisplayItems.Length
    if (remaining = 0) {
        gGUI_Sel := 1
        gGUI_ScrollTop := 0
    } else if (wasSelected) {
        ; Selected item was destroyed — clamp to next (or last if at end)
        gGUI_Sel := Min(idx1, remaining)
        gGUI_ScrollTop := Max(0, gGUI_Sel - 1)
    } else {
        ; PERF: Arithmetic adjustment — no scan needed.
        ; RemoveAt(idx1) shifts items at idx1+ down by 1.
        ; If idx1 < gGUI_Sel, selected item shifted down.
        ; If idx1 > gGUI_Sel, selected item unchanged.
        if (idx1 < gGUI_Sel)
            gGUI_Sel -= 1
        gGUI_ScrollTop := Max(0, gGUI_Sel - 1)
    }

    if (gFR_Enabled)
        FR_Record(FR_EV_DISPLAY_EVICT, hwnd, remaining, wasSelected ? 1 : 0)
    return remaining
}

; Scan frozen display list for windows no longer in the store and evict them.
; Called from _GUI_OnProducerRevChanged when a structural change arrives during ACTIVE.
; Returns count of items removed.
GUI_ReconcileDestroys() {
    global gGUI_State, gGUI_DisplayItems, gWS_Store
    Profiler.Enter("GUI_ReconcileDestroys") ; @profile

    if (gGUI_State != "ACTIVE") {
        Profiler.Leave() ; @profile
        return 0
    }

    Critical "On"
    removed := 0
    items := gGUI_DisplayItems  ; PERF: cache global ref, avoid repeated global dereference in loop
    i := items.Length
    while (i >= 1) {
        if (!gWS_Store.Has(items[i].hwnd + 0)) {
            GUI_EvictDisplayItem(i)
            removed++
        }
        i--
    }
    Critical "Off"

    if (removed > 0) {
        if (gGUI_DisplayItems.Length > 0) {
            GUI_RecalcHover()
            GUI_Repaint()
        } else {
            GUI_DismissOverlay()
        }
    }

    Profiler.Leave() ; @profile
    return removed
}

; ========================= BACKGROUND ICON PRE-CACHE =========================

; Kick the background HICON→bitmap pre-cache timer.
; Reads directly from gWS_Store (always current) — no dependency on display list freshness.
; Safe to call repeatedly: one-shot timer replacement deduplicates naturally.
GUI_KickPreCache() {
    global gGUI_State, PRECACHE_TICK_MS
    ; During ACTIVE, the visible-row path (A1 above) handles it
    if (gGUI_State = "ACTIVE")
        return
    SetTimer(_GUI_PreCacheTick, -PRECACHE_TICK_MS)
}

; Stop the background pre-cache timer (called from gui_main shutdown).
GUI_StopPreCache() {
    SetTimer(_GUI_PreCacheTick, 0)
}

; Self-draining timer: converts up to 4 HICONs → GDI+ bitmaps per tick.
; Scans gWS_Store for windows whose icon isn't yet in gGdip_IconCache (or is stale).
; Re-arms if more work remains; stops itself when everything is cached.
_GUI_PreCacheTick() {
    global gWS_Store, gGdip_IconCache, gGUI_State
    if (gGUI_State = "ACTIVE")
        return

    ; Scan store and collect uncached icons under Critical (safe Map iteration)
    ; gGdip_IconCache is GUI-thread-only, safe to read here
    Critical "On"
    static work := [] ; lint-ignore: static-in-timer
    work.Length := 0
    for hwnd, rec in gWS_Store {
        if (!rec.present || !rec.iconHicon)
            continue
        cached := gGdip_IconCache.Get(hwnd, 0)
        if (cached && cached.hicon = rec.iconHicon && cached.bitmap)
            continue
        work.Push({hwnd: hwnd, hicon: rec.iconHicon})
        if (work.Length >= 4)
            break
    }
    Critical "Off"
    hasMore := (work.Length >= 4)

    ; Convert outside Critical (~1-2ms per icon, non-blocking between calls)
    for _, job in work
        Gdip_PreCacheIcon(job.hwnd, job.hicon)

    ; Re-arm if we hit the batch cap (more may remain)
    if (hasMore) {
        global PRECACHE_TICK_MS
        SetTimer(_GUI_PreCacheTick, -PRECACHE_TICK_MS)
    }
}
