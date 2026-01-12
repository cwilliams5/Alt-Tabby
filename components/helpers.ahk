; ================== helpers.ahk ==================
; Utility helpers: dark mode, wildcard matching (with strong normalization),
; game bypass, activation (Komorebi-aware call-out), blacklist snippet tools, and debug logging.

; ---------- Debug toggles (optionally override in config.ahk) ----------
if !IsSet(DebugBlacklist)
    global DebugBlacklist := false
if !IsSet(DebugKomorebi)
    global DebugKomorebi := false
if !IsSet(DebugLogPath)
    global DebugLogPath := A_ScriptDir "\tabby_debug.log"

; ---------- Logging ----------
_Log(msg) {
    global DebugBlacklist, DebugKomorebi, DebugLogPath
    if !(DebugBlacklist || DebugKomorebi)
        return
    ts := A_YYYY . "-" . A_MM . "-" . A_DD . " " . A_Hour . ":" . A_Min . ":" . A_Sec . "." . SubStr(A_MSec "000", 1, 3)
    try FileAppend(ts . "  " . msg . "`r`n", DebugLogPath, "UTF-8")
}

_LogCodepoints(label, s) {
    if !IsSet(s)
        s := ""
    cp := ""
    Loop StrLen(s) {
        ch := SubStr(s, A_Index, 1)
        cp .= Format("{:04X} ", Ord(ch))  ; safe here; not embedded in a larger format string
    }
    _Log(label . " (len=" . StrLen(s) . "): " . cp)
}

; ---------- Dark mode ----------
EnableDarkMode(hWnd) {
  try {
    on := 1
    DllCall("dwmapi\DwmSetWindowAttribute","ptr",hWnd,"int",20,"ptr",&on,"int",4)
    DllCall("dwmapi\DwmSetWindowAttribute","ptr",hWnd,"int",38,"ptr",&on,"int",4)
  }
}

; ---------- Strong normalization for matching ----------
; - Map plus-like Unicode to ASCII '+'
; - Collapse CR/LF/TAB/NBSP to spaces
; - Remove spaces around '+'
; - Collapse multiple spaces
; - Trim
NormalizeMatchText(s) {
  if !IsSet(s) || (s = "")
    return ""
  ; FULLWIDTH PLUS (FF0B), SMALL PLUS (FE62), SUPERSCRIPT PLUS (207A)
  s := RegExReplace(s, "[\x{FF0B}\x{FE62}\x{207A}]", "+")
  s := RegExReplace(s, "[\r\n\t\xA0]+", " ")
  s := RegExReplace(s, "\s*\+\s*", "+")
  s := RegExReplace(s, " {2,}", " ")
  return Trim(s)
}

; ---------- Wildcards (AHK → regex) with normalization ----------
WildMatch(s, pat) {
  s   := NormalizeMatchText(s)
  pat := NormalizeMatchText(pat)
  ; Escape regex specials, then apply AHK wildcards
  pat := RegExReplace(pat, "([\\.^$+(){}\[\]|])", "\\$1")
  pat := StrReplace(pat, "?", ".")
  pat := StrReplace(pat, "*", ".*")
  return RegExMatch(s, "i)^(?:" . pat . ")$")
}

MatchAny(value, patterns) {
  if !IsSet(patterns) || patterns.Length = 0
    return false
  for _, p in patterns
    if (WildMatch(value, p))
      return true
  return false
}

; pairs = [ {Title:"...", Class:"..."}, ... ]
; Either key may be omitted in a pair. BOTH present keys must match.
MatchPairs(ttl, cls, pairs) {
  if !IsSet(pairs) || pairs.Length = 0
    return false
  for _, r in pairs {
    hasT := HasProp(r, "Title")
    hasC := HasProp(r, "Class")
    tOk := (!hasT) || WildMatch(ttl, r.Title)
    cOk := (!hasC) || WildMatch(cls, r.Class)
    if (tOk && cOk)
      return true
  }
  return false
}

; ---------- Fullscreen heuristic & game bypass ----------
IsFullscreenApprox(win := "A") {
  ; Guard against transient “no active window” / shell handoff states.
  local x := 0, y := 0, w := 0, h := 0
  try {
    if !WinExist(win)
      return false
    WinGetPos &x, &y, &w, &h, win
  } catch {
    ; If we can’t query, treat as not fullscreen (never block Alt+Tab).
    return false
  }
  return (w >= A_ScreenWidth*0.99 && h >= A_ScreenHeight*0.99 && x <= 5 && y <= 5)
}

ShouldBypassForGame() {
  global DisableInProcesses, DisableInFullscreen

  ; Fetch active exe name safely; on failure, just skip process match.
  exename := ""
  try {
    if WinExist("A")
      exename := WinGetProcessName("A")
  } catch as e {
    _Log("ShouldBypassForGame: WinGetProcessName failed: " . e.Message)
    ; Optional: surface when you’re already debugging blacklist/enum.
    if (IsSet(DebugBlacklist) && DebugBlacklist)
      _SoftToast("Bypass check skipped (no active window)")
  }

  if (exename != "") {
    lex := StrLower(exename)
    for _, nm in DisableInProcesses
      if (StrLower(nm) = lex)
        return true
  }

  if (DisableInFullscreen && IsFullscreenApprox("A"))
    return true

  return false
}


