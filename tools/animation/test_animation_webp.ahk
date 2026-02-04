#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
; Animation Test - WebP via Windows Imaging Component (WIC)
; ============================================================
; Uses WIC (built into Windows 10+) to decode WebP frames
; Then displays using GDI+ layered window
; Press Escape to exit, Space to restart animation
; Positioned at center (no offset)

global g_Hwnd := 0
global g_Frames := []        ; Array of GDI+ bitmap pointers
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

Main()

Main() {
    global

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

    ; Initialize COM for WIC
    DllCall("ole32\CoInitializeEx", "ptr", 0, "uint", 0)

    ; Load WebP file
    webpPath := A_ScriptDir "\animation.webp"
    if (!FileExist(webpPath)) {
        MsgBox("WebP not found: " webpPath "`n`nRun make_webp.py first!")
        Cleanup()
        ExitApp()
    }

    ; Load frames using WIC
    if (!LoadWebPFrames(webpPath)) {
        MsgBox("Failed to load WebP frames")
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

    ; Center on screen
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

    ; Show first frame
    g_CurrentFrame := 1
    DrawFrame(1)

    ; Start animation
    g_Running := true
    SetTimer(NextFrame, g_FrameMs)

    ; Status
    ToolTip("WebP Animation Test`nFrames: " g_FrameCount " @ " g_FPS " fps (" g_FrameMs "ms)`nSize: " g_ImgW "x" g_ImgH "`n`nSpace = Restart, Escape = Exit")

    Hotkey("Escape", (*) => ExitApp())
    Hotkey("Space", RestartAnimation)
}

LoadWebPFrames(webpPath) {
    global g_Frames, g_ImgW, g_ImgH

    ; WIC GUIDs
    static CLSID_WICImagingFactory := "{cacaf262-9370-4615-a13b-9f5539da4c0a}"
    static IID_IWICImagingFactory := "{ec5ec8a9-c395-4314-9c77-54d7a935ff70}"
    static GUID_WICPixelFormat32bppPBGRA := Buffer(16)

    ; Initialize GUID for 32bpp PBGRA (premultiplied BGRA - what GDI+ expects)
    NumPut("UInt", 0x6fddc324, GUID_WICPixelFormat32bppPBGRA, 0)
    NumPut("UShort", 0x4e03, GUID_WICPixelFormat32bppPBGRA, 4)
    NumPut("UShort", 0x4bfe, GUID_WICPixelFormat32bppPBGRA, 6)
    NumPut("UChar", 0xb1, GUID_WICPixelFormat32bppPBGRA, 8)
    NumPut("UChar", 0x85, GUID_WICPixelFormat32bppPBGRA, 9)
    NumPut("UChar", 0x3d, GUID_WICPixelFormat32bppPBGRA, 10)
    NumPut("UChar", 0x77, GUID_WICPixelFormat32bppPBGRA, 11)
    NumPut("UChar", 0x76, GUID_WICPixelFormat32bppPBGRA, 12)
    NumPut("UChar", 0x8e, GUID_WICPixelFormat32bppPBGRA, 13)
    NumPut("UChar", 0x8d, GUID_WICPixelFormat32bppPBGRA, 14)
    NumPut("UChar", 0x00, GUID_WICPixelFormat32bppPBGRA, 15)

    ; Create WIC factory
    pFactory := 0
    hr := DllCall("ole32\CoCreateInstance"
        , "ptr", CLSIDFromString(CLSID_WICImagingFactory)
        , "ptr", 0
        , "uint", 1  ; CLSCTX_INPROC_SERVER
        , "ptr", CLSIDFromString(IID_IWICImagingFactory)
        , "ptr*", &pFactory)

    if (hr != 0 || !pFactory) {
        MsgBox("Failed to create WIC factory. Error: " Format("0x{:08X}", hr))
        return false
    }

    ; Create decoder from file
    pDecoder := 0
    hr := ComCall(3, pFactory, "wstr", webpPath, "ptr", 0, "uint", 0, "uint", 0, "ptr*", &pDecoder)  ; CreateDecoderFromFilename

    if (hr != 0 || !pDecoder) {
        MsgBox("Failed to create decoder. Error: " Format("0x{:08X}", hr) "`n`nMake sure you have Windows 10 1809+ for WebP support.")
        ObjRelease(pFactory)
        return false
    }

    ; Get frame count
    frameCount := 0
    hr := ComCall(12, pDecoder, "uint*", &frameCount)  ; GetFrameCount

    if (hr != 0 || frameCount = 0) {
        MsgBox("Failed to get frame count or no frames")
        ObjRelease(pDecoder)
        ObjRelease(pFactory)
        return false
    }

    ; Load each frame
    Loop frameCount {
        frameIndex := A_Index - 1

        ; Get frame
        pFrame := 0
        hr := ComCall(13, pDecoder, "uint", frameIndex, "ptr*", &pFrame)  ; GetFrame

        if (hr != 0 || !pFrame)
            continue

        ; Get frame dimensions (from first frame)
        if (g_ImgW = 0) {
            w := 0, h := 0
            ComCall(3, pFrame, "uint*", &w, "uint*", &h)  ; GetSize
            g_ImgW := w
            g_ImgH := h
        }

        ; Create format converter to get 32bpp PBGRA
        pConverter := 0
        hr := ComCall(10, pFactory, "ptr*", &pConverter)  ; CreateFormatConverter

        if (hr != 0 || !pConverter) {
            ObjRelease(pFrame)
            continue
        }

        ; Initialize converter
        hr := ComCall(3, pConverter  ; Initialize
            , "ptr", pFrame           ; Source
            , "ptr", GUID_WICPixelFormat32bppPBGRA  ; Destination format
            , "uint", 0               ; Dither
            , "ptr", 0                ; Palette
            , "double", 0.0           ; Alpha threshold
            , "uint", 0)              ; Palette type

        if (hr != 0) {
            ObjRelease(pConverter)
            ObjRelease(pFrame)
            continue
        }

        ; Create GDI+ bitmap from WIC bitmap
        pGdipBitmap := CreateGdipBitmapFromWIC(pConverter, g_ImgW, g_ImgH)

        if (pGdipBitmap)
            g_Frames.Push(pGdipBitmap)

        ObjRelease(pConverter)
        ObjRelease(pFrame)
    }

    ObjRelease(pDecoder)
    ObjRelease(pFactory)

    return g_Frames.Length > 0
}

CreateGdipBitmapFromWIC(pWICBitmap, width, height) {
    ; Allocate buffer for pixel data
    stride := width * 4
    bufSize := stride * height
    pixelBuf := Buffer(bufSize, 0)

    ; Create rect for CopyPixels
    rect := Buffer(16, 0)
    NumPut("Int", 0, rect, 0)       ; X
    NumPut("Int", 0, rect, 4)       ; Y
    NumPut("Int", width, rect, 8)   ; Width
    NumPut("Int", height, rect, 12) ; Height

    ; Copy pixels from WIC bitmap
    hr := ComCall(7, pWICBitmap, "ptr", rect.Ptr, "uint", stride, "uint", bufSize, "ptr", pixelBuf.Ptr)  ; CopyPixels

    if (hr != 0)
        return 0

    ; Create GDI+ bitmap
    pBitmap := 0
    hr := DllCall("gdiplus\GdipCreateBitmapFromScan0"
        , "int", width
        , "int", height
        , "int", stride
        , "int", 0x26200A  ; PixelFormat32bppPARGB
        , "ptr", pixelBuf.Ptr
        , "ptr*", &pBitmap)

    if (hr != 0 || !pBitmap)
        return 0

    ; Clone the bitmap so we don't depend on pixelBuf
    pClone := 0
    DllCall("gdiplus\GdipCloneImage", "ptr", pBitmap, "ptr*", &pClone)
    DllCall("gdiplus\GdipDisposeImage", "ptr", pBitmap)

    return pClone
}

CLSIDFromString(str) {
    static guids := Map()
    if (guids.Has(str))
        return guids[str]

    guid := Buffer(16, 0)
    hr := DllCall("ole32\CLSIDFromString", "wstr", str, "ptr", guid.Ptr)
    if (hr = 0)
        guids[str] := guid
    return guid
}

NextFrame() {
    global g_CurrentFrame, g_FrameCount, g_Running
    if (!g_Running)
        return

    g_CurrentFrame++
    if (g_CurrentFrame > g_FrameCount)
        g_CurrentFrame := 1

    DrawFrame(g_CurrentFrame)
}

DrawFrame(frameNum) {
    global g_Frames, g_Hdc, g_Hwnd, g_HdcScreen, g_ImgW, g_ImgH, g_PosX, g_PosY

    if (frameNum < 1 || frameNum > g_Frames.Length)
        return

    pBitmap := g_Frames[frameNum]

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
    NumPut("UChar", 255, blendFunc, 2)
    NumPut("UChar", 1, blendFunc, 3)

    DllCall("UpdateLayeredWindow", "ptr", g_Hwnd
        , "ptr", g_HdcScreen, "ptr", ptDst.Ptr, "ptr", sizeWnd.Ptr
        , "ptr", g_Hdc, "ptr", ptSrc.Ptr, "uint", 0
        , "ptr", blendFunc.Ptr, "uint", 2)
}

RestartAnimation(*) {
    global g_CurrentFrame, g_Running, g_FrameMs
    g_CurrentFrame := 1
    DrawFrame(1)
    if (!g_Running) {
        g_Running := true
        SetTimer(NextFrame, g_FrameMs)
    }
}

Cleanup() {
    global g_Frames, g_GdipToken, g_Hdc, g_HdcScreen, g_DIB, g_DIBOld, g_Hwnd

    SetTimer(NextFrame, 0)

    ; Dispose all frame bitmaps
    for pBitmap in g_Frames {
        if (pBitmap)
            DllCall("gdiplus\GdipDisposeImage", "ptr", pBitmap)
    }
    g_Frames := []

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

    DllCall("ole32\CoUninitialize")
}

OnExit((*) => Cleanup())
