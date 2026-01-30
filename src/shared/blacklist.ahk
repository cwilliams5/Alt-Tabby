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

; Pre-compiled regex arrays (built during Blacklist_Reload, used in Blacklist_IsMatch hot path)
global gBlacklist_TitleRegex := []
global gBlacklist_ClassRegex := []
global gBlacklist_PairClassRegex := []
global gBlacklist_PairTitleRegex := []

; Window style constants for eligibility checks
global BL_WS_CHILD := 0x40000000
global BL_WS_EX_TOOLWINDOW := 0x00000080
global BL_WS_EX_APPWINDOW := 0x00040000
global BL_WS_EX_NOACTIVATE := 0x08000000

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
    global gBlacklist_TitleRegex, gBlacklist_ClassRegex, gBlacklist_PairClassRegex, gBlacklist_PairTitleRegex
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
        ; Atomic swap to empty lists (including regex arrays)
        Critical "On"
        gBlacklist_Titles := newTitles
        gBlacklist_Classes := newClasses
        gBlacklist_Pairs := newPairs
        gBlacklist_TitleRegex := []
        gBlacklist_ClassRegex := []
        gBlacklist_PairClassRegex := []
        gBlacklist_PairTitleRegex := []
        gBlacklist_Loaded := false
        Critical "Off"
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

    ; Pre-compile: avoids per-match regex string building in hot path
    newTitleRegex := []
    for _, p in newTitles
        newTitleRegex.Push(_BL_CompileWildcard(p))
    newClassRegex := []
    for _, p in newClasses
        newClassRegex.Push(_BL_CompileWildcard(p))
    newPairClassRegex := []
    newPairTitleRegex := []
    for _, pair in newPairs {
        newPairClassRegex.Push(_BL_CompileWildcard(pair.Class))
        newPairTitleRegex.Push(_BL_CompileWildcard(pair.Title))
    }

    ; ATOMIC SWAP: Replace all globals at once under Critical to prevent
    ; producers calling Blacklist_IsMatch() from seeing mismatched arrays
    Critical "On"
    gBlacklist_Titles := newTitles
    gBlacklist_Classes := newClasses
    gBlacklist_Pairs := newPairs
    gBlacklist_TitleRegex := newTitleRegex
    gBlacklist_ClassRegex := newClassRegex
    gBlacklist_PairClassRegex := newPairClassRegex
    gBlacklist_PairTitleRegex := newPairTitleRegex
    gBlacklist_Loaded := true
    Critical "Off"
    return true
}

