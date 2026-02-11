# check_batch_guards.ps1 - Batched guard/enforcement checks
# Combines checks that enforce usage patterns to prevent regressions.
# Sub-checks: thememsgbox, callback_critical, log_guards
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
foreach ($f in $allFiles) {
    $fileCache[$f.FullName] = [System.IO.File]::ReadAllLines($f.FullName)
}

# === Sub-check tracking ===
$subTimings = [System.Collections.ArrayList]::new()
$anyFailed = $false
$failOutput = [System.Text.StringBuilder]::new()

# ============================================================
# Sub-check 1: thememsgbox
# Flags bare MsgBox( calls — should use ThemeMsgBox() for dark mode
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$tmIssues = [System.Collections.ArrayList]::new()

# Files exempt from this check
$TM_EXEMPT = @(
    'theme_msgbox.ahk'           # ThemeMsgBox implementation + fallback
    'config_registry_editor.ahk' # Developer tool, runs before theme init
)
$TM_SUPPRESSION = 'lint-ignore: thememsgbox'

foreach ($file in $allFiles) {
    if ($TM_EXEMPT -contains $file.Name) { continue }

    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]

        # Skip comments
        if ($raw -match '^\s*;') { continue }
        # Skip suppressed lines
        if ($raw.Contains($TM_SUPPRESSION)) { continue }

        # Strip end-of-line comments (semicolon preceded by whitespace, outside strings)
        $cleaned = $raw
        $inStr = $false; $commentStart = -1
        for ($j = 0; $j -lt $cleaned.Length; $j++) {
            if ($cleaned[$j] -eq '"') { $inStr = -not $inStr }
            elseif (-not $inStr -and $cleaned[$j] -eq ';' -and $j -gt 0 -and $cleaned[$j - 1] -match '\s') {
                $commentStart = $j - 1; break
            }
        }
        if ($commentStart -ge 0) { $cleaned = $cleaned.Substring(0, $commentStart) }

        # Match bare MsgBox( but NOT ThemeMsgBox(
        # Must be MsgBox( preceded by non-word char or start of line, and NOT preceded by "Theme"
        if ($cleaned -match '(?<!\w)MsgBox\s*\(' -and $cleaned -notmatch 'ThemeMsgBox\s*\(') {
            [void]$tmIssues.Add([PSCustomObject]@{
                File = $relPath; Line = ($i + 1); Text = $raw.Trim()
            })
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_thememsgbox"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

if ($tmIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($tmIssues.Count) bare MsgBox() call(s) found. Use ThemeMsgBox() for dark mode support.")
    [void]$failOutput.AppendLine("  Fix: replace MsgBox(...) with ThemeMsgBox(...) (drop-in replacement).")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: thememsgbox' on the same line.")
    $grouped = $tmIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): $($issue.Text)")
        }
    }
}

# ============================================================
# Sub-check 2: callback_critical
# Verifies Hotkey/OnMessage callbacks start with Critical "On"
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$ccIssues = [System.Collections.ArrayList]::new()
$CC_SUPPRESSION = 'lint-ignore: callback-critical'

# Only scan gui/ files (hotkeys and OnMessage are registered in GUI process)
$guiFiles = @($allFiles | Where-Object { $_.FullName -like "*\gui\*" })

# Phase 1: Collect all Hotkey/OnMessage registrations with named function callbacks
$callbackFuncs = @{}  # funcName -> list of "relpath:lineNum" registration sites

