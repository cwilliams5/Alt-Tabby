# check_batch_guards.ps1 - Batched guard/enforcement checks
# Combines checks that enforce usage patterns to prevent regressions.
# Sub-checks: thememsgbox, callback_critical, log_guards, onmessage_collision, postmessage_safety, callback_signatures, onevent_names, destroy_untrack, critical_leaks, critical_sections, producer_error_boundary, callback_null_guard, callback_invocation_arity, map_delete
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
    $fileCache[$f.FullName] = $text -split "`r?`n"
}

# === Sub-check tracking ===
$subTimings = [System.Collections.ArrayList]::new()
$anyFailed = $false
$failOutput = [System.Text.StringBuilder]::new()

# === Critical section helpers (used by critical_leaks, critical_sections sub-checks) ===

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
    'Launcher_Log'   = @('cfg.DiagLauncherLog', 'DiagLauncherLog')
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
    $joined = $fileCacheText[$file.FullName]
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
# Sub-check 4: onmessage_collision
# Flags when multiple files register OnMessage handlers for the
# same Windows message number. AHK v2 stacks handlers LIFO —
# if the later handler returns a value, earlier handlers are
# silently skipped. Cross-file collisions create fragile
# implicit dependencies.
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$OM_SUPPRESSION = 'lint-ignore: onmessage-collision'

# Phase 1: Collect all global constant values (for resolving named constants)
$omConstants = @{}
foreach ($file in $allFiles) {
    $lines = $fileCache[$file.FullName]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*global\s+(\w+)\s*:=\s*(0x[0-9A-Fa-f]+|\d+)') {
            $cName = $Matches[1]
            $cVal = $Matches[2]
            if ($cVal -like '0x*') {
                $omConstants[$cName] = [Convert]::ToInt32($cVal, 16)
            } else {
                $omConstants[$cName] = [int]$cVal
            }
        }
    }
}

# Phase 2: Collect all OnMessage registrations (skip deregistrations)
$omRegistrations = @{}  # msgNum -> list of @{ File; Line; Raw; MsgExpr }

foreach ($file in $allFiles) {
    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        if ($raw -match '^\s*;') { continue }
        if ($raw.Contains($OM_SUPPRESSION)) { continue }

        # Match OnMessage( <msgExpr>, <handler> [, <addRemove>] )
        if ($raw -notmatch 'OnMessage\s*\(') { continue }

        # Extract the first argument (message identifier)
        $afterParen = $raw.Substring($raw.IndexOf('OnMessage(') + 10)

        # Find first comma (end of msg argument)
        $parenD = 0; $commaIdx = -1
        for ($j = 0; $j -lt $afterParen.Length; $j++) {
            if ($afterParen[$j] -eq '(') { $parenD++ }
            elseif ($afterParen[$j] -eq ')') {
                if ($parenD -eq 0) { break }
                $parenD--
            }
            elseif ($afterParen[$j] -eq ',' -and $parenD -eq 0) {
                $commaIdx = $j; break
            }
        }
        if ($commaIdx -lt 0) { continue }

        $msgExpr = $afterParen.Substring(0, $commaIdx).Trim()

        # Check for deregistration: 3rd argument is 0
        # Find the rest after the handler argument
        $restAfterHandler = $afterParen.Substring($commaIdx + 1)
        # Find second comma
        $parenD = 0; $comma2Idx = -1
        for ($j = 0; $j -lt $restAfterHandler.Length; $j++) {
            if ($restAfterHandler[$j] -eq '(') { $parenD++ }
            elseif ($restAfterHandler[$j] -eq ')') {
                if ($parenD -eq 0) { break }
                $parenD--
            }
            elseif ($restAfterHandler[$j] -eq ',' -and $parenD -eq 0) {
                $comma2Idx = $j; break
            }
        }
        if ($comma2Idx -ge 0) {
            $thirdArg = $restAfterHandler.Substring($comma2Idx + 1).Trim().TrimEnd(')')
            if ($thirdArg -eq '0') { continue }  # Deregistration, skip
        }

        # Resolve message number
        $msgNum = $null
        if ($msgExpr -match '^0x[0-9A-Fa-f]+$') {
            $msgNum = [Convert]::ToInt32($msgExpr, 16)
        } elseif ($msgExpr -match '^\d+$') {
            $msgNum = [int]$msgExpr
        } elseif ($omConstants.ContainsKey($msgExpr)) {
            $msgNum = $omConstants[$msgExpr]
        }
        if ($null -eq $msgNum) { continue }  # Can't resolve, skip

        if (-not $omRegistrations.ContainsKey($msgNum)) {
            $omRegistrations[$msgNum] = [System.Collections.ArrayList]::new()
        }
        [void]$omRegistrations[$msgNum].Add([PSCustomObject]@{
            File = $relPath; Line = ($i + 1); Raw = $raw.Trim(); MsgExpr = $msgExpr
        })
    }
}

