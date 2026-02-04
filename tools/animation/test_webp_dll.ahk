#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
; WebP Animation Test - Using libwebp DLL directly
; ============================================================
; Decodes animated WebP using libwebp's WebPAnimDecoder API
; Requires: libwebpdemux-2.dll and libwebp-2.dll in same folder
;
; Download from MSYS2:
;   https://packages.msys2.org/packages/mingw-w64-x86_64-libwebp
;   Direct: https://mirror.msys2.org/mingw/mingw64/mingw-w64-x86_64-libwebp-1.6.0-1-any.pkg.tar.zst
;   Extract with 7-Zip, get DLLs from mingw64/bin/
;
; Press Escape to exit, Space to restart animation
; ============================================================

global g_Hwnd := 0
global g_Frames := []
global g_FrameCount := 0
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
global g_LogFile := A_ScriptDir "\webp_debug.log"
global g_FrameBuffers := []  ; Keep pixel buffers alive
global g_Alpha := 0          ; Current window alpha (0-255)
global g_FadeState := ""     ; "in_fixed", "in_anim", "playing", "out_anim", "out_fixed"
global g_FadeStepMs := 16    ; ~60fps fade updates
global g_FadeStartTick := 0

; =============================================================================
; Fade Configuration (in milliseconds)
; =============================================================================
global g_FadeInFixedMS := 0      ; Fade in while frozen on frame 1
global g_FadeInAnimationMS := 500 ; Fade in while animation plays
global g_FadeOutAnimationMS := 500 ; Fade out while animation plays
global g_FadeOutFixedMS := 0      ; Fade out while frozen on last frame
; =============================================================================

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
    DebugLog("=== WebP DLL Test Started ===")

    ; Check for DLLs (try multiple naming conventions)
    dllDir := A_ScriptDir
    demuxDll := ""
    webpDll := ""

    ; Try different naming conventions (MSYS2 uses libwebp-7.dll, libwebpdemux-2.dll)
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

    ; Also check for sharpyuv dependency
    sharpyuvDll := ""
    for name in ["libsharpyuv-0.dll", "libsharpyuv.dll"] {
        if (FileExist(dllDir "\" name)) {
            sharpyuvDll := dllDir "\" name
            break
        }
    }

    if (!demuxDll || !webpDll) {
        MsgBox("Required DLLs not found in: " dllDir
            . "`n`nExpected: libwebpdemux-2.dll + libwebp-7.dll"
            . "`n`nDownload from MSYS2:"
            . "`nhttps://mirror.msys2.org/mingw/mingw64/mingw-w64-x86_64-libwebp-1.6.0-1-any.pkg.tar.zst"
            . "`n`nExtract with 7-Zip, copy DLLs from mingw64/bin/")
        ExitApp()
    }

    ; Load dependencies in order: sharpyuv -> webp -> demux
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

    ; Load demux DLL
    g_hWebPDemux := DllCall("LoadLibrary", "str", demuxDll, "ptr")
    if (!g_hWebPDemux) {
        MsgBox("Failed to load: " demuxDll "`n`nError: " A_LastError)
        ExitApp()
    }

    ; Extract just the filename (without .dll) for DllCall
    ; e.g., "C:\path\libwebpdemux-2.dll" -> "libwebpdemux-2"
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

    ; Load WebP frames using DLL
    if (!LoadWebPFramesDLL(webpPath)) {
        MsgBox("Failed to load WebP frames via DLL")
        Cleanup()
        ExitApp()
    }

    g_FrameCount := g_Frames.Length
    if (g_FrameCount = 0) {
        MsgBox("No frames loaded from WebP")
        Cleanup()
        ExitApp()
    }

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

    ; Show first frame with alpha 0 (invisible)
    g_CurrentFrame := 1
    g_Alpha := 0
    DrawFrame(1)

    ; Start fade sequence
    g_FadeStartTick := A_TickCount
    if (g_FadeInFixedMS > 0) {
        ; Start with fixed fade in (frozen on frame 1)
        g_FadeState := "in_fixed"
        g_Running := false
    } else if (g_FadeInAnimationMS > 0) {
        ; Start with animated fade in
        g_FadeState := "in_anim"
        g_Running := true
        SetTimer(NextFrame, g_FrameMs)
    } else {
        ; No fade in - start playing immediately
        g_FadeState := "playing"
        g_Alpha := 255
        g_Running := true
        SetTimer(NextFrame, g_FrameMs)
    }
    SetTimer(FadeStep, g_FadeStepMs)
    SetTimer(NextFrame, g_FrameMs)

    ; Status
    ToolTip("WebP Animation (DLL direct)`nFrames: " g_FrameCount " @ " g_FPS " fps (" g_FrameMs "ms)`nSize: " g_ImgW "x" g_ImgH "`n`nSpace = Restart, Escape = Exit")

    Hotkey("Escape", (*) => ExitApp())
    Hotkey("Space", RestartAnimation)
}

