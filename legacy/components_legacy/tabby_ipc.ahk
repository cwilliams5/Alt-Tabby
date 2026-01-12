#Requires AutoHotkey v2.0
; tabby_ipc.ahk — ultra-light PostMessage IPC (asynchronous, non-blocking)
; Events: 1=TAB_STEP, 2=ALT_UP
; Flags:  bit0 = Shift held (1) / not (0)

global TABBY_MSG_ID := 0
global TABBY_MAGIC  := 0x54414259  ; 'TABY' low-entropy guard

TABBY_IPC_GetMsgId() {
    global TABBY_MSG_ID
    if (TABBY_MSG_ID)
        return TABBY_MSG_ID
    ; Register a named app-defined message; same string => same id across procs.
    TABBY_MSG_ID := DllCall("user32\RegisterWindowMessage", "str", "TABBY_ALTMSG_V1", "uint")
    return TABBY_MSG_ID
}

; Post a tiny notification (never blocks). Targets all top-level windows (broadcast).
TABBY_IPC_Post(evCode, flags := 0, lParam := 0) {
    msg := TABBY_IPC_GetMsgId()
    ; Pack a small signature + flags + event code into wParam.
    ; wParam layout: [ magic low16 | flags8 | event8 ]
    wParam := ((TABBY_MAGIC & 0xFFFF) << 16) | ((flags & 0xFF) << 8) | (evCode & 0xFF)
    DllCall("user32\PostMessage", "ptr", 0xFFFF       ; HWND_BROADCAST
        , "uint", msg, "uptr", wParam, "ptr", lParam) ; returns immediately
}

; Receiver setup: route to a user callback (evCode, flags, lParam)
TABBY_IPC_Listen(cb) {
    msg := TABBY_IPC_GetMsgId()
    OnMessage(msg, (w,l,m,h) => TABBY_IPC__Dispatch(cb, w, l))
}

TABBY_IPC__Dispatch(cb, wParam, lParam) {
    global TABBY_MAGIC
    ; Quick sanity on our low-entropy guard (keeps random traffic out).
    if (((wParam >> 16) & 0xFFFF) != (TABBY_MAGIC & 0xFFFF))
        return
    ev    := (wParam & 0xFF)
    flags := (wParam >> 8) & 0xFF
    try cb(ev, flags, lParam)
}
