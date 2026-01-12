#Requires AutoHotkey v2.0

; Lightweight window enumeration (no komorebi, no MRU).

WinEnumLite_ScanAll() {
    list := WinGetList()
    records := []
    z := 0
    for _, hwnd in list {
        z += 1
        title := WinGetTitle("ahk_id " hwnd)
        class := WinGetClass("ahk_id " hwnd)
        pid := WinGetPID("ahk_id " hwnd)
        isMin := DllCall("user32\IsIconic", "ptr", hwnd, "int") != 0
        isVis := DllCall("user32\IsWindowVisible", "ptr", hwnd, "int") != 0
        state := isMin ? "WorkspaceMinimized" : (isVis ? "WorkspaceShowing" : "WorkspaceHidden")
        rec := Map()
        rec["hwnd"] := hwnd
        rec["title"] := title
        rec["class"] := class
        rec["pid"] := pid
        rec["state"] := state
        rec["z"] := z
        rec["altTabEligible"] := true
        rec["isBlacklisted"] := false
        records.Push(rec)
    }
    return records
}
