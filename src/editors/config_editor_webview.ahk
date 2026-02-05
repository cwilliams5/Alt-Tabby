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
; 3. EXECUTESCRIPT CORRUPTS MESSAGE HANDLER
;    Calling ExecuteScript() from INSIDE a WebMessageReceived callback corrupts
;    the handler - subsequent messages will never be received. The "ready"
;    message works but button clicks don't.
;    FIX: Use SetTimer(func, -1) to defer ExecuteScript outside the callback.
;
; 4. INLINE EVENT HANDLERS BLOCKED
;    WebView2's Content Security Policy blocks inline onclick="..." attributes.
;    Button clicks silently fail with no error.
;    FIX: Use addEventListener() in JavaScript instead:
;      document.getElementById('btn').addEventListener('click', handler);
;
; ============================================================

; Resource IDs (must match alt_tabby.ahk @Ahk2Exe-AddResource directives)
global CEW_RES_WEBVIEW2_DLL := 20
global CEW_RES_EDITOR_HTML := 25

global gCEW_Gui := 0
global gCEW_Controller := 0
global gCEW_WebView := 0
global gCEW_SavedChanges := false
global gCEW_LauncherHwnd := 0
global gCEW_MessageHandler := 0  ; Must store HANDLER OBJECT to prevent garbage collection
global gCEW_MessageToken := 0    ; Token for removal (optional)

; ============================================================
; PUBLIC API
; ============================================================

