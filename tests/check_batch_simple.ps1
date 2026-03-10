# check_batch_simple.ps1 - Batched simple pattern checks (part A)
# Heavy checks that share processedCache. Lighter checks are in check_batch_simple_b.ps1.
# Sub-checks: dead_globals, static_in_timers, timer_lifecycle, dead_locals, dead_params
# Shared file cache: all src/ files (excluding lib/) read once.
#
# Usage: powershell -File tests\check_batch_simple.ps1 [-SourceDir "path\to\src"]
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
    $lines = $text.Split([string[]]@("`r`n", "`n"), [StringSplitOptions]::None)
    $fileCache[$f.FullName] = $lines
}

# === Sub-check tracking ===
$subTimings = [System.Collections.ArrayList]::new()
$anyFailed = $false
$failOutput = [System.Text.StringBuilder]::new()

# === Shared helpers ===

# Pre-compiled regex patterns (hot-path, called 30K+ times in processedCache build)
$script:RX_DBL_STR  = [regex]::new('"[^"]*"', 'Compiled')
$script:RX_SGL_STR  = [regex]::new("'[^']*'", 'Compiled')
$script:RX_CMT_TAIL = [regex]::new('\s;.*$', 'Compiled')

function BS_CleanLine {
    param([string]$line)
    if ($line.Length -eq 0) { return '' }
    $trimmed = $line.TrimStart()
    if ($trimmed.Length -eq 0) { return '' }
    if ($trimmed[0] -eq ';') { return '' }
    $cleaned = $line
    if ($line.IndexOf('"') -ge 0) {
        $cleaned = $script:RX_DBL_STR.Replace($cleaned, '""')
    }
    if ($line.IndexOf("'") -ge 0) {
        $cleaned = $script:RX_SGL_STR.Replace($cleaned, "''")
    }
    if ($cleaned.IndexOf(';') -ge 0) {
        $cleaned = $script:RX_CMT_TAIL.Replace($cleaned, '')
    }
    return $cleaned
}

function BS_CountBraces {
    param([string]$line)
    $opens = 0; $closes = 0
    foreach ($c in $line.ToCharArray()) {
        if ($c -eq '{') { $opens++ }
        elseif ($c -eq '}') { $closes++ }
    }
    return @($opens, $closes)
}

$BS_AHK_KEYWORDS = @(
    'if', 'else', 'while', 'for', 'loop', 'switch', 'case', 'catch',
    'finally', 'try', 'class', 'return', 'throw', 'static', 'global',
    'local', 'until', 'not', 'and', 'or', 'is', 'in', 'contains',
    'new', 'super', 'this', 'true', 'false', 'unset', 'isset'
)

