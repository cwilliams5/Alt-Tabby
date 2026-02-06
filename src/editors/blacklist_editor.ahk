#Requires AutoHotkey v2.0
#Warn VarUnset, Off  ; Suppress warnings for cross-file globals

; ============================================================
; Blacklist Editor - GUI for editing Alt-Tabby blacklist
; ============================================================
; Launch with: alt_tabby.ahk --blacklist
; Or from tray menu: "Edit Blacklist..."
;
; Shows 3 tabs for Title, Class, and Pair blacklist patterns.
; Changes are saved to blacklist.txt and IPC reload message
; is sent to the store to apply changes immediately.
; ============================================================

global gBE_Gui := 0
global gBE_TitleEdit := 0
global gBE_ClassEdit := 0
global gBE_PairEdit := 0
global gBE_OriginalContent := ""
global gBE_SavedChanges := false

; ============================================================
; PUBLIC API
; ============================================================

; Run the blacklist editor
; Returns: true if changes were saved, false otherwise
BlacklistEditor_Run() {
    global gBE_Gui, gBE_SavedChanges, gBlacklist_FilePath, gBlacklist_Loaded

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
    _GUI_AntiFlashReveal(gBE_Gui, true)

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
    _GUI_AntiFlashPrepare(gBE_Gui, "F0F0F0", true)
    gBE_Gui.OnEvent("Close", _BE_OnClose)
    gBE_Gui.OnEvent("Size", _BE_OnSize)
    gBE_Gui.SetFont("s9", "Segoe UI")

    ; Help text at top
    helpText := "Windows matching these patterns are excluded from the Alt-Tab list.`nWildcards: * (any chars), ? (single char) - case-insensitive."
    gBE_Gui.AddText("x10 y10 w580 h40 +Wrap", helpText)

    ; Tab control
    tabs := gBE_Gui.AddTab3("vTabs x10 y55 w580 h350", ["Title Patterns", "Class Patterns", "Pair Patterns"])

    ; Title tab
    tabs.UseTab("Title Patterns")
    gBE_Gui.AddText("x20 y90 w550", "Title patterns - match window titles (e.g., '*Calculator*', 'Notepad'):")
    gBE_TitleEdit := gBE_Gui.AddEdit("vTitleEdit x20 y115 w550 h250 +Multi +WantReturn +VScroll")

    ; Class tab
    tabs.UseTab("Class Patterns")
    gBE_Gui.AddText("x20 y90 w550", "Class patterns - match window class names (e.g., 'Notepad', 'Chrome_*'):")
    gBE_ClassEdit := gBE_Gui.AddEdit("vClassEdit x20 y115 w550 h250 +Multi +WantReturn +VScroll")

    ; Pair tab
    tabs.UseTab("Pair Patterns")
    gBE_Gui.AddText("x20 y90 w550", "Pair patterns - match Class|Title pairs (both must match). Format: ClassName|TitlePattern")
    gBE_PairEdit := gBE_Gui.AddEdit("vPairEdit x20 y115 w550 h250 +Multi +WantReturn +VScroll")

    tabs.UseTab()

    ; Buttons at bottom
    gBE_Gui.AddButton("vBtnSave x400 y420 w90 h30", "Save").OnEvent("Click", _BE_OnSave)
    gBE_Gui.AddButton("vBtnCancel x500 y420 w90 h30", "Cancel").OnEvent("Click", _BE_OnCancel)
}

; ============================================================
; VALUE LOADING/SAVING
; ============================================================

_BE_LoadValues() {
    global gBE_TitleEdit, gBE_ClassEdit, gBE_PairEdit, gBE_OriginalContent
    global gBlacklist_FilePath

    ; Read the blacklist file
    titleLines := ""
    classLines := ""
    pairLines := ""

    if (FileExist(gBlacklist_FilePath)) {
        try {
            content := FileRead(gBlacklist_FilePath, "UTF-8")
            gBE_OriginalContent := content

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
        MsgBox("Failed to save blacklist: " e.Message, "Error", "OK Iconx")
        return false
    }
}

_BE_SendReloadIPC() {
    global cfg, IPC_MSG_RELOAD_BLACKLIST, TIMING_STORE_PROCESS_WAIT

    ; Get store pipe name
    pipeName := cfg.HasOwnProp("StorePipeName") ? cfg.StorePipeName : "tabby_store_v1"

    ; Try to connect to store
    try {
        client := IPC_PipeClient_Connect(pipeName, (*) => 0)
        if (client.hPipe) {
            msg := { type: IPC_MSG_RELOAD_BLACKLIST }
            IPC_PipeClient_Send(client, JSON.Dump(msg))
            Sleep(TIMING_STORE_PROCESS_WAIT)  ; Give store time to process
            IPC_PipeClient_Close(client)
            return true
        }
    }
    return false
}

_BE_HasChanges() {
    global gBE_TitleEdit, gBE_ClassEdit, gBE_PairEdit, gBE_OriginalContent

    ; Rebuild content and compare
    newContent := "[Title]`n" gBE_TitleEdit.Value "`n[Class]`n" gBE_ClassEdit.Value "`n[Pair]`n" gBE_PairEdit.Value

    ; Extract comparable content from original
    oldContent := ""
    currentSection := ""
    Loop Parse gBE_OriginalContent, "`n", "`r" {
        trimmed := Trim(A_LoopField)
        if (SubStr(trimmed, 1, 1) = "[")
            oldContent .= trimmed "`n"
        else if (trimmed != "" && SubStr(trimmed, 1, 1) != ";" && currentSection != "")
            oldContent .= trimmed "`n"
        if (SubStr(trimmed, 1, 1) = "[")
            currentSection := trimmed
    }

    return (newContent != oldContent)
}

; ============================================================
; EVENT HANDLERS
; ============================================================

_BE_OnSave(*) {
    global gBE_Gui, gBE_SavedChanges

    if (_BE_SaveToFile()) {
        ; Try to notify store
        reloaded := _BE_SendReloadIPC()

        gBE_SavedChanges := true
        gBE_Gui.Destroy()

        ; Show success message
        msg := "Blacklist saved."
        if (reloaded)
            msg .= " Store notified to reload."
        else
            msg .= " Store not running - changes will apply on next start."
        MsgBox(msg, "Alt-Tabby Blacklist", "OK Iconi")
    }
}

_BE_OnCancel(*) {
    global gBE_Gui

    if (_BE_HasChanges()) {
        result := MsgBox("You have unsaved changes. Discard them?", "Alt-Tabby Blacklist", "YesNo Icon?")
        if (result = "No")
            return
    }

    gBE_Gui.Destroy()
}

_BE_OnClose(guiObj) {
    if (_BE_HasChanges()) {
        result := MsgBox("You have unsaved changes. Save before closing?", "Alt-Tabby Blacklist", "YesNoCancel Icon?")
        if (result = "Cancel")
            return true  ; Prevent close
        if (result = "Yes")
            _BE_OnSave()
        ; "No" falls through to close
    }
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
    }
}
