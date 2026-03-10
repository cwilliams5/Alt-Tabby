# check_batch_guards.ps1 - Batched guard/enforcement checks (batch A)
# Checks that require shared preprocessing data ($sharedFuncDefs, $sharedLineData, $sharedSetCallbacksDefs).
# Sub-checks: guard_try_finally, critical_leaks, critical_sections, callback_signatures, producer_error_boundary, callback_invocation_arity, paint_resize_ordering
# Shared file cache: all src/ files (excluding lib/) read once.
#
# Usage: powershell -File tests\check_batch_guards.ps1 [-SourceDir "path\to\src"]
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
    $fileCache[$f.FullName] = $text.Split([string[]]@("`r`n", "`n"), [StringSplitOptions]::None)
}

# === Sub-check tracking ===
$subTimings = [System.Collections.ArrayList]::new()
$anyFailed = $false
$failOutput = [System.Text.StringBuilder]::new()

# === Pre-compiled regex patterns (hot-path, called 30K+ times) ===
$script:RX_DBL_STR   = [regex]::new('"[^"]*"', 'Compiled')
$script:RX_SGL_STR   = [regex]::new("'[^']*'", 'Compiled')
$script:RX_CMT_TAIL  = [regex]::new('\s;.*$', 'Compiled')
$script:RX_CRIT_ON_STR   = [regex]::new('(?i)^\s*Critical[\s(]+["\x27]?On["\x27]?\s*\)?', 'Compiled')
$script:RX_CRIT_ON_TRUE  = [regex]::new('(?i)^\s*Critical[\s(]+true\s*\)?', 'Compiled')
$script:RX_CRIT_ON_NUM   = [regex]::new('(?i)^\s*Critical[\s(]+(\d+)\s*\)?', 'Compiled')
$script:RX_CRIT_BARE     = [regex]::new('(?i)^\s*Critical\s*$', 'Compiled')
$script:RX_CRIT_OFF_STR  = [regex]::new('(?i)^\s*Critical[\s(]+["\x27]?Off["\x27]?\s*\)?', 'Compiled')
$script:RX_CRIT_OFF_FALSE= [regex]::new('(?i)^\s*Critical[\s(]+false\s*\)?', 'Compiled')
$script:RX_CRIT_OFF_ZERO = [regex]::new('(?i)^\s*Critical[\s(]+0\s*\)?', 'Compiled')

# guard_try_finally patterns
$script:RX_GUARD_SET_TRUE  = [regex]::new('^\s*(\w+)\s*:=\s*(?:true|1)\s*$', 'Compiled, IgnoreCase')
$script:RX_GUARD_SET_FALSE = [regex]::new('^\s*(\w+)\s*:=\s*(?:false|0)\s*$', 'Compiled, IgnoreCase')
$script:RX_TRY_OPEN        = [regex]::new('(?i)^\s*try\s*\{', 'Compiled')
$script:RX_FINALLY_OPEN    = [regex]::new('(?i)}\s*finally\s*\{', 'Compiled')

# Pre-compute set of files containing "Critical" (reused across sub-checks)
$criticalFiles = [System.Collections.Generic.HashSet[string]]::new()
foreach ($f in $allFiles) {
    if ($fileCacheText[$f.FullName].IndexOf('Critical') -ge 0) {
        [void]$criticalFiles.Add($f.FullName)
    }
}

# === Critical section helpers (used by shared pass, critical_leaks, critical_sections sub-checks) ===

