#Requires AutoHotkey v2.0
; D3D11 HLSL Shader Pipeline — runs converted Shadertoy shaders as backdrop effects.
; Renders to a DXGI texture before D2D BeginDraw, then composited via DrawImage.
;
; Architecture:
;   Shader_Init()     — get immediate context, compile fullscreen VS, create cbuffer
;   Shader_Register() — compile HLSL pixel shader, store in registry
;   Shader_PreRender()— lazy create/resize RT, bind pipeline, Draw(3,0)
;   Shader_GetBitmap()— return ID2D1Bitmap1 for D2D DrawImage
;   Shader_Cleanup()  — release all D3D11 resources
#Warn VarUnset, Off

; ========================= GLOBALS =========================

global gShader_D3DCtx := 0       ; ID3D11DeviceContext (immediate)
global gShader_VS := 0           ; ID3D11VertexShader (fullscreen triangle, shared)
global gShader_CBuffer := 0      ; ID3D11Buffer (16-byte constant buffer, shared)
global gShader_Registry := Map() ; name → {ps, tex, rtv, bitmap, w, h}
global gShader_Ready := false    ; true after Shader_Init succeeds
global gShader_DebugLog := true  ; TEMP: enable file-based debug logging

; ========================= DEBUG LOGGING =========================

_Shader_Log(msg) {
    global gShader_DebugLog
    if (!gShader_DebugLog)
        return
    static logPath := A_Temp "\tabby_shader_debug.log"
    static initialized := false
    if (!initialized) {
        try FileDelete(logPath)
        initialized := true
    }
    try FileAppend(FormatTime(, "HH:mm:ss") " " msg "`n", logPath)
}

; ========================= INIT =========================

; Initialize shader pipeline. Call after gD2D_D3DDevice is valid.
; Returns true on success, false if unavailable.
Shader_Init() {
    global gD2D_D3DDevice, gShader_D3DCtx, gShader_VS, gShader_CBuffer, gShader_Ready

    _Shader_Log("Shader_Init: START, gD2D_D3DDevice=" gD2D_D3DDevice)

    if (!gD2D_D3DDevice) {
        _Shader_Log("Shader_Init: ABORT - no D3D device")
        return false
    }

    try {
        ; Get immediate context (ID3D11Device::GetImmediateContext, vtable 40)
        pCtx := 0
        ComCall(40, gD2D_D3DDevice, "ptr*", &pCtx)
        _Shader_Log("Shader_Init: GetImmediateContext -> pCtx=" pCtx)
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

        vsBytecode := _Shader_Compile(vsHLSL, "VSMain", "vs_4_0")
        _Shader_Log("Shader_Init: VS compile -> " (vsBytecode ? "OK (" vsBytecode.Size " bytes)" : "FAILED"))
        if (!vsBytecode)
            return false

        ; CreateVertexShader (ID3D11Device vtable 12)
        pVS := 0
        hr := ComCall(12, gD2D_D3DDevice, "ptr", vsBytecode, "uptr", vsBytecode.Size, "ptr", 0, "ptr*", &pVS, "int")
        _Shader_Log("Shader_Init: CreateVertexShader hr=0x" Format("{:08X}", hr < 0 ? hr + 0x100000000 : hr) " pVS=" pVS)
        if (!pVS)
            return false
        gShader_VS := pVS

        ; Create constant buffer (16 bytes: time, resolution.xy, pad)
        ; D3D11_BUFFER_DESC (24 bytes): ByteWidth, Usage, BindFlags, CPUAccessFlags, MiscFlags, StructureByteStride
        bufDesc := Buffer(24, 0)
        NumPut("uint", 16, bufDesc, 0)       ; ByteWidth = 16
        NumPut("uint", 2, bufDesc, 4)        ; Usage = D3D11_USAGE_DYNAMIC
        NumPut("uint", 4, bufDesc, 8)        ; BindFlags = D3D11_BIND_CONSTANT_BUFFER
        NumPut("uint", 0x10000, bufDesc, 12) ; CPUAccessFlags = D3D11_CPU_ACCESS_WRITE

        ; CreateBuffer (ID3D11Device vtable 3)
        pCB := 0
        hr := ComCall(3, gD2D_D3DDevice, "ptr", bufDesc, "ptr", 0, "ptr*", &pCB, "int")
        _Shader_Log("Shader_Init: CreateBuffer hr=0x" Format("{:08X}", hr < 0 ? hr + 0x100000000 : hr) " pCB=" pCB)
        if (!pCB)
            return false
        gShader_CBuffer := pCB

        gShader_Ready := true
        _Shader_Log("Shader_Init: SUCCESS - ready=true")
        return true
    } catch as e {
        _Shader_Log("Shader_Init: EXCEPTION - " e.Message " @ " e.What)
        Shader_Cleanup()
        return false
    }
}

