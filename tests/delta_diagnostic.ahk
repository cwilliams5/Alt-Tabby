#Requires AutoHotkey v2.0
#SingleInstance Force

; Diagnostic tool to identify what fields are causing constant deltas

#Include ..\src\shared\config.ahk
#Include ..\src\shared\cjson.ahk
#Include ..\src\shared\ipc_pipe.ahk

global gDiag_Client := 0
global gDiag_PrevItems := Map()
global gDiag_DeltaCount := 0
global gDiag_LogPath := A_Temp "\delta_diagnostic.log"

try FileDelete(gDiag_LogPath)

Log(msg) {
    global gDiag_LogPath
    FileAppend(FormatTime(, "HH:mm:ss.") SubStr(A_TickCount, -2) " " msg "`n", gDiag_LogPath, "UTF-8")
    OutputDebug(msg "`n")
}

Log("=== Delta Diagnostic Started ===")
Log("Connecting to store...")

gDiag_Client := IPC_PipeClient_Connect(StorePipeName, OnMessage)
if (!gDiag_Client.hPipe) {
    Log("FAIL: Could not connect to store")
    ExitApp(1)
}

Log("Connected, sending hello...")

; Send hello
hello := { type: IPC_MSG_HELLO, clientId: "delta_diag", wants: { deltas: true }, projectionOpts: { sort: "Z", columns: "items", includeMinimized: true, includeCloaked: true } }
IPC_PipeClient_Send(gDiag_Client, JSON.Dump(hello))

Log("Waiting for messages... (Ctrl+C to exit)")
Log("Will compare consecutive projections and report which fields differ")
Log("")

; Run for 30 seconds then summarize
SetTimer(SummarizeAndExit, 30000)

OnMessage(line, hPipe := 0) {
    global gDiag_PrevItems, gDiag_DeltaCount
    global IPC_MSG_SNAPSHOT, IPC_MSG_PROJECTION, IPC_MSG_DELTA, IPC_MSG_HELLO_ACK

    obj := ""
    try obj := JSON.Load(line)
    if (!IsObject(obj) || !obj.Has("type"))
        return

    type := obj["type"]

    if (type = IPC_MSG_SNAPSHOT || type = IPC_MSG_PROJECTION) {
        if (!obj.Has("payload") || !obj["payload"].Has("items"))
            return
        items := obj["payload"]["items"]
        rev := obj.Has("rev") ? obj["rev"] : "?"

        Log("--- SNAPSHOT rev=" rev " items=" items.Length " ---")

        ; Compare with previous
        if (gDiag_PrevItems.Count > 0) {
            CompareItems(gDiag_PrevItems, items)
        }

        ; Save current items by hwnd
        gDiag_PrevItems := Map()
        for _, item in items {
            hwnd := item.Has("hwnd") ? item["hwnd"] : (item.HasOwnProp("hwnd") ? item.hwnd : 0)
            if (hwnd)
                gDiag_PrevItems[hwnd] := CloneItem(item)
        }
    }
    else if (type = IPC_MSG_DELTA) {
        gDiag_DeltaCount++
        rev := obj.Has("rev") ? obj["rev"] : "?"
        baseRev := obj.Has("baseRev") ? obj["baseRev"] : "?"

        upserts := 0
        removes := 0
        if (obj.Has("payload")) {
            payload := obj["payload"]
            if (payload.Has("upserts"))
                upserts := payload["upserts"].Length
            if (payload.Has("removes"))
                removes := payload["removes"].Length
        }

        Log("--- DELTA #" gDiag_DeltaCount " rev=" rev " base=" baseRev " upserts=" upserts " removes=" removes " ---")

        ; Detail upserts
        if (obj.Has("payload") && obj["payload"].Has("upserts") && obj["payload"]["upserts"].Length > 0) {
            for _, rec in obj["payload"]["upserts"] {
                hwnd := GetField(rec, "hwnd", 0)
                title := SubStr(GetField(rec, "title", ""), 1, 30)

                if (gDiag_PrevItems.Has(hwnd)) {
                    ; Show what changed
                    old := gDiag_PrevItems[hwnd]
                    changes := []

                    CompareField(old, rec, "title", changes)
                    CompareField(old, rec, "z", changes)
                    CompareField(old, rec, "pid", changes)
                    CompareField(old, rec, "isFocused", changes)
                    CompareField(old, rec, "workspaceName", changes)
                    CompareField(old, rec, "isCloaked", changes)
                    CompareField(old, rec, "isMinimized", changes)
                    CompareField(old, rec, "isOnCurrentWorkspace", changes)
                    CompareField(old, rec, "processName", changes)
                    CompareField(old, rec, "iconHicon", changes)
                    CompareField(old, rec, "lastActivatedTick", changes)

                    if (changes.Length > 0) {
                        Log("  UPSERT hwnd=" hwnd " '" title "' CHANGED: " ArrayJoin(changes, ", "))
                    } else {
                        Log("  UPSERT hwnd=" hwnd " '" title "' (no field changes detected - comparison bug?)")
                    }
                } else {
                    Log("  UPSERT hwnd=" hwnd " '" title "' (NEW window)")
                }

                ; Update our cached copy
                gDiag_PrevItems[hwnd] := CloneItem(rec)
            }
        }

        ; Detail removes
        if (obj.Has("payload") && obj["payload"].Has("removes") && obj["payload"]["removes"].Length > 0) {
            for _, hwnd in obj["payload"]["removes"] {
                Log("  REMOVE hwnd=" hwnd)
                gDiag_PrevItems.Delete(hwnd)
            }
        }
    }
    else if (type = IPC_MSG_HELLO_ACK) {
        Log("Got HELLO_ACK")
    }
}

CompareField(old, new, field, changes) {
    oldVal := GetField(old, field, "__MISSING__")
    newVal := GetField(new, field, "__MISSING__")

    ; Type-aware comparison
    oldStr := FormatVal(oldVal)
    newStr := FormatVal(newVal)

    if (oldStr != newStr) {
        changes.Push(field ":" oldStr "->" newStr)
    }
}

FormatVal(v) {
    if (v = "__MISSING__")
        return "MISSING"
    if (v = "")
        return "''"
    if (v = true || v = 1)
        return "true"
    if (v = false || v = 0)
        return "false"
    return String(v)
}

CompareItems(prevMap, items) {
    ; This is called on SNAPSHOT to see cumulative changes
    ; Delta messages are more useful for per-change analysis
}

GetField(obj, key, defaultVal := "") {
    if (obj is Map)
        return obj.Has(key) ? obj[key] : defaultVal
    try
        return obj.%key%
    catch
        return defaultVal
}

CloneItem(item) {
    ; Create a simple copy for comparison
    clone := Map()
    fields := ["hwnd", "title", "z", "pid", "isFocused", "workspaceName", "isCloaked", "isMinimized", "isOnCurrentWorkspace", "processName", "iconHicon", "lastActivatedTick", "class"]
    for _, f in fields {
        v := GetField(item, f, "")
        clone[f] := v
    }
    return clone
}

ArrayJoin(arr, sep) {
    result := ""
    for i, v in arr {
        if (i > 1)
            result .= sep
        result .= v
    }
    return result
}

SummarizeAndExit() {
    global gDiag_DeltaCount, gDiag_LogPath
    Log("")
    Log("=== SUMMARY ===")
    Log("Total deltas received in 30s: " gDiag_DeltaCount)
    Log("Average deltas per second: " Round(gDiag_DeltaCount / 30, 2))
    Log("")
    Log("Log saved to: " gDiag_LogPath)
    ExitApp(0)
}
