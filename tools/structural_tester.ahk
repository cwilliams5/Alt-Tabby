#Requires AutoHotkey v2.0
#SingleInstance Force

; Structural Tester — opens and closes windows on a timer to test
; Alt-Tabby's structural freeze (items should NOT appear/disappear/reorder
; while the overlay is active, but should update between invocations).

INTERVAL_MS := 3000
MIN_WINDOWS := 1
MAX_WINDOWS := 3

names := ["Waffles", "Pancakes", "Crepes", "French Toast", "Beignets",
          "Churros", "Donuts", "Muffins", "Scones", "Croissants"]

windows := []  ; array of {gui, name}
usedNames := Map()

controlGui := Gui("+AlwaysOnTop", "StructuralTester - Control")
controlGui.Add("Text", "w300 vInfo",
    "Starting in 5s...`n"
    "Range: " MIN_WINDOWS "-" MAX_WINDOWS " windows.`n"
    "Close or press Escape to stop.")
controlGui.Show("w320 h80")

; Delay 5s so the control window is the only one visible initially
SetTimer(StartChurning, -5000)

StartChurning() {
    SpawnWindow()
    SpawnWindow()
    SetTimer(Churn, INTERVAL_MS)
    UpdateStatus()
}

Churn() {
    global windows, MIN_WINDOWS, MAX_WINDOWS
    count := windows.Length

    ; Decide: open or close?
    if (count <= MIN_WINDOWS)
        action := "open"
    else if (count >= MAX_WINDOWS)
        action := "close"
    else
        action := (Random(0, 1) = 0) ? "open" : "close"

    if (action = "open")
        SpawnWindow()
    else
        CloseRandomWindow()
}

SpawnWindow() {
    global windows, names, usedNames
    ; Pick an unused name
    name := ""
    for _, candidate in names {
        if (!usedNames.Has(candidate)) {
            name := candidate
            break
        }
    }
    if (name = "")
        return  ; all names in use

    colors := ["FF6B6B", "4ECDC4", "45B7D1", "96CEB4", "FFEAA7",
               "DDA0DD", "98D8C8", "F7DC6F", "BB8FCE", "85C1E9"]
    colorIdx := Mod(windows.Length, colors.Length) + 1
    bg := colors[colorIdx]

    g := Gui("+Resize", name)
    g.BackColor := bg
    g.Add("Text", "w200 h40 Center", name)

    ; Scatter position so windows don't stack exactly
    x := 200 + Random(0, 600)
    y := 200 + Random(0, 300)
    g.Show("w250 h120 x" x " y" y)

    windows.Push({gui: g, name: name})
    usedNames[name] := true
    UpdateStatus()
}

CloseRandomWindow() {
    global windows, usedNames
    if (windows.Length = 0)
        return
    idx := Random(1, windows.Length)
    entry := windows[idx]
    try entry.gui.Destroy()
    usedNames.Delete(entry.name)
    windows.RemoveAt(idx)
    UpdateStatus()
}

UpdateStatus() {
    global controlGui, windows
    list := ""
    for _, w in windows
        list .= (list ? ", " : "") w.name
    try controlGui["Info"].Value := "Active: " windows.Length " — " list
}

controlGui.OnEvent("Close", CleanupAndExit)
Escape::CleanupAndExit()

CleanupAndExit(*) {
    global windows
    SetTimer(Churn, 0)
    for _, w in windows
        try w.gui.Destroy()
    ExitApp()
}