LoadWebPFramesDLL(webpPath) {
    global g_Frames, g_ImgW, g_ImgH, g_hWebPDemux, g_DemuxDllName

    ; Read file into memory
    fileData := FileRead(webpPath, "RAW")
    fileSize := fileData.Size

    ; WebPData structure: { bytes: ptr, size: size_t }
    webpData := Buffer(A_PtrSize * 2, 0)
    NumPut("ptr", fileData.Ptr, webpData, 0)
    NumPut("uptr", fileSize, webpData, A_PtrSize)

    ; WebPAnimDecoderOptions structure (36 bytes on x64)
    ; { color_mode: int, use_threads: int, padding[7]: uint32 }
    decOptions := Buffer(36, 0)

    ; Initialize options - WebPAnimDecoderOptionsInitInternal
    ; ABI version: 0x0107 (major=1, minor=7)
    WEBP_DEMUX_ABI_VERSION := 0x0107
    result := DllCall(g_DemuxDllName "\WebPAnimDecoderOptionsInitInternal"
        , "ptr", decOptions.Ptr
        , "int", WEBP_DEMUX_ABI_VERSION
        , "int")

    if (!result) {
        MsgBox("WebPAnimDecoderOptionsInitInternal failed")
        return false
    }

    ; Set color mode to MODE_bgrA (8) - pre-multiplied BGRA for GDI+ PixelFormat32bppPARGB
    ; Color modes: MODE_RGBA=1, MODE_BGRA=3, MODE_bgrA=8 (pre-multiplied)
    NumPut("int", 8, decOptions, 0)  ; MODE_bgrA = 8

    ; Create decoder - WebPAnimDecoderNewInternal
    pDecoder := DllCall(g_DemuxDllName "\WebPAnimDecoderNewInternal"
        , "ptr", webpData.Ptr
        , "ptr", decOptions.Ptr
        , "int", WEBP_DEMUX_ABI_VERSION
        , "ptr")

    if (!pDecoder) {
        MsgBox("WebPAnimDecoderNewInternal failed - invalid WebP or memory error")
        return false
    }

    ; Get animation info - WebPAnimDecoderGetInfo
    ; WebPAnimInfo: { canvas_width, canvas_height, loop_count, bgcolor, frame_count, pad[4] }
    animInfo := Buffer(36, 0)  ; 9 * 4 bytes
    result := DllCall(g_DemuxDllName "\WebPAnimDecoderGetInfo"
        , "ptr", pDecoder
        , "ptr", animInfo.Ptr
        , "int")

    if (!result) {
        MsgBox("WebPAnimDecoderGetInfo failed")
        DllCall(g_DemuxDllName "\WebPAnimDecoderDelete", "ptr", pDecoder)
        return false
    }

    g_ImgW := NumGet(animInfo, 0, "uint")
    g_ImgH := NumGet(animInfo, 4, "uint")
    frameCount := NumGet(animInfo, 16, "uint")

    DebugLog("WebP info: " g_ImgW "x" g_ImgH ", " frameCount " frames")

    ; Decode all frames
    Loop {
        ; Check if more frames
        hasMore := DllCall(g_DemuxDllName "\WebPAnimDecoderHasMoreFrames"
            , "ptr", pDecoder
            , "int")

        if (!hasMore)
            break

        ; Get next frame - WebPAnimDecoderGetNext
        pBuf := 0
        timestamp := 0
        result := DllCall(g_DemuxDllName "\WebPAnimDecoderGetNext"
            , "ptr", pDecoder
            , "ptr*", &pBuf
            , "int*", &timestamp
            , "int")

        if (!result || !pBuf)
            break

        ; Create GDI+ bitmap from BGRA buffer
        ; Buffer is canvas_width * 4 * canvas_height
        pBitmap := 0
        stride := g_ImgW * 4
        hr := DllCall("gdiplus\GdipCreateBitmapFromScan0"
            , "int", g_ImgW
            , "int", g_ImgH
            , "int", stride
            , "int", 0x26200A  ; PixelFormat32bppPARGB
            , "ptr", pBuf
            , "ptr*", &pBitmap)

        ; Copy pixel data to persistent buffer (decoder reuses same buffer)
        stride := g_ImgW * 4
        bufSize := stride * g_ImgH
        pixelBuf := Buffer(bufSize, 0)
        DllCall("msvcrt\memcpy", "ptr", pixelBuf.Ptr, "ptr", pBuf, "uptr", bufSize, "ptr")

        ; Create bitmap from our persistent copy
        pBitmap := 0
        hr := DllCall("gdiplus\GdipCreateBitmapFromScan0"
            , "int", g_ImgW
            , "int", g_ImgH
            , "int", stride
            , "int", 0x26200A  ; PixelFormat32bppPARGB
            , "ptr", pixelBuf.Ptr
            , "ptr*", &pBitmap)

        DebugLog("Frame " g_Frames.Length+1 ": pBuf=" pBuf " -> pixelBuf=" pixelBuf.Ptr " bitmap=" pBitmap " (hr=" hr ")")

        if (hr = 0 && pBitmap) {
            ; Keep buffer alive and store bitmap
            g_FrameBuffers.Push(pixelBuf)
            g_Frames.Push(pBitmap)
        } else {
            DebugLog("  ERROR: Bitmap creation failed, hr=" hr)
        }
    }

    ; Clean up decoder
    DllCall(g_DemuxDllName "\WebPAnimDecoderDelete", "ptr", pDecoder)

    DebugLog("Load complete: " g_Frames.Length " frames stored")

    return g_Frames.Length > 0
}