foreach ($file in $guiFiles) {
    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        if ($raw -match '^\s*;') { continue }
        if ($raw.Contains($CC_SUPPRESSION)) { continue }

        # Hotkey("keyname", CallbackFunc) — named function reference
        # Skip: Hotkey("keyname", "On"/"Off") — toggle, not registration
        # Skip: Hotkey("keyname", (*) => ...) — inline lambda
        if ($raw -match 'Hotkey\(\s*"[^"]*"\s*,\s*([A-Za-z_]\w+)\s*\)') {
            $funcName = $Matches[1]
            # "On" and "Off" are toggle commands, not callbacks
            if ($funcName -eq 'On' -or $funcName -eq 'Off') { continue }
            if (-not $callbackFuncs.ContainsKey($funcName)) {
                $callbackFuncs[$funcName] = [System.Collections.ArrayList]::new()
            }
            [void]$callbackFuncs[$funcName].Add("${relPath}:$($i + 1)")
        }

        # OnMessage(msg, CallbackFunc) — named function reference
        # Skip: OnMessage(msg, (*) => ...) — inline lambda
        if ($raw -match 'OnMessage\(\s*[^,]+,\s*([A-Za-z_]\w+)\s*[\),]') {
            $funcName = $Matches[1]
            if (-not $callbackFuncs.ContainsKey($funcName)) {
                $callbackFuncs[$funcName] = [System.Collections.ArrayList]::new()
            }
            [void]$callbackFuncs[$funcName].Add("${relPath}:$($i + 1)")
        }
    }
}

# Phase 2: For each callback function, verify it starts with Critical "On"
# Search ALL gui/ files for the function definition
foreach ($funcName in $callbackFuncs.Keys) {
    $found = $false

    foreach ($file in $guiFiles) {
        $lines = $fileCache[$file.FullName]
        $relPath = $file.FullName.Replace("$projectRoot\", '')

        for ($i = 0; $i -lt $lines.Count; $i++) {
            # Match function definition: FuncName(params) {
            if ($lines[$i] -match "^\s*(?:static\s+)?$([regex]::Escape($funcName))\s*\(.*\)\s*\{?\s*$") {
                $found = $true

                # Scan the next ~10 lines (skipping blank/comment lines) for Critical "On"
                $hasCritical = $false
                $statementsChecked = 0
                for ($j = $i + 1; $j -lt [Math]::Min($i + 15, $lines.Count); $j++) {
                    $checkLine = $lines[$j].Trim()
                    # Skip blank lines and comments
                    if ($checkLine -eq '' -or $checkLine -match '^\s*;') { continue }
                    # Skip global declarations
                    if ($checkLine -match '^\s*global\s') { continue }

                    $statementsChecked++

                    if ($checkLine -match 'Critical\s+"On"' -or
                        $checkLine -match 'Critical\s+true' -or
                        $checkLine -match "Critical\s*\(\s*[`"']On[`"']\s*\)") {
                        $hasCritical = $true
                        break
                    }

                    # Only check first 5 real statements
                    if ($statementsChecked -ge 5) { break }
                }

                if (-not $hasCritical) {
                    # Check if the definition line itself has suppression
                    if (-not $lines[$i].Contains($CC_SUPPRESSION)) {
                        [void]$ccIssues.Add([PSCustomObject]@{
                            File     = $relPath
                            Line     = ($i + 1)
                            Function = $funcName
                            RegSites = $callbackFuncs[$funcName]
                        })
                    }
                }
                break  # Found the definition, stop searching this file
            }
        }
        if ($found) { break }  # Found in this file, stop searching other files
    }
}

$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_callback_critical"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

