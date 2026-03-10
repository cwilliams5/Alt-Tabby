#Requires AutoHotkey v2.0

; ============================================================
; Capture — Screenshot & Video Recording (Dev Tooling)
; ============================================================
; Config-gated hotkeys for capturing overlay screenshots (BitBlt)
; and video recordings (ffmpeg gdigrab). Zero overhead when disabled.
; ============================================================

global gCapture_Recording := false
global gCapture_StdinPipe := 0

; ========================= INIT =========================

Capture_Init() {
    global cfg
    if (!cfg.CaptureEnable)
        return

    ; Register screenshot hotkey
    hk := cfg.CaptureScreenshotHotkey
    if (hk != "") {
        if (SubStr(hk, 1, 1) != "*")
            hk := "*" hk
        Hotkey("~$" hk, (*) => _Capture_Screenshot())
    }

    ; Register video start hotkey
    hk := cfg.CaptureRecordStartHotkey
    if (hk != "") {
        if (SubStr(hk, 1, 1) != "*")
            hk := "*" hk
        Hotkey("~$" hk, (*) => _Capture_RecordStart())
    }

    ; Register video stop hotkey
    hk := cfg.CaptureRecordStopHotkey
    if (hk != "") {
        if (SubStr(hk, 1, 1) != "*")
            hk := "*" hk
        Hotkey("~$" hk, (*) => _Capture_RecordStop())
    }
}

; ========================= OUTPUT DIR =========================

_Capture_GetDir() {
    if (A_IsCompiled)
        return A_ScriptDir "\captures"
    return A_ScriptDir "\..\..\captures"
}

_Capture_EnsureDir() {
    dir := _Capture_GetDir()
    if (!DirExist(dir))
        DirCreate(dir)
    return dir
}

; ========================= GDI+ INIT =========================

_Capture_EnsureGdip() {
    ; Gdip_Startup() is a no-op in the D2D pipeline — GDI+ is never initialized
    ; for the GUI process. We need it for GdipCreateBitmapFromHBITMAP + GdipSaveImageToFile.
    static token := 0
    if (!token) {
        si := Buffer(24, 0)
        NumPut("UInt", 1, si, 0)  ; GdiplusVersion = 1
        DllCall("gdiplus\GdiplusStartup", "Ptr*", &token, "Ptr", si, "Ptr", 0)
    }
    return token
}

; ========================= PNG CLSID =========================

_Capture_GetPngClsid() {
    ; PNG encoder: {557CF406-1A04-11D3-9A73-0000F81EF32E}
    ; Hardcoded bytes — avoids ole32\CLSIDFromString dependency
    static clsid := 0
    if (!clsid) {
        clsid := Buffer(16, 0)
        NumPut("UInt", 0x557CF406, "UShort", 0x1A04, "UShort", 0x11D3, clsid, 0)
        NumPut("UChar", 0x9A, "UChar", 0x73, "UChar", 0x00, "UChar", 0x00,
               "UChar", 0xF8, "UChar", 0x1E, "UChar", 0xF3, "UChar", 0x2E, clsid, 8)
    }
    return clsid
}

; ========================= SCREENSHOT =========================

