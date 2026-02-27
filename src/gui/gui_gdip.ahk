#Requires AutoHotkey v2.0

; D2D Resource Management — brushes, text formats, icon cache
; Replaces GDI+ resource management with Direct2D / DirectWrite equivalents.
; Function names preserve backward compatibility where cross-file callers exist.
#Warn VarUnset, Off

; ========================= D2D RESOURCE STATE =========================

global gD2D_Res := Map()         ; Named resources: brushes (ID2D1SolidColorBrush), text formats (IDWriteTextFormat)
global gD2D_ResScale := 0.0      ; Current resource scale (invalidated on DPI change)

; Dynamic brush cache: argb → ID2D1SolidColorBrush COM wrapper
; FIFO cap — working set is ~5-10 colors (UI palette).
; COM wrappers auto-release via __Delete when evicted.
global gD2D_BrushCache := Map()
global D2D_BRUSH_CACHE_MAX := 100

; Icon bitmap cache: hwnd → {hicon: number, bitmap: ID2D1Bitmap wrapper}
; Avoids re-converting HICON to D2D bitmap on every repaint.
; Naturally bounded by live window count — D2D_PruneIconCache removes
; entries for closed windows on each snapshot.
global gGdip_IconCache := Map()   ; Keep old name for compat with gui_data.ahk callers

; Legacy globals referenced by gui_paint.ahk timing diagnostics
global gGdip_ResScale := 0.0     ; Alias — kept for code that reads it

; ========================= D2D DRAW HELPERS =========================
; These replace the GDI+ Gdip_* draw functions used by gui_paint.ahk.
; All use the global gD2D_RT render target (set by gui_overlay.ahk).

; Fill a rounded rectangle. D2D has native support (no path cache needed).
D2D_FillRoundRect(x, y, w, h, r, brush) {
    global gD2D_RT
    if (w <= 0 || h <= 0 || !gD2D_RT)
        return
    if (r <= 0) {
        static rectBuf := Buffer(16)
        NumPut("float", Float(x), "float", Float(y),
               "float", Float(x + w), "float", Float(y + h), rectBuf)
        gD2D_RT.FillRectangle(rectBuf, brush)
        return
    }
    static rrBuf := Buffer(24)
    NumPut("float", Float(x), "float", Float(y),
           "float", Float(x + w), "float", Float(y + h),
           "float", Float(r), "float", Float(r), rrBuf)
    gD2D_RT.FillRoundedRectangle(rrBuf, brush)
}

; Stroke a rounded rectangle outline.
D2D_StrokeRoundRect(x, y, w, h, r, brush, strokeWidth) {
    global gD2D_RT
    if (w <= 0 || h <= 0 || !gD2D_RT)
        return
    static rrBuf := Buffer(24)
    NumPut("float", Float(x), "float", Float(y),
           "float", Float(x + w), "float", Float(y + h),
           "float", Float(r), "float", Float(r), rrBuf)
    gD2D_RT.DrawRoundedRectangle(rrBuf, brush, strokeWidth, 0)
}

; Draw text with left/near alignment (most common case).
D2D_DrawTextLeft(text, x, y, w, h, brush, tf) {
    global gD2D_RT, DWRITE_TEXT_ALIGNMENT_LEADING, DWRITE_PARAGRAPH_ALIGNMENT_NEAR
    global D2D1_DRAW_TEXT_OPTIONS_CLIP
    if (!gD2D_RT || !tf)
        return
    tf.SetTextAlignment(DWRITE_TEXT_ALIGNMENT_LEADING)
    tf.SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_NEAR)
    static rect := Buffer(16)
    NumPut("float", Float(x), "float", Float(y),
           "float", Float(x + w), "float", Float(y + h), rect)
    gD2D_RT.DrawText(text, tf, rect, brush, D2D1_DRAW_TEXT_OPTIONS_CLIP, 0)
}

; Draw text centered both horizontally and vertically.
D2D_DrawTextCentered(text, x, y, w, h, brush, tf) {
    global gD2D_RT, DWRITE_TEXT_ALIGNMENT_CENTER, DWRITE_PARAGRAPH_ALIGNMENT_CENTER
    global D2D1_DRAW_TEXT_OPTIONS_CLIP
    if (!gD2D_RT || !tf)
        return
    tf.SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER)
    tf.SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER)
    static rect := Buffer(16)
    NumPut("float", Float(x), "float", Float(y),
           "float", Float(x + w), "float", Float(y + h), rect)
    gD2D_RT.DrawText(text, tf, rect, brush, D2D1_DRAW_TEXT_OPTIONS_CLIP, 0)
}

