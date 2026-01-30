#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Expected: file is included after windowstore.ahk

; ============================================================
; Icon Pump - Resolves window icons asynchronously
; ============================================================
; Strategy:
;   1) Try WM_GETICON / class icon (CopyIcon before storing)
;   2) Fallback to process EXE icon, cached per EXE
;   3) Bounded retries with exponential backoff
;
; Cross-process HICON note:
;   HICON handles are USER objects stored in win32k.sys shared
;   kernel memory, not process-local. The numeric handle value
;   can be passed to GUI via IPC and used directly - both processes
;   index into the same kernel handle table. Store owns the icons
;   (via CopyIcon); they remain valid while Store runs.
; ============================================================

; NOTE: GiveUp backoff now in config: cfg.IconPumpGiveUpBackoffMs (default 5000)
global IP_LOG_TITLE_MAX_LEN := 40       ; Max title length for logging

; Configuration (set in IconPump_Start after ConfigLoader_Init)
global IconBatchPerTick := 0
global IconTimerIntervalMs := 0
global IconMaxAttempts := 0
global IconAttemptBackoffMs := 0
global IconAttemptBackoffMultiplier := 0
global IconGiveUpBackoffMs := 5000  ; Default, overridden from cfg in IconPump_Start()

; Diagnostic logging
global _IP_DiagEnabled := false
global _IP_LogPath := ""

; State
global _IP_TimerOn := false
global _IP_Attempts := Map()            ; hwnd -> attempt count
global _IP_IdleTicks := 0               ; Counter for consecutive empty ticks
global _IP_IdleThreshold := 5           ; Default, overridden from config in IconPump_Init()

; Start the icon pump timer
IconPump_Start() {
    global _IP_TimerOn, IconTimerIntervalMs, cfg
    global IconBatchPerTick, IconMaxAttempts
    global IconAttemptBackoffMs, IconAttemptBackoffMultiplier, IconGiveUpBackoffMs
    global _IP_DiagEnabled, _IP_LogPath

    ; Load config values on first start (ConfigLoader_Init has already run)
    if (IconTimerIntervalMs = 0) {
        global _IP_IdleThreshold
        IconBatchPerTick := cfg.IconPumpBatchSize
        IconTimerIntervalMs := cfg.IconPumpIntervalMs
        IconMaxAttempts := cfg.IconPumpMaxAttempts
        IconAttemptBackoffMs := cfg.IconPumpAttemptBackoffMs
        IconAttemptBackoffMultiplier := cfg.IconPumpBackoffMultiplier
        IconGiveUpBackoffMs := cfg.IconPumpGiveUpBackoffMs
        _IP_IdleThreshold := cfg.HasOwnProp("IconPumpIdleThreshold") ? cfg.IconPumpIdleThreshold : 5

        ; Initialize diagnostic logging
        _IP_DiagEnabled := cfg.HasOwnProp("DiagIconPumpLog") ? cfg.DiagIconPumpLog : false
        if (_IP_DiagEnabled) {
            global LOG_PATH_ICONPUMP
            _IP_LogPath := LOG_PATH_ICONPUMP
            LogInitSession(_IP_LogPath, "Alt-Tabby Icon Pump Log")
            _IP_Log("Config: BatchSize=" IconBatchPerTick " IntervalMs=" IconTimerIntervalMs " MaxAttempts=" IconMaxAttempts)
        }
    }

    if (_IP_TimerOn)
        return
    _IP_TimerOn := true
    SetTimer(_IP_Tick, IconTimerIntervalMs)
}

; Diagnostic logging helper
_IP_Log(msg) {
    global _IP_DiagEnabled, _IP_LogPath
    if (!_IP_DiagEnabled || _IP_LogPath = "")
        return
    try {
        timestamp := FormatTime(, "yyyy-MM-dd HH:mm:ss")
        FileAppend(timestamp " " msg "`n", _IP_LogPath, "UTF-8")
    }
}

