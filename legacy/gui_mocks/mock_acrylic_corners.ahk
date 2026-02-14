#Requires AutoHotkey v2.0
; Mock: Isolate what's blocking DWM rounding on Win11
;
; Tests (2 rows x 3 cols):
;   Row 1 - No acrylic (isolate style issue):
;     1. +Resize (WS_THICKFRAME from start) + DWMWCP_ROUND
;     2. -Caption +Resize + DWMWCP_ROUND
;     3. Normal captioned window + DWMWCP_ROUND (should DEFINITELY round)
;
;   Row 2 - With SWC acrylic:
;     4. +Resize + acrylic + DWMWCP_ROUND
;     5. -Caption +Resize + acrylic + DWMWCP_ROUND
;     6. Normal captioned + acrylic + DWMWCP_ROUND
;
; Press Esc to exit

try DllCall("user32\SetProcessDpiAwarenessContext", "ptr", -4, "ptr")

W := 300
H := 180
GAP := 20
ROW_GAP := 60
x0 := 60
y1 := 160
y2 := y1 + H + ROW_GAP

; ======= ROW 1: No acrylic - isolate style =======

; Win 1: +Resize (gives WS_THICKFRAME) + DWMWCP_ROUND, no caption removal
g1 := Gui("+AlwaysOnTop +Resize", "1: +Resize")
g1.BackColor := "1a1a2e"
g1.Show("x" x0 " y" y1 " w" W " h" H)
ApplyCornerPref(g1.Hwnd, 2)

; Win 2: -Caption +Resize + DWMWCP_ROUND
g2 := Gui("+AlwaysOnTop -Caption +Resize", "2: -Caption+Resize")
g2.BackColor := "1a1a2e"
g2.Show("x" (x0 + W + GAP) " y" y1 " w" W " h" H)
ApplyCornerPref(g2.Hwnd, 2)

; Win 3: Normal captioned window (should auto-round on Win11)
g3 := Gui("+AlwaysOnTop", "3: Normal captioned")
g3.BackColor := "1a1a2e"
g3.Show("x" (x0 + 2*(W + GAP)) " y" y1 " w" W " h" H)
ApplyCornerPref(g3.Hwnd, 2)

; ======= ROW 2: With SWC acrylic =======

; Win 4: +Resize + acrylic
g4 := Gui("+AlwaysOnTop +Resize", "4: +Resize+Acrylic")
g4.BackColor := "000000"
g4.Show("x" x0 " y" y2 " w" W " h" H)
ApplyCornerPref(g4.Hwnd, 2)
ApplyAcrylicSWC(g4.Hwnd, 0x66330033)

; Win 5: -Caption +Resize + acrylic
g5 := Gui("+AlwaysOnTop -Caption +Resize", "5: -Cap+Resize+Acrylic")
g5.BackColor := "000000"
g5.Show("x" (x0 + W + GAP) " y" y2 " w" W " h" H)
ApplyCornerPref(g5.Hwnd, 2)
ApplyAcrylicSWC(g5.Hwnd, 0x66330033)

; Win 6: Normal captioned + acrylic
g6 := Gui("+AlwaysOnTop", "6: Captioned+Acrylic")
g6.BackColor := "000000"
g6.Show("x" (x0 + 2*(W + GAP)) " y" y2 " w" W " h" H)
ApplyCornerPref(g6.Hwnd, 2)
ApplyAcrylicSWC(g6.Hwnd, 0x66330033)

; Log actual styles for debugging
loop 6 {
    g := [g1, g2, g3, g4, g5, g6][A_Index]
    style := Format("0x{:08X}", DllCall("user32\GetWindowLongPtrW", "ptr", g.Hwnd, "int", -16, "ptr"))
    exstyle := Format("0x{:08X}", DllCall("user32\GetWindowLongPtrW", "ptr", g.Hwnd, "int", -20, "ptr"))
    ToolTip("Win" A_Index ": style=" style " exstyle=" exstyle, x0, y2 + H + 10 + (A_Index-1)*20, A_Index + 1)
}

ToolTip("Row1=NoAcrylic Row2=Acrylic | Col1=+Resize Col2=-Caption+Resize Col3=Normal`nAll DWMWCP_ROUND. Esc=exit", x0, y1 - 35, 1)

Hotkey("Escape", (*) => ExitApp())
return

; ========================= HELPERS =========================

ApplyAcrylicSWC(hWnd, argbColor) {
    alpha := (argbColor >> 24) & 0xFF
    rr := (argbColor >> 16) & 0xFF
    gg := (argbColor >> 8) & 0xFF
    bb := (argbColor) & 0xFF
    grad := (alpha << 24) | (bb << 16) | (gg << 8) | rr

    accent := Buffer(16, 0)
    NumPut("Int", 4, accent, 0)
    NumPut("Int", 0, accent, 4)
    NumPut("Int", grad, accent, 8)
    NumPut("Int", 0, accent, 12)

    data := Buffer(A_PtrSize * 3, 0)
    NumPut("Int", 19, data, 0)
    NumPut("Ptr", accent.Ptr, data, A_PtrSize)
    NumPut("Int", accent.Size, data, A_PtrSize * 2)

    DllCall("user32\SetWindowCompositionAttribute", "ptr", hWnd, "ptr", data.Ptr, "int")
}

ApplyCornerPref(hWnd, pref) {
    buf := Buffer(4, 0)
    NumPut("Int", pref, buf, 0)
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hWnd, "int", 33, "ptr", buf.Ptr, "int", 4, "int")
}
