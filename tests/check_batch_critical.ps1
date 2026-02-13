# check_batch_critical.ps1 - Batched Critical section checks
# Combines 2 checks into one PowerShell process to reduce startup overhead.
# Sub-checks: critical_leaks, critical_sections
# Shared file cache: all src/ files (excluding lib/) read once, pre-filtered for "Critical".
#
# Usage: powershell -File tests\check_batch_critical.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all pass, 1 = any check failed

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

# === Shared file cache (single read for all sub-checks) ===
$allFiles = @(Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse |
    Where-Object { $_.FullName -notlike "*\lib\*" })
$fileCache = @{}
$fileCacheText = @{}
foreach ($f in $allFiles) {
    $text = [System.IO.File]::ReadAllText($f.FullName)
    $fileCacheText[$f.FullName] = $text
    $fileCache[$f.FullName] = $text -split "`r?`n"
}

# === Sub-check tracking ===
$subTimings = [System.Collections.ArrayList]::new()
$anyFailed = $false
$failOutput = [System.Text.StringBuilder]::new()

# === Shared helpers ===

function BC_CleanLine {
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

function BC_StripComments {
    param([string]$line)
    if ($line.Length -eq 0) { return '' }
    $trimmed = $line.TrimStart()
    if ($trimmed.Length -eq 0) { return '' }
    if ($trimmed[0] -eq ';') { return '' }
    if ($line.IndexOf(';') -ge 0) {
        return $line -replace '\s;.*$', ''
    }
    return $line
}

function BC_CountBraces {
    param([string]$line)
    $opens = 0; $closes = 0
    foreach ($c in $line.ToCharArray()) {
        if ($c -eq '{') { $opens++ }
        elseif ($c -eq '}') { $closes++ }
    }
    return @($opens, $closes)
}

function BC_TestCriticalOn {
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

function BC_TestCriticalOff {
    param([string]$line)
    $trimmed = $line.Trim()
    if ($trimmed -match '(?i)^\s*Critical[\s(]+["\x27]?Off["\x27]?\s*\)?') { return $true }
    if ($trimmed -match '(?i)^\s*Critical[\s(]+false\s*\)?') { return $true }
    if ($trimmed -match '(?i)^\s*Critical[\s(]+0\s*\)?') { return $true }
    return $false
}

$BC_keywordSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
@(
    'if', 'else', 'while', 'for', 'loop', 'switch', 'case', 'catch',
    'finally', 'try', 'class', 'return', 'throw', 'static', 'global',
    'local', 'until', 'not', 'and', 'or', 'is', 'in', 'contains',
    'new', 'super', 'this', 'true', 'false', 'unset', 'isset', 'Critical'
) | ForEach-Object { [void]$BC_keywordSet.Add($_) }

# ============================================================
# Sub-check 1: critical_leaks
# Detects calls to functions containing Critical "Off" from inside
# Critical "On" sections (cross-function Critical state leak).
# Suppress: ; lint-ignore: critical-leak
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$clIssues = [System.Collections.ArrayList]::new()

# Pass 1: Identify functions that contain Critical "Off"
# Also cache processed line data (cleaned, stripped, braces) for reuse in Pass 2
$criticalOffFunctions = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
$clFuncCount = 0
$lineDataCache = @{}  # file -> array of @{ Raw; Cleaned; Stripped; Braces }

foreach ($file in $allFiles) {
    if ($fileCacheText[$file.FullName].IndexOf('Critical') -lt 0) { continue }
    $lines = $fileCache[$file.FullName]

    # Pre-process all lines and cache results
    $lineData = [System.Collections.ArrayList]::new($lines.Count)
    for ($li = 0; $li -lt $lines.Count; $li++) {
        $rawLine = $lines[$li]
        $cleaned = BC_CleanLine $rawLine
        $stripped = if ($cleaned -ne '') { BC_StripComments $rawLine } else { '' }
        $braces = if ($cleaned -ne '') { BC_CountBraces $cleaned } else { @(0, 0) }
        [void]$lineData.Add(@{ Raw = $rawLine; Cleaned = $cleaned; Stripped = $stripped; Braces = $braces })
    }
    $lineDataCache[$file.FullName] = $lineData

    $depth = 0
    $inFunc = $false
    $funcDepth = -1
    $funcName = ""

    for ($i = 0; $i -lt $lineData.Count; $i++) {
        $ld = $lineData[$i]
        $cleaned = $ld.Cleaned
        if ($cleaned -eq '') { continue }

        if (-not $inFunc -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(') {
            $fname = $Matches[1]
            if (-not $BC_keywordSet.Contains($fname) -and $cleaned -match '\{') {
                $inFunc = $true
                $funcName = $fname
                $funcDepth = $depth
                $clFuncCount++
            }
        }

        $depth += $ld.Braces[0] - $ld.Braces[1]

        if ($inFunc) {
            if (BC_TestCriticalOff $ld.Stripped) {
                [void]$criticalOffFunctions.Add($funcName)
            }

            if ($depth -le $funcDepth) {
                $inFunc = $false
                $funcDepth = -1
            }
        }
    }
}

# Pass 2: Find calls to those functions inside Critical sections
# Uses cached line data from Pass 1 (no re-cleaning, re-stripping, or re-counting braces)
if ($criticalOffFunctions.Count -gt 0) {
    # Pre-filter: build regex to skip files that don't mention any leaked function
    $escapedLeaked = @($criticalOffFunctions | ForEach-Object { [regex]::Escape($_) })
    $leakedPattern = [regex]::new('(?:' + ($escapedLeaked -join '|') + ')', 'Compiled')

    foreach ($file in $allFiles) {
        if (-not $lineDataCache.ContainsKey($file.FullName)) { continue }
        # Skip files that don't call any leaked function
        if (-not $leakedPattern.IsMatch($fileCacheText[$file.FullName])) { continue }

        $lineData = $lineDataCache[$file.FullName]
        $relPath = $file.FullName.Replace("$projectRoot\", '')
        $depth = 0
        $inFunc = $false
        $funcDepth = -1
        $funcName = ""
        $criticalOn = $false

        for ($i = 0; $i -lt $lineData.Count; $i++) {
            $ld = $lineData[$i]
            $cleaned = $ld.Cleaned
            if ($cleaned -eq '') { continue }

            if (-not $inFunc -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(') {
                $fname = $Matches[1]
                if (-not $BC_keywordSet.Contains($fname) -and $cleaned -match '\{') {
                    $inFunc = $true
                    $funcName = $fname
                    $funcDepth = $depth
                    $criticalOn = $false
                }
            }

            $depth += $ld.Braces[0] - $ld.Braces[1]

            if ($inFunc) {
                if (BC_TestCriticalOn $ld.Stripped) {
                    $criticalOn = $true
                }
                elseif (BC_TestCriticalOff $ld.Stripped) {
                    $criticalOn = $false
                }

                if ($criticalOn) {
                    $callMatches = [regex]::Matches($cleaned, '(?<![.\w])(\w+)\s*\(')
                    foreach ($m in $callMatches) {
                        $callee = $m.Groups[1].Value
                        if ($BC_keywordSet.Contains($callee)) { continue }
                        if ($callee -eq $funcName) { continue }

                        if ($criticalOffFunctions.Contains($callee)) {
                            if ($ld.Raw -notmatch 'lint-ignore:\s*critical-leak') {
                                [void]$clIssues.Add([PSCustomObject]@{
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

if ($clIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($clIssues.Count) Critical leak(s) found.")
    [void]$failOutput.AppendLine("  These call functions containing Critical `"Off`" from inside a Critical section.")
    [void]$failOutput.AppendLine("  AHK v2 Critical is thread-level `u{2014} the callee's `"Off`" destroys the caller's Critical state.")
    [void]$failOutput.AppendLine("  Fix: remove Critical `"Off`" from the callee, or suppress with:")
    [void]$failOutput.AppendLine("    FuncName()  ; lint-ignore: critical-leak")
    $grouped = $clIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): $($issue.Caller)() calls $($issue.Callee)() inside Critical `u{2014} $($issue.Callee)() contains Critical `"Off`"")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_critical_leaks"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 2: critical_sections
# Detects return/continue/throw inside Critical "On" sections
# without preceding Critical "Off".
# Suppress: ; lint-ignore: critical-section (throw cannot be suppressed)
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$csIssues = [System.Collections.ArrayList]::new()
$csFuncCount = 0

foreach ($file in $allFiles) {
    if ($fileCacheText[$file.FullName].IndexOf('Critical') -lt 0) { continue }

    # Reuse pre-processed line data from sub-check 1 (avoids re-cleaning/re-counting)
    $hasLineData = $lineDataCache.ContainsKey($file.FullName)
    $lineData = if ($hasLineData) { $lineDataCache[$file.FullName] } else { $null }
    $lines = $fileCache[$file.FullName]

    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $depth = 0
    $inFunc = $false
    $funcDepth = -1
    $funcName = ""
    $criticalOn = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($hasLineData) {
            $ld = $lineData[$i]
            $rawLine = $ld.Raw
            $cleaned = $ld.Cleaned
            $commentStripped = $ld.Stripped
            $braceData = $ld.Braces
        } else {
            $rawLine = $lines[$i]
            $cleaned = BC_CleanLine $rawLine
            $commentStripped = if ($cleaned -ne '') { BC_StripComments $rawLine } else { '' }
            $braceData = if ($cleaned -ne '') { BC_CountBraces $cleaned } else { @(0, 0) }
        }
        if ($cleaned -eq '') { continue }

        if (-not $inFunc -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(') {
            $fname = $Matches[1]
            if (-not $BC_keywordSet.Contains($fname) -and $cleaned -match '\{') {
                $inFunc = $true
                $funcName = $fname
                $funcDepth = $depth
                $criticalOn = $false
                $csFuncCount++
            }
        }

        $depth += $braceData[0] - $braceData[1]

        if ($inFunc) {
            if (BC_TestCriticalOn $commentStripped) {
                $criticalOn = $true
            }
            elseif (BC_TestCriticalOff $commentStripped) {
                $criticalOn = $false
            }

            if ($criticalOn) {
                $isReturn = $cleaned -match '(?i)^\s*return\b'
                $isContinue = $cleaned -match '(?i)^\s*continue\b'
                $isThrow = $cleaned -match '(?i)^\s*throw\b'

                if ($isReturn -or $isContinue -or $isThrow) {
                    $canSuppress = -not $isThrow
                    if (-not $canSuppress -or $rawLine -notmatch 'lint-ignore:\s*critical-section') {
                        if ($isReturn) { $stmtType = 'return' }
                        elseif ($isContinue) { $stmtType = 'continue' }
                        else { $stmtType = 'throw' }
                        [void]$csIssues.Add([PSCustomObject]@{
                            File      = $relPath
                            Line      = $i + 1
                            Function  = $funcName
                            Statement = $stmtType
                        })
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

if ($csIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($csIssues.Count) Critical section issue(s) found.")
    [void]$failOutput.AppendLine("  These return/continue/throw while Critical is On, which may skip Critical `"Off`".")
    [void]$failOutput.AppendLine("  Fix: add Critical `"Off`" before the statement, or suppress with:")
    [void]$failOutput.AppendLine("    return  ; lint-ignore: critical-section")
    [void]$failOutput.AppendLine("  Note: throw inside Critical cannot be suppressed (always a bug).")
    $grouped = $csIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): $($issue.Function)() has '$($issue.Statement)' inside Critical `"On`" section")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_critical_sections"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Report
# ============================================================
$totalSw.Stop()

if ($anyFailed) {
    Write-Host $failOutput.ToString().TrimEnd()
} else {
    Write-Host "  PASS: All Critical checks passed (critical_leaks, critical_sections)" -ForegroundColor Green
}

Write-Host "  Timing: total=$($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan

# Write sub-timing for nested display (consumed by static_analysis.ps1)
$subTimings | ConvertTo-Json -Compress | Set-Content "$env:TEMP\sa_batch_critical_timing.json" -Encoding UTF8

if ($anyFailed) { exit 1 }
exit 0
