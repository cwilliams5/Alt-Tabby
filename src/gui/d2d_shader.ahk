#Requires AutoHotkey v2.0
; D3D11 HLSL Shader Pipeline — runs converted Shadertoy shaders as backdrop effects.
; Renders to a DXGI texture, then composited via DrawImage through a shared DXGI surface
; (zero-copy: D2D reads the texture directly on GPU, no CPU readback).
;
; Architecture:
;   Shader_Init()     — get immediate context, compile fullscreen VS, create cbuffer
;   _Shader_Register() — compile HLSL pixel shader, store in registry (with metadata)
;   Shader_PreRender()— lazy create/resize RT, bind pipeline, Draw(3,0)
;   Shader_GetBitmap()— return ID2D1Bitmap1 for D2D DrawImage
;   Shader_Cleanup()  — release all D3D11 resources
#Warn VarUnset, Off

; ========================= GLOBALS =========================

global gShader_D3DCtx := 0       ; ID3D11DeviceContext (immediate)
global gShader_VS := 0           ; ID3D11VertexShader (fullscreen triangle, shared)
global gShader_CBuffer := 0      ; ID3D11Buffer (32-byte constant buffer, shared)
global gShader_Sampler := 0      ; ID3D11SamplerState (wrap + linear, shared)
global gShader_Registry := Map() ; name → {ps, tex, rtv, bitmap, w, h, meta, srvs}
global gShader_Ready := false    ; true after Shader_Init succeeds
global gShader_FrameCount := 0   ; frame counter for cbuffer
global gShader_StateDirty := true ; dirty flag: D3D11 common state needs re-binding
global gShader_BatchMode := false  ; when true, defer RT/SRV unbind to Shader_EndBatch
global _gShader_GdipToken := 0    ; GDI+ startup token (for shutdown on cleanup)

; Mark D3D11 common pipeline state as needing re-binding.
; Call after D2D operations that share the device context (e.g., BeginDraw).
Shader_InvalidateState() {
    global gShader_StateDirty, gShader_BatchMode
    gShader_StateDirty := true
    gShader_BatchMode := false  ; Safety: clear stale batch from exception
}

; Begin a pre-BeginDraw batch: defer RT/SRV unbind between sequential PreRender calls.
Shader_BeginBatch() {
    global gShader_BatchMode
    gShader_BatchMode := true
}

; End batch: unbind RT and SRV slots 0-4 once (instead of per-layer).
Shader_EndBatch() {
    global gShader_BatchMode, gShader_D3DCtx
    gShader_BatchMode := false
    if (!gShader_D3DCtx)
        return
    ctx := gShader_D3DCtx
    ; Unbind RT — OMSetRenderTargets(0, null, null) vtable 33
    ComCall(33, ctx, "uint", 0, "ptr", 0, "ptr", 0, "int")
    ; Unbind SRV slots 0-4 (max iChannels + compute particle slot) — PSSetShaderResources vtable 8
    static nullSrv5 := Buffer(A_PtrSize * 5, 0)
    ComCall(8, ctx, "uint", 0, "uint", 5, "ptr", nullSrv5, "int")
}

; ========================= INIT =========================

; Initialize shader pipeline. Call after gD2D_D3DDevice is valid.
; Returns true on success, false if unavailable.
Shader_Init() {
    global gD2D_D3DDevice, gShader_D3DCtx, gShader_VS, gShader_CBuffer, gShader_Sampler, gShader_Ready
    global RES_ID_SHADER_VS

    if (!gD2D_D3DDevice)
        return false

    global cfg
    if (cfg.DiagShaderLog)
        _Shader_LogInit()

    try {
        ; Get immediate context (ID3D11Device::GetImmediateContext, vtable 40)
        pCtx := 0
        ComCall(40, gD2D_D3DDevice, "ptr*", &pCtx)
        if (!pCtx)
            return false
        gShader_D3DCtx := pCtx

        ; Load or compile fullscreen triangle vertex shader
        if (A_IsCompiled) {
            ; Compiled mode: load pre-compiled DXBC from embedded resource
            vsBytecode := ResourceLoadToBuffer(RES_ID_SHADER_VS)
        } else {
            ; Dev mode: compile inline HLSL
            vsHLSL := "
            (
struct VSOut { float4 pos : SV_Position; float2 uv : TEXCOORD0; };
VSOut VSMain(uint id : SV_VertexID) {
    VSOut o;
    o.uv = float2((id << 1) & 2, id & 2);
    o.pos = float4(o.uv * float2(2, -2) + float2(-1, 1), 0, 1);
    return o;
}
            )"
            vsBytecode := _Shader_Compile(vsHLSL, "VSMain", "vs_4_0", "vs_VSMain")
        }
        if (!vsBytecode)
            return false

        ; CreateVertexShader (ID3D11Device vtable 12)
        pVS := 0
        hr := ComCall(12, gD2D_D3DDevice, "ptr", vsBytecode, "uptr", vsBytecode.Size, "ptr", 0, "ptr*", &pVS, "int")
        if (!pVS)
            return false
        gShader_VS := pVS

        ; Create constant buffer (144 bytes: time, resolution, timeDelta, frame, darken, desaturate, opacity,
        ;   iMouse, selRect, selColor, borderColor, borderWidth, isHovered, entranceT, iMouseSpeed,
        ;   gridW, gridH, maxParticles, reactivity, selGlow, selIntensity)
        ; D3D11_BUFFER_DESC (24 bytes): ByteWidth, Usage, BindFlags, CPUAccessFlags, MiscFlags, StructureByteStride
        bufDesc := Buffer(24, 0)
        NumPut("uint", 144, bufDesc, 0)      ; ByteWidth = 144 (9 × 16, properly aligned)
        NumPut("uint", 2, bufDesc, 4)        ; Usage = D3D11_USAGE_DYNAMIC
        NumPut("uint", 4, bufDesc, 8)        ; BindFlags = D3D11_BIND_CONSTANT_BUFFER
        NumPut("uint", 0x10000, bufDesc, 12) ; CPUAccessFlags = D3D11_CPU_ACCESS_WRITE

        ; CreateBuffer (ID3D11Device vtable 3)
        pCB := 0
        hr := ComCall(3, gD2D_D3DDevice, "ptr", bufDesc, "ptr", 0, "ptr*", &pCB, "int")
        if (!pCB)
            return false
        gShader_CBuffer := pCB

        ; Create sampler state: linear filter + wrap addressing (needed by texture-based shaders)
        ; D3D11_SAMPLER_DESC (52 bytes)
        sampDesc := Buffer(52, 0)
        NumPut("uint", 0x15, sampDesc, 0)    ; Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR (0x15)
        NumPut("uint", 1, sampDesc, 4)       ; AddressU = D3D11_TEXTURE_ADDRESS_WRAP
        NumPut("uint", 1, sampDesc, 8)       ; AddressV = D3D11_TEXTURE_ADDRESS_WRAP
        NumPut("uint", 1, sampDesc, 12)      ; AddressW = D3D11_TEXTURE_ADDRESS_WRAP
        NumPut("float", 0.0, sampDesc, 16)   ; MipLODBias
        NumPut("uint", 1, sampDesc, 20)      ; MaxAnisotropy
        NumPut("uint", 0, sampDesc, 24)      ; ComparisonFunc = NEVER
        ; BorderColor[4] at offset 28 — already zeroed
        NumPut("float", 0.0, sampDesc, 44)   ; MinLOD
        NumPut("float", 3.402823466e+38, sampDesc, 48) ; MaxLOD = FLT_MAX

        ; CreateSamplerState (ID3D11Device vtable 23)
        pSampler := 0
        hr := ComCall(23, gD2D_D3DDevice, "ptr", sampDesc, "ptr*", &pSampler, "int")
        if (!pSampler)
            return false
        gShader_Sampler := pSampler

        if (cfg.DiagShaderLog)
            _Shader_Log("Init: sampler=" gShader_Sampler " VS=" gShader_VS " CB=" gShader_CBuffer)
        gShader_Ready := true
        return true
    } catch as e {
        if (cfg.DiagShaderLog)
            _Shader_Log("Init EXCEPTION: " e.Message)
        Shader_Cleanup()
        return false
    }
}

; ========================= COMPILE =========================