; Stop the icon pump timer
IconPump_Stop() {
    global _IP_TimerOn
    if (!_IP_TimerOn)
        return
    _IP_TimerOn := false
    SetTimer(_IP_Tick, 0)
}

; Ensure the icon pump timer is running (wake from idle pause)
; Call this when new work is enqueued to the icon queue
IconPump_EnsureRunning() {
    global _IP_TimerOn, _IP_IdleTicks, IconTimerIntervalMs
    Pump_EnsureRunning(&_IP_TimerOn, &_IP_IdleTicks, IconTimerIntervalMs, _IP_Tick)
}

; Clean up tracking state AND destroy HICON when windows are removed
; IMPORTANT: Must be called BEFORE gWS_Store.Delete(hwnd) so we can access the record
; RACE FIX: Add Critical to prevent _IP_Tick from processing same hwnd concurrently
IconPump_CleanupWindow(hwnd) {
    Critical "On"
    global _IP_Attempts

    ; Destroy the HICON first (before record is deleted from store)
    rec := WindowStore_GetByHwnd(hwnd)
    if (rec && rec.HasOwnProp("iconHicon") && rec.iconHicon) {
        try DllCall("user32\DestroyIcon", "ptr", rec.iconHicon)
        rec.iconHicon := 0  ; Defensive: prevent use-after-free
    }

    ; Clean up attempt tracking
    if (_IP_Attempts.Has(hwnd))
        _IP_Attempts.Delete(hwnd)
    Critical "Off"
}

