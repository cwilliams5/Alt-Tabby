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

; Window messages
global WM_MOUSEMOVE := 0x0200
global WM_LBUTTONDOWN := 0x0201
global WM_MOUSELEAVE := 0x02A3
global WM_DPICHANGED := 0x02E0

; DWM window attributes
global DWMWA_CLOAK := 13
global DWMWA_USE_IMMERSIVE_DARK_MODE_19 := 19
global DWMWA_USE_IMMERSIVE_DARK_MODE := 20
global DWMWA_WINDOW_CORNER_PREFERENCE := 33
global HWND_TOPMOST := -1
global HWND_NOTOPMOST := -2
global SWP_NOSIZE := 0x0001
global SWP_NOMOVE := 0x0002
global SWP_NOZORDER := 0x0004
global SWP_NOACTIVATE := 0x0010
global SWP_SHOWWINDOW := 0x0040
global SWP_NOOWNERZORDER := 0x0200

; Monitor
global MONITOR_DEFAULTTONEAREST := 2

; GDI+ enums
global GDIP_UNIT_PIXEL := 2
global GDIP_STRING_ALIGN_NEAR := 0
global GDIP_STRING_ALIGN_CENTER := 1
global GDIP_STRING_ALIGN_FAR := 2
global GDIP_STRING_FORMAT_NO_WRAP := 0x00001000
global GDIP_STRING_FORMAT_LINE_LIMIT := 0x00004000
global GDIP_STRING_TRIMMING_ELLIPSIS := 3

; GDI+ rendering modes
global GDIP_SMOOTHING_ANTIALIAS := 4
global GDIP_TEXT_RENDER_ANTIALIAS_GRIDFIT := 5
global GDIP_PIXEL_FORMAT_32BPP_ARGB := 0x26200A
global GDIP_IMAGE_LOCK_WRITE := 2

; BITMAPINFOHEADER
global BITMAPINFOHEADER_SIZE := 40
global BPP_32 := 32

; ============================================================
; Paint Layout Constants (DIP = Device-Independent Pixels)
; ============================================================
; Each row in the overlay has this vertical structure:
;
;   y=0  ┌─────────────────────────────────────────┐
;        │ HDR_Y=4: Header text (workspace label)  │ HEADER_BLOCK=32
;        │ TITLE_Y=6: Main title  (h=TITLE_H=24)   │
;        │ SUB_Y=28: Subtitle     (h=SUB_H=18)      │
;   y=32 └─────────────────────────────────────────┘
;
; Horizontal: [ARROW_W=24][ARROW_PAD=8][ content ][ TEXT_RIGHT_PAD=16]
; Column headers: COL_Y=10, COL_H=20
; ============================================================
global PAINT_HEADER_BLOCK_DIP := 32
global PAINT_HDR_Y_DIP := 4
global PAINT_TITLE_Y_DIP := 6
global PAINT_TITLE_H_DIP := 24
global PAINT_SUB_Y_DIP := 28
global PAINT_SUB_H_DIP := 18
global PAINT_COL_Y_DIP := 10
global PAINT_COL_H_DIP := 20
global PAINT_ARROW_W_DIP := 24
global PAINT_ARROW_PAD_DIP := 8
global PAINT_TEXT_RIGHT_PAD_DIP := 16
