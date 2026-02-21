# check_dead_functions.ps1 - Dead code detection
# Finds functions defined in src/ (not lib/) that are never called or referenced
# anywhere in the codebase (src/ or tests/). Dead functions indicate incomplete
# refactors and bloat the compiled binary.
#
# Auto-discovered by static_analysis.ps1 (check_*.ps1 naming convention).
# Suppress: add '; lint-ignore: dead-function' on the function definition line.
#
# Usage: powershell -File tests\check_dead_functions.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all pass, 1 = any check failed

param(
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

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

# === File cache: read all .ahk files once ===
$srcFiles = @(Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse |
    Where-Object { $_.FullName -notlike "*\lib\*" })
$testFiles = @()
if (Test-Path $testsDir) {
    $testFiles = @(Get-ChildItem -Path $testsDir -Filter "*.ahk" -File)
}

$fileCache = @{}        # fullPath -> string (joined text)
$fileCacheLines = @{}   # fullPath -> string[] (lines)
foreach ($f in $srcFiles) {
    $text = [System.IO.File]::ReadAllText($f.FullName)
    $fileCache[$f.FullName] = $text
    $fileCacheLines[$f.FullName] = $text -split "`r?`n"
}
foreach ($f in $testFiles) {
    $text = [System.IO.File]::ReadAllText($f.FullName)
    $fileCache[$f.FullName] = $text
    $fileCacheLines[$f.FullName] = $text -split "`r?`n"
}

$SUPPRESSION = 'lint-ignore: dead-function'

# AHK keywords that look like function definitions but aren't
$AHK_KEYWORDS = @(
    'if', 'else', 'while', 'for', 'loop', 'switch', 'case', 'catch',
    'finally', 'try', 'class', 'return', 'throw', 'static', 'global',
    'local', 'until', 'not', 'and', 'or', 'is', 'in', 'contains',
    'new', 'super', 'this', 'true', 'false', 'unset', 'isset'
)

# Entry-point patterns exempt from dead-function checking
$ENTRY_POINT_PATTERNS = @(
    '_OnExit',
    '_OnError',
    'OnExitWrapper',
    '_Main$',
    '^GetAppVersion$'       # Called by version resolution at startup
)
$entryPointRegex = [regex]::new(($ENTRY_POINT_PATTERNS -join '|'), 'Compiled, IgnoreCase')

# === Pass 1: Collect all function definitions in src/ ===
$funcDefs = @{}  # funcName -> @{ File; Line; RelPath }

foreach ($file in $srcFiles) {
    $lines = $fileCacheLines[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $inBlockComment = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]

        if ($inBlockComment) {
            if ($raw -match '\*/') { $inBlockComment = $false }
            continue
        }
        if ($raw -match '^\s*/\*') { $inBlockComment = $true; continue }
        if ($raw -match '^\s*;') { continue }

        # Match file-scope function definitions
        if ($raw -match '^\s*(?:static\s+)?([A-Za-z_]\w*)\s*\(') {
            $funcName = $Matches[1]
            if ($funcName.ToLower() -in $AHK_KEYWORDS) { continue }

            # Verify it's a definition (has opening brace on same or next line)
            $hasBrace = $raw -match '\{'
            if (-not $hasBrace -and ($i + 1) -lt $lines.Count) {
                $nextLine = $lines[$i + 1]
                if ($nextLine -match '^\s*\{') { $hasBrace = $true }
            }
            if (-not $hasBrace) { continue }

            # Only keep first definition (AHK uses last, but we report against first)
            if (-not $funcDefs.ContainsKey($funcName)) {
                $funcDefs[$funcName] = @{
                    File    = $file.FullName
                    Line    = $i + 1
                    RelPath = $relPath
                    Raw     = $raw
                }
            }
        }
    }
}

# === Pass 2: Build reference index then check functions ===
$deadFunctions = [System.Collections.ArrayList]::new()

