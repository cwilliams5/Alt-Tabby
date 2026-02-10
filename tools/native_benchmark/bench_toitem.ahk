#Requires AutoHotkey v2.0
#SingleInstance Off

; bench_toitem.ahk — Benchmark projection transform (_WS_ToItem)
;
; Measures:
; 1. Single-item transform cost
; 2. Batch transform (N windows) — Path 3 projection rebuild
; 3. Object construction overhead isolation

#Include %A_ScriptDir%\bench_common.ahk

FileAppend("bench_toitem.ahk — Projection Transform Benchmark`n", "*")
FileAppend("================================================`n", "*")

; --- Generate mock store records ---
_MakeRecord(i) {
    return {
        hwnd: 0x10000 + i,
        title: "Window Title " i " - Some Application Name",
        class: "ApplicationFrameWindow",
        pid: 1000 + i,
        z: i,
        lastActivatedTick: A_TickCount - i * 100,
        isFocused: (i = 1) ? true : false,
        isCloaked: false,
        isMinimized: (Mod(i, 10) = 0) ? true : false,
        workspaceName: "Workspace " Mod(i, 4),
        workspaceId: "ws-" Mod(i, 4),
        isOnCurrentWorkspace: (Mod(i, 4) = 0) ? true : false,
        processName: "app" i ".exe",
        iconHicon: 0xDEAD0000 + i
    }
}

; Pre-generate record sets of various sizes
recordSets := Map()
for _, count in [10, 30, 50, 100, 200] {
    recs := []
    loop count
        recs.Push(_MakeRecord(A_Index))
    recordSets[count] := recs
}

; ============================================================
; BENCHMARK 1: Single-item _WS_ToItem (production code)
; ============================================================
Bench_Header("1. Single-Item Transform (_WS_ToItem)")

_WS_ToItem(rec) {
    return {
        hwnd: rec.hwnd,
        title: rec.title,
        class: rec.class,
        pid: rec.pid,
        z: rec.z,
        lastActivatedTick: rec.lastActivatedTick,
        isFocused: rec.isFocused,
        isCloaked: rec.isCloaked,
        isMinimized: rec.isMinimized,
        workspaceName: rec.workspaceName,
        workspaceId: rec.workspaceId,
        isOnCurrentWorkspace: rec.isOnCurrentWorkspace,
        processName: rec.processName,
        iconHicon: rec.iconHicon
    }
}

singleRec := _MakeRecord(1)
result := Bench_Run((() => _WS_ToItem(singleRec)), 10000, 200, "single item")
Bench_Print(result)

; ============================================================
; BENCHMARK 2: Batch transform (Path 3 rebuild)
; ============================================================
Bench_Header("2. Batch Transform (Full Projection Rebuild)")

_TransformBatch(recs) {
    items := []
    items.Length := recs.Length
    loop recs.Length
        items[A_Index] := _WS_ToItem(recs[A_Index])
    return items
}

for _, count in [10, 30, 50, 100, 200] {
    recs := recordSets[count]
    iters := (count <= 50) ? 5000 : (count <= 100) ? 2000 : 1000
    result := Bench_RunBatch(
        (() => _TransformBatch(recs)),
        count, iters, 100,
        "batch " count " windows"
    )
    Bench_Print(result)
}

; ============================================================
; BENCHMARK 3: Object literal construction overhead
; ============================================================
Bench_Header("3. Object Literal Construction (14 fields, constant values)")

; Isolate object construction from property reads
_ConstructOnly() {
    return {
        hwnd: 0x12345,
        title: "Fixed Title String Here",
        class: "FixedClassName",
        pid: 1234,
        z: 5,
        lastActivatedTick: 99999999,
        isFocused: false,
        isCloaked: false,
        isMinimized: false,
        workspaceName: "Workspace 1",
        workspaceId: "ws-1",
        isOnCurrentWorkspace: true,
        processName: "notepad.exe",
        iconHicon: 0xDEADBEEF
    }
}

result := Bench_Run(_ConstructOnly, 10000, 200, "obj literal (14 fields)")
Bench_Print(result)

; Compare: fewer fields
_Construct4Fields() {
    return { hwnd: 0x12345, title: "Test", pid: 1234, z: 5 }
}

result := Bench_Run(_Construct4Fields, 10000, 200, "obj literal (4 fields)")
Bench_Print(result)

; Compare: empty object
_ConstructEmpty() {
    return {}
}

result := Bench_Run(_ConstructEmpty, 10000, 200, "obj literal (0 fields)")
Bench_Print(result)

; ============================================================
; BENCHMARK 4: Property read overhead
; ============================================================
Bench_Header("4. Property Read Overhead (14 reads from object)")

_ReadAllFields(rec) {
    a := rec.hwnd
    b := rec.title
    c := rec.class
    d := rec.pid
    e := rec.z
    f := rec.lastActivatedTick
    g := rec.isFocused
    h := rec.isCloaked
    i := rec.isMinimized
    j := rec.workspaceName
    k := rec.workspaceId
    l := rec.isOnCurrentWorkspace
    m := rec.processName
    n := rec.iconHicon
    return a  ; prevent optimization
}

result := Bench_Run((() => _ReadAllFields(singleRec)), 10000, 200, "14 property reads")
Bench_Print(result)

; ============================================================
; BENCHMARK 5: Dynamic property access (%field%)
; ============================================================
Bench_Header("5. Dynamic vs Static Property Access")

fields := ["hwnd", "title", "class", "pid", "z", "lastActivatedTick",
    "isFocused", "isCloaked", "isMinimized", "workspaceName",
    "workspaceId", "isOnCurrentWorkspace", "processName", "iconHicon"]

_DynamicRead(rec, fields) {
    for _, f in fields
        v := rec.%f%
    return v
}

result := Bench_Run((() => _DynamicRead(singleRec, fields)), 10000, 200, "14 dynamic %field% reads")
Bench_Print(result)

; ============================================================
Bench_Header("Summary")
FileAppend("'single item' = full cost of one _WS_ToItem call.`n", "*")
FileAppend("'batch N' = cost of transforming N windows (divide by N for per-item).`n", "*")
FileAppend("'obj literal' benchmarks isolate construction from reads.`n", "*")
FileAppend("'dynamic vs static' shows the penalty _WS_ToItem avoids by hardcoding.`n", "*")
FileAppend("`nDone.`n", "*")

ExitApp(0)