; ========================= COMPILE =========================

; Compile HLSL source to shader bytecode. Returns a Buffer with compiled bytes, or 0 on failure.
; Extracts bytecode immediately from the ID3DBlob and releases it — avoids vtable
; lifetime issues where the blob's vtable (inside d3dcompiler_47.dll) could become
; invalid if the DLL is unloaded between calls.
_Shader_Compile(hlsl, entryPoint, target) {
    _Shader_Log("_Shader_Compile: entry='" entryPoint "' target='" target "' hlslLen=" StrLen(hlsl))

    ; Ensure d3dcompiler_47 stays loaded (DllCall may unload between calls)
    static hModule := DllCall("LoadLibrary", "str", "d3dcompiler_47", "ptr")
    if (!hModule) {
        _Shader_Log("_Shader_Compile: FAILED - LoadLibrary d3dcompiler_47 returned 0")
        return 0
    }

    ; D3DCompile expects ANSI/UTF-8 source, not UTF-16.
    cbNeeded := StrPut(hlsl, "UTF-8")
    srcBuf := Buffer(cbNeeded)
    StrPut(hlsl, srcBuf, "UTF-8")
    srcLen := cbNeeded - 1  ; exclude null terminator
    _Shader_Log("_Shader_Compile: UTF-8 srcLen=" srcLen " bufSize=" cbNeeded)

    pBlob := 0
    pErrors := 0
    hr := DllCall("d3dcompiler_47\D3DCompile",
        "ptr", srcBuf, "uptr", srcLen,
        "ptr", 0, "ptr", 0, "ptr", 0,
        "astr", entryPoint, "astr", target,
        "uint", 0, "uint", 0,
        "ptr*", &pBlob, "ptr*", &pErrors, "int")

    _Shader_Log("_Shader_Compile: D3DCompile hr=0x" Format("{:08X}", hr < 0 ? hr + 0x100000000 : hr) " pBlob=" pBlob " pErrors=" pErrors)

    ; Extract error message before releasing
    if (pErrors) {
        try {
            pErrStr := ComCall(3, pErrors, "ptr")  ; GetBufferPointer
            if (pErrStr) {
                errMsg := StrGet(pErrStr, "UTF-8")
                _Shader_Log("_Shader_Compile: ERROR MSG: " errMsg)
            }
            ComCall(2, pErrors)
        }
    }

    if (hr < 0 || !pBlob) {
        _Shader_Log("_Shader_Compile: FAILED - hr < 0 or no blob")
        return 0
    }

    ; Extract bytecode into a persistent Buffer, then release the blob.
    ; This avoids holding a reference to a COM object whose vtable lives
    ; inside d3dcompiler_47.dll.
    pCode := ComCall(3, pBlob, "ptr")    ; GetBufferPointer
    codeSize := ComCall(4, pBlob, "uptr") ; GetBufferSize
    _Shader_Log("_Shader_Compile: bytecode pCode=" pCode " size=" codeSize)
    if (!pCode || !codeSize) {
        ComCall(2, pBlob)
        _Shader_Log("_Shader_Compile: FAILED - no bytecode")
        return 0
    }

    bytecode := Buffer(codeSize)
    DllCall("ntdll\RtlMoveMemory", "ptr", bytecode, "ptr", pCode, "uptr", codeSize)
    ComCall(2, pBlob)  ; Release blob — we have our own copy now
    _Shader_Log("_Shader_Compile: SUCCESS - " codeSize " bytes extracted")
    return bytecode
}