; Compile HLSL source to shader bytecode. Returns a Buffer with compiled bytes, or 0 on failure.
; Extracts bytecode immediately from the ID3DBlob and releases it — avoids vtable
; lifetime issues where the blob's vtable (inside d3dcompiler_47.dll) could become
; invalid if the DLL is unloaded between calls.
; Uses disk cache to skip D3DCompile when HLSL source hasn't changed.
; cacheName: unique name for cache file (e.g., "vs_VSMain", "ps_digital_rain").
_Shader_Compile(hlsl, entryPoint, target, cacheName := "") {
    global cfg
    diagLog := cfg.DiagShaderLog  ; PERF: cache — read 3 times below
    ; Check bytecode cache first
    ; PERF: _Shader_HashSource returns the UTF-8 encoded HLSL via outSrcBuf/outSrcLen
    ; so we can reuse it for D3DCompile (avoids double-encoding ~10KB HLSL)
    cacheKey := cacheName ? cacheName : entryPoint
    srcBuf := 0, srcLen := 0
    hash := _Shader_HashSource(hlsl, entryPoint, target, &srcBuf, &srcLen)
    if (hash) {
        cached := _Shader_CacheRead(cacheKey, hash)
        if (cached) {
            if (diagLog)
                _Shader_Log("Compile " cacheKey ": cache HIT (" cached.Size " bytes)")
            return cached
        }
    }

    ; Ensure d3dcompiler_47 stays loaded (DllCall may unload between calls)
    static hModule := DllCall("LoadLibrary", "str", "d3dcompiler_47", "ptr")
    if (!hModule)
        return 0

    ; D3DCompile expects ANSI/UTF-8 source, not UTF-16.
    ; PERF: Reuse UTF-8 buffer from _Shader_HashSource when available
    if (!srcBuf || !srcLen) {
        cbNeeded := StrPut(hlsl, "UTF-8")
        srcBuf := Buffer(cbNeeded)
        StrPut(hlsl, srcBuf, "UTF-8")
        srcLen := cbNeeded - 1  ; exclude null terminator
    }

    pBlob := 0
    pErrors := 0
    hr := DllCall("d3dcompiler_47\D3DCompile",
        "ptr", srcBuf, "uptr", srcLen,
        "ptr", 0, "ptr", 0, "ptr", 0,
        "astr", entryPoint, "astr", target,
        "uint", 0, "uint", 0,
        "ptr*", &pBlob, "ptr*", &pErrors, "int")

    ; Log and release error blob
    if (pErrors) {
        try {
            pErrStr := ComCall(3, pErrors, "ptr")  ; GetBufferPointer
            errLen := ComCall(4, pErrors, "uptr")   ; GetBufferSize
            if (pErrStr && errLen && diagLog)
                _Shader_Log("Compile errors: " StrGet(pErrStr, errLen, "UTF-8"))
            ComCall(2, pErrors)
        }
    }

    if (hr < 0 || !pBlob) {
        if (diagLog)
            _Shader_Log("Compile FAILED hr=" Format("{:#x}", hr))
        return 0
    }

    ; Extract bytecode into a persistent Buffer, then release the blob.
    pCode := ComCall(3, pBlob, "ptr")    ; GetBufferPointer
    codeSize := ComCall(4, pBlob, "uptr") ; GetBufferSize
    if (!pCode || !codeSize) {
        ComCall(2, pBlob)
        return 0
    }

    bytecode := Buffer(codeSize)
    DllCall("ntdll\RtlMoveMemory", "ptr", bytecode, "ptr", pCode, "uptr", codeSize)
    ComCall(2, pBlob)  ; Release blob — we have our own copy now

    ; Write to cache (fire-and-forget)
    if (hash) {
        _Shader_CacheWrite(cacheKey, hash, bytecode)
        if (diagLog)
            _Shader_Log("Compile " cacheKey ": cache MISS, compiled + wrote " bytecode.Size " bytes")
    }

    return bytecode
}

; ========================= BYTECODE CACHE =========================

; Compute MD5 hash of (hlsl + entryPoint + target) via Windows CNG (bcrypt.dll).
; Returns a 16-byte Buffer, or 0 on failure.
; Also returns the UTF-8 encoded HLSL buffer via &outSrcBuf/&outSrcLen for reuse
; by _Shader_Compile (avoids double-encoding the ~10KB HLSL source).
_Shader_HashSource(hlsl, entryPoint, target, &outSrcBuf := 0, &outSrcLen := 0) {
    ; PERF: Encode HLSL to UTF-8 once — reused by caller for D3DCompile
    cbNeeded := StrPut(hlsl, "UTF-8")
    outSrcBuf := Buffer(cbNeeded)
    StrPut(hlsl, outSrcBuf, "UTF-8")
    outSrcLen := cbNeeded - 1

    ; PERF: Cache BCrypt algorithm provider — MD5 providers are reusable across calls
    static hAlg := 0
    if (!hAlg) {
        hr := DllCall("bcrypt\BCryptOpenAlgorithmProvider",
            "ptr*", &hAlg, "str", "MD5", "ptr", 0, "uint", 0, "int")
        if (hr < 0 || !hAlg) {
            hAlg := 0
            return 0
        }
    }

    hHash := 0
    hr := DllCall("bcrypt\BCryptCreateHash",
        "ptr", hAlg, "ptr*", &hHash, "ptr", 0, "uint", 0, "ptr", 0, "uint", 0, "uint", 0, "int")
    if (hr < 0 || !hHash)
        return 0

    ; PERF: Hash parts separately — avoids copying ~10KB HLSL into a concatenated string
    static sepBuf := Buffer(1, 0)
    NumPut("uchar", 10, sepBuf)  ; '\n' separator
    hr := DllCall("bcrypt\BCryptHashData",
        "ptr", hHash, "ptr", outSrcBuf, "uint", outSrcLen, "uint", 0, "int")
    if (hr >= 0)
        hr := DllCall("bcrypt\BCryptHashData",
            "ptr", hHash, "ptr", sepBuf, "uint", 1, "uint", 0, "int")
    if (hr >= 0) {
        epLen := StrPut(entryPoint, "UTF-8") - 1
        epBuf := Buffer(epLen + 1)
        StrPut(entryPoint, epBuf, "UTF-8")
        hr := DllCall("bcrypt\BCryptHashData",
            "ptr", hHash, "ptr", epBuf, "uint", epLen, "uint", 0, "int")
    }
    if (hr >= 0)
        hr := DllCall("bcrypt\BCryptHashData",
            "ptr", hHash, "ptr", sepBuf, "uint", 1, "uint", 0, "int")
    if (hr >= 0) {
        tgtLen := StrPut(target, "UTF-8") - 1
        tgtBuf := Buffer(tgtLen + 1)
        StrPut(target, tgtBuf, "UTF-8")
        hr := DllCall("bcrypt\BCryptHashData",
            "ptr", hHash, "ptr", tgtBuf, "uint", tgtLen, "uint", 0, "int")
    }
    if (hr < 0) {
        DllCall("bcrypt\BCryptDestroyHash", "ptr", hHash)
        return 0
    }

    digest := Buffer(16, 0)  ; MD5 = 16 bytes
    hr := DllCall("bcrypt\BCryptFinishHash",
        "ptr", hHash, "ptr", digest, "uint", 16, "uint", 0, "int")
    DllCall("bcrypt\BCryptDestroyHash", "ptr", hHash)

    return (hr >= 0) ? digest : 0
}

; Resolve cache directory path (shader_cache/ next to config.ini). Creates dir if needed.
; Returns path string, or "" on failure.
_Shader_CachePath() {
    global gConfigIniPath
    static cachedPath := ""
    if (cachedPath != "")
        return cachedPath

    if (!gConfigIniPath)
        return ""

    SplitPath(gConfigIniPath, , &dir)
    cacheDir := dir "\shader_cache"
    if (!DirExist(cacheDir)) {
        try DirCreate(cacheDir)
        catch
            return ""
    }
    cachedPath := cacheDir
    return cachedPath
}

; Read cached bytecode for a shader. Returns Buffer on cache hit, 0 on miss/corruption.
; File format: [16 bytes MD5 hash][N bytes DXBC bytecode]
_Shader_CacheRead(name, hash) {
    cacheDir := _Shader_CachePath()
    if (!cacheDir)
        return 0

    filePath := cacheDir "\" name ".bin"
    if (!FileExist(filePath))
        return 0

    try {
        f := FileOpen(filePath, "r")
        if (!f)
            return 0

        fileSize := f.Length
        if (fileSize <= 16) {
            f.Close()
            return 0
        }

        ; Read stored hash (first 16 bytes)
        storedHash := Buffer(16, 0)
        f.RawRead(storedHash, 16)

        ; Compare hashes
        if (DllCall("ntdll\RtlCompareMemory", "ptr", storedHash, "ptr", hash, "uptr", 16, "uptr") != 16) {
            f.Close()
            return 0
        }

        ; Hash matches — read bytecode
        bytecodeSize := fileSize - 16
        bytecode := Buffer(bytecodeSize)
        f.RawRead(bytecode, bytecodeSize)
        f.Close()
        return bytecode
    } catch {
        return 0
    }
}

