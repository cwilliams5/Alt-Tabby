; ================== ipc_targeted.ahk (AHKv2) ==================
#Requires AutoHotkey v2.0

; ---- Public API ------------------------------------------------
; Micro (interceptor) side:
;   TABBY_IPC_InitMicro()
;   TABBY_IPC_Post(ev, flags := 0, lParam := 0)   ; ev: 1=TAB_STEP, 2=ALT_UP (kept for compatibility)
;   TABBY_IPC_SendStep(shiftFlag := 0)
;   TABBY_IPC_SendAltUp()

; Receiver (switcher) side:
;   TABBY_IPC_InitReceiver(handlerFn)             ; handlerFn(ev, flags, lParam)

; ---------------------------------------------------------------

; ---- Globals ----
global __TAB_msg_STEP := 0
global __TAB_msg_ALTUP := 0
global __TAB_msg_HELLO := 0
global __TAB_msg_HELLO_ACK := 0

global __TAB_role := ""                 ; "micro" | "receiver"
global __TAB_handler := 0               ; receiver’s delegate
global __TAB_target := 0                ; micro->receiver target hwnd
global __TAB_peerMicro := 0             ; receiver caches last micro hwnd
global __TAB_lastHelloTick := 0
global __TAB_helloTimerOn := false
global __TAB_pendingRetry := false

; redundant ALT_UP re-post guard
global __TAB_lastAltUpTick := 0

; ---- Constants ----
__TAB_HWND_BROADCAST() => 0xFFFF
__TAB_MSGFLT_ADD()     => 1

; ---- Utilities ----
__TAB_Reg(msgName) {
  return DllCall("user32\RegisterWindowMessageW", "str", msgName, "uint")
}

__TAB_AllowMsgForThisWindow(msgId) {
  ; Allows message from lower IL senders if needed (safe no-op if same IL).
  try DllCall("user32\ChangeWindowMessageFilterEx"
    , "ptr", A_ScriptHwnd
    , "uint", msgId
    , "uint", __TAB_MSGFLT_ADD()
    , "ptr", 0
    , "int")
}

__TAB_SendNotify(hWnd, msg, wParam := 0, lParam := 0) {
  ; Async, non-blocking across threads/processes
  return DllCall("user32\SendNotifyMessageW"
    , "ptr", hWnd
    , "uint", msg
    , "uptr", wParam
    , "ptr", lParam
    , "int")
}

__TAB_SendHello_Broadcast(*) {
  global __TAB_msg_HELLO, __TAB_helloTimerOn, __TAB_lastHelloTick
  __TAB_lastHelloTick := A_TickCount
  __TAB_SendNotify(__TAB_HWND_BROADCAST(), __TAB_msg_HELLO, A_ScriptHwnd, 0)
}

__TAB_StartHelloTimer() {
  global __TAB_helloTimerOn
  if (__TAB_helloTimerOn)
    return
  __TAB_helloTimerOn := true
  ; quick bursts for first second, then back off
  ; 0ms, 120ms, 250ms, 500ms, stop when __TAB_target learned
  seq := [0, 120, 250, 500]
  i := 1
  for delay in seq {
    SetTimer(() => (__TAB_target ? 0 : __TAB_SendHello_Broadcast()), -delay)
  }
  ; safety: after 2s, try once more if still no target
  SetTimer(() => (__TAB_target ? 0 : __TAB_SendHello_Broadcast()), -2000)
}

__TAB_OnMsg(wParam, lParam, msg, hwnd) {
  global __TAB_role, __TAB_handler, __TAB_msg_STEP, __TAB_msg_ALTUP, __TAB_msg_HELLO, __TAB_msg_HELLO_ACK
  global __TAB_peerMicro, __TAB_target

  if (msg = __TAB_msg_HELLO) {
    ; someone is announcing; if we’re receiver, cache its hwnd and ACK with our hwnd
    if (__TAB_role = "receiver") {
      __TAB_peerMicro := wParam
      __TAB_SendNotify(wParam, __TAB_msg_HELLO_ACK, A_ScriptHwnd, 0)
    }
    return
  }

  if (msg = __TAB_msg_HELLO_ACK) {
    ; micro learns receiver’s hwnd
    __TAB_target := wParam
    return
  }

  ; Delivery to receiver:
  if (__TAB_role = "receiver") {
    if !IsSet(__TAB_handler) || !__TAB_handler
      return
    if (msg = __TAB_msg_STEP) {
      (__TAB_handler).Call(1, wParam, lParam)   ; ev=1 (TAB_STEP)
      return
    }
    if (msg = __TAB_msg_ALTUP) {
      (__TAB_handler).Call(2, wParam, lParam)   ; ev=2 (ALT_UP)
      return
    }
  }
}

