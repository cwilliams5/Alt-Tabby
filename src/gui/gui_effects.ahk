#Requires AutoHotkey v2.0
; GPU Effects System — D2D1 effect graph management for visual styles.
; Effects are created once at init, cached in gFX_GPU, and reused per-frame
; by updating properties (SetFloat, SetColorF, etc.). This avoids GPU resource
; allocation during paint (~50μs per CreateEffect vs ~2μs per SetValue).
;
; Core pattern: Flood → Crop → GaussianBlur = "SoftRect"
; Produces a soft-edged colored rectangle without intermediate bitmaps.
; Used for GPU shadows, glows, and ambient effects.
#Warn VarUnset, Off

; ========================= GPU EFFECT CACHE =========================

global gFX_GPU := Map()      ; name → ID2D1Effect
global gFX_GPUReady := false  ; Set after successful init
global gFX_GPUOutput := Map() ; name → ID2D1Image (cached GetOutput results)
global gFX_HDRActive := false  ; True when HDR gamma compensation is active

; Initialize GPU effects. Call after gD2D_RT is valid.
; Returns true on success, false if effects unavailable.
FX_GPU_Init() {
    global gD2D_RT, gFX_GPU, gFX_GPUReady, gFX_GPUOutput, gFX_HDRActive, cfg
    global CLSID_D2D1GaussianBlur, CLSID_D2D1Shadow, CLSID_D2D1Flood
    global CLSID_D2D1Crop, CLSID_D2D1ColorMatrix, CLSID_D2D1Saturation
    global CLSID_D2D1Blend, CLSID_D2D1Composite, CLSID_D2D1Turbulence
    global CLSID_D2D1Morphology, CLSID_D2D1GammaTransfer, CLSID_D2D1DirectionalBlur
    global LOG_PATH_PAINT_TIMING

    if (!gD2D_RT || !cfg.PerfGPUEffects)
        return false

    try {
        ; --- SoftRect chain: Flood → Crop → Blur (selection shadow/glow) ---
        gFX_GPU["flood"]  := gD2D_RT.CreateEffect(CLSID_D2D1Flood)
        gFX_GPU["crop"]   := gD2D_RT.CreateEffect(CLSID_D2D1Crop)
        gFX_GPU["blur"]   := gD2D_RT.CreateEffect(CLSID_D2D1GaussianBlur)

        ; Wire the chain once: flood → crop → blur
        gFX_GPU["crop"].SetInput(0, gFX_GPU["flood"].GetOutput())
        gFX_GPU["blur"].SetInput(0, gFX_GPU["crop"].GetOutput())

        ; --- Second SoftRect for glow (can run with different params) ---
        gFX_GPU["flood2"] := gD2D_RT.CreateEffect(CLSID_D2D1Flood)
        gFX_GPU["crop2"]  := gD2D_RT.CreateEffect(CLSID_D2D1Crop)
        gFX_GPU["blur2"]  := gD2D_RT.CreateEffect(CLSID_D2D1GaussianBlur)
        gFX_GPU["crop2"].SetInput(0, gFX_GPU["flood2"].GetOutput())
        gFX_GPU["blur2"].SetInput(0, gFX_GPU["crop2"].GetOutput())

        ; --- Shadow effect (direct D2D1Shadow — for CommandList-based shadow) ---
        gFX_GPU["shadow"] := gD2D_RT.CreateEffect(CLSID_D2D1Shadow)

        ; --- Color effects ---
        gFX_GPU["colorMatrix"] := gD2D_RT.CreateEffect(CLSID_D2D1ColorMatrix)
        gFX_GPU["saturation"]  := gD2D_RT.CreateEffect(CLSID_D2D1Saturation)
        gFX_GPU["blend"]       := gD2D_RT.CreateEffect(CLSID_D2D1Blend)
        gFX_GPU["composite"]   := gD2D_RT.CreateEffect(CLSID_D2D1Composite)

        ; --- Noise chain: Turbulence → Crop → Saturation ---
        ; Crop is required: turbulence has infinite output extent, DrawImage would crash.
        gFX_GPU["turbulence"]  := gD2D_RT.CreateEffect(CLSID_D2D1Turbulence)
        gFX_GPU["noiseCrop"]   := gD2D_RT.CreateEffect(CLSID_D2D1Crop)
        gFX_GPU["noiseSat"]    := gD2D_RT.CreateEffect(CLSID_D2D1Saturation)
        gFX_GPU["noiseCrop"].SetInput(0, gFX_GPU["turbulence"].GetOutput())
        gFX_GPU["noiseSat"].SetInput(0, gFX_GPU["noiseCrop"].GetOutput())

        ; --- DirectionalBlur ---
        gFX_GPU["dirBlur"]     := gD2D_RT.CreateEffect(CLSID_D2D1DirectionalBlur)

        ; --- Morphology (glow outlines) ---
        gFX_GPU["morphology"]  := gD2D_RT.CreateEffect(CLSID_D2D1Morphology)

        ; --- Gamma transfer (bloom/exposure + HDR compensation) ---
        gFX_GPU["gamma"]       := gD2D_RT.CreateEffect(CLSID_D2D1GammaTransfer)

        ; Cache frequently-used GetOutput() results (avoids COM call per frame)
        gFX_GPUOutput["blur"]  := gFX_GPU["blur"].GetOutput()
        gFX_GPUOutput["blur2"] := gFX_GPU["blur2"].GetOutput()
        gFX_GPUOutput["noiseSat"] := gFX_GPU["noiseSat"].GetOutput()

        ; --- HDR compensation: insert GammaTransfer after blur outputs ---
        ; When HDR active, gFX_GPUOutput["blur"/"blur2"] point to gamma outputs instead,
        ; so all SoftRect callers get HDR correction automatically.
        hdrActive := false
        if (cfg.PerfHDRCompensation = "on")
            hdrActive := true
        else if (cfg.PerfHDRCompensation = "auto")
            hdrActive := D2D_IsHDRActive()

        if (hdrActive) {
            gammaExp := cfg.PerfHDRGammaExponent
            ; Primary chain: blur → gamma → cached output
            _FX_ConfigureHDRGamma(gFX_GPU["gamma"], gammaExp)
            gFX_GPU["gamma"].SetInput(0, gFX_GPUOutput["blur"])
            gFX_GPUOutput["blur"] := gFX_GPU["gamma"].GetOutput()

            ; Secondary chain: blur2 → gamma2 → cached output
            gFX_GPU["gamma2"] := gD2D_RT.CreateEffect(CLSID_D2D1GammaTransfer)
            _FX_ConfigureHDRGamma(gFX_GPU["gamma2"], gammaExp)
            gFX_GPU["gamma2"].SetInput(0, gFX_GPUOutput["blur2"])
            gFX_GPUOutput["blur2"] := gFX_GPU["gamma2"].GetOutput()
        }

        gFX_HDRActive := hdrActive

        ; Log HDR state
        if (cfg.DiagPaintTimingLog)
            LogAppend(LOG_PATH_PAINT_TIMING, "FX_GPU_Init: HDR=" (hdrActive ? "active" : "inactive") " mode=" cfg.PerfHDRCompensation)

        gFX_GPUReady := true
        return true
    } catch as e {
        FX_GPU_Dispose()
        return false
    }
}

