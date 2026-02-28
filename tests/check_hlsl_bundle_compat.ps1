# check_hlsl_bundle_compat.ps1 - Validate HLSL files are safe for AHK bundling
#
# HLSL shader sources are embedded into AHK continuation sections by
# tools/shader_bundle.ps1. Two HLSL patterns break AHK parsing:
#   1. Double quotes (") — terminates the AHK string literal early
#   2. Lines starting with ) — AHK interprets as continuation section closer
#
# Scoped to src/shaders/*.hlsl only.
#
# Usage: powershell -File tests\check_hlsl_bundle_compat.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all pass, 1 = any issue found

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

$shaderDir = Join-Path $SourceDir "shaders"
if (-not (Test-Path $shaderDir)) {
    Write-Host "  HLSL bundle compat: no src/shaders/ directory [PASS]" -ForegroundColor Green
    exit 0
}

$hlslFiles = @(Get-ChildItem -Path $shaderDir -Filter "*.hlsl")
if ($hlslFiles.Count -eq 0) {
    Write-Host "  HLSL bundle compat: no .hlsl files [PASS]" -ForegroundColor Green
    exit 0
}

# === Scan each HLSL file ===
$errors = @()

foreach ($file in $hlslFiles) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $relPath = "shaders\$($file.Name)"

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $lineNum = $i + 1

        # Check 1: Double quotes break AHK string continuation sections
        if ($line.Contains('"')) {
            $errors += "${relPath}:${lineNum}: contains double quote (breaks AHK continuation section)"
        }

        # Check 2: Line starting with ) closes AHK continuation section prematurely
        if ($line -match '^\s*\)') {
            $errors += "${relPath}:${lineNum}: line starts with ) (AHK interprets as continuation section closer)"
        }
    }
}

# === Report ===
if ($errors.Count -gt 0) {
    Write-Host "  FAIL: $($errors.Count) HLSL bundle compatibility issue(s):" -ForegroundColor Red
    foreach ($err in $errors) {
        Write-Host "    $err" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "  Fix: Remove double quotes from comments (use single quotes)." -ForegroundColor Yellow
    Write-Host "  Fix: Move ) to end of previous line (e.g., keep ); on same line as last arg)." -ForegroundColor Yellow
    exit 1
} else {
    Write-Host "  HLSL bundle compat: $($hlslFiles.Count) file(s) checked [PASS]" -ForegroundColor Green
    exit 0
}
