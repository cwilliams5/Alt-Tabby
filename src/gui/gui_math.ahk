#Requires AutoHotkey v2.0
; Math helpers shared between gui_win.ahk and tests
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals/functions

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

; Shared layout metrics cache - used by gui_paint.ahk and gui_input.ahk
; Only recalculates when scale changes (avoids 13+ Round() calls per frame)
GUI_GetCachedLayout(scale) {
    global cfg
    global PAINT_HDR_Y_DIP, PAINT_TITLE_Y_DIP, PAINT_TITLE_H_DIP
    global PAINT_SUB_Y_DIP, PAINT_SUB_H_DIP, PAINT_COL_Y_DIP, PAINT_COL_H_DIP

    static cached := {}, cachedScale := 0.0
    if (Abs(cachedScale - scale) < 0.001)
        return cached

    cached := {}
    cached.RowH := Round(cfg.GUI_RowHeight * scale)
    if (cached.RowH < 1)
        cached.RowH := 1
    cached.Mx := Round(cfg.GUI_MarginX * scale)
    cached.My := Round(cfg.GUI_MarginY * scale)
    cached.ISize := Round(cfg.GUI_IconSize * scale)
    cached.Rad := Round(cfg.GUI_RowRadius * scale)
    cached.gapText := Round(cfg.GUI_IconTextGapPx * scale)
    cached.gapCols := Round(cfg.GUI_ColumnGapPx * scale)
    cached.hdrY4 := Round(PAINT_HDR_Y_DIP * scale)
    cached.hdrH28 := Round(cfg.GUI_HeaderHeightPx * scale)
    cached.iconLeftDip := Round(cfg.GUI_IconLeftMargin * scale)
    cached.titleY := Round(PAINT_TITLE_Y_DIP * scale)
    cached.titleH := Round(PAINT_TITLE_H_DIP * scale)
    cached.subY := Round(PAINT_SUB_Y_DIP * scale)
    cached.subH := Round(PAINT_SUB_H_DIP * scale)
    cached.colY := Round(PAINT_COL_Y_DIP * scale)
    cached.colH := Round(PAINT_COL_H_DIP * scale)
    cached.hdrBlock := Round(GUI_HeaderBlockDip() * scale)
    cachedScale := scale
    return cached
}
