# check_critical_sections.ps1 - Static analysis for AHK v2 Critical section hygiene
# Pre-gate test: runs before any AHK process launches.
# Detects functions where return or continue occurs inside a Critical "On"
# section without a preceding Critical "Off", which would leave Critical on
# after the function exits (or skip cleanup in a loop).
#
# Some handlers (e.g., GUI hotkey callbacks) intentionally leave Critical on.
# Suppress individual lines with: ; lint-ignore: critical-section
#
# Usage: powershell -File tests\check_critical_sections.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all clear, 1 = issues found

param(
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

# === Helpers ===
function Clean-Line {
    param([string]$line)
    # Remove quoted strings to avoid false matches inside string literals
    $cleaned = $line -replace '"[^"]*"', '""'
    $cleaned = $cleaned -replace "'[^']*'", "''"
    # Remove end-of-line comments (semicolon preceded by whitespace)
    $cleaned = $cleaned -replace '\s;.*$', ''
    # Remove full-line comments
    if ($cleaned -match '^\s*;') { return '' }
    return $cleaned
}

function Strip-Comments {
    # Strip comments only (preserve string contents for Critical detection)
    param([string]$line)
    $stripped = $line -replace '\s;.*$', ''
    if ($stripped -match '^\s*;') { return '' }
    return $stripped
}

function Count-Braces {
    param([string]$line)
    $opens = 0; $closes = 0
    foreach ($c in $line.ToCharArray()) {
        if ($c -eq '{') { $opens++ }
        elseif ($c -eq '}') { $closes++ }
    }
    return @($opens, $closes)
}

function Test-CriticalOn {
    param([string]$line)
    $trimmed = $line.Trim()
    if ($trimmed -match '(?i)^\s*Critical[\s(]+["\x27]?On["\x27]?\s*\)?') { return $true }
    if ($trimmed -match '(?i)^\s*Critical[\s(]+true\s*\)?') { return $true }
    if ($trimmed -match '(?i)^\s*Critical[\s(]+(\d+)\s*\)?') {
        $val = [int]$Matches[1]
        if ($val -gt 0) { return $true }
        return $false
    }
    if ($trimmed -match '(?i)^\s*Critical\s*$') { return $true }
    return $false
}

function Test-CriticalOff {
    param([string]$line)
    $trimmed = $line.Trim()
    if ($trimmed -match '(?i)^\s*Critical[\s(]+["\x27]?Off["\x27]?\s*\)?') { return $true }
    if ($trimmed -match '(?i)^\s*Critical[\s(]+false\s*\)?') { return $true }
    if ($trimmed -match '(?i)^\s*Critical[\s(]+0\s*\)?') { return $true }
    return $false
}

function Test-HasSuppression {
    param([string]$rawLine)
    return ($rawLine -match 'lint-ignore:\s*critical-section')
}

$AHK_KEYWORDS = @(
    'if', 'else', 'while', 'for', 'loop', 'switch', 'case', 'catch',
    'finally', 'try', 'class', 'return', 'throw', 'static', 'global',
    'local', 'until', 'not', 'and', 'or', 'is', 'in', 'contains',
    'new', 'super', 'this', 'true', 'false', 'unset', 'isset'
)

# === Resolve source directory ===
if (-not $SourceDir) {
    $SourceDir = (Resolve-Path "$PSScriptRoot\..\src").Path
}
if (-not (Test-Path $SourceDir)) {
    Write-Host "  ERROR: Source directory not found: $SourceDir" -ForegroundColor Red
    exit 1
}

$projectRoot = (Resolve-Path "$SourceDir\..").Path
$files = Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse
Write-Host "  Scanning $($files.Count) files for Critical section issues..." -ForegroundColor Cyan

# ============================================================
# Single pass: parse each function and track Critical state
# ============================================================
$scanSw = [System.Diagnostics.Stopwatch]::StartNew()
$issues = [System.Collections.ArrayList]::new()
$funcCount = 0

foreach ($file in $files) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $depth = 0
    $inFunc = $false
    $funcDepth = -1
    $funcName = ""
    $criticalOn = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $rawLine = $lines[$i]
        $cleaned = Clean-Line $rawLine
        if ($cleaned -eq '') { continue }

        # Use comment-stripped (but string-preserved) line for Critical detection
        $commentStripped = Strip-Comments $rawLine

        # Detect function/method start (when not already inside one)
        if (-not $inFunc -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(') {
            $fname = $Matches[1]
            if ($fname.ToLower() -notin $AHK_KEYWORDS -and $cleaned -match '\{') {
                $inFunc = $true
                $funcName = $fname
                $funcDepth = $depth
                $criticalOn = $false
                $funcCount++
            }
        }

        $braces = Count-Braces $cleaned
        $depth += $braces[0] - $braces[1]

        if ($inFunc) {
            # Track Critical state transitions
            if (Test-CriticalOn $commentStripped) {
                $criticalOn = $true
            }
            elseif (Test-CriticalOff $commentStripped) {
                $criticalOn = $false
            }

            # Check for return/continue while Critical is on
            if ($criticalOn) {
                $isReturn = $cleaned -match '(?i)^\s*return\b'
                $isContinue = $cleaned -match '(?i)^\s*continue\b'

                if ($isReturn -or $isContinue) {
                    if (-not (Test-HasSuppression $rawLine)) {
                        if ($isReturn) { $stmtType = 'return' } else { $stmtType = 'continue' }
                        [void]$issues.Add([PSCustomObject]@{
                            File      = $relPath
                            Line      = $i + 1
                            Function  = $funcName
                            Statement = $stmtType
                        })
                    }
                }
            }

            # End of function
            if ($depth -le $funcDepth) {
                $inFunc = $false
                $funcDepth = -1
                $criticalOn = $false
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
$statsLine  = "  Stats:  $funcCount functions, $($files.Count) files"

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "  FAIL: $($issues.Count) Critical section issue(s) found." -ForegroundColor Red
    Write-Host "  These return/continue while Critical is On, which may skip Critical `"Off`"." -ForegroundColor Red
    Write-Host "  Fix: add Critical `"Off`" before the statement, or suppress with:" -ForegroundColor Yellow
    Write-Host "    return  ; lint-ignore: critical-section" -ForegroundColor Yellow

    $grouped = $issues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        Write-Host "`n    $($group.Name):" -ForegroundColor Yellow
        foreach ($issue in $group.Group | Sort-Object Line) {
            Write-Host "      Line $($issue.Line): $($issue.Function)() has '$($issue.Statement)' inside Critical `"On`" section" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 1
} else {
    Write-Host "  PASS: All Critical sections properly closed before return/continue" -ForegroundColor Green
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 0
}
