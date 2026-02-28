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

; ========================= BACKDROP EFFECT STATE =========================

global gFX_BackdropStyle := 0        ; 0=None, 1-6=styles (cycled by C key)
global gFX_BackdropSeedX := 0.0      ; Random offset for turbulence — refreshed on each open/style switch
global gFX_BackdropSeedY := 0.0      ; Gives different pattern without using D2D's seed property
global gFX_BackdropSeedPhase := 0.0  ; Random phase offset (radians) for orbit starting position
global FX_BG_STYLE_NAMES := ["None", "Gradient", "Caustic", "Aurora", "Grain", "Vignette", "Layered"]
global gFX_MouseX := 0.0             ; Mouse X in client coords (physical px)
global gFX_MouseY := 0.0             ; Mouse Y in client coords (physical px)
global gFX_MouseInWindow := false    ; Mouse is inside overlay window

; Initialize GPU effects. Call after gD2D_RT is valid.
; Returns true on success, false if effects unavailable.
FX_GPU_Init() {
    global gD2D_RT, gFX_GPU, gFX_GPUReady, gFX_GPUOutput, gFX_HDRActive, cfg
    global CLSID_D2D1GaussianBlur, CLSID_D2D1Shadow, CLSID_D2D1Flood
    global CLSID_D2D1Crop, CLSID_D2D1ColorMatrix, CLSID_D2D1Saturation
    global CLSID_D2D1Blend, CLSID_D2D1Composite, CLSID_D2D1Turbulence
    global CLSID_D2D1Morphology, CLSID_D2D1DirectionalBlur
    global CLSID_D2D1PointSpecular
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

        ; Cache frequently-used GetOutput() results (avoids COM call per frame)
        gFX_GPUOutput["blur"]  := gFX_GPU["blur"].GetOutput()
        gFX_GPUOutput["blur2"] := gFX_GPU["blur2"].GetOutput()
        gFX_GPUOutput["noiseSat"] := gFX_GPU["noiseSat"].GetOutput()

        ; --- Background turbulence chain (separate from Plasma selection chain) ---
        ; Wrapped in own try/catch: backdrop failure must not kill selection effects.
        try {
            gFX_GPU["bgTurb"]    := gD2D_RT.CreateEffect(CLSID_D2D1Turbulence)
            gFX_GPU["bgCrop"]    := gD2D_RT.CreateEffect(CLSID_D2D1Crop)
            gFX_GPU["bgSat"]     := gD2D_RT.CreateEffect(CLSID_D2D1Saturation)
            gFX_GPU["bgCrop"].SetInput(0, gFX_GPU["bgTurb"].GetOutput())
            gFX_GPU["bgSat"].SetInput(0, gFX_GPU["bgCrop"].GetOutput())
            gFX_GPUOutput["bgSat"] := gFX_GPU["bgSat"].GetOutput()

            ; --- Point Specular chain (uses bgTurb as surface/height map) ---
            try {
                gFX_GPU["specular"]  := gD2D_RT.CreateEffect(CLSID_D2D1PointSpecular)
                gFX_GPU["specCrop"]  := gD2D_RT.CreateEffect(CLSID_D2D1Crop)
                gFX_GPU["specular"].SetInput(0, gFX_GPU["bgTurb"].GetOutput())
                gFX_GPU["specCrop"].SetInput(0, gFX_GPU["specular"].GetOutput())
                gFX_GPUOutput["specCrop"] := gFX_GPU["specCrop"].GetOutput()
            } catch {
                ; PointSpecular may not be available on all systems
            }
        } catch {
            ; Background chains failed — backdrop effects unavailable, selection styles still work
        }

        ; --- HDR compensation: CPU-side gamma on flood colors ---
        ; Previous approach inserted GammaTransfer AFTER blur, but gamma on blurred
        ; premultiplied alpha produces bright pixel artifacts at edges (RGB amplified
        ; above alpha at near-transparent fringes). Since SoftRect floods a single color,
        ; applying gamma to the ARGB before it enters the chain is equivalent and safe.
        hdrActive := false
        if (cfg.PerfHDRCompensation = "on")
            hdrActive := true
        else if (cfg.PerfHDRCompensation = "auto")
            hdrActive := D2D_IsHDRActive()

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

    ; HDR: gamma-correct the flood color CPU-side (avoids premultiplied alpha edge artifacts)
    gFX_GPU["flood"].SetColorF(FX_FLOOD_COLOR, FX_HDRCorrectARGB(argb))

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

    ; HDR: gamma-correct the flood color CPU-side (avoids premultiplied alpha edge artifacts)
    gFX_GPU["flood2"].SetColorF(FX_FLOOD_COLOR, FX_HDRCorrectARGB(argb))
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
    global cfg, gD2D_RT, gFX_GPUReady, gFX_AmbientTime

    baseARGB := cfg.GUI_SelARGB
    userAlpha := ((baseARGB >> 24) & 0xFF) / 255.0
    baseRGB := baseARGB & 0x00FFFFFF

    ; Entrance flourish: shadow lifts from (0,0) to (3,3) offset
    liftT := Anim_GetValue("fx_glass_lift", 1.0)
    shadowOffX := 3.0 * liftT
    shadowOffY := 3.0 * liftT

    ; GPU soft shadow — 6px blur, animated offset
    shadowAlpha := Round(0.45 * 255) << 24
    FX_DrawSoftRect(x, y, w, h, shadowAlpha, 6.0, shadowOffX, shadowOffY)

    ; Ambient glow breathe (Full mode: blur oscillates 8↔12px, ~2s cycle)
    glowBlur := 10.0
    if (gFX_AmbientTime > 0)
        glowBlur := 10.0 + 2.0 * Sin(gFX_AmbientTime * 0.00314)  ; ~2s cycle

    ; Subtle outer glow — selection color, wide blur, very transparent
    glowAlpha := Round(userAlpha * 0.25 * 255) << 24
    glowARGB := glowAlpha | baseRGB
    FX_DrawSoftRect2(x - 4, y - 4, w + 8, h + 8, glowARGB, glowBlur)

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
    global cfg, gD2D_RT, gFX_AmbientTime

    baseARGB := cfg.GUI_SelARGB
    userAlpha := ((baseARGB >> 24) & 0xFF) / 255.0
    baseRGB := baseARGB & 0x00FFFFFF

    ; Brighten the glow color (push toward white for bloom)
    glowR := Min(255, ((baseRGB >> 16) & 0xFF) + 80)
    glowG := Min(255, ((baseRGB >> 8) & 0xFF) + 80)
    glowB := Min(255, (baseRGB & 0xFF) + 80)
    brightRGB := (glowR << 16) | (glowG << 8) | glowB

    ; Entrance flourish: bloom flash — glow intensity spikes then settles
    bloomMult := Anim_GetValue("fx_neon_bloom", 1.0)

    ; Ambient pulse (Full mode: alpha oscillates, ~1.5s cycle)
    ambientMult := 1.0
    if (gFX_AmbientTime > 0)
        ambientMult := 1.0 + 0.15 * Sin(gFX_AmbientTime * 0.00419)  ; ~1.5s cycle

    ; Wide outer glow — bright, large blur (modulated by bloom + ambient)
    outerAlpha := Round(userAlpha * 0.5 * bloomMult * ambientMult * 255)
    if (outerAlpha > 255)
        outerAlpha := 255
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
    global cfg, gD2D_RT, gFX_AmbientTime

    baseARGB := cfg.GUI_SelARGB
    userAlpha := ((baseARGB >> 24) & 0xFF) / 255.0
    baseRGB := baseARGB & 0x00FFFFFF

    ; Deep shadow
    shadowAlpha := Round(0.55 * 255) << 24
    FX_DrawSoftRect(x, y, w, h, shadowAlpha, 8.0, 4, 5)

    ; Entrance flourish: glow flares bright then dims
    flareMult := Anim_GetValue("fx_ember_flare", 1.0)

    ; Ambient firelight flicker (Full mode: R channel ±15, ~2s cycle)
    flickerR := 0
    if (gFX_AmbientTime > 0)
        flickerR := Round(15 * Sin(gFX_AmbientTime * 0.00314))  ; ~2s cycle

    ; Warm amber glow — orange tinted, wide spread
    emberR := Min(255, ((baseRGB >> 16) & 0xFF) + 60 + flickerR)
    emberG := Max(0, ((baseRGB >> 8) & 0xFF))
    emberB := Max(0, (baseRGB & 0xFF) - 30)
    warmRGB := (emberR << 16) | (emberG << 8) | emberB
    warmAlpha := Round(userAlpha * 0.4 * flareMult * 255)
    if (warmAlpha > 255)
        warmAlpha := 255
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
    global cfg, gD2D_RT, gFX_AmbientTime

    baseARGB := cfg.GUI_SelARGB

    ; Ambient shadow breathe (Full mode: blur STDEV oscillates 16↔20px, ~3s cycle)
    blurStdev := 18.0
    if (gFX_AmbientTime > 0) {
        blurStdev := 18.0 + 2.0 * Sin(gFX_AmbientTime * 0.00209)  ; ~3s full cycle
    }

    ; Large, very soft shadow — the star of this style
    shadowAlpha := Round(0.35 * 255) << 24
    FX_DrawSoftRect(x, y, w, h, shadowAlpha, blurStdev, 2, 3)

    ; Flat fill, no gradient
    D2D_FillRoundRect(x, y, w, h, r, D2D_GetCachedBrush(baseARGB))
}

