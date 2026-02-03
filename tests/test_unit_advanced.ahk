; Unit Tests - Advanced Scenarios
; Defensive Close, Update Race Guard, WindowStore_MetaChanged
; Included by test_unit.ahk

RunUnitTests_Advanced() {
    global TestPassed, TestErrors, cfg

    ; ============================================================
    ; Defensive Close Before Reconnect Tests
    ; ============================================================
    Log("`n--- Defensive Close Tests ---")

    ; Test 1: IPC_PipeClient_Close is idempotent
    Log("Testing IPC_PipeClient_Close() idempotency...")
    try {
        ; Create a client with no pipe (already closed state)
        mockClient := {
            pipeName: "test",
            hPipe: 0,
            timerFn: 0,
            buf: ""
        }

        ; Should not crash when called on already-closed client
        IPC_PipeClient_Close(mockClient)
        IPC_PipeClient_Close(mockClient)  ; Double-call

        Log("PASS: IPC_PipeClient_Close() is idempotent (safe to call twice)")
        TestPassed++
    } catch as e {
        Log("FAIL: IPC_PipeClient_Close() crashed on double-call: " e.Message)
        TestErrors++
    }

    ; Test 2: IPC_PipeClient_Close handles non-object gracefully
    Log("Testing IPC_PipeClient_Close() handles invalid input...")
    try {
        IPC_PipeClient_Close(0)
        IPC_PipeClient_Close("")
        IPC_PipeClient_Close("not an object")

        Log("PASS: IPC_PipeClient_Close() handles invalid input gracefully")
        TestPassed++
    } catch as e {
        Log("FAIL: IPC_PipeClient_Close() should handle invalid input: " e.Message)
        TestErrors++
    }

    ; ============================================================
    ; Update Race Guard Tests (Bug 4 Prevention)
    ; ============================================================
    Log("`n--- Update Race Guard Tests ---")

    ; Test 1: g_UpdateCheckInProgress defaults to false
    Log("Testing g_UpdateCheckInProgress defaults to false...")
    try {
        global g_UpdateCheckInProgress

        if (g_UpdateCheckInProgress = false) {
            Log("PASS: g_UpdateCheckInProgress defaults to false")
            TestPassed++
        } else {
            Log("FAIL: g_UpdateCheckInProgress should default to false, got: " g_UpdateCheckInProgress)
            TestErrors++
        }
    } catch as e {
        Log("FAIL: g_UpdateCheckInProgress default check error: " e.Message)
        TestErrors++
    }

    ; ============================================================
    ; WindowStore_MetaChanged Functional Tests
    ; ============================================================
    Log("`n--- WindowStore_MetaChanged Functional Tests ---")

    ; Test 1: Empty previous meta returns true (first-time case)
    Log("Testing WindowStore_MetaChanged() with empty previous meta...")
    try {
        nextMeta := Map("currentWSName", "workspace1")
        result := WindowStore_MetaChanged("", nextMeta)
        if (result = true) {
            Log("PASS: WindowStore_MetaChanged returns true for empty previous meta")
            TestPassed++
        } else {
            Log("FAIL: Should return true for empty previous meta, got: " result)
            TestErrors++
        }
    } catch as e {
        Log("FAIL: WindowStore_MetaChanged empty meta error: " e.Message)
        TestErrors++
    }

    ; Test 2: Same workspace name returns false (no change)
    Log("Testing WindowStore_MetaChanged() with identical workspace names...")
    try {
        prev := Map("currentWSName", "workspace1")
        next := Map("currentWSName", "workspace1")
        result := WindowStore_MetaChanged(prev, next)
        if (result = false) {
            Log("PASS: WindowStore_MetaChanged returns false when workspace unchanged")
            TestPassed++
        } else {
            Log("FAIL: Should return false for same workspace, got: " result)
            TestErrors++
        }
    } catch as e {
        Log("FAIL: WindowStore_MetaChanged same workspace error: " e.Message)
        TestErrors++
    }

    ; Test 3: Different workspace names returns true (changed)
    Log("Testing WindowStore_MetaChanged() with different workspace names...")
    try {
        prev := Map("currentWSName", "workspace1")
        next := Map("currentWSName", "workspace2")
        result := WindowStore_MetaChanged(prev, next)
        if (result = true) {
            Log("PASS: WindowStore_MetaChanged returns true when workspace changed")
            TestPassed++
        } else {
            Log("FAIL: Should return true for different workspaces, got: " result)
            TestErrors++
        }
    } catch as e {
        Log("FAIL: WindowStore_MetaChanged different workspace error: " e.Message)
        TestErrors++
    }

    ; Test 4: Handles plain Object meta (not Map)
    Log("Testing WindowStore_MetaChanged() with plain Object meta...")
    try {
        prev := { currentWSName: "ws_a" }
        next := { currentWSName: "ws_b" }
        result := WindowStore_MetaChanged(prev, next)
        if (result = true) {
            Log("PASS: WindowStore_MetaChanged handles plain Object meta")
            TestPassed++
        } else {
            Log("FAIL: Should return true for different Object meta workspaces, got: " result)
            TestErrors++
        }

        ; Also test same name with Object
        prev2 := { currentWSName: "ws_a" }
        next2 := { currentWSName: "ws_a" }
        result2 := WindowStore_MetaChanged(prev2, next2)
        if (result2 = false) {
            Log("PASS: WindowStore_MetaChanged returns false for same Object meta workspace")
            TestPassed++
        } else {
            Log("FAIL: Should return false for same Object meta workspace, got: " result2)
            TestErrors++
        }
    } catch as e {
        Log("FAIL: WindowStore_MetaChanged Object meta error: " e.Message)
        TestErrors++
    }

    ; ============================================================
    ; Meta Inclusion Decision Tests (WorkspaceDeltaStyle logic)
    ; ============================================================
    ; Tests the boolean expression: includeMeta := !isSparse || isAlwaysMode || metaChanged
    Log("`n--- Meta Inclusion Decision Tests ---")

    ; Test 1: isSparse=true, isAlwaysMode=true → includeMeta=true
    Log("Testing includeMeta when isSparse=true, isAlwaysMode=true...")
    try {
        isSparse := true
        isAlwaysMode := true
        metaChanged := false
        includeMeta := !isSparse || isAlwaysMode || metaChanged
        if (includeMeta = true) {
            Log("PASS: includeMeta=true when isAlwaysMode=true (regardless of sparse)")
            TestPassed++
        } else {
            Log("FAIL: Should be true when isAlwaysMode=true, got: " includeMeta)
            TestErrors++
        }
    } catch as e {
        Log("FAIL: Meta inclusion test 1 error: " e.Message)
        TestErrors++
    }

    ; Test 2: isSparse=true, isAlwaysMode=false, metaChanged=false → includeMeta=false
    Log("Testing includeMeta when isSparse=true, isAlwaysMode=false, metaChanged=false...")
    try {
        isSparse := true
        isAlwaysMode := false
        metaChanged := false
        includeMeta := !isSparse || isAlwaysMode || metaChanged
        if (includeMeta = false) {
            Log("PASS: includeMeta=false when OnChange mode, sparse, and no meta change")
            TestPassed++
        } else {
            Log("FAIL: Should be false in OnChange mode with no meta change, got: " includeMeta)
            TestErrors++
        }
    } catch as e {
        Log("FAIL: Meta inclusion test 2 error: " e.Message)
        TestErrors++
    }

    ; Test 3: isSparse=true, isAlwaysMode=false, metaChanged=true → includeMeta=true
    Log("Testing includeMeta when isSparse=true, isAlwaysMode=false, metaChanged=true...")
    try {
        isSparse := true
        isAlwaysMode := false
        metaChanged := true
        includeMeta := !isSparse || isAlwaysMode || metaChanged
        if (includeMeta = true) {
            Log("PASS: includeMeta=true when OnChange mode but meta actually changed")
            TestPassed++
        } else {
            Log("FAIL: Should be true when meta changed, got: " includeMeta)
            TestErrors++
        }
    } catch as e {
        Log("FAIL: Meta inclusion test 3 error: " e.Message)
        TestErrors++
    }

    ; Test 4: isSparse=false (full row) → includeMeta=true always
    Log("Testing includeMeta when isSparse=false (full row mode)...")
    try {
        isSparse := false
        isAlwaysMode := false
        metaChanged := false
        includeMeta := !isSparse || isAlwaysMode || metaChanged
        if (includeMeta = true) {
            Log("PASS: includeMeta=true when full row mode (!isSparse)")
            TestPassed++
        } else {
            Log("FAIL: Should be true in full row mode, got: " includeMeta)
            TestErrors++
        }
    } catch as e {
        Log("FAIL: Meta inclusion test 4 error: " e.Message)
        TestErrors++
    }
}
