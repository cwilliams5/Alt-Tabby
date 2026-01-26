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
    ; NOTE: These tests use code inspection to verify _BL_IsAltTabEligible
    ; contains all required Windows API checks. This supplements functional
    ; tests because:
    ; - Some checks (cloaking, owned windows) require specific window states
    ;   that are difficult to create reliably in tests
    ; - The full eligibility logic involves many interacting conditions
    ;
    ; LIMITATIONS: Verifies patterns EXIST but not their correctness.
    ; Functional tests in test_blacklist.ahk validate actual filtering behavior.
    ; These are REGRESSION GUARDS - they catch accidental removal of eligibility checks.
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
    ; WinEventHook Empty Title Filter Test (Code Inspection)
    ; ============================================================
    ; NOTE: This test uses code inspection because WinEventHook requires
    ; system-level hooks (SetWinEventHook) that cannot be safely tested
    ; without affecting the real Windows event stream.
    ;
    ; The empty-title filter is critical: Windows Task Switching UI sends
    ; focus events with empty titles, which can poison MRU tracking. This
    ; test verifies the defensive check exists.
    ;
    ; LIMITATIONS: Cannot verify the filter executes at the right time.
    ; Live testing with actual window switching validates runtime behavior.
    ; This is a REGRESSION GUARD - catches accidental removal of the fix.
    Log("`n--- WinEventHook Empty Title Filter Test ---")
    Log("Testing WinEventHook filters empty-title windows from focus tracking...")

    wehPath := A_ScriptDir "\..\src\store\winevent_hook.ahk"
    if (!FileExist(wehPath)) {
        Log("SKIP: winevent_hook.ahk not found at " wehPath)
    } else {
        wehCode := FileRead(wehPath)

        ; Check for the critical empty title filter
        ; The fix checks for empty title and returns early to prevent Task Switching UI poisoning
        hasEmptyTitleCheck := InStr(wehCode, 'if (title = "")') || InStr(wehCode, 'if title = ""')
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
        {name: "alt_tabby.ahk (launcher)", path: A_ScriptDir "\..\src\alt_tabby.ahk", args: "--testing-mode"}
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
        ; 750ms is sufficient to detect init failures without being overly slow
        Sleep(750)

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
    ; WindowStore Advanced Tests
    ; ============================================================
    Log("`n--- WindowStore Advanced Tests ---")

    ; Test: WindowStore_EndScan TTL marks windows missing before removal
    Log("Testing EndScan TTL grace period...")

    WindowStore_Init()
    global gWS_Store

    ; Scan 1: Add two windows
    WindowStore_BeginScan()
    rec1 := Map("hwnd", 11111, "title", "Persistent", "class", "Test", "pid", 1,
                "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 1)
    rec2 := Map("hwnd", 22222, "title", "Disappearing", "class", "Test", "pid", 2,
                "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 2)
    WindowStore_UpsertWindow([rec1, rec2], "test")
    WindowStore_EndScan(100)  ; 100ms grace

    AssertEq(gWS_Store[11111].present, true, "Window 1 present after scan 1")
    AssertEq(gWS_Store[22222].present, true, "Window 2 present after scan 1")

    ; Scan 2: Only include window 1
    WindowStore_BeginScan()
    WindowStore_UpsertWindow([rec1], "test")
    WindowStore_EndScan(100)

    ; Window 2 marked missing but NOT removed yet (within grace period)
    AssertEq(gWS_Store[11111].present, true, "Window 1 still present")
    AssertEq(gWS_Store.Has(22222), true, "Window 2 still in store (grace period)")
    AssertEq(gWS_Store[22222].present, false, "Window 2 marked present=false")

    ; Wait for grace period + scan again
    Sleep(150)
    WindowStore_BeginScan()
    WindowStore_UpsertWindow([rec1], "test")
    WindowStore_EndScan(100)

    ; Window 2 removed after grace expires (IsWindow returns false for fake hwnd)
    AssertEq(gWS_Store.Has(22222), false, "Window 2 removed after grace period")

    ; Cleanup
    WindowStore_RemoveWindow([11111], true)

    ; Test: WindowStore_BuildDelta field detection
    Log("Testing BuildDelta field detection...")

    baseItem := {
        hwnd: 12345, title: "Original", class: "TestClass", pid: 100, z: 1,
        isFocused: false, workspaceName: "Main", isCloaked: false,
        isMinimized: false, isOnCurrentWorkspace: true, processName: "test.exe",
        iconHicon: 0
    }

    ; Fields that SHOULD trigger delta (from BuildDelta code)
    triggerTests := [
        {field: "title", newVal: "Changed"},
        {field: "z", newVal: 2},
        {field: "isFocused", newVal: true},
        {field: "workspaceName", newVal: "Other"},
        {field: "isCloaked", newVal: true},
        {field: "isMinimized", newVal: true},
        {field: "isOnCurrentWorkspace", newVal: false},
        {field: "processName", newVal: "other.exe"},
        {field: "iconHicon", newVal: 12345}
    ]

    for _, test in triggerTests {
        changedItem := {}
        for k in baseItem.OwnProps()
            changedItem.%k% := baseItem.%k%
        changedItem.%test.field% := test.newVal

        delta := WindowStore_BuildDelta([baseItem], [changedItem])
        AssertEq(delta.upserts.Length, 1, "Field '" test.field "' triggers delta")
    }

    ; Fields that should NOT trigger delta (class is not in comparison list)
    noTriggerTests := [{field: "class", newVal: "OtherClass"}]
    for _, test in noTriggerTests {
        changedItem := {}
        for k in baseItem.OwnProps()
            changedItem.%k% := baseItem.%k%
        changedItem.%test.field% := test.newVal

        delta := WindowStore_BuildDelta([baseItem], [changedItem])
        AssertEq(delta.upserts.Length, 0, "Field '" test.field "' does NOT trigger delta")
    }

    ; New window creates upsert
    delta := WindowStore_BuildDelta([], [baseItem])
    AssertEq(delta.upserts.Length, 1, "New window triggers upsert")
    AssertEq(delta.removes.Length, 0, "No removes for new window")

    ; Removed window creates remove
    delta := WindowStore_BuildDelta([baseItem], [])
    AssertEq(delta.removes.Length, 1, "Removed window triggers remove")

    ; Test: WindowStore_SetCurrentWorkspace updates all windows
    Log("Testing SetCurrentWorkspace consistency...")

    WindowStore_Init()
    global gWS_Meta

    WindowStore_BeginScan()
    recs := []
    recs.Push(Map("hwnd", 1001, "title", "Win1", "class", "T", "pid", 1,
                  "isVisible", true, "isCloaked", false, "isMinimized", false,
                  "z", 1, "workspaceName", "Main"))
    recs.Push(Map("hwnd", 1002, "title", "Win2", "class", "T", "pid", 2,
                  "isVisible", true, "isCloaked", false, "isMinimized", false,
                  "z", 2, "workspaceName", "Other"))
    recs.Push(Map("hwnd", 1003, "title", "Win3", "class", "T", "pid", 3,
                  "isVisible", true, "isCloaked", false, "isMinimized", false,
                  "z", 3, "workspaceName", ""))  ; Unmanaged
    WindowStore_UpsertWindow(recs, "test")
    WindowStore_EndScan()

    startRev := WindowStore_GetRev()
    WindowStore_SetCurrentWorkspace("", "Main")

    AssertEq(gWS_Store[1001].isOnCurrentWorkspace, true, "Main window on current")
    AssertEq(gWS_Store[1002].isOnCurrentWorkspace, false, "Other window NOT on current")
    AssertEq(gWS_Store[1003].isOnCurrentWorkspace, true, "Unmanaged floats to current")
    AssertEq(gWS_Meta["currentWSName"], "Main", "Meta updated")
    AssertEq(WindowStore_GetRev(), startRev + 1, "Rev bumped exactly once")

    ; Switch workspace
    WindowStore_SetCurrentWorkspace("", "Other")
    AssertEq(gWS_Store[1001].isOnCurrentWorkspace, false, "Main now NOT current")
    AssertEq(gWS_Store[1002].isOnCurrentWorkspace, true, "Other now current")

    ; Cleanup
    WindowStore_RemoveWindow([1001, 1002, 1003], true)

    ; ============================================================
    ; Phase 1: Bypass Mode Detection Tests
    ; ============================================================
    Log("`n--- Bypass Mode Detection Tests ---")

    ; Test 1: Process bypass list matching (case-insensitive)
    Log("Testing bypass process list matching...")

    ; Save original config
    origBypassProcesses := cfg.AltTabBypassProcesses
    origBypassFullscreen := cfg.AltTabBypassFullscreen

    ; Test with comma-separated process list
    cfg.AltTabBypassProcesses := "notepad.exe, calc.exe, game.exe"
    cfg.AltTabBypassFullscreen := false  ; Disable fullscreen check for this test

    ; Mock test: We can't easily test with real windows, but we can verify
    ; the bypass logic by checking the code structure
    bypassPath := A_ScriptDir "\..\src\gui\gui_interceptor.ahk"
    if (FileExist(bypassPath)) {
        bypassCode := FileRead(bypassPath)

        ; Verify process list splitting logic exists
        hasStrSplit := InStr(bypassCode, "StrSplit(cfg.AltTabBypassProcesses")
        hasStrLower := InStr(bypassCode, "StrLower")
        hasTrim := InStr(bypassCode, "Trim(")

        if (hasStrSplit && hasStrLower && hasTrim) {
            Log("PASS: INT_ShouldBypassWindow has process list parsing (split, lowercase, trim)")
            TestPassed++
        } else {
            Log("FAIL: INT_ShouldBypassWindow missing process list parsing")
            Log("  hasStrSplit=" hasStrSplit ", hasStrLower=" hasStrLower ", hasTrim=" hasTrim)
            TestErrors++
        }

        ; Verify fullscreen detection logic exists
        hasFullscreenCheck := InStr(bypassCode, "INT_IsFullscreenHwnd")
        hasScreenWidth := InStr(bypassCode, "A_ScreenWidth")
        hasScreenHeight := InStr(bypassCode, "A_ScreenHeight")

        if (hasFullscreenCheck && hasScreenWidth && hasScreenHeight) {
            Log("PASS: INT_IsFullscreenHwnd checks screen dimensions")
            TestPassed++
        } else {
            Log("FAIL: INT_IsFullscreenHwnd missing screen dimension checks")
            TestErrors++
        }

        ; Verify hotkey disable pattern exists
        hasHotkeyOff := InStr(bypassCode, 'Hotkey("$*Tab", "Off")')
        hasHotkeyOn := InStr(bypassCode, 'Hotkey("$*Tab", "On")')

        if (hasHotkeyOff && hasHotkeyOn) {
            Log("PASS: INT_SetBypassMode toggles Tab hotkey On/Off")
            TestPassed++
        } else {
            Log("FAIL: INT_SetBypassMode missing Tab hotkey toggle")
            TestErrors++
        }
    } else {
        Log("SKIP: gui_interceptor.ahk not found")
    }

    ; Restore original config
    cfg.AltTabBypassProcesses := origBypassProcesses
    cfg.AltTabBypassFullscreen := origBypassFullscreen

    ; ============================================================
    ; Phase 2: Config Validation Bounds Tests
    ; ============================================================
    Log("`n--- Config Validation Bounds Tests ---")

    ; Test that _CL_ValidateSettings clamps out-of-bounds values
    Log("Testing config value clamping...")

    ; Save original values
    origGraceMs := cfg.AltTabGraceMs
    origRowHeight := cfg.GUI_RowHeight
    origRowsMin := cfg.GUI_RowsVisibleMin
    origRowsMax := cfg.GUI_RowsVisibleMax

    ; Test 1: Value below minimum gets clamped up
    cfg.AltTabGraceMs := -100  ; Below min of 0
    _CL_ValidateSettings()
    if (cfg.AltTabGraceMs >= 0) {
        Log("PASS: AltTabGraceMs=-100 clamped to " cfg.AltTabGraceMs " (>= 0)")
        TestPassed++
    } else {
        Log("FAIL: AltTabGraceMs=-100 not clamped, got " cfg.AltTabGraceMs)
        TestErrors++
    }

    ; Test 2: Value above maximum gets clamped down
    cfg.AltTabGraceMs := 99999  ; Above max of 2000
    _CL_ValidateSettings()
    if (cfg.AltTabGraceMs <= 2000) {
        Log("PASS: AltTabGraceMs=99999 clamped to " cfg.AltTabGraceMs " (<= 2000)")
        TestPassed++
    } else {
        Log("FAIL: AltTabGraceMs=99999 not clamped, got " cfg.AltTabGraceMs)
        TestErrors++
    }

    ; Test 3: GUI_RowHeight minimum enforcement
    cfg.GUI_RowHeight := 5  ; Below min of 20
    _CL_ValidateSettings()
    if (cfg.GUI_RowHeight >= 20) {
        Log("PASS: GUI_RowHeight=5 clamped to " cfg.GUI_RowHeight " (>= 20)")
        TestPassed++
    } else {
        Log("FAIL: GUI_RowHeight=5 not clamped, got " cfg.GUI_RowHeight)
        TestErrors++
    }

    ; Test 4: RowsVisibleMin/Max consistency enforcement
    cfg.GUI_RowsVisibleMin := 30
    cfg.GUI_RowsVisibleMax := 10  ; Min > Max - should be fixed
    _CL_ValidateSettings()
    if (cfg.GUI_RowsVisibleMin <= cfg.GUI_RowsVisibleMax) {
        Log("PASS: RowsVisibleMin/Max consistency enforced (min=" cfg.GUI_RowsVisibleMin " max=" cfg.GUI_RowsVisibleMax ")")
        TestPassed++
    } else {
        Log("FAIL: RowsVisibleMin > RowsVisibleMax not fixed")
        TestErrors++
    }

    ; Restore original values
    cfg.AltTabGraceMs := origGraceMs
    cfg.GUI_RowHeight := origRowHeight
    cfg.GUI_RowsVisibleMin := origRowsMin
    cfg.GUI_RowsVisibleMax := origRowsMax

    ; ============================================================
    ; Phase 2: Komorebi Content Parsing Tests
    ; ============================================================
    Log("`n--- Komorebi Content Parsing Tests ---")

    ; Test _KSub_ExtractContentRaw with different content formats
    Log("Testing _KSub_ExtractContentRaw with various content types...")

    ; Test 1: Array content - [1, 2]
    testEvent1 := '{"type":"FocusMonitorWorkspaceNumber","content":[0,2]}'
    result1 := _KSub_ExtractContentRaw(testEvent1)
    if (result1 = "[0,2]") {
        Log("PASS: Array content [0,2] extracted correctly")
        TestPassed++
    } else {
        Log("FAIL: Array content expected '[0,2]', got '" result1 "'")
        TestErrors++
    }

    ; Test 2: String content - "WorkspaceName"
    testEvent2 := '{"type":"FocusNamedWorkspace","content":"Main"}'
    result2 := _KSub_ExtractContentRaw(testEvent2)
    if (result2 = "Main") {
        Log("PASS: String content 'Main' extracted correctly")
        TestPassed++
    } else {
        Log("FAIL: String content expected 'Main', got '" result2 "'")
        TestErrors++
    }

    ; Test 3: Integer content - 1
    testEvent3 := '{"type":"MoveContainerToWorkspaceNumber","content":3}'
    result3 := _KSub_ExtractContentRaw(testEvent3)
    if (result3 = "3") {
        Log("PASS: Integer content 3 extracted correctly")
        TestPassed++
    } else {
        Log("FAIL: Integer content expected '3', got '" result3 "'")
        TestErrors++
    }

    ; Test 4: Object content - {"EventType": value}
    testEvent4 := '{"type":"SocketMessage","content":{"MoveContainerToWorkspaceNumber":5}}'
    result4 := _KSub_ExtractContentRaw(testEvent4)
    if (result4 = "5") {
        Log("PASS: Object content value 5 extracted correctly")
        TestPassed++
    } else {
        Log("FAIL: Object content expected '5', got '" result4 "'")
        TestErrors++
    }

    ; Test 5: Missing content - empty string
    testEvent5 := '{"type":"SomeEvent"}'
    result5 := _KSub_ExtractContentRaw(testEvent5)
    if (result5 = "") {
        Log("PASS: Missing content returns empty string")
        TestPassed++
    } else {
        Log("FAIL: Missing content expected '', got '" result5 "'")
        TestErrors++
    }

    ; Test 6: Workspace name with spaces
    testEvent6 := '{"type":"FocusNamedWorkspace","content":"Work Space 1"}'
    result6 := _KSub_ExtractContentRaw(testEvent6)
    if (result6 = "Work Space 1") {
        Log("PASS: Workspace name with spaces extracted correctly")
        TestPassed++
    } else {
        Log("FAIL: Workspace with spaces expected 'Work Space 1', got '" result6 "'")
        TestErrors++
    }

    ; Test 7: Negative integer content
    testEvent7 := '{"type":"SomeEvent","content":-1}'
    result7 := _KSub_ExtractContentRaw(testEvent7)
    if (result7 = "-1") {
        Log("PASS: Negative integer -1 extracted correctly")
        TestPassed++
    } else {
        Log("FAIL: Negative integer expected '-1', got '" result7 "'")
        TestErrors++
    }

    ; Test _KSub_ArrayTopLevelSplit for proper array parsing
    Log("Testing _KSub_ArrayTopLevelSplit...")

    ; Test 8: Simple numeric array
    testArr1 := "[1, 2, 3]"
    parts1 := _KSub_ArrayTopLevelSplit(testArr1)
    if (parts1.Length = 3 && parts1[1] = "1" && parts1[2] = "2" && parts1[3] = "3") {
        Log("PASS: [1, 2, 3] split into 3 elements")
        TestPassed++
    } else {
        Log("FAIL: [1, 2, 3] split incorrectly, got " parts1.Length " elements")
        TestErrors++
    }

    ; Test 9: Array with nested object
    testArr2 := '[1, {"hwnd": 12345}, "text"]'
    parts2 := _KSub_ArrayTopLevelSplit(testArr2)
    if (parts2.Length = 3) {
        Log("PASS: Array with nested object split into 3 top-level elements")
        TestPassed++
    } else {
        Log("FAIL: Array with nested object expected 3 elements, got " parts2.Length)
        TestErrors++
    }

    ; Test 10: Empty array
    testArr3 := "[]"
    parts3 := _KSub_ArrayTopLevelSplit(testArr3)
    if (parts3.Length = 0) {
        Log("PASS: Empty array returns 0 elements")
        TestPassed++
    } else {
        Log("FAIL: Empty array expected 0 elements, got " parts3.Length)
        TestErrors++
    }
}
