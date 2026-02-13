# check_batch_timers.ps1 - Batched timer-related checks
# Combines 2 checks into one PowerShell process to reduce startup overhead.
# Sub-checks: static_in_timers, timer_lifecycle
# Shared file cache: all src/ files (excluding lib/) read once.
#
# Usage: powershell -File tests\check_batch_timers.ps1 [-SourceDir "path\to\src"]
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

$BT_AHK_KEYWORDS = @(
    'if', 'else', 'while', 'for', 'loop', 'switch', 'case', 'catch',
    'finally', 'try', 'class', 'return', 'throw', 'static', 'global',
    'local', 'until', 'not', 'and', 'or', 'is', 'in', 'contains',
    'new', 'super', 'this', 'true', 'false', 'unset', 'isset'
)

# ============================================================
# Sub-check 1: static_in_timers
# Detects static variables used for state tracking inside timer
# callback functions. Static vars leak state if timer is cancelled
# and restarted.
# Suppress: ; lint-ignore: static-in-timer
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$stIssues = [System.Collections.ArrayList]::new()

# Phase 1: Find all SetTimer targets (function names used as callbacks)
$timerCallbacks = @{}  # functionName -> list of "relpath:lineNum"

foreach ($file in $allFiles) {
    # Pre-filter: skip files that don't contain "SetTimer"
    if ($fileCacheText[$file.FullName].IndexOf('SetTimer', [System.StringComparison]::Ordinal) -lt 0) { continue }

    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = BT_CleanLine $lines[$i]
        if ($cleaned -eq '') { continue }

        # Direct function reference: SetTimer(FuncName  or  SetTimer FuncName
        if ($cleaned -match 'SetTimer\(\s*([A-Za-z_]\w+)\s*[,\.\)]' -or
            $cleaned -match 'SetTimer\s+([A-Za-z_]\w+)\s*[,]') {
            $funcName = $Matches[1]
            if ($funcName -eq 'ToolTip') { continue }
            if (-not $timerCallbacks.ContainsKey($funcName)) {
                $timerCallbacks[$funcName] = [System.Collections.ArrayList]::new()
            }
            [void]$timerCallbacks[$funcName].Add("${relPath}:$($i + 1)")
        }

        # ObjBindMethod pattern: SetTimer(ObjBindMethod(obj, "MethodName"
        if ($cleaned -match 'SetTimer\(\s*ObjBindMethod\(\s*\w+\s*,\s*"(\w+)"') {
            $methodName = $Matches[1]
            if (-not $timerCallbacks.ContainsKey($methodName)) {
                $timerCallbacks[$methodName] = [System.Collections.ArrayList]::new()
            }
            [void]$timerCallbacks[$methodName].Add("${relPath}:$($i + 1)")
        }

        # .Bind() pattern: SetTimer(FuncName.Bind(
        if ($cleaned -match 'SetTimer\(\s*([A-Za-z_]\w+)\.Bind\(') {
            $funcName = $Matches[1]
            if (-not $timerCallbacks.ContainsKey($funcName)) {
                $timerCallbacks[$funcName] = [System.Collections.ArrayList]::new()
            }
            [void]$timerCallbacks[$funcName].Add("${relPath}:$($i + 1)")
        }
    }
}

# Phase 2: For each timer callback, find static variable declarations
$stFunctionsScanned = 0

