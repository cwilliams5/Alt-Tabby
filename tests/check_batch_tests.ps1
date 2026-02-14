# check_batch_tests.ps1 - Batched test-file analysis checks
# Combines 2 test-related checks into one PowerShell process to reduce startup overhead.
# Sub-checks: test_globals, test_functions
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

# Cache: filePath -> string[] (lines)
$script:fileContentCache = @{}
foreach ($f in $srcFiles) {
    $script:fileContentCache[$f.FullName] = [System.IO.File]::ReadAllLines($f.FullName)
}
foreach ($f in $testFiles) {
    $script:fileContentCache[$f.FullName] = [System.IO.File]::ReadAllLines($f.FullName)
}

function Get-CachedFileLines($path) {
    if (-not $script:fileContentCache.ContainsKey($path)) {
        $script:fileContentCache[$path] = [System.IO.File]::ReadAllLines($path)
    }
    return $script:fileContentCache[$path]
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
    $path = $path -replace '%A_ScriptDir%', $scriptDir

    if (-not [System.IO.Path]::IsPathRooted($path)) {
        $path = Join-Path $currentFileDir $path
    }

    try {
        $path = [System.IO.Path]::GetFullPath($path)
    } catch {
        return $null
    }

    if (Test-Path $path) { return $path }
    return $null
}

$script:includeLineCache = @{}

function BT_BuildIncludeTree {
    param(
        [string]$entryFile,
        [string]$scriptDir
    )

    $visited = @{}
    $queue = [System.Collections.Queue]::new()
    $tree = [System.Collections.ArrayList]::new()

    $entryFull = [System.IO.Path]::GetFullPath($entryFile)
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
$funcUsageCache = @{}

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
                $fileText = [string]::Join("`n", $fileLines)
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

            if (-not $funcUsageCache.ContainsKey($file)) {
                $funcUsageCache[$file] = BT_GetFunctionGlobalUsage $file
            }
            $usages = $funcUsageCache[$file]
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
    'WaitForStorePipe',
    'LaunchTestStore',
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
# Report
# ============================================================
$totalSw.Stop()

if ($anyFailed) {
    Write-Host $failOutput.ToString().TrimEnd()
} else {
    Write-Host "  PASS: All test checks passed (test_globals, test_functions)" -ForegroundColor Green
}

Write-Host "  Timing: total=$($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan

# Write sub-timing for nested display (consumed by static_analysis.ps1)
$subTimings | ConvertTo-Json -Compress | Set-Content "$env:TEMP\sa_batch_tests_timing.json" -Encoding UTF8

if ($anyFailed) { exit 1 }
exit 0