; Write compiled bytecode to cache. Fire-and-forget — failures are silent.
; File format: [16 bytes MD5 hash][N bytes DXBC bytecode]
_Shader_CacheWrite(name, hash, bytecode) {
    cacheDir := _Shader_CachePath()
    if (!cacheDir)
        return

    filePath := cacheDir "\" name ".bin"
    try {
        f := FileOpen(filePath, "w")
        if (!f)
            return
        f.RawWrite(hash, 16)
        f.RawWrite(bytecode, bytecode.Size)
        f.Close()
    }
}

; ========================= REGISTER =========================

; Register a shader by name with HLSL pixel shader source and optional metadata.
; meta: {opacity: 0.50, iChannels: [{index: 0, file: "name_i0.png"}]}
; Compiles the PS and stores in registry. Returns true on success.
_Shader_Register(name, hlsl, meta := "") {
    global gD2D_D3DDevice, gShader_Registry, gShader_Ready, cfg

    if (!gShader_Ready || !gD2D_D3DDevice)
        return false

    ; Default metadata
    if (!IsObject(meta))
        meta := {opacity: 1.0, iChannels: []}

    try {
        if (cfg.DiagShaderLog)
            _Shader_Log("Register: " name " compiling PS...")
        psBytecode := _Shader_Compile(hlsl, "PSMain", "ps_4_0", "ps_" name)
        if (!psBytecode) {
            if (cfg.DiagShaderLog)
                _Shader_Log("Register: " name " PS compile FAILED")
            return false
        }

        ; CreatePixelShader (ID3D11Device vtable 15)
        pPS := 0
        ComCall(15, gD2D_D3DDevice, "ptr", psBytecode, "uptr", psBytecode.Size, "ptr", 0, "ptr*", &pPS, "int")
        if (!pPS)
            return false

        gShader_Registry[name] := {ps: pPS, cs: 0, csBuffer: 0, csUAV: 0, csSRV: 0, csNumElements: 0,
            tex: 0, rtv: 0, bitmap: 0, w: 0, h: 0, meta: meta, srvs: [], lastTime: 0.0,
            gridW: 0, gridH: 0, effectiveParticles: 0, reactivity: 1.0, selGlow: 1.0, selIntensity: 1.0}

        ; Load iChannel textures (lazy — loaded here at register time for simplicity)
        if (meta.HasOwnProp("iChannels") && meta.iChannels.Length > 0) {
            _Shader_LoadTextures(name)
        }

        return true
    } catch as e {
        return false
    }
}

; Register a shader from pre-compiled DXBC bytecode embedded as a resource.
; Used in compiled mode — skips D3DCompile entirely.
; resId: Resource ID for the pre-compiled PS DXBC bytecode
; meta: {opacity: 0.50, iChannels: [{index: 0, file: "name_i0.png"}]}
Shader_RegisterFromResource(name, resId, meta := "") {
    global gD2D_D3DDevice, gShader_Registry, gShader_Ready, cfg

    if (!gShader_Ready || !gD2D_D3DDevice)
        return false

    if (!IsObject(meta))
        meta := {opacity: 1.0, iChannels: []}

    try {
        if (cfg.DiagShaderLog)
            _Shader_Log("RegisterFromResource: " name " resId=" resId)

        psBytecode := ResourceLoadToBuffer(resId)
        if (!psBytecode || !psBytecode.Size) {
            if (cfg.DiagShaderLog)
                _Shader_Log("RegisterFromResource: " name " resource load FAILED")
            return false
        }

        ; CreatePixelShader (ID3D11Device vtable 15)
        pPS := 0
        ComCall(15, gD2D_D3DDevice, "ptr", psBytecode, "uptr", psBytecode.Size, "ptr", 0, "ptr*", &pPS, "int")
        if (!pPS)
            return false

        gShader_Registry[name] := {ps: pPS, cs: 0, csBuffer: 0, csUAV: 0, csSRV: 0, csNumElements: 0,
            tex: 0, rtv: 0, bitmap: 0, w: 0, h: 0, meta: meta, srvs: [], lastTime: 0.0,
            gridW: 0, gridH: 0, effectiveParticles: 0, reactivity: 1.0, selGlow: 1.0, selIntensity: 1.0}

        if (meta.HasOwnProp("iChannels") && meta.iChannels.Length > 0)
            _Shader_LoadTextures(name)

        return true
    } catch as e {
        if (cfg.DiagShaderLog)
            _Shader_Log("RegisterFromResource: " name " EXCEPTION: " e.Message)
        return false
    }
}

; Register a shader by reading HLSL from a file in src/shaders/ and compiling at runtime.
; Used in dev mode (running from source) — keeps D3DCompile + disk cache for fast iteration.
; hlslFile: filename relative to src/shaders/ (e.g., "fire.hlsl")
; meta: {opacity: 0.50, iChannels: [{index: 0, file: "name_i0.png"}]}
Shader_RegisterFromFile(name, hlslFile, meta := "") {
    global gD2D_D3DDevice, gShader_Registry, gShader_Ready, cfg

    if (!gShader_Ready || !gD2D_D3DDevice)
        return false

    if (!IsObject(meta))
        meta := {opacity: 1.0, iChannels: []}

    try {
        ; Resolve HLSL path: A_ScriptDir is src/gui/ or src/, shaders are in src/shaders/
        ; hlslFile may include subdirectory (e.g., "mouse\radial_glow.hlsl")
        hlslPath := A_ScriptDir "\shaders\" hlslFile
        if (!FileExist(hlslPath)) {
            ; Try walking up one level (A_ScriptDir might be src/gui/)
            SplitPath(A_ScriptDir, , &parentDir)
            hlslPath := parentDir "\shaders\" hlslFile
        }
        if (!FileExist(hlslPath)) {
            if (cfg.DiagShaderLog)
                _Shader_Log("RegisterFromFile: " name " HLSL not found: " hlslFile)
            return false
        }

        hlsl := FileRead(hlslPath, "UTF-8")
        if (hlsl = "") {
            if (cfg.DiagShaderLog)
                _Shader_Log("RegisterFromFile: " name " empty HLSL: " hlslFile)
            return false
        }

        ; Prepend shared header (cached on first load)
        static sCommonHlsl := ""
        if (sCommonHlsl = "") {
            commonPath := ""
            ; Same directory resolution as shader HLSL
            testPath := A_ScriptDir "\shaders\alt_tabby_common.hlsl"
            if (FileExist(testPath))
                commonPath := testPath
            else {
                SplitPath(A_ScriptDir, , &parentDir2)
                testPath := parentDir2 "\shaders\alt_tabby_common.hlsl"
                if (FileExist(testPath))
                    commonPath := testPath
            }
            if (commonPath != "")
                sCommonHlsl := FileRead(commonPath, "UTF-8") "`n"
        }
        if (sCommonHlsl != "")
            hlsl := sCommonHlsl "#line 1 `"" hlslFile "`"`n" hlsl

        ; Delegate to existing _Shader_Register which handles D3DCompile + cache
        return _Shader_Register(name, hlsl, meta)
    } catch as e {
        if (cfg.DiagShaderLog)
            _Shader_Log("RegisterFromFile: " name " EXCEPTION: " e.Message)
        return false
    }
}

; Register an alias that shares the compiled pixel shader + textures from srcName
; but gets its own render target. Used for multi-layer: same shader, different time/params.
Shader_RegisterAlias(aliasName, srcName) {
    global gShader_Registry, gShader_Ready

    if (!gShader_Ready || !gShader_Registry.Has(srcName))
        return false

    src := gShader_Registry[srcName]
    if (!src.ps)
        return false

    ; Share ps + cs + srvs + compute buffer, own render target (tex/rtv/bitmap start at 0 — lazy created in PreRender)
    alias := {ps: src.ps, cs: src.cs, csBuffer: src.csBuffer, csUAV: src.csUAV, csSRV: src.csSRV, csNumElements: src.csNumElements,
        tex: 0, rtv: 0, bitmap: 0, w: 0, h: 0, meta: src.meta, srvs: src.srvs, lastTime: 0.0,
        gridW: src.gridW, gridH: src.gridH, effectiveParticles: src.effectiveParticles,
        reactivity: src.reactivity, selGlow: src.selGlow, selIntensity: src.selIntensity}
    gShader_Registry[aliasName] := alias
    return true
}

