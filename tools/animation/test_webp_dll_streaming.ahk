#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
; WebP Animation Test - STREAMING DECODE VERSION
; ============================================================
; Instead of decoding all frames upfront (~500MB for 137 frames),
; this version maintains a rolling buffer of N frames and decodes
; ahead as the animation plays.
;
; Memory usage: FramesToBuffer * width * height * 4 bytes
; Example: 24 frames * 1280 * 720 * 4 = ~88MB (vs ~504MB for all)
;
; Press Escape to exit, Space to restart animation
; ============================================================

; =============================================================================
; TUNABLE: Number of frames to keep buffered ahead
; =============================================================================
global FramesToBuffer := 99999  ; ~1 second at 24fps, ~88MB for 1280x720
; =============================================================================

global g_Hwnd := 0
global g_FrameCount := 0
global g_TotalFrames := 0
global g_CurrentFrame := 0
global g_Hdc := 0
global g_HdcScreen := 0
global g_DIB := 0
global g_DIBOld := 0
global g_GdipToken := 0
global g_ImgW := 0
global g_ImgH := 0
global g_PosX := 0
global g_PosY := 0
global g_FPS := 24
global g_FrameMs := 42
global g_Running := false
global g_hWebPDemux := 0
global g_DemuxDllName := ""
global g_LogFile := A_ScriptDir "\webp_streaming_debug.log"
global g_Alpha := 0
global g_FadeState := ""
global g_FadeStepMs := 16
global g_FadeStartTick := 0

; Streaming-specific globals
global g_Decoder := 0           ; Keep decoder alive for streaming
global g_FileData := 0          ; Keep file data alive while decoder exists
global g_FrameBuffer := Map()   ; Circular buffer: frameNum -> {bitmap, pixelBuf}
global g_NextDecodeFrame := 1   ; Next frame to decode
global g_DecoderExhausted := false  ; True when decoder has no more frames

; Fade Configuration
global g_FadeInFixedMS := 0
global g_FadeInAnimationMS := 500
global g_FadeOutAnimationMS := 500
global g_FadeOutFixedMS := 0

DebugLog(msg) {
    global g_LogFile
    FileAppend(A_Now " " msg "`n", g_LogFile)
}

Main()

