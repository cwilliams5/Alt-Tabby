#Requires AutoHotkey v2.0
#SingleInstance Force

#Include %A_ScriptDir%\lib\WebView2.ahk

global gGui, gController, gWebView, gHandler, gToken

gGui := Gui("+Resize", "WebView2 Test")
gGui.OnEvent("Close", (*) => ExitApp())
gGui.Show("w600 h400")

dllPath := A_ScriptDir "\WebView2Loader.dll"
if (!FileExist(dllPath)) {
    FileCopy(A_ScriptDir "WebView2Loader.dll", dllPath)
}

; HTML content inline - avoids .txt extension issue
htmlContent := '
(
<!DOCTYPE html>
<html>
<head><title>WebView2 Test</title></head>
<body style="background:#1a1b26;color:#fff;font-family:sans-serif;padding:20px;">
<h1>WebView2 Message Test</h1>
<p id="status">Waiting...</p>
<button id="testBtn" style="padding:10px 20px;font-size:16px;">Send Test Message</button>
<script>
document.addEventListener("DOMContentLoaded", function() {
  document.getElementById("status").textContent = "DOM loaded, sending ready...";
  window.chrome.webview.postMessage("ready");
  document.getElementById("status").textContent = "Ready sent!";

  document.getElementById("testBtn").addEventListener("click", function() {
    document.getElementById("status").textContent = "Sending test...";
    window.chrome.webview.postMessage("button_clicked");
    document.getElementById("status").textContent = "Test sent!";
  });
});
</script>
</body>
</html>
)'

try {
    gController := WebView2.create(gGui.Hwnd,,,,,, dllPath)
    gController.Fill()
    gWebView := gController.CoreWebView2

    ; Register message handler - store the handler object to prevent GC
    gHandler := WebView2.Handler(RawOnMessage, 3)
    gToken := gWebView.add_WebMessageReceived(gHandler)
    ToolTip("Handler registered, token: " gToken)
    SetTimer(() => ToolTip(), -2000)

    ; Use NavigateToString to load HTML directly (avoids file extension issues)
    gWebView.NavigateToString(htmlContent)
} catch as e {
    MsgBox("Error: " e.Message "`n" e.Stack)
    ExitApp()
}

; Raw handler receives 3 params: handler ptr, sender ptr, args ptr
RawOnMessage(this, sender, args) {
    argsObj := WebView2.WebMessageReceivedEventArgs(args)
    msg := argsObj.TryGetWebMessageAsString()
    MsgBox("Received: " msg)
}
