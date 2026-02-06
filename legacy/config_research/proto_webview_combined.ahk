#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
; Prototype: WebView2 Settings Editor
; Embeds the HTML settings page inside a native AHK GUI window
;
; Requirements (all in temp/):
;   - lib/WebView2.ahk (thqby's WebView2 wrapper)
;   - WebView2Loader.dll (from NuGet package)
;   - proto_webview.html (the settings UI)
;   - Edge WebView2 Runtime (pre-installed on Win10 21H2+ / Win11)
; ============================================================

#Include %A_ScriptDir%\lib\WebView2.ahk

; ---- Globals ----
global gGui := ""
global gController := ""
global gWebView := ""
global gHandler := ""  ; MUST store to prevent GC

; ---- Create GUI Window ----
gGui := Gui("+Resize +MinSize600x400", "Alt-Tabby Settings (WebView2 Prototype)")
gGui.BackColor := "1a1b26"
gGui.MarginX := 0
gGui.MarginY := 0
gGui.OnEvent("Close", _OnClose)
gGui.OnEvent("Size", _OnResize)
gGui.Show("w900 h650")

; ---- Initialize WebView2 ----
dllPath := A_ScriptDir "\WebView2Loader.dll"
if (!FileExist(dllPath)) {
    MsgBox("WebView2Loader.dll not found in:`n" A_ScriptDir
        "`n`nRun the setup or copy the DLL here.")
    ExitApp()
}

htmlFile := A_ScriptDir "\proto_webview.html"
if (!FileExist(htmlFile)) {
    MsgBox("proto_webview.html not found in:`n" A_ScriptDir)
    ExitApp()
}

try {
    ; Create WebView2 controller (synchronous - blocks until ready)
    ; Use defaults for everything except the DLL path
    gController := WebView2.create(gGui.Hwnd,,,,,, dllPath)

    ; Size to fill the window
    gController.Fill()

    ; Get the core WebView2 interface
    gWebView := gController.CoreWebView2

    ; Register message handler - MUST store Handler object to prevent GC
    gHandler := WebView2.Handler(OnWebMessage, 3)
    token := gWebView.add_WebMessageReceived(gHandler)
    ToolTip("Handler registered, token: " token)
    SetTimer(() => ToolTip(), -2000)

    ; Navigate to the HTML file
    htmlPath := StrReplace(htmlFile, "\", "/")
    gWebView.Navigate("file:///" htmlPath)

} catch as e {
    MsgBox("WebView2 initialization failed:`n`n" e.Message
        "`n`nEnsure:`n1. WebView2Loader.dll (x64) is in " A_ScriptDir
        "`n2. Microsoft Edge WebView2 Runtime is installed"
        "`n3. You're running 64-bit AutoHotkey")
    ExitApp()
}

; ---- Event Handlers ----
_OnResize(gui, minMax, w, h) {
    global gController
    if (minMax != -1 && gController != "")
        gController.Fill()
}

_OnClose(*) {
    global gController
    if (gController != "") {
        gController.Close()
        gController := ""
    }
    ExitApp()
}

; ---- WebView2 Message Handler ----
; Raw 3-param handler: (this, sender, argsPtr)
OnWebMessage(this, sender, argsPtr) {
    args := WebView2.WebMessageReceivedEventArgs(argsPtr)
    msg := args.TryGetWebMessageAsString()
    MsgBox("Received from JS:`n" msg)
}
