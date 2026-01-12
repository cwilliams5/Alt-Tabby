#Requires AutoHotkey v2.0
; =============================================================================
; komorebi_pump.ahk — integrates Komorebi workspace info into WindowStore
; Roles:
;   - Tracks current workspace and reflects it into WindowStore.
;   - Seeds/keeps rows for windows in the current workspace (for snappy UI).
;   - Services the WindowStore WS queue: resolves workspaceName for hwnds,
;     merges hints via WindowStore_Ensure(), or requeues if unresolved.
; Design:
;   - Uses ONLY komorebi.ahk helpers (no direct calls to komorebi_sub.ahk).
;   - All writes are stamped with source="komorebi" to respect ownership guards.
; =============================================================================

; ---------- Tunables ----------------------------------------------------------
if !IsSet(KomoTimerIntervalMs)
    KomoTimerIntervalMs := 140        ; cadence for pump tick
if !IsSet(KomoWSBatchPerTick)
    KomoWSBatchPerTick := 24          ; how many hwnds we try to resolve per tick
if !IsSet(KomoPrimeOnStart)
    KomoPrimeOnStart := true          ; do an initial prime of current workspace

; ---------- Module state ------------------------------------------------------
global _KP_TimerOn     := false
global _KP_LastWSId    := ""
global _KP_LastWSName  := ""
global _KP_Primed      := false

; ---------- Public API --------------------------------------------------------
KomorebiPump_Start() {
    global _KP_TimerOn, KomoTimerIntervalMs, KomoPrimeOnStart, _KP_Primed
    if (_KP_TimerOn)
        return
    _KP_TimerOn := true
    _KP_Primed := false   ; let first tick (or prime) do seeding
    SetTimer(_KP_Tick, KomoTimerIntervalMs)
}

KomorebiPump_Stop() {
    global _KP_TimerOn
    if !_KP_TimerOn
        return
    _KP_TimerOn := false
    SetTimer(_KP_Tick, 0)
}

; ---------- Core tick ---------------------------------------------------------
_KP_Tick() {
    global _KP_LastWSId, _KP_LastWSName, _KP_Primed, KomoPrimeOnStart, KomoWSBatchPerTick

    ; 1) Read current workspace (id + name) from komorebi state
    cur := ""
    try cur := Komorebi_GetCurrentWorkspace()
    catch

    wsChanged := false
    if (IsObject(cur)) {
        if (cur.id . "" != _KP_LastWSId . "" || cur.name . "" != _KP_LastWSName . "") {
            _KP_LastWSId   := cur.id   . ""
            _KP_LastWSName := cur.name . ""
            ; reflect into the store
            try WindowStore_SetCurrentWorkspace(_KP_LastWSId, _KP_LastWSName)
            catch
            wsChanged := true
        }
    }

    ; 2) Prime on first run OR whenever the workspace changes:
    ;    ensure all hwnds from the current workspace so they get marked/known.
    if ((KomoPrimeOnStart && !_KP_Primed) || wsChanged) {
        _KP_Primed := true
        if (_KP_LastWSName != "") {
            ; hwnds currently in this workspace (fast single-pass parse)
            list := ""
            try list := Komorebi_ListCurrentWorkspaceHwnds()
            catch
            if (IsObject(list)) {
                for _, hw in list {
                    hints := { workspaceName: _KP_LastWSName, isOnCurrentWorkspace: true }
                    ; ensure rows exist & annotate with workspace hints
                    try WindowStore_Ensure(hw + 0, hints, "komorebi")
                    catch
                }
            }
        }
    }

    ; 3) Service the WindowStore WS queue (resolve workspaceName for unknown rows).
    hwnds := []
    try hwnds := WindowStore_PopWSBatch(KomoWSBatchPerTick)
    catch
    if (!IsObject(hwnds) || hwnds.Length = 0)
        return

    ; Build a dictionary from a single MapAllWindows() pass to resolve many at once.
    wsMapArr := ""
    try wsMapArr := Komorebi_MapAllWindows()
    catch
    wsMap := Map()
    if (IsObject(wsMapArr)) {
        for _, it in wsMapArr {
            if (IsObject(it) && it.Has("hwnd") && it.Has("wsName")) {
                wsMap[it.hwnd + 0] := it.wsName . ""
            }
        }
    }

    ; Optional: also grab the current workspace hwnd list to cheaply mark on-current set.
    curSet := Map()
    if (_KP_LastWSName != "") {
        lcur := ""
        try lcur := Komorebi_ListCurrentWorkspaceHwnds()
        catch
        if (IsObject(lcur)) {
            for _, hw in lcur
                curSet[hw + 0] := true
        }
    }

    ; Resolve each queued hwnd using the map (or fallback to current WS membership)
    for _, hwnd in hwnds {
        hwnd := hwnd + 0
        hints := Map()
        if (wsMap.Has(hwnd)) {
            w := wsMap[hwnd]
            hints["workspaceName"] := w
            if (_KP_LastWSName != "")
                hints["isOnCurrentWorkspace"] := (w = _KP_LastWSName)
            try WindowStore_Ensure(hwnd, hints, "komorebi")
            catch
            continue
        }
        ; Fallback: if we know it's in the current workspace by membership, stamp name
        if (_KP_LastWSName != "" && curSet.Has(hwnd)) {
            hints["workspaceName"] := _KP_LastWSName
            hints["isOnCurrentWorkspace"] := true
            try WindowStore_Ensure(hwnd, hints, "komorebi")
            catch
            continue
        }
        ; Couldn’t resolve now → nudge the store to requeue needsWS for a later tick.
        try WindowStore_UpdateFields(hwnd, Map(), "komorebi")
        catch
    }
}
