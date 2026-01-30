; Unit Tests - Advanced Scenarios
; Defensive Close, Stale File Cleanup, Update Race Guard, Shortcut Conflict, Mismatch Dialog
; Included by test_unit.ahk

RunUnitTests_Advanced() {
    global TestPassed, TestErrors, cfg

    ; ============================================================
    ; Defensive Close Before Reconnect Tests
    ; ============================================================
    Log("`n--- Defensive Close Tests ---")

    ; Test 1: GUI has defensive close before reconnect
    Log("Testing GUI has defensive IPC close before reconnect...")
    try {
        guiPath := A_ScriptDir "\..\src\gui\gui_main.ahk"
        if (FileExist(guiPath)) {
            guiCode := FileRead(guiPath)

            ; Look for the pattern of checking and closing before reconnect
            hasDefensiveClose := InStr(guiCode, "IPC_PipeClient_Close(gGUI_StoreClient)")

            if (hasDefensiveClose) {
                Log("PASS: GUI has defensive IPC_PipeClient_Close before reconnect")
                TestPassed++
            } else {
                Log("FAIL: GUI should have defensive close before reconnect")
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find gui_main.ahk for code inspection")
        }
    } catch as e {
        Log("FAIL: Defensive close check error: " e.Message)
        TestErrors++
    }

    ; Test 2: IPC_PipeClient_Close is idempotent
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

    ; Test 3: IPC_PipeClient_Close handles non-object gracefully
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
    ; Stale File Cleanup Tests (Bug 3 Prevention)
    ; ============================================================
    Log("`n--- Stale File Cleanup Tests ---")

    ; Test: Verify staleFiles array contains all expected temp files
    Log("Testing _Update_CleanupStaleTempFiles() includes all expected files...")
    try {
        setupUtilsPath := A_ScriptDir "\..\src\shared\setup_utils.ahk"
        if (FileExist(setupUtilsPath)) {
            setupCode := FileRead(setupUtilsPath)

            ; Check for all expected stale files in the array
            ; Note: alttabby_admin_toggle.lock is behind TEMP_ADMIN_TOGGLE_LOCK constant
            expectedFiles := [
                "alttabby_wizard.json",
                "alttabby_update.txt",
                "alttabby_install_update.txt",
                "TEMP_ADMIN_TOGGLE_LOCK"
            ]

            allFound := true
            missingFiles := []
            for _, fileName in expectedFiles {
                if (!InStr(setupCode, fileName)) {
                    allFound := false
                    missingFiles.Push(fileName)
                }
            }

            if (allFound) {
                Log("PASS: staleFiles array contains all " expectedFiles.Length " expected temp files")
                TestPassed++
            } else {
                Log("FAIL: staleFiles array missing: " _JoinArray(missingFiles, ", "))
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find setup_utils.ahk")
        }
    } catch as e {
        Log("FAIL: Stale files check error: " e.Message)
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

    ; Test 3: CheckForUpdates function uses the guard (code inspection)
    Log("Testing CheckForUpdates() uses race guard...")
    try {
        setupUtilsPath := A_ScriptDir "\..\src\shared\setup_utils.ahk"
        if (FileExist(setupUtilsPath)) {
            setupCode := FileRead(setupUtilsPath)

            ; Check for guard pattern at start of function
            hasGuardCheck := InStr(setupCode, "if (g_UpdateCheckInProgress)")
            hasGuardSet := InStr(setupCode, "g_UpdateCheckInProgress := true")
            hasGuardReset := InStr(setupCode, "g_UpdateCheckInProgress := false")

            if (hasGuardCheck && hasGuardSet && hasGuardReset) {
                Log("PASS: CheckForUpdates() has race guard (check, set, and reset)")
                TestPassed++
            } else {
                Log("FAIL: CheckForUpdates() missing guard logic (check=" hasGuardCheck ", set=" hasGuardSet ", reset=" hasGuardReset ")")
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find setup_utils.ahk")
        }
    } catch as e {
        Log("FAIL: Update race guard code check error: " e.Message)
        TestErrors++
    }

    ; ============================================================
    ; Shortcut Conflict Detection Tests (Bug 5 Prevention)
    ; ============================================================
    Log("`n--- Shortcut Conflict Detection Tests ---")

    ; Test: _CreateShortcutForCurrentMode has conflict detection
    Log("Testing _CreateShortcutForCurrentMode() has conflict detection...")
    try {
        shortcutsPath := A_ScriptDir "\..\src\launcher\launcher_shortcuts.ahk"
        if (FileExist(shortcutsPath)) {
            shortcutsCode := FileRead(shortcutsPath)

            ; Check for conflict detection pattern
            hasExistingCheck := InStr(shortcutsCode, "if (FileExist(lnkPath))")
            hasTargetCompare := InStr(shortcutsCode, "existingTarget") || InStr(shortcutsCode, "existing.TargetPath")
            hasConflictDialog := InStr(shortcutsCode, "Shortcut Conflict")

            if (hasExistingCheck && hasTargetCompare && hasConflictDialog) {
                Log("PASS: _CreateShortcutForCurrentMode() has conflict detection")
                TestPassed++
            } else {
                Log("FAIL: _CreateShortcutForCurrentMode() missing conflict detection (exists=" hasExistingCheck ", compare=" hasTargetCompare ", dialog=" hasConflictDialog ")")
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find launcher_shortcuts.ahk")
        }
    } catch as e {
        Log("FAIL: Shortcut conflict detection check error: " e.Message)
        TestErrors++
    }

    ; ============================================================
    ; Mismatch Dialog Tests (Bug 6 Prevention)
    ; ============================================================
    Log("`n--- Mismatch Dialog Tests ---")

    ; Test 1: _Launcher_ShowMismatchDialog accepts optional parameters
    Log("Testing _Launcher_ShowMismatchDialog() accepts optional parameters...")
    try {
        installPath := A_ScriptDir "\..\src\launcher\launcher_install.ahk"
        if (FileExist(installPath)) {
            installCode := FileRead(installPath)

            ; Check for optional parameters in function signature
            hasOptionalParams := InStr(installCode, '_Launcher_ShowMismatchDialog(installedPath, title := "", message := "", question := "")')

            if (hasOptionalParams) {
                Log("PASS: _Launcher_ShowMismatchDialog() accepts optional title/message/question params")
                TestPassed++
            } else {
                Log("FAIL: _Launcher_ShowMismatchDialog() should accept optional parameters")
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find launcher_install.ahk")
        }
    } catch as e {
        Log("FAIL: Mismatch dialog params check error: " e.Message)
        TestErrors++
    }

    ; Test 2: _Launcher_HandleMismatchResult function exists
    Log("Testing _Launcher_HandleMismatchResult() function exists...")
    try {
        installPath := A_ScriptDir "\..\src\launcher\launcher_install.ahk"
        if (FileExist(installPath)) {
            installCode := FileRead(installPath)

            hasHandler := InStr(installCode, "_Launcher_HandleMismatchResult(")
            handlesYes := InStr(installCode, 'if (result = "Yes")')
            handlesAlways := InStr(installCode, 'if (result = "Always")') || InStr(installCode, 'else if (result = "Always")')

            if (hasHandler && handlesYes && handlesAlways) {
                Log("PASS: _Launcher_HandleMismatchResult() exists and handles Yes/Always results")
                TestPassed++
            } else {
                Log("FAIL: _Launcher_HandleMismatchResult() missing or incomplete (exists=" hasHandler ", yes=" handlesYes ", always=" handlesAlways ")")
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find launcher_install.ahk")
        }
    } catch as e {
        Log("FAIL: Mismatch result handler check error: " e.Message)
        TestErrors++
    }

    ; Test 3: Same-version case has distinct handling
    Log("Testing same-version mismatch has distinct dialog...")
    try {
        installPath := A_ScriptDir "\..\src\launcher\launcher_install.ahk"
        if (FileExist(installPath)) {
            installCode := FileRead(installPath)

            ; Check for separate handling of versionCompare = 0
            hasSameVersionCase := InStr(installCode, "else if (versionCompare = 0)")
            hasSameVersionMsg := InStr(installCode, "Same Version") || InStr(installCode, "same version")

            if (hasSameVersionCase && hasSameVersionMsg) {
                Log("PASS: Same-version mismatch has distinct case with clear message")
                TestPassed++
            } else {
                Log("FAIL: Same-version should have distinct handling (case=" hasSameVersionCase ", msg=" hasSameVersionMsg ")")
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find launcher_install.ahk")
        }
    } catch as e {
        Log("FAIL: Same-version mismatch check error: " e.Message)
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
}