; ========================= COMPUTE SHADER REGISTRATION =========================

; Map grid quality preset name to width/height.
_Shader_GridPreset(quality) {
    switch StrLower(quality) {
        case "low":    return {w: 256, h: 128}
        case "medium": return {w: 512, h: 256}
        case "high":   return {w: 1024, h: 512}
        case "ultra":  return {w: 2048, h: 1024}
        default:       return {w: 1024, h: 512}
    }
}

; Compute effective buffer size from shader metadata + config settings.
; Returns {totalElements, gridW, gridH, effectiveParticles}.
_Shader_ComputeBufferLayout(computeMeta) {
    global cfg
    baseP := computeMeta.HasOwnProp("baseParticles") ? computeMeta.baseParticles : 0
    effectiveP := Max(1, Round(baseP * cfg.MouseEffect_ParticleDensity))

    ; Determine if this shader uses a grid
    ; If baseParticles < maxParticles (and baseParticles > 0 or maxParticles > baseParticles), it has a grid
    ; Pure grid: baseParticles = 0, maxParticles = gridW * gridH
    ; No grid (ripple): baseParticles = maxParticles
    hasGrid := (baseP < computeMeta.maxParticles) || (baseP = 0)

    if (hasGrid) {
        preset := _Shader_GridPreset(cfg.MouseEffect_GridQuality)
        gridW := preset.w
        gridH := preset.h
        gridCells := gridW * gridH
    } else {
        gridW := 0
        gridH := 0
        gridCells := 0
    }
    totalElements := effectiveP + gridCells
    return {totalElements: totalElements, gridW: gridW, gridH: gridH, effectiveParticles: effectiveP}
}

; Register a compute+pixel shader pair. HLSL source must contain both CSMain and PSMain entry points.
; meta must include compute: {maxParticles: N, particleStride: N}
_Shader_RegisterCompute(name, hlsl, meta) {
    global gD2D_D3DDevice, gShader_Registry, gShader_Ready, cfg

    if (!gShader_Ready || !gD2D_D3DDevice)
        return false

    if (!IsObject(meta))
        return false

    try {
        if (cfg.DiagShaderLog)
            _Shader_Log("RegisterCompute: " name " compiling CS+PS...")

        ; Compile compute shader (cs_5_0)
        csBytecode := _Shader_Compile(hlsl, "CSMain", "cs_5_0", "cs_" name)
        if (!csBytecode) {
            if (cfg.DiagShaderLog)
                _Shader_Log("RegisterCompute: " name " CS compile FAILED")
            return false
        }

        ; Compile pixel shader (ps_5_0 for compute-paired shaders)
        psBytecode := _Shader_Compile(hlsl, "PSMain", "ps_5_0", "ps_" name)
        if (!psBytecode) {
            if (cfg.DiagShaderLog)
                _Shader_Log("RegisterCompute: " name " PS compile FAILED")
            return false
        }

        ; CreateComputeShader (ID3D11Device vtable 18)
        pCS := 0
        ComCall(18, gD2D_D3DDevice, "ptr", csBytecode, "uptr", csBytecode.Size, "ptr", 0, "ptr*", &pCS, "int")
        if (!pCS)
            return false

        ; CreatePixelShader (ID3D11Device vtable 15)
        pPS := 0
        ComCall(15, gD2D_D3DDevice, "ptr", psBytecode, "uptr", psBytecode.Size, "ptr", 0, "ptr*", &pPS, "int")
        if (!pPS) {
            ComCall(2, pCS)
            return false
        }

        ; Compute effective buffer layout from config
        computeMeta := meta.compute
        layout := _Shader_ComputeBufferLayout(computeMeta)

        ; Create structured buffer + UAV + SRV for particle data
        csRes := _Shader_CreateComputeBuffer(layout.totalElements, computeMeta.particleStride)
        if (!csRes) {
            ComCall(2, pCS)
            ComCall(2, pPS)
            return false
        }

        gShader_Registry[name] := {ps: pPS, cs: pCS,
            csBuffer: csRes.buffer, csUAV: csRes.uav, csSRV: csRes.srv, csNumElements: layout.totalElements,
            gridW: layout.gridW, gridH: layout.gridH, effectiveParticles: layout.effectiveParticles,
            tex: 0, rtv: 0, staging: 0, bitmap: 0, w: 0, h: 0, meta: meta, srvs: [], lastTime: 0.0,
            reactivity: 1.0, selGlow: 1.0, selIntensity: 1.0}

        if (meta.HasOwnProp("iChannels") && meta.iChannels.Length > 0)
            _Shader_LoadTextures(name)

        if (cfg.DiagShaderLog)
            _Shader_Log("RegisterCompute: " name " OK cs=" pCS " ps=" pPS " buf=" csRes.buffer
                " grid=" layout.gridW "x" layout.gridH " particles=" layout.effectiveParticles)
        return true
    } catch as e {
        if (cfg.DiagShaderLog)
            _Shader_Log("RegisterCompute: " name " EXCEPTION: " e.Message)
        return false
    }
}

; Register a compute+pixel shader from pre-compiled DXBC resources.
Shader_RegisterComputeFromResource(name, csResId, psResId, meta) {
    global gD2D_D3DDevice, gShader_Registry, gShader_Ready, cfg

    if (!gShader_Ready || !gD2D_D3DDevice || !IsObject(meta))
        return false

    try {
        if (cfg.DiagShaderLog)
            _Shader_Log("RegisterComputeFromResource: " name " csResId=" csResId " psResId=" psResId)

        csBytecode := ResourceLoadToBuffer(csResId)
        if (!csBytecode || !csBytecode.Size)
            return false

        psBytecode := ResourceLoadToBuffer(psResId)
        if (!psBytecode || !psBytecode.Size)
            return false

        ; CreateComputeShader (ID3D11Device vtable 18)
        pCS := 0
        ComCall(18, gD2D_D3DDevice, "ptr", csBytecode, "uptr", csBytecode.Size, "ptr", 0, "ptr*", &pCS, "int")
        if (!pCS)
            return false

        ; CreatePixelShader (ID3D11Device vtable 15)
        pPS := 0
        ComCall(15, gD2D_D3DDevice, "ptr", psBytecode, "uptr", psBytecode.Size, "ptr", 0, "ptr*", &pPS, "int")
        if (!pPS) {
            ComCall(2, pCS)
            return false
        }

        ; Compute effective buffer layout from config
        computeMeta := meta.compute
        layout := _Shader_ComputeBufferLayout(computeMeta)

        csRes := _Shader_CreateComputeBuffer(layout.totalElements, computeMeta.particleStride)
        if (!csRes) {
            ComCall(2, pCS)
            ComCall(2, pPS)
            return false
        }

        gShader_Registry[name] := {ps: pPS, cs: pCS,
            csBuffer: csRes.buffer, csUAV: csRes.uav, csSRV: csRes.srv, csNumElements: layout.totalElements,
            gridW: layout.gridW, gridH: layout.gridH, effectiveParticles: layout.effectiveParticles,
            tex: 0, rtv: 0, staging: 0, bitmap: 0, w: 0, h: 0, meta: meta, srvs: [], lastTime: 0.0,
            reactivity: 1.0, selGlow: 1.0, selIntensity: 1.0}

        if (meta.HasOwnProp("iChannels") && meta.iChannels.Length > 0)
            _Shader_LoadTextures(name)

        return true
    } catch as e {
        if (cfg.DiagShaderLog)
            _Shader_Log("RegisterComputeFromResource: " name " EXCEPTION: " e.Message)
        return false
    }
}

