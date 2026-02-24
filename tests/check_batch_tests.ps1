# check_batch_tests.ps1 - Batched test-file analysis checks
# Combines test-related checks into one PowerShell process to reduce startup overhead.
# Sub-checks: test_globals, test_functions, test_assertions, no_wmi_in_tests,
#             test_undefined_calls, test_cfg_completeness, test_production_calls
# Shared file cache: all src/ files (excluding lib/) + all test files read once.
#
# Usage: powershell -File tests\check_batch_tests.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all pass, 1 = any check failed

param(
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

# === Resolve directories ===
if (-not $SourceDir) {
    $SourceDir = (Resolve-Path "$PSScriptRoot\..\src").Path
}
if (-not (Test-Path $SourceDir)) {
    Write-Host "  ERROR: Source directory not found: $SourceDir" -ForegroundColor Red
    exit 1
}

$projectRoot = (Resolve-Path "$SourceDir\..").Path
$testsDir = Join-Path $projectRoot "tests"

if (-not (Test-Path $testsDir)) {
    Write-Host "  PASS: No tests directory found - skipping" -ForegroundColor Green
    exit 0
}

$srcDirNorm = [System.IO.Path]::GetFullPath($SourceDir).ToLower()

# === Shared file cache (single read for all sub-checks) ===
$srcFiles = @(Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse |
    Where-Object { $_.FullName -notlike "*\lib\*" })
$testFiles = @(Get-ChildItem -Path $testsDir -Filter "*.ahk" -File)

# Cache: filePath -> string[] (lines), filePath -> string (full text)
$script:fileContentCache = @{}
$script:fileTextCache = @{}
foreach ($f in $srcFiles) {
    $text = [System.IO.File]::ReadAllText($f.FullName)
    $script:fileTextCache[$f.FullName] = $text
    $script:fileContentCache[$f.FullName] = $text -split "`r?`n"
}
foreach ($f in $testFiles) {
    $text = [System.IO.File]::ReadAllText($f.FullName)
    $script:fileTextCache[$f.FullName] = $text
    $script:fileContentCache[$f.FullName] = $text -split "`r?`n"
}

function Get-CachedFileLines($path) {
    if (-not $script:fileContentCache.ContainsKey($path)) {
        $text = [System.IO.File]::ReadAllText($path)
        $script:fileTextCache[$path] = $text
        $script:fileContentCache[$path] = $text -split "`r?`n"
    }
    return $script:fileContentCache[$path]
}

function Get-CachedFileText($path) {
    if (-not $script:fileTextCache.ContainsKey($path)) {
        $script:fileTextCache[$path] = [System.IO.File]::ReadAllText($path)
    }
    return $script:fileTextCache[$path]
}

# === Sub-check tracking ===
$subTimings = [System.Collections.ArrayList]::new()
$anyFailed = $false
$failOutput = [System.Text.StringBuilder]::new()

# === Shared constants ===
$MIN_GLOBAL_NAME_LENGTH = 2
$AHK_BUILTINS = @('true', 'false', 'unset', 'this', 'super')
$AHK_KEYWORDS = @(
    'if', 'else', 'while', 'for', 'loop', 'switch', 'case', 'catch',
    'finally', 'try', 'class', 'return', 'throw', 'static', 'global',
    'local', 'until', 'not', 'and', 'or', 'is', 'in', 'contains',
    'new', 'super', 'this', 'true', 'false', 'unset', 'isset'
)

# === Shared helpers ===

function BT_CleanLine {
    param([string]$line)
    if ($line.Length -eq 0) { return '' }
    $trimmed = $line.TrimStart()
    if ($trimmed.Length -eq 0) { return '' }
    if ($trimmed[0] -eq ';') { return '' }
    $cleaned = $line
    if ($line.IndexOf('"') -ge 0) {
        $cleaned = $cleaned -replace '"[^"]*"', '""'
    }
    if ($line.IndexOf("'") -ge 0) {
        $cleaned = $cleaned -replace "'[^']*'", "''"
    }
    if ($cleaned.IndexOf(';') -ge 0) {
        $cleaned = $cleaned -replace '\s;.*$', ''
    }
    return $cleaned
}

function BT_CountBraces {
    param([string]$line)
    $opens = 0; $closes = 0
    foreach ($c in $line.ToCharArray()) {
        if ($c -eq '{') { $opens++ }
        elseif ($c -eq '}') { $closes++ }
    }
    return @($opens, $closes)
}

function BT_StripNested {
    param([string]$s)
    $result = [System.Text.StringBuilder]::new($s.Length)
    $depth = 0
    foreach ($c in $s.ToCharArray()) {
        if ($c -eq '(' -or $c -eq '[') { $depth++ }
        elseif ($c -eq ')' -or $c -eq ']') { if ($depth -gt 0) { $depth-- } }
        elseif ($depth -eq 0) { [void]$result.Append($c) }
    }
    return $result.ToString()
}

function BT_ExtractGlobalNames {
    param([string]$decl)
    $names = @()
    $stripped = BT_StripNested $decl
    foreach ($part in $stripped -split ',') {
        $trimmed = $part.Trim()
        if ($trimmed -match '^(\w+)') {
            $name = $Matches[1]
            if ($name.Length -ge $MIN_GLOBAL_NAME_LENGTH -and $name -notin $AHK_BUILTINS) {
                $names += $name
            }
        }
    }
    return $names
}

function BT_GetFileScopeGlobalDefs {
    param([string]$filePath)

    $defs = @{}
    if (-not (Test-Path $filePath)) { return $defs }

    $lines = Get-CachedFileLines $filePath
    $depth = 0
    $inFunc = $false
    $funcDepth = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = BT_CleanLine $lines[$i]
        if ($cleaned -eq '') { continue }

        $braces = BT_CountBraces $cleaned

        if (-not $inFunc -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(') {
            $fname = $Matches[1].ToLower()
            if ($fname -notin $AHK_KEYWORDS -and $cleaned -match '\{') {
                $inFunc = $true
                $funcDepth = $depth
            }
        }

        $depth += $braces[0] - $braces[1]

        if ($inFunc -and $depth -le $funcDepth) {
            $inFunc = $false
            $funcDepth = -1
        }

        if (-not $inFunc -and $cleaned -match '^\s*global\s+(.+)') {
            $declPart = $Matches[1]
            foreach ($name in (BT_ExtractGlobalNames $declPart)) {
                $escapedName = [regex]::Escape($name)
                if ($declPart -match "\b$escapedName\s*:=") {
                    $defs[$name] = $true
                }
            }
        }
    }
    return $defs
}

function BT_GetFunctionGlobalUsage {
    param([string]$filePath)

    $usages = [System.Collections.ArrayList]::new()
    if (-not (Test-Path $filePath)) { return $usages }

    $lines = Get-CachedFileLines $filePath
    $depth = 0
    $inFunc = $false
    $funcDepth = -1
    $funcName = ""
    $funcGlobals = @{}

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = BT_CleanLine $lines[$i]
        if ($cleaned -eq '') { continue }

        $braces = BT_CountBraces $cleaned

        if (-not $inFunc -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(') {
            $fname = $Matches[1]
            if ($fname.ToLower() -notin $AHK_KEYWORDS -and $cleaned -match '\{') {
                $inFunc = $true
                $funcName = $fname
                $funcDepth = $depth
                $funcGlobals = @{}
            }
        }

        $depth += $braces[0] - $braces[1]

        if ($inFunc) {
            if ($cleaned -match '^\s*global\s+(.+)') {
                foreach ($name in (BT_ExtractGlobalNames $Matches[1])) {
                    if (-not $funcGlobals.ContainsKey($name)) {
                        $funcGlobals[$name] = $true
                        [void]$usages.Add([PSCustomObject]@{
                            Name     = $name
                            FuncName = $funcName
                            Line     = $i + 1
                        })
                    }
                }
            }

            if ($depth -le $funcDepth) {
                $inFunc = $false
                $funcDepth = -1
            }
        }
    }
    return $usages
}

function BT_ResolveAhkInclude {
    param(
        [string]$rawLine,
        [string]$currentFileDir,
        [string]$scriptDir
    )

    $path = $rawLine.Trim()
    $path = $path -replace '^\s*#Include\s+', ''
    $path = $path -replace '^\*i\s+', ''
    $path = $path.Trim('"', "'")
    # Strip inline comments (e.g., "#Include foo.ahk  ; description")
    $path = $path -replace '\s+;.*$', ''
    $path = $path -replace '%A_ScriptDir%', $scriptDir

    try {
        if (-not [System.IO.Path]::IsPathRooted($path)) {
            $path = Join-Path $currentFileDir $path
        }
        $path = [System.IO.Path]::GetFullPath($path)
    } catch {
        return $null  # Illegal characters (e.g., C-style #include <windows.h> in comments)
    }

    if (Test-Path $path) { return $path }
    return $null
}

$script:includeLineCache = @{}
$script:includeTreeCache = @{}

function BT_BuildIncludeTree {
    param(
        [string]$entryFile,
        [string]$scriptDir
    )

    $entryFull = [System.IO.Path]::GetFullPath($entryFile)
    $cacheKey = "$entryFull|$scriptDir"
    if ($script:includeTreeCache.ContainsKey($cacheKey)) {
        return $script:includeTreeCache[$cacheKey]
    }

    $visited = @{}
    $queue = [System.Collections.Queue]::new()
    $tree = [System.Collections.ArrayList]::new()

    $queue.Enqueue($entryFull)
    $visited[$entryFull.ToLower()] = $true
    [void]$tree.Add($entryFull)

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not (Test-Path $current)) { continue }

        $currentDir = [System.IO.Path]::GetDirectoryName($current)

        if (-not $script:includeLineCache.ContainsKey($current)) {
            $allLines = Get-CachedFileLines $current
            $script:includeLineCache[$current] = @($allLines | Where-Object { $_ -match '^\s*#Include\s+' })
        }

        foreach ($line in $script:includeLineCache[$current]) {
            $resolved = BT_ResolveAhkInclude $line $currentDir $scriptDir
            if ($resolved) {
                $key = $resolved.ToLower()
                if (-not $visited.ContainsKey($key)) {
                    $visited[$key] = $true
                    [void]$tree.Add($resolved)
                    $queue.Enqueue($resolved)
                }
            }
        }
    }

    $script:includeTreeCache[$cacheKey] = $tree
    return $tree
}

