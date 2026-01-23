#Requires AutoHotkey v2.0

; ============================================================
; Blacklist Module - File-based window blacklist
; ============================================================
; Loads blacklist patterns from blacklist.txt and provides
; matching functions for producers to filter windows.
;
; File format:
;   [Title]     - Title patterns (one per line)
;   [Class]     - Class patterns (one per line)
;   [Pair]      - Class|Title pairs (both must match)
;
; Wildcards: * (any chars), ? (single char) - case-insensitive
; Lines starting with ; are comments
; ============================================================

; Parsed blacklist data
global gBlacklist_Titles := []
global gBlacklist_Classes := []
global gBlacklist_Pairs := []
global gBlacklist_FilePath := ""
global gBlacklist_Loaded := false

; Initialize and load blacklist from file
Blacklist_Init(filePath := "") {
    global gBlacklist_FilePath

    if (filePath = "") {
        if (A_IsCompiled) {
            ; Compiled: blacklist.txt lives next to the exe
            ; Don't fall back to subdirectories - file will be created here if missing
            gBlacklist_FilePath := A_ScriptDir "\blacklist.txt"
        } else {
            ; Development: try various relative paths
            ; From src/ (alt_tabby.ahk)
            gBlacklist_FilePath := A_ScriptDir "\shared\blacklist.txt"
            if (!FileExist(gBlacklist_FilePath)) {
                ; From src/store/ or src/gui/
                gBlacklist_FilePath := A_ScriptDir "\..\shared\blacklist.txt"
            }
            if (!FileExist(gBlacklist_FilePath)) {
                ; Fallback to same directory
                gBlacklist_FilePath := A_ScriptDir "\blacklist.txt"
            }
        }
    } else {
        gBlacklist_FilePath := filePath
    }

    return Blacklist_Reload()
}

; Reload blacklist from file (creates default if missing)
; Uses atomic swap pattern to prevent race conditions - producers calling
; Blacklist_IsMatch() during reload will see either old or new data, never empty arrays.
Blacklist_Reload() {
    global gBlacklist_Titles, gBlacklist_Classes, gBlacklist_Pairs
    global gBlacklist_FilePath, gBlacklist_Loaded

    ; Build new lists in LOCAL variables first (not globals)
    newTitles := []
    newClasses := []
    newPairs := []

    if (!FileExist(gBlacklist_FilePath)) {
        ; Try to create default blacklist
        _Blacklist_CreateDefault(gBlacklist_FilePath)
    }

    if (!FileExist(gBlacklist_FilePath)) {
        ; Atomic swap to empty lists
        gBlacklist_Titles := newTitles
        gBlacklist_Classes := newClasses
        gBlacklist_Pairs := newPairs
        gBlacklist_Loaded := false
        return false
    }

    try {
        content := FileRead(gBlacklist_FilePath, "UTF-8")
    } catch {
        ; Don't clear existing lists on read error - keep old data
        gBlacklist_Loaded := false
        return false
    }

    currentSection := ""

    Loop Parse, content, "`n", "`r" {
        line := Trim(A_LoopField)

        ; Skip empty lines and comments
        if (line = "" || SubStr(line, 1, 1) = ";")
            continue

        ; Check for section header
        if (SubStr(line, 1, 1) = "[" && SubStr(line, -1) = "]") {
            currentSection := SubStr(line, 2, -1)
            continue
        }

        ; Add to LOCAL lists based on current section
        if (currentSection = "Title") {
            newTitles.Push(line)
        } else if (currentSection = "Class") {
            newClasses.Push(line)
        } else if (currentSection = "Pair") {
            ; Parse Class|Title format
            parts := StrSplit(line, "|")
            if (parts.Length >= 2) {
                newPairs.Push({ Class: parts[1], Title: parts[2] })
            }
        }
    }

    ; ATOMIC SWAP: Replace all globals at once
    ; In AHK v2's cooperative model, these assignments complete atomically
    ; between statement boundaries, so producers never see partial state
    gBlacklist_Titles := newTitles
    gBlacklist_Classes := newClasses
    gBlacklist_Pairs := newPairs
    gBlacklist_Loaded := true
    return true
}

