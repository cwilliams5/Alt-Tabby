; Unit Tests - Setup & Installation
; Version, Task Scheduler, Shortcuts, Setup Config, PE Validation, Temp Detection, Exe Dedup, DateDiff
; Included by test_unit.ahk

RunUnitTests_Setup() {
    global TestPassed, TestErrors, gConfigRegistry, cfg

    ; ============================================================
    ; Version Management Tests
    ; ============================================================
    Log("`n--- Version Management Tests ---")

    ; Test CompareVersions function
    Log("Testing CompareVersions()...")

    ; Test: newer version is greater
    result := CompareVersions("0.4.0", "0.3.2")
    if (result = 1) {
        Log("PASS: CompareVersions('0.4.0', '0.3.2') = 1 (newer is greater)")
        TestPassed++
    } else {
        Log("FAIL: CompareVersions('0.4.0', '0.3.2') should be 1, got " result)
        TestErrors++
    }

    ; Test: older version is less
    result := CompareVersions("0.3.2", "0.4.0")
    if (result = -1) {
        Log("PASS: CompareVersions('0.3.2', '0.4.0') = -1 (older is less)")
        TestPassed++
    } else {
        Log("FAIL: CompareVersions('0.3.2', '0.4.0') should be -1, got " result)
        TestErrors++
    }

    ; Test: equal versions
    result := CompareVersions("1.0.0", "1.0.0")
    if (result = 0) {
        Log("PASS: CompareVersions('1.0.0', '1.0.0') = 0 (equal)")
        TestPassed++
    } else {
        Log("FAIL: CompareVersions('1.0.0', '1.0.0') should be 0, got " result)
        TestErrors++
    }

    ; Test: shorter version string
    result := CompareVersions("1.2", "1.2.0")
    if (result = 0) {
        Log("PASS: CompareVersions('1.2', '1.2.0') = 0 (missing patch = 0)")
        TestPassed++
    } else {
        Log("FAIL: CompareVersions('1.2', '1.2.0') should be 0, got " result)
        TestErrors++
    }

    ; Test: major version difference
    result := CompareVersions("2.0.0", "1.9.9")
    if (result = 1) {
        Log("PASS: CompareVersions('2.0.0', '1.9.9') = 1 (major version wins)")
        TestPassed++
    } else {
        Log("FAIL: CompareVersions('2.0.0', '1.9.9') should be 1, got " result)
        TestErrors++
    }

    ; Test: pre-release suffix stripped
    result := CompareVersions("1.0.0-beta", "1.0.0")
    if (result = 0) {
        Log("PASS: CompareVersions('1.0.0-beta', '1.0.0') = 0 (pre-release stripped)")
        TestPassed++
    } else {
        Log("FAIL: CompareVersions('1.0.0-beta', '1.0.0') should be 0, got " result)
        TestErrors++
    }

    ; Test: leading v stripped
    result := CompareVersions("v1.0.0", "1.0.0")
    if (result = 0) {
        Log("PASS: CompareVersions('v1.0.0', '1.0.0') = 0 (leading v stripped)")
        TestPassed++
    } else {
        Log("FAIL: CompareVersions('v1.0.0', '1.0.0') should be 0, got " result)
        TestErrors++
    }

    ; Test: major only newer
    result := CompareVersions("2", "1.5.0")
    if (result = 1) {
        Log("PASS: CompareVersions('2', '1.5.0') = 1 (major only newer)")
        TestPassed++
    } else {
        Log("FAIL: CompareVersions('2', '1.5.0') should be 1, got " result)
        TestErrors++
    }

    ; Test: both pre-release stripped equal
    result := CompareVersions("1.0.0-rc1", "1.0.0-beta")
    if (result = 0) {
        Log("PASS: CompareVersions('1.0.0-rc1', '1.0.0-beta') = 0 (both pre-release stripped)")
        TestPassed++
    } else {
        Log("FAIL: CompareVersions('1.0.0-rc1', '1.0.0-beta') should be 0, got " result)
        TestErrors++
    }

    ; Test: GetAppVersion returns non-empty string
    Log("Testing GetAppVersion()...")
    version := GetAppVersion()
    if (version != "" && RegExMatch(version, "^\d+\.\d+")) {
        Log("PASS: GetAppVersion() returned valid version: " version)
        TestPassed++
    } else {
        Log("FAIL: GetAppVersion() should return version string, got: " version)
        TestErrors++
    }

    ; Test: _Update_FindExeDownloadUrl parses GitHub API response
    Log("Testing _Update_FindExeDownloadUrl()...")

    ; Sample GitHub API response (simplified but realistic)
    sampleResponse := '{"tag_name":"v0.5.0","assets":[{"name":"AltTabby.exe","browser_download_url":"https://github.com/cwilliams5/Alt-Tabby/releases/download/v0.5.0/AltTabby.exe"}]}'
    url := _Update_FindExeDownloadUrl(sampleResponse)
    expectedUrl := "https://github.com/cwilliams5/Alt-Tabby/releases/download/v0.5.0/AltTabby.exe"
    if (url = expectedUrl) {
        Log("PASS: _Update_FindExeDownloadUrl() found correct URL")
        TestPassed++
    } else {
        Log("FAIL: _Update_FindExeDownloadUrl() should return '" expectedUrl "', got: '" url "'")
        TestErrors++
    }

    ; Test: _Update_FindExeDownloadUrl handles response with no exe
    sampleNoExe := '{"tag_name":"v0.5.0","assets":[{"name":"readme.txt","browser_download_url":"https://example.com/readme.txt"}]}'
    url := _Update_FindExeDownloadUrl(sampleNoExe)
    if (url = "") {
        Log("PASS: _Update_FindExeDownloadUrl() returns empty for no exe")
        TestPassed++
    } else {
        Log("FAIL: _Update_FindExeDownloadUrl() should return empty for no exe, got: '" url "'")
        TestErrors++
    }

    ; Test: tag_name regex handles both "v0.5.0" and "0.5.0" formats
    Log("Testing tag_name parsing...")
    responseWithV := '{"tag_name":"v0.5.0","other":"data"}'
    responseWithoutV := '{"tag_name":"0.5.0","other":"data"}'

    ; Test with 'v' prefix
    if (RegExMatch(responseWithV, '"tag_name"\s*:\s*"v?([^"]+)"', &match1) && match1[1] = "0.5.0") {
        Log("PASS: tag_name regex extracts '0.5.0' from 'v0.5.0'")
        TestPassed++
    } else {
        Log("FAIL: tag_name regex should extract '0.5.0' from 'v0.5.0'")
        TestErrors++
    }

    ; Test without 'v' prefix
    if (RegExMatch(responseWithoutV, '"tag_name"\s*:\s*"v?([^"]+)"', &match2) && match2[1] = "0.5.0") {
        Log("PASS: tag_name regex extracts '0.5.0' from '0.5.0'")
        TestPassed++
    } else {
        Log("FAIL: tag_name regex should extract '0.5.0' from '0.5.0'")
        TestErrors++
    }

    ; ============================================================
    ; Task Scheduler Function Tests
    ; ============================================================
    Log("`n--- Task Scheduler Function Tests ---")

    ; Test AdminTaskExists - should not fail even if task doesn't exist
    Log("Testing AdminTaskExists()...")
    try {
        taskExists := AdminTaskExists()
        Log("PASS: AdminTaskExists() returned " (taskExists ? "true" : "false") " without error")
        TestPassed++
    } catch as e {
        Log("FAIL: AdminTaskExists() threw error: " e.Message)
        TestErrors++
    }

    ; Test CreateAdminTask and DeleteAdminTask (only if admin)
    ; These tests are conditional - they need admin privileges
    ; IMPORTANT: Uses a test-specific task name to avoid destroying the production
    ; "Alt-Tabby" scheduled task (which provides admin mode for installed versions)
    if (A_IsAdmin) {
        Log("Running admin-level Task Scheduler tests...")

        testTaskName := "Alt-Tabby Test"
        testTaskExePath := A_WinDir "\notepad.exe"  ; Safe exe to use for testing

        ; Clean up any leftover test task from previous runs
        DeleteAdminTask(testTaskName)

        ; Test CreateAdminTask
        Log("Testing CreateAdminTask()...")
        createResult := CreateAdminTask(testTaskExePath, "", testTaskName)
        if (createResult) {
            Log("PASS: CreateAdminTask() succeeded")
            TestPassed++

            ; Verify task exists
            if (AdminTaskExists(testTaskName)) {
                Log("PASS: Task verified to exist after creation")
                TestPassed++
            } else {
                Log("FAIL: AdminTaskExists() returned false after CreateAdminTask()")
                TestErrors++
            }

            ; Test DeleteAdminTask
            Log("Testing DeleteAdminTask()...")
            deleteResult := DeleteAdminTask(testTaskName)
            if (deleteResult) {
                Log("PASS: DeleteAdminTask() succeeded")
                TestPassed++

                ; Verify task no longer exists
                if (!AdminTaskExists(testTaskName)) {
                    Log("PASS: Task verified to not exist after deletion")
                    TestPassed++
                } else {
                    Log("FAIL: AdminTaskExists() returned true after DeleteAdminTask()")
                    TestErrors++
                }
            } else {
                Log("FAIL: DeleteAdminTask() returned false")
                TestErrors++
            }
        } else {
            Log("FAIL: CreateAdminTask() returned false")
            TestErrors++
        }
    } else {
        Log("SKIP: Task Scheduler create/delete tests require admin privileges")
        Log("  Run tests as administrator to test CreateAdminTask/DeleteAdminTask")
    }

    ; ============================================================
    ; Shortcut Helper Function Tests
    ; ============================================================
    Log("`n--- Shortcut Helper Function Tests ---")

    ; Test _Shortcut_GetStartMenuPath
    Log("Testing _Shortcut_GetStartMenuPath()...")
    startMenuPath := _Shortcut_GetStartMenuPath()
    if (InStr(startMenuPath, "Start Menu") && InStr(startMenuPath, "Alt-Tabby.lnk")) {
        Log("PASS: _Shortcut_GetStartMenuPath() returned valid path: " startMenuPath)
        TestPassed++
    } else {
        Log("FAIL: _Shortcut_GetStartMenuPath() returned unexpected path: " startMenuPath)
        TestErrors++
    }

    ; Test _Shortcut_GetStartupPath
    Log("Testing _Shortcut_GetStartupPath()...")
    startupPath := _Shortcut_GetStartupPath()
    if (InStr(startupPath, "Startup") && InStr(startupPath, "Alt-Tabby.lnk")) {
        Log("PASS: _Shortcut_GetStartupPath() returned valid path: " startupPath)
        TestPassed++
    } else {
        Log("FAIL: _Shortcut_GetStartupPath() returned unexpected path: " startupPath)
        TestErrors++
    }

    ; Test _Shortcut_GetIconPath
    ; In dev mode: returns path to icon.ico file
    ; In compiled mode: returns effective exe path (icon is embedded)
    Log("Testing _Shortcut_GetIconPath()...")
    iconPath := _Shortcut_GetIconPath()
    if (A_IsCompiled) {
        ; Compiled: should return effective exe path (same as shortcut target)
        effectiveExe := _Shortcut_GetEffectiveExePath()
        if (iconPath = effectiveExe) {
            Log("PASS: _Shortcut_GetIconPath() returns effective exe path (compiled): " iconPath)
            TestPassed++
        } else {
            Log("FAIL: _Shortcut_GetIconPath() should match effective exe path. Got: " iconPath " Expected: " effectiveExe)
            TestErrors++
        }
    } else {
        ; Dev mode: should return icon.ico path
        if (InStr(iconPath, "icon.ico")) {
            Log("PASS: _Shortcut_GetIconPath() returned icon path: " iconPath)
            TestPassed++
        } else {
            Log("FAIL: _Shortcut_GetIconPath() returned unexpected path: " iconPath)
            TestErrors++
        }
    }

    ; Test _Shortcut_GetEffectiveExePath
    Log("Testing _Shortcut_GetEffectiveExePath()...")
    effectivePath := _Shortcut_GetEffectiveExePath()
    if (effectivePath != "") {
        Log("PASS: _Shortcut_GetEffectiveExePath() returned: " effectivePath)
        TestPassed++
    } else {
        Log("FAIL: _Shortcut_GetEffectiveExePath() returned empty string")
        TestErrors++
    }

    ; ============================================================
    ; Setup Config Tests
    ; ============================================================
    Log("`n--- Setup Config Tests ---")

    ; Test that new setup config options exist in registry
    Log("Testing Setup config options in registry...")
    setupConfigsFound := 0
    requiredSetupConfigs := ["SetupExePath", "SetupRunAsAdmin", "SetupAutoUpdateCheck", "SetupFirstRunCompleted"]

    for _, entry in gConfigRegistry {
        if (!entry.HasOwnProp("g"))
            continue
        for _, reqConfig in requiredSetupConfigs {
            if (entry.g = reqConfig) {
                setupConfigsFound++
                break
            }
        }
    }

    if (setupConfigsFound = requiredSetupConfigs.Length) {
        Log("PASS: All " setupConfigsFound " Setup config options found in registry")
        TestPassed++
    } else {
        Log("FAIL: Only " setupConfigsFound "/" requiredSetupConfigs.Length " Setup config options found in registry")
        TestErrors++
    }

    ; Test that cfg object has setup properties after init
    Log("Testing cfg object has Setup properties...")
    setupPropsOk := true
    missingProps := []

    if (!cfg.HasOwnProp("SetupExePath")) {
        missingProps.Push("SetupExePath")
        setupPropsOk := false
    }
    if (!cfg.HasOwnProp("SetupRunAsAdmin")) {
        missingProps.Push("SetupRunAsAdmin")
        setupPropsOk := false
    }
    if (!cfg.HasOwnProp("SetupAutoUpdateCheck")) {
        missingProps.Push("SetupAutoUpdateCheck")
        setupPropsOk := false
    }
    if (!cfg.HasOwnProp("SetupFirstRunCompleted")) {
        missingProps.Push("SetupFirstRunCompleted")
        setupPropsOk := false
    }

    if (setupPropsOk) {
        Log("PASS: cfg object has all Setup properties")
        TestPassed++
    } else {
        Log("FAIL: cfg object missing Setup properties: " _JoinArray(missingProps, ", "))
        TestErrors++
    }

    ; ============================================================
    ; PE Validation Tests (Bug #4 fix)
    ; ============================================================
    Log("`n--- PE Validation Tests ---")

    ; Test with valid PE (notepad.exe)
    Log("Testing _Update_ValidatePEFile with valid PE (notepad.exe)...")
    notepadPath := A_WinDir "\notepad.exe"
    if (FileExist(notepadPath)) {
        if (_Update_ValidatePEFile(notepadPath)) {
            Log("PASS: notepad.exe validated as valid PE")
            TestPassed++
        } else {
            Log("FAIL: notepad.exe should be valid PE")
            TestErrors++
        }
    } else {
        Log("SKIP: notepad.exe not found")
    }

    ; Test with file too small (create temp file)
    Log("Testing _Update_ValidatePEFile rejects small files...")
    smallFile := A_Temp "\test_small_pe.tmp"
    try FileDelete(smallFile)
    try {
        ; Create small file with MZ header but under 100KB
        f := FileOpen(smallFile, "w")
        f.Write("MZ" . _RepeatStr("x", 100))  ; ~102 bytes, under 100KB
        f.Close()
        if (!_Update_ValidatePEFile(smallFile)) {
            Log("PASS: Small file (<100KB) rejected")
            TestPassed++
        } else {
            Log("FAIL: Small file should be rejected")
            TestErrors++
        }
    } catch as e {
        Log("SKIP: Could not create test file: " e.Message)
    }
    try FileDelete(smallFile)

    ; Test with invalid MZ magic (but valid size)
    Log("Testing _Update_ValidatePEFile rejects invalid MZ magic...")
    invalidMZ := A_Temp "\test_invalid_mz.tmp"
    try FileDelete(invalidMZ)
    try {
        ; Create 200KB file without MZ header
        f := FileOpen(invalidMZ, "w")
        f.Write(_RepeatStr("X", 204800))
        f.Close()
        if (!_Update_ValidatePEFile(invalidMZ)) {
            Log("PASS: File without MZ magic rejected")
            TestPassed++
        } else {
            Log("FAIL: File without MZ magic should be rejected")
            TestErrors++
        }
    } catch as e {
        Log("SKIP: Could not create test file: " e.Message)
    }
    try FileDelete(invalidMZ)

    ; ============================================================
    ; Temporary Location Detection Tests (Bug #5 fix)
    ; ============================================================
    Log("`n--- Temporary Location Detection Tests ---")

    ; Test paths that should be detected as temporary
    tempPaths := [
        "C:\Users\test\Downloads\AltTabby.exe",
        "C:\Users\test\Desktop\AltTabby.exe",
        "C:\Users\test\AppData\Local\Temp\AltTabby.exe",
        "D:\temp\subfolder\AltTabby.exe"
    ]

    for _, testPath in tempPaths {
        lowerPath := StrLower(testPath)
        isTemp := (InStr(lowerPath, "\downloads")
            || InStr(lowerPath, "\temp")
            || InStr(lowerPath, "\desktop")
            || InStr(lowerPath, "\appdata\local\temp"))
        if (isTemp) {
            Log("PASS: '" testPath "' detected as temporary")
            TestPassed++
        } else {
            Log("FAIL: '" testPath "' should be detected as temporary")
            TestErrors++
        }
    }

    ; Test paths that should NOT be detected as temporary
    nonTempPaths := [
        "C:\Program Files\Alt-Tabby\AltTabby.exe",
        "C:\Apps\AltTabby.exe",
        "D:\Tools\AltTabby.exe"
    ]

    for _, testPath in nonTempPaths {
        lowerPath := StrLower(testPath)
        isTemp := (InStr(lowerPath, "\downloads")
            || InStr(lowerPath, "\temp")
            || InStr(lowerPath, "\desktop")
            || InStr(lowerPath, "\appdata\local\temp"))
        if (!isTemp) {
            Log("PASS: '" testPath "' not detected as temporary")
            TestPassed++
        } else {
            Log("FAIL: '" testPath "' should NOT be detected as temporary")
            TestErrors++
        }
    }

    ; ============================================================
    ; Exe Name Deduplication Tests (Bug #1 fix)
    ; ============================================================
    Log("`n--- Exe Name Deduplication Tests ---")

    ; Test case-insensitive deduplication logic
    Log("Testing exe name deduplication (case-insensitive)...")
    testNames := []
    seenNames := Map()

    ; Simulate adding names like _Update_KillOtherProcesses does
    namesToAdd := ["AltTabby.exe", "alttabby.exe", "ALTTABBY.EXE", "OtherApp.exe"]
    for _, name in namesToAdd {
        lowerName := StrLower(name)
        if (!seenNames.Has(lowerName)) {
            testNames.Push(name)
            seenNames[lowerName] := true
        }
    }

    if (testNames.Length = 2) {  ; Should have AltTabby.exe and OtherApp.exe
        Log("PASS: Deduplication reduced 4 names to 2 unique names")
        TestPassed++
    } else {
        Log("FAIL: Expected 2 unique names, got " testNames.Length)
        TestErrors++
    }

    ; ============================================================
    ; DateDiff Cooldown Tests (Bug #6 fix)
    ; ============================================================
    Log("`n--- DateDiff Cooldown Tests ---")

    ; Test DateDiff with timestamps
    Log("Testing DateDiff for 24-hour cooldown logic...")

    ; Current time
    nowTime := A_Now

    ; 12 hours ago (should be within cooldown)
    time12hAgo := DateAdd(nowTime, -12, "Hours")
    hours12 := DateDiff(nowTime, time12hAgo, "Hours")
    if (hours12 >= 11 && hours12 <= 13) {  ; Allow some tolerance
        Log("PASS: DateDiff correctly calculated ~12 hours difference: " hours12)
        TestPassed++
    } else {
        Log("FAIL: DateDiff returned " hours12 " hours, expected ~12")
        TestErrors++
    }

    ; 36 hours ago (should be outside cooldown)
    time36hAgo := DateAdd(nowTime, -36, "Hours")
    hours36 := DateDiff(nowTime, time36hAgo, "Hours")
    if (hours36 >= 35 && hours36 <= 37) {
        Log("PASS: DateDiff correctly calculated ~36 hours difference: " hours36)
        TestPassed++
    } else {
        Log("FAIL: DateDiff returned " hours36 " hours, expected ~36")
        TestErrors++
    }

    ; Test cooldown logic
    if (hours12 < 24) {
        Log("PASS: 12 hours ago is within 24h cooldown")
        TestPassed++
    } else {
        Log("FAIL: 12 hours should be within 24h cooldown")
        TestErrors++
    }

    if (hours36 >= 24) {
        Log("PASS: 36 hours ago is outside 24h cooldown")
        TestPassed++
    } else {
        Log("FAIL: 36 hours should be outside 24h cooldown")
        TestErrors++
    }
}
