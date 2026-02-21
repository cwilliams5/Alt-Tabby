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
global gBlacklist_FilePath := ""
global gBlacklist_Loaded := false

; Pre-compiled regex arrays (built during _Blacklist_Reload, used in Blacklist_IsMatch hot path)
global gBlacklist_TitleRegex := []
global gBlacklist_ClassRegex := []
global gBlacklist_PairRegex := []  ; [{class: regex, title: regex}, ...]

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
                ; From src/core/ or src/gui/
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

    return _Blacklist_Reload()
}

; Reload blacklist from file (creates default if missing)
; Uses atomic swap pattern to prevent race conditions - producers calling
; Blacklist_IsMatch() during reload will see either old or new data, never empty arrays.
_Blacklist_Reload() {
    global gBlacklist_TitleRegex, gBlacklist_ClassRegex, gBlacklist_PairRegex
    global gBlacklist_FilePath, gBlacklist_Loaded, LOG_PATH_STORE

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
        gBlacklist_TitleRegex := []
        gBlacklist_ClassRegex := []
        gBlacklist_PairRegex := []
        gBlacklist_Loaded := false
        Critical "Off"
        return false
    }

    try {
        content := FileRead(gBlacklist_FilePath, "UTF-8")
    } catch as e {
        ; Keep stale data usable on transient read error (e.g., file lock)
        LogAppend(LOG_PATH_STORE, "blacklist read error: " e.Message " path=" gBlacklist_FilePath)
        return false
    }

    currentSection := ""

    Loop Parse content, "`n", "`r" {
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
        newTitleRegex.Push(BL_CompileWildcard(p))
    newClassRegex := []
    for _, p in newClasses
        newClassRegex.Push(BL_CompileWildcard(p))
    newPairRegex := []
    for _, pair in newPairs
        newPairRegex.Push({class: BL_CompileWildcard(pair.Class), title: BL_CompileWildcard(pair.Title)})

    ; ATOMIC SWAP: Replace all globals at once under Critical to prevent
    ; producers calling Blacklist_IsMatch() from seeing mismatched arrays
    Critical "On"
    gBlacklist_TitleRegex := newTitleRegex
    gBlacklist_ClassRegex := newClassRegex
    gBlacklist_PairRegex := newPairRegex
    gBlacklist_Loaded := true
    Critical "Off"
    return true
}

; Check if a window matches any blacklist pattern
; Uses pre-compiled regex arrays for hot-path performance (no per-match string building)
Blacklist_IsMatch(title, class) {
    global gBlacklist_TitleRegex, gBlacklist_ClassRegex
    global gBlacklist_PairRegex, gBlacklist_Loaded

    if (!gBlacklist_Loaded)
        return false

    ; RACE FIX: Snapshot globals into locals so a concurrent _Blacklist_Reload() swapping
    ; shorter arrays mid-iteration can't cause index-out-of-bounds (zero-cost: AHK arrays are refs)
    titleRegex := gBlacklist_TitleRegex
    classRegex := gBlacklist_ClassRegex
    pairRegex := gBlacklist_PairRegex

    ; Check title blacklist (pre-compiled regex)
    for _, regex in titleRegex {
        if (RegExMatch(title, regex)) {
            Stats_BumpLifetimeStat("TotalBlacklistSkips")
            return true
        }
    }

    ; Check class blacklist (pre-compiled regex)
    for _, regex in classRegex {
        if (RegExMatch(class, regex)) {
            Stats_BumpLifetimeStat("TotalBlacklistSkips")
            return true
        }
    }

    ; Check pair blacklist (both must match, pre-compiled regex)
    for _, pr in pairRegex {
        if (RegExMatch(class, pr.class) && RegExMatch(title, pr.title)) {
            Stats_BumpLifetimeStat("TotalBlacklistSkips")
            return true
        }
    }

    return false
}

