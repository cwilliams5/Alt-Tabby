#Requires AutoHotkey v2.0
; WebP-to-PNG conversion via libwebp + GDI+.
; Shared utility used by both native and WebView2 config editors.
#Warn VarUnset, Off

WebP_ConvertToPNG(webpPath, outputDir) {
    ; Decode WebP via libwebp (shipped with the app), then save as PNG via GDI+
    try {
        ; Load libwebp DLLs
        static hSharpYuv := 0, hWebP := 0, webpDllName := ""
        if (!hWebP) {
            global RES_ID_SHARPYUV_DLL, RES_ID_WEBP_DLL
            if (A_IsCompiled) {
                dllDir := A_Temp "\AltTabby_WebP"
                if (!DirExist(dllDir))
                    DirCreate(dllDir)
                sharpyuvPath := ResourceExtractToTemp(RES_ID_SHARPYUV_DLL, "libsharpyuv-0.dll", dllDir)
                webpPath2 := ResourceExtractToTemp(RES_ID_WEBP_DLL, "libwebp-7.dll", dllDir)
            } else {
                dllDir := A_ScriptDir "\..\resources"
                for name in ["libsharpyuv-0.dll", "libsharpyuv.dll"] {
                    if (FileExist(dllDir "\" name)) {
                        sharpyuvPath := dllDir "\" name
                        break
                    }
                }
                for name in ["libwebp-7.dll", "libwebp-2.dll", "libwebp.dll"] {
                    if (FileExist(dllDir "\" name)) {
                        webpPath2 := dllDir "\" name
                        break
                    }
                }
            }
            if (IsSet(sharpyuvPath) && sharpyuvPath)
                hSharpYuv := DllCall("LoadLibrary", "str", sharpyuvPath, "ptr")
            if (!IsSet(webpPath2) || !webpPath2)
                return ""
            hWebP := DllCall("LoadLibrary", "str", webpPath2, "ptr")
            if (!hWebP)
                return ""
            SplitPath(webpPath2, &dllFile)
            webpDllName := RegExReplace(dllFile, "\.dll$", "")
        }

        ; Read WebP file into memory
        file := FileOpen(webpPath, "r")
        if (!file)
            return ""
        fileSize := file.Length
        data := Buffer(fileSize)
        file.RawRead(data, fileSize)
        file.Close()

        ; Decode to BGRA pixels
        w := 0, h := 0
        pPixels := DllCall(webpDllName "\WebPDecodeBGRA", "ptr", data, "uint", fileSize, "int*", &w, "int*", &h, "ptr")
        if (!pPixels || w = 0 || h = 0)
            return ""

        ; Initialize GDI+
        static gdipToken := 0
        if (!gdipToken) {
            si := Buffer(24, 0)
            NumPut("uint", 1, si, 0)
            DllCall("gdiplus\GdiplusStartup", "ptr*", &gdipToken, "ptr", si, "ptr", 0)
        }

        ; Create GDI+ bitmap from raw BGRA pixels
        ; PixelFormat32bppARGB = 0x26200A
        pBitmapGdip := 0
        stride := w * 4
        DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", w, "int", h, "int", stride, "int", 0x26200A, "ptr", pPixels, "ptr*", &pBitmapGdip)
        if (!pBitmapGdip) {
            DllCall(webpDllName "\WebPFree", "ptr", pPixels)
            return ""
        }

        ; Save as PNG
        pngPath := outputDir "\alttabby-background.png"
        encoderClsid := Buffer(16, 0)
        DllCall("ole32\CLSIDFromString", "str", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "ptr", encoderClsid, "hresult")
        hr := DllCall("gdiplus\GdipSaveImageToFile", "ptr", pBitmapGdip, "str", pngPath, "ptr", encoderClsid, "ptr", 0, "int")

        DllCall("gdiplus\GdipDisposeImage", "ptr", pBitmapGdip)
        DllCall(webpDllName "\WebPFree", "ptr", pPixels)

        if (hr != 0)
            return ""
        return pngPath
    } catch {
        return ""
    }
}

; Browse for a background image file, handle WebP conversion, and copy to resources/.
; Shared by native and WebView2 config editors.
; configIniPath: path to config.ini (used to locate resources/ directory)
; Returns: destination file path, or "" if cancelled/failed
ConfigEditor_BrowseBackgroundImage(configIniPath) {
    filter := "Images (*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tiff;*.webp)"
    selected := FileSelect(1, , "Select Background Image", filter)
    if (selected = "")
        return ""

    ; Determine resources directory (next to config.ini)
    configDir := ""
    if (configIniPath != "")
        SplitPath(configIniPath, , &configDir)
    else if (A_IsCompiled)
        configDir := A_ScriptDir
    else
        configDir := A_ScriptDir "\.."

    resDir := configDir "\resources"
    if (!DirExist(resDir))
        DirCreate(resDir)

    SplitPath(selected, , , &ext)
    ext := StrLower(ext)
    destExt := ext

    ; WebP → PNG conversion (via libwebp — GDI+ WebP support varies by Windows version)
    if (ext = "webp") {
        converted := WebP_ConvertToPNG(selected, resDir)
        if (converted = "") {
            ThemeMsgBox("Failed to convert WebP image. Please select a PNG or JPG instead.", "Conversion Error", "OK Icon!")
            return ""
        }
        destExt := "png"
        destPath := resDir "\alttabby-background." destExt
        ; Remove old background files only AFTER successful conversion
        loop files resDir "\alttabby-background.*"
            if (A_LoopFileFullPath != converted)
                FileDelete(A_LoopFileFullPath)
        if (converted != destPath)
            FileMove(converted, destPath, true)
    } else {
        destPath := resDir "\alttabby-background." destExt
        FileCopy(selected, destPath, true)
        ; Remove stale background files with different extensions
        loop files resDir "\alttabby-background.*"
            if (A_LoopFileFullPath != destPath)
                FileDelete(A_LoopFileFullPath)
    }

    return destPath
}
