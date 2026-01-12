; ================== komorebi.ahk ==================
; Single source for Komorebi helpers.
; Depends on: _Log(msg) and RunTry(cmdLine) from helpers.ahk
; Ensure helpers.ahk is #included before this file.

if !IsSet(DebugKomorebi)
    global DebugKomorebi := false

; --- Tiny state TTL cache (avoid re-spawning komorebic state repeatedly)
global KState_Text := ""
global KState_Stamp := 0
global KState_TTL := 180   ; ms

; --- LRU cache for hwnd -> (mIdx, wsIdx, wsName)
global KLRU_Map := Map()    ; hwnd -> {mIdx:Int, wsIdx:Int, wsName:Str}
global KLRU_Order := []     ; keeps recency order of hwnds
global KLRU_Cap := 256


; --- Internal logging wrapper (routes to _Log when DebugKomorebi = true)
_KLog(msg) {
    global DebugKomorebi
    if (DebugKomorebi)
        _Log("[komorebi] " . msg)
}

; --- Quote helper for command lines
_KQuote(s) {
    if !IsSet(s)
        return '""'
    if InStr(s, '"')
        return '"' . StrReplace(s, '"', '""') . '"'
    if InStr(s, ' ')
        return '"' . s . '"'
    return s
}

; --- Run a CLI and capture its stdout to a temp file, then read it back
_KRunCaptureToText(cmd, &outText) {
    tmp := A_Temp . "\komorebi_cap_" . A_TickCount . "_" . Random(1000,9999) . ".tmp"
    ; Run via cmd so we can use redirection
    full := 'cmd.exe /c ' . cmd . ' > ' . _KQuote(tmp) . ' 2>&1'
    code := RunTry(full)
    outText := ""
    try {
        if FileExist(tmp)
            outText := FileRead(tmp, "UTF-8")
    }
    try FileDelete(tmp)
    return code
}

_KLRU_Touch(hwnd) {
    global KLRU_Order
    ; remove any existing
    for i, h in KLRU_Order
        if (h = hwnd) {
            KLRU_Order.RemoveAt(i)
            break
        }
    KLRU_Order.InsertAt(1, hwnd)
}

_KLRU_Put(hwnd, mIdx, wsIdx, wsName) {
    global KLRU_Map, KLRU_Order, KLRU_Cap
    KLRU_Map[hwnd] := { mIdx: mIdx, wsIdx: wsIdx, wsName: wsName }
    _KLRU_Touch(hwnd)
    ; evict if needed
    while (KLRU_Order.Length > KLRU_Cap) {
        old := KLRU_Order.RemoveAt(KLRU_Order.Length)
        if (KLRU_Map.Has(old))
            KLRU_Map.Delete(old)
    }
}

_KLRU_Get(hwnd, &mIdx, &wsIdx, &wsName) {
    global KLRU_Map
    if !KLRU_Map.Has(hwnd) {
        mIdx := -1, wsIdx := -1, wsName := ""
        return false
    }
    v := KLRU_Map[hwnd]
    mIdx := v.mIdx, wsIdx := v.wsIdx, wsName := v.wsName
    _KLRU_Touch(hwnd)
    return true
}


Komorebi_IsAvailable() {
    global KomorebicExe
    return (IsSet(KomorebicExe) && KomorebicExe != "" && FileExist(KomorebicExe))
}

; --- For startup sanity checks
Komorebi_DebugPing() {
    global KomorebicExe
    _KLog("DebugPing: starting…")
    _KLog("DebugPing: KomorebicExe='" . KomorebicExe . "'")
    _KLog("IsAvailable=" . (Komorebi_IsAvailable() ? "true" : "false"))

    if Komorebi_IsAvailable() {
        exeQ := _KQuote(KomorebicExe)
        verTxt := ""
        code := _KRunCaptureToText(exeQ . " --version", &verTxt)
        _KLog("DebugPing: '--version' exit=" . code)
        if (StrLen(Trim(verTxt)) > 0)
            _KLog("DebugPing: version='" . Trim(verTxt) . "'")
    }
}

; --- Get the raw JSON state from komorebi
_Komorebi_GetStateText() {
    global KomorebicExe, KState_Text, KState_Stamp, KState_TTL
    if !Komorebi_IsAvailable()
        return ""

    ; TTL reuse
    now := A_TickCount
    if (KState_Text != "" && (now - KState_Stamp) < KState_TTL)
        return KState_Text

    exeQ := _KQuote(KomorebicExe)
    txt := ""
    code := _KRunCaptureToText(exeQ . " state", &txt)
    _KLog("GetState: exit=" . code . " bytes=" . StrLen(txt))

    if (code = 0 && StrLen(txt))
        KState_Text := txt, KState_Stamp := now
    else
        KState_Text := "", KState_Stamp := 0

    return txt
}


