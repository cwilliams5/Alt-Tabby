#Requires AutoHotkey v2.0

; Send a WM_COPYDATA command to a target window (launcher/gui).
; Uses DllCall to bypass DetectHiddenWindows.
; Returns true if message was sent, false if target window is invalid.
IPC_SendWmCopyData(targetHwnd, cmdCode) {
    global WM_COPYDATA
    if (!targetHwnd || !DllCall("user32\IsWindow", "ptr", targetHwnd, "int"))
        return false
    cds := Buffer(A_PtrSize * 3, 0)
    NumPut("uptr", cmdCode, cds, 0)
    NumPut("uptr", 0, cds, A_PtrSize)
    NumPut("uptr", 0, cds, A_PtrSize * 2)
    DllCall("user32\SendMessageTimeoutW"
        , "ptr", targetHwnd
        , "uint", WM_COPYDATA
        , "ptr", A_ScriptHwnd
        , "ptr", cds.Ptr
        , "uint", 0x0002   ; SMTO_ABORTIFHUNG
        , "uint", 3000
        , "ptr*", &_ := 0
        , "ptr")
    return true
}
