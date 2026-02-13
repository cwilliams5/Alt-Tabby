# query_timers.ps1 - Timer inventory
#
# Shows all SetTimer calls across the codebase with callback, interval,
# enclosing function, and file location.
#
# Usage:
#   powershell -File tests/query_timers.ps1               (full inventory)
#   powershell -File tests/query_timers.ps1 heartbeat      (fuzzy search)

param(
    [Parameter(Position=0)]
    [string]$Search
)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$projectRoot = Split-Path $PSScriptRoot -Parent
$srcDir = Join-Path $projectRoot "src"

$ahkKeywords = @('if','else','while','for','loop','switch','case','catch','finally',
    'try','return','throw','not','and','or','is','in','contains','isset',
    'class','static','global','local','until','new','super','this','true','false','unset')

# === Collect source files (exclude lib/) ===
$allFiles = @(Get-ChildItem -Path $srcDir -Filter *.ahk -Recurse |
    Where-Object { $_.FullName -notlike "*\lib\*" })

# === Scan for SetTimer calls ===
$timers = [System.Collections.ArrayList]::new()

foreach ($file in $allFiles) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)

    # File-level pre-filter: skip files without SetTimer
    $found = $false
    foreach ($ln in $lines) {
        if ($ln.IndexOf('SetTimer', [StringComparison]::OrdinalIgnoreCase) -ge 0) { $found = $true; break }
    }
    if (-not $found) { continue }

    $relPath = $file.FullName.Replace("$projectRoot\", '')

    # Pre-build function boundary map for this file
    $funcBounds = [System.Collections.ArrayList]::new()
    for ($j = 0; $j -lt $lines.Count; $j++) {
        if ($lines[$j] -match '^(\w+)\s*\(') {
            $candidate = $Matches[1]
            if ($candidate.ToLower() -in $ahkKeywords) { continue }
            $hasBody = $lines[$j].Contains('{')
            if (-not $hasBody) {
                for ($k = $j + 1; $k -lt [Math]::Min($j + 3, $lines.Count); $k++) {
                    $next = $lines[$k].Trim()
                    if ($next -eq '') { continue }
                    if ($next -eq '{' -or $next.StartsWith('{')) { $hasBody = $true }
                    break
                }
            }
            if ($hasBody) { [void]$funcBounds.Add(@{ Name = $candidate; Line = $j }) }
        }
    }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $trimmed = $lines[$i].Trim()
        if ($trimmed.Length -eq 0 -or $trimmed[0] -eq ';') { continue }

        # Match SetTimer( or SetTimer  (with paren or space)
        if ($trimmed -notmatch '\bSetTimer\s*[\(,]') { continue }

        # Extract callback and interval from the SetTimer call
        $callback = ""
        $interval = ""
        $timerType = "start"

        # Pattern: SetTimer(callback, interval) or SetTimer(callback)
        # Callback can be: FuncName, _FuncName, ObjBindMethod(...), () => ..., func.Bind(...)
        if ($trimmed -match 'SetTimer\s*\(\s*([^,\)]+?)(?:\s*,\s*([^)]+))?\s*\)') {
            $callback = $Matches[1].Trim()
            if ($Matches[2]) {
                $interval = $Matches[2].Trim()
            }
        }

        # Classify timer type
        if ($interval -eq '0') {
            $timerType = "stop"
        } elseif ($interval -match '^\s*-') {
            $timerType = "one-shot"
        } elseif ($interval -eq '' -or $interval -match '^\d') {
            $timerType = "start"
        } else {
            # Variable interval - could be start or stop
            $timerType = "dynamic"
        }

        # Find enclosing function via pre-built boundary map
        $funcName = "(file scope)"
        for ($b = $funcBounds.Count - 1; $b -ge 0; $b--) {
            if ($funcBounds[$b].Line -le $i) { $funcName = $funcBounds[$b].Name; break }
        }

        $lineNum = $i + 1
        [void]$timers.Add(@{
            File     = $relPath
            Line     = $lineNum
            Callback = $callback
            Interval = $interval
            Type     = $timerType
            Func     = $funcName
            _cb = $callback.ToLower(); _iv = $interval.ToLower()
            _fl = $relPath.ToLower(); _fn = $funcName.ToLower()
            _tp = $timerType.ToLower()
        })
    }
}

# === Filter by search term ===
if ($Search) {
    $searchLower = $Search.ToLower()
    $filtered = [System.Collections.ArrayList]::new()
    foreach ($t in $timers) {
        if ($t._cb.Contains($searchLower) -or
            $t._iv.Contains($searchLower) -or
            $t._fl.Contains($searchLower) -or
            $t._fn.Contains($searchLower) -or
            $t._tp.Contains($searchLower)) {
            [void]$filtered.Add($t)
        }
    }
    $timers = $filtered
}

# === Output ===
if ($timers.Count -eq 0) {
    if ($Search) {
        Write-Host "`n  No timers matching: '$Search'" -ForegroundColor Red
    } else {
        Write-Host "`n  No SetTimer calls found" -ForegroundColor Red
    }
    $elapsed = $sw.ElapsedMilliseconds
    Write-Host "  Completed in ${elapsed}ms" -ForegroundColor DarkGray
    exit 1
}

$title = if ($Search) { "Timers matching '$Search'" } else { "Timer Inventory" }
Write-Host ""
Write-Host "  $title ($($timers.Count) calls):" -ForegroundColor White
Write-Host ""

# Group by file
$grouped = $timers | Group-Object { $_.File } | Sort-Object Name

# Calculate column widths
$maxCallback = 10
$maxInterval = 8
$maxType = 8
$maxFunc = 10
foreach ($t in $timers) {
    if ($t.Callback.Length -gt $maxCallback) { $maxCallback = $t.Callback.Length }
    if ($t.Interval.Length -gt $maxInterval) { $maxInterval = $t.Interval.Length }
    if ($t.Type.Length -gt $maxType) { $maxType = $t.Type.Length }
    if ($t.Func.Length -gt $maxFunc) { $maxFunc = $t.Func.Length }
}
# Cap widths for readability
if ($maxCallback -gt 40) { $maxCallback = 40 }
if ($maxFunc -gt 30) { $maxFunc = 30 }

foreach ($group in $grouped) {
    Write-Host "  $($group.Name)" -ForegroundColor Cyan
    $sorted = $group.Group | Sort-Object { $_.Line }
    foreach ($t in $sorted) {
        $cb = $t.Callback
        if ($cb.Length -gt 40) { $cb = $cb.Substring(0, 37) + "..." }
        $cbPad = $cb.PadRight($maxCallback + 2)

        $intPad = $t.Interval.PadRight($maxInterval + 2)

        $typeColor = switch ($t.Type) {
            "start"    { "Green" }
            "stop"     { "DarkGray" }
            "one-shot" { "Yellow" }
            "dynamic"  { "Magenta" }
            default    { "White" }
        }
        $typePad = $t.Type.PadRight($maxType + 2)

        $loc = ":$($t.Line)"
        Write-Host -NoNewline "    $cbPad" -ForegroundColor Green
        Write-Host -NoNewline "$intPad" -ForegroundColor White
        Write-Host -NoNewline "$typePad" -ForegroundColor $typeColor
        Write-Host -NoNewline "in $($t.Func)" -ForegroundColor DarkGray
        Write-Host " $loc" -ForegroundColor DarkGray
    }
}

Write-Host ""
$elapsed = $sw.ElapsedMilliseconds
Write-Host "  Completed in ${elapsed}ms" -ForegroundColor DarkGray
