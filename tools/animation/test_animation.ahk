#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
; Animation Test - PNG Frame Sequence
; ============================================================
; Press Escape to exit, Space to restart animation

global g_Hwnd := 0
global g_Frames := []        ; Array of GDI+ bitmap pointers
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
global g_FPS := 15
global g_FrameMs := 67       ; ms per frame (1000/fps)
global g_Running := false

Main()

Main() {
    global

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

    ; Load frames
    framesDir := A_ScriptDir "\frames"
    if (!DirExist(framesDir)) {
        MsgBox("Frames directory not found: " framesDir "`n`nRun extract_frames.py first!")
        Cleanup()
        ExitApp()
    }

    ; Read metadata
    metaFile := framesDir "\meta.txt"
    if (FileExist(metaFile)) {
        content := FileRead(metaFile)
        if (RegExMatch(content, "fps=([0-9.]+)", &m))
            g_FPS := Float(m[1])
        if (RegExMatch(content, "width=(\d+)", &m))
            g_ImgW := Integer(m[1])
        if (RegExMatch(content, "height=(\d+)", &m))
            g_ImgH := Integer(m[1])
    }

    g_FrameMs := Round(1000 / g_FPS)

    ; Load all frame PNGs
    Loop Files framesDir "\frame_*.png"
    {
        pBitmap := 0
        DllCall("gdiplus\GdipCreateBitmapFromFile", "wstr", A_LoopFileFullPath, "ptr*", &pBitmap)
        if (pBitmap) {
            g_Frames.Push(pBitmap)
            ; Get dimensions from first frame if not in metadata
            if (g_ImgW = 0 && g_Frames.Length = 1) {
                DllCall("gdiplus\GdipGetImageWidth", "ptr", pBitmap, "uint*", &g_ImgW)
                DllCall("gdiplus\GdipGetImageHeight", "ptr", pBitmap, "uint*", &g_ImgH)
            }
        }
    }

    g_FrameCount := g_Frames.Length
    if (g_FrameCount = 0) {
        MsgBox("No frames loaded from " framesDir)
        Cleanup()
        ExitApp()
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
    NumPut("Int", -g_ImgH, bi, 8)  ; Negative = top-down
    NumPut("UShort", 1, bi, 12)
    NumPut("UShort", 32, bi, 14)

    pvBits := 0
    g_DIB := DllCall("CreateDIBSection", "ptr", g_Hdc, "ptr", bi.Ptr, "uint", 0, "ptr*", &pvBits, "ptr", 0, "uint", 0, "ptr")
    g_DIBOld := DllCall("SelectObject", "ptr", g_Hdc, "ptr", g_DIB, "ptr")

    ; Show window
    DllCall("ShowWindow", "ptr", g_Hwnd, "int", 8)  ; SW_SHOWNA

    ; Show first frame
    g_CurrentFrame := 1
    DrawFrame(1)

    ; Start animation
    g_Running := true
    SetTimer(NextFrame, g_FrameMs)

    ; Status tooltip
    ToolTip("Animation Test`nFrames: " g_FrameCount " @ " g_FPS " fps (" g_FrameMs "ms)`nSize: " g_ImgW "x" g_ImgH "`n`nSpace = Restart, Escape = Exit")

    ; Hotkeys
    Hotkey("Escape", (*) => ExitApp())
    Hotkey("Space", RestartAnimation)
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
    NumPut("UChar", 0, blendFunc, 0)    ; AC_SRC_OVER
    NumPut("UChar", 0, blendFunc, 1)
    NumPut("UChar", 255, blendFunc, 2)  ; Full opacity
    NumPut("UChar", 1, blendFunc, 3)    ; AC_SRC_ALPHA

    DllCall("UpdateLayeredWindow", "ptr", g_Hwnd
        , "ptr", g_HdcScreen, "ptr", ptDst.Ptr, "ptr", sizeWnd.Ptr
        , "ptr", g_Hdc, "ptr", ptSrc.Ptr, "uint", 0
        , "ptr", blendFunc.Ptr, "uint", 2)
}

RestartAnimation(*) {
    global g_CurrentFrame, g_Running
    g_CurrentFrame := 1
    DrawFrame(1)
    if (!g_Running) {
        g_Running := true
        SetTimer(NextFrame, g_FrameMs)
    }
}

Cleanup() {
    global g_Frames, g_Token, g_Hdc, g_HdcScreen, g_DIB, g_DIBOld, g_Hwnd

    SetTimer(NextFrame, 0)

    ; Dispose all frame bitmaps
    for pBitmap in g_Frames {
        if (pBitmap)
            DllCall("gdiplus\GdipDisposeImage", "ptr", pBitmap)
    }
    g_Frames := []

    ; Cleanup GDI resources
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
