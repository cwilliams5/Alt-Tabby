# Keyboard Hooks & Rapid Alt-Tab

## Core Rules

- **`SendMode("Event")` is mandatory** — AHK's default `SendInput` temporarily uninstalls all keyboard hooks. User keypresses during that window are lost forever. Enforced by `send_patterns` check.
- **`Critical "On"` in all hotkey callbacks** — Without it, one callback can interrupt another mid-execution. Enforced by `callback_critical` check.
- **komorebic also uninstalls hooks** — `komorebic focus-named-workspace` uses SendInput internally. Fix: async activation with event buffering.

## Key Patterns

- **Async activation**: Buffer events in `gGUI_EventBuffer` while `gGUI_PendingPhase != ""`. Escape cancels pending activation.
- **Lost Tab detection**: ALT_DN + ALT_UP without TAB = Tab was lost. Synthesize it.
- **In-process MRU**: Window data lives in MainProcess — MRU is always authoritative, no stale snapshot risk.

## Game Mode Bypass

Disables Tab hooks when fullscreen game or blacklisted process is focused. WinEventHook sets `isFocused: true` → GUI calls `INT_ShouldBypassWindow(hwnd)` → `Hotkey("$*Tab", "Off")`. When focus leaves, Tab hotkeys re-enabled.

**Critical fix:** Filter windows with empty titles in WinEventHook callback — prevents Task Switching UI from poisoning focus tracking.

## CRITICAL: Critical Sections During Rendering (Context-Dependent)

**`GUI_OnInterceptorEvent` (hotkey handler):** Keep `Critical "On"` for the entire handler. Releasing before render caused partial glass, mapping corruption, and stale projection data. No internal abort points — unsafe to interrupt.

**`_GUI_GraceTimerFired` (deferred timer):** Release Critical BEFORE `_GUI_ShowOverlayWithFrozen()`. This is safe because the show path has 3 RACE FIX abort points that detect `gGUI_State != "ACTIVE"`. Keeping Critical during the 1-2s first paint exceeds Windows' `LowLevelHooksTimeout` (~300ms), causing silent hook removal — the original #303 bug.

**Rule of thumb:** Release Critical before heavy COM work (D2D paint, ShowWindow, DwmFlush) only when the rendering path has internal state-change abort points. Otherwise keep it held.

## Defense Stack

1. `SendMode("Event")` — keeps hook active
2. `Critical "On"` — prevents callback interruption
3. Context-dependent Critical during render (see above)
4. Async activation — non-blocking
5. Event buffering — queue during async
6. Lost Tab detection — synthesize if needed
7. `GetAsyncKeyState(VK_MENU)` — physical Alt polling detects lost hooks (#303)
8. Active-state watchdog — 500ms safety net catches any stuck ACTIVE (#303)
