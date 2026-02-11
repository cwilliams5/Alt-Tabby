# check_batch_guards.ps1 - Batched guard/enforcement checks
# Combines checks that enforce usage patterns to prevent regressions.
# Sub-checks: thememsgbox, callback_critical
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
# Report
# ============================================================
$totalSw.Stop()

if ($anyFailed) {
    Write-Host $failOutput.ToString().TrimEnd()
} else {
    Write-Host "  PASS: All guard checks passed (thememsgbox, callback_critical)" -ForegroundColor Green
}

Write-Host "  Timing: total=$($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan

# Write sub-timing for nested display (consumed by static_analysis.ps1)
$subTimings | ConvertTo-Json -Compress | Set-Content "$env:TEMP\sa_batch_guards_timing.json" -Encoding UTF8

if ($anyFailed) { exit 1 }
exit 0
