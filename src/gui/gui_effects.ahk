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

global gFX_ShaderLayers := []        ; Array of {key, name, opacity, darkness, desat, speed} per configured layer
global gFX_ShaderTime := Map()       ; layerIndex → {offset, carry, accumulate} — per-layer time state
global gFX_MouseEffect      ; Mouse effect state: {key, name, opacity}
global gFX_SelectionEffect  ; Selection effect state: {key, name, opacity, darkness, desat, speed, isBGShader}
global gFX_HoverEffect      ; Hover effect state: {key, name, opacity, darkness, desat, speed, isBGShader}
gFX_MouseEffect := {key: "", name: "", opacity: 0.0, darkness: 0.0, desat: 0.0, speed: 1.0, reactivity: 1.0}
gFX_SelectionEffect := {key: "", name: "", opacity: 1.0, darkness: 0.0, desat: 0.0, speed: 1.0, isBGShader: false}
gFX_HoverEffect := {key: "", name: "", opacity: 0.8, darkness: 0.0, desat: 0.0, speed: 1.0, isBGShader: false}
global gFX_MouseX := 0.0             ; Mouse X in client coords (physical px)
global gFX_MouseY := 0.0             ; Mouse Y in client coords (physical px)
global gFX_MouseInWindow := false    ; Mouse is inside overlay window
global gFX_MousePrevX := 0.0        ; Previous frame mouse X
global gFX_MousePrevY := 0.0        ; Previous frame mouse Y
global gFX_MouseVelX := 0.0         ; Smoothed velocity X (px/sec)
global gFX_MouseVelY := 0.0         ; Smoothed velocity Y (px/sec)
global gFX_MouseSpeed := 0.0        ; Magnitude of velocity (px/sec)
global gFX_MousePrevValid := false   ; False until first valid sample

; Initialize GPU effects. Call after gD2D_RT is valid.
; Returns true on success, false if effects unavailable.
FX_GPU_Init() {
    global gD2D_RT, gFX_GPU, gFX_GPUReady, gFX_GPUOutput, gFX_HDRActive, cfg
    global gFX_ShaderLayers, gFX_MouseEffect, gFX_SelectionEffect, gFX_HoverEffect
    global SHADER_KEYS ; lint-ignore: phantom-global
    global CLSID_D2D1GaussianBlur, CLSID_D2D1Shadow, CLSID_D2D1Flood
    global CLSID_D2D1Crop, CLSID_D2D1ColorMatrix, CLSID_D2D1Saturation
    global CLSID_D2D1Blend, CLSID_D2D1Composite
    global LOG_PATH_PAINT_TIMING

    if (!gD2D_RT)
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

        ; Cache frequently-used GetOutput() results (avoids COM call per frame)
        gFX_GPUOutput["blur"]  := gFX_GPU["blur"].GetOutput()
        gFX_GPUOutput["blur2"] := gFX_GPU["blur2"].GetOutput()

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

        ; --- Background image effect chain: Blur → Saturation → ColorMatrix ---
        ; Wrapped in try/catch: failure falls back to direct DrawBitmap (no effects)
        try {
            global gBGImg_EffectsReady
            gFX_GPU["bgImgBlur"]  := gD2D_RT.CreateEffect(CLSID_D2D1GaussianBlur)
            gFX_GPU["bgImgSat"]   := gD2D_RT.CreateEffect(CLSID_D2D1Saturation)
            gFX_GPU["bgImgColor"] := gD2D_RT.CreateEffect(CLSID_D2D1ColorMatrix)
            ; Wire chain: blur → sat → color
            gFX_GPU["bgImgSat"].SetInput(0, gFX_GPU["bgImgBlur"].GetOutput())
            gFX_GPU["bgImgColor"].SetInput(0, gFX_GPU["bgImgSat"].GetOutput())
            gFX_GPUOutput["bgImgColor"] := gFX_GPU["bgImgColor"].GetOutput()
            ; Shadow effect (independent — not part of blur/sat/color chain)
            gFX_GPU["bgImgShadow"] := gD2D_RT.CreateEffect(CLSID_D2D1Shadow)
            gBGImg_EffectsReady := true
        } catch {
            ; Background image effects unavailable — BGImg_Draw falls back to direct DrawBitmap
        }

        ; Initialize background image bitmap
        BGImg_Init()

        ; Initialize D3D11 shader pipeline + register configured shaders
        ; Wrapped in try/catch: shader failure must not kill selection/backdrop effects
        try {
            if (Shader_Init()) {
                Shader_ExtractTextures()
                _FX_ResolveConfiguredShaders()
                ; Eager-load only configured shaders (not all 150+)
                ; Register source shaders first, then create per-layer aliases
                registered := Map()
                for _, layer in gFX_ShaderLayers {
                    if (layer.key != "" && !registered.Has(layer.key)) {
                        Shader_RegisterByKey(layer.key)
                        registered[layer.key] := true
                    }
                }
                for _, layer in gFX_ShaderLayers {
                    if (layer.key != "")
                        Shader_RegisterAlias(layer.renderKey, layer.key)
                }
                if (gFX_MouseEffect.key != "")
                    Shader_RegisterByKey(gFX_MouseEffect.key)
                if (gFX_SelectionEffect.key != "")
                    Shader_RegisterByKey(gFX_SelectionEffect.key)
                if (gFX_HoverEffect.key != "")
                    Shader_RegisterByKey(gFX_HoverEffect.key)
                _FX_InitShaderTime()
            }
        } catch as shaderErr {
            ; Shader pipeline unavailable — shader layer won't render,
            ; but all D2D-based effects (selection + backdrop styles 1-6) still work.
            if (cfg.DiagShaderLog) {
                global LOG_PATH_SHADER
                LogAppend(LOG_PATH_SHADER, "FX_GPU_Init shader EXCEPTION: " shaderErr.Message " @ " shaderErr.What)
            }
        }

        return true
    } catch as e {
        FX_GPU_Dispose()
        return false
    }
}