; Fill ellipse. D2D ellipse uses center point + radii (not bounding box).
D2D_FillEllipse(x, y, w, h, brush) {
    global gD2D_RT
    if (!gD2D_RT)
        return
    cx := x + w / 2.0
    cy := y + h / 2.0
    rx := w / 2.0
    ry := h / 2.0
    static eBuf := Buffer(16)
    NumPut("float", Float(cx), "float", Float(cy),
           "float", Float(rx), "float", Float(ry), eBuf)
    gD2D_RT.FillEllipse(eBuf, brush)
}

; Fill rectangle.
D2D_FillRect(x, y, w, h, brush) {
    global gD2D_RT
    if (!gD2D_RT)
        return
    static rect := Buffer(16)
    NumPut("float", Float(x), "float", Float(y),
           "float", Float(x + w), "float", Float(y + h), rect)
    gD2D_RT.FillRectangle(rect, brush)
}


; Stroke a rectangle outline.
D2D_StrokeRect(x, y, w, h, brush, strokeWidth := 1.0) { ; lint-ignore: dead-function
    global gD2D_RT
    if (w <= 0 || h <= 0 || !gD2D_RT)
        return
    static rect := Buffer(16)
    NumPut("float", Float(x), "float", Float(y),
           "float", Float(x + w), "float", Float(y + h), rect)
    gD2D_RT.DrawRectangle(rect, brush, strokeWidth, 0)
}

; ========================= BRUSH CACHE =========================

; Get or create a cached D2D solid color brush for the given ARGB color.
; COM wrappers auto-release via __Delete when Map entries are evicted.
D2D_GetCachedBrush(argb) {
    global gD2D_BrushCache, D2D_BRUSH_CACHE_MAX, gD2D_RT
    if (gD2D_BrushCache.Has(argb))
        return gD2D_BrushCache[argb]
    if (!gD2D_RT)
        return 0
    ; FIFO eviction
    if (gD2D_BrushCache.Count >= D2D_BRUSH_CACHE_MAX) {
        for k, _ in gD2D_BrushCache {
            gD2D_BrushCache.Delete(k)  ; COM wrapper __Delete releases the brush
            break
        }
    }
    br := gD2D_RT.CreateSolidColorBrush(D2D_ColorF(argb))
    gD2D_BrushCache[argb] := br
    return br
}

; ========================= RESOURCE MANAGEMENT =========================

