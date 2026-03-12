; Flight Recorder Ring Buffer Tests
; Tests FR_Record() wraparound, slot population, and disabled guard.
; Standalone file — must NOT be included in test chains that stub FR_Record.
#Requires AutoHotkey v2.0
#Warn VarUnset, Off
A_IconHidden := true  ; No tray icon during tests

; Worktree-scoped log path
SplitPath(A_ScriptDir, , &_frWorktreeParent)
SplitPath(_frWorktreeParent, &_frWorktreeId)
global FR_TestLogPath := A_Temp "\fr_tests_" _frWorktreeId ".log"

; Test tracking
global FR_TestPassed := 0
global FR_TestFailed := 0

; ============================================================
; MOCKS (defined BEFORE gui_flight_recorder.ahk include)
; ============================================================

; Mock QPC — incrementing counter for predictable timestamps
global gMock_QPCCounter := 0
QPC() {
    global gMock_QPCCounter
    gMock_QPCCounter += 1
    return gMock_QPCCounter
}

; Mocks for functions called inside _FR_Dump/_FR_DumpPhase2/_FR_ShowNoteDialog.
; Never called in tests, but AHK v2 needs them defined at load time.
GUI_ForceReset() {
}
GUI_HideOverlay() {
}
GUI_GetItemWSName(item) {
    return ""
}
GUI_GetItemIsOnCurrent(item) {
    return true
}
GUI_AntiFlashPrepare(params*) {
}
GUI_AntiFlashReveal(params*) {
}
Theme_GetBgColor() {
    return "000000"
}
Theme_ApplyToGui(params*) {
    return ""
}
Theme_GetAccentColor() {
    return "FFFFFF"
}
Theme_ApplyToControl(params*) {
}
Theme_MarkAccent(params*) {
}
Theme_UntrackGui(params*) {
}

; Globals referenced by _FR_Dump() / FR_Init() in gui_flight_recorder.ahk.
; Never called in tests, but static analysis requires declarations.
global cfg := {DiagFlightRecorder: false, DiagFlightRecorderBufferSize: 2000, DiagFlightRecorderHotkey: "F12"}
global gGUI_State := "IDLE"
global gGUI_LiveItems := []
global gGUI_LiveItemsMap := Map()
global gGUI_DisplayItems := []
global gGUI_Sel := 1
global gGUI_Pending := { hwnd: 0, wsName: "", deadline: 0, phase: "", waitUntil: 0, shell: "", tempFile: "" }
global gGUI_CurrentWSName := ""
global gGUI_OverlayVisible := false
global gGUI_ScrollTop := 0
global gINT_SessionActive := false
global gINT_BypassMode := false
global gINT_AltIsDown := false
global gINT_TabPending := false
global gINT_PressCount := 0
global gINT_TabHeld := false
global gINT_AltUpDuringPending := false
global gINT_PendingDecideArmed := false
global gWS_Rev := 0
global gWS_Store := Map()
global gWS_SortOrderDirty := false
global gWS_MRUBumpOnly := false
global gWS_DirtyHwnds := Map()
global gWS_IconQueue := []
global gWS_PidQueue := []
global gWS_ZQueue := []

; ============================================================
; INCLUDE PRODUCTION CODE
; ============================================================
#Include %A_ScriptDir%\..\src\gui\gui_flight_recorder.ahk

; ============================================================
; TEST UTILITIES
; ============================================================

FR_ResetBuffer(size := 5) {
    global gFR_Enabled, gFR_Size, gFR_Buffer, gFR_Idx, gFR_Count, gMock_QPCCounter
    gFR_Enabled := true
    gFR_Size := size
    gFR_Buffer := []
    gFR_Buffer.Length := size
    Loop size
        gFR_Buffer[A_Index] := [0, 0, 0, 0, 0, 0]
    gFR_Idx := 0
    gFR_Count := 0
    gMock_QPCCounter := 0
}

FR_AssertEq(actual, expected, testName) {
    global FR_TestPassed, FR_TestFailed
    if (actual = expected) {
        FR_TestPassed++
        return true
    }
    FR_TestFailed++
    FR_Log("FAIL: " testName " - Expected: " expected ", Got: " actual)
    return false
}

FR_Log(msg) {
    global FR_TestLogPath
    FileAppend(msg "`n", FR_TestLogPath, "UTF-8")
}

; ============================================================
; TESTS
; ============================================================

