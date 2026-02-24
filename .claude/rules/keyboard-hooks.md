# Keyboard Hooks & Rapid Alt-Tab

## Core Rules

- **`SendMode("Event")` is mandatory** — AHK's default `SendInput` temporarily uninstalls all keyboard hooks. User keypresses during that window are lost forever.
- **`Critical "On"` in all hotkey callbacks** — Without it, one callback can interrupt another mid-execution. Apply to: `_INT_Alt_Down/_INT_Alt_Up`, `_INT_Tab_Down/_INT_Tab_Up`, `_INT_Tab_Decide`, `_INT_Ctrl_Down`, `_INT_Escape_Down`, `GUI_OnInterceptorEvent`.
- **komorebic also uninstalls hooks** — `komorebic focus-named-workspace` uses SendInput internally. Fix: async activation with event buffering.

## Key Patterns

- **Async activation**: Buffer events in `gGUI_EventBuffer` while `gGUI_PendingPhase != ""`. Escape cancels pending activation.
- **Lost Tab detection**: ALT_DN + ALT_UP without TAB = Tab was lost. Synthesize it.
- **In-process MRU**: Window data lives in MainProcess — MRU is always authoritative, no stale snapshot risk.

## Game Mode Bypass

Disables Tab hooks when fullscreen game or blacklisted process is focused. WinEventHook sets `isFocused: true` → GUI calls `INT_ShouldBypassWindow(hwnd)` → `Hotkey("$*Tab", "Off")`. When focus leaves, Tab hotkeys re-enabled.

**Critical fix:** Filter windows with empty titles in WinEventHook callback — prevents Task Switching UI from poisoning focus tracking.

## CRITICAL: Do NOT Release Critical Before Rendering

**This is an optimization trap.** A previous attempt released `Critical "Off"` before GDI+ rendering (~16ms) and caused:
1. **Partial glass background** — timer callbacks interrupted mid-render
2. **Window mapping corruption** — gGUI_LiveItems modified during render
3. **Stale projection data** — producer callbacks accepted during async activation

Keep `Critical "On"` for the entire `GUI_OnInterceptorEvent` handler. The ~16ms delay is acceptable — users won't notice keyboard lag but WILL notice corrupted GUI.

**Only safe to release before rendering when:**
1. Rendering uses `gGUI_DisplayItems` (already populated inside Critical)
2. Display items are independent of producer callbacks

## Defense Stack

1. `SendMode("Event")` — keeps hook active
2. `Critical "On"` — prevents callback interruption
3. Keep Critical during render — prevents data corruption
4. Async activation — non-blocking
5. Event buffering — queue during async
6. Lost Tab detection — synthesize if needed
