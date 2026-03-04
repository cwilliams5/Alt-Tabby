<#
.SYNOPSIS
    Convert all MP4s in captures/ to optimized GIFs for GitHub README.
.DESCRIPTION
    Uses ffmpeg two-pass palette generation for high-quality GIFs:
      - 15 fps (smooth enough for UI demos, small file size)
      - Max width 800px (lanczos downscale, height auto)
      - Per-frame palette diff (optimal for mostly-static UI recordings)
      - Floyd-Steinberg dithering
    Output: same filename with .gif extension alongside the .mp4.
.NOTES
    Requires ffmpeg on PATH (winget install Gyan.FFmpeg)
#>

param(
    [string]$Dir,
    [int]$Fps = 15,
    [int]$MaxWidth = 800
)

$ErrorActionPreference = 'Stop'

# Resolve captures directory
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

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    Write-Host "ffmpeg not found. Install: winget install Gyan.FFmpeg" -ForegroundColor Red
    exit 1
}

$mp4s = Get-ChildItem $capturesDir -Filter '*.mp4'
if ($mp4s.Count -eq 0) {
    Write-Host "No MP4s found in $capturesDir"
    exit 0
}

Write-Host "Converting $($mp4s.Count) MP4(s) to GIF in $capturesDir" -ForegroundColor Cyan
Write-Host "  Settings: ${Fps}fps, max ${MaxWidth}px wide, palette-optimized`n"

foreach ($mp4 in $mp4s) {
    $gifPath = [IO.Path]::ChangeExtension($mp4.FullName, '.gif')
    $gifName = [IO.Path]::GetFileNameWithoutExtension($mp4.Name) + '.gif'

    Write-Host "  $($mp4.Name) -> $gifName ... " -NoNewline

    # Single-command two-pass: generate palette + apply with dithering
    # scale=-1 = auto height preserving aspect ratio
    # stats_mode=diff = optimize palette for changing pixels (ideal for UI recordings)
    $filter = "fps=$Fps,scale='min($MaxWidth,iw)':-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=256:stats_mode=diff[p];[b][p]paletteuse=dither=floyd_steinberg"

    # ffmpeg writes progress to stderr; PS 5.1 treats stderr as errors when
    # ErrorActionPreference=Stop, even with 2>$null. Suppress temporarily.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & ffmpeg -i $mp4.FullName -filter_complex $filter -y $gifPath 2>$null
    $ErrorActionPreference = $prevEAP

    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAILED" -ForegroundColor Red
        continue
    }

    $mp4Size = $mp4.Length
    $gifSize = (Get-Item $gifPath).Length
    $ratio   = [math]::Round($gifSize / 1MB, 1)

    Write-Host "$($ratio)MB" -ForegroundColor Green
}

Write-Host "`nDone. GIFs are alongside MP4s in $capturesDir" -ForegroundColor Green