RunFlightRecorderTests() {
    global FR_TestPassed, FR_TestFailed
    global gFR_Enabled, gFR_Buffer, gFR_Idx, gFR_Size, gFR_Count
    global FR_EV_ALT_DN, FR_EV_TAB_DN, FR_EV_STATE, FR_EV_FREEZE, FR_EV_SESSION_START

    FR_Log("=== Flight Recorder Ring Buffer Tests ===")

    ; ----- Test 1: Single record populates slot 1 -----
    FR_Log("Test: Single record populates slot 1")
    FR_ResetBuffer(5)

    FR_Record(FR_EV_ALT_DN, 10, 20, 30, 40)

    FR_AssertEq(gFR_Idx, 1, "Single: idx=1")
    FR_AssertEq(gFR_Count, 1, "Single: count=1")
    b := gFR_Buffer[1]
    FR_AssertEq(b[1], 1, "Single: timestamp=1 (first QPC call)")
    FR_AssertEq(b[2], FR_EV_ALT_DN, "Single: event=FR_EV_ALT_DN")
    FR_AssertEq(b[3], 10, "Single: d1=10")
    FR_AssertEq(b[4], 20, "Single: d2=20")
    FR_AssertEq(b[5], 30, "Single: d3=30")
    FR_AssertEq(b[6], 40, "Single: d4=40")

    ; ----- Test 2: Fill buffer to capacity -----
    FR_Log("Test: Fill buffer to capacity (5 records)")
    FR_ResetBuffer(5)

    FR_Record(FR_EV_ALT_DN, 1, 0, 0, 0)
    FR_Record(FR_EV_TAB_DN, 2, 0, 0, 0)
    FR_Record(FR_EV_STATE, 3, 0, 0, 0)
    FR_Record(FR_EV_FREEZE, 4, 0, 0, 0)
    FR_Record(FR_EV_SESSION_START, 5, 0, 0, 0)

    FR_AssertEq(gFR_Idx, 5, "Full: idx=5")
    FR_AssertEq(gFR_Count, 5, "Full: count=5")
    FR_AssertEq(gFR_Buffer[1][2], FR_EV_ALT_DN, "Full: slot 1 = ALT_DN")
    FR_AssertEq(gFR_Buffer[2][2], FR_EV_TAB_DN, "Full: slot 2 = TAB_DN")
    FR_AssertEq(gFR_Buffer[3][2], FR_EV_STATE, "Full: slot 3 = STATE")
    FR_AssertEq(gFR_Buffer[4][2], FR_EV_FREEZE, "Full: slot 4 = FREEZE")
    FR_AssertEq(gFR_Buffer[5][2], FR_EV_SESSION_START, "Full: slot 5 = SESSION_START")

    ; ----- Test 3: Wraparound — 6th record overwrites slot 1 -----
    FR_Log("Test: 6th record wraps to slot 1")
    FR_ResetBuffer(5)

    Loop 5
        FR_Record(FR_EV_STATE, A_Index, 0, 0, 0)

    ; 6th record should wrap to slot 1
    FR_Record(FR_EV_ALT_DN, 99, 0, 0, 0)

    FR_AssertEq(gFR_Idx, 1, "Wrap: idx=1 (wrapped)")
    FR_AssertEq(gFR_Count, 6, "Wrap: count=6")
    FR_AssertEq(gFR_Buffer[1][2], FR_EV_ALT_DN, "Wrap: slot 1 overwritten with ALT_DN")
    FR_AssertEq(gFR_Buffer[1][3], 99, "Wrap: slot 1 d1=99")
    ; Slots 2-5 should still have original data
    FR_AssertEq(gFR_Buffer[2][3], 2, "Wrap: slot 2 preserved (d1=2)")
    FR_AssertEq(gFR_Buffer[5][3], 5, "Wrap: slot 5 preserved (d1=5)")

    ; ----- Test 4: Double wraparound — 12 records (2+ full cycles) -----
    FR_Log("Test: 12 records (2+ full cycles)")
    FR_ResetBuffer(5)

    Loop 12
        FR_Record(FR_EV_STATE, A_Index, 0, 0, 0)

    FR_AssertEq(gFR_Idx, 2, "Double: idx=2 (12 mod 5 = 2)")
    FR_AssertEq(gFR_Count, 12, "Double: count=12")
    ; Latest 5 records (8-12) occupy slots: 3,4,5,1,2
    FR_AssertEq(gFR_Buffer[3][3], 8, "Double: slot 3 = record 8")
    FR_AssertEq(gFR_Buffer[4][3], 9, "Double: slot 4 = record 9")
    FR_AssertEq(gFR_Buffer[5][3], 10, "Double: slot 5 = record 10")
    FR_AssertEq(gFR_Buffer[1][3], 11, "Double: slot 1 = record 11")
    FR_AssertEq(gFR_Buffer[2][3], 12, "Double: slot 2 = record 12")

    ; ----- Test 5: Disabled guard prevents recording -----
    FR_Log("Test: Disabled guard prevents recording")
    FR_ResetBuffer(5)

    ; Record one event to verify buffer works
    FR_Record(FR_EV_ALT_DN, 1, 0, 0, 0)
    FR_AssertEq(gFR_Count, 1, "Guard setup: 1 record written")

    ; Disable and try to record
    gFR_Enabled := false
    FR_Record(FR_EV_TAB_DN, 99, 0, 0, 0)

    FR_AssertEq(gFR_Count, 1, "Guard: count unchanged (still 1)")
    FR_AssertEq(gFR_Idx, 1, "Guard: idx unchanged (still 1)")
    FR_AssertEq(gFR_Buffer[2][2], 0, "Guard: slot 2 not written (ev=0)")

    ; ----- Summary -----
    FR_Log("`n=== Flight Recorder Tests Summary ===")
    FR_Log("Passed: " FR_TestPassed)
    FR_Log("Failed: " FR_TestFailed)
    FR_Log("Result: " (FR_TestFailed = 0 ? "ALL TESTS PASSED" : "SOME TESTS FAILED"))

    return FR_TestFailed = 0
}

; ============================================================
; ENTRY POINT
; ============================================================

if (A_ScriptFullPath = A_LineFile) {
    try FileDelete(FR_TestLogPath)
    result := RunFlightRecorderTests()
    ExitApp(result ? 0 : 1)
}