; --- Find the workspace *name* that contains a specific hwnd by scanning the JSON text.
;     Strategy: find the first occurrence of `"hwnd": <hwnd>`, then walk backward to the
;     nearest preceding `"name": "<...>"` that also has `"containers"` before the hwnd.
_Komorebi_FindWorkspaceNameByHwnd(stateText, hwnd) {
    if (stateText = "" || !hwnd)
        return ""

    m := 0
    pos := RegExMatch(stateText, '"hwnd"\s*:\s*' . hwnd . '\b', &m, 1)
    if (pos = 0) {
        _KLog("FindWorkspace: hwnd not found in state")
        return ""
    }

    back := SubStr(stateText, 1, pos)
    names := []
    searchPos := 1
    mm := 0
    while (p := RegExMatch(back, '"name"\s*:\s*"([^"]+)"', &mm, searchPos)) {
        names.Push({ pos: p, name: mm[1], len: StrLen(mm[0]) })
        searchPos := p + StrLen(mm[0])
    }
    if (names.Length = 0) {
        _KLog("FindWorkspace: no name entries before hwnd")
        return ""
    }

    i := names.Length
    loop {
        if (i <= 0)
            break
        cand := names[i]
        block := SubStr(stateText, cand.pos, pos - cand.pos)
        if InStr(block, '"containers"') {
            ws := cand.name
            _KLog("FindWorkspace: hwnd=" . hwnd . " => workspace='" . ws . "'")
            return ws
        }
        i -= 1
    }

    _KLog("FindWorkspace: could not resolve workspace name for hwnd=" . hwnd)
    return ""
}

; --- DWMWA_CLOAKED check
_Komorebi_IsCloaked(hwnd) {
    buf := Buffer(4, 0)
    ; DWMWA_CLOAKED = 14
    hr := DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", 14, "ptr", buf.Ptr, "uint", 4, "int")
    if (hr != 0)
        return false
    return (NumGet(buf, 0, "UInt") != 0)
}

_Komorebi_WaitUncloak(hwnd, waitMs := 300) {
    deadline := A_TickCount + Abs(waitMs)
    loop {
        if !_Komorebi_IsCloaked(hwnd)
            return true
        if (A_TickCount >= deadline)
            break
        Sleep 12
    }
    return !_Komorebi_IsCloaked(hwnd)
}

; === NEW ===
; Robustly find (monitorIndex, workspaceIndex) for the workspace containing the given hwnd.
; Also returns the workspace name (wsName). Returns true on success, false otherwise.
_Komorebi_FindMonitorWorkspaceIndexByHwnd(stateText, hwnd, &mIdx, &wsIdx, &wsName) {
    mIdx := -1, wsIdx := -1, wsName := ""
    if (stateText = "" || !hwnd)
        return false

    ; Absolute position of the target hwnd in the full JSON
    mh := 0
    hx := RegExMatch(stateText, '"hwnd"\s*:\s*' . hwnd . '\b', &mh, 1)
    if (hx = 0) {
        _KLog("IdxFinder: hwnd not found in state")
        return false
    }

    ; Find each monitor's *workspaces* object by anchoring on:
    ;   "workspaces": { ... } , "last_focused_workspace"
    ; The capture group 1 is the *content* of the workspaces object.
    patMon := 's)"workspaces"\s*:\s*\{(.*?)\}\s*,\s*"last_focused_workspace"'
    posMon := 1
    mm := 0
    curMon := 0
    wsContent := "", wsContentAbsStart := 0
    foundMon := false

    while (p := RegExMatch(stateText, patMon, &mm, posMon)) {
        ; mm.Pos(0) .. mm.Pos(0)+mm.Len(0)-1 is the entire "workspaces":{...},"last_focused_workspace"
        blockStart := mm.Pos(0)
        blockEnd   := mm.Pos(0) + mm.Len(0) - 1

        if (blockStart <= hx && hx <= blockEnd) {
            wsContent := mm[1]
            wsContentAbsStart := mm.Pos(1)  ; absolute start of the captured content
            mIdx := curMon
            foundMon := true
            break
        }

        posMon := mm.Pos(0) + mm.Len(0)
        curMon += 1
    }

    if !foundMon {
        _KLog("IdxFinder: containing workspaces block not found around hwnd")
        return false
    }

    ; Inside the selected monitor's workspaces content, find the last "name" *before* hx
    ; That "name" corresponds to the workspace owning the hwnd.
    patName := 's)"name"\s*:\s*"([^"]+)"'
    posN := 1
    mn := 0
    idx := 0
    lastIdx := -1
    lastName := ""
    lastAbs := 0

    while (q := RegExMatch(wsContent, patName, &mn, posN)) {
        absPos := wsContentAbsStart + q - 1
        if (absPos < hx) {
            lastIdx := idx
            lastName := mn[1]
            lastAbs := absPos
        } else {
            break
        }
        posN := mn.Pos(0) + mn.Len(0)
        idx += 1
    }

    if (lastIdx < 0) {
        _KLog("IdxFinder: no workspace name found before hwnd inside selected monitor")
        return false
    }

    wsIdx  := lastIdx
    wsName := lastName
    _KLog("IdxFinder: resolved mIdx=" . mIdx . " wsIdx=" . wsIdx . " wsName='" . wsName . "'")
    return true
}


