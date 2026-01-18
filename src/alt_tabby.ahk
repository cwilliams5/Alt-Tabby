#Requires AutoHotkey v2.0
#SingleInstance Off  ; Multiple instances allowed for multi-process

;@Ahk2Exe-Base C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe

; ============================================================
; Alt-Tabby - Unified Launcher & Mode Router
; ============================================================
; Usage:
;   alt_tabby.exe             - Launch GUI + Store (default)
;   alt_tabby.exe --store     - Run as WindowStore server
;   alt_tabby.exe --viewer    - Run as Debug Viewer
;   alt_tabby.exe --gui-only  - Run as GUI only (store must be running)
;   alt_tabby.exe --config    - Run Config Editor
;   alt_tabby.exe --blacklist - Run Blacklist Editor
;
; IMPORTANT: Mode flag is set BEFORE includes. Each module checks
; this flag and only initializes if it matches.
; ============================================================

; ============================================================
; MODE FLAG - SET BEFORE ANY INCLUDES!
; ============================================================
global g_AltTabbyMode := "launch"

for _, arg in A_Args {
    switch StrLower(arg) {
        case "--store":
            g_AltTabbyMode := "store"
            A_IconHidden := true  ; Hide tray icon IMMEDIATELY to minimize flicker
        case "--viewer":
            g_AltTabbyMode := "viewer"
            A_IconHidden := true
        case "--gui-only":
            g_AltTabbyMode := "gui"
            A_IconHidden := true
        case "--config":
            g_AltTabbyMode := "config"
            ; Config editor shows its own window, no tray icon needed
        case "--blacklist":
            g_AltTabbyMode := "blacklist"
            ; Blacklist editor shows its own window, no tray icon needed
    }
}

; Launcher mode globals (declared early, initialization happens after includes)
if (g_AltTabbyMode = "launch") {
    global g_StorePID := 0
    global g_GuiPID := 0
    global g_ViewerPID := 0
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
}

; Note: Subprocess tray icon hiding is done immediately in arg parsing above
; to minimize flicker (A_IconHidden := true set as soon as mode detected)

; Note: Launcher initialization moved to after includes (needs ConfigLoader_Init)

; ============================================================
; INCLUDES
; ============================================================
; Use #Include <Dir> to set the include base directory before
; including each module, so relative paths resolve correctly.

; Shared libraries (from src/shared/)
#Include %A_ScriptDir%\shared\
#Include config_loader.ahk
#Include config_editor.ahk
#Include blacklist_editor.ahk
#Include json.ahk
#Include ipc_pipe.ahk
#Include blacklist.ahk

; Store module (from src/store/)
#Include %A_ScriptDir%\store\
#Include windowstore.ahk
#Include winenum_lite.ahk
#Include mru_lite.ahk
#Include komorebi_lite.ahk
#Include komorebi_sub.ahk
#Include icon_pump.ahk
#Include proc_pump.ahk
#Include winevent_hook.ahk
#Include store_server.ahk

; Viewer module (from src/viewer/)
#Include %A_ScriptDir%\viewer\
#Include viewer.ahk

; GUI module (from src/gui/)
#Include %A_ScriptDir%\gui\
#Include gui_gdip.ahk
#Include gui_win.ahk
#Include gui_overlay.ahk
#Include gui_workspace.ahk
#Include gui_paint.ahk
#Include gui_input.ahk
#Include gui_store.ahk
#Include gui_state.ahk
#Include gui_interceptor.ahk
#Include gui_main.ahk

; ============================================================
; CONFIG MODE HANDLER
; ============================================================
; Run config editor and exit when launched with --config
if (g_AltTabbyMode = "config") {
    ConfigEditor_Run(false)  ; false = standalone mode, show "restart needed" message
    ExitApp()
}

; Run blacklist editor and exit when launched with --blacklist
if (g_AltTabbyMode = "blacklist") {
    BlacklistEditor_Run()
    ExitApp()
}

; ============================================================
; LAUNCHER MODE INITIALIZATION
; ============================================================
; Must be after includes so we can use ConfigLoader_Init
if (g_AltTabbyMode = "launch") {
    ; Initialize config to get splash settings
    ConfigLoader_Init()

    ; Show splash screen if enabled
    if (cfg.LauncherShowSplash)
        ShowSplashScreen()

    ; Set up tray with on-demand menu updates
    SetupLauncherTray()
    OnMessage(0x404, TrayIconClick)  ; WM_TRAYICON

    ; Launch store and GUI
    LaunchStore()
    Sleep(300)
    LaunchGui()

    ; Hide splash after duration (or immediately if duration is 0)
    if (cfg.LauncherShowSplash) {
        ; Calculate remaining time after launches
        elapsed := A_TickCount - g_SplashStartTick
        remaining := cfg.LauncherSplashDurationMs - elapsed
        if (remaining > 0)
            Sleep(remaining)
        HideSplashScreen()
    }

    ; Stay alive to manage subprocesses
    Persistent()
}

