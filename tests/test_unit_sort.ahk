; Unit Tests - QuickSort
; Correctness tests for QuickSort() in sort_utils.ahk
; Included by test_unit.ahk
#Include test_utils.ahk

RunUnitTests_Sort() {
    global TestPassed, TestErrors

    Log("`n--- QuickSort Tests ---")

    ; --- Test 1: Empty array ---
    Log("Testing empty array...")
    arr := []
    QuickSort(arr, _TestCmpNum)
    AssertEq(arr.Length, 0, "QuickSort empty array stays empty")

    ; --- Test 2: Single element ---
    Log("Testing single element...")
    arr := [{v: 42}]
    QuickSort(arr, _TestCmpNum)
    AssertEq(arr[1].v, 42, "QuickSort single element unchanged")

    ; --- Test 3: Two elements (already sorted) ---
    Log("Testing two elements already sorted...")
    arr := [{v: 1}, {v: 2}]
    QuickSort(arr, _TestCmpNum)
    AssertEq(arr[1].v, 1, "QuickSort two sorted [1]")
    AssertEq(arr[2].v, 2, "QuickSort two sorted [2]")

    ; --- Test 4: Two elements (reversed) ---
    Log("Testing two elements reversed...")
    arr := [{v: 2}, {v: 1}]
    QuickSort(arr, _TestCmpNum)
    AssertEq(arr[1].v, 1, "QuickSort two reversed [1]")
    AssertEq(arr[2].v, 2, "QuickSort two reversed [2]")

    ; --- Test 5: All equal elements ---
    Log("Testing all equal elements...")
    arr := [{v: 5}, {v: 5}, {v: 5}, {v: 5}, {v: 5}]
    QuickSort(arr, _TestCmpNum)
    allFive := true
    for item in arr {
        if (item.v != 5)
            allFive := false
    }
    AssertTrue(allFive, "QuickSort all-equal elements stay equal")
    AssertEq(arr.Length, 5, "QuickSort all-equal preserves length")

    ; --- Test 6: Already sorted ---
    Log("Testing already sorted array...")
    arr := [{v: 1}, {v: 2}, {v: 3}, {v: 4}, {v: 5}]
    QuickSort(arr, _TestCmpNum)
    sorted := true
    Loop arr.Length - 1 {
        if (arr[A_Index].v > arr[A_Index + 1].v)
            sorted := false
    }
    AssertTrue(sorted, "QuickSort already-sorted stays sorted")

    ; --- Test 7: Reverse sorted ---
    Log("Testing reverse sorted array...")
    arr := [{v: 5}, {v: 4}, {v: 3}, {v: 2}, {v: 1}]
    QuickSort(arr, _TestCmpNum)
    sorted := true
    Loop arr.Length - 1 {
        if (arr[A_Index].v > arr[A_Index + 1].v)
            sorted := false
    }
    AssertTrue(sorted, "QuickSort reverse-sorted becomes sorted")
    AssertEq(arr[1].v, 1, "QuickSort reverse first=1")
    AssertEq(arr[5].v, 5, "QuickSort reverse last=5")

    ; --- Test 8: Random data (25 elements, crosses insertion sort cutoff) ---
    Log("Testing 25 random elements...")
    arr := []
    ; Deterministic "random" sequence
    vals := [17, 3, 25, 8, 14, 22, 1, 19, 11, 6, 23, 9, 15, 2, 20, 12, 7, 24, 4, 16, 21, 5, 18, 10, 13]
    for v in vals
        arr.Push({v: v})
    QuickSort(arr, _TestCmpNum)
    sorted := true
    Loop arr.Length - 1 {
        if (arr[A_Index].v > arr[A_Index + 1].v)
            sorted := false
    }
    AssertTrue(sorted, "QuickSort 25 random elements sorted correctly")
    AssertEq(arr[1].v, 1, "QuickSort 25 random first=1")
    AssertEq(arr[25].v, 25, "QuickSort 25 random last=25")

    ; --- Test 9: String comparator ---
    Log("Testing string comparator...")
    arr := [{t: "Zebra"}, {t: "Apple"}, {t: "Mango"}, {t: "Banana"}]
    QuickSort(arr, _TestCmpStr)
    AssertEq(arr[1].t, "Apple", "QuickSort string [1]=Apple")
    AssertEq(arr[2].t, "Banana", "QuickSort string [2]=Banana")
    AssertEq(arr[3].t, "Mango", "QuickSort string [3]=Mango")
    AssertEq(arr[4].t, "Zebra", "QuickSort string [4]=Zebra")

    ; --- Test 10: MRU-style comparator (descending tick) ---
    Log("Testing MRU-style descending comparator...")
    arr := [{tick: 100}, {tick: 300}, {tick: 200}, {tick: 500}, {tick: 400}]
    QuickSort(arr, _TestCmpMRU)
    AssertEq(arr[1].tick, 500, "QuickSort MRU [1]=500 (most recent)")
    AssertEq(arr[5].tick, 100, "QuickSort MRU [5]=100 (least recent)")

    ; --- Test 11: Stability-like check with duplicates ---
    Log("Testing with duplicate keys...")
    arr := [{v: 3, id: "a"}, {v: 1, id: "b"}, {v: 3, id: "c"}, {v: 2, id: "d"}, {v: 1, id: "e"}]
    QuickSort(arr, _TestCmpNum)
    AssertEq(arr[1].v, 1, "QuickSort duplicates [1].v=1")
    AssertEq(arr[2].v, 1, "QuickSort duplicates [2].v=1")
    AssertEq(arr[3].v, 2, "QuickSort duplicates [3].v=2")
    AssertEq(arr[4].v, 3, "QuickSort duplicates [4].v=3")
    AssertEq(arr[5].v, 3, "QuickSort duplicates [5].v=3")

    ; --- Test 12: Non-array/invalid inputs (no crash) ---
    Log("Testing invalid inputs...")
    QuickSort("not an array", _TestCmpNum)  ; Should not crash
    QuickSort(0, _TestCmpNum)               ; Should not crash
    QuickSort(Map(), _TestCmpNum)            ; Should not crash (Map is Object but not Array)
    AssertTrue(true, "QuickSort handles invalid inputs without crash")

    ; --- Test 13: Large array (100 elements, well above insertion sort cutoff) ---
    Log("Testing 100 elements...")
    arr := []
    ; Build descending array
    Loop 100
        arr.Push({v: 101 - A_Index})
    QuickSort(arr, _TestCmpNum)
    sorted := true
    Loop arr.Length - 1 {
        if (arr[A_Index].v > arr[A_Index + 1].v)
            sorted := false
    }
    AssertTrue(sorted, "QuickSort 100 reverse elements sorted")
    AssertEq(arr[1].v, 1, "QuickSort 100 first=1")
    AssertEq(arr[100].v, 100, "QuickSort 100 last=100")

    Log("--- QuickSort Tests Complete ---")
}

; --- Test comparators ---

_TestCmpNum(a, b) {
    return (a.v < b.v) ? -1 : (a.v > b.v) ? 1 : 0
}

_TestCmpStr(a, b) {
    return StrCompare(a.t, b.t)
}

_TestCmpMRU(a, b) {
    ; Descending by tick (most recent first)
    return (a.tick > b.tick) ? -1 : (a.tick < b.tick) ? 1 : 0
}
