#Requires AutoHotkey v2.0  ; check_test_globals: skip (legacy diagnostic, uses old config.ahk)
#SingleInstance Force
#Warn VarUnset, Off
A_IconHidden := true  ; No tray icon during tests

; ============================================================
; Comprehensive Komorebi E2E Test
; ============================================================
; Tests:
; 1. Direct komorebic state parsing
; 2. Store workspace data population (all workspaces)
; 3. Workspace switching with komorebic
; 4. Data persistence after workspace switch
; ============================================================

global TestLogPath := A_Temp "\komorebi_e2e_test.log"
global TestErrors := 0
global TestPassed := 0

try FileDelete(TestLogPath)
Log("=== Komorebi E2E Test " FormatTime(, "yyyy-MM-dd HH:mm:ss") " ===")

; Include shared modules
#Include %A_ScriptDir%\..\src\shared\config.ahk
#Include %A_ScriptDir%\..\src\shared\cjson.ahk
#Include %A_ScriptDir%\..\src\shared\ipc_pipe.ahk
#Include %A_ScriptDir%\..\src\store\windowstore.ahk
#Include %A_ScriptDir%\..\src\store\winenum_lite.ahk
#Include %A_ScriptDir%\..\src\store\komorebi_sub.ahk

; ============================================================
; Part 1: Direct komorebic state analysis
; ============================================================
Log("`n--- Part 1: Direct komorebic state analysis ---")

if (!FileExist(KomorebicExe)) {
    Log("SKIP: komorebic not found at " KomorebicExe)
    ExitApp(1)
}

; Get full state
stateText := _KSub_GetStateDirect()
if (stateText = "") {
    Log("FAIL: Could not get komorebic state")
    ExitApp(1)
}
Log("PASS: Got komorebic state (" StrLen(stateText) " bytes)")
TestPassed++

; Parse state JSON once (cJson)
stateObj := ""
try stateObj := JSON.Load(stateText)
if !(stateObj is Map) {
    Log("FAIL: Could not parse komorebic state JSON")
    ExitApp(1)
}
Log("PASS: Parsed komorebic state JSON")
TestPassed++

; Navigate parsed state
monitorsArr := _KSub_GetMonitorsArray(stateObj)
if (monitorsArr.Length = 0) {
    Log("FAIL: No monitors found in komorebic state")
    ExitApp(1)
}
Log("PASS: Found " monitorsArr.Length " monitor(s)")
TestPassed++

; Count workspaces and windows per workspace
workspaceData := Map()  ; wsName -> [hwnd1, hwnd2, ...]
totalKomorebiWindows := 0

for mi, monObj in monitorsArr {
    wsArr := _KSub_GetWorkspacesArray(monObj)
    Log("  Monitor " (mi-1) ": " wsArr.Length " workspaces")

    for wi, wsObj in wsArr {
        wsName := _KSafe_Str(wsObj, "name")
        if (wsName = "")
            continue

        ; Get containers and count hwnds from parsed structure
        hwnds := []
        if (wsObj is Map && wsObj.Has("containers")) {
            containersRing := wsObj["containers"]
            for _, cont in _KSafe_Elements(containersRing) {
                if !(cont is Map)
                    continue
                if (cont.Has("windows")) {
                    for _, win in _KSafe_Elements(cont["windows"]) {
                        if (win is Map && win.Has("hwnd"))
                            hwnds.Push(_KSafe_Int(win, "hwnd"))
                    }
                }
                if (cont.Has("window")) {
                    winObj := cont["window"]
                    if (winObj is Map && winObj.Has("hwnd"))
                        hwnds.Push(_KSafe_Int(winObj, "hwnd"))
                }
            }
        }

        workspaceData[wsName] := hwnds
        totalKomorebiWindows += hwnds.Length
        Log("    Workspace '" wsName "': " hwnds.Length " windows")
    }
}

Log("  Total komorebi-managed windows: " totalKomorebiWindows)

if (workspaceData.Count > 1) {
    Log("PASS: Found " workspaceData.Count " workspaces with windows")
    TestPassed++
} else if (workspaceData.Count = 1) {
    Log("WARN: Only 1 workspace has windows (need multiple for full test)")
} else {
    Log("FAIL: No workspace data found")
    TestErrors++
}