function BC_CleanLine {
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

function BC_StripComments {
    param([string]$line)
    if ($line.Length -eq 0) { return '' }
    $trimmed = $line.TrimStart()
    if ($trimmed.Length -eq 0) { return '' }
    if ($trimmed[0] -eq ';') { return '' }
    if ($line.IndexOf(';') -ge 0) {
        return $script:RX_CMT_TAIL.Replace($line, '')
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
    if ($script:RX_CRIT_ON_STR.IsMatch($trimmed)) { return $true }
    if ($script:RX_CRIT_ON_TRUE.IsMatch($trimmed)) { return $true }
    $m = $script:RX_CRIT_ON_NUM.Match($trimmed)
    if ($m.Success) {
        $val = [int]$m.Groups[1].Value
        if ($val -gt 0) { return $true }
        return $false
    }
    if ($script:RX_CRIT_BARE.IsMatch($trimmed)) { return $true }
    return $false
}

function BC_TestCriticalOff {
    param([string]$line)
    $trimmed = $line.Trim()
    if ($script:RX_CRIT_OFF_STR.IsMatch($trimmed)) { return $true }
    if ($script:RX_CRIT_OFF_FALSE.IsMatch($trimmed)) { return $true }
    if ($script:RX_CRIT_OFF_ZERO.IsMatch($trimmed)) { return $true }
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

# === Shared pre-processing pass ===
# Builds function definition index and processed line data ONCE,
# reused by callback_signatures, producer_error_boundary, callback_invocation_arity, critical_leaks.
# This eliminates 3 redundant full-file scans (~1.0s savings).
$sharedPassSw = [System.Diagnostics.Stopwatch]::StartNew()

$sharedFuncDefs = @{}           # funcName -> @{ File, DefLine, FileName, Lines, Raw, ParamStr, RequiredCount, HasVariadic, TotalParams }
$sharedSetCallbacksDefs = @{}   # funcName -> @{ ParamNames, GlobalMap } (only *_SetCallbacks)
$sharedLineData = @{}           # file.FullName -> ArrayList of @{ Raw, Cleaned, Stripped, Braces } (critical files only)

foreach ($file in $allFiles) {
    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $isCritical = $criticalFiles.Contains($file.FullName)

    # For critical files, pre-process all lines (reused by critical_leaks)
    if ($isCritical) {
        $lineData = [System.Collections.ArrayList]::new($lines.Count)
        for ($li = 0; $li -lt $lines.Count; $li++) {
            $rawLine = $lines[$li]
            $cleaned = BC_CleanLine $rawLine
            $stripped = if ($cleaned -ne '') { BC_StripComments $rawLine } else { '' }
            $braces = if ($cleaned -ne '') { BC_CountBraces $cleaned } else { @(0, 0) }
            [void]$lineData.Add(@{ Raw = $rawLine; Cleaned = $cleaned; Stripped = $stripped; Braces = $braces })
        }
        $sharedLineData[$file.FullName] = $lineData
    }

    # Build function definition index with brace-depth tracking
    $depth = 0
    $inFunc = $false
    $funcDepth = -1
    $scName = ""
    $scParams = @()

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        if ($raw -match '^\s*;') { continue }

        # Use pre-processed cleaned line if available, otherwise compute
        if ($isCritical) {
            $cleaned = $lineData[$i].Cleaned
        } else {
            $cleaned = BC_CleanLine $raw
        }
        if ($cleaned -eq '') { continue }

        # Detect function definitions (not inside another function)
        if (-not $inFunc -and $cleaned -match '^\s*(?:static\s+)?([A-Za-z_]\w*)\s*\(([^)]*)\)\s*\{?') {
            $funcName = $Matches[1]
            $paramStr = $Matches[2].Trim()
            if (-not $BC_keywordSet.Contains($funcName)) {
                # Parse parameter counts (for callback_signatures)
                $hasVariadic = $paramStr -match '\*'
                $requiredCount = 0
                if ($paramStr -ne '' -and -not $hasVariadic) {
                    foreach ($param in $paramStr -split ',') {
                        $p = $param.Trim()
                        if ($p -eq '') { continue }
                        if ($p -match ':=|=') { continue }
                        $requiredCount++
                    }
                }

                if (-not $sharedFuncDefs.ContainsKey($funcName)) {
                    $sharedFuncDefs[$funcName] = @{
                        File          = $relPath
                        DefLine       = $i
                        FileName      = $file.Name
                        Lines         = $lines
                        Raw           = $raw
                        ParamStr      = $paramStr
                        RequiredCount = $requiredCount
                        HasVariadic   = $hasVariadic
                        TotalParams   = if ($paramStr -eq '') { 0 } else { ($paramStr -split ',').Count }
                    }
                }

                # Track *_SetCallbacks functions (for callback_invocation_arity)
                if ($funcName -match '_SetCallbacks$') {
                    $scParams = @()
                    if ($paramStr -ne '') {
                        foreach ($p in $paramStr -split ',') {
                            $trimP = $p.Trim() -replace '\s*:=.*$', ''
                            $trimP = $trimP -replace '^\s*&?\s*', ''
                            if ($trimP -ne '') { $scParams += $trimP }
                        }
                    }
                }

                if ($cleaned -match '\{') {
                    $inFunc = $true
                    $funcDepth = $depth
                    # Register SetCallbacks definition
                    if ($funcName -match '_SetCallbacks$') {
                        $scName = $funcName
                        $sharedSetCallbacksDefs[$scName] = @{
                            ParamNames = $scParams
                            GlobalMap = @{}
                        }
                    }
                }
            }
        }

        # Brace tracking
        if ($isCritical) {
            $braces = $lineData[$i].Braces
        } else {
            $braces = BC_CountBraces $cleaned
        }
        $depth += $braces[0] - $braces[1]

        # Inside a SetCallbacks function: track callback global assignments
        if ($inFunc -and $scName -ne '' -and $sharedSetCallbacksDefs.ContainsKey($scName)) {
            if ($cleaned -match '^\s*(g\w+_On\w+)\s*:=\s*(\w+)\s*$') {
                $globalName = $Matches[1]
                $assignedParam = $Matches[2]
                $sharedSetCallbacksDefs[$scName].GlobalMap[$assignedParam] = $globalName
            }
        }

        if ($inFunc -and $depth -le $funcDepth) {
            $inFunc = $false
            $funcDepth = -1
            $scName = ""
        }
    }
}

$sharedPassSw.Stop()
[void]$subTimings.Add(@{ Name = "shared_pass"; DurationMs = [math]::Round($sharedPassSw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 1: callback_signatures
# Validates that SetTimer callbacks accept 0 params (or variadic)
# and OnMessage callbacks accept <=4 params (or variadic).
# In AHK v2, wrong param count = runtime crash when the callback fires.
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$CS_SUPPRESSION = 'lint-ignore: callback-signature'

# Phase 1: Use shared function definition index (built in shared pre-processing pass)
$csFuncParams = @{}  # funcName -> @{ RequiredCount; HasVariadic; TotalParams; File; Line }
foreach ($fname in $sharedFuncDefs.Keys) {
    $def = $sharedFuncDefs[$fname]
    $csFuncParams[$fname] = @{
        RequiredCount = $def.RequiredCount
        HasVariadic   = $def.HasVariadic
        TotalParams   = $def.TotalParams
        File          = $def.File
        Line          = $def.DefLine + 1
    }
}

# Phase 2: Find SetTimer and OnMessage registrations, validate signatures
$csIssues = [System.Collections.ArrayList]::new()

foreach ($file in $allFiles) {
    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        if ($raw -match '^\s*;') { continue }
        if ($raw.Contains($CS_SUPPRESSION)) { continue }

        # --- SetTimer(callbackRef, ...) ---
        if ($raw -match 'SetTimer\s*\(\s*([A-Za-z_]\w+)\s*[,)]') {
            $cbName = $Matches[1]

            # Skip deregistrations: SetTimer(ref, 0)
            if ($raw -match 'SetTimer\s*\(\s*[A-Za-z_]\w+\s*,\s*0\s*\)') { continue }

            # Skip .Bind() references (handled by binding)
            if ($raw -match "$cbName\s*\.\s*Bind\s*\(") { continue }

            # Lookup the function definition
            if ($csFuncParams.ContainsKey($cbName)) {
                $info = $csFuncParams[$cbName]
                if (-not $info.HasVariadic -and $info.RequiredCount -gt 0) {
                    [void]$csIssues.Add([PSCustomObject]@{
                        File     = $relPath
                        Line     = $i + 1
                        Kind     = 'SetTimer'
                        Callback = $cbName
                        Detail   = "SetTimer callback '$cbName' has $($info.RequiredCount) required param(s), needs 0 (defined at $($info.File):$($info.Line))"
                    })
                }
            }
        }

        # --- OnMessage(msg, callbackRef) ---
        if ($raw -match 'OnMessage\s*\(\s*[^,]+,\s*([A-Za-z_]\w+)\s*[\),]') {
            $cbName = $Matches[1]

            # Skip deregistrations (3rd arg = 0)
            if ($raw -match 'OnMessage\s*\([^,]+,\s*[A-Za-z_]\w+\s*,\s*0\s*\)') { continue }

            # Skip .Bind() references
            if ($raw -match "$cbName\s*\.\s*Bind\s*\(") { continue }

            if ($csFuncParams.ContainsKey($cbName)) {
                $info = $csFuncParams[$cbName]
                # OnMessage callbacks receive up to 4 params (wParam, lParam, msg, hwnd)
                # Having >4 required params is always wrong
                if (-not $info.HasVariadic -and $info.RequiredCount -gt 4) {
                    [void]$csIssues.Add([PSCustomObject]@{
                        File     = $relPath
                        Line     = $i + 1
                        Kind     = 'OnMessage'
                        Callback = $cbName
                        Detail   = "OnMessage callback '$cbName' has $($info.RequiredCount) required param(s), max 4 (defined at $($info.File):$($info.Line))"
                    })
                }
            }
        }
    }
}

if ($csIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($csIssues.Count) callback signature issue(s) found.")
    [void]$failOutput.AppendLine("  SetTimer callbacks must accept 0 params; OnMessage callbacks max 4.")
    [void]$failOutput.AppendLine("  Wrong param count causes runtime crash when the callback fires.")
    [void]$failOutput.AppendLine("  Fix: adjust the callback signature, or suppress with '; lint-ignore: callback-signature'.")
    $grouped = $csIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): [$($issue.Kind)] $($issue.Detail)")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_callback_signatures"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 2: critical_leaks
# Detects calls to functions containing Critical "Off" from inside
# Critical "On" sections (cross-function Critical state leak).
# Suppress: ; lint-ignore: critical-leak
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$clIssues = [System.Collections.ArrayList]::new()

# Pass 1: Identify functions that contain Critical "Off"
# Uses shared processed line data from shared pre-processing pass
$criticalOffFunctions = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
$clFuncCount = 0

foreach ($file in $allFiles) {
    if (-not $criticalFiles.Contains($file.FullName)) { continue }
    $lineData = $sharedLineData[$file.FullName]

    $depth = 0
    $inFunc = $false
    $funcDepth = -1
    $funcName = ""

    for ($i = 0; $i -lt $lineData.Count; $i++) {
        $ld = $lineData[$i]
        $cleaned = $ld.Cleaned
        if ($cleaned -eq '') {
            $depth += $ld.Braces[0] - $ld.Braces[1]
            if ($depth -lt 0) { $depth = 0 }
            continue
        }

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
# Uses shared line data (no re-cleaning, re-stripping, or re-counting braces)
if ($criticalOffFunctions.Count -gt 0) {
    # Pre-filter: build regex to skip files that don't mention any leaked function
    $escapedLeaked = @($criticalOffFunctions | ForEach-Object { [regex]::Escape($_) })
    $leakedPattern = [regex]::new('(?:' + ($escapedLeaked -join '|') + ')', 'Compiled')
    # Pre-compile hot-path regex for function call extraction (used on every line in Critical sections)
    $rxFuncCall = [regex]::new('(?<![.\w])(\w+)\s*\(', 'Compiled')

    foreach ($file in $allFiles) {
        if (-not $sharedLineData.ContainsKey($file.FullName)) { continue }
        # Skip files that don't call any leaked function
        if (-not $leakedPattern.IsMatch($fileCacheText[$file.FullName])) { continue }

        $lineData = $sharedLineData[$file.FullName]
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
                    $callMatches = $rxFuncCall.Matches($cleaned)
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
# Sub-check 3: critical_sections
# Detects throw inside Critical "On" sections.
# return and continue are exempt: AHK v2 auto-releases Critical on
# function return, and continue stays within the enclosing loop.
# throw cannot be suppressed -- exception propagation can leave
# Critical active in a catch handler.
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$csIssues = [System.Collections.ArrayList]::new()
$csFuncCount = 0

foreach ($file in $allFiles) {
    if (-not $criticalFiles.Contains($file.FullName)) { continue }

    # Reuse pre-processed line data from shared pass (avoids re-cleaning/re-counting)
    $hasLineData = $sharedLineData.ContainsKey($file.FullName)
    $lineData = if ($hasLineData) { $sharedLineData[$file.FullName] } else { $null }
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
                # return: AHK v2 auto-releases Critical on function return (safe)
                # continue: stays in enclosing loop, Critical remains active (safe)
                # throw: exception propagation can leave Critical active in catch (dangerous)
                if ($cleaned -match '(?i)^\s*throw\b') {
                    [void]$csIssues.Add([PSCustomObject]@{
                        File      = $relPath
                        Line      = $i + 1
                        Function  = $funcName
                        Statement = 'throw'
                    })
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
    [void]$failOutput.AppendLine("  throw inside Critical `"On`" is always a bug -- exception propagation")
    [void]$failOutput.AppendLine("  can leave Critical active in a catch handler.")
    [void]$failOutput.AppendLine("  Fix: add Critical `"Off`" before the throw, or restructure to avoid throwing.")
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
# Sub-check 4: producer_error_boundary
# Enforces try-catch error boundaries in producer callbacks and OnMessage handlers.
# After the store→MainProcess refactor, producer errors crash
# the entire app. This check prevents regression if boundaries
# are removed or new callbacks/handlers are added without them.
#
# Three categories:
#   A. Notification callbacks: functions wired via *_SetCallbacks()
#   B. Producer timer callbacks: functions registered via SetTimer()
#      in core/*.ahk, gui_pump.ahk, gui_main.ahk (auto-discovered)
#   C. OnMessage handlers: functions registered via OnMessage()
#      in MainProcess (gui/, core/) and Launcher (launcher/) files
#
# Suppress: ; lint-ignore: error-boundary (on function definition line)
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$EB_SUPPRESSION = 'lint-ignore: error-boundary'
$ebIssues = [System.Collections.ArrayList]::new()

# Auto-discover producer files: all core/*.ahk + gui_pump.ahk + gui_main.ahk
# Using auto-discovery prevents new producer files from being silently missed.
$EB_PRODUCER_PATTERNS = @('src\core\*.ahk', 'src\gui\gui_pump.ahk', 'src\gui\gui_main.ahk')

# Use shared function definition index (built in shared pre-processing pass)
$ebFuncDefs = $sharedFuncDefs

# Helper: check if a function body has try { within first N non-blank statements
function EB_HasTryCatch {
    param([string[]]$lines, [int]$defLine)
    $statementsChecked = 0
    # Scan up to 30 lines — try may appear after Critical guards & re-entrancy checks
    for ($j = $defLine + 1; $j -lt [Math]::Min($defLine + 30, $lines.Count); $j++) {
        $checkLine = $lines[$j].Trim()
        if ($checkLine -eq '' -or $checkLine -match '^\s*;') { continue }
        # Skip global/static/local declarations (common preamble)
        if ($checkLine -match '^\s*(?:global|static|local)\s') { continue }
        # Skip ; @profile lines (stripped in release builds, not real statements)
        if ($checkLine -match ';\s*@profile\s*$') { continue }
        $statementsChecked++
        if ($checkLine -match '^\s*try[\s{]' -or $checkLine -match '^\s*try$') {
            return $true
        }
        # Stop after checking 8 real statements — allows Critical guards before try
        if ($statementsChecked -ge 8) { return $false }
    }
    return $false
}

# Helper: check if a function body is trivial (<=2 non-blank, non-comment, non-decl statements)
# Trivial wrappers (e.g., one-shot starters, thin delegators) are exempt.
function EB_IsTrivial {
    param([string[]]$lines, [int]$defLine)
    $stmtCount = 0
    $depth = 0
    for ($j = $defLine + 1; $j -lt [Math]::Min($defLine + 20, $lines.Count); $j++) {
        $checkLine = $lines[$j].Trim()
        if ($checkLine -eq '' -or $checkLine -match '^\s*;') { continue }
        if ($checkLine -match '^\s*(?:global|static|local)\s') { continue }
        foreach ($c in $checkLine.ToCharArray()) {
            if ($c -eq '{') { $depth++ }
            elseif ($c -eq '}') { $depth--; if ($depth -le 0) { return ($stmtCount -le 2) } }
        }
        $stmtCount++
    }
    return ($stmtCount -le 2)
}

# Category A: Notification callbacks wired via WL_SetCallbacks()
# These are the store→GUI notification interface — called by producers when data changes.
# Other *_SetCallbacks() (IconPump, ProcPump, Stats) wire utility functions that are
# called FROM WITHIN already-protected pump tick callbacks, so they don't need their own boundary.
$ebNotificationCallbacks = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal)

foreach ($file in $allFiles) {
    $lines = $fileCache[$file.FullName]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        if ($raw -match '^\s*;') { continue }
        # Match: WL_SetCallbacks(funcRef1, funcRef2, ...)
        if ($raw -match 'WL_SetCallbacks\s*\(([^)]+)\)') {
            $argStr = $Matches[1]
            foreach ($arg in $argStr -split ',') {
                $trimmed = $arg.Trim()
                # Only match direct function references (not strings, not expressions)
                if ($trimmed -match '^([A-Za-z_]\w+)$') {
                    [void]$ebNotificationCallbacks.Add($Matches[1])
                }
            }
        }
    }
}

# Category B: Producer timer callbacks registered via SetTimer() in producer files
$ebTimerCallbacks = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal)

foreach ($file in $allFiles) {
    # Only check auto-discovered producer files (core/*.ahk, gui_pump.ahk, gui_main.ahk)
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $isProducerFile = $false
    foreach ($pattern in $EB_PRODUCER_PATTERNS) {
        if ($relPath -like $pattern) { $isProducerFile = $true; break }
    }
    if (-not $isProducerFile) { continue }

    $lines = $fileCache[$file.FullName]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        if ($raw -match '^\s*;') { continue }

        # SetTimer(CallbackFunc, interval) — direct function ref
        if ($raw -match 'SetTimer\s*\(\s*([A-Za-z_]\w+)\s*,') {
            $cbName = $Matches[1]
            # Skip deregistrations: SetTimer(ref, 0)
            if ($raw -match 'SetTimer\s*\(\s*[A-Za-z_]\w+\s*,\s*0\s*\)') { continue }
            [void]$ebTimerCallbacks.Add($cbName)
        }

        # SetTimer(boundRef, interval) — variable holding a .Bind() result
        # Pattern: varName := FuncName.Bind(...) then SetTimer(varName, ...)
        # Resolve the original function name from the Bind assignment
        if ($raw -match 'SetTimer\s*\(\s*([A-Za-z_]\w+)\s*,') {
            $varName = $Matches[1]
            # Skip if already a known function name (handled above)
            if ($ebFuncDefs.ContainsKey($varName)) { continue }
            # Search backward (up to 50 lines) for varName := SomeFunc.Bind(
            for ($j = [Math]::Max(0, $i - 50); $j -lt $i; $j++) {
                if ($lines[$j] -match "$([regex]::Escape($varName))\s*:=\s*(\w+)\s*\.\s*Bind\s*\(") {
                    $origFunc = $Matches[1]
                    [void]$ebTimerCallbacks.Add($origFunc)
                    break
                }
            }
        }
    }
}

# Category C: OnMessage handlers — external entry points from Windows message pump.
# If these throw, the app crashes (same risk as timer callbacks post-refactor).
# Scoped to MainProcess (gui/, core/) and Launcher (launcher/) files only —
# handlers in separate subprocesses (pump/, editors/) or shared infrastructure
# (shared/theme.ahk) are either crash-contained or pre-existing low-risk paint callbacks.
$ebOnMessageCallbacks = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal)
$EB_ONMSG_SCOPE = @('src\gui\*', 'src\core\*', 'src\launcher\*')

foreach ($file in $allFiles) {
    $omRelPath = $file.FullName.Replace("$projectRoot\", '')
    $inScope = $false
    foreach ($pattern in $EB_ONMSG_SCOPE) {
        if ($omRelPath -like $pattern) { $inScope = $true; break }
    }
    if (-not $inScope) { continue }

    $lines = $fileCache[$file.FullName]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        if ($raw -match '^\s*;') { continue }
        # Match: OnMessage(msgId, callbackFunc) — direct function reference
        if ($raw -match 'OnMessage\s*\(\s*\w+\s*,\s*([A-Za-z_]\w+)\s*[,)]') {
            [void]$ebOnMessageCallbacks.Add($Matches[1])
        }
    }
}

# Validate all identified callbacks have try-catch
$allCallbacks = [System.Collections.Generic.HashSet[string]]::new($ebNotificationCallbacks, [System.StringComparer]::Ordinal)
foreach ($cb in $ebTimerCallbacks) { [void]$allCallbacks.Add($cb) }
foreach ($cb in $ebOnMessageCallbacks) { [void]$allCallbacks.Add($cb) }

foreach ($cbName in $allCallbacks) {
    if (-not $ebFuncDefs.ContainsKey($cbName)) { continue }
    $info = $ebFuncDefs[$cbName]

    # Check suppression on definition line
    if ($info.Raw.Contains($EB_SUPPRESSION)) { continue }

    # Skip trivial wrappers (<=2 statements): one-shot starters, thin delegators.
    # These delegate to functions that already have their own error boundaries.
    if (EB_IsTrivial $info.Lines $info.DefLine) { continue }

    if (-not (EB_HasTryCatch $info.Lines $info.DefLine)) {
        $category = if ($ebNotificationCallbacks.Contains($cbName)) { 'notification' }
                    elseif ($ebOnMessageCallbacks.Contains($cbName)) { 'onmessage' }
                    else { 'timer' }
        [void]$ebIssues.Add([PSCustomObject]@{
            File     = $info.File
            Line     = $info.DefLine + 1
            Function = $cbName
            Category = $category
        })
    }
}

if ($ebIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($ebIssues.Count) callback(s) missing try-catch error boundary.")
    [void]$failOutput.AppendLine("  After the store->MainProcess refactor, unhandled errors crash the entire app.")
    [void]$failOutput.AppendLine("  All producer callbacks and OnMessage handlers MUST wrap their body in try { ... } catch { ... }.")
    [void]$failOutput.AppendLine("  Fix: add try { at the top of the function body (after global declarations).")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: error-boundary' on the function definition line.")
    $grouped = $ebIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): $($issue.Function)() [$($issue.Category)] - missing try-catch error boundary")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_producer_error_boundary"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 5: callback_invocation_arity
# Validates that callback globals wired via *_SetCallbacks() are
# invoked with the correct argument count. check_arity.ps1 covers
# direct function calls but NOT invocations through callback
# globals (gWS_OnStoreChanged(args...)). This check resolves
# SetCallbacks wiring to the target function, then validates
# every invocation site against the target's parameter signature.
# Reuses $csFuncParams from sub-check 1 (callback_signatures).
# Suppress: ; lint-ignore: callback-invocation-arity
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$ciaIssues = [System.Collections.ArrayList]::new()
$CIA_SUPPRESSION = 'lint-ignore: callback-invocation-arity'

# Phase 1: Use shared SetCallbacks definitions (built in shared pre-processing pass)
$ciaSetCallbacksDefs = $sharedSetCallbacksDefs

# Phase 2: Find call sites of each SetCallbacks to resolve actual function refs
# Example: WL_SetCallbacks(_GUI_OnProducerRevChanged, GUI_OnWorkspaceFlips)
#          -> gWS_OnStoreChanged resolves to _GUI_OnProducerRevChanged
#          -> gWS_OnWorkspaceChanged resolves to GUI_OnWorkspaceFlips
$ciaGlobalToTarget = @{}  # callbackGlobal -> targetFuncName

foreach ($scFuncName in $ciaSetCallbacksDefs.Keys) {
    $def = $ciaSetCallbacksDefs[$scFuncName]

    # Pre-compile regex per SetCallbacks name (avoids ~50K recompilations)
    $escaped = [regex]::Escape($scFuncName)
    $rxCall = [regex]::new("$escaped\s*\(([^)]+)\)", 'Compiled')
    $rxDef  = [regex]::new("^\s*(?:static\s+)?$escaped\s*\([^)]*\)\s*\{", 'Compiled')

    foreach ($file in $allFiles) {
        # File-level pre-filter: skip files that don't mention this function name
        if ($fileCacheText[$file.FullName].IndexOf($scFuncName) -lt 0) { continue }

        $lines = $fileCache[$file.FullName]
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $raw = $lines[$i]
            if ($raw -match '^\s*;') { continue }

            # Match call site: ScFuncName(arg1, arg2, ...)
            # But NOT the definition line (definition has { after closing paren)
            $m = $rxCall.Match($raw)
            if ($m.Success -and -not $rxDef.IsMatch($raw)) {
                $argStr = $m.Groups[1].Value
                $args = @()
                foreach ($a in $argStr -split ',') {
                    $trimA = $a.Trim()
                    if ($trimA -ne '') { $args += $trimA }
                }

                # Map positional arguments to parameter names, then to callback globals
                for ($ai = 0; $ai -lt [Math]::Min($args.Count, $def.ParamNames.Count); $ai++) {
                    $paramName = $def.ParamNames[$ai]
                    if ($def.GlobalMap.ContainsKey($paramName)) {
                        $globalName = $def.GlobalMap[$paramName]
                        $funcRef = $args[$ai]
                        # Only resolve direct function references (identifiers, not expressions)
                        if ($funcRef -match '^[A-Za-z_]\w+$') {
                            $ciaGlobalToTarget[$globalName] = $funcRef
                        }
                    }
                }
            }
        }
    }
}

# Phase 3: Collect invocation sites with argument counts
# Uses $csFuncParams from sub-check 6 (callback_signatures) for function parameter info
$ciaInvocations = @{}  # globalName -> list of @{ File; Line; ArgCount; Code; Suppressed }

foreach ($file in $allFiles) {
    $text = $fileCacheText[$file.FullName]

    # Pre-filter: skip files that don't mention any resolved callback global
    $hasAny = $false
    foreach ($globalName in $ciaGlobalToTarget.Keys) {
        if ($text.Contains("$globalName(")) { $hasAny = $true; break }
    }
    if (-not $hasAny) { continue }

    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        $trimmed = $raw.TrimStart()
        if ($trimmed.Length -eq 0 -or $trimmed[0] -eq ';') { continue }

        foreach ($globalName in $ciaGlobalToTarget.Keys) {
            $callIdx = $raw.IndexOf("$globalName(", [System.StringComparison]::Ordinal)
            if ($callIdx -lt 0) { continue }

            # Skip global declarations and SetCallbacks bodies
            $cleaned = BC_CleanLine $raw
            if ($cleaned.IndexOf("$globalName(", [System.StringComparison]::Ordinal) -lt 0) { continue }
            if ($cleaned -match '^\s*global\s') { continue }
            if ($cleaned -match 'SetCallbacks') { continue }
            if ($cleaned -match "^\s*(?:static\s+)?$([regex]::Escape($globalName))\s*:=") { continue }

            # Count arguments in the invocation
            $afterCall = $raw.Substring($callIdx + $globalName.Length + 1)
            $parenD = 1; $argCount = 0; $hasContent = $false
            for ($j = 0; $j -lt $afterCall.Length; $j++) {
                $c = $afterCall[$j]
                if ($c -eq '(') { $parenD++; $hasContent = $true }
                elseif ($c -eq ')') {
                    $parenD--
                    if ($parenD -eq 0) { break }
                    $hasContent = $true
                }
                elseif ($c -eq ',' -and $parenD -eq 1) { $argCount++ }
                elseif ($c -ne ' ' -and $c -ne "`t") { $hasContent = $true }
            }
            if ($hasContent) { $argCount++ }  # content before first comma = 1 arg

            if (-not $ciaInvocations.ContainsKey($globalName)) {
                $ciaInvocations[$globalName] = [System.Collections.ArrayList]::new()
            }
            [void]$ciaInvocations[$globalName].Add(@{
                File = $relPath; Line = $i + 1; ArgCount = $argCount
                Code = $raw.Trim(); Suppressed = $raw.Contains($CIA_SUPPRESSION)
            })
        }
    }
}

# Phase 4a: Hard arity violations (too few/too many args for the target signature)
foreach ($globalName in $ciaInvocations.Keys) {
    $targetFunc = $ciaGlobalToTarget[$globalName]
    if (-not $csFuncParams.ContainsKey($targetFunc)) { continue }

    $sig = $csFuncParams[$targetFunc]
    $minArgs = $sig.RequiredCount
    $maxArgs = $sig.TotalParams

    foreach ($inv in $ciaInvocations[$globalName]) {
        if ($inv.Suppressed) { continue }
        $tooFew = $inv.ArgCount -lt $minArgs
        $tooMany = (-not $sig.HasVariadic) -and ($inv.ArgCount -gt $maxArgs)

        if ($tooFew -or $tooMany) {
            $detail = if ($tooFew) {
                "passed $($inv.ArgCount) arg(s), needs at least $minArgs"
            } else {
                "passed $($inv.ArgCount) arg(s), max $maxArgs"
            }
            [void]$ciaIssues.Add([PSCustomObject]@{
                File = $inv.File; Line = $inv.Line; Global = $globalName
                TargetFunc = $targetFunc; Detail = $detail; Code = $inv.Code
            })
        }
    }
}

# Phase 4b: Inconsistent arity — when multiple invocation sites for the same callback
# use different argument counts. The minority is flagged as the outlier.
# This catches bugs where default parameters mask wrong behavior (e.g., passing 0 args
# when all other sites pass 1 — the default is not the intended value).
foreach ($globalName in $ciaInvocations.Keys) {
    $invList = $ciaInvocations[$globalName]
    $unsuppressed = @($invList | Where-Object { -not $_.Suppressed })
    if ($unsuppressed.Count -lt 2) { continue }

    # Count occurrences of each arg count
    $argCounts = @{}
    foreach ($inv in $unsuppressed) {
        $key = $inv.ArgCount
        if (-not $argCounts.ContainsKey($key)) { $argCounts[$key] = 0 }
        $argCounts[$key]++
    }
    if ($argCounts.Count -le 1) { continue }  # all consistent

    # Find the majority arg count
    $majorityCount = -1; $majorityArgs = -1
    foreach ($key in $argCounts.Keys) {
        if ($argCounts[$key] -gt $majorityCount) {
            $majorityCount = $argCounts[$key]
            $majorityArgs = $key
        }
    }

    # Flag outliers (sites that differ from majority)
    $targetFunc = $ciaGlobalToTarget[$globalName]
    foreach ($inv in $unsuppressed) {
        if ($inv.ArgCount -ne $majorityArgs) {
            [void]$ciaIssues.Add([PSCustomObject]@{
                File       = $inv.File
                Line       = $inv.Line
                Global     = $globalName
                TargetFunc = $targetFunc
                Detail     = "passes $($inv.ArgCount) arg(s) but $majorityCount/$($unsuppressed.Count) sites pass $majorityArgs"
                Code       = $inv.Code
            })
        }
    }
}

if ($ciaIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($ciaIssues.Count) callback invocation arity issue(s) found.")
    [void]$failOutput.AppendLine("  Callback globals wired via SetCallbacks() must be invoked with consistent")
    [void]$failOutput.AppendLine("  argument counts matching the target function's signature.")
    [void]$failOutput.AppendLine("  Fix: pass the correct number of arguments to the callback invocation.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: callback-invocation-arity' on the invocation line.")
    foreach ($issue in $ciaIssues | Sort-Object File, Line) {
        [void]$failOutput.AppendLine("    $($issue.File):$($issue.Line): $($issue.Global)() -> $($issue.TargetFunc)(): $($issue.Detail)")
        [void]$failOutput.AppendLine("      $($issue.Code)")
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_callback_invocation_arity"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 6: guard_try_finally
# Detects same-function boolean guard pairs (var := true / var := false)
# where the false/0 reset is NOT inside a finally block.
# Without try/finally, an exception between set and reset permanently
# blocks the guard, preventing all future calls.
# Suppress: ; lint-ignore: guard-try-finally (on the := true line)
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$gtfIssues = [System.Collections.ArrayList]::new()
$GTF_SUPPRESSION = 'lint-ignore:\s*guard-try-finally'

# Phase 1: Collect candidate guard pairs (same-function set true + set false)
$gtfCandidates = [System.Collections.ArrayList]::new()

foreach ($file in $allFiles) {
    $text = $fileCacheText[$file.FullName]
    # Pre-filter: skip files without both true/1 and false/0 assignments
    $hasTrue = ($text.IndexOf(':= true') -ge 0) -or ($text.IndexOf(':= 1') -ge 0)
    $hasFalse = ($text.IndexOf(':= false') -ge 0) -or ($text.IndexOf(':= 0') -ge 0)
    if (-not $hasTrue -or -not $hasFalse) { continue }

    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $depth = 0
    $inFunc = $false
    $funcDepth = -1
    $funcName = ""
    $funcStartLine = 0
    # Per-function tracking: varName -> @{ TrueLines = @(); FalseLines = @() }
    $funcGuards = @{}
    # Track global declarations in current function
    $funcGlobals = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        if ($raw -match '^\s*;') { continue }
        $cleaned = BC_CleanLine $raw
        if ($cleaned -eq '') { continue }

        # Detect function definitions (not inside another function)
        if (-not $inFunc -and $cleaned -match '^\s*(?:static\s+)?([A-Za-z_]\w*)\s*\(') {
            $fname = $Matches[1]
            if (-not $BC_keywordSet.Contains($fname) -and $cleaned -match '\{') {
                $inFunc = $true
                $funcName = $fname
                $funcDepth = $depth
                $funcStartLine = $i
                $funcGuards = @{}
                $funcGlobals.Clear()
            }
        }

        $braces = BC_CountBraces $cleaned
        $depth += $braces[0] - $braces[1]

        if ($inFunc) {
            # Track global declarations
            if ($cleaned -match '(?i)^\s*global\b(.*)') {
                $globalList = $Matches[1]
                foreach ($gName in $globalList -split ',') {
                    $g = $gName.Trim() -replace '\s*:=.*', ''
                    if ($g -ne '' -and $g -match '^\w+$') {
                        [void]$funcGlobals.Add($g)
                    }
                }
            }

            # Match guard set true
            $m = $script:RX_GUARD_SET_TRUE.Match($cleaned)
            if ($m.Success) {
                $varName = $m.Groups[1].Value
                if (-not $BC_keywordSet.Contains($varName)) {
                    if (-not $funcGuards.ContainsKey($varName)) {
                        $funcGuards[$varName] = @{ TrueLines = @(); FalseLines = @(); TrueRawLines = @() }
                    }
                    $funcGuards[$varName].TrueLines += $i
                    $funcGuards[$varName].TrueRawLines += $raw
                }
            }

            # Match guard set false
            $m = $script:RX_GUARD_SET_FALSE.Match($cleaned)
            if ($m.Success) {
                $varName = $m.Groups[1].Value
                if (-not $BC_keywordSet.Contains($varName)) {
                    if (-not $funcGuards.ContainsKey($varName)) {
                        $funcGuards[$varName] = @{ TrueLines = @(); FalseLines = @(); TrueRawLines = @() }
                    }
                    $funcGuards[$varName].FalseLines += $i
                }
            }

            # Function ended
            if ($depth -le $funcDepth) {
                # Find same-function guard pairs that are reentrancy guards
                foreach ($varName in $funcGuards.Keys) {
                    $g = $funcGuards[$varName]
                    if ($g.TrueLines.Count -gt 0 -and $g.FalseLines.Count -gt 0) {
                        # Filter: must be a global (name starts with g/_ or declared global)
                        $isGlobal = $varName -match '^_?g' -or $funcGlobals.Contains($varName)
                        if (-not $isGlobal) { continue }

                        # Filter: must be a reentrancy guard (check-then-return before set-true).
                        # Pattern: if (varName) { ... return } appears before := true.
                        # Without this, plain state flags (gGUI_Revealed, gINT_TabPending, etc.)
                        # that toggle within a function would be false positives.
                        $firstTrue = ($g.TrueLines | Measure-Object -Minimum).Minimum
                        $hasGuardCheck = $false
                        $escapedVar = [regex]::Escape($varName)
                        for ($j = $funcStartLine; $j -lt $firstTrue; $j++) {
                            $cl = BC_CleanLine $lines[$j]
                            # Require varName as the sole if-condition (not part of &&/||)
                            if ($cl -match "(?i)^\s*if\s*[\s(]*\!?\s*$escapedVar\s*\)?\s*\{?\s*$") {
                                # Verify a return/throw follows within 10 lines
                                $scanEnd = [Math]::Min($j + 10, $firstTrue)
                                for ($k = $j; $k -lt $scanEnd; $k++) {
                                    $cl2 = BC_CleanLine $lines[$k]
                                    if ($cl2 -match '(?i)^\s*return\b' -or $cl2 -match '(?i)^\s*throw\b') {
                                        $hasGuardCheck = $true
                                        break
                                    }
                                }
                                if ($hasGuardCheck) { break }
                            }
                            # Also match single-line form: if (var) return / if (var) throw
                            elseif ($cl -match "(?i)^\s*if\s*[\s(]*\!?\s*$escapedVar\s*\)?\s+(?:return|throw)\b") {
                                $hasGuardCheck = $true
                                break
                            }
                        }
                        if (-not $hasGuardCheck) { continue }

                        [void]$gtfCandidates.Add([PSCustomObject]@{
                            File = $file.FullName
                            RelPath = $relPath
                            Function = $funcName
                            VarName = $varName
                            TrueLines = $g.TrueLines
                            FalseLines = $g.FalseLines
                            TrueRawLines = $g.TrueRawLines
                            FuncStart = $funcStartLine
                            FuncEnd = $i
                        })
                    }
                }
                $inFunc = $false
                $funcDepth = -1
                $funcGuards = @{}
                $funcGlobals.Clear()
            }
        }
    }
}

# Phase 2: Verify each candidate has its reset inside a finally block
foreach ($cand in $gtfCandidates) {
    # Check lint-ignore suppression on any := true line
    $suppressed = $false
    foreach ($rawLine in $cand.TrueRawLines) {
        if ($rawLine -match $GTF_SUPPRESSION) {
            $suppressed = $true
            break
        }
    }
    if ($suppressed) { continue }

    $lines = $fileCache[$cand.File]
    $firstTrueLine = ($cand.TrueLines | Measure-Object -Minimum).Minimum
    $anyResetInFinally = $false

    # Scan forward from first := true to function end, tracking try/finally nesting
    $tryStack = [System.Collections.Generic.Stack[int]]::new()
    $finallyStack = [System.Collections.Generic.Stack[int]]::new()
    $localDepth = 0
    $falseLineSet = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($fl in $cand.FalseLines) { [void]$falseLineSet.Add($fl) }

    for ($i = $firstTrueLine + 1; $i -le $cand.FuncEnd; $i++) {
        $raw = $lines[$i]
        if ($raw -match '^\s*;') { continue }
        $cleaned = BC_CleanLine $raw
        if ($cleaned -eq '') { continue }

        # Detect try { opening (before depth adjustment)
        if ($script:RX_TRY_OPEN.IsMatch($cleaned)) {
            $tryStack.Push($localDepth)
        }

        # Detect } finally { (before depth adjustment)
        # Push localDepth-1: the } closes the try body (depth-1), { opens finally body.
        # Using localDepth directly would cause immediate pop since } finally { has net-zero braces.
        if ($script:RX_FINALLY_OPEN.IsMatch($cleaned)) {
            if ($tryStack.Count -gt 0) {
                [void]$tryStack.Pop()
            }
            $finallyStack.Push($localDepth - 1)
        }

        # Adjust depth
        $braces = BC_CountBraces $cleaned
        $localDepth += $braces[0] - $braces[1]

        # Pop finished finally blocks
        while ($finallyStack.Count -gt 0 -and $localDepth -le $finallyStack.Peek()) {
            [void]$finallyStack.Pop()
        }
        # Pop finished try blocks
        while ($tryStack.Count -gt 0 -and $localDepth -le $tryStack.Peek()) {
            [void]$tryStack.Pop()
        }

        # Check if this is a reset line
        if ($falseLineSet.Contains($i)) {
            if ($finallyStack.Count -gt 0) {
                $anyResetInFinally = $true
                break
            }
        }
    }

    if (-not $anyResetInFinally) {
        $firstResetLine = ($cand.FalseLines | Measure-Object -Minimum).Minimum
        [void]$gtfIssues.Add([PSCustomObject]@{
            File = $cand.RelPath
            Line = $firstTrueLine + 1  # 1-indexed
            Function = $cand.Function
            VarName = $cand.VarName
            ResetLine = $firstResetLine + 1  # 1-indexed
        })
    }
}

if ($gtfIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($gtfIssues.Count) boolean guard(s) not protected by try/finally.")
    [void]$failOutput.AppendLine("  A guard set true then false in the same function MUST have the reset")
    [void]$failOutput.AppendLine("  inside a finally block. Without it, an exception permanently blocks the guard.")
    [void]$failOutput.AppendLine("  Fix: wrap the function body in try { ... } finally { guard := false }")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: guard-try-finally' on the := true line.")
    $grouped = $gtfIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): $($issue.VarName) in $($issue.Function)() $([char]0x2014) reset on line $($issue.ResetLine) is not inside a finally block")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_guard_try_finally"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 16: paint_resize_ordering
# Verifies GUI_Repaint's bidirectional resize ordering invariant:
#   shrink SetWindowPos BEFORE D2D_Present, grow SetWindowPos AFTER.
# Breaking this ordering causes visible BG image flash on grow resize.
# See: #221, #234, #177
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$paintFile = $allFiles | Where-Object { $_.Name -eq 'gui_paint.ahk' } | Select-Object -First 1
if ($paintFile) {
    $paintLines = $fileCache[$paintFile.FullName]
    # Find GUI_Repaint function boundaries
    $inFunc = $false; $braceDepth = 0
    $funcStart = -1; $funcEnd = -1
    for ($i = 0; $i -lt $paintLines.Count; $i++) {
        $ln = $paintLines[$i]
        if (-not $inFunc -and $ln -match '^\s*GUI_Repaint\s*\(') {
            $inFunc = $true; $funcStart = $i; $braceDepth = 0
        }
        if ($inFunc) {
            foreach ($ch in $ln.ToCharArray()) {
                if ($ch -eq '{') { $braceDepth++ }
                elseif ($ch -eq '}') { $braceDepth--; if ($braceDepth -le 0 -and $funcStart -ne $i) { $funcEnd = $i; break } }
            }
            if ($funcEnd -ge 0) { break }
        }
    }

    $proIssues = [System.Collections.ArrayList]::new()
    if ($funcStart -lt 0) {
        [void]$proIssues.Add("GUI_Repaint function not found in gui_paint.ahk")
    } else {
        # Collect line offsets of key calls within GUI_Repaint
        $isGrowingLine = -1
        $setPos1 = -1; $setPos2 = -1
        $presentLine = -1; $dwmFlushLine = -1
        for ($i = $funcStart; $i -le $funcEnd; $i++) {
            $ln = $paintLines[$i]
            if ($ln -match '^\s*;') { continue }
            if ($ln -match 'isGrowing\s*:=' -and $isGrowingLine -lt 0) { $isGrowingLine = $i }
            if ($ln -match 'Win_SetPosPhys\s*\(') {
                if ($setPos1 -lt 0) { $setPos1 = $i } else { $setPos2 = $i }
            }
            if ($ln -match 'D2D_Present\s*\(') { $presentLine = $i }
            if ($ln -match 'Win_DwmFlush\s*\(') { $dwmFlushLine = $i }
        }

        $ref = "See: https://github.com/cwilliams5/Alt-Tabby/issues/221"
        if ($isGrowingLine -lt 0) {
            [void]$proIssues.Add("isGrowing := not found in GUI_Repaint $([char]0x2014) bidirectional resize logic missing. $ref")
        }
        if ($setPos1 -lt 0 -or $setPos2 -lt 0) {
            [void]$proIssues.Add("Expected 2 Win_SetPosPhys calls in GUI_Repaint (shrink + grow), found $(if ($setPos1 -lt 0) { 0 } elseif ($setPos2 -lt 0) { 1 } else { 2 }). $ref")
        }
        if ($presentLine -lt 0) {
            [void]$proIssues.Add("D2D_Present not found in GUI_Repaint. $ref")
        }
        if ($proIssues.Count -eq 0) {
            # Verify ordering: shrinkSetPos < Present < DwmFlush < growSetPos
            if ($setPos1 -ge $presentLine) {
                [void]$proIssues.Add("Shrink Win_SetPosPhys (line $($setPos1+1)) must be BEFORE D2D_Present (line $($presentLine+1)). $ref")
            }
            if ($setPos2 -le $presentLine) {
                [void]$proIssues.Add("Grow Win_SetPosPhys (line $($setPos2+1)) must be AFTER D2D_Present (line $($presentLine+1)). $ref")
            }
            if ($dwmFlushLine -lt 0) {
                [void]$proIssues.Add("Win_DwmFlush not found before grow Win_SetPosPhys $([char]0x2014) required to prevent stale-content flash. $ref")
            } elseif ($dwmFlushLine -le $presentLine -or $dwmFlushLine -ge $setPos2) {
                [void]$proIssues.Add("Win_DwmFlush (line $($dwmFlushLine+1)) must be between D2D_Present (line $($presentLine+1)) and grow Win_SetPosPhys (line $($setPos2+1)). $ref")
            }
        }
    }

    if ($proIssues.Count -gt 0) {
        $anyFailed = $true
        [void]$failOutput.AppendLine("")
        [void]$failOutput.AppendLine("  FAIL: GUI_Repaint bidirectional resize ordering violated.")
        [void]$failOutput.AppendLine("  The HWND must be $([char]0x2264) content size during SetWindowPos STA pump:")
        [void]$failOutput.AppendLine("    Shrink: Win_SetPosPhys BEFORE D2D_Present")
        [void]$failOutput.AppendLine("    Grow:   D2D_Present $([char]0x2192) Win_DwmFlush $([char]0x2192) Win_SetPosPhys")
        [void]$failOutput.AppendLine("  DO NOT unify both directions to the same ordering (#221, #234).")
        foreach ($issue in $proIssues) {
            [void]$failOutput.AppendLine("    $([char]0x2022) $issue")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_paint_resize_ordering"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Report
# ============================================================
$totalSw.Stop()

if ($anyFailed) {
    Write-Host $failOutput.ToString().TrimEnd()
} else {
    Write-Host "  PASS: All guard checks passed (callback_signatures, critical_leaks, critical_sections, producer_error_boundary, callback_invocation_arity, guard_try_finally, paint_resize_ordering)" -ForegroundColor Green
}

Write-Host "  Timing: shared=$($sharedPassSw.ElapsedMilliseconds)ms total=$($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan

# Write sub-timing for nested display (consumed by static_analysis.ps1)
$subTimings | ConvertTo-Json -Compress | Set-Content "$env:TEMP\sa_batch_guards_timing.json" -Encoding UTF8

if ($anyFailed) { exit 1 }
exit 0