; Register a compute+pixel shader from HLSL file (dev mode).
Shader_RegisterComputeFromFile(name, hlslFile, meta) {
    global gD2D_D3DDevice, gShader_Registry, gShader_Ready, cfg

    if (!gShader_Ready || !gD2D_D3DDevice || !IsObject(meta))
        return false

    try {
        hlslPath := A_ScriptDir "\shaders\" hlslFile
        if (!FileExist(hlslPath)) {
            SplitPath(A_ScriptDir, , &parentDir)
            hlslPath := parentDir "\shaders\" hlslFile
        }
        if (!FileExist(hlslPath))
            return false

        hlsl := FileRead(hlslPath, "UTF-8")
        if (hlsl = "")
            return false

        ; Prepend shared header
        static sCommonHlsl := ""
        if (sCommonHlsl = "") {
            testPath := A_ScriptDir "\shaders\alt_tabby_common.hlsl"
            if (FileExist(testPath))
                sCommonHlsl := FileRead(testPath, "UTF-8") "`n"
            else {
                SplitPath(A_ScriptDir, , &parentDir2)
                testPath := parentDir2 "\shaders\alt_tabby_common.hlsl"
                if (FileExist(testPath))
                    sCommonHlsl := FileRead(testPath, "UTF-8") "`n"
            }
        }
        if (sCommonHlsl != "")
            hlsl := sCommonHlsl "#line 1 `"" hlslFile "`"`n" hlsl

        return _Shader_RegisterCompute(name, hlsl, meta)
    } catch as e {
        if (cfg.DiagShaderLog)
            _Shader_Log("RegisterComputeFromFile: " name " EXCEPTION: " e.Message)
        return false
    }
}

; Create a D3D11 structured buffer with UAV + SRV for compute shader read/write.
; Returns {buffer, uav, srv} or 0 on failure.
_Shader_CreateComputeBuffer(numElements, strideBytes) {
    global gD2D_D3DDevice, cfg

    totalSize := numElements * strideBytes

    ; Initialize buffer data: all zeros except life=1.0 (dead) for each particle.
    ; life field is at offset 16 (after float2 pos + float2 vel) in the 32-byte particle struct.
    ; Uses RtlCopyMemory doubling (O(log N) DllCalls) instead of per-element NumPut loop.
    initData := Buffer(totalSize, 0)
    NumPut("float", 1.0, initData, 16)  ; Write one template particle
    copied := 1
    while (copied < numElements) {
        chunk := Min(copied, numElements - copied)
        DllCall("ntdll\RtlCopyMemory", "ptr", initData.Ptr + copied * strideBytes,
            "ptr", initData.Ptr, "uint", chunk * strideBytes)
        copied += chunk
    }

    ; D3D11_BUFFER_DESC (24 bytes)
    bufDesc := Buffer(24, 0)
    NumPut("uint", totalSize, bufDesc, 0)      ; ByteWidth
    NumPut("uint", 0, bufDesc, 4)              ; Usage = D3D11_USAGE_DEFAULT
    NumPut("uint", 0x88, bufDesc, 8)           ; BindFlags = SHADER_RESOURCE(0x8) | UNORDERED_ACCESS(0x80)
    NumPut("uint", 0, bufDesc, 12)             ; CPUAccessFlags = 0
    NumPut("uint", 0x40, bufDesc, 16)          ; MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED
    NumPut("uint", strideBytes, bufDesc, 20)   ; StructureByteStride

    ; D3D11_SUBRESOURCE_DATA (16 bytes on x64): pSysMem, SysMemPitch, SysMemSlicePitch
    subData := Buffer(A_PtrSize * 2 + 4, 0)
    NumPut("ptr", initData.Ptr, subData, 0)

    ; CreateBuffer (ID3D11Device vtable 3)
    pBuf := 0
    hr := ComCall(3, gD2D_D3DDevice, "ptr", bufDesc, "ptr", subData, "ptr*", &pBuf, "int")
    if (hr < 0 || !pBuf)
        return 0

    ; Create UAV (ID3D11Device vtable 8 = CreateUnorderedAccessView)
    ; D3D11_UNORDERED_ACCESS_VIEW_DESC (20 bytes for buffer): Format, ViewDimension, Buffer{FirstElement, NumElements, Flags}
    uavDesc := Buffer(20, 0)
    NumPut("uint", 0, uavDesc, 0)              ; Format = DXGI_FORMAT_UNKNOWN (structured buffer)
    NumPut("uint", 1, uavDesc, 4)              ; ViewDimension = D3D11_UAV_DIMENSION_BUFFER
    NumPut("uint", 0, uavDesc, 8)              ; Buffer.FirstElement
    NumPut("uint", numElements, uavDesc, 12)   ; Buffer.NumElements
    NumPut("uint", 0, uavDesc, 16)             ; Buffer.Flags

    pUAV := 0
    hr := ComCall(8, gD2D_D3DDevice, "ptr", pBuf, "ptr", uavDesc, "ptr*", &pUAV, "int")
    if (hr < 0 || !pUAV) {
        ComCall(2, pBuf)
        return 0
    }

    ; Create SRV (ID3D11Device vtable 7 = CreateShaderResourceView)
    ; D3D11_SHADER_RESOURCE_VIEW_DESC (16 bytes for buffer): Format, ViewDimension, Buffer{FirstElement, NumElements}
    srvDesc := Buffer(16, 0)
    NumPut("uint", 0, srvDesc, 0)              ; Format = DXGI_FORMAT_UNKNOWN (structured buffer)
    NumPut("uint", 1, srvDesc, 4)              ; ViewDimension = D3D11_SRV_DIMENSION_BUFFER
    NumPut("uint", 0, srvDesc, 8)              ; Buffer.FirstElement
    NumPut("uint", numElements, srvDesc, 12)   ; Buffer.NumElements

    pSRV := 0
    hr := ComCall(7, gD2D_D3DDevice, "ptr", pBuf, "ptr", srvDesc, "ptr*", &pSRV, "int")
    if (hr < 0 || !pSRV) {
        ComCall(2, pUAV)
        ComCall(2, pBuf)
        return 0
    }

    if (cfg.DiagShaderLog)
        _Shader_Log("CreateComputeBuffer: " numElements "x" strideBytes "=" totalSize "B buf=" pBuf " uav=" pUAV " srv=" pSRV)

    return {buffer: pBuf, uav: pUAV, srv: pSRV}
}

; ========================= iCHANNEL TEXTURES =========================

; Load iChannel textures for a shader. GDI+ → CreateTexture2D → CreateShaderResourceView.
; Loads ALL iChannels specified in metadata and stores SRVs in entry.srvs[] (ordered by channel index).
_Shader_LoadTextures(name) {
    global gD2D_D3DDevice, gShader_Registry, cfg

    if (!gShader_Registry.Has(name))
        return

    entry := gShader_Registry[name]
    if (!entry.meta.HasOwnProp("iChannels") || entry.meta.iChannels.Length = 0)
        return

    diagLog := cfg.DiagShaderLog
    if (diagLog)
        _Shader_Log("LoadTextures: " name " has " entry.meta.iChannels.Length " channels")
    for _, ch in entry.meta.iChannels {
        if (diagLog)
            _Shader_Log("  loading ch file=" ch.file)
        pSRV := _Shader_LoadOneTexture(ch.file)
        if (diagLog)
            _Shader_Log("  result SRV=" pSRV)
        entry.srvs.Push(pSRV)  ; 0 if failed — preserves slot ordering
    }
    if (diagLog)
        _Shader_Log("LoadTextures done: " name " srvs.Length=" entry.srvs.Length)
}

