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

# === Pass 2: Find references for each function across all files ===
$deadFunctions = [System.Collections.ArrayList]::new()

# Build a combined regex for all function names (for fast pre-filtering)
$allFuncNames = @($funcDefs.Keys)
if ($allFuncNames.Count -eq 0) {
    Write-Host "  PASS: No functions found in src/ to check" -ForegroundColor Green
    exit 0
}

# Pre-build per-file text for all files (src + test)
$allFileTexts = @{}
foreach ($key in $fileCache.Keys) {
    $allFileTexts[$key] = $fileCache[$key]
}

foreach ($funcName in $allFuncNames) {
    $def = $funcDefs[$funcName]

    # Skip suppressed definitions
    if ($def.Raw.Contains($SUPPRESSION)) { continue }

    # Skip entry-point functions
    if ($entryPointRegex.IsMatch($funcName)) { continue }

    # Search all files for references to this function name
    $refCount = 0
    $defFile = $def.File
    $defLine = $def.Line

    foreach ($filePath in $allFileTexts.Keys) {
        $text = $allFileTexts[$filePath]

        # Quick pre-filter: does the file even mention this function name?
        if ($text.IndexOf($funcName, [System.StringComparison]::Ordinal) -lt 0) { continue }

        # Count meaningful references (not the definition itself)
        $lines = $fileCacheLines[$filePath]
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]

            # Skip if this IS the definition line
            if ($filePath -eq $defFile -and ($i + 1) -eq $defLine) { continue }

            # Skip comments
            if ($line -match '^\s*;') { continue }

            # Check for the function name (as word boundary)
            if ($line.IndexOf($funcName, [System.StringComparison]::Ordinal) -ge 0) {
                # Verify it's a real reference (not inside a comment or string that happens to match)
                # Strip end-of-line comments
                $cleaned = $line
                if ($cleaned.IndexOf(';') -ge 0) {
                    $cleaned = $cleaned -replace '\s;.*$', ''
                }
                if ($cleaned.IndexOf($funcName, [System.StringComparison]::Ordinal) -ge 0) {
                    $refCount++
                    break  # One reference is enough to prove it's not dead
                }
            }
        }

        if ($refCount -gt 0) { break }
    }

    if ($refCount -eq 0) {
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
