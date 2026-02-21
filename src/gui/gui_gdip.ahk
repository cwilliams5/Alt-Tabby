#Requires AutoHotkey v2.0

; GDI+ Helper Functions for GUI rendering

; Global GDI+ state
global gGdip_Token := 0
global gGdip_G := 0
global gGdip_GraphicsHdc := 0      ; HDC the Graphics was created from (for cache validation)
global gGdip_BackHdc := 0
global gGdip_BackHBM := 0
global gGdip_BackPrev := 0
global gGdip_BackW := 0
global gGdip_BackH := 0
global gGdip_ResScale := 0.0
global gGdip_Res := Map()

; Icon bitmap cache: hwnd -> {hicon: number, pBmp: GDI+ bitmap ptr}
; Avoids re-converting HICON to GDI+ bitmap on every repaint
global gGdip_IconCache := Map()

; Dynamic brush/pen caches: auto-populated on first use, cleared on shutdown/scale change
global gGdip_BrushCache := Map()   ; argb -> pBrush
global gGdip_PenCache := Map()     ; "argb_width" -> pPen

; Cache eviction limits (FIFO) to prevent unbounded memory growth
global GDIP_BRUSH_CACHE_MAX := 100
global GDIP_PEN_CACHE_MAX := 100

; Rounded rectangle path cache: "w|h|r" -> pPath (built at origin 0,0)
; FIFO cap — working set is ~5-8 unique (w,h,r) tuples per frame
global GDIP_PATH_CACHE_MAX := 50
global gGdip_PathCache := Map()

; Resource type registry: maps gGdip_Res key names to their GDI+ delete function.
; Single source of truth — used by both GUI_EnsureResources (creation) and _Gdip_DisposeResources (cleanup).
; When adding a new resource, add its key here and it will be cleaned up automatically.
global GDIP_RES_TYPES := Map()
GDIP_RES_TYPES.Set(
    "brush",      ["brMain", "brMainHi", "brSub", "brSubHi", "brCol", "brColHi", "brHdr", "brHit", "brFooterText"],
    "font",       ["fMain", "fMainHi", "fSub", "fSubHi", "fCol", "fColHi", "fHdr", "fAction", "fFooter"],
    "fontFamily", ["ffMain", "ffMainHi", "ffSub", "ffSubHi", "ffCol", "ffColHi", "ffHdr", "ffAction", "ffFooter"],
    "strFormat",  ["fmt", "fmtCenter", "fmtRight", "fmtLeft", "fmtLeftCol", "fmtFooterLeft", "fmtFooterCenter", "fmtFooterRight"]
)

; Pre-built BLENDFUNCTION for UpdateLayeredWindow (AC_SRC_OVER, fully opaque, AC_SRC_ALPHA).
; Shared across gui_paint and gui_overlay to avoid duplication.
Gdip_GetBlendFunction() {
    static bf := Buffer(4, 0)
    static _init := (NumPut("UChar", 0, bf, 0),     ; BlendOp: AC_SRC_OVER
                     NumPut("UChar", 0, bf, 1),      ; BlendFlags: reserved
                     NumPut("UChar", 255, bf, 2),    ; SourceConstantAlpha: fully opaque
                     NumPut("UChar", 0x01, bf, 3))   ; AlphaFormat: AC_SRC_ALPHA
    return bf
}

; Start GDI+
Gdip_Startup() {
    global gGdip_Token
    if (gGdip_Token) {
        return gGdip_Token
    }
    si := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
    NumPut("UInt", 1, si, 0)
    status := DllCall("gdiplus\GdiplusStartup", "ptr*", &gGdip_Token, "ptr", si.Ptr, "ptr", 0, "int")
    if (status = 0 && gGdip_Token) {
        return gGdip_Token
    }
    return 0
}

; Shutdown GDI+ and clean up all resources
Gdip_Shutdown() {
    global gGdip_Token, gGdip_G, gGdip_BackHdc, gGdip_BackHBM, gGdip_BackPrev

    ; Clean icon cache first (before GDI+ shutdown)
    _Gdip_ClearIconCache()

    ; Clean cached brushes/fonts
    _Gdip_DisposeResources()

    ; Delete graphics object
    if (gGdip_G) {
        try DllCall("gdiplus\GdipDeleteGraphics", "ptr", gGdip_G)
        gGdip_G := 0
    }

    ; Clean up backbuffer
    if (gGdip_BackHBM) {
        if (gGdip_BackHdc && gGdip_BackPrev)
            try DllCall("gdi32\SelectObject", "ptr", gGdip_BackHdc, "ptr", gGdip_BackPrev)
        try DllCall("gdi32\DeleteObject", "ptr", gGdip_BackHBM)
        gGdip_BackHBM := 0
    }
    if (gGdip_BackHdc) {
        try DllCall("gdi32\DeleteDC", "ptr", gGdip_BackHdc)
        gGdip_BackHdc := 0
    }

    ; Shutdown GDI+ token last
    if (gGdip_Token) {
        try DllCall("gdiplus\GdiplusShutdown", "uptr", gGdip_Token)
        gGdip_Token := 0
    }
}

