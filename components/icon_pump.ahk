#Requires AutoHotkey v2.0
; =============================================================================
; icon_pump.ahk — resolves per-window icons (HICON) and updates WindowStore
; Strategy:
;   1) Try WM_GETICON / class icon (CopyIcon before storing).
;   2) Fallback to process EXE icon, cached per EXE (store master in WS cache,
;      CopyIcon per row).
;   3) Light re-try with attempt cap to avoid tight loops.
; =============================================================================

; ---------- Tunables ----------------------------------------------------------
if !IsSet(IconBatchPerTick)
    IconBatchPerTick := 16
if !IsSet(IconTimerIntervalMs)
    IconTimerIntervalMs := 80
if !IsSet(IconMaxAttempts)
    IconMaxAttempts := 4

; Skip attempts for obviously non-productive states
if !IsSet(IconSkipHidden)              ; skip when OtherWorkspace/minimized/invisible
    IconSkipHidden := true
if !IsSet(IconIdleBackoffMs)           ; cooldown set when we skip due to state
    IconIdleBackoffMs := 1500

; Backoff after failed attempts (no auto-requeue; we rely on future “tickles”)
if !IsSet(IconAttemptBackoffMs)        ; base backoff after a failed try
    IconAttemptBackoffMs := 300
if !IsSet(IconAttemptBackoffMultiplier) ; optional exponential growth
    IconAttemptBackoffMultiplier := 1.8
if !IsSet(IconGiveUpBackoffMs)         ; after hitting max attempts, set a longer cooldown
    IconGiveUpBackoffMs := 5000


; ---------- Module state ------------------------------------------------------
global _IP_TimerOn      := false
global _IP_Attempts     := Map()  ; hwnd -> attempts

; ---------- Public API --------------------------------------------------------
IconPump_Start() {
    global _IP_TimerOn, IconTimerIntervalMs
    if (_IP_TimerOn)
        return
    _IP_TimerOn := true
    SetTimer(_IP_Tick, IconTimerIntervalMs)
}

IconPump_Stop() {
    global _IP_TimerOn
    if !_IP_TimerOn
        return
    _IP_TimerOn := false
    SetTimer(_IP_Tick, 0)
}

; ---------- Core --------------------------------------------------------------
_IP_Tick() {
    global IconBatchPerTick, _IP_Attempts
    global IconMaxAttempts, IconSkipHidden, IconIdleBackoffMs
    global IconAttemptBackoffMs, IconAttemptBackoffMultiplier, IconGiveUpBackoffMs

    hwnds := WindowStore_PopIconBatch(IconBatchPerTick)
    if (!IsObject(hwnds) || hwnds.Length = 0)
        return

    for _, hwnd in hwnds {
        hwnd := hwnd + 0
        rec := WindowStore_GetByHwnd(hwnd)
        if (!rec)
            continue
        ; Process may have vanished
        if (!WinExist("ahk_id " hwnd))
            continue
        ; Already has icon
        if (rec.iconHicon)
            continue

        ; Skip states that are unlikely to yield an icon right now
        if (IconSkipHidden) {
            if (rec.state = "OtherWorkspace" || rec.isMinimized || !rec.isVisible) {
                _IP_SetCooldown(hwnd, IconIdleBackoffMs)
                continue
            }
        }

        ; Try to resolve from the window first
        h := _IP_TryResolveFromWindow(hwnd)

        ; Fallback via process EXE icon (cached master per exe)
        if (!h) {
            exe := rec.exePath
            if (exe = "" && rec.pid > 0)
                exe := _IP_GetProcessPath(rec.pid)
            if (exe != "") {
                hCopy := WindowStore_GetExeIconCopy(exe)
                if (!hCopy) {
                    master := _IP_ExtractExeIcon(exe)
                    if (master) {
                        WindowStore_ExeIconCachePut(exe, master)  ; store owns master
                        hCopy := DllCall("user32\CopyIcon", "ptr", master, "ptr")
                    }
                }
                h := hCopy
            }
        }

        if (h) {
            ; Success: set icon and clear cooldown
            WindowStore_UpdateFields(hwnd, { iconHicon: h, iconCooldownUntilTick: 0 }, "icons")
            _IP_Attempts[hwnd] := 0
            continue
        }

        ; Failure: bounded retries across future tickles (no immediate requeue loop)
        tries := _IP_Attempts.Has(hwnd) ? (_IP_Attempts[hwnd] + 1) : 1
        _IP_Attempts[hwnd] := tries

        if (tries < IconMaxAttempts) {
            ; Set a backoff; we won't requeue now. A later “tickle” will re-enqueue
            ; when cooldown expires, thanks to _WS_RefreshNeeds().
            step := IconAttemptBackoffMs
            if (IconAttemptBackoffMultiplier > 1) {
                ; simple exponential backoff
                step := Floor(IconAttemptBackoffMs * (IconAttemptBackoffMultiplier ** (tries - 1)))
            }
            _IP_SetCooldown(hwnd, step)
        } else {
            ; We’re done for now; set a longer cooldown. Future activation/workspace
            ; changes will “tickle” and allow another attempt later.
            _IP_SetCooldown(hwnd, IconGiveUpBackoffMs)
        }
    }
}


