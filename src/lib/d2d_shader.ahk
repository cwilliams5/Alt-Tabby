#Requires AutoHotkey v2.0
; D3D11 HLSL Shader Pipeline — runs converted Shadertoy shaders as backdrop effects.
; Renders to a DXGI texture before D2D BeginDraw, then composited via DrawImage.
;
; Architecture:
;   Shader_Init()     — get immediate context, compile fullscreen VS, create cbuffer
;   Shader_Register() — compile HLSL pixel shader, store in registry (with metadata)
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
global gShader_LastTime := 0.0   ; previous frame time for timeDelta

; ========================= INIT =========================

; Initialize shader pipeline. Call after gD2D_D3DDevice is valid.
; Returns true on success, false if unavailable.
Shader_Init() {
    global gD2D_D3DDevice, gShader_D3DCtx, gShader_VS, gShader_CBuffer, gShader_Sampler, gShader_Ready

    if (!gD2D_D3DDevice)
        return false

    if (cfg.DiagShaderLog)
        _Shader_LogInit()

    try {
        ; Get immediate context (ID3D11Device::GetImmediateContext, vtable 40)
        pCtx := 0
        ComCall(40, gD2D_D3DDevice, "ptr*", &pCtx)
        if (!pCtx)
            return false
        gShader_D3DCtx := pCtx

        ; Compile fullscreen triangle vertex shader
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
        if (!vsBytecode)
            return false

        ; CreateVertexShader (ID3D11Device vtable 12)
        pVS := 0
        hr := ComCall(12, gD2D_D3DDevice, "ptr", vsBytecode, "uptr", vsBytecode.Size, "ptr", 0, "ptr*", &pVS, "int")
        if (!pVS)
            return false
        gShader_VS := pVS

        ; Create constant buffer (32 bytes: time, resolution.xy, timeDelta, frame, darken, desaturate, _pad)
        ; D3D11_BUFFER_DESC (24 bytes): ByteWidth, Usage, BindFlags, CPUAccessFlags, MiscFlags, StructureByteStride
        bufDesc := Buffer(24, 0)
        NumPut("uint", 32, bufDesc, 0)       ; ByteWidth = 32
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
    ; Check bytecode cache first
    cacheKey := cacheName ? cacheName : entryPoint
    hash := _Shader_HashSource(hlsl, entryPoint, target)
    if (hash) {
        cached := _Shader_CacheRead(cacheKey, hash)
        if (cached) {
            if (cfg.DiagShaderLog)
                _Shader_Log("Compile " cacheKey ": cache HIT (" cached.Size " bytes)")
            return cached
        }
    }

    ; Ensure d3dcompiler_47 stays loaded (DllCall may unload between calls)
    static hModule := DllCall("LoadLibrary", "str", "d3dcompiler_47", "ptr")
    if (!hModule)
        return 0

    ; D3DCompile expects ANSI/UTF-8 source, not UTF-16.
    cbNeeded := StrPut(hlsl, "UTF-8")
    srcBuf := Buffer(cbNeeded)
    StrPut(hlsl, srcBuf, "UTF-8")
    srcLen := cbNeeded - 1  ; exclude null terminator

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
            if (pErrStr && errLen && cfg.DiagShaderLog)
                _Shader_Log("Compile errors: " StrGet(pErrStr, errLen, "UTF-8"))
            ComCall(2, pErrors)
        }
    }

    if (hr < 0 || !pBlob) {
        if (cfg.DiagShaderLog)
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
        if (cfg.DiagShaderLog)
            _Shader_Log("Compile " cacheKey ": cache MISS, compiled + wrote " bytecode.Size " bytes")
    }

    return bytecode
}

; ========================= BYTECODE CACHE =========================

