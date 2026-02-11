# check_log_guards.ps1 - Caller-side log guard enforcement
# AHK v2 evaluates ALL function arguments BEFORE the call. A guard inside the log
# function is too late - the string concatenation is already done. Wrapping in a
# caller-side if-guard eliminates the wasted work unconditionally.
#
# Only flags log calls with STRING CONCATENATION in arguments (the performance cost).
# Pure literal-string calls like LogFunc("static message") are fine unguarded.
#
# Log function -> required guard:
#   GUI_LogEvent    -> cfg.DiagEventLog
#   Paint_Log       -> cfg.DiagPaintTimingLog
#   _Store_LogInfo  -> cfg.DiagStoreLog
#   _Launcher_Log   -> cfg.DiagLauncherLog
#   _IPC_Log        -> logEnabled or _IPC_IsLogEnabled()
#   _Update_Log     -> cfg.DiagUpdateLog
#   _IP_Log         -> _IP_DiagEnabled or logEnabled
#   _PP_Log         -> cfg.DiagProcPumpLog
#   _WEH_DiagLog    -> cfg.DiagWinEventLog
#   KSub_DiagLog    -> cfg.DiagKomorebiLog
#   _Viewer_Log     -> gViewer_LogPath
#   _Store_LogError -> EXEMPT (always-on, no config flag)
#
# No lint-ignore suppression. If a log function has a config flag and the call
# has concatenation, it must be guarded. No exceptions.
#
# Usage: powershell -File tests\check_log_guards.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all clear, 1 = unguarded log calls found