; ---------- Activation (Komorebi-aware) ----------
; NOTE: Komorebi_FocusHwnd() is implemented in komorebi.ahk. This function just calls it.
; ---------- Activation (Komorebi-aware) ----------
; ---------- Activation (Komorebi-aware) ----------
; --- helpers.ahk ---
; --- helpers.ahk ---
ActivateHwnd(hwnd, state := "") {
  try _KLog("ActivateHwnd: hwnd=" . hwnd . " state=" . state)
  if !hwnd
    return false

  if (state = "OtherWorkspace") {
    if (IsSet(NoBlocking) && NoBlocking) {
      _KLog("ActivateHwnd: skipped (NoBlocking) for OtherWorkspace")
      return false
    }
    SetTimer(() => __ALTAB_FocusOtherWorkspaceAsync(hwnd), -1) ; run once, ASAP
    return false
  }

  if !WinExist("ahk_id " hwnd)
    return false

  stateMM := WinGetMinMax("ahk_id " hwnd)
  if (stateMM = -1)
    DllCall("user32\ShowWindow", "ptr", hwnd, "int", 9)  ; SW_RESTORE

  WinActivate "ahk_id " hwnd
  Sleep 0
  return WinActive("ahk_id " hwnd)
}


__ALTAB_FocusOtherWorkspaceAsync(hwnd) {
  ; This runs off-thread (timer), so any slower CLI calls can’t stall Alt-Tab.
  try {
    ok := Komorebi_FocusHwnd(hwnd)   ; may call RunWait internally
    _KLog("Async focus result=" . (ok ? "ok" : "fail"))
  } catch as e {
    _KLog("Async focus error: " . e.Message)
  }
}



; ---------- (NEW) tiny optional toast for debug-only surfacing ----------
_SoftToast(msg, ms := 900) {
  try {
    ToolTip msg
    SetTimer(() => ToolTip(), -Abs(ms))
  }
}



; Keep this here so komorebi.ahk can use it for CLI attempts.
RunTry(cmdLine) {
  try {
    return RunWait(cmdLine, , "Hide")
  } catch {
    return 1
  }
}

; ---------- Blacklist snippet builder (Alt+B) ----------
EscapeAhkStr(s) {
  q := Chr(34)                 ; double-quote
  return StrReplace(s, q, q q) ; double the quotes
}

BuildBlacklistSnippet(item) {
  ; Raw
  rawT := item.Title, rawC := item.Class
  ; Exact (escaped)
  t := EscapeAhkStr(rawT)
  c := EscapeAhkStr(rawC)
  ; Tolerant (normalize spaces around '+'), then escape
  tTol := EscapeAhkStr(RegExReplace(rawT, "\s*\+\s*", "+"))
  cTol := EscapeAhkStr(RegExReplace(rawC, "\s*\+\s*", "+"))

  ; CHAT GPT HEY YOU. OR ANY AI
  ; YOU ARE VERY BAD AT THESE PARSING STRINGS IN AHKv2
  ; MAKE SURE YOU ARENT CHANGING THEM UNLESS YOU ABSOLUTELY NEED TO
  ; DON'T REMOVE OR CHANGE THIS WARNING
  txt := ';; --- Copy any of these into config.ahk ---`r`n'
  txt .= ';; Title-only (exact):`r`n'
  txt .= 'BlacklistTitle.Push("' . t . '")`r`n`r`n'
  txt .= ';; Class-only (exact):`r`n'
  txt .= 'BlacklistClass.Push("' . c . '")`r`n`r`n'
  txt .= ';; Class+Title (exact):`r`n'
  txt .= 'BlacklistPair.Push({ Class: "' . c . '", Title: "' . t . '" })`r`n`r`n'
  txt .= ';; Class+Title (tolerant of spaces around +):`r`n'
  txt .= 'BlacklistPair.Push({ Class: "' . cTol . '", Title: "' . tTol . '" })`r`n'
  return txt
}

ShowBlacklistSuggestion(item) {
  txt := BuildBlacklistSnippet(item)
  A_Clipboard := txt
  MsgBox txt, "Blacklist snippet (copied to clipboard)", "64"
}

; ---------- Debug helpers to trace blacklist decisions ----------
_DebugDumpBlacklistDecision(ttl, cls) {
    ; Only spam logs for likely offenders; tweak as needed.
    if !(InStr(ttl, "OneDrive") || InStr(cls, "OneDrive") || InStr(ttl, "GDI") || InStr(cls, "GDI"))
        return
    _Log("----- BLACKLIST TRACE -----")
    _Log("RAW Title: " . ttl)
    _Log("RAW Class: " . cls)
    _LogCodepoints("Title codepoints", ttl)
    _LogCodepoints("Class codepoints", cls)

    nt := NormalizeMatchText(ttl), nc := NormalizeMatchText(cls)
    _Log("NORM Title: " . nt)
    _Log("NORM Class: " . nc)

    global BlacklistTitle, BlacklistClass, BlacklistPair

    ; Title rules
    if IsSet(BlacklistTitle) {
        for i, p in BlacklistTitle {
            res := WildMatch(ttl, p) ? "MATCH" : "no"
            _Log("TitleRule[" . i . "]: '" . p . "' -> " . res)
        }
    }

    ; Class rules
    if IsSet(BlacklistClass) {
        for i, p in BlacklistClass {
            res := WildMatch(cls, p) ? "MATCH" : "no"
            _Log("ClassRule[" . i . "]: '" . p . "' -> " . res)
        }
    }

    ; Pair rules
    if IsSet(BlacklistPair) && BlacklistPair.Length {
        for i, r in BlacklistPair {
            hasT := HasProp(r, "Title")
            hasC := HasProp(r, "Class")
            tRes := hasT ? (WildMatch(ttl, r.Title) ? "T=match" : "T=no") : "T=skip"
            cRes := hasC ? (WildMatch(cls, r.Class) ? "C=match" : "C=no")  : "C=skip"
            msg := "Pair[" . i . "]: " . tRes . " " . Chr(59) . " " . cRes
            _Log(msg)
        }
    }

    _Log("---------------------------")
}
