#Requires AutoHotkey v2.0
; ========================= ANIMATION ENGINE =========================
; Tween registry, frame-cap timer, easing functions, FPS debug overlay.
;
; Three modes (cfg.PerfAnimationType):
;   None    — single paint per event, zero CPU idle
;   Minimal — frame-cap timer on events, auto-stop when tweens complete
;   Full    — frame-cap timer runs continuously while overlay visible
;
; Frame loop: one-shot SetTimer launches _Anim_FrameLoop which runs a
; while-loop. Each iteration: Critical On → paint → Critical Off →
; Sleep(0) message pump → NtYieldExecution spin-wait to frame boundary.
; Hotkeys fire during Sleep(0). Spin-wait gives sub-ms frame precision.

; ========================= GLOBALS =========================

global gAnim_Tweens := Map()          ; name -> {startTime, duration, from, to, easing, current, done}
global gAnim_TimerRunning := false
global gAnim_LastFrameTime := 0.0     ; QPC ms of last frame
global gAnim_FrameDt := 0.0           ; Delta ms since last frame
global gAnim_FrameCapMs := 6.94       ; ms per frame (default ~144Hz, set by Anim_Init)
global gAnim_TargetFPS := 144         ; Resolved from config or monitor
global gAnim_TimerPeriodOn := false   ; timeBeginPeriod(1) active?
global gAnim_FPSEnabled := false      ; FPS debug overlay toggle (F key)
global gAnim_OverlayOpacity := 1.0    ; Current overlay fade opacity (0.0-1.0)
global gAnim_HidePending := false     ; Hide-fade in progress
global gAnim_SelPrevIndex := 0        ; Previous selection index (for slide Y calc)
global gAnim_SelNewIndex := 0         ; New selection index (for slide Y calc)
global gFX_AmbientTime := 0.0         ; Cumulative ms for ambient loops (Full mode)

; FPS debug counter state
global gAnim_FPSFrameCount := 0
global gAnim_FPSLastSample := 0.0
global gAnim_FPSDisplay := 0          ; Displayed FPS (updated every 500ms)
global gAnim_FrameTimeDisplay := 0.0  ; Displayed frame time ms

; ========================= INIT =========================

Anim_Init() {
    global gAnim_TargetFPS, gAnim_FrameCapMs, cfg

    ; Resolve AnimationFPS: "Auto" → monitor rate, else parse int (no cap)
    fpsStr := cfg.PerfAnimationFPS
    if (fpsStr = "Auto" || fpsStr = "auto") {
        gAnim_TargetFPS := _Anim_GetMonitorRefreshRate()
    } else {
        parsed := 0
        try parsed := Integer(fpsStr)
        if (parsed < 10)
            parsed := 60
        gAnim_TargetFPS := parsed
    }

    gAnim_FrameCapMs := 1000.0 / gAnim_TargetFPS
}

_Anim_GetMonitorRefreshRate() {
    ; EnumDisplaySettingsW with ENUM_CURRENT_SETTINGS (-1) for primary monitor
    ; DEVMODEW: dmSize at offset 68, dmDisplayFrequency at offset 184
    ; (offset 120 is DEVMODEA — wrong for the W variant)
    dm := Buffer(220, 0)
    NumPut("ushort", 220, dm, 68)  ; dmSize
    ok := DllCall("EnumDisplaySettingsW", "ptr", 0, "int", -1, "ptr", dm, "int")
    if (!ok)
        return 60
    freq := NumGet(dm, 184, "uint")  ; dmDisplayFrequency (DEVMODEW offset)
    return (freq > 0 && freq < 1000) ? freq : 60
}

; ========================= TWEEN ENGINE =========================

Anim_StartTween(name, from, to, durationMs, easingFunc) {
    global gAnim_Tweens, cfg
    dur := durationMs * cfg.PerfAnimationSpeed
    if (dur < 1)
        dur := 1
    gAnim_Tweens[name] := {startTime: QPC(), duration: dur, from: from, to: to, easing: easingFunc, current: from, done: false}
    Anim_EnsureTimer()
}

Anim_GetValue(name, defaultVal := 0) {
    global gAnim_Tweens
    if (gAnim_Tweens.Has(name))
        return gAnim_Tweens[name].current
    return defaultVal
}

Anim_CancelTween(name) {
    global gAnim_Tweens
    if (gAnim_Tweens.Has(name))
        gAnim_Tweens.Delete(name)
}

