#Requires AutoHotkey v2.0

; WM_COPYDATA constants
global IPC_SMTO_ABORTIFHUNG := 0x0002
global IPC_WM_SEND_TIMEOUT_MS := 3000

; Send a WM_COPYDATA command to a target window (launcher/gui).
; Uses DllCall to bypass DetectHiddenWindows.
; Returns true if message was sent, false if target window is invalid.
IPC_SendWmCopyData(targetHwnd, cmdCode) {
    global WM_COPYDATA, IPC_SMTO_ABORTIFHUNG, IPC_WM_SEND_TIMEOUT_MS
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
        , "uint", IPC_SMTO_ABORTIFHUNG
        , "uint", IPC_WM_SEND_TIMEOUT_MS
        , "ptr*", &_ := 0
        , "ptr")
    return true
}

; Send a WM_COPYDATA command with a payload buffer to a target window.
; Uses SendMessage (not DllCall) so caller must manage DetectHiddenWindows.
; Returns true if message was sent successfully.
IPC_SendWmCopyDataWithPayload(targetHwnd, cmdCode, payloadBuf, payloadSize) {
    global WM_COPYDATA
    if (!targetHwnd)
        return false
    cds := Buffer(A_PtrSize * 3, 0)
    NumPut("uptr", cmdCode, cds, 0)
    NumPut("uptr", payloadSize, cds, A_PtrSize)
    NumPut("uptr", payloadBuf.Ptr, cds, A_PtrSize * 2)
    try {
        SendMessage(WM_COPYDATA, A_ScriptHwnd, cds.Ptr, , "ahk_id " targetHwnd)
        return true
    } catch {
        return false
    }
}