; Main pump tick
; Uses Critical sections around per-window processing to prevent TOCTOU races
_IP_Tick() {
    global IconBatchPerTick, _IP_Attempts, _IP_IdleTicks, _IP_IdleThreshold, _IP_TimerOn
    global IconMaxAttempts, IconAttemptBackoffMs, IconAttemptBackoffMultiplier, IconGiveUpBackoffMs
    global IP_LOG_TITLE_MAX_LEN

    hwnds := WindowStore_PopIconBatch(IconBatchPerTick)
    if (!IsObject(hwnds) || hwnds.Length = 0) {
        ; Idle detection: pause timer after threshold empty ticks to reduce CPU churn
        Pump_HandleIdle(&_IP_IdleTicks, _IP_IdleThreshold, &_IP_TimerOn, _IP_Tick, _IP_Log)
        return
    }
    _IP_IdleTicks := 0  ; Reset idle counter when we have work

    now := A_TickCount

    for _, hwnd in hwnds {
        ; Wrap per-window processing in Critical to prevent race conditions
        ; between checking window state and updating it
        Critical "On"

        hwnd := hwnd + 0
        rec := WindowStore_GetByHwnd(hwnd)
        if (!rec) {
            _IP_Log("SKIP hwnd=" hwnd " (not in store)")
            Critical "Off"
            continue
        }

        title := rec.HasOwnProp("title") ? rec.title : ""
        title := SubStr(title, 1, IP_LOG_TITLE_MAX_LEN)  ; Truncate for logging

        ; Window may have vanished - use IsWindow API, not WinExist
        ; WinExist doesn't see cloaked windows (other workspaces), but IsWindow does
        if (!DllCall("user32\IsWindow", "ptr", hwnd, "int")) {
            _IP_Log("SKIP hwnd=" hwnd " '" title "' (window gone)")
            Critical "Off"
            continue
        }

        isHidden := rec.isCloaked || rec.isMinimized || !rec.isVisible
        hasIcon := rec.iconHicon != 0
        currentMethod := rec.HasOwnProp("iconMethod") ? rec.iconMethod : ""

        ; Determine processing mode:
        ; 1. NO_ICON: No icon yet - try all methods
        ; 2. UPGRADE: Has fallback icon, window visible - try WM_GETICON to upgrade
        ; 3. REFRESH: Has WM_GETICON icon - try WM_GETICON to check for changes
        mode := ""
        if (!hasIcon) {
            mode := "NO_ICON"
        } else if (currentMethod != "wm_geticon" && !isHidden) {
            mode := "UPGRADE"
        } else if (currentMethod = "wm_geticon") {
            mode := "REFRESH"
        } else {
            ; Has fallback icon but still hidden - nothing to do
            _IP_Log("SKIP hwnd=" hwnd " '" title "' (has fallback, still hidden)")
            Critical "Off"
            continue
        }

        ; Log what we're doing
        if (mode = "NO_ICON") {
            if (isHidden) {
                _IP_Log("PROC hwnd=" hwnd " '" title "' mode=NO_ICON (hidden) - try UWP/EXE")
            } else {
                _IP_Log("PROC hwnd=" hwnd " '" title "' mode=NO_ICON - trying all methods")
            }
        } else if (mode = "UPGRADE") {
            _IP_Log("PROC hwnd=" hwnd " '" title "' mode=UPGRADE (had " currentMethod ") - try WM_GETICON")
        } else if (mode = "REFRESH") {
            _IP_Log("PROC hwnd=" hwnd " '" title "' mode=REFRESH - checking for icon change")
        }

        ; Try to get icon based on mode
        h := 0
        method := ""

        if (mode = "UPGRADE" || mode = "REFRESH") {
            ; Only try WM_GETICON for upgrade/refresh (window must be visible)
            h := _IP_TryResolveFromWindow(hwnd)
            if (h) {
                method := "wm_geticon"
            }
        } else {
            ; NO_ICON mode - try all methods

            ; Try WM_GETICON first (only if visible)
            if (!isHidden) {
                h := _IP_TryResolveFromWindow(hwnd)
                if (h) {
                    method := "wm_geticon"
                }
            }

            ; Try UWP package icon
            if (!h) {
                h := _IP_TryResolveFromUWP(hwnd, rec.pid)
                if (h) {
                    method := "uwp"
                }
            }

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
                    if (h) {
                        method := "exe"
                    }
                }
            }
        }

        ; Handle result based on mode
        if (h) {
            ; Success - got a new icon
            if (mode = "UPGRADE" || mode = "REFRESH") {
                ; Destroy old icon before replacing
                if (rec.iconHicon)
                    try DllCall("user32\DestroyIcon", "ptr", rec.iconHicon)
            }
            WindowStore_UpdateFields(hwnd, {
                iconHicon: h,
                iconCooldownUntilTick: 0,
                iconMethod: method,
                iconLastRefreshTick: now,
                iconGaveUp: false
            }, "icons")
            _IP_Attempts[hwnd] := 0
            _IP_Log("SUCCESS hwnd=" hwnd " '" title "' mode=" mode " method=" method)
            Critical "Off"
            continue
        }

        ; Failed to get icon
        if (mode = "UPGRADE" || mode = "REFRESH") {
            ; For upgrade/refresh, failure is OK - we keep existing icon
            ; Just update the refresh timestamp so we don't spam retries
            WindowStore_UpdateFields(hwnd, { iconLastRefreshTick: now }, "icons")
            _IP_Log("KEPT hwnd=" hwnd " '" title "' mode=" mode " (WM_GETICON failed, keeping existing)")
            Critical "Off"
            continue
        }

        ; NO_ICON mode failure: bounded retries
        tries := _IP_Attempts.Has(hwnd) ? (_IP_Attempts[hwnd] + 1) : 1
        _IP_Attempts[hwnd] := tries
        _IP_Log("FAIL hwnd=" hwnd " '" title "' attempt=" tries "/" IconMaxAttempts)

        if (tries < IconMaxAttempts) {
            step := IconAttemptBackoffMs
            if (IconAttemptBackoffMultiplier > 1)
                step := Floor(IconAttemptBackoffMs * (IconAttemptBackoffMultiplier ** (tries - 1)))
            _IP_SetCooldown(hwnd, step)
        } else {
            ; Max attempts reached - mark as gave up so we don't retry forever
            WindowStore_UpdateFields(hwnd, { iconGaveUp: true }, "icons")
            _IP_Attempts.Delete(hwnd)  ; Clean up attempts tracking
            _IP_Log("GAVE UP hwnd=" hwnd " '" title "' after " IconMaxAttempts " attempts")
        }

        Critical "Off"
    }
}