Anim_CancelAll() {
    global gAnim_Tweens, gFX_AmbientTime, gAnim_HidePending
    gAnim_Tweens := Map()
    gFX_AmbientTime := 0.0
    gAnim_HidePending := false
    Anim_StopTimer()
}

_Anim_UpdateTweens() {
    global gAnim_Tweens
    now := QPC()
    activeCount := 0
    for _, tw in gAnim_Tweens {
        if (tw.done)
            continue
        elapsed := now - tw.startTime
        t := elapsed / tw.duration
        if (t >= 1.0) {
            tw.current := tw.to
            tw.done := true
        } else {
            ; Apply easing
            eased := tw.easing.Call(t)
            tw.current := tw.from + (tw.to - tw.from) * eased
            activeCount += 1
        }
    }
    return activeCount
}

; ========================= FRAME LOOP =========================

Anim_EnsureTimer() {
    global gAnim_TimerRunning, gAnim_TimerPeriodOn, gAnim_LastFrameTime, cfg
    global gAnim_FPSFrameCount, gAnim_FPSLastSample
    if (cfg.PerfAnimationType = "None")
        return
    if (gAnim_TimerRunning)
        return
    if (!gAnim_TimerPeriodOn) {
        DllCall("winmm\timeBeginPeriod", "uint", 1)
        gAnim_TimerPeriodOn := true
    }
    gAnim_LastFrameTime := QPC()
    gAnim_FPSLastSample := gAnim_LastFrameTime
    gAnim_FPSFrameCount := 0
    gAnim_TimerRunning := true
    ; One-shot timer launches the frame loop in its own thread.
    ; The loop runs until gAnim_TimerRunning is set false.
    SetTimer(_Anim_FrameLoop, -1)
}

Anim_StopTimer() {
    global gAnim_TimerRunning, gAnim_TimerPeriodOn
    gAnim_TimerRunning := false
    ; Cancel pending one-shot if loop hasn't started yet
    SetTimer(_Anim_FrameLoop, 0)
    if (gAnim_TimerPeriodOn) {
        DllCall("winmm\timeEndPeriod", "uint", 1)
        gAnim_TimerPeriodOn := false
    }
}

; Frame loop: runs as a persistent thread via one-shot SetTimer.
; Each iteration: Critical On (paint) → Critical Off → Sleep+spin (frame pacing).
; Hotkeys fire during the Sleep phase between frames.
_Anim_FrameLoop() {
    global gAnim_TimerRunning, gAnim_Tweens, gAnim_LastFrameTime, gAnim_FrameCapMs, gAnim_FrameDt
    global gAnim_OverlayOpacity, gAnim_HidePending, gAnim_FrameTimeDisplay
    global gGUI_OverlayVisible, cfg

    while (gAnim_TimerRunning) {
        Critical "On"

        now := QPC()
        gAnim_FrameDt := now - gAnim_LastFrameTime
        gAnim_LastFrameTime := now

        ; Update all active tweens
        activeCount := _Anim_UpdateTweens()

        ; Sync overlay opacity from tween → apply to window alpha
        _Anim_SyncOverlayOpacity()
        _Anim_ApplyWindowAlpha()

        ; Check if hide-fade completed
        if (gAnim_HidePending && gAnim_Tweens.Has("hideFade") && gAnim_Tweens["hideFade"].done) {
            _Anim_OnHideFadeComplete()
            Critical "Off"
            continue  ; CancelAll sets gAnim_TimerRunning=false → loop exits
        }

        ; Update ambient animations (Full mode only)
        if (cfg.PerfAnimationType = "Full" && gGUI_OverlayVisible)
            FX_UpdateAmbient(gAnim_FrameDt)

        ; Paint frame
        if (gGUI_OverlayVisible) {
            tPaint := QPC()
            GUI_Repaint()
            gAnim_FrameTimeDisplay := QPC() - tPaint
        }

        ; Update FPS counter
        _Anim_UpdateFPSCounter(now)

        ; Auto-stop (Minimal mode: exit when no active tweens)
        if (cfg.PerfAnimationType = "Minimal" && activeCount = 0 && !gAnim_HidePending)
            break

        Critical "Off"

        ; Pump messages once (hotkeys fire here), then spin-wait for frame cap.
        ; Sleep(0) yields to message loop without the ~15ms overhead of Sleep(N>0).
        ; AHK's MsgSleep processes pending messages then returns immediately for N=0.
        Sleep(0)

        ; Spin-wait for precise frame timing (NtYieldExecution yields CPU timeslice)
        _Anim_FramePace()
    }

    Anim_StopTimer()
}

