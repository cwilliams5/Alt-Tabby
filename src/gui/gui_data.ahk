#Requires AutoHotkey v2.0
; Alt-Tabby GUI - Data Layer
; Direct WindowList access: replaces IPC-based gui_store.ahk
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals/functions

; hwnd -> item reference Map for O(1) lookups (populated alongside gGUI_LiveItems)
global gGUI_LiveItemsMap := Map()
; hwnd -> 1-based position in gGUI_LiveItems for O(1) viewport range checks
global gGUI_LiveItemsIndex := Map()

; ========================= LIVE ITEMS REFRESH =========================

; Refresh gGUI_LiveItems from WindowList (direct, no IPC).
; Replaces GUI_RequestSnapshot() — synchronous, always returns fresh data.
GUI_RefreshLiveItems() {
    global gGUI_LiveItems, gGUI_LiveItemsMap, gGUI_LiveItemsIndex
    global gGUI_Sel, gGUI_OverlayVisible, gGUI_ScrollTop, gGUI_Revealed, gGUI_OverlayH
    global gGdip_IconCache, FR_EV_REFRESH

    proj := WL_GetDisplayList({ sort: "MRU", columns: "items", includeCloaked: true })
    FR_Record(FR_EV_REFRESH, proj.items.Length)
    Critical "On"
    gGUI_LiveItems := proj.items
    gGUI_LiveItemsMap := proj.itemsMap

    ; Build position index (hwnd -> 1-based index) for viewport checks
    gGUI_LiveItemsIndex := Map()
    loop gGUI_LiveItems.Length
        gGUI_LiveItemsIndex[gGUI_LiveItems[A_Index].hwnd] := A_Index

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
}

; ========================= COSMETIC PATCH DURING ACTIVE =========================

