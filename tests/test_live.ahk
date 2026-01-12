#Requires AutoHotkey v2.0
#Include ..\src\shared\config.ahk
#Include ..\src\shared\json.ahk
#Include ..\src\shared\ipc_pipe.ahk

; Live integration test harness (observes real system state).

TestLiveDurationSec_Override := ""  ; set to a number to override config

if (TestLiveDurationSec_Override != "")
    TestLiveDurationSec := TestLiveDurationSec_Override
else if IsSet(TestLiveDurationSec_Default)
    TestLiveDurationSec := TestLiveDurationSec_Default
else
    TestLiveDurationSec := 30

TestLiveLogPath := A_ScriptDir "\windowstore_live.log"
TestLiveStorePath := A_ScriptDir "\..\src\store\store_server.ahk"
TestLiveStoreLogPath := A_ScriptDir "\windowstore_store.log"
TestLiveLastMsg := 0

FileAppend("test_live start " FormatTime(, "yyyy-MM-dd HH:mm:ss") "`n", TestLiveLogPath, "UTF-8")

TestLive_StartStore()
TestLive_Client := IPC_PipeClient_Connect(StorePipeName, Func("TestLive_OnMessage"))
TestLive_SendHello()
SetTimer(TestLive_Tick, 500)
SetTimer(TestLive_Stop, -TestLiveDurationSec * 1000)

return

TestLive_Tick() {
    global TestLiveLastMsg, TestLiveLogPath
    if ((A_TickCount - TestLiveLastMsg) > 3000) {
        FileAppend("no messages recently`n", TestLiveLogPath, "UTF-8")
        TestLiveLastMsg := A_TickCount
    }
}

TestLive_Stop() {
    global TestLiveLogPath
    FileAppend("test_live done " FormatTime(, "yyyy-MM-dd HH:mm:ss") "`n", TestLiveLogPath, "UTF-8")
    ExitApp()
}

TestLive_StartStore() {
    global TestLiveStorePath, TestLiveStoreLogPath
    Run('"' A_AhkPath '" "' TestLiveStorePath '" --test --log="' TestLiveStoreLogPath '"', , "Hide")
}

TestLive_SendHello() {
    global TestLive_Client
    msg := { type: IPC_MSG_HELLO, clientId: "test_live", wants: { deltas: false }, projectionOpts: IPC_DefaultProjectionOpts() }
    IPC_PipeClient_Send(TestLive_Client, JXON_Dump(msg))
    req := { type: IPC_MSG_SNAPSHOT_REQUEST, projectionOpts: IPC_DefaultProjectionOpts(), includeItems: true }
    IPC_PipeClient_Send(TestLive_Client, JXON_Dump(req))
}

TestLive_OnMessage(line, hPipe := 0) {
    global TestLiveLastMsg, TestLiveLogPath
    TestLiveLastMsg := A_TickCount
    FileAppend(line "`n", TestLiveLogPath, "UTF-8")
}