; --- Style: "Holograph" ---
; Multi-color prismatic glow. Dual glow with color-shifted halos.
FX_GPU_DrawSelection_Holograph(x, y, w, h, r) {
    global cfg, gD2D_RT, gFX_AmbientTime

    baseARGB := cfg.GUI_SelARGB
    userAlpha := ((baseARGB >> 24) & 0xFF) / 255.0
    baseRGB := baseARGB & 0x00FFFFFF

    ; Extract base color channels
    bR := (baseRGB >> 16) & 0xFF
    bG := (baseRGB >> 8) & 0xFF
    bB := baseRGB & 0xFF

    ; Entrance flourish: prismatic flash — glow intensity spikes
    flashMult := Anim_GetValue("fx_holo_flash", 1.0)

    ; Ambient glow orbit (Full mode: offsets rotate, ~4s cycle)
    orbitX1 := -2.0
    orbitY1 := -2.0
    orbitX2 := 3.0
    orbitY2 := 3.0
    if (gFX_AmbientTime > 0) {
        angle := gFX_AmbientTime * 0.00157  ; ~4s full rotation
        orbitX1 := -2.0 + 3.0 * Cos(angle)
        orbitY1 := -2.0 + 3.0 * Sin(angle)
        orbitX2 := 3.0 - 3.0 * Cos(angle)
        orbitY2 := 3.0 - 3.0 * Sin(angle)
    }

    ; Color-shifted glow 1: shift toward cyan/blue (animated position)
    c1R := Max(0, bR - 60)
    c1G := Min(255, bG + 40)
    c1B := Min(255, bB + 80)
    c1RGB := (c1R << 16) | (c1G << 8) | c1B
    c1Alpha := Round(userAlpha * 0.4 * flashMult * 255)
    if (c1Alpha > 255)
        c1Alpha := 255
    c1ARGB := (c1Alpha << 24) | c1RGB
    FX_DrawSoftRect(x - 6, y - 8, w + 12, h + 16, c1ARGB, 14.0, orbitX1, orbitY1)

    ; Color-shifted glow 2: shift toward magenta/pink (animated position)
    c2R := Min(255, bR + 60)
    c2G := Max(0, bG - 40)
    c2B := Min(255, bB + 40)
    c2RGB := (c2R << 16) | (c2G << 8) | c2B
    c2Alpha := Round(userAlpha * 0.35 * flashMult * 255)
    if (c2Alpha > 255)
        c2Alpha := 255
    c2ARGB := (c2Alpha << 24) | c2RGB
    FX_DrawSoftRect2(x - 4, y - 4, w + 8, h + 8, c2ARGB, 12.0, orbitX2, orbitY2)

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
    global cfg, gD2D_RT, gFX_GPU, gFX_GPUOutput, LOG_PATH_STORE, gFX_AmbientTime
    global FX_TURB_SIZE, FX_TURB_FREQ, FX_TURB_OCTAVES, FX_TURB_NOISE, FX_TURB_OFFSET
    global FX_CROP_RECT, FX_SAT_SATURATION, D2D1_BORDER_SOFT

    try {
        baseARGB := cfg.GUI_SelARGB
        userAlpha := ((baseARGB >> 24) & 0xFF) / 255.0
        baseRGB := baseARGB & 0x00FFFFFF

        ; GPU soft shadow — 8px blur, offset 3,3
        shadowAlpha := Round(0.45 * 255) << 24
        FX_DrawSoftRect(x, y, w, h, shadowAlpha, 8.0, 3, 3)

        ; Ambient noise drift (Full mode: offset scrolls linearly)
        driftX := 0.0
        driftY := 0.0
        if (gFX_AmbientTime > 0) {
            driftX := gFX_AmbientTime * 0.008  ; slow horizontal drift
            driftY := gFX_AmbientTime * 0.003  ; slower vertical drift
        }

        ; Configure turbulence: low frequency for large plasma swirls
        gFX_GPU["turbulence"].SetVector2(FX_TURB_OFFSET, Float(driftX), Float(driftY))
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

; Apply HDR gamma correction to an ARGB integer (CPU-side).
; Called from FX_DrawSoftRect/FX_DrawSoftRect2 to gamma-correct the flood color
; before it enters the effect chain. This avoids the premultiplied alpha edge
; artifacts that occur when GammaTransfer is applied after GaussianBlur.
; Returns corrected ARGB. No-op when HDR inactive.
FX_HDRCorrectARGB(argb) {
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

; ========================= ANIMATION HOOKS =========================

; Per-style entrance flourish — called on each selection change.
; gpuStyleIndex is 0-based (Glass=0, Neon=1, Frosted=2, Ember=3, Minimal=4, Holograph=5, Plasma=6).
FX_OnSelectionChange(gpuStyleIndex) {
    switch gpuStyleIndex {
        case 0:  ; Glass — shadow lifts into place
            Anim_StartTween("fx_glass_lift", 0.0, 1.0, 200, Anim_EaseOutCubic)
        case 1:  ; Neon — bloom flash: glow spikes then settles
            Anim_StartTween("fx_neon_bloom", 1.5, 1.0, 250, Anim_EaseOutQuad)
        case 3:  ; Ember — warm glow flares bright then dims
            Anim_StartTween("fx_ember_flare", 1.8, 1.0, 300, Anim_EaseOutCubic)
        case 5:  ; Holograph — prismatic flash
            Anim_StartTween("fx_holo_flash", 1.5, 1.0, 200, Anim_EaseOutQuad)
    }
}

; Ambient animation update — called every frame in Full mode only.
; Advances gFX_AmbientTime by the frame delta.
FX_UpdateAmbient(dt) {
    global gFX_AmbientTime
    gFX_AmbientTime += dt
}

; ========================= LIVING BACKDROP EFFECTS =========================
; Subtle animated textures on the acrylic glass background.
; Active only when GPUEffects=true AND AnimationType=Full.
; C key cycles through styles (0=None, 1-6=styles).

; Public dispatcher — called from _GUI_PaintOverlay between clear and content.
FX_DrawBackdrop(wPhys, hPhys, scale) { ; lint-ignore: dead-param
    global gFX_BackdropStyle, gFX_MouseInWindow, gFX_GPU

    try {
        switch gFX_BackdropStyle {
            case 1: _FX_BG_GradientDrift(wPhys, hPhys)
            case 2: _FX_BG_Caustic(wPhys, hPhys)
            case 3: _FX_BG_Aurora(wPhys, hPhys)
            case 4: _FX_BG_Grain(wPhys, hPhys)
            case 5: _FX_BG_Vignette(wPhys, hPhys)
            case 6: _FX_BG_Layered(wPhys, hPhys)
        }

        ; Point specular overlay (mouse spotlight on backdrop texture)
        if (gFX_MouseInWindow && gFX_GPU.Has("specular"))
            _FX_BG_PointSpecular(wPhys, hPhys)
    } catch as e {
        ; Backdrop effect failed — show error for diagnosis
        ToolTip("BG ERR: " e.Message " @ " e.What)
        SetTimer(() => ToolTip(), -3000)
    }
}

; --- Dither: fine noise overlay to break up gradient banding ---
; Call INSIDE a PushLayer — the dither blends with surrounding content.
; Uses bgTurb chain with high frequency for fine-grained noise.
_FX_BG_Dither(wPhys, hPhys) {
    global gD2D_RT, gFX_GPU, gFX_GPUOutput, gFX_BackdropSeedX, gFX_BackdropSeedY
    global FX_TURB_OFFSET, FX_TURB_SIZE, FX_TURB_FREQ, FX_TURB_OCTAVES, FX_TURB_NOISE
    global FX_CROP_RECT, FX_SAT_SATURATION

    if (!gFX_GPU.Has("bgTurb"))
        return

    ; High-frequency noise at full desaturation = subtle luminance jitter
    ; D2D Turbulence OFFSET controls both noise position AND output coordinates.
    ; Seed offsets give unique patterns; crop+targetOffset align to render target origin.
    margin := 20
    ofsX := Float(gFX_BackdropSeedX - margin)
    ofsY := Float(gFX_BackdropSeedY - margin)
    gFX_GPU["bgTurb"].SetVector2(FX_TURB_OFFSET, ofsX, ofsY)
    gFX_GPU["bgTurb"].SetVector2(FX_TURB_SIZE, Float(wPhys + 2 * margin), Float(hPhys + 2 * margin))
    gFX_GPU["bgTurb"].SetVector2(FX_TURB_FREQ, 0.15, 0.15)  ; fine grain
    gFX_GPU["bgTurb"].SetUInt(FX_TURB_OCTAVES, 1)
    gFX_GPU["bgTurb"].SetEnum(FX_TURB_NOISE, 1)  ; turbulence mode (sharper)

    ; Crop within generated area at seed position, shift to origin for rendering
    cropX := Float(gFX_BackdropSeedX)
    cropY := Float(gFX_BackdropSeedY)
    gFX_GPU["bgCrop"].SetRectF(FX_CROP_RECT, cropX, cropY, cropX + wPhys, cropY + hPhys)
    gFX_GPU["bgSat"].SetFloat(FX_SAT_SATURATION, 0.0)  ; grayscale

    static drawPt := Buffer(8)
    NumPut("float", -cropX, "float", -cropY, drawPt)

    ; Very subtle — just enough to break 8-bit banding (CRANKED: 0.08 for visibility)
    layerParams := FX_LayerParams(0, 0, wPhys, hPhys, 0.08)
    gD2D_RT.PushLayer(layerParams, 0)
    gD2D_RT.DrawImage(gFX_GPUOutput["bgSat"], drawPt)
    gD2D_RT.PopLayer()
}

; --- Style 1: Gradient Drift ---
; Slow-rotating warm/cool color wash. Two large soft blobs orbiting ~45s.
_FX_BG_GradientDrift(wPhys, hPhys) {
    global gD2D_RT, gFX_AmbientTime, gFX_BackdropSeedPhase, cfg

    baseARGB := cfg.GUI_AcrylicColor
    baseRGB := baseARGB & 0x00FFFFFF
    bR := (baseRGB >> 16) & 0xFF
    bG := (baseRGB >> 8) & 0xFF
    bB := baseRGB & 0xFF

    ; Warm blob (shift toward amber) — CRANKED
    warmR := Min(255, bR + 120)
    warmG := Min(255, bG + 50)
    warmB := Max(0, bB - 40)
    warmARGB := 0xFF000000 | (warmR << 16) | (warmG << 8) | warmB

    ; Cool blob (shift toward blue) — CRANKED
    coolR := Max(0, bR - 50)
    coolG := Min(255, bG + 40)
    coolB := Min(255, bB + 120)
    coolARGB := 0xFF000000 | (coolR << 16) | (coolG << 8) | coolB

    ; Orbit positions (~45s full rotation, random starting phase)
    angle := gFX_AmbientTime * 0.000140 + gFX_BackdropSeedPhase
    cx := wPhys * 0.5
    cy := hPhys * 0.5
    rx := wPhys * 0.35
    ry := hPhys * 0.35

    ; Opacity layer — CRANKED from 0.06 to 0.40
    layerParams := FX_LayerParams(0, 0, wPhys, hPhys, 0.40)
    gD2D_RT.PushLayer(layerParams, 0)

    ; Warm blob (primary SoftRect chain) — CRANKED size from 160 to 400, blur from 100 to 200
    wx := cx + rx * Cos(angle)
    wy := cy + ry * Sin(angle)
    FX_DrawSoftRect(wx - 200, wy - 200, 400, 400, warmARGB, 200.0)

    ; Cool blob (secondary SoftRect chain) — opposite side — CRANKED
    cx2 := cx - rx * Cos(angle)
    cy2 := cy - ry * Sin(angle)
    FX_DrawSoftRect2(cx2 - 200, cy2 - 200, 400, 400, coolARGB, 200.0)

    ; Noise dither to break up 8-bit gradient banding
    _FX_BG_Dither(wPhys, hPhys)

    gD2D_RT.PopLayer()
}

; --- Style 2: Caustic Ripple ---
; Turbulence noise simulating light refracting through textured glass.
_FX_BG_Caustic(wPhys, hPhys) {
    global gD2D_RT, gFX_GPU, gFX_GPUOutput, gFX_AmbientTime, gFX_BackdropSeedX, gFX_BackdropSeedY
    global FX_TURB_OFFSET, FX_TURB_SIZE, FX_TURB_FREQ, FX_TURB_OCTAVES, FX_TURB_NOISE
    global FX_CROP_RECT, FX_SAT_SATURATION

    if (!gFX_GPU.Has("bgTurb"))
        return

    ; D2D Turbulence noise is perlin(x*freq, y*freq) at absolute coordinates.
    ; OFFSET controls where generation starts AND output position, but doesn't shift
    ; the noise function — so to animate, the CROP must drift through the noise field.
    margin := 100
    driftX := margin * 0.8 * Sin(gFX_AmbientTime * 0.0008)
    driftY := margin * 0.8 * Cos(gFX_AmbientTime * 0.0005)

    ; Fixed generation area around seed position (margin accommodates crop drift)
    gFX_GPU["bgTurb"].SetVector2(FX_TURB_OFFSET, Float(gFX_BackdropSeedX - margin), Float(gFX_BackdropSeedY - margin))
    gFX_GPU["bgTurb"].SetVector2(FX_TURB_SIZE, Float(wPhys + 2 * margin), Float(hPhys + 2 * margin))
    gFX_GPU["bgTurb"].SetVector2(FX_TURB_FREQ, 0.008, 0.008)
    gFX_GPU["bgTurb"].SetUInt(FX_TURB_OCTAVES, 3)
    gFX_GPU["bgTurb"].SetEnum(FX_TURB_NOISE, 0)  ; fractalSum (smoother)

    ; Drifting crop slides through the noise field → visible animation
    cropX := Float(gFX_BackdropSeedX + driftX)
    cropY := Float(gFX_BackdropSeedY + driftY)
    gFX_GPU["bgCrop"].SetRectF(FX_CROP_RECT, cropX, cropY, cropX + wPhys, cropY + hPhys)
    gFX_GPU["bgSat"].SetFloat(FX_SAT_SATURATION, 0.6)  ; CRANKED from 0.2

    ; Shift cropped output to render target origin
    static drawPt := Buffer(8)
    NumPut("float", -cropX, "float", -cropY, drawPt)

    ; Render — CRANKED from 0.05 to 0.40
    layerParams := FX_LayerParams(0, 0, wPhys, hPhys, 0.40)
    gD2D_RT.PushLayer(layerParams, 0)
    gD2D_RT.DrawImage(gFX_GPUOutput["bgSat"], drawPt)
    gD2D_RT.PopLayer()
}

; --- Style 3: Aurora ---
; Three soft colored blobs drifting in slow elliptical orbits.
_FX_BG_Aurora(wPhys, hPhys) {
    global gD2D_RT, gFX_AmbientTime, gFX_BackdropSeedPhase

    cx := wPhys * 0.5
    cy := hPhys * 0.5

    ; Three blobs with different orbit speeds and phases (random base phase)
    ; Blob 1: warm rose
    a1 := gFX_AmbientTime * 0.000200 + gFX_BackdropSeedPhase  ; ~31s cycle
    x1 := cx + wPhys * 0.3 * Cos(a1)
    y1 := cy + hPhys * 0.25 * Sin(a1 * 1.3)
    ; Blob 2: cool cyan
    a2 := gFX_AmbientTime * 0.000160 + 2.09 + gFX_BackdropSeedPhase  ; ~39s cycle
    x2 := cx + wPhys * 0.25 * Cos(a2)
    y2 := cy + hPhys * 0.3 * Sin(a2 * 0.9)
    ; Blob 3: neutral violet
    a3 := gFX_AmbientTime * 0.000120 + 4.19 + gFX_BackdropSeedPhase  ; ~52s cycle
    x3 := cx + wPhys * 0.2 * Cos(a3 * 1.1)
    y3 := cy + hPhys * 0.2 * Sin(a3)

    ; Opacity layer — CRANKED from 0.05 to 0.40
    layerParams := FX_LayerParams(0, 0, wPhys, hPhys, 0.40)
    gD2D_RT.PushLayer(layerParams, 0)

    ; Draw all three — CRANKED size from 120 to 350, blur from 90 to 180, brighter colors
    FX_DrawSoftRect(x1 - 175, y1 - 175, 350, 350, 0xFFFF4488, 180.0)  ; rose
    FX_DrawSoftRect(x2 - 175, y2 - 175, 350, 350, 0xFF4488FF, 180.0)  ; cyan
    FX_DrawSoftRect(x3 - 175, y3 - 175, 350, 350, 0xFFAA44FF, 180.0)  ; violet

    ; Noise dither to break up 8-bit gradient banding
    _FX_BG_Dither(wPhys, hPhys)

    gD2D_RT.PopLayer()
}

; --- Style 4: Grain (Film Grain) ---
; Fine static turbulence texture — frosted glass materiality.
_FX_BG_Grain(wPhys, hPhys) {
    global gD2D_RT, gFX_GPU, gFX_GPUOutput, gFX_AmbientTime, gFX_BackdropSeedX, gFX_BackdropSeedY
    global FX_TURB_OFFSET, FX_TURB_SIZE, FX_TURB_FREQ, FX_TURB_OCTAVES, FX_TURB_NOISE
    global FX_CROP_RECT, FX_SAT_SATURATION

    if (!gFX_GPU.Has("bgTurb"))
        return

    ; Fixed generation area; drifting crop for shimmer animation (see Caustic for details)
    margin := 60
    driftX := margin * 0.8 * Sin(gFX_AmbientTime * 0.003)
    driftY := margin * 0.8 * Cos(gFX_AmbientTime * 0.002)

    gFX_GPU["bgTurb"].SetVector2(FX_TURB_OFFSET, Float(gFX_BackdropSeedX - margin), Float(gFX_BackdropSeedY - margin))
    gFX_GPU["bgTurb"].SetVector2(FX_TURB_SIZE, Float(wPhys + 2 * margin), Float(hPhys + 2 * margin))
    gFX_GPU["bgTurb"].SetVector2(FX_TURB_FREQ, 0.05, 0.05)
    gFX_GPU["bgTurb"].SetUInt(FX_TURB_OCTAVES, 4)
    gFX_GPU["bgTurb"].SetEnum(FX_TURB_NOISE, 1)  ; turbulence (sharper detail)

    ; Drifting crop slides through noise field → shimmer animation
    cropX := Float(gFX_BackdropSeedX + driftX)
    cropY := Float(gFX_BackdropSeedY + driftY)
    gFX_GPU["bgCrop"].SetRectF(FX_CROP_RECT, cropX, cropY, cropX + wPhys, cropY + hPhys)
    gFX_GPU["bgSat"].SetFloat(FX_SAT_SATURATION, 0.0)  ; fully desaturated

    static drawPt := Buffer(8)
    NumPut("float", -cropX, "float", -cropY, drawPt)

    ; Render — CRANKED from 0.03 to 0.30
    layerParams := FX_LayerParams(0, 0, wPhys, hPhys, 0.30)
    gD2D_RT.PushLayer(layerParams, 0)
    gD2D_RT.DrawImage(gFX_GPUOutput["bgSat"], drawPt)
    gD2D_RT.PopLayer()
}

; --- Style 5: Vignette Breathe ---
; Pulsing inner shadow — edges darken/lighten in slow breathing cycle.
_FX_BG_Vignette(wPhys, hPhys) {
    global gD2D_RT, gFX_AmbientTime

    ; Breathing alpha — CRANKED: base 0.50, ±0.15 swing, ~4s cycle
    breath := 0.50 + 0.15 * Sin(gFX_AmbientTime * 0.00157)  ; ~4s cycle
    alpha := Round(breath * 255)
    edgeARGB := (alpha << 24) | 0x000000

    ; Depth of edge bands — CRANKED from 15%/12% to 30%/25%
    depthX := Round(wPhys * 0.30)
    depthY := Round(hPhys * 0.25)

    ; Top edge
    FX_DrawSoftRect(0, -depthY, wPhys, depthY, edgeARGB, Float(depthY * 0.7))
    ; Bottom edge (secondary chain)
    FX_DrawSoftRect2(0, hPhys, wPhys, depthY, edgeARGB, Float(depthY * 0.7))
    ; Left edge
    FX_DrawSoftRect(-depthX, 0, depthX, hPhys, edgeARGB, Float(depthX * 0.7))
    ; Right edge (secondary chain)
    FX_DrawSoftRect2(wPhys, 0, depthX, hPhys, edgeARGB, Float(depthX * 0.7))
}

; --- Style 6: Layered (Combined) ---
; Premium stack: Grain base + Caustic overlay + Vignette breathe.
_FX_BG_Layered(wPhys, hPhys) {
    ; Grain at reduced opacity (drawn inside Grain's own layer at 3%, so effective ~2%)
    _FX_BG_Grain(wPhys, hPhys)
    ; Caustic on top (its own layer at 5%, effective ~3%)
    _FX_BG_Caustic(wPhys, hPhys)
    ; Vignette breathe (draws directly, no extra layer needed)
    _FX_BG_Vignette(wPhys, hPhys)
}

; --- Point Specular (Mouse Spotlight) ---
; D2D PointSpecular effect using bgTurb as surface height map.
; The light catches the backdrop texture as the mouse moves.
_FX_BG_PointSpecular(wPhys, hPhys) {
    global gD2D_RT, gFX_GPU, gFX_GPUOutput, gFX_MouseX, gFX_MouseY, gFX_BackdropSeedX, gFX_BackdropSeedY
    global FX_SPEC_LIGHT_POS, FX_SPEC_EXPONENT, FX_SPEC_SURFACE_SCALE
    global FX_SPEC_CONSTANT, FX_SPEC_COLOR, FX_CROP_RECT
    global FX_TURB_SIZE, FX_TURB_FREQ, FX_TURB_OCTAVES, FX_TURB_NOISE, FX_TURB_OFFSET

    ; Ensure bgTurb has a surface for the specular to interact with
    ; (low-cost minimal noise if not already configured by Caustic/Grain)
    ; Explicit offset at seed position — specular inherits bgTurb's coordinate space.
    margin := 20
    gFX_GPU["bgTurb"].SetVector2(FX_TURB_OFFSET, Float(gFX_BackdropSeedX - margin), Float(gFX_BackdropSeedY - margin))
    gFX_GPU["bgTurb"].SetVector2(FX_TURB_SIZE, Float(wPhys + 2 * margin), Float(hPhys + 2 * margin))
    gFX_GPU["bgTurb"].SetVector2(FX_TURB_FREQ, 0.02, 0.02)
    gFX_GPU["bgTurb"].SetUInt(FX_TURB_OCTAVES, 2)
    gFX_GPU["bgTurb"].SetEnum(FX_TURB_NOISE, 0)

    ; Update specular light position from mouse coordinates (in seed-offset coordinate space)
    ; Z = height above surface (larger = wider/softer cone) — CRANKED Z from 300 to 150 (tighter)
    cropX := Float(gFX_BackdropSeedX)
    cropY := Float(gFX_BackdropSeedY)
    gFX_GPU["specular"].SetVector3(FX_SPEC_LIGHT_POS, Float(gFX_MouseX) + cropX, Float(gFX_MouseY) + cropY, 150.0)
    gFX_GPU["specular"].SetFloat(FX_SPEC_EXPONENT, 10.0)      ; CRANKED from 20 (wider highlight)
    gFX_GPU["specular"].SetFloat(FX_SPEC_SURFACE_SCALE, 4.0)  ; CRANKED from 1.5
    gFX_GPU["specular"].SetFloat(FX_SPEC_CONSTANT, 3.0)       ; CRANKED from 0.8
    gFX_GPU["specular"].SetVector3(FX_SPEC_COLOR, 1.0, 1.0, 1.0)  ; white light

    ; Crop specular output within generated area, shift to origin
    gFX_GPU["specCrop"].SetRectF(FX_CROP_RECT, cropX, cropY, cropX + wPhys, cropY + hPhys)

    static drawPt := Buffer(8)
    NumPut("float", -cropX, "float", -cropY, drawPt)

    ; Render — CRANKED from 0.08 to 0.50
    layerParams := FX_LayerParams(0, 0, wPhys, hPhys, 0.50)
    gD2D_RT.PushLayer(layerParams, 0)
    gD2D_RT.DrawImage(gFX_GPUOutput["specCrop"], drawPt)
    gD2D_RT.PopLayer()
}
