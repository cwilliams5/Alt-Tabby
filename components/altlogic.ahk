; altlogic.ahk — Lightning-fast Alt+Tab with overlay, MRU, blacklist debugger (press B while overlay is up)
; altlogic.ahk — Lightning-fast Alt+Tab (receiver mode via IPC)
ALTAB_Init() {
  global QuitHotkey

  ; ===== Defaults (honor config overrides if present) =====
  if !IsSet(RefreshOnOverlay)
    global RefreshOnOverlay := true
  if !IsSet(RefreshOnAltUp)
    global RefreshOnAltUp := true
  if !IsSet(AltDeferMs)
    global AltDeferMs := 8
  if !IsSet(AltGraceMs)
    global AltGraceMs := 80

  ; quit + tray (keep your configurable quit + add a non-Alt emergency quit)
  Hotkey(QuitHotkey, ALTAB_Quit)
  Hotkey("#^Esc", ALTAB_Quit)  ; Win+Ctrl+Esc → emergency exit
  A_TrayMenu.Add("Exit", ALTAB_Quit)

  ; ===== IMPORTANT: receiver mode only — no Alt/Tab hotkeys here =====
  ; We listen for micro-interceptor signals over PostMessage IPC.
  TABBY_IPC_Listen(ALTAB_IPC_Handler)

  ; Debug helpers still usable without Alt
  HotIf(IsBLHotkeyActive)
  Hotkey("*b", ALTAB_Debug_Blacklist)
  Hotkey("*B", ALTAB_Debug_Blacklist)
  HotIf()

  ; Non-Alt test toggles
  Hotkey("#^F10", ALTAB_Toggle_NoGUI)
  Hotkey("#^F11", ALTAB_Toggle_NoBlocking)

  ; start MRU tracking
  MRU_Init()
}


; ---- New: IPC event handler (called by TABBY_IPC_Listen) ----
ALTAB_IPC_Handler(ev, flags, lParam) {
  ; ev: 1=TAB_STEP, 2=ALT_UP
  if (ev = 1) {
    ALTAB_IPC_TabStep( (flags & 0x01) ? -1 : +1 )  ; Shift = backward
  } else if (ev = 2) {
    ALTAB_IPC_AltUp()
  }
}

; dir: +1 forward, -1 backward
ALTAB_IPC_TabStep(dir) {
  global AL_session, AL_tabHeld, AL_firstTick, AL_pressCount, AL_list, AL_len
  global AL_sel, AL_base, HoldMs

  if (AL_tabHeld)
    return
  AL_tabHeld := true

  ; Session start: build list and arm overlay timer
  if !AL_session {
    AL_list := ALTAB_BuildList()
    AL_len  := AL_list.Length
    if (AL_len = 0) {
      AL_tabHeld := false
      return
    }
    curr    := WinGetID("A")
    AL_base := ALTAB_IndexOf(AL_list, curr)
    if (AL_base = 0)
      AL_base := 1
    AL_sel := AL_base

    AL_session    := true
    AL_pressCount := 0
    AL_firstTick  := A_TickCount
    SetTimer(ALTAB_ShowOverlayIfEligible, -HoldMs)
  }

  AL_pressCount += 1
  AL_sel := ALTAB_Wrap(AL_sel + dir, AL_len)

  if (AL_pressCount >= 2) {
    ALTAB_ShowOverlayNow()
    SetTimer(ALTAB_ShowOverlayIfEligible, 0)
  }
  ALTAB_UpdateOverlay()

  ; We allow rapid re-steps while Alt is held; the micro handles AltUp.
  AL_tabHeld := false
}


ALTAB_IPC_AltUp() {
  global AL_session, AL_pressCount, AL_list, AL_sel, AL_overlayUp
  global RefreshOnAltUp

  SetTimer(ALTAB_ShowOverlayIfEligible, 0)
  Overlay_Hide()
  AL_overlayUp := false

  if (AL_session && AL_pressCount >= 1 && AL_list.Length >= 1) {
    if (RefreshOnAltUp) {
      currentSel := AL_list[AL_sel].Hwnd
      fresh := ALTAB_BuildList()
      if (fresh.Length) {
        AL_list := fresh
        idx := ALTAB_IndexOf(AL_list, currentSel)
        if (idx)
          AL_sel := idx
        else if (AL_sel > AL_list.Length)
          AL_sel := 1
      }
    }
    target := AL_list[AL_sel]
    ok := ActivateHwnd(target.Hwnd, target.State)
    if (ok)
      MRU_MoveToFront(target.Hwnd)
  }

  ALTAB_ResetSessionState()   ; clears AL_session, counts, etc.
}


