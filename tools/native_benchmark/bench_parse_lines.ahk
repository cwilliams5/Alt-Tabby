#Requires AutoHotkey v2.0
#SingleInstance Off

; bench_parse_lines.ahk — Benchmark IPC line parsing
;
; Measures:
; 1. Current offset-based InStr/SubStr parsing
; 2. Overhead of SubStr per line
; 3. Callback invocation overhead

#Include %A_ScriptDir%\bench_common.ahk

FileAppend("bench_parse_lines.ahk — IPC Line Parsing Benchmark`n", "*")
FileAppend("==================================================`n", "*")

; --- Generate test buffers with N messages of given size ---
_MakeBuffer(msgCount, msgSize) {
    msg := Bench_PatternString(msgSize)
    buf := ""
    loop msgCount
        buf .= msg "`n"
    return buf
}

; Null callback (measures parse overhead without processing)
_NullCallback(line, hPipe := 0) {
}

; Counter callback (minimal work)
global gLineCount := 0
_CountCallback(line, hPipe := 0) {
    global gLineCount
    gLineCount += 1
}

; ============================================================
; BENCHMARK 1: Current production pattern
; ============================================================
Bench_Header("1. Current Production Pattern (_IPC_ParseLines)")

_ParseLines_Current(stateObj, onMessageFn, hPipe := 0) {
    offset := 1
    while true {
        pos := InStr(stateObj.buf, "`n", , offset)
        if (!pos)
            break
        line := SubStr(stateObj.buf, offset, pos - offset)
        offset := pos + 1
        if (SubStr(line, -1) = "`r")
            line := SubStr(line, 1, -1)
        if (line != "")
            try onMessageFn.Call(line, hPipe)
    }
    if (offset > 1) {
        stateObj.buf := SubStr(stateObj.buf, offset)
        stateObj.bufLen := StrLen(stateObj.buf)
    }
}

; Test matrix: message count × message size
msgCounts := [1, 5, 10, 20, 50]
msgSizes := [100, 500, 1000]

for _, msgSz in msgSizes {
    for _, msgCt in msgCounts {
        bufTemplate := _MakeBuffer(msgCt, msgSz)
        iters := (msgCt * msgSz > 10000) ? 2000 : 5000

        result := Bench_RunBatch(
            (() => (stateObj := { buf: bufTemplate, bufLen: StrLen(bufTemplate) },
                    _ParseLines_Current(stateObj, _NullCallback))),
            msgCt, iters, 100,
            msgCt "msg x " msgSz "B (null cb)"
        )
        Bench_Print(result)
    }
}

; ============================================================
; BENCHMARK 2: With counter callback (minimal processing)
; ============================================================
Bench_Header("2. With Counter Callback (minimal work per line)")

for _, msgSz in [100, 1000] {
    for _, msgCt in [5, 20, 50] {
        bufTemplate := _MakeBuffer(msgCt, msgSz)
        iters := (msgCt * msgSz > 10000) ? 2000 : 5000

        result := Bench_RunBatch(
            (() => (gLineCount := 0,
                    stateObj := { buf: bufTemplate, bufLen: StrLen(bufTemplate) },
                    _ParseLines_Current(stateObj, _CountCallback))),
            msgCt, iters, 100,
            msgCt "msg x " msgSz "B (count cb)"
        )
        Bench_Print(result)
    }
}

; ============================================================
; BENCHMARK 3: InStr cost isolation
; ============================================================
Bench_Header("3. InStr Cost Isolation (finding newlines in buffer)")

_InStrOnly(buf) {
    offset := 1
    count := 0
    while true {
        pos := InStr(buf, "`n", , offset)
        if (!pos)
            break
        offset := pos + 1
        count += 1
    }
    return count
}

for _, msgSz in [100, 1000] {
    for _, msgCt in [5, 20, 50] {
        buf := _MakeBuffer(msgCt, msgSz)
        iters := 5000

        result := Bench_RunBatch(
            (() => _InStrOnly(buf)),
            msgCt, iters, 100,
            msgCt "msg x " msgSz "B (InStr only)"
        )
        Bench_Print(result)
    }
}

; ============================================================
; BENCHMARK 4: SubStr cost isolation
; ============================================================
Bench_Header("4. SubStr Cost Isolation (extracting lines)")

_SubStrOnly(buf, positions) {
    for _, pair in positions {
        line := SubStr(buf, pair[1], pair[2])
    }
}

for _, msgSz in [100, 1000] {
    for _, msgCt in [5, 20, 50] {
        buf := _MakeBuffer(msgCt, msgSz)
        ; Pre-compute positions
        positions := []
        offset := 1
        while true {
            pos := InStr(buf, "`n", , offset)
            if (!pos)
                break
            positions.Push([offset, pos - offset])
            offset := pos + 1
        }
        iters := 5000

        result := Bench_RunBatch(
            (() => _SubStrOnly(buf, positions)),
            msgCt, iters, 100,
            msgCt "msg x " msgSz "B (SubStr only)"
        )
        Bench_Print(result)
    }
}

; ============================================================
; BENCHMARK 5: Callback invocation overhead
; ============================================================
Bench_Header("5. Callback Invocation Overhead (fn.Call cost)")

_CallOverhead(fn, n) {
    loop n
        fn.Call("test line", 0)
}

for _, n in [1, 5, 20, 50] {
    result := Bench_RunBatch(
        (() => _CallOverhead(_NullCallback, n)),
        n, 5000, 100,
        n " fn.Call invocations"
    )
    Bench_Print(result)
}

; ============================================================
Bench_Header("Summary")
FileAppend("'null cb' isolates parse overhead from message processing.`n", "*")
FileAppend("'InStr only' vs 'SubStr only' shows where time is spent.`n", "*")
FileAppend("'fn.Call' overhead shows callback dispatch cost per message.`n", "*")
FileAppend("If InStr dominates, native line scanning helps. If SubStr dominates, not much to gain.`n", "*")
FileAppend("`nDone.`n", "*")

ExitApp(0)