; Ensure D2D resources (brushes, text formats) exist at the current scale.
; Called before each paint. Recreates everything on scale change.
GUI_EnsureResources(scale) {
    Profiler.Enter("GUI_EnsureResources") ; @profile
    global gD2D_Res, gD2D_ResScale, gGdip_ResScale, gD2D_RT, gDW_Factory, cfg
    global gPaint_SessionPaintCount, gPaint_LastPaintTick
    global DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL
    global DWRITE_WORD_WRAPPING_NO_WRAP

    if (Abs(gD2D_ResScale - scale) < 0.001 && gD2D_Res.Count) {
        Profiler.Leave() ; @profile
        return
    }

    if (!gD2D_RT || !gDW_Factory) {
        Profiler.Leave() ; @profile
        return
    }

    ; Log resource recreation
    if (cfg.DiagPaintTimingLog) {
        idleDuration := (gPaint_LastPaintTick > 0) ? (A_TickCount - gPaint_LastPaintTick) : -1
        Paint_Log("  ** RECREATING D2D RESOURCES (oldScale=" gD2D_ResScale " newScale=" scale " resCount=" gD2D_Res.Count " idle=" (idleDuration > 0 ? Round(idleDuration/1000, 1) "s" : "first") ")")
    }

    tRes_Start := QPC()

    t1 := QPC()
    D2D_DisposeResources()
    tRes_Dispose := QPC() - t1

    ; Create brushes from render target
    t1 := QPC()
    brushes := [
        ["brMain", cfg.GUI_MainARGB],
        ["brMainHi", cfg.GUI_MainARGBHi],
        ["brSub", cfg.GUI_SubARGB],
        ["brSubHi", cfg.GUI_SubARGBHi],
        ["brCol", cfg.GUI_ColARGB],
        ["brColHi", cfg.GUI_ColARGBHi],
        ["brHdr", cfg.GUI_HdrARGB],
        ["brFooterText", cfg.GUI_FooterTextARGB]
    ]
    for _, b in brushes {
        gD2D_Res[b[1]] := gD2D_RT.CreateSolidColorBrush(D2D_ColorF(b[2]))
    }
    tRes_Brushes := QPC() - t1

    ; Create text formats from DWrite factory
    t1 := QPC()
    fonts := [
        ["tfMain", cfg.GUI_MainFontName, cfg.GUI_MainFontSize, cfg.GUI_MainFontWeight],
        ["tfMainHi", cfg.GUI_MainFontNameHi, cfg.GUI_MainFontSizeHi, cfg.GUI_MainFontWeightHi],
        ["tfSub", cfg.GUI_SubFontName, cfg.GUI_SubFontSize, cfg.GUI_SubFontWeight],
        ["tfSubHi", cfg.GUI_SubFontNameHi, cfg.GUI_SubFontSizeHi, cfg.GUI_SubFontWeightHi],
        ["tfCol", cfg.GUI_ColFontName, cfg.GUI_ColFontSize, cfg.GUI_ColFontWeight],
        ["tfColHi", cfg.GUI_ColFontNameHi, cfg.GUI_ColFontSizeHi, cfg.GUI_ColFontWeightHi],
        ["tfHdr", cfg.GUI_HdrFontName, cfg.GUI_HdrFontSize, cfg.GUI_HdrFontWeight],
        ["tfAction", cfg.GUI_ActionFontName, cfg.GUI_ActionFontSize, cfg.GUI_ActionFontWeight],
        ["tfFooter", cfg.GUI_FooterFontName, cfg.GUI_FooterFontSize, cfg.GUI_FooterFontWeight]
    ]
    for _, f in fonts {
        tf := gDW_Factory.CreateTextFormat(f[2], 0, f[4], DWRITE_FONT_STYLE_NORMAL,
            DWRITE_FONT_STRETCH_NORMAL, f[3] * scale, "en-us")
        if (tf) {
            tf.SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP)
            ; Set up ellipsis trimming (matches GDI+ GDIP_STRING_TRIMMING_ELLIPSIS)
            _D2D_SetEllipsisTrimming(tf)
        }
        gD2D_Res[f[1]] := tf
    }
    tRes_Fonts := QPC() - t1

    gD2D_ResScale := scale
    gGdip_ResScale := scale  ; Legacy alias

    ; Log resource recreation timing
    if (cfg.DiagPaintTimingLog) {
        tRes_Total := QPC() - tRes_Start
        Paint_Log("    D2D Resources: total=" Round(tRes_Total, 2) "ms | dispose=" Round(tRes_Dispose, 2) " brushes=" Round(tRes_Brushes, 2) " fonts=" Round(tRes_Fonts, 2))
    }
    Profiler.Leave() ; @profile
}

; Set ellipsis trimming on a DirectWrite text format.
_D2D_SetEllipsisTrimming(tf) {
    global gDW_Factory
    if (!gDW_Factory || !tf)
        return
    ; DWRITE_TRIMMING struct: { granularity (4), delimiter (4), delimiterCount (4) }
    ; granularity=2 = DWRITE_TRIMMING_GRANULARITY_CHARACTER
    trimOpts := Buffer(12, 0)
    NumPut("uint", 2, trimOpts, 0)
    try {
        ellipsis := gDW_Factory.CreateEllipsisTrimmingSign(tf)
        tf.SetTrimming(trimOpts, ellipsis)
    }
}

; Dispose all D2D resources. COM wrappers auto-release via __Delete.
D2D_DisposeResources() {
    global gD2D_Res, gD2D_ResScale, gGdip_ResScale, gD2D_BrushCache, gGdip_IconCache

    ; Clear named resources — COM wrapper __Delete releases each object
    gD2D_Res := Map()
    gD2D_ResScale := 0.0
    gGdip_ResScale := 0.0

    ; Clear dynamic brush cache
    gD2D_BrushCache := Map()

    ; Clear icon cache — D2D bitmap wrappers auto-release
    _D2D_ClearIconCache()
}

; ========================= ICON CACHE =========================

