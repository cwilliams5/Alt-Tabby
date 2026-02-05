#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals

; ============================================================
; Config Editor Dispatcher
; ============================================================
; Routes to either WebView2 or native AHK editor based on:
; 1. WebView2 runtime availability
; 2. --force-native flag
;
; WebView2 editor provides a modern HTML/JS interface.
; Native editor uses traditional AHK GUI controls.
; Both share the same INI save logic and restart signaling.
; ============================================================

; ============================================================
; PUBLIC API
; ============================================================

; Run the config editor
; launcherHwnd: HWND of launcher process for WM_COPYDATA restart signal (0 = standalone)
; forceNative: true to skip WebView2 and always use native editor
; Returns: true if changes were saved, false otherwise
ConfigEditor_Run(launcherHwnd := 0, forceNative := false) {
    global gConfigLoaded

    ; Hide tray icon - only launcher should have one
    A_IconHidden := true

    ; Initialize config system if not already done
    if (!gConfigLoaded)
        ConfigLoader_Init()

    ; Try WebView2 first if not forcing native
    if (!forceNative && ConfigEditor_IsWebView2Available()) {
        try {
            return _CE_RunWebView2(launcherHwnd)
        } catch as e {
            ; WebView2 detection succeeded but init failed - fall back to native
            ; This can happen if WebView2 is registered but DLL is missing/corrupt
        }
    }

    ; Use native AHK editor
    return _CE_RunNative(launcherHwnd)
}

; Check if WebView2 runtime is installed
; Returns: true if WebView2 Evergreen runtime is available
ConfigEditor_IsWebView2Available() {
    ; WebView2 Evergreen runtime registers under EdgeUpdate\Clients with this GUID
    static GUID := "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"

    ; Check both 32-bit and 64-bit registry locations
    for regKey in ["HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\" GUID,
                   "HKLM\SOFTWARE\Microsoft\EdgeUpdate\Clients\" GUID,
                   "HKCU\SOFTWARE\Microsoft\EdgeUpdate\Clients\" GUID] {
        try {
            ver := RegRead(regKey, "pv")
            if (ver != "")
                return true
        }
    }
    return false
}