; Load a single texture file → D3D11 SRV. Returns SRV ptr or 0 on failure.
_Shader_LoadOneTexture(fileName) {
    global gD2D_D3DDevice, cfg
    ; Ensure GDI+ is initialized (Gdip_Startup is a no-op in the D2D pipeline)
    static _gdipInit := _Shader_InitGdiplus()
    texPath := Shader_GetTexturePath(fileName)

    diagLog := cfg.DiagShaderLog
    if (!FileExist(texPath)) {
        if (diagLog)
            _Shader_Log("  FILE NOT FOUND: " texPath)
        return 0
    }
    if (diagLog)
        _Shader_Log("  file exists: " texPath)

    try {
        ; Load PNG via GDI+
        pBitmapGdip := 0
        DllCall("gdiplus\GdipCreateBitmapFromFile", "str", texPath, "ptr*", &pBitmapGdip, "int")
        if (!pBitmapGdip) {
            if (diagLog)
                _Shader_Log("  GDI+ load FAILED")
            return 0
        }

        ; Get dimensions
        imgW := 0
        imgH := 0
        DllCall("gdiplus\GdipGetImageWidth", "ptr", pBitmapGdip, "uint*", &imgW)
        DllCall("gdiplus\GdipGetImageHeight", "ptr", pBitmapGdip, "uint*", &imgH)
        if (diagLog)
            _Shader_Log("  GDI+ loaded " imgW "x" imgH)

        ; Lock bits in BGRA format (PixelFormat32bppARGB = 0x26200A)
        ; GDI+ BitmapData struct: 32 bytes on x64
        bmpData := Buffer(32, 0)
        ; Rect struct: {x, y, w, h} as int32s (x=0, y=0 via zero-init)
        lockRect := Buffer(16, 0)
        NumPut("int", imgW, lockRect, 8)
        NumPut("int", imgH, lockRect, 12)

        hr := DllCall("gdiplus\GdipBitmapLockBits", "ptr", pBitmapGdip, "ptr", lockRect,
            "uint", 1, "int", 0x26200A, "ptr", bmpData, "int")  ; ImageLockModeRead=1
        if (hr != 0) {
            if (diagLog)
                _Shader_Log("  LockBits FAILED hr=" hr)
            DllCall("gdiplus\GdipDisposeImage", "ptr", pBitmapGdip)
            return 0
        }

        stride := NumGet(bmpData, 8, "int")
        pPixels := NumGet(bmpData, 16, "ptr")
        if (diagLog)
            _Shader_Log("  stride=" stride " pPixels=" pPixels)

        ; Create D3D11 Texture2D with initial data
        texDesc := Buffer(44, 0)
        NumPut("uint", imgW, texDesc, 0)        ; Width
        NumPut("uint", imgH, texDesc, 4)        ; Height
        NumPut("uint", 1, texDesc, 8)           ; MipLevels
        NumPut("uint", 1, texDesc, 12)          ; ArraySize
        NumPut("uint", 87, texDesc, 16)         ; Format = DXGI_FORMAT_B8G8R8A8_UNORM
        NumPut("uint", 1, texDesc, 20)          ; SampleDesc.Count
        NumPut("uint", 0, texDesc, 24)          ; SampleDesc.Quality
        NumPut("uint", 0, texDesc, 28)          ; Usage = DEFAULT
        NumPut("uint", 0x8, texDesc, 32)        ; BindFlags = SHADER_RESOURCE

        ; D3D11_SUBRESOURCE_DATA (16 bytes on x64): pSysMem, SysMemPitch, SysMemSlicePitch
        initData := Buffer(A_PtrSize * 2 + 4, 0)
        NumPut("ptr", pPixels, initData, 0)
        NumPut("uint", stride, initData, A_PtrSize)

        pTexture := 0
        hr := ComCall(5, gD2D_D3DDevice, "ptr", texDesc, "ptr", initData, "ptr*", &pTexture, "int")

        ; Unlock bits and dispose GDI+ bitmap
        DllCall("gdiplus\GdipBitmapUnlockBits", "ptr", pBitmapGdip, "ptr", bmpData)
        DllCall("gdiplus\GdipDisposeImage", "ptr", pBitmapGdip)

        if (hr < 0 || !pTexture) {
            if (diagLog)
                _Shader_Log("  CreateTexture2D FAILED hr=" Format("{:#x}", hr) " pTex=" pTexture)
            return 0
        }
        if (diagLog)
            _Shader_Log("  Texture2D OK ptr=" pTexture)

        ; CreateShaderResourceView (ID3D11Device vtable 7)
        pSRV := 0
        hr := ComCall(7, gD2D_D3DDevice, "ptr", pTexture, "ptr", 0, "ptr*", &pSRV, "int")
        ; Release the texture (SRV holds a ref)
        ComCall(2, pTexture)

        if (hr < 0 || !pSRV) {
            if (diagLog)
                _Shader_Log("  CreateSRV FAILED hr=" Format("{:#x}", hr))
            return 0
        }

        if (diagLog)
            _Shader_Log("  SRV OK ptr=" pSRV)
        return pSRV
    } catch as e {
        if (diagLog)
            _Shader_Log("  EXCEPTION: " e.Message)
        return 0
    }
}

; ========================= RENDER TARGET =========================

; Release render target resources (tex, rtv, bitmap) from a shader entry.
; Keeps entry.ps and entry.srvs intact — only frees the per-resolution surfaces.
; Release order: bitmap first (holds DXGI surface ref), then rtv, then tex.
_Shader_ReleaseRT(entry) {
    if (entry.bitmap) {
        ComCall(2, entry.bitmap)  ; IUnknown::Release
        entry.bitmap := 0
    }
    if (entry.rtv) {
        ComCall(2, entry.rtv)
        entry.rtv := 0
    }
    if (entry.tex) {
        ComCall(2, entry.tex)
        entry.tex := 0
    }
    entry.w := 0
    entry.h := 0
}

; Lazy-create or resize the render target texture for a shader entry.
; Creates: D3D11 render target texture + RTV (for shader Draw), and a D2D bitmap
; backed by the texture's DXGI surface (zero-copy GPU sharing for DrawImage).
_Shader_CreateRT(entry, w, h) {
    global gD2D_D3DDevice, gD2D_RT

    ; Release old resources before (re)creating at new size
    _Shader_ReleaseRT(entry)

    ; --- D3D11 render target texture (for shader Draw) ---
    ; D3D11_TEXTURE2D_DESC (44 bytes)
    texDesc := Buffer(44, 0)
    NumPut("uint", w, texDesc, 0)         ; Width
    NumPut("uint", h, texDesc, 4)         ; Height
    NumPut("uint", 1, texDesc, 8)         ; MipLevels
    NumPut("uint", 1, texDesc, 12)        ; ArraySize
    NumPut("uint", 87, texDesc, 16)       ; Format = DXGI_FORMAT_B8G8R8A8_UNORM
    NumPut("uint", 1, texDesc, 20)        ; SampleDesc.Count
    NumPut("uint", 0, texDesc, 24)        ; SampleDesc.Quality
    NumPut("uint", 0, texDesc, 28)        ; Usage = DEFAULT
    NumPut("uint", 0x28, texDesc, 32)     ; BindFlags = RENDER_TARGET | SHADER_RESOURCE

    pTex := 0
    hr := ComCall(5, gD2D_D3DDevice, "ptr", texDesc, "ptr", 0, "ptr*", &pTex, "int")
    if (hr < 0 || !pTex)
        return false
    entry.tex := pTex

    ; CreateRenderTargetView (ID3D11Device vtable 9)
    pRTV := 0
    hr := ComCall(9, gD2D_D3DDevice, "ptr", pTex, "ptr", 0, "ptr*", &pRTV, "int")
    if (hr < 0 || !pRTV)
        return false
    entry.rtv := pRTV

    ; --- D2D bitmap backed by DXGI surface (zero-copy GPU sharing) ---
    ; QI the render target texture for IDXGISurface (MipLevels=1, ArraySize=1 → supported)
    surfaceObj := ComObjQuery(pTex, IDXGISurface.IID)
    if (!surfaceObj)
        return false
    pSurface := ComObjValue(surfaceObj)

    ; D2D1_BITMAP_PROPERTIES1 (32 bytes): pixelFormat(8), dpiX(4), dpiY(4), options(4), colorContext(ptr)
    ; options = D2D1_BITMAP_OPTIONS_NONE (0) — read-only source for DrawImage
    static sharedBP1 := 0
    if (!sharedBP1) {
        sharedBP1 := Buffer(32, 0)
        NumPut("uint", 87, sharedBP1, 0)      ; format = DXGI_FORMAT_B8G8R8A8_UNORM
        NumPut("uint", 1, sharedBP1, 4)       ; alphaMode = D2D1_ALPHA_MODE_PREMULTIPLIED
        NumPut("float", 96.0, sharedBP1, 8)   ; dpiX
        NumPut("float", 96.0, sharedBP1, 12)  ; dpiY
        NumPut("uint", 0, sharedBP1, 16)      ; bitmapOptions = D2D1_BITMAP_OPTIONS_NONE
    }

    ; CreateBitmapFromDxgiSurface (ID2D1DeviceContext vtable 62)
    ; D2D reads directly from the GPU texture — no staging, no CPU copy
    pBitmap := 0
    hr := ComCall(62, gD2D_RT, "ptr", pSurface, "ptr", sharedBP1, "ptr*", &pBitmap, "int")
    if (hr < 0 || !pBitmap)
        return false
    entry.bitmap := pBitmap

    entry.w := w
    entry.h := h
    return true
}

; ========================= PRE-RENDER =========================

