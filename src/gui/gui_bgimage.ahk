#Requires AutoHotkey v2.0

; ============================================================
; Background Image Layer
; ============================================================
; Renders a user-selectable background image in the overlay
; compositing stack. Sits above the shader layer and below
; backdrop effects. Supports fit modes, alignment, opacity,
; blur, desaturation, and brightness.
;
; PERF: The image+effects produce identical pixels every frame.
; We pre-render once to a cached bitmap (via SetTarget), then
; blit it per-frame with a single DrawBitmap call. The cache
; is invalidated on init, config change, or overlay resize.
; ============================================================

; --- Globals (all owned by this file) ---
global gBGImg_Bitmap := 0         ; ID2D1Bitmap of loaded source image (0 if none)
global gBGImg_TileBrush := 0      ; ID2D1BitmapBrush for Tile mode (0 if not Tile)
global gBGImg_Width := 0           ; Natural pixel width of source
global gBGImg_Height := 0          ; Natural pixel height of source
global gBGImg_Ready := false       ; True when source bitmap loaded and valid
global gBGImg_EffectsReady := false ; Set by gui_effects.ahk after effect creation

; --- Cache state ---
global gBGImg_Cache := 0          ; ID2D1Bitmap1 — pre-rendered result at overlay size
global gBGImg_CacheW := 0         ; Width the cache was rendered at
global gBGImg_CacheH := 0         ; Height the cache was rendered at
global gBGImg_CacheDirty := true   ; True when cache needs rebuild
global gBGImg_GdipToken := 0      ; GDI+ startup token (one-shot for image file loading)

; ============================================================
; PUBLIC API
; ============================================================

; Load image from config path. Called from FX_GPU_Init().
BGImg_Init() {
    global cfg, gBGImg_Ready, gBGImg_CacheDirty, LOG_PATH_STORE
    try LogAppend(LOG_PATH_STORE, "BGImg_Init: enabled=" cfg.BGImgEnabled " path='" cfg.BGImgImagePath "'")
    if (!cfg.BGImgEnabled || cfg.BGImgImagePath = "")
        return
    _BGImg_LoadImage(cfg.BGImgImagePath)
    try LogAppend(LOG_PATH_STORE, "BGImg_Init: after load, ready=" gBGImg_Ready)
    gBGImg_CacheDirty := true
}

; Ensure the cache bitmap exists at the correct size. Called BEFORE BeginDraw
; because D2D does not allow resource creation during a draw session.
BGImg_EnsureCache(wPhys, hPhys) {
    global gBGImg_Ready, gBGImg_CacheW, gBGImg_CacheH, gBGImg_CacheDirty, gD2D_RT
    if (!gBGImg_Ready || !gD2D_RT)
        return

    ; Invalidate cache if overlay size changed
    if (wPhys != gBGImg_CacheW || hPhys != gBGImg_CacheH)
        gBGImg_CacheDirty := true

    if (gBGImg_CacheDirty)
        _BGImg_RebuildCache(wPhys, hPhys)
}

; Render the background image layer. Called from _GUI_PaintOverlay() (inside BeginDraw/EndDraw).
; Hot path: one DrawBitmap from the pre-rendered cache.
BGImg_Draw() {
    global gBGImg_Ready, gBGImg_Cache, gD2D_RT, cfg

    if (!gBGImg_Ready || !gD2D_RT || !gBGImg_Cache)
        return

    opacity := cfg.BGImgOpacity
    if (opacity <= 0.0)
        return

    ; Single DrawBitmap blit — destRect=0 means full target, srcRect=0 means full source
    gD2D_RT.DrawBitmap(gBGImg_Cache, 0, opacity, 1, 0)
}

