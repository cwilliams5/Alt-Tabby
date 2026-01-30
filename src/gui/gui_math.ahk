#Requires AutoHotkey v2.0
; Math helpers shared between gui_win.ahk and tests

; Wrap value 0 to count-1
Win_Wrap0(i, count) {
    if (count <= 0) {
        return 0
    }
    r := Mod(i, count)
    if (r < 0) {
        r := r + count
    }
    return r
}

; Wrap value 1 to count
Win_Wrap1(i, count) {
    if (count <= 0) {
        return 0
    }
    r := Mod(i - 1, count)
    if (r < 0) {
        r := r + count
    }
    return r + 1
}