# Phase 3: Flag message numbers with registrations in >1 file
$omIssues = [System.Collections.ArrayList]::new()
foreach ($msgNum in $omRegistrations.Keys) {
    $regs = $omRegistrations[$msgNum]
    $uniqueFiles = @($regs | ForEach-Object { $_.File } | Sort-Object -Unique)
    if ($uniqueFiles.Count -gt 1) {
        [void]$omIssues.Add([PSCustomObject]@{
            MsgNum = '0x{0:X4}' -f $msgNum
            Registrations = $regs
            FileCount = $uniqueFiles.Count
        })
    }
}

if ($omIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($omIssues.Count) OnMessage collision(s) found across files.")
    [void]$failOutput.AppendLine("  AHK v2 stacks handlers LIFO - if the later handler returns a value,")
    [void]$failOutput.AppendLine("  earlier handlers are silently skipped. Cross-file collisions are fragile.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: onmessage-collision' on the OnMessage() line.")
    foreach ($issue in $omIssues | Sort-Object MsgNum) {
        [void]$failOutput.AppendLine("    Message $($issue.MsgNum) registered in $($issue.FileCount) files:")
        foreach ($reg in $issue.Registrations | Sort-Object File, Line) {
            [void]$failOutput.AppendLine("      $($reg.File):$($reg.Line) - OnMessage($($reg.MsgExpr), ...)")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_onmessage_collision"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 5: postmessage_safety
# Flags PostMessage/SendMessage to external window handles
# (ahk_id pattern) that aren't wrapped in a try block.
# TOCTOU race: window can be destroyed between validation and send.
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$PM_SUPPRESSION = 'lint-ignore: postmessage-unsafe'
$pmIssues = [System.Collections.ArrayList]::new()

foreach ($file in $allFiles) {
    $lines = $fileCache[$file.FullName]

    # Pre-filter: skip files without PostMessage/SendMessage + ahk_id
    $hasPattern = $false
    foreach ($line in $lines) {
        if ($line -match '(?:Post|Send)Message\s*\(' -and $line -match 'ahk_id') {
            $hasPattern = $true; break
        }
    }
    if (-not $hasPattern) { continue }

    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $tryDepths = [System.Collections.ArrayList]::new()  # stack of brace depths where try blocks started
    $braceDepth = 0

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        $trimmed = $raw.TrimStart()
        if ($trimmed -eq '' -or $trimmed[0] -eq ';') { continue }

        # Strip strings and comments for brace counting
        $cleaned = $raw
        if ($cleaned.IndexOf('"') -ge 0) {
            $cleaned = $cleaned -replace '"[^"]*"', '""'
        }
        if ($cleaned.IndexOf("'") -ge 0) {
            $cleaned = $cleaned -replace "'[^']*'", "''"
        }
        if ($cleaned.IndexOf(';') -ge 0) {
            $cleaned = $cleaned -replace '\s;.*$', ''
        }

        # Count braces and track try blocks
        foreach ($c in $cleaned.ToCharArray()) {
            if ($c -eq '{') {
                $braceDepth++
            }
            elseif ($c -eq '}') {
                $braceDepth--
                if ($braceDepth -lt 0) { $braceDepth = 0 }
                # Pop any try blocks that ended
                while ($tryDepths.Count -gt 0 -and $tryDepths[$tryDepths.Count - 1] -ge $braceDepth) {
                    $tryDepths.RemoveAt($tryDepths.Count - 1)
                }
            }
        }

        # Detect try block start (braced or single-line)
        if ($trimmed -match '^try\s*\{') {
            [void]$tryDepths.Add($braceDepth - 1)  # opened brace already counted above
        }

        # Check for PostMessage/SendMessage with ahk_id
        if ($raw -match '(?:Post|Send)Message\s*\(' -and $raw -match 'ahk_id') {
            if ($raw.Contains($PM_SUPPRESSION)) { continue }

            # Check if inside a try block OR preceded by 'try' on the same line
            $inTry = $tryDepths.Count -gt 0
            if (-not $inTry -and $trimmed -match '^try\s+(?:Post|Send)Message') {
                $inTry = $true
            }

            if (-not $inTry) {
                [void]$pmIssues.Add([PSCustomObject]@{
                    File = $relPath; Line = ($i + 1); Code = $raw.Trim()
                })
            }
        }
    }
}

if ($pmIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($pmIssues.Count) PostMessage/SendMessage to external hwnd without try.")
    [void]$failOutput.AppendLine("  Window can be destroyed between WinExist() and PostMessage() (TOCTOU race).")
    [void]$failOutput.AppendLine("  Fix: wrap in try { PostMessage(...) } or use try PostMessage(...).")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: postmessage-unsafe' on the same line.")
    foreach ($issue in $pmIssues | Sort-Object File, Line) {
        [void]$failOutput.AppendLine("    $($issue.File):$($issue.Line): $($issue.Code)")
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_postmessage_safety"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 6: callback_signatures
# Validates that SetTimer callbacks accept 0 params (or variadic)
# and OnMessage callbacks accept <=4 params (or variadic).
# In AHK v2, wrong param count = runtime crash when the callback fires.
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$CS_SUPPRESSION = 'lint-ignore: callback-signature'

# Phase 1: Build function definition index (name -> param info)
$csFuncParams = @{}  # funcName -> @{ RequiredCount; HasVariadic; File; Line }

$CS_KEYWORDS = @(
    'if', 'else', 'while', 'for', 'loop', 'switch', 'case', 'catch',
    'finally', 'try', 'class', 'return', 'throw', 'static', 'global',
    'local', 'until', 'not', 'and', 'or', 'is', 'in', 'contains',
    'new', 'super', 'this', 'true', 'false', 'unset', 'isset'
)

foreach ($file in $allFiles) {
    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        if ($raw -match '^\s*;') { continue }

        # Match function definition with param list
        if ($raw -match '^\s*(?:static\s+)?([A-Za-z_]\w*)\s*\(([^)]*)\)\s*\{?') {
            $funcName = $Matches[1]
            $paramStr = $Matches[2].Trim()
            if ($funcName.ToLower() -in $CS_KEYWORDS) { continue }

            # Parse parameter string
            $hasVariadic = $paramStr -match '\*'
            $requiredCount = 0
            if ($paramStr -ne '' -and -not $hasVariadic) {
                # Count parameters that have no default value
                foreach ($param in $paramStr -split ',') {
                    $p = $param.Trim()
                    if ($p -eq '') { continue }
                    # Has default? param := value or param = value
                    if ($p -match ':=|=') { continue }
                    # ByRef? &param — still counts as required
                    $requiredCount++
                }
            }

            if (-not $csFuncParams.ContainsKey($funcName)) {
                $csFuncParams[$funcName] = @{
                    RequiredCount = $requiredCount
                    HasVariadic   = $hasVariadic
                    TotalParams   = if ($paramStr -eq '') { 0 } else { ($paramStr -split ',').Count }
                    File          = $relPath
                    Line          = $i + 1
                }
            }
        }
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
# Sub-check 7: onevent_names
# Validates OnEvent() event name strings against AHK v2 valid
# event names. AHK v2 silently ignores OnEvent() with an
# invalid name — the handler never fires, with no error.
# Suppress: ; lint-ignore: onevent-name
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$OE_SUPPRESSION = 'lint-ignore: onevent-name'

# Registry of valid AHK v2 GUI/control event names (case-insensitive in AHK)
$validEventNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
@(
    # Gui events
    'Close', 'Escape', 'Size', 'DropFiles', 'ContextMenu',
    # Common control events
    'Click', 'DoubleClick', 'Change', 'Focus', 'LoseFocus',
    # ListView/TreeView events
    'ColClick', 'ItemCheck', 'ItemEdit', 'ItemExpand', 'ItemFocus', 'ItemSelect',
    # StatusBar events
    'RightClick'
) | ForEach-Object { [void]$validEventNames.Add($_) }

$oeIssues = [System.Collections.ArrayList]::new()

foreach ($file in $allFiles) {
    $lines = $fileCache[$file.FullName]

    # Pre-filter: skip files without OnEvent
    $joined = $fileCacheText[$file.FullName]
    if ($joined.IndexOf('OnEvent') -lt 0) { continue }

    $relPath = $file.FullName.Replace("$projectRoot\", '')

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        if ($raw -match '^\s*;') { continue }
        if ($raw.Contains($OE_SUPPRESSION)) { continue }
        if ($raw.IndexOf('OnEvent') -lt 0) { continue }

        # Match .OnEvent("EventName", ...)
        $oeMatches = [regex]::Matches($raw, '\.OnEvent\(\s*"([^"]+)"')
        foreach ($m in $oeMatches) {
            $eventName = $m.Groups[1].Value
            if (-not $validEventNames.Contains($eventName)) {
                [void]$oeIssues.Add([PSCustomObject]@{
                    File = $relPath; Line = ($i + 1); EventName = $eventName
                })
            }
        }
    }
}

$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_onevent_names"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

if ($oeIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($oeIssues.Count) OnEvent() call(s) with unrecognized event name.")
    [void]$failOutput.AppendLine("  AHK v2 silently ignores OnEvent() with an invalid name - the handler never fires.")
    [void]$failOutput.AppendLine("  Valid names: $($validEventNames | Sort-Object | Join-String -Separator ', ')")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: onevent-name' on the OnEvent line.")
    $grouped = $oeIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): .OnEvent(``""$($issue.EventName)``"", ...) - unknown event name")
        }
    }
}

# ============================================================
# Sub-check 8: destroy_untrack
# Flags Gui.Destroy() in files that use Theme_ApplyToGui without
# a nearby Theme_UntrackGui() call. Destroying a themed GUI
# without untracking leaves stale references that crash on
# system theme change (WM_SETTINGCHANGE).
# Suppress: ; lint-ignore: destroy-untrack
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$DU_SUPPRESSION = 'lint-ignore: destroy-untrack'

# Phase 1: For each file with Theme_ApplyToGui, extract the GUI expressions
# that are themed. Only Theme_ApplyToGui adds to the tracked array —
# Theme_ApplyToControl applies visual styles but does NOT track for lifecycle.
# Phase 2: Check if Theme_UntrackGui is called for the same expression.
# Phase 3: Only flag if the GUI is also .Destroy()'d without untracking.
$duIssues = [System.Collections.ArrayList]::new()

foreach ($file in $allFiles) {
    $joined = $fileCacheText[$file.FullName]
    if (-not $joined.Contains('Theme_ApplyToGui')) { continue }

    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    # Find all Theme_ApplyToGui(expr) calls — extract the GUI expression
    $themedExprs = @{}
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        if ($raw -match '^\s*;') { continue }
        if ($raw -match 'Theme_ApplyToGui\((\w+(?:\[[^\]]*\])*)\)') {
            $themedExprs[$Matches[1]] = $i + 1
        }
    }
    if ($themedExprs.Count -eq 0) { continue }

    # For each themed expression, check for matching UntrackGui and Destroy calls
    foreach ($expr in @($themedExprs.Keys)) {
        $escaped = [regex]::Escape($expr)
        $hasUntrack = $false
        $destroyLines = [System.Collections.ArrayList]::new()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "Theme_UntrackGui\($escaped\)") { $hasUntrack = $true }
            if ($lines[$i] -match "$escaped\.Destroy\(\)" -and
                $lines[$i] -notmatch '^\s*;' -and
                -not $lines[$i].Contains($DU_SUPPRESSION)) {
                [void]$destroyLines.Add($i + 1)
            }
        }
        # Only flag if themed AND destroyed AND never untracked
        if ($hasUntrack -or $destroyLines.Count -eq 0) { continue }

        foreach ($ln in $destroyLines) {
            [void]$duIssues.Add([PSCustomObject]@{
                File = $relPath; Line = $ln
                GuiVar = $expr; Text = $lines[$ln - 1].Trim()
            })
        }
    }
}