; Release all resources. Called from FX_GPU_Dispose().
BGImg_Dispose() {
    global gBGImg_Bitmap, gBGImg_TileBrush, gBGImg_TileBrushInterp, gBGImg_Ready
    global gBGImg_Width, gBGImg_Height, gBGImg_EffectsReady
    global gBGImg_Cache, gBGImg_CacheW, gBGImg_CacheH, gBGImg_CacheDirty
    gBGImg_Cache := 0        ; COM __Delete releases
    gBGImg_CacheW := 0
    gBGImg_CacheH := 0
    gBGImg_CacheDirty := true
    gBGImg_TileBrush := 0    ; COM __Delete releases
    gBGImg_TileBrushInterp := -1
    gBGImg_Bitmap := 0       ; COM __Delete releases
    gBGImg_Width := 0
    gBGImg_Height := 0
    gBGImg_Ready := false
    gBGImg_EffectsReady := false
    ; GDI+ token intentionally kept alive — no need to shut down/restart for reload
}

; ============================================================
; PRIVATE — Cache Management
; ============================================================

; Render the fully-composited image (with effects) to gBGImg_Cache.
; Uses D2D1.1 SetTarget to redirect drawing to an offscreen bitmap.
; This runs ONCE per config/size change, not per frame.
_BGImg_RebuildCache(wPhys, hPhys) {
    global gD2D_RT, gBGImg_Cache, gBGImg_CacheW, gBGImg_CacheH, gBGImg_CacheDirty
    global gBGImg_Ready, gBGImg_EffectsReady, cfg

    ; Release old cache
    gBGImg_Cache := 0

    if (!gBGImg_Ready || !gD2D_RT)
        return

    try {
        ; Create target-capable bitmap at overlay resolution
        ; D2D1_BITMAP_PROPERTIES1 (32 bytes on x64):
        ;   pixelFormat (8B), dpiX (4B), dpiY (4B), bitmapOptions (4B), pad (4B), colorContext (8B)
        bp1 := Buffer(32, 0)
        NumPut("uint", 87, bp1, 0)     ; DXGI_FORMAT_B8G8R8A8_UNORM
        NumPut("uint", 1, bp1, 4)      ; D2D1_ALPHA_MODE_PREMULTIPLIED
        NumPut("float", 96.0, bp1, 8)  ; dpiX
        NumPut("float", 96.0, bp1, 12) ; dpiY
        NumPut("uint", 0x1, bp1, 16)   ; D2D1_BITMAP_OPTIONS_TARGET

        global LOG_PATH_STORE

        ; Dump the bp1 struct bytes for diagnostics
        bp1Hex := ""
        loop 32
            bp1Hex .= Format("{:02X} ", NumGet(bp1, A_Index - 1, "uchar"))
        try LogAppend(LOG_PATH_STORE, "_BGImg_RebuildCache: w=" wPhys " h=" hPhys " bp1=[" bp1Hex "]")

        sizeU := D2D_SizeU(wPhys, hPhys)
        sizeVal := NumGet(sizeU, "int64")
        try LogAppend(LOG_PATH_STORE, "_BGImg_RebuildCache: sizeU int64=" sizeVal " (w=" NumGet(sizeU, 0, "uint") " h=" NumGet(sizeU, 4, "uint") ")")

        pCacheBmp := 0
        ; ID2D1DeviceContext::CreateBitmap1 (vtable 57)
        ; D2D1_SIZE_U passed by value as int64 (same convention as CreateBitmap vtable 4)
        try {
            ComCall(57, gD2D_RT, "int64", sizeVal, "ptr", 0, "uint", 0, "ptr", bp1, "ptr*", &pCacheBmp, "hresult")
        } catch as cbErr {
            try LogAppend(LOG_PATH_STORE, "_BGImg_RebuildCache: CreateBitmap1 FAILED: " cbErr.Message)
            ; Try fallback: use DllCall directly to rule out ComCall convention issue
            try {
                vtbl := NumGet(NumGet(gD2D_RT.ptr, "ptr"), 57 * A_PtrSize, "ptr")
                hr2 := DllCall(vtbl, "ptr", gD2D_RT.ptr, "uint", wPhys, "uint", hPhys, "ptr", 0, "uint", 0, "ptr", bp1, "ptr*", &pCacheBmp, "int")
                try LogAppend(LOG_PATH_STORE, "_BGImg_RebuildCache: DllCall fallback hr=" hr2 " pBmp=" pCacheBmp)
            } catch as e2 {
                try LogAppend(LOG_PATH_STORE, "_BGImg_RebuildCache: DllCall fallback also failed: " e2.Message)
            }
            if (!pCacheBmp)
                throw cbErr
        }
        try LogAppend(LOG_PATH_STORE, "_BGImg_RebuildCache: CreateBitmap1 OK pBmp=" pCacheBmp)
        if (!pCacheBmp)
            return
        cacheBmp := ID2D1Bitmap1(pCacheBmp)

        ; Save current render target
        pOldTarget := 0
        ; ID2D1DeviceContext::GetTarget (vtable 75)
        ComCall(75, gD2D_RT, "ptr*", &pOldTarget)

        ; Redirect drawing to cache bitmap
        ; ID2D1DeviceContext::SetTarget (vtable 74)
        ComCall(74, gD2D_RT, "ptr", cacheBmp.ptr)

        ; Drawing to the cache requires its own BeginDraw/EndDraw session
        gD2D_RT.BeginDraw()

        ; Clear to transparent
        static sClearColor := Buffer(16, 0)
        gD2D_RT.Clear(sClearColor)

        ; Render image into cache (all the expensive work happens once here)
        fitMode := cfg.BGImgFitMode
        interpMode := _BGImg_GetInterpolationMode()
        ; HighQuality (5) needs the effects path — DrawBitmap only supports 0/1
        needsEffects := (cfg.BGImgBlurRadius > 0 || cfg.BGImgDesaturation > 0 || cfg.BGImgBrightness != 0 || interpMode > 1)

        ; Shadow renders BEFORE the image (behind it)
        if (cfg.BGImgShadowEnabled && gBGImg_EffectsReady && (fitMode = "Fixed" || fitMode = "Fit"))
            _BGImg_DrawShadow(wPhys, hPhys, fitMode, interpMode)

        if (fitMode = "Tile") {
            _BGImg_DrawTiled(wPhys, hPhys, interpMode)
        } else if (needsEffects && gBGImg_EffectsReady) {
            _BGImg_DrawWithEffects(wPhys, hPhys, fitMode, interpMode)
        } else {
            _BGImg_DrawDirect(wPhys, hPhys, fitMode, interpMode)
        }

        gD2D_RT.EndDraw()

        ; Restore original render target
        ComCall(74, gD2D_RT, "ptr", pOldTarget)
        if (pOldTarget)
            ObjRelease(pOldTarget)

        gBGImg_Cache := cacheBmp
        gBGImg_CacheW := wPhys
        gBGImg_CacheH := hPhys
        gBGImg_CacheDirty := false

    } catch as e {
        ; End draw session and restore target on failure
        try {
            gD2D_RT.EndDraw()
        } catch {
        }
        if (IsSet(pOldTarget) && pOldTarget) {
            try {
                ComCall(74, gD2D_RT, "ptr", pOldTarget)
            } catch {
            }
            ObjRelease(pOldTarget)
        }
        global LOG_PATH_STORE
        try LogAppend(LOG_PATH_STORE, "BGImg cache rebuild failed: " e.Message)
    }
}

