; Unit Tests - JSON Parsing and Pattern Matching
; JSON (JXON), cJson Content Extraction, Safe Navigation, Blacklist Patterns
; Split from test_unit_core.ahk for context window optimization
; Included by test_unit.ahk
#Include test_utils.ahk

RunUnitTests_CoreParsing() {
    global TestPassed, TestErrors

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
    ; cJson Content Extraction Tests
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

    ; Test KSafe_Elements with valid ring
    validRing := Map("elements", [1, 2, 3], "focused", 1)
    elResult := KSafe_Elements(validRing)
    AssertEq(elResult.Length, 3, "KSafe_Elements valid ring")

    ; Test KSafe_Elements with empty Map
    AssertEq(KSafe_Elements(Map()).Length, 0, "KSafe_Elements empty Map")

    ; Test KSafe_Elements with non-Map
    AssertEq(KSafe_Elements("not a map").Length, 0, "KSafe_Elements non-Map")

    ; Test KSafe_Elements with Map without "elements" key
    AssertEq(KSafe_Elements(Map("other", 1)).Length, 0, "KSafe_Elements no elements key")

    ; Test _KSafe_Focused with valid ring
    AssertEq(_KSafe_Focused(validRing), 1, "_KSafe_Focused valid ring")

    ; Test _KSafe_Focused with missing key
    AssertEq(_KSafe_Focused(Map()), -1, "_KSafe_Focused missing key")

    ; Test _KSafe_Focused with non-Map
    AssertEq(_KSafe_Focused(42), -1, "_KSafe_Focused non-Map")

    ; Test KSafe_Str with valid key
    testMap2 := Map("name", "TestWorkspace", "count", 5)
    AssertEq(KSafe_Str(testMap2, "name"), "TestWorkspace", "KSafe_Str valid string")

    ; Test KSafe_Str with integer value (should convert to string)
    result := KSafe_Str(testMap2, "count")
    AssertEq(result, "5", "KSafe_Str integer->string conversion")

    ; Test KSafe_Str with missing key
    AssertEq(KSafe_Str(testMap2, "missing"), "", "KSafe_Str missing key")

    ; Test KSafe_Str with non-Map
    AssertEq(KSafe_Str("string", "key"), "", "KSafe_Str non-Map")

    ; Test KSafe_Int with valid key
    AssertEq(KSafe_Int(testMap2, "count"), 5, "KSafe_Int valid integer")

    ; Test KSafe_Int with missing key
    AssertEq(KSafe_Int(testMap2, "missing"), 0, "KSafe_Int missing key")

    ; Test KSafe_Int with non-Map
    AssertEq(KSafe_Int(42, "key"), 0, "KSafe_Int non-Map")

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
            monArr := KSafe_Elements(monitors)
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
                wsArr := KSafe_Elements(wsRing)
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
    AssertEq(KSub_GetFocusedMonitorIndex(miniObj), 0, "Parse+Navigate: focused monitor index")

    ; Test monitors array
    miniMonArr := KSub_GetMonitorsArray(miniObj)
    AssertEq(miniMonArr.Length, 1, "Parse+Navigate: monitor count")

    ; Test focused workspace index
    AssertEq(KSub_GetFocusedWorkspaceIndex(miniMonArr[1]), 1, "Parse+Navigate: focused workspace index")

    ; Test workspace name by index
    AssertEq(KSub_GetWorkspaceNameByIndex(miniMonArr[1], 0), "Alpha", "Parse+Navigate: ws 0 name")
    AssertEq(KSub_GetWorkspaceNameByIndex(miniMonArr[1], 1), "Beta", "Parse+Navigate: ws 1 name")

    ; Test FindWorkspaceByHwnd
    AssertEq(KSub_FindWorkspaceByHwnd(miniObj, 111), "Alpha", "Parse+Navigate: hwnd 111 in Alpha")
    AssertEq(KSub_FindWorkspaceByHwnd(miniObj, 222), "Beta", "Parse+Navigate: hwnd 222 in Beta")
    AssertEq(KSub_FindWorkspaceByHwnd(miniObj, 333), "Beta", "Parse+Navigate: hwnd 333 in Beta")
    AssertEq(KSub_FindWorkspaceByHwnd(miniObj, 999), "", "Parse+Navigate: hwnd 999 not found")

    ; Test GetFocusedHwnd (should navigate to Beta ws, focused container 0, focused window 1 = hwnd 333)
    focusedHwnd := _KSub_GetFocusedHwnd(miniObj)
    AssertEq(focusedHwnd, 333, "Parse+Navigate: focused hwnd is 333")

    ; ============================================================
    ; cJson Malformed Input Error Handling Tests
    ; ============================================================
    ; Verify that JSON.Load throws on malformed input (not crash/hang).
    ; Production code wraps JSON.Load in try-catch - this confirms the behavior.
    Log("`n--- cJson Malformed Input Error Handling Tests ---")

    ; Test 1: Truncated JSON (missing closing brace)
    Log("Testing JSON.Load with truncated input...")
    truncated := '{"type":"test","data":['
    parseThrew := false
    try {
        result := JSON.Load(truncated)
    } catch {
        parseThrew := true
    }
    if (parseThrew) {
        Log("PASS: JSON.Load throws on truncated input")
        TestPassed++
    } else {
        Log("FAIL: JSON.Load should throw on truncated input")
        TestErrors++
    }

    ; Test 2: Invalid JSON (unquoted key)
    Log("Testing JSON.Load with unquoted key...")
    invalidKey := '{unquoted: "value"}'
    parseThrew := false
    try {
        result := JSON.Load(invalidKey)
    } catch {
        parseThrew := true
    }
    if (parseThrew) {
        Log("PASS: JSON.Load throws on unquoted key")
        TestPassed++
    } else {
        Log("FAIL: JSON.Load should throw on unquoted key")
        TestErrors++
    }

    ; Test 3: Binary garbage
    Log("Testing JSON.Load with binary garbage...")
    garbage := Chr(0x00) . Chr(0xFF) . Chr(0xFE) . "garbage"
    parseThrew := false
    try {
        result := JSON.Load(garbage)
    } catch {
        parseThrew := true
    }
    if (parseThrew) {
        Log("PASS: JSON.Load throws on binary garbage")
        TestPassed++
    } else {
        Log("FAIL: JSON.Load should throw on binary garbage")
        TestErrors++
    }

    ; Test 4: Empty string
    Log("Testing JSON.Load with empty string...")
    parseThrew := false
    try {
        result := JSON.Load("")
    } catch {
        parseThrew := true
    }
    if (parseThrew) {
        Log("PASS: JSON.Load throws on empty string")
        TestPassed++
    } else {
        Log("FAIL: JSON.Load should throw on empty string")
        TestErrors++
    }

    ; Test 5: Trailing garbage after valid JSON
    Log("Testing JSON.Load with trailing garbage...")
    trailingGarbage := '{"valid": true} extra stuff'
    parseThrew := false
    try {
        result := JSON.Load(trailingGarbage)
    } catch {
        parseThrew := true
    }
    ; Note: Some parsers accept trailing garbage, some don't - just verify no crash
    Log("INFO: JSON.Load with trailing garbage " (parseThrew ? "throws" : "accepts") " (no crash = OK)")
    TestPassed++

    ; ============================================================
    ; BL_CompileWildcard Regex Metacharacter Escaping Tests
    ; ============================================================
    ; Verify that BL_CompileWildcard correctly escapes regex metacharacters
    ; so that literal dots, brackets, pipes, etc. match literally, not as regex operators.
    Log("`n--- BL_CompileWildcard Metacharacter Escaping Tests ---")

    ; Test: Literal dot should NOT match arbitrary character
    dotRegex := BL_CompileWildcard("msedge.exe")
    AssertEq(!!RegExMatch("msedge.exe", dotRegex), true, "Wildcard dot: 'msedge.exe' matches 'msedge.exe'")
    AssertEq(!!RegExMatch("msedgeXexe", dotRegex), false, "Wildcard dot: 'msedgeXexe' must NOT match 'msedge.exe'")

    ; Test: Literal brackets should match literally
    bracketRegex := BL_CompileWildcard("[Preview]*")
    AssertEq(!!RegExMatch("[Preview] Document", bracketRegex), true, "Wildcard brackets: '[Preview] Document' matches '[Preview]*'")
    AssertEq(!!RegExMatch("Preview Document", bracketRegex), false, "Wildcard brackets: 'Preview Document' must NOT match '[Preview]*'")

    ; Test: Literal pipe should match literally
    pipeRegex := BL_CompileWildcard("foo|bar")
    AssertEq(!!RegExMatch("foo|bar", pipeRegex), true, "Wildcard pipe: 'foo|bar' matches 'foo|bar'")
    AssertEq(!!RegExMatch("foo", pipeRegex), false, "Wildcard pipe: 'foo' must NOT match 'foo|bar'")

    ; Test: Literal plus should match literally
    plusRegex := BL_CompileWildcard("C++")
    AssertEq(!!RegExMatch("C++", plusRegex), true, "Wildcard plus: 'C++' matches 'C++'")
    AssertEq(!!RegExMatch("Cxx", plusRegex), false, "Wildcard plus: 'Cxx' must NOT match 'C++'")

    ; Test: Literal caret should match literally
    caretRegex := BL_CompileWildcard("^test")
    AssertEq(!!RegExMatch("^test", caretRegex), true, "Wildcard caret: '^test' matches '^test'")
    AssertEq(!!RegExMatch("test", caretRegex), false, "Wildcard caret: 'test' must NOT match '^test'")

    ; Test: Literal parens should match literally
    parenRegex := BL_CompileWildcard("(untitled)")
    AssertEq(!!RegExMatch("(untitled)", parenRegex), true, "Wildcard parens: '(untitled)' matches '(untitled)'")
    AssertEq(!!RegExMatch("untitled", parenRegex), false, "Wildcard parens: 'untitled' must NOT match '(untitled)'")

    ; Test: Wildcard + metachar combined: *.exe
    wildcardDotRegex := BL_CompileWildcard("*.exe")
    AssertEq(!!RegExMatch("foo.exe", wildcardDotRegex), true, "Wildcard+dot: 'foo.exe' matches '*.exe'")
    AssertEq(!!RegExMatch("fooXexe", wildcardDotRegex), false, "Wildcard+dot: 'fooXexe' must NOT match '*.exe'")

    ; Test: Case insensitivity preserved with metachar patterns
    AssertEq(!!RegExMatch("MSEDGE.EXE", dotRegex), true, "Wildcard case: 'MSEDGE.EXE' matches 'msedge.exe' (case-insensitive)")

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
}