; Run komorebic with args, hidden; return exit code
Kom_RunWait(args) {
    global KomorebicExe
    return RunWait('"' KomorebicExe '" ' . args, , "Hide")
}


; --- Main entry used by helpers.ActivateHwnd for OtherWorkspace
;     1) Read state
;     2) Resolve monitor/workspace index that contains hwnd (and log name)
;     3) komorebic focus-monitor <mIdx>, then focus-workspace <wsIdx>
;     4) Wait for uncloaked; return true/false
Komorebi_FocusHwnd(hwnd) {
    global KomorebicExe
    if !Komorebi_IsAvailable() {
        _KLog("Komorebi_FocusHwnd: komorebic.exe not found or path not set")
        return false
    }

    cloakedStart := _Komorebi_IsCloaked(hwnd)
    _KLog("Komorebi_FocusHwnd: hwnd=" . hwnd . " cloakedStart=" . (cloakedStart ? "true" : "false"))

    ; ---------- FAST PATH: subscription map ----------
    wsFast := ""
    if Komorebi_SubTryMap(hwnd, &wsFast) && (wsFast != "") {
        _KLog("Komorebi_FocusHwnd: submap -> " . wsFast)
        if (Kom_RunWait('focus-named-workspace ' . _KQuote(wsFast)) = 0) {
            Kom_RunWait('focus-window --hwnd ' . hwnd)
            if _Komorebi_WaitUncloak(hwnd, 180) {
                _KLog("Komorebi_FocusHwnd: success (submap)")
                return true
            }
        }
        _KLog("Komorebi_FocusHwnd: submap focus attempt fell through")
    }

    ; ---------- FAST PATH 2: LRU (no state parse) ----------
    mIdx := -1, wsIdx := -1, wsNameLRU := ""
    if _KLRU_Get(hwnd, &mIdx, &wsIdx, &wsNameLRU) {
        if (mIdx >= 0 && wsIdx >= 0) {
            if (Kom_RunWait('focus-monitor ' . mIdx) = 0 && Kom_RunWait('focus-workspace ' . wsIdx) = 0) {
                Kom_RunWait('focus-window --hwnd ' . hwnd)
                if _Komorebi_WaitUncloak(hwnd, 180) {
                    _KLog("Komorebi_FocusHwnd: success (lru idx)")
                    return true
                }
            }
        }
        if (wsNameLRU != "") {
            if (Kom_RunWait('focus-named-workspace ' . _KQuote(wsNameLRU)) = 0) {
                Kom_RunWait('focus-window --hwnd ' . hwnd)
                if _Komorebi_WaitUncloak(hwnd, 180) {
                    _KLog("Komorebi_FocusHwnd: success (lru name)")
                    return true
                }
            }
        }
        _KLog("Komorebi_FocusHwnd: LRU fell through")
    }

    ; ---------- Normal path: read (TTL-cached) state once ----------
    stateTxt := _Komorebi_GetStateText()
    if (stateTxt = "") {
        _KLog("Komorebi_FocusHwnd: state text empty, abort")
        return false
    }

    wsNameLog := _Komorebi_FindWorkspaceNameByHwnd(stateTxt, hwnd)
    if (wsNameLog != "")
        _KLog("Komorebi_FocusHwnd: workspace='" . wsNameLog . "'")

    mIdx := -1, wsIdx := -1, wsName := ""
    if _Komorebi_FindMonitorWorkspaceIndexByHwnd(stateTxt, hwnd, &mIdx, &wsIdx, &wsName) {
        if (Kom_RunWait('focus-monitor ' . mIdx) = 0 && Kom_RunWait('focus-workspace ' . wsIdx) = 0) {
            Kom_RunWait('focus-window --hwnd ' . hwnd)
            if _Komorebi_WaitUncloak(hwnd, 220) {
                _KLog("Komorebi_FocusHwnd: success (index path)")
                _KLRU_Put(hwnd, mIdx, wsIdx, (wsName != "" ? wsName : wsNameLog))
                return true
            } else {
                _KLog("Komorebi_FocusHwnd: cloaked after index path")
            }
        } else {
            _KLog("Komorebi_FocusHwnd: focus-monitor/workspace failed (index path)")
        }
    } else {
        _KLog("Komorebi_FocusHwnd: failed to resolve indexes; trying name fallback")
    }

    ; ----- Fallback: by name ----------
    if (wsNameLog != "") {
        if (Kom_RunWait('focus-named-workspace ' . _KQuote(wsNameLog)) = 0) {
            Kom_RunWait('focus-window --hwnd ' . hwnd)
            if _Komorebi_WaitUncloak(hwnd, 220) {
                _KLog("Komorebi_FocusHwnd: success (fallback)")
                _KLRU_Put(hwnd, -1, -1, wsNameLog)
                return true
            }
        } else {
            _KLog("Komorebi_FocusHwnd: focus-named-workspace failed (fallback)")
        }
    }

    return false
}

