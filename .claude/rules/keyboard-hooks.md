# Keyboard Hooks & Rapid Alt-Tab

## SendMode("Event") is Mandatory

AHK's default `SendInput` **temporarily uninstalls all keyboard hooks**. User keypresses during that window are lost forever.

```ahk
; At TOP of gui_main.ahk
SendMode("Event")  ; Keep hooks active during Send
```

## Critical "On" in All Hotkey Callbacks

Without it, one callback can interrupt another mid-execution:
```ahk
INT_Alt_Down(*) {
    Critical "On"
    ; ... handler code
}
```

Apply to: `INT_Alt_Down/Up`, `INT_Tab_Down/Up`, `INT_Tab_Decide`, `INT_Ctrl_Down`, `INT_Escape_Down`, `GUI_OnInterceptorEvent`

## komorebic Also Uninstalls Hooks

When we call `komorebic focus-named-workspace`, komorebi uses SendInput internally - briefly uninstalls our hook.

**Fix:** Async activation with event buffering.

## Async Activation Pattern

```ahk
global gGUI_PendingPhase := ""    ; "polling", "waiting", "flushing", or ""
global gGUI_EventBuffer := []      ; Queued events during async

; In GUI_OnInterceptorEvent - buffer if async in progress
if (gGUI_PendingPhase != "") {
    if (evCode = TABBY_EV_ESCAPE) {
        _GUI_CancelPendingActivation()
        return
    }
    gGUI_EventBuffer.Push({ev: evCode, flags: flags, lParam: lParam})
    return
}
```

## Lost Tab Detection

Pattern: ALT_DN + ALT_UP without TAB = Tab was lost. Synthesize it:
```ahk
if (hasAltDn && hasAltUp && !hasTab) {
    events.InsertAt(altDnIdx + 1, {ev: TABBY_EV_TAB_STEP, flags: 0, lParam: 0})
}
```

## Local MRU Updates

During rapid Alt+Tab, we're faster than store deltas. Track local MRU timestamp and skip stale snapshots:
```ahk
global gGUI_LastLocalMRUTick := 0

; After activation
gGUI_LastLocalMRUTick := A_TickCount

; Skip prewarm if MRU fresh (<300ms)
mruAge := A_TickCount - gGUI_LastLocalMRUTick
if (mruAge > 300) GUI_RequestSnapshot()
```

## Game Mode Bypass

Disables Tab hooks when fullscreen game or blacklisted process is focused.

1. Store sends `isFocused: true` in deltas
2. GUI's `GUI_ApplyDelta` calls `INT_ShouldBypassWindow(hwnd)`
3. If bypass needed, `Hotkey("$*Tab", "Off")`
4. Native Alt+Tab works
5. When focus leaves, Tab hotkeys re-enabled

**Critical fix:** Filter windows with empty titles in WinEventHook callback - prevents Task Switching UI from poisoning focus tracking.

## Defense Stack Summary

1. `SendMode("Event")` - keeps hook active
2. `Critical "On"` - prevents callback interruption
3. Async activation - non-blocking
4. Event buffering - queue during async
5. Lost Tab detection - synthesize if needed
6. Local MRU tracking - skip stale snapshots
7. Local WS update - immediate, don't wait for IPC

## Debugging

Enable `EventLog=true` in `[Diagnostics]`. Log: `%TEMP%\tabby_events.log`

Look for: Missing `Tab_Down` between `Alt_Down` and `Alt_Up` = lost Tab.