; Ensure backbuffer exists at specified size
Gdip_EnsureBackbuffer(wPhys, hPhys) {
    global gGdip_BackHdc, gGdip_BackHBM, gGdip_BackPrev, gGdip_BackW, gGdip_BackH, gGdip_G, gGdip_GraphicsHdc

    if (!gGdip_BackHdc) {
        gGdip_BackHdc := DllCall("gdi32\CreateCompatibleDC", "ptr", 0, "ptr")
        if (gGdip_G) {
            try DllCall("gdiplus\GdipDeleteGraphics", "ptr", gGdip_G)
            gGdip_G := 0
            gGdip_GraphicsHdc := 0
        }
    }

    if (wPhys < 1) {
        wPhys := 1
    }
    if (hPhys < 1) {
        hPhys := 1
    }

    if (wPhys = gGdip_BackW && hPhys = gGdip_BackH && gGdip_BackHBM) {
        return
    }

    if (gGdip_BackHBM) {
        DllCall("gdi32\SelectObject", "ptr", gGdip_BackHdc, "ptr", gGdip_BackPrev, "ptr")
        DllCall("gdi32\DeleteObject", "ptr", gGdip_BackHBM)
        gGdip_BackHBM := 0
    }

    bi := _Gdip_CreateBitmapInfoHeader(wPhys, hPhys)

    pvBits := 0
    gGdip_BackHBM := DllCall("gdi32\CreateDIBSection", "ptr", gGdip_BackHdc, "ptr", bi.Ptr, "uint", 0, "ptr*", &pvBits, "ptr", 0, "uint", 0, "ptr")
    gGdip_BackPrev := DllCall("gdi32\SelectObject", "ptr", gGdip_BackHdc, "ptr", gGdip_BackHBM, "ptr")

    if (gGdip_G) {
        try DllCall("gdiplus\GdipDeleteGraphics", "ptr", gGdip_G)
        gGdip_G := 0
        gGdip_GraphicsHdc := 0
    }

    gGdip_BackW := wPhys
    gGdip_BackH := hPhys
}

; Get or create Graphics object (cached when HDC unchanged)
; The Graphics object is reused as long as the backbuffer HDC hasn't changed.
; When backbuffer is reallocated (size change), gGdip_G is cleared by Gdip_EnsureBackbuffer().
Gdip_EnsureGraphics() {
    global gGdip_BackHdc, gGdip_G, gGdip_GraphicsHdc

    if (!gGdip_BackHdc) {
        return 0
    }

    ; Cache hit: Graphics still valid for current HDC (saves 4 DllCalls per frame)
    if (gGdip_G && gGdip_GraphicsHdc = gGdip_BackHdc) {
        return gGdip_G
    }

    ; Cache miss: HDC changed or no Graphics exists - recreate
    if (gGdip_G) {
        try DllCall("gdiplus\GdipDeleteGraphics", "ptr", gGdip_G)
        gGdip_G := 0
    }

    global GDIP_SMOOTHING_ANTIALIAS, GDIP_TEXT_RENDER_ANTIALIAS_GRIDFIT

    DllCall("gdiplus\GdipCreateFromHDC", "ptr", gGdip_BackHdc, "ptr*", &gGdip_G)
    if (!gGdip_G) {
        gGdip_GraphicsHdc := 0
        return 0
    }

    DllCall("gdiplus\GdipSetSmoothingMode", "ptr", gGdip_G, "int", GDIP_SMOOTHING_ANTIALIAS)
    DllCall("gdiplus\GdipSetTextRenderingHint", "ptr", gGdip_G, "int", GDIP_TEXT_RENDER_ANTIALIAS_GRIDFIT)
    gGdip_GraphicsHdc := gGdip_BackHdc
    return gGdip_G
}

; Get font style from weight
_Gdip_FontStyleFromWeight(w) {
    if (w >= 600) {
        return 1  ; Bold
    }
    return 0  ; Regular
}

