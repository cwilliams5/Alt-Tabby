# check_timer_lifecycle.ps1 - Timer leak prevention
# Verifies every repeating SetTimer(callback, positive) has a corresponding
# SetTimer(callback, 0) cancellation path in the same file.
# Negative periods (run-once timers) are exempt - they auto-cancel after firing.
#
# Usage: powershell -File tests\check_timer_lifecycle.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all clear, 1 = unpaired timers found

param(
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

# === Helpers ===
function Clean-Line {
    param([string]$line)
    $cleaned = $line -replace '"[^"]*"', '""'
    $cleaned = $cleaned -replace "'[^']*'", "''"
    if ($cleaned -match '^\s*;') { return '' }
    $cleaned = $cleaned -replace '\s;.*$', ''
    return $cleaned
}

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
Write-Host "  Scanning $($files.Count) files for timer lifecycle issues..." -ForegroundColor Cyan

$SUPPRESSION = 'lint-ignore: timer-lifecycle'

# ============================================================
# Phase 1: Collect all SetTimer starts and cancellations per file
# ============================================================
$phase1Sw = [System.Diagnostics.Stopwatch]::StartNew()

# Per-file data: { starts: @{ callbackName -> @(lineNums) }, cancels: HashSet<callbackName> }
$fileTimerData = @{}
$fileCache = @{}

foreach ($file in $files) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $fileCache[$file.FullName] = $lines
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    $starts = @{}    # callbackName -> list of line numbers
    $cancels = [System.Collections.Generic.HashSet[string]]::new()
    # Track variables that store bound timer refs: varName -> callbackBaseName
    $boundVars = @{}

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        $cleaned = Clean-Line $raw
        if ($cleaned -eq '') { continue }

        # Skip suppressed lines
        if ($raw.Contains($SUPPRESSION)) { continue }

        # === Detect SetTimer calls ===

        # Pattern 1: SetTimer(FuncName, period) - direct function reference
        if ($cleaned -match 'SetTimer\(\s*([A-Za-z_]\w+)\s*,\s*(.+?)\s*\)') {
            $cbName = $Matches[1]
            $periodStr = $Matches[2].Trim()

            # Check if this is a cancellation (period = 0)
            if ($periodStr -eq '0') {
                [void]$cancels.Add($cbName)
                continue
            }

            # Check if period is negative (run-once, exempt)
            # Matches: -100, -CONSTANT, -cfg.Value, -(expr)
            if ($periodStr -match '^-') { continue }

            # Positive literal or variable period → record as start
            if (-not $starts.ContainsKey($cbName)) {
                $starts[$cbName] = [System.Collections.ArrayList]::new()
            }
            [void]$starts[$cbName].Add($i + 1)
        }

        # Pattern 2: SetTimer(FuncName.Bind(...), period) - bound function, often stored
        # e.g. timerFn := FuncName.Bind(arg) ... SetTimer(timerFn, period)
        if ($cleaned -match 'SetTimer\(\s*([A-Za-z_]\w+)\.Bind\(.*?\)\s*,\s*(.+?)\s*\)') {
            $cbName = $Matches[1]
            $periodStr = $Matches[2].Trim()

            if ($periodStr -eq '0') {
                [void]$cancels.Add($cbName)
                continue
            }
            if ($periodStr -match '^-') { continue }

            if (-not $starts.ContainsKey($cbName)) {
                $starts[$cbName] = [System.Collections.ArrayList]::new()
            }
            [void]$starts[$cbName].Add($i + 1)
        }

        # Pattern 3: varName := FuncName.Bind(...) - track bound variable
        if ($cleaned -match '(\w+)\s*:=\s*([A-Za-z_]\w+)\.Bind\(') {
            $varName = $Matches[1]
            $baseName = $Matches[2]
            $boundVars[$varName] = $baseName
        }

        # Pattern 4: SetTimer(varName, period) - variable holding a bound ref
        if ($cleaned -match 'SetTimer\(\s*([A-Za-z_]\w+)\s*,\s*(.+?)\s*\)') {
            $varName = $Matches[1]
            $periodStr = $Matches[2].Trim()

            if ($boundVars.ContainsKey($varName)) {
                $baseName = $boundVars[$varName]
                if ($periodStr -eq '0') {
                    [void]$cancels.Add($baseName)
                    [void]$cancels.Add($varName)
                } elseif ($periodStr -notmatch '^-\d+$') {
                    if (-not $starts.ContainsKey($baseName)) {
                        $starts[$baseName] = [System.Collections.ArrayList]::new()
                    }
                    # Only add if not already added by Pattern 1 for the same line
                    $lineNum = $i + 1
                    if (-not $starts[$baseName].Contains($lineNum)) {
                        [void]$starts[$baseName].Add($lineNum)
                    }
                }
            }
        }

        # Pattern 5: SetTimer(varName, 0) - cancellation via variable
        # (May catch bound refs tracked above, or direct var refs)
        if ($cleaned -match 'SetTimer\(\s*(\w+)\s*,\s*0\s*\)') {
            $varName = $Matches[1]
            [void]$cancels.Add($varName)
            if ($boundVars.ContainsKey($varName)) {
                [void]$cancels.Add($boundVars[$varName])
            }
        }
    }

    if ($starts.Count -gt 0) {
        $fileTimerData[$relPath] = @{
            Starts  = $starts
            Cancels = $cancels
        }
    }
}
$phase1Sw.Stop()