; --- Optional: force-refresh Komorebi state cache (used by callers when needed)
Komorebi_InvalidateStateCache() {
    global KState_Text, KState_Stamp
    KState_Text := ""
    KState_Stamp := 0
}


; Return { id: "", name: "<workspace name>" } or "" if unknown.
; Tolerant parser: prefers explicit name keys; falls back to monitor workspaces + last_focused_workspace index.
Komorebi_GetCurrentWorkspace() {
    txt := _Komorebi_GetStateText()
    if (txt = "")
        return ""

    ; 1) Easy win: look for an explicit focused workspace name anywhere
    m := 0
    if RegExMatch(txt, '"focused_workspace_name"\s*:\s*"([^"]+)"', &m) {
        return { id: "", name: m[1] }
    }
    if RegExMatch(txt, '"current_workspace_name"\s*:\s*"([^"]+)"', &m) {
        return { id: "", name: m[1] }
    }

    ; 2) Walk monitor blocks that expose: "workspaces": { ... }, "last_focused_workspace": <idx|name>
    ; Group 1 = workspaces content, group 2 = name if present, group 3 = index if present
    patMon := 's)"workspaces"\s*:\s*\{(.*?)\}\s*,\s*"(?:last_focused_workspace_name|last_focused_workspace)"\s*:\s*(?:"([^"]+)"|(\d+))'
    pos := 1, mm := 0
    while (p := RegExMatch(txt, patMon, &mm, pos)) {
        wsContent := mm[1]
        if (mm[2] != "") {
            return { id: "", name: mm[2] }
        }
        if (mm[3] != "") {
            idx := Integer(mm[3])
            ; iterate names within this workspaces object
            patName := 's)"name"\s*:\s*"([^"]+)"'
            posN := 1, mn := 0, i := 0
            while (q := RegExMatch(wsContent, patName, &mn, posN)) {
                if (i = idx)
                    return { id: "", name: mn[1] }
                posN := mn.Pos(0) + mn.Len(0)
                i += 1
            }
        }
        pos := mm.Pos(0) + mm.Len(0)
    }

    ; 3) Last resort: any plausible top-level current/last name signal
    if RegExMatch(txt, '"last_focused_workspace_name"\s*:\s*"([^"]+)"', &m)
        return { id: "", name: m[1] }

    return ""
}




; Return UInt hwnd of focused window per komorebi state, or 0 if unavailable.
; Tries multiple tolerant patterns.
Komorebi_GetFocusedHwnd() {
    txt := _Komorebi_GetStateText()
    if (txt = "")
        return 0

    m := 0
    ; Common shapes we might see:
    if RegExMatch(txt, '"focused_window"\s*:\s*\{[^}]*"hwnd"\s*:\s*(\d+)', &m)
        return Integer(m[1])
    if RegExMatch(txt, '"focused_hwnd"\s*:\s*(\d+)', &m)
        return Integer(m[1])
    if RegExMatch(txt, '"last_focused_window"\s*:\s*\{[^}]*"hwnd"\s*:\s*(\d+)', &m)
        return Integer(m[1])

    return 0
}

