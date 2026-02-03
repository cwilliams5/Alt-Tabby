# check_test_functions.ps1 - Static analysis for undefined test utility function references
#
# Catches: Test files that call test utility functions (AssertEq, Log, WaitFor*, etc.)
# without including test_utils.ahk either directly or via their include chain.
#
# Problem: Test module files (e.g., test_unit_core.ahk) use functions like AssertEq
# but don't include test_utils.ahk directly. They rely on being included by run_tests.ahk
# which includes test_utils.ahk first. If someone runs them standalone, AHK shows a
# warning popup about undefined variables.
#
# Algorithm:
# 1. Find all .ahk files in tests/ that are NOT run_tests.ahk
# 2. Check if they use test utility functions (AssertEq, Log, WaitFor*, etc.)
# 3. If they do, verify they either:
#    a. Include test_utils.ahk directly, OR
#    b. Include another file that includes test_utils.ahk (via include chain), OR
#    c. Define the function themselves
# 4. Flag files that use test functions without the proper include chain
#
# Usage: powershell -File tests\check_test_functions.ps1
# Exit codes: 0 = all clear, 1 = issues found

param()

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Test utility functions defined in test_utils.ahk that other test files commonly use
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

# === Helpers ===

function Clean-Line {
    param([string]$line)
    $cleaned = $line -replace '"[^"]*"', '""'
    $cleaned = $cleaned -replace "'[^']*'", "''"
    $cleaned = $cleaned -replace '\s;.*$', ''
    if ($cleaned -match '^\s*;') { return '' }
    return $cleaned
}

function Get-IncludeChain {
    # Recursively trace #Include directives from a file
    # Returns array of absolute file paths
    param(
        [string]$entryFile,
        [string]$scriptDir
    )

    $visited = @{}
    $queue = [System.Collections.Queue]::new()
    $chain = [System.Collections.ArrayList]::new()

    if (-not (Test-Path $entryFile)) { return $chain }

    $entryFull = [System.IO.Path]::GetFullPath($entryFile)
    $queue.Enqueue($entryFull)
    $visited[$entryFull.ToLower()] = $true
    [void]$chain.Add($entryFull)

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not (Test-Path $current)) { continue }

        $currentDir = [System.IO.Path]::GetDirectoryName($current)
        $lines = [System.IO.File]::ReadAllLines($current)

        foreach ($line in $lines) {
            if ($line -match '^\s*#Include\s+') {
                $resolved = Resolve-AhkInclude $line $currentDir $scriptDir
                if ($resolved) {
                    $key = $resolved.ToLower()
                    if (-not $visited.ContainsKey($key)) {
                        $visited[$key] = $true
                        [void]$chain.Add($resolved)
                        $queue.Enqueue($resolved)
                    }
                }
            }
        }
    }

    return $chain
}

function Resolve-AhkInclude {
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

function Get-FunctionCalls {
    # Extract function call names from a file (function names followed by '(')
    param([string]$filePath)

    $calls = @{}
    if (-not (Test-Path $filePath)) { return $calls }

    $lines = [System.IO.File]::ReadAllLines($filePath)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = Clean-Line $lines[$i]
        if ($cleaned -eq '') { continue }

        # Match function calls: identifier followed by (
        foreach ($m in [regex]::Matches($cleaned, '\b([A-Za-z_]\w*)\s*\(')) {
            $funcName = $m.Groups[1].Value
            if (-not $calls.ContainsKey($funcName)) {
                $calls[$funcName] = $i + 1  # Store first occurrence line number
            }
        }
    }

    return $calls
}

