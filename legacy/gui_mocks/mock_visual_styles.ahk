#Requires AutoHotkey v2.0
; Mock: Viable Windows backdrop effects for Alt-Tabby
;
; Shows the 4 backdrop styles that work from AHK/Win32:
;   1. Acrylic (SWC)    - Current Alt-Tabby style, tintable blur
;   2. Blur Behind (SWC) - Aero-style gaussian blur, no tint
;   3. Gradient (SWC)    - Solid tinted overlay, no blur
;   4. Acrylic (DWM)     - Modern DWM-managed blur, active when focused
;
; All use SetWindowCompositionAttribute except #4 which uses
; DwmSetWindowAttribute with DWMWA_SYSTEMBACKDROP_TYPE.
;
; Mica (DWMSBT=2) and Mica Alt (DWMSBT=4) were tested extensively
; and confirmed to require the WinUI/XAML compositor — they cannot
; work from pure Win32/GDI windows regardless of window class,
; background brush, WS_EX_NOREDIRECTIONBITMAP, or paint handling.
;
; Press Esc to exit

try DllCall("user32\SetProcessDpiAwarenessContext", "ptr", -4, "ptr")

W := 400
H := 300
GAP := 12
baseX := (A_ScreenWidth - (4 * W + 3 * GAP)) // 2
baseY := (A_ScreenHeight - H) // 2
baseX := Max(10, baseX)
baseY := Max(10, baseY)

guis := []
gDwmHwnd := 0

; ─── Shared DWM hooks for window 4 ───
WM_ERASEBKGND_ID := 14
OnMessage(WM_ERASEBKGND_ID, _WM_ERASEBKGND)

; ═══════════════════════════════════════════════════════════
;  1. SWC Acrylic — Alt-Tabby's current backdrop
;     Tintable blur that replaces the window surface.
;     Works on Win10 1803+ regardless of focus.
; ═══════════════════════════════════════════════════════════
{
    g := Gui("-Caption +AlwaysOnTop +ToolWindow")
    g.BackColor := "0a0a1a"
    g.MarginX := 24, g.MarginY := 20

    g.SetFont("s16 cWhite Bold", "Segoe UI")
    g.AddText("w" (W - 48), "Acrylic")
    g.SetFont("s10 cDDDDDD Norm")
    g.AddText("w" (W - 48), "SetWindowCompositionAttribute`nACCENT_ENABLE_ACRYLICBLURBEHIND (4)")
    g.SetFont("s9 cAAAAAA")
    g.AddText("w" (W - 48), "Tintable blur behind the window.`nReplaces the window surface entirely.`nWorks regardless of focus state.`n`nThis is what Alt-Tabby uses today.")
    g.SetFont("s9 Norm", "Consolas")
    sc := g.AddText("w" (W - 48) " c44FF44", "...")

    g.Show("x" baseX " y" baseY " w" W " h" H " NoActivate")

    SetDarkMode(g.Hwnd)
    SetCorners(g.Hwnd)
    ok := ApplySWC(g.Hwnd, 4, 0x88002244)
    sc.Value := ok ? "Applied OK" : "FAILED"
    if (!ok)
        sc.SetFont("cFF4444")

    g.OnEvent("Close", (*) => ExitApp())
    guis.Push(g)
}

; ═══════════════════════════════════════════════════════════
;  2. SWC Blur Behind — Aero-style blur
;     Clean gaussian blur, no tint color support.
;     Works on Win10 1803+ regardless of focus.
; ═══════════════════════════════════════════════════════════
{
    x := baseX + (W + GAP)

    g := Gui("-Caption +AlwaysOnTop +ToolWindow")
    g.BackColor := "0a0a1a"
    g.MarginX := 24, g.MarginY := 20

    g.SetFont("s16 cWhite Bold", "Segoe UI")
    g.AddText("w" (W - 48), "Blur Behind")
    g.SetFont("s10 cDDDDDD Norm")
    g.AddText("w" (W - 48), "SetWindowCompositionAttribute`nACCENT_ENABLE_BLURBEHIND (3)")
    g.SetFont("s9 cAAAAAA")
    g.AddText("w" (W - 48), "Gaussian blur without tint color.`nReplaces the window surface entirely.`nWorks regardless of focus state.`n`nClean Aero glass look.")
    g.SetFont("s9 Norm", "Consolas")
    sc := g.AddText("w" (W - 48) " c44FF44", "...")

    g.Show("x" x " y" baseY " w" W " h" H " NoActivate")

    SetDarkMode(g.Hwnd)
    SetCorners(g.Hwnd)
    ok := ApplySWC(g.Hwnd, 3, 0x88002244)
    sc.Value := ok ? "Applied OK" : "FAILED"
    if (!ok)
        sc.SetFont("cFF4444")

    g.OnEvent("Close", (*) => ExitApp())
    guis.Push(g)
}