; ---- Context predicate for blacklist helper ----
IsBLHotkeyActive(*) {
  global AL_session, AL_overlayUp
  return AL_session && AL_overlayUp && GetKeyState("Alt","P")
}

; ---- State ----
global AL_lastAltDown := -999999
global AL_session     := false
global AL_tabHeld     := false
global AL_firstTick   := 0
global AL_pressCount  := 0
global AL_list        := []
global AL_len         := 0
global AL_sel         := 0
global AL_base        := 0
global AL_overlayUp   := false

; Alt+Tab timing helpers
if !IsSet(AltDeferMs)
  global AltDeferMs := 8      ; deferral for Alt arriving after Tab (ms)
global AL_pendingTabTick  := -1
global AL_pendingTabShift := false

; Alt key handling state
global altArmed    := false   ; Alt pressed (waiting to see if Tab follows)
global altConsumed := false   ; Alt+Tab combo in progress (Alt should not reach app)
global altPassed   := false   ; Alt passed through to OS (for non-AltTab uses)

; ---- Event helpers ----
ALTAB_Quit(*) {
  Overlay_Hide()
  Komorebi_SubStop()
  ExitApp()
}
ALTAB_RecordAltDown(*) {
  global AL_lastAltDown, altArmed, altConsumed, altPassed, AltGraceMs
  AL_lastAltDown := A_TickCount
  altArmed    := true
  altConsumed := false
  altPassed   := false
  ; If no Tab arrives within grace, allow Alt to be sent to OS for normal behavior
  SetTimer(ALTAB_PassthroughMaybe, -AltGraceMs)
}

ALTAB_PassthroughMaybe() {
  global altArmed, altConsumed, altPassed
  if (!altArmed || altConsumed || altPassed)
    return
  if GetKeyState("Alt","P") {
    ; No Alt+Tab detected and Alt still held → pass Alt through (enable menu/combos)
    Send "{Alt down}"
    altPassed := true
  }
}

ALTAB_IsAltComboNowOrJustPressed() {
  global AL_lastAltDown, AltGraceMs, UseAltGrace
  return GetKeyState("Alt","P") || ((IsSet(UseAltGrace) ? UseAltGrace : true) && ((A_TickCount - AL_lastAltDown) <= AltGraceMs))
}
ALTAB_AltIsDownForHotkey(*) {
  return GetKeyState("Alt","P")
}
ALTAB_ShouldBypass() {
  return ShouldBypassForGame()
}

; ---- Hooks ----
ALTAB_TabDown_Global(*) {
  if ALTAB_ShouldBypass() {
    Send(GetKeyState("Shift","P") ? "+{Tab}" : "{Tab}")
    return
  }
  if ALTAB_IsAltComboNowOrJustPressed() {
    ALTAB_Common_TabDown()
    return
  }
  ; If Alt is not pressed (no combo) → send Tab through immediately (skip deferral if configured)
  if (IsSet(UseAltGrace) && !UseAltGrace) {
    Send(GetKeyState("Shift","P") ? "+{Tab}" : "{Tab}")
    return
  }
  ; Tab arrived slightly before Alt – defer briefly and check again
  global AL_pendingTabTick, AL_pendingTabShift, AltDeferMs
  AL_pendingTabTick  := A_TickCount
  AL_pendingTabShift := GetKeyState("Shift","P")
  SetTimer(ALTAB_DeferredDecide, -AltDeferMs)
}

