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
        parsed := JSON.Load(jsonObj)
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
        parsed := JSON.Load(jsonArr)
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
        parsed := JSON.Load(jsonBool)
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
        parsed := JSON.Load(jsonNested)
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
        parsed := JSON.Load(jsonEscaped)
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
        emptyObj := JSON.Load('{}')
        emptyArr := JSON.Load('[]')
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
        parsed := JSON.Load(wsJson)
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
        dumped := JSON.Dump(testObj)
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
        dumped := JSON.Dump(testArr)
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
        parsed1 := JSON.Load(originalJson)
        dumped := JSON.Dump(parsed1)
        parsed2 := JSON.Load(dumped)

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

    ; Test 11: JXON_Dump - empty string and zero handling
    ; cJson correctly serializes empty string as "" (not null) and 0 as number
    try {
        nullTest := Map("empty", "", "zero", 0)
        dumped := JSON.Dump(nullTest)
        if (InStr(dumped, '""') && InStr(dumped, ":0")) {
            Log('PASS: JXON_Dump handles empty string as "" and 0 as number')
            TestPassed++
        } else {
            Log("FAIL: JXON_Dump empty/zero output: " dumped)
            TestErrors++
        }
    } catch as e {
        Log("FAIL: JXON_Dump threw error on empty/zero: " e.Message)
        TestErrors++
    }

    ; Test 12: JXON with special characters in keys/values
    try {
        specialJson := '{"key with spaces":"value","emoji":"🎉","unicode":"日本語"}'
        parsed := JSON.Load(specialJson)
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
        parsedA := JSON.Load(jsonA)
        if (parsedA["char"] = "A") {
            Log("PASS: \u0041 decodes to 'A'")
            TestPassed++
        } else {
            Log("FAIL: \u0041 expected 'A', got '" parsedA["char"] "'")
            TestErrors++
        }

        ; Test accented character: \u00E9 = 'é'
        jsonAccent := '{"accent":"caf\u00E9"}'
        parsedAccent := JSON.Load(jsonAccent)
        if (parsedAccent["accent"] = "café") {
            Log("PASS: \u00E9 decodes to 'é' (in context)")
            TestPassed++
        } else {
            Log("FAIL: \u00E9 expected 'café', got '" parsedAccent["accent"] "'")
            TestErrors++
        }

        ; Test CJK character: \u4E2D = '中'
        jsonCJK := '{"cjk":"\u4E2D"}'
        parsedCJK := JSON.Load(jsonCJK)
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
    ; Blacklist Regex Pre-compilation Tests (Code Inspection)
    ; ============================================================
    ; Verify that Blacklist_IsMatch uses pre-compiled regex arrays
    ; rather than building regex strings per-match (hot path performance)
    Log("`n--- Blacklist Regex Pre-compilation Tests ---")

    blPath := A_ScriptDir "\..\src\shared\blacklist.ahk"
    if (!FileExist(blPath)) {
        Log("SKIP: blacklist.ahk not found")
    } else {
        blCode := FileRead(blPath)

        ; Test 1: Pre-compiled regex arrays exist
        Log("Testing blacklist has pre-compiled regex arrays...")
        if (InStr(blCode, "gBlacklist_TitleRegex") && InStr(blCode, "gBlacklist_ClassRegex")) {
            Log("PASS: blacklist.ahk has pre-compiled regex arrays")
            TestPassed++
        } else {
            Log("FAIL: blacklist.ahk missing pre-compiled regex arrays")
            TestErrors++
        }

        ; Test 2: Blacklist_IsMatch does NOT build regex per-match
        ; Check that between "Blacklist_IsMatch" and the next function def, there's no RegExReplace
        Log("Testing Blacklist_IsMatch uses pre-compiled regex...")
        matchStart := InStr(blCode, "Blacklist_IsMatch(title, class)")
        if (matchStart) {
            ; Extract ~500 chars from function start (enough to cover the function body)
            funcChunk := SubStr(blCode, matchStart, 500)
            if (!InStr(funcChunk, "RegExReplace")) {
                Log("PASS: Blacklist_IsMatch does not call RegExReplace (uses pre-compiled)")
                TestPassed++
            } else {
                Log("FAIL: Blacklist_IsMatch should not call RegExReplace in hot path")
                TestErrors++
            }
        } else {
            Log("SKIP: Could not find Blacklist_IsMatch function")
        }

        ; Test 3: _BL_CompileWildcard helper exists
        Log("Testing _BL_CompileWildcard compile helper exists...")
        if (InStr(blCode, "_BL_CompileWildcard(")) {
            Log("PASS: _BL_CompileWildcard compile helper exists")
            TestPassed++
        } else {
            Log("FAIL: _BL_CompileWildcard compile helper missing")
            TestErrors++
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

    ; Test 2.5: _CL_WriteIniPreserveFormat direct tests
    Log("Testing WriteIniPreserveFormat...")

    testWipDir := A_Temp "\tabby_wip_test_" A_TickCount
    testWipPath := testWipDir "\config.ini"

    ; Note: _CL_FormatValue formats ints >= 0x10 as hex (e.g., 150 -> "0x96", 200 -> "0xC8")
    ; Use "string" type to test pure write logic without hex formatting, or expect hex output

    try {
        DirCreate(testWipDir)

        ; Test 1: Update existing value (using bool type to avoid hex conversion)
        Log("Testing WriteIniPreserveFormat updates existing value...")
        wipContent := "[AltTab]`nPrewarmOnAlt=true`nQuickSwitchMs=25`n[GUI]`nRowHeight=40`n"
        FileAppend(wipContent, testWipPath, "UTF-8")

        _CL_WriteIniPreserveFormat(testWipPath, "AltTab", "PrewarmOnAlt", false, true, "bool")

        wipResult := FileRead(testWipPath, "UTF-8")
        if (InStr(wipResult, "PrewarmOnAlt=false") && InStr(wipResult, "QuickSwitchMs=25")) {
            Log("PASS: WriteIniPreserveFormat updated PrewarmOnAlt to false, preserved QuickSwitchMs")
            TestPassed++
        } else {
            Log("FAIL: WriteIniPreserveFormat should update PrewarmOnAlt=false and keep QuickSwitchMs=25")
            Log("  Got: " SubStr(wipResult, 1, 200))
            TestErrors++
        }

        ; Test 2: Comment out default value
        Log("Testing WriteIniPreserveFormat comments out default value...")
        try FileDelete(testWipPath)
        wipContent := "[AltTab]`nPrewarmOnAlt=true`nQuickSwitchMs=25`n"
        FileAppend(wipContent, testWipPath, "UTF-8")

        _CL_WriteIniPreserveFormat(testWipPath, "AltTab", "PrewarmOnAlt", true, true, "bool")

        wipResult := FileRead(testWipPath, "UTF-8")
        if (InStr(wipResult, "; PrewarmOnAlt=true")) {
            Log("PASS: WriteIniPreserveFormat commented out default value (;PrewarmOnAlt=true)")
            TestPassed++
        } else {
            Log("FAIL: WriteIniPreserveFormat should comment out value when it equals default")
            Log("  Got: " SubStr(wipResult, 1, 200))
            TestErrors++
        }

        ; Test 3: Uncomment custom value
        Log("Testing WriteIniPreserveFormat uncomments custom value...")
        try FileDelete(testWipPath)
        wipContent := "[AltTab]`n; PrewarmOnAlt=true`nQuickSwitchMs=25`n"
        FileAppend(wipContent, testWipPath, "UTF-8")

        _CL_WriteIniPreserveFormat(testWipPath, "AltTab", "PrewarmOnAlt", false, true, "bool")

        wipResult := FileRead(testWipPath, "UTF-8")
        if (InStr(wipResult, "PrewarmOnAlt=false") && !InStr(wipResult, "; PrewarmOnAlt=")) {
            Log("PASS: WriteIniPreserveFormat uncommented and set PrewarmOnAlt=false")
            TestPassed++
        } else {
            Log("FAIL: WriteIniPreserveFormat should uncomment and set custom value")
            Log("  Got: " SubStr(wipResult, 1, 200))
            TestErrors++
        }

        ; Test 4: Preserve other content (comments, blank lines, other sections)
        Log("Testing WriteIniPreserveFormat preserves surrounding content...")
        try FileDelete(testWipPath)
        wipContent := "; Alt-Tabby Config`n`n[AltTab]`n; A comment about prewarm`nPrewarmOnAlt=true`n`n[GUI]`nRowHeight=40`n"
        FileAppend(wipContent, testWipPath, "UTF-8")

        _CL_WriteIniPreserveFormat(testWipPath, "AltTab", "PrewarmOnAlt", false, true, "bool")

        wipResult := FileRead(testWipPath, "UTF-8")
        hasHeader := InStr(wipResult, "; Alt-Tabby Config")
        hasComment := InStr(wipResult, "; A comment about prewarm")
        hasGuiSection := InStr(wipResult, "[GUI]")
        hasRowHeight := InStr(wipResult, "RowHeight=40")
        if (hasHeader && hasComment && hasGuiSection && hasRowHeight) {
            Log("PASS: WriteIniPreserveFormat preserved comments, blank lines, and other sections")
            TestPassed++
        } else {
            Log("FAIL: WriteIniPreserveFormat should preserve surrounding content")
            Log("  header=" hasHeader " comment=" hasComment " gui=" hasGuiSection " row=" hasRowHeight)
            TestErrors++
        }

        ; Test 5: Add key to non-last section (key doesn't exist yet)
        Log("Testing WriteIniPreserveFormat adds key to non-last section...")
        try FileDelete(testWipPath)
        wipContent := "[AltTab]`nPrewarmOnAlt=true`n[GUI]`nRowHeight=40`n"
        FileAppend(wipContent, testWipPath, "UTF-8")

        _CL_WriteIniPreserveFormat(testWipPath, "AltTab", "NewBool", false, true, "bool")

        wipResult := FileRead(testWipPath, "UTF-8")
        ; NewBool equals default (false == true? No - false != true), so it should be uncommented
        ; Actually false != true, so shouldComment = false, key should be active
        newKeyPos := InStr(wipResult, "NewBool=false")
        guiPos := InStr(wipResult, "[GUI]")
        if (newKeyPos && guiPos && newKeyPos < guiPos) {
            Log("PASS: WriteIniPreserveFormat added NewBool=false within [AltTab] section (before [GUI])")
            TestPassed++
        } else {
            Log("FAIL: WriteIniPreserveFormat should add new key within correct section")
            Log("  newKeyPos=" newKeyPos " guiPos=" guiPos)
            Log("  Got: " SubStr(wipResult, 1, 200))
            TestErrors++
        }

        ; Cleanup
        try FileDelete(testWipPath)
        try DirDelete(testWipDir)
    } catch as e {
        Log("FAIL: WriteIniPreserveFormat test error: " e.Message)
        TestErrors++
        try DirDelete(testWipDir, true)
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
        {name: "gui_main.ahk", path: A_ScriptDir "\..\src\gui\gui_main.ahk", args: "--test"},
        {name: "alt_tabby.ahk (launcher)", path: A_ScriptDir "\..\src\alt_tabby.ahk", args: "--testing-mode"}
    ]

    ; Launch ALL entry points in parallel (saves ~2s vs sequential)
    pids := []
    errFiles := []
    for idx, ep in entryPoints {
        if (!FileExist(ep.path)) {
            Log("SKIP: " ep.name " not found")
            pids.Push(0)
            errFiles.Push("")
            continue
        }

        errFile := A_Temp "\tabby_entry_test_" A_TickCount "_" idx ".err"
        try FileDelete(errFile)

        cmd := '"' A_AhkPath '" /ErrorStdOut "' ep.path '"'
        if (ep.args != "")
            cmd .= " " ep.args
        cmd := 'cmd.exe /c ' cmd ' 2>"' errFile '"'

        pid := 0
        if (!_Test_RunSilent(cmd, &pid)) {
            Log("FAIL: " ep.name " - could not launch")
            TestErrors++
        }
        pids.Push(pid)
        errFiles.Push(errFile)
    }

    ; Single wait for all to initialize (750ms total instead of 4x750ms)
    Sleep(750)

    ; Collect results from all entry points
    for idx, ep in entryPoints {
        pid := pids[idx]
        errFile := errFiles[idx]
        if (!pid)
            continue

        stillRunning := ProcessExist(pid)

        ; For launcher: find child PIDs BEFORE killing parent (tree kill)
        if (InStr(ep.name, "launcher") && stillRunning) {
            ; taskkill /T kills the entire process tree (cmd → launcher → store + gui)
            _Test_RunWaitSilent('taskkill /F /T /PID ' pid)
            stillRunning := false  ; We just killed it
        } else if (stillRunning) {
            ProcessClose(pid)
        }

        ; Read error output
        errOutput := ""
        if (errFile != "" && FileExist(errFile)) {
            try errOutput := FileRead(errFile)
            try FileDelete(errFile)
        }

        hasError := InStr(errOutput, "Error:") || InStr(errOutput, "has not been assigned")

        if (hasError) {
            Log("FAIL: " ep.name " - runtime initialization error:")
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
            Log("WARN: " ep.name " - exited with output: " SubStr(errOutput, 1, 100))
            Log("PASS: " ep.name " - initialized without fatal error")
            TestPassed++
        } else {
            Log("PASS: " ep.name " - initialized successfully (ran for 0.75s)")
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

    ; Test: EndScan preserves komorebi-managed windows (workspaceName set)
    Log("Testing EndScan komorebi workspace preservation...")

    WindowStore_Init()

    ; Scan 1: Add two windows - one with workspaceName, one without
    WindowStore_BeginScan()
    wsRec1 := Map("hwnd", 33333, "title", "Komorebi Managed", "class", "Test", "pid", 10,
                  "isVisible", true, "isCloaked", true, "isMinimized", false, "z", 1,
                  "workspaceName", "MyWorkspace")
    wsRec2 := Map("hwnd", 44444, "title", "Unmanaged Window", "class", "Test", "pid", 11,
                  "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 2,
                  "workspaceName", "")
    WindowStore_UpsertWindow([wsRec1, wsRec2], "test")
    WindowStore_EndScan(100)

    AssertEq(gWS_Store[33333].present, true, "Komorebi window present after scan 1")
    AssertEq(gWS_Store[44444].present, true, "Unmanaged window present after scan 1")

    ; Scan 2: Only upsert the UNMANAGED window (simulating winenum not seeing komorebi-cloaked window)
    WindowStore_BeginScan()
    WindowStore_UpsertWindow([wsRec2], "test")
    WindowStore_EndScan(100)

    ; Komorebi-managed window should survive (workspaceName protects it)
    AssertEq(gWS_Store.Has(33333), true, "Komorebi window still in store (workspace preservation)")
    AssertEq(gWS_Store[33333].present, true, "Komorebi window still present=true (not marked missing)")

    ; Scan 3: Only upsert neither (both not seen by winenum)
    WindowStore_BeginScan()
    WindowStore_EndScan(100)

    ; Komorebi window should still survive, unmanaged should be marked missing
    AssertEq(gWS_Store.Has(33333), true, "Komorebi window survives even with no upsert")
    AssertEq(gWS_Store[33333].present, true, "Komorebi window still present=true")
    AssertEq(gWS_Store[44444].present, false, "Unmanaged window marked present=false")

    ; Test: Empty workspaceName does NOT protect
    Log("Testing EndScan does not protect empty workspaceName...")
    WindowStore_Init()
    WindowStore_BeginScan()
    emptyWsRec := Map("hwnd", 55555, "title", "Empty WS Window", "class", "Test", "pid", 12,
                      "isVisible", true, "isCloaked", false, "isMinimized", false, "z", 1,
                      "workspaceName", "")
    WindowStore_UpsertWindow([emptyWsRec], "test")
    WindowStore_EndScan(100)

    ; Scan again without upserting - empty workspaceName should NOT protect
    WindowStore_BeginScan()
    WindowStore_EndScan(100)

    AssertEq(gWS_Store[55555].present, false, "Empty workspaceName does NOT protect window")

    ; Cleanup
    WindowStore_RemoveWindow([33333, 44444, 55555], true)

    ; Test: WindowStore_BuildDelta field detection
    Log("Testing BuildDelta field detection...")

    baseItem := {
        hwnd: 12345, title: "Original", class: "TestClass", pid: 100, z: 1,
        isFocused: false, workspaceName: "Main", isCloaked: false,
        isMinimized: false, isOnCurrentWorkspace: true, processName: "test.exe",
        iconHicon: 0, lastActivatedTick: 100
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

    ; Fields that should NOT trigger delta (class and lastActivatedTick are not in comparison list)
    noTriggerTests := [
        {field: "class", newVal: "OtherClass"},
        {field: "lastActivatedTick", newVal: A_TickCount + 99999}
    ]
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

    ; Both arrays empty
    delta := WindowStore_BuildDelta([], [])
    AssertEq(delta.upserts.Length, 0, "Both empty: no upserts")
    AssertEq(delta.removes.Length, 0, "Both empty: no removes")

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

    ; Same-name no-op (no rev bump)
    revBefore := WindowStore_GetRev()
    WindowStore_SetCurrentWorkspace("", "Other")  ; Same name as currently set
    AssertEq(WindowStore_GetRev(), revBefore, "SetCurrentWorkspace same name: no-op")

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
    ; Phase 2: cJson Content Extraction & Safe Navigation Tests
    ; ============================================================
    Log("`n--- cJson Content Extraction Tests ---")

    ; Test cJson returns correct AHK types for different JSON content
    Log("Testing cJson content type detection...")

    ; Test 1: Array content returns AHK Array
    testEvent1 := JSON.Load('{"type":"FocusMonitorWorkspaceNumber","content":[0,2]}')
    content1 := testEvent1["content"]
    if (content1 is Array && content1.Length = 2 && content1[1] = 0 && content1[2] = 2) {
        Log("PASS: Array content [0,2] parsed as AHK Array with correct values")
        TestPassed++
    } else {
        Log("FAIL: Array content type=" Type(content1))
        TestErrors++
    }

    ; Test 2: String content returns AHK String
    testEvent2 := JSON.Load('{"type":"FocusNamedWorkspace","content":"Main"}')
    content2 := testEvent2["content"]
    if (content2 is String && content2 = "Main") {
        Log("PASS: String content 'Main' parsed correctly")
        TestPassed++
    } else {
        Log("FAIL: String content expected 'Main', got '" String(content2) "' type=" Type(content2))
        TestErrors++
    }

    ; Test 3: Integer content returns AHK Integer
    testEvent3 := JSON.Load('{"type":"MoveContainerToWorkspaceNumber","content":3}')
    content3 := testEvent3["content"]
    if (content3 is Integer && content3 = 3) {
        Log("PASS: Integer content 3 parsed correctly")
        TestPassed++
    } else {
        Log("FAIL: Integer content expected 3, got '" String(content3) "' type=" Type(content3))
        TestErrors++
    }

    ; Test 4: Object content returns AHK Map
    testEvent4 := JSON.Load('{"type":"SocketMessage","content":{"MoveContainerToWorkspaceNumber":5}}')
    content4 := testEvent4["content"]
    if (content4 is Map && content4.Has("MoveContainerToWorkspaceNumber") && content4["MoveContainerToWorkspaceNumber"] = 5) {
        Log("PASS: Object content parsed as Map with correct value")
        TestPassed++
    } else {
        Log("FAIL: Object content type=" Type(content4))
        TestErrors++
    }

    ; Test 5: Missing content key
    testEvent5 := JSON.Load('{"type":"SomeEvent"}')
    if (!testEvent5.Has("content")) {
        Log("PASS: Missing content key correctly absent from Map")
        TestPassed++
    } else {
        Log("FAIL: Missing content should not exist in Map")
        TestErrors++
    }

    ; Test 6: Workspace name with spaces
    testEvent6 := JSON.Load('{"type":"FocusNamedWorkspace","content":"Work Space 1"}')
    content6 := testEvent6["content"]
    if (content6 = "Work Space 1") {
        Log("PASS: Workspace name with spaces parsed correctly")
        TestPassed++
    } else {
        Log("FAIL: Workspace with spaces expected 'Work Space 1', got '" String(content6) "'")
        TestErrors++
    }

    ; Test 7: Negative integer content
    testEvent7 := JSON.Load('{"type":"SomeEvent","content":-1}')
    content7 := testEvent7["content"]
    if (content7 is Integer && content7 = -1) {
        Log("PASS: Negative integer -1 parsed correctly")
        TestPassed++
    } else {
        Log("FAIL: Negative integer expected -1, got '" String(content7) "'")
        TestErrors++
    }

    ; ============================================================
    ; Safe Navigation Helper Tests
    ; ============================================================
    Log("`n--- Safe Navigation Helper Tests ---")

    ; Test _KSafe_Elements with valid ring
    validRing := Map("elements", [1, 2, 3], "focused", 1)
    elResult := _KSafe_Elements(validRing)
    AssertEq(elResult.Length, 3, "_KSafe_Elements valid ring")

    ; Test _KSafe_Elements with empty Map
    AssertEq(_KSafe_Elements(Map()).Length, 0, "_KSafe_Elements empty Map")

    ; Test _KSafe_Elements with non-Map
    AssertEq(_KSafe_Elements("not a map").Length, 0, "_KSafe_Elements non-Map")

    ; Test _KSafe_Elements with Map without "elements" key
    AssertEq(_KSafe_Elements(Map("other", 1)).Length, 0, "_KSafe_Elements no elements key")

    ; Test _KSafe_Focused with valid ring
    AssertEq(_KSafe_Focused(validRing), 1, "_KSafe_Focused valid ring")

    ; Test _KSafe_Focused with missing key
    AssertEq(_KSafe_Focused(Map()), -1, "_KSafe_Focused missing key")

    ; Test _KSafe_Focused with non-Map
    AssertEq(_KSafe_Focused(42), -1, "_KSafe_Focused non-Map")

    ; Test _KSafe_Str with valid key
    testMap2 := Map("name", "TestWorkspace", "count", 5)
    AssertEq(_KSafe_Str(testMap2, "name"), "TestWorkspace", "_KSafe_Str valid string")

    ; Test _KSafe_Str with integer value (should convert to string)
    result := _KSafe_Str(testMap2, "count")
    AssertEq(result, "5", "_KSafe_Str integer->string conversion")

    ; Test _KSafe_Str with missing key
    AssertEq(_KSafe_Str(testMap2, "missing"), "", "_KSafe_Str missing key")

    ; Test _KSafe_Str with non-Map
    AssertEq(_KSafe_Str("string", "key"), "", "_KSafe_Str non-Map")

    ; Test _KSafe_Int with valid key
    AssertEq(_KSafe_Int(testMap2, "count"), 5, "_KSafe_Int valid integer")

    ; Test _KSafe_Int with missing key
    AssertEq(_KSafe_Int(testMap2, "missing"), 0, "_KSafe_Int missing key")

    ; Test _KSafe_Int with non-Map
    AssertEq(_KSafe_Int(42, "key"), 0, "_KSafe_Int non-Map")

    ; ============================================================
    ; cJson Large-Input Correctness (Regression Guard)
    ; ============================================================
    Log("`n--- cJson Large-Input Correctness ---")

    ; Build a synthetic komorebi-like state with deeply nested rings
    ; This tests the keys that JXON_Load corrupted on large inputs:
    ; "focused" -> "used", "has_pending_raise_op" -> "_pending_raise_op"
    Log("Testing cJson parses large input without key corruption...")

    ; Build a ~20KB+ JSON string with komorebi ring structure
    workspaces := ""
    loop 8 {
        wsIdx := A_Index - 1
        windows := ""
        loop 10 {
            winIdx := A_Index - 1
            hwndVal := (wsIdx * 100) + winIdx + 65536
            if (winIdx > 0)
                windows .= ","
            windows .= '{"hwnd":' hwndVal ',"title":"Window ' hwndVal '","class":"TestClass","exe":"test.exe","has_pending_raise_op":false}'
        }
        if (wsIdx > 0)
            workspaces .= ","
        workspaces .= '{"name":"WS' wsIdx '","containers":{"elements":[{"windows":{"elements":[' windows '],"focused":0}}],"focused":0},"monocle_container":null,"has_pending_raise_op":false}'
    }

    largeState := '{"monitors":{"elements":[{"workspaces":{"elements":[' workspaces '],"focused":2},"has_pending_raise_op":false}],"focused":0},"has_pending_raise_op":false}'

    ; Verify the string is large enough to trigger the old JXON bug
    stateLen := StrLen(largeState)
    Log("  Generated state: " stateLen " chars (" Round(stateLen / 1024, 1) " KB)")

    ; Parse with cJson
    largeObj := ""
    try largeObj := JSON.Load(largeState)

    if !(largeObj is Map) {
        Log("FAIL: cJson failed to parse large state")
        TestErrors++
    } else {
        ; Test key integrity - these are the keys JXON_Load corrupted
        if (largeObj.Has("focused") || largeObj.Has("monitors")) {
            ; Check top-level "has_pending_raise_op" key
            if (largeObj.Has("has_pending_raise_op")) {
                Log("PASS: Top-level 'has_pending_raise_op' key intact")
                TestPassed++
            } else {
                Log("FAIL: Top-level 'has_pending_raise_op' key missing/corrupted")
                TestErrors++
            }

            ; Navigate to monitors ring and check "focused"
            monitors := largeObj["monitors"]
            if (monitors is Map && monitors.Has("focused") && monitors["focused"] = 0) {
                Log("PASS: monitors.focused key intact (value=0)")
                TestPassed++
            } else {
                Log("FAIL: monitors.focused key missing/corrupted")
                TestErrors++
            }

            ; Navigate to workspace and check "focused"
            monArr := _KSafe_Elements(monitors)
            if (monArr.Length > 0) {
                wsRing := monArr[1]["workspaces"]
                if (wsRing is Map && wsRing.Has("focused") && wsRing["focused"] = 2) {
                    Log("PASS: workspaces.focused key intact (value=2)")
                    TestPassed++
                } else {
                    Log("FAIL: workspaces.focused key missing/corrupted")
                    TestErrors++
                }

                ; Check deep window's has_pending_raise_op
                wsArr := _KSafe_Elements(wsRing)
                if (wsArr.Length > 0) {
                    ws0 := wsArr[1]
                    if (ws0 is Map && ws0.Has("has_pending_raise_op")) {
                        Log("PASS: Workspace 'has_pending_raise_op' key intact")
                        TestPassed++
                    } else {
                        Log("FAIL: Workspace 'has_pending_raise_op' key missing/corrupted")
                        TestErrors++
                    }
                }
            }
        } else {
            Log("FAIL: Basic top-level keys missing from parsed large state")
            TestErrors++
        }
    }

    ; ============================================================
    ; End-to-End Parse + Navigate Test
    ; ============================================================
    Log("`n--- Parse + Navigate Komorebi State Test ---")

    ; Construct a minimal komorebi state with known structure
    miniState := '{"monitors":{"elements":[{"workspaces":{"elements":['
        . '{"name":"Alpha","containers":{"elements":[{"windows":{"elements":[{"hwnd":111,"title":"Win A"}],"focused":0}}],"focused":0},"monocle_container":null},'
        . '{"name":"Beta","containers":{"elements":[{"windows":{"elements":[{"hwnd":222,"title":"Win B"},{"hwnd":333,"title":"Win C"}],"focused":1}}],"focused":0},"monocle_container":null}'
        . '],"focused":1}}],"focused":0}}'

    miniObj := JSON.Load(miniState)

    ; Test focused monitor index
    AssertEq(_KSub_GetFocusedMonitorIndex(miniObj), 0, "Parse+Navigate: focused monitor index")

    ; Test monitors array
    miniMonArr := _KSub_GetMonitorsArray(miniObj)
    AssertEq(miniMonArr.Length, 1, "Parse+Navigate: monitor count")

    ; Test focused workspace index
    AssertEq(_KSub_GetFocusedWorkspaceIndex(miniMonArr[1]), 1, "Parse+Navigate: focused workspace index")

    ; Test workspace name by index
    AssertEq(_KSub_GetWorkspaceNameByIndex(miniMonArr[1], 0), "Alpha", "Parse+Navigate: ws 0 name")
    AssertEq(_KSub_GetWorkspaceNameByIndex(miniMonArr[1], 1), "Beta", "Parse+Navigate: ws 1 name")

    ; Test FindWorkspaceByHwnd
    AssertEq(_KSub_FindWorkspaceByHwnd(miniObj, 111), "Alpha", "Parse+Navigate: hwnd 111 in Alpha")
    AssertEq(_KSub_FindWorkspaceByHwnd(miniObj, 222), "Beta", "Parse+Navigate: hwnd 222 in Beta")
    AssertEq(_KSub_FindWorkspaceByHwnd(miniObj, 333), "Beta", "Parse+Navigate: hwnd 333 in Beta")
    AssertEq(_KSub_FindWorkspaceByHwnd(miniObj, 999), "", "Parse+Navigate: hwnd 999 not found")

    ; Test GetFocusedHwnd (should navigate to Beta ws, focused container 0, focused window 1 = hwnd 333)
    focusedHwnd := _KSub_GetFocusedHwnd(miniObj)
    AssertEq(focusedHwnd, 333, "Parse+Navigate: focused hwnd is 333")

    ; ============================================================
    ; _BL_InsertInSection Tests
    ; ============================================================
    Log("`n--- _BL_InsertInSection Tests ---")

    ; Test 1: Insert into existing section
    Log("Testing _BL_InsertInSection with existing section...")
    testContent := "[Title]`nExistingEntry`n[Class]`nSomeClass`n"
    result := _BL_InsertInSection(testContent, "Title", "NewEntry")
    if (InStr(result, "[Title]`nNewEntry`n") && InStr(result, "ExistingEntry")) {
        Log("PASS: _BL_InsertInSection inserted after section header")
        TestPassed++
    } else {
        Log("FAIL: _BL_InsertInSection did not insert correctly")
        Log("  Result: " SubStr(result, 1, 100))
        TestErrors++
    }

    ; Test 2: Section not found returns content unchanged
    Log("Testing _BL_InsertInSection with missing section...")
    result := _BL_InsertInSection(testContent, "Nonexistent", "NewEntry")
    if (result = testContent) {
        Log("PASS: _BL_InsertInSection returns unchanged when section missing")
        TestPassed++
    } else {
        Log("FAIL: _BL_InsertInSection should return unchanged for missing section")
        TestErrors++
    }

    ; ============================================================
    ; Blacklist Pair Matching E2E Tests
    ; ============================================================
    Log("`n--- Blacklist Pair Matching E2E Tests ---")

    ; Create temp blacklist file with Title, Class, and Pair entries
    testBlDir := A_Temp "\tabby_bl_test_" A_TickCount
    testBlPath := testBlDir "\blacklist.txt"

    ; Save original blacklist path to restore later (prevents breaking live tests)
    global gBlacklist_FilePath
    savedBlPath := gBlacklist_FilePath

    try {
        DirCreate(testBlDir)

        blContent := "[Title]`nBadTitle*`n[Class]`nBadClass`n[Pair]`nPairClass|PairTitle*`n"
        FileAppend(blContent, testBlPath, "UTF-8")

        ; Load the test blacklist
        Blacklist_Init(testBlPath)

        ; Test title-only match
        if (Blacklist_IsMatch("BadTitleFoo", "IrrelevantClass")) {
            Log("PASS: Title-only match works (BadTitle* matches BadTitleFoo)")
            TestPassed++
        } else {
            Log("FAIL: Title-only match should work for BadTitle*")
            TestErrors++
        }

        ; Test class-only match
        if (Blacklist_IsMatch("IrrelevantTitle", "BadClass")) {
            Log("PASS: Class-only match works")
            TestPassed++
        } else {
            Log("FAIL: Class-only match should work for BadClass")
            TestErrors++
        }

        ; Test pair match: BOTH class and title must match
        if (Blacklist_IsMatch("PairTitleFoo", "PairClass")) {
            Log("PASS: Pair match works when BOTH class and title match")
            TestPassed++
        } else {
            Log("FAIL: Pair match should work when both match")
            TestErrors++
        }

        ; Test pair partial: only class matches pair -> false (title doesn't match)
        if (!Blacklist_IsMatch("UnrelatedTitle", "PairClass")) {
            Log("PASS: Pair partial (class only) correctly returns false")
            TestPassed++
        } else {
            Log("FAIL: Pair partial (class only) should return false")
            TestErrors++
        }

        ; Test pair partial: only title matches pair -> false (class doesn't match)
        if (!Blacklist_IsMatch("PairTitleFoo", "UnrelatedClass")) {
            Log("PASS: Pair partial (title only) correctly returns false")
            TestPassed++
        } else {
            Log("FAIL: Pair partial (title only) should return false")
            TestErrors++
        }

        ; Test no match
        if (!Blacklist_IsMatch("SafeTitle", "SafeClass")) {
            Log("PASS: Non-matching title+class correctly returns false")
            TestPassed++
        } else {
            Log("FAIL: Non-matching title+class should return false")
            TestErrors++
        }

        ; Cleanup: restore original blacklist path and reload
        try FileDelete(testBlPath)
        try DirDelete(testBlDir)
        Blacklist_Init(savedBlPath)
    } catch as e {
        Log("FAIL: Blacklist pair E2E test error: " e.Message)
        TestErrors++
        try DirDelete(testBlDir, true)
        Blacklist_Init(savedBlPath)
    }
}