$allFuncNames = @($funcDefs.Keys)
if ($allFuncNames.Count -eq 0) {
    Write-Host "  PASS: No functions found in src/ to check" -ForegroundColor Green
    exit 0
}

# Build a set of all function names for fast lookup
$funcNameSet = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]$allFuncNames, [System.StringComparer]::Ordinal)

# Build reference index: scan each file ONCE, collect all identifiers that could be references.
# For each identifier found as a non-comment reference, record it in the index.
# Track definition-line references separately so we can exclude them.
# Build reference index: scan each file once, checking full text first (fast pre-filter)
# then verify non-definition-line references via line scan.
# This inverts the original O(functions × files) to O(files × remaining_functions).
$refIndex = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$rxStripComment = [regex]::new('\s;.*$', 'Compiled')

# Pre-filter: for each file's full text, find all function names that appear as substrings.
# Then verify each match is a real non-definition reference.
foreach ($filePath in $fileCache.Keys) {
    $text = $fileCache[$filePath]
    $lines = $fileCacheLines[$filePath]

    # Check which not-yet-referenced functions appear in this file's full text
    $candidates = [System.Collections.ArrayList]::new()
    foreach ($funcName in $allFuncNames) {
        if ($refIndex.Contains($funcName)) { continue }
        if ($text.IndexOf($funcName, [System.StringComparison]::Ordinal) -ge 0) {
            [void]$candidates.Add($funcName)
        }
    }

    if ($candidates.Count -eq 0) { continue }

    # Line-level verification for candidates
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line.Length -gt 0 -and $line.TrimStart().StartsWith(';')) { continue }

        $cleaned = $line
        if ($cleaned.IndexOf(';') -ge 0) {
            $cleaned = $rxStripComment.Replace($cleaned, '')
        }

        for ($ci = $candidates.Count - 1; $ci -ge 0; $ci--) {
            $funcName = $candidates[$ci]
            if ($cleaned.IndexOf($funcName, [System.StringComparison]::Ordinal) -ge 0) {
                $def = $funcDefs[$funcName]
                if ($filePath -eq $def.File -and ($i + 1) -eq $def.Line) { continue }
                [void]$refIndex.Add($funcName)
                $candidates.RemoveAt($ci)
            }
        }

        if ($candidates.Count -eq 0) { break }
    }
}

# Check each function against the reference index
foreach ($funcName in $allFuncNames) {
    $def = $funcDefs[$funcName]

    # Skip suppressed definitions
    if ($def.Raw.Contains($SUPPRESSION)) { continue }

    # Skip entry-point functions
    if ($entryPointRegex.IsMatch($funcName)) { continue }

    if (-not $refIndex.Contains($funcName)) {
        [void]$deadFunctions.Add([PSCustomObject]@{
            Name    = $funcName
            File    = $def.RelPath
            Line    = $def.Line
        })
    }
}

# === Report ===
$sw.Stop()

if ($deadFunctions.Count -gt 0) {
    $failOutput = [System.Text.StringBuilder]::new()
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($deadFunctions.Count) dead function(s) found (defined but never referenced).")
    [void]$failOutput.AppendLine("  Dead functions indicate incomplete refactors and bloat the compiled binary.")
    [void]$failOutput.AppendLine("  Fix: remove the function, or suppress with '; lint-ignore: dead-function'.")

    $grouped = $deadFunctions | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): $($issue.Name)()")
        }
    }

    Write-Host $failOutput.ToString().TrimEnd()
    Write-Host "  Timing: $($sw.ElapsedMilliseconds)ms" -ForegroundColor Cyan
    exit 1
} else {
    Write-Host "  PASS: No dead functions found ($($allFuncNames.Count) functions checked)" -ForegroundColor Green
    Write-Host "  Timing: $($sw.ElapsedMilliseconds)ms" -ForegroundColor Cyan
    exit 0
}