# ============================================================
# Phase 2: Find starts without corresponding cancellations
# ============================================================
$phase2Sw = [System.Diagnostics.Stopwatch]::StartNew()
$issues = [System.Collections.ArrayList]::new()
$totalStarts = 0
$totalPaired = 0

foreach ($relPath in $fileTimerData.Keys | Sort-Object) {
    $data = $fileTimerData[$relPath]
    $starts = $data.Starts
    $cancels = $data.Cancels

    foreach ($cbName in $starts.Keys) {
        $totalStarts += $starts[$cbName].Count

        # Check if there's a cancel for this callback in the same file
        if ($cancels.Contains($cbName)) {
            $totalPaired += $starts[$cbName].Count
            continue
        }

        # No cancellation found - flag each start location
        foreach ($lineNum in $starts[$cbName]) {
            [void]$issues.Add([PSCustomObject]@{
                File     = $relPath
                Line     = $lineNum
                Callback = $cbName
            })
        }
    }
}
$phase2Sw.Stop()
$totalSw.Stop()

# ============================================================
# Report
# ============================================================
$timingLine = "  Timing: phase1=$($phase1Sw.ElapsedMilliseconds)ms  phase2=$($phase2Sw.ElapsedMilliseconds)ms  total=$($totalSw.ElapsedMilliseconds)ms"
$statsLine  = "  Stats:  $totalStarts timer start(s), $totalPaired paired, $($issues.Count) unpaired, $($files.Count) file(s)"

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "  FAIL: $($issues.Count) repeating timer(s) without cancellation found." -ForegroundColor Red
    Write-Host "  Every SetTimer(fn, positive) needs a SetTimer(fn, 0) in the same file." -ForegroundColor Red
    Write-Host "  Fix: add SetTimer(callback, 0) in cleanup/exit/stop paths." -ForegroundColor Yellow
    Write-Host "  Suppress: add '; lint-ignore: timer-lifecycle' on the SetTimer line." -ForegroundColor Yellow

    $grouped = $issues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        Write-Host ""
        Write-Host "    $($group.Name):" -ForegroundColor Yellow
        foreach ($issue in $group.Group | Sort-Object Line) {
            Write-Host "      Line $($issue.Line): SetTimer($($issue.Callback), ...) - no cancellation found" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 1
} else {
    Write-Host "  PASS: All $totalStarts repeating timer(s) have cancellation paths" -ForegroundColor Green
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 0
}
