# check_critical_leaks.ps1 - Static analysis for AHK v2 Critical state leaks across function calls
# Pre-gate test: runs before any AHK process launches.
#
# AHK v2 Critical is thread-level, not function-scoped. If function A holds
# Critical "On" and calls function B which contains Critical "Off", B's "Off"
# silently destroys A's Critical state. This check detects that pattern.
#
# Pass 1: Identify functions containing Critical "Off"
# Pass 2: Flag calls to those functions from inside Critical "On" sections
#
# Suppress individual lines with: ; lint-ignore: critical-leak
#
# Usage: powershell -File tests\check_critical_leaks.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all clear, 1 = issues found

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
    $cleaned = $cleaned -replace '\s;.*$', ''
    if ($cleaned -match '^\s*;') { return '' }
    return $cleaned
}

function Strip-Comments {
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
    return ($rawLine -match 'lint-ignore:\s*critical-leak')
}

$AHK_KEYWORDS = @(
    'if', 'else', 'while', 'for', 'loop', 'switch', 'case', 'catch',
    'finally', 'try', 'class', 'return', 'throw', 'static', 'global',
    'local', 'until', 'not', 'and', 'or', 'is', 'in', 'contains',
    'new', 'super', 'this', 'true', 'false', 'unset', 'isset',
    'Critical'
)
$keywordSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($kw in $AHK_KEYWORDS) { [void]$keywordSet.Add($kw) }

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

Write-Host "  Scanning $($files.Count) files for Critical leaks across function calls..." -ForegroundColor Cyan

# ============================================================
# Pass 1: Identify functions that contain Critical "Off"
# ============================================================
$pass1Sw = [System.Diagnostics.Stopwatch]::StartNew()
$criticalOffFunctions = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
$funcCount = 0

foreach ($file in $files) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $joined = [string]::Join("`n", $lines)
    if ($joined.IndexOf('Critical') -lt 0) { continue }

    $depth = 0
    $inFunc = $false
    $funcDepth = -1
    $funcName = ""

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $rawLine = $lines[$i]
        $cleaned = Clean-Line $rawLine
        if ($cleaned -eq '') { continue }

        $commentStripped = Strip-Comments $rawLine

        if (-not $inFunc -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(') {
            $fname = $Matches[1]
            if (-not $keywordSet.Contains($fname) -and $cleaned -match '\{') {
                $inFunc = $true
                $funcName = $fname
                $funcDepth = $depth
                $funcCount++
            }
        }

        $braces = Count-Braces $cleaned
        $depth += $braces[0] - $braces[1]

        if ($inFunc) {
            if (Test-CriticalOff $commentStripped) {
                [void]$criticalOffFunctions.Add($funcName)
            }

            if ($depth -le $funcDepth) {
                $inFunc = $false
                $funcDepth = -1
            }
        }
    }
}
$pass1Sw.Stop()

# ============================================================
# Pass 2: Find calls to those functions inside Critical sections
# ============================================================
$pass2Sw = [System.Diagnostics.Stopwatch]::StartNew()
$issues = [System.Collections.ArrayList]::new()

if ($criticalOffFunctions.Count -gt 0) {
    foreach ($file in $files) {
        $lines = [System.IO.File]::ReadAllLines($file.FullName)
        $joined = [string]::Join("`n", $lines)
        if ($joined.IndexOf('Critical') -lt 0) { continue }

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

            $commentStripped = Strip-Comments $rawLine

            if (-not $inFunc -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(') {
                $fname = $Matches[1]
                if (-not $keywordSet.Contains($fname) -and $cleaned -match '\{') {
                    $inFunc = $true
                    $funcName = $fname
                    $funcDepth = $depth
                    $criticalOn = $false
                }
            }

            $braces = Count-Braces $cleaned
            $depth += $braces[0] - $braces[1]

            if ($inFunc) {
                if (Test-CriticalOn $commentStripped) {
                    $criticalOn = $true
                }
                elseif (Test-CriticalOff $commentStripped) {
                    $criticalOn = $false
                }

                # When inside Critical, check for calls to leaking functions
                if ($criticalOn) {
                    # Match function calls: identifier( but not .method( or keyword(
                    $callMatches = [regex]::Matches($cleaned, '(?<![.\w])(\w+)\s*\(')
                    foreach ($m in $callMatches) {
                        $callee = $m.Groups[1].Value
                        if ($keywordSet.Contains($callee)) { continue }
                        if ($callee -eq $funcName) { continue }  # Skip recursive calls

                        if ($criticalOffFunctions.Contains($callee)) {
                            if (-not (Test-HasSuppression $rawLine)) {
                                [void]$issues.Add([PSCustomObject]@{
                                    File   = $relPath
                                    Line   = $i + 1
                                    Caller = $funcName
                                    Callee = $callee
                                })
                            }
                        }
                    }
                }

                if ($depth -le $funcDepth) {
                    $inFunc = $false
                    $funcDepth = -1
                    $criticalOn = $false
                }
            }
        }
    }
}
$pass2Sw.Stop()
$totalSw.Stop()

# ============================================================
# Report
# ============================================================
$timingLine = "  Timing: pass1=$($pass1Sw.ElapsedMilliseconds)ms  pass2=$($pass2Sw.ElapsedMilliseconds)ms  total=$($totalSw.ElapsedMilliseconds)ms"
$statsLine  = "  Stats:  $funcCount functions, $($files.Count) files, $($criticalOffFunctions.Count) functions with Critical `"Off`""

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "  FAIL: $($issues.Count) Critical leak(s) found." -ForegroundColor Red
    Write-Host "  These call functions containing Critical `"Off`" from inside a Critical section." -ForegroundColor Red
    Write-Host "  AHK v2 Critical is thread-level `u{2014} the callee's `"Off`" destroys the caller's Critical state." -ForegroundColor Red
    Write-Host "  Fix: remove Critical `"Off`" from the callee, or suppress with:" -ForegroundColor Yellow
    Write-Host "    FuncName()  ; lint-ignore: critical-leak" -ForegroundColor Yellow

    $grouped = $issues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        Write-Host "`n    $($group.Name):" -ForegroundColor Yellow
        foreach ($issue in $group.Group | Sort-Object Line) {
            Write-Host "      Line $($issue.Line): $($issue.Caller)() calls $($issue.Callee)() inside Critical `u{2014} $($issue.Callee)() contains Critical `"Off`"" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 1
} else {
    Write-Host "  PASS: No Critical leaks across function calls" -ForegroundColor Green
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 0
}