; Check if a window matches any blacklist pattern
; Uses pre-compiled regex arrays for hot-path performance (no per-match string building)
Blacklist_IsMatch(title, class) {
    global gBlacklist_TitleRegex, gBlacklist_ClassRegex
    global gBlacklist_PairClassRegex, gBlacklist_PairTitleRegex, gBlacklist_Loaded

    if (!gBlacklist_Loaded)
        return false

    ; Check title blacklist (pre-compiled regex)
    for _, regex in gBlacklist_TitleRegex {
        if (RegExMatch(title, regex))
            return true
    }

    ; Check class blacklist (pre-compiled regex)
    for _, regex in gBlacklist_ClassRegex {
        if (RegExMatch(class, regex))
            return true
    }

    ; Check pair blacklist (both must match, pre-compiled regex)
    for i, _ in gBlacklist_PairClassRegex {
        if (RegExMatch(class, gBlacklist_PairClassRegex[i]) && RegExMatch(title, gBlacklist_PairTitleRegex[i]))
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
    if (class = "")
        return false
    return _BL_AddToSection("Class", class)
}

; Add a title pattern to the blacklist file
Blacklist_AddTitle(title) {
    if (title = "")
        return false
    return _BL_AddToSection("Title", title)
}

; Internal helper: Add an entry to a specific section of the blacklist file
_BL_AddToSection(sectionName, entry) {
    global gBlacklist_FilePath

    if (gBlacklist_FilePath = "")
        return false

    try {
        ; Read file, find section, insert entry
        content := FileRead(gBlacklist_FilePath, "UTF-8")
        newContent := _BL_InsertInSection(content, sectionName, entry)
        if (newContent = content)
            return false  ; Failed to insert (section not found)
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
        ; Skip hung windows - WinGetTitle/WinGetClass send messages that block up to 5s
        try {
            if (DllCall("user32\IsHungAppWindow", "ptr", hwnd, "int"))
                return false
        }
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
; Delegates to Ex variant for shared implementation
_BL_IsAltTabEligible(hwnd) {
    vis := false, min := false, clk := false
    return _BL_IsAltTabEligibleEx(hwnd, &vis, &min, &clk)
}

; Extended Alt-Tab eligibility - returns vis/min/cloak via ByRef
; Used by Blacklist_IsWindowEligibleEx to avoid redundant DllCalls in WinUtils_ProbeWindow
_BL_IsAltTabEligibleEx(hwnd, &outVis, &outMin, &outCloak) {
    global BL_WS_CHILD, BL_WS_EX_TOOLWINDOW, BL_WS_EX_APPWINDOW, BL_WS_EX_NOACTIVATE, DWMWA_CLOAKED
    static cloakedBuf := Buffer(4, 0)

    ; Get visibility state
    outVis := DllCall("user32\IsWindowVisible", "ptr", hwnd, "int") != 0
    outMin := DllCall("user32\IsIconic", "ptr", hwnd, "int") != 0

    ; Get regular window style
    style := DllCall("user32\GetWindowLongPtrW", "ptr", hwnd, "int", -16, "ptr")  ; GWL_STYLE

    ; Child windows are never Alt-Tab eligible
    if (style & BL_WS_CHILD)
        return false

    ; Get extended window style
    ex := DllCall("user32\GetWindowLongPtrW", "ptr", hwnd, "int", -20, "ptr")  ; GWL_EXSTYLE

    isTool := (ex & BL_WS_EX_TOOLWINDOW) != 0
    isApp := (ex & BL_WS_EX_APPWINDOW) != 0
    isNoActivate := (ex & BL_WS_EX_NOACTIVATE) != 0

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
    hr := DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", DWMWA_CLOAKED, "ptr", cloakedBuf.Ptr, "uint", 4, "int")
    outCloak := (hr = 0) && (NumGet(cloakedBuf, 0, "UInt") != 0)

    ; Must be visible, minimized, or cloaked
    if !(outVis || outMin || outCloak)
        return false

    return true
}

; Extended eligibility check - returns vis/min/cloak via ByRef when eligible
; Avoids redundant DllCalls when caller also needs these values (e.g., WinUtils_ProbeWindow)
Blacklist_IsWindowEligibleEx(hwnd, title, class, &outVis, &outMin, &outCloak) {
    global cfg
    static cloakedBuf := Buffer(4, 0)

    ; Skip windows with no title
    if (title = "")
        return false

    ; Check Alt-Tab eligibility (keep HasOwnProp - may run before full init)
    useAltTab := cfg.HasOwnProp("UseAltTabEligibility") ? cfg.UseAltTabEligibility : true
    if (useAltTab) {
        if (!_BL_IsAltTabEligibleEx(hwnd, &outVis, &outMin, &outCloak))
            return false
    } else {
        ; Fetch vis/min/cloak directly when eligibility check is skipped
        outVis := DllCall("user32\IsWindowVisible", "ptr", hwnd, "int") != 0
        outMin := DllCall("user32\IsIconic", "ptr", hwnd, "int") != 0
        global DWMWA_CLOAKED
        hr := DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", DWMWA_CLOAKED, "ptr", cloakedBuf.Ptr, "uint", 4, "int")
        outCloak := (hr = 0) && (NumGet(cloakedBuf, 0, "UInt") != 0)
    }

    ; Check blacklist (keep HasOwnProp - may run before full init)
    useBlacklist := cfg.HasOwnProp("UseBlacklist") ? cfg.UseBlacklist : true
    if (useBlacklist && Blacklist_IsMatch(title, class))
        return false

    return true
}

; Pre-compile wildcard pattern to regex string (called during Blacklist_Reload)
_BL_CompileWildcard(pattern) {
    regex := "i)^" RegExReplace(RegExReplace(pattern, "[.+^${}|()\\[\]]", "\$0"), "\*", ".*")
    regex := RegExReplace(regex, "\?", ".")
    regex .= "$"
    return regex
}

; Case-insensitive wildcard match (* and ?) — cold path only (one-off callers)
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