; Compute MD5 hash of (hlsl + entryPoint + target) via Windows CNG (bcrypt.dll).
; Returns a 16-byte Buffer, or 0 on failure.
_Shader_HashSource(hlsl, entryPoint, target) {
    ; Concatenate with null separators to avoid collisions
    combined := hlsl "`n" entryPoint "`n" target
    cbNeeded := StrPut(combined, "UTF-8")
    srcBuf := Buffer(cbNeeded)
    StrPut(combined, srcBuf, "UTF-8")
    srcLen := cbNeeded - 1

    hAlg := 0
    hr := DllCall("bcrypt\BCryptOpenAlgorithmProvider",
        "ptr*", &hAlg, "str", "MD5", "ptr", 0, "uint", 0, "int")
    if (hr < 0 || !hAlg)
        return 0

    hHash := 0
    hr := DllCall("bcrypt\BCryptCreateHash",
        "ptr", hAlg, "ptr*", &hHash, "ptr", 0, "uint", 0, "ptr", 0, "uint", 0, "uint", 0, "int")
    if (hr < 0 || !hHash) {
        DllCall("bcrypt\BCryptCloseAlgorithmProvider", "ptr", hAlg, "uint", 0)
        return 0
    }

    hr := DllCall("bcrypt\BCryptHashData",
        "ptr", hHash, "ptr", srcBuf, "uint", srcLen, "uint", 0, "int")
    if (hr < 0) {
        DllCall("bcrypt\BCryptDestroyHash", "ptr", hHash)
        DllCall("bcrypt\BCryptCloseAlgorithmProvider", "ptr", hAlg, "uint", 0)
        return 0
    }

    digest := Buffer(16, 0)  ; MD5 = 16 bytes
    hr := DllCall("bcrypt\BCryptFinishHash",
        "ptr", hHash, "ptr", digest, "uint", 16, "uint", 0, "int")
    DllCall("bcrypt\BCryptDestroyHash", "ptr", hHash)
    DllCall("bcrypt\BCryptCloseAlgorithmProvider", "ptr", hAlg, "uint", 0)

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
Shader_Register(name, hlsl, meta := "") {
    global gD2D_D3DDevice, gShader_Registry, gShader_Ready

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
        hr := ComCall(15, gD2D_D3DDevice, "ptr", psBytecode, "uptr", psBytecode.Size, "ptr", 0, "ptr*", &pPS, "int")
        if (!pPS)
            return false

        gShader_Registry[name] := {ps: pPS, tex: 0, rtv: 0, staging: 0, bitmap: 0, w: 0, h: 0, meta: meta, srvs: []}

        ; Load iChannel textures (lazy — loaded here at register time for simplicity)
        if (meta.HasOwnProp("iChannels") && meta.iChannels.Length > 0) {
            _Shader_LoadTextures(name)
        }

        return true
    } catch as e {
        return false
    }
}

; ========================= iCHANNEL TEXTURES =========================

