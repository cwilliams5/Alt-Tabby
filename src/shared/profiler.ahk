#Requires AutoHotkey v2.0
; Build-time strip profiler — every code line tagged ; @profile
; In release builds (no --profile flag), compile.ps1 strips all ; @profile lines,
; removing this entire file's content and all Profiler.Enter/Leave call sites.
; Result: true zero cost in production.

; ========================= INIT ========================= ; @profile
; @profile
Profiler_Init() { ; @profile
    global cfg ; @profile
    ; @profile
    ; Profiler only works in --profile builds (this code stripped otherwise) ; @profile
    ; Register hotkey: pass-through + keyboard hook + wildcard (fire regardless of modifiers). ; @profile
    ; Matches FR_Init pattern so it works when Alt is held during Alt-Tab. ; @profile
    hk := cfg.DiagProfilerHotkey ; @profile
    if (SubStr(hk, 1, 1) != "*") ; @profile
        hk := "*" hk ; @profile
    Hotkey("~$" hk, (*) => _Profiler_Toggle()) ; @profile
} ; @profile
; @profile
; ========================= TOGGLE ========================= ; @profile
; @profile
_Profiler_Toggle() { ; @profile
    if (Profiler._recording) ; @profile
        _Profiler_Stop() ; @profile
    else ; @profile
        _Profiler_Start() ; @profile
} ; @profile
; @profile
_Profiler_Start() { ; @profile
    global cfg ; @profile
    Profiler._bufSize := cfg.DiagProfilerBufferSize ; @profile
    Profiler._events := [] ; @profile
    Profiler._events.Length := Profiler._bufSize ; @profile
    Loop Profiler._bufSize ; @profile
        Profiler._events[A_Index] := {t: 0, f: 0, e: 0} ; @profile
    Profiler._idx := 0 ; @profile
    Profiler._count := 0 ; @profile
    Profiler._stack := [] ; @profile
    Profiler._frames := Map() ; @profile
    Profiler._baseTime := QPC() ; @profile
    Profiler._recording := true ; @profile
    ToolTip("Profiler STARTED (buffer: " Profiler._bufSize " events)") ; @profile
    SetTimer((*) => ToolTip(), -2000) ; @profile
} ; @profile
; @profile
_Profiler_Stop() { ; @profile
    Profiler._recording := false ; @profile
    evCount := Min(Profiler._count, Profiler._bufSize) ; @profile
    if (evCount = 0) { ; @profile
        ToolTip("Profiler stopped — no events captured") ; @profile
        SetTimer((*) => ToolTip(), -2000) ; @profile
        return ; @profile
    } ; @profile
    ; @profile
    filePath := _Profiler_Export() ; @profile
    fileName := _Profiler_FileNameOnly(filePath) ; @profile
    ToolTip("Profiler stopped: " evCount " events → " fileName) ; @profile
    SetTimer((*) => ToolTip(), -3000) ; @profile
} ; @profile

; ========================= CORE ========================= ; @profile

class Profiler { ; @profile
    static _events := [] ; @profile
    static _bufSize := 0 ; @profile
    static _idx := 0 ; @profile
    static _count := 0 ; @profile
    static _stack := [] ; @profile
    static _frames := Map() ; @profile
    static _recording := false ; @profile
    static _baseTime := 0 ; @profile
; @profile
    static Enter(name) { ; @profile
        if (!Profiler._recording) ; @profile
            return ; @profile
        if (!Profiler._frames.Has(name)) ; @profile
            Profiler._frames[name] := Profiler._frames.Count ; @profile
        frameIdx := Profiler._frames[name] ; @profile
        Profiler._stack.Push(frameIdx) ; @profile
        Profiler._idx := Mod(Profiler._idx, Profiler._bufSize) + 1 ; @profile
        slot := Profiler._events[Profiler._idx] ; @profile
        slot.t := QPC() ; @profile
        slot.f := frameIdx ; @profile
        slot.e := 1 ; @profile
        Profiler._count += 1 ; @profile
    } ; @profile
; @profile
    static Leave() { ; @profile
        if (!Profiler._recording) ; @profile
            return ; @profile
        frame := Profiler._stack.Length > 0 ? Profiler._stack.Pop() : -1 ; @profile
        Profiler._idx := Mod(Profiler._idx, Profiler._bufSize) + 1 ; @profile
        slot := Profiler._events[Profiler._idx] ; @profile
        slot.t := QPC() ; @profile
        slot.f := frame ; @profile
        slot.e := 0 ; @profile
        Profiler._count += 1 ; @profile
    } ; @profile
} ; @profile

