#Requires AutoHotkey v2.0
; sort_utils.ahk — In-place quicksort for Array objects.
; Algorithm adapted from thqby/ahk2_lib sort.ahk (QSort).
; 3-way partition (Bentley-McIlroy), median-of-3 pivot, insertion sort cutoff at n≤20.
; cmp(a, b) returns <0 if a before b, 0 if equal, >0 if a after b.

QuickSort(arr, cmp) {
    Profiler.Enter("QuickSort") ; @profile
    if (!IsObject(arr) || !(arr is Array) || arr.Length <= 1) {
        Profiler.Leave() ; @profile
        return
    }
    _QS_Sort(arr, cmp, 1, arr.Length)
    Profiler.Leave() ; @profile
}

_QS_Sort(arr, cmp, l, h) {
    n := h - l + 1
    if (n <= 20) {
        _QS_InsertionSort(arr, cmp, l, h)
        return
    }
    ; Median-of-3 pivot
    mid := l + (n >> 1)
    if (cmp(arr[l], arr[mid]) > 0) {
        tmp := arr[l], arr[l] := arr[mid], arr[mid] := tmp
    }
    if (cmp(arr[l], arr[h]) > 0) {
        tmp := arr[l], arr[l] := arr[h], arr[h] := tmp
    }
    if (cmp(arr[mid], arr[h]) > 0) {
        tmp := arr[mid], arr[mid] := arr[h], arr[h] := tmp
    }
    ; Pivot = median, move to arr[l]
    tmp := arr[mid], arr[mid] := arr[l], arr[l] := tmp
    v := arr[l]
    ; 3-way partition (Bentley-McIlroy)
    p := l
    q := h + 1
    i := l
    j := h + 1
    while (true) {
        while (cmp(arr[++i], v) < 0 && i < h)
            continue
        while (cmp(v, arr[--j]) < 0 && j > l)
            continue
        if (i = j && cmp(arr[i], v) = 0) {
            p++
            tmp := arr[p], arr[p] := arr[i], arr[i] := tmp
        }
        if (i >= j)
            break
        tmp := arr[i], arr[i] := arr[j], arr[j] := tmp
        if (cmp(arr[i], v) = 0) {
            p++
            tmp := arr[p], arr[p] := arr[i], arr[i] := tmp
        }
        if (cmp(arr[j], v) = 0) {
            q--
            tmp := arr[q], arr[q] := arr[j], arr[j] := tmp
        }
    }
    ii := j + 1
    k := l
    while (k <= p) {
        tmp := arr[k], arr[k] := arr[j], arr[j] := tmp
        j--
        k++
    }
    k := h
    while (k >= q) {
        tmp := arr[k], arr[k] := arr[ii], arr[ii] := tmp
        ii++
        k--
    }
    _QS_Sort(arr, cmp, l, j)
    _QS_Sort(arr, cmp, ii, h)
}

_QS_InsertionSort(arr, cmp, l, h) {
    i := l + 1
    while (i <= h) {
        key := arr[i]
        j := i - 1
        while (j >= l && cmp(arr[j], key) > 0) {
            arr[j + 1] := arr[j]
            j--
        }
        arr[j + 1] := key
        i++
    }
}