; Check if a window matches any blacklist pattern
Blacklist_IsMatch(title, class) {
    global gBlacklist_Titles, gBlacklist_Classes, gBlacklist_Pairs, gBlacklist_Loaded

    if (!gBlacklist_Loaded)
        return false

    ; Check title blacklist
    for _, pattern in gBlacklist_Titles {
        if (_BL_WildcardMatch(title, pattern))
            return true
    }

    ; Check class blacklist
    for _, pattern in gBlacklist_Classes {
        if (_BL_WildcardMatch(class, pattern))
            return true
    }

    ; Check pair blacklist (both must match)
    for _, pair in gBlacklist_Pairs {
        if (_BL_WildcardMatch(class, pair.Class) && _BL_WildcardMatch(title, pair.Title))
            return true
    }

    return false
}

; Add a new pair entry to the blacklist file (appends to [Pair] section)
Blacklist_AddPair(class, title) {
    global gBlacklist_FilePath

    if (gBlacklist_FilePath = "")
        return false

    ; Format: Class|Title
    entry := class "|" title "`n"

    try {
        FileAppend(entry, gBlacklist_FilePath, "UTF-8")
        return true
    } catch {
        return false
    }
}

; Add a class pattern to the blacklist file
Blacklist_AddClass(class) {
    global gBlacklist_FilePath

    if (gBlacklist_FilePath = "" || class = "")
        return false

    try {
        ; Read file, find [Class] section, insert entry
        content := FileRead(gBlacklist_FilePath, "UTF-8")
        newContent := _BL_InsertInSection(content, "Class", class)
        if (newContent = content)
            return false  ; Failed to insert
        FileDelete(gBlacklist_FilePath)
        FileAppend(newContent, gBlacklist_FilePath, "UTF-8")
        return true
    } catch {
        return false
    }
}

; Add a title pattern to the blacklist file
Blacklist_AddTitle(title) {
    global gBlacklist_FilePath

    if (gBlacklist_FilePath = "" || title = "")
        return false

    try {
        ; Read file, find [Title] section, insert entry
        content := FileRead(gBlacklist_FilePath, "UTF-8")
        newContent := _BL_InsertInSection(content, "Title", title)
        if (newContent = content)
            return false  ; Failed to insert
        FileDelete(gBlacklist_FilePath)
        FileAppend(newContent, gBlacklist_FilePath, "UTF-8")
        return true
    } catch {
        return false
    }
}

; Insert entry into a specific section of the blacklist file
_BL_InsertInSection(content, sectionName, entry) {
    ; Find the section header
    sectionHeader := "[" sectionName "]"
    pos := InStr(content, sectionHeader)
    if (!pos)
        return content  ; Section not found

    ; Find end of header line
    lineEnd := InStr(content, "`n", , pos)
    if (!lineEnd)
        lineEnd := StrLen(content)

    ; Insert entry after the section header
    before := SubStr(content, 1, lineEnd)
    after := SubStr(content, lineEnd + 1)

    return before entry "`n" after
}

; ============================================================
; Window Eligibility - Centralized Alt-Tab eligibility check
; ============================================================

; Check if a window should be included (passes Alt-Tab eligibility AND blacklist)
; Returns true if window should be included, false if it should be filtered out
Blacklist_IsWindowEligible(hwnd, title := "", class := "") {
    global cfg

    ; Get window info if not provided
    if (title = "" || class = "") {
        try {
            if (title = "")
                title := WinGetTitle("ahk_id " hwnd)
            if (class = "")
                class := WinGetClass("ahk_id " hwnd)
        } catch {
            return false
        }
    }

    ; Skip windows with no title
    if (title = "")
        return false

    ; Check Alt-Tab eligibility (keep HasOwnProp - may run before full init)
    useAltTab := cfg.HasOwnProp("UseAltTabEligibility") ? cfg.UseAltTabEligibility : true
    if (useAltTab && !_BL_IsAltTabEligible(hwnd))
        return false

    ; Check blacklist (keep HasOwnProp - may run before full init)
    useBlacklist := cfg.HasOwnProp("UseBlacklist") ? cfg.UseBlacklist : true
    if (useBlacklist && Blacklist_IsMatch(title, class))
        return false

    return true
}

