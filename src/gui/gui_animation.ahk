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
global gAnim_OverlayOpacity := 1.0    ; Current overlay fade opacity (0.0-1.0)
global gAnim_HidePending := false     ; Hide-fade in progress
global gAnim_DeferredTimerStart := false  ; Deferred frame loop start (STA pump safety, #175)
global gAnim_SelPrevIndex := 0        ; Previous selection index (for slide Y calc)
global gAnim_SelNewIndex := 0         ; New selection index (for slide Y calc)
global gFX_AmbientTime := 0.0         ; Cumulative ms for ambient loops (Full mode)

; FPS debug counter state
global FPS_SAMPLE_INTERVAL_MS := 500  ; How often to update the debug FPS readout
global gAnim_FPSFrameCount := 0
global gAnim_FPSLastSample := 0.0
global gAnim_FPSDisplay := 0          ; Displayed FPS (updated every FPS_SAMPLE_INTERVAL_MS)

; Compositor Clock state (Win11+ display-adaptive pacing)
global gAnim_pWaitForClock := 0    ; Function ptr: DCompositionWaitForCompositorClock (0 = unavailable)
global gAnim_pBoostClock := 0      ; Function ptr: DCompositionBoostCompositorClock (0 = unavailable)
global gAnim_QuitEvent := 0        ; Manual-reset event handle for clean frame loop shutdown
global gAnim_BoostActive := false  ; Whether compositor clock boost is currently active

; ========================= INIT =========================

Anim_Init() {
    global gAnim_TargetFPS, gAnim_FrameCapMs, cfg
    global gAnim_pWaitForClock, gAnim_pBoostClock, gAnim_QuitEvent

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

    ; Detect Compositor Clock API (Win11+ only, Build 22000+).
    ; MUST use GetProcAddress — hard-linking crashes on Win10 (missing entry point).
    ; dcomp.dll is already loaded via #DllLoad in gui_overlay.ahk.
    hDComp := DllCall("GetModuleHandle", "str", "dcomp.dll", "ptr")
    if (hDComp) {
        gAnim_pWaitForClock := DllCall("GetProcAddress", "ptr", hDComp,
            "astr", "DCompositionWaitForCompositorClock", "ptr")
        gAnim_pBoostClock := DllCall("GetProcAddress", "ptr", hDComp,
            "astr", "DCompositionBoostCompositorClock", "ptr")
    }

    ; Create quit event for clean frame loop shutdown (manual-reset, initially unsignaled)
    if (gAnim_pWaitForClock)
        gAnim_QuitEvent := DllCall("CreateEvent", "ptr", 0, "int", 1, "int", 0, "ptr", 0, "ptr")
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
    tw := gAnim_Tweens.Get(name, 0)
    return tw ? tw.current : defaultVal
}

_Anim_CancelTween(name) {
    global gAnim_Tweens
    if (gAnim_Tweens.Has(name))
        gAnim_Tweens.Delete(name)
}

Anim_CancelAll() {
    global gAnim_Tweens, gFX_AmbientTime, gAnim_HidePending
    gAnim_Tweens := Map()
    FX_SaveShaderTime()           ; Capture shader carry time before ambient resets
    gFX_AmbientTime := 0.0
    FX_ResetMouseVelocity()
    gAnim_HidePending := false
    _Anim_StopTimer()
}

_Anim_UpdateTweens(now := 0) {
    global gAnim_Tweens
    Profiler.Enter("_Anim_UpdateTweens") ; @profile
    if (!now)
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
    Profiler.Leave() ; @profile
    return activeCount
}

; ========================= FRAME LOOP =========================

Anim_EnsureTimer() {
    global gAnim_TimerRunning, gAnim_TimerPeriodOn, gAnim_LastFrameTime, cfg
    global gAnim_FPSFrameCount, gAnim_FPSLastSample
    global gPaint_RepaintInProgress, gAnim_DeferredTimerStart
    global gAnim_QuitEvent, gAnim_pBoostClock, gAnim_BoostActive
    if (cfg.PerfAnimationType = "None" && !FX_HasActiveShaders())
        return
    if (gAnim_TimerRunning)
        return
    ; If a paint is in progress, the STA pump would dispatch the frame loop
    ; (a blocking while-loop) inside the paint, suspending the paint quasi-thread
    ; forever in Full animation mode. Defer until paint completes. (#175)
    if (gPaint_RepaintInProgress) {
        gAnim_DeferredTimerStart := true
        return
    }
    if (!gAnim_TimerPeriodOn) {
        DllCall("winmm\timeBeginPeriod", "uint", 1)
        gAnim_TimerPeriodOn := true
    }
    ; Reset quit event for new animation session (unsignal it)
    if (gAnim_QuitEvent)
        DllCall("ResetEvent", "ptr", gAnim_QuitEvent)
    gAnim_LastFrameTime := QPC()
    gAnim_FPSLastSample := gAnim_LastFrameTime
    gAnim_FPSFrameCount := 0
    gAnim_TimerRunning := true
    ; Boost compositor clock refresh rate during animation (Dynamic Refresh Rate displays)
    if (gAnim_pBoostClock && !gAnim_BoostActive) {
        DllCall(gAnim_pBoostClock, "int", 1)
        gAnim_BoostActive := true
    }
    ; One-shot timer launches the frame loop in its own thread.
    ; The loop runs until gAnim_TimerRunning is set false.
    SetTimer(_Anim_FrameLoop, -1)
}

_Anim_StopTimer() {
    global gAnim_TimerRunning, gAnim_TimerPeriodOn
    global gAnim_QuitEvent, gAnim_pBoostClock, gAnim_BoostActive
    ; Signal quit event to unblock compositor clock wait immediately
    if (gAnim_QuitEvent)
        DllCall("SetEvent", "ptr", gAnim_QuitEvent)
    gAnim_TimerRunning := false
    ; Cancel pending one-shot if loop hasn't started yet
    SetTimer(_Anim_FrameLoop, 0)
    if (gAnim_TimerPeriodOn) {
        DllCall("winmm\timeEndPeriod", "uint", 1)
        gAnim_TimerPeriodOn := false
    }
    ; Release compositor clock boost
    if (gAnim_pBoostClock && gAnim_BoostActive) {
        DllCall(gAnim_pBoostClock, "int", 0)
        gAnim_BoostActive := false
    }
}

; Final cleanup — close compositor clock handles. Called from _GUI_OnExit().
Anim_Shutdown() {
    global gAnim_QuitEvent, gAnim_pBoostClock, gAnim_BoostActive
    ; Release any active boost
    if (gAnim_pBoostClock && gAnim_BoostActive) {
        DllCall(gAnim_pBoostClock, "int", 0)
        gAnim_BoostActive := false
    }
    ; Close quit event handle
    if (gAnim_QuitEvent) {
        DllCall("CloseHandle", "ptr", gAnim_QuitEvent)
        gAnim_QuitEvent := 0
    }
}

; Frame loop: runs as a persistent thread via one-shot SetTimer.
; Three-tier frame pacing (all OUTSIDE Critical):
;   Tier 1: Compositor Clock (Win11+) — display-adaptive, true frame skip for explicit FPS
;   Tier 2: Waitable swap chain — VSync-paced, spin-wait for explicit FPS
;   Tier 3: QPC spin-wait only — pure software cap
; After pacing: Sleep(0) message pump → Critical On (paint) → Critical Off.
_Anim_FrameLoop() {
    Profiler.Enter("_Anim_FrameLoop") ; @profile
    global gAnim_TimerRunning, gAnim_Tweens, gAnim_LastFrameTime, gAnim_FrameCapMs, gAnim_FrameDt
    global gAnim_OverlayOpacity, gAnim_HidePending, gAnim_FrameTimeDisplay
    global gGUI_OverlayVisible, cfg
    global gD2D_WaitableHandle
    global gAnim_pWaitForClock, gAnim_QuitEvent

    useCompositorClock := (gAnim_pWaitForClock != 0 && gAnim_QuitEvent != 0)
    useWaitable := (gD2D_WaitableHandle != 0)
    autoFPS := (cfg.PerfAnimationFPS = "Auto" || cfg.PerfAnimationFPS = "auto")

    ; Pre-allocate compositor clock handles buffer (1 app handle: quit event)
    if (useCompositorClock) {
        ccHandles := Buffer(A_PtrSize, 0)
        NumPut("ptr", gAnim_QuitEvent, ccHandles, 0)
    }

    while (gAnim_TimerRunning) {

        ; --- Frame pacing (OUTSIDE Critical) ---
        if (useCompositorClock) {
            ; Tier 1: Compositor Clock (Win11+) — display-adaptive pacing.
            ; Returns: 0 = quit event signaled, 1 = compositor ticked, 258 = timeout
            result := DllCall(gAnim_pWaitForClock, "uint", 1, "ptr", ccHandles, "uint", 1000, "uint")
            if (result != 1)  ; Not compositor tick (quit or timeout)
                break
        } else if (useWaitable) {
            ; Tier 2: Waitable swap chain — VSync-paced.
            ; 1000ms timeout prevents hang on device loss (WAIT_FAILED).
            DllCall("WaitForSingleObjectEx", "ptr", gD2D_WaitableHandle, "uint", 1000, "int", 1, "uint")
        }

        ; Always pump messages — hotkeys fire here, at optimal time after VBlank/compositor wait.
        Sleep(0)

        ; Frame skip for explicit FPS — compositor clock ONLY.
        ; Compositor clock ticks independently of Present (no auto-reset event),
        ; so skipping a render is safe. The waitable handle path CANNOT skip
        ; (auto-reset requires Present per consumed signal — Phase 1 lesson).
        ; 1ms tolerance: elapsed time lands right at the cap boundary (render time
        ; + compositor wait ≈ cap). Sub-ms jitter causes false skips without this.
        ; Rendering 1ms early is far better than waiting an extra full tick (~8ms).
        if (useCompositorClock && !autoFPS) {
            if (QPC() - gAnim_LastFrameTime < gAnim_FrameCapMs - 1.0)
                continue
        }

        Critical "On"

        now := QPC()
        gAnim_FrameDt := now - gAnim_LastFrameTime
        gAnim_LastFrameTime := now

        ; Update all active tweens
        activeCount := _Anim_UpdateTweens(now)

        ; Sync overlay opacity from tween → apply to window alpha
        _Anim_SyncOverlayOpacity()
        _Anim_ApplyWindowAlpha()

        ; Check if hide-fade completed
        hideTw := gAnim_HidePending ? gAnim_Tweens.Get("hideFade", 0) : 0
        if (hideTw && hideTw.done) {
            _Anim_OnHideFadeComplete()
            Critical "Off"
            continue  ; CancelAll sets gAnim_TimerRunning=false → loop exits
        }

        ; Cache shader state for this frame (unchanged during paint)
        hasShaders := FX_HasActiveShaders()

        ; Update ambient animations (Full mode, or any mode with active shaders)
        animType := cfg.PerfAnimationType  ; PERF: cache config read
        if (gGUI_OverlayVisible && (animType = "Full" || hasShaders))
            FX_UpdateAmbient(gAnim_FrameDt)

        ; Paint frame (gAnim_FrameTimeDisplay set inside GUI_Repaint,
        ; measuring AcquireBackBuffer through EndDraw, excludes Present)
        if (gGUI_OverlayVisible)
            GUI_Repaint()

        ; Update FPS counter
        _Anim_UpdateFPSCounter(now)

        ; Auto-stop (Minimal mode: exit when no active tweens AND no active shaders)
        if (animType != "Full" && activeCount = 0 && !gAnim_HidePending && !hasShaders)
            break

        Critical "Off"

        ; Post-render pacing — waitable and fallback paths only.
        ; Compositor clock handles ALL pacing at the top of the loop.
        if (!useCompositorClock) {
            if (!useWaitable) {
                ; Tier 3: Fallback — spin-wait for frame boundary
                Sleep(0)
                _Anim_FramePace()
            } else if (!autoFPS) {
                ; Tier 2 explicit FPS: spin-wait for frame cap.
                ; Present() already fired — the waitable signal will be pending
                ; by the time this wait completes, so next WaitForSingleObjectEx
                ; returns immediately.
                _Anim_FramePace()
            }
        }
    }

    Profiler.Leave() ; @profile
    _Anim_StopTimer()
}

; QPC spin-wait until next frame boundary. NtYieldExecution yields CPU timeslice
; each iteration (~0.5ms per yield). For 120Hz: ~5ms spin, for 60Hz: ~13ms spin.
; AHK's Sleep(N>0) goes through MsgSleep which oversleeps by ~10-15ms, making it
; unusable for sub-20ms frame caps. Pure spin is precise and CPU-cheap (yielded).
_Anim_FramePace() {
    Profiler.Enter("_Anim_FramePace") ; @profile
    global gAnim_LastFrameTime, gAnim_FrameCapMs
    nextFrame := gAnim_LastFrameTime + gAnim_FrameCapMs
    while (QPC() < nextFrame)
        DllCall("ntdll\NtYieldExecution")
    Profiler.Leave() ; @profile
}

_Anim_SyncOverlayOpacity() {
    global gAnim_OverlayOpacity, gAnim_Tweens
    static showFadeHandled := false
    Profiler.Enter("_Anim_SyncOverlayOpacity") ; @profile
    ; hideFade takes priority — when present it's the latest intent and the
    ; completed showFade tween is still in the map (never removed until CancelAll).
    tw := gAnim_Tweens.Get("hideFade", 0)
    if (tw) {
        showFadeHandled := false  ; reset for next show/hide cycle
        gAnim_OverlayOpacity := tw.current
        if (gAnim_OverlayOpacity < 0.0)
            gAnim_OverlayOpacity := 0.0
    } else if (!showFadeHandled) {
        tw := gAnim_Tweens.Get("showFade", 0)
        if (tw) {
            gAnim_OverlayOpacity := tw.current
            if (tw.done) {
                gAnim_OverlayOpacity := 1.0
                ; Show-fade complete: remove WS_EX_LAYERED so DWM resumes
                ; live acrylic blur (layered windows get stale cached blur).
                _Anim_RemoveLayered()
                showFadeHandled := true
            }
        }
    }
    Profiler.Leave() ; @profile
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

; Prepare opacity state for the show-fade sequence.
; animated=true: add WS_EX_LAYERED, set alpha=0, opacity=0.0 (tween drives it up)
; animated=false: set opacity=1.0 (no fade)
Anim_PrepareShowFade(animated) {
    global gAnim_OverlayOpacity, gGUI_BaseH
    if (animated) {
        Anim_AddLayered()
        DllCall("SetLayeredWindowAttributes", "ptr", gGUI_BaseH, "uint", 0, "uchar", 0, "uint", 2)
        gAnim_OverlayOpacity := 0.0
    } else {
        gAnim_OverlayOpacity := 1.0
    }
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
    Profiler.Enter("_Anim_DoActualHide") ; @profile
    global gGUI_OverlayVisible, gGUI_Base, gGUI_BaseH, gGUI_Revealed
    global cfg, GUI_LOG_TRIM_EVERY_N_HIDES
    global gGUI_DisplayItems
    static hideCount := 0

    if (!gGUI_OverlayVisible) {
        Profiler.Leave() ; @profile
        return
    }

    ; Release deferred display items — kept alive during hide-fade so the
    ; frame loop paints the frozen list while fading out (not the live MRU).
    gGUI_DisplayItems := []

    GUI_ClearHoverState()

    ; Clear D2D swap chain for clean buffer on next Show.
    ; Paint_ClearSurface handles the repaint guard + D2D error recovery.
    Paint_ClearSurface()

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
    Profiler.Leave() ; @profile
}

; ========================= SELECTION SLIDE =========================

Anim_StartSelectionSlide(prevSel, newSel, count) { ; lint-ignore: dead-param
    global gAnim_SelPrevIndex, gAnim_SelNewIndex
    _Anim_CancelTween("selSlide")
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

; ========================= FPS DEBUG OVERLAY =========================

_Anim_UpdateFPSCounter(now) {
    global gAnim_FPSFrameCount, gAnim_FPSLastSample, gAnim_FPSDisplay, FPS_SAMPLE_INTERVAL_MS
    gAnim_FPSFrameCount += 1
    elapsed := now - gAnim_FPSLastSample
    if (elapsed >= FPS_SAMPLE_INTERVAL_MS) {
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