; Release all cached effects. Safe to call multiple times.
FX_GPU_Dispose() {
    global gFX_GPU, gFX_GPUReady, gFX_GPUOutput, gFX_HDRActive, gFX_ShaderTime
    global gFX_ShaderLayers, gFX_MouseEffect, gFX_SelectionEffect, gFX_HoverEffect
    ; Release background image resources (bitmap depends on render target)
    BGImg_Dispose()
    ; Release cached output images first (prevent dangling refs)
    gFX_GPUOutput := Map()
    ; Release effects (ID2DBase.__Delete handles ObjRelease)
    gFX_GPU := Map()
    gFX_GPUReady := false
    gFX_HDRActive := false
    ; Release shader resources
    gFX_ShaderTime := Map()
    gFX_ShaderLayers := []
    gFX_MouseEffect := {key: "", name: "", opacity: 0.0, darkness: 0.0, desat: 0.0, speed: 1.0, reactivity: 1.0}
    gFX_SelectionEffect := {key: "", name: "", opacity: 1.0, darkness: 0.0, desat: 0.0, speed: 1.0, isBGShader: false}
    gFX_HoverEffect := {key: "", name: "", opacity: 0.8, darkness: 0.0, desat: 0.0, speed: 1.0, isBGShader: false}
    Shader_Cleanup()
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

    flood := gFX_GPU["flood"], crop := gFX_GPU["crop"], blur := gFX_GPU["blur"]

    ; HDR: gamma-correct the flood color CPU-side (avoids premultiplied alpha edge artifacts)
    flood.SetColorF(FX_FLOOD_COLOR, FX_HDRCorrectARGB(argb))

    ; Configure crop to the rectangle bounds
    crop.SetRectF(FX_CROP_RECT, Float(x), Float(y), Float(x + w), Float(y + h))
    crop.SetEnum(1, D2D1_BORDER_SOFT)  ; soft border for smooth blur

    ; Configure blur
    blur.SetFloat(FX_BLUR_STDEV, blurStdDev)
    blur.SetEnum(FX_BLUR_BORDER_MODE, D2D1_BORDER_SOFT)

    ; Draw at offset position
    if (offsetX != 0 || offsetY != 0) {
        static drawPt := Buffer(8)
        NumPut("float", Float(offsetX), "float", Float(offsetY), drawPt)
        gD2D_RT.DrawImage(gFX_GPUOutput["blur"], drawPt)
    } else {
        gD2D_RT.DrawImage(gFX_GPUOutput["blur"])
    }
}

