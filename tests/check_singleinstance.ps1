# check_singleinstance.ps1 - Multi-process model protection
# Ensures entry point has #SingleInstance Off and module files have no #SingleInstance directive.
# Alt-Tabby uses a single exe for multiple process modes (launcher, store, gui, viewer).
# If a module file adds #SingleInstance Force, it could kill sibling processes.
#
# Rules:
#   1. src/alt_tabby.ahk MUST contain #SingleInstance Off
#   2. All other src/**/*.ahk (except src/lib/, standalone entry points) MUST NOT contain #SingleInstance
#
# Standalone entry points (separate processes, not #Include'd by alt_tabby.ahk):
#   - src/editors/config_registry_editor.ahk
#
# Usage: powershell -File tests\check_singleinstance.ps1 [-SourceDir "path\to\src"]
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

# === Standalone entry points (exempt from "no directive" rule) ===
$standaloneEntryPoints = @(
    (Join-Path $SourceDir "editors\config_registry_editor.ahk")
    (Join-Path $SourceDir "store\store_server.ahk")
)

# ============================================================
# Scan
# ============================================================
$scanSw = [System.Diagnostics.Stopwatch]::StartNew()
$issues = [System.Collections.ArrayList]::new()
$filesScanned = 0

$entryPoint = Join-Path $SourceDir "alt_tabby.ahk"

# Rule 1: Entry point must have #SingleInstance Off
$entryPointOk = $false
if (Test-Path $entryPoint) {
    $lines = [System.IO.File]::ReadAllLines($entryPoint)
    foreach ($line in $lines) {
        if ($line -match '^\s*#SingleInstance\s+Off') {
            $entryPointOk = $true
            break
        }
    }
    if (-not $entryPointOk) {
        $relPath = $entryPoint.Replace("$projectRoot\", '')
        [void]$issues.Add([PSCustomObject]@{
            File    = $relPath
            Line    = 0
            Message = "Entry point missing '#SingleInstance Off'"
            Rule    = "required"
        })
    }
} else {
    [void]$issues.Add([PSCustomObject]@{
        File    = "src\alt_tabby.ahk"
        Line    = 0
        Message = "Entry point file not found"
        Rule    = "required"
    })
}

# Rule 2: Module files must not have any #SingleInstance directive
$files = @(Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse |
    Where-Object {
        $_.FullName -notlike "*\lib\*" -and
        $_.FullName -ne $entryPoint -and
        $_.FullName -notin $standaloneEntryPoints
    })

foreach ($file in $files) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $filesScanned++

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        # Skip full-line comments (the directive itself wouldn't be in a comment)
        # But DO check comments that mention #SingleInstance as actual directives
        # AHK treats #SingleInstance as a directive even without ; prefix
        # Only skip lines where ; is the FIRST non-whitespace char
        if ($line -match '^\s*;') { continue }

        # Check for lint-ignore suppression
        if ($line -match 'lint-ignore:\s*singleinstance') { continue }

        # Match any #SingleInstance directive (Force, Ignore, Off)
        if ($line -match '^\s*#SingleInstance') {
            [void]$issues.Add([PSCustomObject]@{
                File    = $relPath
                Line    = $i + 1
                Message = "Module file has directive: $($line.Trim())"
                Rule    = "forbidden"
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
$statsLine  = "  Stats:  $filesScanned module files scanned"

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "  FAIL: $($issues.Count) #SingleInstance issue(s) found." -ForegroundColor Red
    Write-Host "  Entry point needs #SingleInstance Off; module files must not have any #SingleInstance directive." -ForegroundColor Red
    Write-Host "  Suppress: add '; lint-ignore: singleinstance' on the directive line." -ForegroundColor Yellow

    $grouped = $issues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        Write-Host ""
        Write-Host "    $($group.Name):" -ForegroundColor Yellow
        foreach ($issue in $group.Group | Sort-Object Line) {
            if ($issue.Line -gt 0) {
                Write-Host "      Line $($issue.Line): $($issue.Message)" -ForegroundColor Red
            } else {
                Write-Host "      $($issue.Message)" -ForegroundColor Red
            }
        }
    }

    Write-Host ""
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 1
} else {
    Write-Host "  PASS: #SingleInstance directives correctly placed" -ForegroundColor Green
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 0
}