if ($ccIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($ccIssues.Count) Hotkey/OnMessage callback(s) missing Critical ``""On``"".")
    [void]$failOutput.AppendLine("  AHK v2 hotkeys can interrupt each other - Critical prevents race conditions.")
    [void]$failOutput.AppendLine("  Fix: add Critical ``""On``"" as the first statement in the callback function.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: callback-critical' on the Hotkey/OnMessage line or function definition.")
    $grouped = $ccIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): $($issue.Function)() - missing Critical ``""On``""")
            foreach ($ref in $issue.RegSites) {
                [void]$failOutput.AppendLine("        (registered at $ref)")
            }
        }
    }
}

# ============================================================
# Sub-check 3: log_guards
# Caller-side log guard enforcement for log calls with concatenation
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Log function -> acceptable guard patterns
$lgGuards = @{
    'GUI_LogEvent'  = @('cfg.DiagEventLog', 'DiagEventLog')
    'Paint_Log'     = @('cfg.DiagPaintTimingLog', 'DiagPaintTimingLog')
    '_Store_LogInfo' = @('cfg.DiagStoreLog', 'DiagStoreLog', 'cfg.DiagChurnLog', 'DiagChurnLog')
    '_Launcher_Log'  = @('cfg.DiagLauncherLog', 'DiagLauncherLog')
    '_IPC_Log'      = @('logEnabled', '_IPC_IsLogEnabled')
    '_Update_Log'   = @('cfg.DiagUpdateLog', 'DiagUpdateLog')
    '_IP_Log'       = @('_IP_DiagEnabled', 'logEnabled')
    '_PP_Log'       = @('cfg.DiagProcPumpLog', 'DiagProcPumpLog')
    '_WEH_DiagLog'  = @('cfg.DiagWinEventLog', 'DiagWinEventLog')
    'KSub_DiagLog'  = @('cfg.DiagKomorebiLog', 'DiagKomorebiLog')
    '_Viewer_Log'   = @('gViewer_LogPath')
}

$lgCallPattern = '(?<!\w)(' + ($lgGuards.Keys -join '|') + ')\s*\('
$lgAllFuncNames = [string[]]@($lgGuards.Keys)

function BG_LG_CleanLine {
    param([string]$line)
    if ($line -match '^\s*;') { return '' }
    $cleaned = $line -replace '\s;.*$', ''
    return $cleaned
}

function BG_LG_StripStrings {
    param([string]$line)
    $stripped = $line -replace '"[^"]*"', '""'
    $stripped = $stripped -replace "'[^']*'", "''"
    return $stripped
}

function BG_LG_HasConcat {
    param([string]$rawLine, [string]$funcName)
    $idx = $rawLine.IndexOf("$funcName(")
    if ($idx -lt 0) { return $false }
    $argStart = $idx + $funcName.Length + 1
    if ($argStart -ge $rawLine.Length) { return $false }
    $argPart = $rawLine.Substring($argStart)
    $depth = 1; $end = 0
    for ($k = 0; $k -lt $argPart.Length; $k++) {
        $c = $argPart[$k]
        if ($c -eq '(') { $depth++ }
        elseif ($c -eq ')') {
            $depth--
            if ($depth -eq 0) { $end = $k; break }
        }
    }
    if ($end -gt 0) { $argPart = $argPart.Substring(0, $end) }
    $argTrimmed = $argPart.Trim()
    if ($argTrimmed -match '^"[^"]*"$') { return $false }
    if ($argTrimmed -notmatch '"') { return $true }
    $withoutStrings = $argTrimmed -replace '"[^"]*"', ''
    $withoutStrings = $withoutStrings.Trim()
    if ($withoutStrings -match '[A-Za-z_]\w*') { return $true }
    return $false
}

$lgIssues = [System.Collections.ArrayList]::new()
$lgCallsChecked = 0

foreach ($file in $allFiles) {
    $lines = $fileCache[$file.FullName]

    # File-level pre-filter: skip files without any enforced log function
    $hasLogFunc = $false
    $joined = [string]::Join("`n", $lines)
    foreach ($fn in $lgAllFuncNames) {
        if ($joined.Contains($fn)) { $hasLogFunc = $true; break }
    }
    if (-not $hasLogFunc) { continue }

    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $guardStack = [System.Collections.ArrayList]::new()
    $currentDepth = 0
    $prevCleanedLine = ''

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $rawLine = $lines[$i]
        $cleaned = BG_LG_CleanLine $rawLine
        if ($cleaned -eq '') { continue }
        $stripped = BG_LG_StripStrings $cleaned

        # Count braces
        $opens = 0; $closes = 0
        foreach ($c in $stripped.ToCharArray()) {
            if ($c -eq '{') { $opens++ }
            elseif ($c -eq '}') { $closes++ }
        }

        $depthAfterClose = $currentDepth - $closes
        if ($depthAfterClose -lt 0) { $depthAfterClose = 0 }

        # Pop guards whose blocks have closed
        while ($guardStack.Count -gt 0 -and $depthAfterClose -le $guardStack[$guardStack.Count - 1].depth) {
            $guardStack.RemoveAt($guardStack.Count - 1)
        }

        # If a block opens, check if it's a guarded if
        if ($opens -gt 0) {
            $guardLine = $null
            if ($cleaned -match '(?:^|\belse\s+)\s*if[\s(]') {
                $guardLine = $cleaned
            } elseif ($prevCleanedLine -ne '' -and $prevCleanedLine -match '(?:^|\belse\s+)\s*if[\s(]') {
                $guardLine = $prevCleanedLine
            }
            if ($null -ne $guardLine) {
                [void]$guardStack.Add(@{ depth = $depthAfterClose; line = $guardLine })
            }
        }

        $currentDepth = $depthAfterClose + $opens

        # Check if this line contains an enforced log function call
        if ($stripped -notmatch $lgCallPattern) {
            $prevCleanedLine = $cleaned
            continue
        }

        $logFunc = $Matches[1]

        # Skip function DEFINITIONS
        if ($stripped -match "^\s*(?:static\s+)?$logFunc\s*\([^)]*\)\s*\{") {
            $prevCleanedLine = $cleaned; continue
        }
        if ($stripped -match "^\s*(?:static\s+)?$logFunc\s*\([^)]*\)\s*$") {
            if ($i + 1 -lt $lines.Count -and $lines[$i + 1] -match '^\s*\{') {
                $prevCleanedLine = $cleaned; continue
            }
        }

        # Only check calls with string concatenation
        if (-not (BG_LG_HasConcat $rawLine $logFunc)) {
            $prevCleanedLine = $cleaned; continue
        }

        $lgCallsChecked++
        $guardPatterns = $lgGuards[$logFunc]
        $isGuarded = $false

        # Check forward-built guard stack
        for ($s = 0; $s -lt $guardStack.Count; $s++) {
            foreach ($guard in $guardPatterns) {
                if ($guardStack[$s].line.Contains($guard)) {
                    $isGuarded = $true; break
                }
            }
            if ($isGuarded) { break }
        }

        # Braceless guard: look back 1-3 lines
        if (-not $isGuarded) {
            for ($j = [Math]::Max(0, $i - 3); $j -lt $i; $j++) {
                $prevCl = BG_LG_CleanLine $lines[$j]
                if ($prevCl -eq '') { continue }
                if ($prevCl -match '(?:^|\belse\s+)\s*if[\s(]' -and $prevCl -notmatch '\{') {
                    foreach ($guard in $guardPatterns) {
                        if ($prevCl.Contains($guard)) {
                            $isGuarded = $true; break
                        }
                    }
                    if ($isGuarded) { break }
                }
            }
        }

        if (-not $isGuarded) {
            [void]$lgIssues.Add([PSCustomObject]@{
                File = $relPath; Line = $i + 1
                Function = $logFunc; Code = $rawLine.Trim()
            })
        }

        $prevCleanedLine = $cleaned
    }
}

if ($lgIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($lgIssues.Count) unguarded log call(s) with string concatenation found.")
    [void]$failOutput.AppendLine("  AHK v2 evaluates arguments BEFORE the call - string concatenation runs")
    [void]$failOutput.AppendLine("  unconditionally. Wrap log calls in caller-side if-guards.")
    $grouped = $lgIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): $($issue.Function)() missing guard")
            [void]$failOutput.AppendLine("        $($issue.Code)")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_log_guards"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Report
# ============================================================
$totalSw.Stop()

if ($anyFailed) {
    Write-Host $failOutput.ToString().TrimEnd()
} else {
    Write-Host "  PASS: All guard checks passed (thememsgbox, callback_critical, log_guards)" -ForegroundColor Green
}

Write-Host "  Timing: total=$($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan

# Write sub-timing for nested display (consumed by static_analysis.ps1)
$subTimings | ConvertTo-Json -Compress | Set-Content "$env:TEMP\sa_batch_guards_timing.json" -Encoding UTF8

if ($anyFailed) { exit 1 }
exit 0
