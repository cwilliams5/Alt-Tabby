#Requires AutoHotkey v2.0

; Minimal JSON encode/decode (JXON-style) for AHK v2.
; Reference: https://github.com/cocobelgica/AutoHotkey-JSON (adapted for v2).

JXON_Load(src) {
    static q := Chr(34)
    pos := 1
    return JXON__ReadValue(src, &pos)
}

JXON_Dump(obj, indent := "") {
    return JXON__DumpValue(obj, indent, 1)
}

JXON__ReadValue(src, &pos) {
    JXON__SkipWS(src, &pos)
    if (pos > StrLen(src)) {
        return ""
    }
    ch := SubStr(src, pos, 1)
    if (ch = "{") {
        return JXON__ReadObject(src, &pos)
    }
    if (ch = "[") {
        return JXON__ReadArray(src, &pos)
    }
    if (ch = Chr(34)) {
        return JXON__ReadString(src, &pos)
    }
    if (RegExMatch(SubStr(src, pos), "^(true|false|null)", &m)) {
        pos += StrLen(m[1])
        if (m[1] = "true") {
            return true
        }
        if (m[1] = "false") {
            return false
        }
        return ""
    }
    return JXON__ReadNumber(src, &pos)
}

JXON__ReadObject(src, &pos) {
    obj := Map()
    pos += 1
    JXON__SkipWS(src, &pos)
    if (SubStr(src, pos, 1) = "}") {
        pos += 1
        return obj
    }
    loop {
        key := JXON__ReadString(src, &pos)
        JXON__SkipWS(src, &pos)
        pos += 1 ; :
        val := JXON__ReadValue(src, &pos)
        obj[key] := val
        JXON__SkipWS(src, &pos)
        ch := SubStr(src, pos, 1)
        if (ch = "}") {
            pos += 1
            break
        }
        pos += 1 ; ,
    }
    return obj
}

JXON__ReadArray(src, &pos) {
    arr := []
    pos += 1
    JXON__SkipWS(src, &pos)
    if (SubStr(src, pos, 1) = "]") {
        pos += 1
        return arr
    }
    loop {
        arr.Push(JXON__ReadValue(src, &pos))
        JXON__SkipWS(src, &pos)
        ch := SubStr(src, pos, 1)
        if (ch = "]") {
            pos += 1
            break
        }
        pos += 1 ; ,
    }
    return arr
}

JXON__ReadString(src, &pos) {
    pos += 1
    out := ""
    len := StrLen(src)
    while (pos <= len) {
        ch := SubStr(src, pos, 1)
        if (ch = Chr(34)) {
            pos += 1
            break
        }
        if (ch = Chr(92)) {
            pos += 1
            esc := SubStr(src, pos, 1)
            if (esc = "n") {
                out .= "`n"
            } else if (esc = "r") {
                out .= "`r"
            } else if (esc = "t") {
                out .= "`t"
            } else if (esc = Chr(92)) {
                out .= Chr(92)
            } else if (esc = Chr(34)) {
                out .= Chr(34)
            } else if (esc = "/") {
                out .= "/"
            } else if (esc = "b") {
                out .= Chr(8)
            } else if (esc = "f") {
                out .= Chr(12)
            } else if (esc = "u") {
                hex := SubStr(src, pos + 1, 4)
                out .= Chr("0x" hex)
                pos += 4
            } else {
                out .= esc
            }
        } else {
            out .= ch
        }
        pos += 1
    }
    return out
}

JXON__ReadNumber(src, &pos) {
    if (RegExMatch(SubStr(src, pos), "^-?\d+(\.\d+)?([eE][+-]?\d+)?", &m)) {
        pos += StrLen(m[0])
        return m[0] + 0
    }
    return ""
}

JXON__SkipWS(src, &pos) {
    while (pos <= StrLen(src)) {
        ch := SubStr(src, pos, 1)
        if (ch != " " && ch != "`n" && ch != "`r" && ch != "`t") {
            break
        }
        pos += 1
    }
}

JXON__DumpValue(val, indent, level) {
    if IsObject(val) {
        if (val is Array)
            return JXON__DumpArray(val, indent, level)
        return JXON__DumpObject(val, indent, level)
    }
    if (val is Number)
        return val
    if (val == true)
        return "true"
    if (val == false)
        return "false"
    if (val == "")
        return "null"
    return JXON__EscapeString(val)
}

JXON__DumpObject(obj, indent, level) {
    try {
        hasAny := false
        enum := (obj is Map) ? obj : obj.OwnProps()
        for _, _ in enum {
            hasAny := true
            break
        }
        if (!hasAny)
            return "{}"
    } catch {
        return "{}"
    }
    pad := indent ? "`n" . JXON__Repeat(indent, level) : ""
    padInner := indent ? "`n" . JXON__Repeat(indent, level + 1) : ""
    out := "{"
    first := true
    enum := (obj is Map) ? obj : obj.OwnProps()
    for k, v in enum {
        if (!first)
            out .= ","
        out .= padInner . JXON__EscapeString(k) . ":" . (indent ? " " : "") . JXON__DumpValue(v, indent, level + 1)
        first := false
    }
    out .= pad . "}"
    return out
}

JXON__DumpArray(arr, indent, level) {
    if (arr.Length = 0)
        return "[]"
    pad := indent ? "`n" . JXON__Repeat(indent, level) : ""
    padInner := indent ? "`n" . JXON__Repeat(indent, level + 1) : ""
    out := "["
    first := true
    for _, v in arr {
        if (!first)
            out .= ","
        out .= padInner . JXON__DumpValue(v, indent, level + 1)
        first := false
    }
    out .= pad . "]"
    return out
}

JXON__EscapeString(str) {
    static q := Chr(34)
    str := StrReplace(str, Chr(92), "\\")
    str := StrReplace(str, q, Chr(92) . Chr(34))
    str := StrReplace(str, "`r", "\r")
    str := StrReplace(str, "`n", "\n")
    str := StrReplace(str, "`t", "\t")
    return q . str . q
}

JXON__Repeat(s, n) {
    out := ""
    Loop n
        out .= s
    return out
}