; ============================================================
; LAUNCHER FUNCTIONS
; ============================================================

LaunchStore() {
    global g_StorePID
    if (A_IsCompiled) {
        Run('"' A_ScriptFullPath '" --store', , , &g_StorePID)
    } else {
        Run('"' A_AhkPath '" "' A_ScriptDir '\store\store_server.ahk"', , , &g_StorePID)
    }
}

LaunchGui() {
    global g_GuiPID
    if (A_IsCompiled) {
        Run('"' A_ScriptFullPath '" --gui-only', , , &g_GuiPID)
    } else {
        Run('"' A_AhkPath '" "' A_ScriptDir '\gui\gui_main.ahk"', , , &g_GuiPID)
    }
}

LaunchViewer() {
    global g_ViewerPID
    if (A_IsCompiled) {
        Run('"' A_ScriptFullPath '" --viewer', , , &g_ViewerPID)
    } else {
        Run('"' A_AhkPath '" "' A_ScriptDir '\viewer\viewer.ahk"', , , &g_ViewerPID)
    }
}

; ============================================================
; SPLASH SCREEN (Transparent PNG with fade in/out)
; ============================================================

ShowSplashScreen() {
    global g_SplashHwnd, g_SplashStartTick, g_SplashBitmap, g_SplashHdc, g_SplashToken
    global g_SplashHdcScreen, g_SplashImgW, g_SplashImgH, g_SplashPosX, g_SplashPosY, g_SplashHModule
    global cfg

    g_SplashStartTick := A_TickCount

    ; Resolve image path
    imgPath := cfg.LauncherSplashImagePath
    if (!InStr(imgPath, ":")) {  ; Relative path
        if (A_IsCompiled)
            imgPath := A_ScriptDir "\" imgPath
        else
            imgPath := A_ScriptDir "\..\img\logo.png"
    }

    if (!FileExist(imgPath))
        return

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

    ; Load PNG with GDI+
    g_SplashBitmap := 0
    DllCall("gdiplus\GdipCreateBitmapFromFile", "wstr", imgPath, "ptr*", &g_SplashBitmap)
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
    hBitmap := DllCall("CreateDIBSection", "ptr", g_SplashHdc, "ptr", bi.Ptr, "uint", 0, "ptr*", &pvBits, "ptr", 0, "uint", 0, "ptr")
    DllCall("SelectObject", "ptr", g_SplashHdc, "ptr", hBitmap, "ptr")

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
    _SplashUpdateLayeredWindow(0)

    ; Fade in
    _SplashFade(0, 255, cfg.LauncherSplashFadeMs)
}

HideSplashScreen() {
    global g_SplashHwnd, g_SplashBitmap, g_SplashHdc, g_SplashToken, g_SplashHdcScreen, g_SplashHModule
    global cfg

    if (g_SplashHwnd) {
        ; Fade out
        _SplashFade(255, 0, cfg.LauncherSplashFadeMs)

        ; Cleanup window
        DllCall("DestroyWindow", "ptr", g_SplashHwnd)
        g_SplashHwnd := 0
    }

    if (g_SplashHdc) {
        DllCall("DeleteDC", "ptr", g_SplashHdc)
        g_SplashHdc := 0
    }

    if (g_SplashHdcScreen) {
        DllCall("ReleaseDC", "ptr", 0, "ptr", g_SplashHdcScreen)
        g_SplashHdcScreen := 0
    }

    if (g_SplashBitmap) {
        DllCall("gdiplus\GdipDisposeImage", "ptr", g_SplashBitmap)
        g_SplashBitmap := 0
    }

    if (g_SplashToken) {
        DllCall("gdiplus\GdiplusShutdown", "uptr", g_SplashToken)
        g_SplashToken := 0
    }

    if (g_SplashHModule) {
        DllCall("FreeLibrary", "ptr", g_SplashHModule)
        g_SplashHModule := 0
    }
}

