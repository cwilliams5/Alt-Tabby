#Requires AutoHotkey v2.0

; ============================================================
; Launcher Splash Screen - GDI+ PNG with fade animation
; ============================================================
; Shows a transparent PNG splash screen during startup.
; Uses UpdateLayeredWindow for per-pixel alpha blending.

; Splash screen globals
global g_SplashHwnd := 0
global g_SplashStartTick := 0
global g_SplashBitmap := 0
global g_SplashHdc := 0
global g_SplashHdcScreen := 0
global g_SplashToken := 0
global g_SplashHModule := 0
global g_SplashImgW := 0
global g_SplashImgH := 0
global g_SplashPosX := 0
global g_SplashPosY := 0
global g_SplashDIB := 0  ; DIB bitmap handle (must be deleted to avoid leak)
global g_SplashShuttingDown := false  ; Shutdown coordination flag

ShowSplashScreen() {
    global g_SplashHwnd, g_SplashStartTick, g_SplashBitmap, g_SplashHdc, g_SplashToken
    global g_SplashHdcScreen, g_SplashImgW, g_SplashImgH, g_SplashPosX, g_SplashPosY, g_SplashHModule
    global g_SplashDIB, cfg

    g_SplashStartTick := A_TickCount

    ; Load GDI+ library first (required before GdiplusStartup)
    g_SplashHModule := DllCall("LoadLibrary", "str", "gdiplus", "ptr")
    if (!g_SplashHModule)
        return

    ; Start GDI+
    si := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
    NumPut("UInt", 1, si, 0)
    g_SplashToken := 0
    DllCall("gdiplus\GdiplusStartup", "ptr*", &g_SplashToken, "ptr", si.Ptr, "ptr", 0)
    if (!g_SplashToken) {
        DllCall("FreeLibrary", "ptr", g_SplashHModule)
        g_SplashHModule := 0
        return
    }

    ; Load PNG - from embedded resource (compiled) or file (dev mode)
    g_SplashBitmap := 0
    if (A_IsCompiled) {
        ; Load from embedded resource (ID 10, RT_RCDATA=10)
        g_SplashBitmap := _Splash_LoadBitmapFromResource(10)
    } else {
        ; Dev mode: load from file
        imgPath := A_ScriptDir "\..\img\logo.png"
        if (FileExist(imgPath))
            DllCall("gdiplus\GdipCreateBitmapFromFile", "wstr", imgPath, "ptr*", &g_SplashBitmap)
    }

    if (!g_SplashBitmap) {
        DllCall("gdiplus\GdiplusShutdown", "uptr", g_SplashToken)
        DllCall("FreeLibrary", "ptr", g_SplashHModule)
        g_SplashToken := 0
        g_SplashHModule := 0
        return
    }

    ; Get image dimensions
    g_SplashImgW := 0, g_SplashImgH := 0
    DllCall("gdiplus\GdipGetImageWidth", "ptr", g_SplashBitmap, "uint*", &g_SplashImgW)
    DllCall("gdiplus\GdipGetImageHeight", "ptr", g_SplashBitmap, "uint*", &g_SplashImgH)

    ; Create layered window (WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW)
    WS_POPUP := 0x80000000
    WS_EX_LAYERED := 0x80000
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

    if (!g_SplashHwnd) {
        DllCall("gdiplus\GdipDisposeImage", "ptr", g_SplashBitmap)
        DllCall("gdiplus\GdiplusShutdown", "uptr", g_SplashToken)
        DllCall("FreeLibrary", "ptr", g_SplashHModule)
        g_SplashBitmap := 0
        g_SplashToken := 0
        g_SplashHModule := 0
        return
    }

    ; Create compatible DC and draw image
    g_SplashHdcScreen := DllCall("GetDC", "ptr", 0, "ptr")
    g_SplashHdc := DllCall("CreateCompatibleDC", "ptr", g_SplashHdcScreen, "ptr")

    ; Create 32-bit DIB for alpha (top-down with negative height)
    bi := Buffer(40, 0)
    NumPut("UInt", 40, bi, 0)           ; biSize
    NumPut("Int", g_SplashImgW, bi, 4)  ; biWidth
    NumPut("Int", -g_SplashImgH, bi, 8) ; biHeight (negative = top-down)
    NumPut("UShort", 1, bi, 12)         ; biPlanes
    NumPut("UShort", 32, bi, 14)        ; biBitCount

    pvBits := 0
    g_SplashDIB := DllCall("CreateDIBSection", "ptr", g_SplashHdc, "ptr", bi.Ptr, "uint", 0, "ptr*", &pvBits, "ptr", 0, "uint", 0, "ptr")
    DllCall("SelectObject", "ptr", g_SplashHdc, "ptr", g_SplashDIB, "ptr")

    ; Clear the bitmap to transparent (important!)
    DllCall("gdi32\PatBlt", "ptr", g_SplashHdc, "int", 0, "int", 0, "int", g_SplashImgW, "int", g_SplashImgH, "uint", 0x00000042)  ; BLACKNESS

    ; Draw PNG onto DIB using GDI+
    pGraphics := 0
    DllCall("gdiplus\GdipCreateFromHDC", "ptr", g_SplashHdc, "ptr*", &pGraphics)
    ; Set compositing mode to SourceOver for proper alpha blending
    DllCall("gdiplus\GdipSetCompositingMode", "ptr", pGraphics, "int", 0)  ; CompositingModeSourceOver
    DllCall("gdiplus\GdipDrawImageRectI", "ptr", pGraphics, "ptr", g_SplashBitmap, "int", 0, "int", 0, "int", g_SplashImgW, "int", g_SplashImgH)
    DllCall("gdiplus\GdipDeleteGraphics", "ptr", pGraphics)

    ; Show window first, then update with alpha=0 for fade-in start
    DllCall("ShowWindow", "ptr", g_SplashHwnd, "int", 8)  ; SW_SHOWNA

    ; Start with alpha=0 for fade-in
    _Splash_UpdateLayeredWindow(0)

    ; Fade in
    _Splash_Fade(0, 255, cfg.LauncherSplashFadeMs)
}