Main() {
    global

    ; Clear old log
    if FileExist(g_LogFile)
        FileDelete(g_LogFile)
    DebugLog("=== WebP STREAMING Test Started ===")
    DebugLog("FramesToBuffer = " FramesToBuffer)

    ; Check for DLLs
    dllDir := A_ScriptDir
    demuxDll := ""
    webpDll := ""
    sharpyuvDll := ""

    for name in ["libwebpdemux-2.dll", "libwebpdemux.dll"] {
        if (FileExist(dllDir "\" name)) {
            demuxDll := dllDir "\" name
            break
        }
    }

    for name in ["libwebp-7.dll", "libwebp-2.dll", "libwebp.dll"] {
        if (FileExist(dllDir "\" name)) {
            webpDll := dllDir "\" name
            break
        }
    }

    for name in ["libsharpyuv-0.dll", "libsharpyuv.dll"] {
        if (FileExist(dllDir "\" name)) {
            sharpyuvDll := dllDir "\" name
            break
        }
    }

    if (!demuxDll || !webpDll) {
        MsgBox("Required DLLs not found in: " dllDir
            . "`n`nExpected: libwebpdemux-2.dll + libwebp-7.dll")
        ExitApp()
    }

    ; Load dependencies in order
    if (sharpyuvDll) {
        hSharpYuv := DllCall("LoadLibrary", "str", sharpyuvDll, "ptr")
        if (!hSharpYuv) {
            MsgBox("Failed to load: " sharpyuvDll "`nError: " A_LastError)
            ExitApp()
        }
    }

    hWebP := DllCall("LoadLibrary", "str", webpDll, "ptr")
    if (!hWebP) {
        MsgBox("Failed to load: " webpDll "`nError: " A_LastError)
        ExitApp()
    }

    g_hWebPDemux := DllCall("LoadLibrary", "str", demuxDll, "ptr")
    if (!g_hWebPDemux) {
        MsgBox("Failed to load: " demuxDll "`n`nError: " A_LastError)
        ExitApp()
    }

    SplitPath(demuxDll, &demuxFileName)
    g_DemuxDllName := RegExReplace(demuxFileName, "\.dll$", "")

    ; Check for WebP file
    webpPath := A_ScriptDir "\animation.webp"
    if (!FileExist(webpPath)) {
        MsgBox("WebP not found: " webpPath "`n`nRun make_webp.py first!")
        ExitApp()
    }

    ; Initialize GDI+
    hGdiplus := DllCall("LoadLibrary", "str", "gdiplus", "ptr")
    if (!hGdiplus) {
        MsgBox("Failed to load GDI+")
        ExitApp()
    }

    si := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
    NumPut("UInt", 1, si, 0)
    DllCall("gdiplus\GdiplusStartup", "ptr*", &g_GdipToken, "ptr", si.Ptr, "ptr", 0)
    if (!g_GdipToken) {
        MsgBox("Failed to start GDI+")
        ExitApp()
    }

    ; Initialize streaming decoder (but don't decode all frames)
    if (!InitStreamingDecoder(webpPath)) {
        MsgBox("Failed to initialize streaming decoder")
        Cleanup()
        ExitApp()
    }

    if (g_TotalFrames = 0) {
        MsgBox("No frames in WebP")
        Cleanup()
        ExitApp()
    }

    ; Pre-buffer initial frames
    DebugLog("Pre-buffering " FramesToBuffer " frames...")
    Loop Min(FramesToBuffer, g_TotalFrames) {
        if (!DecodeNextFrame())
            break
    }
    DebugLog("Pre-buffer complete, buffer has " g_FrameBuffer.Count " frames")

    ; Read fps from meta.txt if available
    metaFile := A_ScriptDir "\frames\meta.txt"
    if (FileExist(metaFile)) {
        content := FileRead(metaFile)
        if (RegExMatch(content, "fps=([0-9.]+)", &m))
            g_FPS := Float(m[1])
    }
    g_FrameMs := Round(1000 / g_FPS)

    ; Create layered window
    WS_POPUP := 0x80000000
    WS_EX_LAYERED := 0x80000
    WS_EX_TOPMOST := 0x8
    WS_EX_TOOLWINDOW := 0x80

    g_PosX := (A_ScreenWidth - g_ImgW) // 2
    g_PosY := (A_ScreenHeight - g_ImgH) // 2

    g_Hwnd := DllCall("CreateWindowEx"
        , "uint", WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW
        , "str", "Static", "str", ""
        , "uint", WS_POPUP
        , "int", g_PosX, "int", g_PosY, "int", g_ImgW, "int", g_ImgH
        , "ptr", 0, "ptr", 0, "ptr", 0, "ptr", 0, "ptr")

    if (!g_Hwnd) {
        MsgBox("Failed to create window")
        Cleanup()
        ExitApp()
    }

    ; Create compatible DC and DIB
    g_HdcScreen := DllCall("GetDC", "ptr", 0, "ptr")
    g_Hdc := DllCall("CreateCompatibleDC", "ptr", g_HdcScreen, "ptr")

    bi := Buffer(40, 0)
    NumPut("UInt", 40, bi, 0)
    NumPut("Int", g_ImgW, bi, 4)
    NumPut("Int", -g_ImgH, bi, 8)
    NumPut("UShort", 1, bi, 12)
    NumPut("UShort", 32, bi, 14)

    pvBits := 0
    g_DIB := DllCall("CreateDIBSection", "ptr", g_Hdc, "ptr", bi.Ptr, "uint", 0, "ptr*", &pvBits, "ptr", 0, "uint", 0, "ptr")
    g_DIBOld := DllCall("SelectObject", "ptr", g_Hdc, "ptr", g_DIB, "ptr")

    ; Show window
    DllCall("ShowWindow", "ptr", g_Hwnd, "int", 8)

    ; Show first frame with alpha 0
    g_CurrentFrame := 1
    g_Alpha := 0
    DrawFrame(1)

    ; Start fade sequence
    g_FadeStartTick := A_TickCount
    if (g_FadeInFixedMS > 0) {
        g_FadeState := "in_fixed"
        g_Running := false
    } else if (g_FadeInAnimationMS > 0) {
        g_FadeState := "in_anim"
        g_Running := true
        SetTimer(NextFrame, g_FrameMs)
    } else {
        g_FadeState := "playing"
        g_Alpha := 255
        g_Running := true
        SetTimer(NextFrame, g_FrameMs)
    }
    SetTimer(FadeStep, g_FadeStepMs)
    SetTimer(NextFrame, g_FrameMs)

    ; Calculate memory usage
    memUsageMB := Round((FramesToBuffer * g_ImgW * g_ImgH * 4) / (1024 * 1024), 1)

    ; Status
    ToolTip("WebP STREAMING Animation`n"
        . "Total frames: " g_TotalFrames " @ " g_FPS " fps`n"
        . "Buffer size: " FramesToBuffer " frames (~" memUsageMB " MB)`n"
        . "Size: " g_ImgW "x" g_ImgH "`n"
        . "`nSpace = Restart, Escape = Exit")

    Hotkey("Escape", (*) => ExitApp())
    Hotkey("Space", RestartAnimation)
}

InitStreamingDecoder(webpPath) {
    global g_Decoder, g_FileData, g_ImgW, g_ImgH, g_TotalFrames, g_DemuxDllName
    global g_NextDecodeFrame, g_DecoderExhausted

    ; Read file into memory - must keep alive while decoder exists
    g_FileData := FileRead(webpPath, "RAW")
    fileSize := g_FileData.Size

    ; WebPData structure
    webpData := Buffer(A_PtrSize * 2, 0)
    NumPut("ptr", g_FileData.Ptr, webpData, 0)
    NumPut("uptr", fileSize, webpData, A_PtrSize)

    ; Initialize decoder options
    decOptions := Buffer(36, 0)
    WEBP_DEMUX_ABI_VERSION := 0x0107
    result := DllCall(g_DemuxDllName "\WebPAnimDecoderOptionsInitInternal"
        , "ptr", decOptions.Ptr
        , "int", WEBP_DEMUX_ABI_VERSION
        , "int")

    if (!result) {
        DebugLog("WebPAnimDecoderOptionsInitInternal failed")
        return false
    }

    ; MODE_bgrA for pre-multiplied BGRA
    NumPut("int", 8, decOptions, 0)

    ; Create decoder - keep it alive for streaming
    g_Decoder := DllCall(g_DemuxDllName "\WebPAnimDecoderNewInternal"
        , "ptr", webpData.Ptr
        , "ptr", decOptions.Ptr
        , "int", WEBP_DEMUX_ABI_VERSION
        , "ptr")

    if (!g_Decoder) {
        DebugLog("WebPAnimDecoderNewInternal failed")
        return false
    }

    ; Get animation info
    animInfo := Buffer(36, 0)
    result := DllCall(g_DemuxDllName "\WebPAnimDecoderGetInfo"
        , "ptr", g_Decoder
        , "ptr", animInfo.Ptr
        , "int")

    if (!result) {
        DebugLog("WebPAnimDecoderGetInfo failed")
        DllCall(g_DemuxDllName "\WebPAnimDecoderDelete", "ptr", g_Decoder)
        g_Decoder := 0
        return false
    }

    g_ImgW := NumGet(animInfo, 0, "uint")
    g_ImgH := NumGet(animInfo, 4, "uint")
    g_TotalFrames := NumGet(animInfo, 16, "uint")

    DebugLog("WebP info: " g_ImgW "x" g_ImgH ", " g_TotalFrames " frames")

    g_NextDecodeFrame := 1
    g_DecoderExhausted := false

    return true
}

DecodeNextFrame() {
    global g_Decoder, g_DemuxDllName, g_FrameBuffer, g_NextDecodeFrame
    global g_ImgW, g_ImgH, g_DecoderExhausted, g_TotalFrames

    if (g_DecoderExhausted || !g_Decoder)
        return false

    ; Check if more frames available
    hasMore := DllCall(g_DemuxDllName "\WebPAnimDecoderHasMoreFrames"
        , "ptr", g_Decoder
        , "int")

    if (!hasMore) {
        g_DecoderExhausted := true
        DebugLog("Decoder exhausted at frame " g_NextDecodeFrame)
        return false
    }

    ; Decode next frame
    pBuf := 0
    timestamp := 0
    result := DllCall(g_DemuxDllName "\WebPAnimDecoderGetNext"
        , "ptr", g_Decoder
        , "ptr*", &pBuf
        , "int*", &timestamp
        , "int")

    if (!result || !pBuf) {
        g_DecoderExhausted := true
        DebugLog("GetNext failed at frame " g_NextDecodeFrame)
        return false
    }

    ; Copy pixel data (decoder reuses buffer)
    stride := g_ImgW * 4
    bufSize := stride * g_ImgH
    pixelBuf := Buffer(bufSize, 0)
    DllCall("msvcrt\memcpy", "ptr", pixelBuf.Ptr, "ptr", pBuf, "uptr", bufSize, "ptr")

    ; Create GDI+ bitmap from our copy
    pBitmap := 0
    hr := DllCall("gdiplus\GdipCreateBitmapFromScan0"
        , "int", g_ImgW
        , "int", g_ImgH
        , "int", stride
        , "int", 0x26200A  ; PixelFormat32bppPARGB
        , "ptr", pixelBuf.Ptr
        , "ptr*", &pBitmap)

    if (hr != 0 || !pBitmap) {
        DebugLog("Bitmap creation failed for frame " g_NextDecodeFrame ", hr=" hr)
        return false
    }

    ; Store in buffer
    g_FrameBuffer[g_NextDecodeFrame] := {bitmap: pBitmap, pixelBuf: pixelBuf}
    DebugLog("Decoded frame " g_NextDecodeFrame " (buffer: " g_FrameBuffer.Count ")")

    g_NextDecodeFrame++
    return true
}

EvictOldFrames(currentFrame) {
    global g_FrameBuffer, FramesToBuffer

    ; Evict frames that are too far behind current playback position
    ; Keep frames from (currentFrame - 2) to (currentFrame + FramesToBuffer)
    minKeep := Max(1, currentFrame - 2)

    toDelete := []
    for frameNum, data in g_FrameBuffer {
        if (frameNum < minKeep) {
            toDelete.Push(frameNum)
        }
    }

    for frameNum in toDelete {
        data := g_FrameBuffer[frameNum]
        if (data.bitmap)
            DllCall("gdiplus\GdipDisposeImage", "ptr", data.bitmap)
        g_FrameBuffer.Delete(frameNum)
        DebugLog("Evicted frame " frameNum " (buffer: " g_FrameBuffer.Count ")")
    }
}

BufferAhead(currentFrame) {
    global g_FrameBuffer, FramesToBuffer, g_TotalFrames, g_DecoderExhausted

    ; Decode ahead to maintain buffer
    targetFrame := Min(currentFrame + FramesToBuffer, g_TotalFrames)

    while (!g_DecoderExhausted && g_FrameBuffer.Count < FramesToBuffer) {
        if (!DecodeNextFrame())
            break
    }
}

ResetDecoder() {
    global g_Decoder, g_DemuxDllName, g_FileData, g_FrameBuffer
    global g_NextDecodeFrame, g_DecoderExhausted, g_ImgW, g_ImgH, g_TotalFrames

    ; Clean up old buffer
    for frameNum, data in g_FrameBuffer {
        if (data.bitmap)
            DllCall("gdiplus\GdipDisposeImage", "ptr", data.bitmap)
    }
    g_FrameBuffer := Map()

    ; Delete old decoder
    if (g_Decoder) {
        DllCall(g_DemuxDllName "\WebPAnimDecoderDelete", "ptr", g_Decoder)
        g_Decoder := 0
    }

    ; Create new decoder from existing file data
    webpData := Buffer(A_PtrSize * 2, 0)
    NumPut("ptr", g_FileData.Ptr, webpData, 0)
    NumPut("uptr", g_FileData.Size, webpData, A_PtrSize)

    decOptions := Buffer(36, 0)
    WEBP_DEMUX_ABI_VERSION := 0x0107
    DllCall(g_DemuxDllName "\WebPAnimDecoderOptionsInitInternal"
        , "ptr", decOptions.Ptr
        , "int", WEBP_DEMUX_ABI_VERSION
        , "int")
    NumPut("int", 8, decOptions, 0)

    g_Decoder := DllCall(g_DemuxDllName "\WebPAnimDecoderNewInternal"
        , "ptr", webpData.Ptr
        , "ptr", decOptions.Ptr
        , "int", WEBP_DEMUX_ABI_VERSION
        , "ptr")

    g_NextDecodeFrame := 1
    g_DecoderExhausted := false

    DebugLog("Decoder reset for new loop")

    ; Pre-buffer
    Loop Min(FramesToBuffer, g_TotalFrames) {
        if (!DecodeNextFrame())
            break
    }
}

NextFrame() {
    global g_CurrentFrame, g_TotalFrames, g_Running, g_FadeState, g_FadeStartTick
    global g_FadeOutAnimationMS, g_FadeOutFixedMS, g_FrameMs, g_FrameBuffer

    if (!g_Running)
        return

    g_CurrentFrame++

    ; Evict old frames and buffer ahead
    EvictOldFrames(g_CurrentFrame)
    BufferAhead(g_CurrentFrame)

    ; Check if we need to start fade out
    if (g_FadeState = "playing" && g_FadeOutAnimationMS > 0) {
        framesForFadeOut := Round((g_FadeOutAnimationMS / 1000) * (1000 / g_FrameMs))
        if (g_CurrentFrame >= g_TotalFrames - framesForFadeOut) {
            g_FadeState := "out_anim"
            g_FadeStartTick := A_TickCount
        }
    }

    ; Check for loop
    if (g_CurrentFrame > g_TotalFrames) {
        if (g_FadeOutFixedMS > 0 && g_FadeState != "out_fixed") {
            g_CurrentFrame := g_TotalFrames
            g_Running := false
            SetTimer(NextFrame, 0)
            g_FadeState := "out_fixed"
            g_FadeStartTick := A_TickCount
            return
        } else if (g_FadeState = "out_anim" || g_FadeState = "playing") {
            StartNewLoop()
            return
        }
    }

    ; Check if frame is available
    if (!g_FrameBuffer.Has(g_CurrentFrame)) {
        DebugLog("WARNING: Frame " g_CurrentFrame " not in buffer! (buffer has " g_FrameBuffer.Count " frames)")
        ; Try to decode it now
        BufferAhead(g_CurrentFrame)
    }

    DrawFrame(g_CurrentFrame)
}

FadeStep() {
    global g_Alpha, g_FadeState, g_FadeStartTick, g_FadeStepMs
    global g_FadeInFixedMS, g_FadeInAnimationMS, g_FadeOutAnimationMS, g_FadeOutFixedMS
    global g_Running, g_FrameMs, g_CurrentFrame, g_TotalFrames

    elapsed := A_TickCount - g_FadeStartTick

    if (g_FadeState = "in_fixed") {
        progress := elapsed / g_FadeInFixedMS
        if (progress >= 1) {
            progress := 1
            if (g_FadeInAnimationMS > 0) {
                g_FadeState := "in_anim"
                g_FadeStartTick := A_TickCount
                g_Running := true
                SetTimer(NextFrame, g_FrameMs)
            } else {
                g_FadeState := "playing"
                g_Alpha := 255
                g_Running := true
                SetTimer(NextFrame, g_FrameMs)
            }
        }
        totalFadeIn := g_FadeInFixedMS + g_FadeInAnimationMS
        maxAlphaThisPhase := Round(255 * g_FadeInFixedMS / totalFadeIn)
        g_Alpha := Round(progress * maxAlphaThisPhase)
        DrawFrame(g_CurrentFrame)

    } else if (g_FadeState = "in_anim") {
        progress := elapsed / g_FadeInAnimationMS
        if (progress >= 1) {
            progress := 1
            g_FadeState := "playing"
            g_Alpha := 255
        }
        totalFadeIn := g_FadeInFixedMS + g_FadeInAnimationMS
        startAlpha := Round(255 * g_FadeInFixedMS / totalFadeIn)
        g_Alpha := startAlpha + Round(progress * (255 - startAlpha))
        DrawFrame(g_CurrentFrame)

    } else if (g_FadeState = "out_anim") {
        progress := elapsed / g_FadeOutAnimationMS
        if (progress >= 1)
            progress := 1
        totalFadeOut := g_FadeOutAnimationMS + g_FadeOutFixedMS
        minAlphaThisPhase := Round(255 * g_FadeOutFixedMS / totalFadeOut)
        g_Alpha := 255 - Round(progress * (255 - minAlphaThisPhase))
        DrawFrame(g_CurrentFrame)

    } else if (g_FadeState = "out_fixed") {
        progress := elapsed / g_FadeOutFixedMS
        if (progress >= 1) {
            progress := 1
            StartNewLoop()
            return
        }
        totalFadeOut := g_FadeOutAnimationMS + g_FadeOutFixedMS
        startAlpha := Round(255 * g_FadeOutFixedMS / totalFadeOut)
        g_Alpha := Round((1 - progress) * startAlpha)
        DrawFrame(g_CurrentFrame)

    } else if (g_FadeState = "playing") {
        g_Alpha := 255
    }
}

StartNewLoop() {
    global g_CurrentFrame, g_Alpha, g_FadeState, g_FadeStartTick, g_Running, g_FrameMs
    global g_FadeInFixedMS, g_FadeInAnimationMS

    ; Reset decoder for new loop
    ResetDecoder()

    g_CurrentFrame := 1
    g_Alpha := 0
    g_FadeStartTick := A_TickCount
    DrawFrame(1)

    if (g_FadeInFixedMS > 0) {
        g_FadeState := "in_fixed"
        g_Running := false
        SetTimer(NextFrame, 0)
    } else if (g_FadeInAnimationMS > 0) {
        g_FadeState := "in_anim"
        g_Running := true
        SetTimer(NextFrame, g_FrameMs)
    } else {
        g_FadeState := "playing"
        g_Alpha := 255
        g_Running := true
        SetTimer(NextFrame, g_FrameMs)
    }
}

DrawFrame(frameNum) {
    global g_FrameBuffer, g_Hdc, g_Hwnd, g_HdcScreen, g_ImgW, g_ImgH, g_PosX, g_PosY, g_TotalFrames

    if (frameNum < 1 || frameNum > g_TotalFrames)
        return

    if (!g_FrameBuffer.Has(frameNum)) {
        DebugLog("DrawFrame: frame " frameNum " not in buffer")
        return
    }

    pBitmap := g_FrameBuffer[frameNum].bitmap

    if (!pBitmap) {
        DebugLog("DrawFrame: null bitmap for frame " frameNum)
        return
    }

    ; Clear to transparent
    DllCall("gdi32\PatBlt", "ptr", g_Hdc, "int", 0, "int", 0, "int", g_ImgW, "int", g_ImgH, "uint", 0x00000042)

    ; Draw frame
    pGraphics := 0
    DllCall("gdiplus\GdipCreateFromHDC", "ptr", g_Hdc, "ptr*", &pGraphics)
    DllCall("gdiplus\GdipSetCompositingMode", "ptr", pGraphics, "int", 0)
    DllCall("gdiplus\GdipDrawImageRectI", "ptr", pGraphics, "ptr", pBitmap, "int", 0, "int", 0, "int", g_ImgW, "int", g_ImgH)
    DllCall("gdiplus\GdipDeleteGraphics", "ptr", pGraphics)

    ; Update layered window
    ptSrc := Buffer(8, 0)
    ptDst := Buffer(8, 0)
    NumPut("Int", g_PosX, ptDst, 0)
    NumPut("Int", g_PosY, ptDst, 4)
    sizeWnd := Buffer(8, 0)
    NumPut("Int", g_ImgW, sizeWnd, 0)
    NumPut("Int", g_ImgH, sizeWnd, 4)

    blendFunc := Buffer(4, 0)
    NumPut("UChar", 0, blendFunc, 0)
    NumPut("UChar", 0, blendFunc, 1)
    NumPut("UChar", g_Alpha, blendFunc, 2)
    NumPut("UChar", 1, blendFunc, 3)

    DllCall("UpdateLayeredWindow", "ptr", g_Hwnd
        , "ptr", g_HdcScreen, "ptr", ptDst.Ptr, "ptr", sizeWnd.Ptr
        , "ptr", g_Hdc, "ptr", ptSrc.Ptr, "uint", 0
        , "ptr", blendFunc.Ptr, "uint", 2)
}

RestartAnimation(*) {
    global g_FadeStepMs

    SetTimer(NextFrame, 0)
    SetTimer(FadeStep, 0)

    StartNewLoop()
    SetTimer(FadeStep, g_FadeStepMs)
}

Cleanup() {
    global g_FrameBuffer, g_GdipToken, g_Hdc, g_HdcScreen, g_DIB, g_DIBOld, g_Hwnd
    global g_Decoder, g_DemuxDllName, g_FileData

    SetTimer(NextFrame, 0)
    SetTimer(FadeStep, 0)

    ; Dispose all buffered bitmaps
    for frameNum, data in g_FrameBuffer {
        if (data.bitmap)
            DllCall("gdiplus\GdipDisposeImage", "ptr", data.bitmap)
    }
    g_FrameBuffer := Map()

    ; Delete decoder
    if (g_Decoder) {
        DllCall(g_DemuxDllName "\WebPAnimDecoderDelete", "ptr", g_Decoder)
        g_Decoder := 0
    }

    ; Release file data
    g_FileData := 0

    if (g_Hdc && g_DIBOld)
        DllCall("SelectObject", "ptr", g_Hdc, "ptr", g_DIBOld)
    if (g_DIB)
        DllCall("DeleteObject", "ptr", g_DIB)
    if (g_Hdc)
        DllCall("DeleteDC", "ptr", g_Hdc)
    if (g_HdcScreen)
        DllCall("ReleaseDC", "ptr", 0, "ptr", g_HdcScreen)
    if (g_Hwnd)
        DllCall("DestroyWindow", "ptr", g_Hwnd)
    if (g_GdipToken)
        DllCall("gdiplus\GdiplusShutdown", "ptr", g_GdipToken)
}

OnExit((*) => Cleanup())