; ═══════════════════════════════════════════════════════════
;  3. SWC Gradient — Tinted transparent overlay
;     Solid color with alpha blending, no blur.
;     Lowest GPU cost. Works on Win10 1803+.
; ═══════════════════════════════════════════════════════════
{
    x := baseX + 2 * (W + GAP)

    g := Gui("-Caption +AlwaysOnTop +ToolWindow")
    g.BackColor := "0a0a1a"
    g.MarginX := 24, g.MarginY := 20

    g.SetFont("s16 cWhite Bold", "Segoe UI")
    g.AddText("w" (W - 48), "Gradient")
    g.SetFont("s10 cDDDDDD Norm")
    g.AddText("w" (W - 48), "SetWindowCompositionAttribute`nACCENT_ENABLE_TRANSPARENTGRADIENT (2)")
    g.SetFont("s9 cAAAAAA")
    g.AddText("w" (W - 48), "Solid color with alpha blending.`nNo blur effect — just tinted glass.`nLowest GPU overhead.`n`nSimple transparent overlay.")
    g.SetFont("s9 Norm", "Consolas")
    sc := g.AddText("w" (W - 48) " c44FF44", "...")

    g.Show("x" x " y" baseY " w" W " h" H " NoActivate")

    SetDarkMode(g.Hwnd)
    SetCorners(g.Hwnd)
    ok := ApplySWC(g.Hwnd, 2, 0x88002244)
    sc.Value := ok ? "Applied OK" : "FAILED"
    if (!ok)
        sc.SetFont("cFF4444")

    g.OnEvent("Close", (*) => ExitApp())
    guis.Push(g)
}

; ═══════════════════════════════════════════════════════════
;  4. DWM Acrylic — Modern DWM-managed blur
;     Uses DWMWA_SYSTEMBACKDROP_TYPE = TRANSIENTWINDOW (3).
;     Only renders when the window has focus — perfect for
;     Alt-Tabby since the overlay always has focus when shown.
;     Requires: extended frame, host backdrop, hollow brush,
;     WM_ERASEBKGND suppression.
; ═══════════════════════════════════════════════════════════
{
    x := baseX + 3 * (W + GAP)

    g := Gui("+AlwaysOnTop", "DWM Acrylic")
    g.BackColor := "000000"
    g.MarginX := 24, g.MarginY := 10

    g.SetFont("s16 cWhite Bold", "Segoe UI")
    g.AddText("w" (W - 48) " BackgroundTrans", "DWM Acrylic")
    g.SetFont("s10 cDDDDDD Norm")
    g.AddText("w" (W - 48) " BackgroundTrans", "DwmSetWindowAttribute`nDWMSBT_TRANSIENTWINDOW (3)")
    g.SetFont("s9 cAAAAAA")
    g.AddText("w" (W - 48) " BackgroundTrans",
        "Modern DWM-managed acrylic blur.`nOnly active when window is focused.`nFine for Alt-Tabby (overlay has focus).`n`nClick this window to see the effect!")
    g.SetFont("s9 Norm", "Consolas")
    sc := g.AddText("w" (W - 48) " BackgroundTrans c44FF44", "...")

    g.Show("x" x " y" baseY " w" W " h" H " NoActivate")
    gDwmHwnd := g.Hwnd

    SetDarkMode(g.Hwnd)
    SetCorners(g.Hwnd)

    hrF := ExtendFrame(g.Hwnd)
    okH := ApplySWC(g.Hwnd, 5, 0)  ; ACCENT_ENABLE_HOSTBACKDROP
    hrB := SetBackdrop(g.Hwnd, 3)   ; DWMSBT_TRANSIENTWINDOW

    allOk := (hrF = 0) && okH && (hrB = 0)
    sc.Value := allOk ? "Applied OK — click to focus!" : "Frame:" (hrF=0?"OK":"FAIL") " Host:" (okH?"OK":"FAIL") " Backdrop:" (hrB=0?"OK":"FAIL")
    if (!allOk)
        sc.SetFont("cFF4444")

    ; Hollow brush so DWM material shows through
    hollowBrush := DllCall("gdi32\GetStockObject", "int", 5, "ptr")
    DllCall("user32\SetClassLongPtrW",
        "ptr", g.Hwnd, "int", -10, "ptr", hollowBrush, "ptr")
    DllCall("user32\InvalidateRect", "ptr", g.Hwnd, "ptr", 0, "int", 1)
    DllCall("user32\UpdateWindow", "ptr", g.Hwnd)
    try DllCall("dwmapi\DwmFlush")

    g.OnEvent("Close", (*) => ExitApp())
    guis.Push(g)
}