; Run the WebView2 config editor
; launcherHwnd: HWND of launcher process for WM_COPYDATA restart signal (0 = standalone)
; Returns: true if changes were saved, false otherwise
_CE_RunWebView2(launcherHwnd := 0) {
    global gCEW_Gui, gCEW_Controller, gCEW_WebView, gCEW_SavedChanges, gCEW_LauncherHwnd
    global gCEW_MessageHandler, gCEW_MessageToken
    global gConfigLoaded, CEW_RES_WEBVIEW2_DLL, CEW_RES_EDITOR_HTML

    gCEW_LauncherHwnd := launcherHwnd
    gCEW_SavedChanges := false

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
            ResourceExtract(CEW_RES_WEBVIEW2_DLL, dllPath)
        ; HTML always extracted (may have updates)
        ResourceExtract(CEW_RES_EDITOR_HTML, htmlPath)
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

    ; Create GUI window
    gCEW_Gui := Gui("+Resize +MinSize600x400", "Alt-Tabby Configuration")
    gCEW_Gui.OnEvent("Close", _CEW_OnClose)
    gCEW_Gui.OnEvent("Size", _CEW_OnSize)
    gCEW_Gui.Show("w900 h650")

    ; Create WebView2 control
    try {
        gCEW_Controller := WebView2.create(gCEW_Gui.Hwnd,,,,,, dllPath)
        gCEW_Controller.Fill()
        gCEW_WebView := gCEW_Controller.CoreWebView2

        ; Register message handler for save/cancel from JS
        ; CRITICAL: Must store the Handler object to prevent GC!
        ; Use raw 3-param handler and manually wrap the args
        gCEW_MessageHandler := WebView2.Handler(_CEW_OnWebMessageRaw, 3)
        gCEW_MessageToken := gCEW_WebView.add_WebMessageReceived(gCEW_MessageHandler)

        ; Navigate to settings page
        gCEW_WebView.Navigate("file:///" StrReplace(htmlPath, "\", "/"))

    } catch as e {
        gCEW_Gui.Destroy()
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
    global gCEW_Controller
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
_CEW_OnWebMessageRaw(this, sender, argsPtr) {
    args := WebView2.WebMessageReceivedEventArgs(argsPtr)
    _CEW_OnWebMessage(sender, args)
}

_CEW_OnWebMessage(sender, args) {
    global gCEW_Gui, gCEW_SavedChanges, gCEW_LauncherHwnd
    global TABBY_CMD_RESTART_ALL, WM_COPYDATA

    ; Parse JSON message from JavaScript
    try {
        msgJson := args.TryGetWebMessageAsString()
        msg := JSON.Load(msgJson)
        action := msg["action"]

        if (action = "save") {
            ; Apply changes to config.ini
            changes := msg["changes"]
            _CEW_ApplyChanges(changes)
            gCEW_SavedChanges := true

            ; Send restart signal to launcher
            if (gCEW_LauncherHwnd && DllCall("user32\IsWindow", "ptr", gCEW_LauncherHwnd)) {
                cds := Buffer(3 * A_PtrSize, 0)
                NumPut("uptr", TABBY_CMD_RESTART_ALL, cds, 0)
                NumPut("uint", 0, cds, A_PtrSize)
                NumPut("ptr", 0, cds, 2 * A_PtrSize)

                DllCall("user32\SendMessageTimeoutW"
                    , "ptr", gCEW_LauncherHwnd
                    , "uint", WM_COPYDATA
                    , "ptr", A_ScriptHwnd
                    , "ptr", cds.Ptr
                    , "uint", 0x0002
                    , "uint", 3000
                    , "ptr*", &response := 0
                    , "ptr")
            }

            gCEW_Gui.Destroy()

        } else if (action = "cancel") {
            gCEW_Gui.Destroy()

        } else if (action = "ready") {
            ; Page loaded - inject config data
            ; IMPORTANT: Use SetTimer to defer ExecuteScript outside this callback.
            ; Calling ExecuteScript from within WebMessageReceived corrupts the handler,
            ; causing subsequent messages to never be received.
            SetTimer(_CEW_InjectConfigData, -1)
        }
    } catch as e {
        ; Log error for debugging
        try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") " WebMessage error: " e.Message "`n", A_Temp "\tabby_webview_debug.log")
    }
}

; ============================================================
; DATA BRIDGE
; ============================================================

_CEW_InjectConfigData() {
    global gCEW_WebView, gConfigRegistry, gConfigIniPath

    ; Serialize registry to JSON
    registryJson := _CEW_SerializeRegistry()

    ; Serialize current values from INI
    valuesJson := _CEW_SerializeCurrentValues()

    ; Inject into page
    script := "initSettings(" registryJson "," valuesJson ")"
    try gCEW_WebView.ExecuteScript(script)
}

_CEW_SerializeRegistry() {
    global gConfigRegistry

    ; Build JSON array of registry entries
    parts := []
    for _, entry in gConfigRegistry {
        obj := "{"
        if (entry.HasOwnProp("type"))
            obj .= '"type":"' entry.type '",'
        if (entry.HasOwnProp("name"))
            obj .= '"name":"' _CEW_EscapeJson(entry.name) '",'
        if (entry.HasOwnProp("desc"))
            obj .= '"desc":"' _CEW_EscapeJson(entry.desc) '",'
        if (entry.HasOwnProp("long"))
            obj .= '"long":"' _CEW_EscapeJson(entry.long) '",'
        if (entry.HasOwnProp("section"))
            obj .= '"section":"' entry.section '",'
        if (entry.HasOwnProp("s"))
            obj .= '"s":"' entry.s '",'
        if (entry.HasOwnProp("k"))
            obj .= '"k":"' entry.k '",'
        if (entry.HasOwnProp("g"))
            obj .= '"g":"' entry.g '",'
        if (entry.HasOwnProp("t"))
            obj .= '"t":"' entry.t '",'
        if (entry.HasOwnProp("d"))
            obj .= '"d":"' _CEW_EscapeJson(entry.d) '",'
        if (entry.HasOwnProp("default")) {
            if (entry.t = "bool")
                obj .= '"default":' (entry.default ? "true" : "false") ','
            else if (entry.t = "int" || entry.t = "float")
                obj .= '"default":' entry.default ','
            else
                obj .= '"default":"' _CEW_EscapeJson(String(entry.default)) '",'
        }
        if (entry.HasOwnProp("options")) {
            obj .= '"options":['
            optParts := []
            for _, opt in entry.options
                optParts.Push('"' _CEW_EscapeJson(opt) '"')
            obj .= _CEW_JoinArray(optParts, ",")
            obj .= '],'
        }
        ; Remove trailing comma and close
        if (SubStr(obj, -1) = ",")
            obj := SubStr(obj, 1, -1)
        obj .= "}"
        parts.Push(obj)
    }
    return "[" _CEW_JoinArray(parts, ",") "]"
}

_CEW_SerializeCurrentValues() {
    global gConfigRegistry, gConfigIniPath

    parts := []
    for _, entry in gConfigRegistry {
        if (!entry.HasOwnProp("default"))
            continue

        iniVal := IniRead(gConfigIniPath, entry.s, entry.k, "")
        if (iniVal = "")
            val := entry.default
        else
            val := _CEW_ParseValue(iniVal, entry.t)

        if (entry.t = "bool")
            parts.Push('"' entry.g '":' (val ? "true" : "false"))
        else if (entry.t = "int" || entry.t = "float")
            parts.Push('"' entry.g '":' val)
        else
            parts.Push('"' entry.g '":"' _CEW_EscapeJson(String(val)) '"')
    }
    return "{" _CEW_JoinArray(parts, ",") "}"
}

_CEW_ParseValue(iniVal, type) {
    switch type {
        case "bool":
            return (iniVal = "true" || iniVal = "1" || iniVal = "yes")
        case "int":
            if (SubStr(iniVal, 1, 2) = "0x")
                return Integer(iniVal)
            return Integer(iniVal)
        case "float":
            return Float(iniVal)
        default:
            return iniVal
    }
}

_CEW_ApplyChanges(changes) {
    global gConfigRegistry, gConfigIniPath

    for _, entry in gConfigRegistry {
        if (!entry.HasOwnProp("default"))
            continue

        if (!changes.Has(entry.g))
            continue

        newVal := changes[entry.g]
        _CL_WriteIniPreserveFormat(gConfigIniPath, entry.s, entry.k, newVal, entry.default, entry.t)
    }
}

_CEW_EscapeJson(str) {
    str := StrReplace(str, "\", "\\")
    str := StrReplace(str, '"', '\"')
    str := StrReplace(str, "`n", "\n")
    str := StrReplace(str, "`r", "\r")
    str := StrReplace(str, "`t", "\t")
    return str
}

_CEW_JoinArray(arr, sep) {
    result := ""
    for i, item in arr {
        if (i > 1)
            result .= sep
        result .= item
    }
    return result
}

