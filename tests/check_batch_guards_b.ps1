# check_batch_guards_b.ps1 - Batched guard/enforcement checks (batch B)
# Independent checks that don't require shared preprocessing data.
# Sub-checks: thememsgbox, callback_critical, log_guards, onmessage_collision, postmessage_safety, onevent_names, destroy_untrack, callback_null_guard, map_delete
# Shared file cache: all src/ files (excluding lib/) read once.
#
# Usage: powershell -File tests\check_batch_guards_b.ps1 [-SourceDir "path\to\src"]
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

# === Pre-compiled regex patterns ===
$script:RX_DBL_STR   = [regex]::new('"[^"]*"', 'Compiled')
$script:RX_SGL_STR   = [regex]::new("'[^']*'", 'Compiled')
$script:RX_CMT_TAIL  = [regex]::new('\s;.*$', 'Compiled')

# === Helper: clean line (strip strings and comments) ===
function BB_CleanLine {
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
    'GUI_LogEvent'  = @('cfg.DiagEventLog', 'DiagEventLog', 'diagLog')
    'Paint_Log'     = @('cfg.DiagPaintTimingLog', 'DiagPaintTimingLog', 'diagTiming')
    '_Store_LogInfo' = @('cfg.DiagStoreLog', 'DiagStoreLog', 'cfg.DiagChurnLog', 'DiagChurnLog')
    'Launcher_Log'   = @('cfg.DiagLauncherLog', 'DiagLauncherLog')
    '_IPC_Log'      = @('logEnabled', '_IPC_IsLogEnabled')
    '_Update_Log'   = @('cfg.DiagUpdateLog', 'DiagUpdateLog')
    '_IP_Log'       = @('_IP_DiagEnabled', 'logEnabled')
    '_PP_Log'       = @('cfg.DiagProcPumpLog', 'DiagProcPumpLog', 'logEnabled')
    '_WEH_DiagLog'  = @('cfg.DiagWinEventLog', 'DiagWinEventLog', 'logEnabled')
    'KSub_DiagLog'  = @('cfg.DiagKomorebiLog', 'DiagKomorebiLog', 'logEnabled')
    '_Viewer_Log'   = @('gViewer_LogPath')
}

$lgCallPattern = '(?<!\w)(' + ($lgGuards.Keys -join '|') + ')\s*\('
$lgAllFuncNames = [string[]]@($lgGuards.Keys)

function BB_LG_CleanLine {
    param([string]$line)
    if ($line -match '^\s*;') { return '' }
    $cleaned = $script:RX_CMT_TAIL.Replace($line, '')
    return $cleaned
}

function BB_LG_StripStrings {
    param([string]$line)
    $stripped = $script:RX_DBL_STR.Replace($line, '""')
    $stripped = $script:RX_SGL_STR.Replace($stripped, "''")
    return $stripped
}

function BB_LG_HasConcat {
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
    $withoutStrings = $script:RX_DBL_STR.Replace($argTrimmed, '')
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
        $cleaned = BB_LG_CleanLine $rawLine
        if ($cleaned -eq '') { continue }
        $stripped = BB_LG_StripStrings $cleaned

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
        if (-not (BB_LG_HasConcat $rawLine $logFunc)) {
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
                $prevCl = BB_LG_CleanLine $lines[$j]
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
            $cleaned = $script:RX_DBL_STR.Replace($cleaned, '""')
        }
        if ($cleaned.IndexOf("'") -ge 0) {
            $cleaned = $script:RX_SGL_STR.Replace($cleaned, "''")
        }
        if ($cleaned.IndexOf(';') -ge 0) {
            $cleaned = $script:RX_CMT_TAIL.Replace($cleaned, '')
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
# Sub-check 6: onevent_names
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
# Sub-check 7: destroy_untrack
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
# Sub-check 8: callback_null_guard
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
                $cleaned = BB_CleanLine $raw
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
# Sub-check 9: map_delete
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
    Write-Host "  PASS: All guard checks passed (thememsgbox, callback_critical, log_guards, onmessage_collision, postmessage_safety, onevent_names, destroy_untrack, callback_null_guard, map_delete)" -ForegroundColor Green
}

Write-Host "  Timing: total=$($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan

# Write sub-timing for nested display (consumed by static_analysis.ps1)
$subTimings | ConvertTo-Json -Compress | Set-Content "$env:TEMP\sa_batch_guards_b_timing.json" -Encoding UTF8

if ($anyFailed) { exit 1 }
exit 0