ALTAB_DeferredDecide() {
  global AL_pendingTabTick, AL_pendingTabShift, AL_lastAltDown, AltGraceMs
  if (AL_pendingTabTick < 0)
    return
  if (GetKeyState("Alt","P") || ((A_TickCount - AL_lastAltDown) <= AltGraceMs)) {
    ALTAB_Common_TabDown()
  } else {
    Send(AL_pendingTabShift ? "+{Tab}" : "{Tab}")
  }
  AL_pendingTabTick := -1
}

ALTAB_TabDown_AltOnly(*) {
  if ALTAB_ShouldBypass() {
    Send(GetKeyState("Shift","P") ? "+{Tab}" : "{Tab}")
    return
  }
  ALTAB_Common_TabDown()
}
ALTAB_TabUp(*) {
  global AL_tabHeld
  AL_tabHeld := false
}

; ---- Core Alt+Tab logic ----
ALTAB_Common_TabDown() {
  global AL_session, AL_tabHeld, AL_firstTick, AL_pressCount, AL_list, AL_len
  global AL_sel, AL_base, HoldMs, altConsumed

  if (AL_tabHeld)
    return
  AL_tabHeld := true

  ; Alt+Tab combo confirmed – consume Alt (don’t send to active app)
  altConsumed := true
  ; Prevent any Alt-menu highlight (send inert vkE8 key immediately)
  try Send "{Blind}{vkE8}"

  if !AL_session {
    ; Build window list at start of Alt+Tab session
    AL_list := ALTAB_BuildList()
    AL_len  := AL_list.Length
    if (AL_len = 0) {
      ; No switchable windows – pass Tab through
      Send(GetKeyState("Shift","P") ? "+{Tab}" : "{Tab}")
      return
    }
    curr    := WinGetID("A")
    AL_base := ALTAB_IndexOf(AL_list, curr)
    if (AL_base = 0)
      AL_base := 1
    AL_sel := AL_base

    AL_session    := true
    AL_pressCount := 0
    AL_firstTick  := A_TickCount

    SetTimer(ALTAB_ShowOverlayIfEligible, -HoldMs)
  }

  AL_pressCount += 1
  if GetKeyState("Shift","P")
    AL_sel := ALTAB_Wrap(AL_sel - 1, AL_len)
  else
    AL_sel := ALTAB_Wrap(AL_sel + 1, AL_len)

  if (AL_pressCount >= 2) {
    ALTAB_ShowOverlayNow()
    SetTimer(ALTAB_ShowOverlayIfEligible, 0)
  }
  ALTAB_UpdateOverlay()
}

ALTAB_Wrap(idx, len) {
  if (idx < 1)
    return len
  if (idx > len)
    return 1
  return idx
}
ALTAB_IndexOf(arr, hwnd) {
  for idx, it in arr
    if (it.Hwnd = hwnd)
      return idx
  return 0
}

; ---- Alt release = perform switch (if any) ----
ALTAB_AltUp(*) {
  global AL_session, AL_pressCount, AL_list, AL_sel, AL_overlayUp
  global RefreshOnAltUp, altArmed, altConsumed, altPassed

  altArmed := false  ; Alt no longer held
  SetTimer(ALTAB_ShowOverlayIfEligible, 0)  ; cancel overlay delay timer
  Overlay_Hide()
  AL_overlayUp := false

  if (AL_session && AL_pressCount >= 1 && AL_list.Length >= 1) {
    if (RefreshOnAltUp) {
      currentSel := AL_list[AL_sel].Hwnd
      fresh := ALTAB_BuildList()
      if (fresh.Length) {
        AL_list := fresh
        idx := ALTAB_IndexOf(AL_list, currentSel)
        if (idx)
          AL_sel := idx
        else if (AL_sel > AL_list.Length)
          AL_sel := 1
      }
    }
    target := AL_list[AL_sel]
    ok := ActivateHwnd(target.Hwnd, target.State)
    if (ok)
      MRU_MoveToFront(target.Hwnd)
  }

  ; Handle Alt key release behavior based on how Alt was used
  if (altPassed) {
    ; Alt was passed through (Alt held without Tab) – send Alt up to OS
    Send "{Alt up}"
  } else if (!altConsumed) {
    ; Bare Alt press (no Alt+Tab) – optionally allow menu focus
    if (IsSet(BlockBareAlt) ? BlockBareAlt : true) {
      ; Configured to block bare Alt: do nothing (menu highlight was suppressed)
      try Send "{Blind}{vkE8}"
    } else {
      ; Allow bare Alt: simulate a quick Alt press (Alt down+up) to toggle menu focus
      Send "{Alt}"
    }
  }

  ALTAB_ResetSessionState()
}

