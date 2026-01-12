#Requires AutoHotkey v2.0
; ---------------------------------------------------------------------------
; komorebi POC subscriber (AHK v2) — logs workspace changes, window moves/sends,
; and focus changes (HWND->workspace) with names and indices.
; ---------------------------------------------------------------------------

#Warn
#SingleInstance Force
SetWorkingDir A_ScriptDir

; --- Globals (declared; most are initialized in Main) ---
global KomorebicExe := "C:\Program Files\komorebi\bin\komorebic.exe"
global LogPath      := A_ScriptDir . "\komorebi_poc.log"
global ReadChunk    := 32768

; defer PipeName until after we know the script is running
global PipeName     := ""          ; will be set in Main()
global gPipe        := 0
global gConnected   := false
global gClientPid   := 0
global gLastWsName  := ""
global gLastWsIdx   := -1
global gLastMonIdx  := -1
global gOut := 0
global gBuf := ""

OnExit(Cleanup)
Main()
return


Main() {
    global PipeName, KomorebicExe, LogPath

    ; build PipeName once we’re actually running (avoids A_Pid #Warn noise)
    if (!PipeName) {
        pid := ProcessExist()  ; current script pid
        PipeName := "tabby_poc_" . A_TickCount . "_" . pid
    }

    Log("=== komorebi-poc starting ===")
    Log("KomorebicExe = " . KomorebicExe)
    Log("PipeName     = " . PipeName)
    Log("Log file     = " . LogPath)

    if !FileExist(KomorebicExe) {
        Log("ERROR: komorebic not found: " . KomorebicExe)
        ExitApp
    }

    CreatePipe()
    TrySpawnClient()
    WaitForClient()

    ; AHK v2: pass a callable (lambda) for the timer
    SetTimer(() => Tick(), 50)
}


CreatePipe() {
    global PipeName, gPipe, KomorebicExe

    local name := "\\.\pipe\" . PipeName
    ; PIPE_ACCESS_INBOUND (server reads), byte/byte/wait, instances=1
    gPipe := DllCall("CreateNamedPipe"
        , "Str",  name
        , "UInt", 0x00000001           ; PIPE_ACCESS_INBOUND
        , "UInt", 0x00000000           ; PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT
        , "UInt", 1
        , "UInt", 65536, "UInt", 65536
        , "UInt", 0
        , "Ptr",  0
        , "Ptr")

    if (gPipe = 0 || gPipe = -1) {
        gle := A_LastError
        Log("ERROR: CreateNamedPipe failed (GLE=" . gle . ")")
        ExitApp
    }
    Log("Pipe created. Waiting for client to connect …")
    Log("You can also run manually: " . KomorebicExe . " subscribe-pipe " . PipeName)
}


; ---------- PIPE LIFECYCLE ----------
CreatePipeServer(name) {
    global gPipe
    local path := "\\.\pipe\" . name
    ; PIPE_ACCESS_INBOUND(0x00000001), PIPE_TYPE_BYTE(0x0), PIPE_READMODE_BYTE(0x0), PIPE_WAIT(0x0)
    gPipe := DllCall("CreateNamedPipe"
        , "Str", path
        , "UInt", 0x00000001            ; dwOpenMode
        , "UInt", 0x00000000            ; dwPipeMode
        , "UInt", 1                     ; nMaxInstances
        , "UInt", 0                     ; nOutBufferSize
        , "UInt", 64*1024               ; nInBufferSize
        , "UInt", 0                     ; nDefaultTimeOut
        , "Ptr",  0                     ; lpSecurityAttributes
        , "Ptr")
    return gPipe != 0
}

WaitForClient() {
    global gPipe, gConnected

    local ok := DllCall("ConnectNamedPipe", "Ptr", gPipe, "Ptr", 0, "Int")
    if (!ok) {
        gle := A_LastError
        if (gle = 535) {  ; ERROR_PIPE_CONNECTED
            gConnected := true
            Log("Client connected (already).")
            return
        }
        Log("ERROR: ConnectNamedPipe failed (GLE=" . gle . ")")
        ExitApp
    }
    gConnected := true
    Log("Client connected.")
}


TrySpawnClient() {
    global gClientPid, KomorebicExe, PipeName
    try {
        cmd := '"' . KomorebicExe . '" subscribe-pipe ' . PipeName
        local pid := 0
        Run(cmd, , "Hide", &pid)   ; v2: 4th param returns PID
        gClientPid := pid
        Log("Spawned subscriber: pid=" . gClientPid . " -> " . cmd)
    } catch as e {
        Log("WARN: failed to spawn client: " . e.Message)
        Log("Start it manually in a terminal:")
        Log("  " . KomorebicExe . " subscribe-pipe " . PipeName)
    }
}



Cleanup(reason := "", code := 0) {
    global gPipe, gConnected
    try {
        Log("=== komorebi-poc exiting (" . (reason != "" ? reason : "Normal") . ") ===")

        if (gConnected && gPipe)
            DllCall("FlushFileBuffers", "Ptr", gPipe)

        if (gPipe) {
            DllCall("DisconnectNamedPipe", "Ptr", gPipe)
            DllCall("CloseHandle", "Ptr", gPipe)
            gPipe := 0
        }
    } catch as e {
        ; ignore shutdown errors
    }
}



GetLastError() => DllCall("GetLastError")

; ---------- LOGGING ----------
Log(msg) {
    global LogPath
    ts := FormatTime(, "yyyy-MM-dd HH:mm:ss.fff")
    FileAppend(ts . "  " . msg . "`r`n", LogPath, "UTF-8")
}


; ---------- TIMER: PUMP PIPE ----------
Tick() {
    PumpPipe()
}

PumpPipe() {
    global gPipe, ReadChunk, gBuf

    if (!gPipe)
        return

    ; Non-blocking peek
    local bytesRead := 0, totalAvail := 0, leftMsg := 0
    ok := DllCall("PeekNamedPipe", "Ptr", gPipe, "Ptr", 0, "UInt", 0, "UInt*", &bytesRead, "UInt*", &totalAvail, "UInt*", &leftMsg, "Int")
    if (!ok) {
        Log("PeekNamedPipe failed: GLE=" . GetLastError())
        return
    }
    if (totalAvail = 0)
        return

    ; Read a bounded chunk
    local toRead := (totalAvail > ReadChunk) ? ReadChunk : totalAvail
    buf := Buffer(toRead, 0)
    local got := 0
    ok := DllCall("ReadFile", "Ptr", gPipe, "Ptr", buf, "UInt", toRead, "UInt*", &got, "Ptr", 0, "Int")
    if (!ok) {
        Log("ReadFile failed: GLE=" . GetLastError())
        return
    }
    if (got > 0) {
        piece := StrGet(buf.Ptr, got, "UTF-8")
        gBuf .= piece
    }

    ; Extract complete JSON objects
    while true {
        json := _ExtractOneJsonFromBuffer(&gBuf)
        if (json = "")
            break
        HandleNotification(json)
    }
}


; ---------- JSON-ish HELPERS (balanced scans, minimal decoding) ----------
_ExtractOneJsonFromBuffer(&s) {
    if (s = "")
        return ""

    ; find first '{'
    local start := InStr(s, "{")
    if (!start) {
        ; no object start; keep buffer bounded
        if (StrLen(s) > 1000000)
            s := ""
        return ""
    }

    ; scan for matching closing '}' at depth 0, skipping strings
    local i := start, depth := 0, inString := false
    while (i <= StrLen(s)) {
        ch := SubStr(s, i, 1)
        if (!inString) {
            if (ch = '"') {
                inString := true
            } else if (ch = "{") {
                depth += 1
            } else if (ch = "}") {
                depth -= 1
                if (depth = 0) {
                    obj := SubStr(s, start, i - start + 1)
                    s := SubStr(s, i + 1)
                    return obj
                }
            }
        } else {
            if (ch = '"' && SubStr(s, i - 1, 1) != "\")
                inString := false
        }
        i += 1
    }
    ; incomplete, wait for more data
    return ""
}

_Json_ExtractObjectByKey(text, key) {
    ; returns the balanced {...} value for "key": { ... }
    pat := '(?s)"' . key . '"\s*:\s*\{'
    m := 0
    if !RegExMatch(text, pat, &m)
        return ""
    start := m.Pos(0) + m.Len(0) - 1  ; at '{'
    return _BalancedObjectFrom(text, start)
}

_Json_ExtractArrayByKey(text, key) {
    pat := '(?s)"' . key . '"\s*:\s*\['
    m := 0
    if !RegExMatch(text, pat, &m)
        return ""
    start := m.Pos(0) + m.Len(0) - 1 ; at '['
    return _BalancedArrayFrom(text, start)
}

_BalancedObjectFrom(text, bracePos) {
    ; bracePos points to '{'
    local i := bracePos, depth := 0, inString := false
    while (i <= StrLen(text)) {
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
            if (ch = '"' && SubStr(text, i - 1, 1) != "\")
                inString := false
        }
        i += 1
    }
    return ""
}

_BalancedArrayFrom(text, brackPos) {
    ; brackPos points to '['
    local i := brackPos, depth := 0, inString := false
    while (i <= StrLen(text)) {
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
            if (ch = '"' && SubStr(text, i - 1, 1) != "\")
                inString := false
        }
        i += 1
    }
    return ""
}

_ArrayTopLevelSplit(arrayText) {
    ; Input: string like [ {...}, {...}, ... ]
    ; Output: array of element strings (without commas), preserving braces
    res := []
    if (arrayText = "")
        return res
    if (SubStr(arrayText, 1, 1) = "[")
        arrayText := SubStr(arrayText, 2)
    if (SubStr(arrayText, -1) = "]")
        arrayText := SubStr(arrayText, 1, -1)

    local i := 1, depthObj := 0, depthArr := 0, inString := false, start := 1
    while (i <= StrLen(arrayText)) {
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
            if (ch = '"' && SubStr(arrayText, i - 1, 1) != "\")
                inString := false
        }
        i += 1
    }
    last := Trim(SubStr(arrayText, start))
    if (last != "")
        res.Push(last)
    return res
}

_Json_GetStringProp(objText, key) {
    m := 0
    if RegExMatch(objText, '(?s)"' . key . '"\s*:\s*"((?:\\.|[^"])*)"', &m)
        return _UnescapeJson(m[1])
    return ""
}
_Json_GetIntProp(objText, key) {
    m := 0
    if RegExMatch(objText, '(?s)"' . key . '"\s*:\s*(-?\d+)', &m)
        return Integer(m[1])
    return ""
}
_UnescapeJson(s) {
    ; minimal unescape for quotes and backslashes + common escapes
    s := StrReplace(s, '\"', '"')
    s := StrReplace(s, '\\', '\')
    s := StrReplace(s, '\/', '/')
    s := StrReplace(s, '\b', Chr(8))
    s := StrReplace(s, '\f', Chr(12))
    s := StrReplace(s, '\n', "`n")
    s := StrReplace(s, '\r', "`r")
    s := StrReplace(s, '\t', "`t")
    return s
}

; ---------- EVENT PARSING ----------
_GetEventType(evtText) {
    m := 0
    if RegExMatch(evtText, '(?s)"type"\s*:\s*"([^"]+)"', &m)
        return m[1]
    return ""
}

_GetEventContentRaw(evtText) {
    ; returns: "", number string, quoted string, [array], {object}
    ; We only need array/int/string types for our use-cases.
    ; Try array first
    arr := _Json_ExtractArrayByKey(evtText, "content")
    if (arr != "")
        return arr
    ; Try quoted string
    m := 0
    if RegExMatch(evtText, '(?s)"content"\s*:\s*"((?:\\.|[^"])*)"', &m)
        return '"' . m[1] . '"'
    ; Integer
    if RegExMatch(evtText, '(?s)"content"\s*:\s*(-?\d+)', &m)
        return m[1]
    ; Object
    obj := _Json_ExtractObjectByKey(evtText, "content")
    if (obj != "")
        return obj
    return ""
}

_ParseContentToArray(contentRaw) {
    ; Normalize content to an Array of positional args:
    ; - "[1,2]" => [1,2]
    ; - "123"   => [123]
    ; - "\"Name\"" => ["Name"]
    ; - "{...}" => ["{...}"] (used by FocusChange second param object)
    args := []
    if (contentRaw = "")
        return args
    if (SubStr(contentRaw, 1, 1) = "[") {
        list := _ArrayTopLevelSplit(contentRaw)
        for each, it in list {
            it := Trim(it)
            if (SubStr(it, 1, 1) = '"') {
                args.Push(_UnescapeJson(SubStr(it, 2, -1)))
            } else if RegExMatch(it, '^-?\d+$') {
                args.Push(Integer(it))
            } else {
                args.Push(it) ; raw (object etc)
            }
        }
        return args
    }
    if (SubStr(contentRaw, 1, 1) = '"') {
        args.Push(_UnescapeJson(SubStr(contentRaw, 2, -1)))
        return args
    }
    if RegExMatch(contentRaw, '^-?\d+$') {
        args.Push(Integer(contentRaw))
        return args
    }
    args.Push(contentRaw)
    return args
}

; ---------- STATE HELPERS ----------
; Return monitors ring object + array of monitor objects + focused monitor idx
_State_GetMonitorsRing(stateText) {
    ring := _Json_ExtractObjectByKey(stateText, "monitors")
    return ring
}

_State_GetMonitorsArray(stateText) {
    ring := _State_GetMonitorsRing(stateText)
    elems := _Json_ExtractArrayByKey(ring, "elements")
    return _ArrayTopLevelSplit(elems)
}

_State_GetFocusedMonitorIndex(stateText) {
    ring := _State_GetMonitorsRing(stateText)
    return _Json_GetIntProp(ring, "focused")
}

_State_GetWorkspaceRingForMonitor(monObjText) {
    return _Json_ExtractObjectByKey(monObjText, "workspaces")
}

_State_GetWorkspaceArrayForMonitor(monObjText) {
    wsRing := _State_GetWorkspaceRingForMonitor(monObjText)
    wsArr := _Json_ExtractArrayByKey(wsRing, "elements")
    return _ArrayTopLevelSplit(wsArr)
}

_State_GetFocusedWorkspaceIndexForMonitor(monObjText) {
    wsRing := _State_GetWorkspaceRingForMonitor(monObjText)
    return _Json_GetIntProp(wsRing, "focused")
}

_State_GetWorkspaceName(stateText, monIdx, wsIdx) {
    ; komorebi uses 0-based indices; AHK arrays are 1-based.
    mons := _State_GetMonitorsArray(stateText)
    if (monIdx < 0 || monIdx >= mons.Length)
        return ""
    monObj := mons[monIdx + 1]

    wsArr := _State_GetWorkspaceArrayForMonitor(monObj)
    if (wsIdx < 0 || wsIdx >= wsArr.Length)
        return ""
    wsObj := wsArr[wsIdx + 1]

    name := _Json_GetStringProp(wsObj, "name")
    if (name = "") {
        ; fallback: monitor.workspace_names { "N": "Name" }
        wsNamesMap := _Json_ExtractObjectByKey(monObj, "workspace_names")
        m := 0
        if RegExMatch(wsNamesMap, '(?s)"' . wsIdx . '"\s*:\s*"((?:\\.|[^"])*)"', &m)
            name := _UnescapeJson(m[1])
    }
    return name
}



_State_FindWorkspaceByName(stateText, wsName) {
    mons := _State_GetMonitorsArray(stateText)
    for mi, monObj in mons {
        wsArr := _State_GetWorkspaceArrayForMonitor(monObj)
        for wi, wsObj in wsArr {
            name := _Json_GetStringProp(wsObj, "name")
            if (name != "" && StrLower(name) = StrLower(wsName))
                return { mon: mi-1, ws: wi-1, name: name } ; 0-based indices
        }
        wsNamesMap := _Json_ExtractObjectByKey(monObj, "workspace_names")
        m := 0, pos := 1
        while RegExMatch(wsNamesMap, '(?s)"(\d+)"\s*:\s*"((?:\\.|[^"])*)"', &m, pos) {
            idx := Integer(m[1]), nm := _UnescapeJson(m[2])
            if (StrLower(nm) = StrLower(wsName))
                return { mon: mi-1, ws: idx, name: nm }
            pos := m.Pos(0) + m.Len(0)
        }
    }
    return { mon: -1, ws: -1, name: "" }
}


_State_FindWorkspaceOfHwnd(stateText, hwnd) {
    if (!hwnd)
        return { mon: -1, ws: -1, name: "" }
    mons := _State_GetMonitorsArray(stateText)
    for mi, monObj in mons {
        wsArr := _State_GetWorkspaceArrayForMonitor(monObj)
        for wi, wsObj in wsArr {
            ; quick search for "hwnd": <value> inside this workspace object
            if RegExMatch(wsObj, '(?s)"hwnd"\s*:\s*' . hwnd) {
                nm := _Json_GetStringProp(wsObj, "name")
                return { mon: mi-1, ws: wi-1, name: nm }
            }
        }
    }
    return { mon: -1, ws: -1, name: "" }
}

_State_GetFocusedHwnd(stateText) {
    ; Try windows ring: { "elements":[{"hwnd":...},...], "focused":N }
    winRing := _Json_ExtractObjectByKey(stateText, "windows")
    if (winRing != "") {
        idx := _Json_GetIntProp(winRing, "focused")
        arr := _Json_ExtractArrayByKey(winRing, "elements")
        if (arr != "") {
            list := _ArrayTopLevelSplit(arr)
            if (idx >= 0 && idx < list.Length) {
                wobj := list[idx+1]
                return _Json_GetIntProp(wobj, "hwnd")
            }
        }
    }
    ; Other known fallbacks (some builds):
    m := 0
    if RegExMatch(stateText, '(?s)"focused_window"\s*:\s*\{[^}]*"hwnd"\s*:\s*(\d+)', &m)
        return Integer(m[1])
    if RegExMatch(stateText, '(?s)"focused_hwnd"\s*:\s*(\d+)', &m)
        return Integer(m[1])
    if RegExMatch(stateText, '(?s)"last_focused_window"\s*:\s*\{[^}]*"hwnd"\s*:\s*(\d+)', &m)
        return Integer(m[1])
    return 0
}

; ---------- EVENT TYPE GROUPS ----------
IsWorkspaceFocusEvent(t) {
    static S := Map(
        "FocusNamedWorkspace", true,
        "FocusWorkspaceNumber", true,
        "FocusWorkspaceNumbers", true,
        "FocusLastWorkspace", true,
        "CycleFocusWorkspace", true,
        "CycleFocusEmptyWorkspace", true,
        "FocusMonitorWorkspaceNumber", true,
        "FocusMonitorAtCursor", true,
        "FocusMonitorNumber", true,
        "CycleFocusMonitor", true
    )
    return S.Has(t)
}

IsWindowMoveSendEvent(t) {
    static S := Map(
        "MoveContainerToNamedWorkspace", true,
        "SendContainerToNamedWorkspace", true,
        "MoveContainerToWorkspaceNumber", true,
        "SendContainerToWorkspaceNumber", true,
        "MoveContainerToMonitorWorkspaceNumber", true,
        "SendContainerToMonitorWorkspaceNumber", true,
        "CycleMoveContainerToWorkspace", true,
        "CycleSendContainerToWorkspace", true,
        "CycleMoveContainerToMonitor", true,
        "CycleSendContainerToMonitor", true,
        "MoveContainerToMonitorNumber", true,
        "SendContainerToMonitorNumber", true,
        "MoveContainerToLastWorkspace", true,
        "SendContainerToLastWorkspace", true
    )
    return S.Has(t)
}

; ---------- HANDLE EACH NOTIFICATION ----------
HandleNotification(jsonLine) {
    ; jsonLine is a single full notification object
    evtObj := _Json_ExtractObjectByKey(jsonLine, "event")
    stateObj := _Json_ExtractObjectByKey(jsonLine, "state")
    if (evtObj = "" || stateObj = "") {
        Log("WARN: notification missing event or state")
        return
    }

    t := _GetEventType(evtObj)
    contentRaw := _GetEventContentRaw(evtObj)
    args := _ParseContentToArray(contentRaw)

    ; 1) Focus changes at the window level (WindowManagerEvent: FocusChange)
    if (t = "FocusChange") {
        ; content = [ WinEventName, { "hwnd": N } ]
        hwnd := 0
        if (args.Length >= 2) {
            obj := args[2]
            if (SubStr(obj, 1, 1) = "{")
                hwnd := _Json_GetIntProp(obj, "hwnd")
        }
        if (!hwnd) {
            ; fallback to state
            hwnd := _State_GetFocusedHwnd(stateObj)
        }
        loc := _State_FindWorkspaceOfHwnd(stateObj, hwnd)
        if (loc.mon >= 0 && loc.ws >= 0) {
            nm := loc.name
            if (nm = "")
                nm := _State_GetWorkspaceName(stateObj, loc.mon, loc.ws)
            Log("Focus Changed to HWND " . hwnd . " in Workspace " . Chr(34) . nm . Chr(34) . ", ID " . loc.ws . ", Monitor " . loc.mon . " via FocusChange")
        } else {
            Log("Focus Changed to HWND " . hwnd . " (workspace unresolved) via FocusChange")
        }
        return
    }

    ; 2) Workspace focus family
    if IsWorkspaceFocusEvent(t) {
        monIdx := _State_GetFocusedMonitorIndex(stateObj)
        wsIdx := -1
        resolved := false
        nm := ""

        switch t {
        case "FocusMonitorWorkspaceNumber":
            ; args = [mon, ws]
            if (args.Length >= 2) {
                monIdx := Integer(args[1])
                wsIdx := Integer(args[2])
                nm := _State_GetWorkspaceName(stateObj, monIdx, wsIdx)
                resolved := (nm != "")
                Log('Workspace Changed to "' . (nm != "" ? nm : "?") . '", ID ' . wsIdx . ", Monitor " . monIdx . " via " . t . " args=" . contentRaw)
            } else {
                Log("workspace change signal via " . t . " args=" . contentRaw . " (malformed)")
            }
            return
        case "FocusWorkspaceNumber", "FocusWorkspaceNumbers":
            if (args.Length >= 1) {
                wsIdx := Integer(args[1])
                ; if this event doesn’t include monitor, take focused monitor from state
                monIdx := _State_GetFocusedMonitorIndex(stateObj)
                nm := _State_GetWorkspaceName(stateObj, monIdx, wsIdx)
                Log('Workspace Changed to "' . (nm != "" ? nm : "?") . '", ID ' . wsIdx . ", Monitor " . monIdx . " via " . t)
            } else {
                Log("workspace change signal via " . t . " (no args)")
            }
            return
        case "FocusNamedWorkspace":
            if (args.Length >= 1) {
                want := args[1]
                loc := _State_FindWorkspaceByName(stateObj, want)
                if (loc.mon >= 0) {
                    Log('Workspace Changed to "' . loc.name . '", ID ' . loc.ws . ", Monitor " . loc.mon . " via " . t)
                } else {
                    ; fall back to focused monitor & workspace
                    monIdx := _State_GetFocusedMonitorIndex(stateObj)
                    mons := _State_GetMonitorsArray(stateObj)
                    nm := ""
                    wsIdx := -1
                    if (monIdx >= 0 && monIdx < mons.Length) {
                        wsIdx := _State_GetFocusedWorkspaceIndexForMonitor(mons[monIdx+1])
                        nm := _State_GetWorkspaceName(stateObj, monIdx, wsIdx)
                    }
                    Log('Workspace Changed to "' . (nm != "" ? nm : want) . '", ID ' . wsIdx . ", Monitor " . monIdx . " via " . t)
                }
            } else {
                Log("workspace change signal via " . t . " (no name)")
            }
            return
        case "FocusMonitorNumber":
            if (args.Length >= 1) {
                monIdx := Integer(args[1])
                mons := _State_GetMonitorsArray(stateObj)
                wsIdx := _State_GetFocusedWorkspaceIndexForMonitor(mons[monIdx+1])
                nm := _State_GetWorkspaceName(stateObj, monIdx, wsIdx)
                Log('Workspace Changed to "' . (nm != "" ? nm : "?") . '", ID ' . wsIdx . ", Monitor " . monIdx . " via " . t)
            } else {
                Log("workspace change signal via " . t . " (no monitor)")
            }
            return
        case "FocusMonitorAtCursor", "CycleFocusWorkspace", "CycleFocusEmptyWorkspace", "FocusLastWorkspace", "CycleFocusMonitor":
            monIdx := _State_GetFocusedMonitorIndex(stateObj)
            mons := _State_GetMonitorsArray(stateObj)
            if (monIdx >= 0 && monIdx < mons.Length) {
                wsIdx := _State_GetFocusedWorkspaceIndexForMonitor(mons[monIdx+1])
                nm := _State_GetWorkspaceName(stateObj, monIdx, wsIdx)
                Log('Workspace Changed to "' . (nm != "" ? nm : "?") . '", ID ' . wsIdx . ", Monitor " . monIdx . " via " . t)
            } else {
                Log("workspace change signal via " . t . " (name unresolved)")
            }
            return
        }

        ; default: fallthrough (shouldn’t get here)
        Log("workspace change signal via " . t . " args=" . contentRaw . " (name unresolved)")
        return
    }

    ; 3) Window move/send family
    if IsWindowMoveSendEvent(t) {
        ; Try to figure out destination monitor/workspace from args/state
        monIdx := _State_GetFocusedMonitorIndex(stateObj) ; default assumption
        wsIdx := -1
        nm := ""
        haveDest := false

        if (t = "MoveContainerToMonitorWorkspaceNumber" || t = "SendContainerToMonitorWorkspaceNumber") {
            if (args.Length >= 2) {
                monIdx := Integer(args[1])
                wsIdx := Integer(args[2])
                nm := _State_GetWorkspaceName(stateObj, monIdx, wsIdx)
                haveDest := true
            }
        } else if (t = "MoveContainerToWorkspaceNumber" || t = "SendContainerToWorkspaceNumber") {
            if (args.Length >= 1) {
                wsIdx := Integer(args[1])
                nm := _State_GetWorkspaceName(stateObj, monIdx, wsIdx)
                haveDest := true
            }
        } else if (t = "MoveContainerToNamedWorkspace" || t = "SendContainerToNamedWorkspace") {
            if (args.Length >= 1) {
                want := args[1]
                loc := _State_FindWorkspaceByName(stateObj, want)
                if (loc.mon >= 0) {
                    monIdx := loc.mon, wsIdx := loc.ws, nm := loc.name
                    haveDest := true
                }
            }
        } else if (InStr(t, "CycleMoveContainerToMonitor") || InStr(t, "CycleSendContainerToMonitor")) {
            ; after the cycle, state should reflect the focused monitor & its focused workspace
            monIdx := _State_GetFocusedMonitorIndex(stateObj)
            mons := _State_GetMonitorsArray(stateObj)
            if (monIdx >= 0 && monIdx < mons.Length) {
                wsIdx := _State_GetFocusedWorkspaceIndexForMonitor(mons[monIdx+1])
                nm := _State_GetWorkspaceName(stateObj, monIdx, wsIdx)
                haveDest := true
            }
        } else if (InStr(t, "CycleMoveContainerToWorkspace") || InStr(t, "CycleSendContainerToWorkspace") || t = "MoveContainerToLastWorkspace" || t = "SendContainerToLastWorkspace") {
            ; same — use post-state focused ws on focused monitor
            monIdx := _State_GetFocusedMonitorIndex(stateObj)
            mons := _State_GetMonitorsArray(stateObj)
            if (monIdx >= 0 && monIdx < mons.Length) {
                wsIdx := _State_GetFocusedWorkspaceIndexForMonitor(mons[monIdx+1])
                nm := _State_GetWorkspaceName(stateObj, monIdx, wsIdx)
                haveDest := true
            }
        }

        Log("window move/send detected via " . t . " args=" . contentRaw)

        hwnd := _State_GetFocusedHwnd(stateObj) ; best-effort — often the moved window
        if (haveDest && wsIdx >= 0 && monIdx >= 0) {
            nmSafe := (nm != "" ? nm : _State_GetWorkspaceName(stateObj, monIdx, wsIdx))
            if (nmSafe = "")
                nmSafe := "?"
            Log("windowmap hwnd " . (hwnd ? hwnd : "unknown")
                . " -> workspace " . Chr(34) . nmSafe . Chr(34)
                . " (ID " . wsIdx . ", Monitor " . monIdx . ") via " . t)
        } else {
            Log("windowmap target unresolved via " . t . " args=" . contentRaw)
        }
        return
    }

    ; 4) Other events we might care to see for future wiring (minimal log)
    if (t = "Destroy" || t = "Manage" || t = "Unmanage" || t = "Raise" || t = "TitleUpdate" || t = "Show" || t = "Hide" || t = "Minimize" || t = "Uncloak" || t = "Cloak" || t = "MoveResizeStart" || t = "MoveResizeEnd") {
        Log("window-manager event " . t . " content=" . contentRaw)
        return
    }

    if (t = "ResolutionScalingChanged" || t = "WorkAreaChanged" || t = "DisplayConnectionChange" || t = "EnteringSuspendedState" || t = "ResumingFromSuspendedState" || t = "SessionLocked" || t = "SessionUnlocked") {
        Log("monitor event " . t)
        return
    }

    if (t = "EnteredAssociatedVirtualDesktop" || t = "LeftAssociatedVirtualDesktop") {
        Log("virtual-desktop event " . t)
        return
    }

    ; fallback: just show the type
    Log("other event " . t . " content=" . contentRaw)
}
