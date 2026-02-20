#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn VarUnset, Off

; ============================================================
; Config Registry Editor - Standalone Dev Tool
; ============================================================
; Visual editor for config_registry.ahk definitions.
; NOT part of Alt-Tabby runtime - just a developer tool.
;
; Usage: AutoHotkey64.exe config_registry_editor.ahk
; ============================================================

; Third-party libraries
#Include %A_ScriptDir%\..\lib\
#Include cjson.ahk
#Include WebView2.ahk

; Config registry (read-only, provides gConfigRegistry)
#Include %A_ScriptDir%\..\shared\
#Include config_registry.ahk
#Include config_loader.ahk
#Include resource_utils.ahk
#Include theme.ahk
#Include theme_msgbox.ahk
#Include gui_antiflash.ahk

; Anti-flash constants (DWMWA_CLOAK, WS_EX_LAYERED, etc.)
#Include %A_ScriptDir%\..\gui\
#Include gui_constants.ahk

global gCRE_Gui := 0
global gCRE_Controller := 0
global gCRE_WebView := 0
global gCRE_MsgHandler := 0
global gCRE_RegistryPath := A_ScriptDir "\..\shared\config_registry.ahk"

A_IconHidden := true
ConfigLoader_Init()
Theme_Init()
_CRE_Main()

_CRE_Main() {
    global gCRE_Gui, gCRE_Controller, gCRE_WebView, gCRE_MsgHandler

    ; Verify WebView2 runtime
    if (!IsWebView2Available()) {
        ThemeMsgBox("WebView2 runtime is not installed.`nInstall Microsoft Edge WebView2 Runtime to use this editor.", "Error", "Iconx")
        ExitApp()
    }

    dllPath := A_ScriptDir "\..\..\resources\dll\WebView2Loader.dll"
    htmlPath := A_ScriptDir "\config_registry_editor.html"

    if (!FileExist(dllPath)) {
        ThemeMsgBox("A required file (WebView2Loader.dll) is missing from the resources folder.", "Error", "Iconx")
        ExitApp()
    }
    if (!FileExist(htmlPath)) {
        ThemeMsgBox("A required file (config_registry_editor.html) is missing from the editors folder.", "Error", "Iconx")
        ExitApp()
    }

    ; Create GUI
    gCRE_Gui := Gui("+Resize +MinSize900x600", "Config Registry Editor")
    gCRE_Gui.OnEvent("Close", _CRE_OnClose)
    gCRE_Gui.OnEvent("Size", _CRE_OnSize)
    gCRE_Gui.BackColor := "202020"
    gCRE_Gui.Show("w1300 h850")

    ; Create WebView2
    gCRE_Controller := WebView2.create(gCRE_Gui.Hwnd,,,,,, dllPath)
    gCRE_Controller.Fill()
    gCRE_WebView := gCRE_Controller.CoreWebView2

    ; Register message handler (must store reference to prevent GC)
    gCRE_MsgHandler := WebView2.Handler(_CRE_OnMessageRaw, 3)
    gCRE_WebView.add_WebMessageReceived(gCRE_MsgHandler)

    ; Navigate to editor HTML
    gCRE_WebView.Navigate("file:///" StrReplace(htmlPath, "\", "/"))
}

; ============================================================
; Event Handlers
; ============================================================

_CRE_OnClose(*) {
    global gCRE_Controller
    if (gCRE_Controller)
        try gCRE_Controller := 0
    ExitApp()
}

_CRE_OnSize(guiObj, minMax, width, height) { ; lint-ignore: dead-param
    global gCRE_Controller
    if (minMax != -1 && gCRE_Controller)
        try gCRE_Controller.Fill()
}

_CRE_OnMessageRaw(this, sender, argsPtr) { ; lint-ignore: dead-param
    args := WebView2.WebMessageReceivedEventArgs(argsPtr)
    _CRE_OnWebMessage(sender, args)
}

_CRE_OnWebMessage(sender, args) { ; lint-ignore: dead-param
    try {
        msgJson := args.TryGetWebMessageAsString()
        msg := JSON.Load(msgJson)
        action := msg["action"]

        if (action = "ready")
            SetTimer(_CRE_InjectData, -1)
        else if (action = "save")
            SetTimer(_CRE_SaveRegistry.Bind(msg["source"]), -1)
    } catch as e {
        ThemeMsgBox("Could not process a message from the editor.`n`nDetails: " e.Message, "Error", "Iconx")
    }
}

; ============================================================
; Data Bridge
; ============================================================

_CRE_InjectData() {
    global gCRE_WebView, gConfigRegistry
    json := _CRE_SerializeRegistry()
    script := "loadRegistry(" json ")"
    try gCRE_WebView.ExecuteScript(script)
}

_CRE_SerializeRegistry() {
    global gConfigRegistry

    parts := []
    for _, entry in gConfigRegistry {
        obj := "{"

        ; String-valued properties
        for prop in ["type", "name", "desc", "long", "section", "s", "k", "g", "t", "d", "fmt"] {
            if (entry.HasOwnProp(prop))
                obj .= '"' prop '":' _CRE_JsonStr(entry.%prop%) ','
        }

        ; Default value (type-aware serialization)
        if (entry.HasOwnProp("default")) {
            if (entry.t = "bool")
                obj .= '"default":' (entry.default ? "true" : "false") ','
            else if (entry.t = "int" || entry.t = "float")
                obj .= '"default":' entry.default ','
            else
                obj .= '"default":' _CRE_JsonStr(String(entry.default)) ','
        }

        ; Min/Max constraints
        if (entry.HasOwnProp("min"))
            obj .= '"min":' entry.min ',"max":' entry.max ','

        ; Enum options
        if (entry.HasOwnProp("options")) {
            opts := []
            for _, o in entry.options
                opts.Push(_CRE_JsonStr(o))
            obj .= '"options":[' _CRE_JoinArr(opts, ",") '],'
        }

        ; Close object
        if (SubStr(obj, -1) = ",")
            obj := SubStr(obj, 1, -1)
        obj .= "}"
        parts.Push(obj)
    }
    return "[" _CRE_JoinArr(parts, ",") "]"
}

_CRE_SaveRegistry(source) {
    global gCRE_RegistryPath

    ; Backup existing file
    backupPath := gCRE_RegistryPath ".bak"
    try FileCopy(gCRE_RegistryPath, backupPath, true)

    ; Write new source
    try {
        f := FileOpen(gCRE_RegistryPath, "w", "UTF-8-RAW")
        f.Write(source)
        f.Close()
        ThemeMsgBox("Registry saved successfully.`n`nA backup was created at:`n" backupPath, "Saved", "Iconi")
    } catch as e {
        ThemeMsgBox("Could not save the registry file. It may be read-only or locked.`n`nDetails: " e.Message, "Error", "Iconx")
    }
}

; ============================================================
; JSON Helpers
; ============================================================

_CRE_JsonStr(v) {
    s := String(v)
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`t", "\t")
    return '"' s '"'
}

_CRE_JoinArr(arr, sep) {
    r := ""
    for i, v in arr {
        if (i > 1)
            r .= sep
        r .= v
    }
    return r
}
