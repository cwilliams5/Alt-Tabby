#Requires AutoHotkey v2.0
; sort_utils.ahk — In-place quicksort for Array objects.
; Algorithm adapted from thqby/ahk2_lib sort.ahk (QSort).
; 3-way partition (Bentley-McIlroy), median-of-3 pivot, insertion sort cutoff at n≤20.
; cmp(a, b) returns <0 if a before b, 0 if equal, >0 if a after b.

QuickSort(arr, cmp) {
    if (!IsObject(arr) || !(arr is Array) || arr.Length <= 1)
        return
    _QS_Sort(arr, cmp, 1, arr.Length)
}

_QS_Sort(arr, cmp, l, h) {
    n := h - l + 1
    if (n <= 20) {
        _QS_InsertionSort(arr, cmp, l, h)
        return
    }
    ; Median-of-3 pivot
    mid := l + (n >> 1)
    if (cmp(arr[l], arr[mid]) > 0)
        _QS_Swap(arr, l, mid)
    if (cmp(arr[l], arr[h]) > 0)
        _QS_Swap(arr, l, h)
    if (cmp(arr[mid], arr[h]) > 0)
        _QS_Swap(arr, mid, h)
    ; Pivot = median, move to arr[l]
    _QS_Swap(arr, mid, l)
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
            _QS_Swap(arr, p, i)
        }
        if (i >= j)
            break
        _QS_Swap(arr, i, j)
        if (cmp(arr[i], v) = 0) {
            p++
            _QS_Swap(arr, p, i)
        }
        if (cmp(arr[j], v) = 0) {
            q--
            _QS_Swap(arr, q, j)
        }
    }
    ii := j + 1
    k := l
    while (k <= p) {
        _QS_Swap(arr, k, j)
        j--
        k++
    }
    k := h
    while (k >= q) {
        _QS_Swap(arr, k, ii)
        ii++
        k--
    }
    _QS_Sort(arr, cmp, l, j)
    _QS_Sort(arr, cmp, ii, h)
}

_QS_Swap(arr, a, b) {
    tmp := arr[a]
    arr[a] := arr[b]
    arr[b] := tmp
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
