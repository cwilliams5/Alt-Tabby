# check_ipc_constants.ps1 - Static analysis for IPC message type constant usage
# Pre-gate test: runs before any AHK process launches.
# Ensures IPC message type strings use defined constants, not hardcoded literals.
#
# Part A: No hardcoded type strings in JSON (e.g. '"type":"delta"' should use IPC_MSG_DELTA)
# Part B: All IPC_MSG_* constants are referenced in at least one file besides ipc_constants.ahk
# Part C: No raw string comparisons in case statements (e.g. case "delta": should use constant)
#
# Suppress individual lines with: ; lint-ignore: ipc-constant
#
# Usage: powershell -File tests\check_ipc_constants.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all clear, 1 = issues found

param(
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

# === Resolve source directory ===
if (-not $SourceDir) {
    $SourceDir = (Resolve-Path "$PSScriptRoot\..\src").Path
}
if (-not (Test-Path $SourceDir)) {
    Write-Host "  ERROR: Source directory not found: $SourceDir" -ForegroundColor Red
    exit 1
}

$projectRoot = (Resolve-Path "$SourceDir\..").Path

# === Load IPC constants from ipc_constants.ahk ===
$constantsFile = Join-Path $SourceDir "shared\ipc_constants.ahk"
if (-not (Test-Path $constantsFile)) {
    Write-Host "  ERROR: IPC constants file not found: $constantsFile" -ForegroundColor Red
    exit 1
}

# Parse constant name -> value mappings
$constants = @{}
$constantLines = [System.IO.File]::ReadAllLines($constantsFile)
foreach ($line in $constantLines) {
    if ($line -match '^\s*global\s+(IPC_MSG_\w+)\s*:=\s*"([^"]+)"') {
        $constants[$Matches[1]] = $Matches[2]
    }
}

if ($constants.Count -eq 0) {
    Write-Host "  ERROR: No IPC_MSG_* constants found in $constantsFile" -ForegroundColor Red
    exit 1
}

# Build reverse lookup: value -> constant name
$valueToName = @{}
foreach ($kv in $constants.GetEnumerator()) {
    $valueToName[$kv.Value] = $kv.Key
}

# Values joined for regex alternation
$valuesPattern = ($constants.Values | Sort-Object -Descending { $_.Length } | ForEach-Object { [regex]::Escape($_) }) -join '|'

# === Collect source files (excluding lib/ and ipc_constants.ahk itself) ===
$files = @(Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse |
    Where-Object { $_.FullName -notlike "*\lib\*" -and $_.Name -ne "ipc_constants.ahk" })

Write-Host "  Scanning $($files.Count) files for IPC constant issues ($($constants.Count) constants)..." -ForegroundColor Cyan

$scanSw = [System.Diagnostics.Stopwatch]::StartNew()
$issues = [System.Collections.ArrayList]::new()

# === Part A: No hardcoded type strings in JSON ===
# Look for patterns like '"type":"<value>"' where <value> matches an IPC constant value
# and the line does NOT reference the corresponding IPC_MSG_* constant name
foreach ($file in $files) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $rawLine = $lines[$i]

        # Skip comments
        if ($rawLine -match '^\s*;') { continue }

        # Skip suppressed lines
        if ($rawLine -match 'lint-ignore:\s*ipc-constant') { continue }

        # Match hardcoded IPC type value in JSON type field
        # Pattern: "type":"<value>" or 'type":"<value>' (AHK single-quoted strings)
        if ($rawLine -match "['""]type['""]\s*:\s*['""]($valuesPattern)['""]") {
            $foundValue = $Matches[1]
            $expectedConst = $valueToName[$foundValue]

            # Check if the same line already uses the constant name
            if ($rawLine -notmatch [regex]::Escape($expectedConst)) {
                [void]$issues.Add([PSCustomObject]@{
                    File    = $relPath
                    Line    = $i + 1
                    Part    = 'A'
                    Message = "Hardcoded IPC type string '$foundValue' - use $expectedConst instead"
                })
            }
        }
    }
}

