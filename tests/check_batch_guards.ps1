# check_batch_guards.ps1 - Batched guard/enforcement checks
# Combines checks that enforce usage patterns to prevent regressions.
# Sub-checks: thememsgbox, callback_critical, log_guards, onmessage_collision, postmessage_safety, callback_signatures, onevent_names, destroy_untrack
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
# Report
# ============================================================
$totalSw.Stop()

if ($anyFailed) {
    Write-Host $failOutput.ToString().TrimEnd()
} else {
    Write-Host "  PASS: All guard checks passed (thememsgbox, callback_critical, log_guards, onmessage_collision, postmessage_safety, callback_signatures, onevent_names, destroy_untrack)" -ForegroundColor Green
}

Write-Host "  Timing: total=$($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan

# Write sub-timing for nested display (consumed by static_analysis.ps1)
$subTimings | ConvertTo-Json -Compress | Set-Content "$env:TEMP\sa_batch_guards_timing.json" -Encoding UTF8

if ($anyFailed) { exit 1 }
exit 0