; Extract BGRA pixel data from HICON (preserving alpha channel).
; Returns {pixels: Buffer, w: int, h: int, stride: int} or 0 on failure.
_D2D_ExtractIconPixels(hIcon) {
    if (!hIcon)
        return 0

    ; Get icon info — gives us color bitmap and mask
    iiSize := 8 + A_PtrSize * 3
    ii := Buffer(iiSize, 0)
    if (!DllCall("user32\GetIconInfo", "ptr", hIcon, "ptr", ii.Ptr, "int"))
        return 0

    hbmMask := NumGet(ii, 8 + A_PtrSize, "ptr")
    hbmColor := NumGet(ii, 8 + A_PtrSize * 2, "ptr")

    if (!hbmColor) {
        if (hbmMask)
            DllCall("gdi32\DeleteObject", "ptr", hbmMask)
        return 0
    }

    ; Get bitmap dimensions
    bmSize := 24 + A_PtrSize
    bm := Buffer(bmSize, 0)
    if (!DllCall("gdi32\GetObjectW", "ptr", hbmColor, "int", bmSize, "ptr", bm.Ptr, "int")) {
        DllCall("gdi32\DeleteObject", "ptr", hbmColor)
        if (hbmMask)
            DllCall("gdi32\DeleteObject", "ptr", hbmMask)
        return 0
    }

    w := NumGet(bm, 4, "int")
    h := NumGet(bm, 8, "int")
    bpp := NumGet(bm, 18, "ushort")

    if (bpp != 32 || w <= 0 || h <= 0) {
        DllCall("gdi32\DeleteObject", "ptr", hbmColor)
        if (hbmMask)
            DllCall("gdi32\DeleteObject", "ptr", hbmMask)
        return 0
    }

    ; BITMAPINFOHEADER for GetDIBits (top-down, 32bpp)
    bih := Buffer(40, 0)
    NumPut("UInt", 40, bih, 0)
    NumPut("Int", w, bih, 4)
    NumPut("Int", -h, bih, 8)  ; Negative = top-down
    NumPut("UShort", 1, bih, 12)
    NumPut("UShort", 32, bih, 14)

    stride := w * 4
    pixelDataSize := stride * h
    pixels := Buffer(pixelDataSize, 0)

    hdc := DllCall("user32\GetDC", "ptr", 0, "ptr")
    result := DllCall("gdi32\GetDIBits", "ptr", hdc, "ptr", hbmColor, "uint", 0, "uint", h,
        "ptr", pixels.Ptr, "ptr", bih.Ptr, "uint", 0, "int")

    if (!result) {
        DllCall("user32\ReleaseDC", "ptr", 0, "ptr", hdc)
        DllCall("gdi32\DeleteObject", "ptr", hbmColor)
        if (hbmMask)
            DllCall("gdi32\DeleteObject", "ptr", hbmMask)
        return 0
    }

    ; Native alpha scan + mask application (via icon_alpha DLL)
    pixelCount := w * h
    hasAlpha := IconAlpha.ScanOnly(pixels, pixelCount)
    if (!hasAlpha && hbmMask) {
        maskPixels := Buffer(pixelDataSize)
        DllCall("gdi32\GetDIBits", "ptr", hdc, "ptr", hbmMask, "uint", 0, "uint", h,
            "ptr", maskPixels.Ptr, "ptr", bih.Ptr, "uint", 0, "int")
        IconAlpha.ApplyMaskOnly(pixels, maskPixels, pixelCount)
    }
    DllCall("user32\ReleaseDC", "ptr", 0, "ptr", hdc)

    ; Premultiply alpha for D2D (BGRA format, D2D expects premultiplied)
    _D2D_PremultiplyAlpha(pixels, pixelCount)

    DllCall("gdi32\DeleteObject", "ptr", hbmColor)
    if (hbmMask)
        DllCall("gdi32\DeleteObject", "ptr", hbmMask)

    return {pixels: pixels, w: w, h: h, stride: stride}
}

