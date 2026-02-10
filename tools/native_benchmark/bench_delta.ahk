#Requires AutoHotkey v2.0
#SingleInstance Off

; bench_delta.ahk — Benchmark projection diffing (WindowStore_BuildDelta)
;
; Measures:
; 1. Map construction from item arrays
; 2. Field-by-field comparison (full mode vs sparse mode)
; 3. Various change rates (0%, 10%, 50%, 100%)

#Include %A_ScriptDir%\bench_common.ahk

FileAppend("bench_delta.ahk — Projection Diffing Benchmark`n", "*")
FileAppend("===============================================`n", "*")

; --- Field definitions (matches production PROJECTION_FIELDS) ---
global PROJECTION_FIELDS := ["title", "class", "pid", "z", "lastActivatedTick",
    "isFocused", "isCloaked", "isMinimized", "workspaceName",
    "workspaceId", "isOnCurrentWorkspace", "processName", "iconHicon"]

; --- Generate mock items ---
_MakeItem(i) {
    return {
        hwnd: 0x10000 + i,
        title: "Window Title " i " - Application",
        class: "AppFrameWindow",
        pid: 1000 + i,
        z: i,
        lastActivatedTick: 99999999 - i * 100,
        isFocused: (i = 1) ? true : false,
        isCloaked: false,
        isMinimized: false,
        workspaceName: "WS-" Mod(i, 4),
        workspaceId: "ws-" Mod(i, 4),
        isOnCurrentWorkspace: true,
        processName: "app" i ".exe",
        iconHicon: 0xDEAD0000 + i
    }
}

; Clone an item (simulate "next" state)
_CloneItem(item) {
    return {
        hwnd: item.hwnd,
        title: item.title,
        class: item.class,
        pid: item.pid,
        z: item.z,
        lastActivatedTick: item.lastActivatedTick,
        isFocused: item.isFocused,
        isCloaked: item.isCloaked,
        isMinimized: item.isMinimized,
        workspaceName: item.workspaceName,
        workspaceId: item.workspaceId,
        isOnCurrentWorkspace: item.isOnCurrentWorkspace,
        processName: item.processName,
        iconHicon: item.iconHicon
    }
}

; Mutate a percentage of items (change title field)
_MutateItems(items, changeRate) {
    changed := []
    for _, item in items {
        clone := _CloneItem(item)
        if (Random(1, 100) <= changeRate * 100)
            clone.title := "CHANGED " clone.title
        changed.Push(clone)
    }
    return changed
}

; --- Production BuildDelta (simplified, no dirty tracking for benchmark purity) ---
_BuildDelta(prevItems, nextItems, sparse := false) {
    global PROJECTION_FIELDS
    deltaFields := PROJECTION_FIELDS

    static prevMap := Map()
    static nextMap := Map()
    prevMap.Clear()
    for _, rec in prevItems
        prevMap[rec.hwnd] := rec
    nextMap.Clear()
    for _, rec in nextItems
        nextMap[rec.hwnd] := rec

    upserts := []
    removes := []

    for hwnd, rec in nextMap {
        if (!prevMap.Has(hwnd)) {
            upserts.Push(rec)
        } else {
            old := prevMap[hwnd]
            if (sparse) {
                sparseRec := {hwnd: hwnd}
                for _, field in deltaFields {
                    if (rec.%field% != old.%field%)
                        sparseRec.%field% := rec.%field%
                }
                if (ObjOwnPropCount(sparseRec) > 1)
                    upserts.Push(sparseRec)
            } else {
                for _, field in deltaFields {
                    if (rec.%field% != old.%field%) {
                        upserts.Push(rec)
                        break
                    }
                }
            }
        }
    }

    for hwnd, _ in prevMap {
        if (!nextMap.Has(hwnd))
            removes.Push(hwnd)
    }

    return { upserts: upserts, removes: removes }
}

; Pre-generate test data
windowCounts := [10, 30, 50, 100]
changeRates := [0.0, 0.1, 0.5, 1.0]

testData := Map()  ; key: "count_rate" → { prev, next }
for _, count in windowCounts {
    prevItems := []
    loop count
        prevItems.Push(_MakeItem(A_Index))

    for _, rate in changeRates {
        ; Pre-generate the "next" items so mutation cost isn't measured
        nextItems := _MutateItems(prevItems, rate)
        key := count "_" Round(rate * 100)
        testData[key] := { prev: prevItems, next: nextItems }
    }
}