; Get current workspace
focusedMonIdx := _KSub_GetFocusedMonitorIndex(stateObj)
currentWsName := ""
if (focusedMonIdx >= 0 && focusedMonIdx < monitorsArr.Length) {
    monObj := monitorsArr[focusedMonIdx + 1]
    focusedWsIdx := _KSub_GetFocusedWorkspaceIndex(monObj)
    currentWsName := _KSub_GetWorkspaceNameByIndex(monObj, focusedWsIdx)
}
Log("  Current workspace: '" currentWsName "'")

; ============================================================
; Part 2: Store server workspace data test
; ============================================================
Log("`n--- Part 2: Store server workspace data test ---")

storePath := A_ScriptDir "\..\src\store\store_server.ahk"
testPipe := "tabby_komorebi_e2e_" A_TickCount
storePid := 0

try {
    _KE2E_RunSilent('"' A_AhkPath '" /ErrorStdOut "' storePath '" --test --pipe=' testPipe, &storePid)
    if (!storePid) {
        Log("FAIL: Could not start store_server (CreateProcess failed)")
        ExitApp(1)
    }
} catch as e {
    Log("FAIL: Could not start store_server: " e.Message)
    ExitApp(1)
}

; Wait for store to initialize fully (winenum scan + komorebi initial poll)
Log("  Waiting for store initialization (5s)...")
Sleep(5000)

; Connect as client
global gTestResponse := ""
global gTestReceived := false

testClient := IPC_PipeClient_Connect(testPipe, Test_OnMessage)
if (!testClient.hPipe) {
    Log("FAIL: Could not connect to store")
    try ProcessClose(storePid)
    ExitApp(1)
}
Log("PASS: Connected to store")
TestPassed++

; Send hello
helloMsg := { type: IPC_MSG_HELLO, clientId: "e2e_test", wants: { deltas: false } }
IPC_PipeClient_Send(testClient, JSON.Dump(helloMsg))

; Request projection with ALL windows (includeCloaked = true)
projMsg := {
    type: IPC_MSG_PROJECTION_REQUEST,
    projectionOpts: {
        sort: "Z",
        columns: "items",
        includeMinimized: true,
        includeCloaked: true,
        currentWorkspaceOnly: false
    }
}
IPC_PipeClient_Send(testClient, JSON.Dump(projMsg))

; Wait for response
waitStart := A_TickCount
while (!gTestReceived && (A_TickCount - waitStart) < 10000) {
    Sleep(100)
}

if (!gTestReceived) {
    Log("FAIL: Timeout waiting for projection")
    IPC_PipeClient_Close(testClient)
    try ProcessClose(storePid)
    ExitApp(1)
}

Log("PASS: Received projection response")
TestPassed++

