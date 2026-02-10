# check_state_strings.ps1 - Static analysis for AHK v2 state machine string validation
# Pre-gate test: runs before any AHK process launches.
# Detects invalid gGUI_State string literals in assignments and comparisons.
#
# Valid states: IDLE, ALT_PENDING, ACTIVE
# No suppression — invalid state strings are always bugs.
#
# Usage: powershell -File tests\check_state_strings.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all clear, 1 = issues found

param(
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

# === Constants ===
$VALID_STATES = @('IDLE', 'ALT_PENDING', 'ACTIVE')

# === Resolve source directory ===
if (-not $SourceDir) {
    $SourceDir = (Resolve-Path "$PSScriptRoot\..\src").Path
}
if (-not (Test-Path $SourceDir)) {
    Write-Host "  ERROR: Source directory not found: $SourceDir" -ForegroundColor Red
    exit 1
}

$projectRoot = (Resolve-Path "$SourceDir\..").Path
$files = @(Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse |
    Where-Object { $_.FullName -notlike "*\lib\*" })
Write-Host "  Scanning $($files.Count) files for invalid gGUI_State strings..." -ForegroundColor Cyan

# ============================================================
# Single pass: scan each line for gGUI_State string patterns
# ============================================================
$scanSw = [System.Diagnostics.Stopwatch]::StartNew()
$issues = [System.Collections.ArrayList]::new()
$matchCount = 0

foreach ($file in $files) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        # Skip full-line comments
        if ($line -match '^\s*;') { continue }

        # Skip lines without gGUI_State
        if ($line -notmatch 'gGUI_State') { continue }

        # Strip end-of-line comments to avoid false matches in comments
        $stripped = $line -replace '\s;.*$', ''

        # Pattern 1: Assignment — gGUI_State := "VALUE"
        # Pattern 2: Comparison — gGUI_State =/==/!= "VALUE"
        # Pattern 3: Reversed comparison — "VALUE" =/==/!= gGUI_State
        $patterns = @(
            'gGUI_State\s*:=\s*"([^"]*)"',
            'gGUI_State\s*[!=]=?\s*"([^"]*)"',
            '"([^"]*)"\s*[!=]=?\s*gGUI_State'
        )

        foreach ($pattern in $patterns) {
            $regex = [regex]$pattern
            $m = $regex.Matches($stripped)
            foreach ($match in $m) {
                $stateStr = $match.Groups[1].Value
                $matchCount++
                if ($stateStr -cnotin $VALID_STATES) {
                    [void]$issues.Add([PSCustomObject]@{
                        File    = $relPath
                        Line    = $i + 1
                        State   = $stateStr
                        Context = $stripped.Trim()
                    })
                }
            }
        }
    }
}
$scanSw.Stop()
$totalSw.Stop()

# ============================================================
# Report
# ============================================================
$timingLine = "  Timing: scan=$($scanSw.ElapsedMilliseconds)ms  total=$($totalSw.ElapsedMilliseconds)ms"
$statsLine  = "  Stats:  $matchCount state references, $($files.Count) files"

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "  FAIL: $($issues.Count) invalid gGUI_State string(s) found." -ForegroundColor Red
    Write-Host "  Valid states: $($VALID_STATES -join ', ')" -ForegroundColor Yellow

    $grouped = $issues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        Write-Host "`n    $($group.Name):" -ForegroundColor Yellow
        foreach ($issue in $group.Group | Sort-Object Line) {
            Write-Host "      Line $($issue.Line): invalid state `"$($issue.State)`"  ->  $($issue.Context)" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 1
} else {
    Write-Host "  PASS: All gGUI_State strings are valid ($($VALID_STATES -join ', '))" -ForegroundColor Green
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 0
}
