#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Cross-file globals (cfg) come from alt_tabby.ahk

; ============================================================
; Launcher Splash Screen - Image (PNG) or Animation (WebP)
; ============================================================
; Image mode: Shows a transparent PNG with fade in/out
; Animation mode: Plays animated WebP with configurable fade phases
; Uses UpdateLayeredWindow for per-pixel alpha blending.

; ============================================================
; Shared globals (used by both modes)
; ============================================================
global g_SplashHwnd := 0
global g_SplashStartTick := 0
global g_SplashHdc := 0
global g_SplashHdcScreen := 0
global g_SplashToken := 0
global g_SplashHModule := 0
global g_SplashImgW := 0
global g_SplashImgH := 0
global g_SplashPosX := 0
global g_SplashPosY := 0
global g_SplashDIB := 0
global g_SplashDIBOld := 0
global g_SplashShuttingDown := false
global g_SplashMode := ""  ; "Image" or "Animation"

; ============================================================
; Image mode globals
; ============================================================
global g_SplashBitmap := 0

; ============================================================
; Animation mode globals
; ============================================================
global g_SplashFrames := []
global g_SplashFrameBuffers := []
global g_SplashFrameCount := 0
global g_SplashTotalFrames := 0
global g_SplashCurrentFrame := 0
global g_SplashAlpha := 0
global g_SplashFadeState := ""
global g_SplashFadeStartTick := 0
global g_SplashRunning := false
global g_SplashFrameMs := 42
global g_SplashLoopCount := 0
global g_SplashDemuxDllName := ""
global g_SplashHWebP := 0
global g_SplashHSharpYuv := 0
global g_SplashHDemux := 0
global g_SplashExtractedDlls := []  ; Paths to extracted DLLs (for cleanup)
global g_SplashExtractedWebP := ""  ; Path to extracted animation.webp (for cleanup)

; Streaming mode globals (when SplashAnimBufferFrames > 0)
global g_SplashStreaming := false       ; True if streaming mode active
global g_SplashDecoder := 0             ; WebP decoder (kept alive for streaming)
global g_SplashFileData := 0            ; File data buffer (kept alive while decoder exists)
global g_SplashFrameBuffer := Map()     ; Circular buffer: frameNum -> {bitmap, pixelBuf}
global g_SplashNextDecodeFrame := 1     ; Next frame to decode
global g_SplashDecoderExhausted := false

