#Requires AutoHotkey v2.0

; ============================================================
; Resource Utilities - Extract embedded exe resources
; ============================================================

global RT_RCDATA := 10

; Embedded resource IDs (must match @Ahk2Exe-AddResource directives in compile.ps1)
global RES_ID_LOGO := 10           ; logo.png
global RES_ID_ICON := 11           ; icon.png
global RES_ID_ANIMATION := 15      ; animation.webp
global RES_ID_SHARPYUV_DLL := 16   ; libsharpyuv-0.dll
global RES_ID_WEBP_DLL := 17       ; libwebp-7.dll
global RES_ID_DEMUX_DLL := 18      ; libwebpdemux-2.dll
global RES_ID_WEBVIEW2_DLL := 20   ; WebView2Loader.dll
global RES_ID_EDITOR_HTML := 25    ; config_editor.txt (HTML content)

; WebView2 Evergreen runtime GUID (shared by all editors)
global WEBVIEW2_EVERGREEN_GUID := "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"

; Extract an embedded resource to a file
; resourceId: Resource ID from @Ahk2Exe-AddResource directive
; destPath: Full path to write the extracted file
; Returns: true on success, throws on failure
ResourceExtract(resourceId, destPath) {
    global RT_RCDATA

    hRes := DllCall("FindResource", "ptr", 0, "int", resourceId, "int", RT_RCDATA, "ptr")
    if (!hRes)
        throw Error("Resource " resourceId " not found")

    resSize := DllCall("SizeofResource", "ptr", 0, "ptr", hRes, "uint")
    hMem := DllCall("LoadResource", "ptr", 0, "ptr", hRes, "ptr")
    if (!hMem || !resSize)
        throw Error("Failed to load resource " resourceId)

    pData := DllCall("LockResource", "ptr", hMem, "ptr")
    if (!pData)
        throw Error("Failed to lock resource " resourceId)

    buf := Buffer(resSize, 0)
    DllCall("RtlMoveMemory", "ptr", buf.Ptr, "ptr", pData, "uptr", resSize)

    f := FileOpen(destPath, "w")
    try
        f.RawWrite(buf)
    finally
        f.Close()

    return true
}

; Extract resource to temp directory with specified filename
; resourceId: Resource ID from @Ahk2Exe-AddResource directive
; fileName: Name for the extracted file
; destDir: Directory to extract to (default: A_Temp)
; Returns: Full path on success, empty string on failure
ResourceExtractToTemp(resourceId, fileName, destDir := "") {
    if (destDir = "")
        destDir := A_Temp

    destPath := destDir "\" fileName
    try {
        ResourceExtract(resourceId, destPath)
        return destPath
    } catch {
        return ""
    }
}

; Check if WebView2 Evergreen runtime is installed
; Returns: true if WebView2 runtime is available
IsWebView2Available() {
    global WEBVIEW2_EVERGREEN_GUID
    for regKey in ["HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\" WEBVIEW2_EVERGREEN_GUID,
                   "HKLM\SOFTWARE\Microsoft\EdgeUpdate\Clients\" WEBVIEW2_EVERGREEN_GUID,
                   "HKCU\SOFTWARE\Microsoft\EdgeUpdate\Clients\" WEBVIEW2_EVERGREEN_GUID] {
        try {
            ver := RegRead(regKey, "pv")
            if (ver != "")
                return true
        }
    }
    return false
}
