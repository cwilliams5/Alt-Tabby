#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
; Animation Test - GIF Frame Extraction
; ============================================================
; Loads animated GIF and extracts frames at runtime
; Press Escape to exit, Space to restart animation
; Positioned +400px right for side-by-side comparison with PNG version

global g_Hwnd := 0
global g_GifBitmap := 0
global g_FrameCount := 0
global g_CurrentFrame := 0
global g_Hdc := 0
global g_HdcScreen := 0
global g_DIB := 0
global g_DIBOld := 0
global g_Token := 0
global g_ImgW := 0
global g_ImgH := 0
global g_PosX := 0
global g_PosY := 0
global g_FPS := 24
global g_FrameMs := 42
global g_Running := false

; FrameDimensionTime GUID: {6aedbd6d-3fb5-418a-83a6-7f45229dc872}
global g_FrameDimension := Buffer(16)

Main()

Main() {
    global

    ; Set up FrameDimensionTime GUID
    NumPut("UInt", 0x6aedbd6d, g_FrameDimension, 0)
    NumPut("UShort", 0x3fb5, g_FrameDimension, 4)
    NumPut("UShort", 0x418a, g_FrameDimension, 6)
    NumPut("UChar", 0x83, g_FrameDimension, 8)
    NumPut("UChar", 0xa6, g_FrameDimension, 9)
    NumPut("UChar", 0x7f, g_FrameDimension, 10)
    NumPut("UChar", 0x45, g_FrameDimension, 11)
    NumPut("UChar", 0x22, g_FrameDimension, 12)
    NumPut("UChar", 0x9d, g_FrameDimension, 13)
    NumPut("UChar", 0xc8, g_FrameDimension, 14)
    NumPut("UChar", 0x72, g_FrameDimension, 15)

    ; Initialize GDI+
    hModule := DllCall("LoadLibrary", "str", "gdiplus", "ptr")
    if (!hModule) {
        MsgBox("Failed to load GDI+")
        ExitApp()
    }

    si := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
    NumPut("UInt", 1, si, 0)
    DllCall("gdiplus\GdiplusStartup", "ptr*", &g_Token, "ptr", si.Ptr, "ptr", 0)
    if (!g_Token) {
        MsgBox("Failed to start GDI+")
        ExitApp()
    }

    ; Load GIF
    gifPath := A_ScriptDir "\animation.gif"
    if (!FileExist(gifPath)) {
        MsgBox("GIF not found: " gifPath "`n`nRun make_gif.py first!")
        Cleanup()
        ExitApp()
    }

    DllCall("gdiplus\GdipCreateBitmapFromFile", "wstr", gifPath, "ptr*", &g_GifBitmap)
    if (!g_GifBitmap) {
        MsgBox("Failed to load GIF")
        Cleanup()
        ExitApp()
    }

    ; Get dimensions
    DllCall("gdiplus\GdipGetImageWidth", "ptr", g_GifBitmap, "uint*", &g_ImgW)
    DllCall("gdiplus\GdipGetImageHeight", "ptr", g_GifBitmap, "uint*", &g_ImgH)

    ; Get frame count using FrameDimensionTime
    g_FrameCount := 0
    result := DllCall("gdiplus\GdipImageGetFrameCount", "ptr", g_GifBitmap, "ptr", g_FrameDimension.Ptr, "uint*", &g_FrameCount)

    if (g_FrameCount = 0) {
        MsgBox("No frames in GIF (result: " result ")")
        Cleanup()
        ExitApp()
    }

    ; Try to get frame delay from GIF metadata (PropertyTagFrameDelay = 0x5100)
    propSize := 0
    DllCall("gdiplus\GdipGetPropertyItemSize", "ptr", g_GifBitmap, "uint", 0x5100, "uint*", &propSize)
    if (propSize > 0) {
        propItem := Buffer(propSize, 0)
        DllCall("gdiplus\GdipGetPropertyItem", "ptr", g_GifBitmap, "uint", 0x5100, "uint", propSize, "ptr", propItem.Ptr)
        ; Value pointer is at offset 8 (32-bit) or 16 (64-bit) after id(4), length(4), type(2), padding
        valuePtr := NumGet(propItem, 8 + (A_PtrSize = 8 ? 8 : 0), "ptr")
        if (valuePtr) {
            delay := NumGet(valuePtr, 0, "uint")
            if (delay > 0) {
                g_FrameMs := delay * 10  ; GIF delays are in 1/100th seconds
                g_FPS := Round(1000 / g_FrameMs, 1)
            }
        }
    }

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

    ; Show first frame
    g_CurrentFrame := 0
    DrawFrame(0)

    ; Start animation
    g_Running := true
    SetTimer(NextFrame, g_FrameMs)

    ; Status
    ToolTip("GIF Animation Test`nFrames: " g_FrameCount " @ " g_FPS " fps (" g_FrameMs "ms)`nSize: " g_ImgW "x" g_ImgH "`n`nSpace = Restart, Escape = Exit")

    Hotkey("Escape", (*) => ExitApp())
    Hotkey("Space", RestartAnimation)
}

NextFrame() {
    global g_CurrentFrame, g_FrameCount, g_Running
    if (!g_Running)
        return

    g_CurrentFrame++
    if (g_CurrentFrame >= g_FrameCount)
        g_CurrentFrame := 0

    DrawFrame(g_CurrentFrame)
}

DrawFrame(frameNum) {
    global g_GifBitmap, g_FrameDimension, g_Hdc, g_Hwnd, g_HdcScreen, g_ImgW, g_ImgH, g_PosX, g_PosY

    ; Select the frame
    result := DllCall("gdiplus\GdipImageSelectActiveFrame", "ptr", g_GifBitmap, "ptr", g_FrameDimension.Ptr, "uint", frameNum)

    ; Clear to transparent
    DllCall("gdi32\PatBlt", "ptr", g_Hdc, "int", 0, "int", 0, "int", g_ImgW, "int", g_ImgH, "uint", 0x00000042)

    ; Draw current frame
    pGraphics := 0
    DllCall("gdiplus\GdipCreateFromHDC", "ptr", g_Hdc, "ptr*", &pGraphics)
    DllCall("gdiplus\GdipSetCompositingMode", "ptr", pGraphics, "int", 0)
    DllCall("gdiplus\GdipDrawImageRectI", "ptr", pGraphics, "ptr", g_GifBitmap, "int", 0, "int", 0, "int", g_ImgW, "int", g_ImgH)
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
    g_CurrentFrame := 0
    DrawFrame(0)
    if (!g_Running) {
        g_Running := true
        SetTimer(NextFrame, g_FrameMs)
    }
}

Cleanup() {
    global g_GifBitmap, g_Token, g_Hdc, g_HdcScreen, g_DIB, g_DIBOld, g_Hwnd

    SetTimer(NextFrame, 0)

    if (g_GifBitmap)
        DllCall("gdiplus\GdipDisposeImage", "ptr", g_GifBitmap)

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
    if (g_Token)
        DllCall("gdiplus\GdiplusShutdown", "ptr", g_Token)
}

OnExit((*) => Cleanup())