; Patch title/icon/processName/workspace in-place for displayed items during ACTIVE state.
; Does NOT add, remove, or reorder items — selection position is stable.
; gGUI_ToggleBase and gGUI_DisplayItems share item object references, so patching
; one patches both.
;
; Workspace data (workspaceName, isOnCurrentWorkspace) is also patched here because
; in the single-process architecture, gWS_OnWorkspaceChanged fires BEFORE producers
; finish updating the store. GUI_HandleWorkspaceSwitch re-filters with stale workspace
; data. This patch runs AFTER producers complete, correcting stale frozen items.
; If workspace data changed, re-filters display items to show the right windows.
;
; NOTE: Reads gWS_Store/gWS_DirtyHwnds without Critical. Accepted risk: a producer
; could modify a record mid-iteration, yielding one frame of mixed old/new cosmetic
; data. Self-corrects on next cycle; individual AHK property reads are atomic.
GUI_PatchCosmeticUpdates() {
    global gGUI_ToggleBase, gWS_Store, gWS_DirtyHwnds, cfg
    global gGUI_CurrentWSName, gGUI_DisplayItems, gGUI_OverlayVisible
    global _gGUI_LastCosmeticRepaintTick, FR_EV_COSMETIC_PATCH

    ; Debounce: skip if last cosmetic repaint was too recent
    if (cfg.GUI_ActiveRepaintDebounceMs > 0
        && A_TickCount - _gGUI_LastCosmeticRepaintTick < cfg.GUI_ActiveRepaintDebounceMs) {
        if (cfg.DiagCosmeticPatchLog)
            _GUI_CosmeticLog("DEBOUNCE skip (dirty=" gWS_DirtyHwnds.Count " elapsed=" (A_TickCount - _gGUI_LastCosmeticRepaintTick) "ms)")
        return
    }

    if (cfg.DiagCosmeticPatchLog)
        _GUI_CosmeticLog("PATCH start dirty=" gWS_DirtyHwnds.Count " base=" gGUI_ToggleBase.Length)

    ; Walk ToggleBase (frozen snapshot). DisplayItems is a subset of the same objects,
    ; so patching here updates both arrays.
    patched := 0
    wsPatched := false
    for _, item in gGUI_ToggleBase {
        hwnd := item.hwnd
        if (!gWS_DirtyHwnds.Has(hwnd))
            continue
        if (!gWS_Store.Has(hwnd))
            continue
        rec := gWS_Store[hwnd]
        ; Patch cosmetic fields in-place (no position change)
        titleChanged := (rec.title != item.title)
        iconChanged := (rec.iconHicon != item.iconHicon)
        procChanged := (rec.processName != item.processName)
        if (titleChanged) {
            if (cfg.DiagCosmeticPatchLog)
                _GUI_CosmeticLog("  TITLE hwnd=" hwnd " '" SubStr(item.title, 1, 25) "' -> '" SubStr(rec.title, 1, 25) "'")
            item.title := rec.title
            patched++
        }
        if (iconChanged) {
            if (cfg.DiagCosmeticPatchLog)
                _GUI_CosmeticLog("  ICON hwnd=" hwnd " h=" item.iconHicon " -> h=" rec.iconHicon (rec.iconHicon = 0 ? " *** ZEROED ***" : ""))
            item.iconHicon := rec.iconHicon
            patched++
        }
        if (procChanged) {
            if (cfg.DiagCosmeticPatchLog)
                _GUI_CosmeticLog("  PROC hwnd=" hwnd " '" item.processName "' -> '" rec.processName "'")
            item.processName := rec.processName
            patched++
        }
        ; Patch workspace data (handles window moves during ACTIVE state)
        if (rec.workspaceName != item.workspaceName) {
            if (cfg.DiagCosmeticPatchLog)
                _GUI_CosmeticLog("  WS hwnd=" hwnd " '" item.workspaceName "' -> '" rec.workspaceName "'")
            item.workspaceName := rec.workspaceName
            wsName := gGUI_CurrentWSName
            item.isOnCurrentWorkspace := (rec.workspaceName = wsName) || (rec.workspaceName = "")
            wsPatched := true
            patched++
        }
    }

    ; Workspace data changed — re-filter display items to show correct windows.
    ; A window move is a context switch (like a workspace switch): select the
    ; foreground window (the moved window) instead of keeping stale selection.
    if (wsPatched) {
        global gGUI_Sel, gGUI_ScrollTop
        gGUI_DisplayItems := GUI_FilterByWorkspaceMode(gGUI_ToggleBase)
        gGUI_ScrollTop := 0
        gGUI_Sel := 1
        fgHwnd := DllCall("GetForegroundWindow", "Ptr")
        if (fgHwnd) {
            for idx, item in gGUI_DisplayItems {
                if (item.hwnd = fgHwnd) {
                    gGUI_Sel := idx
                    break
                }
            }
        }
        GUI_ClampSelection(gGUI_DisplayItems)
        ; GUI_Repaint handles resize with deferred SetWindowPos (right before
        ; ULW) to prevent DWM frame desync between base and overlay.
    }

    if (patched > 0) {
        FR_Record(FR_EV_COSMETIC_PATCH, patched, gGUI_ToggleBase.Length)
        _gGUI_LastCosmeticRepaintTick := A_TickCount
        GUI_Repaint()
    } else if (cfg.DiagCosmeticPatchLog && gWS_DirtyHwnds.Count > 0) {
        _GUI_CosmeticLog("PATCH end patched=0 (dirty hwnds not in frozen set)")
    }
}

_GUI_CosmeticLog(msg) {
    static logPath := ""
    if (logPath = "")
        logPath := A_Temp "\tabby_cosmetic_patch.log"
    try LogAppend(logPath, msg)
}

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

    ; Snapshot store entries under Critical (safe Map iteration)
    Critical "On"
    entries := []
    for hwnd, rec in gWS_Store {
        if (rec.present && rec.iconHicon)
            entries.Push({hwnd: hwnd, hicon: rec.iconHicon})
    }
    Critical "Off"

    ; Filter to uncached icons (cache checks are safe outside Critical)
    work := []
    for _, e in entries {
        if (gGdip_IconCache.Has(e.hwnd)) {
            cached := gGdip_IconCache[e.hwnd]
            if (cached.hicon = e.hicon && cached.pBmp)
                continue
        }
        work.Push(e)
        if (work.Length >= 4)
            break
    }
    hasMore := (work.Length >= 4)

    ; Convert outside Critical (~1-2ms per icon, non-blocking between calls)
    for _, job in work
        Gdip_PreCacheIcon(job.hwnd, job.hicon)

    ; Re-arm if we hit the batch cap (more may remain)
    if (hasMore)
        SetTimer(_GUI_PreCacheTick, -50)
}

; ========================= VIEWPORT CHANGE DETECTION =========================

; Check if any of the changed hwnds are in the currently visible viewport.
; Used to skip expensive GDI+ repaints when only off-screen items changed.
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
