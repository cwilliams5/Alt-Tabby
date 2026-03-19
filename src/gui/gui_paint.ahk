#Requires AutoHotkey v2.0
; Alt-Tabby GUI - Painting (D2D)
; All rendering via Direct2D HwndRenderTarget.
; Single-window architecture: D2D renders directly to the window surface.
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals/functions

; ========================= PAINT TIMING DEBUG LOG =========================
; Dedicated log for investigating slow paint after extended idle
; Log file: %TEMP%\tabby_paint_timing.log
; Auto-trimmed to keep last ~50KB when exceeding 100KB

global gPaint_LastPaintTick := 0      ; When we last painted (for idle duration calc)
global gPaint_SessionPaintCount := 0  ; How many paints this session
global gPaint_RepaintInProgress := false  ; Reentrancy guard (see #90)
global _gPaint_SubCache := Map()      ; Paint-owned subtitle cache (hwnd → "Class: ..." string)
global PAINT_IDLE_LOG_THRESHOLD_MS := 60000  ; Log verbose context for paints after this idle duration

; ========================= EFFECT STYLE SYSTEM =========================
; Toggled at runtime via B key (gui_interceptor.ahk).
;
; Layout state (written during paint, read by gui_main/gui_input)
global gGUI_LastRowsDesired := -1
global gGUI_RectCacheDirty := true  ; Invalidated on IDLE transition + WM_DISPLAYCHANGE
global gGUI_LeftArrowRect := { x: 0, y: 0, w: 0, h: 0 }
global gGUI_RightArrowRect := { x: 0, y: 0, w: 0, h: 0 }
global gAnim_FrameTimeDisplay := 0.0  ; Displayed frame time ms
Paint_Log(msg) {
    global cfg, LOG_PATH_PAINT_TIMING
    if (!cfg.DiagPaintTimingLog)
        return
    LogAppend(LOG_PATH_PAINT_TIMING, msg)
}

; Trim log file if it exceeds max size, keeping the tail
Paint_LogTrim() {
    global cfg, LOG_PATH_PAINT_TIMING
    if (!cfg.DiagPaintTimingLog)
        return
    LogTrim(LOG_PATH_PAINT_TIMING)
}

Paint_LogStartSession() {
    global cfg, LOG_PATH_PAINT_TIMING, gPaint_SessionPaintCount
    gPaint_SessionPaintCount := 0
    if (!cfg.DiagPaintTimingLog)
        return
    try {
        ; Delete old log on fresh boot for clean slate
        if (FileExist(LOG_PATH_PAINT_TIMING))
            FileDelete(LOG_PATH_PAINT_TIMING)
        FileAppend("========== NEW SESSION " FormatTime(, "yyyy-MM-dd HH:mm:ss") " ==========`n", LOG_PATH_PAINT_TIMING, "UTF-8")
    }
}

; ========================= CLEAR SURFACE =========================
; Clear D2D swap chain to transparent and present.
; Used by hide paths to ensure a clean buffer for the next Show.
; Preserves both guard layers:
;   1. Outer check — prevents nested D2D corruption (nested AcquireBackBuffer
;      overwrites gD2D_BackBuffer, nested BeginDraw fails D2DERR_WRONG_STATE)
;   2. Inner try/finally — prevents guard from getting stuck if any D2D call throws

; Called by D2D_DisposeResources when D2D device is lost/recreated.
; Invalidates the lazy subtitle cache so stale entries aren't reused.
Paint_InvalidateSubCache() {
    global _gPaint_SubCache
    _gPaint_SubCache := Map()
}

Paint_ClearSurface() {
    global gD2D_RT, gPaint_RepaintInProgress
    if (!gD2D_RT || gPaint_RepaintInProgress)
        return
    gPaint_RepaintInProgress := true
    try {
        if (D2D_AcquireBackBuffer()) {
            gD2D_RT.BeginDraw()
            gD2D_RT.Clear(D2D_ColorF(0x00000000))
            gD2D_RT.EndDraw()
            D2D_ReleaseBackBuffer()
            D2D_Present(0)  ; Immediate — about to hide
        }
    } catch {
        try gD2D_RT.EndDraw()   ; Best-effort: don't leave D2D in BeginDraw state
        D2D_ReleaseBackBuffer()
    } finally {
        gPaint_RepaintInProgress := false
    }
}

; ========================= MAIN REPAINT =========================

GUI_Repaint() {
    ; Reentrancy guard: Win32 calls (SetWindowPos, DwmFlush) pump the
    ; message queue, which dispatches queued WinEvent callbacks mid-paint. Those
    ; callbacks update the store and trigger debounced GUI_Repaint,
    ; creating nested repaints that paint intermediate state immediately overwritten.
    ; Guard skips nested calls; the outer paint finishes with correct final state. (#90)
    global gPaint_RepaintInProgress
    global gFR_Enabled, FR_EV_PAINT_RESIZE, FR_EV_PAINT_BLOCKED
    if (gPaint_RepaintInProgress) {
        if (gFR_Enabled)
            FR_Record(FR_EV_PAINT_BLOCKED, 1)
        return
    }
    gPaint_RepaintInProgress := true

    ; try/finally ensures reentrancy guard is ALWAYS reset, even on exception.
    ; Without this, any throw between here and function exit permanently blocks
    ; all future paints (overlay stays blank).
    try {

    Profiler.Enter("GUI_Repaint") ; @profile
    Critical "On"  ; Protect D2D render target from concurrent hotkey interruption
    global gGUI_BaseH, gGUI_LiveItems, gGUI_DisplayItems, gGUI_Sel, gGUI_ScrollTop, gGUI_LastRowsDesired, gGUI_Revealed
    global gGUI_State, cfg, gGUI_RectCacheDirty
    global gPaint_LastPaintTick, gPaint_SessionPaintCount, _gPaint_SubCache
    global gGdip_IconCache, gD2D_Res, gD2D_ResScale, gD2D_RT

    ; ===== TIMING: Start =====
    diagTiming := cfg.DiagPaintTimingLog
    if (diagTiming)
        tTotal := QPC()
    idleDuration := (gPaint_LastPaintTick > 0) ? (A_TickCount - gPaint_LastPaintTick) : -1
    gPaint_SessionPaintCount += 1
    paintNum := gPaint_SessionPaintCount
    if (paintNum = 1)
        _gPaint_SubCache.Clear()  ; PERF: purge stale subtitle entries from prior session

    ; Log context for first paint or paint after long idle
    global PAINT_IDLE_LOG_THRESHOLD_MS
    if (diagTiming && (paintNum = 1 || idleDuration > PAINT_IDLE_LOG_THRESHOLD_MS)) {
        iconCacheSize := gGdip_IconCache.Count  ; O(1) via Map.Count property
        resCount := gD2D_Res.Count
        Paint_Log("===== PAINT #" paintNum " (idle=" (idleDuration > 0 ? Round(idleDuration/1000, 1) "s" : "first") ") =====")
        Paint_Log("  Context: items=" gGUI_LiveItems.Length " frozen=" gGUI_DisplayItems.Length " iconCache=" iconCacheSize " resCount=" resCount " resScale=" gD2D_ResScale " [D2D]")
    }

    ; Use frozen display items when ACTIVE or during hide-fade animation
    ; (hide fade still paints fading frames with the frozen list, not live MRU)
    global gAnim_HidePending
    isActive := (gGUI_State = "ACTIVE")  ; PERF: cache — used multiple times below
    items := (isActive || gAnim_HidePending) ? gGUI_DisplayItems : gGUI_LiveItems

    ; Snapshot selection for this paint frame. STA message pump reentrancy
    ; during COM calls (BeginDraw, EndDraw, DwmFlush) can dispatch hotkey
    ; callbacks that mutate gGUI_Sel mid-frame. Capturing here ensures the
    ; ENFORCE logic and _GUI_PaintOverlay see the same value. (#307)
    paintSel := gGUI_Sel

    ; ENFORCE: When in ACTIVE state with ScrollKeepHighlightOnTop, ensure selection is at top
    if (isActive && cfg.GUI_ScrollKeepHighlightOnTop && items.Length > 0) {
        gGUI_ScrollTop := paintSel - 1
    }

    count := items.Length
    rowsDesired := GUI_ComputeRowsToShow(count)
    oldRows := gGUI_LastRowsDesired
    rowsChanged := (rowsDesired != oldRows)
    if (rowsChanged)
        gGUI_LastRowsDesired := rowsDesired

    ; ===== TIMING: ComputeRect =====
    if (diagTiming)
        t1 := QPC()
    ; PERF: Cache GUI_GetWindowRect results — monitor info (DPI, work area) is stable
    ; during ACTIVE state. Saves 4 DllCalls per frame (MonitorFromWindow + GetMonitorInfoW
    ; + MonitorFromRect + GetDpiForMonitor). Cache misses on: row count change (window
    ; destroyed during ACTIVE), session start (gGUI_RectCacheDirty), display change.
    static _rcXDip := 0, _rcYDip := 0, _rcWDip := 0, _rcHDip := 0
    static _rcScale := 0, _rcWaL := 0, _rcWaT := 0, _rcWaR := 0, _rcWaB := 0
    if (rowsChanged || gGUI_RectCacheDirty) {
        xDip := 0
        yDip := 0
        wDip := 0
        hDip := 0
        scale := 0
        waL := 0
        waT := 0
        waR := 0
        waB := 0
        GUI_GetWindowRect(&xDip, &yDip, &wDip, &hDip, rowsDesired, &scale, &waL, &waT, &waR, &waB)
        _rcXDip := xDip, _rcYDip := yDip, _rcWDip := wDip, _rcHDip := hDip
        _rcScale := scale, _rcWaL := waL, _rcWaT := waT, _rcWaR := waR, _rcWaB := waB
        gGUI_RectCacheDirty := false
    } else {
        xDip := _rcXDip, yDip := _rcYDip, wDip := _rcWDip, hDip := _rcHDip
        scale := _rcScale, waL := _rcWaL, waT := _rcWaT, waR := _rcWaR, waB := _rcWaB
    }
    phX := Round(xDip * scale)
    phY := Round(yDip * scale)
    phW := Round(wDip * scale)
    phH := Round(hDip * scale)
    if (diagTiming)
        tComputeRect := QPC() - t1

    ; ===== TIMING: Pre-render + Resize =====
    if (diagTiming)
        t1 := QPC()

    ; Pre-render independent layers BEFORE the resize sync window.
    ; These use their own D3D11/D2D resources at the new dimensions — they
    ; don't depend on gD2D_RT being resized yet.
    Shader_BeginBatch()
    FX_PreRenderShaderLayers(phW, phH)
    FX_PreRenderMouseEffect(phW, phH)
    Shader_EndBatch()
    BGImg_EnsureCache(phW, phH)

    ; Ensure frame loop runs for continuous shader animation
    if (FX_HasActiveShaders())
        Anim_EnsureTimer()

    ; Bidirectional resize: SetWindowPos pumps STA and CANNOT be made atomic
    ; with DComp Commit / DXGI Present.  During the STA pump a VSync can
    ; fire, compositing an intermediate frame.  The strategy ensures the HWND
    ; is always ≤ content size during the race window so the smaller boundary
    ; hides any overflow:
    ;   Shrink: SetWindowPos FIRST → HWND clips old content cleanly
    ;   Grow:   SetWindowPos LAST  → old HWND clips new content cleanly
    ; DO NOT unify both directions to the same ordering.  Two separate
    ; attempts to do so (#221) both caused visible BG image flash on grow.
    ; DComp SetClipRect + Commit + Present stay adjacent (no STA pump between
    ; them) and always land on the same compositor frame.  (#177, #234, #221)
    needsResize := (rowsChanged && gGUI_Revealed)
    isGrowing := (needsResize && rowsDesired > oldRows)
    if (needsResize) {
        if (gFR_Enabled)
            FR_Record(FR_EV_PAINT_RESIZE, oldRows, rowsDesired, phW, phH)
        ; Suppress stale hover during resize — hover row was computed against
        ; OLD overlay geometry so action buttons would render at wrong position.
        ; WM_MOUSEMOVE will recalculate correctly after resize completes.
        GUI_InvalidateHoverPosition()
        ; Shrink: resize HWND before paint.  During STA pump, old content is
        ; shown clipped by the smaller HWND — no stale-pixel exposure.
        if (!isGrowing && phW > 0 && phH > 0)
            Win_SetPosPhys(gGUI_BaseH, phX, phY, phW, phH)  ; lint-ignore: critical-heavy — paint function, STA pumping is inherent
    }
    if (diagTiming)
        tResize := QPC() - t1

    ; ===== TIMING: D2D AcquireBackBuffer + BeginDraw + PaintOverlay + EndDraw =====
    if (diagTiming)
        t1 := QPC()

    if (gD2D_RT) {
        tPaintWork := QPC()  ; Work time: AcquireBackBuffer through EndDraw (excludes Present)
        if (!D2D_AcquireBackBuffer()) {
            ; FR: back buffer acquire failed
            if (gFR_Enabled)
                FR_Record(FR_EV_PAINT_BLOCKED, 3)
            if (diagTiming) {
                tBeginDraw := 0
                tPaintOverlay := 0
                tEndDraw := 0
            }
        } else {
            gD2D_RT.BeginDraw()
            Shader_InvalidateState()  ; D2D BeginDraw dirtied shared D3D11 context

            ; Clear the render target. Acrylic/AeroGlass: transparent so compositor
            ; backdrop shows through. Solid: paint the tint color directly via D2D
            ; (SWCA gradient conflicts with DwmExtendFrame).
            clearColor := (cfg.GUI_BackdropStyle = "Solid") ? cfg.GUI_AcrylicColor : 0x00000000
            static cachedClearColor := -1, cachedColorF := 0
            if (clearColor != cachedClearColor) {
                cachedClearColor := clearColor
                cachedColorF := D2D_ColorF(clearColor)
            }
            gD2D_RT.Clear(cachedColorF)

            if (diagTiming)
                tBeginDraw := QPC() - t1

            ; ===== TIMING: PaintOverlay (the big one) =====
            if (diagTiming)
                t1 := QPC()

            _GUI_PaintOverlay(items, paintSel, phW, phH, scale, diagTiming)

            if (diagTiming)
                tPaintOverlay := QPC() - t1

            ; ===== TIMING: EndDraw + Present =====
            if (diagTiming)
                t1 := QPC()
            try {
                gD2D_RT.EndDraw()
                ; Capture render work time before Present — Present may block on
                ; VBlank with waitable swap chain, inflating the measurement.
                global gAnim_FrameTimeDisplay
                gAnim_FrameTimeDisplay := QPC() - tPaintWork
                D2D_ReleaseBackBuffer()

                ; DComp clip + Commit + Present: kept adjacent so they land on
                ; the same compositor frame.  Commit and Present ARE STA pump
                ; points, but gPaint_RepaintInProgress blocks reentrant callbacks
                ; from modifying DComp/DXGI state between them.
                if (needsResize && phW > 0 && phH > 0) {
                    D2D_SetClipRect(phW, phH)
                    D2D_Commit()
                }
                D2D_Present()
            } catch as e {
                D2D_ReleaseBackBuffer()
                D2D_HandleDeviceLoss()
                if (diagTiming)
                    Paint_Log("  ** D2D DEVICE LOSS — full pipeline recreated")
            }
            if (diagTiming)
                tEndDraw := QPC() - t1
        }
    } else {
        ; FR: render target is null — paint completely skipped
        if (gFR_Enabled)
            FR_Record(FR_EV_PAINT_BLOCKED, 2)
        if (diagTiming) {
            tBeginDraw := 0
            tPaintOverlay := 0
            tEndDraw := 0
        }
    }

    ; Grow: resize HWND AFTER Present + Commit.  During STA pump, new content
    ; is shown clipped by the old (smaller) HWND — clean transition.
    ; DwmFlush ensures the compositor has processed the new frame before
    ; SetWindowPos pumps STA, preventing stale-content flash.  (#234, #221)
    if (isGrowing && phW > 0 && phH > 0) {
        Win_DwmFlush()  ; lint-ignore: critical-heavy — paint function, STA pumping is inherent
        Win_SetPosPhys(gGUI_BaseH, phX, phY, phW, phH)  ; lint-ignore: critical-heavy
    }

    ; ===== TIMING: Reveal =====
    if (diagTiming)
        t1 := QPC()
    _GUI_RevealBoth()  ; lint-ignore: critical-heavy — paint function, STA pumping is inherent
    if (diagTiming)
        tReveal := QPC() - t1

    ; ===== TIMING: Total =====
    gPaint_LastPaintTick := A_TickCount
    if (diagTiming) {
        tTotalMs := QPC() - tTotal
        if (paintNum = 1 || idleDuration > 60000 || tTotalMs > 100)
            Paint_Log("  Timing: total=" Round(tTotalMs, 2) "ms | computeRect=" Round(tComputeRect, 2) " resize=" Round(tResize, 2) " beginDraw=" Round(tBeginDraw, 2) " paintOverlay=" Round(tPaintOverlay, 2) " endDraw=" Round(tEndDraw, 2) " reveal=" Round(tReveal, 2))
    }
    Profiler.Leave() ; @profile

    } finally {
        gPaint_RepaintInProgress := false
        Anim_ConsumeDeferredStart()
    }
}

_GUI_RevealBoth() {
    global gGUI_Base, gGUI_BaseH, gGUI_Revealed, cfg
    global gGUI_State, gGUI_OverlayVisible  ; Need access to state for race fix
    global gGUI_StealFocus

    Profiler.Enter("_GUI_RevealBoth") ; @profile

    if (gGUI_Revealed) {
        Profiler.Leave() ; @profile
        return
    }

    ; Gate: only reveal if the show sequence explicitly requested it.
    ; Without this, cosmetic patches during the grace period trigger paint →
    ; _GUI_RevealBoth, showing the overlay while gGUI_OverlayVisible is still
    ; false. The quick-switch path then skips GUI_HideOverlay() (thinks overlay
    ; was never shown), leaving a non-interactive ghost overlay on screen.
    if (!gGUI_OverlayVisible) {
        Profiler.Leave() ; @profile
        return
    }

    ; RACE FIX: Abort early if state already changed
    if (gGUI_State != "ACTIVE") {
        try gGUI_Base.Hide()
        Profiler.Leave() ; @profile
        return
    }

    try {
        if (gGUI_StealFocus) {
            ; gGUI_FocusBeforeShow already captured by _GUI_ShowOverlayWithFrozen
            DllCall("user32\ShowWindow", "ptr", gGUI_BaseH, "int", 5)  ; SW_SHOW
            DllCall("user32\SetForegroundWindow", "ptr", gGUI_BaseH)
        } else {
            gGUI_Base.Show("NA")
        }
    }

    ; RACE FIX: Check if Alt was released during Show (which pumps messages)
    if (gGUI_State != "ACTIVE") {
        try gGUI_Base.Hide()
        Profiler.Leave() ; @profile
        return
    }

    ; Single window — no separate overlay Show needed.

    Win_DwmFlush()
    gGUI_Revealed := true
    Profiler.Leave() ; @profile
}

; ========================= OVERLAY PAINTING =========================

_GUI_PaintOverlay(items, selIndex, wPhys, hPhys, scale, diagTiming := false) {
    Profiler.Enter("_GUI_PaintOverlay") ; @profile
    global gGUI_ScrollTop, gGUI_HoverRow, gGUI_FooterText, cfg, gD2D_Res, gGdip_IconCache
    global gPaint_SessionPaintCount, gPaint_LastPaintTick, _gPaint_SubCache
    global PAINT_TEXT_RIGHT_PAD_DIP, gGUI_WorkspaceMode, WS_MODE_CURRENT
    global gGUI_MonitorMode, MON_MODE_CURRENT
    global gFX_GPUReady, gD2D_BrushGeneration, gFX_HoverEffect, gFX_SelectionEffect
    global gAnim_SelPrevIndex, gAnim_SelNewIndex

    ; ===== TIMING: EnsureResources =====
    if (diagTiming) {
        tPO_Start := QPC()
        t1 := QPC()
    }
    GUI_EnsureResources(scale)
    if (diagTiming)
        tPO_Resources := QPC() - t1

    scrollTop := gGUI_ScrollTop

    cachedLayout := GUI_GetCachedLayout(scale)
    RowH := cachedLayout.RowH
    Mx := cachedLayout.Mx
    My := cachedLayout.My
    ISize := cachedLayout.ISize
    Rad := cachedLayout.Rad
    gapText := cachedLayout.gapText
    gapCols := cachedLayout.gapCols
    hdrY4 := cachedLayout.hdrY4
    hdrH28 := cachedLayout.hdrH28
    iconLeftDip := cachedLayout.iconLeftDip

    y := My
    leftX := Mx + iconLeftDip
    textX := leftX + ISize + gapText

    ; Right columns (data-driven: widthProp, nameProp, dataKey)
    ; static: allocated once per process, not per-paint (hot-path rule)
    ; dataKey matches store wire format property names directly
    static colDefs := [
        ["GUI_ColFixed6", "GUI_Col6Name", "Col6"],
        ["GUI_ColFixed5", "GUI_Col5Name", "monitorLabel"],
        ["GUI_ColFixed4", "GUI_Col4Name", "workspaceName"],
        ["GUI_ColFixed3", "GUI_Col3Name", "pid"],
        ["GUI_ColFixed2", "GUI_Col2Name", "hwndHex"]
    ]

    ; Cache column metrics + textW - only rebuild when scale, width, margin, or gap changes
    ; (avoids rebuilding cols array + Round() calls per column per frame)
    static cachedCols := [], cachedColsRightX := 0, cachedTextW := 0
    static _ccScale := -1, _ccW := -1, _ccMx := -1, _ccGap := -1, _ccTextX := -1
    if (scale != _ccScale || wPhys != _ccW || Mx != _ccMx || gapCols != _ccGap || textX != _ccTextX) {
        cachedCols := []
        cachedColsRightX := wPhys - Mx
        for _, def in colDefs {
            colW := Round(cfg.%def[1]% * scale)
            if (colW > 0) {
                cx := cachedColsRightX - colW
                cachedCols.Push({name: cfg.%def[2]%, w: colW, key: def[3], x: cx})
                cachedColsRightX := cx - gapCols
            }
        }
        tw := (cachedColsRightX - Round(PAINT_TEXT_RIGHT_PAD_DIP * scale)) - textX
        cachedTextW := (tw > 0) ? tw : 0
        _ccScale := scale, _ccW := wPhys, _ccMx := Mx, _ccGap := gapCols, _ccTextX := textX
    }
    cols := cachedCols
    textW := cachedTextW

    ; Hoist config/global reads used in compositor stack (matches D2D_Res hoisting at lines 589-609)
    bgAbove := cfg.BGImgRenderAboveShaders
    gpuReady := gFX_GPUReady
    selEffKey := gFX_SelectionEffect.key
    hovEffKey := gFX_HoverEffect.key

    ; Background image layer (configurable: above or below shader layers)
    if (!bgAbove)
        BGImg_Draw()

    ; Shader layers (N stackable layers from config)
    FX_DrawShaderLayers(wPhys, hPhys)

    if (bgAbove)
        BGImg_Draw()

    ; Mouse effect layer (above shader layers, below selection)
    FX_DrawMouseEffect(wPhys, hPhys)

    ; Text shadow params (always enabled when GPU ready)
    shadowP := _FX_GetShadowParams(gpuReady ? 1 : 0, scale)
    static _shadowBrARGB := -1, _shadowBrCached := 0, _shadowBrGen := -1
    if (shadowP.enabled) {
        if (shadowP.argb != _shadowBrARGB || _shadowBrGen != gD2D_BrushGeneration) {
            _shadowBrCached := D2D_GetCachedBrush(shadowP.argb)
            _shadowBrARGB := shadowP.argb
            _shadowBrGen := gD2D_BrushGeneration
        }
        shadowBr := _shadowBrCached
    } else {
        shadowBr := 0
    }
    shadowEnabled := shadowP.enabled
    sOffX := shadowP.offX
    sOffY := shadowP.offY

    ; Header (hoist gD2D_Res lookups — same pattern as row loop at lines 534-539)
    if (cfg.GUI_ShowHeader) {
        hdrY := y + hdrY4
        hdrTextH := cachedLayout.hdrTextH
        brHdr := gD2D_Res["brHdr"]
        tfHdr := gD2D_Res["tfHdr"]
        if (shadowEnabled) {
            D2D_DrawTextLeftShadow("Title", textX, hdrY, textW, hdrTextH, brHdr, tfHdr, shadowBr, sOffX, sOffY)
            for _, col in cols {
                D2D_DrawTextLeftShadow(col.name, col.x, hdrY, col.w, hdrTextH, brHdr, tfHdr, shadowBr, sOffX, sOffY)
            }
        } else {
            D2D_DrawTextLeft("Title", textX, hdrY, textW, hdrTextH, brHdr, tfHdr)
            for _, col in cols {
                D2D_DrawTextLeft(col.name, col.x, hdrY, col.w, hdrTextH, brHdr, tfHdr)
            }
        }
        y := y + hdrH28
    }

    contentTopY := y
    count := items.Length

    footerH := 0
    footerGap := 0
    if (cfg.GUI_ShowFooter) {
        footerH := cachedLayout.footerH
        footerGap := cachedLayout.footerGapTop
    }
    availH := hPhys - My - contentTopY - footerH - footerGap
    if (availH < 0) {
        availH := 0
    }
    contentBottomY := contentTopY + availH

    rowsCap := 0
    if (availH > 0) {
        rowsCap := Floor(availH / RowH)
    }
    rowsToDraw := count
    if (rowsToDraw > rowsCap) {
        rowsToDraw := rowsCap
    }

    ; Empty list
    if (count = 0) {
        rectX := Mx
        rectW := wPhys - 2 * Mx
        rectH := RowH
        rectY := contentTopY + Floor((availH - rectH) / 2)
        if (rectY < contentTopY) {
            rectY := contentTopY
        }
        emptyText := cfg.GUI_EmptyListText
        if (gGUI_MonitorMode = MON_MODE_CURRENT && gGUI_WorkspaceMode = WS_MODE_CURRENT)
            emptyText := "No windows on this workspace and monitor"
        else if (gGUI_WorkspaceMode = WS_MODE_CURRENT)
            emptyText := "No windows on this workspace"
        else if (gGUI_MonitorMode = MON_MODE_CURRENT)
            emptyText := "No windows on this monitor"
        if (shadowEnabled) {
            D2D_DrawTextCenteredShadow(emptyText, rectX, rectY, rectW, rectH, gD2D_Res["brMain"], gD2D_Res["tfMain"], shadowBr, sOffX, sOffY)
        } else {
            D2D_DrawTextCentered(emptyText, rectX, rectY, rectW, rectH, gD2D_Res["brMain"], gD2D_Res["tfMain"])
        }
    } else if (rowsToDraw > 0) {
        ; ===== TIMING: Row loop start =====
        if (diagTiming) {
            tPO_RowsStart := QPC()
            tPO_IconsTotal := 0
        }
        iconCacheHits := 0
        iconCacheMisses := 0

        start0 := Win_Wrap0(scrollTop, count)
        i := 0
        yRow := y

        ; Pre-check column existence once per paint (avoids HasOwnProp per-row per-col)
        if (cols.Length > 0) {
            sample := items[start0 + 1]
            for _, col in cols
                col._exists := sample.HasOwnProp(col.key)
        }

        ; Use cached layout metrics (computed once per scale change above)
        titleY := cachedLayout.titleY
        titleH := cachedLayout.titleH
        subY := cachedLayout.subY
        subH := cachedLayout.subH
        colY := cachedLayout.colY
        colH := cachedLayout.colH
        hoverRow := gGUI_HoverRow
        iconOffY := (RowH - ISize) // 2  ; PERF: hoist loop-invariant icon Y offset

        ; Hoist loop-invariant gD2D_Res lookups (12 keys × N rows → 12 lookups total)
        tfMain := gD2D_Res["tfMain"], tfMainHi := gD2D_Res["tfMainHi"]
        tfSub := gD2D_Res["tfSub"], tfSubHi := gD2D_Res["tfSubHi"]
        tfCol := gD2D_Res["tfCol"], tfColHi := gD2D_Res["tfColHi"]
        brMain := gD2D_Res["brMain"], brMainHi := gD2D_Res["brMainHi"]
        brSub := gD2D_Res["brSub"], brSubHi := gD2D_Res["brSubHi"]
        brCol := gD2D_Res["brCol"], brColHi := gD2D_Res["brColHi"]

        ; Selection rect expansion (in physical px)
        selExpandX := cachedLayout.selExpandX
        selExpandY := cachedLayout.selExpandY

        ; Hoist cfg lookups used in selection + hover paths (like D2D_Res hoisting above)
        cfgSelARGB := cfg.GUI_SelARGB
        cfgSelBorderARGB := cfg.GUI_SelBorderARGB
        cfgSelBorderW := cfg.GUI_SelBorderWidthPx
        cfgHoverARGB := cfg.GUI_HoverARGB
        cfgHovBorderARGB := cfg.GUI_HovBorderARGB
        cfgHovBorderW := cfg.GUI_HovBorderWidthPx
        cfgUseHoverSelEffect := cfg.GUI_UseHoverSelectionEffect
        cfgSelIntensityHover := cfg.GUI_SelectionIntensityForHover

        ; ===== Selection highlight (drawn BEFORE row loop for correct Z-order) =====
        ; The highlight is a background element — text/icons draw on top.
        ; When animation is active, the highlight Y is interpolated between prev and new positions.
        selW := wPhys - 2 * Mx + selExpandX * 2
        selH := RowH
        selX := Mx - selExpandX

        ; Hoist entrance animation value (used by both selection and hover shader paths)
        entranceT := Anim_GetValue("fx_sel_entrance", 1.0)

        if (selIndex > 0 && selIndex <= count) {
            ; Compute the "snap" Y (where the selection IS in the current layout)
            baseSelY := Anim_CalcSelY(selIndex, scrollTop, contentTopY, RowH, count, selExpandY)

            ; Animated slide: lerp from prevSel's Y to current sel's Y
            animT := Anim_GetValue("selSlide", 1.0)
            if (animT < 1.0 && gAnim_SelPrevIndex > 0) {
                prevSelY := Anim_CalcSelY(gAnim_SelPrevIndex, scrollTop, contentTopY, RowH, count, selExpandY)
                selY := prevSelY + (baseSelY - prevSelY) * animT
            } else {
                selY := baseSelY
            }

            if (selEffKey != "" && gpuReady) {
                ; Shader-based selection effect
                FX_PreRenderSelectionEffect(wPhys, hPhys, selX, selY, selW, selH,
                    cfgSelARGB, cfgSelBorderARGB, cfgSelBorderW, 1.0, entranceT, Rad)
                FX_DrawSelectionEffect(wPhys, hPhys, selX, selY, selW, selH, Rad)
            } else {
                ; Simple D2D fill + border (the "None" path)
                D2D_FillRoundRect(selX, selY, selW, selH, Rad, D2D_GetCachedBrush(cfgSelARGB))
                bw := cfgSelBorderW
                if (bw > 0) {
                    half := bw / 2
                    D2D_StrokeRoundRect(selX + half, selY + half, selW - bw, selH - bw, Rad, D2D_GetCachedBrush(cfgSelBorderARGB), bw)
                }
            }
        }

        while (i < rowsToDraw && (yRow + RowH <= contentBottomY)) {
            idx0 := Mod(start0 + i, count)  ; PERF: inlined Win_Wrap0 — operands always non-negative here
            idx1 := idx0 + 1
            cur := items[idx1]
            curHwnd := cur.hwnd
            curIcon := cur.iconHicon
            curTitle := cur.title
            curProc := cur.processName
            isSel := (idx1 = selIndex)

            ; Hover highlight (non-selected rows) — 4-way path
            if (!isSel && idx1 = hoverRow) {
                hoverX := selX      ; PERF: reuse selection geometry (identical computation)
                hoverY := yRow - selExpandY
                hoverW := selW      ; PERF: reuse selection geometry (identical computation)
                if (hovEffKey != "" && gpuReady) {
                    ; Path 1: Independent hover shader
                    FX_PreRenderHoverEffect(wPhys, hPhys, hoverX, hoverY, hoverW, RowH,
                        cfgHoverARGB, cfgHovBorderARGB, cfgHovBorderW, entranceT, Rad)
                    FX_DrawHoverEffect(wPhys, hPhys, hoverX, hoverY, hoverW, RowH, Rad)
                } else if (!cfgUseHoverSelEffect && selEffKey != "" && gpuReady) {
                    ; Path 2: Reuse selection shader at SelectionIntensityForHover (only when hover independence is off)
                    FX_PreRenderSelectionEffect(wPhys, hPhys, hoverX, hoverY, hoverW, RowH,
                        cfgSelARGB, cfgSelBorderARGB, cfgSelBorderW, cfgSelIntensityHover, entranceT, Rad)
                    FX_DrawSelectionEffect(wPhys, hPhys, hoverX, hoverY, hoverW, RowH, Rad)
                } else if (gpuReady) {
                    ; Path 3: GPU flat fill + border
                    FX_GPU_DrawHover(hoverX, hoverY, hoverW, RowH, Rad)
                } else if ((cfgHoverARGB >> 24) > 0 || cfgHovBorderW > 0) {
                    ; Path 4: CPU fallback fill + border
                    hoverAlpha := cfgHoverARGB >> 24
                    if (hoverAlpha > 0)
                        D2D_FillRoundRect(hoverX, hoverY, hoverW, RowH, Rad, D2D_GetCachedBrush(cfgHoverARGB))
                    bw := cfgHovBorderW
                    if (bw > 0) {
                        half := bw / 2
                        D2D_StrokeRoundRect(hoverX + half, hoverY + half, hoverW - bw, RowH - bw, Rad, D2D_GetCachedBrush(cfgHovBorderARGB), bw)
                    }
                }
            }

            ; Selection highlight is now drawn before the row loop (animated Y)
            ; Text formatting still uses isSel for highlighted fonts/colors

            ix := leftX
            iy := yRow + iconOffY

            ; ===== TIMING: Icon draw =====
            if (diagTiming)
                tIcon := QPC()
            iconWasCacheHit := false
            ; #178: cur is a live store ref — iconHicon may be zeroed after window
            ; destruction.  Try the bitmap cache regardless so frozen display items
            ; keep their last-known icon.
            iconDrawn := D2D_DrawCachedIcon(curHwnd, curIcon, ix, iy, ISize, &iconWasCacheHit)
            if (iconDrawn) {
                if (iconWasCacheHit)
                    iconCacheHits += 1
                else
                    iconCacheMisses += 1
            }
            if (!iconDrawn) {
                D2D_FillEllipse(ix, iy, ISize, ISize, D2D_GetCachedBrush(0x60808080))
            }
            if (diagTiming)
                tPO_IconsTotal += QPC() - tIcon

            tfMainUse := isSel ? tfMainHi : tfMain
            tfSubUse := isSel ? tfSubHi : tfSub
            tfColUse := isSel ? tfColHi : tfCol
            brMainUse := isSel ? brMainHi : brMain
            brSubUse := isSel ? brSubHi : brSub
            brColUse := isSel ? brColHi : brCol

            ; Text drawing (with optional shadow)
            title := curTitle
            sub := curProc
            if (sub = "") {
                ; Lazy-cache: concat "Class: " only once per display cycle, not per-frame
                sub := _gPaint_SubCache.Get(curHwnd, "")
                if (sub = "") {
                    sub := "Class: " cur.class
                    _gPaint_SubCache[curHwnd] := sub
                }
            }

            if (shadowEnabled) {
                D2D_DrawTextLeftShadow(title, textX, yRow + titleY, textW, titleH, brMainUse, tfMainUse, shadowBr, sOffX, sOffY)
                D2D_DrawTextLeftShadow(sub, textX, yRow + subY, textW, subH, brSubUse, tfSubUse, shadowBr, sOffX, sOffY)
                for _, col in cols {
                    val := col._exists ? cur.%col.key% : ""
                    D2D_DrawTextLeftShadow(val, col.x, yRow + colY, col.w, colH, brColUse, tfColUse, shadowBr, sOffX, sOffY)
                }
            } else {
                D2D_DrawTextLeft(title, textX, yRow + titleY, textW, titleH, brMainUse, tfMainUse)
                D2D_DrawTextLeft(sub, textX, yRow + subY, textW, subH, brSubUse, tfSubUse)
                for _, col in cols {
                    val := col._exists ? cur.%col.key% : ""
                    D2D_DrawTextLeft(val, col.x, yRow + colY, col.w, colH, brColUse, tfColUse)
                }
            }

            if (idx1 = hoverRow) {
                _GUI_DrawActionButtons(wPhys, yRow, RowH, scale, Mx)
            }

            yRow := yRow + RowH
            i := i + 1
        }
        ; ===== TIMING: Row loop end =====
        if (diagTiming)
            tPO_RowsTotal := QPC() - tPO_RowsStart
    }

    ; Scrollbar
    if (diagTiming)
        t1 := QPC()
    if (count > rowsToDraw && rowsToDraw > 0) {
        _GUI_DrawScrollbar(wPhys, contentTopY, rowsToDraw, RowH, start0, count, cachedLayout)
    }
    if (diagTiming)
        tPO_Scrollbar := QPC() - t1

    ; Footer
    if (diagTiming)
        t1 := QPC()
    if (cfg.GUI_ShowFooter) {
        _GUI_DrawFooter(wPhys, hPhys, shadowP, shadowBr, cachedLayout)
    }
    if (diagTiming)
        tPO_Footer := QPC() - t1

    ; Inner shadow — config-driven depth and opacity (cached — config-stable)
    static _isEnabled := -1, _isAlpha := 0, _isDepthPx := 0
    if (_isEnabled = -1) {
        _isEnabled := cfg.GUI_UseInnerShadow
        _isAlpha := cfg.GUI_InnerShadowAlpha
        _isDepthPx := cfg.GUI_InnerShadowDepthPx
    }
    if (gpuReady && _isEnabled && _isAlpha > 0) {
        FX_GPU_DrawInnerShadow(wPhys, hPhys, Round(_isDepthPx * scale), _isAlpha)
    }

    ; FPS debug overlay (toggled by F key)
    global gAnim_FPSEnabled
    if (gAnim_FPSEnabled)
        Anim_DrawFPSOverlay(wPhys, hPhys, scale)

    ; ===== TIMING: Log PaintOverlay details for first paint or paint after long idle =====
    if (diagTiming) {
        tPO_Total := QPC() - tPO_Start
        idleDuration := (gPaint_LastPaintTick > 0) ? (A_TickCount - gPaint_LastPaintTick) : -1
        if (gPaint_SessionPaintCount <= 1 || idleDuration > 60000 || tPO_Total > 50) {
            Paint_Log("  PaintOverlay: total=" Round(tPO_Total, 2) "ms | resources=" Round(tPO_Resources, 2) " rows=" (IsSet(tPO_RowsTotal) ? Round(tPO_RowsTotal, 2) : 0) " scrollbar=" Round(tPO_Scrollbar, 2) " footer=" Round(tPO_Footer, 2))
            if (IsSet(tPO_IconsTotal)) {
                Paint_Log("    Icons: totalTime=" Round(tPO_IconsTotal, 2) "ms | hits=" iconCacheHits " misses=" iconCacheMisses " rowsDrawn=" rowsToDraw)
            }
        }
    }
    Profiler.Leave() ; @profile
}

; ========================= ACTION BUTTONS =========================

; Get scaled action button metrics with minimums enforced
; Returns: {size, gap, rad} — cached per scale
GUI_GetActionBtnMetrics(scale) {
    global cfg
    static cached := {size: 0, gap: 0, rad: 0}, cachedScale := 0.0
    if (Abs(cachedScale - scale) < 0.001)
        return cached
    size := Round(cfg.GUI_ActionBtnSizePx * scale)
    if (size < 12)
        size := 12
    gap := Round(cfg.GUI_ActionBtnGapPx * scale)
    if (gap < 2)
        gap := 2
    rad := Round(cfg.GUI_ActionBtnRadiusPx * scale)
    if (rad < 2)
        rad := 2
    cached := {size: size, gap: gap, rad: rad}
    cachedScale := scale
    return cached
}

; Draw a single action button and update btnX position
_GUI_DrawOneActionButton(&btnX, btnY, size, rad, scale, bc, gap, tfAction) {
    global gGUI_HoverBtn

    if (!bc.show)
        return

    hovered := (gGUI_HoverBtn = bc.name)
    bgCol := hovered ? bc.bgHov : bc.bg
    txCol := hovered ? bc.txHov : bc.tx

    D2D_FillRoundRect(btnX, btnY, size, size, rad, D2D_GetCachedBrush(bgCol))
    if (bc.borderPx > 0) {
        D2D_StrokeRoundRect(btnX + 0.5, btnY + 0.5, size - 1, size - 1, rad, D2D_GetCachedBrush(bc.border), Round(bc.borderPx * scale))
    }
    D2D_DrawTextCentered(bc.glyph, btnX, btnY, size, size, D2D_GetCachedBrush(txCol), tfAction)
    btnX := btnX - (size + gap)
}

_GUI_DrawActionButtons(wPhys, yRow, rowHPhys, scale, Mx) {
    global gGUI_HoverBtn, cfg, gD2D_Res

    ; Pre-build button configs once (config-stable — process restarts on config change)
    ; Eliminates per-frame dynamic property concat + lookup (3 buttons × ~5 dynamic accesses)
    static btnCfg := 0, tfAction := 0
    if (!btnCfg) {
        tfAction := gD2D_Res["tfAction"]
        btnCfg := [
            {name: "close", show: cfg.GUI_ShowCloseButton,
             bg: cfg.GUI_CloseButtonBGARGB, bgHov: cfg.GUI_CloseButtonBGHoverARGB,
             tx: cfg.GUI_CloseButtonTextARGB, txHov: cfg.GUI_CloseButtonTextHoverARGB,
             border: cfg.GUI_CloseButtonBorderARGB, glyph: cfg.GUI_CloseButtonGlyph, borderPx: cfg.GUI_CloseButtonBorderPx},
            {name: "kill", show: cfg.GUI_ShowKillButton,
             bg: cfg.GUI_KillButtonBGARGB, bgHov: cfg.GUI_KillButtonBGHoverARGB,
             tx: cfg.GUI_KillButtonTextARGB, txHov: cfg.GUI_KillButtonTextHoverARGB,
             border: cfg.GUI_KillButtonBorderARGB, glyph: cfg.GUI_KillButtonGlyph, borderPx: cfg.GUI_KillButtonBorderPx},
            {name: "blacklist", show: cfg.GUI_ShowBlacklistButton,
             bg: cfg.GUI_BlacklistButtonBGARGB, bgHov: cfg.GUI_BlacklistButtonBGHoverARGB,
             tx: cfg.GUI_BlacklistButtonTextARGB, txHov: cfg.GUI_BlacklistButtonTextHoverARGB,
             border: cfg.GUI_BlacklistButtonBorderARGB, glyph: cfg.GUI_BlacklistButtonGlyph, borderPx: cfg.GUI_BlacklistButtonBorderPx}
        ]
    }

    metrics := GUI_GetActionBtnMetrics(scale)
    size := metrics.size
    gap := metrics.gap
    rad := metrics.rad
    marR := Mx

    btnX := wPhys - marR - size
    btnY := yRow + (rowHPhys - size) // 2

    for _, bc in btnCfg
        _GUI_DrawOneActionButton(&btnX, btnY, size, rad, scale, bc, gap, tfAction)
}

; ========================= SCROLLBAR =========================

; PERF: start0 passed from caller (already computed in _GUI_PaintOverlay) to avoid
; redundant Win_Wrap0 call
_GUI_DrawScrollbar(wPhys, contentTopY, rowsDrawn, rowHPhys, start0, count, cachedLayout) {
    global cfg, gD2D_BrushGeneration
    Profiler.Enter("_GUI_DrawScrollbar") ; @profile
    if (!cfg.GUI_ScrollBarEnabled || count <= 0 || rowsDrawn <= 0 || rowHPhys <= 0) {
        Profiler.Leave() ; @profile
        return
    }

    trackH := rowsDrawn * rowHPhys
    if (trackH <= 0) {
        Profiler.Leave() ; @profile
        return
    }

    ; Use cached layout passed from caller (avoids redundant GUI_GetCachedLayout call)
    cl := cachedLayout
    trackW := cl.sbTrackW
    marR := cl.sbMarR

    x := wPhys - marR - trackW
    y := contentTopY
    r := trackW // 2

    thumbH := Floor(trackH * rowsDrawn / count)
    if (thumbH < 3) {
        thumbH := 3
    }

    startRatio := start0 / count
    y1 := y + Floor(startRatio * trackH)
    y2 := y1 + thumbH
    yEnd := y + trackH

    ; Static-cached scrollbar brushes (config-stable, re-cached on device loss)
    static _sbGutterARGB := -1, _sbGutterBr := 0
    static _sbThumbARGB := -1, _sbThumbBr := 0, _sbGen := -1
    gutterARGB := cfg.GUI_ScrollBarGutterARGB
    thumbARGB := cfg.GUI_ScrollBarThumbARGB
    if (_sbGen != gD2D_BrushGeneration || gutterARGB != _sbGutterARGB || thumbARGB != _sbThumbARGB) {
        _sbGutterBr := D2D_GetCachedBrush(gutterARGB)
        _sbThumbBr := D2D_GetCachedBrush(thumbARGB)
        _sbGutterARGB := gutterARGB
        _sbThumbARGB := thumbARGB
        _sbGen := gD2D_BrushGeneration
    }

    if (cfg.GUI_ScrollBarGutterEnabled) {
        D2D_FillRoundRect(x, y, trackW, trackH, r, _sbGutterBr)
    }

    thumbBr := _sbThumbBr
    if (y2 <= yEnd) {
        D2D_FillRoundRect(x, y1, trackW, thumbH, r, thumbBr)
    } else {
        h1 := yEnd - y1
        if (h1 > 0) {
            D2D_FillRoundRect(x, y1, trackW, h1, r, thumbBr)
        }
        h2 := y2 - yEnd
        if (h2 > 0) {
            D2D_FillRoundRect(x, y, trackW, h2, r, thumbBr)
        }
    }
    Profiler.Leave() ; @profile
}

; ========================= FOOTER =========================

_GUI_DrawFooter(wPhys, hPhys, shadowP, shadowBr, cachedLayout) {
    global gGUI_FooterText, gGUI_LeftArrowRect, gGUI_RightArrowRect, gGUI_HoverBtn, cfg, gD2D_Res
    global gD2D_BrushGeneration
    Profiler.Enter("_GUI_DrawFooter") ; @profile

    hasShadow := shadowP.enabled
    sOffX := shadowP.offX
    sOffY := shadowP.offY

    ; Use cached layout passed from caller (avoids redundant GUI_GetCachedLayout call)
    cl := cachedLayout
    fh := cl.footerH
    mx := cl.Mx
    my := cl.My

    fx := mx
    fy := hPhys - my - fh
    fw := wPhys - 2 * mx
    fr := cl.footerBGRad

    ; Static-cached footer brushes (config-stable, re-cached on device loss)
    static _ftBgARGB := -1, _ftBgBr := 0
    static _ftBdrARGB := -1, _ftBdrBr := 0, _ftGen := -1
    bgARGB := cfg.GUI_FooterBGARGB
    bdrARGB := cfg.GUI_FooterBorderARGB
    if (_ftGen != gD2D_BrushGeneration || bgARGB != _ftBgARGB || bdrARGB != _ftBdrARGB) {
        _ftBgBr := D2D_GetCachedBrush(bgARGB)
        _ftBdrBr := D2D_GetCachedBrush(bdrARGB)
        _ftBgARGB := bgARGB
        _ftBdrARGB := bdrARGB
        _ftGen := gD2D_BrushGeneration
    }

    ; Draw footer background
    D2D_FillRoundRect(fx, fy, fw, fh, fr, _ftBgBr)
    if (cfg.GUI_FooterBorderPx > 0) {
        D2D_StrokeRoundRect(fx + 0.5, fy + 0.5, fw - 1, fh - 1, fr, _ftBdrBr, cl.footerBorderPx)
    }

    ; Arrow dimensions
    arrowW := cl.footerArrowW
    arrowPad := cl.footerArrowPad

    ; Hoist repeated gD2D_Res lookups
    tfFooter := gD2D_Res["tfFooter"]
    brFooterText := gD2D_Res["brFooterText"]
    static leftArrowGlyph := Chr(0x2190)
    static rightArrowGlyph := Chr(0x2192)

    ; Arrow brush: highlight on hover, normal otherwise
    brArrowL := (gGUI_HoverBtn = "arrowLeft") ? gD2D_Res["brMainHi"] : brFooterText
    brArrowR := (gGUI_HoverBtn = "arrowRight") ? gD2D_Res["brMainHi"] : brFooterText

    ; Left arrow
    leftArrowX := fx + arrowPad
    leftArrowY := fy
    leftArrowW := arrowW
    leftArrowH := fh

    ; Store hit region for click detection
    gGUI_LeftArrowRect.x := leftArrowX
    gGUI_LeftArrowRect.y := leftArrowY
    gGUI_LeftArrowRect.w := leftArrowW
    gGUI_LeftArrowRect.h := leftArrowH

    ; Draw left arrow
    if (hasShadow) {
        D2D_DrawTextCenteredShadow(leftArrowGlyph, leftArrowX, leftArrowY, leftArrowW, leftArrowH, brArrowL, tfFooter, shadowBr, sOffX, sOffY)
    } else {
        D2D_DrawTextCentered(leftArrowGlyph, leftArrowX, leftArrowY, leftArrowW, leftArrowH, brArrowL, tfFooter)
    }

    ; Right arrow
    rightArrowX := fx + fw - arrowPad - arrowW
    rightArrowY := fy
    rightArrowW := arrowW
    rightArrowH := fh

    ; Store hit region for click detection
    gGUI_RightArrowRect.x := rightArrowX
    gGUI_RightArrowRect.y := rightArrowY
    gGUI_RightArrowRect.w := rightArrowW
    gGUI_RightArrowRect.h := rightArrowH

    ; Draw right arrow
    if (hasShadow) {
        D2D_DrawTextCenteredShadow(rightArrowGlyph, rightArrowX, rightArrowY, rightArrowW, rightArrowH, brArrowR, tfFooter, shadowBr, sOffX, sOffY)
    } else {
        D2D_DrawTextCentered(rightArrowGlyph, rightArrowX, rightArrowY, rightArrowW, rightArrowH, brArrowR, tfFooter)
    }

    ; Center text (between arrows)
    textX := leftArrowX + leftArrowW + arrowPad
    textW := rightArrowX - textX - arrowPad
    if (textW < 0) {
        textW := 0
    }

    if (hasShadow) {
        D2D_DrawTextCenteredShadow(gGUI_FooterText, textX, fy, textW, fh, brFooterText, tfFooter, shadowBr, sOffX, sOffY)
    } else {
        D2D_DrawTextCentered(gGUI_FooterText, textX, fy, textW, fh, brFooterText, tfFooter)
    }
    Profiler.Leave() ; @profile
}

; Shadow text wrappers moved to gui_gdip.ahk as inlined D2D_DrawTextLeftShadow /
; D2D_DrawTextCenteredShadow (single function call with one null check + one
; alignment guard for both shadow and main text draws).

; Get shadow parameters for current effect style.
; Returns {enabled, offX, offY, argb} or {enabled: false}.
; Uses config values (GUI_TextShadowAlpha, GUI_TextShadowDistancePx).
; Static cached objects — callers only read properties, never mutate.
_FX_GetShadowParams(fx, scale) {
    static sDisabled := {enabled: false, offX: 0, offY: 0, argb: 0}
    static sEnabled := {enabled: true, offX: 0, offY: 0, argb: 0}
    static sFx := -1, sScale := -1, sAlpha := -1, sDist := -1

    global cfg
    Profiler.Enter("_FX_GetShadowParams") ; @profile
    if (!fx || !cfg.GUI_UseTextShadow) {
        Profiler.Leave() ; @profile
        return sDisabled
    }
    alpha := cfg.GUI_TextShadowAlpha
    if (alpha <= 0) {
        Profiler.Leave() ; @profile
        return sDisabled
    }

    dist := cfg.GUI_TextShadowDistancePx
    if (fx != sFx || scale != sScale || alpha != sAlpha || dist != sDist) {
        sFx := fx
        sScale := scale
        sAlpha := alpha
        sDist := dist
        off := Max(1, Round(dist * scale))
        sEnabled.offX := off
        sEnabled.offY := off
        sEnabled.argb := (alpha << 24) | 0x000000
    }
    Profiler.Leave() ; @profile
    return sEnabled
}


