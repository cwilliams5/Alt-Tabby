#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals

; ============================================================
; Blacklist Editor - GUI for editing Alt-Tabby blacklist
; ============================================================
; Launch with: alt_tabby.ahk --blacklist
; Or from tray menu: "Edit Blacklist..."
;
; Shows 3 tabs for Title, Class, and Pair blacklist patterns.
; Changes are saved to blacklist.txt and WM_COPYDATA reload
; signal is sent via launcher to apply changes immediately.
; ============================================================

global gBE_Gui := 0
global gBE_TitleEdit := 0
global gBE_ClassEdit := 0
global gBE_PairEdit := 0
global gBE_OriginalTitle := ""
global gBE_OriginalClass := ""
global gBE_OriginalPair := ""
global gBE_SavedChanges := false
global gBE_LauncherHwnd := 0

; ============================================================
; PUBLIC API
; ============================================================

; Run the blacklist editor
; Returns: true if changes were saved, false otherwise
BlacklistEditor_Run(launcherHwnd := 0) {
    global gBE_Gui, gBE_SavedChanges, gBE_LauncherHwnd, gBlacklist_FilePath, gBlacklist_Loaded
    gBE_LauncherHwnd := launcherHwnd

    ; Hide tray icon - only launcher should have one
    A_IconHidden := true

    gBE_SavedChanges := false

    ; Initialize blacklist if not already done
    if (!gBlacklist_Loaded)
        Blacklist_Init()

    ; Create and show the GUI
    _BE_CreateGui()
    _BE_LoadValues()

    gBE_Gui.Show()
    GUI_AntiFlashReveal(gBE_Gui, true)

    ; Block until GUI closes
    WinWaitClose(gBE_Gui.Hwnd)

    return gBE_SavedChanges
}

; ============================================================
; GUI CREATION
; ============================================================

_BE_CreateGui() {
    global gBE_Gui, gBE_TitleEdit, gBE_ClassEdit, gBE_PairEdit

    gBE_Gui := Gui("+Resize +MinSize500x400", "Alt-Tabby Blacklist Editor")
    GUI_AntiFlashPrepare(gBE_Gui, Theme_GetBgColor())
    gBE_Gui.OnEvent("Close", _BE_OnClose)
    gBE_Gui.OnEvent("Size", _BE_OnSize)
    gBE_Gui.SetFont("s9", "Segoe UI")
    themeEntry := Theme_ApplyToGui(gBE_Gui)

    ; Help text at top
    helpText := "Windows matching these patterns are excluded from the Alt-Tab list.`nWildcards: * (any chars), ? (single char) - case-insensitive."
    gBE_Gui.AddText("x10 y10 w580 h40 +Wrap", helpText)

    ; Tab control
    tabs := gBE_Gui.AddTab3("vTabs x10 y55 w580 h350", ["Title Patterns", "Class Patterns", "Pair Patterns"])
    Theme_ApplyToControl(tabs, "Tab", themeEntry)

    ; Title tab
    tabs.UseTab("Title Patterns")
    gBE_Gui.AddText("x20 y90 w550", "Title patterns - match window titles (e.g., '*Calculator*', 'Notepad'):")
    gBE_TitleEdit := gBE_Gui.AddEdit("vTitleEdit x20 y115 w550 h250 +Multi +WantReturn +VScroll")
    Theme_ApplyToControl(gBE_TitleEdit, "Edit", themeEntry)

    ; Class tab
    tabs.UseTab("Class Patterns")
    gBE_Gui.AddText("x20 y90 w550", "Class patterns - match window class names (e.g., 'Notepad', 'Chrome_*'):")
    gBE_ClassEdit := gBE_Gui.AddEdit("vClassEdit x20 y115 w550 h250 +Multi +WantReturn +VScroll")
    Theme_ApplyToControl(gBE_ClassEdit, "Edit", themeEntry)

    ; Pair tab
    tabs.UseTab("Pair Patterns")
    gBE_Gui.AddText("x20 y90 w550", "Pair patterns — match class and title together (e.g., 'Chrome_WidgetWin_1|*YouTube*'):")
    gBE_PairEdit := gBE_Gui.AddEdit("vPairEdit x20 y115 w550 h250 +Multi +WantReturn +VScroll")
    Theme_ApplyToControl(gBE_PairEdit, "Edit", themeEntry)

    tabs.UseTab()

    ; Install tab WndProc subclass for text color (must be AFTER all UseTab calls)
    Theme_InstallTabSubclass(tabs)

    ; Register change listeners for dirty indicator
    gBE_TitleEdit.OnEvent("Change", _BE_OnContentChange)
    gBE_ClassEdit.OnEvent("Change", _BE_OnContentChange)
    gBE_PairEdit.OnEvent("Change", _BE_OnContentChange)

    ; Buttons at bottom
    btnTest := gBE_Gui.AddButton("vBtnTest x10 y420 w120 h30", "Test Patterns")
    btnTest.OnEvent("Click", _BE_OnTestPatterns)
    btnSave := gBE_Gui.AddButton("vBtnSave x400 y420 w90 h30", "Save")
    btnSave.OnEvent("Click", _BE_OnSave)
    btnCancel := gBE_Gui.AddButton("vBtnCancel x500 y420 w90 h30", "Cancel")
    btnCancel.OnEvent("Click", _BE_OnCancel)
    Theme_ApplyToControl(btnTest, "Button", themeEntry)
    Theme_ApplyToControl(btnSave, "Button", themeEntry)
    Theme_ApplyToControl(btnCancel, "Button", themeEntry)
}