; Try to get icon from window via WM_GETICON or class icon
; Prefer larger icons (ICON_BIG=32x32) over small (16x16) since we display at 36px+
; Uses SendMessageTimeoutW with SMTO_ABORTIFHUNG to avoid blocking on hung windows.
_IP_TryResolveFromWindow(hWnd) {
    WM_GETICON := 0x7F
    ICON_SMALL2 := 2
    ICON_SMALL := 0
    ICON_BIG := 1
    GCLP_HICONSM := -34
    GCLP_HICON := -14
    SMTO_ABORTIFHUNG := 0x0002
    TIMEOUT_MS := 500

    try {
        ; Skip hung windows entirely - fast kernel check, no messages sent
        if (DllCall("user32\IsHungAppWindow", "ptr", hWnd, "int"))
            return 0

        ; Use SendMessageTimeoutW instead of SendMessage to avoid blocking
        ; on windows that become hung between the IsHungAppWindow check and the send.
        ; SMTO_ABORTIFHUNG returns immediately if target thread is not responding.
        h := 0
        result := 0

        ; Prefer large icons first for better quality at display size
        result := DllCall("user32\SendMessageTimeoutW", "ptr", hWnd, "uint", WM_GETICON, "uptr", ICON_BIG, "ptr", 0, "uint", SMTO_ABORTIFHUNG, "uint", TIMEOUT_MS, "uptr*", &h, "int")
        if (!result || !h) {
            h := 0
            result := DllCall("user32\SendMessageTimeoutW", "ptr", hWnd, "uint", WM_GETICON, "uptr", ICON_SMALL2, "ptr", 0, "uint", SMTO_ABORTIFHUNG, "uint", TIMEOUT_MS, "uptr*", &h, "int")
        }
        if (!result || !h) {
            h := 0
            result := DllCall("user32\SendMessageTimeoutW", "ptr", hWnd, "uint", WM_GETICON, "uptr", ICON_SMALL, "ptr", 0, "uint", SMTO_ABORTIFHUNG, "uint", TIMEOUT_MS, "uptr*", &h, "int")
        }
        if (!h)
            h := DllCall("user32\GetClassLongPtrW", "ptr", hWnd, "int", GCLP_HICON, "ptr")
        if (!h)
            h := DllCall("user32\GetClassLongPtrW", "ptr", hWnd, "int", GCLP_HICONSM, "ptr")
        if (h)
            return DllCall("user32\CopyIcon", "ptr", h, "ptr")
    } catch as e {
        _IP_Log("WARN: _IP_TryResolveFromWindow failed for hwnd=" hWnd " err=" e.Message)
    }
    return 0
}

; Get process exe path from pid (uses shared utility)
_IP_GetProcessPath(pid) {
    return ProcessUtils_GetPath(pid)
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
    } catch as e {
        _IP_Log("WARN: ExtractIconExW failed for path=" exePath " err=" e.Message)
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
    } catch as e {
        _IP_Log("WARN: ExtractIconExW fallback (explorer.exe) failed err=" e.Message)
    }
    return 0
}

; Set cooldown on a window
_IP_SetCooldown(hwnd, ms) {
    next := A_TickCount + (ms + 0)
    WindowStore_UpdateFields(hwnd, { iconCooldownUntilTick: next }, "icons")
}

; ============================================================
; UWP Icon Support
; ============================================================
; UWP apps don't have traditional EXE icons - their icons are PNG files
; in the app package folder, referenced via AppxManifest.xml.