_Capture_Screenshot() {
    global gGUI_OverlayVisible, gGUI_BaseH

    if (!gGUI_OverlayVisible)
        return

    _Capture_EnsureGdip()

    ; Get overlay window rect (physical screen pixels)
    rect := Buffer(16, 0)
    if (!DllCall("GetWindowRect", "Ptr", gGUI_BaseH, "Ptr", rect))
        return
    x := NumGet(rect, 0, "Int")
    y := NumGet(rect, 4, "Int")
    w := NumGet(rect, 8, "Int") - x
    h := NumGet(rect, 12, "Int") - y

    if (w <= 0 || h <= 0)
        return

    ; BitBlt from screen DC
    hScreenDC := DllCall("GetDC", "Ptr", 0, "Ptr")
    hMemDC := DllCall("CreateCompatibleDC", "Ptr", hScreenDC, "Ptr")
    hBitmap := DllCall("CreateCompatibleBitmap", "Ptr", hScreenDC, "Int", w, "Int", h, "Ptr")
    hOldBmp := DllCall("SelectObject", "Ptr", hMemDC, "Ptr", hBitmap, "Ptr")
    DllCall("BitBlt", "Ptr", hMemDC, "Int", 0, "Int", 0, "Int", w, "Int", h
        , "Ptr", hScreenDC, "Int", x, "Int", y, "UInt", 0x00CC0020) ; SRCCOPY

    ; Convert HBITMAP to GDI+ bitmap
    pBitmap := 0
    gdipResult := DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", hBitmap, "Ptr", 0, "Ptr*", &pBitmap, "int")

    if (gdipResult != 0 || !pBitmap) {
        DllCall("SelectObject", "Ptr", hMemDC, "Ptr", hOldBmp)
        DllCall("DeleteObject", "Ptr", hBitmap)
        DllCall("DeleteDC", "Ptr", hMemDC)
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", hScreenDC)
        ToolTip("Screenshot failed (bitmap creation error)")
        SetTimer(() => ToolTip(), -3000)
        return
    }

    ; Save to PNG
    dir := _Capture_EnsureDir()
    fileName := "screenshot_" FormatTime(, "yyyyMMdd_HHmmss") ".png"
    filePath := dir "\" fileName
    pngClsid := _Capture_GetPngClsid()
    saveResult := DllCall("gdiplus\GdipSaveImageToFile", "Ptr", pBitmap, "Str", filePath, "Ptr", pngClsid, "Ptr", 0)

    ; Cleanup
    DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
    DllCall("SelectObject", "Ptr", hMemDC, "Ptr", hOldBmp)
    DllCall("DeleteObject", "Ptr", hBitmap)
    DllCall("DeleteDC", "Ptr", hMemDC)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hScreenDC)

    if (saveResult != 0) {
        ToolTip("Screenshot failed (could not save to " fileName ")")
        SetTimer(() => ToolTip(), -5000)
        return
    }

    ToolTip("Screenshot saved: " fileName)
    SetTimer(() => ToolTip(), -2000)
}

; ========================= VIDEO RECORDING =========================
;
; Uses CreateProcess with a stdin pipe instead of Run(). To stop ffmpeg
; gracefully we write "q" to its stdin — ffmpeg's standard quit command.
; This avoids AttachConsole + GenerateConsoleCtrlEvent which sends Ctrl+C
; to ALL attached processes (including our AHK process, crashing it).
;