__TAB_InitCommon() {
  global __TAB_msg_STEP, __TAB_msg_ALTUP, __TAB_msg_HELLO, __TAB_msg_HELLO_ACK
  ; Use GUID-like names to avoid collisions
  __TAB_msg_STEP      := __TAB_Reg("TABBY_STEP_5b1b1e9b-ec5e-4aa0-8893-1f4d2a1c1a00")
  __TAB_msg_ALTUP     := __TAB_Reg("TABBY_ALTUP_9b40a4d1-1c0f-4dc5-8b7e-0bdb6c8a5f01")
  __TAB_msg_HELLO     := __TAB_Reg("TABBY_HELLO_a1157f6c-2a6f-4e3d-afe1-3bcd29c3c102")
  __TAB_msg_HELLO_ACK := __TAB_Reg("TABBY_HELLO_ACK_3a3d3e6c-8b9a-4e2b-945f-10c7f4b2d203")

  OnMessage(__TAB_msg_HELLO,     __TAB_OnMsg)
  OnMessage(__TAB_msg_HELLO_ACK, __TAB_OnMsg)
  OnMessage(__TAB_msg_STEP,      __TAB_OnMsg)
  OnMessage(__TAB_msg_ALTUP,     __TAB_OnMsg)

  ; Allow through UIPI if needed (harmless otherwise)
  __TAB_AllowMsgForThisWindow(__TAB_msg_HELLO)
  __TAB_AllowMsgForThisWindow(__TAB_msg_HELLO_ACK)
  __TAB_AllowMsgForThisWindow(__TAB_msg_STEP)
  __TAB_AllowMsgForThisWindow(__TAB_msg_ALTUP)
}

; ---- Public: Receiver init ----
TABBY_IPC_InitReceiver(handlerFn) {
  global __TAB_role, __TAB_handler
  __TAB_InitCommon()
  __TAB_role   := "receiver"
  __TAB_handler := handlerFn
  ; On first HELLO from micro we’ll reply with ACK; nothing more to do now.
}

; ---- Public: Micro init ----
TABBY_IPC_InitMicro() {
  global __TAB_role
  __TAB_InitCommon()
  __TAB_role := "micro"
  __TAB_StartHelloTimer()
}

; ---- Micro send helpers ----
__TAB_EvToMsg(ev) {
  global __TAB_msg_STEP, __TAB_msg_ALTUP
  return (ev = 1) ? __TAB_msg_STEP
       : (ev = 2) ? __TAB_msg_ALTUP
       : 0
}

__TAB_TargetEnsure() {
  global __TAB_target
  if (__TAB_target)
    return true
  __TAB_StartHelloTimer()
  return false
}

__TAB_Send(ev, flags := 0, lParam := 0) {
  global __TAB_target
  msg := __TAB_EvToMsg(ev)
  if (!msg)
    return
  if (!__TAB_TargetEnsure()) {
    ; If target is not known yet, schedule a quick retry (non-blocking) and bail.
    SetTimer(() => __TAB_Send(ev, flags, lParam), -1)  ; next tick ASAP
    return
  }
  __TAB_SendNotify(__TAB_target, msg, flags, lParam)
}

; Backward-compatible entry
TABBY_IPC_Post(ev, flags := 0, lParam := 0) => __TAB_Send(ev, flags, lParam)

TABBY_IPC_SendStep(shiftFlag := 0) {
  __TAB_Send(1, shiftFlag & 1, 0)
}

TABBY_IPC_SendAltUp() {
  global __TAB_lastAltUpTick
  __TAB_lastAltUpTick := A_TickCount
  __TAB_Send(2, 0, 0)
  ; tiny redundant pings to survive edge races (still async/non-blocking)
  SetTimer(TABBY_IPC_SendAltUp__retry5,  -5)
  SetTimer(TABBY_IPC_SendAltUp__retry25, -25)
}
TABBY_IPC_SendAltUp__retry5(*)  => __TAB_Send(2, 0, 0)
TABBY_IPC_SendAltUp__retry25(*) => __TAB_Send(2, 0, 0)
