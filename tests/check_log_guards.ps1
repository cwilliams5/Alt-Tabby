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
#   Store_LogInfo   -> cfg.DiagStoreLog
#   Launcher_Log    -> cfg.DiagLauncherLog
#   _IPC_Log        -> logEnabled or _IPC_IsLogEnabled()
#   _Update_Log     -> cfg.DiagUpdateLog
#   _IP_Log         -> _IP_DiagEnabled or logEnabled
#   _PP_Log         -> cfg.DiagProcPumpLog
#   _WEH_DiagLog    -> cfg.DiagWinEventLog
#   KSub_DiagLog    -> cfg.DiagKomorebiLog
#   _Viewer_Log     -> gViewer_LogPath
#   Store_LogError  -> EXEMPT (always-on, no config flag)
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
    'Store_LogInfo' = @('cfg.DiagStoreLog', 'DiagStoreLog')
    'Launcher_Log'  = @('cfg.DiagLauncherLog', 'DiagLauncherLog')
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
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    # Pre-compute brace depth at each line (O(n) per file, not O(n²) per call)
    $depthAt = [int[]]::new($lines.Count)
    $curDepth = 0
    for ($k = 0; $k -lt $lines.Count; $k++) {
        $depthAt[$k] = $curDepth
        $cl = Clean-Line $lines[$k]
        if ($cl -eq '') { continue }
        $st = Strip-Strings $cl
        foreach ($c in $st.ToCharArray()) {
            if ($c -eq '{') { $curDepth++ }
            elseif ($c -eq '}') { if ($curDepth -gt 0) { $curDepth-- } }
        }
    }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $rawLine = $lines[$i]
        $cleaned = Clean-Line $rawLine

        if ($cleaned -eq '') { continue }

        # Check if this line contains an enforced log function call
        $stripped = Strip-Strings $cleaned
        if ($stripped -notmatch $logCallPattern) { continue }

        $logFunc = $Matches[1]

        # Skip function DEFINITIONS
        if ($stripped -match "^\s*(?:static\s+)?$logFunc\s*\([^)]*\)\s*\{") { continue }
        if ($stripped -match "^\s*(?:static\s+)?$logFunc\s*\([^)]*\)\s*$") {
            if ($i + 1 -lt $lines.Count -and $lines[$i + 1] -match '^\s*\{') { continue }
        }

        # Only check calls with string concatenation
        if (-not (Has-Concatenation $rawLine $logFunc)) { continue }

        $callsChecked++

        # Check if this call is inside a guarded if-block.
        # Walk backwards through ALL enclosing blocks looking for a matching guard.
        $guardPatterns = $logGuards[$logFunc]
        $isGuarded = $false

        $callDepth = $depthAt[$i]
        $scanDepth = $callDepth
        for ($j = $i - 1; $j -ge 0 -and -not $isGuarded; $j--) {
            $prevCleaned = Clean-Line $lines[$j]
            if ($prevCleaned -eq '') { continue }

            $prevStripped = Strip-Strings $prevCleaned

            # Track depth going backwards (} adds, { subtracts)
            foreach ($c in $prevStripped.ToCharArray()) {
                if ($c -eq '}') { $scanDepth++ }
                elseif ($c -eq '{') { $scanDepth-- }
            }

            # Crossed into an outer block — check if it's a guarded if
            if ($scanDepth -lt $callDepth) {
                $linesToCheck = @($prevCleaned)
                if ($j -gt 0) {
                    $prevPrev = Clean-Line $lines[$j - 1]
                    if ($prevPrev -ne '') { $linesToCheck += $prevPrev }
                }

                foreach ($checkLine in $linesToCheck) {
                    if ($checkLine -match '^\s*if[\s(]') {
                        foreach ($guard in $guardPatterns) {
                            if ($checkLine.Contains($guard)) {
                                $isGuarded = $true
                                break
                            }
                        }
                        if ($isGuarded) { break }
                    }
                }

                $callDepth = $scanDepth
            }
        }

        # Check for braceless if-guard directly before the call
        # Pattern: if (guard)\n    LogFunc(...)
        if (-not $isGuarded) {
            for ($j = [Math]::Max(0, $i - 3); $j -lt $i; $j++) {
                $prevCleaned = Clean-Line $lines[$j]
                if ($prevCleaned -eq '') { continue }
                if ($prevCleaned -match '^\s*if[\s(]' -and $prevCleaned -notmatch '\{') {
                    foreach ($guard in $guardPatterns) {
                        if ($prevCleaned.Contains($guard)) {
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
