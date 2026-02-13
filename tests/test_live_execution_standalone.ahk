; Live Tests - Execution Modes (Standalone /src only)
; Split from test_live_execution.ahk for parallel execution
; Included by test_live.ahk
#Include test_utils.ahk

RunLiveTests_ExecutionStandalone() {
    global TestPassed, TestErrors, cfg
    global IPC_MSG_HELLO

    storePath := A_ScriptDir "\..\src\store\store_server.ahk"

    ; ============================================================
    ; Standalone /src Execution Test
    ; ============================================================
    Log("`n--- Standalone /src Execution Test ---")

    ; Test that store_server.ahk can be launched directly from /src
    standaloneStorePipe := "tabby_standalone_test_" A_TickCount
    standaloneStorePid := 0

    if (!_Test_RunSilent('"' A_AhkPath '" /ErrorStdOut "' storePath '" --test --pipe=' standaloneStorePipe, &standaloneStorePid)) {
        Log("FAIL: Could not launch standalone store_server.ahk")
        TestErrors++
        standaloneStorePid := 0
    }

    if (standaloneStorePid) {
        ; Wait for store pipe to become available (adaptive)
        ; NOTE: Do NOT reduce this timeout. Store startup (parse + config + blacklist +
        ; pipe creation) is I/O-bound and competes with 15+ parallel test processes.
        if (!WaitForStorePipe(standaloneStorePipe, 5000)) {
            Log("FAIL: Standalone store pipe not ready within timeout")
            TestErrors++
            try ProcessClose(standaloneStorePid)
            standaloneStorePid := 0
        }
    }

    if (standaloneStorePid) {
        ; Verify process is running
        if (ProcessExist(standaloneStorePid)) {
            Log("PASS: Standalone store_server.ahk launched (PID=" standaloneStorePid ")")
            TestPassed++

            ; Try to connect to verify pipe was created
            standaloneClient := IPC_PipeClient_Connect(standaloneStorePipe, Test_OnStandaloneMessage)

            if (standaloneClient.hPipe) {
                Log("PASS: Connected to standalone store pipe")
                TestPassed++
                IPC_PipeClient_Close(standaloneClient)
            } else {
                Log("FAIL: Could not connect to standalone store pipe")
                TestErrors++
            }
        } else {
            Log("FAIL: Standalone store_server.ahk exited unexpectedly")
            TestErrors++
        }

        try ProcessClose(standaloneStorePid)
        ; Wait for process to fully exit
        waitStart := A_TickCount
        while (ProcessExist(standaloneStorePid) && (A_TickCount - waitStart) < 2000)
            Sleep(20)
    }
}