; Alt-Tab eligibility rules (matches Windows behavior)
_BL_IsAltTabEligible(hwnd) {
    ; Get visibility state
    isVisible := DllCall("user32\IsWindowVisible", "ptr", hwnd, "int") != 0
    isMin := DllCall("user32\IsIconic", "ptr", hwnd, "int") != 0

    ; Get regular window style
    style := DllCall("user32\GetWindowLongPtrW", "ptr", hwnd, "int", -16, "ptr")  ; GWL_STYLE

    WS_CHILD := 0x40000000

    ; Child windows are never Alt-Tab eligible
    if (style & WS_CHILD)
        return false

    ; Get extended window style
    ex := DllCall("user32\GetWindowLongPtrW", "ptr", hwnd, "int", -20, "ptr")  ; GWL_EXSTYLE

    WS_EX_TOOLWINDOW := 0x00000080
    WS_EX_APPWINDOW := 0x00040000
    WS_EX_NOACTIVATE := 0x08000000

    isTool := (ex & WS_EX_TOOLWINDOW) != 0
    isApp := (ex & WS_EX_APPWINDOW) != 0
    isNoActivate := (ex & WS_EX_NOACTIVATE) != 0

    ; Tool windows are never Alt-Tab eligible
    if (isTool)
        return false

    ; NoActivate windows are not Alt-Tab eligible
    if (isNoActivate)
        return false

    ; Get owner window
    owner := DllCall("user32\GetWindow", "ptr", hwnd, "uint", 4, "ptr")  ; GW_OWNER

    ; Owned windows need WS_EX_APPWINDOW to be eligible
    if (owner != 0 && !isApp)
        return false

    ; Check DWM cloaking
    cloakedBuf := Buffer(4, 0)
    hr := DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", 14, "ptr", cloakedBuf.Ptr, "uint", 4, "int")
    isCloaked := (hr = 0) && (NumGet(cloakedBuf, 0, "UInt") != 0)

    ; Must be visible, minimized, or cloaked
    if !(isVisible || isMin || isCloaked)
        return false

    return true
}

; Case-insensitive wildcard match (* and ?)
_BL_WildcardMatch(str, pattern) {
    if (pattern = "")
        return false
    ; Convert wildcard pattern to regex
    regex := "i)^" RegExReplace(RegExReplace(pattern, "[.+^${}|()\\[\]]", "\$0"), "\*", ".*")
    regex := RegExReplace(regex, "\?", ".")
    regex .= "$"
    return RegExMatch(str, regex)
}

; Get current blacklist stats (for debugging)
Blacklist_GetStats() {
    global gBlacklist_Titles, gBlacklist_Classes, gBlacklist_Pairs, gBlacklist_FilePath
    return {
        filePath: gBlacklist_FilePath,
        titles: gBlacklist_Titles.Length,
        classes: gBlacklist_Classes.Length,
        pairs: gBlacklist_Pairs.Length
    }
}

; Create default blacklist file with common Windows exclusions
_Blacklist_CreateDefault(path) {
    content := "; Alt-Tabby Blacklist Configuration`n"
    content .= "; Windows matching these patterns are excluded from the window list.`n"
    content .= "; Wildcards: * (any chars), ? (single char) - case-insensitive`n"
    content .= ";`n"
    content .= "; To blacklist a window from the viewer, double-click its row.`n"
    content .= "`n"
    content .= "[Title]`n"
    content .= "komoborder*`n"
    content .= "YasbBar`n"
    content .= "NVIDIA GeForce Overlay`n"
    content .= "DWM Notification Window`n"
    content .= "MSCTFIME UI`n"
    content .= "Default IME`n"
    content .= "Task Switching`n"
    content .= "Command Palette`n"
    content .= "GDI+ Window*`n"
    content .= "Windows Input Experience`n"
    content .= "Program Manager`n"
    content .= "`n"
    content .= "[Class]`n"
    content .= "komoborder*`n"
    content .= "CEF-OSC-WIDGET`n"
    content .= "Dwm`n"
    content .= "MSCTFIME UI`n"
    content .= "IME`n"
    content .= "MSTaskSwWClass`n"
    content .= "MSTaskListWClass`n"
    content .= "Shell_TrayWnd`n"
    content .= "Shell_SecondaryTrayWnd`n"
    content .= "GDI+ Hook Window Class`n"
    content .= "XamlExplorerHostIslandWindow`n"
    content .= "WinUIDesktopWin32WindowClass`n"
    content .= "Windows.UI.Core.CoreWindow`n"
    content .= "Qt*QWindow*`n"
    content .= "AutoHotkeyGUI`n"
    content .= "`n"
    content .= "[Pair]`n"
    content .= "; Format: Class|Title (both must match)`n"
    content .= "GDI+ Hook Window Class|GDI+ Window*`n"

    try {
        FileAppend(content, path, "UTF-8")
        return true
    } catch {
        return false
    }
}