$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_destroy_untrack"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

if ($duIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($duIssues.Count) Gui.Destroy() call(s) in themed files without Theme_UntrackGui().")
    [void]$failOutput.AppendLine("  Theme system tracks GUIs via Theme_ApplyToGui(). Destroying without untracking")
    [void]$failOutput.AppendLine("  leaves stale references that crash on system theme change (WM_SETTINGCHANGE).")
    [void]$failOutput.AppendLine("  Fix: call Theme_UntrackGui(gui) before gui.Destroy().")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: destroy-untrack' on the .Destroy() line.")
    $grouped = $duIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): $($issue.GuiVar).Destroy() - missing Theme_UntrackGui()")
        }
    }
}

# ============================================================
# Sub-check 9: critical_leaks
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
    # Pre-compile hot-path regex for function call extraction (used on every line in Critical sections)
    $rxFuncCall = [regex]::new('(?<![.\w])(\w+)\s*\(', 'Compiled')

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
# Sub-check 10: critical_sections
# Detects return/continue/throw inside Critical "On" sections
# without preceding Critical "Off".
# Suppress: ; lint-ignore: critical-section (throw cannot be suppressed)
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$csIssues = [System.Collections.ArrayList]::new()
$csFuncCount = 0

foreach ($file in $allFiles) {
    if ($fileCacheText[$file.FullName].IndexOf('Critical') -lt 0) { continue }

    # Reuse pre-processed line data from critical_leaks (avoids re-cleaning/re-counting)
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
# Sub-check 11: producer_error_boundary
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

# Build function definition index: funcName -> @{ File; Line; Lines (body start) }
# Reuse $allFiles and $fileCache from shared cache
$ebFuncDefs = @{}
foreach ($file in $allFiles) {
    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $depth = 0
    $inFunc = $false
    $funcDepth = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = BC_CleanLine $lines[$i]
        if ($cleaned -eq '') { continue }

        if (-not $inFunc -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(') {
            $fname = $Matches[1]
            if (-not $BC_keywordSet.Contains($fname) -and $cleaned -match '\{') {
                $inFunc = $true
                $funcDepth = $depth
                if (-not $ebFuncDefs.ContainsKey($fname)) {
                    $ebFuncDefs[$fname] = @{
                        File = $relPath; DefLine = $i; FileName = $file.Name
                        Lines = $lines; Raw = $lines[$i]
                    }
                }
            }
        }

        $braces = BC_CountBraces $cleaned
        $depth += $braces[0] - $braces[1]

        if ($inFunc -and $depth -le $funcDepth) {
            $inFunc = $false
            $funcDepth = -1
        }
    }
}

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
# Sub-check 12: callback_null_guard
# Notification callback globals (gWS_On*) are initialized to 0
# and wired later via SetCallbacks. Invoking them without a null
# check crashes if callbacks aren't wired yet (early init, tests).
# Before the refactor these were IPC sends (fire-and-forget).
# Now they're direct function calls that throw on null.
# Suppress: ; lint-ignore: callback-null-guard
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$cngIssues = [System.Collections.ArrayList]::new()
$CNG_SUPPRESSION = 'lint-ignore: callback-null-guard'

# Phase 1: Collect notification callback globals (global g*_On* := 0)
$callbackGlobals = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal)