; ========================= EXPORT ========================= ; @profile
; @profile
_Profiler_Export() { ; @profile
    evCount := Min(Profiler._count, Profiler._bufSize) ; @profile
    ; @profile
    ; Read ring buffer in chronological order (oldest to newest) ; @profile
    ordered := [] ; @profile
    ordered.Length := evCount ; @profile
    Loop evCount { ; @profile
        ; Walk backwards from _idx to find oldest, then forward ; @profile
        srcIdx := Profiler._idx - evCount + A_Index ; @profile
        if (srcIdx < 1) ; @profile
            srcIdx += Profiler._bufSize ; @profile
        ordered[A_Index] := Profiler._events[srcIdx] ; @profile
    } ; @profile
    ; @profile
    ; Build frame name list ordered by index ; @profile
    frameNames := [] ; @profile
    frameNames.Length := Profiler._frames.Count ; @profile
    for name, idx in Profiler._frames ; @profile
        frameNames[idx + 1] := name ; @profile
    ; @profile
    ; Build shared.frames JSON array ; @profile
    framesJson := "" ; @profile
    for i, name in frameNames { ; @profile
        if (i > 1) ; @profile
            framesJson .= "," ; @profile
        framesJson .= '{"name":"' name '"}' ; @profile
    } ; @profile
    ; @profile
    ; Determine baseTime from the first event in the ordered buffer ; @profile
    baseTime := ordered[1].t ; @profile
    ; @profile
    ; Build events JSON array ; @profile
    eventsJson := "" ; @profile
    for i, ev in ordered { ; @profile
        if (i > 1) ; @profile
            eventsJson .= "," ; @profile
        typeStr := ev.e ? "O" : "C" ; @profile
        atUs := Round((ev.t - baseTime) * 1000) ; @profile
        eventsJson .= '{"type":"' typeStr '","frame":' ev.f ',"at":' atUs '}' ; @profile
    } ; @profile
    ; @profile
    ; Compute endValue ; @profile
    lastEv := ordered[evCount] ; @profile
    endValue := Round((lastEv.t - baseTime) * 1000) ; @profile
    ; @profile
    json := '{' ; @profile
        . '"$schema":"https://www.speedscope.app/file-format-schema.json",' ; @profile
        . '"version":"0.0.1",' ; @profile
        . '"shared":{"frames":[' framesJson ']},' ; @profile
        . '"profiles":[{' ; @profile
        . '"type":"evented",' ; @profile
        . '"name":"Alt-Tabby Profiler",' ; @profile
        . '"unit":"microseconds",' ; @profile
        . '"startValue":0,' ; @profile
        . '"endValue":' endValue ',' ; @profile
        . '"events":[' eventsJson ']' ; @profile
        . '}]}' ; @profile
    ; @profile
    recorderDir := _Profiler_GetRecorderDir() ; @profile
    if (!DirExist(recorderDir)) ; @profile
        DirCreate(recorderDir) ; @profile
    timeStr := FormatTime(, "yyyyMMdd_HHmmss") ; @profile
    filePath := recorderDir "\profile_" timeStr ".speedscope.json" ; @profile
    try FileAppend(json, filePath, "UTF-8") ; @profile
    return filePath ; @profile
} ; @profile
; @profile
_Profiler_GetRecorderDir() { ; @profile
    if (A_IsCompiled) ; @profile
        return A_ScriptDir "\recorder" ; @profile
    return A_ScriptDir "\..\..\recorder" ; @profile
} ; @profile
; @profile
_Profiler_FileNameOnly(path) { ; @profile
    pos := InStr(path, "\",, -1) ; @profile
    return pos ? SubStr(path, pos + 1) : path ; @profile
} ; @profile