function Get-FunctionDefinitions {
    # Extract function definitions from a file
    # A function definition is: FuncName(params) { at line start (not indented call)
    param([string]$filePath)

    $defs = @{}
    if (-not (Test-Path $filePath)) { return $defs }

    $lines = [System.IO.File]::ReadAllLines($filePath)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = Clean-Line $lines[$i]
        if ($cleaned -eq '') { continue }

        # Match function definitions: must have { at end (not a call with nested parens)
        # Pattern: FuncName(simple_params) { where simple_params has no nested ()
        # This avoids matching calls like AssertEq(_WS_GetOpt(...), ...) as definitions
        if ($cleaned -match '^\s*(?:static\s+)?([A-Za-z_]\w*)\s*\([^()]*\)\s*\{') {
            $funcName = $Matches[1]
            # Skip keywords
            if ($funcName -notin @('if', 'while', 'for', 'switch', 'catch', 'loop')) {
                $defs[$funcName] = $i + 1
            }
        }
    }

    return $defs
}

# === Main ===

$testsDir = $PSScriptRoot
if (-not (Test-Path $testsDir)) {
    Write-Host "  ERROR: Tests directory not found: $testsDir" -ForegroundColor Red
    exit 1
}

$projectRoot = (Resolve-Path "$testsDir\..").Path

# Find all test files except run_tests.ahk (the main entry point)
$testFiles = @(Get-ChildItem -Path $testsDir -Filter "*.ahk" -File | Where-Object { $_.Name -ne 'run_tests.ahk' })

if ($testFiles.Count -eq 0) {
    Write-Host "  PASS: No test files to check" -ForegroundColor Green
    exit 0
}

Write-Host "  Scanning $($testFiles.Count) test files for undefined test function references..." -ForegroundColor Cyan

$issues = [System.Collections.ArrayList]::new()

foreach ($file in $testFiles) {
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    # Get function calls in this file
    $calls = Get-FunctionCalls $file.FullName

    # Check if file uses any test utility functions
    $usedTestFunctions = @()
    foreach ($func in $TEST_UTIL_FUNCTIONS) {
        if ($calls.ContainsKey($func)) {
            $usedTestFunctions += @{ Name = $func; Line = $calls[$func] }
        }
    }

    if ($usedTestFunctions.Count -eq 0) {
        continue  # File doesn't use test utility functions
    }

    # Get include chain from this file
    $includeChain = Get-IncludeChain $file.FullName $file.DirectoryName

    # Check if test_utils.ahk is in the include chain
    $hasTestUtils = $false
    foreach ($inc in $includeChain) {
        if ($inc -match 'test_utils\.ahk$') {
            $hasTestUtils = $true
            break
        }
    }

    if ($hasTestUtils) {
        continue  # File has proper include
    }

    # Get function definitions from this file and its include chain
    $availableDefs = @{}
    foreach ($inc in $includeChain) {
        $defs = Get-FunctionDefinitions $inc
        foreach ($k in $defs.Keys) {
            if (-not $availableDefs.ContainsKey($k)) {
                $availableDefs[$k] = $defs[$k]
            }
        }
    }

    # Check each used test function
    foreach ($usage in $usedTestFunctions) {
        if (-not $availableDefs.ContainsKey($usage.Name)) {
            [void]$issues.Add([PSCustomObject]@{
                File     = $relPath
                Line     = $usage.Line
                Function = $usage.Name
            })
        }
    }
}

$sw.Stop()

# === Report ===

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "  FAIL: $($issues.Count) undefined test function reference(s) found." -ForegroundColor Red
    Write-Host "  These files use test utility functions without including test_utils.ahk." -ForegroundColor Red
    Write-Host "  Running them standalone will show AHK warning popups about undefined variables." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Fix: Add '#Include test_utils.ahk' near the top of each file." -ForegroundColor Yellow

    $grouped = $issues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        Write-Host "`n    $($group.Name):" -ForegroundColor Yellow
        foreach ($issue in $group.Group | Sort-Object Line) {
            Write-Host "      Line $($issue.Line): calls '$($issue.Function)' without including test_utils.ahk" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host "  Scanned: $($testFiles.Count) files, $($sw.ElapsedMilliseconds)ms" -ForegroundColor Cyan
    exit 1
} else {
    Write-Host "  PASS: All test files have proper includes for test utility functions" -ForegroundColor Green
    Write-Host "  Scanned: $($testFiles.Count) files, $($sw.ElapsedMilliseconds)ms" -ForegroundColor Cyan
    exit 0
}