; QPC spin-wait until next frame boundary. NtYieldExecution yields CPU timeslice
; each iteration (~0.5ms per yield). For 120Hz: ~5ms spin, for 60Hz: ~13ms spin.
; AHK's Sleep(N>0) goes through MsgSleep which oversleeps by ~10-15ms, making it
; unusable for sub-20ms frame caps. Pure spin is precise and CPU-cheap (yielded).
_Anim_FramePace() {
    global gAnim_LastFrameTime, gAnim_FrameCapMs
    nextFrame := gAnim_LastFrameTime + gAnim_FrameCapMs
    while (QPC() < nextFrame)
        DllCall("ntdll\NtYieldExecution")
}

_Anim_SyncOverlayOpacity() {
    global gAnim_OverlayOpacity, gAnim_Tweens
    ; hideFade takes priority — when present it's the latest intent and the
    ; completed showFade tween is still in the map (never removed until CancelAll).
    if (gAnim_Tweens.Has("hideFade")) {
        gAnim_OverlayOpacity := gAnim_Tweens["hideFade"].current
        if (gAnim_OverlayOpacity < 0.0)
            gAnim_OverlayOpacity := 0.0
    } else if (gAnim_Tweens.Has("showFade")) {
        gAnim_OverlayOpacity := gAnim_Tweens["showFade"].current
        if (gAnim_Tweens["showFade"].done) {
            gAnim_OverlayOpacity := 1.0
            ; Show-fade complete: remove WS_EX_LAYERED so DWM resumes
            ; live acrylic blur (layered windows get stale cached blur).
            _Anim_RemoveLayered()
        }
    }
}

; Apply gAnim_OverlayOpacity to the window via SetLayeredWindowAttributes.
; DWM fades the entire composition (content + acrylic + shadow) as one unit.
_Anim_ApplyWindowAlpha() {
    global gAnim_OverlayOpacity, gGUI_BaseH
    if (gAnim_OverlayOpacity >= 1.0)
        return
    alpha := Round(gAnim_OverlayOpacity * 255)
    if (alpha < 0)
        alpha := 0
    if (alpha > 255)
        alpha := 255
    DllCall("SetLayeredWindowAttributes", "ptr", gGUI_BaseH, "uint", 0, "uchar", alpha, "uint", 2)  ; LWA_ALPHA=2
}

; Add WS_EX_LAYERED for fade animation. Called at fade start.
Anim_AddLayered() {
    global gGUI_BaseH, GWL_EXSTYLE, WS_EX_LAYERED
    exStyle := DllCall("user32\GetWindowLong" (A_PtrSize = 8 ? "Ptr" : ""), "ptr", gGUI_BaseH, "int", GWL_EXSTYLE, "ptr")
    if (!(exStyle & WS_EX_LAYERED))
        DllCall("user32\SetWindowLong" (A_PtrSize = 8 ? "Ptr" : ""), "ptr", gGUI_BaseH, "int", GWL_EXSTYLE, "ptr", exStyle | WS_EX_LAYERED)
}

; Remove WS_EX_LAYERED after fade completes. Restores live acrylic blur.
_Anim_RemoveLayered() {
    global gGUI_BaseH, GWL_EXSTYLE, WS_EX_LAYERED
    exStyle := DllCall("user32\GetWindowLong" (A_PtrSize = 8 ? "Ptr" : ""), "ptr", gGUI_BaseH, "int", GWL_EXSTYLE, "ptr")
    if (exStyle & WS_EX_LAYERED) {
        DllCall("user32\SetWindowLong" (A_PtrSize = 8 ? "Ptr" : ""), "ptr", gGUI_BaseH, "int", GWL_EXSTYLE, "ptr", exStyle & ~WS_EX_LAYERED)
    }
}