foreach ($file in $allFiles) {
    $lines = $fileCache[$file.FullName]

    # Pre-filter: skip files without any timer callback function name
    if ($timerCallbacks.Count -gt 0) {
        $joined = $fileCacheText[$file.FullName]
        $hasCallback = $false
        foreach ($cbName in $timerCallbacks.Keys) {
            if ($joined.IndexOf($cbName) -ge 0) { $hasCallback = $true; break }
        }
        if (-not $hasCallback) { continue }
    }

    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $depth = 0
    $inFunc = $false
    $funcDepth = -1
    $funcName = ""

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = BT_CleanLine $lines[$i]

        if (-not $inFunc -and $cleaned -ne '' -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(') {
            $fname = $Matches[1]
            if ($fname.ToLower() -notin $BT_AHK_KEYWORDS -and $cleaned -match '\{') {
                $inFunc = $true
                $funcName = $fname
                $funcDepth = $depth
                $stFunctionsScanned++
            }
        }

        $braces = BT_CountBraces $cleaned
        $depth += $braces[0] - $braces[1]

        if ($inFunc) {
            if ($timerCallbacks.ContainsKey($funcName) -and $cleaned -ne '') {
                if ($cleaned -match '^\s*static\s+(.+)') {
                    $staticContent = $Matches[1]
                    $rawLine = $lines[$i]

                    if ($rawLine -match 'lint-ignore:\s*static-in-timer') {
                        # Suppressed
                    } else {
                        # Parse each variable in the static declaration
                        $parenDepth = 0
                        $parts = [System.Collections.ArrayList]::new()
                        $current = [System.Text.StringBuilder]::new()
                        foreach ($c in $staticContent.ToCharArray()) {
                            if ($c -eq '(' -or $c -eq '[') { $parenDepth++ }
                            elseif ($c -eq ')' -or $c -eq ']') { if ($parenDepth -gt 0) { $parenDepth-- } }
                            if ($c -eq ',' -and $parenDepth -eq 0) {
                                [void]$parts.Add($current.ToString())
                                $current = [System.Text.StringBuilder]::new()
                            } else {
                                [void]$current.Append($c)
                            }
                        }
                        [void]$parts.Add($current.ToString())

                        foreach ($part in $parts) {
                            $trimmed = $part.Trim()
                            if ($trimmed -match '^(\w+)(.*)$') {
                                $varName = $Matches[1]
                                $rest = $Matches[2].Trim()

                                # Exclusion: Buffer() allocations for DllCall marshalling
                                if ($rest -match '^:=\s*Buffer\(') { continue }

                                # Exclusion: static var := 0 (numeric zero init for DllCall marshal)
                                if ($rest -match '^:=\s*0\s*$') { continue }

                                [void]$stIssues.Add([PSCustomObject]@{
                                    File         = $relPath
                                    Function     = $funcName
                                    Line         = ($i + 1)
                                    Variable     = $varName
                                    SetTimerRefs = $timerCallbacks[$funcName]
                                })
                            }
                        }
                    }
                }
            }

            if ($depth -le $funcDepth) {
                $inFunc = $false
                $funcDepth = -1
            }
        }
    }
}

if ($stIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($stIssues.Count) static variable(s) in timer callback(s) found.")
    [void]$failOutput.AppendLine("  Static vars in timer callbacks can leak state if the timer is cancelled and restarted.")
    [void]$failOutput.AppendLine("  Fix: use tick-based timing with globals instead of static counters.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: static-in-timer' on the static declaration line.")
    $grouped = $stIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): $($issue.Function)() has static var '$($issue.Variable)'")
            foreach ($ref in $issue.SetTimerRefs) {
                [void]$failOutput.AppendLine("        (SetTimer at $ref)")
            }
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_static_in_timers"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 2: timer_lifecycle
# Verifies every repeating SetTimer(callback, positive) has a
# corresponding SetTimer(callback, 0) cancellation in the same file.
# Negative periods (run-once timers) are exempt.
# Suppress: ; lint-ignore: timer-lifecycle
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$TL_SUPPRESSION = 'lint-ignore: timer-lifecycle'
$bindIdentityIssues = [System.Collections.ArrayList]::new()

# Phase 1: Collect all SetTimer starts and cancellations per file
$fileTimerData = @{}

