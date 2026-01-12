; ================== komorebi_sub.ahk ==================
; Fast komorebi subscription bridge using a Named Pipe (no PowerShell, no files).
; - AHK hosts \\.\pipe\<name> (overlapped, non-blocking)
; - Launches one hidden: komorebic.exe subscribe-pipe <name>
; - Timer peeks & reads only when bytes are available (never blocks UI)
; - Maintains fast cache: hwnd -> workspace_name, plus last "state" JSON
; - Auto-reconnect & backoff

#Requires AutoHotkey v2.0

; -------- CONFIG --------
global KomorebicExe            := IsSet(KomorebicExe) ? KomorebicExe : "C:\Program Files\komorebi\bin\komorebic.exe"
global KSub_PollMs             := 50           ; timer cadence (lower = snappier)
global KSub_MaxBytesPerTick    := 65536        ; cap bytes processed per tick
global KSub_IdleRecycleMs      := 120000       ; recycle if no events this long (ms)
global KSub_MaxRestartBackoff  := 5000         ; ms

; -------- STATE --------
global KSub_PipeName := "tabby_" A_TickCount "_" Random(1000,9999)
global KSub_hPipe    := 0
global KSub_hEvent   := 0
global KSub_Over     := 0                       ; OVERLAPPED struct buffer
global KSub_Connected := false

global KSub_ClientPid := 0                      ; komorebic subscribe-pipe pid
global KSub_LastEvent := 0
global KSub_BackoffMs := 0
global KSub_LastStart := 0

global KSub_Buf := ""                           ; partial line buffer
global KSub_Map := Map()                        ; hwnd -> workspace_name
global KSub_StateText := ""                     ; last "state" JSON

; Track last workspace we observed (by name)
global KSub_LastWorkspaceName := ""
; Optional: control whether we kick a full winenum on workspace change
if !IsSet(KSub_RunRescanOnWSChange)
    KSub_RunRescanOnWSChange := true


; -------- Logging (safe if _Log missing) --------
KSub_Log(msg) {
    if (IsSet(DebugKomorebi) && DebugKomorebi) {
        try {
            _Log("[komorebi] " . msg)
        } catch as e {
            ; ignore logging errors
        }
    }
}

; -------- Public API --------
Komorebi_SubEnsure() {
    if (KSub_hPipe && KSub_Connected)
        return true
    return Komorebi_SubStart()
}