NextFrame() {
    global g_CurrentFrame, g_FrameCount, g_Running, g_FadeState, g_FadeStartTick
    global g_FadeOutAnimationMS, g_FadeOutFixedMS, g_FrameMs
    if (!g_Running)
        return

    g_CurrentFrame++

    ; Check if we need to start fade out (while still animating)
    if (g_FadeState = "playing" && g_FadeOutAnimationMS > 0) {
        ; Calculate how many frames before the end to start fading
        framesForFadeOut := Round((g_FadeOutAnimationMS / 1000) * (1000 / g_FrameMs))
        if (g_CurrentFrame >= g_FrameCount - framesForFadeOut) {
            g_FadeState := "out_anim"
            g_FadeStartTick := A_TickCount
        }
    }

    ; When reaching end of loop
    if (g_CurrentFrame > g_FrameCount) {
        if (g_FadeOutFixedMS > 0 && g_FadeState != "out_fixed") {
            ; Switch to fixed fade out on last frame
            g_CurrentFrame := g_FrameCount
            g_Running := false
            SetTimer(NextFrame, 0)
            g_FadeState := "out_fixed"
            g_FadeStartTick := A_TickCount
            return
        } else if (g_FadeState = "out_anim" || g_FadeState = "playing") {
            ; No fixed fade out, restart loop
            StartNewLoop()
            return
        }
    }

    DrawFrame(g_CurrentFrame)
}