; Dispose all cached GDI+ resources
_Gdip_DisposeResources() {
    global gGdip_Res, gGdip_ResScale, gGdip_BrushCache, gGdip_PenCache, gGdip_PathCache, gGdip_G, gGdip_GraphicsHdc, GDIP_RES_TYPES

    ; Delete and invalidate cached Graphics object (force recreation on next EnsureGraphics call)
    ; Must delete before clearing pointer to prevent leak
    if (gGdip_G) {
        try DllCall("gdiplus\GdipDeleteGraphics", "ptr", gGdip_G)
        gGdip_G := 0
    }
    gGdip_GraphicsHdc := 0

    ; Always clear dynamic brush/pen caches (independent of gGdip_Res)
    for _, pBr in gGdip_BrushCache {
        if (pBr)
            DllCall("gdiplus\GdipDeleteBrush", "ptr", pBr)
    }
    gGdip_BrushCache := Map()
    for _, pPen in gGdip_PenCache {
        if (pPen)
            DllCall("gdiplus\GdipDeletePen", "ptr", pPen)
    }
    gGdip_PenCache := Map()

    ; Clear path cache (geometry depends on scale/layout, must rebuild)
    for _, pPath in gGdip_PathCache {
        if (pPath)
            try DllCall("gdiplus\GdipDeletePath", "ptr", pPath)
    }
    gGdip_PathCache := Map()

    if (!gGdip_Res.Count) {
        gGdip_ResScale := 0.0
        return
    }

    ; Delete resources by type using the shared GDIP_RES_TYPES registry.
    ; Keeps cleanup in sync with creation — add new keys to the registry, not here.
    static deleteFns := Map(
        "brush",      "gdiplus\GdipDeleteBrush",
        "font",       "gdiplus\GdipDeleteFont",
        "fontFamily", "gdiplus\GdipDeleteFontFamily",
        "strFormat",  "gdiplus\GdipDeleteStringFormat"
    )
    for resType, keys in GDIP_RES_TYPES {
        fn := deleteFns[resType]
        for _, k in keys {
            if (gGdip_Res.Has(k) && gGdip_Res[k])
                DllCall(fn, "ptr", gGdip_Res[k])
        }
    }

    gGdip_Res := Map()
    gGdip_ResScale := 0.0
}

; ========================= RESOURCE MANAGEMENT =========================