Komorebi_SubStart() {
    global KSub_hPipe, KSub_hEvent, KSub_Over, KSub_Connected
    global KSub_ClientPid, KSub_LastEvent, KSub_BackoffMs, KSub_LastStart, KSub_PipeName

    Komorebi_SubStop()  ; clean slate

    ; Validate komorebic path
    if !(IsSet(KomorebicExe) && KomorebicExe != "" && FileExist(KomorebicExe)) {
        KSub_Log("SubStart: komorebic.exe not found; will retry")
        SetTimer(Komorebi_SubPoll, KSub_PollMs)
        return false
    }

    ; Backoff if crash-looping
    now := A_TickCount
    if (KSub_LastStart && now - KSub_LastStart < 3000) {
        KSub_BackoffMs := Min(KSub_MaxRestartBackoff, Max(500, KSub_BackoffMs * 2))
        Sleep KSub_BackoffMs
    } else {
        KSub_BackoffMs := 0
    }
    KSub_LastStart := A_TickCount

    ; Create overlapped Named Pipe server (message mode)
    PIPE_ACCESS_INBOUND   := 0x00000001
    FILE_FLAG_OVERLAPPED  := 0x40000000
    PIPE_TYPE_MESSAGE     := 0x00000004
    PIPE_READMODE_MESSAGE := 0x00000002
    PIPE_WAIT             := 0x00000000

    name := "\\.\pipe\" . KSub_PipeName
    KSub_hPipe := DllCall("CreateNamedPipeW"
        , "str", name
        , "uint", PIPE_ACCESS_INBOUND | FILE_FLAG_OVERLAPPED
        , "uint", PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT
        , "uint", 1                 ; max instances
        , "uint", 65536             ; out buffer (unused for inbound)
        , "uint", 65536             ; in buffer
        , "uint", 0                 ; default timeout
        , "ptr", 0                  ; security attrs
        , "ptr")
    if (KSub_hPipe = 0 || KSub_hPipe = -1) {
        KSub_Log("SubStart: CreateNamedPipe failed")
        SetTimer(Komorebi_SubPoll, KSub_PollMs)
        return false
    }

    ; Create event for OVERLAPPED connect
    KSub_hEvent := DllCall("CreateEventW", "ptr", 0, "int", 1, "int", 0, "ptr", 0, "ptr")
    if (!KSub_hEvent) {
        KSub_Log("SubStart: CreateEvent failed")
        Komorebi_SubStop()
        SetTimer(Komorebi_SubPoll, KSub_PollMs)
        return false
    }

    ; Allocate OVERLAPPED and set hEvent (x64 offset 24, x86 offset 16)
    KSub_Over := Buffer(A_PtrSize=8 ? 32 : 20, 0)
    NumPut("ptr", KSub_hEvent, KSub_Over, (A_PtrSize=8) ? 24 : 16)

    ; Begin async connect
    ok := DllCall("ConnectNamedPipe", "ptr", KSub_hPipe, "ptr", KSub_Over.Ptr, "int")
    if (!ok) {
        gle := DllCall("GetLastError", "uint")
        if (gle = 997) { ; ERROR_IO_PENDING
            KSub_Connected := false
        } else if (gle = 535) { ; ERROR_PIPE_CONNECTED
            KSub_Connected := true
        } else {
            KSub_Log("SubStart: ConnectNamedPipe err=" . gle)
            Komorebi_SubStop()
            SetTimer(Komorebi_SubPoll, KSub_PollMs)
            return false
        }
    } else {
        KSub_Connected := true
    }

    ; Launch hidden komorebic subscriber (client)
    try {
        KSub_ClientPid := Run('"' KomorebicExe '" subscribe-pipe ' KSub_PipeName, , "Hide")
        KSub_Log("SubStart: spawned client pid=" . KSub_ClientPid . " pipe=" . KSub_PipeName)
    } catch as e {
        KSub_Log("SubStart: failed to start subscribe-pipe: " . e.Message)
        ; keep server alive; we may connect later
    }

    KSub_LastEvent := A_TickCount
    SetTimer(Komorebi_SubPoll, KSub_PollMs)
    return true
}

Komorebi_SubStop() {
    global KSub_ClientPid, KSub_hPipe, KSub_hEvent, KSub_Over, KSub_Connected
    SetTimer(Komorebi_SubPoll, 0)

    if (KSub_ClientPid) {
        try {
            ProcessClose(KSub_ClientPid)
        } catch as e {
            ; ignore
        }
        KSub_ClientPid := 0
    }

    if (KSub_hPipe) {
        try {
            DllCall("DisconnectNamedPipe", "ptr", KSub_hPipe)
        } catch as e {
        }
        try {
            DllCall("CloseHandle", "ptr", KSub_hPipe)
        } catch as e {
        }
        KSub_hPipe := 0
    }
    if (KSub_hEvent) {
        try {
            DllCall("CloseHandle", "ptr", KSub_hEvent)
        } catch as e {
        }
        KSub_hEvent := 0
    }
    KSub_Over := 0
    KSub_Connected := false
    KSub_Log("SubStop: done")
}

; ---- Fast map lookup used by your Komorebi_FocusHwnd fast path ----
Komorebi_SubTryMap(hwnd, &ws) {
    global KSub_Map, KSub_StateText
    if (KSub_Map.Has(hwnd)) {
        ws := KSub_Map[hwnd]
        return (ws != "")
    }
    if (KSub_StateText != "") {
        try {
            w := _Komorebi_FindWorkspaceNameByHwnd(KSub_StateText, hwnd)
            if (w != "") {
                KSub_Map[hwnd] := w
                ws := w
                return true
            }
        } catch as e {
            ; ignore
        }
    }
    ws := ""
    return false
}

