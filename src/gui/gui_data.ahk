#Requires AutoHotkey v2.0
; Alt-Tabby GUI - Data Layer
; Direct WindowList access for GUI data layer
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals/functions

; hwnd -> item reference Map for O(1) lookups (populated alongside gGUI_LiveItems)
global gGUI_LiveItemsMap := Map()
global _gGUI_LastCosmeticRepaintTick := 0  ; Debounce for cosmetic repaints during ACTIVE

; ========================= LIVE ITEMS REFRESH =========================

; Refresh gGUI_LiveItems from WindowList — synchronous, always returns fresh data.
GUI_RefreshLiveItems() {
    Profiler.Enter("GUI_RefreshLiveItems") ; @profile
    global gGUI_LiveItems, gGUI_LiveItemsMap
    global gGUI_Sel, gGUI_OverlayVisible, gGUI_ScrollTop, gGUI_Revealed, gGUI_OverlayH
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

; ========================= BACKGROUND ICON PRE-CACHE =========================

; Kick the background HICON→bitmap pre-cache timer.
; Reads directly from gWS_Store (always current) — no dependency on display list freshness.
; Safe to call repeatedly: one-shot timer replacement deduplicates naturally.
GUI_KickPreCache() {
    global gGUI_State
    ; During ACTIVE, the visible-row path (A1 above) handles it
    if (gGUI_State = "ACTIVE")
        return
    SetTimer(_GUI_PreCacheTick, -50)
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
    work := []
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
    if (hasMore)
        SetTimer(_GUI_PreCacheTick, -50)
}
