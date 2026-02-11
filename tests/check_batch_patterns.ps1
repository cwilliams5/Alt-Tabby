# check_batch_patterns.ps1 - Batched forbidden/outdated code pattern checks
# Combines 4 pattern checks into one PowerShell process to reduce startup overhead.
# Sub-checks: code_patterns, logging_hygiene, v1_patterns, send_patterns
#
# Usage: powershell -File tests\check_batch_patterns.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all pass, 1 = any check failed

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

# === Sub-check tracking ===
$subTimings = [System.Collections.ArrayList]::new()
$anyFailed = $false

# === Sub-check definitions ===
$subChecks = @(
    @{ Name = 'check_code_patterns';    Script = '_check_code_patterns.ps1' }
    @{ Name = 'check_logging_hygiene';  Script = '_check_logging_hygiene.ps1' }
    @{ Name = 'check_v1_patterns';      Script = '_check_v1_patterns.ps1' }
    @{ Name = 'check_send_patterns';    Script = '_check_send_patterns.ps1' }
)

foreach ($check in $subChecks) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = & "$PSScriptRoot\$($check.Script)" -SourceDir $SourceDir -BatchMode
    $sw.Stop()

    [void]$subTimings.Add(@{ Name = $check.Name; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

    if ($result -eq 1) {
        $anyFailed = $true
    }
}

# ============================================================
# Report
# ============================================================
$totalSw.Stop()

if ($anyFailed) {
    # Failure details already printed by sub-checks
    Write-Host ""
} else {
    Write-Host "  PASS: All pattern checks passed (code_patterns, logging_hygiene, v1_patterns, send_patterns)" -ForegroundColor Green
}

Write-Host "  Timing: total=$($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan

# Write sub-timing for nested display (consumed by static_analysis.ps1)
$subTimings | ConvertTo-Json -Compress | Set-Content "$env:TEMP\sa_batch_patterns_timing.json" -Encoding UTF8

if ($anyFailed) { exit 1 }
exit 0