; ========================= REGISTER =========================

; Register a shader by name with HLSL pixel shader source.
; Compiles the PS and stores in registry. Returns true on success.
Shader_Register(name, hlsl) {
    global gD2D_D3DDevice, gShader_Registry, gShader_Ready

    _Shader_Log("Shader_Register: name='" name "' ready=" gShader_Ready " device=" gD2D_D3DDevice)

    if (!gShader_Ready || !gD2D_D3DDevice) {
        _Shader_Log("Shader_Register: ABORT - not ready or no device")
        return false
    }

    try {
        psBytecode := _Shader_Compile(hlsl, "PSMain", "ps_4_0")
        if (!psBytecode) {
            _Shader_Log("Shader_Register: FAILED - PS compile failed")
            return false
        }

        ; CreatePixelShader (ID3D11Device vtable 15)
        pPS := 0
        hr := ComCall(15, gD2D_D3DDevice, "ptr", psBytecode, "uptr", psBytecode.Size, "ptr", 0, "ptr*", &pPS, "int")
        _Shader_Log("Shader_Register: CreatePixelShader hr=0x" Format("{:08X}", hr < 0 ? hr + 0x100000000 : hr) " pPS=" pPS)
        if (!pPS)
            return false

        gShader_Registry[name] := {ps: pPS, tex: 0, rtv: 0, staging: 0, bitmap: 0, w: 0, h: 0}
        _Shader_Log("Shader_Register: SUCCESS - '" name "' registered")
        return true
    } catch as e {
        _Shader_Log("Shader_Register: EXCEPTION - " e.Message " @ " e.What)
        return false
    }
}

; ========================= RENDER TARGET =========================

