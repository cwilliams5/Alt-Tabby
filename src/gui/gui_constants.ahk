#Requires AutoHotkey v2.0
; Event codes shared between interceptor, state machine, and tests
global TABBY_EV_TAB_STEP := 1  ; Tab pressed during Alt+Tab session
global TABBY_EV_ALT_UP   := 2  ; Alt released, session ended
global TABBY_EV_ALT_DOWN := 3  ; Alt pressed, session starting
global TABBY_EV_ESCAPE   := 4  ; Escape pressed, cancel session
global TABBY_FLAG_SHIFT  := 1  ; Shift modifier flag