; ============================================================
; VALUE LOADING/SAVING
; ============================================================

_BE_LoadValues() {
    global gBE_TitleEdit, gBE_ClassEdit, gBE_PairEdit
    global gBE_OriginalTitle, gBE_OriginalClass, gBE_OriginalPair
    global gBlacklist_FilePath

    ; Read the blacklist file
    titleLines := ""
    classLines := ""
    pairLines := ""

    if (FileExist(gBlacklist_FilePath)) {
        try {
            content := FileRead(gBlacklist_FilePath, "UTF-8")

            currentSection := ""
            Loop Parse content, "`n", "`r" {
                line := A_LoopField

                ; Check for section header
                trimmed := Trim(line)
                if (SubStr(trimmed, 1, 1) = "[" && SubStr(trimmed, -1) = "]") {
                    currentSection := SubStr(trimmed, 2, -1)
                    continue
                }

                ; Skip header comments (lines before first section)
                if (currentSection = "")
                    continue

                ; Add to appropriate edit based on section
                if (currentSection = "Title")
                    titleLines .= line "`n"
                else if (currentSection = "Class")
                    classLines .= line "`n"
                else if (currentSection = "Pair")
                    pairLines .= line "`n"
            }
        }
    }

    ; Set edit values
    gBE_TitleEdit.Value := RTrim(titleLines, "`n")
    gBE_ClassEdit.Value := RTrim(classLines, "`n")
    gBE_PairEdit.Value := RTrim(pairLines, "`n")

    ; Store initial state for change detection
    gBE_OriginalTitle := gBE_TitleEdit.Value
    gBE_OriginalClass := gBE_ClassEdit.Value
    gBE_OriginalPair := gBE_PairEdit.Value
}

_BE_SaveToFile() {
    global gBE_TitleEdit, gBE_ClassEdit, gBE_PairEdit
    global gBlacklist_FilePath

    ; Build new file content
    content := "; Alt-Tabby Blacklist Configuration`n"
    content .= "; Windows matching these patterns are excluded from the window list.`n"
    content .= "; Wildcards: * (any chars), ? (single char) - case-insensitive`n"
    content .= ";`n"
    content .= "; To blacklist a window from the viewer, double-click its row.`n"
    content .= "`n"

    ; Title section
    content .= "[Title]`n"
    titleText := gBE_TitleEdit.Value
    if (titleText != "") {
        Loop Parse titleText, "`n", "`r" {
            if (A_LoopField != "")
                content .= A_LoopField "`n"
        }
    }
    content .= "`n"

    ; Class section
    content .= "[Class]`n"
    classText := gBE_ClassEdit.Value
    if (classText != "") {
        Loop Parse classText, "`n", "`r" {
            if (A_LoopField != "")
                content .= A_LoopField "`n"
        }
    }
    content .= "`n"

    ; Pair section
    content .= "[Pair]`n"
    content .= "; Format: Class|Title (both must match)`n"
    pairText := gBE_PairEdit.Value
    if (pairText != "") {
        Loop Parse pairText, "`n", "`r" {
            if (A_LoopField != "")
                content .= A_LoopField "`n"
        }
    }

    ; Write file
    try {
        FileDelete(gBlacklist_FilePath)
        FileAppend(content, gBlacklist_FilePath, "UTF-8")
        return true
    } catch as e {
        ThemeMsgBox("Could not save the blacklist file. It may be read-only or locked by another program.`n`nDetails: " e.Message, "Error", "OK Iconx")
        return false
    }
}

_BE_SendReloadNotify() {
    global gBE_LauncherHwnd, TABBY_CMD_RELOAD_BLACKLIST
    return IPC_SendWmCopyData(gBE_LauncherHwnd, TABBY_CMD_RELOAD_BLACKLIST)
}

