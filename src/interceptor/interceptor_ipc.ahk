#Requires AutoHotkey v2.0

; interceptor_ipc.ahk - Ultra-light PostMessage IPC for interceptor
; Uses Windows message broadcast for non-blocking, async communication
;
; Events:
;   1 = TAB_STEP   (Tab pressed during Alt+Tab session)
;   2 = ALT_UP     (Alt released, session ended)
;
; Flags (wParam bits):
;   bit0 = Shift held (1) / not (0)

global TABBY_MSG_ID := 0
global TABBY_MAGIC  := 0x54414259  ; 'TABY' low-entropy guard

; Get or register the app-defined message ID
; Same string = same ID across all processes
TABBY_IPC_GetMsgId() {
    global TABBY_MSG_ID
    if (TABBY_MSG_ID)
        return TABBY_MSG_ID
    TABBY_MSG_ID := DllCall("user32\RegisterWindowMessage", "str", "TABBY_ALTMSG_V1", "uint")
    return TABBY_MSG_ID
}

; Post event to all top-level windows (broadcast)
; Non-blocking - returns immediately
; @param evCode  Event code (1=TAB_STEP, 2=ALT_UP)
; @param flags   Bit flags (bit0=shift)
; @param lParam  Optional additional data
TABBY_IPC_Post(evCode, flags := 0, lParam := 0) {
    msg := TABBY_IPC_GetMsgId()
    ; Pack: [ magic low16 | flags8 | event8 ]
    wParam := ((TABBY_MAGIC & 0xFFFF) << 16) | ((flags & 0xFF) << 8) | (evCode & 0xFF)
    DllCall("user32\PostMessage", "ptr", 0xFFFF, "uint", msg, "uptr", wParam, "ptr", lParam)
}

; Register a callback to receive events
; @param cb  Callback function(evCode, flags, lParam)
TABBY_IPC_Listen(cb) {
    msg := TABBY_IPC_GetMsgId()
    OnMessage(msg, (w, l, m, h) => _TABBY_IPC_Dispatch(cb, w, l))
}

_TABBY_IPC_Dispatch(cb, wParam, lParam) {
    global TABBY_MAGIC
    ; Validate magic guard
    if (((wParam >> 16) & 0xFFFF) != (TABBY_MAGIC & 0xFFFF))
        return
    ev    := (wParam & 0xFF)
    flags := (wParam >> 8) & 0xFF
    try cb(ev, flags, lParam)
}

; Event constants for clarity
global TABBY_EV_TAB_STEP := 1
global TABBY_EV_ALT_UP   := 2
global TABBY_FLAG_SHIFT  := 1
