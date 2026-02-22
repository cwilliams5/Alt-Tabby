# static_analysis.ps1 - Parallel dispatcher for static analysis checks
# Discovers and runs all check_*.ps1 scripts in the tests/ directory,
# plus hardcoded dual-duty query tools in tools/ (invoked with -Check).
# All checks launch in parallel; wall-clock time = slowest check.
# Exit codes: 0 = all pass, 1 = any check failed
#
# To add a new check: create tests/check_<name>.ps1 that accepts
# -SourceDir and exits 0 (pass) or 1 (fail). It will be auto-discovered.
#
# Usage: powershell -File tests\static_analysis.ps1 [-SourceDir "path\to\src"]

param(
    [string]$SourceDir,
    [switch]$Timing
)

$ErrorActionPreference = 'Stop'

if (-not $SourceDir) {
    $SourceDir = (Resolve-Path "$PSScriptRoot\..\src").Path
}
if (-not (Test-Path $SourceDir)) {
    Write-Host "  ERROR: Source directory not found: $SourceDir" -ForegroundColor Red
    exit 1
}

# Auto-discover check scripts in tests/
$checks = @(Get-ChildItem "$PSScriptRoot\check_*.ps1" | Sort-Object Name)

# Hardcoded dual-duty query tools in tools/ (invoked with -Check flag)
$toolsDir = Join-Path (Split-Path $PSScriptRoot) "tools"
$toolChecks = @(
    "query_global_ownership.ps1"
    "query_function_visibility.ps1"
) | ForEach-Object { Get-Item (Join-Path $toolsDir $_) }
$checks += $toolChecks

if ($checks.Count -eq 0) {
    Write-Host "  No static analysis checks found" -ForegroundColor Yellow
    exit 0
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
Write-Host "  Running $($checks.Count) static analysis check bundle(s) in parallel..." -ForegroundColor Cyan

# --- Launch all checks in parallel ---
# Each check runs as a separate powershell.exe process.
# Output is captured to temp files so parallel checks don't interleave.
# After all complete, results are displayed sequentially.
$procs = @()
foreach ($check in $checks) {
    $name = $check.BaseName
    $outFile = "$env:TEMP\sa_${name}.log"
    Remove-Item -Force -ErrorAction SilentlyContinue $outFile

    # Use -Command with *>&1 to merge ALL output streams (including Write-Host
    # information stream 6) into stdout, which then gets captured to file.
    # This preserves the full output from each check for sequential replay.
    $escapedPath = $check.FullName -replace "'", "''"
    $escapedSrc = $SourceDir -replace "'", "''"
    # Tools/ scripts need -Check flag to run in enforcement mode
    $extraArgs = if ($check.DirectoryName -ne $PSScriptRoot) { " -Check" } else { "" }
    $cmdArgs = "-NoProfile -Command ""& '$escapedPath' -SourceDir '$escapedSrc'$extraArgs *>&1; exit `$LASTEXITCODE"""

    $proc = Start-Process -FilePath "powershell.exe" `
        -ArgumentList $cmdArgs `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $outFile

    # Access .Handle immediately to cache the native process handle.
    # Without this, fast-exiting processes release their handle before
    # we read ExitCode, leaving it null (which fails the -ne 0 check).
    $handle = $proc.Handle

    $procs += @{
        Process     = $proc
        Name        = $name
        Label       = $check.Name
        OutFile     = $outFile
        LaunchTickMs = $sw.ElapsedMilliseconds
    }
}

# --- Wait for all and collect results ---
$failures = 0
$results = [System.Collections.ArrayList]::new()
foreach ($p in $procs) {
    $p.Process | Wait-Process
    $durationMs = 0
    if ($Timing) {
        # Prefer Process.ExitTime - StartTime for accurate per-process duration.
        # Fall back to parent Stopwatch if CLR returns garbage (rare race condition
        # that can produce values like -13 billion seconds).
        try {
            $ms = ($p.Process.ExitTime - $p.Process.StartTime).TotalMilliseconds
            if ($ms -ge 0 -and $ms -le 600000) {
                $durationMs = $ms
            } else {
                $durationMs = $sw.ElapsedMilliseconds - $p.LaunchTickMs
            }
        } catch {
            $durationMs = $sw.ElapsedMilliseconds - $p.LaunchTickMs
        }
    }
    [void]$results.Add(@{
        Name       = $p.Name
        Label      = $p.Label
        ExitCode   = $p.Process.ExitCode
        OutFile    = $p.OutFile
        DurationMs = $durationMs
    })
    if ($p.Process.ExitCode -ne 0) { $failures++ }
}

$sw.Stop()

# --- Count total checks (batch bundles expand to sub-checks via their timing JSON) ---
$totalChecks = 0
foreach ($r in $results) {
    $batchName = $r.Name -replace '^check_', ''
    $subFile = "$env:TEMP\sa_${batchName}_timing.json"
    if (Test-Path $subFile) {
        try {
            $subData = Get-Content $subFile -Raw | ConvertFrom-Json
            $totalChecks += @($subData).Count
        } catch {
            $totalChecks += 1
        }
    } else {
        $totalChecks += 1
    }
}

# --- Display results: only failures (passes are noise) ---
foreach ($r in $results) {
    if ($r.ExitCode -ne 0) {
        $output = if (Test-Path $r.OutFile) { Get-Content $r.OutFile -Raw -ErrorAction SilentlyContinue } else { "" }
        if ($output) {
            Write-Host $output.TrimEnd()
        }
        Write-Host "  FAIL: $($r.Label)" -ForegroundColor Red
    }
}

$passCount = $checks.Count - $failures
if ($failures -gt 0) {
    Write-Host "  Static analysis: $failures bundle failure(s), $passCount passed ($totalChecks total checks) ($($sw.ElapsedMilliseconds)ms)" -ForegroundColor Red
} else {
    Write-Host "  Static analysis: all $totalChecks checks passed ($($sw.ElapsedMilliseconds)ms)" -ForegroundColor Green
}

# Write per-check timing data for test.ps1 to consume
if ($Timing) {
    $timingData = @($results | ForEach-Object { @{ Name = $_.Label; DurationMs = [math]::Round($_.DurationMs, 1) } })

    # Merge batch sub-timing into parent entries (adds Children array)
    foreach ($entry in $timingData) {
        $batchName = $entry.Name -replace '\.ps1$', '' -replace '^check_', ''
        $subFile = "$env:TEMP\sa_${batchName}_timing.json"
        if (Test-Path $subFile) {
            $subData = Get-Content $subFile -Raw | ConvertFrom-Json
            $entry['Children'] = @($subData | ForEach-Object { @{ Name = $_.Name; DurationMs = $_.DurationMs } })
            Remove-Item -Force -ErrorAction SilentlyContinue $subFile
        }
    }

    $timingData | ConvertTo-Json -Compress -Depth 4 | Set-Content "$env:TEMP\sa_timing.json" -Encoding UTF8
}

# Cleanup temp files (output logs + any remaining sub-timing JSONs not consumed by $Timing block)
foreach ($r in $results) {
    Remove-Item -Force -ErrorAction SilentlyContinue $r.OutFile
    $batchName = $r.Name -replace '^check_', ''
    Remove-Item -Force -ErrorAction SilentlyContinue "$env:TEMP\sa_${batchName}_timing.json"
}

if ($failures -gt 0) {
    exit 1
}
exit 0