; Release all cached effects. Safe to call multiple times.
FX_GPU_Dispose() {
    global gFX_GPU, gFX_GPUReady, gFX_GPUOutput, gFX_HDRActive
    ; Release cached output images first (prevent dangling refs)
    gFX_GPUOutput := Map()
    ; Release effects (ID2DBase.__Delete handles ObjRelease)
    gFX_GPU := Map()
    gFX_GPUReady := false
    gFX_HDRActive := false
}

; ========================= SOFT RECT PRIMITIVE =========================
; Flood → Crop → GaussianBlur = soft-edged colored rectangle.
; The blur naturally softens the sharp crop edges, producing a shadow/glow shape.
; No intermediate bitmap needed — pure effect graph, fully GPU-accelerated.

; Draw a soft rectangle using the primary chain (flood→crop→blur).
; x,y,w,h: rectangle in physical pixels. argb: fill color. blurStdDev: blur amount.
; offsetX/Y: additional translation (e.g., shadow offset).
FX_DrawSoftRect(x, y, w, h, argb, blurStdDev, offsetX := 0, offsetY := 0) {
    global gD2D_RT, gFX_GPU, gFX_GPUOutput
    global FX_FLOOD_COLOR, FX_CROP_RECT, FX_BLUR_STDEV, FX_BLUR_BORDER_MODE, D2D1_BORDER_SOFT

    ; Configure flood color (premultiplied)
    gFX_GPU["flood"].SetColorF(FX_FLOOD_COLOR, argb)

    ; Configure crop to the rectangle bounds
    gFX_GPU["crop"].SetRectF(FX_CROP_RECT, Float(x), Float(y), Float(x + w), Float(y + h))
    gFX_GPU["crop"].SetEnum(1, D2D1_BORDER_SOFT)  ; soft border for smooth blur

    ; Configure blur
    gFX_GPU["blur"].SetFloat(FX_BLUR_STDEV, blurStdDev)
    gFX_GPU["blur"].SetEnum(FX_BLUR_BORDER_MODE, D2D1_BORDER_SOFT)

    ; Draw at offset position
    if (offsetX != 0 || offsetY != 0) {
        pt := Buffer(8, 0)
        NumPut("float", Float(offsetX), "float", Float(offsetY), pt)
        gD2D_RT.DrawImage(gFX_GPUOutput["blur"], pt)
    } else {
        gD2D_RT.DrawImage(gFX_GPUOutput["blur"])
    }
}

