#Requires AutoHotkey v2.0
; Event codes shared between interceptor, state machine, and tests
global TABBY_EV_TAB_STEP := 1  ; Tab pressed during Alt+Tab session
global TABBY_EV_ALT_UP   := 2  ; Alt released, session ended
global TABBY_EV_ALT_DOWN := 3  ; Alt pressed, session starting
global TABBY_EV_ESCAPE   := 4  ; Escape pressed, cancel session
global TABBY_FLAG_SHIFT  := 1  ; Shift modifier flag

; Win32 window constants
global SW_RESTORE := 9
global GWL_EXSTYLE := -20
global WS_EX_LAYERED := 0x80000
global HWND_TOPMOST := -1
global HWND_NOTOPMOST := -2
global SWP_NOSIZE := 0x0001
global SWP_NOMOVE := 0x0002
global SWP_SHOWWINDOW := 0x0040
global SWP_ASYNCWINDOWPOS := 0x4000

; GDI+ enums
global GDIP_UNIT_PIXEL := 2
global GDIP_STRING_ALIGN_NEAR := 0
global GDIP_STRING_ALIGN_CENTER := 1
global GDIP_STRING_ALIGN_FAR := 2
global GDIP_STRING_FORMAT_NO_WRAP := 0x00001000
global GDIP_STRING_FORMAT_LINE_LIMIT := 0x00004000
global GDIP_STRING_TRIMMING_ELLIPSIS := 3

; Paint layout (DIP values, pre-scale)
global PAINT_HDR_Y_DIP := 4
global PAINT_TITLE_Y_DIP := 6
global PAINT_TITLE_H_DIP := 24
global PAINT_SUB_Y_DIP := 28
global PAINT_SUB_H_DIP := 18
global PAINT_COL_Y_DIP := 10
global PAINT_COL_H_DIP := 20
global PAINT_ARROW_W_DIP := 24
global PAINT_ARROW_PAD_DIP := 8
