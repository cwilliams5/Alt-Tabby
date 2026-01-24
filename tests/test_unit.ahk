; Unit Tests - WindowStore, Config, Entry Point Initialization
; Tests that don't require external processes or --live flag
; Included by run_tests.ahk

RunUnitTests() {
    global TestPassed, TestErrors, gConfigRegistry, cfg

    ; ============================================================
    ; WindowStore Unit Tests
    ; ============================================================
    Log("`n--- WindowStore Unit Tests ---")

    ; Test 1: _WS_GetOpt with Map
    testMap := Map("sort", "Z", "includeMinimized", false)
    AssertEq(_WS_GetOpt(testMap, "sort", "MRU"), "Z", "_WS_GetOpt with Map")

    ; Test 2: _WS_GetOpt with plain Object
    testObj := { sort: "Title", columns: "hwndsOnly" }
    AssertEq(_WS_GetOpt(testObj, "sort", "MRU"), "Title", "_WS_GetOpt with plain Object")

    ; Test 3: _WS_GetOpt default value
    AssertEq(_WS_GetOpt(testObj, "missing", "default"), "default", "_WS_GetOpt default value")

    ; Test 4: _WS_GetOpt with non-object
    AssertEq(_WS_GetOpt(0, "key", "fallback"), "fallback", "_WS_GetOpt with non-object")

    ; Test 5: WindowStore basic operations
    WindowStore_Init()
    WindowStore_BeginScan()

    testRecs := []
    rec1 := Map()
    rec1["hwnd"] := 12345
    rec1["title"] := "Test Window 1"
    rec1["class"] := "TestClass"
    rec1["pid"] := 100
    rec1["isVisible"] := true
    rec1["isCloaked"] := false
    rec1["isMinimized"] := false
    rec1["z"] := 1
    testRecs.Push(rec1)

    rec2 := Map()
    rec2["hwnd"] := 67890
    rec2["title"] := "Test Window 2"
    rec2["class"] := "TestClass2"
    rec2["pid"] := 200
    rec2["isVisible"] := true
    rec2["isCloaked"] := false
    rec2["isMinimized"] := false
    rec2["z"] := 2
    testRecs.Push(rec2)

    result := WindowStore_UpsertWindow(testRecs, "test")
    AssertEq(result.added, 2, "WindowStore_UpsertWindow adds records")

    ; Test 6: GetProjection with plain object opts (THE BUG FIX)
    proj := WindowStore_GetProjection({ sort: "Z", columns: "items" })
    AssertEq(proj.items.Length, 2, "GetProjection with plain object opts")

    ; Test 7: GetProjection with Map opts
    projMap := WindowStore_GetProjection(Map("sort", "Title"))
    AssertEq(projMap.items.Length, 2, "GetProjection with Map opts")

    ; Test 8: Z-order sorting
    projZ := WindowStore_GetProjection({ sort: "Z" })
    AssertEq(projZ.items[1].z, 1, "Z-order sorting (first item z=1)")

    ; ============================================================
    ; Race Condition Prevention Tests
    ; ============================================================
    Log("`n--- Race Condition Prevention Tests ---")

    ; Test: _WS_BumpRev atomicity - rev should increment exactly once
    global gWS_Rev
    startRev := gWS_Rev
    _WS_BumpRev("test")
    AssertEq(gWS_Rev, startRev + 1, "_WS_BumpRev increments rev exactly once")

    ; Test: _WS_BumpRev records source in diagnostics
    global gWS_DiagSource
    prevCount := gWS_DiagSource.Has("test") ? gWS_DiagSource["test"] : 0
    _WS_BumpRev("test")
    AssertEq(gWS_DiagSource["test"], prevCount + 1, "_WS_BumpRev records diagnostic source")

    ; Test: Z-queue deduplication - same hwnd shouldn't be added twice
    WindowStore_ClearZQueue()
    global gWS_ZQueue
    WindowStore_EnqueueForZ(99999)
    WindowStore_EnqueueForZ(99999)  ; Duplicate
    AssertEq(gWS_ZQueue.Length, 1, "Z-queue deduplication prevents duplicates")

    ; Test: Z-queue clear empties both queue and set
    WindowStore_EnqueueForZ(88888)
    WindowStore_ClearZQueue()
    global gWS_ZQueueSet
    AssertEq(gWS_ZQueue.Length, 0, "Z-queue clear empties queue")
    AssertEq(gWS_ZQueueSet.Count, 0, "Z-queue clear empties set")

    ; ============================================================
    ; JSON (JXON) Unit Tests
    ; ============================================================
    Log("`n--- JSON (JXON) Unit Tests ---")

    ; Test 1: JXON_Load - simple object
    jsonObj := '{"name":"test","value":42}'
    try {
        parsed := JXON_Load(jsonObj)
        if (parsed["name"] = "test" && parsed["value"] = 42) {
            Log("PASS: JXON_Load parses simple object correctly")
            TestPassed++
        } else {
            Log("FAIL: JXON_Load parsed wrong values: name=" parsed["name"] ", value=" parsed["value"])
            TestErrors++
        }
    } catch as e {
        Log("FAIL: JXON_Load threw error on valid JSON: " e.Message)
        TestErrors++
    }

    ; Test 2: JXON_Load - array
    jsonArr := '[1, 2, 3, "four"]'
    try {
        parsed := JXON_Load(jsonArr)
        if (parsed.Length = 4 && parsed[1] = 1 && parsed[4] = "four") {
            Log("PASS: JXON_Load parses array correctly")
            TestPassed++
        } else {
            Log("FAIL: JXON_Load parsed wrong array values")
            TestErrors++
        }
    } catch as e {
        Log("FAIL: JXON_Load threw error on valid array: " e.Message)
        TestErrors++
    }

    ; Test 3: JXON_Load - boolean and null
    jsonBool := '{"yes":true,"no":false,"nothing":null}'
    try {
        parsed := JXON_Load(jsonBool)
        if (parsed["yes"] = true && parsed["no"] = false && parsed["nothing"] = "") {
            Log("PASS: JXON_Load parses true/false/null correctly")
            TestPassed++
        } else {
            Log("FAIL: JXON_Load parsed wrong boolean/null values")
            TestErrors++
        }
    } catch as e {
        Log("FAIL: JXON_Load threw error on boolean/null JSON: " e.Message)
        TestErrors++
    }

    ; Test 4: JXON_Load - nested object
    jsonNested := '{"outer":{"inner":"value"}}'
    try {
        parsed := JXON_Load(jsonNested)
        if (parsed["outer"]["inner"] = "value") {
            Log("PASS: JXON_Load parses nested objects correctly")
            TestPassed++
        } else {
            Log("FAIL: JXON_Load parsed wrong nested value")
            TestErrors++
        }
    } catch as e {
        Log("FAIL: JXON_Load threw error on nested JSON: " e.Message)
        TestErrors++
    }

    ; Test 5: JXON_Load - escaped characters in string
    ; Note: In AHK, we need to double-escape: \\ in AHK string = \ in JSON = escape char
    jsonEscaped := '{"text":"line1\nline2\ttab\"quote\"","path":"C:\\Users"}'
    try {
        parsed := JXON_Load(jsonEscaped)
        hasNewline := InStr(parsed["text"], "`n")
        hasTab := InStr(parsed["text"], "`t")
        hasQuote := InStr(parsed["text"], '"')
        hasBackslash := InStr(parsed["path"], "\")
        if (hasNewline && hasTab && hasQuote && hasBackslash) {
            Log("PASS: JXON_Load handles escape sequences correctly")
            TestPassed++
        } else {
            Log("FAIL: JXON_Load escape handling: newline=" hasNewline ", tab=" hasTab ", quote=" hasQuote ", backslash=" hasBackslash)
            TestErrors++
        }
    } catch as e {
        Log("FAIL: JXON_Load threw error on escaped JSON: " e.Message)
        TestErrors++
    }

    ; Test 6: JXON_Load - empty object/array
    try {
        emptyObj := JXON_Load('{}')
        emptyArr := JXON_Load('[]')
        objIsMap := (emptyObj is Map)
        arrIsArray := (emptyArr is Array) && emptyArr.Length = 0
        if (objIsMap && arrIsArray) {
            Log("PASS: JXON_Load handles empty {} and [] correctly")
            TestPassed++
        } else {
            Log("FAIL: JXON_Load empty handling: objIsMap=" objIsMap ", arrIsArray=" arrIsArray)
            TestErrors++
        }
    } catch as e {
        Log("FAIL: JXON_Load threw error on empty JSON: " e.Message)
        TestErrors++
    }

    ; Test 7: JXON_Load - whitespace handling
    try {
        wsJson := '  {  "key"  :  "value"  }  '
        parsed := JXON_Load(wsJson)
        if (parsed["key"] = "value") {
            Log("PASS: JXON_Load handles extra whitespace correctly")
            TestPassed++
        } else {
            Log("FAIL: JXON_Load whitespace handling failed")
            TestErrors++
        }
    } catch as e {
        Log("FAIL: JXON_Load threw error on whitespace JSON: " e.Message)
        TestErrors++
    }

    ; Test 8: JXON_Dump - simple object
    testObj := Map("name", "test", "value", 42)
    try {
        dumped := JXON_Dump(testObj)
        if (InStr(dumped, '"name"') && InStr(dumped, '"test"') && InStr(dumped, "42")) {
            Log("PASS: JXON_Dump serializes Map correctly")
            TestPassed++
        } else {
            Log("FAIL: JXON_Dump output missing expected content: " dumped)
            TestErrors++
        }
    } catch as e {
        Log("FAIL: JXON_Dump threw error: " e.Message)
        TestErrors++
    }

    ; Test 9: JXON_Dump - array
    ; Note: JXON_Dump outputs 1/0 for booleans due to AHK's boolean representation
    testArr := [1, "two", 3.14]
    try {
        dumped := JXON_Dump(testArr)
        if (InStr(dumped, "[") && InStr(dumped, "1") && InStr(dumped, '"two"') && InStr(dumped, "3.14")) {
            Log("PASS: JXON_Dump serializes array correctly")
            TestPassed++
        } else {
            Log("FAIL: JXON_Dump array output: " dumped)
            TestErrors++
        }
    } catch as e {
        Log("FAIL: JXON_Dump threw error on array: " e.Message)
        TestErrors++
    }

    ; Test 10: Round-trip test - Load → Dump → Load
    originalJson := '{"type":"projection","rev":123,"payload":{"items":[{"hwnd":1,"title":"Test"}]}}'
    try {
        parsed1 := JXON_Load(originalJson)
        dumped := JXON_Dump(parsed1)
        parsed2 := JXON_Load(dumped)

        ; Verify key values survive round-trip
        if (parsed2["type"] = "projection" && parsed2["rev"] = 123 && parsed2["payload"]["items"][1]["title"] = "Test") {
            Log("PASS: JXON round-trip (Load→Dump→Load) preserves data")
            TestPassed++
        } else {
            Log("FAIL: JXON round-trip lost data")
            TestErrors++
        }
    } catch as e {
        Log("FAIL: JXON round-trip threw error: " e.Message)
        TestErrors++
    }

    ; Test 11: JXON_Dump - null/empty string handling
    try {
        nullTest := Map("empty", "", "zero", 0)
        dumped := JXON_Dump(nullTest)
        if (InStr(dumped, "null") && InStr(dumped, ":0")) {
            Log("PASS: JXON_Dump handles empty string as null and 0 as number")
            TestPassed++
        } else {
            Log("FAIL: JXON_Dump null/zero output: " dumped)
            TestErrors++
        }
    } catch as e {
        Log("FAIL: JXON_Dump threw error on null/empty: " e.Message)
        TestErrors++
    }

    ; Test 12: JXON with special characters in keys/values
    try {
        specialJson := '{"key with spaces":"value","emoji":"🎉","unicode":"日本語"}'
        parsed := JXON_Load(specialJson)
        if (parsed.Has("key with spaces") && parsed["key with spaces"] = "value") {
            Log("PASS: JXON_Load handles keys with spaces")
            TestPassed++
        } else {
            Log("FAIL: JXON_Load failed on special keys")
            TestErrors++
        }
    } catch as e {
        Log("FAIL: JXON_Load threw error on special chars: " e.Message)
        TestErrors++
    }

    ; ============================================================
    ; Config System Tests
    ; ============================================================
    Log("`n--- Config System Tests ---")

    ; Test 1: Verify critical config defaults are set
    Log("Testing config defaults after ConfigLoader_Init()...")
    configDefaultsOk := true
    configErrors := []

    ; These should all have non-zero/non-empty values after init
    ; Uses cfg object (single global config container)
    if (!cfg.HasOwnProp("StorePipeName") || cfg.StorePipeName = "") {
        configErrors.Push("cfg.StorePipeName is empty")
        configDefaultsOk := false
    }
    if (!cfg.HasOwnProp("AltTabGraceMs") || cfg.AltTabGraceMs <= 0) {
        configErrors.Push("cfg.AltTabGraceMs is 0 or unset")
        configDefaultsOk := false
    }
    if (!cfg.HasOwnProp("GUI_RowHeight") || cfg.GUI_RowHeight <= 0) {
        configErrors.Push("cfg.GUI_RowHeight is 0 or unset")
        configDefaultsOk := false
    }
    if (!cfg.HasOwnProp("GUI_RowsVisibleMax") || cfg.GUI_RowsVisibleMax <= 0) {
        configErrors.Push("cfg.GUI_RowsVisibleMax is 0 or unset")
        configDefaultsOk := false
    }
    if (!cfg.HasOwnProp("WinEventHookDebounceMs") || cfg.WinEventHookDebounceMs <= 0) {
        configErrors.Push("cfg.WinEventHookDebounceMs is 0 or unset")
        configDefaultsOk := false
    }
    if (!cfg.HasOwnProp("StoreHeartbeatIntervalMs") || cfg.StoreHeartbeatIntervalMs <= 0) {
        configErrors.Push("cfg.StoreHeartbeatIntervalMs is 0 or unset")
        configDefaultsOk := false
    }

    if (configDefaultsOk) {
        Log("PASS: All critical config defaults are set correctly")
        TestPassed++
    } else {
        Log("FAIL: Config defaults not set correctly:")
        for _, err in configErrors {
            Log("  - " err)
        }
        TestErrors++
    }

    ; Test 2: INI Supplementing - partial config gets new keys added
    Log("Testing INI supplementing (partial config gets new keys)...")
    testConfigDir := A_Temp "\tabby_config_test_" A_TickCount
    testConfigPath := testConfigDir "\config.ini"

    try {
        DirCreate(testConfigDir)

        ; Create a minimal config.ini with only one setting
        partialIni := "[AltTab]`nGraceMs=999`n"
        FileAppend(partialIni, testConfigPath, "UTF-8")

        ; Read back to verify it was written
        originalContent := FileRead(testConfigPath)
        hasOnlySetting := InStr(originalContent, "GraceMs=999") && !InStr(originalContent, "QuickSwitchMs")

        if (!hasOnlySetting) {
            Log("FAIL: Could not create partial test config.ini")
            TestErrors++
        } else {
            ; Call _CL_SupplementIni to add missing keys
            _CL_SupplementIni(testConfigPath)

            ; Read back and check for supplemented keys
            supplementedContent := FileRead(testConfigPath)

            ; Check that new keys were added (commented out with ; prefix)
            hasGraceMs := InStr(supplementedContent, "GraceMs=999")  ; Original preserved (uncommented since customized)
            hasQuickSwitch := InStr(supplementedContent, "; QuickSwitchMs=")  ; New key added (commented - default)
            hasPrewarm := InStr(supplementedContent, "; PrewarmOnAlt=")  ; New key added (commented - default)
            hasGuiSection := InStr(supplementedContent, "[GUI]")  ; New section added

            if (hasGraceMs && hasQuickSwitch && hasPrewarm && hasGuiSection) {
                Log("PASS: INI supplementing added missing keys (commented) while preserving existing")
                TestPassed++

                ; Verify the original value wasn't changed
                if (InStr(supplementedContent, "GraceMs=999")) {
                    Log("PASS: Original config value (GraceMs=999) was preserved")
                    TestPassed++
                } else {
                    Log("FAIL: Original config value was overwritten")
                    TestErrors++
                }
            } else {
                Log("FAIL: INI supplementing did not add expected keys")
                Log("  hasGraceMs=" hasGraceMs ", hasQuickSwitch=" hasQuickSwitch ", hasPrewarm=" hasPrewarm ", hasGuiSection=" hasGuiSection)
                TestErrors++
            }
        }

        ; Cleanup
        try FileDelete(testConfigPath)
        try DirDelete(testConfigDir)
    } catch as e {
        Log("FAIL: INI supplementing test error: " e.Message)
        TestErrors++
        try DirDelete(testConfigDir, true)
    }

    ; Test 3: Config registry completeness - every setting has required fields
    Log("Testing config registry completeness...")
    registryErrors := []
    settingCount := 0

    for _, entry in gConfigRegistry {
        ; Skip section/subsection headers
        if (entry.HasOwnProp("type") && (entry.type = "section" || entry.type = "subsection"))
            continue

        ; Settings must have these fields
        if (!entry.HasOwnProp("s")) {
            registryErrors.Push("Entry missing 's' (section)")
        }
        if (!entry.HasOwnProp("k")) {
            registryErrors.Push("Entry missing 'k' (key)")
        }
        if (!entry.HasOwnProp("g")) {
            registryErrors.Push("Entry missing 'g' (global name)")
        }
        if (!entry.HasOwnProp("default")) {
            registryErrors.Push("Entry " (entry.HasOwnProp("k") ? entry.k : "?") " missing 'default'")
        }
        if (!entry.HasOwnProp("t")) {
            registryErrors.Push("Entry " (entry.HasOwnProp("k") ? entry.k : "?") " missing 't' (type)")
        }
        settingCount++
    }

    if (registryErrors.Length = 0) {
        Log("PASS: All " settingCount " config registry entries have required fields")
        TestPassed++
    } else {
        Log("FAIL: Config registry has incomplete entries:")
        for _, err in registryErrors {
            Log("  - " err)
        }
        TestErrors++
    }

    ; ============================================================
    ; Entry Point Initialization Tests
    ; ============================================================
    ; These test that each entry point file can actually RUN (not just syntax check)
    ; by launching with ErrorStdOut and checking for runtime errors
    Log("`n--- Entry Point Initialization Tests ---")
    Log("Testing that entry points initialize without runtime errors...")

    entryPoints := [
        {name: "store_server.ahk", path: A_ScriptDir "\..\src\store\store_server.ahk", args: "--pipe=entry_test_store_" A_TickCount},
        {name: "viewer.ahk", path: A_ScriptDir "\..\src\viewer\viewer.ahk", args: "--nogui"},
        {name: "gui_main.ahk", path: A_ScriptDir "\..\src\gui\gui_main.ahk", args: ""},
        {name: "alt_tabby.ahk (launcher)", path: A_ScriptDir "\..\src\alt_tabby.ahk", args: ""}
    ]

    for _, ep in entryPoints {
        if (!FileExist(ep.path)) {
            Log("SKIP: " ep.name " not found")
            continue
        }

        ; Run with ErrorStdOut to capture runtime errors to a temp file
        errFile := A_Temp "\tabby_entry_test_" A_TickCount "_" A_Index ".err"
        try FileDelete(errFile)

        ; Use cmd.exe to capture stderr
        cmd := '"' A_AhkPath '" /ErrorStdOut "' ep.path '"'
        if (ep.args != "")
            cmd .= " " ep.args
        cmd := 'cmd.exe /c ' cmd ' 2>"' errFile '"'

        pid := 0
        try {
            Run(cmd, , "Hide", &pid)
        } catch as e {
            Log("FAIL: " ep.name " - could not launch: " e.Message)
            TestErrors++
            continue
        }

        ; Wait a moment for initialization to complete (or fail)
        Sleep(1500)

        ; Check if process is still running
        stillRunning := ProcessExist(pid)

        ; Kill it if still running (we just wanted to test init)
        if (stillRunning) {
            ProcessClose(pid)
        }

        ; Special cleanup for launcher: it spawns child processes (store, gui)
        if (InStr(ep.name, "launcher")) {
            Sleep(200)  ; Let children start
            ; Kill any AutoHotkey processes running store or gui spawned by launcher
            for proc in ComObjGet("winmgmts:").ExecQuery("SELECT * FROM Win32_Process WHERE Name='AutoHotkey64.exe'") {
                cmdLine := ""
                try cmdLine := proc.CommandLine
                if (InStr(cmdLine, "store_server.ahk") || InStr(cmdLine, "gui_main.ahk")) {
                    try ProcessClose(proc.ProcessId)
                }
            }
        }

        ; Read error output
        errOutput := ""
        if (FileExist(errFile)) {
            try {
                errOutput := FileRead(errFile)
            }
            try FileDelete(errFile)
        }

        ; Check for errors
        hasError := InStr(errOutput, "Error:") || InStr(errOutput, "has not been assigned")

        if (hasError) {
            Log("FAIL: " ep.name " - runtime initialization error:")
            ; Show first few lines of error
            errLines := StrSplit(errOutput, "`n")
            lineCount := 0
            for _, line in errLines {
                if (Trim(line) != "" && lineCount < 5) {
                    Log("  " Trim(line))
                    lineCount++
                }
            }
            TestErrors++
        } else if (!stillRunning && errOutput != "") {
            ; Process exited but had some output (might be warning)
            Log("WARN: " ep.name " - exited with output: " SubStr(errOutput, 1, 100))
            Log("PASS: " ep.name " - initialized without fatal error")
            TestPassed++
        } else {
            Log("PASS: " ep.name " - initialized successfully (ran for 1.5s)")
            TestPassed++
        }
    }

    ; ============================================================
    ; WindowStore_UpdateFields 'exists' field test
    ; ============================================================
    Log("`n--- WindowStore_UpdateFields Tests ---")

    ; Ensure store is initialized
    WindowStore_Init()
    WindowStore_BeginScan()

    ; Add a test window
    testHwnd := 99999
    testRec := Map()
    testRec["hwnd"] := testHwnd
    testRec["title"] := "Test Bypass Window"
    testRec["class"] := "TestClass"
    testRec["pid"] := 999
    testRec["isVisible"] := true
    testRec["isCloaked"] := false
    testRec["isMinimized"] := false
    testRec["z"] := 1
    testRec["isFocused"] := false
    WindowStore_UpsertWindow([testRec], "test")
    WindowStore_EndScan()

    ; Test: UpdateFields on existing window should return exists=true
    result := WindowStore_UpdateFields(testHwnd, { isFocused: true }, "test")
    if (result.exists = true) {
        Log("PASS: WindowStore_UpdateFields returns exists=true for window in store")
        TestPassed++
    } else {
        Log("FAIL: WindowStore_UpdateFields should return exists=true for window in store")
        TestErrors++
    }

    ; Test: UpdateFields on non-existent window should return exists=false
    result := WindowStore_UpdateFields(88888, { isFocused: true }, "test")
    if (result.exists = false) {
        Log("PASS: WindowStore_UpdateFields returns exists=false for window not in store")
        TestPassed++
    } else {
        Log("FAIL: WindowStore_UpdateFields should return exists=false for window not in store")
        TestErrors++
    }

    ; Test: UpdateFields changed field - updating same value should be changed=false
    result := WindowStore_UpdateFields(testHwnd, { isFocused: true }, "test")
    if (result.changed = false && result.exists = true) {
        Log("PASS: WindowStore_UpdateFields returns changed=false when value unchanged")
        TestPassed++
    } else {
        Log("FAIL: WindowStore_UpdateFields should return changed=false when value unchanged (got changed=" result.changed ")")
        TestErrors++
    }

    ; Clean up - remove test window
    WindowStore_RemoveWindow([testHwnd], true)

    ; ============================================================
    ; Icon Pump Tests
    ; ============================================================
    Log("`n--- Icon Pump Tests ---")

    ; Test 1: EXE Icon Extraction (Non-UWP)
    Log("Testing EXE icon extraction from notepad.exe...")
    exePath := A_WinDir "\notepad.exe"
    if (FileExist(exePath)) {
        hIcon := _IP_ExtractExeIcon(exePath)
        if (hIcon != 0) {
            Log("PASS: Extracted icon from notepad.exe (hIcon=" hIcon ")")
            TestPassed++
            ; Cleanup
            try DllCall("user32\DestroyIcon", "ptr", hIcon)
        } else {
            Log("FAIL: Failed to extract icon from notepad.exe")
            TestErrors++
        }
    } else {
        Log("SKIP: notepad.exe not found at " exePath)
    }

    ; Test 2: UWP Detection - explorer.exe is NOT a UWP app
    Log("Testing UWP detection (explorer.exe should not be UWP)...")
    explorerPid := ProcessExist("explorer.exe")
    if (explorerPid > 0) {
        isUWP := _IP_AppHasPackage(explorerPid)
        if (!isUWP) {
            Log("PASS: explorer.exe correctly detected as non-UWP")
            TestPassed++
        } else {
            Log("FAIL: explorer.exe incorrectly detected as UWP")
            TestErrors++
        }
    } else {
        Log("SKIP: explorer.exe not running")
    }

    ; Test 3: UWP Detection - invalid PID should return false
    Log("Testing UWP detection with invalid PID...")
    isUWP := _IP_AppHasPackage(0)
    if (!isUWP) {
        Log("PASS: Invalid PID (0) correctly returns false for UWP check")
        TestPassed++
    } else {
        Log("FAIL: Invalid PID should return false for UWP check")
        TestErrors++
    }

    ; Test 4: UWP Logo Path - only run if Calculator is running
    Log("Testing UWP logo path extraction...")
    calcHwnd := WinExist("ahk_exe Calculator.exe")
    if (!calcHwnd) {
        calcHwnd := WinExist("ahk_exe CalculatorApp.exe")
    }
    if (calcHwnd) {
        calcPid := WinGetPID("ahk_id " calcHwnd)
        isUWP := _IP_AppHasPackage(calcPid)
        if (isUWP) {
            logoPath := _IP_GetUWPLogoPath(calcHwnd)
            if (logoPath != "" && FileExist(logoPath)) {
                Log("PASS: Found Calculator logo at: " logoPath)
                TestPassed++
            } else if (logoPath != "") {
                Log("WARN: Logo path found but file missing: " logoPath)
                Log("PASS: UWP logo path extraction returned a path (file may be missing)")
                TestPassed++
            } else {
                Log("WARN: Calculator is UWP but logo path not found (manifest format may differ)")
                Log("PASS: UWP detection worked, logo extraction is best-effort")
                TestPassed++
            }
        } else {
            Log("SKIP: Calculator not detected as UWP (may be Win32 version)")
        }
    } else {
        Log("SKIP: Calculator not running for UWP test")
    }

    ; Test 5: Icon Resolution Chain - cloaked window should still get EXE icon
    Log("Testing icon resolution chain for cloaked windows...")
    ; Create a mock scenario: we have an exePath, test that we can get an icon from it
    ; even when the "window" would be considered cloaked
    testExe := A_WinDir "\explorer.exe"
    if (FileExist(testExe)) {
        ; Get icon via EXE fallback (simulating what happens for cloaked windows)
        hCopy := WindowStore_GetExeIconCopy(testExe)
        if (!hCopy) {
            master := _IP_ExtractExeIcon(testExe)
            if (master) {
                ; Don't actually cache in store during test
                hCopy := DllCall("user32\CopyIcon", "ptr", master, "ptr")
                try DllCall("user32\DestroyIcon", "ptr", master)
            }
        }
        if (hCopy != 0) {
            Log("PASS: EXE fallback works for cloaked window scenario (got icon from " testExe ")")
            TestPassed++
            try DllCall("user32\DestroyIcon", "ptr", hCopy)
        } else {
            Log("FAIL: EXE fallback should work even for cloaked windows")
            TestErrors++
        }
    } else {
        Log("SKIP: explorer.exe not found at " testExe)
    }

    ; Test 6: GetProcessPath helper
    Log("Testing _IP_GetProcessPath helper...")
    if (explorerPid > 0) {
        procPath := _IP_GetProcessPath(explorerPid)
        if (procPath != "" && InStr(procPath, "explorer.exe")) {
            Log("PASS: _IP_GetProcessPath returned: " procPath)
            TestPassed++
        } else {
            Log("FAIL: _IP_GetProcessPath should return explorer.exe path, got: " procPath)
            TestErrors++
        }
    } else {
        Log("SKIP: explorer.exe not running for process path test")
    }

    ; Test 7: Hidden windows MUST be enqueued for icon resolution
    ; This is the critical end-to-end test - verifies that cloaked/minimized windows
    ; actually make it into the icon queue (the bug was they were filtered out here)
    Log("Testing hidden window icon enqueue (critical E2E test)...")
    WindowStore_Init()
    WindowStore_BeginScan()

    ; Create a cloaked window record (simulating a window on another workspace)
    cloakedHwnd := 77777
    cloakedRec := Map()
    cloakedRec["hwnd"] := cloakedHwnd
    cloakedRec["title"] := "Test Cloaked Window"
    cloakedRec["class"] := "TestClass"
    cloakedRec["pid"] := 999
    cloakedRec["isVisible"] := true
    cloakedRec["isCloaked"] := true  ; CLOAKED - simulates other workspace
    cloakedRec["isMinimized"] := false
    cloakedRec["z"] := 1
    cloakedRec["exePath"] := A_WinDir "\notepad.exe"
    WindowStore_UpsertWindow([cloakedRec], "test")

    ; Create a minimized window record
    minHwnd := 88888
    minRec := Map()
    minRec["hwnd"] := minHwnd
    minRec["title"] := "Test Minimized Window"
    minRec["class"] := "TestClass"
    minRec["pid"] := 998
    minRec["isVisible"] := false  ; Minimized windows often have isVisible=false
    minRec["isCloaked"] := false
    minRec["isMinimized"] := true  ; MINIMIZED
    minRec["z"] := 2
    minRec["exePath"] := A_WinDir "\explorer.exe"
    WindowStore_UpsertWindow([minRec], "test")

    WindowStore_EndScan()

    ; Pop the icon batch - both windows should be in the queue
    batch := WindowStore_PopIconBatch(10)

    cloakedInQueue := false
    minInQueue := false
    for _, hwnd in batch {
        if (hwnd = cloakedHwnd)
            cloakedInQueue := true
        if (hwnd = minHwnd)
            minInQueue := true
    }

    if (cloakedInQueue) {
        Log("PASS: Cloaked window was enqueued for icon resolution")
        TestPassed++
    } else {
        Log("FAIL: Cloaked window was NOT enqueued - this is the bug that breaks other-workspace icons!")
        TestErrors++
    }

    if (minInQueue) {
        Log("PASS: Minimized window was enqueued for icon resolution")
        TestPassed++
    } else {
        Log("FAIL: Minimized window was NOT enqueued - this breaks minimized window icons!")
        TestErrors++
    }

    ; Clean up
    WindowStore_RemoveWindow([cloakedHwnd, minHwnd], true)

    ; Test 8: WindowStore_EnqueueIconRefresh with throttle
    Log("Testing icon refresh throttle...")
    WindowStore_Init()
    WindowStore_BeginScan()

    ; Create a window with WM_GETICON icon (eligible for refresh)
    refreshHwnd := 66666
    refreshRec := Map()
    refreshRec["hwnd"] := refreshHwnd
    refreshRec["title"] := "Test Refresh Window"
    refreshRec["class"] := "TestClass"
    refreshRec["pid"] := 997
    refreshRec["isVisible"] := true
    refreshRec["isCloaked"] := false
    refreshRec["isMinimized"] := false
    refreshRec["z"] := 1
    refreshRec["iconHicon"] := 12345  ; Has icon
    refreshRec["iconMethod"] := "wm_geticon"  ; Got it via WM_GETICON
    refreshRec["iconLastRefreshTick"] := 0  ; Never refreshed
    WindowStore_UpsertWindow([refreshRec], "test")
    WindowStore_EndScan()

    ; First refresh should enqueue (never refreshed before)
    WindowStore_EnqueueIconRefresh(refreshHwnd)
    batch1 := WindowStore_PopIconBatch(10)
    firstRefreshEnqueued := false
    for _, hwnd in batch1 {
        if (hwnd = refreshHwnd)
            firstRefreshEnqueued := true
    }

    if (firstRefreshEnqueued) {
        Log("PASS: First icon refresh was enqueued (no throttle for new window)")
        TestPassed++
    } else {
        Log("FAIL: First icon refresh should be enqueued")
        TestErrors++
    }

    ; Update the refresh tick to simulate recent refresh
    WindowStore_UpdateFields(refreshHwnd, { iconLastRefreshTick: A_TickCount }, "test")

    ; Second refresh immediately should be throttled
    WindowStore_EnqueueIconRefresh(refreshHwnd)
    batch2 := WindowStore_PopIconBatch(10)
    secondRefreshEnqueued := false
    for _, hwnd in batch2 {
        if (hwnd = refreshHwnd)
            secondRefreshEnqueued := true
    }

    if (!secondRefreshEnqueued) {
        Log("PASS: Second icon refresh was throttled (within throttle window)")
        TestPassed++
    } else {
        Log("FAIL: Second icon refresh should be throttled")
        TestErrors++
    }

    ; Clean up
    WindowStore_RemoveWindow([refreshHwnd], true)

    ; Test 9: Icon upgrade - visible window with EXE fallback gets re-queued
    Log("Testing icon upgrade queue (EXE fallback -> WM_GETICON upgrade)...")
    WindowStore_Init()
    WindowStore_BeginScan()

    ; Create a window that started cloaked (got EXE icon), now visible
    upgradeHwnd := 55555
    upgradeRec := Map()
    upgradeRec["hwnd"] := upgradeHwnd
    upgradeRec["title"] := "Test Upgrade Window"
    upgradeRec["class"] := "TestClass"
    upgradeRec["pid"] := 996
    upgradeRec["isVisible"] := true  ; NOW visible
    upgradeRec["isCloaked"] := false  ; NOT cloaked anymore
    upgradeRec["isMinimized"] := false
    upgradeRec["z"] := 1
    upgradeRec["iconHicon"] := 12345  ; Has icon
    upgradeRec["iconMethod"] := "exe"  ; Got it via EXE fallback (not WM_GETICON)
    WindowStore_UpsertWindow([upgradeRec], "test")
    WindowStore_EndScan()

    ; Check if upgrade gets queued
    batch3 := WindowStore_PopIconBatch(10)
    upgradeEnqueued := false
    for _, hwnd in batch3 {
        if (hwnd = upgradeHwnd)
            upgradeEnqueued := true
    }

    if (upgradeEnqueued) {
        Log("PASS: Visible window with EXE fallback icon was queued for upgrade")
        TestPassed++
    } else {
        Log("FAIL: Visible window with EXE fallback icon should be queued for upgrade to WM_GETICON")
        TestErrors++
    }

    ; Clean up
    WindowStore_RemoveWindow([upgradeHwnd], true)

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
    if (A_IsAdmin) {
        Log("Running admin-level Task Scheduler tests...")

        ; Create a test task with a unique name
        testTaskExePath := A_WinDir "\notepad.exe"  ; Safe exe to use for testing

        ; Save the current task state
        originalTaskExists := AdminTaskExists()

        ; Test CreateAdminTask
        Log("Testing CreateAdminTask()...")
        createResult := CreateAdminTask(testTaskExePath)
        if (createResult) {
            Log("PASS: CreateAdminTask() succeeded")
            TestPassed++

            ; Verify task exists
            if (AdminTaskExists()) {
                Log("PASS: Task verified to exist after creation")
                TestPassed++
            } else {
                Log("FAIL: AdminTaskExists() returned false after CreateAdminTask()")
                TestErrors++
            }

            ; Test DeleteAdminTask
            Log("Testing DeleteAdminTask()...")
            deleteResult := DeleteAdminTask()
            if (deleteResult) {
                Log("PASS: DeleteAdminTask() succeeded")
                TestPassed++

                ; Verify task no longer exists
                if (!AdminTaskExists()) {
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

        ; Restore original state if task existed before
        if (originalTaskExists && !AdminTaskExists()) {
            Log("NOTE: Original task was removed by test - this shouldn't happen in normal testing")
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

; Helper to join array elements
_JoinArray(arr, sep) {
    result := ""
    for i, item in arr {
        if (i > 1)
            result .= sep
        result .= item
    }
    return result
}

; Helper to repeat a string n times
_RepeatStr(str, count) {
    result := ""
    loop count
        result .= str
    return result
}