; Parse and analyze projection
try {
    respObj := JSON.Load(gTestResponse)
    items := respObj["payload"]["items"]
    meta := respObj["payload"]["meta"]

    Log("  Total items in projection: " items.Length)
    Log("  Store current workspace: '" meta["currentWSName"] "'")

    ; Check if store's current workspace matches komorebic
    if (meta["currentWSName"] = currentWsName) {
        Log("PASS: Store current workspace matches komorebic")
        TestPassed++
    } else {
        Log("FAIL: Store current workspace '" meta["currentWSName"] "' != komorebic '" currentWsName "'")
        TestErrors++
    }

    ; Count windows by workspace
    wsCount := Map()
    noWsCount := 0
    cloakedCount := 0

    for _, item in items {
        wsName := item.Has("workspaceName") ? item["workspaceName"] : ""
        isCloaked := item.Has("isCloaked") ? item["isCloaked"] : false

        if (wsName = "") {
            noWsCount++
        } else {
            if (!wsCount.Has(wsName))
                wsCount[wsName] := 0
            wsCount[wsName]++
        }

        if (isCloaked)
            cloakedCount++
    }

    Log("  Windows by workspace in store:")
    for ws, cnt in wsCount {
        Log("    '" ws "': " cnt " windows")
    }
    Log("  Windows without workspace: " noWsCount)
    Log("  Cloaked windows: " cloakedCount)

    ; Verify ALL workspaces with windows from komorebic appear in store
    missingWorkspaces := []
    for ws, hwnds in workspaceData {
        ; Skip workspaces with 0 windows - they won't be in the store
        if (hwnds.Length = 0)
            continue
        if (!wsCount.Has(ws) || wsCount[ws] = 0) {
            missingWorkspaces.Push(ws)
        }
    }

    if (missingWorkspaces.Length = 0) {
        Log("PASS: All komorebi workspaces with windows are represented in store")
        TestPassed++
    } else {
        Log("FAIL: Missing workspaces in store: " _ArrayJoin(missingWorkspaces, ", "))
        TestErrors++
    }

    ; Verify komorebi windows have workspace names
    komorebiHwndsWithWs := 0
    for ws, hwnds in workspaceData {
        for _, hwnd in hwnds {
            ; Check if this hwnd has workspace in store
            for _, item in items {
                if (item["hwnd"] = hwnd && item.Has("workspaceName") && item["workspaceName"] != "") {
                    komorebiHwndsWithWs++
                    break
                }
            }
        }
    }

    Log("  Komorebi windows with workspace in store: " komorebiHwndsWithWs "/" totalKomorebiWindows)

    if (totalKomorebiWindows > 0) {
        pct := Round(komorebiHwndsWithWs / totalKomorebiWindows * 100)
        if (pct >= 80) {
            Log("PASS: " pct "% of komorebi windows have workspace data")
            TestPassed++
        } else {
            Log("FAIL: Only " pct "% of komorebi windows have workspace data (expected >= 80%)")
            TestErrors++
        }
    }

} catch as e {
    Log("FAIL: Parse error: " e.Message)
    TestErrors++
}

; ============================================================
; Part 3: Workspace switching test
; ============================================================
Log("`n--- Part 3: Workspace switching test ---")

; Find a different workspace to switch to
targetWorkspace := ""
for ws, hwnds in workspaceData {
    if (ws != currentWsName && hwnds.Length > 0) {
        targetWorkspace := ws
        break
    }
}

if (targetWorkspace = "") {
    Log("SKIP: No other workspace with windows to switch to")
} else {
    Log("  Switching from '" currentWsName "' to '" targetWorkspace "'...")

    ; Use komorebic to switch workspace
    switchCmd := 'cmd.exe /c ""' KomorebicExe '" focus-named-workspace ' targetWorkspace '"'
    try {
        _KE2E_RunWaitSilent(switchCmd)
    } catch as e {
        Log("WARN: Switch command may have failed: " e.Message)
    }

    ; Wait for subscription to process the switch
    Sleep(2000)

    ; Request new projection
    gTestResponse := ""
    gTestReceived := false
    IPC_PipeClient_Send(testClient, JSON.Dump(projMsg))

    waitStart := A_TickCount
    while (!gTestReceived && (A_TickCount - waitStart) < 5000) {
        Sleep(100)
    }

    if (gTestReceived) {
        try {
            respObj2 := JSON.Load(gTestResponse)
            meta2 := respObj2["payload"]["meta"]
            items2 := respObj2["payload"]["items"]

            Log("  Store current workspace after switch: '" meta2["currentWSName"] "'")

            if (meta2["currentWSName"] = targetWorkspace) {
                Log("PASS: Store tracked workspace switch correctly")
                TestPassed++
            } else {
                Log("FAIL: Store shows '" meta2["currentWSName"] "' but expected '" targetWorkspace "'")
                TestErrors++
            }

            ; Verify workspace data persists
            wsCount2 := Map()
            for _, item in items2 {
                wsName := item.Has("workspaceName") ? item["workspaceName"] : ""
                if (wsName != "") {
                    if (!wsCount2.Has(wsName))
                        wsCount2[wsName] := 0
                    wsCount2[wsName]++
                }
            }

            Log("  Windows by workspace after switch:")
            for ws, cnt in wsCount2 {
                Log("    '" ws "': " cnt " windows")
            }

            ; Check original workspace still has its windows
            if (wsCount2.Has(currentWsName) && wsCount2[currentWsName] > 0) {
                Log("PASS: Original workspace '" currentWsName "' data preserved")
                TestPassed++
            } else {
                Log("FAIL: Original workspace '" currentWsName "' data lost after switch")
                TestErrors++
            }

        } catch as e {
            Log("FAIL: Parse error after switch: " e.Message)
            TestErrors++
        }
    } else {
        Log("FAIL: No response after workspace switch")
        TestErrors++
    }

    ; Switch back to original workspace
    Log("  Switching back to '" currentWsName "'...")
    switchBackCmd := 'cmd.exe /c ""' KomorebicExe '" focus-named-workspace ' currentWsName '"'
    try {
        _KE2E_RunWaitSilent(switchBackCmd)
    }
    Sleep(1000)
}