GUI_EnsureResources(scale) {
    Profiler.Enter("GUI_EnsureResources") ; @profile
    global gGdip_Res, gGdip_ResScale, cfg
    global gPaint_SessionPaintCount, gPaint_LastPaintTick
    global GDIP_UNIT_PIXEL, GDIP_STRING_ALIGN_NEAR, GDIP_STRING_ALIGN_CENTER, GDIP_STRING_ALIGN_FAR
    global GDIP_STRING_FORMAT_NO_WRAP, GDIP_STRING_FORMAT_LINE_LIMIT, GDIP_STRING_TRIMMING_ELLIPSIS

    if (Abs(gGdip_ResScale - scale) < 0.001 && gGdip_Res.Count) {
        ; Resources exist and scale unchanged - skip recreation
        Profiler.Leave() ; @profile
        return
    }

    ; Log resource recreation (this is potentially slow)
    if (cfg.DiagPaintTimingLog) {
        idleDuration := (gPaint_LastPaintTick > 0) ? (A_TickCount - gPaint_LastPaintTick) : -1
        Paint_Log("  ** RECREATING RESOURCES (oldScale=" gGdip_ResScale " newScale=" scale " resCount=" gGdip_Res.Count " idle=" (idleDuration > 0 ? Round(idleDuration/1000, 1) "s" : "first") ")")
    }

    tRes_Start := QPC()

    t1 := QPC()
    _Gdip_DisposeResources()
    tRes_Dispose := QPC() - t1

    t1 := QPC()
    Gdip_Startup()
    tRes_Startup := QPC() - t1

    ; Brushes
    t1 := QPC()
    brushes := [
        ["brMain", cfg.GUI_MainARGB],
        ["brMainHi", cfg.GUI_MainARGBHi],
        ["brSub", cfg.GUI_SubARGB],
        ["brSubHi", cfg.GUI_SubARGBHi],
        ["brCol", cfg.GUI_ColARGB],
        ["brColHi", cfg.GUI_ColARGBHi],
        ["brHdr", cfg.GUI_HdrARGB],
        ; brHit: Nearly transparent black (alpha=0x01) for hit-test background.
        ; Fully transparent (0x00) would make the window click-through.
        ["brHit", 0x01000000],
        ["brFooterText", cfg.GUI_FooterTextARGB]
    ]
    for _, b in brushes {
        br := 0
        DllCall("gdiplus\GdipCreateSolidFill", "int", b[2], "ptr*", &br)
        gGdip_Res[b[1]] := br
    }
    tRes_Brushes := QPC() - t1

    ; Fonts
    t1 := QPC()

    fonts := [
        [cfg.GUI_MainFontName, cfg.GUI_MainFontSize, cfg.GUI_MainFontWeight, "ffMain", "fMain"],
        [cfg.GUI_MainFontNameHi, cfg.GUI_MainFontSizeHi, cfg.GUI_MainFontWeightHi, "ffMainHi", "fMainHi"],
        [cfg.GUI_SubFontName, cfg.GUI_SubFontSize, cfg.GUI_SubFontWeight, "ffSub", "fSub"],
        [cfg.GUI_SubFontNameHi, cfg.GUI_SubFontSizeHi, cfg.GUI_SubFontWeightHi, "ffSubHi", "fSubHi"],
        [cfg.GUI_ColFontName, cfg.GUI_ColFontSize, cfg.GUI_ColFontWeight, "ffCol", "fCol"],
        [cfg.GUI_ColFontNameHi, cfg.GUI_ColFontSizeHi, cfg.GUI_ColFontWeightHi, "ffColHi", "fColHi"],
        [cfg.GUI_HdrFontName, cfg.GUI_HdrFontSize, cfg.GUI_HdrFontWeight, "ffHdr", "fHdr"],
        [cfg.GUI_ActionFontName, cfg.GUI_ActionFontSize, cfg.GUI_ActionFontWeight, "ffAction", "fAction"],
        [cfg.GUI_FooterFontName, cfg.GUI_FooterFontSize, cfg.GUI_FooterFontWeight, "ffFooter", "fFooter"]
    ]
    for _, f in fonts {
        fam := 0
        font := 0
        style := _Gdip_FontStyleFromWeight(f[3])
        DllCall("gdiplus\GdipCreateFontFamilyFromName", "wstr", f[1], "ptr", 0, "ptr*", &fam)
        DllCall("gdiplus\GdipCreateFont", "ptr", fam, "float", f[2] * scale, "int", style, "int", GDIP_UNIT_PIXEL, "ptr*", &font)
        gGdip_Res[f[4]] := fam
        gGdip_Res[f[5]] := font
    }
    tRes_Fonts := QPC() - t1

    ; String formats
    t1 := QPC()
    fmtFlags := GDIP_STRING_FORMAT_NO_WRAP | GDIP_STRING_FORMAT_LINE_LIMIT

    formats := [
        ["fmt", GDIP_STRING_ALIGN_NEAR, GDIP_STRING_ALIGN_NEAR],
        ["fmtCenter", GDIP_STRING_ALIGN_CENTER, GDIP_STRING_ALIGN_NEAR],
        ["fmtRight", GDIP_STRING_ALIGN_FAR, GDIP_STRING_ALIGN_NEAR],
        ["fmtLeft", GDIP_STRING_ALIGN_NEAR, GDIP_STRING_ALIGN_NEAR],
        ["fmtLeftCol", GDIP_STRING_ALIGN_NEAR, GDIP_STRING_ALIGN_NEAR],
        ["fmtFooterLeft", GDIP_STRING_ALIGN_NEAR, GDIP_STRING_ALIGN_CENTER],
        ["fmtFooterCenter", GDIP_STRING_ALIGN_CENTER, GDIP_STRING_ALIGN_CENTER],
        ["fmtFooterRight", GDIP_STRING_ALIGN_FAR, GDIP_STRING_ALIGN_CENTER]
    ]
    for _, fm in formats {
        fmt := 0
        DllCall("gdiplus\GdipCreateStringFormat", "int", 0, "ushort", 0, "ptr*", &fmt)
        DllCall("gdiplus\GdipSetStringFormatFlags", "ptr", fmt, "int", fmtFlags)
        DllCall("gdiplus\GdipSetStringFormatTrimming", "ptr", fmt, "int", GDIP_STRING_TRIMMING_ELLIPSIS)
        DllCall("gdiplus\GdipSetStringFormatAlign", "ptr", fmt, "int", fm[2])
        DllCall("gdiplus\GdipSetStringFormatLineAlign", "ptr", fmt, "int", fm[3])
        gGdip_Res[fm[1]] := fmt
    }
    tRes_Formats := QPC() - t1

    gGdip_ResScale := scale

    ; Log resource recreation timing
    if (cfg.DiagPaintTimingLog) {
        tRes_Total := QPC() - tRes_Start
        Paint_Log("    Resources: total=" Round(tRes_Total, 2) "ms | dispose=" Round(tRes_Dispose, 2) " startup=" Round(tRes_Startup, 2) " brushes=" Round(tRes_Brushes, 2) " fonts=" Round(tRes_Fonts, 2) " formats=" Round(tRes_Formats, 2))
    }
    Profiler.Leave() ; @profile
}

