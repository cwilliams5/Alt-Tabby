#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals

; ============================================================
; Config Editor WebView2 - HTML/JS based settings UI
; ============================================================
; Called by config_editor.ahk dispatcher when WebView2 runtime is available.
; Uses Microsoft Edge WebView2 for modern, styled settings interface.
;
; Resources embedded via @Ahk2Exe-AddResource in alt_tabby.ahk:
;   ID 20 = WebView2Loader.dll
;   ID 25 = config_editor.txt (HTML content)
;
; ============================================================
; WEBVIEW2 LESSONS LEARNED (hard-won knowledge)
; ============================================================
;
; 1. HTML FILE EXTENSION FOR COMPILATION
;    Ahk2Exe silently fails to embed .html files due to RT_HTML resource type
;    attempting to dereference CSS % values. Use .txt extension for HTML content
;    embedded via @Ahk2Exe-AddResource. The file is copied to .html at runtime.
;
; 2. HANDLER GARBAGE COLLECTION
;    The wrapper returned by add_WebMessageReceived() creates a TypedHandler
;    internally that gets garbage collected if not stored. You MUST:
;    - Use WebView2.Handler(callback, 3) to create a raw handler
;    - Store the handler object in a global variable (not just the token)
;    - Use a 3-param callback: (this, sender, argsPtr)
;    - Manually wrap args: WebView2.WebMessageReceivedEventArgs(argsPtr)
;
; 3. WIN32 CALLS INSIDE CALLBACK CORRUPT MESSAGE HANDLER
;    Calling ExecuteScript() or GUI Show() from INSIDE a WebMessageReceived
;    callback corrupts the handler - subsequent messages will never be received.
;    Any Win32 call that pumps messages has this effect.
;    FIX: Use SetTimer(func, -1) to defer ALL work outside the callback.
;
; 4. INLINE EVENT HANDLERS BLOCKED
;    WebView2's Content Security Policy blocks inline onclick="..." attributes.
;    Button clicks silently fail with no error.
;    FIX: Use addEventListener() in JavaScript instead:
;      document.getElementById('btn').addEventListener('click', handler);
;
; 5. DWM CLOAKING + WEBVIEW2: DEFERRED CLOAK PATTERN
;    DWM cloaking (DWMWA_CLOAK=13) is the gold standard for preventing white
;    flash — used by Chrome/Firefox. But WebView2.create() on a cloaked window
;    crashes silently (needs DWM composition to initialize).
;
;    SOLUTION: Three-phase deferred cloaking:
;      Phase 1 (Prepare): Cloak + WS_EX_LAYERED alpha=0 + off-screen (-32000).
;        Cloaking prevents DWM from compositing the frame during Show().
;      Phase 2 (Init): Uncloak right BEFORE WebView2.create(). Window is still
;        alpha=0 and off-screen, so uncloaking is invisible. WebView2 gets the
;        DWM composition it needs. Off-screen is defense-in-depth: if DWM
;        frame leaks through alpha=0 during init, it leaks at -32000.
;      Phase 3 (Reveal): Re-cloak, center via raw Win32, set alpha=255, uncloak,
;        remove WS_EX_LAYERED. Window appears fully rendered in a single frame.
;
;    Why keep off-screen if we cloak? Between uncloak (Phase 2) and re-cloak
;    (Phase 3), the window is uncloaked while WebView2 initializes. Only alpha=0
;    hides it during this gap. Alpha=0 USUALLY hides the frame but can
;    intermittently leak (DWM race). Off-screen ensures any leak is invisible.
;
;    See _GUI_AntiFlashPrepare/Reveal() in gui_antiflash.ahk.
;
; 6. OFF-SCREEN CENTERING REQUIRES RAW WIN32
;    AHK v2's Gui.Move() applies DPI scaling on coordinates. When a window
;    is off-screen at x=-32000 and you compute center via MonitorGetWorkArea
;    or A_ScreenWidth, the DPI double-scaling puts it in the wrong position.
;    FIX: Use GetMonitorInfoW + GetWindowRect + SetWindowPos — all in physical
;    pixels, bypassing AHK's DPI layer. See GUI_AntiFlashReveal() in
;    gui_antiflash.ahk.
;
; ============================================================

global gCEW_Gui := 0
global gCEW_Controller := 0
global gCEW_WebView := 0
global gCEW_SavedChanges := false
global gCEW_HasChanges := false
global gCEW_LauncherHwnd := 0  ; lint-ignore: dead-global  ; Set by init, consumed by alt_tabby.ahk exit handler
global gCEW_MessageHandler := 0  ; Must store HANDLER OBJECT to prevent garbage collection