; Cleanup
IPC_PipeClient_Close(testClient)
try ProcessClose(storePid)

; ============================================================
; Summary
; ============================================================
Log("`n=== Test Summary ===")
Log("Passed: " TestPassed)
Log("Failed: " TestErrors)
Log("Result: " (TestErrors = 0 ? "ALL TESTS PASSED" : "SOME TESTS FAILED"))
Log("Log file: " TestLogPath)

ExitApp(TestErrors > 0 ? 1 : 0)

; ============================================================
; Callbacks
; ============================================================

Test_OnMessage(line, hPipe := 0) {
    global gTestResponse, gTestReceived
    ; Only accept explicit projection responses, not broadcast snapshots
    if (InStr(line, '"type":"projection"')) {
        gTestResponse := line
        gTestReceived := true
    }
}

; ============================================================
; Helpers
; ============================================================

Log(msg) {
    global TestLogPath
    FileAppend(msg "`n", TestLogPath, "UTF-8")
}

_ArrayJoin(arr, sep := ", ") {
    out := ""
    for i, v in arr {
        if (i > 1)
            out .= sep
        out .= v
    }
    return out
}

; Launch a process hidden without cursor feedback (STARTF_FORCEOFFFEEDBACK).
; Sets outPid to the new process ID. Returns true on success.
_KE2E_RunSilent(cmdLine, &outPid := 0) {
    outPid := 0
    cmdBuf := Buffer((StrLen(cmdLine) + 1) * 2)
    StrPut(cmdLine, cmdBuf, "UTF-16")
    si := Buffer(104, 0)
    NumPut("UInt", 104, si, 0)    ; cb
    NumPut("UInt", 0x81, si, 60)  ; dwFlags: STARTF_USESHOWWINDOW | STARTF_FORCEOFFFEEDBACK
    pi := Buffer(24, 0)
    result := DllCall("CreateProcessW",
        "Ptr", 0, "Ptr", cmdBuf,
        "Ptr", 0, "Ptr", 0,
        "Int", 0, "UInt", 0x08000000,
        "Ptr", 0, "Ptr", 0,
        "Ptr", si, "Ptr", pi, "Int")
    if (result) {
        outPid := NumGet(pi, 16, "UInt")
        DllCall("CloseHandle", "Ptr", NumGet(pi, 0, "Ptr"))
        DllCall("CloseHandle", "Ptr", NumGet(pi, 8, "Ptr"))
    }
    return result
}

; Launch a process hidden without cursor feedback and wait for it to exit.
; Returns the process exit code, or -1 on failure.
_KE2E_RunWaitSilent(cmdLine) {
    cmdBuf := Buffer((StrLen(cmdLine) + 1) * 2)
    StrPut(cmdLine, cmdBuf, "UTF-16")
    si := Buffer(104, 0)
    NumPut("UInt", 104, si, 0)
    NumPut("UInt", 0x81, si, 60)
    pi := Buffer(24, 0)
    result := DllCall("CreateProcessW",
        "Ptr", 0, "Ptr", cmdBuf,
        "Ptr", 0, "Ptr", 0,
        "Int", 0, "UInt", 0x08000000,
        "Ptr", 0, "Ptr", 0,
        "Ptr", si, "Ptr", pi, "Int")
    if (!result)
        return -1
    hProcess := NumGet(pi, 0, "Ptr")
    DllCall("CloseHandle", "Ptr", NumGet(pi, 8, "Ptr"))
    DllCall("WaitForSingleObject", "Ptr", hProcess, "UInt", 0xFFFFFFFF)
    exitCode := 0
    DllCall("GetExitCodeProcess", "Ptr", hProcess, "UInt*", &exitCode)
    DllCall("CloseHandle", "Ptr", hProcess)
    return exitCode
}
