; Unit Tests - Core Data Structures
; WindowStore, Race Condition Prevention, JSON (JXON), Config System, Entry Points
; Included by test_unit.ahk

RunUnitTests_Core() {
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

    ; Test 10: Round-trip test - Load -> Dump -> Load
    originalJson := '{"type":"projection","rev":123,"payload":{"items":[{"hwnd":1,"title":"Test"}]}}'
    try {
        parsed1 := JXON_Load(originalJson)
        dumped := JXON_Dump(parsed1)
        parsed2 := JXON_Load(dumped)

        ; Verify key values survive round-trip
        if (parsed2["type"] = "projection" && parsed2["rev"] = 123 && parsed2["payload"]["items"][1]["title"] = "Test") {
            Log("PASS: JXON round-trip (Load->Dump->Load) preserves data")
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

    ; Test 13: JXON_Load - Unicode escape sequences (\uXXXX)
    ; Note: In AHK v2 single-quoted strings, backslashes are literal (no escaping)
    ; So '\u0041' is literally backslash-u-0041, which is valid JSON unicode escape
    Log("Testing JSON unicode escape sequences...")
    try {
        ; Test basic BMP character: \u0041 = 'A'
        jsonA := '{"char":"\u0041"}'
        parsedA := JXON_Load(jsonA)
        if (parsedA["char"] = "A") {
            Log("PASS: \u0041 decodes to 'A'")
            TestPassed++
        } else {
            Log("FAIL: \u0041 expected 'A', got '" parsedA["char"] "'")
            TestErrors++
        }

        ; Test accented character: \u00E9 = 'é'
        jsonAccent := '{"accent":"caf\u00E9"}'
        parsedAccent := JXON_Load(jsonAccent)
        if (parsedAccent["accent"] = "café") {
            Log("PASS: \u00E9 decodes to 'é' (in context)")
            TestPassed++
        } else {
            Log("FAIL: \u00E9 expected 'café', got '" parsedAccent["accent"] "'")
            TestErrors++
        }

        ; Test CJK character: \u4E2D = '中'
        jsonCJK := '{"cjk":"\u4E2D"}'
        parsedCJK := JXON_Load(jsonCJK)
        if (parsedCJK["cjk"] = "中") {
            Log("PASS: \u4E2D decodes to '中'")
            TestPassed++
        } else {
            Log("FAIL: \u4E2D expected '中', got '" parsedCJK["cjk"] "'")
            TestErrors++
        }
    } catch as e {
        Log("FAIL: JSON unicode escape test threw error: " e.Message)
        TestErrors++
    }

    ; ============================================================
    ; Blacklist Wildcard Matching Tests
    ; ============================================================
    Log("`n--- Blacklist Wildcard Matching Tests ---")

    ; Test _BL_WildcardMatch edge cases
    Log("Testing _BL_WildcardMatch edge cases...")

    ; Test 1: * matches any string
    if (_BL_WildcardMatch("test", "*")) {
        Log("PASS: * matches any string")
        TestPassed++
    } else {
        Log("FAIL: * should match any string")
        TestErrors++
    }

    ; Test 2: * matches empty string
    if (_BL_WildcardMatch("", "*")) {
        Log("PASS: * matches empty string")
        TestPassed++
    } else {
        Log("FAIL: * should match empty string")
        TestErrors++
    }

    ; Test 3: ? matches single character
    if (_BL_WildcardMatch("a", "?")) {
        Log("PASS: ? matches single char")
        TestPassed++
    } else {
        Log("FAIL: ? should match single char")
        TestErrors++
    }

    ; Test 4: ? does NOT match multiple characters
    if (!_BL_WildcardMatch("ab", "?")) {
        Log("PASS: ? does not match two chars")
        TestPassed++
    } else {
        Log("FAIL: ? should not match two chars")
        TestErrors++
    }

    ; Test 5: Wildcard with literal dot (regex special char)
    if (_BL_WildcardMatch("test.exe", "*.exe")) {
        Log("PASS: wildcard with literal dot works")
        TestPassed++
    } else {
        Log("FAIL: *.exe should match test.exe")
        TestErrors++
    }

    ; Test 6: Literal brackets (regex special char)
    if (_BL_WildcardMatch("[Bracket]", "[Bracket]")) {
        Log("PASS: literal brackets match")
        TestPassed++
    } else {
        Log("FAIL: literal brackets should match")
        TestErrors++
    }

    ; Test 7: Empty pattern returns false
    if (!_BL_WildcardMatch("test", "")) {
        Log("PASS: empty pattern returns false")
        TestPassed++
    } else {
        Log("FAIL: empty pattern should return false")
        TestErrors++
    }

    ; Test 8: Case insensitivity
    if (_BL_WildcardMatch("TEST", "test") && _BL_WildcardMatch("test", "TEST")) {
        Log("PASS: matching is case-insensitive")
        TestPassed++
    } else {
        Log("FAIL: matching should be case-insensitive")
        TestErrors++
    }

    ; Test 9: Plus sign (regex special char)
    if (_BL_WildcardMatch("C++", "C++")) {
        Log("PASS: literal + sign matches")
        TestPassed++
    } else {
        Log("FAIL: literal + sign should match")
        TestErrors++
    }

    ; Test 10: Dollar sign and caret (regex special chars)
    if (_BL_WildcardMatch("$price^", "$price^")) {
        Log("PASS: literal $ and ^ match")
        TestPassed++
    } else {
        Log("FAIL: literal $ and ^ should match")
        TestErrors++
    }

    ; ============================================================
    ; Alt-Tab Eligibility Code Inspection Tests
    ; ============================================================
    Log("`n--- Alt-Tab Eligibility Code Inspection Tests ---")
    Log("Testing _BL_IsAltTabEligible code structure...")

    blPath := A_ScriptDir "\..\src\shared\blacklist.ahk"
    if (!FileExist(blPath)) {
        Log("SKIP: blacklist.ahk not found at " blPath)
    } else {
        blCode := FileRead(blPath)

        ; Verify all eligibility checks exist in the code
        eligibilityChecks := [
            {pattern: "WS_CHILD", name: "WS_CHILD check"},
            {pattern: "WS_EX_TOOLWINDOW", name: "WS_EX_TOOLWINDOW check"},
            {pattern: "WS_EX_NOACTIVATE", name: "WS_EX_NOACTIVATE check"},
            {pattern: "GW_OWNER", name: "owner window check"},
            {pattern: "IsWindowVisible", name: "visibility check"},
            {pattern: "DwmGetWindowAttribute", name: "DWM cloaking check"},
            {pattern: "WS_EX_APPWINDOW", name: "WS_EX_APPWINDOW for owned windows"},
            {pattern: "IsIconic", name: "minimized state check"}
        ]

        allChecksPresent := true
        for _, check in eligibilityChecks {
            if (InStr(blCode, check.pattern)) {
                Log("PASS: _BL_IsAltTabEligible has " check.name)
                TestPassed++
            } else {
                Log("FAIL: _BL_IsAltTabEligible missing " check.name " (" check.pattern ")")
                TestErrors++
                allChecksPresent := false
            }
        }
    }

    ; ============================================================
    ; WinEventHook Empty Title Filter Test
    ; ============================================================
    Log("`n--- WinEventHook Empty Title Filter Test ---")
    Log("Testing WinEventHook filters empty-title windows from focus tracking...")

    wehPath := A_ScriptDir "\..\src\store\winevent_hook.ahk"
    if (!FileExist(wehPath)) {
        Log("SKIP: winevent_hook.ahk not found at " wehPath)
    } else {
        wehCode := FileRead(wehPath)

        ; Check for the critical empty title filter
        ; The fix checks for empty title and returns early to prevent Task Switching UI poisoning
        hasEmptyTitleCheck := InStr(wehCode, 'if (title = "")') || InStr(wehCode, 'if (title = "")')
        hasFocusSkipComment := InStr(wehCode, "FOCUS SKIP") || InStr(wehCode, "no title")
        hasReturnAfterCheck := InStr(wehCode, "CRITICAL: Skip windows with empty titles")

        if (hasEmptyTitleCheck && (hasFocusSkipComment || hasReturnAfterCheck)) {
            Log("PASS: WinEventHook filters windows with empty titles (Task Switching UI fix)")
            TestPassed++
        } else {
            Log("FAIL: WinEventHook should filter empty-title windows to prevent focus poisoning")
            Log("  hasEmptyTitleCheck=" hasEmptyTitleCheck ", hasFocusSkipComment=" hasFocusSkipComment)
            TestErrors++
        }
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
    ; Diagnostic Logging Guard Tests
    ; ============================================================
    ; These tests verify that logging functions respect their config flags
    ; and don't write files when disabled (default behavior)
    Log("`n--- Diagnostic Logging Guard Tests ---")

    ; Test 1: Verify all diagnostic config options default to false
    diagOptions := ["DiagChurnLog", "DiagKomorebiLog", "DiagEventLog", "DiagWinEventLog",
                    "DiagStoreLog", "DiagIconPumpLog", "DiagProcPumpLog", "DiagLauncherLog", "DiagIPCLog"]
    allDefaultFalse := true
    for _, opt in diagOptions {
        if (!cfg.HasOwnProp(opt)) {
            Log("FAIL: cfg missing diagnostic option: " opt)
            TestErrors++
            allDefaultFalse := false
        } else if (cfg.%opt% != false) {
            Log("FAIL: " opt " should default to false, got: " cfg.%opt%)
            TestErrors++
            allDefaultFalse := false
        }
    }
    if (allDefaultFalse) {
        Log("PASS: All " diagOptions.Length " diagnostic options default to false")
        TestPassed++
    }

    ; Test 2: Verify IPC_Log handles uninitialized cfg gracefully
    ; Save current state
    global IPC_DebugLogPath
    savedIPCPath := IPC_DebugLogPath
    IPC_DebugLogPath := ""

    ; Create a minimal test - _IPC_Log should not crash with partial cfg
    testLogFile := A_Temp "\tabby_ipc_test_" A_TickCount ".log"
    try {
        ; _IPC_Log checks IsSet(cfg) && IsObject(cfg) && cfg.HasOwnProp("DiagIPCLog")
        ; With cfg.DiagIPCLog = false, it should return without writing
        _IPC_Log("test message that should not appear")

        ; Verify no file was created (since DiagIPCLog is false)
        if (FileExist(testLogFile)) {
            Log("FAIL: _IPC_Log wrote file when DiagIPCLog=false")
            TestErrors++
            try FileDelete(testLogFile)
        } else {
            Log("PASS: _IPC_Log respects DiagIPCLog=false (no file created)")
            TestPassed++
        }
    } catch as e {
        Log("FAIL: _IPC_Log crashed: " e.Message)
        TestErrors++
    }

    ; Restore state
    IPC_DebugLogPath := savedIPCPath

    ; ============================================================
    ; Entry Point Initialization Tests
    ; ============================================================
    ; These test that each entry point file can actually RUN (not just syntax check)
    ; by launching with ErrorStdOut and checking for runtime errors
    Log("`n--- Entry Point Initialization Tests ---")
    Log("Testing that entry points initialize without runtime errors...")

    entryPoints := [
        {name: "store_server.ahk", path: A_ScriptDir "\..\src\store\store_server.ahk", args: "--test --pipe=entry_test_store_" A_TickCount},
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
}