# === Part B: All constants referenced outside ipc_constants.ahk ===
# Build set of all constant names that appear in any source file
$usedConstants = @{}
foreach ($file in $files) {
    $content = [System.IO.File]::ReadAllText($file.FullName)
    foreach ($constName in $constants.Keys) {
        if ($content.Contains($constName)) {
            $usedConstants[$constName] = $true
        }
    }
}

foreach ($constName in $constants.Keys | Sort-Object) {
    if (-not $usedConstants.ContainsKey($constName)) {
        [void]$issues.Add([PSCustomObject]@{
            File    = "src\shared\ipc_constants.ahk"
            Line    = 0
            Part    = 'B'
            Message = "IPC constant $constName is defined but never referenced in any source file"
        })
    }
}

# === Part C: No raw string comparisons in case statements ===
# Scan for case "<ipc_value>": patterns where the value matches an IPC constant
foreach ($file in $files) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $rawLine = $lines[$i]

        # Skip comments
        if ($rawLine -match '^\s*;') { continue }

        # Skip suppressed lines
        if ($rawLine -match 'lint-ignore:\s*ipc-constant') { continue }

        # Match: case "value": (with optional whitespace)
        if ($rawLine -match "^\s*case\s+['""]($valuesPattern)['""]\s*:") {
            $foundValue = $Matches[1]
            $expectedConst = $valueToName[$foundValue]
            [void]$issues.Add([PSCustomObject]@{
                File    = $relPath
                Line    = $i + 1
                Part    = 'C'
                Message = "Raw string in case statement '$foundValue' - use $expectedConst instead"
            })
        }
    }
}

$scanSw.Stop()
$totalSw.Stop()

# ============================================================
# Report
# ============================================================
$timingLine = "  Timing: scan=$($scanSw.ElapsedMilliseconds)ms  total=$($totalSw.ElapsedMilliseconds)ms"
$statsLine  = "  Stats:  $($constants.Count) constants, $($files.Count) files"

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "  FAIL: $($issues.Count) IPC constant issue(s) found." -ForegroundColor Red

    $partAIssues = @($issues | Where-Object { $_.Part -eq 'A' })
    $partBIssues = @($issues | Where-Object { $_.Part -eq 'B' })
    $partCIssues = @($issues | Where-Object { $_.Part -eq 'C' })

    if ($partAIssues.Count -gt 0) {
        Write-Host "`n  Part A - Hardcoded type strings in JSON ($($partAIssues.Count)):" -ForegroundColor Yellow
        Write-Host "  Fix: replace literal string with IPC_MSG_* constant, or suppress with:" -ForegroundColor Yellow
        Write-Host "    ; lint-ignore: ipc-constant" -ForegroundColor Yellow
        foreach ($issue in $partAIssues | Sort-Object File, Line) {
            Write-Host "    $($issue.File):$($issue.Line): $($issue.Message)" -ForegroundColor Red
        }
    }

    if ($partBIssues.Count -gt 0) {
        Write-Host "`n  Part B - Unused IPC constants ($($partBIssues.Count)):" -ForegroundColor Yellow
        foreach ($issue in $partBIssues | Sort-Object Message) {
            Write-Host "    $($issue.Message)" -ForegroundColor Red
        }
    }

    if ($partCIssues.Count -gt 0) {
        Write-Host "`n  Part C - Raw strings in case statements ($($partCIssues.Count)):" -ForegroundColor Yellow
        Write-Host "  Fix: replace literal string with IPC_MSG_* constant, or suppress with:" -ForegroundColor Yellow
        Write-Host "    ; lint-ignore: ipc-constant" -ForegroundColor Yellow
        foreach ($issue in $partCIssues | Sort-Object File, Line) {
            Write-Host "    $($issue.File):$($issue.Line): $($issue.Message)" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 1
} else {
    Write-Host "  PASS: All IPC message types use constants correctly" -ForegroundColor Green
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 0
}