; Evict oldest entry from a FIFO cache (Map iteration order = insertion order).
_Gdip_EvictOldest(cache, maxCount, deleteFunc) {
    if (cache.Count >= maxCount) {
        for k, v in cache {
            if (v)
                try DllCall("gdiplus\" deleteFunc, "ptr", v)
            cache.Delete(k)
            break
        }
    }
}

; Get or create a cached solid brush for the given ARGB color
; FIFO cap at 100: working set is ~5-10 colors (UI palette), cap is 10-20x headroom.
; No liveness signal to prune by (a color is "in use" only during paint), so FIFO is appropriate here.
Gdip_GetCachedBrush(argb) {
    global gGdip_BrushCache, GDIP_BRUSH_CACHE_MAX
    if (gGdip_BrushCache.Has(argb))
        return gGdip_BrushCache[argb]
    _Gdip_EvictOldest(gGdip_BrushCache, GDIP_BRUSH_CACHE_MAX, "GdipDeleteBrush")
    pBr := 0
    DllCall("gdiplus\GdipCreateSolidFill", "int", argb, "ptr*", &pBr)
    gGdip_BrushCache[argb] := pBr
    return pBr
}

; Get or create a cached pen for the given ARGB color and width
; FIFO cap at 100: working set is ~3-5 pen styles, cap is 20-33x headroom.
; No liveness signal to prune by, so FIFO is appropriate here.
Gdip_GetCachedPen(argb, width) {
    global gGdip_PenCache, GDIP_PEN_CACHE_MAX
    key := argb "_" width
    if (gGdip_PenCache.Has(key))
        return gGdip_PenCache[key]
    _Gdip_EvictOldest(gGdip_PenCache, GDIP_PEN_CACHE_MAX, "GdipDeletePen")
    pPen := 0
    DllCall("gdiplus\GdipCreatePen1", "int", argb, "float", width, "int", 2, "ptr*", &pPen)
    gGdip_PenCache[key] := pPen
    return pPen
}

; ========================= CACHED ROUND RECT PATH =========================

; Get or create a cached GDI+ path for the given (w, h, r) at origin (0,0).
; Callers translate via GdipTranslateWorldTransform before filling/drawing.
; FIFO cap at 50: working set is ~5-8 unique (w,h,r) tuples.
_Gdip_GetCachedRoundRectPath(w, h, r) {
    global gGdip_PathCache, GDIP_PATH_CACHE_MAX
    key := w "|" h "|" r
    if (gGdip_PathCache.Has(key))
        return gGdip_PathCache[key]
    _Gdip_EvictOldest(gGdip_PathCache, GDIP_PATH_CACHE_MAX, "GdipDeletePath")
    ; Build path at origin (0, 0)
    pPath := 0
    r2 := r * 2.0
    DllCall("gdiplus\GdipCreatePath", "int", 0, "ptr*", &pPath)
    DllCall("gdiplus\GdipAddPathArc", "ptr", pPath, "float", 0, "float", 0, "float", r2, "float", r2, "float", 180.0, "float", 90.0)
    DllCall("gdiplus\GdipAddPathLine", "ptr", pPath, "float", r, "float", 0, "float", w - r, "float", 0)
    DllCall("gdiplus\GdipAddPathArc", "ptr", pPath, "float", w - r2, "float", 0, "float", r2, "float", r2, "float", 270.0, "float", 90.0)
    DllCall("gdiplus\GdipAddPathLine", "ptr", pPath, "float", w, "float", r, "float", w, "float", h - r)
    DllCall("gdiplus\GdipAddPathArc", "ptr", pPath, "float", w - r2, "float", h - r2, "float", r2, "float", r2, "float", 0.0, "float", 90.0)
    DllCall("gdiplus\GdipAddPathLine", "ptr", pPath, "float", w - r, "float", h, "float", r, "float", h)
    DllCall("gdiplus\GdipAddPathArc", "ptr", pPath, "float", 0, "float", h - r2, "float", r2, "float", r2, "float", 90.0, "float", 90.0)
    DllCall("gdiplus\GdipClosePathFigure", "ptr", pPath)
    gGdip_PathCache[key] := pPath
    return pPath
}

; Fill rounded rectangle using cached path + world transform translation.
; 3 DllCalls per call (translate + fill + reset) vs 11 for uncached version.
Gdip_FillRoundRectCached(g, pBr, x, y, w, h, r) {
    if (w <= 0 || h <= 0)
        return
    if (r <= 0) {
        DllCall("gdiplus\GdipFillRectangle", "ptr", g, "ptr", pBr, "float", x, "float", y, "float", w, "float", h)
        return
    }
    pPath := _Gdip_GetCachedRoundRectPath(w, h, r)
    DllCall("gdiplus\GdipTranslateWorldTransform", "ptr", g, "float", x, "float", y, "int", 0)
    DllCall("gdiplus\GdipFillPath", "ptr", g, "ptr", pBr, "ptr", pPath)
    DllCall("gdiplus\GdipResetWorldTransform", "ptr", g)
}

; Stroke rounded rectangle using cached path + world transform translation.
; 3 DllCalls per call (translate + draw + reset) vs 12 for uncached version.
Gdip_StrokeRoundRectCached(g, pPen, x, y, w, h, r) {
    if (w <= 0 || h <= 0)
        return
    pPath := _Gdip_GetCachedRoundRectPath(w, h, r)
    DllCall("gdiplus\GdipTranslateWorldTransform", "ptr", g, "float", x, "float", y, "int", 0)
    DllCall("gdiplus\GdipDrawPath", "ptr", g, "ptr", pPen, "ptr", pPath)
    DllCall("gdiplus\GdipResetWorldTransform", "ptr", g)
}

; Draw text
Gdip_DrawText(g, text, x, y, w, h, br, font, fmt) {
    static rf := Buffer(16, 0)  ; static: reused per-call, repopulated before each DllCall
    NumPut("Float", x, rf, 0)
    NumPut("Float", y, rf, 4)
    NumPut("Float", w, rf, 8)
    NumPut("Float", h, rf, 12)
    DllCall("gdiplus\GdipDrawString", "ptr", g, "wstr", text, "int", -1, "ptr", font, "ptr", rf.Ptr, "ptr", fmt, "ptr", br)
}

; Draw centered text in rectangle (pBr = pre-cached brush pointer)
Gdip_DrawCenteredText(g, text, x, y, w, h, pBr, font, fmtCenter) {
    static rf := Buffer(16, 0)  ; static: reused per-call, repopulated before each DllCall
    NumPut("Float", x, rf, 0)
    NumPut("Float", y, rf, 4)
    NumPut("Float", w, rf, 8)
    NumPut("Float", h, rf, 12)
    DllCall("gdiplus\GdipDrawString", "ptr", g, "wstr", text, "int", -1, "ptr", font, "ptr", rf.Ptr, "ptr", fmtCenter, "ptr", pBr)
}

; Fill ellipse (pBr = pre-cached brush pointer)
Gdip_FillEllipse(g, pBr, x, y, w, h) {
    DllCall("gdiplus\GdipFillEllipse", "ptr", g, "ptr", pBr, "float", x, "float", y, "float", w, "float", h)
}

; Convert HICON to GDI+ Bitmap preserving alpha channel
; GdipCreateBitmapFromHICON flattens alpha to 0/255, losing semi-transparency.
; This function extracts raw pixel data and preserves the full alpha channel.
_Gdip_CreateBitmapFromHICON_Alpha(hIcon) {
    if (!hIcon)
        return 0

    ; Get icon info - gives us color bitmap and mask
    ; ICONINFO: fIcon(4) + xHotspot(4) + yHotspot(4) + hbmMask(ptr) + hbmColor(ptr)
    iiSize := 8 + A_PtrSize * 3
    ii := Buffer(iiSize, 0)
    if (!DllCall("user32\GetIconInfo", "ptr", hIcon, "ptr", ii.Ptr, "int"))
        return 0

    hbmMask := NumGet(ii, 8 + A_PtrSize, "ptr")
    hbmColor := NumGet(ii, 8 + A_PtrSize * 2, "ptr")

    ; We need hbmColor for 32-bit icons
    if (!hbmColor) {
        if (hbmMask)
            DllCall("gdi32\DeleteObject", "ptr", hbmMask)
        return 0
    }

    ; Get bitmap dimensions via BITMAP structure
    ; BITMAP: bmType(4) + bmWidth(4) + bmHeight(4) + bmWidthBytes(4) + bmPlanes(2) + bmBitsPixel(2) + bmBits(ptr)
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

    ; Only handle 32-bit icons with this method
    if (bpp != 32 || w <= 0 || h <= 0) {
        DllCall("gdi32\DeleteObject", "ptr", hbmColor)
        if (hbmMask)
            DllCall("gdi32\DeleteObject", "ptr", hbmMask)
        ; Fall back to standard method for non-32bit icons
        pBmp := 0
        DllCall("gdiplus\GdipCreateBitmapFromHICON", "ptr", hIcon, "ptr*", &pBmp)
        return pBmp
    }

    ; Set up BITMAPINFOHEADER for GetDIBits (top-down, 32bpp, BI_RGB)
    bih := _Gdip_CreateBitmapInfoHeader(w, h)

    ; Allocate buffer for pixel data (BGRA format, 4 bytes per pixel)
    stride := w * 4
    pixelDataSize := stride * h
    pixels := Buffer(pixelDataSize, 0)

    ; Get device context and extract pixel data
    hdc := DllCall("user32\GetDC", "ptr", 0, "ptr")
    result := DllCall("gdi32\GetDIBits", "ptr", hdc, "ptr", hbmColor, "uint", 0, "uint", h, "ptr", pixels.Ptr, "ptr", bih.Ptr, "uint", 0, "int")
    DllCall("user32\ReleaseDC", "ptr", 0, "ptr", hdc)

    if (!result) {
        DllCall("gdi32\DeleteObject", "ptr", hbmColor)
        if (hbmMask)
            DllCall("gdi32\DeleteObject", "ptr", hbmMask)
        return 0
    }

    ; Native alpha scan + mask application (replaces AHK NumGet/NumPut loops)
    ; Source: icon_alpha.c — 250-550x faster than AHK loops
    pixelCount := w * h
    hasAlpha := IconAlpha.ScanOnly(pixels, pixelCount)
    if (!hasAlpha && hbmMask) {
        ; Get mask bitmap data (request 32-bit for easier processing)
        maskBih := _Gdip_CreateBitmapInfoHeader(w, h)
        maskPixels := Buffer(pixelDataSize, 0)
        hdc := DllCall("user32\GetDC", "ptr", 0, "ptr")
        DllCall("gdi32\GetDIBits", "ptr", hdc, "ptr", hbmMask, "uint", 0, "uint", h, "ptr", maskPixels.Ptr, "ptr", maskBih.Ptr, "uint", 0, "int")
        DllCall("user32\ReleaseDC", "ptr", 0, "ptr", hdc)
        ; Apply mask natively (no redundant re-scan)
        IconAlpha.ApplyMaskOnly(pixels, maskPixels, pixelCount)
    }

    ; Create GDI+ bitmap with GDI+ owning the memory (scan0 = 0)
    global GDIP_PIXEL_FORMAT_32BPP_ARGB, GDIP_IMAGE_LOCK_WRITE
    pBmp := 0
    status := DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", w, "int", h, "int", 0, "int", GDIP_PIXEL_FORMAT_32BPP_ARGB, "ptr", 0, "ptr*", &pBmp, "int")

    if (status != 0 || !pBmp) {
        DllCall("gdi32\DeleteObject", "ptr", hbmColor)
        if (hbmMask)
            DllCall("gdi32\DeleteObject", "ptr", hbmMask)
        return 0
    }

    ; Lock bitmap to get write access to GDI+'s internal pixel buffer
    ; BitmapData: Width(4) + Height(4) + Stride(4) + PixelFormat(4) + Scan0(ptr) + Reserved(ptr)
    bd := Buffer(16 + A_PtrSize * 2, 0)
    rect := Buffer(16, 0)
    NumPut("int", 0, rect, 0)   ; x
    NumPut("int", 0, rect, 4)   ; y
    NumPut("int", w, rect, 8)   ; width
    NumPut("int", h, rect, 12)  ; height

    status := DllCall("gdiplus\GdipBitmapLockBits", "ptr", pBmp, "ptr", rect.Ptr, "uint", GDIP_IMAGE_LOCK_WRITE, "int", GDIP_PIXEL_FORMAT_32BPP_ARGB, "ptr", bd.Ptr, "int")

    if (status != 0) {
        DllCall("gdiplus\GdipDisposeImage", "ptr", pBmp)
        DllCall("gdi32\DeleteObject", "ptr", hbmColor)
        if (hbmMask)
            DllCall("gdi32\DeleteObject", "ptr", hbmMask)
        return 0
    }

    ; Get scan0 pointer and stride from BitmapData
    gdipStride := NumGet(bd, 8, "int")
    scan0 := NumGet(bd, 16, "ptr")

    ; Copy our pixel data into GDI+'s buffer
    if (gdipStride = stride) {
        ; Same stride - single memcpy
        DllCall("msvcrt\memcpy", "ptr", scan0, "ptr", pixels.Ptr, "uptr", pixelDataSize)
    } else {
        ; Different stride - copy row by row
        loop h {
            srcOffset := (A_Index - 1) * stride
            dstOffset := (A_Index - 1) * gdipStride
            DllCall("msvcrt\memcpy", "ptr", scan0 + dstOffset, "ptr", pixels.Ptr + srcOffset, "uptr", w * 4)
        }
    }

    ; Unlock bitmap - now it owns a copy of our data
    DllCall("gdiplus\GdipBitmapUnlockBits", "ptr", pBmp, "ptr", bd.Ptr)

    ; Clean up source bitmaps
    DllCall("gdi32\DeleteObject", "ptr", hbmColor)
    if (hbmMask)
        DllCall("gdi32\DeleteObject", "ptr", hbmMask)

    return pBmp
}

; Eagerly convert HICON to GDI+ bitmap and cache it, without drawing.
; Called when icons are resolved so the bitmap is ready before paint.
; Pre-caching prevents grey circles: the store may DestroyIcon after sending a
; replacement, but the GUI's cached GDI+ bitmap (created here while the HICON
; was still valid) survives independently.
Gdip_PreCacheIcon(hwnd, hIcon) {
    global gGdip_IconCache
    if (!hIcon)
        return

    ; Already cached with same hIcon - nothing to do
    if (gGdip_IconCache.Has(hwnd)) {
        cached := gGdip_IconCache[hwnd]
        if (cached.hicon = hIcon && cached.pBmp)
            return
        ; hIcon changed - dispose old bitmap
        if (cached.pBmp)
            try DllCall("gdiplus\GdipDisposeImage", "ptr", cached.pBmp)
    }

    ; Convert HICON to GDI+ bitmap while the handle is still valid
    pBmp := _Gdip_CreateBitmapFromHICON_Alpha(hIcon)

    ; No FIFO eviction — cache grows with live window count.
    ; Gdip_PruneIconCache cleans up entries for closed windows after every snapshot.
    gGdip_IconCache[hwnd] := {hicon: hIcon, pBmp: pBmp}
}