; Cleanup a single GDI/system resource (helper to reduce repetition)
_Splash_CleanupResource(&globalRef, cleanupFn, dllName := "", extraArg := "") {
    if (!globalRef)
        return
    try {
        if (extraArg != "") {
            DllCall(cleanupFn, "ptr", extraArg, "ptr", globalRef)
        } else if (dllName != "") {
            DllCall(dllName "\" cleanupFn, "ptr", globalRef)
        } else {
            DllCall(cleanupFn, "ptr", globalRef)
        }
    }
    globalRef := 0
}

; ============================================================
; Main Entry Points
; ============================================================

ShowSplashScreen() {
    global g_SplashMode, g_SplashStartTick, cfg

    g_SplashStartTick := A_TickCount
    g_SplashMode := cfg.LauncherSplashScreen

    if (g_SplashMode = "Image")
        _Splash_ShowImage()
    else if (g_SplashMode = "Animation")
        _Splash_ShowAnimation()
    ; "None" = do nothing
}

HideSplashScreen() {
    global g_SplashMode

    if (g_SplashMode = "Image")
        _Splash_HideImage()
    else if (g_SplashMode = "Animation")
        _Splash_HideAnimation()
}

; Returns true if splash is active and should block (for timing in launcher_main)
IsSplashActive() {
    global g_SplashHwnd
    return g_SplashHwnd != 0
}

; ============================================================
; IMAGE MODE - Static PNG with fade
; ============================================================

_Splash_ShowImage() {
    global g_SplashHwnd, g_SplashBitmap, g_SplashHdc, g_SplashToken
    global g_SplashHdcScreen, g_SplashImgW, g_SplashImgH, g_SplashPosX, g_SplashPosY
    global g_SplashHModule, g_SplashDIB, g_SplashDIBOld, cfg
    global RES_ID_LOGO

    ; Load GDI+ library first
    g_SplashHModule := DllCall("LoadLibrary", "str", "gdiplus", "ptr")
    if (!g_SplashHModule)
        return

    ; Start GDI+
    si := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
    NumPut("UInt", 1, si, 0)
    g_SplashToken := 0
    DllCall("gdiplus\GdiplusStartup", "ptr*", &g_SplashToken, "ptr", si.Ptr, "ptr", 0)
    if (!g_SplashToken) {
        _Splash_CleanupResource(&g_SplashHModule, "FreeLibrary")
        return
    }

    ; Load PNG - from embedded resource (compiled) or file (dev mode)
    g_SplashBitmap := 0
    if (A_IsCompiled) {
        g_SplashBitmap := Splash_LoadBitmapFromResource(RES_ID_LOGO)
    } else {
        imgPath := A_ScriptDir "\..\resources\img\logo.png"
        if (FileExist(imgPath))
            DllCall("gdiplus\GdipCreateBitmapFromFile", "wstr", imgPath, "ptr*", &g_SplashBitmap)
    }

    if (!g_SplashBitmap) {
        _Splash_CleanupResource(&g_SplashToken, "GdiplusShutdown", "gdiplus")
        _Splash_CleanupResource(&g_SplashHModule, "FreeLibrary")
        return
    }

    ; Get image dimensions
    g_SplashImgW := 0, g_SplashImgH := 0
    DllCall("gdiplus\GdipGetImageWidth", "ptr", g_SplashBitmap, "uint*", &g_SplashImgW)
    DllCall("gdiplus\GdipGetImageHeight", "ptr", g_SplashBitmap, "uint*", &g_SplashImgH)

    ; Create window and DC
    _Splash_CreateWindow()
    if (!g_SplashHwnd)
        return

    ; Draw PNG onto DIB
    _Splash_DrawBitmapToHdc(g_SplashBitmap)

    ; Show and fade in
    DllCall("ShowWindow", "ptr", g_SplashHwnd, "int", 8)  ; SW_SHOWNA
    _Splash_UpdateLayeredWindowAlpha(0)
    _Splash_Fade(0, 255, cfg.LauncherSplashImageFadeMs)
}

_Splash_HideImage() {
    global g_SplashHwnd, g_SplashBitmap, g_SplashHdc, g_SplashToken
    global g_SplashHdcScreen, g_SplashHModule, g_SplashDIB, g_SplashDIBOld
    global g_SplashShuttingDown, cfg

    g_SplashShuttingDown := true

    if (g_SplashHwnd) {
        _Splash_Fade(255, 0, cfg.LauncherSplashImageFadeMs)
        _Splash_CleanupResource(&g_SplashHwnd, "DestroyWindow")
    }

    ; Restore original bitmap, then cleanup
    if (g_SplashHdc && g_SplashDIBOld)
        try DllCall("gdi32\SelectObject", "ptr", g_SplashHdc, "ptr", g_SplashDIBOld)
    g_SplashDIBOld := 0
    _Splash_CleanupResource(&g_SplashDIB, "DeleteObject")
    _Splash_CleanupResource(&g_SplashHdc, "DeleteDC")
    _Splash_CleanupResource(&g_SplashHdcScreen, "ReleaseDC", "", 0)
    _Splash_CleanupResource(&g_SplashBitmap, "GdipDisposeImage", "gdiplus")
    _Splash_CleanupResource(&g_SplashToken, "GdiplusShutdown", "gdiplus")
    _Splash_CleanupResource(&g_SplashHModule, "FreeLibrary")
}

; ============================================================
; ANIMATION MODE - Animated WebP
; ============================================================

_Splash_ShowAnimation() {
    global g_SplashHwnd, g_SplashHdc, g_SplashToken, g_SplashHdcScreen
    global g_SplashImgW, g_SplashImgH, g_SplashHModule, g_SplashDIB, g_SplashDIBOld
    global g_SplashFrames, g_SplashFrameCount, g_SplashCurrentFrame, g_SplashTotalFrames
    global g_SplashAlpha, g_SplashFadeState, g_SplashFadeStartTick, g_SplashStreaming
    global g_SplashRunning, g_SplashFrameMs, g_SplashLoopCount, g_SplashExtractedWebP, cfg
    global RES_ID_ANIMATION

    ; Load WebP DLLs
    if (!_Splash_LoadWebPDlls())
        return

    ; Load GDI+ library
    g_SplashHModule := DllCall("LoadLibrary", "str", "gdiplus", "ptr")
    if (!g_SplashHModule) {
        _Splash_UnloadWebPDlls()
        return
    }

    ; Start GDI+
    si := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
    NumPut("UInt", 1, si, 0)
    g_SplashToken := 0
    DllCall("gdiplus\GdiplusStartup", "ptr*", &g_SplashToken, "ptr", si.Ptr, "ptr", 0)
    if (!g_SplashToken) {
        _Splash_CleanupResource(&g_SplashHModule, "FreeLibrary")
        _Splash_UnloadWebPDlls()
        return
    }

    ; Load WebP frames
    webpPath := ""
    if (A_IsCompiled) {
        ; Extract animation.webp from resources to temp
        webpPath := _Splash_ExtractResourceToTemp(RES_ID_ANIMATION, "animation.webp")
        g_SplashExtractedWebP := webpPath  ; Save for cleanup
    } else {
        webpPath := A_ScriptDir "\..\resources\animation.webp"
    }

    if (!webpPath || !FileExist(webpPath)) {
        _Splash_CleanupResource(&g_SplashToken, "GdiplusShutdown", "gdiplus")
        _Splash_CleanupResource(&g_SplashHModule, "FreeLibrary")
        _Splash_UnloadWebPDlls()
        return
    }

    ; Determine streaming vs preload mode
    bufferFrames := cfg.LauncherSplashAnimBufferFrames
    g_SplashStreaming := (bufferFrames > 0)

    if (g_SplashStreaming) {
        ; Streaming mode: initialize decoder and pre-buffer
        if (!_Splash_InitStreamingDecoder(webpPath)) {
            _Splash_CleanupResource(&g_SplashToken, "GdiplusShutdown", "gdiplus")
            _Splash_CleanupResource(&g_SplashHModule, "FreeLibrary")
            _Splash_UnloadWebPDlls()
            return
        }
        ; Pre-buffer initial frames
        Loop Min(bufferFrames, g_SplashTotalFrames) {
            if (!_Splash_DecodeNextFrame())
                break
        }
        g_SplashFrameCount := g_SplashTotalFrames
    } else {
        ; Preload mode: decode all frames upfront
        if (!_Splash_LoadWebPFrames(webpPath)) {
            _Splash_CleanupResource(&g_SplashToken, "GdiplusShutdown", "gdiplus")
            _Splash_CleanupResource(&g_SplashHModule, "FreeLibrary")
            _Splash_UnloadWebPDlls()
            return
        }
        g_SplashFrameCount := g_SplashFrames.Length
        g_SplashTotalFrames := g_SplashFrameCount
    }

    if (g_SplashFrameCount = 0) {
        _Splash_CleanupResource(&g_SplashToken, "GdiplusShutdown", "gdiplus")
        _Splash_CleanupResource(&g_SplashHModule, "FreeLibrary")
        _Splash_UnloadWebPDlls()
        return
    }

    ; Create window and DC
    _Splash_CreateWindow()
    if (!g_SplashHwnd)
        return

    ; Show window
    DllCall("ShowWindow", "ptr", g_SplashHwnd, "int", 8)  ; SW_SHOWNA

    ; Initialize animation state
    g_SplashCurrentFrame := 1
    g_SplashAlpha := 0
    g_SplashLoopCount := 0
    g_SplashFadeStartTick := A_TickCount
    _Splash_DrawAnimFrame(1)

    ; Start fade sequence
    if (cfg.LauncherSplashAnimFadeInFixedMs > 0) {
        g_SplashFadeState := "in_fixed"
        g_SplashRunning := false
    } else if (cfg.LauncherSplashAnimFadeInAnimMs > 0) {
        g_SplashFadeState := "in_anim"
        g_SplashRunning := true
    } else {
        g_SplashFadeState := "playing"
        g_SplashAlpha := 255
        g_SplashRunning := true
    }

    SetTimer(_Splash_AnimFadeStep, 16)
    SetTimer(_Splash_AnimNextFrame, g_SplashFrameMs)
}

_Splash_HideAnimation() {
    global g_SplashHwnd, g_SplashHdc, g_SplashToken, g_SplashHdcScreen
    global g_SplashHModule, g_SplashDIB, g_SplashDIBOld, g_SplashShuttingDown
    global g_SplashFrames, g_SplashFrameBuffers, g_SplashStreaming
    global g_SplashDecoder, g_SplashDemuxDllName, g_SplashFileData, g_SplashFrameBuffer

    g_SplashShuttingDown := true

    ; Stop timers
    SetTimer(_Splash_AnimFadeStep, 0)
    SetTimer(_Splash_AnimNextFrame, 0)

    ; Destroy window
    _Splash_CleanupResource(&g_SplashHwnd, "DestroyWindow")

    ; Dispose frame resources based on mode
    if (g_SplashStreaming) {
        ; Streaming mode: dispose buffered bitmaps
        for _, data in g_SplashFrameBuffer {
            if (data.bitmap)
                DllCall("gdiplus\GdipDisposeImage", "ptr", data.bitmap)
        }
        g_SplashFrameBuffer := Map()

        ; Delete decoder
        if (g_SplashDecoder) {
            DllCall(g_SplashDemuxDllName "\WebPAnimDecoderDelete", "ptr", g_SplashDecoder)
            g_SplashDecoder := 0
        }

        ; Release file data
        g_SplashFileData := 0
    } else {
        ; Preload mode: dispose all frame bitmaps
        for pBitmap in g_SplashFrames {
            if (pBitmap)
                DllCall("gdiplus\GdipDisposeImage", "ptr", pBitmap)
        }
        g_SplashFrames := []
        g_SplashFrameBuffers := []  ; Release pixel buffer memory
    }

    ; Cleanup DC resources
    if (g_SplashHdc && g_SplashDIBOld)
        try DllCall("gdi32\SelectObject", "ptr", g_SplashHdc, "ptr", g_SplashDIBOld)
    g_SplashDIBOld := 0
    _Splash_CleanupResource(&g_SplashDIB, "DeleteObject")
    _Splash_CleanupResource(&g_SplashHdc, "DeleteDC")
    _Splash_CleanupResource(&g_SplashHdcScreen, "ReleaseDC", "", 0)

    ; Shutdown GDI+ and unload
    _Splash_CleanupResource(&g_SplashToken, "GdiplusShutdown", "gdiplus")
    _Splash_CleanupResource(&g_SplashHModule, "FreeLibrary")

    ; Unload WebP DLLs
    _Splash_UnloadWebPDlls()
}

; ============================================================
; WebP DLL Loading/Unloading
; ============================================================

_Splash_LoadWebPDlls() {
    global g_SplashHWebP, g_SplashHSharpYuv, g_SplashHDemux
    global g_SplashDemuxDllName, g_SplashExtractedDlls
    global RES_ID_SHARPYUV_DLL, RES_ID_WEBP_DLL, RES_ID_DEMUX_DLL

    dllDir := ""
    demuxDll := ""
    webpDll := ""
    sharpyuvDll := ""

    if (A_IsCompiled) {
        ; Extract DLLs from resources to temp folder
        dllDir := A_Temp "\AltTabby_Splash"
        if (!DirExist(dllDir))
            DirCreate(dllDir)

        sharpyuvDll := _Splash_ExtractResourceToTemp(RES_ID_SHARPYUV_DLL, "libsharpyuv-0.dll", dllDir)
        webpDll := _Splash_ExtractResourceToTemp(RES_ID_WEBP_DLL, "libwebp-7.dll", dllDir)
        demuxDll := _Splash_ExtractResourceToTemp(RES_ID_DEMUX_DLL, "libwebpdemux-2.dll", dllDir)

        if (sharpyuvDll)
            g_SplashExtractedDlls.Push(sharpyuvDll)
        if (webpDll)
            g_SplashExtractedDlls.Push(webpDll)
        if (demuxDll)
            g_SplashExtractedDlls.Push(demuxDll)
    } else {
        ; Dev mode: load from resources folder
        dllDir := A_ScriptDir "\..\resources"

        for name in ["libsharpyuv-0.dll", "libsharpyuv.dll"] {
            if (FileExist(dllDir "\" name)) {
                sharpyuvDll := dllDir "\" name
                break
            }
        }
        for name in ["libwebp-7.dll", "libwebp-2.dll", "libwebp.dll"] {
            if (FileExist(dllDir "\" name)) {
                webpDll := dllDir "\" name
                break
            }
        }
        for name in ["libwebpdemux-2.dll", "libwebpdemux.dll"] {
            if (FileExist(dllDir "\" name)) {
                demuxDll := dllDir "\" name
                break
            }
        }
    }

    if (!demuxDll || !webpDll)
        return false

    ; Load dependencies in order: sharpyuv -> webp -> demux
    if (sharpyuvDll) {
        g_SplashHSharpYuv := DllCall("LoadLibrary", "str", sharpyuvDll, "ptr")
        if (!g_SplashHSharpYuv)
            return false
    }

    g_SplashHWebP := DllCall("LoadLibrary", "str", webpDll, "ptr")
    if (!g_SplashHWebP) {
        _Splash_UnloadWebPDlls()
        return false
    }

    g_SplashHDemux := DllCall("LoadLibrary", "str", demuxDll, "ptr")
    if (!g_SplashHDemux) {
        _Splash_UnloadWebPDlls()
        return false
    }

    ; Extract DLL name for DllCall (e.g., "libwebpdemux-2")
    SplitPath(demuxDll, &demuxFileName)
    g_SplashDemuxDllName := RegExReplace(demuxFileName, "\.dll$", "")

    return true
}

_Splash_UnloadWebPDlls() {
    global g_SplashHWebP, g_SplashHSharpYuv, g_SplashHDemux
    global g_SplashExtractedDlls, g_SplashExtractedWebP

    ; Unload DLLs (reverse order)
    if (g_SplashHDemux) {
        DllCall("FreeLibrary", "ptr", g_SplashHDemux)
        g_SplashHDemux := 0
    }
    if (g_SplashHWebP) {
        DllCall("FreeLibrary", "ptr", g_SplashHWebP)
        g_SplashHWebP := 0
    }
    if (g_SplashHSharpYuv) {
        DllCall("FreeLibrary", "ptr", g_SplashHSharpYuv)
        g_SplashHSharpYuv := 0
    }

    ; Delete extracted temp DLLs
    for dllPath in g_SplashExtractedDlls {
        try FileDelete(dllPath)
    }
    g_SplashExtractedDlls := []

    ; Delete extracted animation.webp
    if (g_SplashExtractedWebP != "") {
        try FileDelete(g_SplashExtractedWebP)
        g_SplashExtractedWebP := ""
    }

    ; Try to remove temp folder (will fail if not empty, that's OK)
    try DirDelete(A_Temp "\AltTabby_Splash")
}

; ============================================================
; WebP Frame Loading
; ============================================================

_Splash_LoadWebPFrames(webpPath) {
    global g_SplashFrames, g_SplashFrameBuffers, g_SplashImgW, g_SplashImgH
    global g_SplashDemuxDllName, g_SplashFrameMs

    ; Read file into memory
    fileData := FileRead(webpPath, "RAW")
    fileSize := fileData.Size

    ; WebPData structure: { bytes: ptr, size: size_t }
    webpData := Buffer(A_PtrSize * 2, 0)
    NumPut("ptr", fileData.Ptr, webpData, 0)
    NumPut("uptr", fileSize, webpData, A_PtrSize)

    ; WebPAnimDecoderOptions structure
    decOptions := Buffer(36, 0)

    ; Initialize options
    WEBP_DEMUX_ABI_VERSION := 0x0107
    result := DllCall(g_SplashDemuxDllName "\WebPAnimDecoderOptionsInitInternal"
        , "ptr", decOptions.Ptr
        , "int", WEBP_DEMUX_ABI_VERSION
        , "int")

    if (!result)
        return false

    ; Set color mode to MODE_bgrA (8) - pre-multiplied BGRA
    NumPut("int", 8, decOptions, 0)

    ; Create decoder
    pDecoder := DllCall(g_SplashDemuxDllName "\WebPAnimDecoderNewInternal"
        , "ptr", webpData.Ptr
        , "ptr", decOptions.Ptr
        , "int", WEBP_DEMUX_ABI_VERSION
        , "ptr")

    if (!pDecoder)
        return false

    ; Get animation info
    animInfo := Buffer(36, 0)
    result := DllCall(g_SplashDemuxDllName "\WebPAnimDecoderGetInfo"
        , "ptr", pDecoder
        , "ptr", animInfo.Ptr
        , "int")

    if (!result) {
        DllCall(g_SplashDemuxDllName "\WebPAnimDecoderDelete", "ptr", pDecoder)
        return false
    }

    g_SplashImgW := NumGet(animInfo, 0, "uint")
    g_SplashImgH := NumGet(animInfo, 4, "uint")

    ; Calculate frame timing from first two frames
    prevTimestamp := 0

    ; Decode all frames
    Loop {
        hasMore := DllCall(g_SplashDemuxDllName "\WebPAnimDecoderHasMoreFrames"
            , "ptr", pDecoder
            , "int")

        if (!hasMore)
            break

        pBuf := 0
        timestamp := 0
        result := DllCall(g_SplashDemuxDllName "\WebPAnimDecoderGetNext"
            , "ptr", pDecoder
            , "ptr*", &pBuf
            , "int*", &timestamp
            , "int")

        if (!result || !pBuf)
            break

        ; Calculate frame duration from timestamp delta
        if (g_SplashFrames.Length = 1)
            g_SplashFrameMs := timestamp - prevTimestamp
        prevTimestamp := timestamp

        ; Copy pixel data to persistent buffer (decoder reuses same buffer)
        stride := g_SplashImgW * 4
        bufSize := stride * g_SplashImgH
        pixelBuf := Buffer(bufSize, 0)
        DllCall("msvcrt\memcpy", "ptr", pixelBuf.Ptr, "ptr", pBuf, "uptr", bufSize, "ptr")

        ; Create bitmap from our persistent copy
        pBitmap := 0
        hr := DllCall("gdiplus\GdipCreateBitmapFromScan0"
            , "int", g_SplashImgW
            , "int", g_SplashImgH
            , "int", stride
            , "int", 0x26200A  ; PixelFormat32bppPARGB
            , "ptr", pixelBuf.Ptr
            , "ptr*", &pBitmap)

        if (hr = 0 && pBitmap) {
            g_SplashFrameBuffers.Push(pixelBuf)
            g_SplashFrames.Push(pBitmap)
        }
    }

    ; Clean up decoder
    DllCall(g_SplashDemuxDllName "\WebPAnimDecoderDelete", "ptr", pDecoder)

    ; Ensure minimum frame time
    if (g_SplashFrameMs < 16)
        g_SplashFrameMs := 42  ; Default ~24fps

    return g_SplashFrames.Length > 0
}

; ============================================================
; Streaming Decoder Functions
; ============================================================

_Splash_InitStreamingDecoder(webpPath) {
    global g_SplashDecoder, g_SplashFileData, g_SplashImgW, g_SplashImgH
    global g_SplashTotalFrames, g_SplashDemuxDllName, g_SplashFrameMs
    global g_SplashNextDecodeFrame, g_SplashDecoderExhausted, g_SplashFrameBuffer

    ; Read file into memory - must keep alive while decoder exists
    g_SplashFileData := FileRead(webpPath, "RAW")
    fileSize := g_SplashFileData.Size

    ; WebPData structure
    webpData := Buffer(A_PtrSize * 2, 0)
    NumPut("ptr", g_SplashFileData.Ptr, webpData, 0)
    NumPut("uptr", fileSize, webpData, A_PtrSize)

    ; Initialize decoder options
    decOptions := Buffer(36, 0)
    WEBP_DEMUX_ABI_VERSION := 0x0107
    result := DllCall(g_SplashDemuxDllName "\WebPAnimDecoderOptionsInitInternal"
        , "ptr", decOptions.Ptr
        , "int", WEBP_DEMUX_ABI_VERSION
        , "int")

    if (!result)
        return false

    ; MODE_bgrA for pre-multiplied BGRA
    NumPut("int", 8, decOptions, 0)

    ; Create decoder - keep it alive for streaming
    g_SplashDecoder := DllCall(g_SplashDemuxDllName "\WebPAnimDecoderNewInternal"
        , "ptr", webpData.Ptr
        , "ptr", decOptions.Ptr
        , "int", WEBP_DEMUX_ABI_VERSION
        , "ptr")

    if (!g_SplashDecoder)
        return false

    ; Get animation info
    animInfo := Buffer(36, 0)
    result := DllCall(g_SplashDemuxDllName "\WebPAnimDecoderGetInfo"
        , "ptr", g_SplashDecoder
        , "ptr", animInfo.Ptr
        , "int")

    if (!result) {
        DllCall(g_SplashDemuxDllName "\WebPAnimDecoderDelete", "ptr", g_SplashDecoder)
        g_SplashDecoder := 0
        return false
    }

    g_SplashImgW := NumGet(animInfo, 0, "uint")
    g_SplashImgH := NumGet(animInfo, 4, "uint")
    g_SplashTotalFrames := NumGet(animInfo, 16, "uint")

    g_SplashNextDecodeFrame := 1
    g_SplashDecoderExhausted := false
    g_SplashFrameBuffer := Map()

    ; Get frame timing from first frame
    g_SplashFrameMs := 42  ; Default
    return true
}

_Splash_DecodeNextFrame() {
    global g_SplashDecoder, g_SplashDemuxDllName, g_SplashFrameBuffer
    global g_SplashNextDecodeFrame, g_SplashImgW, g_SplashImgH
    global g_SplashDecoderExhausted, g_SplashTotalFrames, g_SplashFrameMs

    if (g_SplashDecoderExhausted || !g_SplashDecoder)
        return false

    ; Check if more frames available
    hasMore := DllCall(g_SplashDemuxDllName "\WebPAnimDecoderHasMoreFrames"
        , "ptr", g_SplashDecoder
        , "int")

    if (!hasMore) {
        g_SplashDecoderExhausted := true
        return false
    }

    ; Decode next frame
    pBuf := 0
    timestamp := 0
    result := DllCall(g_SplashDemuxDllName "\WebPAnimDecoderGetNext"
        , "ptr", g_SplashDecoder
        , "ptr*", &pBuf
        , "int*", &timestamp
        , "int")

    if (!result || !pBuf) {
        g_SplashDecoderExhausted := true
        return false
    }

    ; Get frame timing from second frame (first frame timestamp is 0)
    static prevTimestamp := 0
    if (g_SplashNextDecodeFrame = 2 && timestamp > prevTimestamp)
        g_SplashFrameMs := timestamp - prevTimestamp
    prevTimestamp := timestamp

    ; Copy pixel data (decoder reuses buffer)
    stride := g_SplashImgW * 4
    bufSize := stride * g_SplashImgH
    pixelBuf := Buffer(bufSize, 0)
    DllCall("msvcrt\memcpy", "ptr", pixelBuf.Ptr, "ptr", pBuf, "uptr", bufSize, "ptr")

    ; Create GDI+ bitmap from our copy
    pBitmap := 0
    hr := DllCall("gdiplus\GdipCreateBitmapFromScan0"
        , "int", g_SplashImgW
        , "int", g_SplashImgH
        , "int", stride
        , "int", 0x26200A  ; PixelFormat32bppPARGB
        , "ptr", pixelBuf.Ptr
        , "ptr*", &pBitmap)

    if (hr != 0 || !pBitmap)
        return false

    ; Store in buffer
    g_SplashFrameBuffer[g_SplashNextDecodeFrame] := {bitmap: pBitmap, pixelBuf: pixelBuf}
    g_SplashNextDecodeFrame++
    return true
}

_Splash_EvictOldFrames(currentFrame) {
    global g_SplashFrameBuffer

    ; Keep frames from (currentFrame - 2) onward; evict older frames
    minKeep := Max(1, currentFrame - 2)

    toDelete := []
    for frameNum, data in g_SplashFrameBuffer {
        if (frameNum < minKeep)
            toDelete.Push(frameNum)
    }

    for frameNum in toDelete {
        data := g_SplashFrameBuffer[frameNum]
        if (data.bitmap)
            DllCall("gdiplus\GdipDisposeImage", "ptr", data.bitmap)
        g_SplashFrameBuffer.Delete(frameNum)
    }
}

_Splash_BufferAhead() {
    global g_SplashFrameBuffer, g_SplashTotalFrames, g_SplashDecoderExhausted, cfg

    bufferFrames := cfg.LauncherSplashAnimBufferFrames

    ; Decode ahead to maintain buffer
    while (!g_SplashDecoderExhausted && g_SplashFrameBuffer.Count < bufferFrames) {
        if (!_Splash_DecodeNextFrame())
            break
    }
}

_Splash_ResetStreamingDecoder() {
    global g_SplashDecoder, g_SplashDemuxDllName, g_SplashFileData, g_SplashFrameBuffer
    global g_SplashNextDecodeFrame, g_SplashDecoderExhausted, g_SplashImgW, g_SplashImgH
    global g_SplashTotalFrames, cfg

    ; Clean up old buffer
    for _, data in g_SplashFrameBuffer {
        if (data.bitmap)
            DllCall("gdiplus\GdipDisposeImage", "ptr", data.bitmap)
    }
    g_SplashFrameBuffer := Map()

    ; Delete old decoder
    if (g_SplashDecoder) {
        DllCall(g_SplashDemuxDllName "\WebPAnimDecoderDelete", "ptr", g_SplashDecoder)
        g_SplashDecoder := 0
    }

    ; Create new decoder from existing file data
    webpData := Buffer(A_PtrSize * 2, 0)
    NumPut("ptr", g_SplashFileData.Ptr, webpData, 0)
    NumPut("uptr", g_SplashFileData.Size, webpData, A_PtrSize)

    decOptions := Buffer(36, 0)
    WEBP_DEMUX_ABI_VERSION := 0x0107
    DllCall(g_SplashDemuxDllName "\WebPAnimDecoderOptionsInitInternal"
        , "ptr", decOptions.Ptr
        , "int", WEBP_DEMUX_ABI_VERSION
        , "int")
    NumPut("int", 8, decOptions, 0)

    g_SplashDecoder := DllCall(g_SplashDemuxDllName "\WebPAnimDecoderNewInternal"
        , "ptr", webpData.Ptr
        , "ptr", decOptions.Ptr
        , "int", WEBP_DEMUX_ABI_VERSION
        , "ptr")

    g_SplashNextDecodeFrame := 1
    g_SplashDecoderExhausted := false

    ; Pre-buffer
    bufferFrames := cfg.LauncherSplashAnimBufferFrames
    Loop Min(bufferFrames, g_SplashTotalFrames) {
        if (!_Splash_DecodeNextFrame())
            break
    }
}

; ============================================================
; Animation Playback
; ============================================================

_Splash_AnimNextFrame() {
    global g_SplashCurrentFrame, g_SplashFrameCount, g_SplashRunning, g_SplashStreaming
    global g_SplashFadeState, g_SplashFadeStartTick, g_SplashFrameMs
    global g_SplashLoopCount, g_SplashShuttingDown, g_SplashTotalFrames, cfg

    if (!g_SplashRunning || g_SplashShuttingDown)
        return

    g_SplashCurrentFrame++

    ; Streaming mode: evict old frames and buffer ahead
    if (g_SplashStreaming) {
        _Splash_EvictOldFrames(g_SplashCurrentFrame)
        _Splash_BufferAhead()
    }

    ; Check if we need to start fade out (while still animating)
    if (g_SplashFadeState = "playing" && cfg.LauncherSplashAnimFadeOutAnimMs > 0) {
        framesForFadeOut := Round((cfg.LauncherSplashAnimFadeOutAnimMs / 1000) * (1000 / g_SplashFrameMs))
        if (g_SplashCurrentFrame >= g_SplashTotalFrames - framesForFadeOut) {
            g_SplashFadeState := "out_anim"
            g_SplashFadeStartTick := A_TickCount
        }
    }

    ; When reaching end of loop
    if (g_SplashCurrentFrame > g_SplashTotalFrames) {
        g_SplashLoopCount++

        ; Check if we've completed all loops
        maxLoops := cfg.LauncherSplashAnimLoops
        if (maxLoops > 0 && g_SplashLoopCount >= maxLoops) {
            ; Animation complete - trigger hide
            SetTimer(_Splash_AnimNextFrame, 0)
            SetTimer(_Splash_AnimFadeStep, 0)
            return
        }

        if (cfg.LauncherSplashAnimFadeOutFixedMs > 0 && g_SplashFadeState != "out_fixed") {
            ; Switch to fixed fade out on last frame
            g_SplashCurrentFrame := g_SplashTotalFrames
            g_SplashRunning := false
            SetTimer(_Splash_AnimNextFrame, 0)
            g_SplashFadeState := "out_fixed"
            g_SplashFadeStartTick := A_TickCount
            return
        } else if (g_SplashFadeState = "out_anim" || g_SplashFadeState = "playing") {
            ; Restart loop
            _Splash_AnimStartNewLoop()
            return
        }
    }

    _Splash_DrawAnimFrame(g_SplashCurrentFrame)
}

_Splash_AnimFadeStep() {
    global g_SplashAlpha, g_SplashFadeState, g_SplashFadeStartTick
    global g_SplashRunning, g_SplashFrameMs, g_SplashCurrentFrame
    global g_SplashTotalFrames, g_SplashShuttingDown, cfg

    if (g_SplashShuttingDown)
        return

    elapsed := A_TickCount - g_SplashFadeStartTick
    fadeInFixed := cfg.LauncherSplashAnimFadeInFixedMs
    fadeInAnim := cfg.LauncherSplashAnimFadeInAnimMs
    fadeOutAnim := cfg.LauncherSplashAnimFadeOutAnimMs
    fadeOutFixed := cfg.LauncherSplashAnimFadeOutFixedMs

    if (g_SplashFadeState = "in_fixed") {
        progress := fadeInFixed > 0 ? elapsed / fadeInFixed : 1
        if (progress >= 1) {
            progress := 1
            if (fadeInAnim > 0) {
                g_SplashFadeState := "in_anim"
                g_SplashFadeStartTick := A_TickCount
                g_SplashRunning := true
                SetTimer(_Splash_AnimNextFrame, g_SplashFrameMs)
            } else {
                g_SplashFadeState := "playing"
                g_SplashAlpha := 255
                g_SplashRunning := true
                SetTimer(_Splash_AnimNextFrame, g_SplashFrameMs)
            }
        }
        totalFadeIn := fadeInFixed + fadeInAnim
        maxAlphaThisPhase := totalFadeIn > 0 ? Round(255 * fadeInFixed / totalFadeIn) : 255
        g_SplashAlpha := Round(progress * maxAlphaThisPhase)
        _Splash_DrawAnimFrame(g_SplashCurrentFrame)

    } else if (g_SplashFadeState = "in_anim") {
        progress := fadeInAnim > 0 ? elapsed / fadeInAnim : 1
        if (progress >= 1) {
            progress := 1
            g_SplashFadeState := "playing"
            g_SplashAlpha := 255
        }
        totalFadeIn := fadeInFixed + fadeInAnim
        startAlpha := totalFadeIn > 0 ? Round(255 * fadeInFixed / totalFadeIn) : 0
        g_SplashAlpha := startAlpha + Round(progress * (255 - startAlpha))
        _Splash_DrawAnimFrame(g_SplashCurrentFrame)

    } else if (g_SplashFadeState = "out_anim") {
        progress := fadeOutAnim > 0 ? elapsed / fadeOutAnim : 1
        if (progress >= 1)
            progress := 1
        totalFadeOut := fadeOutAnim + fadeOutFixed
        minAlphaThisPhase := totalFadeOut > 0 ? Round(255 * fadeOutFixed / totalFadeOut) : 0
        g_SplashAlpha := 255 - Round(progress * (255 - minAlphaThisPhase))
        _Splash_DrawAnimFrame(g_SplashCurrentFrame)

    } else if (g_SplashFadeState = "out_fixed") {
        progress := fadeOutFixed > 0 ? elapsed / fadeOutFixed : 1
        if (progress >= 1) {
            progress := 1
            _Splash_AnimStartNewLoop()
            return
        }
        totalFadeOut := fadeOutAnim + fadeOutFixed
        startAlpha := totalFadeOut > 0 ? Round(255 * fadeOutFixed / totalFadeOut) : 255
        g_SplashAlpha := Round((1 - progress) * startAlpha)
        _Splash_DrawAnimFrame(g_SplashCurrentFrame)

    } else if (g_SplashFadeState = "playing") {
        g_SplashAlpha := 255
    }
}

_Splash_AnimStartNewLoop() {
    global g_SplashCurrentFrame, g_SplashAlpha, g_SplashFadeState, g_SplashStreaming
    global g_SplashFadeStartTick, g_SplashRunning, g_SplashFrameMs
    global g_SplashLoopCount, g_SplashShuttingDown, cfg

    if (g_SplashShuttingDown)
        return

    ; Check if we've completed all loops
    maxLoops := cfg.LauncherSplashAnimLoops
    if (maxLoops > 0 && g_SplashLoopCount >= maxLoops) {
        SetTimer(_Splash_AnimNextFrame, 0)
        SetTimer(_Splash_AnimFadeStep, 0)
        return
    }

    ; Reset decoder for streaming mode
    if (g_SplashStreaming)
        _Splash_ResetStreamingDecoder()

    g_SplashCurrentFrame := 1
    g_SplashAlpha := 0
    g_SplashFadeStartTick := A_TickCount
    _Splash_DrawAnimFrame(1)

    fadeInFixed := cfg.LauncherSplashAnimFadeInFixedMs
    fadeInAnim := cfg.LauncherSplashAnimFadeInAnimMs

    if (fadeInFixed > 0) {
        g_SplashFadeState := "in_fixed"
        g_SplashRunning := false
        SetTimer(_Splash_AnimNextFrame, 0)
    } else if (fadeInAnim > 0) {
        g_SplashFadeState := "in_anim"
        g_SplashRunning := true
        SetTimer(_Splash_AnimNextFrame, g_SplashFrameMs)
    } else {
        g_SplashFadeState := "playing"
        g_SplashAlpha := 255
        g_SplashRunning := true
        SetTimer(_Splash_AnimNextFrame, g_SplashFrameMs)
    }
}

_Splash_DrawAnimFrame(frameNum) {
    global g_SplashFrames, g_SplashHdc, g_SplashHwnd, g_SplashHdcScreen, g_SplashStreaming
    global g_SplashImgW, g_SplashImgH, g_SplashPosX, g_SplashPosY, g_SplashAlpha
    global g_SplashFrameBuffer, g_SplashTotalFrames

    if (frameNum < 1 || frameNum > g_SplashTotalFrames)
        return

    ; Get bitmap based on mode
    pBitmap := 0
    if (g_SplashStreaming) {
        if (!g_SplashFrameBuffer.Has(frameNum))
            return
        pBitmap := g_SplashFrameBuffer[frameNum].bitmap
    } else {
        if (frameNum > g_SplashFrames.Length)
            return
        pBitmap := g_SplashFrames[frameNum]
    }

    if (!pBitmap)
        return

    ; Clear to transparent
    DllCall("gdi32\PatBlt", "ptr", g_SplashHdc, "int", 0, "int", 0
        , "int", g_SplashImgW, "int", g_SplashImgH, "uint", 0x00000042)

    ; Draw frame
    pGraphics := 0
    DllCall("gdiplus\GdipCreateFromHDC", "ptr", g_SplashHdc, "ptr*", &pGraphics)
    DllCall("gdiplus\GdipSetCompositingMode", "ptr", pGraphics, "int", 0)
    DllCall("gdiplus\GdipDrawImageRectI", "ptr", pGraphics, "ptr", pBitmap
        , "int", 0, "int", 0, "int", g_SplashImgW, "int", g_SplashImgH)
    DllCall("gdiplus\GdipDeleteGraphics", "ptr", pGraphics)

    ; Update layered window with current alpha
    _Splash_UpdateLayeredWindowAlpha(g_SplashAlpha)
}

; ============================================================
; Shared Helper Functions
; ============================================================

_Splash_CreateWindow() {
    global g_SplashHwnd, g_SplashHdc, g_SplashHdcScreen
    global g_SplashImgW, g_SplashImgH, g_SplashPosX, g_SplashPosY
    global g_SplashDIB, g_SplashDIBOld
    global WS_EX_LAYERED  ; From gui_constants.ahk

    WS_POPUP := 0x80000000
    WS_EX_TOPMOST := 0x8
    WS_EX_TOOLWINDOW := 0x80

    ; Center on screen
    screenW := A_ScreenWidth, screenH := A_ScreenHeight
    g_SplashPosX := (screenW - g_SplashImgW) // 2
    g_SplashPosY := (screenH - g_SplashImgH) // 2

    g_SplashHwnd := DllCall("CreateWindowEx"
        , "uint", WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW
        , "str", "Static", "str", ""
        , "uint", WS_POPUP
        , "int", g_SplashPosX, "int", g_SplashPosY, "int", g_SplashImgW, "int", g_SplashImgH
        , "ptr", 0, "ptr", 0, "ptr", 0, "ptr", 0, "ptr")

    if (!g_SplashHwnd)
        return

    ; Create compatible DC and DIB
    g_SplashHdcScreen := DllCall("GetDC", "ptr", 0, "ptr")
    g_SplashHdc := DllCall("CreateCompatibleDC", "ptr", g_SplashHdcScreen, "ptr")

    bi := Buffer(40, 0)
    NumPut("UInt", 40, bi, 0)
    NumPut("Int", g_SplashImgW, bi, 4)
    NumPut("Int", -g_SplashImgH, bi, 8)  ; Negative = top-down
    NumPut("UShort", 1, bi, 12)
    NumPut("UShort", 32, bi, 14)

    pvBits := 0
    g_SplashDIB := DllCall("CreateDIBSection", "ptr", g_SplashHdc, "ptr", bi.Ptr
        , "uint", 0, "ptr*", &pvBits, "ptr", 0, "uint", 0, "ptr")
    g_SplashDIBOld := DllCall("SelectObject", "ptr", g_SplashHdc, "ptr", g_SplashDIB, "ptr")
}

_Splash_DrawBitmapToHdc(pBitmap) {
    global g_SplashHdc, g_SplashImgW, g_SplashImgH

    ; Clear to transparent
    DllCall("gdi32\PatBlt", "ptr", g_SplashHdc, "int", 0, "int", 0
        , "int", g_SplashImgW, "int", g_SplashImgH, "uint", 0x00000042)

    ; Draw bitmap onto DIB
    pGraphics := 0
    DllCall("gdiplus\GdipCreateFromHDC", "ptr", g_SplashHdc, "ptr*", &pGraphics)
    DllCall("gdiplus\GdipSetCompositingMode", "ptr", pGraphics, "int", 0)
    DllCall("gdiplus\GdipDrawImageRectI", "ptr", pGraphics, "ptr", pBitmap
        , "int", 0, "int", 0, "int", g_SplashImgW, "int", g_SplashImgH)
    DllCall("gdiplus\GdipDeleteGraphics", "ptr", pGraphics)
}

_Splash_UpdateLayeredWindowAlpha(alpha) {
    global g_SplashHwnd, g_SplashHdc, g_SplashHdcScreen, g_SplashShuttingDown
    global g_SplashImgW, g_SplashImgH, g_SplashPosX, g_SplashPosY

    if (!g_SplashHwnd || g_SplashShuttingDown)
        return

    ptSrc := Buffer(8, 0)
    ptDst := Buffer(8, 0)
    NumPut("Int", g_SplashPosX, ptDst, 0)
    NumPut("Int", g_SplashPosY, ptDst, 4)
    sizeWnd := Buffer(8, 0)
    NumPut("Int", g_SplashImgW, sizeWnd, 0)
    NumPut("Int", g_SplashImgH, sizeWnd, 4)

    blendFunc := Buffer(4, 0)
    NumPut("UChar", 0, blendFunc, 0)      ; AC_SRC_OVER
    NumPut("UChar", 0, blendFunc, 1)
    NumPut("UChar", alpha, blendFunc, 2)  ; SourceConstantAlpha
    NumPut("UChar", 1, blendFunc, 3)      ; AC_SRC_ALPHA

    DllCall("UpdateLayeredWindow", "ptr", g_SplashHwnd
        , "ptr", g_SplashHdcScreen, "ptr", ptDst.Ptr, "ptr", sizeWnd.Ptr
        , "ptr", g_SplashHdc, "ptr", ptSrc.Ptr, "uint", 0
        , "ptr", blendFunc.Ptr, "uint", 2)
}

_Splash_Fade(fromAlpha, toAlpha, durationMs) {
    global g_SplashHwnd, g_SplashShuttingDown
    if (!g_SplashHwnd)
        return

    if (durationMs <= 0) {
        _Splash_UpdateLayeredWindowAlpha(toAlpha)
        return
    }

    steps := durationMs // 16
    if (steps < 1)
        steps := 1

    startTick := A_TickCount
    Loop steps {
        if (!g_SplashHwnd || g_SplashShuttingDown)
            return
        elapsed := A_TickCount - startTick
        progress := Min(elapsed / durationMs, 1.0)
        alpha := Integer(fromAlpha + (toAlpha - fromAlpha) * progress)
        _Splash_UpdateLayeredWindowAlpha(alpha)
        if (progress >= 1.0)
            break
        Sleep(16)
    }
    if (g_SplashHwnd && !g_SplashShuttingDown)
        _Splash_UpdateLayeredWindowAlpha(toAlpha)
}

; ============================================================
; Resource Loading Helpers
; ============================================================

; Load a GDI+ bitmap from an embedded PE resource
Splash_LoadBitmapFromResource(resourceId) {
    global RT_RCDATA
    hRes := DllCall("FindResource", "ptr", 0, "int", resourceId, "int", RT_RCDATA, "ptr")
    if (!hRes)
        return 0

    resSize := DllCall("SizeofResource", "ptr", 0, "ptr", hRes, "uint")
    hMem := DllCall("LoadResource", "ptr", 0, "ptr", hRes, "ptr")
    if (!hMem || !resSize)
        return 0

    pData := DllCall("LockResource", "ptr", hMem, "ptr")
    if (!pData)
        return 0

    hGlobal := DllCall("GlobalAlloc", "uint", 0x0002, "uptr", resSize, "ptr")
    if (!hGlobal)
        return 0

    pGlobal := DllCall("GlobalLock", "ptr", hGlobal, "ptr")
    if (!pGlobal) {
        DllCall("GlobalFree", "ptr", hGlobal)
        return 0
    }

    DllCall("RtlMoveMemory", "ptr", pGlobal, "ptr", pData, "uptr", resSize)
    DllCall("GlobalUnlock", "ptr", hGlobal)

    pStream := 0
    hr := DllCall("ole32\CreateStreamOnHGlobal", "ptr", hGlobal, "int", 1, "ptr*", &pStream, "int")
    if (hr != 0 || !pStream) {
        DllCall("GlobalFree", "ptr", hGlobal)
        return 0
    }

    pBitmap := 0
    DllCall("gdiplus\GdipCreateBitmapFromStream", "ptr", pStream, "ptr*", &pBitmap)
    ObjRelease(pStream)

    return pBitmap
}

; Wrapper for shared ResourceExtractToTemp (maintains existing call signature)
_Splash_ExtractResourceToTemp(resourceId, fileName, destDir := "") {
    return ResourceExtractToTemp(resourceId, fileName, destDir)
}
