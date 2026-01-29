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

; Dynamic brush/pen caches: auto-populated on first use, cleared on shutdown/scale change
global gGdip_BrushCache := Map()   ; argb -> pBrush
global gGdip_PenCache := Map()     ; "argb_width" -> pPen

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
    global gGdip_Res, gGdip_ResScale, gGdip_BrushCache, gGdip_PenCache

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

; Get or create a cached solid brush for the given ARGB color
Gdip_GetCachedBrush(argb) {
    global gGdip_BrushCache
    if (gGdip_BrushCache.Has(argb))
        return gGdip_BrushCache[argb]
    pBr := 0
    DllCall("gdiplus\GdipCreateSolidFill", "int", argb, "ptr*", &pBr)
    gGdip_BrushCache[argb] := pBr
    return pBr
}

; Get or create a cached pen for the given ARGB color and width
Gdip_GetCachedPen(argb, width) {
    global gGdip_PenCache
    key := argb "_" width
    if (gGdip_PenCache.Has(key))
        return gGdip_PenCache[key]
    pPen := 0
    DllCall("gdiplus\GdipCreatePen1", "int", argb, "float", width, "int", 2, "ptr*", &pPen)
    gGdip_PenCache[key] := pPen
    return pPen
}

; Fill rounded rectangle (pBr = pre-cached brush pointer)
Gdip_FillRoundRect(g, pBr, x, y, w, h, r) {
    if (w <= 0 || h <= 0) {
        return
    }

    if (r <= 0) {
        DllCall("gdiplus\GdipFillRectangle", "ptr", g, "ptr", pBr, "float", x, "float", y, "float", w, "float", h)
        return
    }

    pPath := 0
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

    DllCall("gdiplus\GdipFillPath", "ptr", g, "ptr", pBr, "ptr", pPath)

    if (pPath) {
        DllCall("gdiplus\GdipDeletePath", "ptr", pPath)
    }
}

; Stroke rounded rectangle (pPen = pre-cached pen pointer)
Gdip_StrokeRoundRect(g, pPen, x, y, w, h, r) {
    if (w <= 0 || h <= 0) {
        return
    }

    pPath := 0
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

    DllCall("gdiplus\GdipDrawPath", "ptr", g, "ptr", pPen, "ptr", pPath)

    if (pPath) {
        DllCall("gdiplus\GdipDeletePath", "ptr", pPath)
    }
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

; Draw icon from HICON (uncached - used internally)
Gdip_DrawIconFromHicon(g, hIcon, x, y, size) {
    if (!hIcon || !g) {
        return false
    }

    pBmp := _Gdip_CreateBitmapFromHICON_Alpha(hIcon)
    if (!pBmp) {
        return false
    }

    DllCall("gdiplus\GdipDrawImageRectI", "ptr", g, "ptr", pBmp, "int", x, "int", y, "int", size, "int", size)
    DllCall("gdiplus\GdipDisposeImage", "ptr", pBmp)
    return true
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

    ; Set up BITMAPINFOHEADER for GetDIBits
    ; Size=40, Width, Height (negative for top-down), Planes=1, BitCount=32, Compression=BI_RGB
    bih := Buffer(40, 0)
    NumPut("uint", 40, bih, 0)          ; biSize
    NumPut("int", w, bih, 4)            ; biWidth
    NumPut("int", -h, bih, 8)           ; biHeight (negative = top-down DIB)
    NumPut("ushort", 1, bih, 12)        ; biPlanes
    NumPut("ushort", 32, bih, 14)       ; biBitCount
    NumPut("uint", 0, bih, 16)          ; biCompression = BI_RGB

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

    ; Scan pixels to check if icon has real alpha channel
    ; (some 32-bit icons have all alpha=0 and rely on mask instead)
    ; Early exit: any non-zero alpha means icon has alpha channel
    hasAlpha := false
    loop pixelDataSize // 4 {
        if (NumGet(pixels, (A_Index - 1) * 4 + 3, "uchar") > 0) {
            hasAlpha := true
            break
        }
    }

    ; If no alpha detected, we need to use the mask to determine transparency
    if (!hasAlpha && hbmMask) {
        ; Get mask bitmap data
        maskBih := Buffer(40, 0)
        NumPut("uint", 40, maskBih, 0)
        NumPut("int", w, maskBih, 4)
        NumPut("int", -h, maskBih, 8)
        NumPut("ushort", 1, maskBih, 12)
        NumPut("ushort", 32, maskBih, 14)  ; Request 32-bit for easier processing
        NumPut("uint", 0, maskBih, 16)

        maskPixels := Buffer(pixelDataSize, 0)
        hdc := DllCall("user32\GetDC", "ptr", 0, "ptr")
        DllCall("gdi32\GetDIBits", "ptr", hdc, "ptr", hbmMask, "uint", 0, "uint", h, "ptr", maskPixels.Ptr, "ptr", maskBih.Ptr, "uint", 0, "int")
        DllCall("user32\ReleaseDC", "ptr", 0, "ptr", hdc)

        ; Apply mask: where mask is white (0xFFFFFF), pixel is transparent
        loop pixelDataSize // 4 {
            offset := (A_Index - 1) * 4
            maskVal := NumGet(maskPixels, offset, "uint") & 0xFFFFFF
            if (maskVal = 0) {
                ; Mask is black = opaque
                NumPut("uchar", 255, pixels, offset + 3)
            } else {
                ; Mask is white = transparent
                NumPut("uchar", 0, pixels, offset + 3)
            }
        }
    }

    ; Create GDI+ bitmap with GDI+ owning the memory (scan0 = 0)
    ; PixelFormat32bppARGB = 0x26200A
    pBmp := 0
    status := DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", w, "int", h, "int", 0, "int", 0x26200A, "ptr", 0, "ptr*", &pBmp, "int")

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

    ; ImageLockModeWrite = 2
    status := DllCall("gdiplus\GdipBitmapLockBits", "ptr", pBmp, "ptr", rect.Ptr, "uint", 2, "int", 0x26200A, "ptr", bd.Ptr, "int")

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

    ; Cache miss or stale - convert with alpha preservation and cache
    pBmp := _Gdip_CreateBitmapFromHICON_Alpha(hIcon)
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