_BE_HasChanges() {
    global gBE_TitleEdit, gBE_ClassEdit, gBE_PairEdit
    global gBE_OriginalTitle, gBE_OriginalClass, gBE_OriginalPair
    return (_BE_NormalizeContent(gBE_TitleEdit.Value) != _BE_NormalizeContent(gBE_OriginalTitle)
        || _BE_NormalizeContent(gBE_ClassEdit.Value) != _BE_NormalizeContent(gBE_OriginalClass)
        || _BE_NormalizeContent(gBE_PairEdit.Value) != _BE_NormalizeContent(gBE_OriginalPair))
}

_BE_NormalizeContent(text) {
    ; Strip trailing whitespace from each line and remove blank lines
    result := ""
    Loop Parse text, "`n", "`r" {
        line := RTrim(A_LoopField)
        if (line != "")
            result .= line "`n"
    }
    return RTrim(result, "`n")
}

; ============================================================
; EVENT HANDLERS
; ============================================================

_BE_OnContentChange(*) {
    _BE_UpdateTitle()
}

_BE_UpdateTitle() {
    global gBE_Gui
    if (!_BE_IsGuiValid())
        return
    title := _BE_HasChanges() ? "Alt-Tabby Blacklist *" : "Alt-Tabby Blacklist Editor"
    gBE_Gui.Title := title
}

_BE_OnSave(*) {
    global gBE_Gui, gBE_SavedChanges

    if (_BE_SaveToFile()) {
        ; Notify launcher → GUI to reload blacklist
        reloaded := _BE_SendReloadNotify()

        gBE_SavedChanges := true
        Theme_UntrackGui(gBE_Gui)
        gBE_Gui.Destroy()

        ; Show success message
        msg := "Blacklist saved."
        if (reloaded)
            msg .= " Changes applied immediately."
        else
            msg .= " Alt-Tabby not running - changes will apply on next start."
        ThemeMsgBox(msg, "Alt-Tabby Blacklist", "OK Iconi")
    }
}

_BE_OnCancel(*) {
    global gBE_Gui

    if (_BE_HasChanges()) {
        result := ThemeMsgBox("You have unsaved changes. Discard them?", "Alt-Tabby Blacklist", "YesNo Icon?")
        if (result = "No")
            return
    }

    Theme_UntrackGui(gBE_Gui)
    gBE_Gui.Destroy()
}

_BE_OnClose(guiObj) {
    if (_BE_HasChanges()) {
        result := ThemeMsgBox("You have unsaved changes. Save before closing?", "Alt-Tabby Blacklist", "YesNoCancel Icon?")
        if (result = "Cancel")
            return true  ; Prevent close
        if (result = "Yes") {
            _BE_OnSave()
            return false
        }
        ; "No" falls through to close
    }
    Theme_UntrackGui(guiObj)
    return false  ; Allow close
}

; Check if GUI is still valid (not destroyed)
_BE_IsGuiValid() {
    global gBE_Gui
    if (!gBE_Gui)
        return false
    try {
        hwnd := gBE_Gui.Hwnd
        return hwnd != 0
    } catch {
        return false
    }
}

_BE_OnSize(guiObj, minMax, width, height) {
    ; Guard against destroyed GUI
    if (!_BE_IsGuiValid())
        return

    if (minMax = -1)  ; Minimized
        return

    ; Resize tab control
    try {
        guiObj["Tabs"].Move(, , width - 20, height - 110)
    }

    ; Resize edit controls within tabs
    editHeight := height - 200
    editWidth := width - 50
    try {
        guiObj["TitleEdit"].Move(, , editWidth, editHeight)
        guiObj["ClassEdit"].Move(, , editWidth, editHeight)
        guiObj["PairEdit"].Move(, , editWidth, editHeight)
    }

    ; Move buttons
    try {
        guiObj["BtnCancel"].Move(width - 100, height - 45)
        guiObj["BtnSave"].Move(width - 200, height - 45)
        guiObj["BtnTest"].Move(10, height - 45)
    }
}

; ============================================================
; TEST PATTERNS
; ============================================================
; Tests patterns from the active tab against all visible windows.
; Shows a results popup with matches per pattern.

