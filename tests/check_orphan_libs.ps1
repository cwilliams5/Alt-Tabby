# check_orphan_libs.ps1 - Detect unreferenced files in src/lib/
#
# Every .ahk file in src/lib/ must be #Include'd by at least one file in src/.
# Internal lib-to-lib includes count (e.g., Direct2D.ahk includes ctypes.ahk).
# Orphans should be moved to reference/ or removed.
#
# Usage: powershell -File tests\check_orphan_libs.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all pass, 1 = orphan(s) found

param(
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'

# === Resolve source directory ===
if (-not $SourceDir) {
    $SourceDir = (Resolve-Path "$PSScriptRoot\..\src").Path
}
if (-not (Test-Path $SourceDir)) {
    Write-Host "  ERROR: Source directory not found: $SourceDir" -ForegroundColor Red
    exit 1
}

$libDir = Join-Path $SourceDir "lib"
if (-not (Test-Path $libDir)) {
    Write-Host "  Orphan libs: no src/lib/ directory [PASS]" -ForegroundColor Green
    exit 0
}

# === Collect lib files ===
$libFiles = @(Get-ChildItem -Path $libDir -Filter "*.ahk" -Recurse)
if ($libFiles.Count -eq 0) {
    Write-Host "  Orphan libs: no .ahk files in src/lib/ [PASS]" -ForegroundColor Green
    exit 0
}

# === Collect all source files (including lib/) ===
$allSrcFiles = @(Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse)

# === For each lib file, check if any source file #Include's it ===
$orphans = @()

foreach ($lib in $libFiles) {
    $libName = $lib.Name
    $found = $false

    foreach ($src in $allSrcFiles) {
        # Don't count self-references
        if ($src.FullName -eq $lib.FullName) { continue }

        $lines = [System.IO.File]::ReadAllLines($src.FullName)
        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if (-not $trimmed.StartsWith('#Include')) { continue }
            # Check if this #Include references the lib file by name
            if ($trimmed -match [regex]::Escape($libName)) {
                $found = $true
                break
            }
        }
        if ($found) { break }
    }

    if (-not $found) {
        $orphans += $lib.FullName.Replace("$SourceDir\", '')
    }
}

# === Report ===
if ($orphans.Count -gt 0) {
    Write-Host "  FAIL: $($orphans.Count) lib file(s) not referenced by any #Include directive:" -ForegroundColor Red
    foreach ($f in $orphans | Sort-Object) {
        Write-Host "    ORPHAN: $f" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "  Fix: Move unused libs to reference/ or add a #Include directive." -ForegroundColor Yellow
    exit 1
} else {
    Write-Host "  Orphan libs: all $($libFiles.Count) lib files referenced [PASS]" -ForegroundColor Green
    exit 0
}