; ---------- Icon resolution helpers ------------------------------------------
_IP_TryResolveFromWindow(hWnd) {
    ; Attempts WM_GETICON (SMALL2, SMALL, BIG), then class icons.
    WM_GETICON   := 0x7F
    ICON_SMALL2  := 2
    ICON_SMALL   := 0
    ICON_BIG     := 1
    GCLP_HICONSM := -34
    GCLP_HICON   := -14

    try {
        h := SendMessage(WM_GETICON, ICON_SMALL2, 0, , "ahk_id " hWnd)
        if (!h)
            h := SendMessage(WM_GETICON, ICON_SMALL, 0, , "ahk_id " hWnd)
        if (!h)
            h := SendMessage(WM_GETICON, ICON_BIG,   0, , "ahk_id " hWnd)
        if (!h)
            h := DllCall("user32\GetClassLongPtrW", "ptr", hWnd, "int", GCLP_HICONSM, "ptr")
        if (!h)
            h := DllCall("user32\GetClassLongPtrW", "ptr", hWnd, "int", GCLP_HICON,   "ptr")
        if (h) {
            return DllCall("user32\CopyIcon", "ptr", h, "ptr")  ; copy → store owns it
        }
    } catch {
    }
    return 0
}

_IP_GetProcessPath(pid) {
    ; PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    hProc := DllCall("kernel32\OpenProcess", "uint", 0x1000, "int", 0, "uint", pid, "ptr")
    if (!hProc)
        return ""
    buf := Buffer(32767*2, 0), cch := 32767
    ok := DllCall("kernel32\QueryFullProcessImageNameW", "ptr", hProc, "uint", 0, "ptr", buf.Ptr, "uint*", &cch, "int")
    DllCall("kernel32\CloseHandle", "ptr", hProc)
    return ok ? StrGet(buf.Ptr, "UTF-16") : ""
}

_IP_ExtractExeIcon(exePath) {
    ; Extract a single icon (prefer small), return HICON master (pump owns; cache owns after put).
    hSmall := 0, hLarge := 0
    try {
        got := DllCall("shell32\ExtractIconExW", "wstr", exePath, "int", 0, "ptr*", &hLarge, "ptr*", &hSmall, "uint", 1, "uint")
        if (hSmall) {
            if (hLarge) {
                try DllCall("user32\DestroyIcon", "ptr", hLarge)
            }
            return hSmall
        }
        if (hLarge) {
            return hLarge
        }
    } catch {
    }
    ; Try explorer.exe as last resort (usually present)
    try {
        win := A_WinDir . "\explorer.exe"
        got := DllCall("shell32\ExtractIconExW", "wstr", win, "int", 0, "ptr*", &hLarge, "ptr*", &hSmall, "uint", 1, "uint")
        if (hSmall) {
            if (hLarge) {
                try DllCall("user32\DestroyIcon", "ptr", hLarge)
            }
            return hSmall
        }
        if (hLarge) {
            return hLarge
        }
    } catch {
    }
    return 0
}

_IP_SetCooldown(hwnd, ms) {
    next := A_TickCount + (ms + 0)
    WindowStore_UpdateFields(hwnd, { iconCooldownUntilTick: next }, "icons")
}