HideSplashScreen() {
    global g_SplashHwnd, g_SplashBitmap, g_SplashHdc, g_SplashToken, g_SplashHdcScreen, g_SplashHModule
    global g_SplashDIB, g_SplashShuttingDown, cfg

    ; Set shutdown flag FIRST to stop any in-progress fades
    g_SplashShuttingDown := true

    if (g_SplashHwnd) {
        ; Fade out
        _Splash_Fade(255, 0, cfg.LauncherSplashFadeMs)

        ; Cleanup window
        try DllCall("DestroyWindow", "ptr", g_SplashHwnd)
        g_SplashHwnd := 0
    }

    ; Delete DIB before DC (must delete bitmap before the DC it's selected into)
    if (g_SplashDIB) {
        try DllCall("DeleteObject", "ptr", g_SplashDIB)
        g_SplashDIB := 0
    }

    if (g_SplashHdc) {
        try DllCall("DeleteDC", "ptr", g_SplashHdc)
        g_SplashHdc := 0
    }

    if (g_SplashHdcScreen) {
        try DllCall("ReleaseDC", "ptr", 0, "ptr", g_SplashHdcScreen)
        g_SplashHdcScreen := 0
    }

    if (g_SplashBitmap) {
        try DllCall("gdiplus\GdipDisposeImage", "ptr", g_SplashBitmap)
        g_SplashBitmap := 0
    }

    if (g_SplashToken) {
        try DllCall("gdiplus\GdiplusShutdown", "uptr", g_SplashToken)
        g_SplashToken := 0
    }

    if (g_SplashHModule) {
        try DllCall("FreeLibrary", "ptr", g_SplashHModule)
        g_SplashHModule := 0
    }
}

; Update layered window with specified alpha - uses UpdateLayeredWindow for per-pixel alpha
_Splash_UpdateLayeredWindow(alpha) {
    global g_SplashHwnd, g_SplashHdc, g_SplashHdcScreen, g_SplashShuttingDown
    global g_SplashImgW, g_SplashImgH, g_SplashPosX, g_SplashPosY

    if (!g_SplashHwnd || g_SplashShuttingDown)
        return

    ptSrc := Buffer(8, 0)  ; Source point (0,0)
    ptDst := Buffer(8, 0)
    NumPut("Int", g_SplashPosX, ptDst, 0)
    NumPut("Int", g_SplashPosY, ptDst, 4)
    sizeWnd := Buffer(8, 0)
    NumPut("Int", g_SplashImgW, sizeWnd, 0)
    NumPut("Int", g_SplashImgH, sizeWnd, 4)

    blendFunc := Buffer(4, 0)
    NumPut("UChar", 0, blendFunc, 0)      ; BlendOp = AC_SRC_OVER
    NumPut("UChar", 0, blendFunc, 1)      ; BlendFlags
    NumPut("UChar", alpha, blendFunc, 2)  ; SourceConstantAlpha
    NumPut("UChar", 1, blendFunc, 3)      ; AlphaFormat = AC_SRC_ALPHA

    DllCall("UpdateLayeredWindow", "ptr", g_SplashHwnd
        , "ptr", g_SplashHdcScreen, "ptr", ptDst.Ptr, "ptr", sizeWnd.Ptr
        , "ptr", g_SplashHdc, "ptr", ptSrc.Ptr, "uint", 0
        , "ptr", blendFunc.Ptr, "uint", 2)  ; ULW_ALPHA
}

_Splash_Fade(fromAlpha, toAlpha, durationMs) {
    global g_SplashHwnd, g_SplashShuttingDown
    if (!g_SplashHwnd)
        return

    if (durationMs <= 0) {
        _Splash_UpdateLayeredWindow(toAlpha)
        return
    }

    steps := durationMs // 16  ; ~60fps
    if (steps < 1)
        steps := 1

    startTick := A_TickCount
    Loop steps {
        ; Exit early if shutdown started or window destroyed
        if (!g_SplashHwnd || g_SplashShuttingDown)
            return
        elapsed := A_TickCount - startTick
        progress := Min(elapsed / durationMs, 1.0)
        alpha := Integer(fromAlpha + (toAlpha - fromAlpha) * progress)
        _Splash_UpdateLayeredWindow(alpha)
        if (progress >= 1.0)
            break
        Sleep(16)
    }
    ; Guard final update
    if (g_SplashHwnd && !g_SplashShuttingDown)
        _Splash_UpdateLayeredWindow(toAlpha)
}

; Load a GDI+ bitmap from an embedded PE resource
; resourceId: The resource ID (e.g., 10 for logo.png)
; Returns: GDI+ bitmap pointer, or 0 on failure
_Splash_LoadBitmapFromResource(resourceId) {
    ; Find the resource (RT_RCDATA = 10)
    hRes := DllCall("FindResource", "ptr", 0, "int", resourceId, "int", 10, "ptr")
    if (!hRes)
        return 0

    ; Get resource size and load it
    resSize := DllCall("SizeofResource", "ptr", 0, "ptr", hRes, "uint")
    hMem := DllCall("LoadResource", "ptr", 0, "ptr", hRes, "ptr")
    if (!hMem || !resSize)
        return 0

    ; Lock the resource to get a pointer to the data
    pData := DllCall("LockResource", "ptr", hMem, "ptr")
    if (!pData)
        return 0

    ; Allocate global memory and copy resource data (needed for IStream)
    hGlobal := DllCall("GlobalAlloc", "uint", 0x0002, "uptr", resSize, "ptr")  ; GMEM_MOVEABLE
    if (!hGlobal)
        return 0

    pGlobal := DllCall("GlobalLock", "ptr", hGlobal, "ptr")
    if (!pGlobal) {
        DllCall("GlobalFree", "ptr", hGlobal)
        return 0
    }

    DllCall("RtlMoveMemory", "ptr", pGlobal, "ptr", pData, "uptr", resSize)
    DllCall("GlobalUnlock", "ptr", hGlobal)

    ; Create IStream from the global memory
    pStream := 0
    hr := DllCall("ole32\CreateStreamOnHGlobal", "ptr", hGlobal, "int", 1, "ptr*", &pStream, "int")
    if (hr != 0 || !pStream) {
        DllCall("GlobalFree", "ptr", hGlobal)
        return 0
    }

    ; Create GDI+ bitmap from IStream
    pBitmap := 0
    DllCall("gdiplus\GdipCreateBitmapFromStream", "ptr", pStream, "ptr*", &pBitmap)

    ; Release IStream (it owns the HGLOBAL now due to fDeleteOnRelease=1)
    ObjRelease(pStream)

    return pBitmap
}