# ============================================================
# Sub-check 1: test_globals
# Verify test include chains provide all globals needed by production code
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Pass 1: Collect all file-scope global definitions from src/
$knownGlobals = @{}
$globalDefsCache = @{}
$script:funcUsageCache = @{}

foreach ($file in $srcFiles) {
    $defs = BT_GetFileScopeGlobalDefs $file.FullName
    $globalDefsCache[$file.FullName] = $defs
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    foreach ($name in $defs.Keys) {
        if (-not $knownGlobals.ContainsKey($name)) {
            $knownGlobals[$name] = $relPath
        }
    }
}

# Find test entry points (files with #Requires, not skipped)
$entryPoints = [System.Collections.ArrayList]::new()
$skipped = 0

foreach ($tf in $testFiles) {
    $firstLines = @(Get-CachedFileLines $tf.FullName | Select-Object -First 10)
    $hasRequires = $false
    $hasSkip = $false
    foreach ($line in $firstLines) {
        if ($line -match '^\s*#Requires\s+AutoHotkey') { $hasRequires = $true }
        if ($line -match ';\s*check_test_globals:\s*skip') { $hasSkip = $true }
    }
    if ($hasRequires -and -not $hasSkip) {
        [void]$entryPoints.Add($tf)
    } elseif ($hasRequires -and $hasSkip) {
        $skipped++
    }
}

$tgIssues = [System.Collections.ArrayList]::new()

