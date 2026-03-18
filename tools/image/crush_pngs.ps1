<#
.SYNOPSIS
    Crush all PNGs in captures/ for minimum file size.
.DESCRIPTION
    Two-pass optimization:
      1. pngquant  (lossy) — palette reduction, visually lossless for UI screenshots
      2. oxipng    (lossless) — bit-level squeeze on the pngquant output
    Skips files already ending in -fs8.png (pngquant output suffix).
.NOTES
    Install dependencies:
      winget install pngquant
      cargo install oxipng
#>

param(
    [string]$Dir
)

$ErrorActionPreference = 'Stop'

# Resolve captures directory (same logic as _Capture_GetDir)
if ($Dir) {
    $capturesDir = $Dir
} else {
    $capturesDir = Join-Path $PSScriptRoot '..\release\captures'
}
$resolved = Resolve-Path $capturesDir -ErrorAction SilentlyContinue
$capturesDir = if ($resolved) { $resolved.Path } else { $null }
if (-not $capturesDir -or -not (Test-Path $capturesDir)) {
    Write-Host "No captures directory found at: $(Join-Path $PSScriptRoot '..\release\captures')" -ForegroundColor Yellow
    Write-Host "  Pass -Dir <path> to specify a different directory."
    exit 0
}

# Check dependencies
$hasPngquant = Get-Command pngquant -ErrorAction SilentlyContinue
$hasOxipng   = Get-Command oxipng   -ErrorAction SilentlyContinue

if (-not $hasPngquant -and -not $hasOxipng) {
    Write-Host "No PNG optimization tools found. Install at least one:" -ForegroundColor Red
    Write-Host "  winget install pngquant"
    Write-Host "  cargo install oxipng"
    exit 1
}

$pngs = Get-ChildItem $capturesDir -Filter '*.png' | Where-Object { $_.Name -notmatch '-fs8\.png$' }
if ($pngs.Count -eq 0) {
    Write-Host "No PNGs found in $capturesDir"
    exit 0
}

Write-Host "Crushing $($pngs.Count) PNG(s) in $capturesDir" -ForegroundColor Cyan
$totalBefore = 0
$totalAfter  = 0

foreach ($png in $pngs) {
    $sizeBefore = $png.Length
    $totalBefore += $sizeBefore

    # Pass 1: pngquant (lossy palette reduction)
    if ($hasPngquant) {
        & pngquant --quality=80-100 --skip-if-larger --force --ext .png -- $png.FullName 2>$null
    }

    # Pass 2: oxipng (lossless bit-level optimization)
    if ($hasOxipng) {
        & oxipng -o 4 --strip safe -q $png.FullName 2>$null
    }

    # Re-read size after optimization
    $sizeAfter = (Get-Item $png.FullName).Length
    $totalAfter += $sizeAfter
    $pct = if ($sizeBefore -gt 0) { [math]::Round((1 - $sizeAfter / $sizeBefore) * 100, 1) } else { 0 }

    $sizeStr = "{0,8:N0} -> {1,8:N0}  ({2}%)" -f $sizeBefore, $sizeAfter, $pct
    Write-Host "  $($png.Name)  $sizeStr"
}

$totalPct = if ($totalBefore -gt 0) { [math]::Round((1 - $totalAfter / $totalBefore) * 100, 1) } else { 0 }
Write-Host "`nTotal: $([math]::Round($totalBefore/1KB))KB -> $([math]::Round($totalAfter/1KB))KB  ($totalPct% saved)" -ForegroundColor Green