_Anim_OnHideFadeComplete() {
    global gAnim_HidePending, gAnim_OverlayOpacity
    gAnim_HidePending := false
    gAnim_OverlayOpacity := 1.0
    ; Perform actual window hide (same sequence as GUI_HideOverlay's immediate path)
    _Anim_DoActualHide()
    Anim_CancelAll()
}

; Force-complete a pending hide-fade immediately.
; Called when a new Alt+Tab sequence starts during the fade — the overlay must
; finish hiding before the next show sequence can set gGUI_OverlayVisible.
Anim_ForceCompleteHide() {
    global gAnim_HidePending
    if (!gAnim_HidePending)
        return
    _Anim_OnHideFadeComplete()
}

_Anim_DoActualHide() {
    global gGUI_OverlayVisible, gGUI_Base, gGUI_BaseH, gGUI_Revealed, gD2D_RT
    global cfg, GUI_LOG_TRIM_EVERY_N_HIDES
    global gGUI_DisplayItems
    static hideCount := 0

    if (!gGUI_OverlayVisible)
        return

    ; Release deferred display items — kept alive during hide-fade so the
    ; frame loop paints the frozen list while fading out (not the live MRU).
    gGUI_DisplayItems := []

    GUI_ClearHoverState()

    ; Clear D2D surface
    if (gD2D_RT) {
        try {
            gD2D_RT.BeginDraw()
            gD2D_RT.Clear(D2D_ColorF(0x00000000))
            gD2D_RT.EndDraw()
            D2D_Present()
        } catch {
        }
    }

    try {
        gGUI_Base.Hide()
    }
    gGUI_OverlayVisible := false
    gGUI_Revealed := false

    ; Remove WS_EX_LAYERED and reset alpha so next Show gets fresh DWM blur
    _Anim_RemoveLayered()
    DllCall("SetLayeredWindowAttributes", "ptr", gGUI_BaseH, "uint", 0, "uchar", 255, "uint", 2)

    hideCount += 1
    if (Mod(hideCount, GUI_LOG_TRIM_EVERY_N_HIDES) = 0) {
        Paint_LogTrim()
    }
}

; ========================= SELECTION SLIDE =========================

Anim_StartSelectionSlide(prevSel, newSel, count) { ; lint-ignore: dead-param
    global gAnim_SelPrevIndex, gAnim_SelNewIndex
    Anim_CancelTween("selSlide")
    gAnim_SelPrevIndex := prevSel
    gAnim_SelNewIndex := newSel
    ; 0→1 tween: paint code lerps between prev and new Y positions
    Anim_StartTween("selSlide", 0.0, 1.0, 120, Anim_EaseOutCubic)
}

; Compute the Y position of a selection index in the current layout.
; Used by paint code to resolve prevSel Y for animation interpolation.
Anim_CalcSelY(selIndex, scrollTop, contentTopY, RowH, count, selExpandY) {
    ; Row offset from scroll position (wrapping)
    rowOffset := Win_Wrap0(selIndex - 1 - scrollTop, count)
    return contentTopY + rowOffset * RowH - selExpandY
}

; ========================= EASING FUNCTIONS =========================

Anim_EaseOutCubic(t) {
    inv := 1.0 - t
    return 1.0 - inv * inv * inv
}

Anim_EaseOutQuad(t) {
    inv := 1.0 - t
    return 1.0 - inv * inv
}

Anim_Linear(t) { ; lint-ignore: dead-function
    return t
}

; ========================= FPS DEBUG OVERLAY =========================

_Anim_UpdateFPSCounter(now) {
    global gAnim_FPSFrameCount, gAnim_FPSLastSample, gAnim_FPSDisplay
    gAnim_FPSFrameCount += 1
    elapsed := now - gAnim_FPSLastSample
    if (elapsed >= 500.0) {  ; Update every 500ms
        gAnim_FPSDisplay := Round(gAnim_FPSFrameCount / (elapsed / 1000.0))
        gAnim_FPSFrameCount := 0
        gAnim_FPSLastSample := now
    }
}

Anim_DrawFPSOverlay(wPhys, hPhys, scale) { ; lint-ignore: dead-param
    global gAnim_FPSDisplay, gAnim_FrameTimeDisplay, gD2D_RT, gD2D_Res, gAnim_TargetFPS

    ; Build display text
    ftMs := Round(gAnim_FrameTimeDisplay, 1)
    text := ftMs "ms " gAnim_FPSDisplay "/" gAnim_TargetFPS

    ; Layout: top-right corner
    padX := Round(8 * scale)
    padY := Round(6 * scale)
    textH := Round(14 * scale)
    textW := Round(120 * scale)
    bgW := textW + padX * 2
    bgH := textH + padY * 2
    bgX := wPhys - bgW - Round(8 * scale)
    bgY := Round(8 * scale)

    ; Background rect (semi-transparent dark)
    bgBrush := D2D_GetCachedBrush(0xB0000000)
    D2D_FillRoundRect(bgX, bgY, bgW, bgH, Round(4 * scale), bgBrush)

    ; Text (white)
    textBrush := D2D_GetCachedBrush(0xFFFFFFFF)
    ; Use sub text format (small, already cached in gD2D_Res)
    if (gD2D_Res.Has("tfSub"))
        D2D_DrawTextLeft(text, bgX + padX, bgY + padY, textW, textH, textBrush, gD2D_Res["tfSub"])
}
