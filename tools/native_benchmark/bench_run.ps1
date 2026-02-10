<#
.SYNOPSIS
    Runs all native optimization benchmarks and collects results.

.DESCRIPTION
    Executes each bench_*.ahk file via AutoHotkey64.exe, captures output,
    and writes combined results to bench_results.txt.

.PARAMETER Filter
    Optional: run only benchmarks matching this pattern (e.g., "utf8", "alpha")

.PARAMETER Runs
    Number of runs per benchmark (default: 3). Reports are per-run.

.EXAMPLE
    .\bench_run.ps1
    .\bench_run.ps1 -Filter utf8
    .\bench_run.ps1 -Runs 5
#>
param(
    [string]$Filter = "",
    [int]$Runs = 3
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Find AutoHotkey
$ahk = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
if (-not (Test-Path $ahk)) {
    $ahk = Get-Command AutoHotkey64.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
    if (-not $ahk) {
        Write-Error "AutoHotkey64.exe not found. Install AHK v2 or add to PATH."
        exit 1
    }
}

# Discover benchmarks
$benchFiles = Get-ChildItem "$scriptDir\bench_*.ahk" | Where-Object { $_.Name -ne "bench_common.ahk" } | Sort-Object Name
if ($Filter) {
    $benchFiles = $benchFiles | Where-Object { $_.Name -match $Filter }
}

if ($benchFiles.Count -eq 0) {
    Write-Host "No benchmark files found matching filter '$Filter'" -ForegroundColor Yellow
    exit 0
}

$resultsFile = Join-Path $scriptDir "bench_results.txt"
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# Header
$header = @"
================================================================================
Native Optimization Benchmark Results
Date: $timestamp
AHK:  $ahk
Runs: $Runs per benchmark
Host: $($env:COMPUTERNAME) / $($env:PROCESSOR_IDENTIFIER)
================================================================================

"@

Set-Content $resultsFile $header
Write-Host $header

foreach ($bench in $benchFiles) {
    $name = $bench.BaseName
    Write-Host "`n--- $name ---" -ForegroundColor Cyan

    for ($run = 1; $run -le $Runs; $run++) {
        Write-Host "  Run $run/$Runs... " -NoNewline

        $runHeader = "`n--- $name (Run $run/$Runs) ---`n"
        Add-Content $resultsFile $runHeader

        try {
            $output = & $ahk /ErrorStdOut $bench.FullName 2>&1
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) {
                $errMsg = "  FAILED (exit code $exitCode)"
                Write-Host $errMsg -ForegroundColor Red
                Add-Content $resultsFile "FAILED (exit code $exitCode)"
                Add-Content $resultsFile ($output | Out-String)
            } else {
                Write-Host "OK" -ForegroundColor Green
                $text = $output | Out-String
                Add-Content $resultsFile $text
            }
        } catch {
            $errMsg = "  ERROR: $_"
            Write-Host $errMsg -ForegroundColor Red
            Add-Content $resultsFile "ERROR: $_"
        }
    }
}

Write-Host "`n================" -ForegroundColor Green
Write-Host "Results written to: $resultsFile" -ForegroundColor Green
Write-Host "================" -ForegroundColor Green