; -------- Timer: connect progress, read available bytes (non-blocking) --------
Komorebi_SubPoll() {
    global KSub_hPipe, KSub_hEvent, KSub_Over, KSub_Connected
    global KSub_ClientPid, KSub_LastEvent, KSub_IdleRecycleMs, KSub_MaxBytesPerTick

    if (!KSub_hPipe) {
        Komorebi_SubStart()
        return
    }

    ; If not connected yet, check the event
    if (!KSub_Connected) {
        res := DllCall("kernel32\WaitForSingleObject", "ptr", KSub_hEvent, "uint", 0, "uint")
        if (res = 0) { ; WAIT_OBJECT_0
            KSub_Connected := true
            KSub_Log("SubPoll: pipe connected")
        }
        return
    }

    ; Read loop (bounded by bytes per tick)
    bytesProcessed := 0
    loop {
        avail := 0, bytesLeft := 0
        ok := DllCall("PeekNamedPipe"
            , "ptr", KSub_hPipe
            , "ptr", 0, "uint", 0
            , "uint*", 0
            , "uint*", &avail
            , "uint*", &bytesLeft
            , "int")
        if (!ok) {
            gle := DllCall("GetLastError", "uint")
            if (gle = 109) { ; ERROR_BROKEN_PIPE
                KSub_Log("SubPoll: client disconnected (broken pipe) -> restarting")
                Komorebi_SubStart()
                return
            }
            return
        }

        if (avail = 0)
            break

        toRead := Min(avail, KSub_MaxBytesPerTick - bytesProcessed)
        if (toRead <= 0)
            break

        buf := Buffer(toRead)
        read := 0
        ok2 := DllCall("ReadFile"
            , "ptr", KSub_hPipe
            , "ptr", buf.Ptr
            , "uint", toRead
            , "uint*", &read
            , "ptr", 0
            , "int")
        if (!ok2) {
            gle := DllCall("GetLastError", "uint")
            if (gle = 109) {
                KSub_Log("SubPoll: client disconnected during read -> restarting")
                Komorebi_SubStart()
                return
            }
            return
        }

        if (read > 0) {
            chunk := StrGet(buf.Ptr, read, "UTF-8")
            KSub_LastEvent := A_TickCount
            KSub_ProcessChunk(chunk)
            bytesProcessed += read
            if (bytesProcessed >= KSub_MaxBytesPerTick)
                break
        } else {
            break
        }
    }

    ; Recycle if idle for a long time (handles komorebi restarts)
    idle := A_TickCount - KSub_LastEvent
    if (idle > KSub_IdleRecycleMs) {
        KSub_Log("SubPoll: idle " . idle . "ms -> recycling subscriber")
        Komorebi_SubStart()
    }
}

KSub_ProcessChunk(chunk) {
    global KSub_Buf
    KSub_Buf .= chunk
    while true {
        pos := InStr(KSub_Buf, "`n")
        if (!pos)
            break
        line := RTrim(SubStr(KSub_Buf, 1, pos - 1), "`r")
        KSub_Buf := SubStr(KSub_Buf, pos + 1)
        if (line != "")
            Komorebi_SubOnLine(line)
    }
}