; ============================================================
; PRIVATE — Image Loading
; ============================================================

_BGImg_LoadImage(filePath) {
    global gD2D_RT, gBGImg_Bitmap, gBGImg_TileBrush
    global gBGImg_Width, gBGImg_Height, gBGImg_Ready
    global DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED, cfg

    global LOG_PATH_STORE
    try LogAppend(LOG_PATH_STORE, "_BGImg_LoadImage: path='" filePath "' exists=" FileExist(filePath) " gD2D_RT=" (gD2D_RT ? "yes" : "no"))
    if (!gD2D_RT || !FileExist(filePath))
        return

    try {
        ; One-shot GDI+ init (D2D pipeline doesn't use GDI+, but we need it for image file decoding)
        global gBGImg_GdipToken
        if (!gBGImg_GdipToken) {
            si := Buffer(24, 0)
            NumPut("uint", 1, si, 0)  ; GdiplusVersion = 1
            hr := DllCall("gdiplus\GdiplusStartup", "ptr*", &gBGImg_GdipToken, "ptr", si, "ptr", 0)
            try LogAppend(LOG_PATH_STORE, "_BGImg_LoadImage: GdiplusStartup hr=" hr " token=" gBGImg_GdipToken)
        }

        ; Load via GDI+
        pBitmapGdip := 0
        gdipHr := DllCall("gdiplus\GdipCreateBitmapFromFile", "str", filePath, "ptr*", &pBitmapGdip, "int")
        try LogAppend(LOG_PATH_STORE, "_BGImg_LoadImage: GdipCreateBitmapFromFile hr=" gdipHr " pBitmap=" pBitmapGdip)
        if (!pBitmapGdip)
            throw Error("GDI+ failed to load: " filePath " hr=" gdipHr)

        ; Get dimensions
        imgW := 0, imgH := 0
        DllCall("gdiplus\GdipGetImageWidth", "ptr", pBitmapGdip, "uint*", &imgW)
        DllCall("gdiplus\GdipGetImageHeight", "ptr", pBitmapGdip, "uint*", &imgH)

        if (imgW = 0 || imgH = 0) {
            DllCall("gdiplus\GdipDisposeImage", "ptr", pBitmapGdip)
            throw Error("Image has zero dimensions")
        }

        ; Lock bits in BGRA format (PixelFormat32bppARGB = 0x26200A)
        bmpData := Buffer(32, 0)
        lockRect := Buffer(16, 0)
        NumPut("int", 0, lockRect, 0)
        NumPut("int", 0, lockRect, 4)
        NumPut("int", imgW, lockRect, 8)
        NumPut("int", imgH, lockRect, 12)

        hr := DllCall("gdiplus\GdipBitmapLockBits", "ptr", pBitmapGdip, "ptr", lockRect,
            "uint", 1, "int", 0x26200A, "ptr", bmpData, "int")  ; ImageLockModeRead=1
        if (hr != 0) {
            DllCall("gdiplus\GdipDisposeImage", "ptr", pBitmapGdip)
            throw Error("LockBits failed hr=" hr)
        }

        stride := NumGet(bmpData, 8, "int")
        pPixels := NumGet(bmpData, 16, "ptr")
        pixelCount := imgW * imgH

        ; Copy pixels and premultiply alpha for D2D
        pixelBuf := Buffer(stride * imgH)
        DllCall("ntdll\RtlCopyMemory", "ptr", pixelBuf.Ptr, "ptr", pPixels, "uint", stride * imgH)
        D2D_PremultiplyAlpha(pixelBuf, pixelCount)

        ; Unlock and dispose GDI+ bitmap
        DllCall("gdiplus\GdipBitmapUnlockBits", "ptr", pBitmapGdip, "ptr", bmpData)
        DllCall("gdiplus\GdipDisposeImage", "ptr", pBitmapGdip)

        ; Create D2D bitmap
        sizeU := D2D_SizeU(imgW, imgH)
        bitmapProps := D2D_BitmapProps(96.0, 96.0, DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED)
        bitmap := gD2D_RT.CreateBitmap(sizeU, pixelBuf.Ptr, stride, bitmapProps)
        try LogAppend(LOG_PATH_STORE, "_BGImg_LoadImage: D2D bitmap created, ptr=" (bitmap ? bitmap.ptr : 0) " w=" imgW " h=" imgH)

        gBGImg_Bitmap := bitmap
        gBGImg_Width := imgW
        gBGImg_Height := imgH
        gBGImg_Ready := true

        ; Create tile brush if Tile mode is active
        if (cfg.BGImgFitMode = "Tile")
            _BGImg_CreateTileBrush()

    } catch as e {
        global LOG_PATH_STORE
        try LogAppend(LOG_PATH_STORE, "BGImg load failed: " e.Message)
        gBGImg_Ready := false
    }
}

global gBGImg_TileBrushInterp := -1  ; Cached interpolation mode for tile brush (-1 = not created)

_BGImg_CreateTileBrush(interpMode := 1) {
    global gD2D_RT, gBGImg_Bitmap, gBGImg_TileBrush, gBGImg_TileBrushInterp
    if (!gBGImg_Bitmap)
        return

    ; BitmapBrush only supports 0 (nearest) and 1 (linear) — clamp HighQuality to linear
    brushInterp := (interpMode >= 1) ? 1 : 0

    ; D2D1_BITMAP_BRUSH_PROPERTIES: { extendModeX, extendModeY, interpolationMode }
    brushProps := Buffer(12, 0)
    NumPut("uint", 1, brushProps, 0)  ; D2D1_EXTEND_MODE_WRAP
    NumPut("uint", 1, brushProps, 4)  ; D2D1_EXTEND_MODE_WRAP
    NumPut("uint", brushInterp, brushProps, 8)

    try {
        pBrush := 0
        ; ID2D1RenderTarget::CreateBitmapBrush (vtable 7)
        ComCall(7, gD2D_RT, "ptr", gBGImg_Bitmap.ptr, "ptr", brushProps, "ptr", 0, "ptr*", &pBrush)
        if (pBrush) {
            gBGImg_TileBrush := ID2DBase(pBrush)
            gBGImg_TileBrushInterp := brushInterp
        }
    } catch {
        ; BitmapBrush creation failed — Tile mode won't render
    }
}

; ============================================================
; PRIVATE — Interpolation Mode
; ============================================================

; Map user-facing ScaleFilter to D2D interpolation mode constant.
; Sharp=0 (NEAREST_NEIGHBOR), Smooth=1 (LINEAR), HighQuality=5 (HIGH_QUALITY_CUBIC)
_BGImg_GetInterpolationMode() {
    global cfg
    switch cfg.BGImgScaleFilter {
        case "Smooth":      return 1
        case "HighQuality": return 5
        default:            return 0   ; Sharp / nearest-neighbor
    }
}

; ============================================================
; PRIVATE — Fit / Alignment (called during cache build only)
; ============================================================

_BGImg_ParseAlignment(alignment) {
    switch alignment {
        case "TopLeft":     return {x: 0.0, y: 0.0}
        case "Top":         return {x: 0.5, y: 0.0}
        case "TopRight":    return {x: 1.0, y: 0.0}
        case "Left":        return {x: 0.0, y: 0.5}
        case "Center":      return {x: 0.5, y: 0.5}
        case "Right":       return {x: 1.0, y: 0.5}
        case "BottomLeft":  return {x: 0.0, y: 1.0}
        case "Bottom":      return {x: 0.5, y: 1.0}
        case "BottomRight": return {x: 1.0, y: 1.0}
        default:            return {x: 0.5, y: 0.5}
    }
}

_BGImg_ComputeRects(wPhys, hPhys, fitMode, alignment, userScale := 1.0) {
    global gBGImg_Width, gBGImg_Height
    imgW := gBGImg_Width
    imgH := gBGImg_Height
    align := _BGImg_ParseAlignment(alignment)

    switch fitMode {
        case "Fill":
            ; Cover: scale so image fills entire area, crop excess (ignores userScale)
            scale := Max(wPhys / imgW, hPhys / imgH)
            ; Source rect: which part of the image is visible
            srcW := wPhys / scale
            srcH := hPhys / scale
            srcX := (imgW - srcW) * align.x
            srcY := (imgH - srcH) * align.y
            return {
                dest: D2D_RectF(0, 0, wPhys, hPhys),
                src: D2D_RectF(srcX, srcY, srcX + srcW, srcY + srcH)
            }

        case "Fit":
            ; Contain: scale to fit within overlay, then apply user scale
            scale := Min(wPhys / imgW, hPhys / imgH) * userScale
            destW := imgW * scale
            destH := imgH * scale
            destX := (wPhys - destW) * align.x
            destY := (hPhys - destH) * align.y
            return {
                dest: D2D_RectF(destX, destY, destX + destW, destY + destH),
                src: D2D_RectF(0, 0, imgW, imgH)
            }

        case "Stretch":
            ; Distort to fill (ignores userScale)
            return {
                dest: D2D_RectF(0, 0, wPhys, hPhys),
                src: D2D_RectF(0, 0, imgW, imgH)
            }

        case "Fixed":
            ; Natural size * user scale, positioned by alignment
            destW := imgW * userScale
            destH := imgH * userScale
            destX := (wPhys - destW) * align.x
            destY := (hPhys - destH) * align.y
            return {
                dest: D2D_RectF(destX, destY, destX + destW, destY + destH),
                src: D2D_RectF(0, 0, imgW, imgH)
            }

        default:
            return {
                dest: D2D_RectF(0, 0, wPhys, hPhys),
                src: D2D_RectF(0, 0, imgW, imgH)
            }
    }
}

; ============================================================
; PRIVATE — Drawing (called during cache build only)
; ============================================================

_BGImg_DrawDirect(wPhys, hPhys, fitMode, interpMode := 1) {
    global gD2D_RT, gBGImg_Bitmap, cfg
    rects := _BGImg_ComputeRects(wPhys, hPhys, fitMode, cfg.BGImgAlignment, cfg.BGImgScale)
    gD2D_RT.DrawBitmap(gBGImg_Bitmap, rects.dest, 1.0, interpMode, rects.src)
}

_BGImg_DrawTiled(wPhys, hPhys, interpMode := 1) {
    global gD2D_RT, gBGImg_TileBrush, gBGImg_TileBrushInterp
    ; Recreate brush if interpolation mode changed or brush doesn't exist
    brushInterp := (interpMode >= 1) ? 1 : 0
    if (!gBGImg_TileBrush || gBGImg_TileBrushInterp != brushInterp) {
        gBGImg_TileBrush := 0  ; Release old brush
        _BGImg_CreateTileBrush(interpMode)
        if (!gBGImg_TileBrush)
            return
    }
    fillRect := D2D_RectF(0, 0, wPhys, hPhys)
    gD2D_RT.FillRectangle(fillRect, gBGImg_TileBrush)
}

_BGImg_DrawWithEffects(wPhys, hPhys, fitMode, interpMode := 1) {
    global gD2D_RT, gBGImg_Bitmap, gFX_GPU, gFX_GPUOutput, cfg
    global FX_BLUR_STDEV, FX_SAT_SATURATION, FX_CMATRIX_MATRIX

    ; Set bitmap as input to blur effect (head of chain)
    gFX_GPU["bgImgBlur"].SetInput(0, gBGImg_Bitmap)

    ; Configure blur
    gFX_GPU["bgImgBlur"].SetFloat(FX_BLUR_STDEV, cfg.BGImgBlurRadius)

    ; Configure saturation (D2D: 0=gray, 1=original)
    gFX_GPU["bgImgSat"].SetFloat(FX_SAT_SATURATION, 1.0 - cfg.BGImgDesaturation)

    ; Configure brightness via color matrix
    _BGImg_UpdateBrightness(cfg.BGImgBrightness)

    ; Compute positioning (with user scale for Fixed/Fit)
    rects := _BGImg_ComputeRects(wPhys, hPhys, fitMode, cfg.BGImgAlignment, cfg.BGImgScale)

    ; Extract rect values for scale/translate matrix
    dLeft := NumGet(rects.dest, 0, "float")
    dTop := NumGet(rects.dest, 4, "float")
    dRight := NumGet(rects.dest, 8, "float")
    dBottom := NumGet(rects.dest, 12, "float")
    destW := dRight - dLeft
    destH := dBottom - dTop

    sLeft := NumGet(rects.src, 0, "float")
    sTop := NumGet(rects.src, 4, "float")
    sRight := NumGet(rects.src, 8, "float")
    sBottom := NumGet(rects.src, 12, "float")
    srcW := sRight - sLeft
    srcH := sBottom - sTop

    scaleX := (srcW > 0) ? destW / srcW : 1.0
    scaleY := (srcH > 0) ? destH / srcH : 1.0

    ; D2D1_MATRIX_3X2_F: { _11, _12, _21, _22, _31, _32 }
    mtx := Buffer(24, 0)
    NumPut("float", Float(scaleX), mtx, 0)   ; _11
    NumPut("float", Float(scaleY), mtx, 12)  ; _22
    NumPut("float", Float(dLeft - sLeft * scaleX), mtx, 16)  ; _31 (translateX)
    NumPut("float", Float(dTop - sTop * scaleY), mtx, 20)   ; _32 (translateY)

    gD2D_RT.SetTransform(mtx)
    gD2D_RT.DrawImage(gFX_GPUOutput["bgImgColor"], 0, 0, interpMode)
    gD2D_RT.SetTransform(D2D_Matrix3x2_Identity())
}

_BGImg_DrawShadow(wPhys, hPhys, fitMode, interpMode := 1) {
    global gD2D_RT, gBGImg_Bitmap, gFX_GPU, cfg
    global FX_SHADOW_BLUR, FX_SHADOW_COLOR

    shadowEffect := gFX_GPU["bgImgShadow"]

    ; Set source bitmap as shadow input
    shadowEffect.SetInput(0, gBGImg_Bitmap)

    ; Configure shadow blur radius and color (black at user opacity)
    shadowEffect.SetFloat(FX_SHADOW_BLUR, cfg.BGImgShadowRadius)
    shadowEffect.SetVector4(FX_SHADOW_COLOR, 0.0, 0.0, 0.0, cfg.BGImgShadowOpacity)

    ; Compute image destination rect (same as image draw — reuses scale)
    rects := _BGImg_ComputeRects(wPhys, hPhys, fitMode, cfg.BGImgAlignment, cfg.BGImgScale)

    ; Extract rect values
    dLeft := NumGet(rects.dest, 0, "float")
    dTop := NumGet(rects.dest, 4, "float")
    dRight := NumGet(rects.dest, 8, "float")
    dBottom := NumGet(rects.dest, 12, "float")
    destW := dRight - dLeft
    destH := dBottom - dTop

    sLeft := NumGet(rects.src, 0, "float")
    sTop := NumGet(rects.src, 4, "float")
    sRight := NumGet(rects.src, 8, "float")
    sBottom := NumGet(rects.src, 12, "float")
    srcW := sRight - sLeft
    srcH := sBottom - sTop

    scaleX := (srcW > 0) ? destW / srcW : 1.0
    scaleY := (srcH > 0) ? destH / srcH : 1.0

    ; Shadow transform = image transform + shadow offset
    offsetX := cfg.BGImgShadowOffsetX
    offsetY := cfg.BGImgShadowOffsetY
    mtx := Buffer(24, 0)
    NumPut("float", Float(scaleX), mtx, 0)   ; _11
    NumPut("float", Float(scaleY), mtx, 12)  ; _22
    NumPut("float", Float(dLeft - sLeft * scaleX + offsetX), mtx, 16)  ; _31
    NumPut("float", Float(dTop - sTop * scaleY + offsetY), mtx, 20)   ; _32

    shadowOutput := shadowEffect.GetOutput()
    gD2D_RT.SetTransform(mtx)
    gD2D_RT.DrawImage(shadowOutput, 0, 0, interpMode)
    gD2D_RT.SetTransform(D2D_Matrix3x2_Identity())
}

_BGImg_UpdateBrightness(brightness) {
    global gFX_GPU, FX_CMATRIX_MATRIX
    m := D2D_ColorMatrix_Identity()
    if (brightness != 0.0) {
        ; Row 4 = translation offsets: byte offset 64/68/72 for R/G/B
        NumPut("float", Float(brightness), m, 64)
        NumPut("float", Float(brightness), m, 68)
        NumPut("float", Float(brightness), m, 72)
    }
    gFX_GPU["bgImgColor"].SetMatrix5x4(FX_CMATRIX_MATRIX, m)
}
