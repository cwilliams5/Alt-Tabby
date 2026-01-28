#Requires AutoHotkey v2.0

; ============================================================
; Komorebi JSON Extraction Helpers
; ============================================================
; Pure JSON extraction utilities with no komorebi-specific logic.
; These are used by komorebi_state.ahk and komorebi_sub.ahk.
;
; Functions:
;   _KSub_ExtractObjectByKey   - Extract balanced {...} for a key
;   _KSub_ExtractArrayByKey    - Extract balanced [...] for a key
;   _KSub_ExtractContentRaw    - Extract event "content" (array/string/int/object)
;   _KSub_BalancedObjectFrom   - Get balanced object from position
;   _KSub_BalancedArrayFrom    - Get balanced array from position
;   _KSub_GetStringProp        - Get string property value
;   _KSub_GetIntProp           - Get integer property value
;   _KSub_GetRingFocused       - Get top-level "focused" from Ring object
;   _KSub_UnescapeJson         - Unescape JSON string
;   _KSub_ArrayTopLevelSplit   - Split array into top-level elements
;   _KSub_IsQuoteEscaped       - Check if quote at position is escaped
; ============================================================

; Check if a quote character at position `pos` is escaped by counting
; consecutive backslashes before it. Even count = not escaped, odd = escaped.
; Handles edge cases like `\\"` (escaped backslash before unescaped quote).
_KSub_IsQuoteEscaped(text, pos) {
    if (pos <= 1)
        return false
    backslashCount := 0
    checkPos := pos - 1
    while (checkPos >= 1 && SubStr(text, checkPos, 1) = "\") {
        backslashCount += 1
        checkPos -= 1
    }
    ; Odd number of backslashes = quote is escaped
    ; Even number (including 0) = quote is NOT escaped
    return (Mod(backslashCount, 2) = 1)
}

_KSub_ExtractObjectByKey(text, key) {
    ; Returns the balanced {...} value for "key": { ... }
    pat := '(?s)"' key '"\s*:\s*\{'
    m := 0
    if !RegExMatch(text, pat, &m)
        return ""
    start := m.Pos(0) + m.Len(0) - 1  ; at '{'
    return _KSub_BalancedObjectFrom(text, start)
}

; Extract "content" field from event - tries array, string, number, then object
; Based on POC's _GetEventContentRaw which handles all komorebi content formats
_KSub_ExtractContentRaw(evtText) {
    ; Try array first: "content": [...]
    arr := _KSub_ExtractArrayByKey(evtText, "content")
    if (arr != "") {
        _KSub_DiagLog("    ExtractContent: found array")
        return arr
    }

    ; Try quoted string: "content": "value"
    m := 0
    if RegExMatch(evtText, '(?s)"content"\s*:\s*"((?:\\.|[^"])*)"', &m) {
        _KSub_DiagLog("    ExtractContent: found string")
        return m[1]  ; Return unquoted for consistency
    }

    ; Try integer: "content": 123
    m := 0
    if RegExMatch(evtText, '(?s)"content"\s*:\s*(-?\d+)', &m) {
        _KSub_DiagLog("    ExtractContent: found integer=" m[1])
        return m[1]
    }

    ; Try object: "content": {...}
    ; This handles SocketMessage format where content is {EventType: value}
    obj := _KSub_ExtractObjectByKey(evtText, "content")
    if (obj != "") {
        _KSub_DiagLog("    ExtractContent: found object, extracting value")
        ; Try to extract the workspace index from within the object
        ; e.g., {"MoveContainerToWorkspaceNumber": 1} -> extract 1
        m := 0
        ; Look for any numeric value in the object
        if RegExMatch(obj, ':\s*(-?\d+)', &m)
            return m[1]
        ; Look for any string value
        if RegExMatch(obj, ':\s*"([^"]*)"', &m)
            return m[1]
        ; Return the whole object as fallback
        return obj
    }

    _KSub_DiagLog("    ExtractContent: no content found")
    return ""
}

_KSub_ExtractArrayByKey(text, key) {
    pat := '(?s)"' key '"\s*:\s*\['
    m := 0
    if !RegExMatch(text, pat, &m)
        return ""
    start := m.Pos(0) + m.Len(0) - 1  ; at '['
    return _KSub_BalancedArrayFrom(text, start)
}

