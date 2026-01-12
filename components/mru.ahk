#Requires AutoHotkey v2.0
;===============================================================================
; mru.ahk — focus/activation stream → annotate WindowStore
; Public:
;   MRU_Init()
;   MRU_GetList()              -> array of hwnds (most-recent-first) [debug]
;   MRU_SetDebounce(ms)        -> set activation debounce window in ms (0=off)
;   MRU_MoveToFront(hwnd)      -> (debug/back-compat)
;   MRU_Remove(hwnd)           -> (debug/back-compat)
; Notes:
;   - Requires WindowStore_Ensure / WindowStore_UpdateFields / WindowStore_RemoveWindow.
;   - Assumes winenum.ahk has registered its enumerate-by-hwnd fetcher with the store.
;===============================================================================

;------------------------------ Module state ----------------------------------
global _MRU_list := []           ; debug deque (most-recent-first)
global _MRU_msg  := 0
global _MRU_win  := 0

global _MRU_prevFocusedHwnd := 0 ; last hwnd we marked isFocused=true
global _MRU_lastActHwnd     := 0 ; for debounce
global _MRU_lastActTick     := 0

; Config: activation debounce window in ms (0 = off)
global MRU_ActivationDebounceMs := 0

; Optional: set to your overlay title to ignore its focus events
; global OverlayTitle := "Tabby Overlay"  ; (set elsewhere if you’d like)

;------------------------------ Public API ------------------------------------

MRU_Init() {
    global _MRU_msg, _MRU_win
    if (_MRU_msg)  ; already initialized
        return

    _MRU_win := Gui("-Caption +ToolWindow")
    _MRU_win.Hide()

    ; register hidden GUI as a shell hook window
    DllCall("RegisterShellHookWindow", "ptr", _MRU_win.Hwnd)

    ; get the message id for shell notifications and route it
    _MRU_msg := DllCall("RegisterWindowMessage", "str", "SHELLHOOK", "uint")
    OnMessage(_MRU_msg, MRU_OnShell)

    OnExit(_MRU_OnExit)
}

MRU_SetDebounce(ms) {
    global MRU_ActivationDebounceMs
    MRU_ActivationDebounceMs := Max(0, ms + 0)
}

MRU_GetList() {
    global _MRU_list
    return _MRU_list.Clone()   ; shallow copy for safety
}

MRU_MoveToFront(hwnd) {
    global _MRU_list
    hwnd := hwnd + 0
    if (hwnd = 0)
        return
    ; remove old occurrence
    for i, h in _MRU_list {
        if (h = hwnd) {
            _MRU_list.RemoveAt(i)
            break
        }
    }
    _MRU_list.InsertAt(1, hwnd)
}

MRU_Remove(hwnd) {
    global _MRU_list
    hwnd := hwnd + 0
    if (hwnd = 0)
        return
    for i, h in _MRU_list {
        if (h = hwnd) {
            _MRU_list.RemoveAt(i)
            break
        }
    }
}

;--------------------------- Shell hook handler -------------------------------

MRU_OnShell(wParam, lParam, msg, hwnd) {
    static HSHELL_WINDOWCREATED      := 1
    static HSHELL_WINDOWDESTROYED    := 2
    static HSHELL_WINDOWACTIVATED    := 4
    static HSHELL_RUDEAPPACTIVATED   := 0x8004

    if (lParam = 0)
        return

    switch wParam {
        case HSHELL_WINDOWCREATED:
            _MRU_OnCreated(lParam)

        case HSHELL_WINDOWDESTROYED:
            _MRU_OnDestroyed(lParam)

        case HSHELL_WINDOWACTIVATED, HSHELL_RUDEAPPACTIVATED:
            _MRU_OnActivated(lParam)
    }
}

;------------------------------ Event handling --------------------------------

_MRU_OnCreated(hwnd) {
    ; Seed the store quickly so background pumps can enrich later.
    try WindowStore_Ensure(hwnd, 0, "mru")
    catch
        ; ignore

    ; Keep debug deque in sync (optional)
    MRU_MoveToFront(hwnd)
}


_MRU_OnDestroyed(hwnd) {
    ; Clean store immediately to avoid “ghosts”.
    try WindowStore_RemoveWindow(hwnd)
    catch
        ; ignore
    ; Sync debug deque
    MRU_Remove(hwnd)
    ; Clear prev focus marker if it was this hwnd
    global _MRU_prevFocusedHwnd
    if (_MRU_prevFocusedHwnd = hwnd)
        _MRU_prevFocusedHwnd := 0
}

_MRU_OnActivated(hwnd) {
    ; Ignore our own AHK/overlay focus to prevent churn
    if (_MRU_ShouldIgnore(hwnd))
        return

    ; Debounce repeated activations (same hwnd within N ms)
    global MRU_ActivationDebounceMs, _MRU_lastActHwnd, _MRU_lastActTick
    now := A_TickCount
    if (MRU_ActivationDebounceMs > 0) {
        if (hwnd = _MRU_lastActHwnd && (now - _MRU_lastActTick) < MRU_ActivationDebounceMs)
            return
        _MRU_lastActHwnd := hwnd
        _MRU_lastActTick := now
    }

    ; Mark new focus & MRU in the store (owned by MRU)
    try WindowStore_Ensure(hwnd, { lastActivatedTick: now, isFocused: true }, "mru")
    catch
        ; ignore

    ; Clear focus flag on the previously focused window (if different)
    global _MRU_prevFocusedHwnd
    if (_MRU_prevFocusedHwnd && _MRU_prevFocusedHwnd != hwnd) {
        try WindowStore_UpdateFields(_MRU_prevFocusedHwnd, { isFocused: false }, "mru")
        catch
            ; ignore
    }
    _MRU_prevFocusedHwnd := hwnd

    ; Keep debug deque in sync
    MRU_MoveToFront(hwnd)
}


;------------------------------ Helpers ---------------------------------------

_MRU_ShouldIgnore(hwnd) {
    ; Ignore known AHK/overlay windows so they don’t pollute MRU.
    cls := _MRU_GetClass(hwnd)
    if (cls = "AutoHotkeyGUI")
        return true

    if (IsSet(OverlayTitle) && OverlayTitle) {
        ttl := ""
        try ttl := WinGetTitle("ahk_id " hwnd)
        if (ttl = OverlayTitle)
            return true
    }
    return false
}

_MRU_GetClass(hWnd) {
    buf := Buffer(256*2, 0)
    DllCall("user32\GetClassNameW", "ptr", hWnd, "ptr", buf.Ptr, "int", 256, "int")
    return StrGet(buf.Ptr, "UTF-16")
}

_MRU_OnExit(reason, code) {
    global _MRU_win
    try {
        if IsObject(_MRU_win)
            _MRU_win.Destroy()
    }
}

