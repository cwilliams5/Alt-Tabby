#Requires AutoHotkey v2.0
#SingleInstance Force
A_IconHidden := true  ; No tray icon during tests
#Include ..\src\shared\config.ahk

; Headless viewer integration test (no GUI).

TestViewerDurationSec_Override := ""  ; set to a number to override config

if (TestViewerDurationSec_Override != "")
    TestViewerDurationSec := TestViewerDurationSec_Override
else if IsSet(TestLiveDurationSec_Default)
    TestViewerDurationSec := TestLiveDurationSec_Default
else
    TestViewerDurationSec := 30

TestViewerLogPath := A_ScriptDir "\viewer_live.log"
TestViewerStoreLogPath := A_ScriptDir "\viewer_store.log"
TestViewerStorePath := A_ScriptDir "\..\src\store\store_server.ahk"
TestViewerPath := A_ScriptDir "\..\src\viewer\viewer.ahk"
TestViewerPipeName := "tabby_viewer_test_" A_TickCount
TestViewer_StorePid := 0
TestViewer_ViewerPid := 0

try FileDelete(TestViewerLogPath)
try FileDelete(TestViewerStoreLogPath)

try OnError(TestViewer_OnError)

FileAppend("test_viewer_live start " FormatTime(, "yyyy-MM-dd HH:mm:ss") "`n", TestViewerLogPath, "UTF-8")

TestViewer_StartStore()
TestViewer_StartViewer()
SetTimer(TestViewer_Stop, -TestViewerDurationSec * 1000)

return

TestViewer_StartStore() {
    global TestViewerStorePath, TestViewerStoreLogPath, AhkV2Path, TestViewerPipeName, TestViewer_StorePid
    runner := (IsSet(AhkV2Path) && FileExist(AhkV2Path)) ? AhkV2Path : A_AhkPath
    _TV_RunSilent('"' runner '" "' TestViewerStorePath '" --test --log="' TestViewerStoreLogPath '" --pipe="' TestViewerPipeName '"', &TestViewer_StorePid)
}

TestViewer_StartViewer() {
    global TestViewerPath, TestViewerLogPath, AhkV2Path, TestViewerPipeName, TestViewer_ViewerPid
    runner := (IsSet(AhkV2Path) && FileExist(AhkV2Path)) ? AhkV2Path : A_AhkPath
    _TV_RunSilent('"' runner '" "' TestViewerPath '" --nogui --log="' TestViewerLogPath '" --pipe="' TestViewerPipeName '"', &TestViewer_ViewerPid)
}

TestViewer_Stop() {
    global TestViewerLogPath, TestViewer_StorePid, TestViewer_ViewerPid
    FileAppend("test_viewer_live done " FormatTime(, "yyyy-MM-dd HH:mm:ss") "`n", TestViewerLogPath, "UTF-8")
    try ProcessClose(TestViewer_ViewerPid)
    try ProcessClose(TestViewer_StorePid)
    ExitApp()
}

TestViewer_OnError(err, *) {
    global TestViewerLogPath
    msg := "test_viewer_error " FormatTime(, "yyyy-MM-dd HH:mm:ss") "`n" err.Message "`n"
    try FileAppend(msg, TestViewerLogPath, "UTF-8")
    ExitApp(1)
    return true
}

; Launch a process hidden without cursor feedback (STARTF_FORCEOFFFEEDBACK).
; Sets outPid to the new process ID. Returns true on success.
_TV_RunSilent(cmdLine, &outPid := 0) {
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
