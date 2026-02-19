# Alt-Tabby Configuration Options

> **Auto-generated from `config_registry.ahk`** - Do not edit manually.
> Run `build-config-docs.ahk` to regenerate.

This document lists all configuration options available in `config.ini`.
Edit `config.ini` (next to AltTabby.exe) to customize behavior.

## Table of Contents

- [AltTab](#alttab)
- [Launcher](#launcher)
- [Theme](#theme)
- [GUI](#gui)
- [Komorebi](#komorebi)
- [Setup](#setup)
- [Tools](#tools)
- [IPC](#ipc)
- [Store](#store)
- [Diagnostics](#diagnostics)

---

## AltTab

These control the Alt-Tab overlay behavior - tweak these first!

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `GraceMs` | int | `150` | `0` - `2000` | Grace period before showing GUI (ms). During this time, if Alt is released, we do a quick switch without showing GUI. |
| `QuickSwitchMs` | int | `100` | `0` - `1000` | Maximum time for quick switch without showing GUI (ms). If Alt+Tab and release happen within this time, instant switch. |
| `SwitchOnClick` | bool | `true` | - | Activate window immediately when clicking a row (like Windows native). When false, clicking selects the row and activation happens when Alt is released. |
| `AsyncActivationPollMs` | int | `15` | `10` - `100` | Polling interval (ms) when switching to a window on a different workspace. Lower = more responsive but higher CPU. |

### Bypass

When to let native Windows Alt-Tab handle the switch instead of Alt-Tabby

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `BypassFullscreen` | bool | `true` | - | Bypass Alt-Tabby when the foreground window is fullscreen (covers >=99%% of screen). Useful for games that need native Alt-Tab behavior. |
| `BypassFullscreenThreshold` | float | `0.99` | `0.50` - `1.00` | Fraction of screen dimensions a window must cover to be considered fullscreen. Lower values catch borderless windowed games that don't quite fill the screen. |
| `BypassFullscreenTolerancePx` | int | `5` | `0` - `50` | Maximum pixels from screen edge for a window to still be considered fullscreen. Increase if borderless windows are offset by more than 5px. |
| `BypassProcesses` | string | `(empty)` | - | Comma-separated list of process names to bypass (e.g., 'game.exe,vlc.exe'). When these processes are in the foreground, native Windows Alt-Tab is used instead. |

### Internal Timing

Internal timing parameters (usually no need to change)

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `AltLeewayMs` | int | `60` | `20` - `200` | Alt key timing tolerance window (ms). After Alt is released, Tab presses within this window are still treated as Alt+Tab. Increase for slower typing speeds. |
| `WSPollTimeoutMs` | int | `200` | `50` - `2000` | Timeout when polling for workspace switch completion (ms). Used during cross-workspace activation. |
| `TabDecisionMs` | int | `24` | `15` - `100` | Tab decision window (ms). When Tab is pressed, we wait this long before committing to show the overlay. Allows detecting rapid Tab releases. Lower = more responsive but may cause accidental triggers. |
| `WorkspaceSwitchSettleMs` | int | `75` | `0` - `500` | Wait time after workspace switch (ms). When activating a window on a different komorebi workspace, we wait this long for the workspace to stabilize before activating the window. Increase if windows fail to activate on slow systems. |

## Launcher

Settings for the main Alt-Tabby launcher process (splash screen, startup behavior).

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `SplashScreen` | enum | `Image` | - | Splash screen mode. Image = static PNG logo with fade. Animation = animated WebP. None = disabled. |

### Image Splash

Settings for static image splash screen

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `SplashImageDurationMs` | int | `3000` | `0` - `10000` | Image splash screen display duration in milliseconds (includes fade time). Set to 0 for minimum. |
| `SplashImageFadeMs` | int | `500` | `0` - `2000` | Image splash screen fade in/out duration in milliseconds. |

### Animation Splash

Settings for animated WebP splash screen

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `SplashAnimFadeInFixedMs` | int | `0` | `0` - `5000` | Fade in duration while frozen on first frame (ms). 0 = skip fixed fade in. |
| `SplashAnimFadeInAnimMs` | int | `500` | `0` - `5000` | Fade in duration while animation plays (ms). 0 = skip animated fade in. |
| `SplashAnimFadeOutAnimMs` | int | `500` | `0` - `5000` | Fade out duration while animation plays (ms). 0 = skip animated fade out. |
| `SplashAnimFadeOutFixedMs` | int | `0` | `0` - `5000` | Fade out duration while frozen on last frame (ms). 0 = skip fixed fade out. |
| `SplashAnimLoops` | int | `1` | `0` - `100` | Number of animation loops before auto-closing. 0 = loop forever (requires manual dismiss). |
| `SplashAnimBufferFrames` | int | `24` | `0` - `500` | Streaming decode buffer size. 0 = load all frames upfront (~500MB). >0 = buffer N frames (~4MB per frame at 1280x720). Default 24 = ~88MB, 1 second buffer at 24fps. |

### Editor & Debug

Config editor and debug menu options

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `ForceNativeEditor` | bool | `false` | - | Always use the native AHK config editor instead of the WebView2 version. |
| `ShowTrayDebugItems` | bool | `false` | - | Show the Dev menu and extra editor options in the tray menu. Useful for testing dialogs and debugging. |

## Theme

Color theme for dialogs and editors. The main Alt-Tab overlay has its own color settings in GUI Appearance.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `Theme` | enum | `Automatic` | - | Color theme for dialogs and editors. Automatic follows the Windows system setting. |

### Customize Dark Mode Colors

Override individual colors for dark mode. Leave at defaults for the standard dark theme.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `DarkBg` | int | `0x202020` | `0x0` - `0xFFFFFF` | Main background |
| `DarkPanelBg` | int | `0x2B2B2B` | `0x0` - `0xFFFFFF` | Panel / secondary background |
| `DarkTertiary` | int | `0x333333` | `0x0` - `0xFFFFFF` | Tertiary background (cards, hover zones) |
| `DarkEditBg` | int | `0x383838` | `0x0` - `0xFFFFFF` | Edit / input background |
| `DarkHover` | int | `0x404040` | `0x0` - `0xFFFFFF` | Hover highlight |
| `DarkText` | int | `0xE0E0E0` | `0x0` - `0xFFFFFF` | Primary text |
| `DarkEditText` | int | `0xE0E0E0` | `0x0` - `0xFFFFFF` | Edit / input text |
| `DarkTextSecondary` | int | `0xAAAAAA` | `0x0` - `0xFFFFFF` | Secondary text |
| `DarkTextMuted` | int | `0x888888` | `0x0` - `0xFFFFFF` | Muted / disabled text |
| `DarkAccent` | int | `0x60CDFF` | `0x0` - `0xFFFFFF` | Accent / link color |
| `DarkAccentHover` | int | `0x78D6FF` | `0x0` - `0xFFFFFF` | Accent hover state |
| `DarkAccentText` | int | `0x202020` | `0x0` - `0xFFFFFF` | Text on accent background |
| `DarkBorder` | int | `0x404040` | `0x0` - `0xFFFFFF` | Standard border |
| `DarkBorderInput` | int | `0x505050` | `0x0` - `0xFFFFFF` | Input border |
| `DarkToggleBg` | int | `0x505050` | `0x0` - `0xFFFFFF` | Toggle switch off state |
| `DarkSuccess` | int | `0x9ECE6A` | `0x0` - `0xFFFFFF` | Success indicator |
| `DarkWarning` | int | `0xE0AF68` | `0x0` - `0xFFFFFF` | Warning indicator |
| `DarkDanger` | int | `0xF7768E` | `0x0` - `0xFFFFFF` | Danger indicator |

### Customize Light Mode Colors

Override individual colors for light mode. Leave at defaults for the standard light theme.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `LightBg` | int | `0xF0F0F0` | `0x0` - `0xFFFFFF` | Main background |
| `LightPanelBg` | int | `0xFFFFFF` | `0x0` - `0xFFFFFF` | Panel / secondary background |
| `LightTertiary` | int | `0xEBEBEB` | `0x0` - `0xFFFFFF` | Tertiary background (cards, hover zones) |
| `LightEditBg` | int | `0xFFFFFF` | `0x0` - `0xFFFFFF` | Edit / input background |
| `LightHover` | int | `0xE0E0E0` | `0x0` - `0xFFFFFF` | Hover highlight |
| `LightText` | int | `0x0` | `0x0` - `0xFFFFFF` | Primary text |
| `LightEditText` | int | `0x0` | `0x0` - `0xFFFFFF` | Edit / input text |
| `LightTextSecondary` | int | `0x444444` | `0x0` - `0xFFFFFF` | Secondary text |
| `LightTextMuted` | int | `0x666666` | `0x0` - `0xFFFFFF` | Muted / disabled text |
| `LightAccent` | int | `0x66CC` | `0x0` - `0xFFFFFF` | Accent / link color |
| `LightAccentHover` | int | `0x55AA` | `0x0` - `0xFFFFFF` | Accent hover state |
| `LightAccentText` | int | `0xFFFFFF` | `0x0` - `0xFFFFFF` | Text on accent background |
| `LightBorder` | int | `0xD0D0D0` | `0x0` - `0xFFFFFF` | Standard border |
| `LightBorderInput` | int | `0xBBBBBB` | `0x0` - `0xFFFFFF` | Input border |
| `LightToggleBg` | int | `0xCCCCCC` | `0x0` - `0xFFFFFF` | Toggle switch off state |
| `LightSuccess` | int | `0x2E7D32` | `0x0` - `0xFFFFFF` | Success indicator |
| `LightWarning` | int | `0xE65100` | `0x0` - `0xFFFFFF` | Warning indicator |
| `LightDanger` | int | `0xC62828` | `0x0` - `0xFFFFFF` | Danger indicator |

### Title Bar Colors (Win11)

Custom title bar background and text colors. Win11 22H2+ only; ignored on Win10. Disabling may require closing and reopening dialogs to fully revert.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `CustomTitleBarColors` | bool | `false` | - | Enable custom title bar background and text colors on Win11. When off, Windows manages title bar colors. |
| `DarkTitleBarBg` | int | `0x202020` | `0x0` - `0xFFFFFF` | Dark mode title bar background |
| `DarkTitleBarText` | int | `0xE0E0E0` | `0x0` - `0xFFFFFF` | Dark mode title bar text |
| `LightTitleBarBg` | int | `0xF0F0F0` | `0x0` - `0xFFFFFF` | Light mode title bar background |
| `LightTitleBarText` | int | `0x0` | `0x0` - `0xFFFFFF` | Light mode title bar text |

### Title Bar Border Color (Win11)

Custom window border color. Win11 22H2+ only; ignored on Win10. Independent of title bar colors above. Disabling may require closing and reopening dialogs to fully revert.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `CustomTitleBarBorder` | bool | `false` | - | Enable custom window border color on Win11. When off, Windows manages the border color. |
| `DarkTitleBarBorder` | int | `0x60CDFF` | `0x0` - `0xFFFFFF` | Dark mode window border color |
| `LightTitleBarBorder` | int | `0x66CC` | `0x0` - `0xFFFFFF` | Light mode window border color |

### Button Hover Colors

Custom accent-colored button hover. Uses owner-draw for full color control.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `CustomButtonColors` | bool | `false` | - | Enable custom button hover/pressed colors. When off, buttons use standard Windows theme. |
| `DarkButtonHoverBg` | int | `0x60CDFF` | `0x0` - `0xFFFFFF` | Dark mode button hover background |
| `DarkButtonHoverText` | int | `0x202020` | `0x0` - `0xFFFFFF` | Dark mode button hover text |
| `LightButtonHoverBg` | int | `0x66CC` | `0x0` - `0xFFFFFF` | Light mode button hover background |
| `LightButtonHoverText` | int | `0xFFFFFF` | `0x0` - `0xFFFFFF` | Light mode button hover text |

## GUI

Visual styling for the Alt-Tab overlay window.

### Background Window

Window background and frame styling

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `AcrylicColor` | int | `0x33000033` | `0x0` - `0xFFFFFFFF` | Background tint color with alpha (0xAARRGGBB) |
| `CornerRadiusPx` | int | `18` | `0` - `100` | Window corner radius in pixels |

### Size Config

Window and row sizing

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `ScreenWidthPct` | float | `0.60` | `0.10` - `1.00` | GUI width as fraction of screen |
| `RowsVisibleMin` | int | `1` | `1` - `20` | Minimum visible rows |
| `RowsVisibleMax` | int | `8` | `1` - `50` | Maximum visible rows |
| `RowHeight` | int | `56` | `20` - `200` | Height of each row in pixels |
| `MarginX` | int | `18` | `0` - `200` | Horizontal margin in pixels |
| `MarginY` | int | `18` | `0` - `200` | Vertical margin in pixels |

### Virtual List Look

Row and icon appearance

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `IconSize` | int | `36` | `8` - `256` | Icon size in pixels |
| `IconLeftMargin` | int | `8` | `0` - `100` | Left margin before icon in pixels |
| `IconTextGapPx` | int | `12` | `0` - `50` | Gap between icon and title text in pixels |
| `ColumnGapPx` | int | `10` | `0` - `50` | Gap between right-side data columns in pixels |
| `HeaderHeightPx` | int | `28` | `16` - `60` | Header row height in pixels |
| `RowRadius` | int | `12` | `0` - `50` | Row corner radius in pixels |
| `SelARGB` | int | `0x662B5CAD` | `0x0` - `0xFFFFFFFF` | Selection highlight color (ARGB) |

### Selection & Scrolling

Selection and scroll behavior

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `ScrollKeepHighlightOnTop` | bool | `true` | - | Keep selection at top when scrolling |
| `EmptyListText` | string | `No Windows` | - | Text shown when no windows available |

### Tooltips

Feedback tooltip timing for accessibility

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `TooltipDurationMs` | int | `2000` | `500` - `10000` | Tooltip display duration in milliseconds. Increase for accessibility. |
| `HoverPollIntervalMs` | int | `100` | `50` - `500` | Hover state polling interval (ms). Lower = more responsive but higher CPU. |

### Action Buttons

Row action buttons shown on hover

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `ShowCloseButton` | bool | `true` | - | Show close button on hover |
| `ShowKillButton` | bool | `true` | - | Show kill button on hover |
| `ShowBlacklistButton` | bool | `true` | - | Show blacklist button on hover |
| `ActionBtnSizePx` | int | `24` | `12` - `64` | Action button size in pixels |
| `ActionBtnGapPx` | int | `6` | `0` - `50` | Gap between action buttons in pixels |
| `ActionBtnRadiusPx` | int | `6` | `0` - `32` | Action button corner radius |
| `ActionFontName` | string | `Segoe UI Symbol` | - | Action button font name |
| `ActionFontSize` | int | `18` | `8` - `48` | Action button font size |
| `ActionFontWeight` | int | `700` | `100` - `900` | Action button font weight |

### Close Button Styling

Close button appearance

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `CloseButtonBorderPx` | int | `1` | `0` - `10` | Close button border width |
| `CloseButtonBorderARGB` | int | `0x88FFFFFF` | `0x0` - `0xFFFFFFFF` | Close button border color (ARGB) |
| `CloseButtonBGARGB` | int | `0xFF000000` | `0x0` - `0xFFFFFFFF` | Close button background color (ARGB) |
| `CloseButtonBGHoverARGB` | int | `0xFF888888` | `0x0` - `0xFFFFFFFF` | Close button background color on hover (ARGB) |
| `CloseButtonTextARGB` | int | `0xFFFFFFFF` | `0x0` - `0xFFFFFFFF` | Close button text color (ARGB) |
| `CloseButtonTextHoverARGB` | int | `0xFFFF0000` | `0x0` - `0xFFFFFFFF` | Close button text color on hover (ARGB) |
| `CloseButtonGlyph` | string | `X` | - | Close button glyph character |

### Kill Button Styling

Kill button appearance

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `KillButtonBorderPx` | int | `1` | `0` - `10` | Kill button border width |
| `KillButtonBorderARGB` | int | `0x88FFB4A5` | `0x0` - `0xFFFFFFFF` | Kill button border color (ARGB) |
| `KillButtonBGARGB` | int | `0xFF300000` | `0x0` - `0xFFFFFFFF` | Kill button background color (ARGB) |
| `KillButtonBGHoverARGB` | int | `0xFFD00000` | `0x0` - `0xFFFFFFFF` | Kill button background color on hover (ARGB) |
| `KillButtonTextARGB` | int | `0xFFFFE8E8` | `0x0` - `0xFFFFFFFF` | Kill button text color (ARGB) |
| `KillButtonTextHoverARGB` | int | `0xFFFFFFFF` | `0x0` - `0xFFFFFFFF` | Kill button text color on hover (ARGB) |
| `KillButtonGlyph` | string | `K` | - | Kill button glyph character |

### Blacklist Button Styling

Blacklist button appearance

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `BlacklistButtonBorderPx` | int | `1` | `0` - `10` | Blacklist button border width |
| `BlacklistButtonBorderARGB` | int | `0x88999999` | `0x0` - `0xFFFFFFFF` | Blacklist button border color (ARGB) |
| `BlacklistButtonBGARGB` | int | `0xFF000000` | `0x0` - `0xFFFFFFFF` | Blacklist button background color (ARGB) |
| `BlacklistButtonBGHoverARGB` | int | `0xFF888888` | `0x0` - `0xFFFFFFFF` | Blacklist button background color on hover (ARGB) |
| `BlacklistButtonTextARGB` | int | `0xFFFFFFFF` | `0x0` - `0xFFFFFFFF` | Blacklist button text color (ARGB) |
| `BlacklistButtonTextHoverARGB` | int | `0xFFFF0000` | `0x0` - `0xFFFFFFFF` | Blacklist button text color on hover (ARGB) |
| `BlacklistButtonGlyph` | string | `B` | - | Blacklist button glyph character |

### Columns

Extra data columns (0 = hidden)

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `ShowHeader` | bool | `true` | - | Show column headers |
| `ColFixed2` | int | `70` | `0` - `500` | Column 2 width (HWND) |
| `ColFixed3` | int | `50` | `0` - `500` | Column 3 width (PID) |
| `ColFixed4` | int | `60` | `0` - `500` | Column 4 width (Workspace) |
| `ColFixed5` | int | `0` | `0` - `500` | Column 5 width (0=hidden) |
| `ColFixed6` | int | `0` | `0` - `500` | Column 6 width (0=hidden) |
| `Col2Name` | string | `HWND` | - | Column 2 header name |
| `Col3Name` | string | `PID` | - | Column 3 header name |
| `Col4Name` | string | `WS` | - | Column 4 header name |
| `Col5Name` | string | `(empty)` | - | Column 5 header name |
| `Col6Name` | string | `(empty)` | - | Column 6 header name |

### Header Font

Column header text styling

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `HdrFontName` | string | `Segoe UI` | - | Header font name |
| `HdrFontSize` | int | `12` | `6` - `48` | Header font size |
| `HdrFontWeight` | int | `600` | `100` - `900` | Header font weight |
| `HdrARGB` | int | `0xFFD0D6DE` | `0x0` - `0xFFFFFFFF` | Header text color (ARGB) |

### Main Font

Window title text styling

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `MainFontName` | string | `Segoe UI` | - | Main font name |
| `MainFontSize` | int | `20` | `8` - `72` | Main font size |
| `MainFontWeight` | int | `400` | `100` - `900` | Main font weight |
| `MainFontNameHi` | string | `Segoe UI` | - | Main font name when highlighted |
| `MainFontSizeHi` | int | `20` | `8` - `72` | Main font size when highlighted |
| `MainFontWeightHi` | int | `800` | `100` - `900` | Main font weight when highlighted |
| `MainARGB` | int | `0xFFF0F0F0` | `0x0` - `0xFFFFFFFF` | Main text color (ARGB) |
| `MainARGBHi` | int | `0xFFF0F0F0` | `0x0` - `0xFFFFFFFF` | Main text color when highlighted (ARGB) |

### Sub Font

Subtitle row text styling

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `SubFontName` | string | `Segoe UI` | - | Sub font name |
| `SubFontSize` | int | `12` | `6` - `48` | Sub font size |
| `SubFontWeight` | int | `400` | `100` - `900` | Sub font weight |
| `SubFontNameHi` | string | `Segoe UI` | - | Sub font name when highlighted |
| `SubFontSizeHi` | int | `12` | `6` - `48` | Sub font size when highlighted |
| `SubFontWeightHi` | int | `600` | `100` - `900` | Sub font weight when highlighted |
| `SubARGB` | int | `0xFFB5C0CE` | `0x0` - `0xFFFFFFFF` | Sub text color (ARGB) |
| `SubARGBHi` | int | `0xFFB5C0CE` | `0x0` - `0xFFFFFFFF` | Sub text color when highlighted (ARGB) |

### Column Font

Column value text styling

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `ColFontName` | string | `Segoe UI` | - | Column font name |
| `ColFontSize` | int | `12` | `6` - `48` | Column font size |
| `ColFontWeight` | int | `400` | `100` - `900` | Column font weight |
| `ColFontNameHi` | string | `Segoe UI` | - | Column font name when highlighted |
| `ColFontSizeHi` | int | `12` | `6` - `48` | Column font size when highlighted |
| `ColFontWeightHi` | int | `600` | `100` - `900` | Column font weight when highlighted |
| `ColARGB` | int | `0xFFF0F0F0` | `0x0` - `0xFFFFFFFF` | Column text color (ARGB) |
| `ColARGBHi` | int | `0xFFF0F0F0` | `0x0` - `0xFFFFFFFF` | Column text color when highlighted (ARGB) |

### Scrollbar

Scrollbar appearance

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `ScrollBarEnabled` | bool | `true` | - | Show scrollbar when content overflows |
| `ScrollBarWidthPx` | int | `6` | `2` - `30` | Scrollbar width in pixels |
| `ScrollBarMarginRightPx` | int | `8` | `0` - `50` | Scrollbar right margin in pixels |
| `ScrollBarThumbARGB` | int | `0x88FFFFFF` | `0x0` - `0xFFFFFFFF` | Scrollbar thumb color (ARGB) |
| `ScrollBarGutterEnabled` | bool | `false` | - | Show scrollbar gutter background |
| `ScrollBarGutterARGB` | int | `0x30000000` | `0x0` - `0xFFFFFFFF` | Scrollbar gutter color (ARGB) |

### Footer

Footer bar appearance

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `ShowFooter` | bool | `true` | - | Show footer bar |
| `FooterBorderPx` | int | `0` | `0` - `10` | Footer border width in pixels |
| `FooterBorderARGB` | int | `0x33FFFFFF` | `0x0` - `0xFFFFFFFF` | Footer border color (ARGB) |
| `FooterBGRadius` | int | `0` | `0` - `50` | Footer background corner radius |
| `FooterBGARGB` | int | `0x0` | `0x0` - `0xFFFFFFFF` | Footer background color (ARGB) |
| `FooterTextARGB` | int | `0xFFFFFFFF` | `0x0` - `0xFFFFFFFF` | Footer text color (ARGB) |
| `FooterFontName` | string | `Segoe UI` | - | Footer font name |
| `FooterFontSize` | int | `14` | `6` - `48` | Footer font size |
| `FooterFontWeight` | int | `600` | `100` - `900` | Footer font weight |
| `FooterHeightPx` | int | `24` | `0` - `100` | Footer height in pixels |
| `FooterGapTopPx` | int | `8` | `0` - `50` | Gap between content and footer in pixels |
| `FooterPaddingX` | int | `12` | `0` - `100` | Footer horizontal padding in pixels |

## Komorebi

Settings for komorebi tiling window manager integration.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `CrossWorkspaceMethod` | enum | `MimicNative` | - | How Alt-Tabby activates windows on other workspaces.<br>MimicNative = directly uncloaks and activates via COM (like native Alt+Tab), letting komorebi reconcile.<br>RevealMove = uncloaks window, focuses it, then commands komorebi to move it back to its workspace.<br>SwitchActivate = commands komorebi to switch first, waits for confirmation, then activates (may flash previously focused window).<br>MimicNative and RevealMove require COM and fall back to SwitchActivate if COM fails. |
| `MimicNativeSettleMs` | int | `0` | `0` - `1000` | Milliseconds to wait after SwitchTo before returning (0 = no delay). Increase if cross-workspace activation is unreliable on slower systems. |
| `UseSocket` | bool | `true` | - | Send commands directly to komorebi's named pipe instead of spawning komorebic.exe. Faster. Falls back to komorebic.exe if socket unavailable. |
| `WorkspaceConfirmationMethod` | enum | `PollCloak` | - | How Alt-Tabby verifies a workspace switch completed (only used when CrossWorkspaceMethod=SwitchActivate).<br>PollKomorebic = polls komorebic CLI (spawns cmd.exe every 15ms), works on multi-monitor but highest CPU.<br>PollCloak = checks DWM cloaked state (recommended, sub-microsecond DllCall).<br>AwaitDelta = waits for store delta, lowest CPU but potentially higher latency. |

### Subscription

Event-driven komorebi integration via named pipe

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `SubPollMs` | int | `50` | `10` - `1000` | Pipe poll interval (checking for incoming data) |
| `SubIdleRecycleMs` | int | `120000` | `10000` - `600000` | Restart subscription if no events for this long (stale detection) |
| `SubFallbackPollMs` | int | `2000` | `500` - `30000` | Fallback polling interval if subscription fails |
| `SubCacheMaxAgeMs` | int | `10000` | `1000` - `60000` | Maximum age (ms) for cached workspace assignments before they are considered stale. Lower values track rapid workspace switching more accurately. |
| `SubBatchCloakEventsMs` | int | `50` | `0` - `500` | Batch cloak/uncloak events during workspace switches (ms). 0 = disabled, push immediately. |
| `MruSuppressionMs` | int | `2000` | `500` - `5000` | Duration (ms) to suppress WinEventHook MRU updates after a workspace switch. Prevents focus events from corrupting window order during transitions. |

## Setup

Installation paths and first-run settings. Managed automatically by the setup wizard.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `ExePath` | string | `(empty)` | - | Full path to AltTabby.exe after installation. Empty = use current location. |
| `RunAsAdmin` | bool | `false` | - | Run with administrator privileges via Task Scheduler (no UAC prompts after setup). |
| `AutoUpdateCheck` | bool | `true` | - | Automatically check for updates on startup. |
| `FirstRunCompleted` | bool | `false` | - | Set to true after first-run wizard completes. |
| `InstallationId` | string | `(empty)` | - | Unique installation ID (8-char hex). Generated on first run. Used for mutex naming and admin task identification. |
| `SuppressAdminRepairPrompt` | bool | `false` | - | Don't prompt to repair stale admin task. Set automatically when user clicks 'Don't ask again'. |

## Tools

Paths to external executables used by Alt-Tabby.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `AhkV2Path` | string | `(empty)` | - | Path to AHK v2 executable (for spawning subprocesses). Leave empty to auto-discover via PATH and known install locations |
| `KomorebicExe` | string | `(empty)` | - | Path to komorebic.exe. Leave empty to auto-discover via PATH and known install locations |

## IPC

Named pipe IPC for enrichment pump and launcher control signals.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `PumpPipeName` | string | `tabby_pump_v1` | - | Named pipe name for enrichment pump communication |
| `IdleTickMs` | int | `100` | `15` - `500` | Pump poll interval when idle (ms). Lower = more responsive but more CPU. |

## Store

Window store configuration: producers, filtering, timing, and caching. Most users won't need to change these.

### Producer Toggles

WinEventHook and MRU are always enabled (core). These control optional producers

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `KomorebiIntegration` | enum | `Always` | - | Komorebi integration mode. Always = subscription with polling fallback and auto-retry (recommended). Polling = periodic state polling only. Never = disabled. |
| `AdditionalWindowInformation` | enum | `Always` | - | How to resolve window icons and process names. Always = separate process with in-process fallback (recommended). NonBlocking = separate process only, no fallback. ProcessOnly = in-process only, saves memory. Never = disabled. |
| `PumpIconPruneIntervalMs` | int | `300000` | `10000` - `3600000` | Interval (ms) for pump to prune HICONs of closed windows |
| `PumpHangTimeoutMs` | int | `15000` | `5000` - `60000` | Time (ms) without a pump response before declaring it hung and restarting |

### Window Filtering

Filter windows like native Alt-Tab (skip tool windows, etc.) and apply blacklist

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `UseAltTabEligibility` | bool | `true` | - | Filter windows like native Alt-Tab (skip tool windows, etc.) |
| `UseBlacklist` | bool | `true` | - | Apply blacklist from shared/blacklist.txt |

### WinEventHook

Event-driven window change detection. Events are queued then processed in batches

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `DebounceMs` | int | `50` | `10` - `1000` | Debounce rapid events (e.g., window moving fires many events) |
| `BatchMs` | int | `100` | `10` - `2000` | Batch processing interval - how often queued events are processed |
| `IdleThreshold` | int | `10` | `1` - `100` | Empty batch ticks before pausing timer. Lower = faster idle detection, higher = more responsive to bursts. |
| `ActiveRepaintDebounceMs` | int | `250` | `0` - `2000` | Minimum interval between cosmetic repaints while overlay is active (ms). Prevents animated titles from flooding repaints. 0 = no debounce. |

### Z-Pump

When WinEventHook adds a window, Z-pump triggers a WinEnum scan for accurate Z-order

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `IntervalMs` | int | `200` | `50` - `5000` | How often to check for windows needing Z-order updates (ms) |

### WinEnum

Full window enumeration (startup, snapshot, Z-pump, safety polling)

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `MissingWindowGraceMs` | int | `1200` | `100` - `10000` | Grace period before removing a missing window (ms). Shorter values remove ghost windows faster (Outlook/Teams). Longer values tolerate slow-starting apps. |
| `FallbackScanIntervalMs` | int | `2000` | `500` - `10000` | Polling interval when WinEventHook fails and fallback scanning is active (ms). Lower = more responsive but higher CPU. |
| `SafetyPollMs` | int | `0` | `0` - `300000` | Safety polling interval (0=disabled, or 30000+ for safety net) |
| `ValidateExistenceMs` | int | `5000` | `0` - `60000` | How often to check for dead/zombie windows (ms). Lightweight check that removes windows that no longer exist. 0 = disabled. |

### MRU Lite

Fallback focus tracker (only runs if WinEventHook fails to start)

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `PollMs` | int | `250` | `50` - `5000` | Polling interval for focus tracking fallback |

### Icon Pump

Resolves window icons asynchronously with retry/backoff

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `IntervalMs` | int | `80` | `20` - `1000` | How often the pump processes its queue |
| `BatchSize` | int | `16` | `1` - `100` | Max icons to process per tick (prevents lag spikes) |
| `MaxAttempts` | int | `4` | `1` - `20` | Max attempts before giving up on a window's icon |
| `AttemptBackoffMs` | int | `300` | `50` - `5000` | Base backoff after failed attempt (multiplied by attempt number) |
| `BackoffMultiplier` | float | `1.80` | `1.00` - `5.00` | Backoff multiplier for exponential backoff (1.0 = linear) |
| `GiveUpBackoffMs` | int | `5000` | `1000` - `30000` | Long cooldown (ms) after max icon resolution attempts are exhausted. Lower values retry sooner for problematic apps. |
| `RefreshThrottleMs` | int | `5000` | `1000` - `300000` | Minimum time between icon refresh checks per window (ms). Icons are rechecked on focus and title change. The per-window throttle prevents spam from terminals with animated titles. |
| `IconRefreshOnTitleChange` | bool | `true` | - | Re-check window icons when title changes (e.g., browser tab switch). Per-window throttle (RefreshThrottleMs) prevents spam. |
| `IdleThreshold` | int | `5` | `1` - `100` | Empty queue ticks before pausing timer. Lower = faster idle detection, higher = more responsive to bursts. |
| `ResolveTimeoutMs` | int | `500` | `100` - `2000` | WM_GETICON timeout in milliseconds. Increase for slow or hung applications that need more time to respond. |

### Process Pump

Resolves PID -> process name asynchronously

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `IntervalMs` | int | `100` | `20` - `1000` | How often the pump processes its queue |
| `BatchSize` | int | `16` | `1` - `100` | Max PIDs to resolve per tick |
| `IdleThreshold` | int | `5` | `1` - `100` | Empty queue ticks before pausing timer. Lower = faster idle detection, higher = more responsive to bursts. |
| `FailedPidRetryMs` | int | `60000` | `5000` - `300000` | How long (ms) before retrying process name lookup for a PID that previously failed. |

### Cache Limits

Size limits for internal caches to prevent unbounded memory growth

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `UwpLogoMax` | int | `50` | `5` - `500` | Maximum number of cached UWP logo paths. Prevents repeated manifest parsing for multi-window UWP apps. |

## Diagnostics

Debug options, viewer settings, and test configuration. All logging disabled by default.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `FlightRecorder` | bool | `true` | - | Enable in-memory flight recorder. Press F12 after a missed Alt-Tab to dump the last ~30s of events to the recorder/ folder. Near-zero performance impact. |
| `FlightRecorderBufferSize` | int | `2000` | `500` - `10000` | Number of events kept in the flight recorder ring buffer. 2000 ≈ 30s of typical activity. Higher values capture more history at ~48 bytes per slot. |
| `FlightRecorderHotkey` | string | `*F12` | - | Hotkey to dump the flight recorder buffer. Use AHK v2 hotkey syntax (e.g. *F12, ^F12, +F11). * prefix = fire regardless of modifiers (works during Alt-Tab). Pass-through: the key still reaches other apps. |
| `ChurnLog` | bool | `false` | - | Log revision bump sources to %TEMP%\\tabby_store_error.log. Use when store rev is churning rapidly when idle. |
| `KomorebiLog` | bool | `false` | - | Log komorebi subscription events to %TEMP%\\tabby_ksub_diag.log. Use when workspace tracking has issues. |
| `AltTabTooltips` | bool | `false` | - | Show tooltips for Alt-Tab state machine debugging. Use when overlay behavior is incorrect. |
| `EventLog` | bool | `false` | - | Log Alt-Tab events to %TEMP%\\tabby_events.log. Use when debugging rapid Alt-Tab or event timing issues. |
| `WinEventLog` | bool | `false` | - | Log WinEventHook focus events to %TEMP%\\tabby_weh_focus.log. Use when focus tracking issues occur. |
| `StoreLog` | bool | `false` | - | Log MainProcess startup and operational info to %TEMP%\\tabby_store_error.log. Use for general debugging. |
| `IconPumpLog` | bool | `false` | - | Log icon pump operations to %TEMP%\\tabby_iconpump.log. Use when debugging icon resolution issues (cloaked windows, UWP apps). |
| `ProcPumpLog` | bool | `false` | - | Log process pump operations to %TEMP%\\tabby_procpump.log. Use when debugging process name resolution failures. |
| `PumpLog` | bool | `false` | - | Log EnrichmentPump operations to %TEMP%\\tabby_pump.log. Use when debugging icon/title/process enrichment in the pump subprocess. |
| `LauncherLog` | bool | `false` | - | Log launcher startup to %TEMP%\\tabby_launcher.log. Use when debugging startup issues, subprocess launch, or mutex problems. |
| `IPCLog` | bool | `false` | - | Log IPC pipe operations to %TEMP%\\tabby_ipc.log. Use when debugging pump IPC communication issues. |
| `PaintTimingLog` | bool | `false` | - | Log GUI paint timing to %TEMP%\\tabby_paint_timing.log. Use when debugging slow overlay rendering after extended idle. |
| `WebViewLog` | bool | `false` | - | Log WebView2 config editor errors to %TEMP%\\tabby_webview_debug.log. Use when debugging config editor issues. |
| `UpdateLog` | bool | `false` | - | Log auto-update check and apply steps to %TEMP%\\tabby_update.log. Use when debugging update failures. |
| `CosmeticPatchLog` | bool | `false` | - | Log cosmetic patch operations during ACTIVE state to %TEMP%\\tabby_cosmetic_patch.log. Use when debugging title/icon/processName updates in the overlay. |
| `StatsTracking` | bool | `true` | - | Track usage statistics (Alt-Tabs, quick switches, etc.) and persist to stats.ini. Shown in the dashboard. |

### Log Size Limits

Control diagnostic log file sizes

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `LogMaxKB` | int | `100` | `50` - `1000` | Maximum diagnostic log file size in KB before trimming. |
| `LogKeepKB` | int | `50` | `25` - `500` | Size to keep after log trim in KB. Must be less than LogMaxKB. |

---

*Generated on 2026-02-19 with 251 total settings.*