# === Pre-compute cleaned lines and brace counts (reused by multiple sub-checks) ===
$sharedPassSw = [System.Diagnostics.Stopwatch]::StartNew()
$processedCache = @{}
foreach ($f in $allFiles) {
    $lines = $fileCache[$f.FullName]
    $processed = [object[]]::new($lines.Count)
    for ($li = 0; $li -lt $lines.Count; $li++) {
        $cleaned = BS_CleanLine $lines[$li]
        # Inline brace counting (eliminates ~25K function call overhead)
        if ($cleaned -ne '') {
            $o = 0; $c = 0
            foreach ($ch in $cleaned.ToCharArray()) {
                if ($ch -eq '{') { $o++ } elseif ($ch -eq '}') { $c++ }
            }
            $braces = @($o, $c)
        } else {
            $braces = @(0, 0)
        }
        $processed[$li] = @{ Raw = $lines[$li]; Cleaned = $cleaned; Braces = $braces }
    }
    $processedCache[$f.FullName] = $processed
}
$sharedPassSw.Stop()
[void]$subTimings.Add(@{ Name = "shared_pass"; DurationMs = [math]::Round($sharedPassSw.Elapsed.TotalMilliseconds, 1) })

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

    $processed = $processedCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    for ($i = 0; $i -lt $processed.Count; $i++) {
        $cleaned = $processed[$i].Cleaned
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
    # Pre-filter: skip files without any timer callback function name
    if ($timerCallbacks.Count -gt 0) {
        $joined = $fileCacheText[$file.FullName]
        $hasCallback = $false
        foreach ($cbName in $timerCallbacks.Keys) {
            if ($joined.IndexOf($cbName) -ge 0) { $hasCallback = $true; break }
        }
        if (-not $hasCallback) { continue }
    }

    $processed = $processedCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $depth = 0
    $inFunc = $false
    $funcDepth = -1
    $funcName = ""

    for ($i = 0; $i -lt $processed.Count; $i++) {
        $ld = $processed[$i]
        $cleaned = $ld.Cleaned

        if (-not $inFunc -and $cleaned -ne '' -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(') {
            $fname = $Matches[1]
            if ($fname.ToLower() -notin $BS_AHK_KEYWORDS -and $cleaned -match '\{') {
                $inFunc = $true
                $funcName = $fname
                $funcDepth = $depth
                $stFunctionsScanned++
            }
        }

        $depth += $ld.Braces[0] - $ld.Braces[1]

        if ($inFunc) {
            if ($timerCallbacks.ContainsKey($funcName) -and $cleaned -ne '') {
                if ($cleaned -match '^\s*static\s+(.+)') {
                    $staticContent = $Matches[1]
                    $rawLine = $ld.Raw

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

# Pre-compile regex patterns for timer_lifecycle (used across 3 phases on every line)
$rxTL_Direct     = [regex]::new('SetTimer\(\s*([A-Za-z_]\w+)\s*,\s*(.+?)\s*\)', 'Compiled')
$rxTL_Bind       = [regex]::new('SetTimer\(\s*([A-Za-z_]\w+)\.Bind\(.*?\)\s*,\s*(.+?)\s*\)', 'Compiled')
$rxTL_ArrowPre   = [regex]::new('SetTimer\(\s*\(', 'Compiled')
$rxTL_Arrow      = [regex]::new('SetTimer\(\s*\(.*?\)\s*=>.*?,\s*(.+?)\s*\)', 'Compiled')
$rxTL_BoundVar   = [regex]::new('(\w+)\s*:=\s*([A-Za-z_]\w+)\.Bind\(', 'Compiled')
$rxTL_Cancel     = [regex]::new('SetTimer\(\s*(\w+)\s*,\s*0\s*\)', 'Compiled')
$rxTL_NegPeriod  = [regex]::new('^-', 'Compiled')
$rxTL_PosDigits  = [regex]::new('^\d+$', 'Compiled')
$rxTL_NegDigits  = [regex]::new('^-\d+$', 'Compiled')
$rxTL_AnyReg     = [regex]::new('SetTimer\(\s*([A-Za-z_]\w+)\s*,', 'Compiled')
$rxTL_VarAssign  = [regex]::new('(\w+)\s*:=\s*([A-Za-z_]\w+)\s*$', 'Compiled')
$rxTL_FuncDef    = [regex]::new('^([A-Za-z_]\w+)\s*\(', 'Compiled')

# Phase 1: Collect all SetTimer starts and cancellations per file
$fileTimerData = @{}

foreach ($file in $allFiles) {
    # Pre-filter: skip files without SetTimer (only ~8/68 files contain SetTimer calls)
    $hasSetTimer = $fileCacheText[$file.FullName].IndexOf('SetTimer', [System.StringComparison]::Ordinal) -ge 0
    if (-not $hasSetTimer) { continue }

    $processed = $processedCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    $starts = @{}    # callbackName -> list of line numbers
    $cancels = [System.Collections.Generic.HashSet[string]]::new()
    $boundVars = @{}  # varName -> callbackBaseName

    for ($i = 0; $i -lt $processed.Count; $i++) {
        $ld = $processed[$i]
        $cleaned = $ld.Cleaned
        if ($cleaned -eq '') { continue }

        if ($ld.Raw.Contains($TL_SUPPRESSION)) { continue }

        # Pattern 1: SetTimer(FuncName, period) - direct function reference
        $m1 = $rxTL_Direct.Match($cleaned)
        if ($m1.Success) {
            $cbName = $m1.Groups[1].Value
            $periodStr = $m1.Groups[2].Value.Trim()

            if ($periodStr -eq '0') {
                [void]$cancels.Add($cbName)
                continue
            }
            if ($rxTL_NegPeriod.IsMatch($periodStr)) { continue }

            if (-not $starts.ContainsKey($cbName)) {
                $starts[$cbName] = [System.Collections.ArrayList]::new()
            }
            [void]$starts[$cbName].Add($i + 1)
        }

        # Pattern 2: SetTimer(FuncName.Bind(...), period)
        $m2 = $rxTL_Bind.Match($cleaned)
        if ($m2.Success) {
            $cbName = $m2.Groups[1].Value
            $periodStr = $m2.Groups[2].Value.Trim()

            if ($periodStr -eq '0') {
                [void]$cancels.Add($cbName)
                continue
            }
            if ($rxTL_NegPeriod.IsMatch($periodStr)) { continue }

            # Bind identity check: inline .Bind() with positive period creates
            # an uncancellable repeating timer (each .Bind() creates a new object).
            # Correct pattern: store bound ref in a variable first.
            if ($rxTL_PosDigits.IsMatch($periodStr) -and [int]$periodStr -gt 0) {
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

        # Pattern 2b: SetTimer(() => ..., period) - arrow function (uncancellable)
        # Arrow functions create a new object each call, same problem as inline .Bind().
        if ($rxTL_ArrowPre.IsMatch($cleaned) -and $cleaned.Contains('=>')) {
            $mArr = $rxTL_Arrow.Match($cleaned)
            if ($mArr.Success) {
                $periodStr = $mArr.Groups[1].Value.Trim()
                if ($periodStr -ne '0' -and -not $rxTL_NegPeriod.IsMatch($periodStr) -and $rxTL_PosDigits.IsMatch($periodStr) -and [int]$periodStr -gt 0) {
                    [void]$bindIdentityIssues.Add([PSCustomObject]@{
                        File     = $relPath
                        Line     = ($i + 1)
                        Callback = '() =>'
                        Period   = $periodStr
                    })
                }
            }
        }

        # Pattern 3: varName := FuncName.Bind(...) - track bound variable
        $m3 = $rxTL_BoundVar.Match($cleaned)
        if ($m3.Success) {
            $varName = $m3.Groups[1].Value
            $baseName = $m3.Groups[2].Value
            $boundVars[$varName] = $baseName
        }

        # Pattern 4: SetTimer(varName, period) - variable holding a bound ref
        $m4 = $rxTL_Direct.Match($cleaned)
        if ($m4.Success) {
            $varName = $m4.Groups[1].Value
            $periodStr = $m4.Groups[2].Value.Trim()

            if ($boundVars.ContainsKey($varName)) {
                $baseName = $boundVars[$varName]
                if ($periodStr -eq '0') {
                    [void]$cancels.Add($baseName)
                    [void]$cancels.Add($varName)
                } elseif (-not $rxTL_NegDigits.IsMatch($periodStr)) {
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
        $m5 = $rxTL_Cancel.Match($cleaned)
        if ($m5.Success) {
            $varName = $m5.Groups[1].Value
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

# Phase 3: Cross-file dead cancel detection
# Find SetTimer(fn, 0) where fn is never registered (SetTimer(fn, ...)) in ANY file
# AND fn is not a known function definition or bound variable.
# This catches renamed/removed timer callbacks whose cancellation is now a no-op.
$allRegistered = [System.Collections.Generic.HashSet[string]]::new()
$allBoundVars = [System.Collections.Generic.HashSet[string]]::new()
$allFuncDefs = [System.Collections.Generic.HashSet[string]]::new()
$allCancels = [System.Collections.ArrayList]::new()

# Collect all registrations (positive AND negative periods) across all files
foreach ($relPath in $fileTimerData.Keys) {
    $data = $fileTimerData[$relPath]
    foreach ($cbName in $data.Starts.Keys) {
        [void]$allRegistered.Add($cbName)
    }
}

foreach ($file in $allFiles) {
    $processed = $processedCache[$file.FullName]
    for ($i = 0; $i -lt $processed.Count; $i++) {
        $cleaned = $processed[$i].Cleaned
        if ($cleaned -eq '') { continue }
        # Any SetTimer registration (positive or negative period) -- ignore lint-ignore
        # because Phase 3 checks existence, not same-file balance
        $mReg = $rxTL_AnyReg.Match($cleaned)
        if ($mReg.Success) {
            $regName = $mReg.Groups[1].Value
            if (-not $rxTL_Cancel.IsMatch($cleaned)) {
                [void]$allRegistered.Add($regName)
            }
        }
        # Bound variable assignments: varName := FuncName.Bind(...)
        $mBV = $rxTL_BoundVar.Match($cleaned)
        if ($mBV.Success) {
            [void]$allBoundVars.Add($mBV.Groups[1].Value)
        }
        # Direct function ref stored in variable: varName := FuncName (no parens)
        $mVA = $rxTL_VarAssign.Match($cleaned)
        if ($mVA.Success) {
            [void]$allBoundVars.Add($mVA.Groups[1].Value)
        }
        # Function definitions: FuncName(params) {
        $mFD = $rxTL_FuncDef.Match($cleaned)
        if ($mFD.Success) {
            [void]$allFuncDefs.Add($mFD.Groups[1].Value)
        }
    }
}

# Collect all cancellations across all files
foreach ($file in $allFiles) {
    $processed = $processedCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    for ($i = 0; $i -lt $processed.Count; $i++) {
        $cleaned = $processed[$i].Cleaned
        if ($cleaned -eq '') { continue }
        if ($processed[$i].Raw.Contains($TL_SUPPRESSION)) { continue }
        $mCancel = $rxTL_Cancel.Match($cleaned)
        if ($mCancel.Success) {
            $cbName = $mCancel.Groups[1].Value
            [void]$allCancels.Add([PSCustomObject]@{
                File = $relPath; Line = ($i + 1); Callback = $cbName
            })
        }
    }
}

$deadCancelIssues = [System.Collections.ArrayList]::new()
foreach ($cancel in $allCancels) {
    $cb = $cancel.Callback
    # Known via any registration (positive or one-shot)
    if ($allRegistered.Contains($cb)) { continue }
    # Known bound variable (stores a .Bind() ref)
    if ($allBoundVars.Contains($cb)) { continue }
    # Known function definition (may be registered dynamically)
    if ($allFuncDefs.Contains($cb)) { continue }
    [void]$deadCancelIssues.Add($cancel)
}

if ($deadCancelIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($deadCancelIssues.Count) dead timer cancellation(s) found.")
    [void]$failOutput.AppendLine("  SetTimer(fn, 0) where fn is not a known function, bound variable, or registered timer.")
    [void]$failOutput.AppendLine("  This means the callback was renamed or removed but the cancel is now a no-op.")
    [void]$failOutput.AppendLine("  Fix: remove the dead SetTimer(fn, 0) or fix the callback name.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: timer-lifecycle' on the SetTimer line.")
    $grouped = $deadCancelIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): SetTimer($($issue.Callback), 0) - callback never registered")
        }
    }
}

if ($bindIdentityIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($bindIdentityIssues.Count) repeating timer(s) with inline .Bind() or arrow function found.")
    [void]$failOutput.AppendLine("  Each .Bind()/arrow creates a new object, so SetTimer(fn.Bind(x), 0) won't cancel")
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
            if ($issue.Callback -eq '() =>') {
                [void]$failOutput.AppendLine("      Line $($issue.Line): SetTimer(() => ..., $($issue.Period)) - arrow function creates uncancellable timer")
            } else {
                [void]$failOutput.AppendLine("      Line $($issue.Line): SetTimer($($issue.Callback).Bind(...), $($issue.Period)) - inline .Bind() creates uncancellable timer")
            }
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_timer_lifecycle"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 3: dead_globals
# Detects file-scope global declarations that are never referenced
# outside their declaring file. These are dead globals that can
# be removed.
# Suppress: ; lint-ignore: dead-global
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$dgIssues = [System.Collections.ArrayList]::new()

# Phase 1: Collect ALL file-scope global declarations from src/ files
$dgAllGlobals = [System.Collections.ArrayList]::new()

# Exempt API-surface / constant-definition library files from dead-global check.
# These files declare D2D/DXGI/GDI+ enums and constants for completeness — not all
# are consumed yet, but removing them means re-declaring when next needed.
$dgExemptFiles = @('d2d_types.ahk', 'gui_constants.ahk')

foreach ($file in $allFiles) {
    if ($file.Name -in $dgExemptFiles) { continue }
    $processed = $processedCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $depth = 0

    for ($i = 0; $i -lt $processed.Count; $i++) {
        $ld = $processed[$i]
        $cleaned = $ld.Cleaned
        if ($cleaned -eq '') { continue }

        # Only look at file-scope (depth == 0) global declarations
        if ($depth -eq 0 -and $cleaned -match '^\s*global\s+(.+)') {
            # Check for lint-ignore suppression
            if ($ld.Raw -match 'lint-ignore:\s*dead-global') {
                $depth += $ld.Braces[0] - $ld.Braces[1]
                if ($depth -lt 0) { $depth = 0 }
                continue
            }

            $declContent = $Matches[1]

            # Split on commas, respecting nested parens/brackets
            $dgParenDepth = 0
            $dgParts = [System.Collections.ArrayList]::new()
            $dgCurrent = [System.Text.StringBuilder]::new()
            foreach ($ch in $declContent.ToCharArray()) {
                if ($ch -eq '(' -or $ch -eq '[') { $dgParenDepth++ }
                elseif ($ch -eq ')' -or $ch -eq ']') { if ($dgParenDepth -gt 0) { $dgParenDepth-- } }
                if ($ch -eq ',' -and $dgParenDepth -eq 0) {
                    [void]$dgParts.Add($dgCurrent.ToString())
                    [void]$dgCurrent.Clear()
                } else {
                    [void]$dgCurrent.Append($ch)
                }
            }
            [void]$dgParts.Add($dgCurrent.ToString())

            foreach ($part in $dgParts) {
                $trimmed = $part.Trim()
                if ($trimmed -match '^(\w+)') {
                    $varName = $Matches[1]
                    [void]$dgAllGlobals.Add(@{
                        Name = $varName
                        File = $relPath
                        Line = ($i + 1)
                        FullPath = $file.FullName
                    })
                }
            }
        }

        $depth += $ld.Braces[0] - $ld.Braces[1]
        if ($depth -lt 0) { $depth = 0 }
    }
}

# Phase 2: Build text cache for test files (src/ already in $fileCacheText)
$dgTestTexts = @{}
$dgTestsDir = Join-Path $projectRoot "tests"
if (Test-Path $dgTestsDir) {
    foreach ($file in @(Get-ChildItem -Path $dgTestsDir -Filter "*.ahk" -Recurse)) {
        if (-not $fileCacheText.ContainsKey($file.FullName)) {
            $dgTestTexts[$file.FullName] = [System.IO.File]::ReadAllText($file.FullName)
        }
    }
}

# Phase 3: For each global, check if it appears in any file OTHER than its declaring file.
# For globals only in their declaring file, check if they have any reads (not just writes).
# A global is "dead" if it has no external references AND no reads within its declaring file
# (only declarations, global access statements, and pure assignments like VarName := expr).
foreach ($g in $dgAllGlobals) {
    $varName = $g.Name
    $declFullPath = $g.FullPath
    $foundElsewhere = $false

    # Check all src/ files (excluding declaring file)
    foreach ($f in $allFiles) {
        if ($f.FullName -eq $declFullPath) { continue }
        if ($fileCacheText[$f.FullName].IndexOf($varName, [System.StringComparison]::Ordinal) -ge 0) {
            $foundElsewhere = $true
            break
        }
    }

    # Check test files if not found in src/
    if (-not $foundElsewhere) {
        foreach ($kv in $dgTestTexts.GetEnumerator()) {
            if ($kv.Value.IndexOf($varName, [System.StringComparison]::Ordinal) -ge 0) {
                $foundElsewhere = $true
                break
            }
        }
    }

    if ($foundElsewhere) { continue }

    # Global only in declaring file -- check if it has any reads (not just writes).
    # A line is a "read" if VarName appears on a non-global, non-assignment line.
    # This catches write-only globals (declared + assigned but never consumed).
    $hasRead = $false
    $dgLines = $fileCache[$declFullPath]
    $escapedName = [regex]::Escape($varName)

    for ($li = 0; $li -lt $dgLines.Count; $li++) {
        $dgRaw = $dgLines[$li]
        if ($dgRaw.IndexOf($varName, [System.StringComparison]::Ordinal) -lt 0) { continue }

        $dgCleaned = BS_CleanLine $dgRaw
        if ($dgCleaned -eq '') { continue }

        # Skip global declaration/access lines (global VarName ... at any depth)
        if ($dgCleaned -match '^\s*global\b') { continue }

        # Skip pure assignment lines: VarName := expr (VarName is the LHS target)
        if ($dgCleaned -match "^\s*$escapedName\s*:=") { continue }

        # Any other occurrence means VarName is being read (used as value, passed to
        # function, indexed, iterated, compared, etc.)
        $hasRead = $true
        break
    }

    if (-not $hasRead) {
        [void]$dgIssues.Add([PSCustomObject]@{
            Name = $varName
            File = $g.File
            Line = $g.Line
        })
    }
}

if ($dgIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($dgIssues.Count) dead global(s) found.")
    [void]$failOutput.AppendLine("  Global declared at file scope but never referenced outside its file, and write-only within it.")
    [void]$failOutput.AppendLine("  Fix: remove the global declaration if unused, or move it to local scope.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: dead-global' on the declaration line.")
    $grouped = $dgIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): $($issue.Name)")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_dead_globals"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# === Shared: Extract function definitions for sub-checks 4-5 ===
# Parses file-scope function defs: name, param string, body range.
$bsFuncDefs = [System.Collections.ArrayList]::new()

foreach ($file in $allFiles) {
    $bfProc = $processedCache[$file.FullName]
    $bfRel = $file.FullName.Replace("$projectRoot\", '')
    $bfDepth = 0
    $bfInFunc = $false
    $bfPending = $false
    $bfName = ''; $bfParams = ''; $bfDefIdx = 0; $bfStartLine = 0

    for ($bfi = 0; $bfi -lt $bfProc.Count; $bfi++) {
        $bfLd = $bfProc[$bfi]
        $bfCl = $bfLd.Cleaned
        if ($bfCl -eq '') { continue }
        $bfO = $bfLd.Braces[0]; $bfC = $bfLd.Braces[1]

        if (-not $bfInFunc -and -not $bfPending -and $bfDepth -eq 0) {
            if ($bfCl -match '^\s*(\w+)\s*\(') {
                $bfCandName = $Matches[1]
                if ($bfCandName -notin $BS_AHK_KEYWORDS) {
                    # Extract param string with paren matching
                    $bfPS = $bfCl.IndexOf('(')
                    $bfPD = 0; $bfPE = -1
                    for ($bfci = $bfPS; $bfci -lt $bfCl.Length; $bfci++) {
                        if ($bfCl[$bfci] -eq '(') { $bfPD++ }
                        elseif ($bfCl[$bfci] -eq ')') { $bfPD--; if ($bfPD -eq 0) { $bfPE = $bfci; break } }
                    }
                    if ($bfPE -gt $bfPS) {
                        $bfName = $bfCandName
                        $bfParams = $bfCl.Substring($bfPS + 1, $bfPE - $bfPS - 1)
                        $bfStartLine = $bfi + 1
                        $bfDefIdx = $bfi
                        if ($bfO -gt 0) {
                            $bfInFunc = $true
                            $bfDepth += $bfO - $bfC
                            if ($bfDepth -le 0) {
                                [void]$bsFuncDefs.Add(@{
                                    Name = $bfName; Params = $bfParams; DefIdx = $bfDefIdx
                                    EndIdx = $bfi; File = $bfRel; FullPath = $file.FullName
                                    StartLine = $bfStartLine
                                })
                                $bfInFunc = $false; $bfDepth = 0
                            }
                        } else {
                            $bfPending = $true
                        }
                        continue
                    }
                }
            }
        }

        if ($bfPending) {
            if ($bfO -gt 0) {
                $bfInFunc = $true
                $bfPending = $false
                $bfDepth += $bfO - $bfC
                if ($bfDepth -le 0) {
                    [void]$bsFuncDefs.Add(@{
                        Name = $bfName; Params = $bfParams; DefIdx = $bfDefIdx
                        EndIdx = $bfi; File = $bfRel; FullPath = $file.FullName
                        StartLine = $bfStartLine
                    })
                    $bfInFunc = $false; $bfDepth = 0
                }
            } else {
                $bfPending = $false
                $bfDepth += $bfO - $bfC
                if ($bfDepth -lt 0) { $bfDepth = 0 }
            }
            continue
        }

        if ($bfInFunc) {
            $bfDepth += $bfO - $bfC
            if ($bfDepth -le 0) {
                [void]$bsFuncDefs.Add(@{
                    Name = $bfName; Params = $bfParams; DefIdx = $bfDefIdx
                    EndIdx = $bfi; File = $bfRel; FullPath = $file.FullName
                    StartLine = $bfStartLine
                })
                $bfInFunc = $false; $bfDepth = 0
            }
        } else {
            $bfDepth += $bfO - $bfC
            if ($bfDepth -lt 0) { $bfDepth = 0 }
        }
    }
}

# Shared helper: parse param names from a param string
function BS_ParseParamNames {
    param([string]$paramStr)
    $result = @{}
    $ps = $paramStr.Trim()
    if ($ps -eq '' -or $ps -eq '*') { return $result }
    $ppd = 0
    $parts = [System.Collections.ArrayList]::new()
    $buf = [System.Text.StringBuilder]::new()
    foreach ($ch in $ps.ToCharArray()) {
        if ($ch -eq '(' -or $ch -eq '[') { $ppd++ }
        elseif ($ch -eq ')' -or $ch -eq ']') { if ($ppd -gt 0) { $ppd-- } }
        if ($ch -eq ',' -and $ppd -eq 0) {
            [void]$parts.Add($buf.ToString()); [void]$buf.Clear()
        } else { [void]$buf.Append($ch) }
    }
    [void]$parts.Add($buf.ToString())
    foreach ($pp in $parts) {
        $ppt = $pp.Trim()
        if ($ppt -eq '*' -or $ppt.EndsWith('*')) { continue }
        $ppt = $ppt -replace '^(?:ByRef\s+|&)', ''
        if ($ppt -match '^(\w+)') { $result[$Matches[1]] = $true }
    }
    return $result
}

# ============================================================
# Sub-check 4: dead_locals
# Detects local variables inside functions that are assigned but
# never read. Write-only locals are dead code.
# Suppress: ; lint-ignore: dead-local (on assignment or function def line)
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$dlIssues = [System.Collections.ArrayList]::new()

foreach ($fd in $bsFuncDefs) {
    $dlProc = $processedCache[$fd.FullPath]
    $dlDefIdx = $fd.DefIdx
    $dlEndIdx = $fd.EndIdx

    # Function-level suppression
    if ($dlProc[$dlDefIdx].Raw -match 'lint-ignore:\s*dead-local') { continue }

    $dlParamNames = BS_ParseParamNames $fd.Params

    # Collect globals, statics, and local assignments within function body
    $dlGlobals = @{}
    $dlStatics = @{}
    $dlLocals = @{}  # varName -> @{ Line = int; Idx = int }

    for ($dli = $dlDefIdx + 1; $dli -lt $dlEndIdx; $dli++) {
        $dlCl = $dlProc[$dli].Cleaned
        if ($dlCl -eq '') { continue }

        # Collect global declarations
        if ($dlCl -match '^\s*global\b\s+(.*)') {
            foreach ($gp in $Matches[1].Split(',')) {
                if ($gp.Trim() -match '^(\w+)') { $dlGlobals[$Matches[1]] = $true }
            }
            continue
        }

        # Collect static declarations
        if ($dlCl -match '^\s*static\b\s+(.*)') {
            foreach ($sp in $Matches[1].Split(',')) {
                if ($sp.Trim() -match '^(\w+)') { $dlStatics[$Matches[1]] = $true }
            }
            continue
        }

        # Collect for-loop variables (two-var form)
        if ($dlCl -match '^\s*for\s+(\w+)\s*,\s*(\w+)\s+in\b') {
            foreach ($fv in @($Matches[1], $Matches[2])) {
                if ($fv -ne '_' -and -not $dlGlobals.ContainsKey($fv) -and
                    -not $dlStatics.ContainsKey($fv) -and -not $dlParamNames.ContainsKey($fv) -and
                    -not $dlLocals.ContainsKey($fv)) {
                    $dlLocals[$fv] = @{ Line = $dli + 1; Idx = $dli }
                }
            }
            continue
        }
        # Collect for-loop variables (single-var form)
        if ($dlCl -match '^\s*for\s+(\w+)\s+in\b') {
            $fv = $Matches[1]
            if ($fv -ne '_' -and -not $dlGlobals.ContainsKey($fv) -and
                -not $dlStatics.ContainsKey($fv) -and -not $dlParamNames.ContainsKey($fv) -and
                -not $dlLocals.ContainsKey($fv)) {
                $dlLocals[$fv] = @{ Line = $dli + 1; Idx = $dli }
            }
            continue
        }

        # Collect catch-as variables
        if ($dlCl -match '^\s*catch\b.*\bas\s+(\w+)') {
            $cv = $Matches[1]
            if ($cv -ne '_' -and -not $dlGlobals.ContainsKey($cv) -and
                -not $dlStatics.ContainsKey($cv) -and -not $dlParamNames.ContainsKey($cv) -and
                -not $dlLocals.ContainsKey($cv)) {
                $dlLocals[$cv] = @{ Line = $dli + 1; Idx = $dli }
            }
        }

        # Collect explicit local declarations: local varName :=
        if ($dlCl -match '^\s*local\s+(\w+)\s*:=') {
            $lv = $Matches[1]
            if ($lv -ne '_' -and -not $dlLocals.ContainsKey($lv)) {
                $dlLocals[$lv] = @{ Line = $dli + 1; Idx = $dli }
            }
            continue
        }

        # Collect implicit local assignments: varName :=
        if ($dlCl -match '^\s*(\w+)\s*:=') {
            $av = $Matches[1]
            if ($null -ne $av -and $av -ne '_' -and $av -notin $BS_AHK_KEYWORDS -and
                -not $av.StartsWith('A_') -and -not $dlLocals.ContainsKey($av)) {
                if (-not $dlGlobals.ContainsKey($av) -and -not $dlStatics.ContainsKey($av) -and
                    -not $dlParamNames.ContainsKey($av)) {
                    $dlLocals[$av] = @{ Line = $dli + 1; Idx = $dli }
                }
            }
        }
    }

    # Check each local for reads in the function body
    foreach ($dlVar in @($dlLocals.Keys)) {
        $dlHasRead = $false
        $dlEsc = [regex]::Escape($dlVar)

        for ($dli = $dlDefIdx + 1; $dli -lt $dlEndIdx; $dli++) {
            $dlCl = $dlProc[$dli].Cleaned
            if ($dlCl -eq '') { continue }
            if ($dlCl.IndexOf($dlVar, [System.StringComparison]::Ordinal) -lt 0) { continue }

            # Skip global/static/local declaration lines
            if ($dlCl -match '^\s*(global|static|local)\b') { continue }

            # Skip pure assignment lines: VarName :=
            if ($dlCl -match "^\s*$dlEsc\s*:=") { continue }

            # Skip for-loop header lines where this var is being defined
            if ($dlCl -match '^\s*for\b') {
                if ($dlCl -match "^\s*for\s+(?:(\w+)\s*,\s*)?(\w+)\s+in\b") {
                    if ($dlVar -eq $Matches[1] -or $dlVar -eq $Matches[2]) { continue }
                }
            }

            # Skip catch-as definition lines for this variable
            if ($dlCl -match "^\s*catch\b.*\bas\s+$dlEsc\b") { continue }

            # Word-bounded occurrence = a read
            if ($dlCl -match "(?<![.\w])$dlEsc(?!\w)") {
                $dlHasRead = $true
                break
            }
        }

        if (-not $dlHasRead) {
            $dlInfo = $dlLocals[$dlVar]
            if ($null -eq $dlInfo) { continue }

            # Fallback: check raw lines for mixed-quote string concatenation
            # (BS_CleanLine can eat variables between alternating quote styles)
            $dlRawHit = $false
            for ($dli = $dlDefIdx + 1; $dli -lt $dlEndIdx; $dli++) {
                if ($dli -eq $dlInfo['Idx']) { continue }  # skip definition line
                $dlRawLine = $dlProc[$dli].Raw
                if ($dlRawLine.IndexOf($dlVar, [System.StringComparison]::Ordinal) -lt 0) { continue }
                $dlRawTrimmed = $dlRawLine.TrimStart()
                if ($dlRawTrimmed.Length -gt 0 -and $dlRawTrimmed[0] -ne ';') {
                    $dlRawHit = $true; break
                }
            }
            if ($dlRawHit) { continue }

            # Check per-line lint-ignore
            $dlRaw = $dlProc[$dlInfo['Idx']].Raw
            if ($dlRaw -match 'lint-ignore:\s*dead-local') { continue }

            [void]$dlIssues.Add([PSCustomObject]@{
                Func = $fd.Name; Var = $dlVar
                File = $fd.File; Line = $dlInfo['Line']
            })
        }
    }
}

if ($dlIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($dlIssues.Count) dead local variable(s) found.")
    [void]$failOutput.AppendLine("  Local variable assigned but never read within its function.")
    [void]$failOutput.AppendLine("  Fix: remove the variable, or use '_' for intentional throwaway.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: dead-local' on assignment or function line.")
    $dlGrouped = $dlIssues | Group-Object File
    foreach ($group in $dlGrouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line) ($($issue.Func)): $($issue.Var)")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_dead_locals"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 5: dead_params
# Detects function parameters never referenced in the function
# body. Excludes variadic (*) and throwaway (_).
# Auto-exempts functions registered as callbacks (framework-mandated signatures).
# Suppress: ; lint-ignore: dead-param (on function definition line)
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$dpIssues = [System.Collections.ArrayList]::new()

# Build set of function names registered as callbacks (auto-exempt from dead-param).
# AHK v2 callback signatures are framework-mandated -- can't remove params without crash.
$dpCallbackFuncs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$dpCbPatterns = @(
    [regex]::new('(?:OnMessage|Hotkey)\s*\(\s*[^,]+,\s*(\w+)', 'Compiled'),
    [regex]::new('(?:OnExit|OnError)\s*\(\s*(\w+)', 'Compiled'),
    [regex]::new('CallbackCreate\s*\(\s*(\w+)', 'Compiled'),
    [regex]::new('\.OnEvent\s*\(\s*"[^"]*"\s*,\s*(\w+)', 'Compiled'),
    [regex]::new('IPC_Pipe\w+_(?:Connect|Start)\s*\(\s*[^,]+,\s*(\w+)', 'Compiled'),
    [regex]::new('OVERLAPPED\s*\(\s*(\w+)', 'Compiled')
)
foreach ($f in $allFiles) {
    $dpText = $fileCacheText[$f.FullName]
    foreach ($rx in $dpCbPatterns) {
        foreach ($m in $rx.Matches($dpText)) {
            $cbName = $m.Groups[1].Value
            if ($cbName -and $cbName -notin $BS_AHK_KEYWORDS) {
                [void]$dpCallbackFuncs.Add($cbName)
            }
        }
    }
}

foreach ($fd in $bsFuncDefs) {
    $dpProc = $processedCache[$fd.FullPath]
    $dpDefIdx = $fd.DefIdx
    $dpEndIdx = $fd.EndIdx

    # Function-level suppression
    if ($dpProc[$dpDefIdx].Raw -match 'lint-ignore:\s*dead-param') { continue }

    # Auto-exempt functions registered as callbacks (framework-mandated signatures)
    if ($dpCallbackFuncs.Contains($fd.Name)) { continue }

    $dpParamStr = $fd.Params.Trim()
    if ($dpParamStr -eq '' -or $dpParamStr -eq '*') { continue }

    $dpNames = BS_ParseParamNames $dpParamStr

    foreach ($dpName in @($dpNames.Keys)) {
        if ($dpName -eq '_') { continue }

        $dpFound = $false
        $dpEsc = [regex]::Escape($dpName)

        for ($dpi = $dpDefIdx + 1; $dpi -lt $dpEndIdx; $dpi++) {
            $dpCl = $dpProc[$dpi].Cleaned
            if ($dpCl -eq '') { continue }
            if ($dpCl.IndexOf($dpName, [System.StringComparison]::Ordinal) -lt 0) { continue }
            if ($dpCl -match "(?<![.\w])$dpEsc(?!\w)") {
                $dpFound = $true
                break
            }
        }

        if (-not $dpFound) {
            [void]$dpIssues.Add([PSCustomObject]@{
                Func = $fd.Name; Param = $dpName
                File = $fd.File; Line = $fd.StartLine
            })
        }
    }
}

if ($dpIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($dpIssues.Count) dead parameter(s) found.")
    [void]$failOutput.AppendLine("  Function parameter never referenced in function body.")
    [void]$failOutput.AppendLine("  Fix: remove param, rename to '_', or use it. For callbacks with fixed")
    [void]$failOutput.AppendLine("  signatures, add '; lint-ignore: dead-param' on the function definition line.")
    $dpGrouped = $dpIssues | Group-Object File
    foreach ($group in $dpGrouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line) ($($issue.Func)): $($issue.Param)")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_dead_params"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Report
# ============================================================
$totalSw.Stop()

if ($anyFailed) {
    Write-Host $failOutput.ToString().TrimEnd()
} else {
    Write-Host "  PASS: All simple checks A passed (static_in_timers, timer_lifecycle, dead_globals, dead_locals, dead_params)" -ForegroundColor Green
}

Write-Host "  Timing: shared=$($sharedPassSw.ElapsedMilliseconds)ms total=$($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan

# Write sub-timing for nested display (consumed by static_analysis.ps1)
$subTimings | ConvertTo-Json -Compress | Set-Content "$env:TEMP\sa_batch_simple_timing.json" -Encoding UTF8

if ($anyFailed) { exit 1 }
exit 0