if ($entryPoints.Count -gt 0) {
    foreach ($entry in $entryPoints) {
        $scriptDir = $entry.DirectoryName
        $tree = BT_BuildIncludeTree $entry.FullName $scriptDir

        $availableGlobals = @{}
        foreach ($file in $tree) {
            if (-not $globalDefsCache.ContainsKey($file)) {
                $globalDefsCache[$file] = BT_GetFileScopeGlobalDefs $file
            }
            $defs = $globalDefsCache[$file]
            foreach ($name in $defs.Keys) {
                $availableGlobals[$name] = $true
            }
        }

        $relEntry = $entry.FullName.Replace("$projectRoot\", '')
        foreach ($file in $tree) {
            $fileLower = $file.ToLower()
            if (-not $fileLower.StartsWith($srcDirNorm)) { continue }

            # Pre-filter: skip src files that don't mention any of the test's available globals
            # (can't have undeclared usage of globals it doesn't reference at all)
            if ($availableGlobals.Count -gt 0 -and $knownGlobals.Count -gt 0) {
                $fileLines = Get-CachedFileLines $file
                $fileText = Get-CachedFileText $file
                $hasRelevantGlobal = $false
                foreach ($gName in $knownGlobals.Keys) {
                    if (-not $availableGlobals.ContainsKey($gName)) {
                        if ($fileText.IndexOf($gName, [System.StringComparison]::Ordinal) -ge 0) {
                            $hasRelevantGlobal = $true; break
                        }
                    }
                }
                if (-not $hasRelevantGlobal) { continue }
            }

            if (-not $script:funcUsageCache.ContainsKey($file)) {
                $script:funcUsageCache[$file] = BT_GetFunctionGlobalUsage $file
            }
            $usages = $script:funcUsageCache[$file]
            $relFile = $file.Replace("$projectRoot\", '')

            foreach ($usage in $usages) {
                $name = $usage.Name
                if ($knownGlobals.ContainsKey($name) -and -not $availableGlobals.ContainsKey($name)) {
                    [void]$tgIssues.Add([PSCustomObject]@{
                        TestEntry = $relEntry
                        SrcFile   = $relFile
                        Line      = $usage.Line
                        FuncName  = $usage.FuncName
                        Global    = $name
                        DefinedIn = $knownGlobals[$name]
                    })
                }
            }
        }
    }
}

$tgDeduped = @($tgIssues | Sort-Object TestEntry, Global -Unique)

if ($tgDeduped.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($tgDeduped.Count) global(s) missing from test include chains.")
    [void]$failOutput.AppendLine("  Production code uses globals not available in the test's #Include tree.")
    [void]$failOutput.AppendLine("  Fix: add 'global <name> := <value>' to the test file, or #Include the file that defines it.")

    $grouped = $tgDeduped | Group-Object TestEntry
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("")
        [void]$failOutput.AppendLine("    Test: $($group.Name)")
        foreach ($issue in $group.Group | Sort-Object SrcFile, Line) {
            [void]$failOutput.AppendLine("      $($issue.SrcFile):$($issue.Line) - $($issue.FuncName)() needs '$($issue.Global)'")
            [void]$failOutput.AppendLine("        (defined in $($issue.DefinedIn))")
        }
    }
}

$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_test_globals"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 2: test_functions
# Detect test files calling test utility functions without including test_utils.ahk
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$TEST_UTIL_FUNCTIONS = @(
    'Log',
    'AssertEq',
    'AssertNeq',
    'AssertTrue',
    'AssertFalse',
    'WaitForFlag',
    '_Test_RunSilent',
    '_Test_RunWaitSilent'
)

function BT_GetFunctionCalls {
    param([string]$filePath)

    $calls = @{}
    if (-not (Test-Path $filePath)) { return $calls }

    $lines = Get-CachedFileLines $filePath
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = BT_CleanLine $lines[$i]
        if ($cleaned -eq '') { continue }

        foreach ($m in [regex]::Matches($cleaned, '\b([A-Za-z_]\w*)\s*\(')) {
            $funcName = $m.Groups[1].Value
            if (-not $calls.ContainsKey($funcName)) {
                $calls[$funcName] = $i + 1
            }
        }
    }

    return $calls
}

function BT_GetFunctionDefinitions {
    param([string]$filePath)

    $defs = @{}
    if (-not (Test-Path $filePath)) { return $defs }

    $lines = Get-CachedFileLines $filePath
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = BT_CleanLine $lines[$i]
        if ($cleaned -eq '') { continue }

        if ($cleaned -match '^\s*(?:static\s+)?([A-Za-z_]\w*)\s*\([^()]*\)\s*\{') {
            $funcName = $Matches[1]
            if ($funcName -notin @('if', 'while', 'for', 'switch', 'catch', 'loop')) {
                $defs[$funcName] = $i + 1
            }
        }
    }

    return $defs
}

# Filter test files for sub-check 2 (exclude run_tests.ahk)
$tfNonEntry = @($testFiles | Where-Object { $_.Name -ne 'run_tests.ahk' })

$tfIssues = [System.Collections.ArrayList]::new()

foreach ($file in $tfNonEntry) {
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    $calls = BT_GetFunctionCalls $file.FullName

    $usedTestFunctions = @()
    foreach ($func in $TEST_UTIL_FUNCTIONS) {
        if ($calls.ContainsKey($func)) {
            $usedTestFunctions += @{ Name = $func; Line = $calls[$func] }
        }
    }

    if ($usedTestFunctions.Count -eq 0) {
        continue
    }

    $includeChain = BT_BuildIncludeTree $file.FullName $file.DirectoryName

    $hasTestUtils = $false
    foreach ($inc in $includeChain) {
        if ($inc -match 'test_utils\.ahk$') {
            $hasTestUtils = $true
            break
        }
    }

    if ($hasTestUtils) {
        continue
    }

    $availableDefs = @{}
    foreach ($inc in $includeChain) {
        $defs = BT_GetFunctionDefinitions $inc
        foreach ($k in $defs.Keys) {
            if (-not $availableDefs.ContainsKey($k)) {
                $availableDefs[$k] = $defs[$k]
            }
        }
    }

    foreach ($usage in $usedTestFunctions) {
        if (-not $availableDefs.ContainsKey($usage.Name)) {
            [void]$tfIssues.Add([PSCustomObject]@{
                File     = $relPath
                Line     = $usage.Line
                Function = $usage.Name
            })
        }
    }
}

if ($tfIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($tfIssues.Count) undefined test function reference(s) found.")
    [void]$failOutput.AppendLine("  These files use test utility functions without including test_utils.ahk.")
    [void]$failOutput.AppendLine("  Running them standalone will show AHK warning popups about undefined variables.")
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  Fix: Add '#Include test_utils.ahk' near the top of each file.")

    $grouped = $tfIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("")
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): calls '$($issue.Function)' without including test_utils.ahk")
        }
    }
}

$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_test_functions"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 3: test_assertions
# Detect test functions with no assertions, constant-vs-constant
# assertions, and always-pass if/else branches.
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$TA_SUPPRESSION = 'lint-ignore: test-assertions'

