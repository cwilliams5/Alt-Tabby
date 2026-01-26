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

## CRITICAL: Do NOT Release Critical Before Rendering

**This is a common optimization trap. DO NOT release Critical before GUI operations.**

A previous attempt to improve keyboard responsiveness released `Critical "Off"` before GDI+ rendering (which takes ~16ms). This caused severe bugs:

1. **Partial glass background** - IPC messages interrupted mid-render
2. **Window mapping corruption** - gGUI_Items modified during render
3. **Stale projection data** - Snapshots accepted during async activation

The ~16ms delay is acceptable. Users won't notice keyboard lag, but they WILL notice:
- Partially drawn GUI backgrounds
- Wrong windows in the list
- Only 1 window showing after quick Alt+Tab

**Safe pattern:**
```ahk
GUI_OnInterceptorEvent(evCode, flags, lParam) {
    Critical "On"  ; KEEP ON for entire handler
    ; ... state mutations ...
    ; ... GUI_ShowOverlay / GUI_Repaint ...
    ; ... NO Critical "Off" before return ...
}
```

**Only safe to release Critical before rendering when:**
1. Rendering uses `gGUI_FrozenItems` (already populated inside Critical)
2. Frozen items are independent of incoming IPC messages

## Async Activation Must Block Snapshots

When `gGUI_PendingPhase != ""`, incoming snapshots must be skipped:

```ahk
if (gGUI_PendingPhase != "" && !isToggleResponse) {
    ; Skip - async activation in progress
    return
}
```

Otherwise, workspace-filtered snapshots corrupt gGUI_Items during activation.

## Defense Stack Summary

1. `SendMode("Event")` - keeps hook active
2. `Critical "On"` - prevents callback interruption
3. **Keep Critical during render** - prevents data corruption
4. Async activation - non-blocking
5. **Block snapshots during async** - prevents stale data
6. Event buffering - queue during async
7. Lost Tab detection - synthesize if needed
8. Local MRU tracking - skip stale snapshots
9. Local WS update - immediate, don't wait for IPC

## Debugging

Enable `EventLog=true` in `[Diagnostics]`. Log: `%TEMP%\tabby_events.log`

Look for: Missing `Tab_Down` between `Alt_Down` and `Alt_Up` = lost Tab.
