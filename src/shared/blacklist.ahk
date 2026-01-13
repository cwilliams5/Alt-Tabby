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
        ; Default: blacklist.txt next to this script (in shared/)
        gBlacklist_FilePath := A_ScriptDir "\shared\blacklist.txt"
        if (!FileExist(gBlacklist_FilePath)) {
            ; Try relative to script directory for store_server
            gBlacklist_FilePath := A_ScriptDir "\..\shared\blacklist.txt"
        }
        if (!FileExist(gBlacklist_FilePath)) {
            ; Fallback to same directory
            gBlacklist_FilePath := A_ScriptDir "\blacklist.txt"
        }
    } else {
        gBlacklist_FilePath := filePath
    }

    return Blacklist_Reload()
}

; Reload blacklist from file
Blacklist_Reload() {
    global gBlacklist_Titles, gBlacklist_Classes, gBlacklist_Pairs
    global gBlacklist_FilePath, gBlacklist_Loaded

    gBlacklist_Titles := []
    gBlacklist_Classes := []
    gBlacklist_Pairs := []

    if (!FileExist(gBlacklist_FilePath)) {
        gBlacklist_Loaded := false
        return false
    }

    try {
        content := FileRead(gBlacklist_FilePath, "UTF-8")
    } catch {
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

        ; Add to appropriate list based on current section
        if (currentSection = "Title") {
            gBlacklist_Titles.Push(line)
        } else if (currentSection = "Class") {
            gBlacklist_Classes.Push(line)
        } else if (currentSection = "Pair") {
            ; Parse Class|Title format
            parts := StrSplit(line, "|")
            if (parts.Length >= 2) {
                gBlacklist_Pairs.Push({ Class: parts[1], Title: parts[2] })
            }
        }
    }

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

; Add a new pair entry to the blacklist file
Blacklist_AddPair(class, title) {
    global gBlacklist_FilePath

    if (gBlacklist_FilePath = "")
        return false

    ; Format: Class|Title
    entry := class "|" title "`n"

    try {
        ; Append to [Pair] section at end of file
        FileAppend(entry, gBlacklist_FilePath, "UTF-8")
        return true
    } catch {
        return false
    }
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