# Helper function name patterns that are exempt from needing assertions
$TA_HELPER_PATTERNS = @(
    '^_',               # Private helpers
    'Setup',            # Test setup functions
    'Helper',           # Explicit helpers
    'Mock',             # Mock definitions
    'Reset',            # State reset
    'Init',             # Initialization
    'Cleanup',          # Teardown
    'Create.*Items',    # Test data factories
    'Build.*Data',      # Test data builders
    'Launch',           # Process launchers
    'WaitFor',          # Polling utilities
    'RunAll',           # Test suite runners that call sub-tests
    'RunLiveTests$',    # Live test dispatcher (calls sub-functions)
    '_On\w+'            # IPC/event callback handlers (e.g. Test_OnServerMessage)
)
$taHelperRegex = [regex]::new(($TA_HELPER_PATTERNS -join '|'), 'Compiled, IgnoreCase')

# Assertion patterns that indicate a test is verifying something
$TA_ASSERT_PATTERNS = @(
    'AssertEq\s*\(',
    'AssertNeq\s*\(',
    'AssertTrue\s*\(',
    'AssertFalse\s*\(',
    'Log\(\s*"FAIL',
    'Log\(\s*"PASS'
)
$taAssertRegex = [regex]::new(($TA_ASSERT_PATTERNS -join '|'), 'Compiled')

# Constant literal pattern for both sides of an assertion
$taConstantAssertRegex = [regex]::new(
    'Assert(?:Eq|Neq|True|False)\s*\(\s*(?:true|false|0|1|"[^"]*")\s*,\s*(?:true|false|0|1|"[^"]*")\s*(?:,|\))',
    'Compiled, IgnoreCase'
)

$taIssues = [System.Collections.ArrayList]::new()

foreach ($file in $testFiles) {
    $lines = Get-CachedFileLines $file.FullName
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    # Pre-filter: skip files without any function definitions
    $joined = [string]::Join("`n", $lines)
    if ($joined.IndexOf('(', [System.StringComparison]::Ordinal) -lt 0) { continue }

    # Extract test functions and their bodies
    $depth = 0
    $inFunc = $false
    $funcDepth = -1
    $funcName = ""
    $funcStartLine = 0
    $funcBody = [System.Text.StringBuilder]::new()
    $funcHasSuppression = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        $cleaned = BT_CleanLine $raw
        if ($cleaned -eq '') {
            if ($inFunc) { [void]$funcBody.AppendLine($raw) }
            continue
        }

        $braces = BT_CountBraces $cleaned

        # Detect function start
        if (-not $inFunc -and $cleaned -match '^\s*(?:static\s+)?([A-Za-z_]\w*)\s*\([^)]*\)\s*\{?') {
            $fname = $Matches[1]
            if ($fname.ToLower() -notin $AHK_KEYWORDS) {
                # Check if the opening brace is on this line or next
                $hasBrace = $cleaned -match '\{'
                if (-not $hasBrace -and ($i + 1) -lt $lines.Count) {
                    $nextCleaned = BT_CleanLine $lines[$i + 1]
                    if ($nextCleaned -match '^\s*\{') { $hasBrace = $true }
                }
                if ($hasBrace) {
                    $inFunc = $true
                    $funcName = $fname
                    $funcStartLine = $i + 1
                    $funcDepth = $depth
                    $funcBody = [System.Text.StringBuilder]::new()
                    $funcHasSuppression = $raw.Contains($TA_SUPPRESSION)
                }
            }
        }

        $depth += $braces[0] - $braces[1]

        if ($inFunc) {
            [void]$funcBody.AppendLine($raw)

            if ($depth -le $funcDepth) {
                # Function ended — analyze it
                $inFunc = $false
                $funcDepth = -1
                $bodyText = $funcBody.ToString()

                # Skip suppressed functions
                if ($funcHasSuppression -or $bodyText.Contains($TA_SUPPRESSION)) {
                    continue
                }

                # Skip helper/utility functions
                if ($taHelperRegex.IsMatch($funcName)) { continue }

                # Skip functions that are clearly not test functions
                # (must start with Test, RunTests_, or RunLiveTests_)
                $isTestFunc = $funcName -match '^(?:Test|RunTests_|RunLiveTests_)'
                if (-not $isTestFunc) { continue }

                # Check 3a: No assertions at all
                if (-not $taAssertRegex.IsMatch($bodyText)) {
                    [void]$taIssues.Add([PSCustomObject]@{
                        File = $relPath; Line = $funcStartLine
                        Function = $funcName; Kind = 'no-assertions'
                        Detail = "Test function has no assertions (no AssertEq/AssertTrue/Log PASS/FAIL)"
                    })
                }

                # Check 3c: Constant-vs-constant assertions
                $constMatches = $taConstantAssertRegex.Matches($bodyText)
                foreach ($cm in $constMatches) {
                    # Find the line number within the function body
                    $matchOffset = $cm.Index
                    $bodyUpToMatch = $bodyText.Substring(0, $matchOffset)
                    $lineOffset = ($bodyUpToMatch -split "`n").Count - 1
                    $trimmedMatch = $cm.Value.TrimEnd(',', ')')
                    [void]$taIssues.Add([PSCustomObject]@{
                        File = $relPath; Line = $funcStartLine + $lineOffset
                        Function = $funcName; Kind = 'constant-assertion'
                        Detail = "Assertion compares two constants: $trimmedMatch"
                    })
                }
            }
        }
    }
}

if ($taIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($taIssues.Count) test assertion quality issue(s) found.")
    [void]$failOutput.AppendLine("  Tests without assertions pass unconditionally and provide no regression protection.")
    [void]$failOutput.AppendLine("  Fix: add meaningful assertions, or suppress with '; lint-ignore: test-assertions'.")

    $grouped = $taIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): $($issue.Function)() [$($issue.Kind)]")
            [void]$failOutput.AppendLine("        $($issue.Detail)")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_test_assertions"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 4: no_wmi_in_tests
# Ban WMI ComObjGet("winmgmts:") in test files.
# WMI COM calls degrade under test process churn — use
# _Test_EnumProcesses/CountProcesses/FindChildProcesses instead.
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$wmiIssues = [System.Collections.ArrayList]::new()
$wmiPattern = [regex]::new('ComObjGet\s*\(\s*"winmgmts', 'Compiled')

foreach ($file in $testFiles) {
    $text = Get-CachedFileText $file.FullName
    $lines = Get-CachedFileLines $file.FullName

    if (-not $wmiPattern.IsMatch($text)) { continue }

    $relPath = $file.FullName.Replace("$projectRoot\", '')
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        if ($raw -match '^\s*;') { continue }
        if ($wmiPattern.IsMatch($raw)) {
            [void]$wmiIssues.Add([PSCustomObject]@{
                File = $relPath
                Line = $i + 1
                Code = $raw.Trim()
            })
        }
    }
}

