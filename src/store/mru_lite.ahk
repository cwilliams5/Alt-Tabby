#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Expected: file is included after windowstore.ahk

; MRU-lite: track active window and update lastActivatedTick in store.
; This is a FALLBACK - only used if WinEventHook fails to start.

; Configuration (use value from config.ahk if set, otherwise default)
global MruLiteIntervalMs := IsSet(MruLitePollMs) ? MruLitePollMs : 250

global _MRU_LastHwnd := 0

MRU_Lite_Init() {
    global MruLiteIntervalMs
    SetTimer(MRU_Lite_Tick, MruLiteIntervalMs)
}

MRU_Lite_Tick() {
    global _MRU_LastHwnd
    hwnd := 0
    try {
        hwnd := WinGetID("A")
    } catch {
        ; No active window (e.g., during workspace switch)
        return
    }
    if (!hwnd || hwnd = _MRU_LastHwnd) {
        return
    }
    ; Clear focus on previous window
    if (_MRU_LastHwnd) {
        try {
            WindowStore_UpdateFields(_MRU_LastHwnd, { isFocused: false })
        }
    }
    _MRU_LastHwnd := hwnd
    try {
        WindowStore_UpdateFields(hwnd, { lastActivatedTick: A_TickCount, isFocused: true })
    }
}