_BE_OnTestPatterns(*) {
    global gBE_Gui, gBE_TitleEdit, gBE_ClassEdit, gBE_PairEdit
    global DWMWA_CLOAKED

    ; Get active tab
    tabCtrl := gBE_Gui["Tabs"]
    activeTab := tabCtrl.Value  ; 1=Title, 2=Class, 3=Pair

    ; Get patterns from active tab
    switch activeTab {
        case 1: editCtrl := gBE_TitleEdit
        case 2: editCtrl := gBE_ClassEdit
        case 3: editCtrl := gBE_PairEdit
        default: return
    }

    ; Parse non-empty, non-comment lines
    patterns := []
    Loop Parse editCtrl.Value, "`n", "`r" {
        line := Trim(A_LoopField)
        if (line != "" && SubStr(line, 1, 1) != ";")
            patterns.Push(line)
    }

    if (patterns.Length = 0) {
        ThemeMsgBox("No patterns to test on this tab.", "Test Patterns", "OK Iconi")
        return
    }

    ; Enumerate visible, uncloaked windows with titles
    windows := []
    myHwnd := gBE_Gui.Hwnd
    static cloakedBuf := Buffer(4, 0)
    for hwnd in WinGetList() {
        if (hwnd = myHwnd)
            continue
        try {
            title := WinGetTitle(hwnd)
            class := WinGetClass(hwnd)
        } catch
            continue
        if (title = "")
            continue
        if (!DllCall("user32\IsWindowVisible", "Ptr", hwnd, "Int"))
            continue
        DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", hwnd, "UInt", DWMWA_CLOAKED, "Ptr", cloakedBuf.Ptr, "UInt", 4)
        if (NumGet(cloakedBuf, 0, "UInt"))
            continue
        windows.Push({title: title, class: class})
    }

    ; Test each pattern against windows
    output := ""
    matchedPatterns := 0
    maxShown := 10

    for _, pattern in patterns {
        matches := []

        switch activeTab {
            case 1:  ; Title patterns match against window titles
                for _, w in _BE_MatchWindows(windows, pattern, "title")
                    matches.Push(w.title)
            case 2:  ; Class patterns match against window classes
                for _, w in _BE_MatchWindows(windows, pattern, "class")
                    matches.Push(w.class " — " w.title)
            case 3:  ; Pair patterns: Class|Title, both must match
                parts := StrSplit(pattern, "|")
                if (parts.Length < 2)
                    continue
                for _, w in _BE_MatchWindows(_BE_MatchWindows(windows, parts[1], "class"), parts[2], "title")
                    matches.Push(w.class " | " w.title)
        }

        output .= pattern "`r`n"
        if (matches.Length > 0) {
            matchedPatterns++
            for i, m in matches {
                if (i > maxShown) {
                    output .= "    ... and " (matches.Length - maxShown) " more`r`n"
                    break
                }
                output .= "    > " m "`r`n"
            }
        } else {
            output .= "    (no matches)`r`n"
        }
        output .= "`r`n"
    }

    tabName := (activeTab = 1) ? "title" : (activeTab = 2) ? "class" : "pair"
    summary := matchedPatterns " of " patterns.Length " " tabName " patterns matched against " windows.Length " visible windows."

    _BE_ShowTestResults(summary, output)
}

; Match windows whose field matches a wildcard pattern
; windows: array of {title, class} objects
; pattern: wildcard string (passed to BL_CompileWildcard)
; fieldName: property name to match against ("title" or "class")
; Returns: array of matching window objects
_BE_MatchWindows(windows, pattern, fieldName) {
    try regex := BL_CompileWildcard(pattern)
    catch
        return []
    matched := []
    for _, w in windows {
        if (RegExMatch(w.%fieldName%, regex))
            matched.Push(w)
    }
    return matched
}

_BE_ShowTestResults(summary, details) {
    rg := Gui("+AlwaysOnTop -MinimizeBox", "Test Results")
    GUI_AntiFlashPrepare(rg, Theme_GetBgColor())
    rg.SetFont("s10", "Segoe UI")
    rg.MarginX := 16
    rg.MarginY := 12
    themeEntry := Theme_ApplyToGui(rg)

    hdr := rg.AddText("w456 c" Theme_GetAccentColor(), summary)
    Theme_MarkAccent(hdr)

    rg.SetFont("s9", "Consolas")
    edit := rg.AddEdit("w456 h300 y+12 +ReadOnly +Multi +VScroll +HScroll", details)
    Theme_ApplyToControl(edit, "Edit", themeEntry)

    rg.SetFont("s10", "Segoe UI")
    btnClose := rg.AddButton("x" (16 + 456 - 80) " w80 y+12 Default", "Close")
    btnClose.OnEvent("Click", (*) => (Theme_UntrackGui(rg), rg.Destroy()))
    Theme_ApplyToControl(btnClose, "Button", themeEntry)

    rg.OnEvent("Close", (*) => (Theme_UntrackGui(rg), rg.Destroy()))
    rg.OnEvent("Escape", (*) => (Theme_UntrackGui(rg), rg.Destroy()))

    rg.Show("w488")
    GUI_AntiFlashReveal(rg, true)
}