; Draw a soft rectangle using the secondary chain (flood2→crop2→blur2).
; Allows drawing two different soft rects without reconfiguring the primary chain.
FX_DrawSoftRect2(x, y, w, h, argb, blurStdDev, offsetX := 0, offsetY := 0) {
    global gD2D_RT, gFX_GPU, gFX_GPUOutput
    global FX_FLOOD_COLOR, FX_CROP_RECT, FX_BLUR_STDEV, FX_BLUR_BORDER_MODE, D2D1_BORDER_SOFT

    flood2 := gFX_GPU["flood2"], crop2 := gFX_GPU["crop2"], blur2 := gFX_GPU["blur2"]

    ; HDR: gamma-correct the flood color CPU-side (avoids premultiplied alpha edge artifacts)
    flood2.SetColorF(FX_FLOOD_COLOR, FX_HDRCorrectARGB(argb))
    crop2.SetRectF(FX_CROP_RECT, Float(x), Float(y), Float(x + w), Float(y + h))
    crop2.SetEnum(1, D2D1_BORDER_SOFT)
    blur2.SetFloat(FX_BLUR_STDEV, blurStdDev)
    blur2.SetEnum(FX_BLUR_BORDER_MODE, D2D1_BORDER_SOFT)

    if (offsetX != 0 || offsetY != 0) {
        static drawPt := Buffer(8)
        NumPut("float", Float(offsetX), "float", Float(offsetY), drawPt)
        gD2D_RT.DrawImage(gFX_GPUOutput["blur2"], drawPt)
    } else {
        gD2D_RT.DrawImage(gFX_GPUOutput["blur2"])
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
FX_GPU_DrawHover(x, y, w, h, rad) {
    global cfg
    baseARGB := cfg.GUI_HoverARGB
    if ((baseARGB >> 24) = 0 && cfg.GUI_HovBorderWidthPx <= 0)
        return  ; fully transparent fill + no border — nothing to draw
    if ((baseARGB >> 24) > 0)
        D2D_FillRoundRect(x, y, w, h, rad, D2D_GetCachedBrush(baseARGB))
    bw := cfg.GUI_HovBorderWidthPx
    if (bw > 0) {
        half := bw / 2
        D2D_StrokeRoundRect(x + half, y + half, w - bw, h - bw, rad, D2D_GetCachedBrush(cfg.GUI_HovBorderARGB), bw)
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

; Reset mouse velocity state (call when overlay hides/shows).
FX_ResetMouseVelocity() {
    global gFX_MouseVelX, gFX_MouseVelY, gFX_MouseSpeed, gFX_MousePrevValid
    gFX_MouseVelX := 0.0
    gFX_MouseVelY := 0.0
    gFX_MouseSpeed := 0.0
    gFX_MousePrevValid := false
}

; Ambient animation update — called every frame.
; Advances gFX_AmbientTime by the frame delta.
FX_UpdateAmbient(dt) {
    global gFX_AmbientTime
    gFX_AmbientTime += dt
}

; ========================= MULTI-LAYER SHADER SYSTEM =========================

; Pre-render all active shader layers (D3D11 pipeline). Called BEFORE D2D BeginDraw.
FX_PreRenderShaderLayers(w, h) {
    Profiler.Enter("FX_PreRenderShaderLayers") ; @profile
    global gFX_ShaderLayers, gShader_Ready, gFX_AmbientTime, gFX_ShaderTime ; lint-ignore: phantom-global (gShader_Ready in src/lib/d2d_shader.ahk)
    global gFX_GPUReady, cfg

    if (!gShader_Ready || !gFX_GPUReady || gFX_ShaderLayers.Length = 0) {
        Profiler.Leave() ; @profile
        return
    }

    for _, layer in gFX_ShaderLayers {
        if (layer.key = "")
            continue

        ; Compute effective time: (ambient / 1000) * speed + offset + carry
        ; Time state is per-layer (keyed by layerIndex), not per-shader
        baseTime := gFX_AmbientTime / 1000.0
        if (gFX_ShaderTime.Has(layer.layerIndex)) {
            t := gFX_ShaderTime[layer.layerIndex]
            baseTime := t.offset + t.carry + (gFX_AmbientTime / 1000.0)
        }
        effectiveTime := baseTime * layer.speed

        try {
            Shader_PreRender(layer.renderKey, w, h, effectiveTime, layer.darkness, layer.desat, layer.opacity)
        } catch as e {
            global LOG_PATH_SHADER
            errDetail := "Shader ERR [" layer.renderKey "]: " e.Message " @ " e.What
            if (e.HasProp("Extra") && e.Extra != "")
                errDetail .= " extra=" e.Extra
            if (e.HasProp("Number") && e.Number != 0)
                errDetail .= " hr=" Format("0x{:08x}", e.Number & 0xFFFFFFFF)
            ToolTip(errDetail)
            SetTimer(() => ToolTip(), -5000)
            if (cfg.DiagShaderLog)
                LogAppend(LOG_PATH_SHADER, errDetail)
        }
    }
    Profiler.Leave() ; @profile
}

; Draw all active shader layers inside D2D BeginDraw.
; Opacity is baked into shader output via AT_PostProcess — no PushLayer needed.
FX_DrawShaderLayers(wPhys, hPhys) { ; lint-ignore: dead-param
    Profiler.Enter("FX_DrawShaderLayers") ; @profile
    global gD2D_RT, gFX_ShaderLayers, gShader_Ready ; lint-ignore: phantom-global (gShader_Ready in src/lib/d2d_shader.ahk)

    if (!gShader_Ready || gFX_ShaderLayers.Length = 0) {
        Profiler.Leave() ; @profile
        return
    }

    for _, layer in gFX_ShaderLayers {
        if (layer.key = "")
            continue
        pBitmap := Shader_GetBitmap(layer.renderKey)
        if (pBitmap)
            gD2D_RT.DrawImage(pBitmap)
    }
    Profiler.Leave() ; @profile
}

; ========================= MOUSE EFFECT =========================

; Pre-render the mouse effect (D3D11 pipeline). Called BEFORE D2D BeginDraw.
FX_PreRenderMouseEffect(w, h) {
    Profiler.Enter("FX_PreRenderMouseEffect") ; @profile
    global gFX_MouseEffect, gShader_Ready, gFX_GPUReady, gFX_AmbientTime, gFX_ShaderTime ; lint-ignore: phantom-global
    global gFX_MouseX, gFX_MouseY, gFX_MouseInWindow, cfg
    global gFX_MousePrevX, gFX_MousePrevY, gFX_MouseVelX, gFX_MouseVelY, gFX_MouseSpeed, gFX_MousePrevValid

    if (gFX_MouseEffect.key = "" || !gShader_Ready || !gFX_GPUReady) {
        Profiler.Leave() ; @profile
        return
    }

    ; --- Compute mouse velocity (CPU-side, per frame) ---
    baseTime := gFX_AmbientTime / 1000.0 * gFX_MouseEffect.speed
    if (gFX_ShaderTime.Has(gFX_MouseEffect.key)) {
        t := gFX_ShaderTime[gFX_MouseEffect.key]
        baseTime := (t.offset + t.carry + (gFX_AmbientTime / 1000.0)) * gFX_MouseEffect.speed
    }

    static prevTime := 0.0
    dtSec := (prevTime > 0) ? baseTime - prevTime : 0.0
    prevTime := baseTime

    if (!gFX_MouseInWindow) {
        ; Mouse left window — reset velocity state
        gFX_MouseVelX := 0.0
        gFX_MouseVelY := 0.0
        gFX_MouseSpeed := 0.0
        gFX_MousePrevValid := false
    } else if (dtSec < 0.0001) {
        ; dt too small (first frame or timing catch-up) — keep last values
    } else if (!gFX_MousePrevValid) {
        ; First valid sample — seed previous position, zero velocity
        gFX_MousePrevX := gFX_MouseX
        gFX_MousePrevY := gFX_MouseY
        gFX_MousePrevValid := true
    } else {
        ; Compute raw velocity (px/sec) and smooth with exponential filter
        rawVelX := (gFX_MouseX - gFX_MousePrevX) / dtSec
        rawVelY := (gFX_MouseY - gFX_MousePrevY) / dtSec
        alpha := 0.3
        gFX_MouseVelX := gFX_MouseVelX * (1.0 - alpha) + rawVelX * alpha
        gFX_MouseVelY := gFX_MouseVelY * (1.0 - alpha) + rawVelY * alpha
        gFX_MouseSpeed := Sqrt(gFX_MouseVelX * gFX_MouseVelX + gFX_MouseVelY * gFX_MouseVelY)
        gFX_MousePrevX := gFX_MouseX
        gFX_MousePrevY := gFX_MouseY
    }

    ; --- Adaptive frame skip: skip mouse shader when it exceeded budget last frame ---
    global gAnim_FrameCapMs
    static mouseSkipNext := false
    static mouseLastRenderMs := 0.0

    if (cfg.PerfAdaptiveMouseFPS && mouseSkipNext) {
        mouseSkipNext := false  ; always render the frame after a skip
        Profiler.Leave() ; @profile
        return
    }

    tBefore := QPC()
    try {
        Shader_PreRender(gFX_MouseEffect.key, w, h, baseTime,
            gFX_MouseEffect.darkness, gFX_MouseEffect.desat, gFX_MouseEffect.opacity,
            gFX_MouseX, gFX_MouseY, gFX_MouseVelX, gFX_MouseVelY, gFX_MouseSpeed)
    } catch as e {
        global LOG_PATH_SHADER
        errDetail := "Mouse shader ERR [" gFX_MouseEffect.key "]: " e.Message " @ " e.What
        ToolTip(errDetail)
        SetTimer(() => ToolTip(), -5000)
        if (cfg.DiagShaderLog)
            LogAppend(LOG_PATH_SHADER, errDetail)
    }
    mouseLastRenderMs := QPC() - tBefore

    ; If the mouse shader alone took more than half the frame budget, skip next frame
    if (cfg.PerfAdaptiveMouseFPS && mouseLastRenderMs > gAnim_FrameCapMs * 0.5)
        mouseSkipNext := true
    Profiler.Leave() ; @profile
}

; Draw the mouse effect inside D2D BeginDraw.
FX_DrawMouseEffect(wPhys, hPhys) { ; lint-ignore: dead-param
    Profiler.Enter("FX_DrawMouseEffect") ; @profile
    global gD2D_RT, gFX_MouseEffect, gShader_Ready ; lint-ignore: phantom-global

    if (gFX_MouseEffect.key = "" || !gShader_Ready) {
        Profiler.Leave() ; @profile
        return
    }

    pBitmap := Shader_GetBitmap(gFX_MouseEffect.key)
    if (pBitmap)
        gD2D_RT.DrawImage(pBitmap)
    Profiler.Leave() ; @profile
}

; ========================= SELECTION EFFECT =========================

; Pre-render the selection shader. Called DURING paint (needs selection geometry).
; Decomposes ARGB ints to premultiplied float4 RGBA for the shader cbuffer.
FX_PreRenderSelectionEffect(w, h, selX, selY, selW, selH, selARGB, borderARGB, borderWidth, isHovered, entranceT, rowRadius := 0.0) {
    Profiler.Enter("FX_PreRenderSelectionEffect") ; @profile
    global gFX_SelectionEffect, gShader_Ready, gFX_GPUReady, gFX_AmbientTime, gFX_ShaderTime ; lint-ignore: phantom-global
    global gShader_Registry, cfg ; lint-ignore: phantom-global

    if (gFX_SelectionEffect.key = "" || !gShader_Ready || !gFX_GPUReady) {
        Profiler.Leave() ; @profile
        return
    }

    ; Set selGlow/selIntensity right before render (shared-entry fix with hover)
    if (!gFX_SelectionEffect.isBGShader && gShader_Registry.Has(gFX_SelectionEffect.key)) {
        gShader_Registry[gFX_SelectionEffect.key].selGlow := cfg.GUI_SelectionGlow
        gShader_Registry[gFX_SelectionEffect.key].selIntensity := cfg.GUI_SelectionIntensity
    }

    baseTime := gFX_AmbientTime / 1000.0
    if (gFX_ShaderTime.Has(gFX_SelectionEffect.key)) {
        t := gFX_ShaderTime[gFX_SelectionEffect.key]
        baseTime := t.offset + t.carry + (gFX_AmbientTime / 1000.0)
    }
    baseTime *= gFX_SelectionEffect.speed

    ; Decompose ARGB → premultiplied float4 RGBA
    selA := ((selARGB >> 24) & 0xFF) / 255.0
    selR := (((selARGB >> 16) & 0xFF) / 255.0) * selA
    selG := (((selARGB >> 8) & 0xFF) / 255.0) * selA
    selB := ((selARGB & 0xFF) / 255.0) * selA

    bdrA := ((borderARGB >> 24) & 0xFF) / 255.0
    bdrR := (((borderARGB >> 16) & 0xFF) / 255.0) * bdrA
    bdrG := (((borderARGB >> 8) & 0xFF) / 255.0) * bdrA
    bdrB := ((borderARGB & 0xFF) / 255.0) * bdrA

    ; BG-as-selection Resize mode: render at selection rect size so the shader fills the rect
    renderW := w, renderH := h
    if (gFX_SelectionEffect.isBGShader && cfg.GUI_BGShaderAsSelectionSize = "Resize") {
        renderW := Max(Round(selW), 1)
        renderH := Max(Round(selH), 1)
    }

    ; BG shaders don't read isHovered from the cbuffer, so apply it as opacity multiplier.
    ; Selection: isHovered=1.0 → opacity unchanged. Hover: isHovered=0.5 → half opacity.
    effectOpacity := gFX_SelectionEffect.opacity
    if (gFX_SelectionEffect.isBGShader)
        effectOpacity *= isHovered

    try {
        Shader_PreRender(gFX_SelectionEffect.key, renderW, renderH, baseTime,
            gFX_SelectionEffect.darkness, gFX_SelectionEffect.desat, effectOpacity,
            0, 0, 0.0, 0.0, 0.0,
            selX, selY, selW, selH,
            selR, selG, selB, selA,
            bdrR, bdrG, bdrB, bdrA,
            borderWidth * 1.0, isHovered * 1.0, entranceT * 1.0, rowRadius * 1.0)
    } catch as e {
        global LOG_PATH_SHADER
        errDetail := "Selection shader ERR [" gFX_SelectionEffect.key "]: " e.Message " @ " e.What
        ToolTip(errDetail)
        SetTimer(() => ToolTip(), -5000)
        if (cfg.DiagShaderLog)
            LogAppend(LOG_PATH_SHADER, errDetail)
    }
    Profiler.Leave() ; @profile
}

; Draw the selection effect inside D2D BeginDraw.
; selX/selY/selW/selH/rad are only needed for BG-as-selection (clipping + border).
FX_DrawSelectionEffect(wPhys, hPhys, selX := 0, selY := 0, selW := 0, selH := 0, rad := 0) { ; lint-ignore: dead-param
    Profiler.Enter("FX_DrawSelectionEffect") ; @profile
    global gD2D_RT, gFX_SelectionEffect, gShader_Ready, cfg ; lint-ignore: phantom-global

    if (gFX_SelectionEffect.key = "" || !gShader_Ready) {
        Profiler.Leave() ; @profile
        return
    }

    pBitmap := Shader_GetBitmap(gFX_SelectionEffect.key)
    if (!pBitmap) {
        Profiler.Leave() ; @profile
        return
    }

    if (gFX_SelectionEffect.isBGShader) {
        static srcRect := Buffer(16), tgtPt := Buffer(8), dstRect := Buffer(16)
        ; Clip shader output to RowRadius rounded rect
        clipped := D2D_PushRoundRectClipLayer(selX, selY, selW, selH, rad)
        if (cfg.GUI_BGShaderAsSelectionSize = "Resize") {
            ; Resize mode: shader rendered at selW×selH — draw full texture into selection rect
            NumPut("float", Float(selX), "float", Float(selY),
                   "float", Float(selX + selW), "float", Float(selY + selH), dstRect)
            NumPut("float", 0.0, "float", 0.0,
                   "float", Float(selW), "float", Float(selH), srcRect)
            gD2D_RT.DrawBitmap({ptr: pBitmap}, dstRect, 1.0, 1, srcRect)
        } else {
            ; Clip mode: shader rendered at full size — crop to selection rect
            NumPut("float", Float(selX), "float", Float(selY),
                   "float", Float(selX + selW), "float", Float(selY + selH), srcRect)
            NumPut("float", Float(selX), "float", Float(selY), tgtPt)
            gD2D_RT.DrawImage(pBitmap, tgtPt, srcRect)
        }
        if (clipped)
            D2D_PopClipLayer()
        ; Draw border on top (outside clip layer so it's not masked)
        bw := cfg.GUI_SelBorderWidthPx
        if (bw > 0) {
            half := bw / 2
            D2D_StrokeRoundRect(selX + half, selY + half, selW - bw, selH - bw, rad,
                D2D_GetCachedBrush(cfg.GUI_SelBorderARGB), bw)
        }
    } else {
        gD2D_RT.DrawImage(pBitmap)
    }
    Profiler.Leave() ; @profile
}

; ========================= SHADER CONFIG RESOLUTION =========================

; Initialize per-layer time state (random offset + accumulate flag).
; Called after shader registration during FX_GPU_Init and after lazy-load.
; Each layer gets its own random offset — even if multiple layers use the same shader.
; Mouse/selection effects are keyed by shader name (single instances, no collision).
; Skips entries already initialized (preserves time state across lazy-load).
_FX_InitShaderTime() {
    global gFX_ShaderTime, gFX_ShaderLayers, gFX_MouseEffect, gFX_SelectionEffect, gFX_HoverEffect
    global gShader_Registry ; lint-ignore: phantom-global

    if (!IsObject(gFX_ShaderTime))
        gFX_ShaderTime := Map()

    ; Per-layer time state (keyed by layerIndex, not shader name)
    for _, layer in gFX_ShaderLayers {
        idx := layer.layerIndex
        if (gFX_ShaderTime.Has(idx))
            continue  ; Already initialized

        minOff := layer.timeOffsetMin
        maxOff := layer.timeOffsetMax
        accum := layer.timeAccumulate

        ; Ensure min <= max
        if (minOff > maxOff)
            maxOff := minOff

        gFX_ShaderTime[idx] := {offset: Random(minOff, maxOff) * 1.0, carry: 0.0, accumulate: accum}
    }

    ; Mouse/selection/hover effects: keyed by shader name, use shader JSON metadata defaults
    for _, shaderKey in [gFX_MouseEffect.key, gFX_SelectionEffect.key, gFX_HoverEffect.key] {
        if (shaderKey = "" || gFX_ShaderTime.Has(shaderKey))
            continue
        minOff := 30, maxOff := 90, accum := true
        if (gShader_Registry.Has(shaderKey)) {
            meta := gShader_Registry[shaderKey].meta
            if (IsObject(meta) && meta.HasOwnProp("timeOffsetMin"))
                minOff := meta.timeOffsetMin
            if (IsObject(meta) && meta.HasOwnProp("timeOffsetMax"))
                maxOff := meta.timeOffsetMax
            if (IsObject(meta) && meta.HasOwnProp("timeAccumulate"))
                accum := meta.timeAccumulate
        }
        if (minOff > maxOff)
            maxOff := minOff
        gFX_ShaderTime[shaderKey] := {offset: Random(minOff, maxOff) * 1.0, carry: 0.0, accumulate: accum}
    }
}

; Initialize shader time for a single shader key (mouse/selection effects).
; Uses shader JSON metadata for offset defaults.
_FX_InitShaderTimeForKey(shaderKey) {
    global gFX_ShaderTime, gShader_Registry ; lint-ignore: phantom-global
    if (shaderKey = "" || gFX_ShaderTime.Has(shaderKey))
        return
    minOff := 30, maxOff := 90, accum := true
    if (gShader_Registry.Has(shaderKey)) {
        meta := gShader_Registry[shaderKey].meta
        if (IsObject(meta) && meta.HasOwnProp("timeOffsetMin"))
            minOff := meta.timeOffsetMin
        if (IsObject(meta) && meta.HasOwnProp("timeOffsetMax"))
            maxOff := meta.timeOffsetMax
        if (IsObject(meta) && meta.HasOwnProp("timeAccumulate"))
            accum := meta.timeAccumulate
    }
    if (minOff > maxOff)
        maxOff := minOff
    gFX_ShaderTime[shaderKey] := {offset: Random(minOff, maxOff) * 1.0, carry: 0.0, accumulate: accum}
}

; Resolve all shader layer configs from cfg.Shader1_* through Shader4_*,
; MouseEffect_*, and GUI_SelectionEffect into runtime state.
_FX_ResolveConfiguredShaders() {
    global gFX_ShaderLayers, gFX_MouseEffect, gFX_SelectionEffect, gFX_HoverEffect, cfg
    global SHADER_KEYS, MOUSE_SHADER_KEYS, SELECTION_SHADER_KEYS ; lint-ignore: phantom-global
    global gShader_Registry ; lint-ignore: phantom-global

    gFX_ShaderLayers := []

    ; Global shader toggle — skip all layer resolution when disabled
    if (!cfg.ShaderUseShaderLayers)
        return

    ; Resolve up to 4 shader layers
    Loop 4 {
        layerKey := cfg.%"Shader" A_Index "_ShaderName"%
        if (layerKey = "")
            continue

        ; Validate key exists in SHADER_KEYS
        found := false
        for _, k in SHADER_KEYS {
            if (k = layerKey) {
                found := true
                break
            }
        }
        if (!found)
            continue

        ; renderKey: per-layer alias so each layer gets its own render target
        ; even when multiple layers use the same shader
        renderKey := layerKey "#" A_Index

        gFX_ShaderLayers.Push({
            key: layerKey,
            renderKey: renderKey,
            name: layerKey,
            layerIndex: A_Index,
            opacity: cfg.%"Shader" A_Index "_ShaderOpacity"%,
            darkness: cfg.%"Shader" A_Index "_ShaderDarkness"%,
            desat: cfg.%"Shader" A_Index "_ShaderDesaturation"%,
            speed: cfg.%"Shader" A_Index "_ShaderSpeed"%,
            timeOffsetMin: cfg.%"Shader" A_Index "_TimeOffsetMin"%,
            timeOffsetMax: cfg.%"Shader" A_Index "_TimeOffsetMax"%,
            timeAccumulate: cfg.%"Shader" A_Index "_TimeAccumulate"%
        })
    }

    ; Resolve mouse effect
    mouseKey := cfg.MouseEffect_UseMouseEffect ? cfg.MouseEffect_Name : ""
    if (mouseKey != "") {
        found := false
        for _, k in MOUSE_SHADER_KEYS {
            if (k = mouseKey) {
                found := true
                break
            }
        }
        if (found) {
            gFX_MouseEffect := {key: mouseKey, name: mouseKey,
                opacity: cfg.MouseEffect_Opacity,
                darkness: cfg.MouseEffect_Darkness,
                desat: cfg.MouseEffect_Desaturation,
                speed: cfg.MouseEffect_Speed,
                reactivity: cfg.MouseEffect_Reactivity}
            ; Set reactivity on the shader registry entry if already registered
            if (gShader_Registry.Has(mouseKey))
                gShader_Registry[mouseKey].reactivity := cfg.MouseEffect_Reactivity
        } else {
            gFX_MouseEffect := {key: "", name: "", opacity: 0.0, darkness: 0.0, desat: 0.0, speed: 1.0, reactivity: 1.0}
        }
    } else {
        gFX_MouseEffect := {key: "", name: "", opacity: 0.0, darkness: 0.0, desat: 0.0, speed: 1.0, reactivity: 1.0}
    }

    ; Resolve selection effect — BG-as-selection overrides dedicated selection shaders
    _emptySelEffect := {key: "", name: "", opacity: 1.0, darkness: 0.0, desat: 0.0, speed: 1.0, isBGShader: false}
    if (!cfg.GUI_UseSelectionEffect) {
        gFX_SelectionEffect := _emptySelEffect
    } else if (cfg.GUI_UseBGShaderAsSelection) {
        bgKey := cfg.GUI_BGShaderAsSelection
        found := false
        for _, k in SHADER_KEYS {
            if (k = bgKey) {
                found := true
                break
            }
        }
        if (found) {
            gFX_SelectionEffect := {key: bgKey, name: bgKey,
                opacity: cfg.GUI_SelectionOpacity,
                darkness: cfg.GUI_SelectionDarkness,
                desat: cfg.GUI_SelectionDesaturation,
                speed: cfg.GUI_SelectionSpeed,
                isBGShader: true}
        } else {
            gFX_SelectionEffect := _emptySelEffect
        }
    } else {
        selKey := cfg.GUI_SelectionEffect
        if (selKey != "" && selKey != "None") {
            found := false
            for _, k in SELECTION_SHADER_KEYS {
                if (k = selKey) {
                    found := true
                    break
                }
            }
            if (found) {
                gFX_SelectionEffect := {key: selKey, name: selKey,
                    opacity: cfg.GUI_SelectionOpacity,
                    darkness: cfg.GUI_SelectionDarkness,
                    desat: cfg.GUI_SelectionDesaturation,
                    speed: cfg.GUI_SelectionSpeed,
                    isBGShader: false}
                if (gShader_Registry.Has(selKey)) {
                    gShader_Registry[selKey].selGlow := cfg.GUI_SelectionGlow
                    gShader_Registry[selKey].selIntensity := cfg.GUI_SelectionIntensity
                }
            } else {
                gFX_SelectionEffect := _emptySelEffect
            }
        } else {
            gFX_SelectionEffect := _emptySelEffect
        }
    }

    ; Resolve hover effect — mirrors selection resolve with hover-specific config
    _emptyHovEffect := {key: "", name: "", opacity: 0.8, darkness: 0.0, desat: 0.0, speed: 1.0, isBGShader: false}
    if (!cfg.GUI_UseHoverSelectionEffect) {
        gFX_HoverEffect := _emptyHovEffect
    } else if (cfg.GUI_UseBGShaderAsHoverSelection) {
        bgKey := cfg.GUI_HoverBGShaderAsSelection
        found := false
        for _, k in SHADER_KEYS {
            if (k = bgKey) {
                found := true
                break
            }
        }
        if (found) {
            gFX_HoverEffect := {key: bgKey, name: bgKey,
                opacity: cfg.GUI_HoverSelectionOpacity,
                darkness: cfg.GUI_HoverSelectionDarkness,
                desat: cfg.GUI_HoverSelectionDesaturation,
                speed: cfg.GUI_HoverSelectionSpeed,
                isBGShader: true}
        } else {
            gFX_HoverEffect := _emptyHovEffect
        }
    } else {
        hovSelKey := cfg.GUI_HoverSelectionEffect
        if (hovSelKey != "" && hovSelKey != "None") {
            found := false
            for _, k in SELECTION_SHADER_KEYS {
                if (k = hovSelKey) {
                    found := true
                    break
                }
            }
            if (found) {
                gFX_HoverEffect := {key: hovSelKey, name: hovSelKey,
                    opacity: cfg.GUI_HoverSelectionOpacity,
                    darkness: cfg.GUI_HoverSelectionDarkness,
                    desat: cfg.GUI_HoverSelectionDesaturation,
                    speed: cfg.GUI_HoverSelectionSpeed,
                    isBGShader: false}
                if (gShader_Registry.Has(hovSelKey)) {
                    gShader_Registry[hovSelKey].selGlow := cfg.GUI_HoverSelectionGlow
                    gShader_Registry[hovSelKey].selIntensity := 1.0
                }
            } else {
                gFX_HoverEffect := _emptyHovEffect
            }
        } else {
            gFX_HoverEffect := _emptyHovEffect
        }
    }
}

; Save shader carry time before gFX_AmbientTime resets.
; Called from Anim_CancelAll (gui_animation.ahk) on overlay hide.
FX_SaveShaderTime() {
    global gFX_ShaderTime, gFX_AmbientTime
    sessionSec := gFX_AmbientTime / 1000.0
    for _, t in gFX_ShaderTime {
        if (t.accumulate)
            t.carry += sessionSec
    }
}

; Check if any shaders are configured (background, mouse, or selection).
; Used by gui_animation.ahk to keep frame loop running for shader animation.
FX_HasActiveShaders() {
    global gFX_ShaderLayers, gFX_MouseEffect, gFX_SelectionEffect, gFX_HoverEffect
    return (gFX_ShaderLayers.Length > 0 || gFX_MouseEffect.key != "" || gFX_SelectionEffect.key != "" || gFX_HoverEffect.key != "")
}

; Release render targets for shaders no longer in any active slot.
_FX_ReleaseInactiveShaders() {
    global gFX_ShaderLayers, gFX_MouseEffect, gFX_SelectionEffect, gFX_HoverEffect
    activeNames := []
    for _, layer in gFX_ShaderLayers {
        if (layer.key != "")
            activeNames.Push(layer.renderKey)
    }
    if (gFX_MouseEffect.key != "")
        activeNames.Push(gFX_MouseEffect.key)
    if (gFX_SelectionEffect.key != "")
        activeNames.Push(gFX_SelectionEffect.key)
    if (gFX_HoverEffect.key != "")
        activeNames.Push(gFX_HoverEffect.key)
    Shader_ReleaseInactive(activeNames)
}

; ========================= SHADER CYCLING =========================

; Cycle the shader for a specific layer (1-based index).
FX_CycleShaderLayer(layerIndex) {
    global gFX_ShaderLayers, gFX_GPUReady, gShader_Ready, cfg ; lint-ignore: phantom-global
    global SHADER_NAMES, SHADER_KEYS ; lint-ignore: phantom-global
    global gShader_Registry ; lint-ignore: phantom-global

    static cycling := false
    if (cycling)
        return
    cycling := true

    if (!gFX_GPUReady || !gShader_Ready) {
        cycling := false
        return
    }

    ; Find current key for this layer (by layerIndex field, not array position)
    currentKey := ""
    layerArrayIdx := 0
    for i, layer in gFX_ShaderLayers {
        if (layer.layerIndex = layerIndex) {
            currentKey := layer.key
            layerArrayIdx := i
            break
        }
    }

    ; Find current index in SHADER_KEYS
    currentIdx := 0  ; 0 = None
    Loop SHADER_KEYS.Length {
        if (SHADER_KEYS[A_Index] = currentKey) {
            currentIdx := A_Index - 1
            break
        }
    }

    ; Cycle forward — just pick the next name, register on-demand
    total := SHADER_NAMES.Length
    currentIdx := Mod(currentIdx + 1, total)

    newKey := (currentIdx = 0) ? "" : SHADER_KEYS[currentIdx + 1]
    newName := SHADER_NAMES[currentIdx + 1]

    ; Register only the shader we need (if not already registered)
    if (newKey != "" && !gShader_Registry.Has(newKey))
        Shader_RegisterByKey(newKey)

    ; Update layer config
    newRenderKey := (newKey != "") ? newKey "#" layerIndex : ""
    if (layerArrayIdx > 0) {
        gFX_ShaderLayers[layerArrayIdx].key := newKey
        gFX_ShaderLayers[layerArrayIdx].renderKey := newRenderKey
        gFX_ShaderLayers[layerArrayIdx].name := newName
    } else if (newKey != "") {
        ; Create new layer from config values
        gFX_ShaderLayers.Push({
            key: newKey, renderKey: newRenderKey, name: newName, layerIndex: layerIndex,
            opacity: cfg.%"Shader" layerIndex "_ShaderOpacity"%,
            darkness: cfg.%"Shader" layerIndex "_ShaderDarkness"%,
            desat: cfg.%"Shader" layerIndex "_ShaderDesaturation"%,
            speed: cfg.%"Shader" layerIndex "_ShaderSpeed"%,
            timeOffsetMin: cfg.%"Shader" layerIndex "_TimeOffsetMin"%,
            timeOffsetMax: cfg.%"Shader" layerIndex "_TimeOffsetMax"%,
            timeAccumulate: cfg.%"Shader" layerIndex "_TimeAccumulate"%
        })
    }

    ; Register per-layer alias so this layer gets its own render target
    if (newKey != "")
        Shader_RegisterAlias(newRenderKey, newKey)

    ; Generate fresh per-layer time offset for this layer
    global gFX_ShaderTime
    if (newKey != "") {
        minOff := 30, maxOff := 90, accum := true
        if (layerArrayIdx > 0) {
            layer := gFX_ShaderLayers[layerArrayIdx]
            if (layer.HasOwnProp("timeOffsetMin"))
                minOff := layer.timeOffsetMin
            if (layer.HasOwnProp("timeOffsetMax"))
                maxOff := layer.timeOffsetMax
            if (layer.HasOwnProp("timeAccumulate"))
                accum := layer.timeAccumulate
        }
        if (minOff > maxOff)
            maxOff := minOff
        gFX_ShaderTime[layerIndex] := {offset: Random(minOff, maxOff) * 1.0, carry: 0.0, accumulate: accum}
    } else if (gFX_ShaderTime.Has(layerIndex)) {
        gFX_ShaderTime.Delete(layerIndex)
    }

    ; Remove empty trailing layers
    while (gFX_ShaderLayers.Length > 0 && gFX_ShaderLayers[gFX_ShaderLayers.Length].key = "")
        gFX_ShaderLayers.Pop()

    _FX_ReleaseInactiveShaders()

    cycling := false

    ToolTip("Layer " layerIndex ": " newName)
    SetTimer(() => ToolTip(), -2000)
    GUI_Repaint()
}

; Cycle the mouse effect.
FX_CycleMouseEffect() {
    global gFX_MouseEffect, gFX_GPUReady, gShader_Ready ; lint-ignore: phantom-global
    global MOUSE_SHADER_NAMES, MOUSE_SHADER_KEYS, gShader_Registry ; lint-ignore: phantom-global

    if (!gFX_GPUReady || !gShader_Ready)
        return

    currentIdx := 0
    Loop MOUSE_SHADER_KEYS.Length {
        if (MOUSE_SHADER_KEYS[A_Index] = gFX_MouseEffect.key) {
            currentIdx := A_Index - 1
            break
        }
    }

    ; Cycle forward — register on-demand
    total := MOUSE_SHADER_NAMES.Length
    currentIdx := Mod(currentIdx + 1, total)

    if (currentIdx = 0) {
        gFX_MouseEffect := {key: "", name: "", opacity: 0.30, darkness: gFX_MouseEffect.darkness,
            desat: gFX_MouseEffect.desat, speed: gFX_MouseEffect.speed, reactivity: gFX_MouseEffect.reactivity}
    } else {
        newKey := MOUSE_SHADER_KEYS[currentIdx + 1]
        if (!gShader_Registry.Has(newKey))
            Shader_RegisterByKey(newKey)
        if (gShader_Registry.Has(newKey))
            gShader_Registry[newKey].reactivity := gFX_MouseEffect.reactivity
        gFX_MouseEffect := {key: newKey, name: MOUSE_SHADER_NAMES[currentIdx + 1],
            opacity: gFX_MouseEffect.opacity, darkness: gFX_MouseEffect.darkness,
            desat: gFX_MouseEffect.desat, speed: gFX_MouseEffect.speed, reactivity: gFX_MouseEffect.reactivity}
        ; Init time state for the new shader (keyed by name for mouse/selection)
        _FX_InitShaderTimeForKey(newKey)
    }

    _FX_ReleaseInactiveShaders()

    ToolTip("Mouse: " (currentIdx = 0 ? "None" : MOUSE_SHADER_NAMES[currentIdx + 1]))
    SetTimer(() => ToolTip(), -2000)
    GUI_Repaint()
}

; Cycle the selection effect.
; When UseBGShaderAsSelection is active, cycles through BG shaders instead.
FX_CycleSelectionEffect() {
    global gFX_SelectionEffect, gFX_GPUReady, gShader_Ready ; lint-ignore: phantom-global
    global SELECTION_SHADER_NAMES, SELECTION_SHADER_KEYS, gShader_Registry ; lint-ignore: phantom-global
    global SHADER_NAMES, SHADER_KEYS, cfg ; lint-ignore: phantom-global

    if (!gFX_GPUReady || !gShader_Ready)
        return

    useBG := cfg.GUI_UseBGShaderAsSelection
    names := useBG ? SHADER_NAMES : SELECTION_SHADER_NAMES
    keys := useBG ? SHADER_KEYS : SELECTION_SHADER_KEYS

    currentIdx := 0
    Loop keys.Length {
        if (keys[A_Index] = gFX_SelectionEffect.key) {
            currentIdx := A_Index - 1
            break
        }
    }

    ; Cycle forward — register on-demand
    total := names.Length
    currentIdx := Mod(currentIdx + 1, total)

    if (currentIdx = 0) {
        gFX_SelectionEffect := {key: "", name: "",
            opacity: cfg.GUI_SelectionOpacity, darkness: cfg.GUI_SelectionDarkness,
            desat: cfg.GUI_SelectionDesaturation, speed: cfg.GUI_SelectionSpeed,
            isBGShader: false}
    } else {
        newKey := keys[currentIdx + 1]
        if (!gShader_Registry.Has(newKey))
            Shader_RegisterByKey(newKey)
        gFX_SelectionEffect := {key: newKey, name: names[currentIdx + 1],
            opacity: cfg.GUI_SelectionOpacity, darkness: cfg.GUI_SelectionDarkness,
            desat: cfg.GUI_SelectionDesaturation, speed: cfg.GUI_SelectionSpeed,
            isBGShader: useBG}
        if (!useBG && gShader_Registry.Has(newKey)) {
            gShader_Registry[newKey].selGlow := cfg.GUI_SelectionGlow
            gShader_Registry[newKey].selIntensity := cfg.GUI_SelectionIntensity
        }
        ; Init time state for the new shader (keyed by name for mouse/selection)
        _FX_InitShaderTimeForKey(newKey)
    }

    _FX_ReleaseInactiveShaders()

    ToolTip("Selection: " (currentIdx = 0 ? "None" : names[currentIdx + 1]))
    SetTimer(() => ToolTip(), -2000)
    GUI_Repaint()
}

; ========================= HOVER EFFECT =========================

; Pre-render the hover shader. Mirrors FX_PreRenderSelectionEffect but uses hover config.
; Sets selGlow/selIntensity on the registry entry right before render to avoid shared-entry conflict.
FX_PreRenderHoverEffect(w, h, selX, selY, selW, selH, selARGB, borderARGB, borderWidth, entranceT, rowRadius := 0.0) {
    Profiler.Enter("FX_PreRenderHoverEffect") ; @profile
    global gFX_HoverEffect, gShader_Ready, gFX_GPUReady, gFX_AmbientTime, gFX_ShaderTime ; lint-ignore: phantom-global
    global gShader_Registry, cfg ; lint-ignore: phantom-global

    if (gFX_HoverEffect.key = "" || !gShader_Ready || !gFX_GPUReady) {
        Profiler.Leave() ; @profile
        return
    }

    ; Set selGlow/selIntensity right before render (shared-entry fix)
    hovIntensity := cfg.GUI_HoverSelectionIntensity
    if (gShader_Registry.Has(gFX_HoverEffect.key)) {
        gShader_Registry[gFX_HoverEffect.key].selGlow := cfg.GUI_HoverSelectionGlow
        gShader_Registry[gFX_HoverEffect.key].selIntensity := hovIntensity
    }

    baseTime := gFX_AmbientTime / 1000.0
    if (gFX_ShaderTime.Has(gFX_HoverEffect.key)) {
        t := gFX_ShaderTime[gFX_HoverEffect.key]
        baseTime := t.offset + t.carry + (gFX_AmbientTime / 1000.0)
    }
    baseTime *= gFX_HoverEffect.speed

    ; Decompose ARGB → premultiplied float4 RGBA
    selA := ((selARGB >> 24) & 0xFF) / 255.0
    selR := (((selARGB >> 16) & 0xFF) / 255.0) * selA
    selG := (((selARGB >> 8) & 0xFF) / 255.0) * selA
    selB := ((selARGB & 0xFF) / 255.0) * selA

    bdrA := ((borderARGB >> 24) & 0xFF) / 255.0
    bdrR := (((borderARGB >> 16) & 0xFF) / 255.0) * bdrA
    bdrG := (((borderARGB >> 8) & 0xFF) / 255.0) * bdrA
    bdrB := ((borderARGB & 0xFF) / 255.0) * bdrA

    ; BG-as-hover Resize mode: render at hover rect size
    renderW := w, renderH := h
    if (gFX_HoverEffect.isBGShader && cfg.GUI_HoverBGShaderAsSelectionSize = "Resize") {
        renderW := Max(Round(selW), 1)
        renderH := Max(Round(selH), 1)
    }

    ; BG shaders don't read isHovered/selIntensity, so apply intensity as opacity multiplier
    effectOpacity := gFX_HoverEffect.opacity
    if (gFX_HoverEffect.isBGShader)
        effectOpacity *= hovIntensity

    try {
        Shader_PreRender(gFX_HoverEffect.key, renderW, renderH, baseTime,
            gFX_HoverEffect.darkness, gFX_HoverEffect.desat, effectOpacity,
            0, 0, 0.0, 0.0, 0.0,
            selX, selY, selW, selH,
            selR, selG, selB, selA,
            bdrR, bdrG, bdrB, bdrA,
            borderWidth * 1.0, hovIntensity * 1.0, entranceT * 1.0, rowRadius * 1.0)
    } catch as e {
        global LOG_PATH_SHADER
        errDetail := "Hover shader ERR [" gFX_HoverEffect.key "]: " e.Message " @ " e.What
        ToolTip(errDetail)
        SetTimer(() => ToolTip(), -5000)
        if (cfg.DiagShaderLog)
            LogAppend(LOG_PATH_SHADER, errDetail)
    }
    Profiler.Leave() ; @profile
}

; Draw the hover effect inside D2D BeginDraw.
FX_DrawHoverEffect(wPhys, hPhys, selX, selY, selW, selH, rad) { ; lint-ignore: dead-param
    Profiler.Enter("FX_DrawHoverEffect") ; @profile
    global gD2D_RT, gFX_HoverEffect, gShader_Ready, cfg ; lint-ignore: phantom-global

    if (gFX_HoverEffect.key = "" || !gShader_Ready) {
        Profiler.Leave() ; @profile
        return
    }

    pBitmap := Shader_GetBitmap(gFX_HoverEffect.key)
    if (!pBitmap) {
        Profiler.Leave() ; @profile
        return
    }

    if (gFX_HoverEffect.isBGShader) {
        static hov_srcRect := Buffer(16), hov_tgtPt := Buffer(8), hov_dstRect := Buffer(16)
        ; Clip shader output to RowRadius rounded rect
        clipped := D2D_PushRoundRectClipLayer(selX, selY, selW, selH, rad)
        if (cfg.GUI_HoverBGShaderAsSelectionSize = "Resize") {
            NumPut("float", Float(selX), "float", Float(selY),
                   "float", Float(selX + selW), "float", Float(selY + selH), hov_dstRect)
            NumPut("float", 0.0, "float", 0.0,
                   "float", Float(selW), "float", Float(selH), hov_srcRect)
            gD2D_RT.DrawBitmap({ptr: pBitmap}, hov_dstRect, 1.0, 1, hov_srcRect)
        } else {
            NumPut("float", Float(selX), "float", Float(selY),
                   "float", Float(selX + selW), "float", Float(selY + selH), hov_srcRect)
            NumPut("float", Float(selX), "float", Float(selY), hov_tgtPt)
            gD2D_RT.DrawImage(pBitmap, hov_tgtPt, hov_srcRect)
        }
        if (clipped)
            D2D_PopClipLayer()
        ; Draw border on top (outside clip layer so it's not masked)
        bw := cfg.GUI_HovBorderWidthPx
        if (bw > 0) {
            half := bw / 2
            D2D_StrokeRoundRect(selX + half, selY + half, selW - bw, selH - bw, rad,
                D2D_GetCachedBrush(cfg.GUI_HovBorderARGB), bw)
        }
    } else {
        gD2D_RT.DrawImage(pBitmap)
    }
    Profiler.Leave() ; @profile
}

; Cycle the hover effect.
; When UseBGShaderAsHoverSelection is active, cycles through BG shaders instead.
FX_CycleHoverEffect() {
    global gFX_HoverEffect, gFX_GPUReady, gShader_Ready ; lint-ignore: phantom-global
    global SELECTION_SHADER_NAMES, SELECTION_SHADER_KEYS, gShader_Registry ; lint-ignore: phantom-global
    global SHADER_NAMES, SHADER_KEYS, cfg ; lint-ignore: phantom-global

    if (!gFX_GPUReady || !gShader_Ready)
        return

    useBG := cfg.GUI_UseBGShaderAsHoverSelection
    names := useBG ? SHADER_NAMES : SELECTION_SHADER_NAMES
    keys := useBG ? SHADER_KEYS : SELECTION_SHADER_KEYS

    currentIdx := 0
    Loop keys.Length {
        if (keys[A_Index] = gFX_HoverEffect.key) {
            currentIdx := A_Index - 1
            break
        }
    }

    ; Cycle forward — register on-demand
    total := names.Length
    currentIdx := Mod(currentIdx + 1, total)

    if (currentIdx = 0) {
        gFX_HoverEffect := {key: "", name: "",
            opacity: cfg.GUI_HoverSelectionOpacity, darkness: cfg.GUI_HoverSelectionDarkness,
            desat: cfg.GUI_HoverSelectionDesaturation, speed: cfg.GUI_HoverSelectionSpeed,
            isBGShader: false}
    } else {
        newKey := keys[currentIdx + 1]
        if (!gShader_Registry.Has(newKey))
            Shader_RegisterByKey(newKey)
        gFX_HoverEffect := {key: newKey, name: names[currentIdx + 1],
            opacity: cfg.GUI_HoverSelectionOpacity, darkness: cfg.GUI_HoverSelectionDarkness,
            desat: cfg.GUI_HoverSelectionDesaturation, speed: cfg.GUI_HoverSelectionSpeed,
            isBGShader: useBG}
        if (!useBG && gShader_Registry.Has(newKey)) {
            gShader_Registry[newKey].selGlow := cfg.GUI_HoverSelectionGlow
            gShader_Registry[newKey].selIntensity := 1.0
        }
        ; Init time state for the new shader
        _FX_InitShaderTimeForKey(newKey)
    }

    _FX_ReleaseInactiveShaders()

    ToolTip("Hover: " (currentIdx = 0 ? "None" : names[currentIdx + 1]))
    SetTimer(() => ToolTip(), -2000)
    GUI_Repaint()
}