; Draw a soft rectangle using the secondary chain (flood2→crop2→blur2).
; Allows drawing two different soft rects without reconfiguring the primary chain.
FX_DrawSoftRect2(x, y, w, h, argb, blurStdDev, offsetX := 0, offsetY := 0) {
    global gD2D_RT, gFX_GPU, gFX_GPUOutput
    global FX_FLOOD_COLOR, FX_CROP_RECT, FX_BLUR_STDEV, FX_BLUR_BORDER_MODE, D2D1_BORDER_SOFT

    gFX_GPU["flood2"].SetColorF(FX_FLOOD_COLOR, argb)
    gFX_GPU["crop2"].SetRectF(FX_CROP_RECT, Float(x), Float(y), Float(x + w), Float(y + h))
    gFX_GPU["crop2"].SetEnum(1, D2D1_BORDER_SOFT)
    gFX_GPU["blur2"].SetFloat(FX_BLUR_STDEV, blurStdDev)
    gFX_GPU["blur2"].SetEnum(FX_BLUR_BORDER_MODE, D2D1_BORDER_SOFT)

    if (offsetX != 0 || offsetY != 0) {
        pt := Buffer(8, 0)
        NumPut("float", Float(offsetX), "float", Float(offsetY), pt)
        gD2D_RT.DrawImage(gFX_GPUOutput["blur2"], pt)
    } else {
        gD2D_RT.DrawImage(gFX_GPUOutput["blur2"])
    }
}

; ========================= GPU STYLE RENDERERS =========================
; Each style function draws the selection highlight using GPU effects.
; They replace _FX_DrawSelection / _FX_DrawSelDropShadow for GPU styles.

; --- Style: "Glass" ---
; Real GPU shadow + gradient fill + crisp border.
; The gold standard: clean, modern, depth without heaviness.
FX_GPU_DrawSelection_Glass(x, y, w, h, r) {
    global cfg, gD2D_RT, gFX_GPUReady

    baseARGB := cfg.GUI_SelARGB
    userAlpha := ((baseARGB >> 24) & 0xFF) / 255.0
    baseRGB := baseARGB & 0x00FFFFFF

    ; GPU soft shadow — 6px blur, offset 3,3, dark
    shadowAlpha := Round(0.45 * 255) << 24
    FX_DrawSoftRect(x, y, w, h, shadowAlpha, 6.0, 3, 3)

    ; Subtle outer glow — selection color, wide blur, very transparent
    glowAlpha := Round(userAlpha * 0.25 * 255) << 24
    glowARGB := glowAlpha | baseRGB
    FX_DrawSoftRect2(x - 4, y - 4, w + 8, h + 8, glowARGB, 10.0)

    ; Selection fill with layer compositing (same HDR-correct pattern as Effects style)
    opaqueBase := 0xFF000000 | baseRGB
    opaqueDark := 0xFF000000 | FX_BlendToBlack(baseARGB, 0.18)
    layerParams := FX_LayerParams(x, y, x + w, y + h, userAlpha)
    gD2D_RT.PushLayer(layerParams, 0)

    gradBr := FX_LinearGradient(x, y, x + w, y + h, [
        [0.0, opaqueBase],
        [1.0, opaqueDark]
    ])
    if (gradBr)
        D2D_FillRoundRect(x, y, w, h, r, gradBr)
    else
        D2D_FillRoundRect(x, y, w, h, r, D2D_GetCachedBrush(opaqueBase))

    gD2D_RT.PopLayer()

    ; Crisp border
    bw := cfg.GUI_SelBorderWidthPx
    if (bw > 0) {
        half := bw / 2
        D2D_StrokeRoundRect(x + half, y + half, w - bw, h - bw, r, D2D_GetCachedBrush(cfg.GUI_SelBorderARGB), bw)
    }
}