; Add a new pair entry to the blacklist file (inserts into [Pair] section)
Blacklist_AddPair(class, title) {
    if (class = "" || title = "")
        return false
    return _BL_AddToSection("Pair", class "|" title)
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
    global gBlacklist_FilePath, LOG_PATH_STORE

    if (gBlacklist_FilePath = "")
        return false

    try {
        ; Read file, find section, insert entry
        content := FileRead(gBlacklist_FilePath, "UTF-8")
        newContent := _BL_InsertInSection(content, sectionName, entry)
        if (newContent = content)
            return false  ; Failed to insert (section not found)
        tmpPath := gBlacklist_FilePath ".tmp"
        try FileDelete(tmpPath)  ; Clean stale tmp from prior crash
        FileAppend(newContent, tmpPath, "UTF-8")
        FileMove(tmpPath, gBlacklist_FilePath, 1)  ; 1 = overwrite
        return true
    } catch as e {
        LogAppend(LOG_PATH_STORE, "blacklist write error in _BL_AddToSection: " e.Message)
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
; Delegates to Blacklist_IsWindowEligibleEx (DRY — single source for eligibility + blacklist logic)
Blacklist_IsWindowEligible(hwnd, title := "", class := "") {
    Profiler.Enter("Blacklist_IsWindowEligible") ; @profile
    ; Get window info if not provided
    if (title = "" || class = "") {
        ; Skip hung windows - WinGetTitle/WinGetClass send messages that block up to 5s
        try {
            if (DllCall("user32\IsHungAppWindow", "ptr", hwnd, "int")) {
                Profiler.Leave() ; @profile
                return false
            }
        }
        try {
            if (title = "")
                title := WinGetTitle("ahk_id " hwnd)
            if (class = "")
                class := WinGetClass("ahk_id " hwnd)
        } catch {
            Profiler.Leave() ; @profile
            return false
        }
    }

    ; Delegate to Ex variant (vis/min/clk refs discarded — no extra cost since
    ; the same DllCalls happen either way via BL_ProbeVisMinCloak)
    vis := false, min := false, clk := false
    Profiler.Leave() ; @profile
    return Blacklist_IsWindowEligibleEx(hwnd, title, class, &vis, &min, &clk)
}

; Shared vis/min/cloak probe — single source for the DllCall trio
; Used by _BL_IsAltTabEligibleEx, Blacklist_IsWindowEligibleEx, and WinUtils_ProbeWindow
BL_ProbeVisMinCloak(hwnd, &outVis, &outMin, &outCloak) {
    global DWMWA_CLOAKED
    static cloakedBuf := Buffer(4, 0)
    outVis := DllCall("user32\IsWindowVisible", "ptr", hwnd, "int") != 0
    outMin := DllCall("user32\IsIconic", "ptr", hwnd, "int") != 0
    hr := DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", DWMWA_CLOAKED, "ptr", cloakedBuf.Ptr, "uint", 4, "int")
    outCloak := (hr = 0) && (NumGet(cloakedBuf, 0, "UInt") != 0)
}

; Extended Alt-Tab eligibility - returns vis/min/cloak via ByRef
; Used by Blacklist_IsWindowEligibleEx to avoid redundant DllCalls in WinUtils_ProbeWindow
_BL_IsAltTabEligibleEx(hwnd, &outVis, &outMin, &outCloak) {
    global BL_WS_CHILD, BL_WS_EX_TOOLWINDOW, BL_WS_EX_APPWINDOW, BL_WS_EX_NOACTIVATE
    global GWL_STYLE, GWL_EXSTYLE, GW_OWNER

    ; Get visibility state via shared helper
    BL_ProbeVisMinCloak(hwnd, &outVis, &outMin, &outCloak)

    ; Get regular window style
    style := DllCall("user32\GetWindowLongPtrW", "ptr", hwnd, "int", GWL_STYLE, "ptr")

    ; Child windows are never Alt-Tab eligible
    if (style & BL_WS_CHILD)
        return false

    ; Get extended window style
    ex := DllCall("user32\GetWindowLongPtrW", "ptr", hwnd, "int", GWL_EXSTYLE, "ptr")

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
    owner := DllCall("user32\GetWindow", "ptr", hwnd, "uint", GW_OWNER, "ptr")

    ; Owned windows need WS_EX_APPWINDOW to be eligible
    if (owner != 0 && !isApp)
        return false

    ; Must be visible, minimized, or cloaked
    if !(outVis || outMin || outCloak)
        return false

    return true
}

; Extended eligibility check - returns vis/min/cloak via ByRef when eligible
; Avoids redundant DllCalls when caller also needs these values (e.g., WinUtils_ProbeWindow)
Blacklist_IsWindowEligibleEx(hwnd, title, class, &outVis, &outMin, &outCloak) {
    global cfg

    ; Skip windows with no title
    if (title = "")
        return false

    ; Check Alt-Tab eligibility (use cached config value for hot path performance)
    global gCached_UseAltTabEligibility
    if (gCached_UseAltTabEligibility) {
        if (!_BL_IsAltTabEligibleEx(hwnd, &outVis, &outMin, &outCloak))
            return false
    } else {
        ; Fetch vis/min/cloak directly when eligibility check is skipped
        BL_ProbeVisMinCloak(hwnd, &outVis, &outMin, &outCloak)
    }

    ; Check blacklist (use cached config value for hot path performance)
    global gCached_UseBlacklist
    if (gCached_UseBlacklist && Blacklist_IsMatch(title, class))
        return false

    return true
}

; Pre-compile wildcard pattern to regex string (called during _Blacklist_Reload)
BL_CompileWildcard(pattern) {
    regex := "i)^" RegExReplace(RegExReplace(pattern, "[.+^${}|()\\[\]]", "\$0"), "\*", ".*")
    regex := RegExReplace(regex, "\?", ".")
    regex .= "$"
    return regex
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