ToolTip("Viable Backdrop Styles | Esc to exit | Click #4 to see DWM Acrylic", baseX, baseY - 25, 1)

Hotkey("Escape", (*) => ExitApp())
return

; ═══════════════════════════════════════════════════════════
;  Message Handlers
; ═══════════════════════════════════════════════════════════

_WM_ERASEBKGND(wParam, lParam, msg, hwnd) {
    global gDwmHwnd
    if (hwnd = gDwmHwnd)
        return 1
}

; ═══════════════════════════════════════════════════════════
;  DLL Wrappers
; ═══════════════════════════════════════════════════════════

ApplySWC(hWnd, accentType, argbColor) {
    alpha := (argbColor >> 24) & 0xFF
    rr    := (argbColor >> 16) & 0xFF
    gg    := (argbColor >> 8)  & 0xFF
    bb    := (argbColor)       & 0xFF
    grad  := (alpha << 24) | (bb << 16) | (gg << 8) | rr

    accent := Buffer(16, 0)
    NumPut("Int", accentType, accent, 0)
    NumPut("Int", 0,          accent, 4)
    NumPut("Int", grad,       accent, 8)
    NumPut("Int", 0,          accent, 12)

    data := Buffer(A_PtrSize * 3, 0)
    NumPut("Int", 19,          data, 0)
    NumPut("Ptr", accent.Ptr,  data, A_PtrSize)
    NumPut("Int", accent.Size, data, A_PtrSize * 2)

    return DllCall("user32\SetWindowCompositionAttribute",
        "ptr", hWnd, "ptr", data.Ptr, "int")
}

SetDarkMode(hWnd) {
    buf := Buffer(4, 0)
    NumPut("Int", 1, buf, 0)
    try DllCall("dwmapi\DwmSetWindowAttribute",
        "ptr", hWnd, "int", 20, "ptr", buf.Ptr, "int", 4, "int")
    try DllCall("dwmapi\DwmSetWindowAttribute",
        "ptr", hWnd, "int", 19, "ptr", buf.Ptr, "int", 4, "int")
}

SetCorners(hWnd) {
    buf := Buffer(4, 0)
    NumPut("Int", 2, buf, 0)
    try DllCall("dwmapi\DwmSetWindowAttribute",
        "ptr", hWnd, "int", 33, "ptr", buf.Ptr, "int", 4, "int")
}

ExtendFrame(hWnd) {
    margins := Buffer(16, 0)
    NumPut("Int", -1, margins, 0)
    NumPut("Int", -1, margins, 4)
    NumPut("Int", -1, margins, 8)
    NumPut("Int", -1, margins, 12)
    return DllCall("dwmapi\DwmExtendFrameIntoClientArea",
        "ptr", hWnd, "ptr", margins.Ptr, "int")
}

SetBackdrop(hWnd, backdropType) {
    buf := Buffer(4, 0)
    NumPut("Int", backdropType, buf, 0)
    try return DllCall("dwmapi\DwmSetWindowAttribute",
        "ptr", hWnd, "int", 38, "ptr", buf.Ptr, "int", 4, "int")
    catch
        return -1
}