; Load iChannel textures for a shader. GDI+ → CreateTexture2D → CreateShaderResourceView.
; Loads ALL iChannels specified in metadata and stores SRVs in entry.srvs[] (ordered by channel index).
_Shader_LoadTextures(name) {
    global gD2D_D3DDevice, gShader_Registry

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
    global gD2D_D3DDevice
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
        ; Rect struct: {x, y, w, h} as int32s
        lockRect := Buffer(16, 0)
        NumPut("int", 0, lockRect, 0)
        NumPut("int", 0, lockRect, 4)
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

; Lazy-create or resize the render target texture for a shader entry.
; Creates: D3D11 render target texture + RTV (for shader Draw), staging texture
; (for GPU→CPU readback), and a D2D bitmap (on gD2D_RT's device, for DrawImage).
_Shader_CreateRT(entry, w, h) {
    global gD2D_D3DDevice, gD2D_RT

    ; Release old resources (raw COM ptrs from ComCall "ptr*")
    if (entry.bitmap) {
        ComCall(2, entry.bitmap)  ; IUnknown::Release
        entry.bitmap := 0
    }
    if (entry.staging) {
        ComCall(2, entry.staging)
        entry.staging := 0
    }
    if (entry.rtv) {
        ComCall(2, entry.rtv)
        entry.rtv := 0
    }
    if (entry.tex) {
        ComCall(2, entry.tex)
        entry.tex := 0
    }

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

    ; --- Staging texture (for GPU→CPU readback) ---
    stagingDesc := Buffer(44, 0)
    NumPut("uint", w, stagingDesc, 0)         ; Width
    NumPut("uint", h, stagingDesc, 4)         ; Height
    NumPut("uint", 1, stagingDesc, 8)         ; MipLevels
    NumPut("uint", 1, stagingDesc, 12)        ; ArraySize
    NumPut("uint", 87, stagingDesc, 16)       ; Format = DXGI_FORMAT_B8G8R8A8_UNORM
    NumPut("uint", 1, stagingDesc, 20)        ; SampleDesc.Count
    NumPut("uint", 0, stagingDesc, 24)        ; SampleDesc.Quality
    NumPut("uint", 3, stagingDesc, 28)        ; Usage = D3D11_USAGE_STAGING
    NumPut("uint", 0, stagingDesc, 32)        ; BindFlags = 0 (staging can't bind)
    NumPut("uint", 0x20000, stagingDesc, 36)  ; CPUAccessFlags = D3D11_CPU_ACCESS_READ

    pStaging := 0
    hr := ComCall(5, gD2D_D3DDevice, "ptr", stagingDesc, "ptr", 0, "ptr*", &pStaging, "int")
    if (hr < 0 || !pStaging)
        return false
    entry.staging := pStaging

    ; --- D2D bitmap (on gD2D_RT's device — compatible for DrawImage) ---
    ; ID2D1RenderTarget::CreateBitmap (vtable 4)
    ; D2D1_SIZE_U passed by value as int64: width in low 32 bits, height in high 32
    sizeVal := w | (h << 32)
    ; D2D1_BITMAP_PROPERTIES (16 bytes): {format, alphaMode}, dpiX, dpiY
    bmpProps := Buffer(16, 0)
    NumPut("uint", 87, bmpProps, 0)       ; format = DXGI_FORMAT_B8G8R8A8_UNORM
    NumPut("uint", 1, bmpProps, 4)        ; alphaMode = D2D1_ALPHA_MODE_PREMULTIPLIED
    NumPut("float", 96.0, bmpProps, 8)    ; dpiX
    NumPut("float", 96.0, bmpProps, 12)   ; dpiY

    pBitmap := 0
    hr := ComCall(4, gD2D_RT, "int64", sizeVal, "ptr", 0, "uint", 0, "ptr", bmpProps, "ptr*", &pBitmap, "int")
    if (hr < 0 || !pBitmap)
        return false
    entry.bitmap := pBitmap

    entry.w := w
    entry.h := h
    return true
}

; GUID helper
_Shader_MakeGUID(str) {
    buf := Buffer(16, 0)
    DllCall("ole32\CLSIDFromString", "str", str, "ptr", buf, "hresult")
    return buf
}

; ========================= PRE-RENDER =========================

; Run the D3D11 shader pipeline. Call BEFORE D2D BeginDraw.
; timeSec: elapsed time in seconds. darken/desaturate: 0.0-1.0 post-processing.
Shader_PreRender(name, w, h, timeSec, darken := 0.0, desaturate := 0.0) {
    global gShader_D3DCtx, gShader_VS, gShader_CBuffer, gShader_Sampler, gShader_Registry, gShader_Ready
    global gShader_FrameCount, gShader_LastTime
    static dbgRendered := Map()

    if (!gShader_Ready || !gShader_Registry.Has(name))
        return false

    ; One-time log per shader name
    if (cfg.DiagShaderLog && !dbgRendered.Has(name)) {
        dbgRendered[name] := true
        entry_ := gShader_Registry[name]
        _Shader_Log("PreRender FIRST: " name " srvs=" entry_.srvs.Length " sampler=" gShader_Sampler " ps=" entry_.ps)
    }

    entry := gShader_Registry[name]
    if (!entry.ps)
        return false

    ; Lazy create/resize render target
    if (entry.w != w || entry.h != h || !entry.tex) {
        if (!_Shader_CreateRT(entry, w, h))
            return false
    }

    if (!entry.rtv || !entry.bitmap)
        return false

    ctx := gShader_D3DCtx

    ; Compute timeDelta
    timeDelta := 0.0
    if (gShader_LastTime > 0)
        timeDelta := timeSec - gShader_LastTime
    gShader_LastTime := timeSec
    gShader_FrameCount += 1

    ; Map cbuffer → write all 32 bytes → Unmap
    ; D3D11_MAPPED_SUBRESOURCE (16 bytes on x64): pData(0), RowPitch(8), DepthPitch(12)
    mapped := Buffer(16, 0)
    ; Map (vtable 14): resource, subresource, mapType=WRITE_DISCARD(4), mapFlags, mappedResource
    hr := ComCall(14, ctx, "ptr", gShader_CBuffer, "uint", 0, "uint", 4, "uint", 0, "ptr", mapped, "int")
    if (hr < 0)
        return false
    pData := NumGet(mapped, 0, "ptr")
    if (pData) {
        NumPut("float", Float(timeSec), pData, 0)          ; time        (offset 0)
        NumPut("float", Float(w), pData, 4)                 ; resolution.x (offset 4)
        NumPut("float", Float(h), pData, 8)                 ; resolution.y (offset 8)
        NumPut("float", Float(timeDelta), pData, 12)        ; timeDelta   (offset 12)
        NumPut("uint", gShader_FrameCount, pData, 16)       ; frame       (offset 16)
        NumPut("float", Float(darken), pData, 20)           ; darken      (offset 20)
        NumPut("float", Float(desaturate), pData, 24)       ; desaturate  (offset 24)
        NumPut("float", 0.0, pData, 28)                     ; _pad        (offset 28)
    }
    ; Unmap (vtable 15)
    ComCall(15, ctx, "ptr", gShader_CBuffer, "uint", 0)

    ; ClearRenderTargetView (vtable 50) — transparent black
    static clearColor := _Shader_MakeClearColor()
    ComCall(50, ctx, "ptr", entry.rtv, "ptr", clearColor)

    ; OMSetRenderTargets (vtable 33): count, ppRTVs, depthStencil
    rtvBuf := Buffer(A_PtrSize, 0)
    NumPut("ptr", entry.rtv, rtvBuf)
    ComCall(33, ctx, "uint", 1, "ptr", rtvBuf, "ptr", 0)

    ; RSSetViewports (vtable 44)
    ; D3D11_VIEWPORT (24 bytes): TopLeftX, TopLeftY, Width, Height, MinDepth, MaxDepth
    vp := Buffer(24, 0)
    NumPut("float", 0.0, vp, 0)         ; TopLeftX
    NumPut("float", 0.0, vp, 4)         ; TopLeftY
    NumPut("float", Float(w), vp, 8)    ; Width
    NumPut("float", Float(h), vp, 12)   ; Height
    NumPut("float", 0.0, vp, 16)        ; MinDepth
    NumPut("float", 1.0, vp, 20)        ; MaxDepth
    ComCall(44, ctx, "uint", 1, "ptr", vp)

    ; IASetPrimitiveTopology (vtable 24) — TRIANGLELIST = 4
    ComCall(24, ctx, "uint", 4)

    ; VSSetShader (vtable 11): shader, classInstances, numClassInstances
    ComCall(11, ctx, "ptr", gShader_VS, "ptr", 0, "uint", 0)

    ; PSSetShader (vtable 9)
    ComCall(9, ctx, "ptr", entry.ps, "ptr", 0, "uint", 0)

    ; PSSetConstantBuffers (vtable 16): startSlot, numBuffers, ppBuffers
    cbBuf := Buffer(A_PtrSize, 0)
    NumPut("ptr", gShader_CBuffer, cbBuf)
    ComCall(16, ctx, "uint", 0, "uint", 1, "ptr", cbBuf)

    ; Bind iChannel texture SRVs if available (PSSetShaderResources vtable 8)
    nSrvs := entry.srvs.Length
    if (nSrvs > 0) {
        srvBuf := Buffer(A_PtrSize * nSrvs, 0)
        Loop nSrvs
            NumPut("ptr", entry.srvs[A_Index], srvBuf, (A_Index - 1) * A_PtrSize)
        ComCall(8, ctx, "uint", 0, "uint", nSrvs, "ptr", srvBuf)
    }

    ; Bind sampler state to all slots used by SRVs (PSSetSamplers vtable 10)
    if (gShader_Sampler) {
        nSamplers := Max(nSrvs, 1)
        sampBuf := Buffer(A_PtrSize * nSamplers, 0)
        Loop nSamplers
            NumPut("ptr", gShader_Sampler, sampBuf, (A_Index - 1) * A_PtrSize)
        ComCall(10, ctx, "uint", 0, "uint", nSamplers, "ptr", sampBuf)
    }

    ; Draw (vtable 13): vertexCount=3, startVertexLocation=0
    ComCall(13, ctx, "uint", 3, "uint", 0)

    ; Unbind render target — clean state for D2D BeginDraw
    ; OMSetRenderTargets(0, null, null)
    ComCall(33, ctx, "uint", 0, "ptr", 0, "ptr", 0)

    ; Unbind SRVs if they were bound
    if (nSrvs > 0) {
        nullSrvBuf := Buffer(A_PtrSize * nSrvs, 0)
        ComCall(8, ctx, "uint", 0, "uint", nSrvs, "ptr", nullSrvBuf)
    }

    ; --- GPU→CPU readback: copy rendered texture to D2D bitmap ---
    ; CopyResource (vtable 47): staging ← render texture
    ComCall(47, ctx, "ptr", entry.staging, "ptr", entry.tex)

    ; Map staging texture (vtable 14): D3D11_MAP_READ=1
    mapped := Buffer(16, 0)
    hr := ComCall(14, ctx, "ptr", entry.staging, "uint", 0, "uint", 1, "uint", 0, "ptr", mapped, "int")
    if (hr < 0)
        return false
    pPixels := NumGet(mapped, 0, "ptr")
    rowPitch := NumGet(mapped, A_PtrSize, "uint")

    ; CopyFromMemory on D2D bitmap (ID2D1Bitmap vtable 10): dstRect, srcData, pitch
    ComCall(10, entry.bitmap, "ptr", 0, "ptr", pPixels, "uint", rowPitch, "int")

    ; Unmap staging (vtable 15)
    ComCall(15, ctx, "ptr", entry.staging, "uint", 0)

    return true
}

; Helper: create a static 16-byte float4 clear color (0,0,0,0)
_Shader_MakeClearColor() {
    buf := Buffer(16, 0)
    return buf
}

; ========================= BITMAP ACCESS =========================

; Return the ID2D1Bitmap1 ptr for DrawImage. Returns 0 if not available.
Shader_GetBitmap(name) {
    global gShader_Registry
    if (!gShader_Registry.Has(name))
        return 0
    return gShader_Registry[name].bitmap
}

; Return the metadata for a registered shader, or 0 if not found.
Shader_GetMeta(name) {
    global gShader_Registry
    if (!gShader_Registry.Has(name))
        return 0
    return gShader_Registry[name].meta
}

; ========================= CLEANUP =========================

; Release all D3D11 shader resources. Safe to call multiple times.
Shader_Cleanup() {
    global gShader_D3DCtx, gShader_VS, gShader_CBuffer, gShader_Sampler, gShader_Registry, gShader_Ready
    global gShader_FrameCount, gShader_LastTime

    ; Release per-shader resources (all raw COM ptrs)
    for _, entry in gShader_Registry {
        for _, srv in entry.srvs {
            if (srv)
                ComCall(2, srv)
        }
        if (entry.bitmap)
            ComCall(2, entry.bitmap)
        if (entry.staging)
            ComCall(2, entry.staging)
        if (entry.rtv)
            ComCall(2, entry.rtv)
        if (entry.tex)
            ComCall(2, entry.tex)
        if (entry.ps)
            ComCall(2, entry.ps)
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
    gShader_LastTime := 0.0
}

; ========================= GDI+ INIT =========================

; One-shot GDI+ startup for texture loading. The main D2D pipeline doesn't use GDI+,
; but we need it here to decode PNG files into pixel data for D3D11 textures.
_Shader_InitGdiplus() {
    si := Buffer(24, 0)  ; GdiplusStartupInput (x64)
    NumPut("uint", 1, si, 0)  ; GdiplusVersion = 1
    token := 0
    DllCall("gdiplus\GdiplusStartup", "ptr*", &token, "ptr", si, "ptr", 0)
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