FadeStep() {
    global g_Alpha, g_FadeState, g_FadeStartTick, g_FadeStepMs
    global g_FadeInFixedMS, g_FadeInAnimationMS, g_FadeOutAnimationMS, g_FadeOutFixedMS
    global g_Running, g_FrameMs, g_CurrentFrame, g_FrameCount

    elapsed := A_TickCount - g_FadeStartTick

    if (g_FadeState = "in_fixed") {
        ; Fading in while frozen on frame 1
        progress := elapsed / g_FadeInFixedMS
        if (progress >= 1) {
            progress := 1
            ; Transition to animated fade in or playing
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
        ; Alpha goes from 0 to partial (proportional to fixed portion of total fade in)
        totalFadeIn := g_FadeInFixedMS + g_FadeInAnimationMS
        maxAlphaThisPhase := Round(255 * g_FadeInFixedMS / totalFadeIn)
        g_Alpha := Round(progress * maxAlphaThisPhase)
        DrawFrame(g_CurrentFrame)

    } else if (g_FadeState = "in_anim") {
        ; Fading in while animation plays
        progress := elapsed / g_FadeInAnimationMS
        if (progress >= 1) {
            progress := 1
            g_FadeState := "playing"
            g_Alpha := 255
        }
        ; Alpha continues from where fixed left off to 255
        totalFadeIn := g_FadeInFixedMS + g_FadeInAnimationMS
        startAlpha := Round(255 * g_FadeInFixedMS / totalFadeIn)
        g_Alpha := startAlpha + Round(progress * (255 - startAlpha))
        DrawFrame(g_CurrentFrame)

    } else if (g_FadeState = "out_anim") {
        ; Fading out while animation plays
        progress := elapsed / g_FadeOutAnimationMS
        if (progress >= 1)
            progress := 1
        ; Alpha goes from 255 down to partial (leave room for fixed portion)
        totalFadeOut := g_FadeOutAnimationMS + g_FadeOutFixedMS
        minAlphaThisPhase := Round(255 * g_FadeOutFixedMS / totalFadeOut)
        g_Alpha := 255 - Round(progress * (255 - minAlphaThisPhase))
        DrawFrame(g_CurrentFrame)

    } else if (g_FadeState = "out_fixed") {
        ; Fading out while frozen on last frame
        progress := elapsed / g_FadeOutFixedMS
        if (progress >= 1) {
            progress := 1
            ; Fade out complete - restart loop
            StartNewLoop()
            return
        }
        ; Alpha goes from partial down to 0
        totalFadeOut := g_FadeOutAnimationMS + g_FadeOutFixedMS
        startAlpha := Round(255 * g_FadeOutFixedMS / totalFadeOut)
        g_Alpha := Round((1 - progress) * startAlpha)
        DrawFrame(g_CurrentFrame)

    } else if (g_FadeState = "playing") {
        ; Not fading - just ensure alpha is 255
        g_Alpha := 255
    }
}

StartNewLoop() {
    global g_CurrentFrame, g_Alpha, g_FadeState, g_FadeStartTick, g_Running, g_FrameMs
    global g_FadeInFixedMS, g_FadeInAnimationMS

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
    global g_Frames, g_Hdc, g_Hwnd, g_HdcScreen, g_ImgW, g_ImgH, g_PosX, g_PosY

    if (frameNum < 1 || frameNum > g_Frames.Length)
        return

    pBitmap := g_Frames[frameNum]

    DebugLog("DrawFrame " frameNum ": pBitmap=" pBitmap)

    ; Debug: check bitmap pointer
    if (!pBitmap) {
        DebugLog("  ERROR: null bitmap!")
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
    NumPut("UChar", g_Alpha, blendFunc, 2)  ; Use global alpha for fading
    NumPut("UChar", 1, blendFunc, 3)

    DllCall("UpdateLayeredWindow", "ptr", g_Hwnd
        , "ptr", g_HdcScreen, "ptr", ptDst.Ptr, "ptr", sizeWnd.Ptr
        , "ptr", g_Hdc, "ptr", ptSrc.Ptr, "uint", 0
        , "ptr", blendFunc.Ptr, "uint", 2)
}

RestartAnimation(*) {
    global g_FadeStepMs

    ; Stop any current animation/fade
    SetTimer(NextFrame, 0)
    SetTimer(FadeStep, 0)

    ; Restart with new loop
    StartNewLoop()
    SetTimer(FadeStep, g_FadeStepMs)
}

Cleanup() {
    global g_Frames, g_GdipToken, g_Hdc, g_HdcScreen, g_DIB, g_DIBOld, g_Hwnd

    SetTimer(NextFrame, 0)
    SetTimer(FadeStep, 0)

    ; Dispose all frame bitmaps
    for pBitmap in g_Frames {
        if (pBitmap)
            DllCall("gdiplus\GdipDisposeImage", "ptr", pBitmap)
    }
    g_Frames := []
    g_FrameBuffers := []  ; Release pixel buffer memory

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