; --- Style: "Neon" ---
; Bright glow bloom + thin bright border. Cyberpunk aesthetic.
; Double glow: inner tight + outer wide, both using selection color.
FX_GPU_DrawSelection_Neon(x, y, w, h, r) {
    global cfg, gD2D_RT

    baseARGB := cfg.GUI_SelARGB
    userAlpha := ((baseARGB >> 24) & 0xFF) / 255.0
    baseRGB := baseARGB & 0x00FFFFFF

    ; Brighten the glow color (push toward white for bloom)
    glowR := Min(255, ((baseRGB >> 16) & 0xFF) + 80)
    glowG := Min(255, ((baseRGB >> 8) & 0xFF) + 80)
    glowB := Min(255, (baseRGB & 0xFF) + 80)
    brightRGB := (glowR << 16) | (glowG << 8) | glowB

    ; Wide outer glow — bright, large blur
    outerAlpha := Round(userAlpha * 0.5 * 255)
    outerARGB := (outerAlpha << 24) | brightRGB
    FX_DrawSoftRect(x - 8, y - 8, w + 16, h + 16, outerARGB, 16.0)

    ; Tight inner glow — saturated, small blur
    innerAlpha := Round(userAlpha * 0.7 * 255)
    innerARGB := (innerAlpha << 24) | baseRGB
    FX_DrawSoftRect2(x - 2, y - 2, w + 4, h + 4, innerARGB, 4.0)

    ; Semi-transparent fill — darker than normal for contrast with glow
    fillAlpha := Round(userAlpha * 0.6 * 255)
    darkRGB := FX_BlendToBlack(baseARGB, 0.4)
    fillARGB := (fillAlpha << 24) | darkRGB
    D2D_FillRoundRect(x, y, w, h, r, D2D_GetCachedBrush(fillARGB))

    ; Bright 2px border — the neon wire
    borderAlpha := Round(Min(1.0, userAlpha * 1.3) * 255)
    borderARGB := (borderAlpha << 24) | brightRGB
    D2D_StrokeRoundRect(x + 1, y + 1, w - 2, h - 2, r, D2D_GetCachedBrush(borderARGB), 2)
}

; --- Style: "Frosted" ---
; Extra-soft diffuse shadow + layered semi-transparent fills for depth.
; Multiple overlapping soft rects at different opacities = frosted glass look.
FX_GPU_DrawSelection_Frosted(x, y, w, h, r) {
    global cfg, gD2D_RT

    baseARGB := cfg.GUI_SelARGB
    userAlpha := ((baseARGB >> 24) & 0xFF) / 255.0
    baseRGB := baseARGB & 0x00FFFFFF

    ; Very soft, wide shadow — diffuse light feel
    shadowAlpha := Round(0.25 * 255) << 24
    FX_DrawSoftRect(x, y, w, h, shadowAlpha, 16.0, 3, 4)

    ; Soft ambient glow — wider, lighter version of the selection color
    ambientAlpha := Round(userAlpha * 0.15 * 255)
    ambientARGB := (ambientAlpha << 24) | baseRGB
    FX_DrawSoftRect2(x - 6, y - 4, w + 12, h + 8, ambientARGB, 12.0)

    ; Fill with layer compositing
    opaqueBase := 0xFF000000 | baseRGB
    opaqueLight := 0xFF000000 | _FX_LightenRGB(baseRGB, 0.15)
    layerParams := FX_LayerParams(x, y, x + w, y + h, userAlpha)
    gD2D_RT.PushLayer(layerParams, 0)

    ; Base fill — flat, uniform (frosted = no strong gradient)
    D2D_FillRoundRect(x, y, w, h, r, D2D_GetCachedBrush(opaqueBase))

    ; Subtle top highlight — lighter band across the top third
    highlightBr := FX_LinearGradient(x, y, x, y + h * 0.4, [
        [0.0, opaqueLight],
        [1.0, 0x00000000]
    ])
    if (highlightBr)
        D2D_FillRoundRect(x, y, w, h, r, highlightBr)

    gD2D_RT.PopLayer()

    ; Soft border
    bw := cfg.GUI_SelBorderWidthPx
    if (bw > 0) {
        half := bw / 2
        borderAlpha := Round(userAlpha * 0.6 * 255)
        borderARGB := (borderAlpha << 24) | baseRGB
        D2D_StrokeRoundRect(x + half, y + half, w - bw, h - bw, r, D2D_GetCachedBrush(borderARGB), bw)
    }
}

