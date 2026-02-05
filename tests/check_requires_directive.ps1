# check_requires_directive.ps1 - Static analysis for missing #Requires directive
# Pre-gate test: runs before any AHK process launches.
# Ensures every .ahk source file declares #Requires AutoHotkey v2.0.
# Without it, a file could accidentally run under v1 on dual-install systems.
#
# Excluded: version_info.ahk (auto-generated compiler directives only)
#
# Usage: powershell -File tests\check_requires_directive.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all clear, 1 = missing directives found

param(
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

# === Exclusions ===

# Files that don't contain executable AHK code
$EXCLUDED_FILES = @(
    'version_info.ahk'
)

# === Resolve source directory ===

if (-not $SourceDir) {
    $SourceDir = (Resolve-Path "$PSScriptRoot\..\src").Path
}
if (-not (Test-Path $SourceDir)) {
    Write-Host "  ERROR: Source directory not found: $SourceDir" -ForegroundColor Red
    exit 1
}

# === Scan ===

$files = @(Get-ChildItem -Path $SourceDir -Recurse -Filter '*.ahk' |
    Where-Object { $_.FullName -notlike "*\lib\*" })
$issues = @()

foreach ($file in $files) {
    # Skip excluded files
    if ($EXCLUDED_FILES -contains $file.Name) { continue }

    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $found = $false

    # Check all lines for #Requires directive (usually line 1, but could be after comments)
    foreach ($line in $lines) {
        if ($line -match '^\s*#Requires\s+AutoHotkey\s+v2') {
            $found = $true
            break
        }
        # Stop searching after first non-comment, non-blank, non-directive line
        # (directives must appear before code)
        if ($line -match '^\s*[^;#\s]' -and $line -notmatch '^\s*;') {
            break
        }
    }

    if (-not $found) {
        $relPath = $file.FullName
        if ($relPath.StartsWith($SourceDir)) {
            $relPath = $relPath.Substring($SourceDir.Length).TrimStart('\', '/')
        }
        $issues += $relPath
    }
}

$totalSw.Stop()

# === Report ===

$timingLine = "  Timing: total=$($totalSw.ElapsedMilliseconds)ms"
$statsLine  = "  Stats:  $($files.Count) files scanned, $($issues.Count) missing"

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "  FAIL: $($issues.Count) file(s) missing #Requires AutoHotkey v2.0" -ForegroundColor Red
    Write-Host "  Add as the first line: #Requires AutoHotkey v2.0" -ForegroundColor Red
    Write-Host ""
    foreach ($f in $issues | Sort-Object) {
        Write-Host "    $f" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 1
} else {
    Write-Host "  PASS: All files have #Requires AutoHotkey v2.0" -ForegroundColor Green
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 0
}
