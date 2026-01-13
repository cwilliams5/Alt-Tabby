#Requires AutoHotkey v2.0

; GUI Configuration - Appearance and behavior settings

; Background Window
global GUI_AcrylicAlpha    := 0x33
global GUI_AcrylicBaseRgb  := 0x330000
global GUI_CornerRadiusPx  := 18
global GUI_AlwaysOnTop     := true

; Selection scroll behavior
global GUI_ScrollKeepHighlightOnTop := true

; Size config
global GUI_ScreenWidthPct := 0.60
global GUI_RowsVisibleMin := 1
global GUI_RowsVisibleMax := 8

; Virtual list look
global GUI_RowHeight   := 56
global GUI_MarginX     := 18
global GUI_MarginY     := 18
global GUI_IconSize    := 36
global GUI_IconLeftMargin := 8
global GUI_RowRadius   := 12
global GUI_SelARGB     := 0x662B5CAD

; Action keystrokes
global GUI_AllowCloseKeystroke     := true
global GUI_AllowKillKeystroke      := true
global GUI_AllowBlacklistKeystroke := true

; Show row action buttons on hover
global GUI_ShowCloseButton      := true
global GUI_ShowKillButton       := true
global GUI_ShowBlacklistButton  := true

; Action button geometry
global GUI_ActionBtnSizePx   := 24
global GUI_ActionBtnGapPx    := 6
global GUI_ActionBtnRadiusPx := 6
global GUI_ActionFontName    := "Segoe UI Symbol"
global GUI_ActionFontSize    := 18
global GUI_ActionFontWeight  := 700

; Close button styling
global GUI_CloseButtonBorderPx      := 1
global GUI_CloseButtonBorderARGB    := 0x88FFFFFF
global GUI_CloseButtonBGARGB        := 0xFF000000
global GUI_CloseButtonBGHoverARGB   := 0xFF888888
global GUI_CloseButtonTextARGB      := 0xFFFFFFFF
global GUI_CloseButtonTextHoverARGB := 0xFFFF0000
global GUI_CloseButtonGlyph         := "X"

; Kill button styling
global GUI_KillButtonBorderPx       := 1
global GUI_KillButtonBorderARGB     := 0x88FFB4A5
global GUI_KillButtonBGARGB         := 0xFF300000
global GUI_KillButtonBGHoverARGB    := 0xFFD00000
global GUI_KillButtonTextARGB       := 0xFFFFE8E8
global GUI_KillButtonTextHoverARGB  := 0xFFFFFFFF
global GUI_KillButtonGlyph          := "K"

; Blacklist button styling
global GUI_BlacklistButtonBorderPx      := 1
global GUI_BlacklistButtonBorderARGB    := 0x88999999
global GUI_BlacklistButtonBGARGB        := 0xFF000000
global GUI_BlacklistButtonBGHoverARGB   := 0xFF888888
global GUI_BlacklistButtonTextARGB      := 0xFFFFFFFF
global GUI_BlacklistButtonTextHoverARGB := 0xFFFF0000
global GUI_BlacklistButtonGlyph         := "B"

; Extra columns
global GUI_ColFixed2   := 70   ; HWND
global GUI_ColFixed3   := 50   ; PID
global GUI_ColFixed4   := 60   ; Workspace
global GUI_ColFixed5   := 0
global GUI_ColFixed6   := 0

global GUI_ShowHeader := true
global GUI_Col2Name := "HWND"
global GUI_Col3Name := "PID"
global GUI_Col4Name := "WS"
global GUI_Col5Name := ""
global GUI_Col6Name := ""

; Header font
global GUI_HdrFontName   := "Segoe UI"
global GUI_HdrFontSize   := 12
global GUI_HdrFontWeight := 600
global GUI_HdrARGB       := 0xFFD0D6DE

; Main Font
global GUI_MainFontName := "Segoe UI"
global GUI_MainFontSize := 20
global GUI_MainFontWeight := 400
global GUI_MainFontNameHi := "Segoe UI"
global GUI_MainFontSizeHi := 20
global GUI_MainFontWeightHi := 800
global GUI_MainARGB := 0xFFF0F0F0
global GUI_MainARGBHi := 0xFFF0F0F0

; Sub Font
global GUI_SubFontName := "Segoe UI"
global GUI_SubFontSize := 12
global GUI_SubFontWeight := 400
global GUI_SubFontNameHi := "Segoe UI"
global GUI_SubFontSizeHi := 12
global GUI_SubFontWeightHi := 600
global GUI_SubARGB     := 0xFFB5C0CE
global GUI_SubARGBHi   := 0xFFB5C0CE

; Col Font
global GUI_ColFontName := "Segoe UI"
global GUI_ColFontSize := 12
global GUI_ColFontWeight := 400
global GUI_ColFontNameHi := "Segoe UI"
global GUI_ColFontSizeHi := 12
global GUI_ColFontWeightHi := 600
global GUI_ColARGB := 0xFFF0F0F0
global GUI_ColARGBHi := 0xFFF0F0F0

; Scrollbar
global GUI_ScrollBarEnabled         := true
global GUI_ScrollBarWidthPx         := 6
global GUI_ScrollBarMarginRightPx   := 8
global GUI_ScrollBarThumbARGB       := 0x88FFFFFF
global GUI_ScrollBarGutterEnabled   := false
global GUI_ScrollBarGutterARGB      := 0x30000000

global GUI_EmptyListText := "No Windows"

; Footer
global GUI_ShowFooter          := true
global GUI_FooterTextAlign     := "center"
global GUI_FooterBorderPx      := 0
global GUI_FooterBorderARGB    := 0x33FFFFFF
global GUI_FooterBGRadius      := 0
global GUI_FooterBGARGB        := 0x00000000
global GUI_FooterTextARGB      := 0xFFFFFFFF
global GUI_FooterFontName      := "Segoe UI"
global GUI_FooterFontSize      := 14
global GUI_FooterFontWeight    := 600
global GUI_FooterHeightPx      := 24
global GUI_FooterGapTopPx      := 8
global GUI_FooterPaddingX      := 12