; --- Style: "Ember" ---
; Warm amber glow + deep shadow. Rich, warm aesthetic.
FX_GPU_DrawSelection_Ember(x, y, w, h, r) {
    global cfg, gD2D_RT

    baseARGB := cfg.GUI_SelARGB
    userAlpha := ((baseARGB >> 24) & 0xFF) / 255.0
    baseRGB := baseARGB & 0x00FFFFFF

    ; Deep shadow
    shadowAlpha := Round(0.55 * 255) << 24
    FX_DrawSoftRect(x, y, w, h, shadowAlpha, 8.0, 4, 5)

    ; Warm amber glow — orange tinted, wide spread
    emberR := Min(255, ((baseRGB >> 16) & 0xFF) + 60)
    emberG := Max(0, ((baseRGB >> 8) & 0xFF))
    emberB := Max(0, (baseRGB & 0xFF) - 30)
    warmRGB := (emberR << 16) | (emberG << 8) | emberB
    warmAlpha := Round(userAlpha * 0.4 * 255)
    warmARGB := (warmAlpha << 24) | warmRGB
    FX_DrawSoftRect2(x - 6, y - 6, w + 12, h + 12, warmARGB, 12.0)

    ; Fill with warm gradient
    opaqueBase := 0xFF000000 | baseRGB
    warmDark := 0xFF000000 | FX_BlendToBlack(baseARGB, 0.30)
    layerParams := FX_LayerParams(x, y, x + w + 8, y + h + 8, userAlpha)
    gD2D_RT.PushLayer(layerParams, 0)

    gradBr := FX_LinearGradient(x, y, x + w * 0.5, y + h, [
        [0.0, opaqueBase],
        [0.7, warmDark],
        [1.0, 0xFF000000 | FX_BlendToBlack(baseARGB, 0.45)]
    ])
    if (gradBr)
        D2D_FillRoundRect(x, y, w, h, r, gradBr)
    else
        D2D_FillRoundRect(x, y, w, h, r, D2D_GetCachedBrush(opaqueBase))

    gD2D_RT.PopLayer()

    ; Warm border
    bw := Max(1, cfg.GUI_SelBorderWidthPx)
    half := bw / 2
    borderAlpha := Round(Min(1.0, userAlpha * 1.1) * 255)
    borderARGB := (borderAlpha << 24) | warmRGB
    D2D_StrokeRoundRect(x + half, y + half, w - bw, h - bw, r, D2D_GetCachedBrush(borderARGB), bw)
}

; --- Style: "Minimal" ---
; Perfect soft shadow only. No gradient, no border effects. Ultra-clean.
FX_GPU_DrawSelection_Minimal(x, y, w, h, r) {
    global cfg, gD2D_RT

    baseARGB := cfg.GUI_SelARGB

    ; Large, very soft shadow — the star of this style
    shadowAlpha := Round(0.35 * 255) << 24
    FX_DrawSoftRect(x, y, w, h, shadowAlpha, 18.0, 2, 3)

    ; Flat fill, no gradient
    D2D_FillRoundRect(x, y, w, h, r, D2D_GetCachedBrush(baseARGB))
}

; --- Style: "Holograph" ---
; Multi-color prismatic glow. Dual glow with color-shifted halos.
FX_GPU_DrawSelection_Holograph(x, y, w, h, r) {
    global cfg, gD2D_RT

    baseARGB := cfg.GUI_SelARGB
    userAlpha := ((baseARGB >> 24) & 0xFF) / 255.0
    baseRGB := baseARGB & 0x00FFFFFF

    ; Extract base color channels
    bR := (baseRGB >> 16) & 0xFF
    bG := (baseRGB >> 8) & 0xFF
    bB := baseRGB & 0xFF

    ; Color-shifted glow 1: shift toward cyan/blue (top-left bias)
    c1R := Max(0, bR - 60)
    c1G := Min(255, bG + 40)
    c1B := Min(255, bB + 80)
    c1RGB := (c1R << 16) | (c1G << 8) | c1B
    c1Alpha := Round(userAlpha * 0.4 * 255)
    c1ARGB := (c1Alpha << 24) | c1RGB
    FX_DrawSoftRect(x - 6, y - 8, w + 12, h + 16, c1ARGB, 14.0, -2, -2)

    ; Color-shifted glow 2: shift toward magenta/pink (bottom-right bias)
    c2R := Min(255, bR + 60)
    c2G := Max(0, bG - 40)
    c2B := Min(255, bB + 40)
    c2RGB := (c2R << 16) | (c2G << 8) | c2B
    c2Alpha := Round(userAlpha * 0.35 * 255)
    c2ARGB := (c2Alpha << 24) | c2RGB
    FX_DrawSoftRect2(x - 4, y - 4, w + 8, h + 8, c2ARGB, 12.0, 3, 3)

    ; Fill with subtle gradient
    opaqueBase := 0xFF000000 | baseRGB
    opaqueDark := 0xFF000000 | FX_BlendToBlack(baseARGB, 0.15)
    layerParams := FX_LayerParams(x, y, x + w, y + h, userAlpha)
    gD2D_RT.PushLayer(layerParams, 0)

    gradBr := FX_LinearGradient(x, y, x + w, y + h, [
        [0.0, opaqueBase],
        [1.0, opaqueDark]
    ])
    if (gradBr)
        D2D_FillRoundRect(x, y, w, h, r, gradBr)
    else
        D2D_FillRoundRect(x, y, w, h, r, D2D_GetCachedBrush(opaqueBase))

    gD2D_RT.PopLayer()

    ; Bright prismatic border
    bw := Max(1, cfg.GUI_SelBorderWidthPx)
    half := bw / 2
    D2D_StrokeRoundRect(x + half, y + half, w - bw, h - bw, r, D2D_GetCachedBrush(cfg.GUI_SelBorderARGB), bw)
}