; Lazy-create or resize the render target texture for a shader entry.
; Creates: D3D11 render target texture + RTV (for shader Draw), staging texture
; (for GPU→CPU readback), and a D2D bitmap (on gD2D_RT's device, for DrawImage).
_Shader_CreateRT(entry, w, h) {
    global gD2D_D3DDevice, gD2D_RT

    _Shader_Log("_Shader_CreateRT: w=" w " h=" h " device=" gD2D_D3DDevice " RT=" gD2D_RT.ptr)

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
    _Shader_Log("_Shader_CreateRT: CreateTexture2D hr=0x" Format("{:08X}", hr < 0 ? hr + 0x100000000 : hr) " pTex=" pTex)
    if (hr < 0 || !pTex)
        return false
    entry.tex := pTex

    ; CreateRenderTargetView (ID3D11Device vtable 9)
    pRTV := 0
    hr := ComCall(9, gD2D_D3DDevice, "ptr", pTex, "ptr", 0, "ptr*", &pRTV, "int")
    _Shader_Log("_Shader_CreateRT: CreateRTV hr=0x" Format("{:08X}", hr < 0 ? hr + 0x100000000 : hr) " pRTV=" pRTV)
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
    _Shader_Log("_Shader_CreateRT: CreateStaging hr=0x" Format("{:08X}", hr < 0 ? hr + 0x100000000 : hr) " pStaging=" pStaging)
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
    _Shader_Log("_Shader_CreateRT: CreateBitmap hr=0x" Format("{:08X}", hr < 0 ? hr + 0x100000000 : hr) " pBitmap=" pBitmap)
    if (hr < 0 || !pBitmap)
        return false
    entry.bitmap := pBitmap

    entry.w := w
    entry.h := h
    _Shader_Log("_Shader_CreateRT: SUCCESS - tex=" pTex " staging=" pStaging " bitmap=" pBitmap)
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
Shader_PreRender(name, w, h, timeSec) {
    global gShader_D3DCtx, gShader_VS, gShader_CBuffer, gShader_Registry, gShader_Ready

    ; Log only first call + on resize (avoid spamming per-frame)
    static lastLogW := 0, lastLogH := 0, callCount := 0
    callCount++
    doLog := (callCount <= 3 || w != lastLogW || h != lastLogH)
    if (doLog)
        _Shader_Log("Shader_PreRender: name='" name "' w=" w " h=" h " t=" Round(timeSec, 2) " ready=" gShader_Ready " has=" gShader_Registry.Has(name))

    if (!gShader_Ready || !gShader_Registry.Has(name)) {
        if (doLog)
            _Shader_Log("Shader_PreRender: ABORT - not ready or name not registered")
        return false
    }

    entry := gShader_Registry[name]
    if (!entry.ps) {
        if (doLog)
            _Shader_Log("Shader_PreRender: ABORT - no pixel shader")
        return false
    }

    ; Lazy create/resize render target
    if (entry.w != w || entry.h != h || !entry.tex) {
        _Shader_Log("Shader_PreRender: creating RT (old " entry.w "x" entry.h " -> new " w "x" h ")")
        if (!_Shader_CreateRT(entry, w, h)) {
            _Shader_Log("Shader_PreRender: _Shader_CreateRT FAILED")
            return false
        }
    }

    if (!entry.rtv || !entry.bitmap) {
        if (doLog)
            _Shader_Log("Shader_PreRender: ABORT - rtv=" entry.rtv " bitmap=" entry.bitmap)
        return false
    }

    ctx := gShader_D3DCtx

    ; Map cbuffer → write time, resolution → Unmap
    ; D3D11_MAPPED_SUBRESOURCE (16 bytes on x64): pData(0), RowPitch(8), DepthPitch(12)
    mapped := Buffer(16, 0)
    ; Map (vtable 14): resource, subresource, mapType=WRITE_DISCARD(4), mapFlags, mappedResource
    hr := ComCall(14, ctx, "ptr", gShader_CBuffer, "uint", 0, "uint", 4, "uint", 0, "ptr", mapped, "int")
    if (hr < 0) {
        if (doLog)
            _Shader_Log("Shader_PreRender: Map FAILED hr=0x" Format("{:08X}", hr + 0x100000000))
        return false
    }
    pData := NumGet(mapped, 0, "ptr")
    if (pData) {
        NumPut("float", Float(timeSec), pData, 0)        ; time
        NumPut("float", Float(w), pData, 4)               ; resolution.x
        NumPut("float", Float(h), pData, 8)               ; resolution.y
        NumPut("float", 0.0, pData, 12)                   ; _pad
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

    ; Draw (vtable 13): vertexCount=3, startVertexLocation=0
    ComCall(13, ctx, "uint", 3, "uint", 0)

    ; Unbind render target — clean state for D2D BeginDraw
    ; OMSetRenderTargets(0, null, null)
    ComCall(33, ctx, "uint", 0, "ptr", 0, "ptr", 0)

    ; --- GPU→CPU readback: copy rendered texture to D2D bitmap ---
    ; CopyResource (vtable 47): staging ← render texture
    ComCall(47, ctx, "ptr", entry.staging, "ptr", entry.tex)

    ; Map staging texture (vtable 14): D3D11_MAP_READ=1
    mapped := Buffer(16, 0)
    hr := ComCall(14, ctx, "ptr", entry.staging, "uint", 0, "uint", 1, "uint", 0, "ptr", mapped, "int")
    if (hr < 0) {
        if (doLog)
            _Shader_Log("Shader_PreRender: Map staging FAILED hr=0x" Format("{:08X}", hr + 0x100000000))
        return false
    }
    pPixels := NumGet(mapped, 0, "ptr")
    rowPitch := NumGet(mapped, A_PtrSize, "uint")

    ; CopyFromMemory on D2D bitmap (ID2D1Bitmap vtable 10): dstRect, srcData, pitch
    hr := ComCall(10, entry.bitmap, "ptr", 0, "ptr", pPixels, "uint", rowPitch, "int")

    ; Unmap staging (vtable 15)
    ComCall(15, ctx, "ptr", entry.staging, "uint", 0)

    if (doLog) {
        _Shader_Log("Shader_PreRender: readback rowPitch=" rowPitch " CopyFromMemory hr=0x" Format("{:08X}", hr < 0 ? hr + 0x100000000 : hr))
        _Shader_Log("Shader_PreRender: Draw(3,0) completed OK - VS=" gShader_VS " PS=" entry.ps " bitmap=" entry.bitmap)
        lastLogW := w
        lastLogH := h
    }

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
    if (!gShader_Registry.Has(name)) {
        static logMiss := true
        if (logMiss) {
            _Shader_Log("Shader_GetBitmap: name='" name "' NOT in registry")
            logMiss := false
        }
        return 0
    }
    bmp := gShader_Registry[name].bitmap
    static logFirst := true
    if (logFirst) {
        _Shader_Log("Shader_GetBitmap: name='" name "' bitmap=" bmp)
        logFirst := false
    }
    return bmp
}

; ========================= HLSL SOURCES =========================

; Matrix Rain — Shadertoy-style digital rain converted to HLSL.
Shader_HLSL_MatrixRain() {
    return "
    (
cbuffer Constants : register(b0) {
    float time;
    float2 resolution;
    float _pad;
};

// Hash function for pseudo-random
float hash(float2 p) {
    float h = dot(p, float2(127.1, 311.7));
    return frac(sin(h) * 43758.5453);
}

// Character-like pattern (simplified glyph)
float charPattern(float2 uv, float id) {
    // Grid of dots/bars simulating matrix glyphs
    float2 g = frac(uv * float2(3.0, 4.0) + hash(float2(id, id * 0.7)) * 10.0);
    float d = step(0.3, g.x) * step(0.3, g.y);
    // Mix patterns based on ID
    float pattern2 = step(0.5, frac(sin(id * 91.7) * 437.5));
    float bar = step(0.4, g.x) * step(g.y, 0.8);
    return lerp(d, bar, pattern2);
}

struct PSInput {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = fragCoord / resolution;

    // Grid parameters
    float colWidth = 14.0;  // pixels per column
    float rowHeight = 16.0; // pixels per row

    float col = floor(fragCoord.x / colWidth);
    float row = floor(fragCoord.y / rowHeight);

    // Per-column properties
    float colHash = hash(float2(col, 0.0));
    float speed = 2.0 + colHash * 4.0;        // Fall speed varies per column
    float offset = colHash * 100.0;             // Start offset
    float trailLen = 8.0 + colHash * 16.0;      // Trail length varies

    // Current position in the rain stream
    float rainPos = time * speed + offset;
    float headRow = frac(rainPos / 40.0) * (resolution.y / rowHeight + trailLen);

    // Distance from head of trail
    float dist = headRow - row;

    // Only draw if within trail
    if (dist < 0.0 || dist > trailLen) {
        return float4(0, 0, 0, 0);
    }

    // Brightness: bright at head, fading tail
    float brightness = 1.0 - (dist / trailLen);
    brightness = brightness * brightness; // Quadratic falloff

    // Head glow (first 2 chars are brighter/whiter)
    float headGlow = saturate(1.0 - dist * 0.5);

    // Character cell UV
    float2 cellUV = float2(frac(fragCoord.x / colWidth), frac(fragCoord.y / rowHeight));

    // Character ID changes over time (scrolling effect)
    float charId = hash(float2(col, floor(row + time * speed * 0.3)));

    // Character shape
    float ch = charPattern(cellUV, charId + floor(time * 2.0));

    // Color: green with white head
    float3 green = float3(0.1, 0.9, 0.3);
    float3 white = float3(0.8, 1.0, 0.85);
    float3 color = lerp(green, white, headGlow * 0.7);

    // Final alpha from character shape and trail brightness
    float alpha = ch * brightness * 0.9;

    // Slight column brightness variation
    alpha *= 0.6 + 0.4 * hash(float2(col * 7.3, 1.0));

    // Premultiplied alpha output for D2D compositing
    return float4(color * alpha, alpha);
}
    )"
}

; ========================= CLEANUP =========================

; Release all D3D11 shader resources. Safe to call multiple times.
Shader_Cleanup() {
    global gShader_D3DCtx, gShader_VS, gShader_CBuffer, gShader_Registry, gShader_Ready

    ; Release per-shader resources (all raw COM ptrs)
    for _, entry in gShader_Registry {
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
}
