#Requires AutoHotkey v2.0
#SingleInstance Force
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
    global TestViewerStorePath, TestViewerStoreLogPath, AhkV2Path, TestViewerPipeName
    runner := (IsSet(AhkV2Path) && FileExist(AhkV2Path)) ? AhkV2Path : A_AhkPath
    Run('"' runner '" "' TestViewerStorePath '" --test --log="' TestViewerStoreLogPath '" --pipe="' TestViewerPipeName '"', , "Hide", &TestViewer_StorePid)
}

TestViewer_StartViewer() {
    global TestViewerPath, TestViewerLogPath, AhkV2Path, TestViewerPipeName
    runner := (IsSet(AhkV2Path) && FileExist(AhkV2Path)) ? AhkV2Path : A_AhkPath
    Run('"' runner '" "' TestViewerPath '" --nogui --log="' TestViewerLogPath '" --pipe="' TestViewerPipeName '"', , "Hide", &TestViewer_ViewerPid)
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