; --- Style: "Plasma" ---
; Turbulence noise overlay + gradient fill. Organic, living texture.
; Uses the noise chain (turbulence → noiseCrop → noiseSat) for texture.
FX_GPU_DrawSelection_Plasma(x, y, w, h, r) {
    global cfg, gD2D_RT, gFX_GPU, gFX_GPUOutput, LOG_PATH_STORE
    global FX_TURB_SIZE, FX_TURB_FREQ, FX_TURB_OCTAVES, FX_TURB_NOISE
    global FX_CROP_RECT, FX_SAT_SATURATION, D2D1_BORDER_SOFT

    try {
        baseARGB := cfg.GUI_SelARGB
        userAlpha := ((baseARGB >> 24) & 0xFF) / 255.0
        baseRGB := baseARGB & 0x00FFFFFF

        ; GPU soft shadow — 8px blur, offset 3,3
        shadowAlpha := Round(0.45 * 255) << 24
        FX_DrawSoftRect(x, y, w, h, shadowAlpha, 8.0, 3, 3)

        ; Configure turbulence: low frequency for large plasma swirls
        gFX_GPU["turbulence"].SetVector2(FX_TURB_SIZE, Float(w + 20), Float(h + 20))
        gFX_GPU["turbulence"].SetVector2(FX_TURB_FREQ, 0.015, 0.015)
        gFX_GPU["turbulence"].SetUInt(FX_TURB_OCTAVES, 3)
        gFX_GPU["turbulence"].SetEnum(FX_TURB_NOISE, 1)  ; turbulence mode

        ; Crop in turbulence's local space (0,0 origin); DrawImage offset handles positioning
        gFX_GPU["noiseCrop"].SetRectF(FX_CROP_RECT, 0.0, 0.0, Float(w), Float(h))
        gFX_GPU["noiseCrop"].SetEnum(1, D2D1_BORDER_SOFT)

        ; Desaturate noise slightly for subtler texture
        gFX_GPU["noiseSat"].SetFloat(FX_SAT_SATURATION, 0.3)

        ; PushLayer for overall compositing at user alpha
        layerParams := FX_LayerParams(x, y, x + w, y + h, userAlpha)
        gD2D_RT.PushLayer(layerParams, 0)

        ; Gradient fill (base → darker)
        opaqueBase := 0xFF000000 | baseRGB
        opaqueDark := 0xFF000000 | FX_BlendToBlack(baseARGB, 0.25)
        gradBr := FX_LinearGradient(x, y, x + w, y + h, [
            [0.0, opaqueBase],
            [1.0, opaqueDark]
        ])
        if (gradBr)
            D2D_FillRoundRect(x, y, w, h, r, gradBr)
        else
            D2D_FillRoundRect(x, y, w, h, r, D2D_GetCachedBrush(opaqueBase))

        ; Nested PushLayer for noise overlay at low opacity
        noiseLayerParams := FX_LayerParams(x, y, x + w, y + h, 0.12)
        gD2D_RT.PushLayer(noiseLayerParams, 0)

        ; DrawImage noise at selection origin
        pt := Buffer(8, 0)
        NumPut("float", Float(x), "float", Float(y), pt)
        gD2D_RT.DrawImage(gFX_GPUOutput["noiseSat"], pt)

        gD2D_RT.PopLayer()  ; noise layer
        gD2D_RT.PopLayer()  ; selection layer

        ; Border
        bw := cfg.GUI_SelBorderWidthPx
        if (bw > 0) {
            half := bw / 2
            D2D_StrokeRoundRect(x + half, y + half, w - bw, h - bw, r, D2D_GetCachedBrush(cfg.GUI_SelBorderARGB), bw)
        }
    } catch as e {
        ; GPU effect failure — fall back to Glass style
        try LogAppend(LOG_PATH_STORE, "FX_Plasma err=" e.Message " file=" e.File " line=" e.Line)
        FX_GPU_DrawSelection_Glass(x, y, w, h, r)
    }
}

