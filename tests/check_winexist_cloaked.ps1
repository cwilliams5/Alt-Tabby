# check_winexist_cloaked.ps1 - Static analysis for WinExist() with hwnd lookups
# Pre-gate test: flags uses of WinExist("ahk_id ...") in store/producer code
# where DllCall("user32\IsWindow") should be used instead.
#
# WinExist("ahk_id " hwnd) returns FALSE for cloaked windows (hidden by DWM).
# Store and producer code must use DllCall("user32\IsWindow", "ptr", hwnd).
# GUI files are exempt since they work with already-filtered window lists.
#
# Usage: powershell -File tests\check_winexist_cloaked.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all clear, 1 = issues found

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

# === Collect files from store\ and shared\ only ===
$targetDirs = @('store', 'shared')
$files = @()
foreach ($dir in $targetDirs) {
    $dirPath = Join-Path $SourceDir $dir
    if (Test-Path $dirPath) {
        $files += @(Get-ChildItem -Path $dirPath -Filter "*.ahk" -Recurse)
    }
}

if ($files.Count -eq 0) {
    Write-Host "  No .ahk files found in store\ or shared\ subdirectories" -ForegroundColor Yellow
    exit 0
}

Write-Host "  Scanning $($files.Count) files for WinExist() with hwnd lookups..." -ForegroundColor Cyan

# === Suppression comment ===
$SUPPRESSION = 'lint-ignore: winexist-cloaked'

# === Scan files ===
$issues = [System.Collections.ArrayList]::new()

foreach ($file in $files) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        $lineNum = $i + 1

        # Check for suppression comment on the raw line (before any stripping)
        if ($raw.Contains($SUPPRESSION)) { continue }

        # Strip comments but preserve strings.
        # We only strip end-of-line comments (semicolon preceded by whitespace)
        # and full-line comments. We do NOT strip strings because the pattern
        # we're looking for ("ahk_id") appears inside string literals.
        $cleaned = $raw
        # Skip full-line comments
        if ($cleaned -match '^\s*;') { continue }
        # Strip end-of-line comments: find '; ' that is not inside a string
        # Simple approach: remove everything after ' ;' that follows a non-quote context
        # For robustness, strip trailing comment by finding last ' ;' outside quotes
        $inStr = $false
        $commentStart = -1
        for ($j = 0; $j -lt $cleaned.Length; $j++) {
            if ($cleaned[$j] -eq '"') {
                $inStr = -not $inStr
            }
            elseif (-not $inStr -and $cleaned[$j] -eq ';' -and $j -gt 0 -and $cleaned[$j - 1] -match '\s') {
                $commentStart = $j - 1
                break
            }
        }
        if ($commentStart -ge 0) {
            $cleaned = $cleaned.Substring(0, $commentStart)
        }

        # Pattern 1: WinExist("ahk_id  (with optional whitespace variations)
        # Pattern 2: WinExist( ... ahk_id ... ) on the same line
        # Both patterns: WinExist followed by ( and ahk_id somewhere before )
        if ($cleaned -match 'WinExist\s*\([^)]*ahk_id') {
            [void]$issues.Add([PSCustomObject]@{
                File = $relPath
                Line = $lineNum
                Text = $raw.TrimEnd()
            })
        }
    }
}

$totalSw.Stop()

# === Report ===
$timingLine = "  Timing: total=$($totalSw.ElapsedMilliseconds)ms"
$statsLine  = "  Stats:  $($files.Count) files scanned, $($issues.Count) issue(s) found"

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "  FAIL: $($issues.Count) use(s) of WinExist() with hwnd lookup found." -ForegroundColor Red
    Write-Host "  WinExist('ahk_id ' hwnd) returns FALSE for cloaked windows." -ForegroundColor Red
    Write-Host "  Fix: use DllCall('user32\IsWindow', 'ptr', hwnd) instead." -ForegroundColor Yellow
    Write-Host "  Suppress: add '; lint-ignore: winexist-cloaked' on the same line." -ForegroundColor Yellow

    $grouped = $issues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        Write-Host "`n    $($group.Name):" -ForegroundColor Yellow
        foreach ($issue in $group.Group | Sort-Object Line) {
            Write-Host "      Line $($issue.Line): $($issue.Text)" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 1
} else {
    Write-Host "  PASS: No WinExist() with hwnd lookups in store/shared code" -ForegroundColor Green
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 0
}