; Premultiply BGRA pixel data for D2D (which expects premultiplied alpha).
; For cached icons this runs once per icon — acceptable even at 256x256.
_D2D_PremultiplyAlpha(pixels, pixelCount) {
    loop pixelCount {
        offset := (A_Index - 1) * 4
        a := NumGet(pixels, offset + 3, "uchar")
        if (a = 0) {
            ; Fully transparent — zero all channels
            NumPut("uint", 0, pixels, offset)
        } else if (a < 255) {
            ; Semi-transparent — premultiply
            b := NumGet(pixels, offset, "uchar")
            g := NumGet(pixels, offset + 1, "uchar")
            r := NumGet(pixels, offset + 2, "uchar")
            NumPut("uchar", (b * a) // 255, pixels, offset)
            NumPut("uchar", (g * a) // 255, pixels, offset + 1)
            NumPut("uchar", (r * a) // 255, pixels, offset + 2)
        }
        ; a=255: fully opaque — no change needed
    }
}

; Create a D2D bitmap from HICON pixel data.
_D2D_CreateBitmapFromPixels(iconData) {
    global gD2D_RT, DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED
    if (!gD2D_RT || !iconData)
        return 0
    sizeU := D2D_SizeU(iconData.w, iconData.h)
    bitmapProps := D2D_BitmapProps(96.0, 96.0, DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED)
    try {
        bitmap := gD2D_RT.CreateBitmap(sizeU, iconData.pixels.Ptr, iconData.stride, bitmapProps)
        return bitmap
    }
    return 0
}

; Eagerly convert HICON to D2D bitmap and cache it, without drawing.
; Called when icons are resolved so the bitmap is ready before paint.
; Backward-compatible name for gui_data.ahk callers.
Gdip_PreCacheIcon(hwnd, hIcon) {
    global gGdip_IconCache, gD2D_RT
    if (!hIcon || !gD2D_RT)
        return

    ; Already cached with same hIcon — nothing to do
    cached := gGdip_IconCache.Get(hwnd, 0)
    if (cached && cached.hicon = hIcon && cached.bitmap)
        return

    ; Extract pixel data and create D2D bitmap
    iconData := _D2D_ExtractIconPixels(hIcon)
    if (!iconData)
        return
    bitmap := _D2D_CreateBitmapFromPixels(iconData)
    gGdip_IconCache[hwnd] := {hicon: hIcon, bitmap: bitmap}
}

; Draw icon with caching — avoids HICON→D2D bitmap conversion on every frame.
; Parameters: &wasCacheHit — set to true/false for logging
D2D_DrawCachedIcon(hwnd, hIcon, x, y, size, &wasCacheHit := "") {
    global gGdip_IconCache, gD2D_RT

    if (!hIcon || !gD2D_RT) {
        wasCacheHit := false
        return false
    }

    ; Check cache — O(1) lookup
    if (gGdip_IconCache.Has(hwnd)) {
        cached := gGdip_IconCache[hwnd]
        if (cached.hicon = hIcon && cached.bitmap) {
            static destRect := Buffer(16)
            NumPut("float", Float(x), "float", Float(y),
                   "float", Float(x + size), "float", Float(y + size), destRect)
            gD2D_RT.DrawBitmap(cached.bitmap, destRect, 1.0, 1, 0)
            wasCacheHit := true
            return true
        }
    }

    ; Cache miss — extract and cache
    wasCacheHit := false
    iconData := _D2D_ExtractIconPixels(hIcon)
    if (!iconData) {
        gGdip_IconCache[hwnd] := {hicon: hIcon, bitmap: 0}
        return false
    }
    bitmap := _D2D_CreateBitmapFromPixels(iconData)
    if (!bitmap) {
        gGdip_IconCache[hwnd] := {hicon: hIcon, bitmap: 0}
        return false
    }
    gGdip_IconCache[hwnd] := {hicon: hIcon, bitmap: bitmap}

    static destRect2 := Buffer(16)
    NumPut("float", Float(x), "float", Float(y),
           "float", Float(x + size), "float", Float(y + size), destRect2)
    gD2D_RT.DrawBitmap(bitmap, destRect2, 1.0, 1, 0)
    return true
}

; Clear entire icon cache (call on shutdown or render target recreation).
_D2D_ClearIconCache() {
    global gGdip_IconCache
    ; COM wrappers auto-release via __Delete when Map is cleared
    gGdip_IconCache := Map()
}

; Prune icon cache entries for hwnds not in the live items map.
; Backward-compatible name for gui_data.ahk callers.
Gdip_PruneIconCache(liveHwnds) {
    global gGdip_IconCache

    if (!gGdip_IconCache.Count)
        return

    ; Two-pass: collect stale keys first (can't delete during AHK v2 Map iteration)
    stale := []
    for hwnd, _ in gGdip_IconCache {
        if (!liveHwnds.Has(hwnd))
            stale.Push(hwnd)
    }

    for _, hwnd in stale {
        gGdip_IconCache.Delete(hwnd)  ; COM wrapper __Delete releases the bitmap
    }
}

; ========================= LEGACY COMPAT =========================

; No-op — D2D factories are initialized in GUI_CreateWindow (gui_overlay.ahk).
; Backward-compatible for gui_main.ahk callers.
Gdip_Startup() {
    return 1
}

; Shutdown D2D resources. Backward-compatible for gui_main.ahk callers.
Gdip_Shutdown() {
    D2D_DisposeResources()
    ; Render target + factory cleanup handled by _D2D_ShutdownAll in gui_overlay.ahk
}
