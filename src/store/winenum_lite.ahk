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
        records.Push({
            hwnd: hwnd,
            title: title,
            class: class,
            pid: pid,
            state: state,
            z: z,
            altTabEligible: true,
            isBlacklisted: false
        })
    }
    return records
}