; Run the D3D11 shader pipeline. Call BEFORE D2D BeginDraw.
; timeSec: elapsed time in seconds. darken/desaturate: 0.0-1.0 post-processing.
Shader_PreRender(name, w, h, timeSec, darken := 0.0, desaturate := 0.0, opacity := 1.0,
    mouseX := 0, mouseY := 0, mouseVelX := 0.0, mouseVelY := 0.0, mouseSpeed := 0.0,
    selX := 0, selY := 0, selW := 0, selH := 0,
    selColorR := 0.0, selColorG := 0.0, selColorB := 0.0, selColorA := 0.0,
    borderR := 0.0, borderG := 0.0, borderB := 0.0, borderA := 0.0,
    borderWidth := 0.0, isHovered := 0.0, entranceT := 0.0, rowRadius := 0.0) {
    global gShader_D3DCtx, gShader_VS, gShader_CBuffer, gShader_Sampler, gShader_Registry, gShader_Ready
    global gShader_FrameCount, gShader_StateDirty, gShader_BatchMode, cfg
    static dbgRendered := Map()
    Profiler.Enter("Shader_PreRender") ; @profile
    cb := gShader_CBuffer

    ; PERF: single .Get() replaces .Has() + [] double hash lookup
    entry := gShader_Registry.Get(name, 0)
    if (!gShader_Ready || !entry) {
        Profiler.Leave() ; @profile
        return false
    }

    ; One-time log per shader name (reuse entry from above)
    if (cfg.DiagShaderLog && !dbgRendered.Has(name)) {
        dbgRendered[name] := true
        _Shader_Log("PreRender FIRST: " name " srvs=" entry.srvs.Length " sampler=" gShader_Sampler " ps=" entry.ps
            . " darken=" darken " desat=" desaturate " opacity=" opacity
            . " gridW=" entry.gridW " gridH=" entry.gridH " maxP=" entry.effectiveParticles)
    }
    if (!entry.ps) {
        Profiler.Leave() ; @profile
        return false
    }

    ; Lazy create/resize render target
    if (entry.w != w || entry.h != h || !entry.tex) {
        if (!_Shader_CreateRT(entry, w, h)) {
            Profiler.Leave() ; @profile
            return false
        }
    }

    if (!entry.rtv || !entry.bitmap) {
        Profiler.Leave() ; @profile
        return false
    }

    ctx := gShader_D3DCtx

    ; Compute timeDelta per-shader (each shader tracks its own lastTime to avoid
    ; cross-shader pollution when multiple shaders render per frame with different time values)
    timeDelta := 0.0
    if (entry.lastTime > 0)
        timeDelta := timeSec - entry.lastTime
    entry.lastTime := timeSec
    gShader_FrameCount += 1

    ; Map cbuffer → write all 144 bytes → Unmap
    ; D3D11_MAPPED_SUBRESOURCE (16 bytes on x64): pData(0), RowPitch(8), DepthPitch(12)
    static mapped1 := Buffer(16, 0)
    ; Map (vtable 14): resource, subresource, mapType=WRITE_DISCARD(4), mapFlags, mappedResource
    hr := ComCall(14, ctx, "ptr", cb, "uint", 0, "uint", 4, "uint", 0, "ptr", mapped1, "int")
    if (hr < 0) {
        Profiler.Leave() ; @profile
        return false
    }
    pData := NumGet(mapped1, 0, "ptr")
    if (pData) {
        ; Core params + mouse (offset 0-44, 12 values)
        NumPut("float", timeSec, "float", Float(w), "float", Float(h), "float", timeDelta,
               "uint", gShader_FrameCount, "float", darken, "float", desaturate, "float", opacity,
               "float", Float(mouseX), "float", Float(mouseY), "float", mouseVelX, "float", mouseVelY,
               pData, 0)
        ; Selection rect + colors (offset 48-92, 12 values)
        NumPut("float", Float(selX), "float", Float(selY), "float", Float(selW), "float", Float(selH),
               "float", selColorR, "float", selColorG, "float", selColorB, "float", selColorA,
               "float", borderR, "float", borderG, "float", borderB, "float", borderA,
               pData, 48)
        ; Selection params + compute config + tuning (offset 96-136, 11 values)
        NumPut("float", borderWidth, "float", isHovered, "float", entranceT, "float", mouseSpeed,
               "uint", entry.gridW, "uint", entry.gridH, "uint", entry.effectiveParticles, "float", entry.reactivity,
               "float", entry.selGlow, "float", entry.selIntensity, "float", rowRadius,
               pData, 96)
    }
    ; Unmap (vtable 15) — void; "int" return type suppresses false HRESULT throw from RAX garbage
    ComCall(15, ctx, "ptr", cb, "uint", 0, "int")

    ; --- Compute shader dispatch (if this shader has a CS component) ---
    if (entry.cs) {
        ; CSSetShader (ID3D11DeviceContext vtable 69)
        ComCall(69, ctx, "ptr", entry.cs, "ptr", 0, "uint", 0, "int")

        ; CSSetConstantBuffers (vtable 71): same cbuffer at slot 0
        static csCbBuf := Buffer(A_PtrSize, 0), csLastCb := 0
        if (cb != csLastCb) {
            NumPut("ptr", cb, csCbBuf)
            csLastCb := cb
            ComCall(71, ctx, "uint", 0, "uint", 1, "ptr", csCbBuf, "int")
        }

        ; CSSetUnorderedAccessViews (vtable 68): UAV at slot 0
        static csUavBuf := Buffer(A_PtrSize, 0), csLastUav := 0
        if (entry.csUAV != csLastUav) {
            NumPut("ptr", entry.csUAV, csUavBuf)
            csLastUav := entry.csUAV
        }
        static csInitialCount := Buffer(4, 0), csInitDone := false
        if (!csInitDone) {
            NumPut("uint", 0xFFFFFFFF, csInitialCount)  ; -1 = don't reset append counter
            csInitDone := true
        }
        ComCall(68, ctx, "uint", 0, "uint", 1, "ptr", csUavBuf, "ptr", csInitialCount, "int")

        ; Dispatch (vtable 41): ceil(numElements / 64) thread groups
        numGroups := (entry.csNumElements + 63) // 64
        ComCall(41, ctx, "uint", numGroups, "uint", 1, "uint", 1, "int")

        ; Unbind CS and UAV (clean state for PS phase)
        ComCall(69, ctx, "ptr", 0, "ptr", 0, "uint", 0, "int")
        static csNullUav := Buffer(A_PtrSize, 0)
        ComCall(68, ctx, "uint", 0, "uint", 1, "ptr", csNullUav, "ptr", csInitialCount, "int")
    }

    ; ClearRenderTargetView (vtable 50)
    static clearColor := _Shader_MakeClearColor()
    ComCall(50, ctx, "ptr", entry.rtv, "ptr", clearColor, "int")

    ; OMSetRenderTargets (vtable 33): count, ppRTVs, depthStencil
    static rtvBuf := Buffer(A_PtrSize, 0), lastRtv := 0
    if (entry.rtv != lastRtv) {
        NumPut("ptr", entry.rtv, rtvBuf)
        lastRtv := entry.rtv
    }
    ComCall(33, ctx, "uint", 1, "ptr", rtvBuf, "ptr", 0, "int")

    ; RSSetViewports (vtable 44)
    ; D3D11_VIEWPORT (24 bytes): TopLeftX, TopLeftY, Width, Height, MinDepth, MaxDepth
    static vp := Buffer(24, 0), vpW := 0, vpH := 0, vpMaxDepthSet := false
    if (!vpMaxDepthSet) {
        NumPut("float", 1.0, vp, 20)
        vpMaxDepthSet := true
    }
    vpChanged := (vpW != w || vpH != h)
    if (vpChanged) {
        vpW := w, vpH := h
        NumPut("float", Float(w), "float", Float(h), vp, 8)  ; PERF: combined NumPut
    }
    if (gShader_StateDirty || vpChanged)
        ComCall(44, ctx, "uint", 1, "ptr", vp, "int")

    ; --- Common pipeline state: skip when already set in this pre-BeginDraw batch ---
    if (gShader_StateDirty) {
        ; IASetPrimitiveTopology (vtable 24) — TRIANGLELIST = 4
        ComCall(24, ctx, "uint", 4, "int")

        ; VSSetShader (vtable 11): shader, classInstances, numClassInstances
        ComCall(11, ctx, "ptr", gShader_VS, "ptr", 0, "uint", 0, "int")

        ; PSSetConstantBuffers (vtable 16): startSlot, numBuffers, ppBuffers
        static cbBuf := Buffer(A_PtrSize, 0), cbBufLast := 0
        if (cb != cbBufLast) {
            NumPut("ptr", cb, cbBuf)
            cbBufLast := cb
        }
        ComCall(16, ctx, "uint", 0, "uint", 1, "ptr", cbBuf, "int")

        ; PSSetSamplers (vtable 10): bind all 8 slots with shared sampler
        if (gShader_Sampler) {
            static sampBuf := Buffer(A_PtrSize * 8, 0), sampFilled := 0
            if (sampFilled != gShader_Sampler) {
                Loop 8
                    NumPut("ptr", gShader_Sampler, sampBuf, (A_Index - 1) * A_PtrSize)
                sampFilled := gShader_Sampler
            }
            ComCall(10, ctx, "uint", 0, "uint", 8, "ptr", sampBuf, "int")
        }

        gShader_StateDirty := false
    }

    ; PSSetShader (vtable 9) — per-shader, always needed
    ComCall(9, ctx, "ptr", entry.ps, "ptr", 0, "uint", 0, "int")

    ; Bind iChannel texture SRVs if available (PSSetShaderResources vtable 8)
    nSrvs := entry.srvs.Length
    if (nSrvs > 0) {
        static srvBuf := 0, srvBufN := 0, lastSrvEntry := 0
        if (srvBufN != nSrvs) {
            srvBufN := nSrvs
            srvBuf := Buffer(A_PtrSize * nSrvs, 0)
            lastSrvEntry := 0  ; Force rebuild on resize
        }
        ; SRV pointers are stable per entry (textures don't change per frame) — skip rebuild
        if (lastSrvEntry != ObjPtr(entry)) {
            Loop nSrvs
                NumPut("ptr", entry.srvs[A_Index], srvBuf, (A_Index - 1) * A_PtrSize)
            lastSrvEntry := ObjPtr(entry)
        }
        ComCall(8, ctx, "uint", 0, "uint", nSrvs, "ptr", srvBuf, "int")
    }

    ; Bind compute particle buffer as SRV at slot 4 (PSSetShaderResources, startSlot=4)
    if (entry.csSRV) {
        static csParticleSrvBuf := Buffer(A_PtrSize, 0), csLastSrv := 0
        if (entry.csSRV != csLastSrv) {
            NumPut("ptr", entry.csSRV, csParticleSrvBuf)
            csLastSrv := entry.csSRV
        }
        ComCall(8, ctx, "uint", 4, "uint", 1, "ptr", csParticleSrvBuf, "int")
    }

    ; (Samplers bound once in dirty-flag block above)

    ; Draw (vtable 13): vertexCount=3, startVertexLocation=0
    ComCall(13, ctx, "uint", 3, "uint", 0, "int")

    ; Unbind RT + SRVs — skip when batching (deferred to Shader_EndBatch)
    if (!gShader_BatchMode) {
        ; Unbind render target — clean state for D2D BeginDraw
        ; OMSetRenderTargets(0, null, null)
        ComCall(33, ctx, "uint", 0, "ptr", 0, "ptr", 0, "int")

        ; Unbind SRVs: always clear slots 0-4 (iChannels + particle SRV).
        ; Unbinding slots that weren't bound is a D3D11 no-op (null → null).
        static nullSrvBuf5 := Buffer(A_PtrSize * 5, 0)
        if (nSrvs > 0 || entry.csSRV)
            ComCall(8, ctx, "uint", 0, "uint", 5, "ptr", nullSrvBuf5, "int")
    }

    ; D2D bitmap is backed by the render target's DXGI surface — no readback needed.
    ; D2D DrawImage reads directly from GPU memory. Command serialization on the
    ; shared immediate context guarantees the Draw() above completes before D2D reads.
    ; NOTE: The old staging-texture path had Map() here, which was an accidental GPU
    ; fence.  gui_paint.ahk's DwmFlush on grow resize compensates for its removal.
    ; If a GPU stall is ever re-added here, the DwmFlush becomes redundant but harmless.
    Profiler.Leave() ; @profile
    return entry.bitmap  ; PERF: return bitmap ptr directly (truthy when valid, 0 on failure paths)
}

; Helper: create a static 16-byte float4 clear color (0,0,0,0)
_Shader_MakeClearColor() {
    buf := Buffer(16, 0)
    return buf
}

; ========================= BITMAP ACCESS =========================

; Release render targets for shaders NOT in the given active set.
; activeNames: array of shader key strings currently in use.
Shader_ReleaseInactive(activeNames) {
    global gShader_Registry
    activeSet := Map()
    for _, n in activeNames {
        if (n != "")
            activeSet[n] := true
    }
    for name, entry in gShader_Registry {
        if (!activeSet.Has(name) && (entry.tex || entry.bitmap))
            _Shader_ReleaseRT(entry)
    }
}

; ========================= CLEANUP =========================

; Release all D3D11 shader resources. Safe to call multiple times.
Shader_Cleanup() {
    global gShader_D3DCtx, gShader_VS, gShader_CBuffer, gShader_Sampler, gShader_Registry, gShader_Ready
    global gShader_FrameCount

    ; Release per-shader resources (all raw COM ptrs).
    ; Aliases share ps, cs, csBuffer, csUAV, csSRV, and the srvs array with their
    ; source entry. Track released pointers to avoid double-Release on shared objects.
    released := Map()
    for _, entry in gShader_Registry {
        for _, srv in entry.srvs {
            if (srv && !released.Has(srv)) {
                ComCall(2, srv, "uint")
                released[srv] := true
            }
        }
        _Shader_ReleaseRT(entry)  ; RT resources (tex/rtv/bitmap) are per-entry, never shared
        ; Release compute resources
        if (entry.HasOwnProp("csSRV") && entry.csSRV && !released.Has(entry.csSRV)) {
            ComCall(2, entry.csSRV, "uint")
            released[entry.csSRV] := true
        }
        if (entry.HasOwnProp("csUAV") && entry.csUAV && !released.Has(entry.csUAV)) {
            ComCall(2, entry.csUAV, "uint")
            released[entry.csUAV] := true
        }
        if (entry.HasOwnProp("csBuffer") && entry.csBuffer && !released.Has(entry.csBuffer)) {
            ComCall(2, entry.csBuffer, "uint")
            released[entry.csBuffer] := true
        }
        if (entry.HasOwnProp("cs") && entry.cs && !released.Has(entry.cs)) {
            ComCall(2, entry.cs, "uint")
            released[entry.cs] := true
        }
        if (entry.ps && !released.Has(entry.ps)) {
            ComCall(2, entry.ps, "uint")
            released[entry.ps] := true
        }
    }
    gShader_Registry := Map()

    if (gShader_Sampler) {
        ComCall(2, gShader_Sampler)
        gShader_Sampler := 0
    }
    if (gShader_CBuffer) {
        ComCall(2, gShader_CBuffer)
        gShader_CBuffer := 0
    }
    if (gShader_VS) {
        ComCall(2, gShader_VS)
        gShader_VS := 0
    }
    if (gShader_D3DCtx) {
        ComCall(2, gShader_D3DCtx)
        gShader_D3DCtx := 0
    }

    gShader_Ready := false
    gShader_FrameCount := 0

    ; Shut down GDI+ if it was initialized for texture loading
    global _gShader_GdipToken
    if (_gShader_GdipToken) {
        DllCall("gdiplus\GdiplusShutdown", "ptr", _gShader_GdipToken)
        _gShader_GdipToken := 0
    }
}

; ========================= GDI+ INIT =========================

; One-shot GDI+ startup for texture loading. The main D2D pipeline doesn't use GDI+,
; but we need it here to decode PNG files into pixel data for D3D11 textures.
_Shader_InitGdiplus() {
    global _gShader_GdipToken
    if (_gShader_GdipToken)
        return _gShader_GdipToken
    si := Buffer(24, 0)  ; GdiplusStartupInput (x64)
    NumPut("uint", 1, si, 0)  ; GdiplusVersion = 1
    token := 0
    DllCall("gdiplus\GdiplusStartup", "ptr*", &token, "ptr", si, "ptr", 0)
    _gShader_GdipToken := token
    return token
}

; ========================= DIAGNOSTICS =========================

_Shader_LogInit() {
    global LOG_PATH_SHADER ; lint-ignore: phantom-global
    LogInitSession(LOG_PATH_SHADER, "Alt-Tabby Shader Pipeline Log")
}

_Shader_Log(msg) {
    global LOG_PATH_SHADER ; lint-ignore: phantom-global
    LogAppend(LOG_PATH_SHADER, msg)
}
