; Unit Tests - Advanced Scenarios
; Defensive Close, Update Race Guard
; Included by test_unit.ahk
#Include test_utils.ahk

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
    ; HandleTimerError Unit Tests
    ; ============================================================
    ; The shared error boundary used by ALL timer callbacks (~12+).
    ; Tests backoff progression, threshold behavior, and counter tracking.
    Log("`n--- HandleTimerError Tests ---")

    mockErr := { Message: "test error", File: "test.ahk", Line: 1, What: "" }
    mockLogPath := A_Temp "\tabby_test_hte.log"
    try FileDelete(mockLogPath)

    ; Test 1-2: Below threshold — returns 0, no backoff
    errCount := 0
    backoffUntil := 0
    result := HandleTimerError(mockErr, &errCount, &backoffUntil, mockLogPath, "test")
    AssertEq(errCount, 1, "HandleTimerError: errCount increments to 1")
    AssertEq(result, 0, "HandleTimerError: below threshold returns 0")

    result := HandleTimerError(mockErr, &errCount, &backoffUntil, mockLogPath, "test")
    AssertEq(errCount, 2, "HandleTimerError: errCount increments to 2")
    AssertEq(result, 0, "HandleTimerError: still below threshold returns 0")

    ; Test 3: Hits threshold (3) — first backoff is 5000ms
    result := HandleTimerError(mockErr, &errCount, &backoffUntil, mockLogPath, "test")
    AssertEq(errCount, 3, "HandleTimerError: errCount reaches threshold")
    AssertEq(result, 5000, "HandleTimerError: first backoff is 5000ms")
    AssertTrue(backoffUntil > 0, "HandleTimerError: backoffUntil is set")

    ; Test 4: 4th error — backoff doubles to 10000ms
    result := HandleTimerError(mockErr, &errCount, &backoffUntil, mockLogPath, "test")
    AssertEq(result, 10000, "HandleTimerError: second backoff doubles to 10000ms")

    ; Test 5: 5th error — backoff doubles to 20000ms
    result := HandleTimerError(mockErr, &errCount, &backoffUntil, mockLogPath, "test")
    AssertEq(result, 20000, "HandleTimerError: third backoff doubles to 20000ms")

    ; Test 6: Backoff caps at 300000ms (5 min)
    ; Simulate many consecutive errors to hit cap: need errCount-maxErrors >= 6 (5000*2^6=320000 > 300000)
    errCount := 10
    backoffUntil := 0
    result := HandleTimerError(mockErr, &errCount, &backoffUntil, mockLogPath, "test")
    ; errCount is now 11, overshoot = 11-3 = 8, 5000 * 2^8 = 1280000 > 300000 → capped
    AssertEq(result, 300000, "HandleTimerError: backoff caps at 300000ms (5 min)")

    ; Test 7: Custom maxErrors parameter
    errCount := 0
    backoffUntil := 0
    result := HandleTimerError(mockErr, &errCount, &backoffUntil, mockLogPath, "test", 1)
    AssertEq(result, 5000, "HandleTimerError: custom maxErrors=1 triggers on first error")

    ; Cleanup
    try FileDelete(mockLogPath)

    ; ============================================================
    ; QPC High-Precision Timer Tests
    ; ============================================================
    ; QPC() wraps QueryPerformanceCounter — returns milliseconds as float.
    ; Used in 18+ production files for diagnostic timing.
    Log("`n--- QPC Tests ---")

    ; Test 1: QPC returns positive value
    t1 := QPC()
    AssertTrue(t1 > 0, "QPC: returns positive value")

    ; Test 2: QPC is monotonically increasing
    t2 := QPC()
    AssertTrue(t2 >= t1, "QPC: monotonically increasing (t2 >= t1)")

    ; Test 3: Consecutive calls are fast (< 50ms apart)
    AssertTrue((t2 - t1) < 50, "QPC: consecutive calls < 50ms apart (got " Round(t2 - t1, 3) "ms)")

    ; ============================================================
    ; HiSleep High-Precision Sleep Tests
    ; ============================================================
    ; HiSleep(ms) uses QPC spin-loop for sub-ms precision.
    ; Conservative tolerances to avoid flakiness on slow machines.
    Log("`n--- HiSleep Tests ---")

    ; Test 1: HiSleep(50) within tolerance
    start := QPC()
    HiSleep(50)
    elapsed := QPC() - start
    AssertTrue(elapsed >= 40 && elapsed <= 100, "HiSleep(50): elapsed within 40-100ms (got " Round(elapsed, 2) "ms)")

    ; Test 2: HiSleep(0) returns immediately
    start := QPC()
    HiSleep(0)
    elapsed := QPC() - start
    AssertTrue(elapsed < 10, "HiSleep(0): returns within 10ms (got " Round(elapsed, 2) "ms)")

    ; ============================================================
    ; Win32ErrorString Tests
    ; ============================================================
    ; Converts Win32 error codes to human-readable strings via FormatMessage.
    ; Used in 5 production files for diagnostic logging.
    Log("`n--- Win32ErrorString Tests ---")

    ; Test 1: Known error code (ERROR_ACCESS_DENIED = 5)
    msg5 := Win32ErrorString(5)
    AssertTrue(InStr(msg5, "denied") > 0 || InStr(msg5, "Denied") > 0, "Win32ErrorString(5): contains 'denied' (got '" msg5 "')")

    ; Test 2: Error code 0 (ERROR_SUCCESS) returns non-empty
    msg0 := Win32ErrorString(0)
    AssertTrue(StrLen(msg0) > 0, "Win32ErrorString(0): returns non-empty string (got '" msg0 "')")

    ; Test 3: Unknown error code returns fallback with error number
    msg99 := Win32ErrorString(99999)
    AssertTrue(InStr(msg99, "99999") > 0, "Win32ErrorString(99999): fallback contains '99999' (got '" msg99 "')")

}
