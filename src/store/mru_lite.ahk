#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Expected: file is included after windowstore.ahk

; MRU-lite: track active window and update lastActivatedTick in store.

global _MRU_LastHwnd := 0

MRU_Lite_Init() {
    SetTimer(MRU_Lite_Tick, 250)
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