; Check if a process is a UWP/packaged app (has a package identity)
_IP_AppHasPackage(pid) {
    global PROCESS_QUERY_LIMITED_INFORMATION
    if (!pid || pid <= 0)
        return false

    ; Open process with PROCESS_QUERY_LIMITED_INFORMATION (0x1000)
    hProc := DllCall("kernel32\OpenProcess", "uint", PROCESS_QUERY_LIMITED_INFORMATION, "int", 0, "uint", pid, "ptr")
    if (!hProc)
        return false

    ; Try GetPackageId - returns 0 if app has no package identity
    ; Buffer for PACKAGE_ID structure (variable size, use 1024 bytes)
    bufLen := 1024
    buf := Buffer(bufLen, 0)

    ; GetPackageId returns ERROR_SUCCESS (0) if app has package
    ; ERROR_INSUFFICIENT_BUFFER (122) also means it has a package (just needs bigger buffer)
    result := DllCall("kernel32\GetPackageId", "ptr", hProc, "uint*", &bufLen, "ptr", buf.Ptr, "int")
    DllCall("kernel32\CloseHandle", "ptr", hProc)

    ; SUCCESS or INSUFFICIENT_BUFFER means it's a UWP app
    return (result = 0 || result = 122)
}

; Get the UWP app's logo path from the package
_IP_GetUWPLogoPath(hwnd) {
    ; Get PID from hwnd
    pid := 0
    try {
        pid := WinGetPID("ahk_id " hwnd)
    }
    if (!pid)
        return ""

    ; Get package path
    packagePath := _IP_GetPackagePath(pid)
    if (packagePath = "")
        return ""

    ; Read AppxManifest.xml to find logo path
    manifestPath := packagePath "\AppxManifest.xml"
    if (!FileExist(manifestPath))
        return ""

    logoRelPath := ""
    try {
        content := FileRead(manifestPath, "UTF-8")

        ; Look for Logo element in Properties or VisualElements
        ; Common patterns:
        ;   <Logo>Assets\StoreLogo.png</Logo>
        ;   <Square44x44Logo>Assets\Square44x44Logo.png</Square44x44Logo>
        ;   <Square150x150Logo>Assets\Square150x150Logo.png</Square150x150Logo>

        ; Prefer Square44x44Logo (closest to icon size), then Square150x150Logo, then Logo
        if (RegExMatch(content, 'i)Square44x44Logo="([^"]+)"', &m))
            logoRelPath := m[1]
        else if (RegExMatch(content, 'i)<Square44x44Logo>([^<]+)</Square44x44Logo>', &m))
            logoRelPath := m[1]
        else if (RegExMatch(content, 'i)Square150x150Logo="([^"]+)"', &m))
            logoRelPath := m[1]
        else if (RegExMatch(content, 'i)<Square150x150Logo>([^<]+)</Square150x150Logo>', &m))
            logoRelPath := m[1]
        else if (RegExMatch(content, 'i)<Logo>([^<]+)</Logo>', &m))
            logoRelPath := m[1]

    } catch {
        return ""
    }

    if (logoRelPath = "")
        return ""

    ; Logo path in manifest is relative, often without scale qualifier
    ; Actual files have scale suffixes like .scale-100.png, .scale-200.png
    basePath := packagePath "\" StrReplace(logoRelPath, "/", "\")

    ; Try to find the best scale version
    ; Remove .png extension to search for scale variants
    baseNoExt := RegExReplace(basePath, "\.png$", "")

    ; Search for scale variants (prefer larger scales for better quality)
    scales := [200, 150, 125, 100]
    for _, scale in scales {
        testPath := baseNoExt ".scale-" scale ".png"
        if (FileExist(testPath))
            return testPath
    }

    ; Try targetsize variants (common for app icons)
    sizes := [48, 44, 32, 24, 16]
    for _, size in sizes {
        testPath := baseNoExt ".targetsize-" size ".png"
        if (FileExist(testPath))
            return testPath
        ; Also try with _altform-unplated suffix
        testPath := baseNoExt ".targetsize-" size "_altform-unplated.png"
        if (FileExist(testPath))
            return testPath
    }

    ; Fall back to exact path if it exists
    if (FileExist(basePath))
        return basePath

    return ""
}