; Draw icon with caching - avoids HICON->Bitmap conversion on every frame
; Cache key is hwnd; invalidates if hIcon value changes
; Note: hIcon from pump works cross-process (USER objects in win32k.sys shared memory)
; Parameters:
;   &wasCacheHit - Optional ByRef: set to true if cache hit, false otherwise (for logging)
Gdip_DrawCachedIcon(g, hwnd, hIcon, x, y, size, &wasCacheHit := "") {
    global gGdip_IconCache

    if (!hIcon || !g) {
        wasCacheHit := false
        return false
    }

    ; Check cache - O(1) lookup
    if (gGdip_IconCache.Has(hwnd)) {
        cached := gGdip_IconCache[hwnd]
        ; Cache hit - verify hIcon hasn't changed and pBmp exists
        if (cached.hicon = hIcon && cached.pBmp) {
            DllCall("gdiplus\GdipDrawImageRectI", "ptr", g, "ptr", cached.pBmp, "int", x, "int", y, "int", size, "int", size)
            wasCacheHit := true
            return true
        }
        ; hIcon changed - dispose old bitmap
        if (cached.pBmp) {
            try DllCall("gdiplus\GdipDisposeImage", "ptr", cached.pBmp)
        }
    }

    ; Cache miss or stale - convert with alpha preservation and cache
    wasCacheHit := false
    pBmp := _Gdip_CreateBitmapFromHICON_Alpha(hIcon)
    if (!pBmp) {
        ; Conversion failed - cache the failure to prevent repeated attempts
        gGdip_IconCache[hwnd] := {hicon: hIcon, pBmp: 0}
        return false
    }

    ; No FIFO eviction — cache grows with live window count.
    ; Gdip_PruneIconCache cleans up entries for closed windows after every snapshot.
    gGdip_IconCache[hwnd] := {hicon: hIcon, pBmp: pBmp}

    ; Draw
    DllCall("gdiplus\GdipDrawImageRectI", "ptr", g, "ptr", pBmp, "int", x, "int", y, "int", size, "int", size)
    return true
}