; Update layered window with specified alpha - uses UpdateLayeredWindow for per-pixel alpha
_SplashUpdateLayeredWindow(alpha) {
    global g_SplashHwnd, g_SplashHdc, g_SplashHdcScreen
    global g_SplashImgW, g_SplashImgH, g_SplashPosX, g_SplashPosY

    if (!g_SplashHwnd)
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

_SplashFade(fromAlpha, toAlpha, durationMs) {
    global g_SplashHwnd
    if (!g_SplashHwnd)
        return

    if (durationMs <= 0) {
        _SplashUpdateLayeredWindow(toAlpha)
        return
    }

    steps := durationMs // 16  ; ~60fps
    if (steps < 1)
        steps := 1

    startTick := A_TickCount
    Loop steps {
        elapsed := A_TickCount - startTick
        progress := Min(elapsed / durationMs, 1.0)
        alpha := Integer(fromAlpha + (toAlpha - fromAlpha) * progress)
        _SplashUpdateLayeredWindow(alpha)
        if (progress >= 1.0)
            break
        Sleep(16)
    }
    _SplashUpdateLayeredWindow(toAlpha)
}

; ============================================================
; TRAY MENU (ON-DEMAND UPDATES)
; ============================================================

TrayIconClick(wParam, lParam, msg, hwnd) {
    ; 0x205 = WM_RBUTTONUP (right-click release)
    if (lParam = 0x205) {
        UpdateTrayMenu()
        A_TrayMenu.Show()  ; Must explicitly show the menu
        return 1  ; Prevent default handling (we showed it ourselves)
    }
    return 0  ; Let default handling continue for other events
}

SetupLauncherTray() {
    TraySetIcon("shell32.dll", 15)
    A_IconTip := "Alt-Tabby"
    UpdateTrayMenu()
}

UpdateTrayMenu() {
    global g_StorePID, g_GuiPID, g_ViewerPID

    tray := A_TrayMenu
    tray.Delete()

    ; Header
    tray.Add("Alt-Tabby", (*) => 0)
    tray.Disable("Alt-Tabby")
    tray.Add()

    ; Store status
    storeRunning := g_StorePID && ProcessExist(g_StorePID)
    if (storeRunning) {
        tray.Add("Store: Restart", (*) => RestartStore())
    } else {
        tray.Add("Store: Launch", (*) => LaunchStore())
    }

    ; GUI status
    guiRunning := g_GuiPID && ProcessExist(g_GuiPID)
    if (guiRunning) {
        tray.Add("GUI: Restart", (*) => RestartGui())
    } else {
        tray.Add("GUI: Launch", (*) => LaunchGui())
    }

    ; Viewer status (optional, launch from menu)
    viewerRunning := g_ViewerPID && ProcessExist(g_ViewerPID)
    if (viewerRunning) {
        tray.Add("Viewer: Restart", (*) => RestartViewer())
    } else {
        tray.Add("Viewer: Launch", (*) => LaunchViewer())
    }

    tray.Add()

    ; Restart option (only if something is running)
    if (storeRunning || guiRunning || viewerRunning) {
        tray.Add("Restart All", (*) => RestartAll())
        tray.Add()
    }

    ; Editors
    tray.Add("Edit Config...", (*) => LaunchConfigEditor())
    tray.Add("Edit Blacklist...", (*) => LaunchBlacklistEditor())
    tray.Add()

    tray.Add("Exit", (*) => ExitAll())
}

RestartStore() {
    global g_StorePID
    if (g_StorePID && ProcessExist(g_StorePID))
        ProcessClose(g_StorePID)
    g_StorePID := 0
    Sleep(300)
    LaunchStore()
}

RestartGui() {
    global g_GuiPID
    if (g_GuiPID && ProcessExist(g_GuiPID))
        ProcessClose(g_GuiPID)
    g_GuiPID := 0
    Sleep(300)
    LaunchGui()
}

RestartViewer() {
    global g_ViewerPID
    if (g_ViewerPID && ProcessExist(g_ViewerPID))
        ProcessClose(g_ViewerPID)
    g_ViewerPID := 0
    Sleep(300)
    LaunchViewer()
}

RestartAll() {
    global g_StorePID, g_GuiPID, g_ViewerPID

    ; Kill existing processes
    if (g_StorePID && ProcessExist(g_StorePID))
        ProcessClose(g_StorePID)
    if (g_GuiPID && ProcessExist(g_GuiPID))
        ProcessClose(g_GuiPID)
    if (g_ViewerPID && ProcessExist(g_ViewerPID))
        ProcessClose(g_ViewerPID)

    g_StorePID := 0
    g_GuiPID := 0
    g_ViewerPID := 0

    Sleep(500)

    ; Relaunch core processes
    LaunchStore()
    Sleep(300)
    LaunchGui()
}

ExitAll() {
    global g_StorePID, g_GuiPID, g_ViewerPID

    ; Kill all subprocesses
    if (g_StorePID && ProcessExist(g_StorePID))
        ProcessClose(g_StorePID)
    if (g_GuiPID && ProcessExist(g_GuiPID))
        ProcessClose(g_GuiPID)
    if (g_ViewerPID && ProcessExist(g_ViewerPID))
        ProcessClose(g_ViewerPID)

    ExitApp()
}

LaunchConfigEditor() {
    ; Run config editor with auto-restart enabled
    ; Returns true if changes were saved
    if (ConfigEditor_Run(true)) {
        ; Restart store and GUI to apply changes
        RestartStore()
        Sleep(300)
        RestartGui()
    }
}

LaunchBlacklistEditor() {
    ; Run blacklist editor
    ; IPC reload is sent automatically by the editor
    BlacklistEditor_Run()
}
