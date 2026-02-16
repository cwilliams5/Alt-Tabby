#Requires AutoHotkey v2.0
#SingleInstance Force

; Cosmetic Tester — cycles window title and icon to test Alt-Tabby's
; cosmetic patch pipeline (title + icon updates during ACTIVE state).

; Extract icons from well-known system executables
iconPaths := [
    A_WinDir "\explorer.exe",
    A_WinDir "\notepad.exe",
    A_WinDir "\System32\cmd.exe",
    A_WinDir "\System32\mspaint.exe",
    A_WinDir "\System32\calc.exe",
    A_WinDir "\System32\SnippingTool.exe",
    A_WinDir "\System32\taskmgr.exe",
]

; Pre-extract HICONs
icons := []
for _, path in iconPaths {
    if (!FileExist(path))
        continue
    hLarge := 0
    hSmall := 0
    DllCall("shell32\ExtractIconExW", "wstr", path, "int", 0, "ptr*", &hLarge, "ptr*", &hSmall, "uint", 1, "uint")
    if (hLarge) {
        if (hSmall)
            DllCall("user32\DestroyIcon", "ptr", hSmall)
        icons.Push(hLarge)
    } else if (hSmall) {
        icons.Push(hSmall)
    }
}

myGui := Gui("+Resize", "CosmeticTester - 0")
myGui.Add("Text", "w350 vInfo",
    "Title changes every 500ms, icon every 2s.`n"
    "Icons loaded: " icons.Length "`n"
    "Close or press Escape to stop.")
myGui.Show("w370 h100")

counter := 0
iconIdx := 0

SetTimer(UpdateTitle, 500)
SetTimer(UpdateIcon, 2000)

UpdateTitle() {
    global myGui, counter
    counter++
    try myGui.Title := "CosmeticTester - " counter
}

UpdateIcon() {
    global myGui, icons, iconIdx
    if (icons.Length = 0)
        return
    iconIdx := Mod(iconIdx, icons.Length) + 1
    hIcon := icons[iconIdx]
    ; WM_SETICON for both big (ICON_BIG=1) and small (ICON_SMALL=0)
    DllCall("user32\SendMessageW", "ptr", myGui.Hwnd, "uint", 0x80, "uptr", 1, "ptr", hIcon)
    DllCall("user32\SendMessageW", "ptr", myGui.Hwnd, "uint", 0x80, "uptr", 0, "ptr", hIcon)
}

myGui.OnEvent("Close", CleanupAndExit)
Escape::CleanupAndExit()

CleanupAndExit(*) {
    global icons
    for _, h in icons
        try DllCall("user32\DestroyIcon", "ptr", h)
    ExitApp()
}
