#Requires AutoHotkey v2.0
#SingleInstance Off

; bench_utf8.ahk — Benchmark UTF-16 to UTF-8 encoding (IPC hot path)
;
; Measures:
; 1. StrPut two-pass (measure length + encode) — current production pattern
; 2. StrPut single-pass to pre-sized buffer — potential optimization
; 3. Object allocation overhead (the { buf:, len: } return)

#Include %A_ScriptDir%\bench_common.ahk

FileAppend("bench_utf8.ahk — IPC UTF-8 Encoding Benchmark`n", "*")
FileAppend("==============================================`n", "*")

; Pre-allocate reusable write buffer (matches production IPC_WRITE_BUF)
global IPC_READ_CHUNK_SIZE := 65536
global IPC_WRITE_BUF := Buffer(IPC_READ_CHUNK_SIZE)

; --- Test data at various sizes ---
sizes := [100, 500, 1000, 5000, 10000, 32000, 64000]
testStrings := Map()
for _, sz in sizes
    testStrings[sz] := Bench_PatternString(sz)

; Also test with Unicode content (window titles often have non-ASCII)
unicodeStr1k := ""
loop 250
    unicodeStr1k .= Chr(Random(0x4E00, 0x9FFF))  ; CJK characters (3 bytes each in UTF-8)

; ============================================================
; BENCHMARK 1: Current production pattern (two-pass StrPut)
; ============================================================
Bench_Header("1. Current Production Pattern (_IPC_StrToUtf8)")

_Current_StrToUtf8(str) {
    global IPC_WRITE_BUF, IPC_READ_CHUNK_SIZE
    len := StrPut(str, "UTF-8") - 1
    if (len <= IPC_READ_CHUNK_SIZE) {
        StrPut(str, IPC_WRITE_BUF, "UTF-8")
        return { buf: IPC_WRITE_BUF, len: len }
    }
    buf := Buffer(len)
    StrPut(str, buf, "UTF-8")
    return { buf: buf, len: len }
}

for _, sz in sizes {
    str := testStrings[sz]
    result := Bench_Run((() => _Current_StrToUtf8(str)), 10000, 200, "current " sz "B")
    Bench_Print(result)
}

; Unicode test
result := Bench_Run((() => _Current_StrToUtf8(unicodeStr1k)), 10000, 200, "current 1KB unicode")
Bench_Print(result)

; ============================================================
; BENCHMARK 2: Single-pass StrPut (skip length measurement)
; ============================================================
Bench_Header("2. Single-Pass StrPut (pre-sized buffer)")

; If we know the buffer is large enough, skip the length query.
; Worst case UTF-8: each UTF-16 char → 3 bytes. So maxLen = StrLen(str) * 3.
_SinglePass_StrToUtf8(str) {
    global IPC_WRITE_BUF, IPC_READ_CHUNK_SIZE
    ; Single StrPut call returns bytes written (including null)
    len := StrPut(str, IPC_WRITE_BUF, IPC_READ_CHUNK_SIZE, "UTF-8") - 1
    return { buf: IPC_WRITE_BUF, len: len }
}

for _, sz in sizes {
    str := testStrings[sz]
    result := Bench_Run((() => _SinglePass_StrToUtf8(str)), 10000, 200, "1-pass  " sz "B")
    Bench_Print(result)
}

result := Bench_Run((() => _SinglePass_StrToUtf8(unicodeStr1k)), 10000, 200, "1-pass  1KB unicode")
Bench_Print(result)

; ============================================================
; BENCHMARK 3: Raw StrPut only (no object allocation)
; ============================================================
Bench_Header("3. Raw StrPut Only (no object wrapper)")

; Isolate StrPut cost from object creation cost
_RawStrPut(str) {
    global IPC_WRITE_BUF, IPC_READ_CHUNK_SIZE
    return StrPut(str, IPC_WRITE_BUF, IPC_READ_CHUNK_SIZE, "UTF-8") - 1
}

for _, sz in sizes {
    str := testStrings[sz]
    result := Bench_Run((() => _RawStrPut(str)), 10000, 200, "raw     " sz "B")
    Bench_Print(result)
}

result := Bench_Run((() => _RawStrPut(unicodeStr1k)), 10000, 200, "raw     1KB unicode")
Bench_Print(result)

; ============================================================
; BENCHMARK 4: Object allocation overhead (isolated)
; ============================================================
Bench_Header("4. Object Allocation Overhead (isolated)")

_AllocOnly() {
    global IPC_WRITE_BUF
    return { buf: IPC_WRITE_BUF, len: 1000 }
}

result := Bench_Run(_AllocOnly, 10000, 200, "obj alloc only")
Bench_Print(result)

; Also measure Buffer allocation (for oversized messages)
_BufferAlloc(sz) {
    return Buffer(sz)
}

for _, sz in [1000, 10000, 65536, 131072] {
    result := Bench_Run((() => _BufferAlloc(sz)), 10000, 200, "Buffer(" sz ")")
    Bench_Print(result)
}

; ============================================================
; SUMMARY
; ============================================================
Bench_Header("Key Question: Is two-pass StrPut measurably slower than single-pass?")
FileAppend("Compare 'current' vs '1-pass' rows at each size.`n", "*")
FileAppend("Compare '1-pass' vs 'raw' rows to see object allocation overhead.`n", "*")
FileAppend("`nDone.`n", "*")

ExitApp(0)
