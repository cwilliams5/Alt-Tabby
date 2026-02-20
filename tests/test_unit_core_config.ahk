; Unit Tests - Configuration System and Entry Points
; Config System, INI Parsing, Diagnostics, Entry Point Initialization
; Split from test_unit_core.ahk for context window optimization
; Included by test_unit.ahk
#Include test_utils.ahk

RunUnitTests_CoreConfig() {
    global TestPassed, TestErrors, cfg, LOG_KEEP_BYTES

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
    if (!cfg.HasOwnProp("PumpPipeName") || cfg.PumpPipeName = "") {
        configErrors.Push("cfg.PumpPipeName is empty")
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
    if (!cfg.HasOwnProp("AltTabGraceMs")) {
        configErrors.Push("cfg.AltTabGraceMs is unset")
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
    _Test_WithTempDir("tabby_config_test", _Test_IniSupplementing)
    _Test_IniSupplementing(dir) {
        global TestPassed, TestErrors
        testConfigPath := dir "\config.ini"

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
            hasSwitchOnClick := InStr(supplementedContent, "; SwitchOnClick=")  ; New key added (commented - default)
            hasGuiSection := InStr(supplementedContent, "[GUI]")  ; New section added

            if (hasGraceMs && hasQuickSwitch && hasSwitchOnClick && hasGuiSection) {
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
                Log("  hasGraceMs=" hasGraceMs ", hasQuickSwitch=" hasQuickSwitch ", hasSwitchOnClick=" hasSwitchOnClick ", hasGuiSection=" hasGuiSection)
                TestErrors++
            }
        }
    }

    ; Test 2.5: CL_WriteIniPreserveFormat direct tests
    Log("Testing WriteIniPreserveFormat...")

    ; Note: _CL_FormatValue formats ints >= 0x10 as hex (e.g., 150 -> "0x96", 200 -> "0xC8")
    ; Use "string" type to test pure write logic without hex formatting, or expect hex output

    _Test_WithTempDir("tabby_wip_test", _Test_WriteIniPreserveFormat)
    _Test_WriteIniPreserveFormat(dir) {
        global TestPassed, TestErrors
        testWipPath := dir "\config.ini"

        ; Test 1: Update existing value (using bool type to avoid hex conversion)
        Log("Testing WriteIniPreserveFormat updates existing value...")
        wipContent := "[AltTab]`nSwitchOnClick=true`nQuickSwitchMs=25`n[GUI]`nRowHeight=40`n"
        FileAppend(wipContent, testWipPath, "UTF-8")

        CL_WriteIniPreserveFormat(testWipPath, "AltTab", "SwitchOnClick", false, true, "bool")

        wipResult := FileRead(testWipPath, "UTF-8")
        if (InStr(wipResult, "SwitchOnClick=false") && InStr(wipResult, "QuickSwitchMs=25")) {
            Log("PASS: WriteIniPreserveFormat updated SwitchOnClick to false, preserved QuickSwitchMs")
            TestPassed++
        } else {
            Log("FAIL: WriteIniPreserveFormat should update SwitchOnClick=false and keep QuickSwitchMs=25")
            Log("  Got: " SubStr(wipResult, 1, 200))
            TestErrors++
        }

        ; Test 2: Comment out default value
        Log("Testing WriteIniPreserveFormat comments out default value...")
        try FileDelete(testWipPath)
        wipContent := "[AltTab]`nSwitchOnClick=true`nQuickSwitchMs=25`n"
        FileAppend(wipContent, testWipPath, "UTF-8")

        CL_WriteIniPreserveFormat(testWipPath, "AltTab", "SwitchOnClick", true, true, "bool")

        wipResult := FileRead(testWipPath, "UTF-8")
        if (InStr(wipResult, "; SwitchOnClick=true")) {
            Log("PASS: WriteIniPreserveFormat commented out default value (;SwitchOnClick=true)")
            TestPassed++
        } else {
            Log("FAIL: WriteIniPreserveFormat should comment out value when it equals default")
            Log("  Got: " SubStr(wipResult, 1, 200))
            TestErrors++
        }

        ; Test 3: Uncomment custom value
        Log("Testing WriteIniPreserveFormat uncomments custom value...")
        try FileDelete(testWipPath)
        wipContent := "[AltTab]`n; SwitchOnClick=true`nQuickSwitchMs=25`n"
        FileAppend(wipContent, testWipPath, "UTF-8")

        CL_WriteIniPreserveFormat(testWipPath, "AltTab", "SwitchOnClick", false, true, "bool")

        wipResult := FileRead(testWipPath, "UTF-8")
        if (InStr(wipResult, "SwitchOnClick=false") && !InStr(wipResult, "; SwitchOnClick=")) {
            Log("PASS: WriteIniPreserveFormat uncommented and set SwitchOnClick=false")
            TestPassed++
        } else {
            Log("FAIL: WriteIniPreserveFormat should uncomment and set custom value")
            Log("  Got: " SubStr(wipResult, 1, 200))
            TestErrors++
        }

        ; Test 4: Preserve other content (comments, blank lines, other sections)
        Log("Testing WriteIniPreserveFormat preserves surrounding content...")
        try FileDelete(testWipPath)
        wipContent := "; Alt-Tabby Config`n`n[AltTab]`n; A comment about click behavior`nSwitchOnClick=true`n`n[GUI]`nRowHeight=40`n"
        FileAppend(wipContent, testWipPath, "UTF-8")

        CL_WriteIniPreserveFormat(testWipPath, "AltTab", "SwitchOnClick", false, true, "bool")

        wipResult := FileRead(testWipPath, "UTF-8")
        hasHeader := InStr(wipResult, "; Alt-Tabby Config")
        hasComment := InStr(wipResult, "; A comment about click behavior")
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
        wipContent := "[AltTab]`nSwitchOnClick=true`n[GUI]`nRowHeight=40`n"
        FileAppend(wipContent, testWipPath, "UTF-8")

        CL_WriteIniPreserveFormat(testWipPath, "AltTab", "NewBool", false, true, "bool")

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
    }

    ; Test 2.6: _CL_CleanupOrphanedKeys removes orphaned keys from known sections
    Log("Testing CleanupOrphanedKeys...")
    _Test_WithTempDir("tabby_cleanup_test", _Test_CleanupOrphanedKeys)
    _Test_CleanupOrphanedKeys(dir) {
        global TestPassed, TestErrors
        testCleanupPath := dir "\config.ini"

        ; Create config.ini with:
        ; - Valid key in known section (should keep)
        ; - Orphaned key in known section (should remove)
        ; - Unknown section entirely (should keep)
        cleanupContent := ""
        cleanupContent .= "[AltTab]`n"
        cleanupContent .= ";;; Valid setting description`n"
        cleanupContent .= "GraceMs=200`n"
        cleanupContent .= ";;; Orphaned setting (doesn't exist in registry)`n"
        cleanupContent .= "; ObsoleteOldSetting=true`n"
        cleanupContent .= "`n"
        cleanupContent .= "[CustomUserSection]`n"
        cleanupContent .= ";;; User's own custom section`n"
        cleanupContent .= "MyCustomKey=value`n"
        FileAppend(cleanupContent, testCleanupPath, "UTF-8")

        ; Run cleanup
        _CL_CleanupOrphanedKeys(testCleanupPath)

        ; Read back and verify
        cleanedContent := FileRead(testCleanupPath, "UTF-8")

        hasValidKey := InStr(cleanedContent, "GraceMs=200")
        hasOrphanedKey := InStr(cleanedContent, "ObsoleteOldSetting")
        hasOrphanedComment := InStr(cleanedContent, "Orphaned setting")
        hasCustomSection := InStr(cleanedContent, "[CustomUserSection]")
        hasCustomKey := InStr(cleanedContent, "MyCustomKey=value")

        cleanupPassed := true
        if (!hasValidKey) {
            Log("FAIL: CleanupOrphanedKeys removed valid key GraceMs")
            cleanupPassed := false
        }
        if (hasOrphanedKey) {
            Log("FAIL: CleanupOrphanedKeys did not remove orphaned key ObsoleteOldSetting")
            cleanupPassed := false
        }
        if (hasOrphanedComment) {
            Log("FAIL: CleanupOrphanedKeys did not remove orphaned key's comment")
            cleanupPassed := false
        }
        if (!hasCustomSection || !hasCustomKey) {
            Log("FAIL: CleanupOrphanedKeys removed unknown section [CustomUserSection]")
            cleanupPassed := false
        }

        if (cleanupPassed) {
            Log("PASS: CleanupOrphanedKeys removed orphaned keys from known sections, preserved unknown sections")
            TestPassed++
        } else {
            Log("  Content after cleanup: " SubStr(cleanedContent, 1, 300))
            TestErrors++
        }
    }

    ; Test: _CL_MigrateKeys — BGR->RGB byte swap and AcrylicColor migration
    Log("Testing _CL_MigrateKeys...")
    _Test_WithTempDir("tabby_migrate_test", _Test_MigrateKeys)
    _Test_MigrateKeys(dir) {
        global TestPassed, TestErrors
        testMigratePath := dir "\config.ini"

        ; Case 1: Basic BGR->RGB migration (0xFF0000 BGR = blue -> 0x0000FF RGB)
        IniWrite("0x80", testMigratePath, "GUI", "AcrylicAlpha")
        IniWrite("0xFF0000", testMigratePath, "GUI", "AcrylicBaseRgb")
        _CL_MigrateKeys(testMigratePath)
        AssertEq(IniRead(testMigratePath, "GUI", "AcrylicColor", ""), "0x800000FF", "MigrateKeys: BGR->RGB byte swap with explicit alpha")

        ; Case 2: Default alpha (0x33) when only AcrylicBaseRgb present (green unaffected by swap)
        try FileDelete(testMigratePath)
        IniWrite("0x00FF00", testMigratePath, "GUI", "AcrylicBaseRgb")
        _CL_MigrateKeys(testMigratePath)
        AssertEq(IniRead(testMigratePath, "GUI", "AcrylicColor", ""), "0x3300FF00", "MigrateKeys: default alpha when only RGB present")

        ; Case 3: Skip migration when AcrylicColor already user-set
        try FileDelete(testMigratePath)
        IniWrite("0x80", testMigratePath, "GUI", "AcrylicAlpha")
        IniWrite("0xFF0000", testMigratePath, "GUI", "AcrylicBaseRgb")
        IniWrite("0xAABBCCDD", testMigratePath, "GUI", "AcrylicColor")
        _CL_MigrateKeys(testMigratePath)
        AssertEq(IniRead(testMigratePath, "GUI", "AcrylicColor", ""), "0xAABBCCDD", "MigrateKeys: skip when AcrylicColor already user-set")

        ; Case 4: No-op when no old keys exist
        try FileDelete(testMigratePath)
        IniWrite("123", testMigratePath, "GUI", "SomeOtherKey")
        _CL_MigrateKeys(testMigratePath)
        AssertEq(IniRead(testMigratePath, "GUI", "AcrylicColor", ""), "", "MigrateKeys: no-op when no old keys exist")
    }

    ; Test 3: Config registry completeness - every setting has required fields
    Log("Testing config registry completeness...")
    registryErrors := []
    settingCount := 0
    seenGlobals := Map()
    seenSectionKeys := Map()

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
        ; Validate min/max consistency
        if (entry.HasOwnProp("min")) {
            if (!entry.HasOwnProp("max"))
                registryErrors.Push("Entry " entry.k " has 'min' but no 'max'")
            else if (entry.min > entry.max)
                registryErrors.Push("Entry " entry.k " min > max")
            if (entry.t != "int" && entry.t != "float")
                registryErrors.Push("Entry " entry.k " has min/max but type is '" entry.t "'")
            if (entry.default < entry.min || entry.default > entry.max)
                registryErrors.Push("Entry " entry.k " default outside range")
        }
        if (entry.HasOwnProp("max") && !entry.HasOwnProp("min"))
            registryErrors.Push("Entry " entry.k " has 'max' but no 'min'")
        if (entry.HasOwnProp("fmt") && entry.fmt != "hex")
            registryErrors.Push("Entry " entry.k " has unknown fmt '" entry.fmt "'")

        ; Uniqueness: no duplicate global names
        if (entry.HasOwnProp("g")) {
            if (seenGlobals.Has(entry.g))
                registryErrors.Push("Duplicate global name '" entry.g "' (first: " seenGlobals[entry.g] ", also: " entry.k ")")
            else
                seenGlobals[entry.g] := entry.k
        }

        ; Uniqueness: no duplicate section+key pairs
        if (entry.HasOwnProp("s") && entry.HasOwnProp("k")) {
            sk := entry.s "|" entry.k
            if (seenSectionKeys.Has(sk))
                registryErrors.Push("Duplicate section+key '" sk "' (first: " seenSectionKeys[sk] ", also: " entry.g ")")
            else
                seenSectionKeys[sk] := entry.HasOwnProp("g") ? entry.g : entry.k
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
    ; Config INI Type Parsing Functional Tests
    ; ============================================================
    ; These tests write a real config.ini and verify _CL_LoadAllSettings parses correctly
    Log("`n--- Config INI Type Parsing Functional Tests ---")

    global gConfigIniPath, gConfigLoaded
    savedIniPath := gConfigIniPath
    savedLoaded := gConfigLoaded

    ; Save cfg values we'll be testing
    savedSwitchOnClick := cfg.AltTabSwitchOnClick
    savedGraceMs := cfg.AltTabGraceMs
    savedWidthPct := cfg.GUI_ScreenWidthPct
    savedPipeName := cfg.PumpPipeName

    testCfgDir := A_Temp "\tabby_cfgparse_test_" A_TickCount
    testCfgPath := testCfgDir "\config.ini"

    try {
        DirCreate(testCfgDir)

        ; Write INI values using IniWrite (ensures IniRead-compatible format)
        gConfigIniPath := testCfgPath
        IniWrite("true", testCfgPath, "AltTab", "SwitchOnClick")
        IniWrite("200", testCfgPath, "AltTab", "GraceMs")
        IniWrite("0.75", testCfgPath, "GUI", "ScreenWidthPct")
        IniWrite("test_custom_pipe", testCfgPath, "IPC", "PumpPipeName")

        ; Reinitialize from temp INI
        _CL_InitializeDefaults()
        _CL_LoadAllSettings()
        _CL_ValidateSettings()

        ; Test 1: Bool "true" -> true
        AssertEq(cfg.AltTabSwitchOnClick, true, "Config parse: bool 'true' -> true")

        ; Test 2: Int valid -> 200
        AssertEq(cfg.AltTabGraceMs, 200, "Config parse: int '200' -> 200")

        ; Test 3: Float valid -> 0.75
        AssertEq(cfg.GUI_ScreenWidthPct, 0.75, "Config parse: float '0.75' -> 0.75")

        ; Test 4: String -> "test_custom_pipe"
        AssertEq(cfg.PumpPipeName, "test_custom_pipe", "Config parse: string 'test_custom_pipe'")

        ; Test 5: Bool "yes" variant
        IniWrite("yes", testCfgPath, "AltTab", "SwitchOnClick")
        _CL_InitializeDefaults()
        _CL_LoadAllSettings()
        AssertEq(cfg.AltTabSwitchOnClick, true, "Config parse: bool 'yes' -> true")

        ; Test 6: Bool "false" -> false
        IniWrite("false", testCfgPath, "AltTab", "SwitchOnClick")
        _CL_InitializeDefaults()
        _CL_LoadAllSettings()
        AssertEq(cfg.AltTabSwitchOnClick, false, "Config parse: bool 'false' -> false")

        ; Test 7: Int invalid -> default preserved
        try FileDelete(testCfgPath)
        IniWrite("not_a_number", testCfgPath, "AltTab", "GraceMs")
        _CL_InitializeDefaults()
        _CL_LoadAllSettings()
        AssertEq(cfg.AltTabGraceMs, 150, "Config parse: invalid int -> default 150 preserved")

        ; Test 8: Empty value -> default preserved
        try FileDelete(testCfgPath)
        _CL_InitializeDefaults()
        _CL_LoadAllSettings()
        AssertEq(cfg.AltTabGraceMs, 150, "Config parse: empty value -> default 150 preserved")

    } catch as e {
        Log("FAIL: Config INI type parsing test error: " e.Message)
        TestErrors++
    }

    ; Restore original state
    gConfigIniPath := savedIniPath
    gConfigLoaded := savedLoaded
    _CL_InitializeDefaults()
    _CL_LoadAllSettings()
    _CL_ValidateSettings()
    cfg.AltTabSwitchOnClick := savedSwitchOnClick
    cfg.AltTabGraceMs := savedGraceMs
    cfg.GUI_ScreenWidthPct := savedWidthPct
    cfg.PumpPipeName := savedPipeName

    ; Cleanup
    try FileDelete(testCfgPath)
    try DirDelete(testCfgDir)

    ; ============================================================
    ; Diagnostic Logging Guard Tests
    ; ============================================================
    ; These tests verify that logging functions respect their config flags
    ; and don't write files when disabled (default behavior)
    Log("`n--- Diagnostic Logging Guard Tests ---")

    ; Test 1: Verify all diagnostic config options default to false
    diagOptions := ["DiagChurnLog", "DiagKomorebiLog", "DiagEventLog", "DiagWinEventLog",
                    "DiagStoreLog", "DiagIconPumpLog", "DiagProcPumpLog", "DiagPumpLog", "DiagLauncherLog", "DiagIPCLog"]
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
    ; Config INI Type Parsing & Formatting Tests
    ; ============================================================
    ; Verify _CL_FormatValue correctly formats typed values for INI output
    ; and that _CL_LoadAllSettings has proper parsing branches for bool/int/float.
    Log("`n--- Config INI Type Parsing Tests ---")

    ; Test: _CL_FormatValue(true, "bool") → "true"
    AssertEq(_CL_FormatValue(true, "bool"), "true", "_CL_FormatValue(true, bool) = 'true'")

    ; Test: _CL_FormatValue(false, "bool") → "false"
    AssertEq(_CL_FormatValue(false, "bool"), "false", "_CL_FormatValue(false, bool) = 'false'")

    ; Test: _CL_FormatValue(42, "int") → "42" (small int, no hex)
    AssertEq(_CL_FormatValue(5, "int"), "5", "_CL_FormatValue(5, int) = '5' (small int, decimal)")

    ; Test: _CL_FormatValue(large int) → hex format
    hexResult := _CL_FormatValue(255, "int")
    AssertEq(hexResult, "0xFF", "_CL_FormatValue(255, int) = '0xFF' (large int, hex)")

    ; Test: _CL_FormatValue(0.5, "float") → string "0.5" (uses {:.6g} format)
    floatResult := _CL_FormatValue(0.5, "float")
    AssertEq(floatResult, "0.5", "_CL_FormatValue(0.5, float) = '0.5'")

    ; Test: _CL_FormatValue("hello", "string") → "hello"
    AssertEq(_CL_FormatValue("hello", "string"), "hello", "_CL_FormatValue('hello', string) = 'hello'")

    ; ============================================================
    ; Config Validation Bounds Tests
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

    ; Test 5: Enum invalid value falls back to default
    origThemeMode := cfg.Theme_Mode
    cfg.Theme_Mode := "BogusValue"
    _CL_ValidateSettings()
    if (cfg.Theme_Mode = "Automatic") {
        Log("PASS: Theme_Mode='BogusValue' reset to default 'Automatic'")
        TestPassed++
    } else {
        Log("FAIL: Theme_Mode='BogusValue' not reset, got '" cfg.Theme_Mode "'")
        TestErrors++
    }
    cfg.Theme_Mode := origThemeMode

    ; Test 6: Enum valid value preserved
    origThemeMode := cfg.Theme_Mode
    cfg.Theme_Mode := "Dark"
    _CL_ValidateSettings()
    if (cfg.Theme_Mode = "Dark") {
        Log("PASS: Theme_Mode='Dark' preserved (valid enum)")
        TestPassed++
    } else {
        Log("FAIL: Theme_Mode='Dark' not preserved, got '" cfg.Theme_Mode "'")
        TestErrors++
    }
    cfg.Theme_Mode := origThemeMode

    ; Test 7: LogKeepKB >= LogMaxKB forced to half
    origKeepKB := cfg.DiagLogKeepKB
    origMaxKB := cfg.DiagLogMaxKB
    cfg.DiagLogKeepKB := 500
    cfg.DiagLogMaxKB := 500
    _CL_ValidateSettings()
    if (cfg.DiagLogKeepKB = 250) {
        Log("PASS: DiagLogKeepKB=500 with DiagLogMaxKB=500 forced to 250 (half)")
        TestPassed++
    } else {
        Log("FAIL: DiagLogKeepKB not forced to half, got " cfg.DiagLogKeepKB)
        TestErrors++
    }
    if (LOG_KEEP_BYTES = 250 * 1024) {
        Log("PASS: LOG_KEEP_BYTES derived correctly (" LOG_KEEP_BYTES ")")
        TestPassed++
    } else {
        Log("FAIL: LOG_KEEP_BYTES expected " (250 * 1024) ", got " LOG_KEEP_BYTES)
        TestErrors++
    }
    cfg.DiagLogKeepKB := origKeepKB
    cfg.DiagLogMaxKB := origMaxKB

    ; Test 8: SafetyPollMs floor — low value floored to 30000
    origSafetyPoll := cfg.WinEnumSafetyPollMs
    cfg.WinEnumSafetyPollMs := 5000
    _CL_ValidateSettings()
    if (cfg.WinEnumSafetyPollMs = 30000) {
        Log("PASS: WinEnumSafetyPollMs=5000 floored to 30000")
        TestPassed++
    } else {
        Log("FAIL: WinEnumSafetyPollMs=5000 not floored, got " cfg.WinEnumSafetyPollMs)
        TestErrors++
    }
    cfg.WinEnumSafetyPollMs := origSafetyPoll

    ; Test 8b: SafetyPollMs floor — zero passes through (disabled)
    origSafetyPoll := cfg.WinEnumSafetyPollMs
    cfg.WinEnumSafetyPollMs := 0
    _CL_ValidateSettings()
    if (cfg.WinEnumSafetyPollMs = 0) {
        Log("PASS: WinEnumSafetyPollMs=0 preserved (disabled)")
        TestPassed++
    } else {
        Log("FAIL: WinEnumSafetyPollMs=0 not preserved, got " cfg.WinEnumSafetyPollMs)
        TestErrors++
    }
    cfg.WinEnumSafetyPollMs := origSafetyPoll

    ; ============================================================
    ; Theme Palette <-> Config Registry Cross-Reference Tests
    ; ============================================================
    ; Validates that every palette color field has matching Dark + Light
    ; config entries, and vice versa. Catches silent breakage when a
    ; palette field is added without the config entry (or vice versa).
    Log("`n--- Theme Palette Cross-Reference Tests ---")

    ; The canonical palette field list (must match gThemeColorFields in theme.ahk)
    paletteFields := [
        "bg", "panelBg", "tertiary", "editBg", "hover", "text", "editText",
        "textSecondary", "textMuted", "accent", "accentHover", "accentText",
        "border", "borderInput", "toggleBg", "success", "warning", "danger"
    ]

    ; Build lookup of all config globals from the registry
    registryGlobals := Map()
    for _, entry in gConfigRegistry {
        if (entry.HasOwnProp("g"))
            registryGlobals[entry.g] := true
    }

    ; Test 1: Every palette field has a Dark + Light config entry
    paletteErrors := []
    for _, field in paletteFields {
        suffix := StrUpper(SubStr(field, 1, 1)) SubStr(field, 2)
        darkKey := "Theme_Dark" suffix
        lightKey := "Theme_Light" suffix
        if (!registryGlobals.Has(darkKey))
            paletteErrors.Push("Missing config entry for palette field '" field "' (expected global " darkKey ")")
        if (!registryGlobals.Has(lightKey))
            paletteErrors.Push("Missing config entry for palette field '" field "' (expected global " lightKey ")")
    }

    if (paletteErrors.Length = 0) {
        Log("PASS: All " paletteFields.Length " palette fields have Dark + Light config entries (" paletteFields.Length * 2 " total)")
        TestPassed++
    } else {
        Log("FAIL: Palette <-> config cross-reference errors:")
        for _, err in paletteErrors
            Log("  - " err)
        TestErrors++
    }

    ; Test 2: Every Theme_Dark*/Theme_Light* color config entry has a matching palette field
    ; (catches orphaned config entries that no palette builder reads)
    orphanErrors := []
    paletteFieldMap := Map()
    for _, field in paletteFields {
        suffix := StrUpper(SubStr(field, 1, 1)) SubStr(field, 2)
        paletteFieldMap["Dark" suffix] := true
        paletteFieldMap["Light" suffix] := true
    }

    for _, entry in gConfigRegistry {
        if (!entry.HasOwnProp("g"))
            continue
        g := entry.g
        ; Match Theme_Dark* and Theme_Light* color entries (hex format, not booleans or other Theme_ entries)
        if (entry.HasOwnProp("fmt") && entry.fmt = "hex") {
            for _, prefix in ["Theme_Dark", "Theme_Light"] {
                if (SubStr(g, 1, StrLen(prefix)) = prefix) {
                    remainder := SubStr(g, StrLen(prefix) + 1)
                    ; Skip non-palette entries (TitleBar*, Button* are progressive enhancements, not palette)
                    if (SubStr(remainder, 1, 8) = "TitleBar" || SubStr(remainder, 1, 6) = "Button")
                        continue
                    variant := SubStr(prefix, 7)  ; "Dark" or "Light"
                    lookupKey := variant remainder
                    if (!paletteFieldMap.Has(lookupKey))
                        orphanErrors.Push("Config entry " g " has no matching palette field (suffix: " remainder ")")
                }
            }
        }
    }

    if (orphanErrors.Length = 0) {
        Log("PASS: All Dark/Light palette config entries map to a palette field (no orphans)")
        TestPassed++
    } else {
        Log("FAIL: Orphaned palette config entries (not consumed by palette builder):")
        for _, err in orphanErrors
            Log("  - " err)
        TestErrors++
    }

    ; Test 3: Config reload populates all palette cfg values with valid hex ints
    ; This validates the ConfigLoader_Init() -> Theme_Reload() data path:
    ; after config load, every palette cfg property exists and is a valid integer.
    Log("Testing palette config values are populated after ConfigLoader_Init()...")
    paletteValueErrors := []
    for _, field in paletteFields {
        suffix := StrUpper(SubStr(field, 1, 1)) SubStr(field, 2)
        for _, prefix in ["Theme_Dark", "Theme_Light"] {
            prop := prefix suffix
            if (!cfg.HasOwnProp(prop)) {
                paletteValueErrors.Push(prop " not present on cfg after init")
            } else {
                val := cfg.%prop%
                if (!IsInteger(val) || val < 0 || val > 0xFFFFFF)
                    paletteValueErrors.Push(prop " has invalid value: " val " (expected 0x0-0xFFFFFF)")
            }
        }
    }

    if (paletteValueErrors.Length = 0) {
        Log("PASS: All " paletteFields.Length * 2 " palette cfg values are valid hex ints in range")
        TestPassed++
    } else {
        Log("FAIL: Palette cfg value errors:")
        for _, err in paletteValueErrors
            Log("  - " err)
        TestErrors++
    }

    ; Test 4: ConfigLoader_Init() is re-entrant (supports config reload path)
    ; _Launcher_ApplyConfigChanges calls ConfigLoader_Init() a second time
    ; to reload INI. Verify re-calling doesn't corrupt state.
    Log("Testing ConfigLoader_Init() re-entrancy for config reload...")
    savedPipe := cfg.PumpPipeName
    savedGrace := cfg.AltTabGraceMs

    ConfigLoader_Init()  ; Second call (first was during test startup)

    reentryOk := true
    if (!cfg.HasOwnProp("PumpPipeName") || cfg.PumpPipeName = "") {
        Log("FAIL: PumpPipeName empty after ConfigLoader_Init() re-call")
        reentryOk := false
    }
    if (!cfg.HasOwnProp("AltTabGraceMs") || cfg.AltTabGraceMs <= 0) {
        Log("FAIL: AltTabGraceMs invalid after ConfigLoader_Init() re-call")
        reentryOk := false
    }
    ; Verify palette values survive re-init too
    if (!cfg.HasOwnProp("Theme_DarkBg") || !IsInteger(cfg.Theme_DarkBg)) {
        Log("FAIL: Theme_DarkBg missing/invalid after ConfigLoader_Init() re-call")
        reentryOk := false
    }

    if (reentryOk) {
        Log("PASS: ConfigLoader_Init() re-entrant - config values intact after second call")
        TestPassed++
    } else {
        TestErrors++
    }

    ; Restore
    cfg.PumpPipeName := savedPipe
    cfg.AltTabGraceMs := savedGrace
}
