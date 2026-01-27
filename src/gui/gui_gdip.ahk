#Requires AutoHotkey v2.0

; GDI+ Helper Functions for GUI rendering

; Global GDI+ state
global gGdip_Token := 0
global gGdip_G := 0
global gGdip_BackHdc := 0
global gGdip_BackHBM := 0
global gGdip_BackPrev := 0
global gGdip_BackW := 0
global gGdip_BackH := 0
global gGdip_CurScale := 1.0
global gGdip_ResScale := 0.0
global gGdip_Res := Map()

; Icon bitmap cache: hwnd -> {hicon: number, pBmp: GDI+ bitmap ptr}
; Avoids re-converting HICON to GDI+ bitmap on every repaint
global gGdip_IconCache := Map()

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
    Gdip_ClearIconCache()

    ; Clean cached brushes/fonts
    Gdip_DisposeResources()

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
    global gGdip_BackHdc, gGdip_BackHBM, gGdip_BackPrev, gGdip_BackW, gGdip_BackH, gGdip_G

    if (!gGdip_BackHdc) {
        gGdip_BackHdc := DllCall("gdi32\CreateCompatibleDC", "ptr", 0, "ptr")
        if (gGdip_G) {
            try DllCall("gdiplus\GdipDeleteGraphics", "ptr", gGdip_G)
            gGdip_G := 0
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

    bi := Buffer(40, 0)
    NumPut("UInt", 40, bi, 0)
    NumPut("Int", wPhys, bi, 4)
    NumPut("Int", -hPhys, bi, 8)
    NumPut("UShort", 1, bi, 12)
    NumPut("UShort", 32, bi, 14)
    NumPut("UInt", 0, bi, 16)

    pvBits := 0
    gGdip_BackHBM := DllCall("gdi32\CreateDIBSection", "ptr", gGdip_BackHdc, "ptr", bi.Ptr, "uint", 0, "ptr*", &pvBits, "ptr", 0, "uint", 0, "ptr")
    gGdip_BackPrev := DllCall("gdi32\SelectObject", "ptr", gGdip_BackHdc, "ptr", gGdip_BackHBM, "ptr")

    if (gGdip_G) {
        try DllCall("gdiplus\GdipDeleteGraphics", "ptr", gGdip_G)
        gGdip_G := 0
    }

    gGdip_BackW := wPhys
    gGdip_BackH := hPhys
}

; Get or create Graphics object
Gdip_EnsureGraphics() {
    global gGdip_BackHdc, gGdip_G

    if (!gGdip_BackHdc) {
        return 0
    }

    if (gGdip_G) {
        try DllCall("gdiplus\GdipDeleteGraphics", "ptr", gGdip_G)
        gGdip_G := 0
    }

    DllCall("gdiplus\GdipCreateFromHDC", "ptr", gGdip_BackHdc, "ptr*", &gGdip_G)
    if (!gGdip_G) {
        return 0
    }

    DllCall("gdiplus\GdipSetSmoothingMode", "ptr", gGdip_G, "int", 4)
    DllCall("gdiplus\GdipSetTextRenderingHint", "ptr", gGdip_G, "int", 5)
    return gGdip_G
}

; Get font style from weight
Gdip_FontStyleFromWeight(w) {
    if (w >= 600) {
        return 1  ; Bold
    }
    return 0  ; Regular
}

; Dispose all cached GDI+ resources
Gdip_DisposeResources() {
    global gGdip_Res, gGdip_ResScale

    if (!gGdip_Res.Count) {
        gGdip_ResScale := 0.0
        return
    }

    brushKeys := ["brMain", "brMainHi", "brSub", "brSubHi", "brCol", "brColHi", "brHdr", "brHit", "brFooterText"]
    for _, k in brushKeys {
        if (gGdip_Res.Has(k) && gGdip_Res[k]) {
            DllCall("gdiplus\GdipDeleteBrush", "ptr", gGdip_Res[k])
        }
    }

    fontKeys := ["fMain", "fMainHi", "fSub", "fSubHi", "fCol", "fColHi", "fHdr", "fAction", "fFooter"]
    for _, k in fontKeys {
        if (gGdip_Res.Has(k) && gGdip_Res[k]) {
            DllCall("gdiplus\GdipDeleteFont", "ptr", gGdip_Res[k])
        }
    }

    famKeys := ["ffMain", "ffMainHi", "ffSub", "ffSubHi", "ffCol", "ffColHi", "ffHdr", "ffAction", "ffFooter"]
    for _, k in famKeys {
        if (gGdip_Res.Has(k) && gGdip_Res[k]) {
            DllCall("gdiplus\GdipDeleteFontFamily", "ptr", gGdip_Res[k])
        }
    }

    fmtKeys := ["fmt", "fmtCenter", "fmtRight", "fmtLeft", "fmtLeftCol", "fmtFooterLeft", "fmtFooterCenter", "fmtFooterRight"]
    for _, k in fmtKeys {
        if (gGdip_Res.Has(k) && gGdip_Res[k]) {
            DllCall("gdiplus\GdipDeleteStringFormat", "ptr", gGdip_Res[k])
        }
    }

    gGdip_Res := Map()
    gGdip_ResScale := 0.0
}

; Fill rounded rectangle
Gdip_FillRoundRect(g, argb, x, y, w, h, r) {
    if (w <= 0 || h <= 0) {
        return
    }

    if (r <= 0) {
        pBr := 0
        DllCall("gdiplus\GdipCreateSolidFill", "int", argb, "ptr*", &pBr)
        DllCall("gdiplus\GdipFillRectangle", "ptr", g, "ptr", pBr, "float", x, "float", y, "float", w, "float", h)
        if (pBr) {
            DllCall("gdiplus\GdipDeleteBrush", "ptr", pBr)
        }
        return
    }

    pPath := 0
    pBr := 0
    r2 := r * 2.0

    DllCall("gdiplus\GdipCreatePath", "int", 0, "ptr*", &pPath)
    DllCall("gdiplus\GdipAddPathArc", "ptr", pPath, "float", x, "float", y, "float", r2, "float", r2, "float", 180.0, "float", 90.0)
    DllCall("gdiplus\GdipAddPathLine", "ptr", pPath, "float", x + r, "float", y, "float", x + w - r, "float", y)
    DllCall("gdiplus\GdipAddPathArc", "ptr", pPath, "float", x + w - r2, "float", y, "float", r2, "float", r2, "float", 270.0, "float", 90.0)
    DllCall("gdiplus\GdipAddPathLine", "ptr", pPath, "float", x + w, "float", y + r, "float", x + w, "float", y + h - r)
    DllCall("gdiplus\GdipAddPathArc", "ptr", pPath, "float", x + w - r2, "float", y + h - r2, "float", r2, "float", r2, "float", 0.0, "float", 90.0)
    DllCall("gdiplus\GdipAddPathLine", "ptr", pPath, "float", x + w - r, "float", y + h, "float", x + r, "float", y + h)
    DllCall("gdiplus\GdipAddPathArc", "ptr", pPath, "float", x, "float", y + h - r2, "float", r2, "float", r2, "float", 90.0, "float", 90.0)
    DllCall("gdiplus\GdipClosePathFigure", "ptr", pPath)

    DllCall("gdiplus\GdipCreateSolidFill", "int", argb, "ptr*", &pBr)
    DllCall("gdiplus\GdipFillPath", "ptr", g, "ptr", pBr, "ptr", pPath)

    if (pBr) {
        DllCall("gdiplus\GdipDeleteBrush", "ptr", pBr)
    }
    if (pPath) {
        DllCall("gdiplus\GdipDeletePath", "ptr", pPath)
    }
}

; Stroke rounded rectangle
Gdip_StrokeRoundRect(g, argb, x, y, w, h, r, strokeWidth := 1) {
    if (w <= 0 || h <= 0) {
        return
    }

    pPath := 0
    pPen := 0
    r2 := r * 2.0

    DllCall("gdiplus\GdipCreatePath", "int", 0, "ptr*", &pPath)
    DllCall("gdiplus\GdipAddPathArc", "ptr", pPath, "float", x, "float", y, "float", r2, "float", r2, "float", 180.0, "float", 90.0)
    DllCall("gdiplus\GdipAddPathLine", "ptr", pPath, "float", x + r, "float", y, "float", x + w - r, "float", y)
    DllCall("gdiplus\GdipAddPathArc", "ptr", pPath, "float", x + w - r2, "float", y, "float", r2, "float", r2, "float", 270.0, "float", 90.0)
    DllCall("gdiplus\GdipAddPathLine", "ptr", pPath, "float", x + w, "float", y + r, "float", x + w, "float", y + h - r)
    DllCall("gdiplus\GdipAddPathArc", "ptr", pPath, "float", x + w - r2, "float", y + h - r2, "float", r2, "float", r2, "float", 0.0, "float", 90.0)
    DllCall("gdiplus\GdipAddPathLine", "ptr", pPath, "float", x + w - r, "float", y + h, "float", x + r, "float", y + h)
    DllCall("gdiplus\GdipAddPathArc", "ptr", pPath, "float", x, "float", y + h - r2, "float", r2, "float", r2, "float", 90.0, "float", 90.0)
    DllCall("gdiplus\GdipClosePathFigure", "ptr", pPath)

    DllCall("gdiplus\GdipCreatePen1", "int", argb, "float", strokeWidth, "int", 2, "ptr*", &pPen)
    DllCall("gdiplus\GdipDrawPath", "ptr", g, "ptr", pPen, "ptr", pPath)

    if (pPen) {
        DllCall("gdiplus\GdipDeletePen", "ptr", pPen)
    }
    if (pPath) {
        DllCall("gdiplus\GdipDeletePath", "ptr", pPath)
    }
}

; Draw text
Gdip_DrawText(g, text, x, y, w, h, br, font, fmt) {
    rf := Buffer(16, 0)
    NumPut("Float", x, rf, 0)
    NumPut("Float", y, rf, 4)
    NumPut("Float", w, rf, 8)
    NumPut("Float", h, rf, 12)
    DllCall("gdiplus\GdipDrawString", "ptr", g, "wstr", text, "int", -1, "ptr", font, "ptr", rf.Ptr, "ptr", fmt, "ptr", br)
}

; Draw centered text in rectangle
Gdip_DrawCenteredText(g, text, x, y, w, h, argb, font, fmtCenter) {
    rf := Buffer(16, 0)
    NumPut("Float", x, rf, 0)
    NumPut("Float", y, rf, 4)
    NumPut("Float", w, rf, 8)
    NumPut("Float", h, rf, 12)
    br := 0
    DllCall("gdiplus\GdipCreateSolidFill", "int", argb, "ptr*", &br)
    DllCall("gdiplus\GdipDrawString", "ptr", g, "wstr", text, "int", -1, "ptr", font, "ptr", rf.Ptr, "ptr", fmtCenter, "ptr", br)
    if (br) {
        DllCall("gdiplus\GdipDeleteBrush", "ptr", br)
    }
}

; Fill ellipse
Gdip_FillEllipse(g, argb, x, y, w, h) {
    pBr := 0
    DllCall("gdiplus\GdipCreateSolidFill", "int", argb, "ptr*", &pBr)
    DllCall("gdiplus\GdipFillEllipse", "ptr", g, "ptr", pBr, "float", x, "float", y, "float", w, "float", h)
    if (pBr) {
        DllCall("gdiplus\GdipDeleteBrush", "ptr", pBr)
    }
}

; Draw icon from HICON (uncached - used internally)
Gdip_DrawIconFromHicon(g, hIcon, x, y, size) {
    if (!hIcon || !g) {
        return false
    }

    pBmp := 0
    DllCall("gdiplus\GdipCreateBitmapFromHICON", "ptr", hIcon, "ptr*", &pBmp)
    if (!pBmp) {
        return false
    }

    DllCall("gdiplus\GdipDrawImageRectI", "ptr", g, "ptr", pBmp, "int", x, "int", y, "int", size, "int", size)
    DllCall("gdiplus\GdipDisposeImage", "ptr", pBmp)
    return true
}

; Draw icon with caching - avoids HICON->Bitmap conversion on every frame
; Cache key is hwnd; invalidates if hIcon value changes
; Note: hIcon from Store works cross-process (USER objects in win32k.sys shared memory)
Gdip_DrawCachedIcon(g, hwnd, hIcon, x, y, size) {
    global gGdip_IconCache

    if (!hIcon || !g) {
        return false
    }

    ; Check cache - O(1) lookup
    if (gGdip_IconCache.Has(hwnd)) {
        cached := gGdip_IconCache[hwnd]
        ; Cache hit - verify hIcon hasn't changed
        if (cached.hicon = hIcon && cached.pBmp) {
            DllCall("gdiplus\GdipDrawImageRectI", "ptr", g, "ptr", cached.pBmp, "int", x, "int", y, "int", size, "int", size)
            return true
        }
        ; hIcon changed - dispose old bitmap
        if (cached.pBmp) {
            try DllCall("gdiplus\GdipDisposeImage", "ptr", cached.pBmp)
        }
    }

    ; Cache miss or stale - convert and cache
    pBmp := 0
    DllCall("gdiplus\GdipCreateBitmapFromHICON", "ptr", hIcon, "ptr*", &pBmp)
    if (!pBmp) {
        ; Conversion failed - remove from cache if present
        if (gGdip_IconCache.Has(hwnd))
            gGdip_IconCache.Delete(hwnd)
        return false
    }

    ; Store in cache
    gGdip_IconCache[hwnd] := {hicon: hIcon, pBmp: pBmp}

    ; Draw
    DllCall("gdiplus\GdipDrawImageRectI", "ptr", g, "ptr", pBmp, "int", x, "int", y, "int", size, "int", size)
    return true
}

; Invalidate cache entry for a specific hwnd (call when window removed)
Gdip_InvalidateIconCache(hwnd) {
    global gGdip_IconCache

    if (!gGdip_IconCache.Has(hwnd))
        return

    cached := gGdip_IconCache[hwnd]
    if (cached.pBmp) {
        try DllCall("gdiplus\GdipDisposeImage", "ptr", cached.pBmp)
    }
    gGdip_IconCache.Delete(hwnd)
}

; Clear entire icon cache (call on shutdown or major state reset)
Gdip_ClearIconCache() {
    global gGdip_IconCache

    for hwnd, cached in gGdip_IconCache {
        if (cached.pBmp) {
            try DllCall("gdiplus\GdipDisposeImage", "ptr", cached.pBmp)
        }
    }
    gGdip_IconCache := Map()
}

; Generate color from index (fallback when no icon)
Gdip_ARGBFromIndex(i) {
    r := (37 * i) & 0xFF
    g := (71 * i) & 0xFF
    b := (113 * i) & 0xFF
    return (0xCC << 24) | (r << 16) | (g << 8) | b
}

; Clear graphics surface
Gdip_Clear(g, argb := 0x00000000) {
    DllCall("gdiplus\GdipGraphicsClear", "ptr", g, "int", argb)
}

; Fill rectangle
Gdip_FillRect(g, br, x, y, w, h) {
    DllCall("gdiplus\GdipFillRectangle", "ptr", g, "ptr", br, "float", x, "float", y, "float", w, "float", h)
}