_Capture_RecordStart() {
    global gGUI_OverlayVisible, gGUI_BaseH, gCapture_Recording, gCapture_StdinPipe

    if (!gGUI_OverlayVisible || gCapture_Recording)
        return

    ; Get overlay window rect (physical screen pixels)
    rect := Buffer(16, 0)
    DllCall("GetWindowRect", "Ptr", gGUI_BaseH, "Ptr", rect)
    x := NumGet(rect, 0, "Int")
    y := NumGet(rect, 4, "Int")
    w := NumGet(rect, 8, "Int") - x
    h := NumGet(rect, 12, "Int") - y

    if (w <= 0 || h <= 0)
        return

    ; H.264 requires even dimensions
    w += (w & 1)
    h += (h & 1)

    dir := _Capture_EnsureDir()
    fileName := "video_" FormatTime(, "yyyyMMdd_HHmmss") ".mp4"
    filePath := dir "\" fileName

    cmd := 'ffmpeg -f gdigrab -framerate 30'
        . ' -offset_x ' x ' -offset_y ' y ' -video_size ' w 'x' h
        . ' -i desktop'
        . ' -c:v libx264 -preset ultrafast -crf 18 -pix_fmt yuv420p'
        . ' -y "' filePath '"'

    ; Create stdin pipe — read end inherited by ffmpeg, write end kept by us
    sa := Buffer(24, 0)                     ; SECURITY_ATTRIBUTES (x64)
    NumPut("UInt", 24, sa, 0)               ; nLength
    NumPut("Int", 1, sa, 16)                ; bInheritHandle = TRUE

    hReadPipe := 0
    hWritePipe := 0
    if (!DllCall("CreatePipe", "Ptr*", &hReadPipe, "Ptr*", &hWritePipe, "Ptr", sa, "UInt", 0)) {
        ToolTip("Recording failed: CreatePipe error")
        SetTimer(() => ToolTip(), -3000)
        return
    }

    ; Write end stays with us — must NOT be inherited by ffmpeg
    DllCall("SetHandleInformation", "Ptr", hWritePipe, "UInt", 1, "UInt", 0) ; clear HANDLE_FLAG_INHERIT

    ; Open NUL for stdout/stderr so ffmpeg doesn't fail on progress writes
    hNul := DllCall("CreateFileW", "Str", "NUL", "UInt", 0x40000000, "UInt", 3
        , "Ptr", sa, "UInt", 3, "UInt", 0, "Ptr", 0, "Ptr") ; GENERIC_WRITE, SHARE_RW, OPEN_EXISTING

    ; STARTUPINFOW (x64: 104 bytes)
    si := Buffer(104, 0)
    NumPut("UInt", 104, si, 0)              ; cb
    NumPut("UInt", 0x101, si, 60)           ; dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW
    NumPut("UShort", 0, si, 64)             ; wShowWindow = SW_HIDE
    NumPut("Ptr", hReadPipe, si, 80)        ; hStdInput = pipe read end
    NumPut("Ptr", hNul, si, 88)             ; hStdOutput = NUL
    NumPut("Ptr", hNul, si, 96)             ; hStdError = NUL

    ; PROCESS_INFORMATION (x64: 24 bytes)
    pi := Buffer(24, 0)

    ok := DllCall("CreateProcessW", "Ptr", 0, "Str", cmd, "Ptr", 0, "Ptr", 0
        , "Int", 1, "UInt", 0x08000000, "Ptr", 0, "Ptr", 0, "Ptr", si, "Ptr", pi) ; CREATE_NO_WINDOW

    ; Close handles our process doesn't need
    DllCall("CloseHandle", "Ptr", hReadPipe)
    DllCall("CloseHandle", "Ptr", hNul)

    if (!ok) {
        DllCall("CloseHandle", "Ptr", hWritePipe)
        ToolTip("Recording failed: CreateProcess error (is ffmpeg on PATH?)")
        SetTimer(() => ToolTip(), -3000)
        return
    }

    DllCall("CloseHandle", "Ptr", NumGet(pi, 0, "Ptr"))   ; hProcess
    DllCall("CloseHandle", "Ptr", NumGet(pi, 8, "Ptr"))   ; hThread

    gCapture_StdinPipe := hWritePipe
    gCapture_Recording := true

    ToolTip("Recording started: " fileName)
    SetTimer(() => ToolTip(), -2000)
}

_Capture_RecordStop() {
    global gCapture_Recording, gCapture_StdinPipe

    if (!gCapture_Recording)
        return

    ; Write "q" to ffmpeg's stdin — graceful quit (finalizes MP4 moov atom)
    qBuf := Buffer(2, 0)
    NumPut("UChar", 0x71, qBuf, 0)          ; 'q'
    NumPut("UChar", 0x0A, qBuf, 1)          ; '\n'
    written := 0
    DllCall("WriteFile", "Ptr", gCapture_StdinPipe, "Ptr", qBuf, "UInt", 2, "UInt*", &written, "Ptr", 0)
    DllCall("CloseHandle", "Ptr", gCapture_StdinPipe)

    gCapture_Recording := false
    gCapture_StdinPipe := 0

    ToolTip("Recording stopped")
    SetTimer(() => ToolTip(), -2000)
}