_KSub_BalancedObjectFrom(text, bracePos) {
    ; bracePos points to '{'
    i := bracePos
    depth := 0
    inString := false
    len := StrLen(text)

    while (i <= len) {
        ch := SubStr(text, i, 1)
        if (!inString) {
            if (ch = '"') {
                inString := true
            } else if (ch = "{") {
                depth += 1
            } else if (ch = "}") {
                depth -= 1
                if (depth = 0)
                    return SubStr(text, bracePos, i - bracePos + 1)
            }
        } else {
            if (ch = '"' && !_KSub_IsQuoteEscaped(text, i))
                inString := false
        }
        i += 1
    }
    return ""
}

_KSub_BalancedArrayFrom(text, brackPos) {
    ; brackPos points to '['
    i := brackPos
    depth := 0
    inString := false
    len := StrLen(text)

    while (i <= len) {
        ch := SubStr(text, i, 1)
        if (!inString) {
            if (ch = '"') {
                inString := true
            } else if (ch = "[") {
                depth += 1
            } else if (ch = "]") {
                depth -= 1
                if (depth = 0)
                    return SubStr(text, brackPos, i - brackPos + 1)
            }
        } else {
            if (ch = '"' && !_KSub_IsQuoteEscaped(text, i))
                inString := false
        }
        i += 1
    }
    return ""
}

_KSub_GetStringProp(objText, key) {
    m := 0
    if RegExMatch(objText, '(?s)"' key '"\s*:\s*"((?:\\.|[^"])*)"', &m)
        return _KSub_UnescapeJson(m[1])
    return ""
}

_KSub_GetIntProp(objText, key) {
    m := 0
    if RegExMatch(objText, '(?s)"' key '"\s*:\s*(-?\d+)', &m)
        return Integer(m[1])
    return ""
}

; Get the "focused" index from a Ring object (monitors, workspaces, containers, windows).
; Ring JSON is: { "elements": [...nested objects with their own "focused"...], "focused": N }
; _KSub_GetIntProp finds the FIRST "focused" which is a nested one inside "elements".
; The ring's own "focused" is always the LAST one (after the "elements" array), so we
; search only the tail of the string for speed — avoids scanning the entire elements array.
_KSub_GetRingFocused(ringText) {
    ; Fast path: Ring's "focused" is the LAST one near the end, after "elements": [...]
    ; The tail may still contain nested "focused" from the last workspace's containers,
    ; so use greedy .* to find the LAST occurrence. On 200 chars this is essentially free.
    m := 0
    tail := SubStr(ringText, -200)
    if RegExMatch(tail, '(?s).*"focused"\s*:\s*(-?\d+)', &m)
        return Integer(m[1])
    ; Fallback: search full text with greedy match
    if RegExMatch(ringText, '(?s).*"focused"\s*:\s*(-?\d+)', &m)
        return Integer(m[1])
    return ""
}

_KSub_UnescapeJson(s) {
    s := StrReplace(s, '\"', '"')
    s := StrReplace(s, '\\', '\')
    s := StrReplace(s, '\/', '/')
    s := StrReplace(s, '\n', "`n")
    s := StrReplace(s, '\r', "`r")
    s := StrReplace(s, '\t', "`t")
    return s
}

; Split array into top-level elements
_KSub_ArrayTopLevelSplit(arrayText) {
    res := []
    if (arrayText = "")
        return res
    if (SubStr(arrayText, 1, 1) = "[")
        arrayText := SubStr(arrayText, 2)
    if (SubStr(arrayText, -1) = "]")
        arrayText := SubStr(arrayText, 1, -1)

    i := 1
    depthObj := 0
    depthArr := 0
    inString := false
    start := 1
    len := StrLen(arrayText)

    while (i <= len) {
        ch := SubStr(arrayText, i, 1)
        if (!inString) {
            if (ch = '"') {
                inString := true
            } else if (ch = "{") {
                depthObj += 1
            } else if (ch = "}") {
                depthObj -= 1
            } else if (ch = "[") {
                depthArr += 1
            } else if (ch = "]") {
                depthArr -= 1
            } else if (ch = "," && depthObj = 0 && depthArr = 0) {
                piece := Trim(SubStr(arrayText, start, i - start))
                if (piece != "")
                    res.Push(piece)
                start := i + 1
            }
        } else {
            if (ch = '"' && !_KSub_IsQuoteEscaped(arrayText, i))
                inString := false
        }
        i += 1
    }
    last := Trim(SubStr(arrayText, start))
    if (last != "")
        res.Push(last)
    return res
}