; Get the package installation path for a UWP process
_IP_GetPackagePath(pid) {
    global PROCESS_QUERY_LIMITED_INFORMATION
    if (!pid || pid <= 0)
        return ""

    ; Open process with PROCESS_QUERY_LIMITED_INFORMATION
    hProc := DllCall("kernel32\OpenProcess", "uint", PROCESS_QUERY_LIMITED_INFORMATION, "int", 0, "uint", pid, "ptr")
    if (!hProc)
        return ""

    ; Get package full name
    nameLen := 0
    DllCall("kernel32\GetPackageFullName", "ptr", hProc, "uint*", &nameLen, "ptr", 0, "int")

    if (nameLen <= 0) {
        DllCall("kernel32\CloseHandle", "ptr", hProc)
        return ""
    }

    nameBuf := Buffer(nameLen * 2, 0)
    result := DllCall("kernel32\GetPackageFullName", "ptr", hProc, "uint*", &nameLen, "ptr", nameBuf.Ptr, "int")
    DllCall("kernel32\CloseHandle", "ptr", hProc)

    if (result != 0)
        return ""

    packageFullName := StrGet(nameBuf.Ptr, "UTF-16")
    if (packageFullName = "")
        return ""

    ; Get package path from full name
    pathLen := 0
    DllCall("kernel32\GetPackagePathByFullName", "wstr", packageFullName, "uint*", &pathLen, "ptr", 0, "int")

    if (pathLen <= 0)
        return ""

    pathBuf := Buffer(pathLen * 2, 0)
    result := DllCall("kernel32\GetPackagePathByFullName", "wstr", packageFullName, "uint*", &pathLen, "ptr", pathBuf.Ptr, "int")

    if (result != 0)
        return ""

    return StrGet(pathBuf.Ptr, "UTF-16")
}

; Try to extract icon from UWP package
_IP_TryResolveFromUWP(hwnd, pid) {
    ; Check if it's a UWP app
    if (!_IP_AppHasPackage(pid))
        return 0

    ; Get logo path
    logoPath := _IP_GetUWPLogoPath(hwnd)
    if (logoPath = "" || !FileExist(logoPath))
        return 0

    ; Load PNG as HBITMAP
    hBitmap := 0
    hIcon := 0
    try {
        hBitmap := LoadPicture(logoPath, "GDI+")
        if (!hBitmap)
            return 0

        ; Convert HBITMAP to HICON
        hIcon := _IP_BitmapToIcon(hBitmap)
    } catch as e {
        _IP_Log("UWP LoadPicture FAILED path=" logoPath " err=" e.Message)
    }

    ; ALWAYS clean up hBitmap if allocated (whether success or failure)
    if (hBitmap)
        DllCall("gdi32\DeleteObject", "ptr", hBitmap)

    return hIcon
}

; Convert HBITMAP to HICON
_IP_BitmapToIcon(hBitmap) {
    if (!hBitmap)
        return 0

    ; Get bitmap info
    bm := Buffer(32, 0)  ; BITMAP structure
    if (!DllCall("gdi32\GetObjectW", "ptr", hBitmap, "int", 32, "ptr", bm.Ptr, "int"))
        return 0

    width := NumGet(bm, 4, "int")
    height := NumGet(bm, 8, "int")

    ; Create icon info
    ii := Buffer(A_PtrSize * 4 + 8, 0)  ; ICONINFO structure
    NumPut("int", 1, ii, 0)              ; fIcon = TRUE
    NumPut("int", 0, ii, 4)              ; xHotspot
    NumPut("int", 0, ii, 8)              ; yHotspot

    ; Create monochrome mask bitmap (all white = fully opaque)
    hMask := DllCall("gdi32\CreateBitmap", "int", width, "int", height, "uint", 1, "uint", 1, "ptr", 0, "ptr")
    if (!hMask)
        return 0

    NumPut("ptr", hMask, ii, A_PtrSize = 8 ? 16 : 12)    ; hbmMask
    NumPut("ptr", hBitmap, ii, A_PtrSize = 8 ? 24 : 16)  ; hbmColor

    hIcon := DllCall("user32\CreateIconIndirect", "ptr", ii.Ptr, "ptr")

    DllCall("gdi32\DeleteObject", "ptr", hMask)

    return hIcon
}