; ========================= GPU INNER SHADOW =========================
; GPU-accelerated window-edge shadows (replaces gradient-strip approach).

FX_GPU_DrawInnerShadow(wPhys, hPhys, depth, alpha) {
    ; Top: dark band blurred downward
    edgeAlpha := Round(alpha * 1.2)
    if (edgeAlpha > 255) edgeAlpha := 255
    topARGB := (edgeAlpha << 24) | 0x000000
    FX_DrawSoftRect(0, -depth, wPhys, depth, topARGB, Float(depth * 0.8))

    ; Bottom
    botAlpha := Round(alpha * 0.9)
    botARGB := (botAlpha << 24) | 0x000000
    FX_DrawSoftRect2(0, hPhys, wPhys, depth, botARGB, Float(depth * 0.8))
}

; ========================= GPU HOVER =========================

; GPU-enhanced hover with soft glow behind the row.
FX_GPU_DrawHover(x, y, w, h, _r) { ; lint-ignore: dead-param
    global cfg
    baseARGB := cfg.GUI_HoverARGB
    ; Soft glow behind hover row
    FX_DrawSoftRect(x, y, w, h, baseARGB, 4.0)
}

; ========================= NOISE OVERLAY =========================
; Full-window turbulence noise texture overlay.
; Uses the noise chain (turbulence → noiseCrop → noiseSat).

FX_GPU_DrawNoiseOverlay(wPhys, hPhys, opacity) { ; lint-ignore: dead-function
    global gD2D_RT, gFX_GPU, gFX_GPUOutput
    global FX_TURB_SIZE, FX_TURB_FREQ, FX_TURB_OCTAVES, FX_TURB_NOISE
    global FX_CROP_RECT, FX_SAT_SATURATION, D2D1_BORDER_SOFT

    ; Configure turbulence for full-window noise
    gFX_GPU["turbulence"].SetVector2(FX_TURB_SIZE, Float(wPhys), Float(hPhys))
    gFX_GPU["turbulence"].SetVector2(FX_TURB_FREQ, 0.03, 0.03)
    gFX_GPU["turbulence"].SetUInt(FX_TURB_OCTAVES, 2)
    gFX_GPU["turbulence"].SetEnum(FX_TURB_NOISE, 1)

    ; Crop to window bounds
    gFX_GPU["noiseCrop"].SetRectF(FX_CROP_RECT, 0.0, 0.0, Float(wPhys), Float(hPhys))
    gFX_GPU["noiseCrop"].SetEnum(1, D2D1_BORDER_SOFT)

    ; Desaturate to grayscale
    gFX_GPU["noiseSat"].SetFloat(FX_SAT_SATURATION, 0.0)

    ; Draw with opacity layer
    layerParams := FX_LayerParams(0, 0, wPhys, hPhys, opacity)
    gD2D_RT.PushLayer(layerParams, 0)
    gD2D_RT.DrawImage(gFX_GPUOutput["noiseSat"])
    gD2D_RT.PopLayer()
}

; ========================= STYLE DISPATCH =========================
; Central dispatch for GPU selection rendering. Called from gui_paint.ahk.

; GPU style names (indices 0+). Style 0 = first GPU style.
global FX_GPU_STYLE_NAMES := [ ; lint-ignore: dead-global
    "Glass",
    "Neon",
    "Frosted",
    "Ember",
    "Minimal",
    "Holograph",
    "Plasma"
]

