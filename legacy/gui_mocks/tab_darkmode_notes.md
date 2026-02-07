# Tab Control Dark Mode - Approach Log

## Problem
Tab control (SysTabControl32) text labels don't update during live dark/light theme transitions.
Labels look correct on initial open, but toggling system theme doesn't update inactive tab text/bg.

## ROOT CAUSE
AHK v2 internally handles WM_NOTIFY and WM_DRAWITEM for Tab3 controls.
OnMessage callbacks NEVER receive NM_CUSTOMDRAW or WM_DRAWITEM for inactive tabs.
The ONLY way to control tab rendering is to subclass the tab control's WndProc
directly via SetWindowLongPtrW (not SetWindowSubclass — AHK overrides that too).

## WORKING SOLUTION: Approach #8 (SetWindowLongPtrW paint-over)
- **SetWindowTheme("DarkMode_Explorer")** for dark tab chrome (bg, borders, hover)
- **SetWindowLongPtrW(GWL_WNDPROC=-4)** on the tab HWND to replace WndProc
- **Install subclass LAST** — after all UseTab() calls and control creation
  (AHK re-subclasses during tab setup, so installing early gets overwritten)
- **WM_PAINT handler**: call original WndProc first (theme paints backgrounds),
  then paint tab text on top using GetDC/ReleaseDC
- **CallbackCreate(_TabWndProc, "", 4)** — normal mode, 4 params (hWnd, uMsg, wParam, lParam)
- **CallWindowProcW** to forward non-paint messages to original WndProc
- Verified: subclass=OK, RED diagnostic text visible on ALL tabs in both modes
- **Status: WORKING** — text and backgrounds correct in both dark and light modes

### Final Fix: Text-only paint-over (no FillRect)
- Do NOT FillRect tab backgrounds — let the theme paint all chrome (bg, borders, hover)
- Only draw text on top with SetBkMode(TRANSPARENT) + DrawTextW
- This preserves the theme's visual appearance while fixing text color
- FillRect was overwriting theme backgrounds with wrong colors (item rect != visual area)

### Key Implementation Details
- Subclass must be installed AFTER all UseTab() calls (critical!)
- Use CallbackCreate("", 4) not ("Fast", 4) — Fast mode unreliable for paint ops
- WndProc receives (hWnd, uMsg, wParam, lParam) — standard 4-param signature
- Forward all non-paint messages via CallWindowProcW to original proc
- Store original proc in global gTabOrigProc, callback in gTabNewProc
- On toggle: SetWindowTheme swaps tab theme, subclass stays installed (verified)
- Subclass verification: compare GetWindowLongPtrW result against gTabNewProc

## Approaches Tried (FAILED)

### 1. NM_CUSTOMDRAW (FAILED - CONFIRMED)
- OnMessage(0x004E) for WM_NOTIFY with NM_CUSTOMDRAW (code=-12)
- RED diagnostic text — text stays BLACK
- **Handler does NOT fire at all** for tab controls in AHK v2
- AHK internally handles WM_NOTIFY for Tab3, never passes to OnMessage
- Production theme.ahk _Theme_OnNotify is dead code for tabs

### 2. TCS_OWNERDRAWFIXED + WM_DRAWITEM (PARTIAL)
- WM_DRAWITEM fires for SELECTED tab only, not inactive tabs
- AHK internally handles WM_DRAWITEM and only passes selected tab

### 3. SetWindowSubclass (comctl32) + WM_PAINT (FAILED)
- Subclass NOT called AT ALL
- AHK's Tab3 overrides comctl32 SetWindowSubclass

### 4. SetWindowLongPtrW + full WM_PAINT (SUPERSEDED by #8)
- Was written with SetWindowTheme("","") to disable all theming
- Full custom paint (strip bg, content area, border, items)
- Subclass installed too early (before UseTab calls) — got overwritten by AHK
- Superseded by #8 which installs LAST and uses paint-over strategy

### 5. Simple SetWindowTheme + RedrawWindow (FAILED)
- Dark tab BACKGROUND works, text stays BLACK
- SetWindowTheme controls bg chrome but NOT text color

### 5b. Approach 5 + NM_CUSTOMDRAW (FAILED)
- Same as #1 — NM_CUSTOMDRAW never fires in AHK v2

### 6. TCS_OWNERDRAWFIXED + WM_DRAWITEM + SetWindowTheme("","") (FAILED)
- Identical to #2 — WM_DRAWITEM still only fires for selected tab
- Disabling theming made no difference

## Key Win32 Facts
- SetWindowTheme("DarkMode_Explorer"): dark visual theme (dark bg, but black text)
- SetWindowTheme("Explorer"): standard light visual theme
- SetWindowTheme("", ""): disables visual theming entirely (classic mode)
- AllowDarkModeForWindow (uxtheme #133): per-window dark mode enable
- SetPreferredAppMode (uxtheme #135): app-wide mode (call before creating windows)
- FlushMenuThemes (uxtheme #136): must follow SetPreferredAppMode
- Tab messages: TCM_GETITEMCOUNT=0x1304, TCM_GETCURSEL=0x130B,
  TCM_GETITEMRECT=0x130A, TCM_GETITEMW=0x133C, TCM_SETCURSEL=0x130C,
  TCM_ADJUSTRECT=0x1328
- TCITEM struct x64: mask=0, pszText=16, cchTextMax=24. Total size=40.
- DRAWITEMSTRUCT x64: CtlType=0, itemID=8, itemState=16, hwndItem=24, hDC=32, rcItem=40
- _CR(rgb): converts 0xRRGGBB to COLORREF 0x00BBGGRR
- WM_PAINT=0x000F, WM_ERASEBKGND=0x0014, WM_DRAWITEM=0x002B
- GWL_WNDPROC=-4, GWL_STYLE=-16, TCS_OWNERDRAWFIXED=0x2000
- DT_CENTER|DT_VCENTER|DT_SINGLELINE = 0x25

## Production Integration Plan
Once mock is working:
1. Remove dead NM_CUSTOMDRAW handler from theme.ahk (_Theme_OnNotify, gTheme_TabHwnds)
2. Add SetWindowLongPtrW subclass logic to Theme_ApplyToControl for "Tab" type
3. Store original/new WndProc per tab HWND (Map)
4. In _Theme_ReapplyAll, InvalidateRect on tab controls triggers WM_PAINT in subclass
5. In Theme_UntrackGui, restore original WndProc before destroying GUI