; ============================================================
; PUBLIC API
; ============================================================

; Run the WebView2 config editor
; launcherHwnd: HWND of launcher process for WM_COPYDATA restart signal (0 = standalone)
; Returns: true if changes were saved, false otherwise
CE_RunWebView2(launcherHwnd := 0) {
    global gCEW_Gui, gCEW_Controller, gCEW_WebView, gCEW_SavedChanges, gCEW_HasChanges, gCEW_LauncherHwnd
    global gCEW_MessageHandler
    global gConfigLoaded, RES_ID_WEBVIEW2_DLL, RES_ID_EDITOR_HTML

    gCEW_LauncherHwnd := launcherHwnd
    gCEW_SavedChanges := false
    gCEW_HasChanges := false

    ; Initialize config system if not already done
    if (!gConfigLoaded)
        ConfigLoader_Init()

    ; Extract DLL and HTML from embedded resources (compiled) or copy from source (dev)
    dllPath := A_Temp "\AltTabby_WebView2Loader.dll"
    htmlPath := A_Temp "\AltTabby_settings.html"

    if (A_IsCompiled) {
        ; Extract DLL if missing or corrupt
        dllSize := FileExist(dllPath) ? FileGetSize(dllPath) : 0
        if (dllSize < 1000)
            ResourceExtract(RES_ID_WEBVIEW2_DLL, dllPath)
        ; HTML always extracted (may have updates)
        ResourceExtract(RES_ID_EDITOR_HTML, htmlPath)
    } else {
        ; Dev mode: copy from source
        srcDll := A_ScriptDir "\..\resources\dll\WebView2Loader.dll"
        srcHtml := A_ScriptDir "\..\resources\html\config_editor.txt"
        dllSize := FileExist(dllPath) ? FileGetSize(dllPath) : 0
        if (dllSize < 1000 && FileExist(srcDll))
            FileCopy(srcDll, dllPath, true)
        if (FileExist(srcHtml))
            FileCopy(srcHtml, htmlPath, true)
    }

    ; Verify files exist
    if (!FileExist(dllPath) || !FileExist(htmlPath))
        throw Error("WebView2 resources not found")

    ; Anti-flash: cloaked + off-screen + alpha=0. Show("Hide") does NOT work —
    ; WebView2 needs a visible parent to render. Cloak covers the Show() to prevent
    ; frame flash, then we uncloak before WebView2.create() (needs DWM composition).
    gCEW_Gui := Gui("+Resize +MinSize600x400", "Alt-Tabby Configuration")
    gCEW_Gui.OnEvent("Close", _CEW_OnClose)
    gCEW_Gui.OnEvent("Size", _CEW_OnSize)
    Theme_ApplyToGui(gCEW_Gui)
    GUI_AntiFlashPrepare(gCEW_Gui, Theme_GetBgColor())
    gCEW_Gui.Show("x-32000 y-32000 w900 h650")

    ; Safety: reveal after 3s even if "ready" never fires (WebView2 error, etc.)
    SetTimer(_CEW_ForceReveal, -3000)

    ; Create WebView2 control
    ; Uncloak first — WebView2 needs DWM composition to initialize (lesson #5).
    ; Window is still alpha=0 and off-screen, so uncloaking is invisible to user.
    global DWMWA_CLOAK
    DllCall("dwmapi\DwmSetWindowAttribute", "ptr", gCEW_Gui.Hwnd, "uint", DWMWA_CLOAK, "int*", 0, "uint", 4)
    try {
        gCEW_Controller := WebView2.create(gCEW_Gui.Hwnd,,,,,, dllPath)

        ; Set WebView2 default background to match theme BEFORE navigation.
        try gCEW_Controller.DefaultBackgroundColor := Theme_GetWebViewBgColor()

        gCEW_Controller.Fill()
        gCEW_WebView := gCEW_Controller.CoreWebView2

        ; Register message handler for save/cancel from JS
        ; CRITICAL: Must store the Handler object to prevent GC!
        ; Use raw 3-param handler and manually wrap the args
        gCEW_MessageHandler := WebView2.Handler(_CEW_OnWebMessageRaw, 3)
        gCEW_WebView.add_WebMessageReceived(gCEW_MessageHandler)

        ; Navigate to settings page
        gCEW_WebView.Navigate("file:///" StrReplace(htmlPath, "\", "/"))

    } catch as e {
        try Theme_UntrackGui(gCEW_Gui)
        try gCEW_Gui.Destroy()
        throw Error("Failed to create WebView2: " e.Message)
    }

    ; Block until GUI closes
    WinWaitClose(gCEW_Gui.Hwnd)

    return gCEW_SavedChanges
}

; ============================================================
; EVENT HANDLERS
; ============================================================

_CEW_OnClose(guiObj) {
    global gCEW_Controller, gCEW_HasChanges
    ; Warn about unsaved changes (matches native editor behavior)
    if (gCEW_HasChanges) {
        result := ThemeMsgBox("You have unsaved changes. Save before closing?", "Alt-Tabby Configuration", "YesNoCancel Icon?")
        if (result = "Cancel")
            return true  ; Prevent close
        if (result = "Yes") {
            ; Request save from JS, then close
            SetTimer(_CEW_SaveAndClose, -1)
            return true  ; Block this close, _CEW_SaveAndClose will destroy
        }
    }
    ; Clean up WebView2
    if (gCEW_Controller) {
        try gCEW_Controller := 0
    }
    return false  ; Allow close
}

_CEW_OnSize(guiObj, minMax, width, height) {
    global gCEW_Controller
    if (minMax = -1)  ; Minimized
        return
    ; Resize WebView2 to fill window
    if (gCEW_Controller) {
        try gCEW_Controller.Fill()
    }
}

; Raw 3-param handler wrapper - manually wraps args pointer
_CEW_OnWebMessageRaw(this, sender, argsPtr) { ; lint-ignore: dead-param
    args := WebView2.WebMessageReceivedEventArgs(argsPtr)
    _CEW_OnWebMessage(sender, args)
}

_CEW_OnWebMessage(sender, args) { ; lint-ignore: dead-param
    global gCEW_Gui, gCEW_SavedChanges, gCEW_HasChanges, gCEW_LauncherHwnd
    global cfg, LOG_PATH_WEBVIEW, LOG_PATH_STORE

    ; Parse JSON message from JavaScript
    try {
        msgJson := args.TryGetWebMessageAsString()
        msg := JSON.Load(msgJson)
        action := msg["action"]

        if (action = "save") {
            ; Apply changes to config.ini
            changes := msg["changes"]
            _CEW_ApplyChanges(changes)

            ; Delete removed array sections (text-based: removes headers + comments + all occurrences)
            if (msg.Has("deleteSections")) {
                delNames := []
                for _, sectionName in msg["deleteSections"]
                    delNames.Push(sectionName)
                if (delNames.Length > 0)
                    CL_DeleteSections(delNames)
            }

            gCEW_SavedChanges := true

            try Theme_UntrackGui(gCEW_Gui)
            gCEW_Gui.Destroy()

        } else if (action = "cancel") {
            try Theme_UntrackGui(gCEW_Gui)
            gCEW_Gui.Destroy()

        } else if (action = "dirty") {
            ; Track dirty state for X-button close handler
            gCEW_HasChanges := msg["hasChanges"]

        } else if (action = "browse") {
            ; File browse — defer out of callback (Lesson #3)
            globalName := msg["globalName"]
            SetTimer(() => _CEW_OnFileBrowse(globalName), -1)

        } else if (action = "ready") {
            ; Page loaded - dark CSS painted, safe to reveal and inject data.
            ; IMPORTANT: Defer EVERYTHING out of this callback via SetTimer.
            ; Lesson #3: ExecuteScript inside callback corrupts the handler.
            ; Same applies to GUI Show() — any Win32 call that pumps messages
            ; from inside WebMessageReceived can corrupt the handler.
            SetTimer(_CEW_OnReady, -1)
        }
    } catch as e {
        ; Log error for debugging — include truncated raw JSON for context
        if (cfg.DiagWebViewLog) {
            detail := IsSet(msgJson) ? " json=" SubStr(msgJson, 1, 200) : ""
            try LogAppend(LOG_PATH_WEBVIEW, "WebMessage error: " e.Message detail)
        }
        try LogAppend(LOG_PATH_STORE, "WebMessage error: " e.Message)
    }
}

; ============================================================
; DATA BRIDGE
; ============================================================

_CEW_InjectConfigData() {
    global gCEW_WebView, gConfigRegistry, gConfigIniPath

    ; Serialize registry to JSON (shared helper in config_registry.ahk)
    registryJson := ConfigRegistry_SerializeToJSON()

    ; Serialize current values from INI
    valuesJson := _CEW_SerializeCurrentValues()

    ; Inject into page
    script := "initSettings(" registryJson "," valuesJson ")"
    try gCEW_WebView.ExecuteScript(script)
}

_CEW_SerializeCurrentValues() {
    global gConfigRegistry, gConfigIniPath

    ; Pre-scan for array_section counts + detect actual layers from INI
    arraySections := Map()
    for _, entry in gConfigRegistry {
        if (entry.HasOwnProp("type") && entry.type = "section" && entry.HasOwnProp("array_section"))
            arraySections[entry.name] := entry.array_section
    }

    ; Detect actual layer count from INI for each array section
    actualLayerCounts := Map()
    for sectionName, maxCount in arraySections {
        actualCount := 0
        Loop maxCount {
            try {
                sectionKeys := IniRead(gConfigIniPath, sectionName "." A_Index)
                if (sectionKeys != "")
                    actualCount := A_Index
            }
        }
        actualLayerCounts[sectionName] := Max(1, actualCount)
    }

    values := Map()

    ; Pass active layer counts to JS as metadata
    for sectionName, count in actualLayerCounts
        values["_activeLayerCount_" sectionName] := count

    for _, entry in gConfigRegistry {
        if (!entry.HasOwnProp("default"))
            continue

        if (InStr(entry.g, "{N}")) {
            ; Array section — serialize only active layers
            count := actualLayerCounts.Has(entry.s) ? actualLayerCounts[entry.s] : 1
            Loop count {
                expandedG := StrReplace(entry.g, "{N}", A_Index)
                sectionName := entry.s "." A_Index
                iniVal := IniRead(gConfigIniPath, sectionName, entry.k, "")
                if (iniVal = "")
                    val := (A_Index = 1 && entry.HasOwnProp("default1")) ? entry.default1 : entry.default
                else
                    val := CL_ParseValue(iniVal, entry.t)
                values[expandedG] := val
            }
        } else {
            iniVal := IniRead(gConfigIniPath, entry.s, entry.k, "")
            if (iniVal = "")
                val := entry.default
            else
                val := CL_ParseValue(iniVal, entry.t)
            values[entry.g] := val
        }
    }
    return JSON.Dump(values)
}

_CEW_ApplyChanges(changes) {
    result := CL_SaveChanges(changes)
    if (result.failed > 0 && result.saved = 0)
        ThemeMsgBox("Could not save settings — the config file may be`nread-only, locked, or on a full disk.", "Alt-Tabby Configuration", "Iconx")
    else if (result.failed > 0)
        ThemeMsgBox(result.saved " saved, " result.failed " failed to write.", "Alt-Tabby Configuration", "Icon!")
}

; ============================================================
; WINDOW REVEAL (anti-flash)
; ============================================================

; Deferred handler for "ready" — runs outside the WebMessageReceived callback
_CEW_OnReady() {
    global gCEW_WebView

    ; Inject palette and data BEFORE reveal (window still hidden at alpha=0, off-screen)
    try gCEW_WebView.ExecuteScript(Theme_GetWebViewJS())
    _CEW_InjectConfigData()

    ; NOW reveal the fully-styled window
    _CEW_RevealWindow()

    ; Listen for live theme changes
    Theme_OnChange(_CEW_OnThemeChange)
}

_CEW_OnThemeChange() {
    global gCEW_WebView
    if (!gCEW_WebView)
        return
    try gCEW_WebView.ExecuteScript(Theme_GetWebViewJS())
}

_CEW_RevealWindow() {
    global gCEW_Gui
    if (!gCEW_Gui)
        return
    try {
        SetTimer(_CEW_ForceReveal, 0)  ; Cancel safety timer
        GUI_AntiFlashReveal(gCEW_Gui, false, true)
    }
}

_CEW_ForceReveal() {
    _CEW_RevealWindow()
}

; ============================================================
; FILE BROWSE
; ============================================================

_CEW_OnFileBrowse(globalName) {
    global gCEW_WebView, gConfigIniPath

    filter := "Images (*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tiff;*.webp)"
    selected := FileSelect(1, , "Select Background Image", filter)
    if (selected = "")
        return

    ; Determine resources directory (next to config.ini)
    configDir := ""
    if (gConfigIniPath != "")
        SplitPath(gConfigIniPath, , &configDir)
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
        converted := _CEW_ConvertWebPToPNG(selected, resDir)
        if (converted = "") {
            ThemeMsgBox("Failed to convert WebP image. Please select a PNG or JPG instead.", "Conversion Error", "OK Icon!")
            return
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

    ; Send path back to JS
    escaped := StrReplace(StrReplace(destPath, "\", "\\"), "'", "\'")
    try gCEW_WebView.ExecuteScript("setFilePath('" globalName "','" escaped "')")
}

_CEW_ConvertWebPToPNG(webpPath, outputDir) {
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

; Trigger JS save (which posts "save" message back, applying changes and destroying GUI)
_CEW_SaveAndClose() {
    global gCEW_WebView
    if (gCEW_WebView)
        try gCEW_WebView.ExecuteScript("saveChanges()")
}