; Draw selection using the active GPU style.
; gpuStyleIndex: 0-based index into FX_GPU_STYLE_NAMES.
; Wrapped in try/catch — GPU effect failures fall back to flat fill.
FX_GPU_DrawSelection(gpuStyleIndex, x, y, w, h, r) {
    global cfg
    if (w <= 0 || h <= 0)
        return
    try {
        switch gpuStyleIndex {
            case 0: FX_GPU_DrawSelection_Glass(x, y, w, h, r)
            case 1: FX_GPU_DrawSelection_Neon(x, y, w, h, r)
            case 2: FX_GPU_DrawSelection_Frosted(x, y, w, h, r)
            case 3: FX_GPU_DrawSelection_Ember(x, y, w, h, r)
            case 4: FX_GPU_DrawSelection_Minimal(x, y, w, h, r)
            case 5: FX_GPU_DrawSelection_Holograph(x, y, w, h, r)
            case 6: FX_GPU_DrawSelection_Plasma(x, y, w, h, r)
            default: FX_GPU_DrawSelection_Glass(x, y, w, h, r)
        }
    } catch {
        ; GPU effect failed — fall back to simple fill
        D2D_FillRoundRect(x, y, w, h, r, D2D_GetCachedBrush(cfg.GUI_SelARGB))
    }
}

; ========================= HDR COMPENSATION =========================

; Configure a GammaTransfer effect for HDR brightness compensation.
; Sets C' = 1.0 * C^exp + 0.0 on RGB channels, disables alpha (must stay linear).
_FX_ConfigureHDRGamma(effect, exp) {
    global FX_GAMMA_RED_AMP, FX_GAMMA_RED_EXP, FX_GAMMA_RED_OFF, FX_GAMMA_RED_DISABLE
    global FX_GAMMA_GREEN_AMP, FX_GAMMA_GREEN_EXP, FX_GAMMA_GREEN_OFF, FX_GAMMA_GREEN_DISABLE
    global FX_GAMMA_BLUE_AMP, FX_GAMMA_BLUE_EXP, FX_GAMMA_BLUE_OFF, FX_GAMMA_BLUE_DISABLE
    global FX_GAMMA_ALPHA_DISABLE

    ; Red channel: C' = 1.0 * C^exp + 0.0
    effect.SetFloat(FX_GAMMA_RED_AMP, 1.0)
    effect.SetFloat(FX_GAMMA_RED_EXP, exp)
    effect.SetFloat(FX_GAMMA_RED_OFF, 0.0)
    effect.SetBool(FX_GAMMA_RED_DISABLE, false)

    ; Green channel
    effect.SetFloat(FX_GAMMA_GREEN_AMP, 1.0)
    effect.SetFloat(FX_GAMMA_GREEN_EXP, exp)
    effect.SetFloat(FX_GAMMA_GREEN_OFF, 0.0)
    effect.SetBool(FX_GAMMA_GREEN_DISABLE, false)

    ; Blue channel
    effect.SetFloat(FX_GAMMA_BLUE_AMP, 1.0)
    effect.SetFloat(FX_GAMMA_BLUE_EXP, exp)
    effect.SetFloat(FX_GAMMA_BLUE_OFF, 0.0)
    effect.SetBool(FX_GAMMA_BLUE_DISABLE, false)

    ; Alpha: MUST stay linear — disable gamma on alpha channel
    effect.SetBool(FX_GAMMA_ALPHA_DISABLE, true)
}

; Apply HDR gamma correction to an ARGB integer (for non-GPU brush colors).
; Returns corrected ARGB. No-op when HDR inactive.
FX_HDRCorrectARGB(argb) { ; lint-ignore: dead-function
    global gFX_HDRActive, cfg
    if (!gFX_HDRActive)
        return argb
    exp := cfg.PerfHDRGammaExponent
    a := (argb >> 24) & 0xFF
    r := ((argb >> 16) & 0xFF) / 255.0
    g := ((argb >> 8) & 0xFF) / 255.0
    b := (argb & 0xFF) / 255.0
    r := Round((r ** exp) * 255)
    g := Round((g ** exp) * 255)
    b := Round((b ** exp) * 255)
    return (a << 24) | (r << 16) | (g << 8) | b
}

; ========================= COLOR UTILITIES =========================

; Lighten an RGB value toward white by factor (0.0=no change, 1.0=pure white).
; Input/output: 0x00RRGGBB (no alpha).
_FX_LightenRGB(rgb, factor) {
    r := (rgb >> 16) & 0xFF
    g := (rgb >> 8) & 0xFF
    b := rgb & 0xFF
    r := Round(r + (255 - r) * factor)
    g := Round(g + (255 - g) * factor)
    b := Round(b + (255 - b) * factor)
    return (r << 16) | (g << 8) | b
}