ALTAB_ResetSessionState() {
  global AL_session, AL_pressCount, AL_tabHeld, AL_list, AL_len, AL_sel, AL_base
  global AL_pendingTabTick, altArmed, altConsumed, altPassed
  AL_session    := false
  AL_pressCount := 0
  AL_tabHeld    := false
  AL_list       := []
  AL_len        := 0
  AL_sel        := 0
  AL_base       := 0
  AL_pendingTabTick := -1
  altArmed    := false
  altConsumed := false
  altPassed   := false
}

; ---- Overlay ----
ALTAB_ShowOverlayIfEligible() {
  global AL_session, AL_firstTick, HoldMs
  if !AL_session
    return
  if !GetKeyState("Alt","P")
    return
  if (A_TickCount - AL_firstTick) < HoldMs
    return
  ALTAB_ShowOverlayNow()
}

ALTAB_Toggle_NoGUI(*) {
  global OverlayEnabled
  if !IsSet(OverlayEnabled)
    OverlayEnabled := true
  OverlayEnabled := !OverlayEnabled
  ToolTip "OverlayEnabled = " (OverlayEnabled ? "ON" : "OFF")
  SetTimer(() => ToolTip(), -800)
}

ALTAB_Toggle_NoBlocking(*) {
  global NoBlocking
  if (!IsSet(NoBlocking))
    NoBlocking := false
  NoBlocking := !NoBlocking
  ToolTip "NoBlocking = " (NoBlocking ? "ON" : "OFF")
  SetTimer(() => ToolTip(), -800)
}

ALTAB_ShowOverlayNow() {
  global AL_list, AL_sel, AL_overlayUp, RefreshOnOverlay

  local overlayEnabled := IsSet(OverlayEnabled) ? !!OverlayEnabled : true
  if !overlayEnabled
    return
  if (AL_list.Length = 0)
    return

  if (RefreshOnOverlay) {
    prev := (AL_sel >= 1 && AL_sel <= AL_list.Length) ? AL_list[AL_sel].Hwnd : 0
    fresh := ALTAB_BuildList()
    if (fresh.Length) {
      AL_list := fresh
      if (prev) {
        idx := ALTAB_IndexOf(AL_list, prev)
        if (idx)
          AL_sel := idx
        else if (AL_sel > AL_list.Length)
          AL_sel := 1
      } else if (AL_sel > AL_list.Length) {
        AL_sel := 1
      }
    }
  }

  Overlay_ShowList(AL_list, AL_sel)
  AL_overlayUp := true
}

ALTAB_UpdateOverlay() {
  global AL_list, AL_sel
  if (AL_list.Length = 0)
    return
  Overlay_UpdateSelection(AL_list, AL_sel)
}

; ---- MRU + Z-order ----
ALTAB_BuildList() {
  global UseMRU
  arr := WinList_EnumerateAll()  ; filtered, Z-order list
  if (!UseMRU)
    return arr

  local hmap := Map(), ordered := [], mru := MRU_GetList()
  for _, item in arr
    hmap[item.Hwnd] := item
  if IsObject(mru) {
    for _, h in mru
      if hmap.Has(h) {
        ordered.Push(hmap[h])
        hmap.Delete(h)
      }
  }
  for hwnd, item in hmap
    ordered.Push(item)
  return ordered
}

; ---- Debug: Alt+B to show blacklist snippet for selected window ----
ALTAB_Debug_Blacklist(*) {
  global AL_session, AL_overlayUp, AL_list, AL_sel
  if !(AL_session && AL_overlayUp && AL_list.Length && AL_sel >= 1 && AL_sel <= AL_list.Length)
    return
  item := AL_list[AL_sel]
  ShowBlacklistSuggestion(item)
}