; ============================================================
; BENCHMARK 1: Full mode (detect any change, push full record)
; ============================================================
Bench_Header("1. Full Mode Delta (push full record on any change)")

for _, count in windowCounts {
    for _, rate in changeRates {
        key := count "_" Round(rate * 100)
        data := testData[key]
        iters := (count <= 50) ? 3000 : 1000

        result := Bench_RunBatch(
            (() => _BuildDelta(data.prev, data.next, false)),
            count, iters, 100,
            "full " count "win " Round(rate * 100) "% changed"
        )
        Bench_Print(result)
    }
}

; ============================================================
; BENCHMARK 2: Sparse mode (only changed fields in upsert)
; ============================================================
Bench_Header("2. Sparse Mode Delta (only changed fields)")

for _, count in windowCounts {
    for _, rate in changeRates {
        key := count "_" Round(rate * 100)
        data := testData[key]
        iters := (count <= 50) ? 3000 : 1000

        result := Bench_RunBatch(
            (() => _BuildDelta(data.prev, data.next, true)),
            count, iters, 100,
            "sparse " count "win " Round(rate * 100) "% changed"
        )
        Bench_Print(result)
    }
}

; ============================================================
; BENCHMARK 3: Map construction cost (isolated)
; ============================================================
Bench_Header("3. Map Construction Cost (isolated)")

_MapBuild(items) {
    m := Map()
    for _, rec in items
        m[rec.hwnd] := rec
    return m
}

for _, count in windowCounts {
    key := count "_0"
    data := testData[key]
    iters := (count <= 50) ? 5000 : 2000

    result := Bench_RunBatch(
        (() => _MapBuild(data.prev)),
        count, iters, 100,
        "Map build " count " items"
    )
    Bench_Print(result)
}

; Reusable Map + Clear pattern
_MapBuildReuse(items, m) {
    m.Clear()
    for _, rec in items
        m[rec.hwnd] := rec
}

reusableMap := Map()
for _, count in windowCounts {
    key := count "_0"
    data := testData[key]
    iters := (count <= 50) ? 5000 : 2000

    result := Bench_RunBatch(
        (() => _MapBuildReuse(data.prev, reusableMap)),
        count, iters, 100,
        "Map reuse " count " items"
    )
    Bench_Print(result)
}

; ============================================================
; BENCHMARK 4: Field comparison cost (isolated)
; ============================================================
Bench_Header("4. Field Comparison Cost (14 fields, two objects)")

_CompareFields(a, b) {
    global PROJECTION_FIELDS
    for _, field in PROJECTION_FIELDS {
        if (a.%field% != b.%field%)
            return true
    }
    return false
}

itemA := _MakeItem(1)
itemB := _CloneItem(itemA)  ; identical
itemC := _CloneItem(itemA)
itemC.title := "DIFFERENT"  ; differs on field 1

result := Bench_Run((() => _CompareFields(itemA, itemB)), 10000, 200, "14 fields (identical)")
Bench_Print(result)

result := Bench_Run((() => _CompareFields(itemA, itemC)), 10000, 200, "14 fields (diff at field 1)")
Bench_Print(result)

; ============================================================
; BENCHMARK 5: ObjOwnPropCount overhead
; ============================================================
Bench_Header("5. ObjOwnPropCount Overhead")

sparseObj1 := { hwnd: 0x1234 }
sparseObj14 := _MakeItem(1)

result := Bench_Run((() => ObjOwnPropCount(sparseObj1)), 10000, 200, "ObjOwnPropCount (1 prop)")
Bench_Print(result)

result := Bench_Run((() => ObjOwnPropCount(sparseObj14)), 10000, 200, "ObjOwnPropCount (14 props)")
Bench_Print(result)

; ============================================================
Bench_Header("Summary")
FileAppend("'full' vs 'sparse' shows the cost of building partial records.`n", "*")
FileAppend("'Map build' vs 'Map reuse' shows static Map optimization value.`n", "*")
FileAppend("'0% changed' is the best case (all comparisons, no upserts).`n", "*")
FileAppend("'100% changed' is the worst case (all comparisons + all upserts).`n", "*")
FileAppend("`nDone.`n", "*")

ExitApp(0)