if ($wmiIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($wmiIssues.Count) WMI usage(s) found in test files.")
    [void]$failOutput.AppendLine("  WMI COM calls (ComObjGet(`"winmgmts:`")) degrade under process churn and hang.")
    [void]$failOutput.AppendLine("  Use _Test_EnumProcesses/_Test_CountProcesses/_Test_FindChildProcesses from test_utils.ahk instead.")
    foreach ($issue in $wmiIssues) {
        [void]$failOutput.AppendLine("    $($issue.File):$($issue.Line): $($issue.Code)")
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_no_wmi_in_tests"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 5: test_undefined_calls
# Detect test files calling functions that don't exist anywhere
# in the project. AHK v2 only reports these at runtime with a
# dialog popup, blocking automated test execution.
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Build global function definition set from ALL project files
$tucAllDefs = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

# From cached files (src/ + tests/)
foreach ($path in $script:fileContentCache.Keys) {
    $defs = BT_GetFunctionDefinitions $path
    foreach ($name in $defs.Keys) { [void]$tucAllDefs.Add($name) }
}

# Class names from cached files (constructors callable as ClassName())
foreach ($path in $script:fileContentCache.Keys) {
    foreach ($line in $script:fileContentCache[$path]) {
        if ($line -match '^\s*class\s+(\w+)') {
            [void]$tucAllDefs.Add($Matches[1])
        }
    }
}

# From lib/ files (not in shared cache — third-party code)
# Uses lenient scanner: doesn't require { on same line as definition
$tucLibDir = Join-Path $SourceDir "lib"
if (Test-Path $tucLibDir) {
    foreach ($f in @(Get-ChildItem -Path $tucLibDir -Filter "*.ahk" -Recurse)) {
        $libLines = [System.IO.File]::ReadAllLines($f.FullName)
        for ($li = 0; $li -lt $libLines.Count; $li++) {
            $lt = $libLines[$li].TrimStart()
            if ($lt -match '^(?:static\s+)?([A-Za-z_]\w*)\s*\(') {
                $fn = $Matches[1]
                if ($fn -notin @('if','while','for','loop','switch','catch','return',
                    'throw','class','try','else','static','global','local')) {
                    [void]$tucAllDefs.Add($fn)
                }
            }
            if ($lt -match '^class\s+(\w+)') { [void]$tucAllDefs.Add($Matches[1]) }
        }
    }
}

# AHK v2 built-in functions and constructors (not defined in .ahk files)
$tucBuiltins = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($b in @(
    'Abs','Ceil','Exp','Floor','Log','Ln','Max','Min','Mod','Round','Sqrt',
    'Sin','Cos','Tan','ASin','ACos','ATan','Random','Integer','Float','Number',
    'Chr','Format','FormatTime','InStr','LTrim','Ord','RegExMatch','RegExReplace',
    'RTrim','Sort','StrCompare','StrGet','StrLen','StrLower','StrPtr','StrPut',
    'StrReplace','StrSplit','StrUpper','SubStr','Trim','String',
    'HasBase','HasMethod','HasProp','IsAlnum','IsAlpha','IsDigit','IsFloat',
    'IsInteger','IsLabel','IsLower','IsNumber','IsObject','IsSet','IsSetRef',
    'IsSpace','IsTime','IsUpper','IsXDigit','Type','GetMethod',
    'Array','Map','Object','Buffer',
    'ObjAddRef','ObjBindMethod','ObjFromPtr','ObjFromPtrAddRef','ObjGetBase',
    'ObjGetCapacity','ObjHasOwnProp','ObjOwnPropCount','ObjOwnProps','ObjPtr',
    'ObjPtrAddRef','ObjRelease','ObjSetBase','ObjSetCapacity',
    'NumGet','NumPut','VarSetStrCapacity',
    'Gui','GuiCtrlFromHwnd','GuiFromHwnd','LoadPicture','MenuFromHandle',
    'IL_Add','IL_Create','IL_Destroy','MenuBar','Menu',
    'InputBox','MsgBox','ToolTip','TrayTip','TraySetIcon','FileSelect','DirSelect',
    'DirCopy','DirCreate','DirDelete','DirExist','DirMove','Download',
    'FileAppend','FileCopy','FileCreateShortcut','FileDelete','FileEncoding',
    'FileExist','FileGetAttrib','FileGetShortcut','FileGetSize','FileGetTime',
    'FileGetVersion','FileInstall','FileMove','FileOpen','FileRead',
    'FileRecycle','FileRecycleEmpty','FileSetAttrib','FileSetTime','SplitPath',
    'RegDelete','RegDeleteKey','RegRead','RegWrite','SetRegView',
    'IniDelete','IniRead','IniWrite',
    'WinActivate','WinActivateBottom','WinActive','WinClose','WinExist',
    'WinGetClass','WinGetClientPos','WinGetControls','WinGetControlsHwnd',
    'WinGetCount','WinGetExStyle','WinGetID','WinGetIDLast','WinGetList',
    'WinGetMinMax','WinGetPID','WinGetPos','WinGetProcessName','WinGetProcessPath',
    'WinGetStyle','WinGetText','WinGetTitle','WinGetTransColor','WinGetTransparent',
    'WinHide','WinKill','WinMaximize','WinMinimize','WinMove','WinMoveBottom',
    'WinMoveTop','WinRedraw','WinRestore','WinSetAlwaysOnTop','WinSetEnabled',
    'WinSetExStyle','WinSetRegion','WinSetStyle','WinSetTitle','WinSetTransColor',
    'WinSetTransparent','WinShow','WinWait','WinWaitActive','WinWaitClose',
    'WinWaitNotActive','DetectHiddenText','DetectHiddenWindows','SetTitleMatchMode',
    'SetWinDelay','StatusBarGetText','StatusBarWait',
    'ControlClick','ControlFocus','ControlGetChecked','ControlGetChoice',
    'ControlGetClassNN','ControlGetEnabled','ControlGetFocus','ControlGetHwnd',
    'ControlGetIndex','ControlGetItems','ControlGetPos','ControlGetStyle',
    'ControlGetExStyle','ControlGetText','ControlGetVisible','ControlHide',
    'ControlMove','ControlSend','ControlSendText','ControlSetChecked',
    'ControlSetEnabled','ControlSetStyle','ControlSetExStyle','ControlSetText',
    'ControlShow','EditGetCurrentCol','EditGetCurrentLine','EditGetLine',
    'EditGetLineCount','EditGetSelectedText','EditPaste','ListViewGetContent',
    'MenuSelect','SetControlDelay',
    'ProcessClose','ProcessExist','ProcessGetName','ProcessGetPath',
    'ProcessSetPriority','ProcessWait','ProcessWaitClose','Run','RunAs','RunWait',
    'Shutdown',
    'BlockInput','Click','CoordMode','GetKeyName','GetKeySC','GetKeyState',
    'GetKeyVK','Hotkey','HotIf','HotIfWinActive','HotIfWinExist',
    'HotIfWinNotActive','HotIfWinNotExist','Hotstring','InputHook',
    'InstallKeybdHook','InstallMouseHook','KeyHistory','KeyWait',
    'MouseClick','MouseClickDrag','MouseGetPos','MouseMove',
    'Send','SendEvent','SendInput','SendLevel','SendMode','SendPlay','SendText',
    'SetCapsLockState','SetDefaultMouseSpeed','SetKeyDelay','SetMouseDelay',
    'SetNumLockState','SetScrollLockState','SetStoreCapsLockMode','CaretGetPos',
    'ComCall','ComObjActive','ComObjConnect','ComObjGet','ComObjQuery',
    'ComObjType','ComObjValue','ComObject','ComValue',
    'CallbackCreate','CallbackFree','DllCall',
    'OnClipboardChange','OnError','OnExit','OnMessage','PostMessage','SendMessage',
    'SetTimer','Critical','Persistent','Thread',
    'EnvGet','EnvSet','MonitorGet','MonitorGetCount','MonitorGetName',
    'MonitorGetPrimary','MonitorGetWorkArea','SysGet','SysGetIPAddresses',
    'DriveGetCapacity','DriveGetFileSystem','DriveGetLabel','DriveGetList',
    'DriveGetSerial','DriveGetSpaceFree','DriveGetStatus','DriveGetStatusCD',
    'DriveGetType','DriveSetLabel','DriveLock','DriveUnlock','DriveEject','DriveRetract',
    'SoundBeep','SoundGetInterface','SoundGetMute','SoundGetName',
    'SoundGetVolume','SoundPlay','SoundSetMute','SoundSetVolume',
    'DateAdd','DateDiff',
    'ClipboardAll','ClipWait','Edit','ExitApp','GroupActivate','GroupAdd',
    'GroupClose','GroupDeactivate','ImageSearch','ListHotkeys','ListLines',
    'ListVars','OutputDebug','Pause','PixelGetColor','PixelSearch',
    'Reload','SetWorkingDir','Sleep','Suspend',
    'Error','IndexError','MemberError','MethodError','OSError',
    'PropertyError','TargetError','TimeoutError','TypeError',
    'UnsetError','UnsetItemError','ValueError','ZeroDivisionError',
    'Func','BoundFunc','Closure','Enumerator','File','RegExMatchInfo','VarRef'
)) { [void]$tucBuiltins.Add($b) }

# Keywords that syntactically look like function calls
$tucKeywords = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($kw in @('if','while','for','loop','switch','catch','return','throw',
    'class','static','try','else','finally','until','not','and','or',
    'global','local','new','super','this','isset','in','contains')) {
    [void]$tucKeywords.Add($kw)
}

# Global variable names (callback pattern: varName() where varName holds a func ref)
$tucGlobalVars = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($path in $script:fileContentCache.Keys) {
    foreach ($line in $script:fileContentCache[$path]) {
        if ($line -match '^\s*global\s+(.+)') {
            foreach ($chunk in $Matches[1].Split(',')) {
                $ct = $chunk.Trim()
                if ($ct -match '^(\w+)') {
                    [void]$tucGlobalVars.Add($Matches[1])
                }
            }
        }
    }
}

# Function parameter names (callback pattern: paramName() inside function body)
foreach ($path in $script:fileContentCache.Keys) {
    foreach ($line in $script:fileContentCache[$path]) {
        $trimmed = $line.TrimStart()
        if ($trimmed -match '^(?:static\s+)?([A-Za-z_]\w*)\s*\((.+)') {
            $fn = $Matches[1].ToLower()
            if ($fn -in @('if','while','for','loop','switch','catch','return',
                'throw','class','try','else','static','global','local')) { continue }
            $paramText = $Matches[2]
            $closeIdx = $paramText.IndexOf(')')
            if ($closeIdx -ge 0) { $paramText = $paramText.Substring(0, $closeIdx) }
            foreach ($param in $paramText.Split(',')) {
                $p = $param.Trim() -replace '^\*', '' -replace '^&', ''
                if ($p -match '^(\w+)') {
                    [void]$tucGlobalVars.Add($Matches[1])
                }
            }
        }
    }
}

# Strict bare function call regex (excludes method calls: obj.Method())
$tucCallRx = [regex]::new('(?<![.\w])([A-Za-z_]\w*)\s*\(', 'Compiled')

$tucIssues = [System.Collections.ArrayList]::new()

foreach ($file in $testFiles) {
    $lines = Get-CachedFileLines $file.FullName
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $inBlockComment = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $trimmed = $line.TrimStart()

        if ($trimmed.StartsWith('/*')) { $inBlockComment = $true }
        if ($inBlockComment) {
            if ($trimmed.Contains('*/')) { $inBlockComment = $false }
            continue
        }
        if ($trimmed.StartsWith(';') -or $trimmed.StartsWith('#')) { continue }

        # Strip strings and inline comments
        $cleaned = $line
        if ($line.IndexOf('"') -ge 0) { $cleaned = $cleaned -replace '"[^"]*"', '""' }
        if ($line.IndexOf("'") -ge 0) { $cleaned = $cleaned -replace "'[^']*'", "''" }
        $semiIdx = $cleaned.IndexOf(' ;')
        if ($semiIdx -ge 0) { $cleaned = $cleaned.Substring(0, $semiIdx) }

        foreach ($m in $tucCallRx.Matches($cleaned)) {
            $funcName = $m.Groups[1].Value
            if ($tucKeywords.Contains($funcName)) { continue }
            if ($tucAllDefs.Contains($funcName)) { continue }
            if ($tucBuiltins.Contains($funcName)) { continue }
            if ($tucGlobalVars.Contains($funcName)) { continue }

            [void]$tucIssues.Add([PSCustomObject]@{
                File     = $relPath
                Line     = $i + 1
                Function = $funcName
                Context  = $trimmed.Substring(0, [Math]::Min($trimmed.Length, 100)).Trim()
            })
        }
    }
}

# Deduplicate: same function in same file only reported once
$tucDeduped = @($tucIssues | Sort-Object File, Function -Unique)

if ($tucDeduped.Count -gt 0) {
    $anyFailed = $true
    $grouped = $tucDeduped | Group-Object Function | Sort-Object Name
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($grouped.Count) undefined function(s) called in test files:")
    [void]$failOutput.AppendLine("  These functions don't exist anywhere in the project. Tests will show")
    [void]$failOutput.AppendLine("  'local variable has not been assigned a value' popup at runtime.")
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  Fix: Remove stale call, or add mock/stub definition to the test file.")
    foreach ($group in $grouped) {
        [void]$failOutput.AppendLine("")
        [void]$failOutput.AppendLine("    UNDEFINED: $($group.Name) ($($group.Count) call site(s))")
        foreach ($call in $group.Group) {
            [void]$failOutput.AppendLine("      $($call.File):$($call.Line): $($call.Context)")
        }
    }
}

$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_test_undefined_calls"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 6: test_cfg_completeness
# Verify test mock cfg objects include all properties that
# production code in the test's include tree actually accesses.
# Catches runtime "no property named X" errors when new config
# entries are added but test mocks aren't updated.
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$tccIssues = [System.Collections.ArrayList]::new()

# Phase 1: Extract all g: field values from config_registry.ahk (valid property names)
$registryFile = Join-Path $SourceDir "shared\config_registry.ahk"
$registryProps = [System.Collections.Generic.HashSet[string]]::new()

if (Test-Path $registryFile) {
    $regText = Get-CachedFileText $registryFile
    foreach ($m in [regex]::Matches($regText, '\bg:\s*"([^"]+)"')) {
        [void]$registryProps.Add($m.Groups[1].Value)
    }
}

# Phase 2: Build per-file cfg property access sets (src/ files only)
# Matches cfg.PropertyName — same regex as cfg_properties in check_batch_simple
$tccCfgAccessRx = [regex]::new('\bcfg\.([A-Za-z_]\w*)\b', 'Compiled')
$tccMethodSkip = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($s in @('HasOwnProp','DefineProp','Clone','Ptr','Base','OwnProps',
    'DeleteProp','GetOwnPropDesc','HasProp','__Init','__New')) {
    [void]$tccMethodSkip.Add($s)
}

$tccFileAccess = @{}  # filePath -> HashSet<string> of cfg properties accessed
foreach ($file in $srcFiles) {
    $text = Get-CachedFileText $file.FullName
    if ($text.IndexOf('cfg.', [System.StringComparison]::Ordinal) -lt 0) { continue }

    $props = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($m in $tccCfgAccessRx.Matches($text)) {
        $prop = $m.Groups[1].Value
        if (-not $tccMethodSkip.Contains($prop) -and $registryProps.Contains($prop)) {
            [void]$props.Add($prop)
        }
    }
    if ($props.Count -gt 0) {
        $tccFileAccess[$file.FullName] = $props
    }
}

# Phase 3: For each test with a mock cfg, collect accessed properties from include tree
if ($registryProps.Count -gt 0) {
    foreach ($file in $testFiles) {
        $text = Get-CachedFileText $file.FullName
        if ($text.IndexOf('cfg := {', [System.StringComparison]::Ordinal) -lt 0) { continue }

        $lines = Get-CachedFileLines $file.FullName
        $relPath = $file.FullName.Replace("$projectRoot\", '')

        # Extract mock cfg property names
        $inCfg = $false
        $cfgStartLine = 0
        $mockProps = [System.Collections.Generic.HashSet[string]]::new()

        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if (-not $inCfg) {
                if ($line -match '^\s*(?:global\s+)?cfg\s*:=\s*\{') {
                    $inCfg = $true
                    $cfgStartLine = $i + 1
                }
            }
            if ($inCfg) {
                foreach ($pm in [regex]::Matches($line, '(\w+)\s*:')) {
                    [void]$mockProps.Add($pm.Groups[1].Value)
                }
                if ($line -match '\}') { $inCfg = $false }
            }
        }

        if ($mockProps.Count -eq 0) { continue }

        # Build include tree and collect all cfg properties accessed by src/ files in the tree
        $tree = BT_BuildIncludeTree $file.FullName $file.DirectoryName
        $neededProps = [System.Collections.Generic.HashSet[string]]::new()

        foreach ($incFile in $tree) {
            if ($tccFileAccess.ContainsKey($incFile)) {
                foreach ($prop in $tccFileAccess[$incFile]) {
                    [void]$neededProps.Add($prop)
                }
            }
        }

        # Compare: report properties accessed by included production code but missing from mock
        $missing = [System.Collections.ArrayList]::new()
        foreach ($prop in $neededProps) {
            if (-not $mockProps.Contains($prop)) {
                [void]$missing.Add($prop)
            }
        }
        if ($missing.Count -gt 0) {
            [void]$tccIssues.Add([PSCustomObject]@{
                File    = $relPath
                Line    = $cfgStartLine
                Missing = ($missing | Sort-Object) -join ', '
                Count   = $missing.Count
            })
        }
    }
}

if ($tccIssues.Count -gt 0) {
    $anyFailed = $true
    $totalMissing = ($tccIssues | Measure-Object -Property Count -Sum).Sum
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $totalMissing config property(ies) missing from test mock cfg objects.")
    [void]$failOutput.AppendLine("  Production code in the test's include tree accesses cfg properties not defined in the mock.")
    [void]$failOutput.AppendLine("  Without them, cfg.PropertyName throws 'no property named' at runtime.")
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  Fix: add the missing properties with default values to the test's cfg object.")
    foreach ($issue in $tccIssues) {
        [void]$failOutput.AppendLine("    $($issue.File):$($issue.Line): missing $($issue.Count) prop(s): $($issue.Missing)")
    }
}

$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_test_cfg_completeness"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 7: test_production_calls
# Detect production code (included by tests) calling functions
# that are not defined or mocked in the test's include tree.
# AHK v2 treats unresolved function names as variable lookups
# at runtime → "local variable has not been assigned" popup.
#
# test_undefined_calls (sub-check 5) only scans test files.
# This check closes the gap: production code pulled in via
# #Include can call functions the test doesn't provide.
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Reuse $tucBuiltins, $tucKeywords, $tucCallRx, $tucGlobalVars from sub-check 5
# Reuse $entryPoints and BT_BuildIncludeTree from sub-check 1

$tpcLibDirNorm = [System.IO.Path]::GetFullPath((Join-Path $SourceDir "lib")).ToLower()
$tpcFuncDefCache = @{}

$tpcIssues = [System.Collections.ArrayList]::new()

if ($entryPoints.Count -gt 0) {
    foreach ($entry in $entryPoints) {
        $scriptDir = $entry.DirectoryName
        $tree = BT_BuildIncludeTree $entry.FullName $scriptDir

        # Build function set available in this tree (defined + mocked)
        $availFuncs = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)

        foreach ($file in $tree) {
            if (-not $tpcFuncDefCache.ContainsKey($file)) {
                $tpcFuncDefCache[$file] = BT_GetFunctionDefinitions $file
            }
            foreach ($name in $tpcFuncDefCache[$file].Keys) {
                [void]$availFuncs.Add($name)
            }
        }

        # Also add class names (constructors)
        foreach ($file in $tree) {
            foreach ($line in (Get-CachedFileLines $file)) {
                if ($line -match '^\s*class\s+(\w+)') {
                    [void]$availFuncs.Add($Matches[1])
                }
            }
        }

        # Also add lib/ function definitions (third-party code always available at runtime)
        $tpcLibDir = Join-Path $SourceDir "lib"
        if (Test-Path $tpcLibDir) {
            foreach ($f in @(Get-ChildItem -Path $tpcLibDir -Filter "*.ahk" -Recurse)) {
                if (-not $tpcFuncDefCache.ContainsKey($f.FullName)) {
                    $libLines = [System.IO.File]::ReadAllLines($f.FullName)
                    $libDefs = @{}
                    for ($li = 0; $li -lt $libLines.Count; $li++) {
                        $lt = $libLines[$li].TrimStart()
                        if ($lt -match '^(?:static\s+)?([A-Za-z_]\w*)\s*\(') {
                            $fn = $Matches[1]
                            if ($fn -notin @('if','while','for','loop','switch','catch','return',
                                'throw','class','try','else','static','global','local')) {
                                $libDefs[$fn] = $li + 1
                            }
                        }
                        if ($lt -match '^class\s+(\w+)') { $libDefs[$Matches[1]] = $li + 1 }
                    }
                    $tpcFuncDefCache[$f.FullName] = $libDefs
                }
                foreach ($name in $tpcFuncDefCache[$f.FullName].Keys) {
                    [void]$availFuncs.Add($name)
                }
            }
        }

        $relEntry = $entry.FullName.Replace("$projectRoot\", '')

        # Scan only production files in the tree:
        # - Skip test files (sub-check 5 covers those)
        # - Skip lib/ files (third-party code, not loaded in test context)
        foreach ($file in $tree) {
            $fileLower = $file.ToLower()
            if (-not $fileLower.StartsWith($srcDirNorm)) { continue }
            if ($fileLower.StartsWith($tpcLibDirNorm)) { continue }

            $lines = Get-CachedFileLines $file
            $inBlockComment = $false

            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                $trimmed = $line.TrimStart()

                if ($trimmed.StartsWith('/*')) { $inBlockComment = $true }
                if ($inBlockComment) {
                    if ($trimmed.Contains('*/')) { $inBlockComment = $false }
                    continue
                }
                if ($trimmed.StartsWith(';') -or $trimmed.StartsWith('#')) { continue }

                # Strip strings and inline comments
                $cleaned = $line
                if ($line.IndexOf('"') -ge 0) { $cleaned = $cleaned -replace '"[^"]*"', '""' }
                if ($line.IndexOf("'") -ge 0) { $cleaned = $cleaned -replace "'[^']*'", "''" }
                $semiIdx = $cleaned.IndexOf(' ;')
                if ($semiIdx -ge 0) { $cleaned = $cleaned.Substring(0, $semiIdx) }

                foreach ($m in $tucCallRx.Matches($cleaned)) {
                    $funcName = $m.Groups[1].Value
                    if ($tucKeywords.Contains($funcName)) { continue }
                    if ($availFuncs.Contains($funcName)) { continue }
                    if ($tucBuiltins.Contains($funcName)) { continue }
                    if ($tucGlobalVars.Contains($funcName)) { continue }

                    $relFile = $file.Replace("$projectRoot\", '')
                    [void]$tpcIssues.Add([PSCustomObject]@{
                        TestEntry = $relEntry
                        SrcFile   = $relFile
                        Line      = $i + 1
                        Function  = $funcName
                        Context   = $trimmed.Substring(0, [Math]::Min($trimmed.Length, 100)).Trim()
                    })
                }
            }
        }
    }
}

# Deduplicate: same function + src file + test entry only reported once
$tpcDeduped = @($tpcIssues | Sort-Object TestEntry, SrcFile, Function -Unique)

if ($tpcDeduped.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($tpcDeduped.Count) undefined function(s) in production code included by tests.")
    [void]$failOutput.AppendLine("  Production code calls functions not available in the test's #Include tree.")
    [void]$failOutput.AppendLine("  Tests will show 'local variable has not been assigned a value' popup at runtime.")
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  Fix: add a mock/stub in the test file, or #Include the file that defines the function.")

    $grouped = $tpcDeduped | Group-Object TestEntry
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("")
        [void]$failOutput.AppendLine("    Test: $($group.Name)")
        foreach ($issue in $group.Group | Sort-Object SrcFile, Line) {
            [void]$failOutput.AppendLine("      $($issue.SrcFile):$($issue.Line) - $($issue.Function)() undefined")
        }
    }
}

$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_test_production_calls"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Report
# ============================================================
$totalSw.Stop()

if ($anyFailed) {
    Write-Host $failOutput.ToString().TrimEnd()
} else {
    Write-Host "  PASS: All test checks passed (test_globals, test_functions, test_assertions, no_wmi_in_tests, test_undefined_calls, test_cfg_completeness, test_production_calls)" -ForegroundColor Green
}

Write-Host "  Timing: total=$($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan

# Write sub-timing for nested display (consumed by static_analysis.ps1)
$subTimings | ConvertTo-Json -Compress | Set-Content "$env:TEMP\sa_batch_tests_timing.json" -Encoding UTF8

if ($anyFailed) { exit 1 }
exit 0