; Return [{ hwnd, wsName }, ...] using a single pass over state text.
; We scan each monitor's "workspaces" block; for each workspace's "name", we collect "hwnd" values until the next workspace.
Komorebi_MapAllWindows() {
    txt := _Komorebi_GetStateText()
    if (txt = "")
        return ""

    patMon := 's)"workspaces"\s*:\s*\{(.*?)\}\s*,\s*"(?:last_focused_workspace|last_focused_workspace_name)"'
    pos := 1, mm := 0
    out := []
    seen := Map()

    while (p := RegExMatch(txt, patMon, &mm, pos)) {
        wsContent := mm[1]
        ; iterate workspace names with positions
        patName := 's)"name"\s*:\s*"([^"]+)"'
        posN := 1, mn := 0
        names := []  ; [{name, startRel, endRel}]
        while (q := RegExMatch(wsContent, patName, &mn, posN)) {
            names.Push({ name: mn[1], startRel: mn.Pos(0), endRel: mn.Pos(0) + mn.Len(0) - 1 })
            posN := mn.Pos(0) + mn.Len(0)
        }
        if (names.Length = 0) {
            pos := mm.Pos(0) + mm.Len(0)
            continue
        }
        totalLen := StrLen(wsContent)
        ; for each workspace segment, collect hwnds
        i := 1
        while (i <= names.Length) {
            segStart := names[i].startRel
            segEnd   := (i < names.Length) ? (names[i+1].startRel - 1) : totalLen
            segment  := SubStr(wsContent, segStart, segEnd - segStart + 1)
            ; collect hwnds within this workspace segment
            ph := 0, posH := 1, mh := 0
            while (r := RegExMatch(segment, '"hwnd"\s*:\s*(\d+)', &mh, posH)) {
                hw := Integer(mh[1])
                if (hw > 0 && !seen.Has(hw)) {
                    out.Push({ hwnd: hw, wsName: names[i].name })
                    seen[hw] := true
                }
                posH := mh.Pos(0) + mh.Len(0)
            }
            i += 1
        }
        pos := mm.Pos(0) + mm.Len(0)
    }

    return out
}


; Return [hwnd, ...] for the currently focused workspace, or "" if unknown.
; Uses current workspace name + same segmentation approach as MapAllWindows().
Komorebi_ListCurrentWorkspaceHwnds() {
    cur := Komorebi_GetCurrentWorkspace()
    if (!IsObject(cur) || cur.name = "")
        return ""

    txt := _Komorebi_GetStateText()
    if (txt = "")
        return ""

    patMon := 's)"workspaces"\s*:\s*\{(.*?)\}\s*,\s*"(?:last_focused_workspace|last_focused_workspace_name)"'
    pos := 1, mm := 0

    while (p := RegExMatch(txt, patMon, &mm, pos)) {
        wsContent := mm[1]
        ; enumerate workspace names w/ positions
        patName := 's)"name"\s*:\s*"([^"]+)"'
        posN := 1, mn := 0
        names := []
        while (q := RegExMatch(wsContent, patName, &mn, posN)) {
            names.Push({ name: mn[1], startRel: mn.Pos(0), endRel: mn.Pos(0) + mn.Len(0) - 1 })
            posN := mn.Pos(0) + mn.Len(0)
        }
        if (names.Length = 0) {
            pos := mm.Pos(0) + mm.Len(0)
            continue
        }
        totalLen := StrLen(wsContent)

        ; find the segment matching the current workspace name
        i := 1
        while (i <= names.Length) {
            if (names[i].name != cur.name) {
                i += 1
                continue
            }
            segStart := names[i].startRel
            segEnd   := (i < names.Length) ? (names[i+1].startRel - 1) : totalLen
            segment  := SubStr(wsContent, segStart, segEnd - segStart + 1)
            ; collect hwnds
            hwnds := []
            posH := 1, mh := 0
            while (r := RegExMatch(segment, '"hwnd"\s*:\s*(\d+)', &mh, posH)) {
                hw := Integer(mh[1])
                if (hw > 0)
                    hwnds.Push(hw)
                posH := mh.Pos(0) + mh.Len(0)
            }
            return hwnds
        }
        pos := mm.Pos(0) + mm.Len(0)
    }
    return ""
}

