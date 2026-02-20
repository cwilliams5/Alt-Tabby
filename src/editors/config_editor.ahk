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
    global gConfigLoaded, cfg

    ; Hide tray icon - only launcher should have one
    A_IconHidden := true

    ; Initialize config system if not already done
    if (!gConfigLoaded)
        ConfigLoader_Init()

    ; Initialize theme system (needs config loaded first)
    Theme_Init()

    ; Respect config setting in addition to command-line flag
    if (cfg.LauncherForceNativeEditor)
        forceNative := true

    ; Try WebView2 first if not forcing native
    if (!forceNative && IsWebView2Available()) {
        try {
            return CE_RunWebView2(launcherHwnd)
        } catch as e {
            ; WebView2 detection succeeded but init failed - fall back to native
            ; This can happen if WebView2 is registered but DLL is missing/corrupt
            if (cfg.DiagWebViewLog) {
                global LOG_PATH_WEBVIEW
                try LogAppend(LOG_PATH_WEBVIEW, "WebView2 init failed, falling back to native: " e.Message)
            }
        }
    }

    ; Use native AHK editor
    return CE_RunNative(launcherHwnd)
}

