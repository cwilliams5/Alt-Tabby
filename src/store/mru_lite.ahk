#Requires AutoHotkey v2.0

; MRU-lite: track active window and update lastActivatedTick in store.

global _MRU_LastHwnd := 0

MRU_Lite_Init() {
    SetTimer(MRU_Lite_Tick, 250)
}

MRU_Lite_Tick() {
    global _MRU_LastHwnd
    hwnd := WinGetID("A")
    if (!hwnd || hwnd = _MRU_LastHwnd)
        return
    _MRU_LastHwnd := hwnd
    WindowStore_UpdateFields(hwnd, { lastActivatedTick: A_TickCount, isFocused: true })
}