; Clear entire icon cache (call on shutdown or major state reset)
_Gdip_ClearIconCache() {
    global gGdip_IconCache

    for _, cached in gGdip_IconCache {
        if (cached.pBmp) {
            try DllCall("gdiplus\GdipDisposeImage", "ptr", cached.pBmp)
        }
    }
    gGdip_IconCache := Map()
}

; Prune icon cache entries for hwnds not in the live items map.
; Call after snapshot replacement to remove orphaned GDI+ bitmaps.
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
        cached := gGdip_IconCache[hwnd]
        if (cached.pBmp)
            try DllCall("gdiplus\GdipDisposeImage", "ptr", cached.pBmp)
        gGdip_IconCache.Delete(hwnd)
    }
}

; Clear graphics surface
Gdip_Clear(g, argb := 0x00000000) {
    DllCall("gdiplus\GdipGraphicsClear", "ptr", g, "int", argb)
}

; Create a top-down 32bpp BITMAPINFOHEADER buffer
_Gdip_CreateBitmapInfoHeader(w, h) {
    global BITMAPINFOHEADER_SIZE, BPP_32
    bi := Buffer(BITMAPINFOHEADER_SIZE, 0)
    NumPut("UInt", BITMAPINFOHEADER_SIZE, bi, 0)
    NumPut("Int", w, bi, 4)
    NumPut("Int", -h, bi, 8)
    NumPut("UShort", 1, bi, 12)
    NumPut("UShort", BPP_32, bi, 14)
    NumPut("UInt", 0, bi, 16)
    return bi
}

; Fill rectangle
Gdip_FillRect(g, br, x, y, w, h) {
    DllCall("gdiplus\GdipFillRectangle", "ptr", g, "ptr", br, "float", x, "float", y, "float", w, "float", h)
}
