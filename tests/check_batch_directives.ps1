# check_batch_directives.ps1 - Batched directive/keyword checks
# Combines 4 simple checks into one PowerShell process to reduce startup overhead.
# Sub-checks: requires_directive, singleinstance, state_strings, winexist_cloaked
#
# Usage: powershell -File tests\check_batch_directives.ps1 [-SourceDir "path\to\src"]
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
# Sub-check 1: requires_directive
# Ensures every .ahk file declares #Requires AutoHotkey v2.0
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$EXCLUDED_FILES_RD = @('version_info.ahk')
$rdIssues = @()

foreach ($file in $allFiles) {
    if ($EXCLUDED_FILES_RD -contains $file.Name) { continue }

    $lines = $fileCache[$file.FullName]
    $found = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*#Requires\s+AutoHotkey\s+v2') {
            $found = $true
            break
        }
        if ($line -match '^\s*[^;#\s]' -and $line -notmatch '^\s*;') {
            break
        }
    }

    if (-not $found) {
        $relPath = $file.FullName
        if ($relPath.StartsWith($SourceDir)) {
            $relPath = $relPath.Substring($SourceDir.Length).TrimStart('\', '/')
        }
        $rdIssues += $relPath
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_requires_directive"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

if ($rdIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($rdIssues.Count) file(s) missing #Requires AutoHotkey v2.0")
    [void]$failOutput.AppendLine("  Add as the first line: #Requires AutoHotkey v2.0")
    foreach ($f in $rdIssues | Sort-Object) {
        [void]$failOutput.AppendLine("    $f")
    }
}

# ============================================================
# Sub-check 2: singleinstance
# Entry point needs #SingleInstance Off; modules must not have it
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$siIssues = [System.Collections.ArrayList]::new()
$entryPoint = Join-Path $SourceDir "alt_tabby.ahk"
$standaloneEntryPoints = @(
    (Join-Path $SourceDir "editors\config_registry_editor.ahk")
    (Join-Path $SourceDir "store\store_server.ahk")
)

# Rule 1: Entry point must have #SingleInstance Off
if (Test-Path $entryPoint) {
    $entryPointOk = $false
    $lines = $fileCache[$entryPoint]
    foreach ($line in $lines) {
        if ($line -match '^\s*#SingleInstance\s+Off') { $entryPointOk = $true; break }
    }
    if (-not $entryPointOk) {
        $relPath = $entryPoint.Replace("$projectRoot\", '')
        [void]$siIssues.Add([PSCustomObject]@{
            File = $relPath; Line = 0
            Message = "Entry point missing '#SingleInstance Off'"; Rule = "required"
        })
    }
} else {
    [void]$siIssues.Add([PSCustomObject]@{
        File = "src\alt_tabby.ahk"; Line = 0
        Message = "Entry point file not found"; Rule = "required"
    })
}

# Rule 2: Module files must not have any #SingleInstance directive
$moduleFiles = @($allFiles | Where-Object {
    $_.FullName -ne $entryPoint -and
    $_.FullName -notin $standaloneEntryPoints
})
foreach ($file in $moduleFiles) {
    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*;') { continue }
        if ($line -match 'lint-ignore:\s*singleinstance') { continue }
        if ($line -match '^\s*#SingleInstance') {
            [void]$siIssues.Add([PSCustomObject]@{
                File = $relPath; Line = ($i + 1)
                Message = "Module file has directive: $($line.Trim())"; Rule = "forbidden"
            })
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_singleinstance"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

if ($siIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($siIssues.Count) #SingleInstance issue(s) found.")
    [void]$failOutput.AppendLine("  Entry point needs #SingleInstance Off; module files must not have any #SingleInstance directive.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: singleinstance' on the directive line.")
    $grouped = $siIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            if ($issue.Line -gt 0) {
                [void]$failOutput.AppendLine("      Line $($issue.Line): $($issue.Message)")
            } else {
                [void]$failOutput.AppendLine("      $($issue.Message)")
            }
        }
    }
}

# ============================================================
# Sub-check 3: state_strings
# Validates gGUI_State string literals (IDLE, ALT_PENDING, ACTIVE)
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$VALID_STATES = @('IDLE', 'ALT_PENDING', 'ACTIVE')
$ssIssues = [System.Collections.ArrayList]::new()

foreach ($file in $allFiles) {
    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*;') { continue }
        if ($line -notmatch 'gGUI_State') { continue }
        $stripped = $line -replace '\s;.*$', ''
        $statePatterns = @(
            'gGUI_State\s*:=\s*"([^"]*)"',
            'gGUI_State\s*[!=]=?\s*"([^"]*)"',
            '"([^"]*)"\s*[!=]=?\s*gGUI_State'
        )
        foreach ($pattern in $statePatterns) {
            $regex = [regex]$pattern
            $m = $regex.Matches($stripped)
            foreach ($match in $m) {
                $stateStr = $match.Groups[1].Value
                if ($stateStr -cnotin $VALID_STATES) {
                    [void]$ssIssues.Add([PSCustomObject]@{
                        File = $relPath; Line = ($i + 1)
                        State = $stateStr; Context = $stripped.Trim()
                    })
                }
            }
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_state_strings"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

if ($ssIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($ssIssues.Count) invalid gGUI_State string(s) found.")
    [void]$failOutput.AppendLine("  Valid states: $($VALID_STATES -join ', ')")
    $grouped = $ssIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): invalid state `"$($issue.State)`"  ->  $($issue.Context)")
        }
    }
}

# ============================================================
# Sub-check 4: winexist_cloaked
# Flags WinExist("ahk_id ...") in store/shared code
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$weIssues = [System.Collections.ArrayList]::new()
$weFiles = @($allFiles | Where-Object {
    $_.FullName -like "*\store\*" -or $_.FullName -like "*\shared\*"
})
$WE_SUPPRESSION = 'lint-ignore: winexist-cloaked'

foreach ($file in $weFiles) {
    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        if ($raw.Contains($WE_SUPPRESSION)) { continue }
        if ($raw -match '^\s*;') { continue }
        # Strip end-of-line comments preserving strings
        $cleaned = $raw
        $inStr = $false; $commentStart = -1
        for ($j = 0; $j -lt $cleaned.Length; $j++) {
            if ($cleaned[$j] -eq '"') { $inStr = -not $inStr }
            elseif (-not $inStr -and $cleaned[$j] -eq ';' -and $j -gt 0 -and $cleaned[$j - 1] -match '\s') {
                $commentStart = $j - 1; break
            }
        }
        if ($commentStart -ge 0) { $cleaned = $cleaned.Substring(0, $commentStart) }

        if ($cleaned -match 'WinExist\s*\([^)]*ahk_id') {
            [void]$weIssues.Add([PSCustomObject]@{
                File = $relPath; Line = ($i + 1); Text = $raw.TrimEnd()
            })
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_winexist_cloaked"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

if ($weIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($weIssues.Count) use(s) of WinExist() with hwnd lookup found.")
    [void]$failOutput.AppendLine("  WinExist('ahk_id ' hwnd) returns FALSE for cloaked windows.")
    [void]$failOutput.AppendLine("  Fix: use DllCall('user32\IsWindow', 'ptr', hwnd) instead.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: winexist-cloaked' on the same line.")
    $grouped = $weIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): $($issue.Text)")
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
    Write-Host "  PASS: All directive checks passed (requires, singleinstance, state_strings, winexist_cloaked)" -ForegroundColor Green
}

Write-Host "  Timing: total=$($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan

# Write sub-timing for nested display (consumed by static_analysis.ps1)
$subTimings | ConvertTo-Json -Compress | Set-Content "$env:TEMP\sa_batch_directives_timing.json" -Encoding UTF8

if ($anyFailed) { exit 1 }
exit 0