foreach ($file in $allFiles) {
    $lines = $fileCache[$file.FullName]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        if ($raw -match '^\s*global\s+(g\w+_On\w+)\s*:=\s*0\b') {
            [void]$callbackGlobals.Add($Matches[1])
        }
    }
}

# Phase 2: Find all invocation sites and verify null-check guard
if ($callbackGlobals.Count -gt 0) {
    foreach ($file in $allFiles) {
        $text = $fileCacheText[$file.FullName]

        # Pre-filter: skip files that don't mention any callback global
        $hasAny = $false
        foreach ($cbName in $callbackGlobals) {
            if ($text.Contains("$cbName(")) { $hasAny = $true; break }
        }
        if (-not $hasAny) { continue }

        $lines = $fileCache[$file.FullName]
        $relPath = $file.FullName
        if ($relPath.StartsWith("$projectRoot\")) {
            $relPath = $relPath.Substring("$projectRoot\".Length)
        }

        for ($i = 0; $i -lt $lines.Count; $i++) {
            $raw = $lines[$i]
            $trimmed = $raw.TrimStart()
            if ($trimmed.Length -eq 0 -or $trimmed[0] -eq ';') { continue }
            if ($raw.Contains($CNG_SUPPRESSION)) { continue }

            foreach ($cbName in $callbackGlobals) {
                # Check for invocation: cbName(
                if ($raw.IndexOf("$cbName(", [System.StringComparison]::Ordinal) -lt 0) { continue }

                # Strip strings and comments
                $cleaned = BC_CleanLine $raw
                if ($cleaned.IndexOf("$cbName(", [System.StringComparison]::Ordinal) -lt 0) { continue }

                # Skip the SetCallbacks definition (assigns the callback, doesn't invoke it)
                if ($cleaned -match 'SetCallbacks') { continue }

                # Skip global declarations (the := 0 init line)
                if ($cleaned -match '^\s*global\s') { continue }

                # Verify guard: preceding non-blank, non-comment line must contain if (cbName)
                $guarded = $false

                # Same-line guard: if (cbName) cbName(...)
                if ($cleaned -match "if\s*\(\s*$([regex]::Escape($cbName))\s*\)") {
                    $guarded = $true
                }

                # Also check for compound condition: if (... && cbName)
                if (-not $guarded -and $cleaned -match "\b$([regex]::Escape($cbName))\b.*$([regex]::Escape($cbName))\(") {
                    # The variable appears before the call on the same line — might be a compound guard
                    if ($cleaned -match "if\s*\(.*\b$([regex]::Escape($cbName))\b") {
                        $guarded = $true
                    }
                }

                # Previous-line guard
                if (-not $guarded) {
                    for ($pi = $i - 1; $pi -ge 0 -and $pi -ge ($i - 3); $pi--) {
                        $prevLine = $lines[$pi].TrimStart()
                        if ($prevLine.Length -eq 0 -or $prevLine[0] -eq ';') { continue }
                        if ($prevLine -match "if\s*\(.*\b$([regex]::Escape($cbName))\b") {
                            $guarded = $true
                        }
                        break  # Stop at first non-blank, non-comment line
                    }
                }

                if (-not $guarded) {
                    [void]$cngIssues.Add([PSCustomObject]@{
                        File = $relPath; Line = $i + 1
                        Callback = $cbName; Code = $raw.Trim()
                    })
                }
            }
        }
    }
}

if ($cngIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($cngIssues.Count) unguarded notification callback invocation(s).")
    [void]$failOutput.AppendLine("  Notification callbacks (gWS_On*) are initialized to 0 and wired later.")
    [void]$failOutput.AppendLine("  Invoking without a null check crashes if callbacks aren't wired yet.")
    [void]$failOutput.AppendLine("  Fix: add 'if (callbackVar)' guard before the invocation.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: callback-null-guard' on the invocation line.")
    foreach ($issue in $cngIssues | Sort-Object File, Line) {
        [void]$failOutput.AppendLine("    $($issue.File):$($issue.Line): $($issue.Callback)() invoked without null guard")
        [void]$failOutput.AppendLine("      $($issue.Code)")
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_callback_null_guard"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 13: callback_invocation_arity
# Validates that callback globals wired via *_SetCallbacks() are
# invoked with the correct argument count. check_arity.ps1 covers
# direct function calls but NOT invocations through callback
# globals (gWS_OnStoreChanged(args...)). This check resolves
# SetCallbacks wiring to the target function, then validates
# every invocation site against the target's parameter signature.
# Reuses $csFuncParams from sub-check 6 and $callbackGlobals
# from sub-check 12.
# Suppress: ; lint-ignore: callback-invocation-arity
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$ciaIssues = [System.Collections.ArrayList]::new()
$CIA_SUPPRESSION = 'lint-ignore: callback-invocation-arity'

# Phase 1: Find *_SetCallbacks() definitions — map parameter positions to callback globals
# Example: WL_SetCallbacks(onStoreChanged, onWorkspaceChanged) {
#              gWS_OnStoreChanged := onStoreChanged    -> param position 0 -> gWS_OnStoreChanged
#              gWS_OnWorkspaceChanged := onWorkspaceChanged -> param position 1 -> gWS_OnWorkspaceChanged
#          }
$ciaSetCallbacksDefs = @{}  # funcName -> @{ ParamNames = string[]; GlobalMap = @{ paramName -> globalName } }

foreach ($file in $allFiles) {
    $lines = $fileCache[$file.FullName]
    $depth = 0
    $inFunc = $false
    $funcDepth = -1
    $scName = ""
    $scParams = @()

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = BC_CleanLine $lines[$i]
        if ($cleaned -eq '') { continue }

        # Detect *_SetCallbacks function definition
        if (-not $inFunc -and $cleaned -match '^\s*(?:static\s+)?(\w+_SetCallbacks)\s*\(([^)]*)\)\s*\{?') {
            $scName = $Matches[1]
            $paramStr = $Matches[2].Trim()
            $scParams = @()
            if ($paramStr -ne '') {
                foreach ($p in $paramStr -split ',') {
                    $trimP = $p.Trim() -replace '\s*:=.*$', ''  # strip defaults
                    $trimP = $trimP -replace '^\s*&?\s*', ''     # strip ByRef
                    if ($trimP -ne '') { $scParams += $trimP }
                }
            }
            if ($cleaned -match '\{') {
                $inFunc = $true
                $funcDepth = $depth
                $ciaSetCallbacksDefs[$scName] = @{
                    ParamNames = $scParams
                    GlobalMap = @{}
                }
            }
        }

        $braces = BC_CountBraces $cleaned
        $depth += $braces[0] - $braces[1]

        if ($inFunc) {
            # Look for assignments: gSomeCallback := paramName
            if ($cleaned -match '^\s*(g\w+_On\w+)\s*:=\s*(\w+)\s*$') {
                $globalName = $Matches[1]
                $assignedParam = $Matches[2]
                if ($ciaSetCallbacksDefs.ContainsKey($scName)) {
                    $ciaSetCallbacksDefs[$scName].GlobalMap[$assignedParam] = $globalName
                }
            }
            if ($depth -le $funcDepth) {
                $inFunc = $false
                $funcDepth = -1
            }
        }
    }
}

# Phase 2: Find call sites of each SetCallbacks to resolve actual function refs
# Example: WL_SetCallbacks(_GUI_OnProducerRevChanged, GUI_OnWorkspaceFlips)
#          -> gWS_OnStoreChanged resolves to _GUI_OnProducerRevChanged
#          -> gWS_OnWorkspaceChanged resolves to GUI_OnWorkspaceFlips
$ciaGlobalToTarget = @{}  # callbackGlobal -> targetFuncName

foreach ($scFuncName in $ciaSetCallbacksDefs.Keys) {
    $def = $ciaSetCallbacksDefs[$scFuncName]

    foreach ($file in $allFiles) {
        $lines = $fileCache[$file.FullName]
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $raw = $lines[$i]
            if ($raw -match '^\s*;') { continue }

            # Match call site: ScFuncName(arg1, arg2, ...)
            # But NOT the definition line (definition has { after closing paren)
            if ($raw -match "$([regex]::Escape($scFuncName))\s*\(([^)]+)\)" -and
                $raw -notmatch "^\s*(?:static\s+)?$([regex]::Escape($scFuncName))\s*\([^)]*\)\s*\{") {
                $argStr = $Matches[1]
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
# Sub-check 14: map_delete
# Flags Map.Delete() calls without a safety guard.
# AHK v2 Map.Delete() throws ValueError if the key doesn't exist.
# Guards recognized:
#   1. try on the same line (try map.Delete(...))
#   2. .Has(key) on same map variable within 10 lines above
#   3. .Get(key on same map variable within 10 lines above (implies existence check)
#   4. Same map variable iterated with "for" in the containing function (prune loop)
# Suppress: ; lint-ignore: map-delete
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$MD_SUPPRESSION = 'lint-ignore: map-delete'

# Regex to match .Delete( calls — captures map variable and key expression
$mdDeleteRx = [regex]::new('(\w+(?:\.\w+)*)\.Delete\(([^)]+)\)')

# Non-map types that have .Delete() methods (GUI controls, TrayMenu, etc.)
$mdNonMapTypes = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
@('A_TrayMenu', 'gViewer_LV', 'Sidebar', 'tray', 'menu', 'LV') |
    ForEach-Object { [void]$mdNonMapTypes.Add($_) }

$mdIssues = [System.Collections.ArrayList]::new()

foreach ($file in $allFiles) {
    $joined = $fileCacheText[$file.FullName]
    if ($joined.IndexOf('.Delete(') -lt 0) { continue }

    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        $trimmed = $raw.TrimStart()

        # Skip comments
        if ($trimmed.Length -gt 0 -and $trimmed[0] -eq ';') { continue }

        # Must contain .Delete(
        if ($raw.IndexOf('.Delete(') -lt 0) { continue }

        # Skip suppressed
        if ($raw.Contains($MD_SUPPRESSION)) { continue }

        # Extract map variable and key
        $m = $mdDeleteRx.Match($raw)
        if (-not $m.Success) { continue }

        $mapVar = $m.Groups[1].Value
        $keyExpr = $m.Groups[2].Value.Trim()

        # Skip non-Map .Delete() calls (GUI controls, etc.)
        $baseVar = $mapVar
        if ($mapVar.Contains('.')) {
            $baseVar = $mapVar.Substring($mapVar.LastIndexOf('.') + 1)
        }
        if ($mdNonMapTypes.Contains($baseVar)) { continue }
        # Skip if key is empty or a string literal (not a Map operation)
        if ($keyExpr -eq '' -or $keyExpr[0] -eq '"' -or $keyExpr[0] -eq "'") { continue }

        # Guard 1: try on same line
        if ($trimmed -match '^\s*try\b') { continue }

        # Guard 2 & 3: .Has(key) or .Get(key on same map variable within 10 lines above
        $hasGuard = $false
        $lookBack = [Math]::Max(0, $i - 10)
        $escapedMap = [regex]::Escape($mapVar)
        $escapedKey = [regex]::Escape($keyExpr)
        for ($j = $lookBack; $j -lt $i; $j++) {
            $prev = $lines[$j]
            if ($prev -match "$escapedMap\.Has\(\s*$escapedKey\s*\)") { $hasGuard = $true; break }
            if ($prev -match "$escapedMap\.Get\(\s*$escapedKey\b") { $hasGuard = $true; break }
        }
        if ($hasGuard) { continue }

        # Guard 4: Prune loop — same map iterated with "for" in containing function.
        # Find function start by scanning backward for function signature.
        $inPruneLoop = $false
        $funcStart = -1
        for ($j = $i - 1; $j -ge 0; $j--) {
            $fl = $lines[$j].TrimStart()
            # Function signature: word( at start of line with { (distinguishes
            # function definitions from function calls like DllCall(...))
            if ($fl -match '^\w+\([^)]*\)\s*\{') {
                $funcStart = $j
                break
            }
        }
        if ($funcStart -ge 0) {
            # Search from function start to current line for "for ... in <mapVar>"
            for ($j = $funcStart; $j -lt $i; $j++) {
                if ($lines[$j] -match "\bfor\b.*\bin\b\s+$escapedMap\b") {
                    $inPruneLoop = $true
                    break
                }
            }
        }
        if ($inPruneLoop) { continue }

        # Unguarded — flag it
        [void]$mdIssues.Add([PSCustomObject]@{
            File = $relPath
            Line = $i + 1
            MapVar = $mapVar
            Key = $keyExpr
            Code = $trimmed
        })
    }
}

$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_map_delete"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

if ($mdIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($mdIssues.Count) unguarded Map.Delete() call(s) found.")
    [void]$failOutput.AppendLine("  AHK v2 Map.Delete() throws ValueError if the key doesn't exist.")
    [void]$failOutput.AppendLine("  Fix: add .Has(key) check before .Delete(), wrap in try, or verify")
    [void]$failOutput.AppendLine("  the key is guaranteed to exist (e.g., from iterating the same map).")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: map-delete' on the .Delete() line.")
    $grouped = $mdIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            $delStr = "$($issue.MapVar).Delete($($issue.Key))"
            [void]$failOutput.AppendLine("      Line $($issue.Line): $delStr - no .Has() guard, try, or prune-loop iteration")
        }
    }
}

# ============================================================
# Report
# ============================================================
$totalSw.Stop()

if ($anyFailed) {
    Write-Host $failOutput.ToString().TrimEnd()
} else {
    Write-Host "  PASS: All guard checks passed (thememsgbox, callback_critical, log_guards, onmessage_collision, postmessage_safety, callback_signatures, onevent_names, destroy_untrack, critical_leaks, critical_sections, producer_error_boundary, callback_null_guard, callback_invocation_arity, map_delete)" -ForegroundColor Green
}

Write-Host "  Timing: total=$($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan

# Write sub-timing for nested display (consumed by static_analysis.ps1)
$subTimings | ConvertTo-Json -Compress | Set-Content "$env:TEMP\sa_batch_guards_timing.json" -Encoding UTF8

if ($anyFailed) { exit 1 }
exit 0