param(
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

# === Log function -> acceptable guard patterns ===
$logGuards = @{
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

# Build regex matching enforced log functions
$logCallPattern = '(?<!\w)(' + ($logGuards.Keys -join '|') + ')\s*\('

# All log function names for file-level pre-filter
$allLogFuncNames = [string[]]@($logGuards.Keys)

# === Helpers ===
function Clean-Line {
    param([string]$line)
    if ($line -match '^\s*;') { return '' }
    $cleaned = $line -replace '\s;.*$', ''
    return $cleaned
}

function Strip-Strings {
    param([string]$line)
    $stripped = $line -replace '"[^"]*"', '""'
    $stripped = $stripped -replace "'[^']*'", "''"
    return $stripped
}

function Has-Concatenation {
    param([string]$rawLine, [string]$funcName)

    $idx = $rawLine.IndexOf("$funcName(")
    if ($idx -lt 0) { return $false }
    $argStart = $idx + $funcName.Length + 1
    if ($argStart -ge $rawLine.Length) { return $false }
    $argPart = $rawLine.Substring($argStart)

    # Find matching closing paren
    $depth = 1
    $end = 0
    for ($k = 0; $k -lt $argPart.Length; $k++) {
        $c = $argPart[$k]
        if ($c -eq '(') { $depth++ }
        elseif ($c -eq ')') {
            $depth--
            if ($depth -eq 0) { $end = $k; break }
        }
    }
    if ($end -gt 0) {
        $argPart = $argPart.Substring(0, $end)
    }

    $argTrimmed = $argPart.Trim()

    # Pure string literal — no concat overhead
    if ($argTrimmed -match '^"[^"]*"$') { return $false }

    # No quotes at all — variable reference (concat)
    if ($argTrimmed -notmatch '"') { return $true }

    # Mixed: remove quoted strings, check for remaining identifiers
    $withoutStrings = $argTrimmed -replace '"[^"]*"', ''
    $withoutStrings = $withoutStrings.Trim()
    if ($withoutStrings -match '[A-Za-z_]\w*') { return $true }

    return $false
}

# === Resolve source directory ===
if (-not $SourceDir) {
    $SourceDir = (Resolve-Path "$PSScriptRoot\..\src").Path
}
if (-not (Test-Path $SourceDir)) {
    Write-Host "  ERROR: Source directory not found: $SourceDir" -ForegroundColor Red
    exit 1
}

$projectRoot = (Resolve-Path "$SourceDir\..").Path

# ============================================================
# Scan
# ============================================================
$scanSw = [System.Diagnostics.Stopwatch]::StartNew()
$issues = [System.Collections.ArrayList]::new()
$callsChecked = 0

$files = @(Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse |
    Where-Object { $_.FullName -notlike "*\lib\*" })

foreach ($file in $files) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)

    # File-level pre-filter: skip files without any enforced log function
    $hasLogFunc = $false
    $joined = [string]::Join("`n", $lines)
    foreach ($fn in $allLogFuncNames) {
        if ($joined.Contains($fn)) { $hasLogFunc = $true; break }
    }
    if (-not $hasLogFunc) { continue }

    $relPath = $file.FullName.Replace("$projectRoot\", '')

    # Forward guard stack: tracks enclosing if-blocks with guard conditions.
    # Each entry: @{ depth = <int>; line = <string> }
    # An entry at depth D means "code at depth > D is inside this guard".
    # Pop when depth drops to <= D (block closed).
    $guardStack = [System.Collections.ArrayList]::new()
    $currentDepth = 0
    $prevCleanedLine = ''

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $rawLine = $lines[$i]
        $cleaned = Clean-Line $rawLine
        if ($cleaned -eq '') { continue }
        $stripped = Strip-Strings $cleaned

        # Count braces
        $opens = 0; $closes = 0
        foreach ($c in $stripped.ToCharArray()) {
            if ($c -eq '{') { $opens++ }
            elseif ($c -eq '}') { $closes++ }
        }

        # Depth after closing braces, before opening braces
        $depthAfterClose = $currentDepth - $closes
        if ($depthAfterClose -lt 0) { $depthAfterClose = 0 }

        # Pop guards whose blocks have closed
        while ($guardStack.Count -gt 0 -and $depthAfterClose -le $guardStack[$guardStack.Count - 1].depth) {
            $guardStack.RemoveAt($guardStack.Count - 1)
        }

        # If a block opens ({ on this line), check if it's a guarded if.
        # Check this line and the previous non-empty line (for multi-line if conditions).
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
        if ($stripped -notmatch $logCallPattern) {
            $prevCleanedLine = $cleaned
            continue
        }

        $logFunc = $Matches[1]

        # Skip function DEFINITIONS
        if ($stripped -match "^\s*(?:static\s+)?$logFunc\s*\([^)]*\)\s*\{") {
            $prevCleanedLine = $cleaned
            continue
        }
        if ($stripped -match "^\s*(?:static\s+)?$logFunc\s*\([^)]*\)\s*$") {
            if ($i + 1 -lt $lines.Count -and $lines[$i + 1] -match '^\s*\{') {
                $prevCleanedLine = $cleaned
                continue
            }
        }

        # Only check calls with string concatenation
        if (-not (Has-Concatenation $rawLine $logFunc)) {
            $prevCleanedLine = $cleaned
            continue
        }

        $callsChecked++

        $guardPatterns = $logGuards[$logFunc]
        $isGuarded = $false

        # Check forward-built guard stack (O(1) — stack is typically 0-3 entries)
        for ($s = 0; $s -lt $guardStack.Count; $s++) {
            foreach ($guard in $guardPatterns) {
                if ($guardStack[$s].line.Contains($guard)) {
                    $isGuarded = $true
                    break
                }
            }
            if ($isGuarded) { break }
        }

        # Braceless guard: look back 1-3 lines (fixed O(1) cost)
        # Pattern: if (guard)\n    LogFunc(...)
        if (-not $isGuarded) {
            for ($j = [Math]::Max(0, $i - 3); $j -lt $i; $j++) {
                $prevCl = Clean-Line $lines[$j]
                if ($prevCl -eq '') { continue }
                if ($prevCl -match '(?:^|\belse\s+)\s*if[\s(]' -and $prevCl -notmatch '\{') {
                    foreach ($guard in $guardPatterns) {
                        if ($prevCl.Contains($guard)) {
                            $isGuarded = $true
                            break
                        }
                    }
                    if ($isGuarded) { break }
                }
            }
        }

        if (-not $isGuarded) {
            [void]$issues.Add([PSCustomObject]@{
                File     = $relPath
                Line     = $i + 1
                Function = $logFunc
                Code     = $rawLine.Trim()
            })
        }

        $prevCleanedLine = $cleaned
    }
}
$scanSw.Stop()
$totalSw.Stop()

# ============================================================
# Report
# ============================================================
$timingLine = "  Timing: scan=$($scanSw.ElapsedMilliseconds)ms  total=$($totalSw.ElapsedMilliseconds)ms"
$statsLine  = "  Stats:  $callsChecked log call(s) with concatenation checked, $($files.Count) file(s) scanned"

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "  FAIL: $($issues.Count) unguarded log call(s) with string concatenation found." -ForegroundColor Red
    Write-Host "  AHK v2 evaluates arguments BEFORE the call - string concatenation runs" -ForegroundColor Red
    Write-Host "  unconditionally. Wrap log calls in caller-side if-guards." -ForegroundColor Red

    $grouped = $issues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        Write-Host ""
        Write-Host "    $($group.Name):" -ForegroundColor Yellow
        foreach ($issue in $group.Group | Sort-Object Line) {
            Write-Host "      Line $($issue.Line): $($issue.Function)() missing guard" -ForegroundColor Red
            Write-Host "        $($issue.Code)" -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 1
} else {
    Write-Host "  PASS: All log calls with concatenation have caller-side guards" -ForegroundColor Green
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 0
}
