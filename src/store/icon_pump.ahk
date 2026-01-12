#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Expected: file is included after windowstore.ahk

; ============================================================
; Icon Pump - Resolves window icons asynchronously
; ============================================================
; Strategy:
;   1) Try WM_GETICON / class icon (CopyIcon before storing)
;   2) Fallback to process EXE icon, cached per EXE
;   3) Bounded retries with exponential backoff
; ============================================================

; Configuration
global IconBatchPerTick := 16
global IconTimerIntervalMs := 80
global IconMaxAttempts := 4
global IconSkipHidden := true           ; Skip cloaked/minimized windows
global IconIdleBackoffMs := 1500        ; Cooldown when skipping hidden
global IconAttemptBackoffMs := 300      ; Base backoff after failed try
global IconAttemptBackoffMultiplier := 1.8
global IconGiveUpBackoffMs := 5000      ; Long cooldown after max attempts

; State
global _IP_TimerOn := false
global _IP_Attempts := Map()            ; hwnd -> attempt count

; Start the icon pump timer
IconPump_Start() {
    global _IP_TimerOn, IconTimerIntervalMs
    if (_IP_TimerOn)
        return
    _IP_TimerOn := true
    SetTimer(_IP_Tick, IconTimerIntervalMs)
}

; Stop the icon pump timer
IconPump_Stop() {
    global _IP_TimerOn
    if (!_IP_TimerOn)
        return
    _IP_TimerOn := false
    SetTimer(_IP_Tick, 0)
}

; Main pump tick
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

        ; Window may have vanished
        if (!WinExist("ahk_id " hwnd))
            continue

        ; Already has icon
        if (rec.iconHicon)
            continue

        ; Skip hidden windows (unlikely to yield icon)
        if (IconSkipHidden) {
            if (rec.state = "OtherWorkspace" || rec.isMinimized || !rec.isVisible) {
                _IP_SetCooldown(hwnd, IconIdleBackoffMs)
                continue
            }
        }

        ; Try window-level icon
        h := _IP_TryResolveFromWindow(hwnd)

        ; Fallback: process EXE icon
        if (!h) {
            exe := rec.exePath
            if (exe = "" && rec.pid > 0)
                exe := _IP_GetProcessPath(rec.pid)
            if (exe != "") {
                hCopy := WindowStore_GetExeIconCopy(exe)
                if (!hCopy) {
                    master := _IP_ExtractExeIcon(exe)
                    if (master) {
                        WindowStore_ExeIconCachePut(exe, master)
                        hCopy := DllCall("user32\CopyIcon", "ptr", master, "ptr")
                    }
                }
                h := hCopy
            }
        }

        if (h) {
            ; Success
            WindowStore_UpdateFields(hwnd, { iconHicon: h, iconCooldownUntilTick: 0 }, "icons")
            _IP_Attempts[hwnd] := 0
            continue
        }

        ; Failure: bounded retries
        tries := _IP_Attempts.Has(hwnd) ? (_IP_Attempts[hwnd] + 1) : 1
        _IP_Attempts[hwnd] := tries

        if (tries < IconMaxAttempts) {
            step := IconAttemptBackoffMs
            if (IconAttemptBackoffMultiplier > 1)
                step := Floor(IconAttemptBackoffMs * (IconAttemptBackoffMultiplier ** (tries - 1)))
            _IP_SetCooldown(hwnd, step)
        } else {
            _IP_SetCooldown(hwnd, IconGiveUpBackoffMs)
        }
    }
}

; Try to get icon from window via WM_GETICON or class icon
_IP_TryResolveFromWindow(hWnd) {
    WM_GETICON := 0x7F
    ICON_SMALL2 := 2
    ICON_SMALL := 0
    ICON_BIG := 1
    GCLP_HICONSM := -34
    GCLP_HICON := -14

    try {
        h := SendMessage(WM_GETICON, ICON_SMALL2, 0, , "ahk_id " hWnd)
        if (!h)
            h := SendMessage(WM_GETICON, ICON_SMALL, 0, , "ahk_id " hWnd)
        if (!h)
            h := SendMessage(WM_GETICON, ICON_BIG, 0, , "ahk_id " hWnd)
        if (!h)
            h := DllCall("user32\GetClassLongPtrW", "ptr", hWnd, "int", GCLP_HICONSM, "ptr")
        if (!h)
            h := DllCall("user32\GetClassLongPtrW", "ptr", hWnd, "int", GCLP_HICON, "ptr")
        if (h)
            return DllCall("user32\CopyIcon", "ptr", h, "ptr")
    } catch {
    }
    return 0
}

; Get process exe path from pid
_IP_GetProcessPath(pid) {
    hProc := DllCall("kernel32\OpenProcess", "uint", 0x1000, "int", 0, "uint", pid, "ptr")
    if (!hProc)
        return ""
    buf := Buffer(32767 * 2, 0)
    cch := 32767
    ok := DllCall("kernel32\QueryFullProcessImageNameW", "ptr", hProc, "uint", 0, "ptr", buf.Ptr, "uint*", &cch, "int")
    DllCall("kernel32\CloseHandle", "ptr", hProc)
    return ok ? StrGet(buf.Ptr, "UTF-16") : ""
}

; Extract icon from exe file
_IP_ExtractExeIcon(exePath) {
    hSmall := 0
    hLarge := 0
    try {
        DllCall("shell32\ExtractIconExW", "wstr", exePath, "int", 0, "ptr*", &hLarge, "ptr*", &hSmall, "uint", 1, "uint")
        if (hSmall) {
            if (hLarge)
                try DllCall("user32\DestroyIcon", "ptr", hLarge)
            return hSmall
        }
        if (hLarge)
            return hLarge
    } catch {
    }
    ; Last resort: explorer.exe
    try {
        win := A_WinDir "\explorer.exe"
        DllCall("shell32\ExtractIconExW", "wstr", win, "int", 0, "ptr*", &hLarge, "ptr*", &hSmall, "uint", 1, "uint")
        if (hSmall) {
            if (hLarge)
                try DllCall("user32\DestroyIcon", "ptr", hLarge)
            return hSmall
        }
        if (hLarge)
            return hLarge
    } catch {
    }
    return 0
}

; Set cooldown on a window
_IP_SetCooldown(hwnd, ms) {
    next := A_TickCount + (ms + 0)
    WindowStore_UpdateFields(hwnd, { iconCooldownUntilTick: next }, "icons")
}