; -------- Parse each JSON line --------
; -------- Parse each JSON line --------
Komorebi_SubOnLine(line) {
    global KSub_Map, KSub_StateText

    hwnd := 0, ws := ""

    m := 0
    if RegExMatch(line, '"hwnd"\s*:\s*(\d+)', &m)
        hwnd := Integer(m[1])

    n := 0
    if RegExMatch(line, '"workspace_name"\s*:\s*"([^"]+)"', &n)
        ws := n[1]
    else if RegExMatch(line, '"workspace"\s*:\s*"([^"]+)"', &n)
        ws := n[1]
    else if InStr(line, '"workspace"') && RegExMatch(line, '"name"\s*:\s*"([^"]+)"', &n)
        ws := n[1]

    ; Fast path: line explicitly carried hwnd + workspace
    if (hwnd && ws != "") {
        ; Route through our central handler (updates store + optional rescan)
        KSub_OnWorkspaceObservation(hwnd, ws)
        return
    }

    ; Full state update present on this line?
    if InStr(line, '"state"') {
        st := _KSub_ExtractStateJson(line)
        if (st != "" && st != "{}") {
            KSub_StateText := st
            ; If we also know a hwnd on this event, derive workspace from state
            if (hwnd) {
                try {
                    w := _Komorebi_FindWorkspaceNameByHwnd(st, hwnd) ; from komorebi.ahk
                    if (w != "") {
                        ; Use the same central handler so we set current WS, ensure(), and rescan if changed
                        KSub_OnWorkspaceObservation(hwnd, w)
                        return
                    }
                } catch {
                    ; ignore
                }
            }
        }
    }

    ; Otherwise nothing actionable on this line
}


; Extract the JSON object that follows the "state": key on this line
_KSub_ExtractStateJson(line) {
    posState := InStr(line, '"state"')
    if (!posState)
        return ""
    posColon := InStr(line, ":", false, posState)
    if (!posColon)
        return ""
    i := posColon + 1
    while (i <= StrLen(line) && SubStr(line, i, 1) ~= "\s")
        i += 1
    if (i > StrLen(line) || SubStr(line, i, 1) != "{")
        return ""
    depth := 0, start := i, j := i
    while (j <= StrLen(line)) {
        ch := SubStr(line, j, 1)
        if (ch = "{") {
            depth += 1
        } else if (ch = "}") {
            depth -= 1
            if (depth = 0)
                return SubStr(line, start, j - start + 1)
        } else if (ch = '"') {
            j += 1
            while (j <= StrLen(line)) {
                c := SubStr(line, j, 1)
                if (c = '"' && SubStr(line, j-1, 1) != "\")
                    break
                j += 1
            }
        }
        j += 1
    }
    return ""
}

; Handle an observation that a specific hwnd belongs to a workspaceName.
; - Updates fast map
; - If the workspace changed vs. last seen → set current WS, Ensure(hwnd, hints), and run a full rescan
; - If the workspace is unchanged → just Ensure(hwnd, hints)
KSub_OnWorkspaceObservation(hwnd, workspaceName) {
    global KSub_Map, KSub_LastWorkspaceName, KSub_RunRescanOnWSChange

    hwnd := hwnd + 0
    ws   := workspaceName . ""

    if (hwnd <= 0 || ws = "")
        return

    ; Keep local fast map fresh
    KSub_Map[hwnd] := ws

    ; Same workspace as last observation? Just ensure the row with hints.
    if (KSub_LastWorkspaceName != "" && KSub_LastWorkspaceName = ws) {
        try WindowStore_Ensure(hwnd, { workspaceName: ws, isOnCurrentWorkspace: true }, "komorebi")
        catch
            ; ignore
        return
    }

    ; Workspace changed → update “current workspace”, ensure hwnd, and optionally rescan
    KSub_LastWorkspaceName := ws

    ; 1) Tell the store the new current workspace
    try WindowStore_SetCurrentWorkspace("", ws)
    catch
        ; ignore

    ; 2) Ensure the hwnd exists and annotate it
    try WindowStore_Ensure(hwnd, { workspaceName: ws, isOnCurrentWorkspace: true }, "komorebi")
    catch
        ; ignore

    ; 3) Kick a fresh full enumeration so presence/z-order/state are synced
    if (KSub_RunRescanOnWSChange) {
        try WinList_EnumerateAll()
        catch
            ; ignore
    }
}


; Convenience wrapper if you ever want to trigger a rescan from elsewhere.
KSub_TriggerFullRescan() {
    try WinList_EnumerateAll()
    catch
        ; ignore
}