foreach ($file in $allFiles) {
    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    $starts = @{}    # callbackName -> list of line numbers
    $cancels = [System.Collections.Generic.HashSet[string]]::new()
    $boundVars = @{}  # varName -> callbackBaseName

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        $cleaned = BT_CleanLine $raw
        if ($cleaned -eq '') { continue }

        if ($raw.Contains($TL_SUPPRESSION)) { continue }

        # Pattern 1: SetTimer(FuncName, period) - direct function reference
        if ($cleaned -match 'SetTimer\(\s*([A-Za-z_]\w+)\s*,\s*(.+?)\s*\)') {
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

        # Pattern 2: SetTimer(FuncName.Bind(...), period)
        if ($cleaned -match 'SetTimer\(\s*([A-Za-z_]\w+)\.Bind\(.*?\)\s*,\s*(.+?)\s*\)') {
            $cbName = $Matches[1]
            $periodStr = $Matches[2].Trim()

            if ($periodStr -eq '0') {
                [void]$cancels.Add($cbName)
                continue
            }
            if ($periodStr -match '^-') { continue }

            # Bind identity check: inline .Bind() with positive period creates
            # an uncancellable repeating timer (each .Bind() creates a new object).
            # Correct pattern: store bound ref in a variable first.
            if ($periodStr -match '^\d+$' -and [int]$periodStr -gt 0) {
                [void]$bindIdentityIssues.Add([PSCustomObject]@{
                    File     = $relPath
                    Line     = ($i + 1)
                    Callback = $cbName
                    Period   = $periodStr
                })
            }

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
                    $lineNum = $i + 1
                    if (-not $starts[$baseName].Contains($lineNum)) {
                        [void]$starts[$baseName].Add($lineNum)
                    }
                }
            }
        }

        # Pattern 5: SetTimer(varName, 0) - cancellation via variable
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

# Phase 2: Find starts without corresponding cancellations
$tlIssues = [System.Collections.ArrayList]::new()
$totalStarts = 0
$totalPaired = 0

foreach ($relPath in $fileTimerData.Keys | Sort-Object) {
    $data = $fileTimerData[$relPath]
    $starts = $data.Starts
    $cancels = $data.Cancels

    foreach ($cbName in $starts.Keys) {
        $totalStarts += $starts[$cbName].Count

        if ($cancels.Contains($cbName)) {
            $totalPaired += $starts[$cbName].Count
            continue
        }

        foreach ($lineNum in $starts[$cbName]) {
            [void]$tlIssues.Add([PSCustomObject]@{
                File     = $relPath
                Line     = $lineNum
                Callback = $cbName
            })
        }
    }
}

if ($tlIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($tlIssues.Count) repeating timer(s) without cancellation found.")
    [void]$failOutput.AppendLine("  Every SetTimer(fn, positive) needs a SetTimer(fn, 0) in the same file.")
    [void]$failOutput.AppendLine("  Fix: add SetTimer(callback, 0) in cleanup/exit/stop paths.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: timer-lifecycle' on the SetTimer line.")
    $grouped = $tlIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): SetTimer($($issue.Callback), ...) - no cancellation found")
        }
    }
}

if ($bindIdentityIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($bindIdentityIssues.Count) repeating timer(s) with inline .Bind() found.")
    [void]$failOutput.AppendLine("  Each .Bind() creates a new object, so SetTimer(fn.Bind(x), 0) won't cancel")
    [void]$failOutput.AppendLine("  a timer started with SetTimer(fn.Bind(x), period) - different objects.")
    [void]$failOutput.AppendLine("  Fix: store the bound ref in a variable first:")
    [void]$failOutput.AppendLine("    boundRef := Func.Bind(args)")
    [void]$failOutput.AppendLine("    SetTimer(boundRef, period)")
    [void]$failOutput.AppendLine("    SetTimer(boundRef, 0)  ; same object - cancellation works")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: timer-lifecycle' on the SetTimer line.")
    $grouped = $bindIdentityIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): SetTimer($($issue.Callback).Bind(...), $($issue.Period)) - inline .Bind() creates uncancellable timer")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_timer_lifecycle"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Report
# ============================================================
$totalSw.Stop()

if ($anyFailed) {
    Write-Host $failOutput.ToString().TrimEnd()
} else {
    Write-Host "  PASS: All timer checks passed (static_in_timers, timer_lifecycle)" -ForegroundColor Green
}

Write-Host "  Timing: total=$($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan

# Write sub-timing for nested display (consumed by static_analysis.ps1)
$subTimings | ConvertTo-Json -Compress | Set-Content "$env:TEMP\sa_batch_timers_timing.json" -Encoding UTF8

if ($anyFailed) { exit 1 }
exit 0
